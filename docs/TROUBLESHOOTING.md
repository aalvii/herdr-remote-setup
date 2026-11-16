# Troubleshooting

Use the exit code first, then read the log.

| Exit | Log |
|------|-----|
| any | Client Windows `%LOCALAPPDATA%\HerdrSetup\logs\setup-*.log` |
| any | Client macOS `~/Library/Logs/HerdrSetup/setup-*.log` |
| any | Host `~/.local/state/herdr-setup/setup.log` |

---

## Remote machine stuck at "connecting" and cannot be selected

Three independent causes were observed in one incident. Check them in order.

### 1. Tailscale SSH is serving port 22

Symptom: the handshake succeeds, then about 10 seconds later the client logs
`endpoint did not acknowledge surface revocation`, and the machine never
activates.

Check on the host:

```bash
tailscale debug prefs | grep RunSSH      # must be false
```

Cause: herdr's bridge is wrapped by
`tailscaled be-child ssh --force-v1-behavior`, which changes the channel
semantics.

Fix:

```bash
sudo tailscale set --ssh=false
```

### 2. The local client stopped retrying

Symptom: `herdr-client.log` has no new lines for many minutes, although SSH
works and `herdr --machine <name> agent list` returns data.

Cause: known upstream issue #3842. Re-activation is single-shot; after a
revocation timeout the client does not try again.

Fix: restart only the client.

```
Ctrl+B then Q      # detach
herdr              # start a fresh client
```

If the TUI is frozen, close the window, or run `client\watchdog.ps1` which
stops the client process and relaunches it through a scheduled task. Panes and
agents survive either way.

### 3. The remote server is not a detached daemon

Symptom: `herdr machine status` prints
`remote Herdr server is stopped or incompatible`, and `herdr status --json`
reports `"detached_server_daemon": false`.

Cause: the server was started from an SSH session, for example with `nohup`.
Herdr's saved-machine gate rejects it.

Fix:

```bash
herdr server stop
setsid -f herdr server </dev/null >/dev/null 2>&1
herdr status --json | grep detached_server_daemon    # expect true
```

Do not use plain `nohup herdr server &`. Use `setsid -f`.

---

## macOS host or client problems

### "need setsid or python3" or enrollment does not start

macOS has no `setsid`, and the detached herdr start uses `python3`. Install the
Command Line Tools once:

```bash
xcode-select --install
python3 -V
```

The first `python3` call may open an install dialog. Finish it, then rerun.

### Host: sshd refuses the enrolled key

```bash
ls -ld ~ ~/.ssh ~/.ssh/authorized_keys
```

`~/.ssh` must be 700, `authorized_keys` 600, and `$HOME` must not be group or
other writable. The host script removes write permission; if you ran the steps
by hand, run `chmod go-w ~`.

Check that Remote Login is on:

```bash
sudo systemsetup -getremotelogin
sudo systemsetup -setremotelogin on
```

Or System Settings > General > Sharing > Remote Login.

### Host: Tailscale CLI not found

The App Store build has no CLI on `PATH`. The standalone app has one inside the
bundle:

```bash
/Applications/Tailscale.app/Contents/MacOS/Tailscale status
```

`brew install --cask tailscale` installs the standalone app. Open it once so the
daemon starts, then rerun the script.

### Launcher: "cannot be opened because the developer cannot be verified"

Gatekeeper quarantines files that came from a download. Allow it:

- right-click the `.command` file, choose **Open**, then **Open** again; or
- `xattr -d com.apple.quarantine /path/to/Herdr-Setup.command`.

### Watchdog LaunchAgent does not run

```bash
launchctl print gui/$(id -u)/dev.herdr.watchdog
tail -20 ~/Library/Logs/HerdrSetup/watchdog.log
```

If `watchdog.log` says "no client log found", the real client log path differs
from the three probed paths. Set it explicitly:

```bash
HERDR_CLIENT_LOG="$HOME/Library/Application Support/herdr/herdr-client.log" \
  bash client/watchdog-macos.sh --dry-run
```

Then put the same path in the LaunchAgent `ProgramArguments` or the environment.
The watchdog never guesses and never restarts a healthy client.

The watchdog reopens Terminal through `osascript`. macOS may ask for Automation
permission the first time. Allow it, or restart the client by hand.

### The app shows guidance instead of running

That is by design. Host mode runs on the host, client mode runs on the client.
Pick the OS of the machine the app is running on. `Host + Windows` and
`Client + Linux` are not shipped.

---

## Exit 2 - prerequisite or input

### "OpenSSH client missing"

Windows: Settings > Apps > Optional features > Add a feature > **OpenSSH Client**.
Verify with `ssh -V`. macOS and Linux ship it with the OS.

### "Invalid connection code"

- copy it again as one line, with no spaces or line breaks;
- confirm the package version matches on both sides (`VERSION`);
- v1 codes are still accepted, but they are always treated as `mode=key`.

### "unknown option" / "cannot run as root"

Host options are listed by `./host/setup.sh --help`. `install-autostart.sh`
must run as root.

---

## Exit 3 - network (Tailscale)

### Tailscale install failed

Windows needs Administrator. Right-click `setup.cmd` > Run as administrator.

Manual: `winget install --id Tailscale.Tailscale`

### "Host is not reachable in the tailnet"

```powershell
tailscale status
tailscale ip -4
```

1. Is the client logged in? `tailscale up`.
2. Same tailnet? Compare the account shown by `tailscale status` on both sides.
3. Is the host online and does it show the address in the code?
4. Is an ACL blocking the pair?

If the code carries `tskey-...`, the key may be expired, already used, or from
another tailnet.

---

## Exit 4 - transport

### A. Tailscale SSH (`mode=ts-ssh`)

Symptoms: `Permission denied`, `no supported authentication methods`, or an
immediate refusal, while the host is visible in `tailscale status`.

Checklist:

```bash
# on the host
tailscale debug prefs | grep -i RunSSH
sudo tailscale up --ssh --advertise-tags=tag:herdr-host
```

`RunSSH` must be `true`. If it is `false`, Tailscale SSH is off.

ACL must contain an `ssh` section that matches the node:

```json
{
  "ssh": [
    { "action": "accept", "src": ["autogroup:member"],
      "dst": ["tag:herdr-host"], "users": ["alice"] }
  ]
}
```

Common causes:

| Cause | Symptom | Fix |
|-------|---------|-----|
| no `ssh` ACL section | refused | add the section |
| `action: check` | browser prompt, BatchMode fails | use `accept` |
| node lost its tag after re-registration | refused | re-run `tailscale up --advertise-tags=...` or use `install-autostart.sh` |
| `dst` uses an IP instead of a tag | works until re-registration | switch to `tag:` |
| host user not in `users` | refused | add the user |

### B. OpenSSH key (`mode=key`)

"SSH authentication failed" means the client key is not authorized.

```bash
# host
ssh-keygen -lf ~/.ssh/authorized_keys
# client
ssh-keygen -lf $env:USERPROFILE\.ssh\id_ed25519.pub
```

If the client fingerprint is absent:

```bash
echo 'ssh-ed25519 AAAA...your-public-key... you@client' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### Connection closes immediately, no banner

The host `sshd` may apply per-source penalties after repeated failures.
Reference hardening:

```ini
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers alice
MaxAuthTries 5
```

Options: wait out the penalty, restart `sshd`, or connect from another address.

---

## Exit 5 - herdr

### "Downloading Herdr" then failure

`herdr.dev` serves the manifest; the binary comes from GitHub Releases. The
client falls back to `client/assets/herdr-windows-x86_64.zip`. Confirm it exists
next to `setup.ps1`.

### `herdr machine add` hangs

It prepares the remote server over SSH and can be slow on DERP relays. Retry:

```powershell
herdr machine add <target> --label <name>
herdr machine status <name>
```

### herdr says "noninteractive SSH command timed out"

A status probe failed. It does not always mean the files are wrong. Check:

```powershell
ssh -o BatchMode=yes <user>@<target> "echo ok"
tailscale ping <target>
```

If Tailscale reports `DERP`, latency is high; retry or wait for a direct path.

---

## After a VM reboot or re-registration

Observed: herdr can reconnect across a reboot even when the Tailscale device ID
changed. That works when the **100.x address is unchanged** and the machine
entry targets that address.

It breaks when:

- the node re-registers with a new 100.x address (the entry is pinned by IP);
- the node loses its tag and the ACL is tag-based (`ts-ssh` only).

Mitigations shipped in this package:

- Connection code v2 carries `dns`; the client prefers the MagicDNS name.
- `install-autostart.sh` re-asserts tag and `--ssh` at boot.
- Disable node key expiry for server nodes in the admin console.

Verify a node kept its identity:

```bash
tailscale status --json | tr , '\n' | grep -iE 'publickey|dnsname'
```

Compare before and after the reboot. A changed `PublicKey` means the state was
lost, not that the reboot changed anything.

---

## Quick health check

Client (Windows):

```powershell
powershell -File client\setup.ps1 -SelfTest
powershell -File app\herdr-setup.ps1 -SelfTest
powershell -File tools\verify-package.ps1
```

Client (macOS):

```bash
bash client/setup-macos.sh --self-test
bash app/herdr-setup.sh --self-test
```

Host (Linux and macOS):

```bash
./host/setup.sh --json | head -c 300
herdr status
tailscale ip -4
tailscale debug prefs | grep -i RunSSH
```
