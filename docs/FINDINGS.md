# Reproducible findings

Recorded 2026-09-21. One HP ScanJet Pro 2000 s1, USB `03f0:5905`, Apple Silicon, macOS 27.0 build 26A428. No claim of HP support for this OS is implied.

## Package comparison

| Official HP package | Inspected Scanner 4 | Exact 2000 s1 backend |
| --- | --- | --- |
| ScanJet Essentials 5.15.5.7 | 5.2.2 (57), Intel x86_64 | `hpgt2000.bundle` present |
| ScanJet Essentials 5.20.0.1 | 5.3.1, universal | Model registration retained; `hpgt2000.bundle` absent |

The older complete app passes `codesign --verify --deep --strict` and Gatekeeper assessment as Notarized Developer ID, HP Inc. (`6HB5Y2QTA3`). All 26 inspected Mach-O components in that app are x86_64. An ARM64 loader rejects the Intel model backend; an x86_64 helper loads it through Rosetta.

Registration is in `Contents/Resources/DeviceMatchingInfo.plist`. `DeviceInfo.plist` maps the model through `HPSJTULIPScan.bundle`; its `TulipMapping.plist` selects the nested `hpgt2000.bundle`. Merely adding a USB ID to a different module does not implement the protocol.

The backend identifies as `com.foxlinkimage.hpgt2000`, version 0.34.16.526. Its executable SHA-256 is `8a55ec224c3d4b3ba7316f61ec1d4d0cf1fc4ddbdafa9789aaaea83cf2697bd9`.

## Sources and hashes

- [Original 5.15.5.7 package at HP](https://ftp.hp.com/pub/softlib/software12/HP_Quick_Start/osx/Installations/Essentials/Pinnacles_Canopus/hp-printer-essentials-SJ-5_15_5_7.pkg)
  - SHA-256: `92c986eaae53ab8e65a362e2c997f91a4903f91a398ea2db08b80a113cb78dac`
- [Inspected newer 5.20.0.1 package at HP](https://ftp.hp.com/pub/softlib/software12/HP_Quick_Start/osx/Installations/Essentials/macOS26/hp-printer-essentials-SJ-5_20_0_1.pkg)
  - SHA-256: `c130c1c7395bba977faab3f4dbaeacc47bf41d305c53f5eb948edb8ecf0a5525`
- [HP model support page](https://support.hp.com/us-en/drivers/hp-scanjet-pro-2000-s1-sheet-feed-scanner/10430932)
- [HP Easy Admin documentation](https://support.hp.com/us-en/document/c06164609)
- [Apple's current Rosetta availability](https://support.apple.com/en-us/102527)

Use the helper for checksum and signature checks. Never substitute a different download merely because its filename matches. If HP removes the package, this project has no bundled fallback or mirror.

## Observed installation and acquisition

Only the previously absent `/Library/Image Capture/Devices/HP Scanner 4.app` was added, after backup and user approval. The original tested addition was assigned root:wheel ownership and verified. No package installer scripts ran. All 10,811 original inventoried file/link entries remained unchanged, and 274 added entries matched the staged app.

USB reconnection alone did not refresh discovery. Restarting the current user's `icdd` allowed the scanner to match `com.hp.scanModule4`. A native ImageCaptureCore client opened and closed a session successfully. The HP driver process was confirmed **X86-64 (translated)**.

Image Capture then produced four simplex pages and eight duplex pages. Settings: 300 dpi, color, US Letter, PDF, combine into one document, OCR off, image correction None, automatic page length off. All rendered pages were readable; both sides were upright in the duplex result. Logs confirmed duplex enabled and successful scan completion (error 0). Scanned documents and raw logs are intentionally not published.

The single test Mac already had other HP software. Clean-Mac independence, cancellation, reconnect recovery after scanning, rollback and reboot persistence need separate testing. This project provides no native ARM64 backend. Future durable support would require a native backend or a separately developed compatible implementation.
