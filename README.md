# Tang Mega 138K - FPGA projects

Self-contained FPGA projects for the **Sipeed Tang Mega 138K**
(Gowin **GW5AST-138C**). All of them put **1920x1080 @ 60 Hz** on HDMI with no
framebuffer - four generate the picture in fabric, and the fifth wakes up the
**hard RISC-V CPU** hiding in the same die and lets it print to the screen.

## Video projects

Every pixel is computed on the fly at the 150 MHz pixel clock as the raster
scans - there is **no framebuffer** and no external memory.

| Preview | Project | What it shows |
|---|---|---|
| <img src="fractal_art/docs/art_1080p.png" width="220"> | **[fractal_art](fractal_art/)** | Generative, ever-changing fractal art - a Julia set that wanders and recolours forever |
| <img src="fractal_anim/docs/julia_1080p.png" width="220"> | **[fractal_anim](fractal_anim/)** | Animated Julia set that morphs smoothly between shapes |
| <img src="mandelbrot/docs/mandelbrot_1080p.png" width="220"> | **[mandelbrot](mandelbrot/)** | The classic Mandelbrot set, rendered live |
| <img src="analog_clock/docs/clock_1080p.png" width="220"> | **[analog_clock](analog_clock/)** | Analog clock with moving hour / minute / second hands |

- **The three fractal projects** share one proven **escape-time pipeline**
  (`z <- z^2 + c`, evaluated once per pixel): the iteration loop is fully
  unrolled into a deep pipeline in **Q4.14** fixed point, so a new pixel enters
  and a finished pixel leaves every clock. `mandelbrot` sweeps `c` across the
  screen; `fractal_anim` and `fractal_art` fix the view and walk `c` over time.
- **The clock** avoids per-pixel multiplies entirely: the hand / ring / tick
  tests are affine or quadratic in the screen coordinates, so they are tracked
  with **adders only (a DDA)** and a few per-frame lookup tables.
- **`tools/`** holds a bit-exact **Python model** that both validates the
  fixed-point math and generates the Verilog colour / angle LUTs and the
  reference renders in `docs/`.

All four close timing at the **150 MHz** pixel clock.

## Hard RISC-V

| Preview | Project | What it does |
|---|---|---|
| <img src="riscv_hdmi/docs/hdmi_console.png" width="220"> | **[riscv_hdmi](riscv_hdmi/)** | Runs C on the **AndesCore A25** hardened into the GW5AST-138C, printing to a 1080p text console |

The GW5AST-138C is not just an FPGA: it carries an **A25 + AE350 subsystem as
hardened silicon**, so the CPU costs *zero LUTs and zero registers*. This
project boots it from a fabric ROM baked into the bitstream - no debugger, no
SPI-flash programming - gives it fabric RAM for its stack, and has it print a
greeting to two places at once: the serial console, and a **120x33 character
screen** the fabric scans out at 1920x1080. The CPU writes characters into a
dual-ported buffer; a glyph ROM and a five-stage pipeline turn them into
pixels as the raster passes.

Gowin's IP Core Generator has no AE350 entry in the **Education** edition,
which makes the core look unavailable. It is not: `AE350_SOC` is in the device
primitive library and can be instantiated by hand. Doing so means meeting a few
requirements the generator would otherwise handle silently - the core clock
arrives over a *dedicated path* from one specific PLL output, the internal DLM
does not exist on this part, and the data port is 64 bits wide. The project
README documents each one, along with the LED-only bisection programs used to
find them.

## Hardware

- **Board:** Sipeed Tang Mega 138K
- **FPGA:** Gowin GW5AST-138C (`GW5AST-LV138PG484AC1/I0`, `gw5ast138c-007`)
- **Video clocking:** on-chip PLL, VCO 750 MHz -> 150 MHz pixel + 750 MHz serial (5x)
- **Video output:** 1920x1080, 150 MHz pixel clock (~60.6 Hz refresh), raw
  **DVI** TMDS (no InfoFrame / HDCP). Connect the HDMI cable **directly to a TV
  or monitor** - some AV receivers reject a raw-DVI stream.
- **Serial console** (riscv_hdmi): through the on-board **BL616** USB-serial
  bridge at 115200 8N1; if two COM ports appear, it is usually the
  higher-numbered one.
- **On-board LEDs:** `T18`, `R18`, `R17`, `P16` - **active low**. Note `V13`
  has no LED fitted on this board and `U21` is a dedicated CPU/SSPI pin.

## Build

1. Install **Gowin EDA V1.9.11.03** (Education is fine - everything here,
   including the hard RISC-V, was built with it).
2. Open `<project>/eda_proj/<project>.gprj`.
3. Set the top module to `top`, then **Synthesize -> Place & Route -> Program**.

The bitstream lands in `<project>/eda_proj/impl/pnr/<project>.fs`
(the `impl/` build output is git-ignored).

For `riscv_hdmi` the firmware is compiled into the bitstream, so build it
**first** (`fw/build.ps1`, xPack `riscv-none-elf-gcc`) whenever the C changes.
