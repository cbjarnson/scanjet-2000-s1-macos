# ScanJet Button — local experimental helper

A native Apple Silicon menu-bar app for the HP ScanJet Pro 2000 s1 (`03f0:5905`).
The installed HP Scanner 4 driver still performs scanning through Rosetta.

Build with `zsh build.zsh`, then open `../build/ScanJet Button.app`.
This builds locally with an ad-hoc signature. It is not notarized or installed
as a login item. No HP components, system security settings, or `/Library` files
are changed. Keep the app running for front-button scanning; quit it to stop.

The **ScanJet** menu in the menu bar offers:

- **Scan a new document**: starts one batch without using Image Capture.
- **Use front Scan button**: enables or pauses the hardware trigger.
- **Scan both sides**: duplex on by default; turn it off for simplex.
- **Choose save folder…**: defaults to `~/Documents/Scans` and remembers changes.
- **Save as**: PDF by default, or JPEG when you explicitly choose it. The choice
  stays selected for future scans and after restarting until you change it.
- **File size**: Smallest, Balanced (default), or Higher quality. This choice is
  also remembered. All three retain 300 dpi; they vary JPEG compression.
- **Open save folder** and **Show latest scan**.

Each PDF batch becomes one uniquely named document. JPEG mode creates a new
folder per batch with `Page 0001.jpg`, `Page 0002.jpg`, and so on, in scanner order
(one image per scanned side). The next press starts a new batch. Color, 300 dpi,
US Letter. Settings affect future scans only; existing files stay untouched.

PDFs embed the compressed JPEG images, so they are substantially smaller than
the lossless PDFs from v0.2.0. Actual size varies with the paper. Choose Higher
quality when small details matter more than file size.
No OCR, cleanup, blank-page deletion, or automatic opening of another app.
Close Image Capture or other scanner apps before using this helper.

On a failed or cancelled scan, received pages are saved with `INCOMPLETE` in
the PDF filename or JPEG folder name. Original page files remain in `.scanjet-work`
under the save folder if a scan or output conversion fails. That folder is hidden in Finder;
Command-Shift-period shows hidden files. Successful batches remove only their
own temporary page files after validating and saving the output.

## Implementation evidence

The generic interrupt report `08` is not sufficient to start a scan. HP's
`GetButtonInput` calls `FSIReadSensorButtonStatus` with selector zero. Its
`USBRW` implementation sends:

1. Bulk OUT endpoint `02`: `82 28 1f 00 04 00 00 00`.
2. Bulk OUT endpoint `02`: `00 00 00 00` (button-status selector).
3. Bulk IN endpoint `81`: 16-byte status (`28 00 00 00 04 00 00 00 …`).
4. Bulk IN endpoint `81`: four bytes; observed `01 00 00 00` for Scan and
   `00 00 00 00` on the following read.

Only that status query is reproduced. Normal USB opens, no seizure, bounded
timeouts, and handles released before any ImageCaptureCore acquisition.
The app requires an idle reading before accepting a press after launch,
reconnection, pause, or completion. It does not poll USB while scanning. Each
batch uses a separate scan process because restarting discovery in the same
process failed on the tested macOS 27 build. The menu-bar app stays open.

Button press and clear were physically verified on the development Mac.
The helper produced an eight-page duplex PDF. The final implementation then
produced two separate two-page duplex PDFs in succession, the second started
by a user-confirmed front-button press while the menu-bar app stayed running.
The prior PDFs remained byte-for-byte unchanged. The folder chooser was used
to change the destination, and that choice survived restarting the helper.
Page order and orientation follow the loaded paper. The final front-button
test was upside down on both sides; no automatic rotation was applied.
Those v0.2.0 scans retained lossless images. Starting with v0.3.0, both formats
use adjustable JPEG compression, with Balanced as the default. The build's
offline tests check compression levels, JPEG dimensions and numbered output,
PDF page count and compressed JPEG embedding, separate batches, partial-output
names, rejecting duplicate publication, and empty or unreadable input. Those checks do not prove hardware
scanning, restart behavior, reconnection, or paper-jam recovery.
The separate physical and preference-persistence checks for v0.3.0 are recorded
in [release validation](../docs/TESTING.md).
