#!/usr/bin/env python3
"""
Software render of the analog_clock_gen.v hardware clock.

Uses the same face geometry, hand lengths / widths / tails, hour-mark positions
and colours as the Verilog, so the PNG matches what the FPGA actually drives to
the screen - hard edges, no anti-aliasing, just like the real output.

Emits docs/clock_1080p.png (the default 10:08:00 face) and docs/clock_faces.png
(a montage at a few different times, to show the hands move).
"""
import struct, zlib, math, os

W_full, H_full = 1920, 1080
CX, CY = 960, 540

RING_IN,  RING_OUT = 400, 416
CENTER_R2 = 12 * 12
TICK_R, TICK_HS = 370, 8

# hands: (length, tail, half-width)
SEC = (370, 50, 3)
MIN = (330, 12, 7)
HR  = (230, 12, 10)

# colours as ready-made 3-byte pixels (matches the COL_* localparams)
COL_BG   = bytes((0x10, 0x10, 0x18))
COL_FACE = bytes((0x1E, 0x1E, 0x28))
COL_RING = bytes((0xE8, 0xE8, 0xF0))
COL_TICK = bytes((0xB0, 0xB0, 0xC0))
COL_HR   = bytes((0xF0, 0xF0, 0xF8))
COL_MIN  = bytes((0xD8, 0xD8, 0xE0))
COL_SEC  = bytes((0xFF, 0x30, 0x20))
COL_DOT  = bytes((0xFF, 0x30, 0x20))

RING_IN2, RING_OUT2 = RING_IN * RING_IN, RING_OUT * RING_OUT
TB_LO, TB_HI = (TICK_R - 16) ** 2, (TICK_R + 16) ** 2   # radial gate for ticks

# hour marks at radius 370, every 30 deg: (round(370*sin), round(-370*cos))
TICKS = [(round(TICK_R * math.sin(math.radians(k * 30))),
          round(-TICK_R * math.cos(math.radians(k * 30)))) for k in range(12)]

def hand_uv(idx):            # idx 0..59 -> unit vector, screen coords (y down)
    a = math.radians(idx * 6)
    return math.sin(a), -math.cos(a)

def indices(h, m, s):        # same mapping as the hardware time base
    return s % 60, m % 60, (h % 12) * 5 + (m // 12)

def shade(dx, dy, uv):
    """Priority mux: centre > second > minute > hour > tick > ring > face > bg."""
    r2 = dx * dx + dy * dy
    if r2 <= CENTER_R2:
        return COL_DOT
    sx, sy, mx, my, hx, hy = uv
    p = dx * sx + dy * sy; q = dx * sy - dy * sx
    if -SEC[1] <= p <= SEC[0] and -SEC[2] <= q <= SEC[2]: return COL_SEC
    p = dx * mx + dy * my; q = dx * my - dy * mx
    if -MIN[1] <= p <= MIN[0] and -MIN[2] <= q <= MIN[2]: return COL_MIN
    p = dx * hx + dy * hy; q = dx * hy - dy * hx
    if -HR[1] <= p <= HR[0] and -HR[2] <= q <= HR[2]: return COL_HR
    if TB_LO <= r2 <= TB_HI:
        for tx, ty in TICKS:
            if -TICK_HS <= dx - tx <= TICK_HS and -TICK_HS <= dy - ty <= TICK_HS:
                return COL_TICK
    if RING_IN2 <= r2 <= RING_OUT2: return COL_RING
    if r2 < RING_IN2: return COL_FACE
    return COL_BG

def write_png(path, W, H, rows):
    def ch(t, d):
        c = t + d; return struct.pack(">I", len(d)) + c + struct.pack(">I", zlib.crc32(c))
    raw = b"".join(b"\x00" + r for r in rows)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n"
        + ch(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
        + ch(b"IDAT", zlib.compress(raw, 9)) + ch(b"IEND", b""))

def render(h, m, s, path):
    uv = sum((hand_uv(i) for i in indices(h, m, s)), ())
    rows = []
    for yy in range(H_full):
        dy = yy - CY; row = bytearray()
        for xx in range(W_full):
            row += shade(xx - CX, dy, uv)
        rows.append(bytes(row))
    write_png(path, W_full, H_full, rows); print("wrote", path, f"{W_full}x{H_full} @ {h:02d}:{m:02d}:{s:02d}")

def render_montage(times, TILE, path):
    n = len(times); big = [bytearray(TILE * n * 3) for _ in range(TILE)]
    half = 540; scale = (2 * half) / TILE          # sample the central 1080x1080
    for idx, (h, m, s) in enumerate(times):
        uv = sum((hand_uv(i) for i in indices(h, m, s)), ()); ox = idx * TILE
        for yy in range(TILE):
            dy = int(yy * scale) - half
            for xx in range(TILE):
                dx = int(xx * scale) - half
                big[yy][(ox + xx) * 3:(ox + xx) * 3 + 3] = shade(dx, dy, uv)
    write_png(path, TILE * n, TILE, [bytes(r) for r in big]); print("wrote", path)

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    docs = os.path.join(here, "..", "docs"); os.makedirs(docs, exist_ok=True)
    render(10, 8, 0, os.path.join(docs, "clock_1080p.png"))
    render_montage([(10, 8, 0), (2, 50, 25), (6, 15, 40), (9, 35, 10)], 300,
                   os.path.join(docs, "clock_faces.png"))
