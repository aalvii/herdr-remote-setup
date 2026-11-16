# Third-party notices

This project is not affiliated with or endorsed by Herdr or Tailscale.

## Herdr

| Item | Value |
|------|-------|
| Project | Herdr, terminal workspace manager for AI coding agents |
| Version | 0.9.5 |
| License | Apache License 2.0 |
| Source | https://github.com/herdrdev/herdr |
| Bundled file | `client/assets/herdr-windows-x86_64.zip` |
| Full license | `client/assets/LICENSE-herdr.txt` |

The Windows archive is included as an offline fallback for the client setup. It
is a repackaged Herdr Windows release for this installer and is not
byte-identical to the upstream release asset. The Herdr binary remains under the
Apache License 2.0. The rest of this repository is under the MIT License in
`LICENSE`.

## Tailscale

Tailscale is installed at runtime by the setup scripts. It is not bundled in
this repository. Tailscale is a separate product with its own license and terms
at https://tailscale.com.

## OpenSSH

The scripts use the OpenSSH client and server that ship with the operating
system. OpenSSH is not bundled.
