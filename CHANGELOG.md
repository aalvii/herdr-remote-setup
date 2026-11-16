# Changelog

## 3.1.1 - 2026-11-15

Restore the portable double-click launchers.

### Added

- `host/Herdr-Provision.desktop` and `app/Herdr-Setup.desktop`. Each file uses
  the `%k` field code to resolve its own folder, so the repository stores no
  absolute path. Both pass `desktop-file-validate`, and the resolved path works
  when it contains a space.
- `install-desktop.sh` remains the option for absolute menu entries and a
  Desktop shortcut.

### Changed

- `VERSION` is 3.1.1.
- README, QUICKSTART, ARCHITECTURE, and TROUBLESHOOTING describe the portable
  launchers.

---

## 3.1.0 - 2026-11-15

Public repository release. The product behavior is unchanged.

### Added

- `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, `.gitattributes`,
  `.editorconfig`, and issue and pull request templates.
- `.github/workflows/ci.yml` runs the public scan and self-tests on Ubuntu,
  Windows, and macOS.
- `tools/check-public.py` fails on key material, private key headers, internal
  hostnames, author home paths, and the private orchestration bundle name.
- `host/install-desktop.sh` now installs a Desktop shortcut, sets the GNOME
  trusted flag when `gio` exists, and supports `--uninstall`.

### Changed

- Public tree no longer carries the private orchestration bundle, the legacy
  prototypes, the internal handoff, or old release archives. They live outside
  this repository.
- `docs/acl-policy.hujson` is a generic template. The tailnet device inventory
  and customer hostnames are removed.
- `docs/ACCESS-MODEL.md` is rewritten in English and corrected. It no longer
  recommends Tailscale SSH for herdr clients.
- The prebuilt `.desktop` files are removed. `install-desktop.sh` generates
  absolute `Exec` paths at install time, so no author path is stored.
- Example users, hosts, and paths in the docs are generic. No real account,
  hostname, IP address, or public key remains.
- `VERSION` is 3.1.0.

### Fixed

- The ACL example no longer contradicts the key-mode decision.

### Notes

- This release is repository hygiene only. The Linux host and Windows client
  flows were re-tested; the macOS paths remain unverified because no Mac was
  reachable.

---

## 3.0.0 - 2026-11-14

macOS support for both roles, and one thin app to pick Role and OS.

### Added

- macOS host support in `host/setup.sh`: Darwin preflight, Tailscale app-bundle
  and Homebrew discovery, `brew install --cask tailscale`, Remote Login check
  through `systemsetup` and `launchctl`, a group-writable `$HOME` fix that sshd
  requires, herdr discovery in `~/.local/bin` and Homebrew paths, and
  `ifconfig` address discovery.
- `start_detached` helper. It uses `setsid -f` where available and
  `python3 subprocess.Popen(start_new_session=True)` on macOS, which has no
  `setsid`. Both the herdr server and `enroll.py` use it.
- `host/Herdr-Provision.command`: double-clickable macOS launcher for the host
  flow. It keeps the Terminal window open so the code stays readable.
- `client/setup-macos.sh`: macOS client. Same eight steps as the Windows
  client: decode v1/v2 code, Tailscale, herdr, SSH key, enrollment, machine
  registration, reachability check, watchdog. Bash 3.2 safe.
- `client/watchdog-macos.sh`: same stall detection as the Windows watchdog,
  restart through `osascript` and Terminal, exit codes 0/2/10/11.
- `client/install-watchdog-macos.sh`: watchdog as a LaunchAgent
  `dev.herdr.watchdog`, with `launchctl bootstrap` and `plutil -lint`.
- `app/herdr-setup.ps1` and `app/Herdr-Setup.cmd`: Windows front end. WinForms,
  PowerShell 5.1, no third-party runtime.
- `app/herdr-setup.sh`, `app/Herdr-Setup.command`, `app/launch-app.sh`, and
  `app/Herdr-Setup.desktop`: Linux and macOS front end. One shell menu.
- One support matrix per front end: Host+Linux, Host+macOS, Client+Windows,
  Client+macOS run; Host+Windows and Client+Linux are not shipped and show
  guidance instead.
- `--self-test`, `--dry-run`, and headless `-NoGui` paths so the app can be
  verified without a second machine.
- `tools/verify-package.ps1` fails on secret-shaped `tskey-auth-...` literals
  in shipped code files.

### Changed

- `VERSION` is 3.0.0.
- `install-desktop.sh` also installs **Herdr Remote Setup (App)**.
- `host/Herdr-Provision.desktop` Exec points at the v3.0.0 mirror path.
- `host/provision.sh` no longer requires the execute bit on `setup.sh`, and
  calls it through `bash`. A zip or scp copy may not keep file modes.
- README, QUICKSTART, ARCHITECTURE, TROUBLESHOOTING and HANDOFF describe macOS
  and the app.

### Fixed

- The client self-test fixture contained a `tskey-auth-...` shaped literal. It
  is now `example-auth-key`, and the new secret scan keeps it out.
- `KEY_COUNT` printed a second `0` line on an empty `authorized_keys`.
- The macOS client accepts an enrollment response only when the body says
  `"ok": true`, not on the HTTP status alone.
- The macOS client leaves an existing machine entry alone when it cannot parse
  the entry id, instead of removing and re-adding it, which triggers #3842.

### Notes

- macOS host and client paths are implemented but **not runtime verified**. No
  macOS machine was reachable for the release test. The macOS scripts pass
  `bash -n`, the LaunchAgent plist parses, and the detached-start mechanism was
  proven on Linux, but no real Mac ran them.
- The app runtime choice is evidence based. The Linux host has python3 but no
  `tkinter` and no `DISPLAY`, so Tkinter cannot run there. Windows PowerShell
  5.1 with WinForms needs no install. macOS Command Line Tools `python3` does
  not ship tkinter reliably. See `docs/ARCHITECTURE.md`.

---

## 2.1.0 - 2026-11-14

One-command provisioning, automatic enrollment, automatic watchdog.

### Added

- `host/provision.sh`: single entry point. Resolves the Tailscale auth key from
  `--authkey`, `$HERDR_TS_AUTHKEY`, `/etc/herdr-setup/authkey`, or a prompt, then
  runs `setup.sh --mode key --enroll` and prints the code.
- `host/provision-gui.sh`: one-dialog version for desktop users.
- `--save-key` stores the auth key at `/etc/herdr-setup/authkey` (root 600).
- `host/enroll.py` and `host/enroll.sh`: one-time SSH key enrollment endpoint.
  The token is embedded in the connection code as `enroll=<port>:<token>`.
- Client posts its public key to the enrollment endpoint when key auth fails,
  then retries SSH.
- `client/watchdog.ps1`: detects the stalled-client state and restarts only the
  client. Relaunch uses an interactive scheduled task, because a TUI needs a
  console.
- `client/install-watchdog.ps1`: installs or removes the watchdog task.
- Client installs the watchdog by default (`-NoWatchdog` to skip).
- `install-desktop.sh` adds a second menu entry, **Herdr: New Client Code**.
- `host/Herdr-Provision.desktop` + `host/launch-provision.sh`: double-clickable
  launcher that opens a terminal and runs the flow without any command. Works
  without zenity.
- `docs/QUICKSTART.md`: one-page end-to-end flow with expected output.
- TROUBLESHOOTING section for the three observed stall causes.

### Changed

- Product flow is now: host `./provision.sh` -> client double-click -> paste
  code -> done. No separate enrollment or watchdog commands.
- **Default transport is now `key`.** `ts-ssh` is documented as incompatible
  with herdr's remote bridge: the bridge is wrapped by
  `tailscaled be-child ssh --force-v1-behavior`, which breaks surface
  activation and revocation.
- `host/setup.sh --mode key` warns when Tailscale SSH is still enabled.
- README, ARCHITECTURE, ACCESS-MODEL updated.

### Fixed

- Enrollment listener failed silently on a busy port; it now binds port 0 and
  reports the real port through a port file.
- `enroll.txt` had shifted fields (port/token/ttl).
- Remote server started with `nohup` reports `detached_server_daemon: false`
  and blocks saved machines. Use `setsid -f herdr server`.

### Notes

- Observed upstream issue: herdrdev/herdr#3842 (surface revocation timeout,
  single-shot re-activation).
- Preview channel test pending.

---

## 2.0.0 - 2026-11-14

Tailscale SSH transport, dual-mode product.

### Added

- `--mode ts-ssh|key|auto` on the host; the client honours the mode in the code.
- Tailscale SSH support: no SSH key exchange, authorization from the tailnet ACL.
- `host/install-autostart.sh`: systemd unit that re-asserts Tailscale identity,
  tag, and `--ssh` after a reboot or re-registration.
- Connection code **v2** (`v=2;mode=...;dns=...`), with automatic v1 fallback.
- `docs/ACCESS-MODEL.md`: operator / client / herdr-host roles, tagging rules,
  customer onboarding and revocation, ACL matrix.
- `docs/acl-policy.hujson`: paste-ready tailnet policy.
- Client self-test now covers both v1 and v2 parsing.
- Client prefers the MagicDNS name over a pinned 100.x address.

### Changed

- Host reports `dns`, `tag`, and `mode` in human and `--json` output.
- Client reports the chosen mode in results and logs.
- ACL guidance added to the README (`action: accept` required for unattended).
- `VERSION` bumped to 2.0.0.

### Notes

- Reboot does not change the node. Losing `/var/lib/tailscale` does.
- `ts-ssh` fails if a re-registered node loses its tag; the autostart unit
  prevents that.

### Fixed

- `SSH_HostKeys` is absent from `tailscale status --json` on 1.104.x; both the
  host script and the autostart unit now read `RunSSH` from `tailscale debug prefs`.
- Client verification used `herdr --machine <name> status`, which is not a
  valid command; it now uses `herdr machine status <name>`.
- Client removed and re-created machine entries by label; it now matches by
  target and keeps the user-chosen label.

---

## 1.0.0 - 2026-11-14

Productization release.

### Added

- Network layer: the client installs Tailscale and joins the tailnet with a
  one-time auth key embedded in the connection code.
- `client/assets/herdr-windows-x86_64.zip` offline package.
- `-ShowVersion`, `-SelfTest`, `--json`, `--quiet`, `--version`.
- Structured exit codes (0, 2, 3, 4, 5, 6).
- Log files with `tskey-...` redaction.
- `tools/verify-package.ps1`, `make-manifest.ps1`, `uninstall.ps1`.
- `MANIFEST.sha256`.
- Generated desktop entry (`install-desktop.sh`), spec-compliant.

### Fixed

- `ssh-keygen` failed when `%USERPROFILE%\.ssh` was missing.
- PowerShell 5.1 incompatibilities (`&&`, stderr-as-error, TLS 1.2).
- herdr install failed when GitHub was unreachable.
- Hardcoded user paths in launchers.
- Console mojibake from Unicode box characters in `.bat`.

### Previous versions

- 0.9.x prototype scripts (`herdr-setup-machine-a.sh`,
  `herdr-setup-machine-b.bat`, `herdr-remote-setup-b.ps1`).
