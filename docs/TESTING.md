# Release validation

Version 0.3.0, 2026-09-22. Experimental source-only release.

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

## Optional button helper

- Native arm64 compilation and local ad-hoc signature verification passed.
- Build-time offline checks passed: separate batches keep separate page counts,
  partial PDFs have an INCOMPLETE name, and an empty batch creates no PDF.
- The exact HP status query returned zero at idle, one on a user-confirmed Scan
  press, then zero on the next read. A generic USB interrupt was not used as the
  scan trigger.
- The helper acquired an eight-page duplex document. A readiness callback timing
  issue and an ImageCaptureCore reconnect failure were found and corrected.
- The final implementation uses one scan process per batch. Without restarting
  the menu-bar app, it saved a two-page duplex PDF, then a further two-page PDF
  started by the physical front Scan button. The earlier files' SHA-256 hashes
  stayed unchanged. Output pages were rendered and inspected locally. The final
  button-triggered sheet was upside down on both sides; automatic orientation
  correction is not implemented, and the output was left unchanged.
- Changing the destination through the folder chooser persisted across app
  restarts. Original HP components were not changed for button support.

## Smaller files and format selection in v0.3.0

- Native arm64 compilation, local ad-hoc signature verification, and the build's
  offline output checks passed. These cover all three compression levels, JPEG
  dimensions and numbered files, PDF page counts and embedded compressed JPEG
  streams, separate batches, INCOMPLETE naming, duplicate-save refusal, and empty
  or unreadable input.
- JPEG and Smallest were selected in the controls, then the helper was restarted.
  Both selections and the chosen destination persisted. PDF and Balanced were
  restored and verified after another restart, then front-button listening resumed.
- Two new physical duplex acquisitions using PDF and Balanced produced a two-page
  PDF (8,146,206 bytes) and a separate 30-page PDF (48,347,039 bytes). Every page
  contained a compressed JPEG stream. The two-page document retained 300-dpi
  image dimensions, and its first page was rendered and visually checked for
  readable text. These are different documents from the earlier lossless tests;
  their sizes are not a controlled compression-ratio comparison.
- SHA-256 checks confirmed all six pre-existing scan PDFs remained unchanged.
  No existing scans were recompressed. No HP components were changed.
- JPEG file generation was tested offline; a physical acquisition with JPEG
  selected has not yet been tested. The confirmed physical front-button sequence
  above was tested in v0.2.0; the USB query and acquisition lifecycle are unchanged.

## Still unverified

Another Mac, a clean Mac without previous HP components, Finder copy by an external
tester, rollback, cancellation, sleep/reboot/reconnect recovery, direct NAPS2
scanning, physical cancellation/partial-output recovery, held/double button presses,
and button operation after sleep or unplug/reconnect. The HP Utility Scan Button panel exists
for the scanner on the test Mac, but returned Image Capture error 4294967249 when
opened with Image Capture also running. The cause has not been established.
