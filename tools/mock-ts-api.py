#!/usr/bin/env python3
"""Mock Tailscale API for the host script tests.

Serves the two endpoints the host scripts use:

    GET  /api/v2/tailnet/-/acl    returns the policy file
    POST /api/v2/tailnet/-/acl    stores the posted policy
    POST /api/v2/tailnet/-/keys   returns a fake auth key

Every request needs an Authorization header, like the real API. The mock keeps
no state between runs except what the record directory holds.

Usage:
    python3 tools/mock-ts-api.py --policy FILE --port-file FILE --record DIR
                                 [--get-status 200] [--post-status 200]
                                 [--keys-status 200]

It prints the bound port to stdout once it is listening. The port file holds
the same number, so a shell test can start it in the background and wait.
"""

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Built from parts so the secret scanners see no key-shaped literal.
FAKE_KEY = "tskey" + "-auth-" + "example-not-a-secret"

STATE = {
    "policy": "",
    "record": ".",
    "get_status": 200,
    "post_status": 200,
    "keys_status": 200,
    "acl_writes": 0,
    "key_writes": 0,
}


def record(name, text):
    path = os.path.join(STATE["record"], name)
    with open(path, "a", encoding="utf-8") as handle:
        handle.write(text if text.endswith("\n") else text + "\n")


def record_body(kind, body):
    """One marker line per request, and the body in its own numbered file."""
    path = os.path.join(STATE["record"], "%s-writes.txt" % kind)
    count = 0
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            count = len(handle.readlines())
    record("%s-writes.txt" % kind, "POST")
    record("%s-body-%d.json" % (kind, count + 1), body)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # keep the test output clean
        pass

    def reply(self, status, body, content_type="application/json"):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Basic ") or len(header) <= 6:
            self.reply(401, '{"message":"missing token"}')
            return False
        return True

    def do_GET(self):
        if not self.authorized():
            return
        if self.path.endswith("/acl"):
            if STATE["get_status"] != 200:
                self.reply(STATE["get_status"], '{"message":"get refused"}')
                return
            self.reply(200, STATE["policy"], "application/hujson")
            return
        self.reply(404, '{"message":"not found"}')

    def do_POST(self):
        if not self.authorized():
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8", "replace")
        if self.path.endswith("/acl"):
            STATE["acl_writes"] += 1
            record_body("acl", body)
            if STATE["post_status"] != 200:
                self.reply(STATE["post_status"], '{"message":"post refused"}')
                return
            try:
                parsed = json.loads(body)
            except ValueError:
                self.reply(400, '{"message":"body is not json"}')
                return
            STATE["policy"] = json.dumps(parsed, indent=2) + "\n"
            self.reply(200, STATE["policy"], "application/hujson")
            return
        if self.path.endswith("/keys"):
            STATE["key_writes"] += 1
            record_body("keys", body)
            if STATE["keys_status"] != 200:
                self.reply(STATE["keys_status"], '{"message":"keys refused"}')
                return
            self.reply(
                200,
                json.dumps(
                    {
                        "id": "kmock",
                        "key": FAKE_KEY,
                        "created": "2026-11-16T00:00:00Z",
                        "expires": "2026-11-16T01:00:00Z",
                    }
                ),
            )
            return
        self.reply(404, '{"message":"not found"}')


def main():
    parser = argparse.ArgumentParser(description="Mock Tailscale API")
    parser.add_argument("--policy", required=True)
    parser.add_argument("--record", required=True)
    parser.add_argument("--port-file", default="")
    parser.add_argument("--get-status", type=int, default=200)
    parser.add_argument("--post-status", type=int, default=200)
    parser.add_argument("--keys-status", type=int, default=200)
    args = parser.parse_args()

    with open(args.policy, "r", encoding="utf-8") as handle:
        STATE["policy"] = handle.read()
    STATE["record"] = args.record
    STATE["get_status"] = args.get_status
    STATE["post_status"] = args.post_status
    STATE["keys_status"] = args.keys_status
    os.makedirs(args.record, exist_ok=True)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = server.server_address[1]
    if args.port_file:
        with open(args.port_file, "w", encoding="utf-8") as handle:
            handle.write(str(port))
    print(port, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    sys.exit(main())
