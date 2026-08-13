"""Render the model with one thing changed at a time, to identify by ear.

The board and the model agree sample for sample in hw_check.py, yet the board
sounds as though notes are missing. That means the discrepancy is somewhere the
static comparison cannot see, and the fastest way to narrow it is to find out
WHICH notes are absent. These renders split the piece along the lines that
correspond to actual code paths, so an answer of "it sounds like this one"
points at one place in the RTL:

  at_board_level   everything, at the level the board is running (MIX_SH=3).
                   Compare against this, not against preview.wav - preview is
                   12 dB louder, which on its own can hide the quiet notes.

  bass_only        just the every-fourth notes: octave down, sine wavetable.
                   These take a different path through synth8 - inc is shifted
                   and tbl selects table 0. If what is missing on the board is
                   what you hear here, the bass path is where to look.

  lead_only        everything except the bass notes.

  no_delay         full mix with the ping-pong delay bypassed. The delay adds
                   repeats a sixth of a second later; if the board sounds
                   sparse next to the full mix but right next to this one, the
                   delay line is what is not working.

Run:  python diag_render.py
"""

import os
import struct

import music_model as M


HERE = os.path.dirname(os.path.abspath(__file__))
DOCS = os.path.join(HERE, '..', 'docs')

MIX_SH = 3              # what the board is built with


def render(keep='all', delay=True, secs=M.SWEEP_SECS):
    """The model's voice loop, with one switch. Mirrors render_audio()."""
    per_note = M.SR // M.NOTE_HZ
    total = int(M.SR * secs)
    wave = M.wavetables()

    phase = [0] * M.VOICES
    inc = [0] * M.VOICES
    env = [0] * M.VOICES
    pan = [128] * M.VOICES
    tbl = [1] * M.VOICES

    dl = [0] * M.DELAY_LEN
    dr = [0] * M.DELAY_LEN
    dpos = 0
    lp_l = lp_r = 0

    x = M.ONE // 2
    voice = 0
    note_i = 0
    out = bytearray()

    for n in range(total):
        if n % per_note == 0:
            x = M.logistic_step(x, M.sweep_r(n // per_note))
            deg = ((x * x >> M.FRAC) * M.N_DEGREES) >> M.FRAC
            deg = max(0, min(M.N_DEGREES - 1, deg))
            voice = (voice + 1) % M.VOICES
            note_i += 1
            is_bass = (note_i % M.BASS_EVERY) == 0

            play = (keep == 'all'
                    or (keep == 'bass' and is_bass)
                    or (keep == 'lead' and not is_bass))
            if play:
                inc[voice] = M.phase_inc(M.note_hz(deg))
                if is_bass:
                    inc[voice] >>= 1
                env[voice] = 1 << 16
                tbl[voice] = 0 if is_bass else 1
                pan[voice] = M.PAN_MIN + ((x * (M.PAN_MAX - M.PAN_MIN)) >> M.FRAC)

        acc_l = acc_r = 0
        for v in range(M.VOICES):
            if env[v]:
                phase[v] = (phase[v] + inc[v]) & 0xFFFFFFFF
                s = wave[tbl[v]][phase[v] >> (M.PHASE_BITS - M.WAVE_BITS)]
                a = (s * env[v]) >> 16
                acc_l += (a * (255 - pan[v])) >> 8
                acc_r += (a * pan[v]) >> 8
                env[v] -= (env[v] >> M.DECAY_SH) + 1
                if env[v] < 0:
                    env[v] = 0

        dry_l = acc_l >> MIX_SH
        dry_r = acc_r >> MIX_SH

        if not delay:
            out += struct.pack('<hh', M.clamp16(dry_l), M.clamp16(dry_r))
            continue

        echo_l, echo_r = dl[dpos], dr[dpos]
        lp_l += (echo_r - lp_l) >> M.DAMP_SH
        lp_r += (echo_l - lp_r) >> M.DAMP_SH
        dl[dpos] = M.clamp16(dry_l + ((lp_l * M.FEEDBACK) >> 8))
        dr[dpos] = M.clamp16(dry_r + ((lp_r * M.FEEDBACK) >> 8))
        dpos = (dpos + 1) % M.DELAY_LEN
        out += struct.pack('<hh',
                           M.clamp16(dry_l + ((echo_l * M.WET) >> 8)),
                           M.clamp16(dry_r + ((echo_r * M.WET) >> 8)))

    return bytes(out)


if __name__ == '__main__':
    for name, kw in (('at_board_level', dict(keep='all')),
                     ('bass_only',      dict(keep='bass')),
                     ('lead_only',      dict(keep='lead')),
                     ('no_delay',       dict(keep='all', delay=False))):
        M.write_wav(os.path.join(DOCS, 'diag_%s.wav' % name), render(**kw))
