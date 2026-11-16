# Set up Host A and Machine B

This page is the two-machine runbook. Host A runs the herdr server and shows a
6-digit PIN. Machine B connects with that PIN.

Version: see `VERSION` (currently 4.0.0).

## Supported pairs

| Host A | Machine B | PIN flow | Advanced code flow |
|--------|-----------|:---:|:---:|
| Linux | Windows | yes | yes |
| Linux | macOS | no, use Advanced | yes |
| macOS | Windows | yes | yes |
| macOS | macOS | no, use Advanced | yes |

Host A cannot be Windows. Machine B cannot be Linux in this package.

## Before you start

1. A Tailscale account. Both machines must join the same tailnet.
2. Host A: Linux or macOS, sudo or admin rights, sshd, and python3.
   On macOS: `xcode-select --install`.
3. Machine B: Windows 10 or 11.
4. Copy the whole package to both machines.
5. No Tailscale auth key is needed for the PIN flow.
6. On Host A, if Tailscale is not connected yet, run `sudo tailscale up` once.

## Step 1: Share Host A

Linux:

- double-click `host/Herdr-Provision.desktop`; or
- run:

```bash
cd host
bash pair.sh
```

macOS:

- double-click `host/Herdr-Provision.command`; or
- run `bash host/pair.sh`.

The host prints:

```
Herdr Share v4.0.0
  Computer : <hostname>
  User     : <login user>
  Address  : 100.x.y.z:8765

  PIN      : 123456
```

Keep the window open. The PIN is valid for 30 minutes and rotates after each
successful connection. Ctrl+C stops sharing.

The host flow:

1. Checks Tailscale and prints an error if it is not connected.
2. Checks or starts sshd.
3. Installs herdr if missing and starts the herdr server detached.
4. When an API token is stored, checks or adds the `tag:client` policy entries
   and creates a one-time guest join code.
5. Starts the pairing service on the Tailscale address at port 8765.
6. Prints the join code, when there is one, and the PIN.

It never enables Tailscale SSH. A missing or rejected API token does not stop
the PIN flow: the host prints a warning and continues PIN-only.

### macOS host

If the host says SSH is off, enable System Settings > General > Sharing >
Remote Login. The script tries `systemsetup -setremotelogin on` first.

### Linux host

If the host says sshd is not running, start it:

```bash
sudo systemctl start sshd
```

## Step 2: Connect Machine B

1. Double-click `app\Herdr-Setup.cmd`.
2. Click **Connect to a computer**.
3. Pick Host A from the list, or type its Tailscale IP.
4. Enter the 6-digit PIN from Host A.
5. Click **Connect**.
6. When it says Connected, click **Open herdr**.

The app signs in to Tailscale if needed, installs herdr if missing, sends the
public key and PIN, tests SSH, adds Host A to herdr, and installs the watchdog.

If the list is empty, click **Refresh**. Both machines must be online in the same
tailnet, and the host sharing window must still be open.

### macOS client

The PIN client is Windows-only in 4.0.0. On macOS, use the Advanced connection
code flow in section 6.

### Linux client

The Linux client is not shipped.

## Step 3: Verify

On Machine B:

```powershell
herdr machine status
herdr --machine <label>
```

`herdr machine status` must print `reachable`. Then open the TUI:

```powershell
herdr
```

Select the machine in the sidebar. The first selection is manual because a TUI
needs an interactive terminal.

Check the watchdog:

```powershell
Get-ScheduledTask -TaskName HerdrWatchdog
powershell -File client\watchdog.ps1 -DryRun
```

Exit code 0 means healthy. Exit code 11 means the watchdog would restart a
stalled client.

## Troubleshooting

| Symptom | Check | Fix |
|---------|-------|-----|
| No computer found | Is the host sharing window open? | Start `host/pair.sh` and click Refresh |
| No computer found | `tailscale status` on both machines | Both must be online in the same tailnet |
| Wrong PIN | The PIN is six digits and rotates | Read the current PIN on Host A |
| Too many attempts | Five wrong attempts in five minutes | Wait, or restart `pair.sh` |
| Host not visible | The client is logged out of Tailscale | Complete the browser login |
| SSH failed after pairing | `pgrep -x sshd` on Host A | Start sshd; check `~/.ssh` is 700 |
| Port 8765 is busy | Another service owns the port | Stop it; the host prints the error |
| Herdr shows connecting | `tailscale debug prefs \| grep RunSSH` on Host A | Must be false |
| Herdr shows connecting | `herdr status --json` on Host A | `detached_server_daemon` must be true |
| Herdr stalled after revocation | Known issue #3842 | Restart only the client, or wait for the watchdog |

Logs:

- Host A: `~/.local/state/herdr-setup/pair.log`
- Machine B: `%LOCALAPPDATA%\HerdrSetup\logs\pair-*.log`

The pairing service never logs a PIN or a key.

## Advanced: connection code

Use this for automation, for the macOS client in 4.0.0, or when the PIN flow is
not available.

On Host A:

```bash
cd host
bash provision.sh --authkey tskey-auth-xxxxxxxxxxxx --save-key
```

The host prints a base64 connection code. It contains a one-time Tailscale auth
key and an enrollment token. Treat it as a secret.

On Machine B, Windows:

```powershell
cd client
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -ConnectionCode "<code>"
```

On Machine B, macOS:

```bash
cd client
bash setup-macos.sh --code "<code>"
```

The advanced flow is unchanged. It uses the same OpenSSH key transport, the
enrollment endpoint, and `herdr machine add`.

## Security rules

- The PIN is a secret. Do not share it outside the two machines.
- The pairing service binds the Tailscale address only, at port 8765. The
  tailnet encrypts the HTTP traffic.
- The simple flow does not create a `tskey-...` value.
- The advanced connection code is base64, not encryption. It can carry a
  Tailscale auth key and an enrollment token.
- Revoke a machine by removing its key from `~/.ssh/authorized_keys` on Host A.
- Do not post a PIN or a connection code in a ticket or chat.

## Related pages

- `docs/QUICKSTART.md` is the one-page command reference.
- `docs/ARCHITECTURE.md` explains the layers and the pairing protocol.
- `docs/TROUBLESHOOTING.md` is the full failure matrix.
- `docs/ACCESS-MODEL.md` covers tags, ACLs, onboarding, and revocation.
