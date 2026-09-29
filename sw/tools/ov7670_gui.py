#!/usr/bin/env python3
"""Live GUI for the STM32F446RE OV7670 tester (sw/stm32_camtest).

Live view plus the diagnostic commands in one window, so checking the camera
doesn't mean remembering CLI incantations.

Serial I/O runs on a worker thread and hands frames to Tk through a queue --
Tk is not thread-safe, so the UI thread only ever touches widgets, and the
worker only ever touches the port.

Run:
    .venv-litex/bin/python sw/tools/ov7670_gui.py
"""
import queue
import sys
import threading
import time
import tkinter as tk
from tkinter import filedialog, ttk

try:
    import serial
except ImportError:
    sys.exit("pyserial required")

from PIL import Image, ImageTk

PORT_DEFAULT = "/dev/ttyACM0"
BAUD = 921600
W, H = 160, 120
ZOOM = 4

YFRAME = b"YFRAME"


class CameraLink:
    """Owns the serial port. Every method here runs on the worker thread."""

    def __init__(self, port, baud):
        self.ser = serial.Serial(port, baud, timeout=0.2)
        time.sleep(0.3)

    def close(self):
        try:
            self.ser.close()
        except Exception:
            pass

    def drain(self, seconds=0.4):
        end = time.time() + seconds
        buf = b""
        while time.time() < end:
            buf += self.ser.read(4096)
        return buf

    def text_command(self, letter, settle):
        self.drain(0.2)
        self.ser.write(letter.encode())
        time.sleep(settle)
        return self.drain(0.5).decode(errors="replace")

    def stream(self, stop_event, on_frame, on_log):
        """Drive the firmware's continuous luma stream until stop_event."""
        self.drain(0.2)
        self.ser.write(b"s")
        buf = b""
        npix = W * H
        while not stop_event.is_set():
            chunk = self.ser.read(16384)
            if chunk:
                buf += chunk
            i = buf.find(YFRAME)
            if i < 0:
                # Keep only a tail; a header may be split across reads.
                if len(buf) > 1 << 20:
                    buf = buf[-4096:]
                continue
            eol = buf.find(b"\r\n", i)
            if eol < 0:
                continue
            start = eol + 2
            while len(buf) - start < npix and not stop_event.is_set():
                chunk = self.ser.read(16384)
                if chunk:
                    buf += chunk
            if stop_event.is_set():
                break
            on_frame(buf[start:start + npix])
            buf = buf[start + npix:]

        # Any byte stops the firmware loop; then flush whatever was in flight.
        self.ser.write(b"x")
        time.sleep(0.2)
        self.drain(0.3)
        on_log("-- stream stopped --\n")


class App:
    def __init__(self, root, port):
        self.root = root
        self.port = port
        self.link = None
        self.worker = None
        self.stop_event = threading.Event()
        self.frames = queue.Queue(maxsize=2)
        self.logs = queue.Queue()
        self.busy = False

        self.fps_t0 = time.time()
        self.fps_n = 0
        self.last_plane = None

        root.title("OV7670 tester — STM32F446RE")
        self._build()
        self._connect()
        self.root.after(30, self._pump)
        self.root.protocol("WM_DELETE_WINDOW", self.on_close)

    # ---------------- UI ----------------
    def _build(self):
        main = ttk.Frame(self.root, padding=8)
        main.grid(sticky="nsew")
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)

        left = ttk.Frame(main)
        left.grid(row=0, column=0, sticky="n")

        self.canvas = tk.Canvas(left, width=W * ZOOM, height=H * ZOOM,
                                bg="#111", highlightthickness=1,
                                highlightbackground="#444")
        self.canvas.grid(row=0, column=0)
        self._img_id = self.canvas.create_image(0, 0, anchor="nw")
        self._photo = None

        self.stats = ttk.Label(left, text="not streaming",
                               font=("TkFixedFont", 10))
        self.stats.grid(row=1, column=0, sticky="w", pady=(6, 0))

        btns = ttk.Frame(left)
        btns.grid(row=2, column=0, sticky="w", pady=(8, 0))
        self.b_stream = ttk.Button(btns, text="▶ Start stream",
                                   command=self.toggle_stream, width=15)
        self.b_stream.grid(row=0, column=0, padx=(0, 6))
        self.b_snap = ttk.Button(btns, text="Save PNG",
                                 command=self.save_png, width=11)
        self.b_snap.grid(row=0, column=1, padx=(0, 6))

        diag = ttk.LabelFrame(left, text="Diagnostics", padding=6)
        diag.grid(row=3, column=0, sticky="ew", pady=(10, 0))
        for i, (label, letter, settle) in enumerate([
                ("Probe SCCB", "p", 2.5),
                ("Signal activity", "a", 3.5),
                ("Register dump", "r", 7.0)]):
            ttk.Button(diag, text=label, width=17,
                       command=lambda l=letter, s=settle: self.run_text(l, s)
                       ).grid(row=0, column=i, padx=3)
        ttk.Label(diag, text="(stop the stream first)",
                  foreground="#777").grid(row=1, column=0, columnspan=3,
                                          sticky="w", pady=(4, 0))

        right = ttk.Frame(main)
        right.grid(row=0, column=1, sticky="nsew", padx=(12, 0))
        main.columnconfigure(1, weight=1)
        main.rowconfigure(0, weight=1)

        ttk.Label(right, text="Console").grid(row=0, column=0, sticky="w")
        self.text = tk.Text(right, width=62, height=26, wrap="none",
                            font=("TkFixedFont", 9), bg="#1b1b1b", fg="#ddd",
                            insertbackground="#ddd")
        self.text.grid(row=1, column=0, sticky="nsew")
        sb = ttk.Scrollbar(right, command=self.text.yview)
        sb.grid(row=1, column=1, sticky="ns")
        self.text["yscrollcommand"] = sb.set
        right.rowconfigure(1, weight=1)
        right.columnconfigure(0, weight=1)

    def log(self, s):
        self.text.insert("end", s)
        self.text.see("end")

    # ---------------- serial plumbing ----------------
    def _connect(self):
        try:
            self.link = CameraLink(self.port, BAUD)
            self.log(f"connected: {self.port} @ {BAUD}\n")
        except Exception as e:
            self.log(f"CONNECT FAILED: {e}\n"
                     f"Is another program holding {self.port}?\n")

    def _pump(self):
        """UI-thread tick: drain the queues filled by the worker."""
        try:
            while True:
                self.log(self.logs.get_nowait())
        except queue.Empty:
            pass

        plane = None
        try:
            while True:
                plane = self.frames.get_nowait()
        except queue.Empty:
            pass

        if plane is not None:
            self.last_plane = plane
            img = Image.frombytes("L", (W, H), plane).resize(
                (W * ZOOM, H * ZOOM), Image.NEAREST)
            self._photo = ImageTk.PhotoImage(img)
            self.canvas.itemconfig(self._img_id, image=self._photo)

            self.fps_n += 1
            dt = time.time() - self.fps_t0
            if dt >= 1.0:
                lo, hi = min(plane), max(plane)
                self.stats.config(
                    text=f"{self.fps_n/dt:4.2f} fps   min={lo:3d} max={hi:3d}"
                         f"   {W}x{H} luma")
                self.fps_t0, self.fps_n = time.time(), 0

        self.root.after(30, self._pump)

    # ---------------- actions ----------------
    def toggle_stream(self):
        if self.worker and self.worker.is_alive():
            self.stop_event.set()
            self.b_stream.config(text="▶ Start stream", state="disabled")
            self.root.after(600, lambda: self.b_stream.config(state="normal"))
            self.stats.config(text="not streaming")
            return

        if not self.link:
            self.log("no serial connection\n")
            return

        self.stop_event = threading.Event()
        self.fps_t0, self.fps_n = time.time(), 0

        def on_frame(plane):
            try:
                self.frames.put_nowait(plane)
            except queue.Full:
                pass          # UI is behind; newest frame wins, drop this one

        self.worker = threading.Thread(
            target=self._safe,
            args=(lambda: self.link.stream(self.stop_event, on_frame,
                                           self.logs.put),),
            daemon=True)
        self.worker.start()
        self.b_stream.config(text="■ Stop stream")
        self.log("-- streaming --\n")

    def run_text(self, letter, settle):
        if self.worker and self.worker.is_alive():
            self.log("stop the stream first\n")
            return
        if not self.link or self.busy:
            return
        self.busy = True
        self.log(f"\n> command '{letter}'\n")

        def job():
            out = self.link.text_command(letter, settle)
            self.logs.put(out + "\n")
            self.busy = False

        threading.Thread(target=self._safe, args=(job,), daemon=True).start()

    def _safe(self, fn):
        try:
            fn()
        except Exception as e:
            self.logs.put(f"ERROR: {type(e).__name__}: {e}\n")
            self.busy = False

    def save_png(self):
        if self.last_plane is None:
            self.log("nothing captured yet\n")
            return
        path = filedialog.asksaveasfilename(
            defaultextension=".png",
            filetypes=[("PNG image", "*.png")],
            initialfile=time.strftime("ov7670_%Y%m%d_%H%M%S.png"))
        if not path:
            return
        Image.frombytes("L", (W, H), self.last_plane).save(path)
        self.log(f"saved {path}\n")

    def on_close(self):
        self.stop_event.set()
        if self.worker and self.worker.is_alive():
            self.worker.join(timeout=1.5)
        if self.link:
            self.link.close()
        self.root.destroy()


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else PORT_DEFAULT
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except tk.TclError:
        pass
    App(root, port)
    root.mainloop()


if __name__ == "__main__":
    main()
