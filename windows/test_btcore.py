"""Тесты протокола BT Share. Запуск: python -m unittest discover -s windows -v"""

import os
import shutil
import socket
import tempfile
import threading
import time
import unittest

import btcore


def wait_for(condition, timeout=5.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if condition():
            return True
        time.sleep(0.05)
    return bool(condition())


class ProtocolTests(unittest.TestCase):
    def test_beacon_roundtrip(self):
        self.assertEqual(btcore.parse_beacon(btcore.make_beacon("Petya-PC")), "Petya-PC")

    def test_foreign_packets_are_ignored(self):
        self.assertIsNone(btcore.parse_beacon(b"hello"))

    def test_beacon_name_is_cut_on_character_boundary(self):
        parsed = btcore.parse_beacon(btcore.make_beacon("я" * 50))
        self.assertTrue(parsed)
        self.assertTrue(all(ch == "я" for ch in parsed))
        self.assertLessEqual(len(parsed.encode("utf-8")), btcore.MAX_NAME_BYTES)

    def test_session_header_layout(self):
        self.assertEqual(btcore.make_session_header(2), b"BTS1\x00\x00\x00\x02")

    def test_file_meta_layout(self):
        self.assertEqual(btcore.make_file_meta("a.txt", 5),
                         b"\x00\x05" + b"a.txt" + b"\x00" * 7 + b"\x05")

    def test_safe_name(self):
        self.assertEqual(btcore.safe_name("../../evil:name?.txt"), "evil_name_.txt")
        self.assertEqual(btcore.safe_name(""), "file.bin")

    def test_broadcast_addresses_include_limited_broadcast(self):
        self.assertIn("255.255.255.255", btcore.local_broadcast_addresses())


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.src = os.path.join(self.tmp, "src")
        self.dst = os.path.join(self.tmp, "dst")
        os.makedirs(self.src)
        self.saved = []
        self.errors = []
        self.receiver = btcore.Receiver(
            post=lambda fn: fn(),
            on_progress=lambda value: None,
            on_saved=self.saved.append,
            on_error=self.errors.append,
            recv_dir=self.dst,
            host="127.0.0.1",
            port=0,
        )
        self.receiver.start()
        self.port = self.receiver.bound_port

    def tearDown(self):
        self.receiver.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def make_source(self, name, data):
        path = os.path.join(self.src, name)
        with open(path, "wb") as f:
            f.write(data)
        return path

    def test_several_files_arrive_intact(self):
        files = [
            self.make_source("one.bin", b"hello"),
            self.make_source("big.bin", os.urandom(3 * btcore.CHUNK + 123)),
            self.make_source("пример.txt", "привет мир".encode("utf-8")),
            self.make_source("empty.txt", b""),
        ]
        btcore.send_files("127.0.0.1", self.port, files)
        self.assertEqual(self.errors, [])
        self.assertEqual(len(self.saved), len(files))
        for src_path in files:
            name = os.path.basename(src_path)
            with open(src_path, "rb") as a, open(os.path.join(self.dst, name), "rb") as b:
                self.assertEqual(a.read(), b.read(), name)

    def test_progress_reaches_one(self):
        src_path = self.make_source("p.bin", os.urandom(2 * btcore.CHUNK))
        fractions = []
        btcore.send_files("127.0.0.1", self.port, [src_path], lambda f, mbps: fractions.append(f))
        self.assertTrue(fractions)
        self.assertAlmostEqual(fractions[-1], 1.0)

    def test_same_name_gets_suffix(self):
        src_path = self.make_source("dup.txt", b"x")
        btcore.send_files("127.0.0.1", self.port, [src_path])
        btcore.send_files("127.0.0.1", self.port, [src_path])
        self.assertTrue(os.path.exists(os.path.join(self.dst, "dup (1).txt")))

    def test_unknown_sender_is_rejected(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(b"XXXX0000")
            try:
                s.recv(1)  # сервер закрывает соединение
            except ConnectionResetError:
                pass  # закрытие с непрочитанными данными даёт сброс, это тоже отказ
        self.assertTrue(wait_for(lambda: self.errors))
        self.assertEqual(self.saved, [])

    def test_disconnect_removes_partial_file(self):
        with socket.create_connection(("127.0.0.1", self.port), timeout=5) as s:
            s.sendall(btcore.make_session_header(1)
                      + btcore.make_file_meta("half.bin", 100)
                      + b"0" * 10)
        self.assertTrue(wait_for(lambda: self.errors))
        self.assertFalse(os.path.exists(os.path.join(self.dst, "half.bin")))


class DiscoveryTests(unittest.TestCase):
    def test_listener_receives_beacon(self):
        sock = btcore.open_discovery_socket(port=0)
        port = sock.getsockname()[1]
        found = []
        stop = threading.Event()
        worker = threading.Thread(target=btcore.discovery_loop,
                                  args=(sock, stop, lambda ip, name: found.append((ip, name))),
                                  daemon=True)
        worker.start()

        out = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            out.sendto(btcore.make_beacon("TestPC"), ("127.0.0.1", port))
        finally:
            out.close()

        self.assertTrue(wait_for(lambda: found))
        stop.set()
        worker.join(3)
        self.assertEqual(found, [("127.0.0.1", "TestPC")])


if __name__ == "__main__":
    unittest.main()
