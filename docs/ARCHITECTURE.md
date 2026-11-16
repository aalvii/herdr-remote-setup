# Architecture

## Layers

```
+---------------------------------------------------+
| 3. Workspace   herdr                              |
|    server, machine entries, panes                 |
+---------------------------------------------------+
| 2. Transport   Tailscale SSH  |  OpenSSH + key    |
|    ACL identity               |  authorized_keys  |
+---------------------------------------------------+
| 1. Network     Tailscale                          |
|    tailnet membership, 100.x addressing           |
+---------------------------------------------------+
```

Layer 1 is mandatory for a host without a public address.

## Platforms

| Role | Linux | macOS | Windows |
|------|:---:|:---:|:---:|
| Host | yes | yes | not shipped |
| Client | not shipped | yes | yes |

`host/setup.sh` accepts `Linux` and `Darwin`. `client/setup.ps1` is Windows
only. `client/setup-macos.sh` is macOS only. Both guard their own OS and exit 2
on anything else.

macOS differences that the code handles:

| Concern | Linux | macOS |
|---------|-------|-------|
| Detached server | `setsid -f` | `python3 Popen(start_new_session=True)` |
| sshd check | `systemctl`, then `pgrep` | `pgrep`, then `launchctl print` |
| sshd start | `systemctl start` | `systemsetup -setremotelogin on` |
| Tailscale paths | `/usr/bin`, `/usr/local/bin` | app bundle, Homebrew |
| Tailscale install | `curl install.sh` | `brew install --cask tailscale` |
| Addresses | `ip -4 addr` | `ifconfig` |
| Clipboard | xclip, xsel, wl-copy | `pbcopy` |
| Watchdog | scheduled task | LaunchAgent |
| Launcher | portable `.desktop` | `.command` |

`$HOME` must not be group or other writable on macOS, or sshd refuses the key.
The host script removes write permission when it finds it.

The shipped `.desktop` files use the `%k` field code to resolve their own folder,
so the repository stores no absolute path. `install-desktop.sh` writes absolute
menu entries for the current machine when a user wants them.

## Detached start

`herdr status --json` must report `"detached_server_daemon": true`. The server
must be a session leader with no controlling terminal.

- Linux: `setsid -f herdr server`.
- macOS has no `setsid`. `start_detached` uses
  `python3 -c 'Popen(..., start_new_session=True)'`, which calls `setsid(2)` in
  the child.

Measured on the Linux host: the running server and a Python
`start_new_session=True` child both show `pgrp == session == pid` and `tty=?`.
The macOS runner passes `python3` and `enroll.py` through the same helper.

## Simple pairing

The primary user path is a 6-digit PIN.

```
Host A                             Machine B
host/pair.sh                       app Herdr-Setup.cmd
  pairing service :8765              scan tailnet peers
  shows PIN 123456  <--- PIN ---     POST key + PIN
  appends key                        SSH, herdr machine add
```

- `host/pair.py` binds the Tailscale IPv4 address at port 8765. It does not bind
  the LAN or the internet.
- `GET /api/info` identifies the service and returns the host and login user.
- `POST /api/request` takes the PIN, the client name, and an SSH public key. A
  correct PIN appends the key to `~/.ssh/authorized_keys` with mode 600.
- The PIN is six digits, rotates after each success, expires after 30 minutes,
  and allows five wrong attempts per source in five minutes. It is never logged.
- The client finds sharing hosts by probing each tailnet peer at port 8765. The
  fixed port is a deliberate exception to the port-0 rule for enrollment:
  discovery needs a known port. The service is bound to the tailnet and gated by
  the PIN.
- The client then connects over OpenSSH key, runs `herdr machine add`, and
  installs the watchdog.
- The traffic is plain HTTP inside the tailnet. WireGuard encrypts it. The PIN
  authorizes the key exchange.

This removes the connection code and the Tailscale auth key from the normal
flow. It still needs a Tailscale account on both machines. A UU-level experience
without a Tailscale account would need a hosted rendezvous and relay service,
which is a different product.

## The app

`app/` is a front end. The verified scripts stay the source of truth.

- Simple Windows: `app/herdr-connect.ps1` calls `client/pair.ps1`.
- Simple Linux/macOS: `app/herdr-setup.sh` offers Share, Connect, and Advanced.
- Advanced Windows: `app/herdr-setup.ps1` is the role/OS and connection-code app.
- Advanced Linux/macOS: `app/herdr-setup-advanced.sh` is the old role/OS app.

The advanced app uses a six-row support matrix. A `run` row becomes `guidance`
when its OS is not the local OS. Nothing is started in that case.

Runtime choice is evidence based:

| Target | Measured | Decision |
|--------|----------|----------|
| Linux host | python3 3.13, no `tkinter`, no `DISPLAY` | Tkinter cannot run |
| Windows client | PowerShell 5.1 with WinForms | WinForms |
| macOS | not reachable; CLT `python3` has no reliable tkinter | shell menu |

A local web page was rejected because it needs a helper to run commands, and a
helper needs a runtime that at least one target lacks. Electron and Tauri were
rejected as too heavy for a two-button pair.

| Front end | Platform | Needs |
|-----------|----------|-------|
| `app/herdr-connect.ps1` | Windows | PowerShell 5.1, .NET Framework |
| `client/pair.ps1` | Windows | OpenSSH, herdr |
| `app/herdr-setup.ps1` | Windows | PowerShell 5.1, .NET Framework |
| `app/herdr-setup.sh` | Linux, macOS | `/bin/bash` 3.2+ |

All have a self-test. The Windows apps have a headless path for tests.

## Transport modes

| Mode | Server side | Client side | Revocation | herdr compatible |
|------|-------------|-------------|------------|:---:|
| `key` | `sshd` + `authorized_keys` | own key pair | remove the key line | **yes** |
| `ts-ssh` | `tailscale up --ssh` + ACL | tailnet identity | edit ACL | **no** |

`ts-ssh` is kept for human SSH access only. herdr's remote bridge is launched
through OpenSSH; when Tailscale SSH serves port 22, the bridge is wrapped by
`tailscaled be-child ssh --force-v1-behavior`. The endpoint handshake still
succeeds, but surface activation and revocation are not acknowledged, and the
machine never becomes usable.

Observed evidence:

```
# remote process tree with Tailscale SSH on
/usr/sbin/tailscaled be-child ssh ... --force-v1-behavior \
  --cmd=printf ' %s ' 'herdr-remote-output-ready:1' \
        exec /home/<user>/.local/bin/herdr remote-client-bridge --idle-timeout-v1
```

Default mode is `key`. `auto` remains available for experiments only.

## Key enrollment

This is the advanced flow. The simple PIN flow uses `host/pair.py` and does not
use this endpoint.

Manual key authorization is the only step the product could not automate.
`host/enroll.py` closes it:

```
client  --HTTP POST /enroll-->  host
          {"code": "<token>", "key": "ssh-ed25519 ..."}
host: validate token (constant-time), validate key shape, append to
      ~/.ssh/authorized_keys (0600), reply 200, then stop
```

- one-time token, TTL default 600 s
- bind 0.0.0.0, protected by the token
- wrong token → 401, logged with the source address
- one success shuts the listener down

The token travels inside the connection code as `enroll=<port>:<token>`.

## Watchdog

`client/watchdog.ps1` and `client/watchdog-macos.sh` detect the stalled state
and restart only the client:

```
read last 120 lines of the client log
last event == failure (revocation / health check) and log idle > stale minutes
  -> stop the client process (command line without " server")
  -> relaunch with a console
```

A TUI needs an interactive console. On Windows,
`Start-Process` and `cmd /c start` from a non-console context exit immediately;
a scheduled task with `LogonType Interactive` works. The task action is
`wscript.exe` with `client/watchdog-hidden.vbs`, which starts
`watchdog.ps1 -Quiet` with a hidden window. The two-minute check no longer
flashes a console. On macOS the watchdog is a LaunchAgent and reopens Terminal
through `osascript`.

The macOS client log path was not observed on a real Mac. The watchdog probes
three likely paths and accepts `HERDR_CLIENT_LOG`. If none exists it exits 2 and
does nothing, so a wrong path cannot restart a healthy client.

### Why `ts-ssh` is not automatically better

Authorization is evaluated from the node's **current** identity and tags at
connect time. If the node re-registers without its tag, the ACL stops matching
and Tailscale SSH is refused, even though nothing changed on the client.

`authorized_keys` is static: it survives re-registration untouched.

So:

- `ts-ssh` = fewer secrets, but depends on correct node state.
- `key` = more setup, but more resilient to node churn.

The `install-autostart.sh` unit exists to close that gap for `ts-ssh`.

## Re-registration

A reboot alone keeps the node. What creates a new node:

| Cause | Node key | 100.x address | Tag | Fix |
|-------|----------|---------------|-----|-----|
| normal reboot | kept | kept | kept | none |
| state on ephemeral storage | lost | usually new | lost | persist `/var/lib/tailscale` |
| `tailscale logout` | lost | new | lost | avoid, or re-run `up` |
| `--ephemeral` node | lost per start | new | from key | do not use for hosts |
| node key expiry | same node | kept | kept | disable key expiry |
| image rebuild | lost | new | lost | autostart guard |

`install-autostart.sh` writes:

```
/etc/herdr-setup/tailscale.env          root:root 600
/etc/systemd/system/herdr-tailscale-ssh.service
```

The unit runs after `tailscaled`, and only calls `tailscale up` when the state
is not `Running`, `RunSSH` is false, or the tag is missing. This is
idempotent and safe to run on every boot.

## Connection code

This is the advanced flow. The simple PIN flow does not use a connection code.

### v2 (current)

```
base64("v=2;mode=key;user=<u>;host=<h>;dns=<fqdn>;ips=<csv>;ts=<epoch>;tag=<tag>;key=<authkey>")
```

| Key | Required | Meaning |
|-----|:---:|---------|
| `v` | yes | format version |
| `mode` | yes | `ts-ssh` or `key` |
| `user` | yes | login user |
| `host` | yes | short hostname, used as the herdr label |
| `dns` | no | MagicDNS name; preferred target |
| `ips` | yes | comma-separated addresses, Tailscale IP first |
| `ts` | yes | Unix timestamp |
| `tag` | no | node tag, informational |
| `key` | no | one-time Tailscale auth key |

### v1 (legacy)

```
base64("<user>@<host>:<csv-ips>:<epoch>[:tskey-...]")
```

The client detects `v=` and falls back to the v1 parser otherwise. v1 codes are
always treated as `mode=key`.

## Target selection order

1. `dns` (MagicDNS), when present
2. each entry in `ips`, in order

`ts-ssh` tests with `PreferredAuthentications=none` so a key-based server fails
fast instead of prompting.

## Idempotency

| Component | Re-run behavior |
|-----------|-----------------|
| Tailscale | installed once; `up` only when needed |
| Tailscale SSH | re-asserted when `RunSSH` is false |
| herdr | installed once; server start skipped when running |
| SSH key (`key` mode) | generated once; kept |
| herdr machine entry | removed and re-added to refresh the target |

## State and logs

Host (Linux and macOS):

```
~/.local/state/herdr-setup/setup.log
~/.local/state/herdr-setup/pair.log             600
~/.local/state/herdr-setup/pair.pin             600, removed on exit
~/.local/state/herdr-setup/pair.port            600, removed on exit
~/.local/state/herdr-setup/connection-code.txt   600
~/.local/state/herdr-setup/enroll.port           600
~/.local/state/herdr-setup/enroll.txt            600
/etc/herdr-setup/tailscale.env                   root 600
/etc/herdr-setup/authkey                         root 600
```

Client (Windows):

```
%LOCALAPPDATA%\HerdrSetup\logs\setup-<ts>.log
%LOCALAPPDATA%\HerdrSetup\machines.txt
```

Client (macOS):

```
~/Library/Logs/HerdrSetup/setup-<ts>.log
~/Library/Logs/HerdrSetup/watchdog.log
~/Library/Application Support/HerdrSetup/machines.txt
~/Library/LaunchAgents/dev.herdr.watchdog.plist
```

## Exit codes

| Code | Name | Meaning |
|------|------|---------|
| 0 | OK | success |
| 2 | PREREQ | missing tool, bad option, bad code |
| 3 | NET | Tailscale install/join/reachability |
| 4 | TRANSPORT | Tailscale SSH refused, or key auth failed |
| 5 | HERDR | herdr install or configuration |
| 6 | INTERNAL | unexpected error |

## Deliberate limits

- No password bootstrap. The recommended setup disables password auth.
- No silent elevation on Windows.
- No automatic ACL editing. The tailnet policy stays operator-owned.
- `ts-ssh` depends on the operator keeping node tags correct; the autostart unit
  reduces, but cannot remove, that dependency.
