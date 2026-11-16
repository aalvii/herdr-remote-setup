# Security policy

## Supported versions

| Version | Supported |
|---------|:---:|
| 3.1.x | yes |
| 3.0.x | security fixes only |
| 2.x and older | no |

## Report a vulnerability

Do not open a public issue. Use GitHub's private vulnerability reporting for
this repository (Security, Report a vulnerability).

Include:

- affected version from `VERSION`
- operating system and role, host or client
- the exact steps or command
- the exit code
- the relevant log lines with secrets removed

Never include a `tskey-...` value, a private key, a connection code, or an
enrollment token in a report. Replace them with `<redacted>`. If a secret was
exposed, revoke it first.

## Scope

In scope:

- the pairing service in `host/pair.py`, the PIN flow, and key append
- the enrollment endpoint in `host/enroll.py`
- credential handling in `host/` and `client/`
- secret leakage in logs, the PIN, the connection code, or the repository
- the Tailscale ACL example and the access model
- privilege or transport bypasses

Out of scope:

- vulnerabilities in herdr, Tailscale, OpenSSH, or Windows PowerShell
- missing hardening that the documentation already names as a deliberate limit
- the base64 connection code being readable. It is encoded, not encrypted, and
  the documentation says so.

## Known limits

- The simple flow uses a 6-digit PIN. It allows five wrong attempts per source
  in five minutes, rotates after each success, and expires after 30 minutes.
- The pairing service binds the Tailscale address only, at port 8765. It uses
  plain HTTP inside the tailnet; WireGuard encrypts it. The PIN gates the key
  exchange.
- The PIN is passed to the client child process as a command-line argument. A
  local administrator can see it in the process list while the client runs.
- The connection code is base64, not encryption. It can contain a one-time
  Tailscale auth key and an enrollment token. Treat it as a secret.
- The Windows app and both client CLIs pass the code to the child process as a
  command-line argument. A local administrator can see it in the process list
  while the setup runs. Run the setup on a machine you trust, and do not share
  the code.
- The enrollment endpoint binds `0.0.0.0` and is protected by a one-time token.
  It stops after one successful request or when the TTL expires.
- The app does not embed a secret. It reads the PIN or code from the input field
  and hands it to the verified client script.

## Response

Maintainers aim to acknowledge a report within seven days. A fix is released as
a patch version with a `CHANGELOG.md` entry. Reporters are credited unless they
ask otherwise.
