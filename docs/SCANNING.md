# Everyday scanning workflow

In Image Capture, select the scanner and click **Show Details** if needed.

1. **Scan To → Other…** chooses your destination folder. A dedicated local `Scans` folder is convenient.
2. Set **Format: PDF** and leave **Combine into single document** checked to keep a document's pages together.
3. Before each new document, enter a **new, unused Name**, for example `2026-09-21-invoice-001`. Keep the same name only when intentionally adding pages to the same PDF. Changing the output name produced separate PDFs in our physical tests, without quitting Image Capture.
4. Enable **Duplex** when both sides matter, and check page order after scanning. The feeder's loading order determines document order.
5. Save the original scan before doing cleanup or OCR.

Suggested processing workflow: scan to PDF in Image Capture, then import that PDF into an OCR/cleanup app. [NAPS2](https://www.naps2.com/) is a free, open-source option for Mac with page rotation and deskew tools. Its [OCR documentation](https://www.naps2.com/doc/ocr) describes making imported PDFs searchable; on Mac, use **Tools → OCR**, download the appropriate language, enable searchable PDFs, and save a new PDF. This postprocessing workflow has not been tested as part of this driver recovery project. Direct scanning from NAPS2 with this specific driver is also untested.

Apple's general guide: [Scan images or documents](https://support.apple.com/guide/mac-help/mh28032/mac).

## Front-panel scan button

Use the optional [ScanJet Button helper](../button-helper/README.md) for one
fresh batch per press. **Save as** defaults to PDF (all pages combined); choose
JPEG explicitly for a numbered image per side in a new batch folder. This format
stays selected until you change it. **File size** offers Smallest, Balanced
(default), and Higher quality, all at 300 dpi. Format and size choices survive
restarting the helper and affect both the front button and the on-screen scan
button. Existing files are left untouched.

Its **Choose save folder…** control remembers the destination;
**Scan both sides** controls duplex. The default save folder is Documents/Scans.
The helper can stay in the menu bar with its window closed. It must remain running,
and Image Capture or other scanner apps must release the scanner first.

The front button was physically verified with this helper, including a second
document without restarting the app. It leaves HP's built-in button configuration
unchanged. [HP also documents assigning buttons through HP Utility](https://support.hp.com/gb-en/document/c05294082),
but that panel returned error 4294967249 during testing. The community helper is
an independent alternative; it does not repair HP Utility's button workflow.
