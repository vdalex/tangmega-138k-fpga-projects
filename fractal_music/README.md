# Fractal music generator with visualisation (Tang Mega 138K)

A **logistic map composes**, and the trajectory of that same map fills the
screen with a playhead riding along it — so what you see is literally where the
notes are coming from. Eight voices, stereo with a ping-pong room, out through
the board's on-board DAC; **1280x720 @ 60 Hz** over HDMI on a Sipeed Tang Mega
138K (Gowin GW5AST-138C).

![screen](docs/screen.png)

Nothing here scripts the music. `x <- r*x*(1-x)` is stepped once per note while
`r` sweeps from 2.8 to 4.0 over forty seconds, and the shape of the piece falls
out of where the map happens to be: below the first bifurcation the orbit is a
fixed point and one note repeats; past it the orbit splits and a two-note
figure appears, then four, then chaos — and inside the chaos there are windows
where a clear motif returns. The period-3 window at `r ~ 3.83` is unmistakable,
and it is where the playhead is frozen in the picture above.

Listen: [docs/preview.wav](docs/preview.wav) — rendered by the model, and
identical to the board sample for sample.

## The picture is the trajectory, not the attractor

The textbook bifurcation diagram plots where the orbit *ends up* at each `r`,
settled over hundreds of iterations. That is [docs/attractor.png](docs/attractor.png),
and it is **not** what this design draws, because it does not agree with what
you hear.

Just past `r = 3` the fixed point turns unstable — but only barely, its
multiplier is `1+e`. An orbit sitting on it takes thousands of iterations to
spiral away, so the settled picture shows a fork thirty pixels wide at the
moment the music is still playing one pitch. Measured, the ear heard the split
about a second after the eye saw it, and no iteration count that fits in a
note's clock budget closes that gap: at `r = 3.0025` a perturbation grows 1.37x
in 127 steps, and roughly 2700 are needed.

So the screen shows every point the orbit actually visits, plotted at the
column of its own `r`. Picture and sound then agree by construction — the same
delayed fork is in both. Past the transient the two renderings are identical
pixel for pixel, and the trajectory one is denser (6.2% of pixels lit against
4.4%) because it keeps the approach as well as the destination.

## How it works

**The composer** (`logistic_seq.v`) steps the map in Q3.15 — 18 bits, chosen
because the DSPs on this part are 18x18, so each of the two products is exactly
one DSP and one cycle. `r` comes from a table rather than an accumulator so the
board visits exactly the values the model rendered: with a chaotic map, "very
nearly the same" is a different piece. The orbit point becomes a scale degree
(squared first, which spreads the crowded top of the range over the scale), a
stereo position, and every fourth note an octave drop.

**127 iterations per note**, not one. The count has to be coprime with the
period of every window worth hearing: 15 and 63 are divisible by three and
flatten the period-3 window into a single repeated note. 127 is prime.

**The synthesiser** (`synth8.v`) time-multiplexes eight voices onto one
wavetable and one set of multipliers — 6 clocks per voice out of the 1568
between samples. Pitch is quantised to a minor pentatonic, which is what keeps
an essentially random sequence consonant, and the envelope tail (~0.38 s)
is deliberately longer than the note spacing (0.125 s) so three notes are
always sounding together. **The harmony is nothing but that overlap.**

**The room** (`pingpong.v`) is a stereo delay whose channels feed back into
each other, damped a little each pass. 165 ms, deliberately not a neat fraction
of the note grid — an exact multiple would land the repeats on the beat and
read as a rhythmic effect instead of a space.

**The output** is a PT8211: a 16-bit R-2R ladder with no master clock and no
registers at all, driven in LSB-justified ("Japanese") format. It converts on
each word-select edge, so the frame rate *is* its conversion clock and the
divider has to be uniform — which rules out dithering one to average out at
exactly 48 kHz. Of the uniform dividers available from the 75 MHz pixel clock,
49 gives **47831.6 Hz**, six cents from 48 kHz where 48 would have been thirty.

Everything — video, audio, the composer — runs on the single 75 MHz pixel
clock. There is no simulator for this board, and a clock domain crossing is
exactly the kind of fault that is expensive to find without one.

## Numbers

| | |
|---|---|
| Output | 1280x720 @ 60 Hz, raw DVI |
| Sample rate | 47831.6 Hz (75 MHz / 49 / 32) |
| Voices | 8, round-robin, ~0.38 s tail |
| Note grid | 8 per second; 320 notes = one 40 s sweep |
| Fmax | **127.8 MHz** against a 75 MHz constraint, 0 violated endpoints |
| Logic | 1404 LUT/ALU (2%), 832 registers, 24 SSRAM |
| Memory | 34 BSRAM (10%) — the diagram is 7200 words of it |
| DSP | 13 blocks (6%) |

## Layout

```
eda_proj/                          Gowin project (open fractal_music.gprj)
  src/top.v                        PLL, reset, the note grid, I2S clocking
  src/audio/logistic_seq.v         the composer - the map and the note events
  src/audio/synth8.v               8-voice wavetable synth, panned
  src/audio/pingpong.v             cross-coupled stereo delay
  src/audio/audio_drive.v          PT8211 driver, from Sipeed's example
  src/video-misc/bifur_screen.v    the diagram, full frame, with the playhead
  src/video-misc/sweep_rom.v       generated: r and its Julia constant
  src/video-misc/music_video.v     raster and sync
  src/dvi-tx/, gowin_pll_video/    reused HDMI infrastructure
tools/music_model.py               bit-exact model: renders the preview and
                                   the diagram, emits every ROM
tools/hw_check.py                  a second, literal transcription of the RTL,
                                   diffed against the model
tools/diag_render.py               renders the piece with one thing removed at
                                   a time, to identify a fault by ear
docs/                              preview.wav, screen.png, the two diagrams
```

Re-run `python tools/music_model.py` after changing anything musical: it
regenerates the wavetables, the note table, the sweep table and the diagram,
and re-renders `docs/preview.wav` so the reference always matches the source.

## Verifying a change

There is no simulator for this part, so `tools/hw_check.py` is the substitute.
It is a deliberately literal second transcription of the Verilog — fixed
widths, truncation where the RTL truncates, the same order of operations — read
from the same tables the bitstream was built from, and diffed against the model
note for note and sample for sample. It found several faults that listening
never would have isolated.

To use it, set `LOOP_REPEATS = 1` in `logistic_seq.v` first. That reseeds the
orbit at the end of each lap so every pass reproduces `docs/preview.wav`
exactly; with the default of 0 the orbit carries over and the piece never
repeats, which is better music but not comparable.

The board also reports on itself. LEDs are **active low**:

| | |
|---|---|
| T18 | blinks — the fabric is running |
| R18 | lit — sample frames are flowing |
| R17 | lit — the mix has hit the rails |
| P16 | lit — the orbit escaped [0,1) |

Normal operation is T18 blinking, R18 lit, the other two dark.

## Tuning

Musical parameters live in `tools/music_model.py` and are mirrored into the
Verilog: `ROOT_HZ` and `PENTATONIC` (the scale), `DECAY_SH` (how long notes
ring, and so how thick the harmony is), `BASS_EVERY`, `HARMONICS` (brightness
of the sawtooth), `PAN_MIN`/`PAN_MAX` (stereo width), `DELAY_MS`, `FEEDBACK`,
`WET`. `MIX_SH` in `synth8.v` is the output level.

`ITERS` in `logistic_seq.v` must match `ITERS_PER_NOTE` in the model, and must
stay coprime with the small window periods. `R_MIN` sets how long the calm
opening lasts — the piece is a fixed point until `r = 3`, which at 2.8 is about
seven seconds of one note.

## Build

Open `eda_proj/fractal_music.gprj` in Gowin EDA (V1.9.11.03), set the top
module to `top`, Synthesize -> Place & Route -> Program. Headless:

```tcl
open_project fractal_music.gprj
set_option -top_module top
run all
```

Connect HDMI **directly to a TV or monitor** — this is raw DVI with no
InfoFrame and no HDCP, and AV receivers reject it. Audio comes out of the
3.5 mm jack, not over HDMI: real HDMI audio needs data islands, TERC4, clock
regeneration and InfoFrames, none of which the DVI transmitter here does.

## What this cost

Three faults in this project were invisible in every report the tools produce
and were found only by instrumenting the fabric:

- **`$readmemh` loads nothing if the digit count does not match the memory
  width.** Five hex digits is twenty bits; the vector was eighteen. Gowin emits
  `EX2526`, skips the initialisation, builds the ROM empty, and carries on. The
  composer ran on a meaningless `r` for days while every other part measured
  correct — the Python checker reads the same file with its own parser and gets
  the intended numbers. The tables are now compiled in as constants.
- **Two structurally identical modules get merged**, and the log reports one
  instance as `NL0002 ... swept in optimizing` — indistinguishable from an
  instance being deleted for being unused. `r_rom` and `c_rom` are now one
  module with two outputs.
- **A shared register between two multiplies** is the shape a tool folds into
  a DSP's own output register. One register per product now.

The instrument in each case was an LED latch: a flag set on the first
occurrence of an impossible condition, held until reset, read at leisure. On a
board with no simulator, no printf and no debugger, four LEDs and a hypothesis
narrow things faster than listening does.
