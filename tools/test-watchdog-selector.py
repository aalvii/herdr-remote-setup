#!/usr/bin/env python3
"""Regression tests for the macOS watchdog client selector.

The watchdog runs on macOS only, so these cases skip on other platforms. The
process table and osascript are replaced by fakes on PATH, so no real process is
signalled and no Terminal window opens.

Contracts pinned here:
  - only the herdr client TUI is selected; herdr-core, an SSH control master, a
    Node agent, the local server, and the watchdog itself are never selected
  - the relaunch passes --machine, from --machine, HERDR_MACHINE, or the label
    that the macOS setup recorded for the last pairing
  - --dry-run lists the same selection and signals nothing

Usage:
    python3 tools/test-watchdog-selector.py
Exit codes: 0 all cases passed or the platform was skipped, 1 a case failed,
2 the harness could not run.
"""

import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WATCHDOG = os.path.join(ROOT, "client", "watchdog-macos.sh")

PASS = 0
FAIL = 0

STUCK_LINE = "2026-01-01T00:00:00Z client did not acknowledge surface revocation"

PROCS = [
    ("100", "/usr/local/bin/herdr", "/usr/local/bin/herdr"),
    ("101", "/usr/local/bin/herdr", "/usr/local/bin/herdr server"),
    ("102", "/usr/local/bin/herdr-core", "/usr/local/bin/herdr-core connect 100.64.0.5"),
    ("103", "/usr/bin/ssh", "ssh -o ControlMaster=auto user@100.64.0.5 herdr remote-client-bridge"),
    ("104", "node", "node /opt/herdr-agent.js"),
    ("105", "/bin/bash", "/bin/bash /opt/herdr/client/watchdog-macos.sh --quiet"),
    ("106", "/usr/local/bin/herdr", "/usr/local/bin/herdr status"),
    ("107", "/usr/local/bin/herdr", "/usr/local/bin/herdr machine list --json"),
]

FAKE_PGREP = """#!/usr/bin/env python3
import os
for line in open(os.environ["FAKE_PROCS"]):
    line = line.strip()
    if line:
        print(line.split("\\t")[0])
"""

FAKE_PS = """#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
pid = None
for i, arg in enumerate(args):
    if arg == "-p" and i + 1 < len(args):
        pid = args[i + 1]
    elif arg.startswith("-p") and len(arg) > 2:
        pid = arg[2:]
fmt = "command"
for i, arg in enumerate(args):
    if arg == "-o" and i + 1 < len(args):
        fmt = args[i + 1]
    elif arg.startswith("-o") and len(arg) > 2:
        fmt = arg[2:]
for line in open(os.environ["FAKE_PROCS"]):
    line = line.rstrip("\\n")
    if not line:
        continue
    name, comm, cmd = line.split("\\t", 2)
    if name == pid:
        print(comm if fmt.split("=", 1)[0] == "comm" else cmd)
"""

FAKE_OSASCRIPT = """#!/usr/bin/env python3
import os, sys
with open(os.environ["FAKE_OSASCRIPT"], "a") as handle:
    handle.write(" ".join(sys.argv[1:]) + "\\n")
"""

FAKE_NOOP = """#!/bin/sh
exit 0
"""


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print("ok   %s" % name)
    else:
        FAIL += 1
        print("FAIL %s%s" % (name, (" -- " + str(detail)) if detail else ""))


class Sandbox(object):
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="herdr-watchdog-")
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(os.path.join(self.home, "Library", "Logs"))
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.space_bin = os.path.join(self.tmp, "bin with space")
        os.makedirs(self.space_bin)
        self.procs = os.path.join(self.tmp, "procs.txt")
        self.osascript = os.path.join(self.tmp, "osascript.txt")
        self.log = os.path.join(self.tmp, "client.log")
        self.write_tool("pgrep", FAKE_PGREP)
        self.write_tool("ps", FAKE_PS)
        self.write_tool("osascript", FAKE_OSASCRIPT)
        self.write_tool("sleep", FAKE_NOOP)
        self.write_tool("herdr", FAKE_NOOP)
        self.write_tool_at(self.space_bin, "herdr", FAKE_NOOP)
        self.write_procs(PROCS)
        with open(self.log, "w", encoding="utf-8") as handle:
            handle.write("2026-01-01T00:00:00Z client connected\n")
            handle.write(STUCK_LINE + "\n")
        stale = time.time() - 600
        os.utime(self.log, (stale, stale))

    def write_tool(self, name, body):
        self.write_tool_at(self.bin, name, body)

    def write_tool_at(self, directory, name, body):
        path = os.path.join(directory, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.chmod(path, 0o755)

    def write_procs(self, procs):
        with open(self.procs, "w", encoding="utf-8") as handle:
            for pid, comm, cmd in procs:
                handle.write("%s\t%s\t%s\n" % (pid, comm, cmd))

    @property
    def machines_path(self):
        return os.path.join(self.home, "Library", "Application Support",
                            "HerdrSetup", "machines.txt")

    @property
    def last_machine_path(self):
        return os.path.join(self.home, "Library", "Application Support",
                            "HerdrSetup", "last-machine.txt")

    def machines_file(self, label):
        os.makedirs(os.path.dirname(self.machines_path), exist_ok=True)
        with open(self.machines_path, "w", encoding="utf-8") as handle:
            handle.write("older-host\n%s\n" % label)

    def last_machine_file(self, label):
        os.makedirs(os.path.dirname(self.last_machine_path), exist_ok=True)
        with open(self.last_machine_path, "w", encoding="utf-8") as handle:
            handle.write("%s\n" % label)

    def run(self, args=(), machine=None, use_machines=None, herdr_dir=None,
            procs=None, last_machine=None):
        if procs is not None:
            self.write_procs(procs)
        env = {
            "HOME": self.home,
            "PATH": ((herdr_dir + ":") if herdr_dir else "") + self.bin
                    + ":/usr/bin:/bin:/usr/sbin:/sbin",
            "FAKE_PROCS": self.procs,
            "FAKE_OSASCRIPT": self.osascript,
        }
        if machine is not None:
            env["HERDR_MACHINE"] = machine
        if os.path.exists(self.osascript):
            os.unlink(self.osascript)
        if os.path.exists(self.machines_path):
            os.unlink(self.machines_path)
        if os.path.exists(self.last_machine_path):
            os.unlink(self.last_machine_path)
        if use_machines is not None:
            self.machines_file(use_machines)
        if last_machine is not None:
            self.last_machine_file(last_machine)
        cmd = ["bash", WATCHDOG, "--quiet", "--client-log", self.log] + list(args)
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True)
        recorded = ""
        if os.path.exists(self.osascript):
            with open(self.osascript, "r", encoding="utf-8") as handle:
                recorded = handle.read().replace('\\"', '"')
        watchdog_log = os.path.join(self.home, "Library", "Logs",
                                    "HerdrSetup", "watchdog.log")
        logged = ""
        if os.path.exists(watchdog_log):
            with open(watchdog_log, "r", encoding="utf-8") as handle:
                logged = handle.read()
        return proc.returncode, proc.stdout + proc.stderr, recorded, logged

    def close(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


def main():
    if not os.path.isfile(WATCHDOG):
        print("watchdog-macos.sh not found")
        return 2
    if sys.platform != "darwin":
        print("skip: the macOS watchdog runs on macOS only")
        return 0

    box = Sandbox()
    try:
        rc, out, recorded, logged = box.run(["--dry-run"])
        dry = [line for line in logged.splitlines() if "DRY RUN" in line]
        check("select: dry run reports the restart", rc == 11, (rc, out))
        check("select: only the client TUI is selected",
              len(dry) == 1 and "would stop 100 " in dry[0], dry)
        check("select: the dry run signals nothing", recorded == "", recorded)

        rc, out, recorded, logged = box.run(["--machine", "pi-host"])
        check("relaunch: the watchdog restarts the client", rc == 10, (rc, out))
        check("relaunch: --machine is passed to the client",
              "--machine 'pi-host'" in recorded, recorded)

        rc, out, recorded, logged = box.run(machine="env-host")
        check("relaunch: HERDR_MACHINE is passed to the client",
              rc == 10 and "--machine 'env-host'" in recorded, (rc, recorded))

        rc, out, recorded, logged = box.run(use_machines="paired-host")
        check("relaunch: the last paired label is passed to the client",
              rc == 10 and "--machine 'paired-host'" in recorded, (rc, recorded))

        rc, out, recorded, logged = box.run(use_machines="newer-host",
                                            last_machine="reused-host")
        check("relaunch: the latest pairing wins over file order",
              rc == 10 and "--machine 'reused-host'" in recorded,
              (rc, recorded))

        rc, out, recorded, logged = box.run()
        check("relaunch: no label means no invented label",
              rc == 10 and "--machine" not in recorded, (rc, recorded))
        check("relaunch: a missing label is logged",
              "no machine label" in logged, logged)

        space_herdr = os.path.join(box.space_bin, "herdr")
        space_procs = [("100", space_herdr, space_herdr)]
        rc, out, recorded, logged = box.run(herdr_dir=box.space_bin,
                                            procs=space_procs)
        check("relaunch: an executable path with spaces is shell quoted",
              rc == 10 and ("exec '%s'" % space_herdr) in recorded,
              (rc, recorded))
    finally:
        box.close()

    print("")
    print("%d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
