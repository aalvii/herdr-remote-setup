# Herdr Remote Setup

Prepare a Linux or macOS host for remote control and connect a Windows or macOS
client to it in one step. Three layers: **network (Tailscale)**, **transport
(Tailscale SSH or OpenSSH key)**, **workspace (herdr)**.

Version: see `VERSION`.

Start with [`docs/USAGE.md`](docs/USAGE.md) for the complete operator
instruction.

---

## 0. Simple setup: one PIN

The primary path needs no connection code and no IP address.

1. **Host, Linux or macOS.** Start sharing:
   - double-click `host/Herdr-Provision.desktop` or
     `host/Herdr-Provision.command`; or
   - run `host/pair.sh`.
   The host prints a computer name, a 6-digit PIN, and, when an API token is
   stored, a one-time **guest join code**.
2. **Client, Windows.** Double-click `app\Herdr-Setup.cmd`.
   Click **Connect to a computer**. Pick the computer. Paste the join code if
   the host printed one. Enter the PIN. Click **Connect**. Then click
   **Open herdr**.
3. Done. The machine is added to herdr and the watchdog is installed.

No base64 code. No IP address. No command line.

### 0.1 The guest join code

A guest without a Tailscale account can join the owner's tailnet as a tagged
`tag:client` device. One admin action is still needed, once:

1. Create a Tailscale API token with auth-key creation and ACL read/write, and
   store it root-only on the host:
   ```bash
   sudo mkdir -p /etc/herdr-setup
   sudo sh -c 'printf "%s\n" "<your-api-token>" > /etc/herdr-setup/tailscale-api.key'
   sudo chmod 600 /etc/herdr-setup/tailscale-api.key
   ```
2. Each guest run then needs no admin console. `host/pair.sh` checks the policy
   with `host/ensure-acl.sh`, creates a one-time key with `host/guest-key.sh`,
   and prints `Guest join code: <one-time key>`.
3. The guest pastes that code into the Connect panel. The client joins the
   tailnet with it, then pairs the SSH key with the PIN.

The host never writes the policy when the required entries already exist. It
adds only missing entries, keeps a backup under `/etc/herdr-setup`, and prints
the JSON snippet when it cannot write. Without the token the flow is PIN-only,
as in 4.0.0.

Use `host/pair.sh --no-join-code` for PIN-only sharing, and
`host/pair.sh --no-acl-write` to check the policy without changing it.

| Action | Linux | macOS | Windows |
|--------|:---:|:---:|:---:|
| Share this computer | yes | yes | not shipped |
| Share with a guest join code | yes | yes | not shipped |
| Connect with a PIN | not shipped | Advanced flow in 4.0.0 | yes |
| Connect with a join code and PIN | not shipped | no | yes |
| Advanced connection code | yes | yes | yes |

The host pairing service listens on the Tailscale address only. The PIN is six
digits, rotates after each successful connection, and allows five wrong attempts
in five minutes. Under the hood the flow still uses OpenSSH key transport. The
host appends the client key automatically, then the client runs
`herdr machine add`.

The old role and OS app is under **Advanced setup** in the Windows app, or
`app/herdr-setup-advanced.sh` on Linux and macOS. The connection-code flow is
described in sections 1 to 6.

Runtime choice, from what is installed on the three targets:

| Target | Evidence | Result |
|---|---|---|
| Linux host | python3 3.13 present, **no tkinter**, **no DISPLAY** | shell host and pairing service |
| Windows client | PowerShell 5.1 + WinForms present, no install | WinForms |
| macOS | Command Line Tools `python3` does not ship tkinter reliably | shell menu |

The app stays native and tiny: WinForms on Windows, a shell menu on Linux and
macOS. No Electron, no Tauri, no Python runtime to install on Windows.

---

## 1. Advanced: two transport modes

| Mode | Authorization | SSH key needed | Use |
|------|---------------|:---:|-----|
| `key` | `~/.ssh/authorized_keys` | yes | **Default. Required for herdr.** |
| `ts-ssh` | tailnet identity + ACL | no | Human SSH only; breaks herdr |
| `auto` | ts-ssh when enabled, else key | depends | Not recommended |

### Transport note: Tailscale SSH is not supported by herdr

herdr's remote bridge runs over OpenSSH. With Tailscale SSH enabled, the bridge
is wrapped by `tailscaled be-child ssh --force-v1-behavior`, which changes the
channel semantics. The symptom is a handshake that succeeds, then fails with
`endpoint did not acknowledge surface revocation`, and the machine never
activates.

Use `--mode key` (default). To keep Tailscale SSH for human logins, move the
system sshd to another port and point herdr at it with
`ssh://user@host:port`. Do not keep both on port 22.

### ACL requirement for `ts-ssh` (optional)

If you enable Tailscale SSH for human access, it needs an `ssh` section in the
tailnet policy:

```json
{
  "tagOwners": {
    "tag:herdr-host": ["autogroup:admin"]
  },
  "ssh": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:herdr-host"],
      "users": ["alice"]
    }
  ]
}
```

Use `action: "accept"` for unattended use. `action: "check"` forces a periodic
browser confirmation and breaks automation.

The host must also enable SSH locally:

```bash
sudo tailscale up --ssh --advertise-tags=tag:herdr-host
```

---

## 2. Host: generate a connection code (one command)

Works on Linux and macOS. On macOS install the Command Line Tools once
(`xcode-select --install`) so `python3` exists; it starts the enrollment
endpoint and, because macOS has no `setsid`, starts the herdr server in its own
session.

```bash
cd host

# One command. Fixes mode=key, enables enrollment for 1 hour, prints the code.
./provision.sh --authkey tskey-auth-xxxxxxxxxxxx
```

On macOS the same command runs from Terminal. The double-click launcher is
`host/Herdr-Provision.command`.

`provision.sh` is the product entry point. It resolves the auth key from
`--authkey`, `$HERDR_TS_AUTHKEY`, `/etc/herdr-setup/authkey`, or an interactive
prompt. Save it once and later runs need no arguments:

```bash
./provision.sh --authkey tskey-auth-xxxx --save-key
./provision.sh
```

**No commands on Linux:** run `./install-desktop.sh` once, then choose **Herdr
Remote Setup** or **Herdr: New Client Code** from the application menu, or use
the Desktop shortcut it creates. On macOS, double-click
`host/Herdr-Provision.command`. Both paths open a terminal, run the flow, and
keep the code visible.

| Provision option | Meaning |
|------------------|---------|
| `--authkey <key>` | Tailscale auth key for the client |
| `--save-key` | Store the key at `/etc/herdr-setup/authkey` (root only) |
| `--ttl <seconds>` | Enrollment lifetime (default 3600) |
| `--clip` | Copy the code to the clipboard |
| `--json` | Machine-readable output |

Lower-level entry, when you need custom options:

```bash
./setup.sh --mode key --authkey tskey-auth-xxxxxxxx --enroll
```

**Desktop users:** `./provision-gui.sh`, or `./install-desktop.sh` to add the
menu entry **Herdr: New Client Code**.

| Option | Meaning |
|--------|---------|
| `--mode ts-ssh\|key\|auto` | Transport selection |
| `--tag tag:...` | Node tag; keeps ACL matching after re-registration |
| `--authkey <key>` | One-time Tailscale key embedded for the client |
| `--enable-ssh` | Runs `tailscale up --ssh` (needs sudo) |
| `--enroll` | Starts a one-time key enrollment endpoint and embeds its token |
| `--enroll-port <n>` | Enrollment port (default 8787) |
| `--enroll-ttl <n>` | Enrollment lifetime in seconds (default 600) |
| `--json` | Machine-readable result |
| `--quiet` | No progress output |
| `--version` | Print version |

Output: a base64 connection code, saved to
`~/.local/state/herdr-setup/connection-code.txt` (mode 600).

**Desktop users:** `./setup-gui.sh`, or `./install-desktop.sh` for a menu entry.
Both need `zenity`.

### Keep the node correct after a reboot

If the host loses `/var/lib/tailscale`, the node re-registers with a new node key
and a new device ID. The tag and `--ssh` are not restored automatically, so ACL
rules stop matching and Tailscale SSH breaks.

Install the guard once:

```bash
sudo ./install-autostart.sh --authkey tskey-auth-xxxxxxxx --tag tag:herdr-host
```

It writes `/etc/herdr-setup/tailscale.env` (root 600) and a oneshot unit that
re-asserts identity, tag, and `--ssh` only when they are missing.

---

## 3. Client: paste the code

### Windows

Copy the `client` folder to the Windows machine, then either:

- double-click `client\setup.cmd`, paste the code, click **Start setup**; or
- run:

```powershell
cd client
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -ConnectionCode "<code>"
```

### macOS

Copy the whole package to the macOS machine, then either:

- double-click `app/Herdr-Setup.command`, choose **Client**, then **macOS**, and
  paste the code; or
- run:

```bash
bash client/setup-macos.sh --code "<code>"
```

The macOS client needs the same three things the Windows client needs:
Tailscale, herdr, and OpenSSH. It installs all three without a manual download.
The watchdog is a LaunchAgent, `dev.herdr.watchdog`.

The client:

1. decodes the code (v1 colon format and v2 key=value format);
2. installs Tailscale and joins the tailnet;
3. waits for the host;
4. installs herdr (online, then the bundled offline package on Windows);
5. connects over **OpenSSH key**, and enrolls the key automatically when the
   code carries an `enroll` token;
6. registers the machine with `herdr machine add`;
7. verifies the connection;
8. **installs the watchdog** (every 2 minutes). Skip it with `-NoWatchdog` on
   Windows or `--no-watchdog` on macOS.

Result:

```powershell
herdr --machine <hostname>
```

CLI form with options:

```powershell
powershell -File .\setup.ps1 -ConnectionCode "<code>" -NoWatchdog
```

---

### Automatic key enrollment

Without `--enroll`, the client key must be added to the host by hand.
With `--enroll`, the host starts a one-time endpoint and puts its port and token
in the connection code. The client then posts its public key and retries SSH.

```bash
# host
./host/setup.sh --mode key --enroll
# client: nothing extra, setup.ps1 detects the enroll field
```

Rules:
- one-time token, default TTL 600 s, single successful request stops the server
- wrong token is rejected with 401 and logged
- the endpoint only accepts `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-*` keys
- it appends to `~/.ssh/authorized_keys` and sets mode 600

### Watchdog (optional)

herdr 0.9.5 can stall after `endpoint did not acknowledge surface revocation`
and stop retrying (upstream issue #3842). The watchdog detects that state and
restarts only the local client.

Windows:

```powershell
cd client
powershell -File install-watchdog.ps1                  # every 2 minutes
powershell -File watchdog.ps1 -DryRun                  # check without acting
powershell -File install-watchdog.ps1 -Uninstall
```

macOS:

```bash
cd client
bash install-watchdog-macos.sh                         # LaunchAgent, every 2 minutes
bash watchdog-macos.sh --dry-run                       # check without acting
bash install-watchdog-macos.sh --uninstall
```

It acts only when the last log event is a failure and the log has been idle for
the stale window (default 3 minutes). It never stops the server, so panes and
agents survive.

## 4. Connection code format

v2 (current):

```
base64("v=2;mode=key;user=alice;host=HOST;dns=HOST.tailnet.ts.net;ips=100.x,y;ts=EPOCH;tag=tag:herdr-host;key=tskey-...")
```

v1 (legacy, still accepted):

```
base64("user@host:ip1,ip2:epoch[:tskey-...]")
```

The client prefers `dns`, then falls back to each address in `ips`.

---

## 5. Exit codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 2 | Prerequisite or bad input |
| 3 | Network layer (Tailscale) |
| 4 | Transport (SSH auth) |
| 5 | herdr |
| 6 | Internal |

---

## 6. Package layout

```
.
├── VERSION
├── MANIFEST.sha256
├── LICENSE
├── THIRD-PARTY.md
├── SECURITY.md
├── CONTRIBUTING.md
├── app/
│   ├── Herdr-Setup.cmd          # Windows simple app (recommended)
│   ├── Herdr-Connect.cmd        # same Windows simple app
│   ├── herdr-connect.ps1        # two-button Windows client
│   ├── herdr-setup.ps1          # advanced role/OS Windows app
│   ├── Herdr-Setup.command      # macOS Share / Connect / Advanced menu
│   ├── Herdr-Setup.desktop      # Linux Share / Advanced menu
│   ├── herdr-setup.sh           # simple Linux/macOS menu
│   ├── herdr-setup-advanced.sh  # old role/OS shell app
│   └── launch-app.sh            # opens a terminal for the desktop entry
├── host/
│   ├── pair.py                 # pairing service: PIN, key append
│   ├── pair.sh                 # one-command share flow
│   ├── launch-pair.sh          # clickable share launcher
│   ├── provision.sh            # advanced one-command code flow
│   ├── provision-gui.sh        # one-dialog code flow (needs zenity)
│   ├── launch-provision.sh     # advanced clickable launcher
│   ├── Herdr-Provision.command # macOS Share launcher
│   ├── Herdr-Provision.desktop # Linux Share launcher
│   ├── setup.sh                # advanced lower-level entry
│   ├── setup-gui.sh            # zenity wrapper
│   ├── enroll.py               # advanced one-time key enrollment
│   ├── enroll.sh               # enrollment launcher
│   ├── install-desktop.sh      # menu entries and Desktop shortcuts
│   └── install-autostart.sh    # boot-time Tailscale guard
├── client/
│   ├── pair.ps1                # Windows PIN client
│   ├── setup.cmd               # advanced code client
│   ├── setup.ps1               # advanced code client
│   ├── setup-gui.ps1
│   ├── watchdog.ps1
│   ├── install-watchdog.ps1
│   ├── watchdog-hidden.vbs
│   ├── setup-macos.sh          # macOS advanced code client
│   ├── watchdog-macos.sh
│   ├── install-watchdog-macos.sh
│   └── assets/herdr-windows-x86_64.zip  # Apache-2.0, see THIRD-PARTY.md
├── tools/
│   ├── verify-package.ps1
│   ├── make-manifest.ps1
│   ├── check-public.py         # secret and identity scan
│   └── uninstall.ps1
├── docs/
│   ├── QUICKSTART.md
│   ├── SETUP-A-AND-B.md
│   ├── ARCHITECTURE.md
│   ├── ACCESS-MODEL.md
│   ├── acl-policy.hujson
│   └── TROUBLESHOOTING.md
└── .github/workflows/ci.yml
```

The package does not include private orchestration bundles. Releases are built
from this tree, and `tools/check-public.py` fails on key material, internal
hostnames, and author paths.

---

## 7. Verify before shipping

```powershell
powershell -File tools\verify-package.ps1      # VERIFY OK (N files)
powershell -File client\setup.ps1 -SelfTest    # SELFTEST OK (v...)
powershell -File app\herdr-setup.ps1 -SelfTest # SELFTEST OK (v...)
```

On the host:

```bash
./host/setup.sh --version
./host/setup.sh --json | head -c 300
bash app/herdr-setup.sh --self-test
```

---

## 8. Security notes

- The 6-digit PIN is a secret. It is single-use per connection, rotates after a
  success, and allows five wrong attempts in five minutes.
- The pairing service binds the Tailscale address only, on port 8765. It uses
  plain HTTP inside the tailnet, which WireGuard encrypts. It is not exposed to
  the LAN or the internet.
- The simple flow does not create a `tskey-...` value. Tailscale login is
  interactive on both machines.
- The advanced flow still uses a connection code. It is base64, not encryption,
  and can carry a Tailscale auth key. Treat it as a secret.
- The setup CLIs and the Windows app pass the PIN or code to a child process as
  a command-line argument. A local administrator can see it in the process list
  while the setup runs.
- Use single-use, short-expiry auth keys for advanced clients.
- `ts-ssh` removes key sprawl but relies on the ACL. Use `action: accept` only
  with a narrow `src`/`dst`/`users` tuple.
- Logs redact `tskey-...` values. The code itself is never logged.
- `/etc/herdr-setup/tailscale.env` holds a reusable key server-side. Keep it
  root-only and rotate it if exposed.

---

## 9. More

- `docs/SETUP-A-AND-B.md` — two-machine runbook for Host A and Machine B
- `docs/USAGE.md` — complete operator guide: token, share, connect, cleanup
- `docs/QUICKSTART.md` — one-page end-to-end flow
- `docs/ACCESS-MODEL.md` — operator / client / herdr-host roles, tagging, ACL
- `docs/acl-policy.hujson` — paste-ready tailnet policy
- `docs/ARCHITECTURE.md` — layers, formats, re-registration behavior
- `docs/TROUBLESHOOTING.md` — failure matrix
- `CHANGELOG.md` — version history

---

## 10. Open source

- **License:** MIT for this project. The bundled Herdr archive is Apache-2.0.
  See `THIRD-PARTY.md`.
- **Not affiliated:** this project is not affiliated with or endorsed by Herdr
  or Tailscale.
- **Contributing:** `CONTRIBUTING.md`. Run the self-tests and the public scan
  before a pull request.
- **Security:** `SECURITY.md`. Do not open a public issue for a vulnerability.
- **Secrets:** never commit a `tskey-...` value, a private key, a connection
  code, or an enrollment token. `tools/check-public.py` fails the build on key
  material and on internal hostnames or author paths.
- **CI:** `.github/workflows/ci.yml` runs the public scan and the self-tests on
  Ubuntu, Windows, and macOS.
