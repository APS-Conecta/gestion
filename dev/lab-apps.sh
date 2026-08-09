# Apps of ours under development on a dev stack. NOT shipped by a release (ADR-0005).
#
# Tracked but INERT, like compose.dev.yaml: an entry does something only where apps/<id> is a live
# clone, so a clinic reads this file and falls through. Read by provisioning/phases/12-apps.sh and
# scripts/divergence.sh.
#
# ONE LINE, space-separated <appid>=<clone url> — the shape OWN_APPS uses, so nothing needs a second
# parser. The id is the DIRECTORY name too, and it is the app id, not necessarily the repository name.
LAB_APPS="territorio=https://github.com/APS-Conecta/territorio.git"
