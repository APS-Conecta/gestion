#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 APS Conecta
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Collect scoped resource evidence; samples do not establish a supported minimum."""

import argparse
import datetime
import json
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def run(*command):
    result = subprocess.run(command, capture_output=True, text=True, timeout=5)
    if result.returncode:
        raise ValueError("Resource command failed: " + command[0])
    return result.stdout


def counters(path, keys):
    with open(path, encoding="utf-8") as stream:
        values = {parts[0].rstrip(":"): int(parts[1]) for line in stream
                  if (parts := line.split()) and parts[0].rstrip(":") in keys}
    if set(values) != set(keys) or any(value < 0 for value in values.values()):
        raise ValueError("Incomplete host resource counters")
    return values


def snapshot():
    sampled_at, monotonic = now(), time.monotonic()
    memory = counters("/proc/meminfo", ("MemTotal", "MemAvailable", "SwapTotal", "SwapFree"))
    with open("/proc/stat", encoding="utf-8") as stream:
        cpu = stream.readline().split()
    if not cpu or cpu[0] != "cpu" or len(cpu) < 9:
        raise ValueError("Incomplete host CPU counters")
    with open("/proc/sys/kernel/random/boot_id", encoding="utf-8") as stream:
        boot_id = stream.read().strip()
    host = {"memory_total_kib": memory["MemTotal"], "memory_available_kib": memory["MemAvailable"],
            "swap_total_kib": memory["SwapTotal"], "swap_free_kib": memory["SwapFree"],
            "logical_cpus": os.cpu_count(), "available_cpus": len(os.sched_getaffinity(0)),
            "page_size_bytes": os.sysconf("SC_PAGE_SIZE"), "clock_ticks_per_second": os.sysconf("SC_CLK_TCK"),
            "boot_id": boot_id,
            "cpu_ticks": [int(value) for value in cpu[1:]],
            "vm_counters": counters("/proc/vmstat", ("pswpin", "pswpout", "oom_kill"))}
    containers_status = "ok"
    try:
        names = run("docker", "ps", "--filter", "name=^aps-conecta-",
                    "--filter", "name=^nextcloud-aio-mastercontainer$", "--format", "{{.Names}}").splitlines()
        stats = [json.loads(line) for line in run("docker", "stats", "--no-stream", "--format",
                                                 "{{json .}}", *names).splitlines() if line.strip()] if names else []
        if len(stats) != len(names) or {row["Name"].lstrip("/") for row in stats} != set(names):
            raise ValueError("Container disappeared during its usage sample")
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
        containers_status, stats = "unavailable", None
    fields = ("source", "fstype", "size", "used", "avail", "pcent", "target")
    lines = run("df", "-B1", "--output=" + ",".join(fields), "/", "/var/lib/docker").splitlines()
    disks, seen = [], set()
    for line in lines[1:]:
        row = dict(zip(fields, line.split(None, len(fields) - 1)))
        if row["source"] not in seen:
            seen.add(row["source"])
            disks.append(row)
    return {"sampled_at": sampled_at, "monotonic_seconds": monotonic, "host": host,
            "memoria_gib": round(memory["MemTotal"] / 1048576, 1),
            "containers_status": containers_status, "contenedores": stats, "disco": disks}


def sample(path, interval, duration):
    stopped = threading.Event()
    previous = {sig: signal.signal(sig, lambda *_: stopped.set()) for sig in (signal.SIGTERM, signal.SIGINT)}
    deadline, count = time.monotonic() + duration, 0
    try:
        with path.open("x", encoding="utf-8", buffering=1) as stream:
            while not stopped.is_set() and time.monotonic() < deadline:
                stream.write(json.dumps(snapshot(), separators=(",", ":")) + "\n")
                count += 1
                stopped.wait(min(interval, max(0, deadline - time.monotonic())))
            stream.write(json.dumps({"event": "complete", "sampled_at": now(), "samples": count,
                                     "sampler_pid": os.getpid(),
                                     "reason": "stopped" if stopped.is_set() else "duration"}) + "\n")
    finally:
        for sig, handler in previous.items():
            signal.signal(sig, handler)


def completed(path, pid):
    try:
        rows = [json.loads(line) for line in path.read_text().splitlines()]
    except (FileNotFoundError, json.JSONDecodeError):
        return False
    if not rows or rows[-1].get("event") != "complete":
        return False
    if (rows[-1]["samples"] < 2 or rows[-1]["samples"] != len(rows) - 1
            or rows[-1]["sampler_pid"] != pid):
        raise ValueError("Resource series does not belong to this sampler or has insufficient samples")
    return True


def stop(path, pid_file):
    pid = int(pid_file.read_text().strip())
    if pid <= 1:
        raise ValueError("Invalid sampler PID")
    if completed(path, pid):
        return
    try:
        command = Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
        if os.fsencode(str(path)) not in command or not any(Path(os.fsdecode(arg)).name == "usage.py" for arg in command if arg):
            if completed(path, pid):
                return
            raise ValueError("Sampler PID does not identify this resource collector")
        os.kill(pid, signal.SIGTERM)
    except (FileNotFoundError, ProcessLookupError):
        pass
    deadline = time.monotonic() + 20
    while True:
        if completed(path, pid):
            return
        if time.monotonic() >= deadline:
            raise ValueError("Resource collector did not complete within 20 seconds")
        time.sleep(0.1)


def positive_seconds(value):
    value = float(value)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("use positive finite seconds")
    return value


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--interval", type=positive_seconds)
    parser.add_argument("--duration", type=positive_seconds)
    parser.add_argument("--stop", type=Path, metavar="PID_FILE")
    args = parser.parse_args(argv)
    if bool(args.interval) != bool(args.duration) or args.stop and args.interval:
        parser.error("supply interval and duration together, or stop an existing sampler")
    try:
        if args.stop:
            stop(args.output, args.stop)
        elif args.interval:
            sample(args.output, args.interval, args.duration)
        else:
            record = snapshot()
            with args.output.open("x", encoding="utf-8") as stream:
                json.dump(record, stream, indent=1)
        return 0
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired):
        print("FAIL: resource evidence could not be collected completely", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
