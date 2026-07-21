# Analog clock on HDMI (Tang Mega 138K)

A real-time **analog clock** - face, hour marks and three moving hands -
rendered at **1920x1080 @ 60 Hz** over HDMI on the Sipeed Tang Mega 138K
(Gowin GW5AST-138C). Every pixel is generated on the fly from the raster
position; there is **no framebuffer**.

![Clock face showing 10:08](docs/clock_1080p.png)

## How it works

The picture is a set of simple geometric tests evaluated for the pixel at
offset `(dx, dy)` from the screen centre:

- **hands** - a hand with unit direction `(sx, sy)` (scaled by 256) covers the
  pixel when the projection along the hand `dot = dx*sx + dy*sy` is within
  `[-tail, length]` and the perpendicular distance `cross = dx*sy - dy*sx` is
  within `[-halfwidth, halfwidth]`. Three hands = three such tests.
- **face ring & centre** - from `r2 = dx*dx + dy*dy`: the ring is `400..416` px,
  the hub dot is `<= 12` px.
- **hour marks** - twelve small squares on the `radius = 370` circle.
- **colour** - a priority mux picks the top-most element (centre dot > second >
  minute > hour > tick > ring > face > background).

### Multiplier-free per-pixel datapath (to close 150 MHz)

`dot` and `cross` are **affine** in the raster coordinates and `r2` is
**quadratic**, so none of them is multiplied per pixel. Instead each is kept in
an accumulator (a **DDA**): loaded at the start of every active line and stepped
with an adder once per pixel (`r2 += 2*dx + 1`, `dot += sx`, ...). The only
multiplies - the six per-line-start constants - are replaced by small **lookup
tables** indexed by the hand angle, so the pixel pipeline uses **no multipliers
at all**. It is three registered stages:

```
stage 0 : DDA accumulators (dx, r2, dot/cross per hand)
stage 1 : shape flags (ring / face / tick / each hand)
stage 2 : colour priority mux
```

The sync signals are delayed two cycles to match. Timing closes at
**Fmax ~150 MHz**.

### Time base

`frame_tick` fires once per frame; **60 frames = 1 second**. Second/minute/hour
indices advance from there and pick the hand angles from a 60-entry
`sin/cos` LUT (6 deg per step). The hour hand nudges one step (6 deg) every
12 minutes, so it tracks the minutes. The start time is set by the
`init_hour` / `init_min` / `init_sec` parameters (default **10:08:00**).
Because the indices only change during vblank, the hand vectors are stable for
the whole frame - no tearing.

## Layout

```
eda_proj/                 Gowin project (open analog_clock.gprj in the IDE)
  src/top.v               PLL + reset + DVI-TX + analog_clock_gen
  src/video-misc/analog_clock_gen.v   the clock generator (this design)
  src/video-misc/video_timing_ctrl.v  1080p raster timing
  src/dvi-tx/, gowin_pll/  reused HDMI infrastructure (150 MHz pixel clock)
  src/analog_clock.cst/.sdc            pin + timing constraints
tools/clock_model.py      faithful software render of this design (docs/*.png)
docs/                     rendered reference images
```

## Tuning

Parameters on `analog_clock_gen`: `init_hour` / `init_min` / `init_sec` (start
time); the `*_LEN` / `*_HW` / `*_TAIL` localparams (hand lengths, widths and
tails); the `RING_R2_*` / tick radius (face geometry); and the `COL_*`
localparams (palette). Angles come from the embedded `sin_lut` (60 steps).

## Build

Open `eda_proj/analog_clock.gprj` in Gowin EDA (V1.9.11.03), set the top module
to `top`, Synthesize -> Place & Route -> Program. Connect HDMI **directly to a
TV/monitor** (raw DVI, no InfoFrame/HDCP; AV receivers may reject it).
