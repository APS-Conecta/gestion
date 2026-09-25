# Apps of ours under development on a dev stack. NOT shipped by a release (ADR-0005).
#
# Tracked but INERT, like compose.dev.yaml: an entry does something only where apps/<id> is a live
# clone, so a clinic reads this file and falls through. Read by provisioning/phases/12-apps.sh and
# scripts/divergence.sh.
#
# ONE LINE, space-separated <appid>=<clone url> — the shape OWN_APPS uses, so nothing needs a second
# parser. The id is the DIRECTORY name too, and it is the app id, not necessarily the repository name.
# territorio was the last one: lab at first, own at v0.74.0 (2026-09). intravox arrived 2026-09 for
# the welcome-screen program's lab period (ADR-0014) — promoted at v3.1.0-aps1 (2026-09-25): the
# promotion commit vendors the engine and empties this line again.
LAB_APPS=""
