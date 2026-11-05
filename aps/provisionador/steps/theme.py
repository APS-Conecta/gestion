# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""«Tema y marca», the APS Conecta theme and branding. The theme (themes/apsconecta) goes into Nextcloud's themes
folder, which upstream's updates keep, with the establishment's name in its site.css, which the login page shows above
its heading and the header beside the logo. Theming then says «APS Conecta Gestión», with its motto and its site, in
the brand token file's colours, the dark violet as backdrop, light only, with the theme's logos, favicon and
background. Nextcloud's own voice goes quiet: its announcements, first-run wizard, usage survey and support app, its
help links, its free-account link, its update banners and its iOS app banner are off, and a new person's home starts
empty instead of with Nextcloud's sample files, which name it. Everyone's personal settings link the suite's source
code and its licence, and the theme's Spanish says «APS Conecta Gestión» where Nextcloud and its apps say «Nextcloud»,
on its screens and in its emails. Its part of the end-of-install check: what it set, as Nextcloud holds it."""

from steps import THEME, configure, differences, token

NAME = "Tema y marca"
NEEDS = ("start",)
SUITE = "APS Conecta Gestión"
PLACED = f"/var/www/html/themes/{THEME.name}"  # the theme in Nextcloud's themes folder
IMAGES = {"logo": "core/img/logo/logo.svg", "logoheader": "core/img/logo/logo-header.svg",
          "favicon": "core/img/favicon.svg", "background": "core/img/background.svg"}
OFF = ("nextcloud_announcements", "firstrunwizard", "survey_client", "support")
IMPORTED = {"system": {"theme": THEME.name, "enforce_theme": "light", "knowledgebaseenabled": False,
                       "simpleSignUpLink.shown": False, "updatechecker": False, "customclient_ios_appid": "",
                       "skeletondirectory": ""},
            "apps": {"theming": {"productName": SUITE}}}


def theming():
    """What occ theming:config sets, in the order it sets it. The backdrop's colour is the background image's dark
    violet: Nextcloud derives the text over the backdrop and the header icons from it, so a bright one gives black
    text on the violet image."""
    return {"name": SUITE, "slogan": "La salud primaria que compartimos es la que mejora",
            "url": "https://apsconecta.cl", "primary_color": token("--aps-violet"),
            "background_color": token("--aps-violet-dark"), "disable-user-theming": "yes",
            **{image: f"{PLACED}/{path}" for image, path in IMAGES.items()}}


def settings():
    """What Nextcloud holds once the step is done, as occ config:list answers it."""
    held = {key: True if key == "disable-user-theming" else value for key, value in theming().items()
            if key not in IMAGES}
    return {"system": IMPORTED["system"],
            "apps": {"theming": {**IMPORTED["apps"]["theming"], **held,
                                 **{f"{image}Mime": "image/svg+xml" for image in IMAGES}},
                     **{app: {"enabled": "no"} for app in OFF}}}


def files(context):
    """The theme's files, by their path in its folder, its site.css naming the establishment."""
    found = {path.relative_to(THEME).as_posix(): path.read_bytes() for path in THEME.rglob("*") if path.is_file()}
    quoted = context.centre["name"].replace("\\", "\\\\").replace('"', '\\"')
    found["core/css/site.css"] = f':root {{ --aps-clinic: "{quoted}"; }}\n'.encode()
    return found


def run(context):
    nextcloud = context.suite.nextcloud
    nextcloud.place_theme(THEME.name, files(context))
    for key, value in theming().items():
        nextcloud.occ("theming:config", key, value)
    for app in OFF:
        nextcloud.occ("app:disable", app)
    return configure(nextcloud, IMPORTED) or differences(nextcloud, settings())


def check(context):
    return differences(context.suite.nextcloud, settings())
