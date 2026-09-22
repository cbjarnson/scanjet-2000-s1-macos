#!/usr/bin/env python3
"""Synthetic integration checks. Requires Pillow, pikepdf and pdftotext.
Run using OCRmyPDF's Python environment or a separate test virtualenv.
No scanner, user scans, preferences, or production queue are touched.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import tempfile
import uuid
from PIL import Image, ImageDraw, ImageFont
import pikepdf
import pypdfium2 as pdfium

app = Path(sys.argv[1]).resolve()
root = Path(tempfile.mkdtemp(prefix='scanjet-processing-test-'))
queue = root / 'queue'
queue.mkdir()
env = dict(os.environ, SCANJET_QUEUE_DIRECTORY=str(queue))
font = ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf', 42)
source = root / 'fixtures'
source.mkdir()
white = Image.new('RGB', (2550, 3300), (250, 250, 250))
white.save(source / 'blank.tiff', compression='tiff_lzw', dpi=(300, 300))
text = white.copy()
draw = ImageDraw.Draw(text)
for i in range(12):
    draw.text((180, 250 + i * 130), 'SCANJET BACKGROUND QUEUE TEST document number 12345', font=font, fill=(15, 15, 15))
text = text.rotate(3, resample=Image.Resampling.BICUBIC, fillcolor=(250, 250, 250))
text.save(source / 'text.tiff', compression='tiff_lzw', dpi=(300, 300))
faint = white.copy()
ImageDraw.Draw(faint).text((200, 500), 'Faint handwriting must remain', font=font, fill=(225, 225, 225))
faint.save(source / 'faint.tiff', compression='tiff_lzw', dpi=(300, 300))
mark = white.copy()
ImageDraw.Draw(mark).line([(200, 900), (250, 870), (350, 960), (400, 880)], fill=(50, 130, 225), width=4)
mark.save(source / 'mark.tiff', compression='tiff_lzw', dpi=(300, 300))

counter = 0
def job(names, **options):
    global counter
    counter += 1
    raw = root / 'output' / '.scanjet-work' / str(uuid.uuid4())
    raw.mkdir(parents=True)
    pages = []
    for i, name in enumerate(names):
        page = raw / f'page-{i}.tiff'
        page.write_bytes((source / name).read_bytes())
        pages.append(str(page))
    settings = dict(format='pdf', quality='balanced', blank=False, deskew=False, clean=False, ocr=False, rotate=False)
    settings.update(options)
    record = dict(version=1, id=str(counter), created=counter, name=f'Test batch {counter}', state='queued', job=str(raw), folder=str(root / 'output'), pages=pages, settings=settings, scanError='')
    manifest = queue / f'{counter}.json'
    manifest.write_text(json.dumps(record))
    return manifest, record

def run(manifest, expected=0):
    result = subprocess.run([str(app), '--process-job', str(manifest)], env=env, capture_output=True, timeout=300)
    record = json.loads(manifest.read_text())
    assert result.returncode == expected, (result.returncode, record, result.stderr.decode())
    return record

def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

# Full actual OCRmyPDF + unpaper pipeline, with three nonblank pages retained.
a, original = job(['text.tiff', 'blank.tiff', 'faint.tiff', 'mark.tiff'], blank=True, deskew=True, clean=True, ocr=True)
proc = subprocess.Popen([str(app), '--process-job', str(a)], env=env)
deadline = time.monotonic() + 30
while json.loads(a.read_text())['state'] != 'processing':
    assert proc.poll() is None and time.monotonic() < deadline
    time.sleep(0.05)
# Enqueue the next batch while the first is processing; it must remain separate.
b, second = job(['text.tiff'], format='jpeg')
proc.wait(timeout=300)
result = json.loads(a.read_text())
assert proc.returncode == 0, result
assert result['removedPages'] == [2] and result['outputPages'] == 3, result
assert len(pikepdf.open(result['output']).pages) == 3
assert len(pikepdf.open(result['original']).pages) == 4
recognized = subprocess.check_output(['pdftotext', result['output'], '-']).decode()
assert 'BACKGROUND QUEUE TEST' in recognized, recognized[:500]
# Cleanup must not paint large white rectangles over our lightly tinted paper.
rendered = pdfium.PdfDocument(result['output'])[1].render(scale=1).to_pil().convert('L')
assert rendered.histogram()[255] / (rendered.width * rendered.height) < 0.05
assert json.loads(b.read_text())['state'] == 'queued'
before = digest(result['output'])
second_result = run(b)
assert len(list(Path(second_result['output']).glob('*.jpg'))) == 1
assert digest(result['output']) == before

# Recover a crash after atomic publication but before completion was recorded.
result['state'] = 'processing'
result.pop('output')
a.write_text(json.dumps(result))
recovered = run(a)
assert recovered['state'] == 'done' and digest(recovered['output']) == before
assert len(list((root / 'output').glob('Test batch 1.pdf'))) == 1

# Blank-only batches stay visible for review; never publish zero pages.
c, _ = job(['blank.tiff', 'blank.tiff'], blank=True)
all_blank = run(c)
assert all_blank['outputPages'] == 2 and all_blank['removedPages'] == [] and all_blank['notice']

# JPEG removes blank sides but retains faint marks, preserving the requested format.
d, _ = job(['blank.tiff', 'faint.tiff', 'mark.tiff'], format='jpeg', blank=True)
jpeg = run(d)
assert jpeg['removedPages'] == [1] and jpeg['outputPages'] == 2
assert sorted(p.name for p in Path(jpeg['output']).iterdir()) == ['Page 0001.jpg', 'Page 0002.jpg']

# Never overwrite a destination, and retain raw input after failure.
e, item = job(['text.tiff'])
conflict = root / 'output' / (item['name'] + '.pdf')
conflict.write_bytes(b'existing user document')
failed = run(e, 1)
assert failed['state'] == 'failed' and Path(item['job']).is_dir()
assert conflict.read_bytes() == b'existing user document'

# Deskew and rotation can also run without adding an OCR layer.
f, _ = job(['text.tiff'], deskew=True, rotate=True)
no_ocr = run(f)
assert len(pikepdf.open(no_ocr['output']).pages) == 1
assert not subprocess.check_output(['pdftotext', no_ocr['output'], '-']).strip()

# Reject a manifest outside the queue without editing that file.
outside = root / 'not-a-queue-record.json'
outside.write_text(json.dumps(item))
before_outside = outside.read_bytes()
run(outside, 2)
assert outside.read_bytes() == before_outside

# Partial acquisitions retain raw pages even after processed output is saved.
g, partial_record = job(['text.tiff'])
partial_record['scanError'] = 'Synthetic interrupted acquisition'
partial_record['name'] += ' INCOMPLETE'
g.write_text(json.dumps(partial_record))
partial = run(g)
assert 'INCOMPLETE' in Path(partial['output']).name and Path(partial['job']).is_dir()

# A second worker cannot take the processing lock while another owns it.
with (queue / '.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    run(e, 75)

report = dict(result='PASS', original_pages=4, final_pages=3, removed_pages=[2], faint_and_colored_marks_retained=True, actual_ocr_text_verified=True, separate_queued_batch=True, jpeg_output=True, all_blank_retained=True, crash_recovery=True, overwrite_refused=True, lock_exclusion=True, output_bytes=Path(recovered['output']).stat().st_size, artifacts=str(root))
print(json.dumps(report, indent=2))
