# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The install steps, one module each, which «Instalar» runs in order (provisionador.INSTALL).

A step module declares:
  NAME          its Spanish name
  NEEDS         the ids of the steps that must be done before it runs
  run(context)  its work, idempotent: it returns what went wrong as Spanish reasons, and None or [] once the work is
                done; only the suite port raises, Unreachable with its Spanish reason, which «Instalar» records as the
                step's reason too
The context holds the suite port (`suite`), the centre «Centro» confirmed (`centre`) and the address the operator's
browser opens AIO's interface at (`interface`, the (host, port) of APS_INTERFACE_ADDRESS).
"""

import time

POLL = 2  # seconds between two readings of the suite while a step waits for it


def until(read, done, wait):
    """`read()` again until `done` accepts what it answers or `wait` seconds pass; its last answer."""
    deadline = time.monotonic() + wait
    while not done(answer := read()) and time.monotonic() < deadline:
        time.sleep(POLL)
    return answer
