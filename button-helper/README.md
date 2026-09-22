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
- **Open save folder** and **Show latest PDF**.

Every batch gets a separate, uniquely named PDF. Pages within that batch are
combined, and the next press creates a new document. Color, 300 dpi, US Letter.
No OCR, cleanup, blank-page deletion, or automatic opening of another app.
Close Image Capture or other scanner apps before using this helper.

On a failed or cancelled scan, received pages are saved with `INCOMPLETE` in
the filename. Original page files remain in `.scanjet-work` under the save
folder if a scan or PDF conversion fails. That folder is hidden in Finder;
Command-Shift-period shows hidden files. Successful batches remove only their
own temporary page files after validating the PDF data and saving the PDF.

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
Scans retain lossless image data; files can be large (about 23 MB for the
tested two-page document). Apply compression in later processing if needed. The build's
offline test checks that two batches stay separate, a partial output is
marked, and an empty batch creates no PDF. Those checks do not prove hardware
scanning, restart behavior, reconnection, or paper-jam recovery.
