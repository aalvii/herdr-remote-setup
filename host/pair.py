#!/usr/bin/env python3
"""PIN pairing service for the simple Herdr share flow.

The host runs this service on its Tailscale address. The client sends its SSH
public key and the 6-digit PIN shown on the host screen. On a correct PIN the
key is appended to authorized_keys, and the client can connect over SSH.

Protocol:
    GET  /api/info      -> service, version, host, user, port
    GET  /api/health    -> ok
    POST /api/request   -> {"pin": "123456", "name": "PC", "publicKey": "ssh-..."}
                           {"ok": true, "alreadyPresent": false}

Security:
    - bind to the Tailscale address only
    - 6-digit PIN, constant-time compare
    - 5 wrong attempts per source address in 5 minutes
    - no PIN or key in the log
"""

import argparse
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SERVICE = "herdr-pair"
PROTOCOL = 1
MAX_BODY = 8192
KEY_PREFIXES = (
    "ssh-ed25519 ",
    "ssh-rsa ",
    "ecdsa-sha2-",
    "sk-ssh-ed25519@",
    "sk-ecdsa-sha2-",
)

ARGS = None
PIN = ""
PIN_FILE = ""
PORT_FILE = ""
LOG_FILE = ""
SERVER = None
LOCK = threading.Lock()
FAILS = {}


def log(msg):
    line = "%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg)
    print(line, flush=True)
    if LOG_FILE:
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
                os.chmod(LOG_FILE, 0o600)
        except OSError:
            pass


def new_pin():
    return "%06d" % (100000 + secrets.randbelow(900000))


def write_text(path, text):
    try:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(path, 0o600)
    except OSError:
        pass


def set_pin(pin):
    global PIN
    PIN = pin
    write_text(PIN_FILE, PIN + "\n")
    print("", flush=True)
    print("  PIN: %s" % PIN, flush=True)
    print("", flush=True)


def valid_key(key):
    if not key or len(key) > 2000:
        return False
    if "\n" in key or "\r" in key:
        return False
    if not key.startswith(KEY_PREFIXES):
        return False
    parts = key.split()
    if len(parts) < 2:
        return False
    return len(parts[1]) >= 32


def sanitize(value, limit=64):
    value = re.sub(r"[^A-Za-z0-9_.-]", "_", str(value or "client"))
    return value[:limit] or "client"


def append_key(key, name):
    path = os.path.expanduser(ARGS.authorized_keys)
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    try:
        os.chmod(directory, 0o700)
    except OSError:
        pass

    existing = ""
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            existing = handle.read()

    blob = key.split()[1]
    if blob in existing:
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass
        return True

    line = key.strip()
    with open(path, "a", encoding="utf-8") as handle:
        if existing and not existing.endswith("\n"):
            handle.write("\n")
        handle.write(line + "\n")
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
    return False


def rate_limited(source):
    now = time.time()
    with LOCK:
        times = [t for t in FAILS.get(source, []) if now - t < 300]
        FAILS[source] = times
        return len(times) >= 5


def record_fail(source):
    with LOCK:
        FAILS.setdefault(source, []).append(time.time())


class Handler(BaseHTTPRequestHandler):
    server_version = "herdr-pair/1"

    def _json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path == "/api/info":
            return self._json(200, {
                "service": SERVICE,
                "version": PROTOCOL,
                "host": os.uname().nodename if hasattr(os, "uname") else os.environ.get("COMPUTERNAME", ""),
                "user": os.environ.get("USER") or os.environ.get("USERNAME") or "",
                "port": SERVER.server_address[1],
            })
        if self.path == "/api/health":
            return self._json(200, {"ok": True})
        return self._json(404, {"ok": False, "error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path != "/api/request":
            return self._json(404, {"ok": False, "error": "not found"})

        source = self.client_address[0]
        if rate_limited(source):
            log("deny source=%s reason=rate-limit" % source)
            return self._json(429, {"ok": False, "error": "too many attempts"})

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                return self._json(400, {"ok": False, "error": "bad body"})
            data = json.loads(self.rfile.read(length).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return self._json(400, {"ok": False, "error": "bad json"})

        pin = str(data.get("pin", ""))
        key = str(data.get("publicKey", "")).strip()
        name = sanitize(data.get("name", "client"))

        if not hmac.compare_digest(pin, PIN):
            record_fail(source)
            log("deny source=%s name=%s reason=bad-pin" % (source, name))
            return self._json(401, {"ok": False, "error": "bad pin"})

        if not valid_key(key):
            log("deny source=%s name=%s reason=bad-key" % (source, name))
            return self._json(400, {"ok": False, "error": "bad key"})

        try:
            already = append_key(key, name)
        except OSError as exc:
            log("error name=%s source=%s reason=%s" % (name, source, exc))
            return self._json(500, {"ok": False, "error": "cannot write keys"})

        log("paired name=%s source=%s result=%s" % (
            name, source, "already-present" if already else "added"))

        self._json(200, {"ok": True, "alreadyPresent": already})

        if ARGS.once:
            threading.Thread(target=SERVER.shutdown, daemon=True).start()
        else:
            set_pin(new_pin())


def main():
    global ARGS, PIN_FILE, PORT_FILE, LOG_FILE, SERVER

    parser = argparse.ArgumentParser(description="Herdr PIN pairing service")
    parser.add_argument("--bind", default="127.0.0.1",
                        help="address to bind, usually the Tailscale IPv4")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--pin", default="")
    parser.add_argument("--ttl", type=int, default=1800)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--state-dir", default=os.path.expanduser(
        "~/.local/state/herdr-setup"))
    parser.add_argument("--authorized-keys", default=os.path.expanduser(
        "~/.ssh/authorized_keys"))
    args = parser.parse_args()
    ARGS = args

    os.makedirs(args.state_dir, exist_ok=True)
    PIN_FILE = os.path.join(args.state_dir, "pair.pin")
    PORT_FILE = os.path.join(args.state_dir, "pair.port")
    LOG_FILE = os.path.join(args.state_dir, "pair.log")

    pin = args.pin or new_pin()
    if not re.fullmatch(r"[0-9]{6}", pin):
        print("PIN must be 6 digits", file=sys.stderr)
        return 2

    try:
        SERVER = ThreadingHTTPServer((args.bind, args.port), Handler)
    except OSError as exc:
        print("cannot listen on %s:%s: %s" % (args.bind, args.port, exc),
              file=sys.stderr)
        print("Stop the service that owns the port, or pass --port.", file=sys.stderr)
        return 2

    actual_port = SERVER.server_address[1]
    write_text(PORT_FILE, str(actual_port) + "\n")
    write_text(PIN_FILE, pin + "\n")
    global PIN
    PIN = pin

    host = os.uname().nodename if hasattr(os, "uname") else os.environ.get("COMPUTERNAME", "")
    user = os.environ.get("USER") or os.environ.get("USERNAME") or ""
    print("")
    print("================================================================")
    print("  Herdr Share")
    print("================================================================")
    print("")
    print("  Computer : %s" % host)
    print("  User     : %s" % user)
    print("  Address  : %s:%s" % (args.bind, actual_port))
    print("  PIN      : %s" % pin)
    print("")
    print("  Give the PIN to the other computer. It expires in %ds." % args.ttl)
    print("  Ctrl+C stops sharing.")
    print("")

    def expire():
        time.sleep(max(1, args.ttl))
        log("ttl-expired")
        SERVER.shutdown()

    threading.Thread(target=expire, daemon=True).start()
    log("listening bind=%s port=%d ttl=%d" % (args.bind, actual_port, args.ttl))

    try:
        SERVER.serve_forever(poll_interval=0.5)
    except KeyboardInterrupt:
        pass
    finally:
        SERVER.server_close()
        for path in (PIN_FILE, PORT_FILE):
            try:
                os.unlink(path)
            except OSError:
                pass
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
