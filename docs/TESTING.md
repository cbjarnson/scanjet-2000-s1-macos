# Release validation

Version 0.4.1, 2026-09-22. Experimental source-only release.

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

## Background processing in v0.4.0

- Native arm64 build and the existing encoding checks passed.
- A synthetic four-page batch went through the actual installed OCRmyPDF 17.4.2
  and unpaper 7.0.0. A blank side was removed; text, faint writing, and a small
  colored mark were retained. The resulting three-page PDF had searchable text.
- A skewed synthetic page was rendered after processing and appeared straight.
  Default unpaper blur/mask filters initially produced white patches on tinted
  paper. The cleanup arguments were narrowed to noise filtering, and a regression
  check now rejects the observed patch artifact.
- A second, separate job was enqueued while the first was processing. JPEG output,
  all-blank retention, deskew/rotation without OCR, exclusive worker locking,
  recovery after publication but before completion, and refusing to overwrite an
  existing document passed. Failures retained raw input.
- A separate 16-page synthetic job ran through the live app's background queue.
  The UI continued to report the scanner ready and kept Scan new document enabled
  while the OCRmyPDF and unpaper processes were running. It completed with 16 pages.
- Blank removal, deskew, cleanup, and OCR selections persisted through restarting
  the idle menu app; PDF/Balanced, duplex, and the selected destination also persisted.
- The user reported a feeder error and blinking red light during the old v0.3.0
  session. That scan received zero pages and hung waiting for session close. It
  was cancelled and the stalled process stopped; the user subsequently reported
  the scanner working again. A two-minute no-page timeout, bounded session close,
  and direct error handling were added. These timeout/recovery changes are built
  but have not yet been exercised in a physical jam test.
- At the v0.4.0 release, the pipeline tests used synthetic files. Physical capture
  with the new queue and the next physical scan during OCR were still unverified.

## Jam recovery in v0.4.1

- Native arm64 compilation, the existing output checks, and a focused check of
  the driver process path/owner restrictions passed.
- After the user reported another jam and a persistent blinking light despite
  cycling power and USB, the new recovery worker requested a standard macOS USB
  re-enumeration of the single connected 03f0:5905. It then opened an ICA session,
  received readiness, and closed the session normally. It exited successfully,
  reporting both USB reconnect and readiness success. No paper was fed.
- The user then reported **light is off**. This is one observed recovery on the
  original Mac, not proof that software clears every physical or latched fault.
- The project-local app's Recover after jam control was then clicked. Scan and
  front-button controls were disabled during recovery; the app logged Connection
  ready after about 12 seconds. PDF/Balanced, duplex, destination, and processing
  preferences remained intact. Front-button listening was restored through the UI.
- Two subsequent physical acquisitions, with two and four sides respectively,
  completed through the background queue. All 70 earlier completed queue records
  kept the same hashes. This checks queue preservation, not every output image.
- Acquisition errors now pause scanning and offer recovery instead of repeatedly
  blaming other apps. The paused state persists across restarts. Recovery runs
  separately from the background processing queue and never starts a scan.
- Format and size dropdowns were narrowed to fit the controls window.

## Still unverified

Another Mac, a clean Mac without previous HP components, Finder copy by an external
tester, rollback, cancellation, sleep/reboot recovery, direct NAPS2
scanning, physical cancellation/partial-output recovery, held/double button presses,
and button operation after sleep or physical unplug/reconnect. Recovery during an
active jammed acquisition, forced worker termination, and repeated jam recovery
remain unverified. The HP Utility Scan Button panel exists
for the scanner on the test Mac, but returned Image Capture error 4294967249 when
opened with Image Capture also running. The cause has not been established.
