#!/usr/bin/env python3
"""
Render what the HDMI text console actually shows, as a 1920x1080 PNG.

A photograph of the screen picks up reflections and moire; this draws the same
thing from the same inputs instead - the glyphs come from make_font.py, and the
text is lifted straight out of fw/main.c, so the picture cannot drift away from
the firmware. The layout rules (120x33 grid, wrap at the right edge) mirror
scr_putc() in main.c.
"""
import os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from make_font import render_glyphs, write_png, W, H, FIRST, LAST

COLS, ROWS = 120, 33
SCALE = 2                       # the hardware draws 8x16 glyphs at 2x
BG = (0x10, 0x10, 0x18)
FG = (0xE8, 0xE8, 0xF0)

# Enough heartbeat to show the wrap: one full line and part of the next.
HEARTBEAT = 200


def banner_from_source(path):
    """Concatenate the string literals main.c hands to puts_both()."""
    src = open(path, encoding="utf-8").read()
    text = ""
    for call in re.finditer(r"puts_both\s*\((.*?)\);", src, re.S):
        for lit in re.findall(r'"((?:\\.|[^"\\])*)"', call.group(1)):
            text += (lit.replace("\\n", "\n").replace("\\r", "\r")
                        .replace('\\"', '"').replace("\\\\", "\\"))
    if not text:
        raise SystemExit("no puts_both() text found in " + path)
    return text


def lay_out(text):
    """scr_putc() from main.c: wrap at the right edge, no scrolling."""
    grid = [[" "] * COLS for _ in range(ROWS)]
    row = col = 0

    def newline():
        nonlocal row, col
        col = 0
        row = row + 1 if row + 1 < ROWS else 0

    for ch in text:
        if ch == "\r":
            continue
        if ch == "\n":
            newline()
            continue
        if col >= COLS:
            newline()
        grid[row][col] = ch
        col += 1
    return grid, row, col


def draw(grid, glyphs, path):
    pw, ph = COLS * W * SCALE, ROWS * H * SCALE
    rows = [bytearray(bytes(BG) * pw) for _ in range(ph)]

    for r in range(ROWS):
        for c in range(COLS):
            code = ord(grid[r][c])
            if not (FIRST <= code <= LAST) or code == 0x20:
                continue
            g = glyphs[code - FIRST]
            ox, oy = c * W * SCALE, r * H * SCALE
            for y in range(H):
                if not g[y]:
                    continue
                for x in range(W):
                    if g[y] & (0x80 >> x):
                        for dy in range(SCALE):
                            line = rows[oy + y * SCALE + dy]
                            for dx in range(SCALE):
                                o = (ox + x * SCALE + dx) * 3
                                line[o:o + 3] = bytes(FG)

    # 1080 is not a whole number of 32-pixel cells; the hardware leaves the
    # last 24 lines blank, so the image has to as well.
    while len(rows) < 1080:
        rows.append(bytearray(bytes(BG) * pw))
    rows = rows[:1080]

    write_png(path, pw, 1080, [bytes(r) for r in rows])
    print("wrote %s: %dx%d" % (path, pw, 1080))


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    text = banner_from_source(os.path.join(here, "..", "fw", "main.c"))
    text += "*" * HEARTBEAT
    grid, _, _ = lay_out(text)
    docs = os.path.join(here, "..", "docs")
    os.makedirs(docs, exist_ok=True)
    draw(grid, render_glyphs(), os.path.join(docs, "hdmi_console.png"))
