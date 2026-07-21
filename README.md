# Tang Mega 138K - HDMI generative-video projects

Four self-contained FPGA projects for the **Sipeed Tang Mega 138K**
(Gowin **GW5AST-138C**) that synthesise **1920x1080 @ 60 Hz** video in real time
and stream it over HDMI. There is **no framebuffer** - every pixel is computed
on the fly at the 150 MHz pixel clock as the raster scans.

## Projects

| Preview | Project | What it shows |
|---|---|---|
| <img src="fractal_art/docs/art_1080p.png" width="220"> | **[fractal_art](fractal_art/)** | Generative, ever-changing fractal art - a Julia set that wanders and recolours forever |
| <img src="fractal_anim/docs/julia_1080p.png" width="220"> | **[fractal_anim](fractal_anim/)** | Animated Julia set that morphs smoothly between shapes |
| <img src="mandelbrot/docs/mandelbrot_1080p.png" width="220"> | **[mandelbrot](mandelbrot/)** | The classic Mandelbrot set, rendered live |
| _(no model render)_ | **[analog_clock](analog_clock/)** | Analog clock with moving hour / minute / second hands |

Each folder is a complete Gowin project with its own `README.md`.

## How they work

All four generate video directly from the raster position - one pixel per pixel
clock, no frame buffer, no external memory.

- **The three fractal projects** share one proven **escape-time pipeline**
  (`z <- z^2 + c`, evaluated once per pixel): the iteration loop is fully
  unrolled into a deep pipeline in **Q4.14** fixed point, so a new pixel enters
  and a finished pixel leaves every clock. `mandelbrot` sweeps `c` across the
  screen; `fractal_anim` and `fractal_art` fix the view and walk `c` over time.
- **The clock** avoids per-pixel multiplies entirely: the hand / ring / tick
  tests are affine or quadratic in the screen coordinates, so they are tracked
  with **adders only (a DDA)** and a few per-frame lookup tables.
- **`tools/`** (fractal projects) holds a bit-exact **Python model** that both
  validates the fixed-point math and generates the Verilog colour / angle LUTs
  and the reference renders in `docs/`.

Everything is tuned to close timing at the **150 MHz** pixel clock on the
GW5AST-138C.

## Hardware

- **Board:** Sipeed Tang Mega 138K
- **FPGA:** Gowin GW5AST-138C (`GW5AST-LV138PG484AC1/I0`, `gw5ast138c-007`)
- **Clocking:** on-chip PLL, VCO 750 MHz -> 150 MHz pixel + 750 MHz serial (5x)
- **Video:** 1920x1080, 150 MHz pixel clock (~60.6 Hz refresh)
- **Output:** raw **DVI** TMDS (no InfoFrame / HDCP). Connect the HDMI cable
  **directly to a TV or monitor** - some AV receivers reject a raw-DVI stream.

## Build

1. Install **Gowin EDA V1.9.11.03** (Education is fine).
2. Open `<project>/eda_proj/<project>.gprj`.
3. Set the top module to `top`, then **Synthesize -> Place & Route -> Program**.

The bitstream lands in `<project>/eda_proj/impl/pnr/<project>.fs`
(the `impl/` build output is git-ignored).
