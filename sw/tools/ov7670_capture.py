#!/usr/bin/env python3
"""Talk to the STM32F446RE OV7670 tester over the ST-LINK virtual COM port.

The firmware (sw/stm32_camtest) is line-oriented text except for the frame
payload, which is framed between a "FRAME <w>x<h> <bytes> YUV422" header line
and an "ENDFRAME" trailer.

Usage:
    ./ov7670_capture.py probe          # SCCB identity registers
    ./ov7670_capture.py activity       # PCLK/HREF/VSYNC edge counts
    ./ov7670_capture.py regdump
    ./ov7670_capture.py capture -o out.png
"""
import argparse
import re
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial required: pip install pyserial (or use the project venv)")

PORT_DEFAULT = "/dev/ttyACM0"
BAUD = 921600

FRAME_RE  = re.compile(rb"FRAME (\d+)x(\d+) (\d+) YUV422")
YFRAME_RE = re.compile(rb"YFRAME (\d+)x(\d+) (\d+)")


def drain(ser, seconds=0.4):
    """Consume and return whatever is already queued."""
    end = time.time() + seconds
    buf = b""
    while time.time() < end:
        buf += ser.read(4096)
    return buf


def run_text_command(ser, cmd, settle=2.5):
    drain(ser, 0.3)
    ser.write(cmd.encode())
    time.sleep(settle)
    return drain(ser, 0.5).decode(errors="replace")


def capture(ser, timeout=25.0):
    """Send 'c' and return (width, height, payload bytes)."""
    drain(ser, 0.3)
    ser.write(b"c")

    buf = b""
    deadline = time.time() + timeout
    header = None
    while time.time() < deadline:
        chunk = ser.read(8192)
        if chunk:
            buf += chunk
        m = FRAME_RE.search(buf)
        if m:
            header = m
            break
    if not header:
        raise RuntimeError("no FRAME header received:\n"
                           + buf.decode(errors="replace")[-800:])

    w, h, nbytes = (int(header.group(i)) for i in (1, 2, 3))

    # Payload starts right after the header line's CRLF.
    start = buf.find(b"\r\n", header.end())
    if start < 0:
        raise RuntimeError("malformed frame header")
    start += 2

    while len(buf) - start < nbytes and time.time() < deadline:
        chunk = ser.read(8192)
        if chunk:
            buf += chunk
    payload = buf[start:start + nbytes]
    if len(payload) < nbytes:
        raise RuntimeError(f"short frame: got {len(payload)} of {nbytes} bytes")
    return w, h, payload


def yuv422_to_luma(payload, w, h, phase):
    """Extract the Y plane. OV7670 YUV422 interleaves luma with chroma; which
    byte of each pair is Y depends on the TSLB/COM13 ordering, so the phase is
    selectable and chosen by score() below rather than assumed."""
    return bytes(payload[phase::2][:w * h])


def score(plane, w, h):
    """Higher = more likely to be the real luma plane. Chroma-as-luma looks
    flatter and, crucially, far noisier column-to-column; real luma has
    strong neighbour correlation."""
    if len(plane) < w * h:
        return -1e9
    diffs = 0
    for row in range(0, h, 4):                 # sample rows, this is a heuristic
        base = row * w
        line = plane[base:base + w]
        diffs += sum(abs(line[i + 1] - line[i]) for i in range(len(line) - 1))
    spread = max(plane) - min(plane)
    return spread * 4 - diffs / max(1, h // 4) / max(1, w) * 32


def save_png(path, plane, w, h):
    try:
        from PIL import Image
    except ImportError:
        pgm = path.rsplit(".", 1)[0] + ".pgm"
        with open(pgm, "wb") as f:
            f.write(b"P5\n%d %d\n255\n" % (w, h))
            f.write(plane)
        return pgm
    Image.frombytes("L", (w, h), plane).save(path)
    return path


def stream_frames(ser):
    """Generator over luma-only frames produced by the firmware's 's' mode.

    Resynchronises on every YFRAME header rather than assuming the stream
    stays aligned: a dropped byte on the wire would otherwise shear every
    subsequent frame permanently."""
    ser.write(b"s")
    buf = b""
    while True:
        chunk = ser.read(8192)
        if chunk:
            buf += chunk
        m = YFRAME_RE.search(buf)
        if not m:
            if len(buf) > 1 << 20:
                buf = buf[-4096:]      # nothing parseable; don't grow forever
            continue
        start = buf.find(b"\r\n", m.end())
        if start < 0:
            continue
        start += 2
        n = int(m.group(3))
        while len(buf) - start < n:
            chunk = ser.read(8192)
            if chunk:
                buf += chunk
        yield int(m.group(1)), int(m.group(2)), buf[start:start + n]
        buf = buf[start + n:]


def do_stream(ser, save_dir=None):
    import time as _t
    try:
        import numpy as np
        import matplotlib.pyplot as plt
    except ImportError:
        plt = None

    gen = stream_frames(ser)
    w, h, first = next(gen)
    print(f"streaming {w}x{h} luma", file=sys.stderr)

    if plt is None:
        # Headless fallback: keep writing the newest frame to disk.
        n = 0
        for w, h, plane in gen:
            save_png(save_dir or "ov7670_live.png", plane, w, h)
            n += 1
            print(f"\rframes: {n}", end="", file=sys.stderr)
        return

    fig, ax = plt.subplots()
    im = ax.imshow(np.frombuffer(first, dtype=np.uint8).reshape(h, w),
                   cmap="gray", vmin=0, vmax=255)
    ax.set_title("OV7670 live (close window to stop)")
    ax.axis("off")
    plt.ion(); plt.show()

    t0, count = _t.time(), 0
    for w, h, plane in gen:
        im.set_data(np.frombuffer(plane, dtype=np.uint8).reshape(h, w))
        count += 1
        dt = _t.time() - t0
        if dt >= 1.0:
            ax.set_xlabel(f"{count/dt:.1f} fps")
            t0, count = _t.time(), 0
        fig.canvas.draw_idle(); fig.canvas.flush_events()
        if not plt.fignum_exists(fig.number):
            break
    ser.write(b"x")   # any byte stops the firmware's stream loop


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("command",
                    choices=["probe", "activity", "regdump", "capture", "stream"])
    ap.add_argument("--port", default=PORT_DEFAULT)
    ap.add_argument("-o", "--output", default="ov7670_frame.png")
    ap.add_argument("--phase", type=int, choices=[0, 1],
                    help="force the luma byte phase instead of auto-detecting")
    args = ap.parse_args()

    with serial.Serial(args.port, BAUD, timeout=0.2) as ser:
        time.sleep(0.3)

        if args.command == "stream":
            do_stream(ser, args.output)
            return

        if args.command in ("probe", "activity", "regdump"):
            letter = {"probe": "p", "activity": "a", "regdump": "r"}[args.command]
            settle = 6.0 if args.command == "regdump" else 2.5
            print(run_text_command(ser, letter, settle))
            return

        w, h, payload = capture(ser)
        print(f"received {len(payload)} bytes for {w}x{h}", file=sys.stderr)

        if args.phase is not None:
            phase = args.phase
        else:
            cands = [(score(yuv422_to_luma(payload, w, h, p), w, h), p)
                     for p in (0, 1)]
            cands.sort(reverse=True)
            phase = cands[0][1]
            print(f"auto-selected luma phase {phase} "
                  f"(scores: {[(p, round(s)) for s, p in cands]})", file=sys.stderr)

        plane = yuv422_to_luma(payload, w, h, phase)
        out = save_png(args.output, plane, w, h)
        nz = sum(1 for b in plane if b)
        print(f"wrote {out}  min={min(plane)} max={max(plane)} "
              f"nonzero={nz}/{len(plane)}", file=sys.stderr)


if __name__ == "__main__":
    main()
