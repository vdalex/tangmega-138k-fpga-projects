#!/usr/bin/env python3
"""
Bit-exact software model of the FPGA Mandelbrot generator
(mandelbrot_gen.v) plus its "teal & orange" palette.

  * reproduces the exact Q4.14 fixed-point escape-time iteration used in
    hardware, so a render here matches what the board outputs;
  * renders preview PNGs (docs/);
  * emits the Verilog palette LUT that mandelbrot_gen.v embeds.

Usage:
    python mandelbrot_model.py           # render previews + print LUT
"""

import struct, zlib, os

# ---- fixed-point config (must match mandelbrot_gen.v) ----
FRAC   = 14
SCALE  = 1 << FRAC
ESCAPE = 1 << (2*FRAC + 2)          # 4.0 in Q8.28  == 2^30
N      = 14                          # iterations == hardware pipeline stages

# ---- view window: cr in [-2.5, +1.0], square pixels ----
W_full, H_full = 1920, 1080
CR_STEP = 30
CI_STEP = 30
CR_MIN  = -int(2.5 * SCALE)                 # -40960
CI_MIN  = -(CI_STEP * H_full) // 2          # centred vertically

def s18(v):
    v &= (1 << 18) - 1
    return v - (1 << 18) if v & (1 << 17) else v

def mandel_iter(cr, ci):
    """Return escape count 0..N (N == did not escape / in-set)."""
    zr = zi = cnt = 0
    esc = False
    for _ in range(N):
        zr2 = zr*zr
        zi2 = zi*zi
        mag = zr2 + zi2
        if not esc:
            if mag >= ESCAPE:                # hardware: any bit [35:30] set
                esc = True
            else:
                cnt += 1
                zr, zi = s18(((zr2 - zi2) >> FRAC) + cr), s18((zr*zi >> (FRAC-1)) + ci)
    return cnt

# ---- palette: "teal & orange" vortex look, sampled from the reference ----
# control points (position 0..1 across the escaping bands) -> RGB
_CTRL = [
    (0.00, (  6,  22,  38)),   # deep navy-teal (far outside)
    (0.16, ( 16,  86, 108)),   # dark teal
    (0.33, ( 34, 168, 182)),   # teal
    (0.50, ( 96, 226, 230)),   # turquoise
    (0.64, (176, 248, 244)),   # light cyan
    (0.76, (250, 250, 240)),   # cream highlight
    (0.86, (243, 156, 108)),   # salmon
    (0.94, (208,  96,  22)),   # orange
    (1.00, (120,  40,  28)),   # rust (near the set)
]

def _lerp(a, b, t):
    return tuple(round(a[k] + (b[k]-a[k])*t) for k in range(3))

def palette(cnt):
    if cnt >= N:
        return (0, 0, 0)                     # in-set -> black
    t = cnt / (N - 1) if N > 1 else 0.0
    for i in range(len(_CTRL)-1):
        p0, c0 = _CTRL[i]
        p1, c1 = _CTRL[i+1]
        if t <= p1:
            return _lerp(c0, c1, (t-p0)/(p1-p0) if p1 > p0 else 0.0)
    return _CTRL[-1][1]

# ---- PNG writer (no external deps) ----
def write_png(path, W, H, rows):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c))
    raw = b"".join(b"\x00" + r for r in rows)
    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 2, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(raw, 9))
           + chunk(b"IEND", b""))
    open(path, "wb").write(png)

def render(W, H, path):
    sx = W_full / W; sy = H_full / H
    rows = []
    for yy in range(H):
        ci = CI_MIN + int(yy*sy)*CI_STEP
        row = bytearray()
        for xx in range(W):
            cr = CR_MIN + int(xx*sx)*CR_STEP
            row += bytes(palette(mandel_iter(cr, ci)))
        rows.append(bytes(row))
    write_png(path, W, H, rows)
    print("wrote", path, f"{W}x{H}")

def emit_verilog_lut():
    lines = ["\tfunction [23 : 0] palette(input [6 : 0] cnt);", "\t\tcase(cnt)"]
    for c in range(N+1):
        r, g, b = palette(c)
        lines.append(f"\t\t\t7'd{c}: palette = 24'h{r:02X}{g:02X}{b:02X};")
    lines += ["\t\t\tdefault: palette = 24'h000000;", "\t\tendcase", "\tendfunction"]
    return "\n".join(lines)

if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    docs = os.path.join(here, "..", "docs")
    os.makedirs(docs, exist_ok=True)
    render(960, 540, os.path.join(docs, "mandelbrot_preview.png"))
    open(os.path.join(here, "palette_lut.vh"), "w").write(emit_verilog_lut()+"\n")
    print("\n--- Verilog palette LUT (also written to tools/palette_lut.vh) ---")
    print(emit_verilog_lut())
