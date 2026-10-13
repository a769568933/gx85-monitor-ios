"""Static integrity checks; not a substitute for Xcode build or XCTest."""
from pathlib import Path
import json
import plistlib
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / '.tools/python'))
from tree_sitter import Language, Parser
import tree_sitter_swift
from openstep_parser import OpenStepDecoder

parser = Parser(Language(tree_sitter_swift.language()))
files = list((ROOT / 'GX85Core').rglob('*.swift')) + list((ROOT / 'GX85Monitor').rglob('*.swift')) + list((ROOT / 'GX85MonitorTests').rglob('*.swift'))
errors = []
for path in files:
    data = path.read_bytes()
    stack = [parser.parse(data).root_node]
    while stack:
        node = stack.pop()
        if node.type == 'ERROR' or node.is_missing:
            errors.append(f'{path.relative_to(ROOT)}:{node.start_point.row+1}:{node.start_point.column+1}: {node.type}: {data[node.start_byte:node.end_byte].decode()[:150]}')
        stack.extend(reversed(node.children))
print(f'Swift grammar: {len(files)} files, {len(errors)} diagnostics')
for error in errors: print(error)

with (ROOT / 'GX85Monitor.xcodeproj/project.pbxproj').open(encoding='utf-8') as stream:
    project = OpenStepDecoder.ParseFromFile(stream)
objects = project['objects']
refs = [obj for obj in objects.values() if obj['isa'] == 'PBXFileReference' and obj.get('sourceTree') == '<group>']
for ref in refs:
    if not (ROOT / ref['path']).exists(): errors.append('Missing project file: ' + ref['path'])
sources = {obj['path'] for obj in refs if obj.get('lastKnownFileType') == 'sourcecode.swift'}
expected = {p.relative_to(ROOT).as_posix() for p in files if 'GX85Core' not in p.parts}
if sources != expected: errors.append(f'Source membership mismatch: {sources ^ expected}')

with (ROOT / 'GX85Monitor/Info.plist').open('rb') as stream: info = plistlib.load(stream)
assert info['NSLocalNetworkUsageDescription']
assert set(info['UISupportedInterfaceOrientations']) == {'UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'}
for path in (ROOT / 'GX85Monitor/Assets.xcassets').rglob('Contents.json'): json.loads(path.read_text(encoding='utf-8'))
for path in (ROOT / 'GX85Monitor.xcodeproj').rglob('*.xcscheme'):
    scheme = ET.parse(path)
    for reference in scheme.iter('BuildableReference'):
        if reference.attrib['BlueprintIdentifier'] not in objects: errors.append('Scheme target is missing')
print(f'Project references: {len(refs)}; plist, assets and shared scheme parsed')
if (ROOT / '.github/workflows/ios-build.yml').exists():
    import yaml
    with (ROOT / '.github/workflows/ios-build.yml').open(encoding='utf-8') as stream: workflow = yaml.safe_load(stream)
    assert 'jobs' in workflow
    print('Workflow YAML parsed')
if errors:
    print('\n'.join(errors))
    sys.exit(1)
print('Static integrity checks passed. Swift type checking, XCTest and device validation have NOT run here.')
