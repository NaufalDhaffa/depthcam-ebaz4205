#!/usr/bin/env python3
"""Receive the EBAZ4205 stereo depth stream and display / save it.

Wire format (see docs/BOARD_CONFIG.md and sw/apps/depth_stream/src/depth_stream.h):
each UDP datagram is a 4-byte little-endian header {frame_id:u16,
chunk_index:u16} followed by up to 1400 disparity bytes. chunk_index is the
pixel offset within the frame where this datagram's payload starts.

A frame is emitted once every chunk of it has arrived. Chunks whose frame_id
doesn't match the frame being assembled start a new frame -- a frame missing
any chunk is dropped rather than shown half-stale, since UDP gives no
ordering or delivery guarantee.

Usage:
    ./depth_receiver.py                 # live view (needs matplotlib)
    ./depth_receiver.py --save out_dir  # write each frame as a PGM instead
    ./depth_receiver.py --stats         # just print frame/loss statistics
"""
import argparse
import socket
import struct
import sys
import time
from pathlib import Path

WIDTH, HEIGHT = 160, 120
PIXELS = WIDTH * HEIGHT
HDR = struct.Struct("<HH")  # little-endian: ARM writes these natively
LISTEN_PORT = 5001


def frames(sock):
    """Yield (frame_id, bytearray) for each fully received frame."""
    cur_id = None
    buf = bytearray(PIXELS)
    have = 0
    while True:
        pkt, _ = sock.recvfrom(2048)
        if len(pkt) < HDR.size:
            continue
        frame_id, chunk_index = HDR.unpack_from(pkt, 0)
        payload = pkt[HDR.size:]
        if chunk_index + len(payload) > PIXELS:
            continue  # malformed / not ours
        if frame_id != cur_id:
            # New frame: whatever was partially assembled is discarded.
            cur_id, have = frame_id, 0
            buf = bytearray(PIXELS)
        buf[chunk_index:chunk_index + len(payload)] = payload
        have += len(payload)
        if have >= PIXELS:
            yield frame_id, bytes(buf)
            cur_id = None


def write_pgm(path, data):
    with open(path, "wb") as f:
        f.write(b"P5\n%d %d\n255\n" % (WIDTH, HEIGHT))
        f.write(data)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=LISTEN_PORT)
    ap.add_argument("--save", metavar="DIR",
                    help="write frames as PGM files instead of displaying")
    ap.add_argument("--stats", action="store_true",
                    help="print frame rate and dropped-frame count only")
    args = ap.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", args.port))
    print(f"listening on UDP :{args.port} for {WIDTH}x{HEIGHT} depth frames",
          file=sys.stderr)

    stream = frames(sock)

    if args.save:
        outdir = Path(args.save)
        outdir.mkdir(parents=True, exist_ok=True)
        for n, (frame_id, data) in enumerate(stream):
            write_pgm(outdir / f"depth_{n:05d}.pgm", data)
            print(f"frame {n} (id={frame_id}) -> {outdir}", file=sys.stderr)
        return

    if args.stats:
        last, count, prev_id = time.time(), 0, None
        dropped = 0
        for frame_id, _ in stream:
            count += 1
            if prev_id is not None:
                gap = (frame_id - prev_id) & 0xFFFF
                if gap > 1:
                    dropped += gap - 1
            prev_id = frame_id
            now = time.time()
            if now - last >= 1.0:
                print(f"{count} fps, {dropped} frames dropped so far")
                count, last = 0, now
        return

    try:
        import matplotlib.pyplot as plt
        import numpy as np
    except ImportError:
        sys.exit("matplotlib and numpy are needed for live view; "
                 "use --save or --stats instead")

    fig, ax = plt.subplots()
    img = ax.imshow(np.zeros((HEIGHT, WIDTH), dtype=np.uint8),
                    cmap="inferno", vmin=0, vmax=255)
    ax.set_title("EBAZ4205 stereo disparity")
    fig.colorbar(img, ax=ax, label="disparity (scaled)")
    plt.ion()
    plt.show()

    for frame_id, data in stream:
        img.set_data(np.frombuffer(data, dtype=np.uint8).reshape(HEIGHT, WIDTH))
        ax.set_xlabel(f"frame id {frame_id}")
        fig.canvas.draw_idle()
        fig.canvas.flush_events()
        if not plt.fignum_exists(fig.number):
            break


if __name__ == "__main__":
    main()
