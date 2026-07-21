#!/usr/bin/env python3
"""
Bit-exact software model of the animated Julia-set generator (julia_gen.v).

The escape-time iteration is the same z <- z^2 + c as Mandelbrot, but:
  * z0 = the pixel's complex coordinate (not 0);
  * c  = a constant that walks a circle  c = R * (cos t, sin t),
    advanced a little each frame -> the fractal morphs continuously.

This script renders preview frames (docs/) and emits the two Verilog LUTs
that julia_gen.v embeds (the c-circle and the palette), so the rendered
frames match what the board outputs.
"""
import struct, zlib, math, os

# ---- fixed point (must match julia_gen.v) ----
FRAC   = 14
SCALE  = 1 << FRAC
ESCAPE = 1 << (2*FRAC + 2)          # 4.0 in Q8.28
N      = 14                          # iterations == hardware pipeline stages

# ---- view: centred on origin, square pixels ----
W_full, H_full = 1920, 1080
ZR_STEP = 27
ZI_STEP = 27
ZR_MIN  = -(ZR_STEP * W_full) // 2
ZI_MIN  = -(ZI_STEP * H_full) // 2

# ---- animated parameter c = R*(cos,sin) around a 256-step circle ----
ANG = 256
R   = 0.7885

def c_at(theta):
    a = 2*math.pi*theta/ANG
    return (round(R*math.cos(a)*SCALE), round(R*math.sin(a)*SCALE))

def s18(v):
    v &= (1 << 18) - 1
    return v - (1 << 18) if v & (1 << 17) else v

def julia(zr, zi, cr, ci):
    cnt = 0; esc = False
    for _ in range(N):
        zr2 = zr*zr; zi2 = zi*zi; mag = zr2 + zi2
        if not esc:
            if mag >= ESCAPE:
                esc = True
            else:
                cnt += 1
                zr, zi = s18(((zr2 - zi2) >> FRAC) + cr), s18((zr*zi >> (FRAC-1)) + ci)
    return cnt

# ---- palette: same "teal & orange" as the Mandelbrot project ----
_CTRL = [(0.00,(6,22,38)),(0.16,(16,86,108)),(0.33,(34,168,182)),(0.50,(96,226,230)),
         (0.64,(176,248,244)),(0.76,(250,250,240)),(0.86,(243,156,108)),(0.94,(208,96,22)),(1.00,(120,40,28))]
def _lerp(a,b,t): return tuple(round(a[k]+(b[k]-a[k])*t) for k in range(3))
def palette(cnt):
    if cnt >= N: return (0,0,0)
    t = cnt/(N-1)
    for i in range(len(_CTRL)-1):
        p0,c0 = _CTRL[i]; p1,c1 = _CTRL[i+1]
        if t <= p1: return _lerp(c0,c1,(t-p0)/(p1-p0) if p1>p0 else 0)
    return _CTRL[-1][1]

# ---- PNG ----
def write_png(path, W, H, rows):
    def ch(tag,d):
        c=tag+d; return struct.pack(">I",len(d))+c+struct.pack(">I",zlib.crc32(c))
    raw=b"".join(b"\x00"+r for r in rows)
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",W,H,8,2,0,0,0))
                          +ch(b"IDAT",zlib.compress(raw,9))+ch(b"IEND",b""))

def render(theta, W, H, path):
    cr, ci = c_at(theta)
    sx = W_full/W; sy = H_full/H
    rows=[]
    for yy in range(H):
        zi0 = ZI_MIN + int(yy*sy)*ZI_STEP
        row=bytearray()
        for xx in range(W):
            zr0 = ZR_MIN + int(xx*sx)*ZR_STEP
            row += bytes(palette(julia(zr0, zi0, cr, ci)))
        rows.append(bytes(row))
    write_png(path, W, H, rows)
    print("wrote", path, f"{W}x{H} theta={theta}")

def render_montage(thetas, TW, TH, path):
    big=[bytearray(TW*len(thetas)*3) for _ in range(TH)]
    sx=W_full/TW; sy=H_full/TH
    for idx,theta in enumerate(thetas):
        cr,ci=c_at(theta); ox=idx*TW
        for yy in range(TH):
            zi0=ZI_MIN+int(yy*sy)*ZI_STEP
            for xx in range(TW):
                zr0=ZR_MIN+int(xx*sx)*ZR_STEP
                r,g,b=palette(julia(zr0,zi0,cr,ci))
                big[yy][(ox+xx)*3:(ox+xx)*3+3]=bytes((r,g,b))
    write_png(path, TW*len(thetas), TH, [bytes(r) for r in big])
    print("wrote", path)

def emit_c_lut():
    L=["\t// c = 0.7885*(cos,sin) around a 256-step circle, Q4.14 (generated)",
       "\tfunction [35 : 0] c_lut(input [7 : 0] theta);  // {c_re[17:0], c_im[17:0]}",
       "\t\tcase(theta)"]
    for th in range(ANG):
        cr,ci=c_at(th)
        L.append(f"\t\t\t8'd{th}: c_lut = {{18'sd{cr} & 18'h3FFFF, 18'sd{ci} & 18'h3FFFF}};"
                 if False else
                 f"\t\t\t8'd{th}: c_lut = {{18'h{cr & 0x3FFFF:05X}, 18'h{ci & 0x3FFFF:05X}}};")
    L += ["\t\t\tdefault: c_lut = 36'h0;","\t\tendcase","\tendfunction"]
    return "\n".join(L)

def emit_palette_lut():
    L=["\tfunction [23 : 0] palette(input [6 : 0] cnt);","\t\tcase(cnt)"]
    for c in range(N+1):
        r,g,b=palette(c); L.append(f"\t\t\t7'd{c}: palette = 24'h{r:02X}{g:02X}{b:02X};")
    L += ["\t\t\tdefault: palette = 24'h000000;","\t\tendcase","\tendfunction"]
    return "\n".join(L)

if __name__ == "__main__":
    here=os.path.dirname(os.path.abspath(__file__))
    docs=os.path.join(here,"..","docs"); os.makedirs(docs,exist_ok=True)
    open(os.path.join(here,"c_lut.vh"),"w").write(emit_c_lut()+"\n")
    open(os.path.join(here,"palette_lut.vh"),"w").write(emit_palette_lut()+"\n")
    print("wrote tools/c_lut.vh, tools/palette_lut.vh")
    render_montage([0,32,64,96,128,160,192,224], 240, 135, os.path.join(docs,"julia_frames.png"))
    render(43, 1920, 1080, os.path.join(docs,"julia_1080p.png"))
