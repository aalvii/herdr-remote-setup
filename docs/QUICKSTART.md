# Quickstart

One page: share a Linux or macOS computer, connect a Windows machine with a
6-digit PIN. No connection code, no Tailscale auth key, no IP address.

Version: see `VERSION` (currently 4.0.0).

| Action | Linux | macOS | Windows |
|--------|:---:|:---:|:---:|
| Share this computer | yes | yes | not shipped |
| Connect with a PIN | not shipped | Advanced flow in 4.0.0 | yes |
| Advanced connection code | yes | yes | yes |

---

## 0. Prerequisites

- A Tailscale account. Both machines must join the same tailnet.
- Host: Linux or macOS, with sudo or admin rights, sshd, and python3.
  On macOS, install the command line tools once with `xcode-select --install`.
- Client: Windows 10 or 11.
- Copy the whole package to both machines. Do not copy only the `client`
  folder.

The simple flow does not need a `tskey-...` auth key. The apps open the Tailscale
browser login when needed. On the host, if Tailscale is not connected yet, run
`sudo tailscale up` once before sharing.

---

## 1. Share the host

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

Keep this window open. The PIN is valid for 30 minutes. It rotates after each
successful connection. Ctrl+C stops sharing.

The host flow checks or starts sshd and herdr, then starts the pairing service
on the Tailscale address. It does not enable Tailscale SSH.

If it exits with `SSH server is not running`, start sshd. On macOS, enable
System Settings > General > Sharing > Remote Login.

---

## 2. Connect the Windows client

1. Double-click `app\Herdr-Setup.cmd`.
2. Click **Connect to a computer**.
3. Pick the sharing computer from the list, or type its IP.
4. Enter the 6-digit PIN.
5. Click **Connect**.
6. When it says Connected, click **Open herdr**.

The app signs in to Tailscale if needed, installs herdr if missing, sends the
public key and PIN, tests SSH, adds the machine to herdr, and installs the
watchdog. No command line is needed.

If the list is empty, click **Refresh**. Both machines must be online in the same
tailnet, and the host sharing window must still be open.

The direct command form, for testing:

```powershell
cd client
powershell -ExecutionPolicy Bypass -File .\pair.ps1 -HostName 100.x.y.z -Pin 123456
```

---

## 3. Use it

On the Windows machine:

```powershell
herdr machine status
herdr --machine <label>
```

Or run `herdr` and select the machine in the sidebar.

Check the watchdog:

```powershell
Get-ScheduledTask -TaskName HerdrWatchdog
powershell -File client\watchdog.ps1 -DryRun
```

---

## 4. How the simple flow works

1. The host pairing service listens on the Tailscale address at port 8765.
2. The Windows app scans tailnet peers and asks each one for
   `/api/info`. A sharing host answers with `service: herdr-pair`.
3. The app sends the client public key and the PIN to `/api/request`.
4. The host checks the PIN, appends the key to `~/.ssh/authorized_keys`, and
   returns `ok`.
5. The client connects over OpenSSH key, runs `herdr machine add`, and installs
   the watchdog.

No Tailscale SSH. No connection code. The PIN is the only shared secret.

---

## 5. If it does not work

| Symptom | Check | Fix |
|---------|-------|-----|
| No computer found | Is the host sharing window open? | Start `host/pair.sh` and click Refresh |
| No computer found | Are both machines on the same tailnet? | `tailscale status` on both |
| Wrong PIN | PIN is six digits and rotates after each success | Read the current PIN on the host |
| Too many attempts | Five wrong attempts in five minutes | Wait five minutes or restart `pair.sh` |
| Host not visible | Tailscale is logged out on the client | Complete the browser login |
| SSH failed after pairing | `pgrep -x sshd` on the host | Start sshd; check `~/.ssh` is 700 |
| Port 8765 is busy | Another service owns the port | Stop it; the host prints the error |
| Herdr shows connecting | `tailscale debug prefs \| grep RunSSH` on the host | Must be false |
| Herdr shows connecting | `herdr status --json` on the host | `detached_server_daemon` must be true |
| Herdr stalled after revocation | Known issue #3842 | Restart only the client, or wait for the watchdog |

Logs:

- Host: `~/.local/state/herdr-setup/pair.log`
- Windows: `%LOCALAPPDATA%\HerdrSetup\logs\pair-*.log`

The host pairing service never logs a PIN or a key.

---

## 6. Advanced: connection code

Use this for automation, for the macOS client in 4.0.0, or when the PIN flow is
not available.

Host:

```bash
cd host
bash provision.sh --authkey tskey-auth-xxxxxxxxxxxx --save-key
```

This prints a base64 connection code. It contains a one-time Tailscale auth key
and an enrollment token. Treat it as a secret.

Windows client:

```powershell
cd client
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -ConnectionCode "<code>"
```

macOS client:

```bash
cd client
bash setup-macos.sh --code "<code>"
```

The advanced flow is unchanged. See `README.md`, `docs/ARCHITECTURE.md`, and
`docs/SETUP-A-AND-B.md` for details.

---

## 7. Operations

| Task | Command |
|------|---------|
| Share this computer | `./host/pair.sh` |
| Stop sharing | Ctrl+C in the host window |
| Connect from Windows | `app\Herdr-Setup.cmd` |
| Check the watchdog | `powershell -File client\watchdog.ps1 -DryRun` |
| Remove the watchdog | `powershell -File client\install-watchdog.ps1 -Uninstall` |
| Remove machine entries | `powershell -File tools\uninstall.ps1` |
| Advanced new code | `./host/provision.sh` |
| Auto-start guard for Tailscale | `sudo ./host/install-autostart.sh --authkey ... --tag tag:herdr-host` |

---

## 8. Security

- The PIN is a secret. It is six digits, rotates after each success, and allows
  five wrong attempts in five minutes.
- The pairing service binds the Tailscale address only, at port 8765. The tailnet
  encrypts the HTTP traffic.
- The simple flow does not create a `tskey-...` value.
- The advanced connection code is base64, not encryption. It can carry a
  Tailscale auth key and an enrollment token. Treat it as a secret.
- The PIN or code can appear in the process list while a client runs. That is a
  documented limit.

---

## 9. More

- `docs/SETUP-A-AND-B.md` — the two-machine runbook
- `docs/ARCHITECTURE.md` — layers and the pairing protocol
- `docs/TROUBLESHOOTING.md` — full failure matrix
- `docs/ACCESS-MODEL.md` — tags, ACLs, onboarding, and revocation
