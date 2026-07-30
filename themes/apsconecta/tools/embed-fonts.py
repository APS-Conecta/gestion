#!/usr/bin/env python3
"""Subset the theme's brand fonts to the glyphs each lockup actually uses, and embed them in the
SVG as data-URI @font-face rules.

Why: an SVG served as an image (background-image / <img>) is an isolated document. It cannot reach
the @font-face rules in server.css, so `font-family="Fraunces, Georgia, serif"` falls through to
Georgia on Windows and to whatever fc-match returns elsewhere. A font declared INSIDE the SVG with
a data: URL is not an external fetch, so it survives that isolation.
"""
import base64, io, pathlib, re
from fontTools.ttLib import TTFont
from fontTools.subset import Subsetter, Options
from fontTools.varLib.instancer import instantiateVariableFont

REPO = pathlib.Path("/home/dani/Descargas/CESFAM-Intranet/gestion")
FONTS = REPO / "themes/apsconecta/core/fonts"

def subset_b64(woff2, text, wght):
    """One static instance at `wght`, cut down to `text`, re-compressed as woff2, base64."""
    f = TTFont(woff2)
    if "fvar" in f:
        f = instantiateVariableFont(f, {"wght": wght}, inplace=False, updateFontNames=False)
    opts = Options()
    opts.flavor = "woff2"
    opts.desubroutinize = True
    opts.layout_features = ["kern", "liga", "calt"]   # keep kerning: this is a wordmark
    opts.notdef_outline = False
    sub = Subsetter(options=opts)
    sub.populate(text=text)
    sub.subset(f)
    # `head.modified` is stamped with the current time on save; carry the source font's value so at
    # least the clock stops leaking into the art. The output is still NOT byte-reproducible —
    # measured 2026-07-30: two subsets of the same input in the same process differ before
    # compression is involved. So re-run this only when the art or the fonts change; a re-run for
    # its own sake produces a diff that means nothing.
    f["head"].modified = TTFont(woff2)["head"].modified
    buf = io.BytesIO()
    f.flavor = "woff2"
    f.save(buf)
    return base64.b64encode(buf.getvalue()).decode(), len(buf.getvalue())

def style_block(faces):
    rules = []
    for family, weight, b64 in faces:
        rules.append(
            f'    @font-face {{ font-family:"{family}"; font-style:normal; font-weight:{weight};\n'
            f'      src:url("data:font/woff2;base64,{b64}") format("woff2"); }}')
    return "  <style>\n" + "\n".join(rules) + "\n  </style>\n"

def embed(src, dst, faces_spec, header_comment):
    # Idempotent: drop any face this script embedded before, so re-running (or running with
    # src == dst, which is how logo.svg is updated in place) yields the same bytes as a first run.
    svg = re.sub(r"\s*<style>.*?</style>\n?", "\n", src.read_text(), flags=re.S)
    texts = re.findall(r"<text[^>]*>(.*?)</text>", svg, re.S)
    faces = []
    for family, weight, woff2, chars in faces_spec:
        b64, size = subset_b64(FONTS / woff2, chars, weight)
        faces.append((family, weight, b64))
        print(f"    {family} {weight}: {chars!r} -> {size/1024:.1f} KB subset")
    # The style block goes first inside <svg>, before <defs>/<g>, so the faces exist before use.
    out = svg.replace("<defs>", style_block(faces) + "  <defs>", 1)
    if "<style>" not in out:                      # no <defs> in this file
        out = re.sub(r"(<svg[^>]*>\n)", r"\1" + style_block(faces), out, count=1)
    # Drop the OS-font fallbacks: they were the bug. The embedded face is the only one that can win.
    out = out.replace('font-family="Fraunces, Georgia, serif"', 'font-family="Fraunces"')
    out = re.sub(r'font-family="&#39;Nunito Sans&#39;[^"]*"', 'font-family="Nunito Sans"', out)
    out = out.replace("<svg ", header_comment + "<svg ", 1) if header_comment else out
    dst.write_text(out)
    print(f"  {dst.name}: {len(out)/1024:.1f} KB  (texts: {[t.strip() for t in texts]})")

if __name__ == "__main__":
    # Run this after ANY change to a lockup's text or to the brand fonts, then commit the SVG.
    # Needs fontTools + brotli on the host (`pip install fonttools brotli`); nothing in the stack
    # or in CI runs it. scripts/test.sh fails if a theme SVG has <text> without an embedded face,
    # which is what stops new art shipping with the Georgia fallback again (BUGS.md B-011).
    #
    #   python3 themes/apsconecta/tools/embed-fonts.py
    #
    # Source of the header lockup is the brand kit, per AGENTS.md: art is designed there, and only
    # the server-ready result lives here.
    KIT = REPO.parent / "APS Conecta Nextcloud"
    LOGO = REPO / "themes/apsconecta/core/img/logo"
    print("header lockup (tiled, from the kit):")
    embed(KIT / "logo-header.svg", LOGO / "logo-header.svg",
          [("Fraunces", 600, "Fraunces.woff2", "APS Conecta"),
           ("Nunito Sans", 700, "NunitoSans.woff2", "Gestión")], "")
    print("login lockup (tile-free, the theme's own):")
    embed(LOGO / "logo.svg", LOGO / "logo.svg",
          [("Fraunces", 600, "Fraunces.woff2", "APS Conecta"),
           ("Nunito Sans", 700, "NunitoSans.woff2", "GESTIÓN")], "")
