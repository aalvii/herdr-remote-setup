## Why

<!-- The problem this solves for a host operator or a client user. -->

## What changed

<!-- Behavior, files, and the shape of the change. -->

## Checks

- [ ] `python3 tools/check-public.py` is clean
- [ ] `tools/verify-package.ps1` prints `VERIFY OK`
- [ ] Client and app self-tests pass on the affected OS
- [ ] `bash -n` passes for changed shell files
- [ ] No secret, connection code, private key, or internal hostname is included
- [ ] `VERSION`, `CHANGELOG.md`, and the affected docs are updated
- [ ] `MANIFEST.sha256` is rebuilt

## Notes for the reviewer

<!-- Anything the reviewer should look at first, or a behavior that is not tested. -->
