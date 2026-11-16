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
- The host can hold a Tailscale API token that creates auth keys and writes the
  tailnet policy. That token is more powerful than a key-creation token: an
  attacker who reads it can rewrite the whole policy. Store it root-only at
  `/etc/herdr-setup/tailscale-api.key`, use a dedicated token named for this
  purpose, rotate it after an engagement, and revoke it if it is exposed. Prefer
  a scoped OAuth client with only ACL write and auth-key creation when the
  organization supports one. The scripts read the file inside the process and
  never print it, pass it on a command line, or write it to a log.
- A guest join code (`tskey-auth-...`) is a single-use credential that expires
  after one hour. It joins the guest as `tag:client`. The scripts print it to the
  terminal only; it is never written to `pair.log`, state files, or shell
  history. Do not paste it into a ticket or a chat.
- A guest that joins with a code is a device in the **owner's** tailnet. The ACL
  limits it to `tag:herdr-host` on tcp:22 and tcp:8765, but it can list the other
  peers with `tailscale status`. If that is unacceptable, device sharing with the
  guest's own Tailscale account is the correct model.
- The host adds ACL entries; it never removes or rewrites another rule, and it
  keeps a policy backup under `/etc/herdr-setup` before a write. It refuses to
  write an unparsable or unexpected policy and prints the snippet instead. The
  scope includes a wrong entry the scripts add, and a policy write that changes a
  rule outside `tagOwners.tag:client` or the `tag:client` grant.

## Response

Maintainers aim to acknowledge a report within seven days. A fix is released as
a patch version with a `CHANGELOG.md` entry. Reporters are credited unless they
ask otherwise.
