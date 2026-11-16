# Quickstart

One page: from a fresh host and a fresh client to a working herdr remote
session. Hosts: Linux or macOS. Clients: Windows or macOS. Version: see
`VERSION` (currently 3.1.1).

For the no-command-line path, open `app/` first: `Herdr-Setup.cmd` on Windows,
`Herdr-Setup.command` on macOS, or `Herdr-Setup.desktop` on Linux. Pick Role
and OS. The rest of this page is the same flow with the commands shown.

---

## 0. Prerequisites

| Item | Host (Linux) | Host (macOS) | Client (Windows) | Client (macOS) |
|------|--------------|--------------|------------------|----------------|
| OS | Linux with systemd or not | macOS 12+ | Windows 10/11 | macOS 12+ |
| Rights | sudo | admin or sudo | Administrator (Tailscale install) | admin (Tailscale install) |
| Tools | `curl`, `python3`, `base64`, `setsid` | `curl`, `python3` (Command Line Tools), `base64` | OpenSSH Client (`ssh -V`) | OpenSSH (`ssh -V`) |
| Network | reachable tailnet | reachable tailnet | internet; GitHub optional | internet |
| Tailscale | installed by the script | app bundle or Homebrew | installed by the script | app bundle or Homebrew |

macOS needs `python3` from Command Line Tools for the enrollment endpoint and
for the detached herdr start: `xcode-select --install`.

Prepare **once**, in the Tailscale admin console:

1. https://login.tailscale.com/admin/settings/keys → **Generate auth key**
2. Reusable: off. Expiration: 1 hour. Ephemeral: off. Pre-approved: on.
3. Copy `tskey-auth-...`

---

## 1. Host: one command

Linux:

```bash
cd host
chmod +x *.sh

# first run: store the key and print the code
./provision.sh --authkey tskey-auth-xxxxxxxxxxxx --save-key

# later runs: no arguments needed
./provision.sh
```

macOS: the same commands from Terminal, or double-click
`host/Herdr-Provision.command`. The `.command` file keeps Terminal open so the
code stays visible.

Expected tail of the output:

```
>> Preflight (v3.1.0)
OK Platform: Linux 6.x
OK Tailscale IP: 100.x.y.z
OK herdr: herdr 0.9.5
OK herdr server running
OK SSH server running, authorized keys: N
>> Starting key enrollment endpoint
OK Enrollment listening on :PORT (ttl 3600s)
...
Connection code
----------------------------------------------------------------

<base64 code>

----------------------------------------------------------------
Details
  mode      : key
  host      : alice@HOST
  dns       : HOST.tailnet.ts.net
  addresses : 100.x.y.z,...
  auth key  : included (single use, sensitive)
  enroll    : port PORT, one-time token in the code
```

Copy the code. It is valid for about one hour.

Desktop alternative: `./provision-gui.sh`, or install the menu entry with
`./install-desktop.sh` (**Herdr: New Client Code**).

### No commands at all

Double-click `host/Herdr-Provision.desktop` in the file manager. It opens a
terminal, runs the flow, and keeps the code visible. The file resolves its own
folder, so it works wherever the package is extracted.

If the file manager marks it untrusted, right-click it and choose **Allow this
file to be executed**. If the file manager opens it as text, run
`./install-desktop.sh` once instead. That adds **Herdr Remote Setup**, **Herdr
Remote Setup (App)**, and **Herdr: New Client Code** to the application menu,
and puts a Desktop shortcut in `~/Desktop`.

The launcher picks its behavior automatically:

| Situation | Action |
|-----------|--------|
| terminal available, zenity installed | GUI dialog |
| terminal available, no zenity | text flow in that terminal |
| launched from an icon | opens a terminal window first |

`launch-provision.sh` implements this. It needs no arguments.

For automation:

```bash
./provision.sh --json | python3 -c 'import json,sys;print(json.load(sys.stdin)["code"])'
```

---

## 2. Client: copy the folder, double-click

### Windows

Copy the whole `client` folder to the Windows machine (USB, share, or cloud).
The new machine has no tailnet yet, so do not rely on scp from the host.

```
client\
├── setup.cmd
├── setup.ps1
├── setup-gui.ps1
├── watchdog.ps1
├── install-watchdog.ps1
└── assets\herdr-windows-x86_64.zip     <- required for offline herdr install
```

Right-click `setup.cmd` → **Run as administrator** → paste the code → Start setup.

### macOS

Copy the whole package, then double-click `app/Herdr-Setup.command`, choose
**Client** and **macOS**, and paste the code. Or run
`bash client/setup-macos.sh --code "<code>"`.

The macOS client installs Tailscale with Homebrew when it is missing. Without
Homebrew it stops and names the download page, because the standalone app needs
a GUI install once. It installs herdr from `herdr.dev` (macOS assets confirmed
for x86_64 and aarch64).

Expected output:

```
>> Herdr Remote Setup client v3.1.0
OK Format: v2
OK Mode: key
OK Tailnet path ready
OK herdr found
>> Transport layer (OpenSSH key)
OK SSH session: alice@HOST
>> Registering the machine in herdr
OK Machine entry created: HOST
OK herdr machine reachable
>> Installing the connection watchdog
OK Watchdog installed (every 2 min)

  Setup complete (v3.1.0, mode key)
  herdr --machine HOST
```

What each step does:

| Step | Action |
|------|--------|
| 1 | decode the code (v1 and v2 supported) |
| 2 | install Tailscale, join the tailnet with the embedded auth key |
| 3 | wait until the host appears in `tailscale status` |
| 4 | install herdr: online → local `assets` zip |
| 5 | generate the SSH key if missing |
| 6 | try SSH; on failure POST the key to the enrollment endpoint, then retry |
| 7 | register the machine in herdr |
| 8 | install the watchdog task |

### CLI form

```powershell
powershell -File .\setup.ps1 -ConnectionCode "<code>"
powershell -File .\setup.ps1 -ConnectionCode "<code>" -NoWatchdog
powershell -File .\setup.ps1 -SelfTest
powershell -File .\setup.ps1 -ShowVersion
```

macOS:

```bash
bash client/setup-macos.sh --code "<code>"
bash client/setup-macos.sh --code "<code>" --no-watchdog
bash client/setup-macos.sh --self-test
bash client/setup-macos.sh --version
```

---

## 3. Use it

```powershell
herdr
```

Select the machine in the sidebar. First selection is the only manual step,
because a TUI needs an interactive terminal.

Or from a terminal:

```powershell
herdr --machine HOST
herdr --machine HOST agent list
```

---

## 4. Verify

Client:

```powershell
herdr machine status                    # expect: reachable
powershell -File .\setup.ps1 -SelfTest  # expect: SELFTEST OK
powershell -File app\herdr-setup.ps1 -SelfTest
```

macOS:

```bash
herdr machine status                    # expect: reachable
bash client/setup-macos.sh --self-test
bash app/herdr-setup.sh --self-test
```

Host:

```bash
./host/setup.sh --json | head -c 200
tailscale debug prefs | grep RunSSH     # expect: false
herdr status --json | grep detached_server_daemon   # expect: true
```

Package integrity:

```powershell
powershell -File tools\verify-package.ps1   # VERIFY OK (N files)
```

---

## 5. If the machine shows "connecting"

Three checks, in order:

```bash
# 1. Tailscale SSH must be off (it breaks herdr's bridge)
tailscale debug prefs | grep RunSSH            # must be false
sudo tailscale set --ssh=false

# 2. Remote server must be a detached daemon
herdr status --json | grep detached_server_daemon   # must be true
herdr server stop && setsid -f herdr server </dev/null >/dev/null 2>&1

# 3. Local client may have stopped retrying (upstream issue #3842)
#    Restart only the client: detach with Ctrl+B then Q, run herdr again,
#    or let the watchdog do it:
powershell -File client\watchdog.ps1 -DryRun
```

Full detail: `docs/TROUBLESHOOTING.md`.

---

## 6. Operations

| Task | Command |
|------|---------|
| New client code | `./host/provision.sh` |
| New code, copy to clipboard | `./host/provision.sh --clip` (`pbcopy` on macOS) |
| Rotate the stored auth key | `./host/provision.sh --authkey tskey-... --save-key` |
| Check the watchdog (Windows) | `powershell -File client\watchdog.ps1 -DryRun` |
| Check the watchdog (macOS) | `bash client/watchdog-macos.sh --dry-run` |
| Remove the watchdog (Windows) | `powershell -File client\install-watchdog.ps1 -Uninstall` |
| Remove the watchdog (macOS) | `bash client/install-watchdog-macos.sh --uninstall` |
| Remove machine entries | `powershell -File tools\uninstall.ps1` |
| Keep node identity after reboot | `sudo ./host/install-autostart.sh --authkey ... --tag tag:herdr-host` |
| App self-test | `powershell -File app\herdr-setup.ps1 -SelfTest`; `bash app/herdr-setup.sh --self-test` |

---

## 7. Security

- The connection code is base64, not encryption. It contains the auth key and
  the enrollment token. Treat it as a secret; it is single-use and expires.
- Logs redact `tskey-...`.
- `/etc/herdr-setup/authkey` is root-only (600).
- Password SSH stays disabled; the enrollment endpoint authorizes one key per
  token and then stops.
