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

The button workflow is separate from scanning initiated in Image Capture. [HP documents assigning it through HP Utility](https://support.hp.com/gb-en/document/c05294082). Front-button operation is not verified by this release. HP Utility exposes a Scan Button panel for this model on the test Mac, but opening it returned Image Capture error 4294967249 while Image Capture was also running. Its cause has not been established. Do not assume the single-driver addition installs or repairs HP's background button handler.
