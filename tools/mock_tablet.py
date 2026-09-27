#!/usr/bin/env python3
"""Mock reMarkable 2 for rM2 Sidecar (see ../docs/PROTOCOL.md). Python stdlib only.

Listens for the Mac, sends HELLO, decodes RECTs into a framebuffer, saves it as a PNG
whenever it changed (at most once a second), and logs traffic every 2 s.
With --script-input it also sends a scripted set of INPUT events after connecting.
"""
import argparse
import os
import socket
import struct
import threading
import time
import zlib

W, H = 1404, 1872


def write_png(path, width, height, gray):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    raw = b"".join(b"\x00" + gray[y * width:(y + 1) * width] for y in range(height))
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))  # 8-bit grayscale
           + chunk(b"IDAT", zlib.compress(raw, 6))
           + chunk(b"IEND", b""))
    with open(path + ".tmp", "wb") as f:
        f.write(png)
    os.replace(path + ".tmp", path)


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        part = sock.recv(n - len(buf))
        if not part:
            raise ConnectionError("Mac closed the connection")
        buf += part
    return bytes(buf)


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.reset()
        self.total_bytes = 0

    def reset(self):
        self.bytes = self.rects = self.frames = self.refreshes = 0
        self.fast = self.quality = 0


def script_input(sock, log):
    """Hover a square, drag the same square with the pen down, tap, long-press, tap to dismiss."""
    def send(kind, x, y, pressure=0):
        sock.sendall(struct.pack("<BBHHH", 0x90, kind, x, y, pressure))

    def path(points, kind, pressure=0):
        for (x0, y0), (x1, y1) in zip(points, points[1:]):
            for i in range(20):
                send(kind, x0 + (x1 - x0) * i // 20, y0 + (y1 - y0) * i // 20, pressure)
                time.sleep(0.02)

    square = [(400, 400), (1000, 400), (1000, 1000), (400, 1000), (400, 400)]
    try:
        time.sleep(3)
        log("script: hover around square (400,400)-(1000,1000)")
        path(square, 0)
        time.sleep(1)
        log("script: pen_down at (400,400), drag square, pen_up")
        send(1, 400, 400, 2000)
        path([(400, 400), (1000, 1000)], 2, 2000)  # diagonal drag, e.g. a selection marquee
        send(3, 1000, 1000)
        time.sleep(1)
        log("script: touch_tap at (702,936)")
        send(4, 702, 936)
        time.sleep(1)
        log("script: touch_long_press at (702,936) (right click)")
        send(5, 702, 936)
        time.sleep(2)
        log("script: touch_tap at (200,1700) to dismiss any menu")
        send(4, 200, 1700)
        log("script: done")
    except OSError as e:
        log(f"script: stopped ({e})")


def serve(conn, args, log):
    fb = bytearray(b"\xff" * (W * H))
    stats = Stats()
    dirty = [False]
    stop = threading.Event()

    def reporter():
        last_png = last_report = time.time()
        while not stop.wait(0.5):
            now = time.time()
            with stats.lock:
                if now - last_png >= 1 and dirty[0]:
                    write_png(args.png, W, H, bytes(fb))
                    dirty[0] = False
                    last_png = now
                    log(f"saved {args.png}")
                if now - last_report >= 2:
                    last_report = now
                    log(f"last 2s: {stats.bytes} B, {stats.frames} frames, {stats.rects} rects "
                        f"(fast {stats.fast}, quality {stats.quality}), {stats.refreshes} full refreshes; "
                        f"total {stats.total_bytes} B")
                    stats.reset()

    conn.sendall(struct.pack("<B4sHHH", 0x81, b"RMSC", 1, W, H))
    log("sent HELLO")
    threading.Thread(target=reporter, daemon=True).start()
    if args.script_input:
        threading.Thread(target=script_input, args=(conn, log), daemon=True).start()

    try:
        while True:
            kind = recv_exact(conn, 1)[0]
            if kind == 0x01:
                header = recv_exact(conn, 13)
                x, y, w, h, hint, n = struct.unpack("<HHHHBI", header)
                pixels = zlib.decompress(recv_exact(conn, n))
                if len(pixels) != w * h or x + w > W or y + h > H:
                    raise ValueError(f"bad RECT x={x} y={y} w={w} h={h} len={len(pixels)}")
                with stats.lock:
                    for row in range(h):
                        fb[(y + row) * W + x:(y + row) * W + x + w] = pixels[row * w:(row + 1) * w]
                    dirty[0] = True
                    stats.rects += 1
                    stats.fast += hint == 0
                    stats.quality += hint == 1
                    stats.bytes += 14 + n
                    stats.total_bytes += 14 + n
                if args.verbose:
                    log(f"RECT {x},{y} {w}x{h} hint={hint} {n} B")
            elif kind == 0x02:
                with stats.lock:
                    stats.refreshes += 1
                    stats.bytes += 1
                    stats.total_bytes += 1
                log("FULL_REFRESH")
            elif kind == 0x03:
                with stats.lock:
                    stats.frames += 1
                    stats.bytes += 1
                    stats.total_bytes += 1
            else:
                raise ValueError(f"unknown message type 0x{kind:02x}")
    finally:
        stop.set()
        if dirty[0]:
            write_png(args.png, W, H, bytes(fb))


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=9876)
    p.add_argument("--png", default="mock_frame.png", help="where to save the framebuffer")
    p.add_argument("--script-input", action="store_true", help="send scripted INPUT events after connecting")
    p.add_argument("--verbose", action="store_true", help="log every RECT")
    args = p.parse_args()

    def log(msg):
        print(time.strftime("[%H:%M:%S] ") + msg, flush=True)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)
    log(f"listening on {args.host}:{args.port}")
    while True:
        conn, addr = server.accept()
        log(f"Mac connected from {addr[0]}:{addr[1]}")
        try:
            serve(conn, args, log)
        except (ConnectionError, ValueError, zlib.error) as e:
            log(f"connection ended: {e}")
        finally:
            conn.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
