"""Export actual XCTest attachments on macOS into the existing validation artifact.

The existing workflow uploads dist/*.log. A JSON/base64 envelope preserves the
original image bytes without requiring additional GitHub workflow permissions.
See Apple's Xcode 16.3 xcresulttool release notes for the export subcommand.
"""
from pathlib import Path
import base64
import json
import os
import subprocess

root = Path(__file__).resolve().parents[1]
bundle = root / 'dist/iPhoneTests.xcresult'
if not bundle.is_dir():
    print('No XCTest result bundle: standalone device build has no screenshot evidence.')
    raise SystemExit(0)
output = root / 'dist/TestAttachments'
subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(bundle), '--output-path', str(output)], check=True)
images, manifests = [], []
for path in sorted(output.rglob('*')):
    if path.suffix.lower() in {'.png', '.jpg', '.jpeg'}:
        images.append({'file': str(path.relative_to(output)), 'data': base64.b64encode(path.read_bytes()).decode('ascii')})
    elif path.suffix == '.json':
        manifests.append({'file': str(path.relative_to(output)), 'manifest': json.loads(path.read_text())})
if not images:
    raise SystemExit('No actual test images were exported.')
payload = {'commit': os.environ.get('GITHUB_SHA'), 'run': os.environ.get('GITHUB_RUN_ID'),
           'notice': 'Simulator fixtures, not a GX85 connection or device certification.',
           'manifests': manifests, 'images': images}
(root / 'dist/test-screenshots.log').write_text(json.dumps(payload), encoding='utf-8')
print(f'Preserved {len(images)} original XCTest image attachments in validation artifact.')
