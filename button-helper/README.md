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
Optional background processing is described below. Another app is not opened
automatically.
Close Image Capture or other scanner apps before using this helper.

## Background processing

The scanner only captures the pages. Once it releases the scanner, the controls
say **ready for the next scan** even if PDF/JPEG creation or OCR is still running.
A separate status line reports batches processing or waiting. Only one background
batch runs at a time, at reduced priority, using one OCR worker. No cloud API or
upload is used by the helper.

Each batch remembers the format, quality, destination, and processing choices that
were selected when it started. Changing a setting affects the next batch. All
processing options start off and are remembered when explicitly selected:

- **Remove blank pages**: works for PDF and JPEG. A conservative full-page check
  keeps pages with faint writing, colored marks, or dark borders. It may keep
  noisy blank pages. If the entire batch looks blank, it keeps every page for review.
- **Straighten pages (deskew)**: corrects slight skew in PDFs.
- **Clean specks and noise**: gentle unpaper noise filtering in PDFs. Masking,
  border removal, blur filtering, gray filtering, and black filtering are disabled
  to protect content and avoid white patches on tinted paper.
- **Auto-rotate PDF pages**: attempts to orient text correctly. Sparse text and
  image-only pages may not provide enough evidence for automatic rotation.
- **Searchable PDF (OCR)**: adds selectable/searchable English text locally.

PDF-only options are disabled while JPEG is selected; their preferences are kept
for when you return to PDF. Blank detection itself needs no external dependency.
Deskew, cleanup, rotation, and OCR use [OCRmyPDF](https://github.com/ocrmypdf/OCRmyPDF),
[Tesseract](https://github.com/tesseract-ocr/tesseract), and
[unpaper](https://github.com/unpaper/unpaper). These are separately installed tools,
not copied into this repository. Tested with OCRmyPDF 17.4.2 and unpaper 7.0.0.
With Homebrew already installed, the optional dependencies can be installed with:

```sh
brew install ocrmypdf unpaper
```

The helper checks the usual Homebrew and MacPorts executable locations. Use
OCRmyPDF 17.4 or newer. OCRmyPDF's [processing documentation](https://ocrmypdf.readthedocs.io/en/latest/cookbook.html#image-processing)
explains the underlying tools. Final size and OCR accuracy depend on the pages;
review cleaned output, especially faint handwriting and colored marks.

## Originals, failures, and recovery

When any processing option is active, an **unprocessed copy of every side** is
saved in **Original scans** inside the selected save folder before filtering.
It uses the selected PDF/JPEG format and compression quality. It is not an archival
lossless TIFF backup. **Original scans** opens that folder. The finished document
is saved alongside the other scans, in the selected destination. This keeps both
versions and uses additional disk space. Existing scan documents are never edited.

Failed or cancelled acquisitions keep the received pages in a batch marked
**INCOMPLETE**. Processing failures retain raw TIFFs in `.scanjet-work` under the
batch's original destination, along with `processing.log` if an external tool ran.
Finder's Command-Shift-period shows hidden folders. **Retry processing** retries
failed jobs; it does not rescan paper. Fix a missing dependency or unavailable save
folder first. Completed documents are published atomically without overwriting an
existing file. Original raw pages are removed only after successful publication
and a saved completion record; interrupted acquisition keeps them.

Queue records live in `~/Library/Application Support/ScanJet Button/Queue`.
An interrupted processing job resumes when the helper is reopened. A running
background worker can finish after closing the app; remaining queued jobs wait
until it is reopened. Leave the helper running to drain the entire queue. No
login item or system service is installed.

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
names, rejecting duplicate publication, and empty or unreadable input. The separate
`tests/processing.py` integration suite runs synthetic documents through the actual
OCRmyPDF/unpaper pipeline and checks blank removal, retained faint/color marks,
OCR text, JPEG output, all-blank retention, publication recovery, and overwrite
refusal. It requires Pillow, pikepdf, pypdfium2, and pdftotext. These checks do not
prove physical scanning, USB reconnection, or paper-jam recovery.
The separate physical and preference-persistence checks for each release are recorded
in [release validation](../docs/TESTING.md).
