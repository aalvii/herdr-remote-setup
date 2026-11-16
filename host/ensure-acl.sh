#!/usr/bin/env bash
# Ensure the tailnet policy lets tagged guests reach this host.
#
# Reads the policy with the Tailscale API, adds only the entries that are
# missing, writes it back, and verifies the result. The script never removes or
# changes another rule, and it never resets the policy. When the entries are
# already present it writes nothing.
#
# Required entries:
#   tagOwners.tag:client    a tag owner, so the guest key's tag is legal
#   tag:client -> tag:herdr-host on tcp:22 and tcp:8765
#
# Usage:
#   ./ensure-acl.sh                 ensure and verify
#   ./ensure-acl.sh --no-acl-write  verify only, never write
#   ./ensure-acl.sh --self-test     run the fixtures, no network
#
# Exit codes:
#   0  the ACL is ready (already was, or added and verified)
#   2  prerequisite missing (python3, API key file)
#   3  not ready and not writable (refused, API error, unparsable policy)
#
# The API key needs auth-key creation and ACL read/write:
#   /etc/herdr-setup/tailscale-api.key   (root, mode 600)
#
# Environment overrides, for tests:
#   HERDR_TS_API_KEY_FILE  key file path
#   HERDR_TS_API_URL       API base URL
#   HERDR_TS_TAILNET       tailnet name, default -
#   HERDR_ACL_BACKUP_DIR   where the policy backup goes

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || dirname "$0")"
VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "0.0.0")"
KEY_FILE="${HERDR_TS_API_KEY_FILE:-/etc/herdr-setup/tailscale-api.key}"
API_URL="${HERDR_TS_API_URL:-https://api.tailscale.com/api/v2}"
TAILNET="${HERDR_TS_TAILNET:--}"
BACKUP_DIR="${HERDR_ACL_BACKUP_DIR:-/etc/herdr-setup}"

MODE="ensure"
while [ $# -gt 0 ]; do
  case "$1" in
    --no-acl-write) MODE="verify" ;;
    --self-test) MODE="self-test" ;;
    --help|-h) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "X unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "X python3 is required (macOS: xcode-select --install)" >&2
  exit 2
fi

if [ "$MODE" != "self-test" ]; then
  echo "Herdr ACL check v$VERSION"
  echo "  Policy   : $API_URL/tailnet/$TAILNET/acl"
  echo "  Key file : $KEY_FILE"
  echo ""
  if [ ! -r "$KEY_FILE" ]; then
    echo "X no Tailscale API token at $KEY_FILE" >&2
    echo "  The token needs auth-key creation and ACL read/write." >&2
    exit 2
  fi
fi

HERDR_ACL_VERSION="$VERSION" python3 - "$MODE" <<'PY'
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("HERDR_TS_API_URL", "https://api.tailscale.com/api/v2").rstrip("/")
TAILNET = os.environ.get("HERDR_TS_TAILNET", "-")
KEY_FILE = os.environ.get("HERDR_TS_API_KEY_FILE", "/etc/herdr-setup/tailscale-api.key")
BACKUP_DIR = os.environ.get("HERDR_ACL_BACKUP_DIR", "/etc/herdr-setup")

GUEST_TAG = "tag:client"
HOST_TAG = "tag:herdr-host"
PORTS = ("tcp:22", "tcp:8765")

SNIPPET = {
    "tagOwners": {GUEST_TAG: ["autogroup:admin"]},
    "grants": [
        {"src": [GUEST_TAG], "dst": [HOST_TAG], "ip": list(PORTS)},
    ],
}


def strip_hujson(text):
    """Turn HuJSON into JSON. Removes comments and trailing commas."""
    out = []
    i = 0
    n = len(text)
    in_string = False
    escaped = False
    while i < n:
        char = text[i]
        if in_string:
            out.append(char)
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            i += 1
            continue
        if char == '"':
            in_string = True
            out.append(char)
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            i = n if end < 0 else end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        out.append(char)
        i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def parse_policy(text):
    return json.loads(strip_hujson(text))


def port_of_dst(value):
    """Return the port part of a legacy acl dst such as tag:herdr-host:22."""
    if not isinstance(value, str) or ":" not in value:
        return ""
    return value.rsplit(":", 1)[1]


def grant_entries(policy):
    grants = policy.get("grants")
    if not isinstance(grants, list):
        return []
    return [
        item
        for item in grants
        if isinstance(item, dict)
        and GUEST_TAG in (item.get("src") or [])
        and HOST_TAG in (item.get("dst") or [])
    ]


def missing_entries(policy):
    """Return one line per required entry that is absent."""
    problems = []
    if not isinstance(policy, dict):
        return ["policy is not an object"]

    owners = policy.get("tagOwners")
    if not isinstance(owners, dict) or not owners.get(GUEST_TAG):
        problems.append("tagOwners has no %s owner" % GUEST_TAG)

    if isinstance(policy.get("grants"), list):
        entries = grant_entries(policy)
        if not entries:
            problems.append("grants has no %s -> %s rule" % (GUEST_TAG, HOST_TAG))
        else:
            allowed = set()
            for entry in entries:
                allowed.update(entry.get("ip") or [])
            if "*" not in allowed:
                for port in PORTS:
                    if port not in allowed:
                        problems.append("grant lacks %s" % port)
    elif isinstance(policy.get("acls"), list):
        reached = set()
        for entry in policy["acls"]:
            if not isinstance(entry, dict):
                continue
            if GUEST_TAG not in (entry.get("src") or []):
                continue
            for dest in entry.get("dst") or []:
                reached.add(port_of_dst(dest))
        for port in PORTS:
            if "*" not in reached and port.split(":")[1] not in reached:
                problems.append("acls has no %s -> %s on %s" % (GUEST_TAG, HOST_TAG, port))
    else:
        problems.append("policy has neither grants nor acls")

    return problems


def merge_entries(policy, problems):
    """Add the missing entries. Return (policy, added lines)."""
    merged = json.loads(json.dumps(policy))
    added = []

    owners = merged.get("tagOwners")
    if not isinstance(owners, dict):
        owners = {}
        merged["tagOwners"] = owners
    if not owners.get(GUEST_TAG):
        owners[GUEST_TAG] = ["autogroup:admin"]
        added.append("tagOwners.%s = autogroup:admin" % GUEST_TAG)

    if isinstance(merged.get("grants"), list):
        entries = grant_entries(merged)
        if not entries:
            merged["grants"].append(
                {"src": [GUEST_TAG], "dst": [HOST_TAG], "ip": list(PORTS)}
            )
            added.append("grants %s -> %s on %s" % (GUEST_TAG, HOST_TAG, ", ".join(PORTS)))
        else:
            allowed = set()
            for entry in entries:
                allowed.update(entry.get("ip") or [])
            missing_ports = [port for port in PORTS if port not in allowed]
            if missing_ports:
                entries[0]["ip"] = list(entries[0].get("ip") or []) + missing_ports
                added.append(
                    "grants %s -> %s add %s"
                    % (GUEST_TAG, HOST_TAG, ", ".join(missing_ports))
                )
    elif isinstance(merged.get("acls"), list):
        reached = set()
        for entry in merged["acls"]:
            if isinstance(entry, dict) and GUEST_TAG in (entry.get("src") or []):
                for dest in entry.get("dst") or []:
                    reached.add(port_of_dst(dest))
        want = [
            "%s:%s" % (HOST_TAG, port.split(":")[1])
            for port in PORTS
            if port.split(":")[1] not in reached and "*" not in reached
        ]
        if want:
            merged["acls"].append({"action": "accept", "src": [GUEST_TAG], "dst": want})
            added.append("acls %s -> %s" % (GUEST_TAG, ", ".join(want)))
    else:
        merged["grants"] = [
            {"src": [GUEST_TAG], "dst": [HOST_TAG], "ip": list(PORTS)}
        ]
        added.append("grants %s -> %s on %s" % (GUEST_TAG, HOST_TAG, ", ".join(PORTS)))

    return merged, added


def read_key():
    with open(KEY_FILE, "r", encoding="utf-8") as handle:
        return handle.read().strip()


def call(method, path, body=None, key=""):
    url = "%s/tailnet/%s/%s" % (API, TAILNET, path)
    data = None if body is None else body.encode("utf-8")
    request = urllib.request.Request(url, data=data, method=method)
    token = base64.b64encode((key + ":").encode("utf-8")).decode("ascii")
    request.add_header("Authorization", "Basic " + token)
    request.add_header("Accept", "application/hujson, application/json")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")
    except Exception as error:  # network, DNS, TLS
        return 0, str(error)


def print_snippet():
    print("")
    print("Add this to the tailnet policy:")
    print(json.dumps(SNIPPET, indent=2))


def backup(text):
    os.makedirs(BACKUP_DIR, mode=0o700, exist_ok=True)
    path = os.path.join(
        BACKUP_DIR, "acl-backup-%s.hujson" % time.strftime("%Y%m%d-%H%M%S")
    )
    handle = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(handle, "w", encoding="utf-8") as file:
        file.write(text)
    os.chmod(path, 0o600)
    return path


def run(mode):
    key = read_key()
    status, text = call("GET", "acl", key=key)
    if status in (401, 403):
        print("! the API token cannot read the policy (HTTP %d)" % status)
        print_snippet()
        return 3
    if status != 200:
        print("! cannot read the policy (HTTP %d)" % status)
        detail = text.strip().splitlines()[:3]
        for line in detail:
            print("  " + line)
        return 3

    try:
        policy = parse_policy(text)
    except ValueError as error:
        print("! the policy cannot be parsed: %s" % error)
        print("  Nothing was written. The policy is unchanged.")
        print_snippet()
        return 3

    problems = missing_entries(policy)
    if not problems:
        print("ACL already allows %s" % GUEST_TAG)
        return 0

    for problem in problems:
        print("! " + problem)

    if mode == "verify":
        print("! --no-acl-write: the policy was not changed")
        print_snippet()
        return 3

    merged, added = merge_entries(policy, problems)
    if not added:
        print("! the required entries are present but the policy is not ready")
        print_snippet()
        return 3

    try:
        saved = backup(text)
    except OSError as error:
        print("! cannot save the policy backup: %s" % error)
        print("  Nothing was written.")
        return 3
    print(">> saved policy backup: %s" % saved)

    status, text = call("POST", "acl", body=json.dumps(merged, indent=2) + "\n", key=key)
    if status in (401, 403):
        print("! the API token cannot write the policy (HTTP %d)" % status)
        print_snippet()
        return 3
    if status not in (200, 204):
        print("! the policy write failed (HTTP %d)" % status)
        for line in text.strip().splitlines()[:3]:
            print("  " + line)
        print("  Restore the backup if the policy changed.")
        return 3

    for line in added:
        print(">> added " + line)

    status, text = call("GET", "acl", key=key)
    if status != 200:
        print("! cannot verify the policy (HTTP %d)" % status)
        return 3
    try:
        after = missing_entries(parse_policy(text))
    except ValueError as error:
        print("! the policy read back cannot be parsed: %s" % error)
        return 3
    if after:
        for problem in after:
            print("! still missing: " + problem)
        return 3

    print("ACL updated and verified")
    return 0


def self_test():
    failures = 0

    def check(name, condition):
        nonlocal failures
        if condition:
            print("ok %s" % name)
        else:
            failures += 1
            print("FAIL %s" % name)

    ready = {
        "tagOwners": {"tag:client": ["autogroup:admin"], "tag:herdr-host": ["autogroup:admin"]},
        "grants": [{"src": ["tag:client"], "dst": ["tag:herdr-host"], "ip": ["tcp:22", "tcp:8765"]}],
        "hosts": {"nas": "100.64.0.5"},
        "ssh": [{"action": "check", "src": ["autogroup:member"], "dst": ["tag:herdr-host"], "users": ["box"]}],
    }
    check("ready policy has no problems", missing_entries(ready) == [])

    empty = {
        "tagOwners": {"tag:herdr-host": ["autogroup:admin"]},
        "grants": [{"src": ["tag:client"], "dst": ["tag:herdr-host"], "ip": ["tcp:22"]}],
        "hosts": {"nas": "100.64.0.5"},
        "ssh": [{"action": "check", "src": ["autogroup:member"], "dst": ["tag:herdr-host"], "users": ["box"]}],
    }
    problems = missing_entries(empty)
    check("missing grant port is reported", any("tcp:8765" in item for item in problems))
    check("missing tag owner is reported", any("tagOwners" in item for item in problems))

    merged, added = merge_entries(empty, problems)
    check("merge adds the tag owner", merged["tagOwners"][GUEST_TAG] == ["autogroup:admin"])
    check("merge adds the missing port", "tcp:8765" in merged["grants"][0]["ip"])
    check("merge keeps the other port", "tcp:22" in merged["grants"][0]["ip"])
    check("merge keeps hosts", merged["hosts"] == empty["hosts"])
    check("merge keeps ssh", merged["ssh"] == empty["ssh"])
    check("merge reports its work", len(added) == 2)
    check("merged policy is ready", missing_entries(merged) == [])

    fresh = {"grants": []}
    merged, added = merge_entries(fresh, missing_entries(fresh))
    check("fresh policy gets a grant", missing_entries(merged) == [])
    check("fresh policy keeps grants a list", isinstance(merged["grants"], list))

    legacy = {
        "tagOwners": {"tag:client": ["autogroup:admin"]},
        "acls": [
            {"action": "accept", "src": ["autogroup:member"], "dst": ["tag:herdr-host:22"]},
        ],
    }
    problems = missing_entries(legacy)
    merged, added = merge_entries(legacy, problems)
    check("legacy policy gets a guest acl", len(merged["acls"]) == 2)
    check("legacy guest acl names both ports", merged["acls"][1]["dst"] == [
        "tag:herdr-host:22",
        "tag:herdr-host:8765",
    ])
    check("legacy policy is ready after merge", missing_entries(merged) == [])
    check("legacy merge keeps the old acl", merged["acls"][0]["src"] == ["autogroup:member"])

    hujson = """{
  // guest devices
  "tagOwners": {"tag:client": ["autogroup:admin"],},
  "grants": [
    {"src": ["tag:client"], "dst": ["tag:herdr-host"], "ip": ["tcp:22", "tcp:8765"],},
  ],
  "hosts": {"nas": "100.64.0.5"},
}"""
    parsed = parse_policy(hujson)
    check("hujson comments and trailing commas parse", parsed["hosts"]["nas"] == "100.64.0.5")
    check("hujson policy is ready", missing_entries(parsed) == [])

    try:
        parse_policy("{ not json")
        check("malformed policy raises", False)
    except ValueError:
        check("malformed policy raises", True)

    unknown = {"tagOwners": {}, "nodeAttrs": []}
    check("unknown shape is refused", missing_entries(unknown) != [])

    if failures:
        print("self-test failed (%d)" % failures)
        return 1
    print("self-test ok")
    return 0


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "ensure"
    if mode == "self-test":
        return self_test()
    return run(mode)


if __name__ == "__main__":
    sys.exit(main())
PY
