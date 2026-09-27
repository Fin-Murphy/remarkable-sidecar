#!/usr/bin/env python3
"""Offline protocol test for the tablet server (stdlib only). Plays the Mac side of PROTOCOL.md.

Run the server built with EPAPER=OFF and --dump, then:
    python3 test_sender.py --host 127.0.0.1 --png server-dump.png
It sends frames, checks the dumped framebuffer pixel for pixel, then checks that a malformed RECT
makes the server drop the connection and accept a new one.

Input calibration against the real tablet (instead of the Mac app):
    python3 test_sender.py --host 10.11.99.1 --calibrate
draws five numbered crosshair targets and prints every INPUT message with the nearest target.
"""
import argparse
import socket
import struct
import sys
import time
import zlib

W, H = 1404, 1872


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        part = sock.recv(n - len(buf))
        if not part:
            raise ConnectionError("server closed the connection")
        buf += part
    return buf


def connect(host, port):
    sock = socket.create_connection((host, port), timeout=5)
    hello = recv_exact(sock, 11)
    kind, magic, version, w, h = struct.unpack("<B4sHHH", hello)
    assert (kind, magic, version, w, h) == (0x81, b"RMSC", 1, W, H), f"bad HELLO {hello!r}"
    return sock


def rect_msg(fb, x, y, w, h, hint):
    pixels = b"".join(bytes(fb[(y + r) * W + x:(y + r) * W + x + w]) for r in range(h))
    payload = zlib.compress(pixels)
    return struct.pack("<BHHHHBI", 0x01, x, y, w, h, hint, len(payload)) + payload


def read_png_gray(path):
    """Decodes an 8-bit grayscale (or RGB/RGBA, reduced to its first channel) non-interlaced PNG."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    pos, idat, ihdr = 8, b"", None
    while pos < len(data):
        n, kind = struct.unpack(">I4s", data[pos:pos + 8])
        body = data[pos + 8:pos + 8 + n]
        if kind == b"IHDR":
            ihdr = struct.unpack(">IIBBBBB", body)
        elif kind == b"IDAT":
            idat += body
        pos += 12 + n
    width, height, depth, color, _, _, interlace = ihdr
    assert depth == 8 and interlace == 0, ihdr
    bpp = {0: 1, 2: 3, 4: 2, 6: 4}[color]
    raw, stride = zlib.decompress(idat), width * bpp
    out, prev = bytearray(), bytearray(stride)
    for y in range(height):
        f, line = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b, c = prev[i], prev[i - bpp] if i >= bpp else 0
            if f == 1: line[i] = (line[i] + a) & 255
            elif f == 2: line[i] = (line[i] + b) & 255
            elif f == 3: line[i] = (line[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += line[::bpp]
        prev = line
    return width, height, bytes(out)


TARGETS = [(100, 100), (1304, 100), (702, 936), (100, 1772), (1304, 1772)]
KINDS = ["hover_move", "pen_down", "pen_move", "pen_up", "touch_tap", "touch_long_press"]


def calibrate(host, port):
    fb = bytearray(b"\xff" * (W * H))
    for tx, ty in TARGETS:  # 81 px crosshair, 3 px thick, plus a 20 px box
        for d in range(-40, 41):
            for t in (-1, 0, 1):
                fb[(ty + t) * W + tx + d] = 0
                fb[(ty + d) * W + tx + t] = 0
        for d in range(-10, 11):
            for e in (-10, 10):
                fb[(ty + e) * W + tx + d] = 0
                fb[(ty + d) * W + tx + e] = 0
    sock = connect(host, port)
    sock.sendall(rect_msg(fb, 0, 0, W, H, 1) + b"\x03")
    sock.settimeout(None)
    print("targets:", ", ".join(f"#{i + 1} {t}" for i, t in enumerate(TARGETS)), "- Ctrl-C to stop")
    last = None
    while True:
        kind, k, x, y, p = struct.unpack("<BBHHH", recv_exact(sock, 8))
        assert kind == 0x90, f"unexpected message 0x{kind:02x}"
        if k == 0 and last == 0:
            continue  # don't flood the terminal with hover moves
        n, (tx, ty) = min(enumerate(TARGETS), key=lambda t: (t[1][0] - x) ** 2 + (t[1][1] - y) ** 2)
        print(f"{KINDS[k]:17} x={x:4} y={y:4} pressure={p:4}   nearest #{n + 1} off by ({x - tx:+d}, {y - ty:+d})")
        last = k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=9876)
    ap.add_argument("--png", help="the server's --dump file, as seen from here")
    ap.add_argument("--calibrate", action="store_true", help="show targets and print INPUT messages")
    args = ap.parse_args()
    if args.calibrate:
        try:
            calibrate(args.host, args.port)
        except KeyboardInterrupt:
            pass
        return 0
    if not args.png:
        ap.error("--png is required unless --calibrate")

    fb = bytearray((x // 6 + y // 9) & 255 for y in range(H) for x in range(W))
    sock = connect(args.host, args.port)
    print("HELLO ok")

    # 1. Full frame (as the Mac sends after HELLO).
    sock.sendall(rect_msg(fb, 0, 0, W, H, 1) + b"\x03")
    # 2. Several rects in one frame, including clipped right/bottom edges.
    changes = [(1344, 64, 60, 128, 0), (448, 576, 128, 128, 0), (0, 1792, 320, 80, 0)]
    for x, y, w, h, hint in changes:
        for r in range(h):
            fb[(y + r) * W + x:(y + r) * W + x + w] = bytes([(r * 7 + hint * 40) & 255]) * w
    sock.sendall(b"".join(rect_msg(fb, *c) for c in changes) + b"\x03")
    # 3. A full refresh, then a last small frame.
    sock.sendall(b"\x02")
    fb[100 * W + 100:100 * W + 164] = b"\x00" * 64
    sock.sendall(rect_msg(fb, 64, 64, 128, 64, 1) + b"\x03")
    time.sleep(1.5)

    width, height, got = read_png_gray(args.png)
    assert (width, height) == (W, H), (width, height)
    bad = sum(1 for a, b in zip(got, fb) if a != b)
    print(f"framebuffer check: {bad} of {W * H} pixels differ")

    # 4. A malformed RECT (outside the screen) must make the server drop us...
    sock.sendall(struct.pack("<BHHHHBI", 0x01, 1400, 0, 64, 64, 0, 0))
    try:
        dropped = sock.recv(1) == b""
    except (ConnectionError, socket.timeout):
        dropped = True
    print(f"bad RECT drops connection: {dropped}")
    sock.close()
    # ... and accept the next connection.
    connect(args.host, args.port).close()
    print("reconnect after drop: ok")
    return 0 if bad == 0 and dropped else 1


if __name__ == "__main__":
    sys.exit(main())
