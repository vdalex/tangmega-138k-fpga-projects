#!/usr/bin/env python3
"""
Bit-exact model of the fractal music generator.

The hardware and this file compute the same fixed-point arithmetic, so what you
hear in docs/preview.wav is what the board plays. It also emits every ROM the
design needs, which is the point of doing it this way: a wrong constant costs
seconds here and an hour of build-flash-listen on hardware.

Outputs:
  docs/preview.wav            listen before committing anything to silicon
  docs/bifurcation.png        the diagram, as the screen will show it
  eda_proj/src/bifur_rom.vh   that diagram, 1 bit per pixel, for the fabric
  eda_proj/src/wave_rom.vh    quarter-sine wavetable
  eda_proj/src/note_rom.vh    scale degree -> phase increment
"""
import math, os, struct, zlib

# ---------------------------------------------------------------- fixed point
#
# x and r live in Q3.15 - 18 bits, 15 fractional. The width is chosen by the
# hardware, not by taste: the DSP blocks on this part are 18x18, so at this
# format each of the map's two products is exactly one DSP and one cycle. An
# earlier Q2.30 version needed a 32x32 multiply, which the tool builds as a
# cascade and which held the whole design to 83 MHz against a 150 MHz target.
# Fifteen fractional bits is ample for the structure that matters here - the
# period-doubling cascade and the period-3 window are both far wider than the
# quantisation.
FRAC   = 15
ONE    = 1 << FRAC
R_MIN  = int(2.80 * ONE)        # below this the map is a fixed point: silence
R_MAX  = int(4.00 * ONE)

# The sweep is defined ONCE, over note index, and everything uses it: the
# render, the r table the FPGA reads, and the Julia constants for the picture.
#
# It did not used to be. The render walked r by sample index while emit_r_rom
# walked it by note index, and with the old sample rate those did not divide
# evenly - the two agreed on only 51 of the 320 values. From note 88 onward,
# which is exactly where the chaotic region starts and small differences stop
# staying small, the preview WAV and the board were playing different pieces.
# That is what "the harmony is wrong compared to preview.wav" was.
#
# The constants are the ones the piece was composed against, and they are
# written out literally rather than derived from SR so that retuning the sample
# rate can never silently rewrite the composition again.
SWEEP_TICKS = 320
_SWEEP_NUM  = 6103              # samples per note when the piece was written
_SWEEP_DEN  = 1953120           # ...and the sample count of the whole sweep


def sweep_r(k):
    """r at note k, Q3.15. The single definition of where the music goes."""
    return R_MIN + (R_MAX - R_MIN) * (k * _SWEEP_NUM) // _SWEEP_DEN

# Sample rate is dictated by the hardware, not chosen: everything runs on the
# 75 MHz pixel clock, BCK is that divided by 49, and 32 bits per stereo frame
# gives 75e6/1568. Keeping this number honest here is what makes the preview
# match the board - phase increments are computed from it.
#
# Why 49 and not a round divider: the DAC is a PT8211, an R-2R ladder with no
# master clock and no registers at all. It converts on each WS edge, so the
# frame rate IS its conversion clock and any jitter on it lands straight in the
# audio - which rules out dithering a fractional divider to hit 48000 exactly.
# Of the uniform dividers available from 75 MHz, 49 lands closest:
#
#   /48 -> 48828.1 Hz   +1.73%   (+29.6 cents)
#   /49 -> 47831.6 Hz   -0.35%   ( -6.1 cents)
#
# Exact 48 kHz needs a 12.288 MHz reference; from 50 MHz it is not reachable
# with integer dividers. Note this is a transposition of the whole piece, not a
# detuning - every interval between voices is preserved exactly.
SR         = 47832              # 75 MHz / (49 * 32) = 47831.6, rounded
NOTE_HZ    = 8                  # note grid: 8 per second

# Map iterations per note. The screen shows where the orbit GOES, not where it
# ends up (see trajectory_bitmap), but the music still has to keep pace with a
# sweeping r rather than trail behind it. With one step per note the orbit was
# 46 notes adrift - six seconds, 184 pixels.
#
# Measured against the note at which the two-note figure becomes audible:
#
#      7 steps -> note 63      31 steps -> note 57      127 steps -> note 54
#
# The count must be COPRIME with the period of every window worth hearing, or
# the motif collapses: 15 and 63 are divisible by three and turn the period-3
# window - the best figure in the piece - into one repeated note. 127 is prime.
#
# Must match ITERS in logistic_seq.v. Costs 127 x 4 = 508 clocks of the 5979
# between notes.
ITERS_PER_NOTE = 127
SWEEP_SECS = 40                 # time to cross the whole diagram

# ---------------------------------------------------------------- musical map
#
# Pitch is quantised to a minor pentatonic, which is what keeps an essentially
# random sequence sounding consonant - there is no interval in it that clashes.
# Three octaves is enough range to be interesting without becoming shrill.
PENTATONIC = [0, 3, 5, 7, 10]           # semitones from the root
ROOT_HZ    = 220.0                      # A3
N_DEGREES  = 15                         # 3 octaves x 5 notes

# With the bass an octave below the root, that spans 110 Hz .. 1568 Hz. The
# first version rooted this at A1 and topped out at 392 Hz, which measured as
# 99% of the energy below 273 Hz - everything crammed into the bass, with the
# region the ear is most sensitive to left empty.

# Eight voices, allocated round-robin. In hardware this costs almost nothing:
# at 48 kHz there are ~2000 clocks per sample, so one wavetable and one
# multiplier are time-multiplexed across all of them. Musically it is the
# difference between an arpeggio and a chord - with a decay longer than the
# note spacing, voices overlap and the pentatonic turns them into harmony.
VOICES     = 8
DECAY_SH   = 13                         # env -= env>>13: ~0.6 s tail
BASS_EVERY = 4                          # every Nth note drops an octave
WAVE_BITS  = 8                          # 256 entries per wavetable
PHASE_BITS = 32

# Two timbres in one ROM (address = {table, phase}). A pure sine has no
# harmonics at all, so even with the range raised the result stays dull; but
# giving the bass harmonics too would just muddy the low end. So: sine for the
# bass, a band-limited sawtooth for everything above it.
HARMONICS  = 5                          # 1/n amplitudes, no aliasing below 4.8 kHz

# ---------------------------------------------------------------- space
#
# Stereo position is taken from the orbit rather than assigned per voice, so
# the width carries information: stable in the periodic windows, scattered in
# the chaotic ones. Not quite hard-panned - leaving a little of each note in
# the opposite channel keeps the image from tearing into two separate streams.
PAN_MIN, PAN_MAX = 40, 215

# Ping-pong delay. 165 ms is deliberately not a neat fraction of the 125 ms
# note grid: an exact multiple would make the repeats land on the beat and
# sound like a rhythmic effect instead of a room. The length is also chosen to
# fit 8192 samples, which halves the block RAM the delay lines occupy - with
# this design the placer's spread, not logic, is what limits the clock.
DELAY_MS   = 165
DELAY_LEN  = SR * DELAY_MS // 1000
FEEDBACK   = 140                        # /256 - how much returns for another lap
WET        = 150                        # /256 - how much of the echo is heard
DAMP_SH    = 2                          # one-pole rolloff in the feedback path
MIX_SH     = 1                          # voice sum >> this before the delay


def clamp16(v):
    return -32768 if v < -32768 else (32767 if v > 32767 else v)

W, H       = 640, 360                   # diagram resolution, drawn at 2x -> 1280


def note_hz(degree):
    octave, step = divmod(degree, len(PENTATONIC))
    return ROOT_HZ * (2.0 ** octave) * (2.0 ** (PENTATONIC[step] / 12.0))


def wavetables():
    """[0] = sine for the bass, [1] = band-limited saw for everything else."""
    sine = [int(32767 * math.sin(2 * math.pi * i / 256)) for i in range(256)]
    bright = []
    norm = sum(1.0 / n for n in range(1, HARMONICS + 1))
    for i in range(256):
        v = sum(math.sin(2 * math.pi * n * i / 256) / n
                for n in range(1, HARMONICS + 1)) / norm
        bright.append(max(-32768, min(32767, int(32767 * v))))
    return [sine, bright]


def phase_inc(hz):
    """Phase increment for a 32-bit accumulator at the sample rate."""
    return int(round(hz * (1 << PHASE_BITS) / SR)) & 0xFFFFFFFF


# ---------------------------------------------------------------- the map
def logistic_step(x, r):
    """x <- r*x*(1-x), all Q2.30, exactly as the hardware does it.

    Two 32x32 products, each shifted back down by FRAC. Order matters for the
    rounding: hardware does (x*(ONE-x)) first, then multiplies by r.
    """
    t = (x * (ONE - x)) >> FRAC
    v = (r * t) >> FRAC
    # The same clamp the hardware carries. It cannot fire with this sweep - the
    # orbit peaks at 32386 against ONE = 32768 - and exists so the two sides
    # stay identical even in a state neither should reach. In logistic_seq.v it
    # is load-bearing: unsigned (ONE - x) wraps, and an escaped orbit never
    # returns.
    return (ONE - 1) if v >= ONE else v


def orbit(r, skip=200, take=64):
    """Settle onto the attractor, then report where it lives."""
    x = ONE // 2
    for _ in range(skip):
        x = logistic_step(x, r)
    out = []
    for _ in range(take):
        x = logistic_step(x, r)
        out.append(x)
    return out


# ---------------------------------------------------------------- synthesis
def render_audio():
    """Sweep r across the diagram, playing the orbit. Returns int16 stereo."""
    total    = SR * SWEEP_SECS
    per_note = SR // NOTE_HZ

    wave = wavetables()

    phase = [0] * VOICES
    inc   = [0] * VOICES
    env   = [0] * VOICES            # Q16 amplitude, decays every sample
    pan   = [128] * VOICES          # 0 = hard left, 255 = hard right
    tbl   = [1] * VOICES            # 0 = sine (bass), 1 = bright

    # Ping-pong delay: two lines, each feeding back into the *other* channel,
    # so a repeat bounces left-right-left. That bounce is most of what makes
    # this read as a room rather than as an echo.
    dl = [0] * DELAY_LEN
    dr = [0] * DELAY_LEN
    dpos = 0
    lp_l = lp_r = 0                 # one-pole damping in the feedback path

    x = ONE // 2
    samples = bytearray()
    voice = 0
    note_i = 0

    for n in range(total):
        # --- note grid ---
        if n % per_note == 0:
            r = sweep_r(n // per_note)
            for _ in range(ITERS_PER_NOTE):
                x = logistic_step(x, r)

            # x in [0,1) -> scale degree. The interesting part of the orbit
            # sits in the upper half, so the map is deliberately not linear:
            # squaring spreads that region over more of the range.
            # squaring first: the orbit crowds the top of the range, and this
            # spreads that region across the scale instead of bunching notes
            deg = ((x * x >> FRAC) * N_DEGREES) >> FRAC
            deg = max(0, min(N_DEGREES - 1, deg))

            # Voices take turns; every few notes goes an octave down so the
            # texture keeps a moving bass under the chord.
            voice = (voice + 1) % VOICES
            note_i += 1
            is_bass = (note_i % BASS_EVERY) == 0
            # The octave drop is a shift of the increment, not a halved
            # frequency: hardware only has the one note_rom and takes
            # {1'b0, note_inc[31:1]} from it. Rounding the halved frequency
            # instead differs by an LSB on odd increments, which is enough to
            # step the wavetable one entry early now and then - harmless, but
            # it stops this file and the board agreeing exactly, and exact
            # agreement is what makes a diff between them mean something.
            inc[voice] = phase_inc(note_hz(deg))
            if is_bass:
                inc[voice] >>= 1
            env[voice] = 1 << 16
            tbl[voice] = 0 if is_bass else 1

            # Stereo position comes from the orbit too, so the width is telling
            # you the same thing the diagram is: in a periodic window the notes
            # land on the same few spots and the image holds still; in chaos
            # they scatter across the field.
            pan[voice] = PAN_MIN + ((x * (PAN_MAX - PAN_MIN)) >> FRAC)

        # --- voices ---
        acc_l = acc_r = 0
        for v in range(VOICES):
            if env[v]:
                phase[v] = (phase[v] + inc[v]) & 0xFFFFFFFF
                s = wave[tbl[v]][phase[v] >> (PHASE_BITS - WAVE_BITS)]
                a = (s * env[v]) >> 16
                acc_l += (a * (255 - pan[v])) >> 8
                acc_r += (a * pan[v]) >> 8
                # exponential-ish decay: subtract a proportion each sample
                env[v] -= (env[v] >> DECAY_SH) + 1
                if env[v] < 0:
                    env[v] = 0

        # Voices are mostly part-way through their decay at any moment, so
        # dividing by the full count wastes half the dynamic range. A quarter
        # measures out at a peak near -3 dBFS with the delay on top, which is
        # about right; MIX_SH is the knob if the balance ever changes.
        dry_l = acc_l >> MIX_SH
        dry_r = acc_r >> MIX_SH

        # --- ping-pong delay ---
        echo_l, echo_r = dl[dpos], dr[dpos]

        # Damp the feedback a little each pass. Without this the repeats stay
        # as bright as the source and stack up into harshness; rolling off the
        # top makes them recede instead, which is what reads as distance.
        lp_l += (echo_r - lp_l) >> DAMP_SH
        lp_r += (echo_l - lp_r) >> DAMP_SH

        dl[dpos] = clamp16(dry_l + ((lp_l * FEEDBACK) >> 8))
        dr[dpos] = clamp16(dry_r + ((lp_r * FEEDBACK) >> 8))
        dpos = (dpos + 1) % DELAY_LEN

        out_l = clamp16(dry_l + ((echo_l * WET) >> 8))
        out_r = clamp16(dry_r + ((echo_r * WET) >> 8))
        samples += struct.pack('<hh', out_l, out_r)

    return bytes(samples)


def write_wav(path, pcm):
    hdr = b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt '
    hdr += struct.pack('<IHHIIHH', 16, 1, 2, SR, SR * 4, 4, 16)
    hdr += b'data' + struct.pack('<I', len(pcm))
    open(path, 'wb').write(hdr + pcm)
    print('wrote %s: %.1f s' % (path, len(pcm) / 4 / SR))


# ---------------------------------------------------------------- diagram
def attractor_bitmap():
    """The textbook diagram: where the orbit ENDS UP at each r.

    Settled for 300 iterations per column, so every point is on the attractor.
    This is the canonical picture, and it is not what the board shows - see
    trajectory_bitmap for why.
    """
    rows = [bytearray(W) for _ in range(H)]
    for col in range(W):
        r = R_MIN + (R_MAX - R_MIN) * col // W
        for x in orbit(r, skip=300, take=220):
            y = H - 1 - (x * H >> FRAC)
            if 0 <= y < H:
                rows[y][col] = 1
    return rows


def trajectory_bitmap():
    """Where the orbit actually GOES, sweeping r exactly as the music does.

    The attractor picture and the music disagree at the first bifurcation, and
    the reason is physics rather than a bug. Just past r = 3 the fixed point
    turns unstable, but only barely - its multiplier is 1+e - so an orbit
    sitting on it takes thousands of iterations to spiral away. The settled
    picture shows a fork 30 pixels wide at the note where the music is still
    playing one pitch; measured, the ear hears the split about a second after
    the eye sees it. No iteration count inside a note's clock budget fixes
    that: at r = 3.0025 a perturbation grows 1.37x in 127 steps, and about
    2700 steps are needed.

    So draw what is actually played instead. Every point the orbit visits is
    plotted at the column of its own r, which makes the picture agree with the
    music by construction - the same delayed fork appears in both. Past the
    transient the two renderings are identical pixel for pixel, and this one is
    denser (6.2% of pixels lit against 4.4%) because it keeps the approach as
    well as the destination.

    Each note covers two columns at 640 wide, so both are filled; that also
    puts the drawn column exactly under the playhead, which steps by 4 screen
    pixels per note.
    """
    rows = [bytearray(W) for _ in range(H)]
    x = ONE // 2
    for k in range(SWEEP_TICKS):
        r = sweep_r(k)
        col = (r - R_MIN) * W // (R_MAX - R_MIN)
        if col >= W:
            col = W - 1
        for _ in range(ITERS_PER_NOTE):
            x = logistic_step(x, r)
            y = H - 1 - (x * H >> FRAC)
            if 0 <= y < H:
                rows[y][col] = 1
                if col + 1 < W:
                    rows[y][col + 1] = 1
    return rows


def write_png(path, w, h, rows):
    def ch(t, d):
        c = t + d
        return struct.pack('>I', len(d)) + c + struct.pack('>I', zlib.crc32(c))
    raw = b''.join(b'\x00' + r for r in rows)
    open(path, 'wb').write(
        b'\x89PNG\r\n\x1a\n'
        + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0))
        + ch(b'IDAT', zlib.compress(raw, 9)) + ch(b'IEND', b''))


def save_diagram_png(bmp, path):
    BG, FG = (0x10, 0x10, 0x18), (0x78, 0xF0, 0xC8)
    rows = []
    for y in range(H):
        row = bytearray()
        for v in bmp[y]:
            row += bytes(FG if v else BG)
        rows.append(bytes(row))
    write_png(path, W, H, rows)
    print('wrote', path)


def save_screen_png(bmp, path, note):
    """The 1280x720 frame the board puts on HDMI, rendered rather than filmed.

    Same 2x scaling and the same three colours as bifur_screen.v, so this is
    what the TV shows and not an impression of it. Photographing a screen for
    documentation gives reflections and moire; generating the frame from the
    very data the fabric reads does not.
    """
    BG   = (0x0A, 0x0A, 0x12)
    DIAG = (0x78, 0xF0, 0xC8)
    HEAD = (0xFF, 0x90, 0x30)
    head_x = note * 4                       # the playhead steps 4 px per note
    rows = []
    for y in range(H * 2):
        row = bytearray()
        for x in range(W * 2):
            if head_x <= x < head_x + 3:
                row += bytes(HEAD)
            else:
                row += bytes(DIAG if bmp[y >> 1][x >> 1] else BG)
        rows.append(bytes(row))
    write_png(path, W * 2, H * 2, rows)
    print('wrote %s (playhead at note %d, %.1f s)' % (path, note, note / 8.0))


# ---------------------------------------------------------------- ROMs
# Drawn at 640x360 and scaled 2x on the board to fill 1280x720.


def emit_bifur_rom(bmp, path):
    """Pack the diagram 32 pixels per word: address = row*30 + col/32.

    The whole diagram, every row. It used to be only the bottom STRIP_H, from
    when it shared the screen with a live Julia set and sat in a band along the
    bottom. It now fills the display on its own: 640x360 scaled 2x in both
    directions to 1280x720, so every row is shown.
    """
    words_per_row = W // 32
    with open(path, 'w') as f:
        f.write('// bifurcation diagram: a full %dx%d render,\n' % (W, H))
        f.write('// 1 bit per pixel, %d words per row (tools/music_model.py)\n'
                % words_per_row)
        for y in range(H):
            for wi in range(words_per_row):
                word = 0
                for b in range(32):
                    if bmp[y][wi * 32 + b]:
                        word |= 1 << (31 - b)      # MSB = leftmost pixel
                f.write('%08X\n' % word)
    print('wrote %s: %d words' % (path, H * words_per_row))


def emit_wave_rom(path):
    """Both tables in one ROM, so the hardware address is {table, phase[7:0]}.

    This has to come from wavetables() rather than recomputing a sine here -
    an earlier version did the latter and silently shipped a ROM that did not
    match what the preview had been rendered from.
    """
    tabs = wavetables()
    with open(path, 'w') as f:
        f.write('// two 256-entry wavetables, signed 16-bit (generated)\n')
        f.write('// address = {table, phase[7:0]}: 0 = sine (bass), 1 = bright\n')
        for t in tabs:
            for v in t:
                f.write('%04X\n' % (v & 0xFFFF))
    print('wrote %s: %d entries' % (path, 256 * len(tabs)))


def emit_r_rom(path, ticks=SWEEP_TICKS):
    """Sweep index -> r, Q3.15.

    A table rather than an accumulator so the hardware visits exactly the same
    r values this model does. With a chaotic map, "very nearly the same" is not
    the same: trajectories separate. The structure would survive either way,
    but agreeing exactly is cheap here - one small block RAM.
    """
    with open(path, 'w') as f:
        f.write('// sweep index -> r in Q3.15 (generated)\n')
        for i in range(ticks):
            f.write('%05X\n' % (sweep_r(i) & 0x3FFFF))
        for _ in range(512 - ticks):
            f.write('00000\n')
    print('wrote %s: %d entries' % (path, ticks))


def emit_case_rom(path, module, vals, width, addr_bits, title):
    """Write a ROM as a Verilog case statement, with no data file at all.

    $readmemh cost this project a great deal. Writing 18-bit values as five hex
    digits is twenty bits, and Gowin does not accept a mismatch: it emits
    "EX2526 Entry size 20 does not match memory width 18", skips the
    initialisation entirely, and carries on to build a ROM full of nothing.
    Nothing downstream fails loudly - the composer simply ran on a meaningless
    r for weeks, which put the orbit outside [0,1) and turned the piece into
    noise while every other part of the design measured correct.

    Constants in the source cannot be misparsed, cannot mismatch a width, and
    cannot silently fail to load. For a few hundred entries that is worth far
    more than the tidiness of a data file.
    """
    with open(path, 'w') as f:
        f.write('`timescale 1ns / 1ns\n\n//\n')
        for line in title.strip().splitlines():
            f.write('// %s\n' % line.strip())
        f.write('//\n// GENERATED by tools/music_model.py - do not edit.\n//\n')
        f.write('module %s (\n\tinput\t\t\t\tclk,\n' % module)
        f.write('\tinput\t\t[%d : 0]\taddr,\n' % (addr_bits - 1))
        f.write('\toutput reg\t[%d : 0] data\n);\n\n' % (width - 1))
        # An array with an initial block, not a case statement. A case gives the
        # right answer but synthesises to a 320-way mux: it took the design from
        # 109 MHz down to 75.5 against a 75 MHz constraint, seven levels of
        # logic deep. This form is still constants in the source - nothing to
        # parse, nothing that can fail to load - but the tool recognises it and
        # puts it in block RAM, where a table this size belongs.
        f.write('\t(* ram_style = "block" *)\n')
        f.write('\treg\t[%d : 0]\trom [0 : %d];\n\n'
                % (width - 1, (1 << addr_bits) - 1))
        f.write('\tinteger i;\n\tinitial begin\n')
        f.write("\t\tfor(i = 0; i < %d; i = i + 1) rom[i] = %d'd0;\n"
                % (1 << addr_bits, width))
        for i, v in enumerate(vals):
            f.write("\t\trom[%d] = %d'h%0*X;\n"
                    % (i, width, (width + 3) // 4, v))
        f.write('\tend\n\n\talways@(posedge clk)\n\t\tdata <= rom[addr];\n')
        f.write('\nendmodule\n')
    print('wrote %s: %d entries' % (path, len(vals)))


def emit_sweep_rom(path, rvals, cvals, addr_bits=10):
    """Both sweep tables in ONE module, one memory, one address.

    They used to be two modules, r_rom and c_rom, and after the widths were
    fixed the two became structurally identical - same ports, same depth, same
    style - differing only in their data. The tool then merged the definitions
    and reported one of the two instances as "NL0002 ... swept in optimizing",
    which is indistinguishable in the log from an instance being deleted. That
    ambiguity cost real time during debugging. One module cannot be merged with
    anything, so the question does not arise.

    They share an address anyway: both are indexed by the sweep position, so a
    single 36-bit word holding {c, r} is also one block RAM read instead of two.

    Constants in an initial block rather than $readmemh, deliberately. A data
    file has to agree with the memory width to the bit - five hex digits into an
    eighteen-bit vector raises "EX2526 Entry size 20 does not match memory width
    18", and Gowin's response is to skip the initialisation and build the ROM
    empty. Nothing downstream complains. The composer ran on meaningless r for
    a long time before a diagnostic LED caught it.
    """
    n = 1 << addr_bits
    with open(path, 'w') as f:
        f.write("""`timescale 1ns / 1ns

//
// Sweep index -> r (Q3.15) and the matching Julia constant c = r(2-r)/4 (Q4.14).
//
// The logistic map is conjugate to z <- z^2 + c, so the music and the picture
// are one parameter family seen two ways, and they cannot drift apart if they
// come out of the same word: r=3 gives c=-0.75, the edge of the main cardioid;
// r=4 gives c=-2, the tip of the antenna.
//
// A table rather than an accumulator, so the board visits exactly the r values
// the model rendered the preview with. With a chaotic map that is not
// pedantry - two sweeps differing in one least-significant bit are different
// music within a few dozen notes.
//
// GENERATED by tools/music_model.py - do not edit.
//
module sweep_rom (
	input				clk,
	input		[%d : 0]	addr,

	output	reg	[17 : 0]	r_val,
	output	reg	[17 : 0]	c_re
);

	(* ram_style = "block" *)
	reg	[35 : 0]	rom [0 : %d];		// {c, r}

	integer i;
	initial begin
		for(i = 0; i < %d; i = i + 1) rom[i] = 36'd0;
""" % (addr_bits - 1, n - 1, n))
        for i, (r, c) in enumerate(zip(rvals, cvals)):
            # Pack the number; do not concatenate the text. Two %05X fields is
            # ten hex digits - forty bits - in a thirty-six bit literal, and
            # Verilog quietly drops the top four. r survived in the low bits so
            # the music kept playing while the Julia constant came out mangled
            # and the main panel of the screen went black.
            f.write("\t\trom[%d] = 36'h%09X;\n" % (i, (c << 18) | r))
        f.write("""	end

	reg	[35 : 0]	q;
	always@(posedge clk)begin
		q     <= rom[addr];
		r_val <= q[17 : 0];
		c_re  <= q[35 : 18];
	end

endmodule
""")
    print('wrote %s: %d entries' % (path, len(rvals)))


def emit_note_rom(path):
    with open(path, 'w') as f:
        f.write('// scale degree -> 32-bit phase increment at %d Hz (generated)\n' % SR)
        for d in range(N_DEGREES):
            f.write('%08X\n' % phase_inc(note_hz(d)))
        for _ in range(32 - N_DEGREES):
            f.write('00000000\n')
    print('wrote', path)


if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    docs = os.path.join(here, '..', 'docs')
    src  = os.path.join(here, '..', 'eda_proj', 'src')
    os.makedirs(docs, exist_ok=True)

    write_wav(os.path.join(docs, 'preview.wav'), render_audio())

    # The board shows the trajectory, not the attractor - see the two
    # functions for why. The attractor render is kept alongside it so the
    # difference stays visible in the repository.
    bmp = trajectory_bitmap()
    save_diagram_png(bmp, os.path.join(docs, 'bifurcation.png'))
    emit_bifur_rom(bmp, os.path.join(src, 'bifur_rom.vh'))
    save_diagram_png(attractor_bitmap(), os.path.join(docs, 'attractor.png'))

    # The screen as the board draws it. Note 275 is the period-3 window, the
    # one moment in the sweep where chaos gives way to a clear three-note
    # figure - the most telling place to freeze the playhead.
    save_screen_png(bmp, os.path.join(docs, 'screen.png'), 275)
    emit_wave_rom(os.path.join(src, 'wave_rom.vh'))
    # r_rom.vh has no reader in the build - the table is compiled into
    # sweep_rom.v - but tools/hw_check.py needs the same numbers in a form it
    # can parse, and emitting both from one list is what keeps them equal.
    emit_r_rom(os.path.join(src, 'r_rom.vh'))

    # r and its Julia constant come out of one table - see emit_sweep_rom.
    rvals = [sweep_r(i) & 0x3FFFF for i in range(SWEEP_TICKS)]
    cvals = []
    for i in range(SWEEP_TICKS):
        r = sweep_r(i) / ONE
        cvals.append(int(round(r * (2.0 - r) / 4.0 * (1 << 14))) & 0x3FFFF)
    emit_sweep_rom(os.path.join(src, 'video-misc', 'sweep_rom.v'), rvals, cvals)

    emit_note_rom(os.path.join(src, 'note_rom.vh'))
