# HP ScanJet Pro 2000 s1 on macOS 27

An experimental recovery guide, source-only preparation helper, and optional front-button scanning app for the **HP ScanJet Pro 2000 s1**, USB **03f0:5905**, on Apple Silicon.

**Physically tested on one Mac running macOS 27.0 (26A428):** Image Capture saved a four-page simplex PDF and an eight-page duplex PDF at 300 dpi in color. Every output page was visually checked. The original HP driver runs through **Rosetta**, not natively on ARM64.

This is an independent community project, not an HP release. It contains no HP driver binaries, no scanned documents, and no installer that changes your Mac automatically.

## What was missing

On the tested Mac, HP Scanner 3 (4.28.1) and HPScanner (1.12.1) did not register this scanner. The official older **HP ScanJet Essentials 5.15.5.7** package contains an intact, signed **HP Scanner 4.app 5.2.2 (57)** with the required `hpgt2000.bundle` backend.

The inspected newer 5.20.0.1 package retained this model's registration but omitted that backend. Adding the complete original older app, without replacing any installed HP components, restored scanning after discovery was refreshed. [Technical findings](docs/FINDINGS.md).

## Before you start

- Only this model and the exact Mac/OS configuration above have physical test evidence. A second Mac without existing HP software has not been tested.
- The preparation helper deliberately stops outside macOS 27 on Apple Silicon. Other macOS versions and other scanner models are not covered by this release.
- Rosetta must already work. Follow [Apple's instructions](https://support.apple.com/en-us/102527) if it is absent. The helper does not install Rosetta or accept license terms for you.
- **Do not expect this workaround to survive macOS 28.** Apple states that general Rosetta availability ends with macOS 27, with macOS 28 retaining only limited support for certain older games. [Apple source](https://support.apple.com/en-us/102527).
- HP software has its own terms. Read [THIRD-PARTY.md](THIRD-PARTY.md). This project grants no license to HP software.

## Use it

Download and unzip the source release from [Releases](https://github.com/cbjarnson/scanjet-2000-s1-macos/releases). Open Terminal in the extracted folder. Read the small helper before running it; do not pipe a web download into a shell.

```sh
/bin/zsh scanjet-recovery.zsh check
/bin/zsh scanjet-recovery.zsh prepare
```

`prepare` downloads the approximately 306 MiB original package from HP over HTTPS, checks its pinned SHA-256 and installer signature, extracts only the Scanner 4 payload without running package scripts, and checks the driver against the recorded content manifest, HP identity, and Gatekeeper. It prints a private temporary folder containing the prepared app. Files stay local; there is no telemetry.

Alternatively, use the exact original package you already downloaded from HP:

```sh
/bin/zsh scanjet-recovery.zsh prepare --package '/path/to/hp-printer-essentials-SJ-5_15_5_7.pkg'
```

**Nothing is installed by these commands.** Continue with the [manual installation and rollback guide](docs/INSTALL.md). The only proposed system addition is `/Library/Image Capture/Devices/HP Scanner 4.app`. An existing app at that path must never be overwritten as part of this procedure.

## Optional front-button scanning

The [ScanJet Button helper](button-helper/README.md) adds a native Apple Silicon
menu-bar app. Each front-button press creates a fresh PDF by default, with duplex
on and a remembered save folder. You can explicitly select JPEG images instead;
the format stays selected until you change it, including across app restarts.
Smallest, Balanced (default), and Higher quality file-size settings retain 300 dpi.
PDFs now embed compressed images. Existing scans are never recompressed. Close Image Capture and other scanner apps
when using it. No OCR or cleanup is applied.

Build from source with Apple's Command Line Tools or Xcode installed:

```sh
/bin/zsh button-helper/build.zsh
open 'build/ScanJet Button.app'
```

Keep the helper running for button scans. It has a local ad-hoc signature, is
not notarized, and does not register itself as a login item. The HP acquisition
backend still requires Rosetta. The helper's button detection and repeated
duplex PDF creation have been physically tested on the same Mac only.

## Results and limits

| Check | Result on the original test Mac |
| --- | --- |
| USB detection and Image Capture discovery | Passed |
| Open/read capabilities/close session | Passed |
| Color, 300 dpi, US Letter, simplex PDF | Passed; four pages |
| Color, 300 dpi, US Letter, duplex PDF | Passed; eight pages, both sides upright |
| Original HP signature and Gatekeeper | Passed; HP Inc. 6HB5Y2QTA3 |
| Existing HP files after addition | 10,811 original file/link entries unchanged |
| Front button via optional helper | Passed; a fresh two-page duplex PDF after an earlier batch, without restarting the helper |
| Save-folder choice and separate PDFs | Passed; earlier PDF hashes unchanged |
| Reboot, physical cancel, USB reconnect recovery | Not tested |
| Fresh Mac without earlier HP software | Not tested |
| Native ARM64 backend / macOS 28 | Not provided |

The duplex test retained the fed sheet order; the sheet pairs were in reverse document order. Slight skew and page edges were visible. No output was edited. This is evidence of working acquisition, not a complete scanner certification.

## Help improve the evidence

For destination folders, one PDF per document, and later OCR/cleanup, see the [everyday scanning workflow](docs/SCANNING.md).

[Report your result](https://github.com/cbjarnson/scanjet-2000-s1-macos/issues/new/choose) with the model, Mac chip, macOS version/build, prior HP software, and which scan modes worked. Do not attach private scans, USB serial numbers, full system logs, credentials, or personal paths. Reports from clean Macs are especially useful.

Original helper code and documentation: [MIT license](LICENSE). HP/Foxlink software remains the property of its respective owners and is downloaded separately.
