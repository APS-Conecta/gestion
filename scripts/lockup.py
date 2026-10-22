#!/usr/bin/env python3
"""The wizard's banner lockup as outlines — rewrites the wordmark of php/public/img/logo.svg.

Why paths: the templates draw the lockup by <use href="img/logo.svg#wordmark">. A <use> clone does
not carry the external SVG's own @font-face, so live <text> falls back to whatever the page can
load (FINDINGS R20). Outlines need no font at all.

Authoring tool, run by hand when the lockup's words or the brand fonts change. OSS: HarfBuzz shapes
each line the way a browser would (kerning, and Fraunces' WONK substitutions such as n → n.alt);
fontTools draws the shaped glyphs from the variable font pinned at the same axes. It runs on the
070 logo or on its own earlier output. The fonts are the theme's full variable brand fonts — the
wizard ships only subsets:

    pip install fonttools brotli uharfbuzz
    python3 scripts/lockup.py php/public/img/logo.svg \\
        --fonts themes/apsconecta/core/fonts
"""

import argparse
import hashlib
import io
import pathlib
import re

import uharfbuzz as hb
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

# One row per line of the wordmark: text, font file, pinned axes, size, letter-spacing, centre x,
# baseline y, fill — 070's baselines, sizes and fills; the second line, its spacing and the
# centring (without the trailing letter-spacing) are this tool's.
LINES = (
    (
        "APS Conecta",
        "Fraunces.woff2",
        {"wght": 600, "opsz": 21, "SOFT": 0, "WONK": 1},
        21.0,
        0.0,
        71.0,
        84.0,
        "#5315a8",
    ),
    (
        "GESTIÓN AIO",
        "NunitoSans.woff2",
        {"wght": 700, "wdth": 100, "opsz": 10.5, "YTLC": 500},
        10.5,
        1.6,
        71.0,
        96.5,
        "#485363",
    ),
)
COMMENT = re.compile(
    r"The wordmark is (?:live text over embedded\n.*?never depends on page fonts\.|outlines \(scripts/lockup\.py,\n.*?\.woff2 sha256 [0-9a-f]+\.)",
    re.S,
)


def line_path(fontfile, axes, text, size, spacing, cx, baseline):
    raw = TTFont(fontfile)
    order = (
        raw.getGlyphOrder()
    )  # the instancer keeps the glyph order: HarfBuzz ids map onto it
    raw.flavor = None
    sfnt = io.BytesIO()
    raw.save(sfnt)
    shaper = hb.Font(hb.Face(sfnt.getvalue()))
    shaper.set_variations(axes)
    buf = hb.Buffer()
    buf.add_str(text)
    buf.guess_segment_properties()
    hb.shape(shaper, buf)
    font = instantiateVariableFont(TTFont(fontfile), axes, inplace=False)
    glyphs, scale = font.getGlyphSet(), size / font["head"].unitsPerEm
    placed, x = [], 0.0
    for info, pos in zip(buf.glyph_infos, buf.glyph_positions):
        placed.append(
            (order[info.codepoint], x + pos.x_offset * scale, pos.y_offset * scale)
        )
        x += pos.x_advance * scale + spacing
    width = x - spacing  # CSS letter-spacing trails the last glyph; centre without it
    left = cx - width / 2
    pen = SVGPathPen(glyphs, ntos=lambda v: f"{v:.2f}".rstrip("0").rstrip("."))
    for name, gx, gy in placed:
        glyphs[name].draw(
            TransformPen(pen, (scale, 0, 0, -scale, left + gx, baseline - gy))
        )
    return pen.getCommands(), width


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("svg", type=pathlib.Path)
    ap.add_argument("--fonts", type=pathlib.Path, required=True)
    a = ap.parse_args()
    svg = a.svg.read_text(encoding="utf-8")
    paths = []
    for text, ff, axes, size, spacing, cx, base, fill in LINES:
        d, width = line_path(a.fonts / ff, axes, text, size, spacing, cx, base)
        assert width < 138, (
            f"{text!r} is {width:.1f} wide — it no longer fits the 142-unit viewBox"
        )
        paths.append(
            f'    <path aria-hidden="true" fill="{fill}" d="{d}"></path>  <!-- {text} -->'
        )
        print(f"  {text}: {width:.1f} units wide")
    word = '  <g id="wordmark">\n' + "\n".join(paths) + "\n  </g>\n"
    svg, n = re.subn(r'  <g id="wordmark">\n.*?\n  </g>\n', word, svg, flags=re.S)
    assert n == 1, "no single wordmark group in the svg"
    svg = re.sub(
        r"\s*<style>.*?</style>", "", svg, flags=re.S
    )  # the embedded fonts are dead bytes now
    svg, n = re.subn(
        r'aria-label="[^"]*"', 'aria-label="APS Conecta Gestión AIO"', svg, count=1
    )
    assert n == 1, "no aria-label on the svg"
    sums = ", ".join(
        f"{ff} sha256 {hashlib.sha256((a.fonts / ff).read_bytes()).hexdigest()[:16]}"
        for ff in sorted({line[1] for line in LINES})
    )
    note = (
        "The wordmark is outlines (scripts/lockup.py,\n       from the theme's brand fonts): a <use> clone"
        " cannot carry fonts embedded in this file, so live\n       text fell back to whatever the page"
        f" loaded (R20). Outlines need no font at all.\n       Drawn from {sums}."
    )
    svg, n = COMMENT.subn(lambda _m: note, svg)
    assert n == 1, (
        "the lockup comment drifted from 070's or this tool's own — update COMMENT"
    )
    a.svg.write_text(svg, encoding="utf-8")


if __name__ == "__main__":
    main()
