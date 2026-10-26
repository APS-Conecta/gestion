#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The wizard's brand-token block — projects themes/apsconecta/core/css/tokens.css into
php/public/style.css (#49).

Why a projection: the wizard's origin is the mastercontainer, and the token file lives in the
suite's theme — the wizard cannot fetch it at run time. So the wizard's stylesheet carries a
GENERATED block with the same declarations, committed like every other byte, and `--check`
proves it byte-equal to the token file's own block: the ONE source stays the token file, the
wizard's copy is a projection, and a value that drifts between the two reds the brand gate's
row 270 (which runs this script in --check mode).

  scripts/brand-tokens.py --wizard [CSS]   rewrite the generated block (default
                                           php/public/style.css)
  scripts/brand-tokens.py --check TREE     exit 0 iff TREE's wizard block is the byte
                                           projection of TREE's token file
  scripts/brand-tokens.py --self-test      hermetic, tmp trees only

Standard library only, Python 3.10 (Ubuntu 22.04) — same rule as apps.py beside it.
The TOKENS are the file's; this tool owns no colour, no font, no value.
"""
import argparse
import pathlib
import re
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[1]
TOKENS = "themes/apsconecta/core/css/tokens.css"
WIZARD_CSS = "php/public/style.css"
BEGIN = "aps-brand-tokens begin"
END = "aps-brand-tokens end"

DECL = re.compile(r"^\s*(--aps-[a-z0-9-]+)\s*:\s*([^;]+);\s*(?:/\*.*?\*/)?\s*$")


def parse_tokens(css_text):
    """[(name, value)] in file order — every --aps-* declaration in the token file's :root."""
    out = []
    for line in css_text.splitlines():
        m = DECL.match(line)
        if m:
            out.append((m.group(1), m.group(2).strip()))
    return out


def block(tokens):
    """The generated block, byte-exact: what --wizard writes and --check expects."""
    lines = [
        f"/* {BEGIN} — GENERATED from {TOKENS}",
        "   by scripts/brand-tokens.py; do not edit by hand (row 270 proves the projection). */",
        ":root {",
    ]
    lines += [f"    {name}: {value};" for name, value in tokens]
    lines += ["}", f"/* {END} */"]
    return "\n".join(lines)


def find_block(css_text):
    """The current generated block (a re match) or None — one finder, three callers."""
    return re.search(rf"^/\* {re.escape(BEGIN)} .*$.*?^/\* {re.escape(END)} \*/$",
                     css_text, re.M | re.S)


def project(css_text, tokens):
    """css_text with the generated block replaced (or inserted before the first :root)."""
    have = find_block(css_text)
    if have:
        return css_text[:have.start()] + block(tokens) + css_text[have.end():]
    m = re.search(r"^:root \{", css_text, re.M)
    if not m:
        sys.exit("FATAL: no :root { in the wizard's stylesheet — nowhere to put the token block")
    return css_text[:m.start()] + block(tokens) + "\n\n" + css_text[m.start():]


def read_tokens(tree):
    p = pathlib.Path(tree) / TOKENS
    if not p.is_file():
        sys.exit(f"FATAL: no such file: {p} — the ONE brand token file")
    tokens = parse_tokens(p.read_text(encoding="utf-8"))
    if not tokens:
        sys.exit(f"FATAL: {p} declares no --aps-* tokens")
    return tokens


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--wizard", nargs="?", const=str(REPO / WIZARD_CSS), metavar="CSS",
                    help="rewrite the generated block in the wizard's stylesheet")
    ap.add_argument("--check", metavar="TREE", help="assert TREE's wizard block is the projection")
    ap.add_argument("--self-test", action="store_true", help="hermetic self-test")
    args = ap.parse_args()
    if args.self_test:
        return self_test()
    if args.wizard:
        tokens = read_tokens(REPO)
        css = pathlib.Path(args.wizard)
        new = project(css.read_text(encoding="utf-8"), tokens)
        if new != css.read_text(encoding="utf-8"):
            css.write_text(new, encoding="utf-8")
            print(f"{css}: brand-token block rewritten ({len(tokens)} tokens)")
        else:
            print(f"{css}: brand-token block already current ({len(tokens)} tokens)")
        return 0
    if args.check:
        tree = pathlib.Path(args.check)
        tokens = read_tokens(tree)
        css = tree / WIZARD_CSS
        if not css.is_file():
            sys.exit(f"FATAL: no such file: {css}")
        text = css.read_text(encoding="utf-8")
        if BEGIN not in text or END not in text:
            print(f"FAIL: no generated brand-token block in {WIZARD_CSS} — run "
                  f"scripts/brand-tokens.py --wizard", file=sys.stderr)
            return 1
        want, got = block(tokens), find_block(text).group(0)
        if want != got:
            print(f"FAIL: the wizard's brand-token block is not the projection of {TOKENS}:",
                  file=sys.stderr)
            for w, g in zip(want.splitlines(), got.splitlines()):
                if w != g:
                    print(f"  token file: {w}\n  wizard:    {g}", file=sys.stderr)
            return 1
        print(f"  ok: the wizard's brand-token block is the byte projection of the token file "
              f"({len(tokens)} tokens)")
        return 0
    ap.print_help()
    return 2


def self_test():
    """Hermetic: tmp trees, no repo writes. Covers parse order, insert-then-idempotence,
    --check green, a drifted value redding, and a missing-block red."""
    import shutil

    tmp = pathlib.Path(tempfile.mkdtemp(prefix="brand-tokens-selftest-"))
    ok = [0]

    def check(name, cond):
        ok[0] += bool(cond)
        print(("  ok: " if cond else "FAIL: ") + name)

    tree = tmp / "tree"
    (tree / "themes/apsconecta/core/css").mkdir(parents=True)
    (tree / "php/public").mkdir(parents=True)
    (tree / TOKENS).write_text(
        ":root {\n  --aps-violet: #7f21fe; /* primary */\n  --aps-ink: #101828;\n"
        '  --aps-font-display: "Fraunces", Georgia, serif;\n}\n', encoding="utf-8")
    css = tree / WIZARD_CSS
    css.write_text("body { margin: 0; }\n\n:root {\n    --x: 1;\n}\n", encoding="utf-8")

    tokens = parse_tokens((tree / TOKENS).read_text(encoding="utf-8"))
    check("parse: three tokens in file order, comments stripped",
          tokens == [("--aps-violet", "#7f21fe"), ("--aps-ink", "#101828"),
                     ("--aps-font-display", '"Fraunces", Georgia, serif')])

    once = project(css.read_text(encoding="utf-8"), tokens)
    twice = project(once, tokens)
    check("project: inserts before :root and is idempotent",
          BEGIN in once and once.index("body") < once.index(BEGIN) < once.index(":root {")
          and "--aps-violet: #7f21fe;" in once and once == twice)

    css.write_text(once, encoding="utf-8")
    import contextlib, io
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = main_check(tree)  # the --check leg, factored for reuse
    check("check: green over the fresh projection", rc == 0)

    drifted = once.replace("#7f21fe", "#deadbe")
    css.write_text(drifted, encoding="utf-8")
    with contextlib.redirect_stderr(err):
        rc = main_check(tree)
    check("check: a drifted token value reds", rc == 1)

    css.write_text(once.replace(once[once.index("/* " + BEGIN):], ""), encoding="utf-8")
    err2 = io.StringIO()
    with contextlib.redirect_stderr(err2):
        rc = main_check(tree)
    check("check: a missing block reds (never passes vacuously)", rc == 1)

    shutil.rmtree(tmp)
    print("SELF-TEST: PASS" if ok[0] == 5 else "SELF-TEST: *** FAIL ***")
    return 0 if ok[0] == 5 else 1


def main_check(tree):
    tokens = read_tokens(tree)
    text = (pathlib.Path(tree) / WIZARD_CSS).read_text(encoding="utf-8")
    have = find_block(text)
    return 0 if have is not None and block(tokens) == have.group(0) else 1


if __name__ == "__main__":
    sys.exit(main())
