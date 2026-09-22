# Release validation

Version 0.1.0, 2026-09-21. Experimental source-only release.

## Helper checks performed

- zsh syntax check and help command passed.
- Seven refusal cases passed: unknown command, missing verification argument,
  missing app, empty app, symlink as app root, missing local package, and invalid
  preparation arguments. Reproduce with `/bin/zsh tests/safety.zsh`.
- Read-only environment check on the physical test Mac detected macOS 27.0
  (26A428), Apple Silicon, available Rosetta, USB 03f0:5905, and the installed app.
- Preparation from a local original HP package passed end to end.
- A fresh HTTPS download directly from HP passed end to end, including pinned
  package SHA-256, installer signature, extraction, 234 file hashes, 40 symlink
  targets, exact entry inventory, HP code-signing identity, and Gatekeeper.
- Publication content was checked as text-only source/documentation/manifests,
  without HP binaries, scans, raw logs, private email, or local machine paths.

## Hardware evidence

See [FINDINGS.md](FINDINGS.md) for the earlier successful physical simplex and duplex
scans through the same exact driver. Preparation-helper testing did not reinstall
the driver or move paper. It is not a second independent hardware test.

## Still unverified

Another Mac, a clean Mac without previous HP components, Finder copy by an external
tester, rollback, cancellation, sleep/reboot/reconnect recovery, direct NAPS2
scanning, and front-panel button operation. The HP Utility Scan Button panel exists
for the scanner on the test Mac, but returned Image Capture error 4294967249 when
opened with Image Capture also running. The cause has not been established.
