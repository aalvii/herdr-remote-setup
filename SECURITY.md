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

- the enrollment endpoint in `host/enroll.py`
- credential handling in `host/` and `client/`
- secret leakage in logs, the connection code, or the repository
- the Tailscale ACL example and the access model
- privilege or transport bypasses

Out of scope:

- vulnerabilities in herdr, Tailscale, OpenSSH, or Windows PowerShell
- missing hardening that the documentation already names as a deliberate limit
- the base64 connection code being readable. It is encoded, not encrypted, and
  the documentation says so.

## Response

Maintainers aim to acknowledge a report within seven days. A fix is released as
a patch version with a `CHANGELOG.md` entry. Reporters are credited unless they
ask otherwise.
