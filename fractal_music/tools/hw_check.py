"""Re-implement what the RTL actually does, and diff it against music_model.py.

There is no simulator for this board, so the way to find out whether the FPGA
is playing the piece the preview WAV promises is to write the hardware's
semantics out a second time - reading the same ROM files the bitstream was
built from - and compare note for note and sample for sample.

This is not a second model of the music. It is a transcription of the Verilog,
deliberately literal: fixed widths, truncation where the RTL truncates, and the
same order of operations. Where it disagrees with music_model.py, one of the two
is wrong, and the disagreement says where to look.

Run:  python hw_check.py
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import music_model as M


SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                   '..', 'eda_proj', 'src')


def load_vh(name, count):
    """Read a $readmemh file the way the synthesiser's initial block would."""
    vals = []
    with open(os.path.join(SRC, name)) as f:
        for line in f:
            line = line.split('//')[0].strip()
            if line:
                vals.append(int(line, 16))
    return vals[:count]


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


def sat16(v):
    return 32767 if v > 32767 else (-32768 if v < -32768 else v)


# --------------------------------------------------------------- the composer
def hw_notes(ticks=320):
    """logistic_seq.v, states 0..5. Returns one tuple per note."""
    r_rom = load_vh('r_rom.vh', 512)

    ONE = 1 << M.FRAC
    x = ONE >> 1                        # the reset value in the RTL
    note_i = 0
    out = []

    for k in range(ticks):
        r_val = r_rom[k] & 0x3FFFF      # 18-bit ROM word

        # states 1..4, ITERS times round; only the last becomes a note
        for _ in range(M.ITERS_PER_NOTE):
            prod = x * (ONE - x)
            t_term = (prod >> M.FRAC) & 0x3FFFF
            prod = r_val * t_term
            x = (prod >> M.FRAC) & 0x3FFFF
            if x >= ONE:                # the clamp in logistic_seq.v
                x = ONE - 1

        # s4/s5: degree from x squared, pan from x
        sq = (x * x >> M.FRAC) & 0x3FFFF
        degree = (sq * M.N_DEGREES) >> M.FRAC
        if degree > M.N_DEGREES - 1:
            degree = M.N_DEGREES - 1
        pan = (M.PAN_MIN + ((x * (M.PAN_MAX - M.PAN_MIN)) >> M.FRAC)) & 0xFF
        is_bass = ((note_i + 1) & 3) == 0
        note_i = (note_i + 1) & 0xFF

        out.append((x, degree, is_bass, pan))
    return out


def model_notes(ticks=320):
    """The same sequence as music_model.render_audio() produces it."""
    ONE = M.ONE
    x = ONE // 2
    note_i = 0
    out = []
    for k in range(ticks):
        r = M.sweep_r(k)            # the one definition; see music_model.py
        for _ in range(M.ITERS_PER_NOTE):
            x = M.logistic_step(x, r)
        deg = ((x * x >> M.FRAC) * M.N_DEGREES) >> M.FRAC
        deg = max(0, min(M.N_DEGREES - 1, deg))
        note_i += 1
        is_bass = (note_i % M.BASS_EVERY) == 0
        pan = M.PAN_MIN + ((x * (M.PAN_MAX - M.PAN_MIN)) >> M.FRAC)
        out.append((x, deg, is_bass, pan))
    return out


# --------------------------------------------------------------- the synth
def hw_render(mix_sh, seconds=None):
    """synth8.v + pingpong.v, driven by the composer above."""
    note_rom = load_vh('note_rom.vh', 32)
    wave_vh = load_vh('wave_rom.vh', 512)
    wave = [s16(w) for w in wave_vh]

    notes = hw_notes()
    per_note = M.SR // M.NOTE_HZ
    total = per_note * len(notes) if seconds is None else int(M.SR * seconds)

    phase = [0] * 8
    inc = [0] * 8
    env = [0] * 8
    pan = [128] * 8
    tbl = [1] * 8
    next_v = 0                          # the RTL starts at 0, not 1

    DL = 7892                           # pingpong DELAY_LEN
    mem_l = [0] * DL
    mem_r = [0] * DL
    pos = 0
    lp_l = lp_r = 0

    out = []
    for n in range(total):
        if n % per_note == 0:
            _, degree, is_bass, p = notes[(n // per_note) % len(notes)]
            v = next_v
            next_v = (next_v + 1) & 7
            ni = note_rom[degree]
            inc[v] = (ni >> 1) if is_bass else ni    # {1'b0, note_inc[31:1]}
            env[v] = 1 << 16                         # the phase carries over
            pan[v] = p
            tbl[v] = 0 if is_bass else 1

        acc_l = acc_r = 0
        for v in range(8):
            if env[v] == 0:                          # ph_we is gated on env
                continue
            phase[v] = (phase[v] + inc[v]) & 0xFFFFFFFF
            s = wave[(tbl[v] << 8) | (phase[v] >> 24)]
            a = (s * env[v]) >> 16
            acc_l += (a * (255 - pan[v])) >> 8
            acc_r += (a * pan[v]) >> 8
            dec = (env[v] >> M.DECAY_SH) + 1
            env[v] = env[v] - dec if env[v] > dec else 0

        dry_l = sat16(acc_l >> mix_sh)
        dry_r = sat16(acc_r >> mix_sh)

        rq_l, rq_r = mem_l[pos], mem_r[pos]
        wet_l = (rq_l * M.WET) >> 8
        wet_r = (rq_r * M.WET) >> 8
        dif_l = rq_r - lp_l
        dif_r = rq_l - lp_r
        lp_l = s16(lp_l + (dif_l >> M.DAMP_SH))      # the RTL keeps lp 16-bit
        lp_r = s16(lp_r + (dif_r >> M.DAMP_SH))
        fb_l = (lp_l * M.FEEDBACK) >> 8
        fb_r = (lp_r * M.FEEDBACK) >> 8
        out.append((sat16(dry_l + wet_l), sat16(dry_r + wet_r)))
        mem_l[pos] = sat16(dry_l + fb_l)
        mem_r[pos] = sat16(dry_r + fb_r)
        pos = 0 if pos == DL - 1 else pos + 1

    return out


if __name__ == '__main__':
    hw = hw_notes()
    md = model_notes()

    bad = [(i, h, m) for i, (h, m) in enumerate(zip(hw, md)) if h != m]
    print('notes compared : %d' % len(hw))
    print('notes differing: %d' % len(bad))
    if bad:
        print('\nfirst 12 disagreements   (x, degree, is_bass, pan)')
        for i, h, m in bad[:12]:
            print('  note %3d  hw=%-28s model=%s' % (i, h, m))
    else:
        print('the composer agrees exactly')

    print('\ndegree histogram')
    for src, name in ((hw, 'hw   '), (md, 'model')):
        h = [0] * M.N_DEGREES
        for e in src:
            h[e[1]] += 1
        print('  %s %s' % (name, h))

    # ---- the whole chain, against what the preview WAV actually contains ----
    import struct
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
    n = int(M.SR * secs)

    hwa = hw_render(M.MIX_SH, seconds=secs)
    wav = open(os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            '..', 'docs', 'preview.wav'), 'rb').read()[44:]
    ref = struct.unpack('<%dh' % (2 * n), wav[:4 * n])
    ref = list(zip(ref[0::2], ref[1::2]))

    bad = [i for i, (a, b) in enumerate(zip(hwa, ref)) if a != b]
    print('\nfull chain over %.1f s (%d samples), MIX_SH=%d' % (secs, n, M.MIX_SH))
    print('  samples differing: %d' % len(bad))
    if bad:
        worst = max(abs(hwa[i][0] - ref[i][0]) for i in bad)
        print('  first at %d (%.2f s), largest error %d LSB' %
              (bad[0], bad[0] / float(M.SR), worst))
    else:
        print('  the board and the preview are the same piece, sample for sample')
