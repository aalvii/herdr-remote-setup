#!/usr/bin/env python3
"""Fail when a file looks like it carries a secret or private identity.

This is the repository guard. It runs in CI and locally. It prints only the
rule and location, never the matched value.

Usage:
    python3 tools/check-public.py [--root DIR] [--denylist FILE]

Exit codes:
    0 clean
    1 findings
    2 usage error
"""

import argparse
import os
import re
import subprocess
import sys

SKIP_DIRS = {".git", ".audit", "__pycache__", "node_modules", "dist", ".venv"}
BINARY_EXT = {
    ".zip", ".png", ".jpg", ".jpeg", ".gif", ".ico", ".exe", ".dll", ".pdf",
    ".woff", ".woff2", ".ttf", ".otf", ".so", ".dylib", ".bin", ".gz", ".xz",
}

ALLOWED_HOME_USERS = {"user", "alice", "example", "your-user", "someone"}
ALLOWED_WIN_USERS = {"%USERNAME%", "<user>", "Public", "alice", "example"}


def is_placeholder_key(token: str) -> bool:
    lowered = token.lower()
    if "example" in lowered:
        return True
    return len(set(lowered)) <= 1


def tskey_filter(match: re.Match) -> bool:
    return not is_placeholder_key(match.group(1))


def home_filter(match: re.Match) -> bool:
    return match.group(1) not in ALLOWED_HOME_USERS


def win_filter(match: re.Match) -> bool:
    return match.group(1) not in ALLOWED_WIN_USERS


RULES = [
    (
        "private-key-header",
        re.compile(r"-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----"),
        None,
    ),
    (
        "tailscale-auth-key",
        re.compile(r"tskey-auth-([A-Za-z0-9_-]{6,})"),
        tskey_filter,
    ),
    (
        "openssh-public-key",
        re.compile(
            r"(?:ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)"
            r"|sk-ssh-ed25519@openssh\.com)\s+AAAA[A-Za-z0-9+/=]{40,}"
        ),
        None,
    ),
    (
        "connection-code",
        re.compile(r"(?:dj0y|dj0x)[A-Za-z0-9+/]{80,}={0,2}"),
        None,
    ),
    (
        "github-token",
        re.compile(r"gh[pousr]_[A-Za-z0-9]{30,}"),
        None,
    ),
    (
        "aws-access-key",
        re.compile(r"AKIA[0-9A-Z]{16}"),
        None,
    ),
    (
        "slack-token",
        re.compile(r"xox[baprs]-[A-Za-z0-9-]{10,}"),
        None,
    ),
    (
        "author-home-path",
        re.compile(r"(?<![\w<])/(?:home|Users)/([A-Za-z0-9._-]+)"),
        home_filter,
    ),
    (
        "author-windows-path",
        re.compile(r"[A-Za-z]:\\Users\\([^\\\"']+)"),
        win_filter,
    ),
    (
        "private-orchestration-bundle",
        re.compile("codex" + "-pi-" + "orchestration", re.IGNORECASE),
        None,
    ),
]


def repo_files(root: str):
    try:
        out = subprocess.check_output(
            ["git", "-C", root, "ls-files", "-z"], stderr=subprocess.DEVNULL
        )
        names = [n for n in out.decode("utf-8", "replace").split("\0") if n]
        if names:
            return [os.path.join(root, n.replace("/", os.sep)) for n in names]
    except (OSError, subprocess.CalledProcessError):
        pass

    found = []
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for name in files:
            found.append(os.path.join(base, name))
    return found


def load_denylist(path: str):
    items = []
    if not path or not os.path.isfile(path):
        return items
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            value = line.strip()
            if value and not value.startswith("#"):
                items.append(value)
    return items


def main() -> int:
    parser = argparse.ArgumentParser(description="Public repository secret scan")
    parser.add_argument("--root", default=os.getcwd())
    parser.add_argument("--denylist", default="")
    args = parser.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print("not a directory: %s" % root, file=sys.stderr)
        return 2

    denylist_path = args.denylist or os.path.join(
        root, ".audit", "private-denylist.txt"
    )
    denylist = [d.lower() for d in load_denylist(denylist_path)]

    findings = []
    for path in repo_files(root):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        lowered_rel = rel.lower()
        if any(item in lowered_rel for item in denylist):
            findings.append((rel, 0, "denylist-path"))
        if os.path.splitext(path)[1].lower() in BINARY_EXT:
            continue
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                lines = handle.readlines()
        except OSError:
            continue
        for lineno, line in enumerate(lines, 1):
            lowered = line.lower()
            if any(item in lowered for item in denylist):
                findings.append((rel, lineno, "denylist"))
                continue
            for rule, pattern, keep in RULES:
                for match in pattern.finditer(line):
                    if keep is not None and not keep(match):
                        continue
                    findings.append((rel, lineno, rule))
                    break

    for rel, lineno, rule in findings:
        location = rel if lineno == 0 else "%s:%d" % (rel, lineno)
        print("FAIL %s  %s" % (location, rule))

    if findings:
        print("public scan failed: %d finding(s)" % len(findings))
        return 1

    print("public scan clean (%d files)" % len(repo_files(root)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
