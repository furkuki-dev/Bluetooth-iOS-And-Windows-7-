"""BT Share для Windows: окно приложения. Протокол и сеть находятся в btcore.py."""

import os
import queue
import threading
import time
import tkinter as tk
from functools import partial
from tkinter import filedialog, ttk

import btcore
from btcore import DEVICE_NAME, DISCOVERY_PORT, TRANSFER_PORT


class App(tk.Tk):
    STALE_AFTER = 3.0  # сек без объявления — устройство пропадает из списка

    def __init__(self):
        super().__init__()
        self.title("BT Share")
        self.geometry("480x480")
        self.minsize(440, 440)

        self.ui_queue = queue.Queue()
        self.devices = {}        # ip -> [имя, время последнего объявления]
        self.listen_stop = None  # Event поиска устройств (вкладка «Отправить»)
        self.beacon_stop = None  # Event объявления этого ПК (вкладка «Принять»)
        self.sending = False
        self.receiver = btcore.Receiver(
            post=self.to_ui,
            on_progress=self._recv_progress,
            on_saved=self._recv_saved,
            on_error=self._recv_error,
            recv_dir=btcore.default_recv_dir(),
            port=TRANSFER_PORT,
        )

        self._build_ui()
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self._on_tab_changed(0)
        self.after(150, self._pump)

    # ----- связь потоков с GUI -----

    def to_ui(self, fn):
        """Вызывается из любого потока: откладывает fn до главного потока GUI."""
        self.ui_queue.put(fn)

    def _pump(self):
        while True:
            try:
                fn = self.ui_queue.get_nowait()
            except queue.Empty:
                break
            try:
                fn()
            except tk.TclError:
                pass
        self._prune_devices()
        self.after(150, self._pump)

    # ----- окно -----

    def _build_ui(self):
        self.notebook = ttk.Notebook(self)
        self.notebook.pack(fill="both", expand=True, padx=10, pady=10)
        self.send_tab = ttk.Frame(self.notebook, padding=10)
        self.recv_tab = ttk.Frame(self.notebook, padding=10)
        self.notebook.add(self.send_tab, text="Отправить")
        self.notebook.add(self.recv_tab, text="Принять")
        self.notebook.bind("<<NotebookTabChanged>>", self._on_notebook)
        self._build_send_tab()
        self._build_recv_tab()

    def _build_send_tab(self):
        head = ttk.Frame(self.send_tab)
        head.pack(fill="x")
        ttk.Label(head, text="Устройства рядом", font=("Segoe UI", 11, "bold")).pack(side="left")
        ttk.Button(head, text="Очистить", command=self._clear_devices).pack(side="right")

        ttk.Label(self.send_tab,
                  text="Обе стороны в одной Wi-Fi сети. На получателе открыт режим «Принять».",
                  wraplength=420, justify="center").pack(fill="x", pady=(6, 0))

        self.tree = ttk.Treeview(self.send_tab, columns=("ip",), show="tree headings",
                                 selectmode="browse", height=8)
        self.tree.heading("#0", text="Имя")
        self.tree.heading("ip", text="IP")
        self.tree.column("#0", width=220)
        self.tree.column("ip", width=140, anchor="center")
        self.tree.pack(fill="both", expand=True, pady=8)

        self.send_btn = ttk.Button(self.send_tab, text="Выбрать файлы и отправить",
                                   command=self._pick_and_send)
        self.send_btn.pack(fill="x")

        self.send_progress = ttk.Progressbar(self.send_tab, maximum=100)
        self.send_progress.pack(fill="x", pady=8)

        self.send_status = ttk.Label(self.send_tab, text="", anchor="center",
                                     justify="center", wraplength=420)
        self.send_status.pack(fill="x")

    def _build_recv_tab(self):
        self.recv_status = ttk.Label(self.recv_tab, text="", font=("Segoe UI", 11),
                                     anchor="center", justify="center", wraplength=420)
        self.recv_status.pack(fill="x", pady=(10, 6))

        self.recv_progress = ttk.Progressbar(self.recv_tab, maximum=100)
        self.recv_progress.pack(fill="x", pady=6)

        self.recv_list = tk.Listbox(self.recv_tab, height=8)
        self.recv_list.pack(fill="both", expand=True, pady=6)

        ttk.Label(self.recv_tab,
                  text="Если появится запрос брандмауэра Windows, разрешите доступ для частных сетей.",
                  wraplength=420, justify="center").pack(fill="x", pady=(0, 6))

        row = ttk.Frame(self.recv_tab)
        row.pack(fill="x")
        ttk.Label(row, text=btcore.default_recv_dir(), wraplength=340).pack(side="left")
        ttk.Button(row, text="Открыть папку", command=self._open_folder).pack(side="right")

    # ----- вкладки: поиск или приём, но не оба сразу -----

    def _current_tab(self):
        return self.notebook.index(self.notebook.select())

    def _on_notebook(self, _event):
        self._on_tab_changed(self._current_tab())

    def _on_tab_changed(self, index):
        if index == 0:
            self._stop_receiving()
            self._start_listening()
        else:
            self._stop_listening()
            self._start_receiving()

    # ----- поиск устройств -----

    def _start_listening(self, attempt=0):
        if self.listen_stop is not None or self._current_tab() != 0:
            return
        try:
            sock = btcore.open_discovery_socket(DISCOVERY_PORT)
        except OSError:
            if attempt < 5:
                self.after(400, self._start_listening, attempt + 1)  # порт мог ещё не освободиться
            else:
                self.send_status.config(text=f"Порт {DISCOVERY_PORT} занят. Закройте другие копии BT Share.")
            return
        self.listen_stop = threading.Event()
        threading.Thread(target=btcore.discovery_loop,
                         args=(sock, self.listen_stop, self._on_beacon),
                         daemon=True).start()
        self.send_status.config(text="Поиск устройств…")

    def _stop_listening(self):
        if self.listen_stop is not None:
            self.listen_stop.set()
            self.listen_stop = None
        self.devices.clear()
        self._sync_tree()

    def _on_beacon(self, ip, name):  # вызывается из сетевого потока
        self.to_ui(partial(self._device_seen, ip, name))

    def _device_seen(self, ip, name):
        self.devices[ip] = [name, time.time()]
        self._sync_tree()

    def _prune_devices(self):
        now = time.time()
        stale = [ip for ip, (_, seen) in self.devices.items() if now - seen > self.STALE_AFTER]
        if stale:
            for ip in stale:
                del self.devices[ip]
            self._sync_tree()

    def _sync_tree(self):
        existing = set(self.tree.get_children())
        for ip, (name, _) in self.devices.items():
            if ip in existing:
                self.tree.item(ip, text=name)
            else:
                self.tree.insert("", "end", iid=ip, text=name, values=(ip,))
        for iid in existing - set(self.devices):
            self.tree.delete(iid)

    def _clear_devices(self):
        self.devices.clear()
        self._sync_tree()

    # ----- отправка -----

    def _pick_and_send(self):
        if self.sending:
            return
        selection = self.tree.selection()
        if not selection:
            self.send_status.config(text="Сначала выберите устройство в списке")
            return
        ip = selection[0]
        paths = filedialog.askopenfilenames(title="Файлы для отправки")
        if not paths:
            return

        name = self.devices.get(ip, [ip])[0]
        self.sending = True
        self.send_btn.state(["disabled"])
        self.send_progress["value"] = 0
        self.send_status.config(text=f"Отправка на {name}…")
        threading.Thread(target=self._send_worker, args=(ip, name, list(paths)),
                         daemon=True).start()

    def _send_worker(self, ip, name, paths):
        try:
            btcore.send_files(ip, TRANSFER_PORT, paths,
                              lambda fraction, mbps: self.to_ui(partial(self._send_progress, fraction, mbps)))
            self.to_ui(partial(self._send_done, f"Отправлено файлов: {len(paths)} на «{name}»", True))
        except OSError as e:
            self.to_ui(partial(self._send_done,
                               f"Нет связи с «{name}». Проверьте, что там открыт режим «Принять» "
                               f"и брандмауэр разрешает соединение. ({e})", False))
        except Exception as e:
            self.to_ui(partial(self._send_done, f"Ошибка отправки: {e}", False))

    def _send_progress(self, fraction, mbps):
        self.send_progress["value"] = fraction * 100
        self.send_status.config(text=f"Отправка… {mbps:.1f} МБ/с")

    def _send_done(self, text, ok):
        self.sending = False
        self.send_btn.state(["!disabled"])
        self.send_progress["value"] = 100 if ok else 0
        self.send_status.config(text=text)

    # ----- приём -----

    def _start_receiving(self, attempt=0):
        if self.beacon_stop is not None or self._current_tab() != 1:
            return
        try:
            self.receiver.start()
        except OSError:
            if attempt < 5:
                self.after(400, self._start_receiving, attempt + 1)
            else:
                self.recv_status.config(text=f"Порт {TRANSFER_PORT} занят. Закройте другие копии BT Share.")
            return
        self.beacon_stop = threading.Event()
        threading.Thread(target=btcore.beacon_loop,
                         args=(self.beacon_stop, DISCOVERY_PORT, DEVICE_NAME),
                         daemon=True).start()
        self.recv_status.config(text=f"Ожидание отправителя…\nИмя этого ПК: {DEVICE_NAME}")

    def _stop_receiving(self):
        self.receiver.stop()
        if self.beacon_stop is not None:
            self.beacon_stop.set()
            self.beacon_stop = None
        self.recv_status.config(text="")

    def _recv_progress(self, fraction):
        self.recv_progress["value"] = max(0, min(100, fraction * 100))

    def _recv_saved(self, path):
        name = os.path.basename(path)
        self.recv_list.insert("end", name)
        self.recv_progress["value"] = 100
        self.recv_status.config(text=f"Получен файл: {name}")

    def _recv_error(self, text):
        self.recv_status.config(text=f"Ошибка приёма: {text}")

    # ----- прочее -----

    def _open_folder(self):
        folder = btcore.default_recv_dir()
        os.makedirs(folder, exist_ok=True)
        os.startfile(folder)

    def _on_close(self):
        self._stop_listening()
        self._stop_receiving()
        self.destroy()


if __name__ == "__main__":
    App().mainloop()
