#!/usr/bin/env python3
"""End-to-end regression tests for host/pair.py and host/enroll.py.

Every case starts the real service on the loopback interface with a temporary
state directory and a temporary authorized_keys file, then speaks HTTP to it.
No network access outside loopback, no root, no real key material.

The cases pin the four contracts the two services must honour:
  - a key is authorized only when the full base64 blob matches an existing line
    or is appended exactly once
  - a secret compare accepts arbitrary text without raising an exception
  - a wrong attempt is counted, so the sixth wrong attempt is rate limited
  - the enrollment service listens on its configured address, not on every
    interface

Usage:
    python3 tools/test-host-services.py
Exit codes: 0 all cases passed, 1 a case failed, 2 the harness could not run.
"""

import base64
import http.client
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PAIR = os.path.join(ROOT, "host", "pair.py")
ENROLL = os.path.join(ROOT, "host", "enroll.py")
PIN = "123456"
TOKEN = "example-enroll-token"
MAX_FAILS = 5

PASS = 0
FAIL = 0


def check(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        PASS += 1
        print("ok   %s" % name)
    else:
        FAIL += 1
        print("FAIL %s%s" % (name, (" -- " + str(detail)) if detail else ""))


def make_key(marker, key_type="ssh-ed25519"):
    """Build one well-formed SSH public key line."""
    material = (marker * 64).encode()[:32]
    inner = (struct.pack(">I", len(key_type)) + key_type.encode()
             + struct.pack(">I", len(material)) + material)
    return "%s %s" % (key_type, base64.b64encode(inner).decode())


class Service(object):
    """A host service started on loopback, plus its port and output."""

    def __init__(self, cmd, env):
        self.cmd = cmd
        self.env = env
        self.proc = None
        self.port = 0

    def start(self, port_file, timeout=20.0):
        self.proc = subprocess.Popen(self.cmd, env=self.env,
                                     stdout=subprocess.PIPE,
                                     stderr=subprocess.STDOUT)
        deadline = time.time() + timeout
        while time.time() < deadline:
            if os.path.exists(port_file):
                try:
                    with open(port_file, "r") as handle:
                        text = handle.read().strip()
                except OSError:
                    text = ""
                if text.isdigit():
                    self.port = int(text)
                    return self
            if self.proc.poll() is not None:
                raise RuntimeError("service exited early:\n%s" % self.output())
            time.sleep(0.05)
        raise RuntimeError("service wrote no port file:\n%s" % self.output())

    def output(self):
        if self.proc is None or self.proc.stdout is None:
            return ""
        if self.proc.poll() is None:
            return "<still running>"
        return self.proc.stdout.read().decode("utf-8", "replace")

    def stop(self):
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.proc.terminate()
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait(timeout=10)

    def wait(self, timeout=10):
        return self.proc.wait(timeout=timeout)


def request(port, path, payload=None, method="POST"):
    """Return (status, parsed json). Status 0 means the server sent no reply."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    headers = {"Content-Type": "application/json"} if body else {}
    try:
        conn.request(method, path, body=body, headers=headers)
        resp = conn.getresponse()
        raw = resp.read()
        status = resp.status
    except (http.client.HTTPException, OSError):
        return 0, {}
    finally:
        conn.close()
    try:
        return status, json.loads(raw.decode("utf-8") or "{}")
    except ValueError:
        return status, {}


def listeners(port):
    """Listening socket addresses for a port, or None when lsof is missing."""
    if not shutil.which("lsof"):
        return None
    out = subprocess.run(["lsof", "-nP", "-iTCP:%d" % port, "-sTCP:LISTEN", "-Fn"],
                         capture_output=True, text=True).stdout
    addrs = [line[1:] for line in out.splitlines() if line.startswith("n")]
    return addrs


def read_lines(path):
    if not os.path.exists(path):
        return []
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return [line for line in handle.read().splitlines() if line.strip()]


class PairCase(object):
    def __init__(self, keys=(),
                 keys_text=None):
        self.tmp = tempfile.mkdtemp(prefix="herdr-pair-")
        self.state = os.path.join(self.tmp, "state")
        os.makedirs(self.state)
        self.keys = os.path.join(self.tmp, "authorized_keys")
        if keys_text is not None:
            with open(self.keys, "w", encoding="utf-8") as handle:
                handle.write(keys_text)
        elif keys:
            with open(self.keys, "w", encoding="utf-8") as handle:
                handle.write("\n".join(keys) + "\n")
        env = dict(os.environ)
        self.service = Service([
            sys.executable, PAIR,
            "--bind", "127.0.0.1",
            "--port", "0",
            "--pin", PIN,
            "--state-dir", self.state,
            "--authorized-keys", self.keys,
        ], env)
        self.port_file = os.path.join(self.state, "pair.port")
        self.pin_file = os.path.join(self.state, "pair.pin")

    def __enter__(self):
        self.service.start(self.port_file)
        return self

    def __exit__(self, *exc):
        self.service.stop()
        shutil.rmtree(self.tmp, ignore_errors=True)
        return False

    def post(self, pin, key, name="client"):
        return request(self.service.port, "/api/request",
                       {"pin": pin, "name": name, "publicKey": key})

    def current_pin(self):
        lines = read_lines(self.pin_file)
        return lines[0] if lines else PIN

    def key_lines(self):
        return read_lines(self.keys)


def enroll_case(bind=None):
    tmp = tempfile.mkdtemp(prefix="herdr-enroll-")
    keys = os.path.join(tmp, "authorized_keys")
    port_file = os.path.join(tmp, "enroll.port")
    log_file = os.path.join(tmp, "enroll.log")
    env = dict(os.environ)
    env["HERDR_ENROLL_TOKEN"] = TOKEN
    env["HERDR_ENROLL_PORT"] = "0"
    env["HERDR_ENROLL_TTL"] = "120"
    env["HERDR_ENROLL_KEYS"] = keys
    env["HERDR_ENROLL_PORTFILE"] = port_file
    env["HERDR_ENROLL_LOG"] = log_file
    env.pop("HERDR_ENROLL_BIND", None)
    if bind is not None:
        env["HERDR_ENROLL_BIND"] = bind
    service = Service([sys.executable, ENROLL], env)
    return service, tmp, keys, port_file


def test_pair_rate_limit():
    with PairCase() as case:
        statuses = [case.post("%06d" % (900000 + i), make_key("a"))[0]
                    for i in range(1, MAX_FAILS + 1)]
        status, _ = case.post("999999", make_key("a"))
    check("pair: wrong PIN is 401", statuses[0] == 401, statuses)
    check("pair: sixth wrong attempt is 429", status == 429, status)


def test_pair_non_ascii_pin():
    with PairCase() as case:
        status, body = case.post("\u0661\u0662\u0663\u0664\u0665\u0666", make_key("a"))
        check("pair: non-ASCII PIN answers JSON, not a dead connection",
              status in (400, 401) and body.get("ok") is False,
              (status, body))
        counted = [case.post("999999", make_key("a"))[0] for _ in range(MAX_FAILS - 1)]
        blocked, _ = case.post("999999", make_key("a"))
    check("pair: non-ASCII attempt is counted", blocked == 429,
          (counted, blocked))


def test_pair_exact_blob():
    existing = make_key("x")
    blob = existing.split()[1]
    with PairCase(keys=[existing]) as case:
        status, body = case.post(PIN, "ssh-ed25519 %s client" % blob[:32])
        lines = case.key_lines()
    check("pair: a 32-character blob prefix is not accepted",
          not (status == 200 and body.get("alreadyPresent") is True),
          (status, body))
    check("pair: a blob prefix is not written to authorized_keys",
          lines == [existing], lines)


def test_pair_present_and_append():
    existing = make_key("x")
    fresh = make_key("y")
    fresh_blob = fresh.split()[1]
    with PairCase(keys=[existing]) as case:
        status, body = case.post(case.current_pin(), existing)
        check("pair: the same key reports already present",
              status == 200 and body.get("alreadyPresent") is True, (status, body))
        check("pair: the same key is not appended again",
              case.key_lines() == [existing], case.key_lines())

        status, body = case.post(case.current_pin(), fresh)
        check("pair: a new key is accepted",
              status == 200 and body.get("alreadyPresent") is False, (status, body))
        lines = case.key_lines()
        check("pair: a new key is appended exactly once",
              len(lines) == 2 and lines[0] == existing
              and lines[1].split()[1] == fresh_blob, lines)

        rotated = case.current_pin()
        check("pair: the PIN rotates after a success", rotated != PIN, rotated)
        status, body = case.post(rotated, fresh)
        check("pair: the same key is idempotent",
              status == 200 and body.get("alreadyPresent") is True
              and len(case.key_lines()) == 2, (status, body, case.key_lines()))


def test_enroll_bind():
    service, tmp, keys, port_file = enroll_case(bind="127.0.0.1")
    try:
        service.start(port_file)
        addrs = listeners(service.port)
        if addrs is None:
            print("skip enroll: lsof not available")
            return
        check("enroll: listens on the configured loopback address",
              any(a.startswith("127.0.0.1:") for a in addrs), addrs)
        check("enroll: does not listen on every interface",
              not any(a.startswith("*:") or a.startswith("0.0.0.0:") for a in addrs),
              addrs)
    finally:
        service.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def test_enroll_default_bind():
    service, tmp, keys, port_file = enroll_case()
    try:
        service.start(port_file)
        addrs = listeners(service.port)
        if addrs is None:
            print("skip enroll: lsof not available")
            return
        check("enroll: the default is not the wildcard address",
              not any(a.startswith("*:") or a.startswith("0.0.0.0:") for a in addrs),
              addrs)
    finally:
        service.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def test_enroll_limits():
    service, tmp, keys, port_file = enroll_case(bind="127.0.0.1")
    try:
        service.start(port_file)

        status, body = request(service.port, "/enroll",
                               {"code": "\u2460\u2461\u2462", "key": make_key("a")})
        check("enroll: non-ASCII code answers JSON, not a dead connection",
              status in (400, 401) and body.get("ok") is False, (status, body))

        statuses = [request(service.port, "/enroll",
                            {"code": "wrong", "key": make_key("a")})[0]
                    for _ in range(MAX_FAILS - 1)]
        blocked, _ = request(service.port, "/enroll",
                             {"code": "wrong", "key": make_key("a")})
        check("enroll: a wrong code is 401", statuses[0] == 401, statuses)
        check("enroll: attempts are limited per source", blocked == 429, blocked)
    finally:
        service.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def test_enroll_prefix():
    existing = make_key("x")
    blob = existing.split()[1]
    service, tmp, keys, port_file = enroll_case(bind="127.0.0.1")
    try:
        with open(keys, "w", encoding="utf-8") as handle:
            handle.write(existing + "\n")
        service.start(port_file)
        status, body = request(service.port, "/enroll",
                               {"code": TOKEN,
                                "key": "ssh-ed25519 %s client" % blob[:32]})
        check("enroll: a blob prefix is not accepted",
              not (status == 200 and body.get("alreadyPresent") is True), (status, body))
        lines = read_lines(keys)
        check("enroll: a blob prefix is not written", lines == [existing], lines)
    finally:
        service.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def test_enroll_success_once():
    fresh = make_key("y")
    service, tmp, keys, port_file = enroll_case(bind="127.0.0.1")
    try:
        service.start(port_file)
        status, body = request(service.port, "/enroll", {"code": TOKEN, "key": fresh})
        check("enroll: a correct code accepts the key", status == 200, (status, body))
        check("enroll: the key is appended once", read_lines(keys) == [fresh],
              read_lines(keys))
        rc = service.wait(timeout=15)
        check("enroll: the listener stops after one success", rc == 0, rc)
    finally:
        service.stop()
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    if not os.path.isfile(PAIR) or not os.path.isfile(ENROLL):
        print("pair.py or enroll.py not found under %s" % ROOT)
        return 2
    test_pair_rate_limit()
    test_pair_non_ascii_pin()
    test_pair_exact_blob()
    test_pair_present_and_append()
    test_enroll_bind()
    test_enroll_default_bind()
    test_enroll_limits()
    test_enroll_prefix()
    test_enroll_success_once()
    print("")
    print("%d passed, %d failed" % (PASS, FAIL))
    return 0 if FAIL == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
