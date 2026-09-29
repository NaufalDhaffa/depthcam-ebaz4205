#!/usr/bin/env python3
"""Live tuning interface for the EBAZ4205 stereo depth camera.

Replaces what the Basys3 reference design did with five pushbuttons (resend
the camera register table; nudge the stereo rectification offsets) and adds
arbitrary SCCB register access, orientation control, view rotation and
config persistence.

Two UDP channels, both to the board at 192.168.2.10:
  * 5001  disparity frames stream in  (chunked, see depth_receiver.py)
  * 5002  control request/response    (see sw/apps/depth_stream/src/cam_ctrl.h)

Run:
    .venv-litex/bin/python sw/tools/depth_tuner.py
"""
import json
import queue
import socket
import struct
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

try:
    import numpy as np
    from PIL import Image, ImageTk
except ImportError:
    sys.exit("needs numpy and pillow")

BOARD_IP   = "192.168.2.10"
FRAME_PORT = 5001
CTRL_PORT  = 5002

W, H   = 160, 120
PIXELS = W * H
# 8 bytes, not 6: the board side must keep this a multiple of 4 or its
# memcpy out of the Strongly Ordered PL windows faults. See
# sw/apps/depth_stream/src/depth_stream.h.
HDR    = struct.Struct("<HHBBH")
PLANES = {0: "depth", 1: "cam1", 2: "cam2"}

# Physical stereo geometry. Baseline is the distance between the two lens
# centres; focal length is in PIXELS and must be calibrated (see calibrate()),
# because it depends on the lens actually fitted, not just the sensor.
BASELINE_MM      = 36.0
DEFAULT_FOCAL_PX = 0.0        # 0 = uncalibrated, distance readout disabled

# OV7670 registers this UI exposes by name.
REG_GAIN   = 0x00
REG_COM8   = 0x13   # AGC / AWB / AEC enables
REG_MVFP   = 0x1E   # bit5 mirror, bit4 vflip
REG_AECH   = 0x10
REG_COM7   = 0x12   # bit1 = colour bar test pattern
REG_BRIGHT = 0x55
REG_CONTRAS= 0x56

CMD = dict(PING=0x00, SCCB_WRITE=0x01, SCCB_READ=0x02,
           SET_RECT=0x03, RESEND=0x04, GET_STATUS=0x05, SET_PLANES=0x06)
ST_NAMES = {0: "ok", 1: "bad magic", 2: "bad cmd", 3: "NO ACK"}

REQ = struct.Struct("<BBBBBBH")   # magic0 magic1 cmd cam arg0 arg1 seq
RSP = struct.Struct("<BBBBBBH")   # magic0 magic1 cmd status value pad seq


class Control:
    """Synchronous request/response client for the board's tuning port."""

    def __init__(self, ip=BOARD_IP, port=CTRL_PORT, timeout=1.0):
        self.addr = (ip, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)
        self.seq = 0
        self.lock = threading.Lock()

    def call(self, cmd, cam=0, arg0=0, arg1=0):
        """Returns (status, value). Raises TimeoutError if the board is silent."""
        with self.lock:
            self.seq = (self.seq + 1) & 0xFFFF
            seq = self.seq
            pkt = REQ.pack(ord('D'), ord('C'), cmd, cam, arg0, arg1, seq)
            # One retry: a lost datagram on a point-to-point link is rare but
            # a dropped tuning command that silently does nothing is worse
            # than a slightly slower UI.
            for _ in range(2):
                self.sock.sendto(pkt, self.addr)
                try:
                    data, _ = self.sock.recvfrom(64)
                except socket.timeout:
                    continue
                if len(data) < RSP.size:
                    continue
                m0, m1, rcmd, status, value, _pad, rseq = RSP.unpack_from(data)
                if (m0, m1) == (ord('D'), ord('C')) and rseq == seq:
                    return status, value
            raise TimeoutError("no response from board")

    def sccb_write(self, cam, reg, val):
        return self.call(CMD["SCCB_WRITE"], cam, reg, val)

    def sccb_read(self, cam, reg):
        return self.call(CMD["SCCB_READ"], cam, reg)

    def set_rect(self, row, col):
        return self.call(CMD["SET_RECT"], 0, row & 0xF, col & 0xFF)

    def resend(self):
        return self.call(CMD["RESEND"])

    def status(self):
        return self.call(CMD["GET_STATUS"])

    def set_planes(self, mask):
        """mask bit0 = stream cam1 preview, bit1 = cam2."""
        return self.call(CMD["SET_PLANES"], 0, mask & 3, 0)


def frame_reader(stop, out_q, log_q):
    """Demultiplex the three interleaved planes.

    Each plane is reassembled independently: the board sends one plane per
    frame (round-robin) to keep the per-frame datagram burst small, so a
    given plane only refreshes every few frames and must not be reset by
    another plane's chunks arriving in between."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", FRAME_PORT))
    except OSError as e:
        log_q.put(f"cannot bind UDP {FRAME_PORT}: {e}")
        return
    s.settimeout(0.5)

    state = {p: {"id": None, "buf": bytearray(PIXELS), "have": 0} for p in PLANES}
    while not stop.is_set():
        try:
            pkt, _ = s.recvfrom(2048)
        except socket.timeout:
            continue
        if len(pkt) < HDR.size:
            continue
        fid, idx, plane, _r, _r2 = HDR.unpack_from(pkt, 0)
        if plane not in state:
            continue
        payload = pkt[HDR.size:]
        if idx + len(payload) > PIXELS:
            continue
        st = state[plane]
        if fid != st["id"]:
            st["id"], st["have"], st["buf"] = fid, 0, bytearray(PIXELS)
        st["buf"][idx:idx + len(payload)] = payload
        st["have"] += len(payload)
        if st["have"] >= PIXELS:
            try:
                out_q.put_nowait((plane, bytes(st["buf"])))
            except queue.Full:
                pass
            st["id"] = None
    s.close()


class Tuner:
    CONFIG_KEYS = ("row_offset", "col_offset", "mirror", "vflip", "agc",
                   "awb", "aec", "testbar", "brightness", "contrast",
                   "rotation", "focal_px", "both_cams")

    def __init__(self, root):
        self.root = root
        self.ctrl = Control()
        self.stop = threading.Event()
        # Room for a couple of complete sets of all three planes; at
        # maxsize=2 the third plane of every set was dropped.
        self.frames = queue.Queue(maxsize=6)
        self.logs = queue.Queue()
        self.last_plane = None
        self.fps_t0, self.fps_n = time.time(), 0

        root.title("EBAZ4205 stereo depth — tuning")
        self._vars()
        self._build()

        threading.Thread(target=frame_reader,
                         args=(self.stop, self.frames, self.logs),
                         daemon=True).start()
        self.root.after(30, self._pump)
        self.root.protocol("WM_DELETE_WINDOW", self.close)
        # Off the UI thread: a silent board would otherwise freeze the window
        # for the full request timeout before it is even usable.
        threading.Thread(target=self.ping, daemon=True).start()

    # ---------------- state ----------------
    def _vars(self):
        self.row_offset = tk.IntVar(value=8)
        self.col_offset = tk.IntVar(value=20)
        self.mirror  = tk.BooleanVar(value=False)
        self.vflip   = tk.BooleanVar(value=False)
        self.agc     = tk.BooleanVar(value=True)
        self.awb     = tk.BooleanVar(value=True)
        self.aec     = tk.BooleanVar(value=True)
        self.testbar = tk.BooleanVar(value=False)
        self.brightness = tk.IntVar(value=0x00)
        self.contrast   = tk.IntVar(value=0x40)
        self.rotation   = tk.IntVar(value=0)
        self.focal_px   = tk.DoubleVar(value=DEFAULT_FOCAL_PX)
        self.both_cams  = tk.BooleanVar(value=True)
        self.target_cam = tk.IntVar(value=0)
        self.stream_cam1 = tk.BooleanVar(value=True)
        self.stream_cam2 = tk.BooleanVar(value=True)

    def cams(self):
        return (0, 1) if self.both_cams.get() else (self.target_cam.get(),)

    # ---------------- UI ----------------
    def _build(self):
        main = ttk.Frame(self.root, padding=8)
        main.grid(sticky="nsew")
        self.root.columnconfigure(0, weight=1)
        self.root.rowconfigure(0, weight=1)

        # --- view ---
        view = ttk.Frame(main)
        view.grid(row=0, column=0, sticky="n")
        self.canvases, self._img_ids, self._photos = {}, {}, {}
        grid = ttk.Frame(view)
        grid.grid(row=0, column=0)
        layout = [(1, "Camera 1 (raw)", 0, 0), (2, "Camera 2 (raw)", 0, 1),
                  (0, "Depth map", 1, 0)]
        for plane, title, r, c in layout:
            f = ttk.LabelFrame(grid, text=title, padding=3)
            f.grid(row=r, column=c, padx=4, pady=4)
            cv = tk.Canvas(f, width=336, height=252, bg="#111",
                           highlightthickness=1, highlightbackground="#444")
            cv.grid(row=0, column=0)
            self.canvases[plane] = cv
            self._img_ids[plane] = cv.create_image(168, 126, anchor="center")
            self._photos[plane] = None

        # Per-plane numeric readout, so tuning can be judged on numbers and
        # not only on how the picture looks.
        self.plane_stats = {}
        stat_box = ttk.LabelFrame(grid, text="Measurements", padding=4)
        stat_box.grid(row=1, column=1, sticky="nsew", padx=4, pady=4)
        for i, (plane, title, _r, _c) in enumerate(layout):
            lbl = ttk.Label(stat_box, text=f"{PLANES[plane]}: --",
                            font=("TkFixedFont", 9), anchor="w")
            lbl.grid(row=i, column=0, sticky="w")
            self.plane_stats[plane] = lbl

        self.stats = ttk.Label(view, text="waiting for frames…",
                               font=("TkFixedFont", 10))
        self.stats.grid(row=1, column=0, sticky="w", pady=(6, 0))
        self.dist = ttk.Label(view, text="", font=("TkFixedFont", 10))
        self.dist.grid(row=2, column=0, sticky="w")

        rot = ttk.LabelFrame(view, text="View rotation (host-side only)", padding=6)
        rot.grid(row=3, column=0, sticky="ew", pady=(8, 0))
        for i, a in enumerate((0, 90, 180, 270)):
            ttk.Radiobutton(rot, text=f"{a}°", value=a, variable=self.rotation
                            ).grid(row=0, column=i, padx=6)
        ttk.Label(rot, foreground="#777",
                  text="90°/270° swaps the aspect to 120x160. The sensor cannot\n"
                       "rotate; only mirror/flip below reach the depth engine."
                  ).grid(row=1, column=0, columnspan=4, sticky="w", pady=(4, 0))

        # --- controls ---
        panel = ttk.Frame(main)
        panel.grid(row=0, column=1, sticky="nsew", padx=(12, 0))
        main.columnconfigure(1, weight=1)
        main.rowconfigure(0, weight=1)

        pv = ttk.LabelFrame(panel, text="Preview streaming", padding=6)
        pv.grid(row=99, column=0, sticky="ew", pady=(8, 0))
        ttk.Checkbutton(pv, text="Cam 1", variable=self.stream_cam1,
                        command=self.apply_planes).grid(row=0, column=0, sticky="w")
        ttk.Checkbutton(pv, text="Cam 2", variable=self.stream_cam2,
                        command=self.apply_planes).grid(row=0, column=1, sticky="w")
        ttk.Label(pv, foreground="#777",
                  text="The board sends ONE plane per frame to keep the UDP\n"
                       "burst small. Disabling a preview gives depth more\n"
                       "of the frame budget."
                  ).grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 0))

        tgt = ttk.LabelFrame(panel, text="Target camera", padding=6)
        tgt.grid(row=0, column=0, sticky="ew")
        ttk.Checkbutton(tgt, text="Apply to both cameras",
                        variable=self.both_cams).grid(row=0, column=0, columnspan=2, sticky="w")
        ttk.Radiobutton(tgt, text="Cam 1", value=0, variable=self.target_cam).grid(row=1, column=0, sticky="w")
        ttk.Radiobutton(tgt, text="Cam 2", value=1, variable=self.target_cam).grid(row=1, column=1, sticky="w")

        rect = ttk.LabelFrame(panel, text="Stereo rectification", padding=6)
        rect.grid(row=1, column=0, sticky="ew", pady=(8, 0))
        self._slider(rect, 0, "Row offset (x160 px)", self.row_offset, 0, 15, self.apply_rect)
        self._slider(rect, 1, "Col offset (px)",      self.col_offset, 0, 255, self.apply_rect)
        ttk.Label(rect, foreground="#777",
                  text="Compensates imperfect physical alignment of the two\n"
                       "cameras — the reference design's four buttons."
                  ).grid(row=2, column=0, columnspan=3, sticky="w", pady=(4, 0))

        orient = ttk.LabelFrame(panel, text="Sensor orientation (MVFP)", padding=6)
        orient.grid(row=2, column=0, sticky="ew", pady=(8, 0))
        ttk.Checkbutton(orient, text="Mirror (horizontal)", variable=self.mirror,
                        command=self.apply_mvfp).grid(row=0, column=0, sticky="w")
        ttk.Checkbutton(orient, text="Flip (vertical)", variable=self.vflip,
                        command=self.apply_mvfp).grid(row=0, column=1, sticky="w")
        self.mirror_warn = ttk.Label(orient, foreground="#c46", text="")
        self.mirror_warn.grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 0))

        img = ttk.LabelFrame(panel, text="Image", padding=6)
        img.grid(row=3, column=0, sticky="ew", pady=(8, 0))
        for i, (txt, var) in enumerate([("AGC (gain)", self.agc),
                                        ("AWB (white bal)", self.awb),
                                        ("AEC (exposure)", self.aec)]):
            ttk.Checkbutton(img, text=txt, variable=var,
                            command=self.apply_com8).grid(row=0, column=i, sticky="w", padx=4)
        self._slider(img, 1, "Brightness", self.brightness, 0, 255,
                     lambda *_: self.write_all(REG_BRIGHT, self.brightness.get()))
        self._slider(img, 2, "Contrast",   self.contrast,   0, 255,
                     lambda *_: self.write_all(REG_CONTRAS, self.contrast.get()))
        ttk.Checkbutton(img, text="Colour-bar test pattern", variable=self.testbar,
                        command=self.apply_testbar).grid(row=3, column=0, columnspan=3, sticky="w", pady=(4, 0))
        ttk.Label(img, foreground="#777",
                  text="Test pattern proves the whole data path without optics."
                  ).grid(row=4, column=0, columnspan=3, sticky="w")

        dist = ttk.LabelFrame(panel, text=f"Distance (baseline {BASELINE_MM:.0f} mm)", padding=6)
        dist.grid(row=4, column=0, sticky="ew", pady=(8, 0))
        ttk.Label(dist, text="Focal length (px):").grid(row=0, column=0, sticky="w")
        ttk.Entry(dist, textvariable=self.focal_px, width=9).grid(row=0, column=1, sticky="w")
        ttk.Button(dist, text="Calibrate…", command=self.calibrate).grid(row=0, column=2, padx=4)
        ttk.Label(dist, foreground="#777",
                  text="Z = focal x baseline / disparity. Focal is lens-specific\n"
                       "and must be measured; 0 disables the readout."
                  ).grid(row=1, column=0, columnspan=3, sticky="w", pady=(4, 0))

        act = ttk.Frame(panel)
        act.grid(row=5, column=0, sticky="ew", pady=(10, 0))
        ttk.Button(act, text="Resend config", command=self.resend).grid(row=0, column=0, padx=(0, 5))
        ttk.Button(act, text="Read back", command=self.readback).grid(row=0, column=1, padx=5)
        ttk.Button(act, text="Save…", command=self.save).grid(row=0, column=2, padx=5)
        ttk.Button(act, text="Load…", command=self.load).grid(row=0, column=3, padx=5)

        raw = ttk.LabelFrame(panel, text="Raw register", padding=6)
        raw.grid(row=6, column=0, sticky="ew", pady=(8, 0))
        self.raw_reg = tk.StringVar(value="0x0A")
        self.raw_val = tk.StringVar(value="0x00")
        ttk.Label(raw, text="reg").grid(row=0, column=0)
        ttk.Entry(raw, textvariable=self.raw_reg, width=7).grid(row=0, column=1)
        ttk.Label(raw, text="val").grid(row=0, column=2)
        ttk.Entry(raw, textvariable=self.raw_val, width=7).grid(row=0, column=3)
        ttk.Button(raw, text="Read",  command=self.raw_read).grid(row=0, column=4, padx=3)
        ttk.Button(raw, text="Write", command=self.raw_write).grid(row=0, column=5, padx=3)

        self.text = tk.Text(panel, width=52, height=12, wrap="word",
                            font=("TkFixedFont", 9), bg="#1b1b1b", fg="#ddd")
        self.text.grid(row=7, column=0, sticky="nsew", pady=(8, 0))
        panel.rowconfigure(7, weight=1)

    def _slider(self, parent, row, label, var, lo, hi, cb):
        ttk.Label(parent, text=label).grid(row=row, column=0, sticky="w")
        s = ttk.Scale(parent, from_=lo, to=hi, variable=var, orient="horizontal",
                      length=170, command=lambda *_: cb())
        s.grid(row=row, column=1, sticky="ew", padx=4)
        ttk.Label(parent, textvariable=var, width=4).grid(row=row, column=2)

    def log(self, s):
        self.text.insert("end", s if s.endswith("\n") else s + "\n")
        self.text.see("end")

    # ---------------- board actions ----------------
    def _try(self, fn, what):
        try:
            return fn()
        except TimeoutError:
            self.log(f"{what}: no response (is depth_stream running?)")
        except Exception as e:
            self.log(f"{what}: {type(e).__name__}: {e}")
        return None

    def write_all(self, reg, val):
        for cam in self.cams():
            r = self._try(lambda c=cam: self.ctrl.sccb_write(c, reg, val),
                          f"write 0x{reg:02X}")
            if r and r[0] != 0:
                self.log(f"cam{cam+1} reg 0x{reg:02X}: {ST_NAMES.get(r[0], r[0])}")

    def ping(self):
        """Runs on a worker thread -- reports through the log queue, never
        by touching Tk widgets (Tk is not thread-safe)."""
        try:
            _st, val = self.ctrl.status()
            self.logs.put(f"board ok — cam1_cfg={val & 1} cam2_cfg={(val >> 1) & 1}")
        except TimeoutError:
            self.logs.put("board not responding on UDP 5002 "
                          "(is depth_stream running?)")
        except Exception as e:
            self.logs.put(f"status: {type(e).__name__}: {e}")

    def apply_planes(self):
        mask = (1 if self.stream_cam1.get() else 0) | (2 if self.stream_cam2.get() else 0)
        self._try(lambda: self.ctrl.set_planes(mask), "set_planes")

    def apply_rect(self):
        self._try(lambda: self.ctrl.set_rect(self.row_offset.get(),
                                             self.col_offset.get()), "set_rect")

    def apply_mvfp(self):
        val = (0x20 if self.mirror.get() else 0) | (0x10 if self.vflip.get() else 0)
        self.write_all(REG_MVFP, val)
        # Mirroring both cameras reverses which side a match lies on, and the
        # SSD engine only ever searches one direction (org_R at col-offset).
        self.mirror_warn.config(
            text=("Mirror inverts the disparity search direction —\n"
                  "depth output will be invalid while this is on."
                  if self.mirror.get() else ""))

    def apply_com8(self):
        val = 0x80  # fast AEC
        if self.aec.get(): val |= 0x01
        if self.awb.get(): val |= 0x02
        if self.agc.get(): val |= 0x04
        val |= 0x40 | 0x20  # keep the banding/step bits the table sets
        self.write_all(REG_COM8, val)

    def apply_testbar(self):
        # COM7 bit1 enables the colour-bar generator; the rest of COM7 must
        # keep selecting YUV/VGA, so write the base value with the bit OR'd.
        self.write_all(REG_COM7, 0x02 if self.testbar.get() else 0x00)

    def resend(self):
        r = self._try(self.ctrl.resend, "resend")
        if r:
            self.log("register table resent")

    def readback(self):
        for cam in self.cams():
            for name, reg in (("PID", 0x0A), ("VER", 0x0B), ("MVFP", REG_MVFP),
                              ("COM7", REG_COM7), ("COM8", REG_COM8)):
                r = self._try(lambda c=cam, g=reg: self.ctrl.sccb_read(c, g),
                              f"read 0x{reg:02X}")
                if r:
                    st, v = r
                    self.log(f"cam{cam+1} {name:4s} = 0x{v:02X}"
                             + ("" if st == 0 else f"  [{ST_NAMES.get(st, st)}]"))

    def raw_read(self):
        try:
            reg = int(self.raw_reg.get(), 0)
        except ValueError:
            self.log("reg must be a number, e.g. 0x1E"); return
        for cam in self.cams():
            r = self._try(lambda c=cam: self.ctrl.sccb_read(c, reg), "raw read")
            if r:
                self.log(f"cam{cam+1} 0x{reg:02X} = 0x{r[1]:02X} ({ST_NAMES.get(r[0], r[0])})")

    def raw_write(self):
        try:
            reg = int(self.raw_reg.get(), 0)
            val = int(self.raw_val.get(), 0)
        except ValueError:
            self.log("reg/val must be numbers, e.g. 0x1E / 0x30"); return
        self.write_all(reg, val)
        self.log(f"wrote 0x{val:02X} -> 0x{reg:02X}")

    def calibrate(self):
        """Solve focal length from one known distance: f = Z * d / B."""
        if self.last_plane is None:
            self.log("no frame yet"); return
        arr = np.frombuffer(self.last_plane, dtype=np.uint8)
        nz = arr[arr > 0]
        if nz.size < 100:
            self.log("not enough valid disparity to calibrate"); return
        d = float(np.median(nz)) / 4.0 + 1.0   # undo dOUT = (offset-min)*4
        win = tk.Toplevel(self.root); win.title("Calibrate focal length")
        ttk.Label(win, text=f"Median disparity now: {d:.1f} px\n"
                            f"Enter the true distance to the scene:").grid(row=0, column=0, columnspan=2, padx=8, pady=6)
        mm = tk.DoubleVar(value=500.0)
        ttk.Entry(win, textvariable=mm, width=10).grid(row=1, column=0, padx=8)
        ttk.Label(win, text="mm").grid(row=1, column=1, sticky="w")

        def go():
            z = mm.get()
            if z <= 0 or d <= 0:
                self.log("invalid calibration input"); win.destroy(); return
            f = z * d / BASELINE_MM
            self.focal_px.set(round(f, 1))
            self.log(f"calibrated focal = {f:.1f} px (from Z={z:.0f} mm, d={d:.1f} px)")
            win.destroy()
        ttk.Button(win, text="Set", command=go).grid(row=2, column=0, columnspan=2, pady=8)

    # ---------------- config persistence ----------------
    def _config(self):
        return {k: getattr(self, k).get() for k in self.CONFIG_KEYS}

    def save(self):
        path = filedialog.asksaveasfilename(
            defaultextension=".json", filetypes=[("JSON", "*.json")],
            initialfile="stereo_tuning.json")
        if not path:
            return
        Path(path).write_text(json.dumps(self._config(), indent=2))
        self.log(f"saved {path}")

    def load(self):
        path = filedialog.askopenfilename(filetypes=[("JSON", "*.json")])
        if not path:
            return
        try:
            cfg = json.loads(Path(path).read_text())
        except Exception as e:
            messagebox.showerror("Load failed", str(e)); return
        for k, v in cfg.items():
            if k in self.CONFIG_KEYS:
                getattr(self, k).set(v)
        # Push every loaded value to the board, otherwise the UI would claim
        # a configuration the hardware is not actually in.
        self.apply_rect(); self.apply_mvfp(); self.apply_com8(); self.apply_testbar()
        self.write_all(REG_BRIGHT, self.brightness.get())
        self.write_all(REG_CONTRAS, self.contrast.get())
        self.log(f"loaded {path} and applied to board")

    # ---------------- rendering ----------------
    def _pump(self):
        try:
            while True:
                self.log(self.logs.get_nowait().rstrip())
        except queue.Empty:
            pass

        newest = {}
        try:
            while True:
                plane, data = self.frames.get_nowait()
                newest[plane] = data
        except queue.Empty:
            pass

        for plane, data in newest.items():
            a = np.frombuffer(data, dtype=np.uint8).reshape(H, W)
            rot = self.rotation.get()
            if rot:
                a = np.rot90(a, k=rot // 90)
            ih, iw = a.shape
            scale = max(1, min(336 // iw, 252 // ih))
            img = Image.fromarray(a).resize((iw * scale, ih * scale), Image.NEAREST)
            self._photos[plane] = ImageTk.PhotoImage(img)
            self.canvases[plane].itemconfig(self._img_ids[plane],
                                            image=self._photos[plane])

            # Numbers, not just pictures: mean/min/max tell you whether a
            # camera is over/under-exposed, and "valid %" on the depth plane
            # is the single best measure of whether matching is working.
            if plane == 0:
                valid = int((a > 0).sum())
                self.plane_stats[plane].config(
                    text=f"depth: valid {100*valid/(iw*ih):5.1f}%  "
                         f"max {int(a.max()):3d}  uniq {len(np.unique(a)):3d}")
                self._update_distance(a)
            else:
                self.plane_stats[plane].config(
                    text=f"{PLANES[plane]:5s}: mean {a.mean():5.1f}  "
                         f"min {int(a.min()):3d}  max {int(a.max()):3d}  "
                         f"uniq {len(np.unique(a)):3d}")

            if plane == 0:
                self.last_plane = data

        if newest:
            self.fps_n += len(newest)
            dt = time.time() - self.fps_t0
            if dt >= 1.0:
                self.stats.config(text=f"{self.fps_n/dt:4.1f} planes/s   "
                                       f"rotation {self.rotation.get()}deg")
                self.fps_t0, self.fps_n = time.time(), 0

        self.root.after(30, self._pump)

    def _update_distance(self, a):
        f = self.focal_px.get()
        if f <= 0:
            self.dist.config(text="distance: focal length not calibrated")
            return
        nz = a[a > 0]
        if nz.size < 50:
            self.dist.config(text="distance: not enough valid disparity")
            return
        d = float(np.median(nz)) / 4.0 + 1.0
        z = f * BASELINE_MM / d
        self.dist.config(text=f"median disparity {d:5.1f} px  ->  ~{z:7.0f} mm")

    def close(self):
        self.stop.set()
        self.root.destroy()


def main():
    root = tk.Tk()
    try:
        ttk.Style().theme_use("clam")
    except tk.TclError:
        pass
    Tuner(root)
    root.mainloop()


if __name__ == "__main__":
    main()
