"""BT Share: протокол и сеть для Windows. Без GUI, только стандартная библиотека.

Протокол (тот же, что в приложении для iPhone):
  Объявление: UDP, порт 45678, раз в секунду, байты b"BTSHARE1:" + имя (UTF-8, до 40 байт).
              Отправляется на 255.255.255.255 и на широковещательные адреса подсетей ПК.
  Передача:   TCP, порт 45679:
              b"BTS1" + u32 (число файлов, big-endian)
              для каждого файла: u16 длина имени | имя UTF-8 | u64 размер | данные
              после всех файлов получатель отвечает байтом 0x06.
"""

import os
import platform
import re
import socket
import struct
import threading
import time
from functools import partial

DISCOVERY_PORT = 45678
TRANSFER_PORT = 45679
BEACON_PREFIX = b"BTSHARE1:"
MAGIC = b"BTS1"
ACK = b"\x06"
CHUNK = 1 << 20  # 1 МБ
MAX_NAME_BYTES = 40
DEVICE_NAME = platform.node() or "PC"


def default_recv_dir():
    return os.path.join(os.path.expanduser("~"), "Downloads", "BTShare")


# ---------- кодирование ----------

def name_bytes(text, limit=MAX_NAME_BYTES):
    """Имя для объявления, обрезанное по байтам без порчи UTF-8."""
    return text.encode("utf-8")[:limit].decode("utf-8", "ignore").encode("utf-8")


def make_beacon(name):
    return BEACON_PREFIX + name_bytes(name)


def parse_beacon(data):
    """Имя устройства из объявления или None, если пакет не от BT Share."""
    if not data.startswith(BEACON_PREFIX):
        return None
    return data[len(BEACON_PREFIX):].decode("utf-8", "replace")


def make_session_header(file_count):
    return MAGIC + struct.pack(">I", file_count)


def make_file_meta(name, size):
    raw = name.encode("utf-8")
    return struct.pack(">H", len(raw)) + raw + struct.pack(">Q", size)


def safe_name(name):
    name = os.path.basename(name.replace("\\", "/"))
    name = re.sub(r'[<>:"/\\|?*\x00-\x1f]', "_", name).strip(" .")
    return name or "file.bin"


def unique_path(folder, name):
    base, ext = os.path.splitext(name)
    path = os.path.join(folder, name)
    index = 1
    while os.path.exists(path):
        path = os.path.join(folder, f"{base} ({index}){ext}")
        index += 1
    return path


# ---------- сокеты ----------

def recv_exact(sock, n):
    buf = bytearray(n)
    view = memoryview(buf)
    got = 0
    while got < n:
        r = sock.recv_into(view[got:], n - got)
        if r == 0:
            raise ConnectionError("соединение прервано")
        got += r
    return bytes(buf)


def local_broadcast_addresses():
    """Общий широковещательный адрес и адреса подсетей ПК (для сетей /24)."""
    addrs = {"255.255.255.255"}
    try:
        _, _, ips = socket.gethostbyname_ex(socket.gethostname())
        for ip in ips:
            parts = ip.split(".")
            if len(parts) == 4 and not ip.startswith("127."):
                addrs.add(".".join(parts[:3] + ["255"]))
    except OSError:
        pass
    return sorted(addrs)


# ---------- приём ----------

class Receiver:
    """TCP-сервер приёма. Колбэки передаются через post(), чтобы выполняться в GUI-потоке."""

    def __init__(self, post, on_progress, on_saved, on_error,
                 recv_dir=None, host="", port=TRANSFER_PORT):
        self.post = post
        self.on_progress = on_progress
        self.on_saved = on_saved
        self.on_error = on_error
        self.recv_dir = recv_dir or default_recv_dir()
        self.host = host
        self.port = port
        self.bound_port = None
        self.running = False

    def start(self):
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            srv.bind((self.host, self.port))
        except OSError:
            srv.close()
            raise
        srv.listen(8)
        srv.settimeout(0.5)
        self.bound_port = srv.getsockname()[1]
        self.running = True
        threading.Thread(target=self._accept_loop, args=(srv,), daemon=True).start()

    def stop(self):
        self.running = False

    def _accept_loop(self, srv):
        try:
            while self.running:
                try:
                    conn, _ = srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                threading.Thread(target=self._handle, args=(conn,), daemon=True).start()
        finally:
            srv.close()

    def _handle(self, conn):
        unfinished = None
        with conn:
            try:
                conn.settimeout(30)
                if recv_exact(conn, 4) != MAGIC:
                    raise ValueError("неизвестный отправитель")
                (count,) = struct.unpack(">I", recv_exact(conn, 4))
                os.makedirs(self.recv_dir, exist_ok=True)

                for _ in range(count):
                    (name_len,) = struct.unpack(">H", recv_exact(conn, 2))
                    name = safe_name(recv_exact(conn, name_len).decode("utf-8", "replace"))
                    (size,) = struct.unpack(">Q", recv_exact(conn, 8))
                    path = unique_path(self.recv_dir, name)
                    unfinished = path
                    self._receive_body(conn, path, size)
                    unfinished = None
                    self.post(partial(self.on_saved, path))

                conn.sendall(ACK)
            except Exception as e:
                if unfinished and os.path.exists(unfinished):
                    os.remove(unfinished)
                self.post(partial(self.on_error, str(e)))

    def _receive_body(self, conn, path, size):
        buf = bytearray(CHUNK)
        view = memoryview(buf)
        remaining = size
        with open(path, "wb") as f:
            while remaining > 0:
                r = conn.recv_into(view, min(remaining, CHUNK))
                if r == 0:
                    raise ConnectionError("соединение прервано")
                f.write(view[:r])
                remaining -= r
                self.post(partial(self.on_progress, 1 - remaining / size))


# ---------- отправка ----------

def send_files(host, port, paths, on_progress=None):
    """Блокирующая отправка. on_progress(доля 0..1, МБ/с). Возвращает число отправленных байт."""
    if on_progress is None:
        on_progress = lambda fraction, mbps: None
    sizes = [os.path.getsize(p) for p in paths]
    total = sum(sizes) or 1
    sent = 0
    started = time.time()

    with socket.create_connection((host, port), timeout=10) as s:
        s.settimeout(30)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
        s.sendall(make_session_header(len(paths)))

        for path, size in zip(paths, sizes):
            s.sendall(make_file_meta(os.path.basename(path), size))
            with open(path, "rb", buffering=0) as f:
                while True:
                    chunk = f.read(CHUNK)
                    if not chunk:
                        break
                    s.sendall(chunk)
                    sent += len(chunk)
                    elapsed = max(time.time() - started, 0.001)
                    on_progress(sent / total, sent / elapsed / 1048576)

        if s.recv(1) != ACK:
            raise ConnectionError("получатель не подтвердил приём")
    return sent


# ---------- поиск устройств ----------

def open_discovery_socket(port=DISCOVERY_PORT):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.bind(("", port))
    except OSError:
        s.close()
        raise
    s.settimeout(0.5)
    return s


def discovery_loop(sock, stop, on_found):
    """Слушает объявления до установки stop. on_found(ip, name)."""
    try:
        while not stop.is_set():
            try:
                data, addr = sock.recvfrom(512)
            except socket.timeout:
                continue
            except OSError:
                break
            name = parse_beacon(data)
            if name is not None:
                on_found(addr[0], name)
    finally:
        sock.close()


def beacon_loop(stop, port=DISCOVERY_PORT, name=DEVICE_NAME):
    """Раз в секунду объявляет этот ПК, пока stop не установлен."""
    payload = make_beacon(name)
    targets = [(addr, port) for addr in local_broadcast_addresses()]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    try:
        while not stop.is_set():
            for target in targets:
                try:
                    s.sendto(payload, target)
                except OSError:
                    pass
            stop.wait(1.0)
    finally:
        s.close()
