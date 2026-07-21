#!/usr/bin/env python3
"""
Bit-exact software model of the generative-fractal-art generator
(random_fractal_gen.v): a Julia set whose parameter c does a bounded
pseudo-random walk (so the structure keeps changing and never repeats),
coloured by a cyclic jewel-tone palette that rotates over time.

Renders showcase frames (docs/) and emits the Verilog LUTs the hardware
embeds: the unit-circle cos/sin table and the cyclic palette.
"""
import struct, zlib, math, os

FRAC   = 14
SCALE  = 1 << FRAC
ESCAPE = 1 << (2*FRAC + 2)
N      = 12

W_full, H_full = 1920, 1080
ZR_STEP = 27; ZI_STEP = 27
ZR_MIN  = -(ZR_STEP * W_full) // 2
ZI_MIN  = -(ZI_STEP * H_full) // 2

ANG   = 256                 # c-circle LUT entries
PAL   = 64                  # cyclic palette entries
STRIDE = 4                  # palette entries per escape band
R_FIX = 0.7885              # fixed c radius (angle does the random walking)

# ---- cyclic "jewel-tone" palette (loops smoothly end-to-end) ----
_CTRL = [(10,20,60),(30,90,200),(40,200,220),(120,240,180),
         (250,230,120),(250,140,90),(230,80,160),(120,60,180)]
def cyc(i):
    i %= PAL; seg=len(_CTRL); fi=i/PAL*seg; k=int(fi)%seg; t=fi-int(fi)
    a=_CTRL[k]; b=_CTRL[(k+1)%seg]
    return tuple(round(a[j]+(b[j]-a[j])*t) for j in range(3))

def s18(v):
    v &= (1<<18)-1
    return v-(1<<18) if v & (1<<17) else v
def julia(zr, zi, cr, ci):
    """Return (escape count, final zr, final zi). The final z is carried
    through the pipeline anyway and colours the interior (no black hole)."""
    cnt=0; esc=False
    for _ in range(N):
        zr2=zr*zr; zi2=zi*zi; mag=zr2+zi2
        if not esc:
            if mag>=ESCAPE: esc=True
            else:
                cnt+=1
                zr,zi=s18(((zr2-zi2)>>FRAC)+cr), s18((zr*zi>>(FRAC-1))+ci)
    return cnt, zr, zi

def shade(cnt, zr, zi, off):
    """Exterior -> escape-band colour; interior -> smooth glow from |z| (no hole)."""
    if cnt < N:
        return cyc(cnt*STRIDE + off)
    return cyc(((abs(zr) + abs(zi)) >> 9) + off + 8)

def write_png(path,W,H,rows):
    def ch(t,d):
        c=t+d; return struct.pack(">I",len(d))+c+struct.pack(">I",zlib.crc32(c))
    raw=b"".join(b"\x00"+r for r in rows)
    open(path,"wb").write(b"\x89PNG\r\n\x1a\n"+ch(b"IHDR",struct.pack(">IIBBBBB",W,H,8,2,0,0,0))
                          +ch(b"IDAT",zlib.compress(raw,9))+ch(b"IEND",b""))

def _c(R, deg):
    th=math.radians(deg); return round(R*math.cos(th)*SCALE), round(R*math.sin(th)*SCALE)

def render(R, deg, off, W, H, path):
    cr,ci=_c(R_FIX,deg); sx=W_full/W; sy=H_full/H; rows=[]
    for yy in range(H):
        zi0=ZI_MIN+int(yy*sy)*ZI_STEP; row=bytearray()
        for xx in range(W):
            zr0=ZR_MIN+int(xx*sx)*ZR_STEP
            row+=bytes(shade(*julia(zr0,zi0,cr,ci),off))
        rows.append(bytes(row))
    write_png(path,W,H,rows); print("wrote",path,f"{W}x{H}")

def render_montage(tiles, TW, TH, cols, path):
    rows_n=(len(tiles)+cols-1)//cols
    big=[bytearray(TW*cols*3) for _ in range(TH*rows_n)]
    sx=W_full/TW; sy=H_full/TH
    for idx,(R,deg,off) in enumerate(tiles):
        cr,ci=_c(R_FIX,deg); ox=(idx%cols)*TW; oy=(idx//cols)*TH
        for yy in range(TH):
            zi0=ZI_MIN+int(yy*sy)*ZI_STEP
            for xx in range(TW):
                zr0=ZR_MIN+int(xx*sx)*ZR_STEP
                r,g,b=shade(*julia(zr0,zi0,cr,ci),off)
                big[oy+yy][(ox+xx)*3:(ox+xx)*3+3]=bytes((r,g,b))
    write_png(path,TW*cols,TH*rows_n,[bytes(r) for r in big]); print("wrote",path)

def emit_c_lut():
    L=["\t// c = 0.7885*(cos,sin) around a 256-step circle, Q4.14 (generated)",
       "\tfunction [35 : 0] c_lut(input [7 : 0] a);  // {c_re[17:0], c_im[17:0]}",
       "\t\tcase(a)"]
    for i in range(ANG):
        th=2*math.pi*i/ANG
        cr=round(R_FIX*math.cos(th)*SCALE) & 0x3FFFF
        ci=round(R_FIX*math.sin(th)*SCALE) & 0x3FFFF
        L.append(f"\t\t\t8'd{i}: c_lut = {{18'h{cr:05X}, 18'h{ci:05X}}};")
    L += ["\t\t\tdefault: c_lut = 36'h0;","\t\tendcase","\tendfunction"]
    return "\n".join(L)

def emit_pal_lut():
    L=["\t// cyclic jewel-tone palette x64 (generated)",
       "\tfunction [23 : 0] pal(input [5 : 0] idx);","\t\tcase(idx)"]
    for i in range(PAL):
        r,g,b=cyc(i); L.append(f"\t\t\t6'd{i}: pal = 24'h{r:02X}{g:02X}{b:02X};")
    L += ["\t\t\tdefault: pal = 24'h000000;","\t\tendcase","\tendfunction"]
    return "\n".join(L)

if __name__ == "__main__":
    here=os.path.dirname(os.path.abspath(__file__))
    docs=os.path.join(here,"..","docs"); os.makedirs(docs,exist_ok=True)
    open(os.path.join(here,"c_lut.vh"),"w").write(emit_c_lut()+"\n")
    open(os.path.join(here,"pal_lut.vh"),"w").write(emit_pal_lut()+"\n")
    print("wrote tools/c_lut.vh, tools/pal_lut.vh")
    render_montage([(0.745,20,0),(0.760,55,10),(0.775,95,22),(0.730,130,34),
                    (0.785,165,0),(0.755,205,16),(0.770,240,40),(0.740,300,28)],
                   320, 180, 4, os.path.join(docs,"art_frames.png"))
    render(0.775, 95, 22, 1920, 1080, os.path.join(docs,"art_1080p.png"))
