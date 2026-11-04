#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""AIO's page and its notifications speak es-CL Spanish, never use the other product's name, and paint
the brand through the brand token file.

The operator text is what an administrator reads there:
- the Twig templates: their text, and the title, placeholder, alt, aria-label and data-confirm
  attributes and the buttons' values (code, scripts and styles aside);
- the page scripts: what alert(), confirm() and showError() say, and the text and labels they set;
- php/src's sentences, the mastercontainer's notifications included, except where it logs or
  throws an internal exception (the deSEC flow's exceptions are shown: its controller writes them);
- the containers' display names, in php/containers.json and in the Caddy definition.
A text fails when it carries one of ENGLISH's words; URLs, quoted literals, commands and
identifiers are not prose. Every file read, the stylesheets included, also fails on the name of the
other product (APS-Conecta/gestion-aio), on an English page language and on a colour of the token
file: the page reads the tokens instead (the logo and favicon art may repeat them).
Usage: scripts/aio-page.py [TREE]   (TREE defaults to this repository)
"""
import html.parser
import json
import pathlib
import re
import sys

# Words of upstream's English page that no Spanish sentence uses (so not «use», «note» or «once»).
ENGLISH = frozenset("""
able about above accepted access account add additional after afterwards again all allowed already
also an and any are around at automatic automatically available back backup backups be been before
behind below best between but by can cancel cannot caution change changed changes channel characters
check chosen click clicking close command compatibility confirm consider contact container
containers continue correct correctly could create current currently daily delete deprecated details
did different directories directory disable disabled do docs documentation does domain download
during each email empty enable enabled enabling encryption enter entered equal every everything
example external failed feature features few file finish first folder following for found free from
further get getting good has have here hide hint how if important in included initial inside
installation installed instead integration integrity interface into is itself keep last learn least
leave limited location log login logout logs look manually may might minimal more most must my name
need needed needs network new not now of on one only option optional options or order other our page
partition passphrase password path please port possible powered public publicly reachable read
recommended recording register reload remote remotely remove repair required requirements restart
restore restored reveal running same saturdays save section security see seem seems selected
settings setup should show since some source space spaces start starting stop stopped storage submit
successful successfully sure take test than that the their them then there these they this
those time timezone to tool unavailable update updated updates upgrade uploads validation value
values volume volumes want warning was we were what when which whole will with without work would
wrong yes you your
""".split())
FORBIDDEN = r"Gesti(?:ó|o|&oacute;)n\s+AIO|\blang=[\"']en\b"
TOKENS = "themes/apsconecta/core/css/tokens.css"

URL = re.compile(r"\b(?:https?|ssh)://\S+")
QUOTED = re.compile(r"(?<!\w)'[^'\n]*'(?!\w)")  # a value or a command quoted inside a sentence
COMMAND = re.compile(r"\bsudo\s.*")
TECHNICAL = re.compile(r"[/\\_=@:.<>\[\]{}$#|~*+\d-]")  # paths, identifiers, options, versions


def prose(text):
    """The words of a text, its URLs, quoted literals, commands and identifiers left out."""
    text = COMMAND.sub(" ", QUOTED.sub(" ", URL.sub(" ", re.sub(r"\$\{[^}]*\}", " ", text))))
    words = []
    for token in text.split():
        token = token.strip(".,;:!?¡¿()«»\"'…")
        if token and not TECHNICAL.search(token):
            words += re.findall(r"[^\W\d_]+", token)
    return words


class TwigText(html.parser.HTMLParser):
    SHOWN = {"title", "placeholder", "alt", "aria-label", "data-confirm"}
    NOT_PROSE = {"script", "style", "code", "pre", "kbd", "samp"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.texts, self.inside = [], []

    def handle_starttag(self, tag, attrs):
        if tag in self.NOT_PROSE:
            self.inside.append(tag)
        kind = dict(attrs).get("type")
        for name, value in attrs:
            if value and (name in self.SHOWN or (name == "value" and kind in ("submit", "button", "reset"))):
                self.texts.append((self.getpos()[0], value))

    def handle_endtag(self, tag):
        if self.inside and self.inside[-1] == tag:
            self.inside.pop()

    def handle_data(self, data):
        if not self.inside and data.strip():
            self.texts.append((self.getpos()[0], data))


def twig_texts(src, _):
    # Twig's own syntax becomes blanks of the same shape, so line numbers hold.
    blank = lambda m: re.sub(r"[^\n]", " ", m.group(0))
    parser = TwigText()
    parser.feed(re.sub(r"\{#.*?#\}|\{%.*?%\}|\{\{.*?\}\}", blank, src, flags=re.S))
    parser.close()
    return parser.texts


JS_STRING = re.compile(r"'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\"|`(?:[^`\\]|\\.)*`")
JS_SHOWN = re.compile(r"\b(?:alert|confirm|showError)\s*\("
                      r"|\.(?:textContent|innerText|innerHTML|title|placeholder)\s*=(?!=)"
                      r"|\.setAttribute\(\s*['\"](?:aria-label|title|placeholder|alt|value)['\"]")


def js_texts(src, _):
    texts = []
    for number, line in enumerate(src.splitlines(), 1):
        shown = JS_SHOWN.search(line)
        if shown:
            texts += [(number, m.group(0)[1:-1]) for m in JS_STRING.finditer(line, shown.end())]
    return texts


INTERNAL = re.compile(r"\berror_log\s*\("
                      r"|\bthrow\s+new\s+\\?(?:Exception|RuntimeException|InvalidArgumentException|LogicException|Error)\s*\(")


def php_statements(src):
    """(code, [(line, literal)]) per statement; comments dropped, each literal's place kept as ''."""
    statements, code, literals, i = [], "", [], 0
    while i < len(src):
        if src.startswith(("//", "#"), i) and not src.startswith("#[", i):
            i = len(src) if src.find("\n", i) < 0 else src.find("\n", i)
        elif src.startswith("/*", i):
            i = len(src) if src.find("*/", i) < 0 else src.find("*/", i) + 2
        elif src[i] in "'\"":
            end = i + 1
            while end < len(src) and src[end] != src[i]:
                end += 2 if src[end] == "\\" else 1
            literals.append((src.count("\n", 0, i) + 1, src[i + 1:end]))
            code, i = code + "''", end + 1
        elif src[i] in ";{}":
            statements.append((code, literals))
            code, literals, i = "", [], i + 1
        else:
            code, i = code + src[i], i + 1
    return statements


def php_texts(src, path):
    """Each literal that reads as a sentence, unless its statement logs or throws internally."""
    internal = re.compile(r"\berror_log\s*\(") if path.parent.name == "Desec" else INTERNAL
    return [(line, text) for code, literals in php_statements(src) if not internal.search(code)
            for line, text in literals if len(prose(text)) >= 2]


def display_names(src, _):
    return [(src.count("\n", 0, src.find(f'"{s["display_name"]}"')) + 1, s["display_name"])
            for s in json.loads(src)["aio_services_v1"]]


SURFACES = [
    ("php/templates/**/*.twig", twig_texts),
    ("php/public/*.js", js_texts),
    ("php/src/**/*.php", php_texts),
    ("php/containers.json", display_names),
    ("community-containers/caddy/caddy.json", display_names),
    ("php/public/*.css", lambda src, path: []),
]


def banned(tree):
    """FORBIDDEN, and each colour of the token file as hex or as rgb()."""
    colours = re.findall(r"#([0-9a-f]{6})\b", (tree / TOKENS).read_text(encoding="utf-8"), re.IGNORECASE)
    rgb = [r"rgba?\(\s*{}\s*,\s*{}\s*,\s*{}\b".format(*(int(c[i:i + 2], 16) for i in (0, 2, 4))) for c in colours]
    return re.compile("|".join([FORBIDDEN] + [rf"#{c}\b" for c in colours] + rgb), re.IGNORECASE)


def main():
    tree = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path(__file__).resolve().parent.parent
    bad, forbidden = [], banned(tree)
    for pattern, read in SURFACES:
        files = sorted(tree.glob(pattern))
        if not files:
            bad.append(f"{pattern}: no such files, so nothing would be checked")
        for path in files:
            name, src = path.relative_to(tree), path.read_text(encoding="utf-8")
            bad += [f"{name}:{src.count(chr(10), 0, m.start()) + 1}: carries {m.group(0)!r}"
                    for m in forbidden.finditer(src)]
            for line, text in read(src, path):
                words = sorted({w for w in prose(text) if w.lower() in ENGLISH})
                if words:
                    bad.append(f"{name}:{line}: English {', '.join(words)}: {' '.join(text.split())[:100]!r}")
    if bad:
        print("AIO's page or its notifications: English, the other product's name,"
              " or a brand colour outside the token file:")
        print("\n".join(f"  {line}" for line in bad))
        return 1
    print("AIO's page and its notifications: es-CL Spanish, our name only, brand colours from the token file")
    return 0


if __name__ == "__main__":
    sys.exit(main())
