#!/usr/bin/env python3
"""Render the welcome tree a site DECLARED into a staging directory (phase 41, ADR-0019).

    render.py <library> <stage>

Environment (the phase exports them; arrays newline-joined, one entry per line):
  SITE_NOMBRE SITE_NOMBRE_CORTO SITE_DIRECCION SITE_COMUNA SITE_SERVICIO_SALUD   identity (D3)
  SITE_WELCOME    section|flag rows — WHICH sections exist (review L0-01); flag: wall | empty
                  (wall = the section's structure is stamped "protected": true, stamp_walls below)
  SITE_TEAMS      gid|display rows — one team page each, only when 'equipos' is declared; each
                  links its own folder, which SITE_FOLDERS must declare (team_dir below)
  SITE_FOLDERS    group folders — the only Files roots a rendered link may point at (L0-06)
  SITE_SUBFOLDERS Transversal's subfolders — the Documentos page links exactly these (L0-06)

Library layout (<library> = provisioning/intravox/es):
  core/home.json.tpl        identity + __HOME_TILES__ (one tile per declared section)
  core/footer.json.tpl      identity + __SECTION_LINKS__
  core/images/*             copied
  sections/<s>/<s>.json     the section's hub page (title + uniqueId feed nav/tiles/footer)
  sections/<s>/section.json sidecar: {"tile": {"text": …, "icon": …}} — never staged
  sections/<s>/**           the rest of the section, copied with identity substitution
  sections/documentos/documentos.json.tpl   __SUBFOLDER_LINKS__ instead of a fixed link list
  equipos/equipos.json.tpl  the hub grid = __TEAM_LINKS__ only; equipos/equipo.tpl per team
navigation.json is generated whole: Inicio + one entry per declared section, declaration order.

Every substituted value is JSON-escaped (all placeholders sit inside JSON strings): a register
name with a quote or a backslash renders as itself instead of breaking the page.
Fail-closed (exit 1, one FATAL line): unknown flag, section without a library folder, a team whose
folder the site does not declare, a `/apps/files/?dir=/X` link whose X is not a declared Files
root, a rendered file that is not JSON. Every write goes under <stage>; the library is read-only.
"""
import json
import os
import re
import shutil
import sys

IDENTITY = ("SITE_NOMBRE", "SITE_NOMBRE_CORTO", "SITE_DIRECCION", "SITE_COMUNA", "SITE_SERVICIO_SALUD")
FLAGS = {"wall", ""}
HOME_ID = "page-aps-00000001-0000-4000-8000-000000000001"
APP_TILES = [  # the fixed, app-level tiles every clinic gets; the Files one only when the root exists
    ("Recepción y admisión", "Cupos, reprogramación, orientación", "/apps/files/?dir=/Transversal", "information-outline"),
    ("Gestión y turnos", "Programación semanal del centro", "/apps/calendar/", "calendar-month-outline"),
    ("Teléfonos y anexos", "Directorio interno del CESFAM", "/apps/contacts/", "phone-classic"),
]


def fatal(msg):
    print(f"FATAL: {msg}", file=sys.stderr)
    sys.exit(1)


def lines(var):
    return [l for l in os.environ.get(var, "").split("\n") if l.strip()]


def rows(var):
    out = []
    for l in lines(var):
        key, _, rest = l.partition("|")
        out.append((key.strip(), rest.strip()))
    return out


def team_dir(gid, display, folders):
    """The declared folder a team page links, or None. Programs and sectors: deis.py's emission
    shape (scripts/deis.py:173-192). Any other team — a role page added by hand, 'role-oirs|OIRS' —
    the ONE declared folder whose last segment is its display name (Unidades/OIRS)."""
    if gid.startswith("prog-"):
        cands = ["Programas/" + display.removeprefix("Programa ")]
    elif gid.startswith("sector-"):
        cands = ["Sectores/" + display]
    else:
        cands = [f for f in folders if f.rsplit("/", 1)[-1] == display]
    hits = [c for c in cands if c in folders]
    return hits[0] if len(hits) == 1 else None


def esc(value):
    """A value as the inside of a JSON string literal."""
    return json.dumps(value, ensure_ascii=False)[1:-1]


def strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from strings(v)


def link(title, text, url, icon):
    return {"title": title, "text": text, "url": url, "icon": icon, "target": "_self"}


def main(library, stage):
    identity = {}
    for var in IDENTITY:
        val = os.environ.get(var, "")
        if not val:
            fatal(f"{var} is empty — the site file carries no value to substitute (D3)")
        identity[f"__{var}__"] = esc(val)

    welcome = rows("SITE_WELCOME")
    for section, flag in welcome:
        if flag not in FLAGS:
            fatal(f"SITE_WELCOME row '{section}|{flag}': unknown flag '{flag}' (wall or empty)")
        if not re.fullmatch(r"[a-z0-9-]+", section):
            fatal(f"SITE_WELCOME row '{section}': a section is a lowercase folder name")
        hub_files = [os.path.join(library, "sections", section, f"{section}.json{ext}") for ext in ("", ".tpl")]
        if section != "equipos" and not any(os.path.isfile(h) for h in hub_files):
            fatal(f"SITE_WELCOME declares '{section}' but the library has no sections/{section}/{section}.json(.tpl)")
    if len({s for s, _ in welcome}) != len(welcome):
        fatal("SITE_WELCOME declares a section twice")
    teams = rows("SITE_TEAMS")
    folders = set(lines("SITE_FOLDERS"))
    subfolders = lines("SITE_SUBFOLDERS")
    allowed_roots = {f"/{f}" for f in folders} | {f"/Transversal/{s}" for s in subfolders if "Transversal" in folders}

    def substitute(text):
        for k, v in identity.items():
            text = text.replace(k, v)
        return text

    def put(rel, text):
        path = os.path.join(stage, rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(text)
        written.append(rel)

    def copy_tree(src_dir, rel_dir):
        for root, _, files in os.walk(src_dir):
            for f in files:
                if f == "section.json" or f.endswith(".tpl"):
                    continue
                src = os.path.join(root, f)
                rel = os.path.join(rel_dir, os.path.relpath(src, src_dir))
                if f.endswith(".json"):
                    put(rel, substitute(open(src, encoding="utf-8").read()))
                else:
                    os.makedirs(os.path.dirname(os.path.join(stage, rel)), exist_ok=True)
                    shutil.copyfile(src, os.path.join(stage, rel))
                    written.append(rel)

    def stamp_walls(section, every_page=False):
        # Review L4-01: a `wall` section's STRUCTURE carries the engine's marker, which then
        # refuses delete/move and survives every save. Structure = the section hub, every
        # seeded page that has sub-pages (noticias/avisos — the home's Avisos list reads it),
        # and for equipos every page (every_page: its pages ARE the declared SITE_TEAMS). The
        # seeded example posts stay ordinary, deletable pages like every post staff create
        # later (owner decision 2026-09-28). Per page, never a folder rule (ADR-0019).
        for rel in written:
            page_dir = os.path.dirname(os.path.join(stage, rel))
            if not rel.startswith(section + "/") or rel != os.path.relpath(page_dir, stage) + "/" + os.path.basename(page_dir) + ".json":
                continue  # not a page JSON of this section (a page is <dir>/<dir>.json)
            has_subpages = any(os.path.isfile(os.path.join(page_dir, d, d + ".json"))
                               for d in os.listdir(page_dir) if os.path.isdir(os.path.join(page_dir, d)))
            if every_page or rel == f"{section}/{section}.json" or has_subpages:
                path = os.path.join(stage, rel)
                data = json.load(open(path, encoding="utf-8"))
                data["protected"] = True
                with open(path, "w", encoding="utf-8") as fh:
                    json.dump(data, fh, ensure_ascii=False, indent=2)
                    fh.write("\n")

    written = []
    if os.path.exists(stage) and os.listdir(stage):
        fatal(f"stage {stage} is not empty")
    os.makedirs(stage, exist_ok=True)

    # sections: copy, and collect what nav/tiles/footer need from each hub page + sidecar
    entries = []  # (section, title, uniqueId, tile_text, tile_icon)
    for section, flag in welcome:
        if section == "equipos":
            if not os.path.isfile(os.path.join(library, "equipos", "equipos.json.tpl")):
                fatal("SITE_WELCOME declares 'equipos' but the library has no equipos/equipos.json.tpl")
            hub_tpl = substitute(open(os.path.join(library, "equipos", "equipos.json.tpl"), encoding="utf-8").read())
            frags = [json.dumps(link(d, "Actas, plan y noticias del equipo", f"/apps/intravox/p/page-aps-team-{g}",
                                     "account-group-outline"), ensure_ascii=False) for g, d in teams]
            hub = hub_tpl.replace("__TEAM_LINKS__", ",\n          ".join(frags))
            put("equipos/equipos.json", hub)
            tpl = substitute(open(os.path.join(library, "equipos", "equipo.tpl"), encoding="utf-8").read())
            for gid, display in teams:
                tdir = team_dir(gid, display, folders)
                if tdir is None:
                    fatal(f"SITE_TEAMS row '{gid}|{display}': no single SITE_FOLDERS entry is its folder"
                          f" (Programas/…, Sectores/… or one ending in /{display}) — a team page never links"
                          " a folder the site does not have (L0-06)")
                page = (tpl.replace("__TEAM_ID__", esc(gid)).replace("__TEAM_DISPLAY__", esc(display))
                           .replace("__TEAM_DIR__", esc(tdir)))
                put(f"equipos/{gid}/{gid}.json", page)
            hub_data = json.loads(hub)
            entries.append(("equipos", hub_data["title"], hub_data["uniqueId"], "Quién es quién, anexos y correos", "account-group-outline"))
            if flag == "wall":
                stamp_walls("equipos", every_page=True)
            continue
        sdir = os.path.join(library, "sections", section)
        copy_tree(sdir, section)
        tpl_path = os.path.join(sdir, f"{section}.json.tpl")
        if os.path.isfile(tpl_path):  # documentos: the link list is the declared subfolders
            frags = [json.dumps(link(s, "Carpeta compartida del centro", f"/apps/files/?dir=/Transversal/{s}", "folder-outline"),
                                ensure_ascii=False) for s in subfolders]
            put(f"{section}/{section}.json", substitute(open(tpl_path, encoding="utf-8").read())
                .replace("__SUBFOLDER_LINKS__", ",\n            ".join(frags)))
        hub_data = json.loads(open(os.path.join(stage, section, f"{section}.json"), encoding="utf-8").read())
        side = json.load(open(os.path.join(sdir, "section.json"), encoding="utf-8")) if os.path.isfile(os.path.join(sdir, "section.json")) else {}
        tile = side.get("tile", {})
        entries.append((section, hub_data["title"], hub_data["uniqueId"], tile.get("text", hub_data["title"]), tile.get("icon", "file-document-outline")))
        if flag == "wall":
            stamp_walls(section)

    # core: home tiles, footer links, navigation — all from the declared sections
    tiles = [link(t, x, u, i) for t, x, u, i in APP_TILES if not u.startswith("/apps/files/") or "Transversal" in folders]
    tiles += [link(title, text, f"/apps/intravox/p/{uid}", icon) for _s, title, uid, text, icon in entries]
    home = substitute(open(os.path.join(library, "core", "home.json.tpl"), encoding="utf-8").read())
    put("home.json", home.replace("__HOME_TILES__", ",\n            ".join(json.dumps(t, ensure_ascii=False) for t in tiles)))
    footer = substitute(open(os.path.join(library, "core", "footer.json.tpl"), encoding="utf-8").read())
    put("footer.json", footer.replace("__SECTION_LINKS__", esc(" | ".join(f"[{title}](/apps/intravox/p/{uid})" for _s, title, uid, _t, _i in entries))))
    nav = {"type": "megamenu", "items": [
        {"id": "nav_inicio", "title": "Inicio", "uniqueId": HOME_ID, "url": None, "target": None, "children": []}]}
    for section, title, uid, _t, _i in entries:
        nav["items"].append({"id": f"nav_{section.replace('-', '_')}", "title": title, "uniqueId": uid, "url": None, "target": None, "children": []})
    put("navigation.json", json.dumps(nav, ensure_ascii=False, indent=2) + "\n")
    copy_tree(os.path.join(library, "core", "images"), "images")

    # gates: every staged JSON parses; every Files link points at a declared root
    for rel in written:
        if not rel.endswith(".json"):
            continue
        try:
            data = json.load(open(os.path.join(stage, rel), encoding="utf-8"))
        except ValueError as e:
            fatal(f"{rel} is not valid JSON after rendering ({e}) — a site value broke a page")
        # the parsed strings, not the file text: a link is judged as the browser will read it
        for target in (t for v in strings(data) for t in re.findall(r"/apps/files/\?dir=([^&]*)", v)):
            if target not in allowed_roots:
                fatal(f"{rel} links to Files path '{target}' which no SITE_FOLDERS/SITE_SUBFOLDERS/SITE_TEAMS entry declares (L0-06)")
    print(f"rendered: {len(written)} files; sections: {', '.join(s for s, *_ in entries) or '(none)'}; teams: {len(teams) if any(s == 'equipos' for s, *_ in entries) else 0}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        fatal("usage: render.py <library> <stage>")
    main(sys.argv[1], sys.argv[2])
