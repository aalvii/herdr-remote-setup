# Contributing

Thanks for your interest. This project automates three layers: Tailscale
network, OpenSSH transport, and the herdr workspace.

## Ground rules

These decisions are product requirements, not preferences. A pull request that
reverses one needs a strong case and a test.

1. Transport is OpenSSH with a key. Tailscale SSH breaks herdr's bridge.
2. The remote herdr server starts detached. Linux uses `setsid -f`. macOS uses
   `python3` with `start_new_session=True`.
3. Enrollment binds port 0 and reports the real port through a port file.
4. The verified scripts under `host/` and `client/` are the source of truth.
   The app in `app/` is a front end and must not reimplement a flow.
5. No secret is committed, logged, or printed. That includes `tskey-...`
   values, private keys, connection codes, and enrollment tokens.
6. PowerShell 5.1 compatibility on Windows. No `&&`, no ternary, TLS 1.2 where
   a web call needs it.

## Development

There is no build step. You need:

- bash 3.2 or newer on Linux or macOS
- PowerShell 5.1 or newer on Windows
- python3 for the enrollment endpoint and the repository scan

## Checks

Run these before a pull request.

```bash
python3 tools/check-public.py
for f in $(git ls-files '*.sh' '*.command'); do bash -n "$f"; done
./host/install-desktop.sh
desktop-file-validate ~/.local/share/applications/herdr-remote-setup.desktop
desktop-file-validate ~/.local/share/applications/herdr-share.desktop
desktop-file-validate ~/.local/share/applications/herdr-new-client-code.desktop
bash app/herdr-setup.sh --self-test
bash client/setup-macos.sh --self-test
```

```powershell
powershell -File tools\verify-package.ps1
powershell -File client\setup.ps1 -SelfTest
powershell -File app\herdr-setup.ps1 -SelfTest
```

If you install shellcheck, run it with `-S error`.

## Pull requests

- Keep one change per pull request.
- Update `VERSION`, `CHANGELOG.md`, and the affected docs.
- Rebuild the manifest after any runtime file changes:
  `powershell -File tools\make-manifest.ps1`, then
  `powershell -File tools\verify-package.ps1` (must print `VERIFY OK`).
- Add a test or a self-test assertion for a behavior change.
- Do not add a dependency unless the target OS cannot do the job with what it
  already has.
- Do not add a private orchestration bundle or an internal host list.

CI runs the same checks on Ubuntu, Windows, and macOS.

## Commit messages

Use the imperative mood and a short subject, for example
`client: accept enrollment only on ok:true`.

## License

By contributing you agree that your contribution is licensed under the MIT
License in `LICENSE`.
