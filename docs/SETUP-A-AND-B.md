# Set up Host A and Machine B

This page is the two-machine runbook. Host A runs the herdr server. Machine B
connects to it.

Version: see `VERSION`.

## Supported pairs

| Host A | Machine B | Status |
|--------|-----------|--------|
| Linux | Windows | Fully verified |
| Linux | macOS | macOS client not runtime verified |
| macOS | Windows | macOS host not runtime verified |
| macOS | macOS | Both macOS paths not runtime verified |

Host A cannot be Windows. Machine B cannot be Linux in this package.

## Before you start

1. Access to the Tailscale admin console at https://login.tailscale.com/admin.
2. Host A must already be in the tailnet. Run `tailscale status` on A and check
   that it is online.
3. Create a fresh auth key for B in the console. Settings, Keys, Generate auth
   key. Single use, one hour, pre-approved, not ephemeral. Copy the
   `tskey-auth-...` value.
4. Use a new key for each client. A single-use key cannot onboard a second
   machine.
5. Copy the whole package to A and B. If you copy only `client`, the app and the
   `VERSION` file are missing.

Host A needs sudo or admin rights. Machine B needs Administrator on Windows for
the Tailscale install.

## Step 1: Host A

Open a terminal in the package root on A.

### Clickable launcher

Linux:

- `host/Herdr-Provision.desktop` runs the host flow.
- `app/Herdr-Setup.desktop` opens the app. Choose Host and Linux.

macOS:

- `host/Herdr-Provision.command` runs the host flow.
- `app/Herdr-Setup.command` opens the app. Choose Host and macOS.

If a file manager marks the Linux file untrusted, right-click it and choose
**Allow this file to be executed**.

### Terminal

```bash
cd host
./provision.sh --authkey tskey-auth-xxxxxxxxxxxx --save-key
```

If a zip copy lost the execute bit:

```bash
bash provision.sh --authkey tskey-auth-xxxxxxxxxxxx --save-key
```

Later runs on the same host need no key argument:

```bash
./provision.sh
```

`--save-key` stores the key at `/etc/herdr-setup/authkey` with mode 600. That
helps when you rerun the same flow. It does not make a spent single-use key
valid for a new client.

### macOS host prerequisites

```bash
xcode-select --install
sudo systemsetup -setremotelogin on
```

You can also use System Settings, General, Sharing, Remote Login. The script
tries `systemsetup` and exits 4 if Remote Login stays off.

### Host output

The flow checks or installs Tailscale, starts sshd, installs herdr, starts the
herdr server detached, starts the one-time enrollment endpoint, and prints a
base64 connection code.

Expected details:

```
mode      : key
host      : <user>@<hostname>
dns       : <hostname>.<tailnet>.ts.net
addresses : 100.x.y.z,...
auth key  : included (single use, sensitive)
enroll    : port <PORT>, one-time token in the code
```

The code is saved at `~/.local/state/herdr-setup/connection-code.txt` with mode
600. It is valid for about one hour.

### Confirm the host state

```bash
tailscale debug prefs | grep RunSSH                 # must be false
herdr status --json | grep detached_server_daemon   # must be true
pgrep -x sshd
tailscale ip -4
```

If `RunSSH` is true, disable Tailscale SSH. It breaks herdr:

```bash
sudo tailscale set --ssh=false
```

### Host without an auth key

When both machines are already in the tailnet, you can issue a code without a
key. The client skips the Tailscale join when the host is already visible:

```bash
cd host
./setup.sh --mode key --enroll --enroll-ttl 3600
```

This is the lower-level entry. It does not save the code to the state file.

## Step 2: Machine B

Send the code to B over a private channel. It contains an auth key and an
enrollment token. Treat it as a password.

### B is Windows

1. Copy the package to B.
2. Double-click `app\Herdr-Setup.cmd`.
3. Choose Client and Windows.
4. Paste the code and click Run.
5. Approve the administrator restart if the app asks.

Direct client GUI:

1. Right-click `client\setup.cmd`.
2. Choose **Run as administrator**.
3. Paste the code.
4. Click Start setup.

Command line:

```powershell
cd client
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -ConnectionCode "<code>"
```

Windows needs the OpenSSH Client feature. If `ssh -V` fails, add it from
Settings, Apps, Optional features.

### B is macOS

1. Copy the package to B.
2. Double-click `app/Herdr-Setup.command`.
3. Choose Client and macOS.
4. Paste the code.

Or:

```bash
cd client
bash setup-macos.sh --code "<code>"
```

macOS needs the command line tools for `ssh-keygen` and `python3`:

```bash
xcode-select --install
```

### What B does

1. Decodes the v2 connection code.
2. Installs Tailscale if needed and joins the tailnet with the embedded key.
3. Waits until Host A is visible.
4. Installs herdr locally.
5. Creates `~/.ssh/id_ed25519` if it does not exist.
6. Tries SSH to A. If the key is not authorized, it posts the public key to the
   enrollment endpoint on A and retries.
7. Registers A with `herdr machine add`.
8. Installs the watchdog. Windows uses the `HerdrWatchdog` task. macOS uses the
   `dev.herdr.watchdog` LaunchAgent.

The output ends with:

```
Setup complete (vX.Y.Z, mode key)
  herdr --machine <label>
```

## Step 3: Verify

On Machine B:

```bash
herdr machine status
herdr machine list
herdr --machine <label>
```

`herdr machine status` must print `reachable`. Then open the TUI:

```bash
herdr
```

Select the machine in the sidebar. The first selection is manual because a TUI
needs an interactive terminal.

Check the watchdog.

Windows:

```powershell
Get-ScheduledTask -TaskName HerdrWatchdog
powershell -File client\watchdog.ps1 -DryRun
```

macOS:

```bash
launchctl print gui/$(id -u)/dev.herdr.watchdog
bash client/watchdog-macos.sh --dry-run
```

Exit code 0 means healthy. Exit code 11 means the watchdog would restart a
stalled client.

## Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| B shows `connecting`, then `endpoint did not acknowledge surface revocation` | `tailscale debug prefs \| grep RunSSH` on A | Must be false. Run `sudo tailscale set --ssh=false` |
| Same, SSH works | `herdr status --json` on A | `detached_server_daemon` must be true. Run `herdr server stop`, then `setsid -f herdr server </dev/null >/dev/null 2>&1` |
| Same, server is detached | Client retry loop | Restart only the client. Detach with Ctrl+B then Q, then run `herdr` again, or wait for the watchdog |
| `SSH authentication failed` | The code may be expired or already used | Run `./provision.sh` on A again and send the new code |
| `Host is not reachable in the tailnet` | `tailscale status` on both machines | Both must be online in the same tailnet. Check that the auth key is valid |
| Enrollment endpoint unreachable | Code TTL is one hour by default | Issue a new code, or add the public key to `~/.ssh/authorized_keys` on A manually |
| `OpenSSH client missing` on B | `ssh -V` | Install the Windows OpenSSH Client feature |
| Exit 2, 3, 4, 5, or 6 | Read the log | 2 input or prerequisite, 3 network, 4 SSH, 5 herdr, 6 internal |

Logs:

- Host A: `~/.local/state/herdr-setup/setup.log`
- Windows B: `%LOCALAPPDATA%\HerdrSetup\logs\setup-*.log`
- macOS B: `~/Library/Logs/HerdrSetup/setup-*.log`

## Security rules

- The connection code is base64, not encryption. It contains the auth key and
  the enrollment token.
- The auth key is single use and short lived. Create a new one for each client.
- Do not paste the code into a ticket, chat, or commit.
- The enrollment endpoint accepts one successful key and then stops.
- Revoke a client by removing its line from `~/.ssh/authorized_keys` on A, and
  by revoking its Tailscale key or device.
- `/etc/herdr-setup/authkey` is root-only. Do not copy it to B.

## Related pages

- `docs/QUICKSTART.md` is the one-page command reference.
- `docs/ARCHITECTURE.md` explains the layers and the connection code.
- `docs/TROUBLESHOOTING.md` is the full failure matrix.
- `docs/ACCESS-MODEL.md` covers tags, ACLs, onboarding, and revocation.
