#!/usr/bin/env python3
"""Shared rules for the pairing and enrollment services.

Both services accept one SSH public key and append it to authorized_keys.
They must agree on what an acceptable key is, and neither may authorize a key
by a partial match. This module is the single owner of those rules.
"""

import base64
import binascii
import hmac
import os
import struct

# Key types that the services accept. The value is a prefix of the key type
# token, so family types such as ecdsa-sha2-nistp256 also match.
KEY_PREFIXES = (
    "ssh-ed25519 ",
    "ssh-rsa ",
    "ecdsa-sha2-",
    "sk-ssh-ed25519@openssh.com ",
    "sk-ecdsa-sha2-",
)

MAX_KEY = 2000
MIN_BLOB = 32


def parse_key(text):
    """Return (key_type, blob) for one complete public key, or None.

    The blob is decoded and checked against its own embedded key type and key
    length, so a prefix of a valid blob and a malformed blob are both rejected.
    """
    if not isinstance(text, str):
        return None
    key = text.strip()
    if not key or len(key) > MAX_KEY or "\n" in key or "\r" in key:
        return None
    if not key.startswith(KEY_PREFIXES):
        return None
    parts = key.split()
    if len(parts) < 2:
        return None
    key_type, blob = parts[0], parts[1]
    if len(blob) < MIN_BLOB:
        return None
    try:
        raw = base64.b64decode(blob, validate=True)
    except (binascii.Error, ValueError):
        return None
    if len(raw) < 8:
        return None
    size = struct.unpack(">I", raw[:4])[0]
    if size <= 0 or len(raw) < 4 + size + 4:
        return None
    if raw[4:4 + size].decode("ascii", "replace") != key_type:
        return None
    key_len = struct.unpack(">I", raw[4 + size:8 + size])[0]
    if key_len <= 0 or len(raw) < 8 + size + key_len:
        return None
    return key_type, blob


def key_present(text, blob):
    """True when one line of this authorized_keys text carries exactly this blob."""
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[1] == blob:
            return True
    return False


def read_keys(path):
    if not os.path.exists(path):
        return ""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def append_key(path, key):
    """Append the key unless its blob is already present.

    Returns True when the key was already authorized. Raises ValueError when
    the key is not usable, so an unusable key can never be written.
    """
    parsed = parse_key(key)
    if parsed is None:
        raise ValueError("unusable key")
    blob = parsed[1]

    directory = os.path.dirname(path) or "."
    os.makedirs(directory, mode=0o700, exist_ok=True)
    existing = read_keys(path)

    if key_present(existing, blob):
        _chmod(path)
        return True

    line = key.strip()
    with open(path, "a", encoding="utf-8") as handle:
        if existing and not existing.endswith("\n"):
            handle.write("\n")
        handle.write(line + "\n")
    _chmod(path)
    return False


def secret_equals(supplied, expected):
    """Compare two secrets as UTF-8 bytes so any text is accepted.

    hmac.compare_digest raises TypeError when either text is not ASCII, which
    would kill the request handler before it sends a response.
    """
    return hmac.compare_digest(str(supplied).encode("utf-8"),
                               str(expected).encode("utf-8"))


def _chmod(path):
    try:
        os.chmod(path, 0o600)
    except OSError:
        pass
