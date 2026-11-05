# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The install steps, one module each; the step runner (runner.py) finds them here and runs each once the steps it
needs are green.

A step module, whose name is its id, declares:
  NAME            its Spanish name, as the progress and the red list show it
  NEEDS           the ids of the steps that must be green before it runs
  run(context)    its work, idempotent: it returns what went wrong as Spanish reasons, which the red list shows, and
                  None or [] once the work is done; no step reports success without doing its work. A part of the work
                  that only warns returns a Notice instead, which keeps the step green
  check(context)  optional, its part of the end-of-install check, which runs once every step is green: the Spanish
                  differences between what the step declared and the running suite, None or [] when it is clean
Both answer the same way; only the suite port raises, Unreachable with its Spanish reason, which the runner records as
the step's reason too. The context holds the suite port (`suite`), the centre «Centro» confirmed (`centre`) and the
address the operator's browser opens AIO's interface at (`interface`, the (host, port) of APS_INTERFACE_ADDRESS). A new
step is a new module, with its Seam 2 tests in test_step_<id>.py: no other file lists the steps.
"""

import json
import time

POLL = 2  # seconds between two readings of the suite while a step waits for it
DIFFERS = ("Nextcloud no conserva estos ajustes: {}. Presione «Reintentar»; si vuelve a ocurrir, contacte a APS "
           "Conecta.")


class Notice(str):
    """A reason that only warns: its step is done, so it stays green, with the notice beside it in the progress and in
    the log, since «Listo» may close the page before the operator reads it."""


def until(read, done, wait):
    """`read()` again until `done` accepts what it answers or `wait` seconds pass; its last answer."""
    deadline = time.monotonic() + wait
    while not done(answer := read()) and time.monotonic() < deadline:
        time.sleep(POLL)
    return answer


def differences(nextcloud, settings):
    """Of Nextcloud's settings, {"system": {key: value}, "apps": {app: {key: value}}}, those it does not hold, as one
    Spanish reason in a list, or none."""
    held = json.loads(nextcloud.occ("config:list"))
    wrong = [key for key, value in settings.get("system", {}).items() if held["system"].get(key) != value]
    wrong += [f"{app}.{key}" for app, values in settings.get("apps", {}).items()
              for key, value in values.items() if held["apps"].get(app, {}).get(key) != value]
    return [DIFFERS.format(", ".join(wrong))] if wrong else []


def configure(nextcloud, settings):
    """Import the settings with occ, then what Nextcloud does not hold of them, as `differences` answers it: an import
    that answers but keeps a setting out is a failure."""
    nextcloud.occ("config:import", stdin=json.dumps(settings))
    return differences(nextcloud, settings)
