# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The install step runner: «Instalar» runs every step of steps/ in an order where each comes after the steps it needs,
the core steps first and the optional ones last. A step that fails gets its Spanish reason; the steps that need it wait,
and say for what; a step that does not need it still runs. «Reintentar» runs the failed and waiting steps again, never
a green one. Once every step is green, the end-of-install check runs each step's check: the differences between what
the step declared and the running suite. A step whose part differs turns red again. «Listo» needs every step green and
a clean check. A part of a step's work that only warns gives a notice, which keeps the step green.

Each step's status is kept in the Provisionador's state as it changes: pending, running, green, failed or waiting, so
a restart of the Provisionador resumes the steps it cut short.
"""

import importlib
import pkgutil
import traceback

import steps
from suite import Unreachable

UNEXPECTED = ("La instalación se detuvo por un error inesperado. Presione «Reintentar»; si vuelve a ocurrir, contacte a "
              "APS Conecta e indique el registro del contenedor maestro.")
WAITING = "Espera a que se complete {}."
WAITING_SEVERAL = "Espera a que se completen {} y {}."


def discover():
    """Every step module of steps/, by its id: the core steps, each after the steps it needs, then the optional ones the
    same way; the steps of one rank by id. A core step cannot need an optional one."""
    found = {m.name: importlib.import_module(f"steps.{m.name}") for m in pkgutil.iter_modules(steps.__path__)}
    optional = {name for name, step in found.items() if getattr(step, "OPTIONAL", False)}
    ordered = []
    for group in (set(found) - optional, optional):
        while group - set(ordered):
            ready = sorted(name for name in group - set(ordered) if set(found[name].NEEDS) <= set(ordered))
            if not ready:
                raise RuntimeError(f"steps that need unknown or circular steps: {sorted(group - set(ordered))}")
            ordered += ready
    return {name: found[name] for name in ordered}


STEPS = discover()


def begin(state):
    """«Instalar» or «Reintentar»: every step that is not green is to run."""
    def reopen(s):
        kept = s.get("install", {}).get("steps", {})
        s["install"] = {"steps": {name: kept[name] if kept.get(name, {}).get("status") == "green"
                                  else {"status": "pending"} for name in STEPS}}
    state.change(reopen)


def unfinished(install):
    """The steps a run has not settled yet: pending, or running when a restart cut it short."""
    return {name for name, step in install["steps"].items() if step["status"] in ("pending", "running")}


def failed(install):
    """Whether a step failed or waits for one that is not green."""
    return any(step["status"] in ("failed", "waiting") for step in install["steps"].values())


def problems(call, context):
    """What a step's run or check found wrong, in Spanish."""
    try:
        return call(context) or []
    except Unreachable as outage:
        return [str(outage)]
    except Exception:  # a defect: the log gets the traceback, the operator a reason
        traceback.print_exc()
        return [UNEXPECTED]


def record(state, name, status, reasons=()):
    entry = {"status": status, **({"reason": " ".join(reasons)} if reasons else {})}
    state.change(lambda s: s["install"]["steps"].update({name: entry}))


def green(state):
    return all(step["status"] == "green" for step in state.read()["install"]["steps"].values())


def run(state, context):
    """Run every unfinished step in order, then, once every step is green, the end-of-install check; whether «Listo»
    comes: every step green and the check clean."""
    for name, step in STEPS.items():
        install = state.read()["install"]
        if name not in unfinished(install):
            continue
        blocked = [f"«{STEPS[need].NAME}»" for need in step.NEEDS if install["steps"][need]["status"] != "green"]
        if blocked:
            *others, last = blocked
            record(state, name, "waiting", [WAITING_SEVERAL.format(", ".join(others), last) if others
                                            else WAITING.format(last)])
            continue
        record(state, name, "running")
        found = problems(step.run, context)
        done = all(isinstance(reason, steps.Notice) for reason in found)
        record(state, name, "green" if done else "failed", found)
        if done and found:
            print(*found, flush=True)  # «Listo» may close the page before the operator reads it
    if not green(state):
        return False
    for name, step in STEPS.items():
        if hasattr(step, "check") and (found := problems(step.check, context)):
            record(state, name, "failed", found)
    return green(state)


def progress(install):
    """Each step by its Spanish name, in order, with its status and, when it has one, its reason."""
    return [{"name": STEPS[name].NAME, **step} for name, step in install["steps"].items()]
