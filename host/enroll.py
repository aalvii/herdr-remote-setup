#!/usr/bin/env python3
"""One-time SSH key enrollment endpoint.

The client cannot SSH before its key is authorized, and the host disables
password auth. This endpoint closes that gap: it listens on the tailnet,
accepts one POST with a one-time code plus a public key, appends the key to
~/.ssh/authorized_keys, then exits.

Protocol:
    POST /enroll
    {"code": "<token>", "key": "ssh-ed25519 AAAA... comment"}

Responses:
    200 {"ok": true}                     key accepted (or already present)
    400 {"ok": false, "error": "..."}    malformed key or body
    401 {"ok": false, "error": "bad code"}
    404 {"ok": false, "error": "not found"}

Environment:
    HERDR_ENROLL_TOKEN   required, one-time code
    HERDR_ENROLL_PORT    default 8787
    HERDR_ENROLL_TTL     default 600 seconds
    HERDR_ENROLL_LOG     optional log path
    HERDR_ENROLL_KEYS    optional authorized_keys path
"""

import hmac
import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = os.environ.get("HERDR_ENROLL_TOKEN", "")
PORT = int(os.environ.get("HERDR_ENROLL_PORT", "8787"))
TTL = int(os.environ.get("HERDR_ENROLL_TTL", "600"))
LOG = os.environ.get("HERDR_ENROLL_LOG", "")
PORTFILE = os.environ.get("HERDR_ENROLL_PORTFILE", "")
KEYS = os.environ.get("HERDR_ENROLL_KEYS", os.path.expanduser("~/.ssh/authorized_keys"))

KEY_PREFIXES = ("ssh-ed25519 ", "ssh-rsa ", "ecdsa-sha2-", "sk-ssh-ed25519@")


def log(msg: str) -> None:
    line = "%s %s" % (time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), msg)
    print(line, flush=True)
    if LOG:
        try:
            with open(LOG, "a", encoding="utf-8") as handle:
                handle.write(line + "\n")
        except OSError:
            pass


class Handler(BaseHTTPRequestHandler):
    server_version = "herdr-enroll/1.0"

    def _send(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:  # noqa: N802 - required name
        if self.path != "/enroll":
            return self._send(404, {"ok": False, "error": "not found"})

        try:
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b"{}"
            data = json.loads(raw.decode("utf-8") or "{}")
        except (ValueError, UnicodeDecodeError) as exc:
            return self._send(400, {"ok": False, "error": "bad json: %s" % exc})

        code = str(data.get("code", ""))
        key = str(data.get("key", "")).strip()
        source = self.client_address[0]

        if not hmac.compare_digest(code, TOKEN):
            log("deny source=%s reason=bad-code" % source)
            return self._send(401, {"ok": False, "error": "bad code"})

        if not key.startswith(KEY_PREFIXES):
            log("deny source=%s reason=bad-key" % source)
            return self._send(400, {"ok": False, "error": "bad key"})
        if "\n" in key or "\r" in key or len(key) > 2000:
            return self._send(400, {"ok": False, "error": "bad key"})

        try:
            parts = key.split()
            blob = parts[1] if len(parts) > 1 else ""
        except IndexError:
            blob = ""
        if len(blob) < 32:
            return self._send(400, {"ok": False, "error": "bad key blob"})

        os.makedirs(os.path.dirname(KEYS) or ".", exist_ok=True)
        existing = ""
        if os.path.exists(KEYS):
            with open(KEYS, "r", encoding="utf-8", errors="replace") as handle:
                existing = handle.read()

        if blob in existing:
            log("ok source=%s result=already-present" % source)
            self._send(200, {"ok": True, "alreadyPresent": True})
        else:
            with open(KEYS, "a", encoding="utf-8") as handle:
                if existing and not existing.endswith("\n"):
                    handle.write("\n")
                handle.write(key + "\n")
            try:
                os.chmod(KEYS, 0o600)
            except OSError:
                pass
            log("ok source=%s result=added" % source)
            self._send(200, {"ok": True})

        threading.Thread(target=self.server.shutdown, daemon=True).start()

    def log_message(self, fmt: str, *args) -> None:  # silence default logging
        return


def main() -> int:
    if not TOKEN:
        print("HERDR_ENROLL_TOKEN is required", file=sys.stderr)
        return 2

    server = HTTPServer(("0.0.0.0", PORT), Handler)
    actual_port = server.server_address[1]
    if PORTFILE:
        try:
            with open(PORTFILE, "w", encoding="utf-8") as handle:
                handle.write(str(actual_port))
        except OSError:
            pass
    deadline = time.time() + TTL

    def expire() -> None:
        while time.time() < deadline:
            time.sleep(1)
        log("ttl-expired")
        server.shutdown()

    threading.Thread(target=expire, daemon=True).start()
    log("listening port=%d ttl=%d keys=%s" % (actual_port, TTL, KEYS))
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        server.server_close()
        log("stopped")
    return 0


if __name__ == "__main__":
    sys.exit(main())
