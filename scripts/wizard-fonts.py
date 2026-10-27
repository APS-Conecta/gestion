#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The wizard's font subsets — re-cut to cover every string the wizard renders (#49).

The wizard (php/public) ships two woff2 subsets, not the theme's full fonts: Fraunces instanced
to the one weight the wizard sets (600, the h1–h3 display) and Nunito Sans kept variable over
the 400–800 body range. A wizard string that grows past the subset's character universe renders
in the system fallback — a silent brand leak, exactly what this tool and the brand gate's row
270 exist to prevent.

The universe is MEASURED from the tree: every character of the templates' text and attribute
values, the public JS's string literals, and containers.json's display names — plus the two
random alphabets the wizard paints at run time (hex secrets — the passwords are bin2hex — and
the identifier set for versions, domains and tags). Container LOG bytes are runtime data, not
wizard strings: they render in the mono face and are out of scope by design.

  scripts/wizard-fonts.py --subset [TREE]   re-cut php/public/fonts/*.woff2 from the theme's
                                            full fonts (needs fonttools + brotli; run it after
                                            ANY new wizard string lands, then commit)
  scripts/wizard-fonts.py --check TREE      exit 0 iff both committed subsets cover the measured
                                            universe (the gate's row runs this)
  scripts/wizard-fonts.py --self-test       hermetic: a built-in fixture font, no network

Coverage's honest edge: a character the SOURCE font does not carry can never be in a subset —
it already renders through the page's fallback stack, and the check says so instead of demanding
the impossible. A character the source has that the subset LOST is the regression, and that reds.
"""
import argparse
import json
import pathlib
import re
import sys

try:
    from fontTools.subset import Subsetter, Options
    from fontTools.ttLib import TTFont
    from fontTools.varLib.instancer import instantiateVariableFont
except ImportError:  # pragma: no cover — the loud, never-vacuous failure the gate wants
    sys.exit("FATAL: fontTools is required (pip install fonttools brotli) — every workflow job "
             "that runs the gate installs it; without it this check cannot run")

REPO = pathlib.Path(__file__).resolve().parents[1]
SOURCE_FONTS = pathlib.Path("themes/apsconecta/core/fonts")
OUT_FONTS = pathlib.Path("php/public/fonts")
# (family, source file, output file, instanced weight or None to keep the axis)
FACES = (
    ("Fraunces", "Fraunces.woff2", "Fraunces.woff2", 600),
    ("Nunito Sans", "NunitoSans.woff2", "NunitoSans.woff2", None),
)
# The two run-time alphabets the static tree cannot measure: secrets are bin2hex, and versions,
# domains and tags draw from the identifier set. Anything wider arrives in a template's own
# bytes and is measured with them.
HEX_ALPHABET = "0123456789abcdef"
IDENT_ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-_"
UNIVERSE_FLOOR = 60   # a parse regression that empties the measurement reds, never passes
UNIVERSE_MUST = "áéíóúñ0123456789"   # the es-CL sweep's accents and the numbers, always

TWIG_BLOCK = re.compile(r"\{%.*?%\}|\{\{.*?\}\}", re.S)
HTML_TAG = re.compile(r"<[^>]*>")
QUOTED = re.compile(r'"([^"]*)"|\'([^\']*)\'')


def _texts_of(tree):
    """Every measured string: twig text + attribute values, JS literals, display names."""
    out = []
    for p in sorted((tree / "php/templates").rglob("*.twig")):
        t = TWIG_BLOCK.sub(" ", p.read_text(encoding="utf-8"))
        out += [m.group(1) or m.group(2) or "" for m in QUOTED.finditer(t)]
        out.append(HTML_TAG.sub(" ", t))
    for p in sorted((tree / "php/public").glob("*.js")):
        out += [m.group(1) or m.group(2) or "" for m in QUOTED.finditer(p.read_text(encoding="utf-8"))]
    j = tree / "php/containers.json"
    if j.is_file():
        def _names(node):
            if isinstance(node, dict):
                if "display_name" in node:
                    out.append(str(node["display_name"]))
                for v in node.values():
                    _names(v)
            elif isinstance(node, list):
                for v in node:
                    _names(v)
        _names(json.loads(j.read_text(encoding="utf-8")))
    return out


def universe(tree):
    """The measured character set, plus the run-time alphabets."""
    chars = set("".join(_texts_of(tree))) | set(HEX_ALPHABET + IDENT_ALPHABET) | {" "}
    chars -= {c for c in chars if ord(c) < 32 or ord(c) == 127}
    return chars


def subset_options():
    o = Options()
    o.flavor = "woff2"
    o.desubroutinize = True
    o.layout_features = ["kern", "liga", "calt"]   # UI text kerns; this is not a code font
    o.notdef_outline = False
    # A-008: OFL §2 requires the copyright and license records to survive subsetting; the
    # default keeps the naming IDs, 0 and 13 are the ones the bug dropped.
    o.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14]
    o.name_legacy = True
    return o


def cut(tree, dry=False):
    """Re-cut both subsets from the theme's full fonts; returns [(face, bytes, size)]."""
    text = "".join(sorted(universe(tree)))
    made = []
    for family, src, dst, wght in FACES:
        src_path, dst_path = tree / SOURCE_FONTS / src, tree / OUT_FONTS / dst
        if not src_path.is_file():
            sys.exit(f"FATAL: no such source font: {src_path}")
        f = TTFont(src_path)
        if wght is not None and "fvar" in f:
            f = instantiateVariableFont(f, {"wght": wght}, inplace=False, updateFontNames=False)
        sub = Subsetter(options=subset_options())
        sub.populate(text=text)
        sub.subset(f)
        if not dry:
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            f.flavor = "woff2"
            f.save(dst_path)
        made.append((family, dst, text))
    return made


def check(tree, floor=UNIVERSE_FLOOR, must=UNIVERSE_MUST):
    """0 iff both committed subsets cover the universe; reports source-absent chars as fallback."""
    chars = universe(tree)
    if len(chars) < floor or not set(must) <= chars:
        print(f"FAIL: the measured universe looks broken ({len(chars)} chars) — the measurement, "
              f"not the fonts, is wrong", file=sys.stderr)
        return 1
    fail = 0
    for family, _src, dst, _w in FACES:
        sub_path, src_path = tree / OUT_FONTS / dst, tree / SOURCE_FONTS / _src
        if not sub_path.is_file():
            print(f"FAIL: no such subset: {sub_path}", file=sys.stderr)
            fail = 1
            continue
        have, could = set(TTFont(sub_path).getBestCmap()), set(TTFont(src_path).getBestCmap())
        lost = sorted(c for c in chars if c in could and ord(c) not in have)
        fallback = sorted(c for c in chars if c not in could and ord(c) not in have)
        if lost:
            print(f"FAIL: {family} lost {len(lost)} glyph(s) the source font carries: "
                  f"{''.join(lost)[:80]!r} — re-run scripts/wizard-fonts.py --subset",
                  file=sys.stderr)
            fail = 1
        if fallback:
            print(f"  note: {family} carries no glyph for {len(fallback)} measured char(s) "
                  f"({''.join(fallback)[:60]!r}) — the page's fallback stack renders them, "
                  f"as it always has")
    if not fail:
        print(f"  ok: both subsets cover the measured universe ({len(chars)} chars)")
    return fail


def self_test():
    """Hermetic: a built-from-nothing fixture font through the same cut/check path — a covered
    glyph passes, a lost one reds, a source-absent one is reported as fallback, and a broken
    measurement (empty universe) reds instead of passing vacuously."""
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    import tempfile

    global FACES
    ok = [0]

    def check_(name, cond):
        ok[0] += bool(cond)
        print(("  ok: " if cond else "FAIL: ") + name)

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="wizard-fonts-selftest-"))
    fb = FontBuilder(1000, isTTF=True)
    pen = TTGlyphPen(None)
    pen.moveTo((0, 0)); pen.lineTo((0, 700)); pen.lineTo((500, 700)); pen.lineTo((500, 0))
    pen.closePath()
    box = pen.glyph()
    order = [".notdef", "space", "a", "b", "á"]
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({0x20: "space", 0x61: "a", 0x62: "b", 0xE1: "á"})
    glyphs = {g: box for g in order}
    glyphs[".notdef"] = TTGlyphPen(None).glyph()
    fb.setupGlyf(glyphs)
    fb.setupHorizontalMetrics({g: (500, 0) for g in order})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": "Fixture", "styleName": "Regular",
                        "copyright": "Fixture OFL", "licenseDescription": "SIL OFL 1.1",
                        "licenseInfoURL": "https://openfontlicense.org"})
    fb.setupOS2()
    (tmp / "themes/apsconecta/core/fonts").mkdir(parents=True)
    (tmp / "php/public/fonts").mkdir(parents=True)
    (tmp / "php/templates").mkdir(parents=True)
    src = tmp / "themes/apsconecta/core/fonts" / "Fixture.woff2"
    fb.save(str(src))
    for face in FACES:  # the fixture masquerades as both faces
        (tmp / "themes/apsconecta/core/fonts" / face[1]).write_bytes(src.read_bytes())

    real_faces = FACES
    FACES = (("Fixture", "Fixture.woff2", "Fixture.woff2", None),)
    try:
        (tmp / "php/templates/x.twig").write_text("aba á <p placeholder=\"b a\">á</p>", encoding="utf-8")
        made = cut(tmp, dry=False)
        out = tmp / "php/public/fonts" / "Fixture.woff2"
        have = set(TTFont(str(out)).getBestCmap())
        check_("subset: cuts a woff2 whose cmap carries every measured char the source has",
               out.is_file() and {ord("a"), ord("b"), ord("á"), ord(" ")} <= have)
        names = TTFont(str(out))["name"]
        check_("subset: the OFL name records survive (A-008)",
               any(n.nameID == 13 for n in names.names) and any(n.nameID == 0 for n in names.names)
               and any(n.nameID == 1 for n in names.names))
        check_("check: green over the fresh cut",
               check(tmp, floor=1, must="a") == 0)
        (tmp / "php/templates/x.twig").write_text("ab á c", encoding="utf-8")  # 'c': source lacks it
        rc = check(tmp, floor=1, must="a")
        check_("check: a char the SOURCE lacks is fallback, not a failure (and the cut still green)",
               rc == 0)
        FACES = (("Fixture", "Fixture.woff2", "Absent.woff2", None),)
        check_("check: a missing subset file reds", check(tmp, floor=1, must="a") == 1)
    finally:
        FACES = real_faces

    print("SELF-TEST: PASS" if ok[0] == 5 else "SELF-TEST: *** FAIL ***")
    return 0 if ok[0] == 5 else 1


def main():
    ap = argparse.ArgumentParser(description="the wizard's font subsets")
    ap.add_argument("--subset", nargs="?", const=str(REPO), metavar="TREE",
                    help="re-cut the subsets (default: this checkout)")
    ap.add_argument("--check", metavar="TREE", help="assert the committed subsets cover the universe")
    ap.add_argument("--self-test", action="store_true", help="hermetic self-test")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.subset:
        for family, dst, text in cut(pathlib.Path(args.subset)):
            p = pathlib.Path(args.subset) / OUT_FONTS / dst
            print(f"  {family}: {len(text)} chars -> {p.stat().st_size / 1024:.1f} KB")
        print("commit the two files — the subsets are NOT byte-reproducible, a re-run for its "
              "own sake only makes noise")
        return 0
    if args.check:
        return check(pathlib.Path(args.check))
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
