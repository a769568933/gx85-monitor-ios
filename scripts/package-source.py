"""Package source including hidden workflow, excluding tools, git, builds and credentials."""
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED
import hashlib

root = Path(__file__).resolve().parents[1]
destination = root / 'dist/GX85Monitor-source.zip'
destination.parent.mkdir(exist_ok=True)
excluded = {'.git', '.tools', '.superpowers', '.build', 'dist', 'build', 'DerivedData', '__pycache__', 'xcuserdata'}
files = [p for p in root.rglob('*') if p.is_file() and not (set(p.relative_to(root).parts) & excluded) and not p.name.endswith(('.ipa', '.zip', '.pyc'))]
with ZipFile(destination, 'w', compression=ZIP_DEFLATED) as archive:
    for path in sorted(files): archive.write(path, path.relative_to(root).as_posix())
with ZipFile(destination) as archive:
    assert archive.testzip() is None
    for required in ['.github/workflows/ios-build.yml', 'GX85Core/Package.swift', 'GX85Monitor.xcodeproj/project.pbxproj', 'GX85Monitor.xcodeproj/xcshareddata/xcschemes/GX85Monitor.xcscheme', 'GX85Monitor/Info.plist']:
        assert required in archive.namelist(), required
print(f'{destination}: {len(files)} files, {destination.stat().st_size} bytes')
print('SHA256:', hashlib.sha256(destination.read_bytes()).hexdigest())
