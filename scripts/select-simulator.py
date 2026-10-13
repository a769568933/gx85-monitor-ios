"""Select an available iPhone from the installed Xcode runtime, and boot it."""
import json
import os
import subprocess

listing = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))
candidates = [(runtime, device) for runtime, devices in listing['devices'].items() if '.iOS-' in runtime for device in devices if device.get('isAvailable') and device['name'].startswith('iPhone')]
if not candidates:
    raise SystemExit('No available iPhone simulator runtime in this Xcode image.')

def runtime_version(candidate):
    return tuple(int(part) for part in candidate[0].split('.iOS-')[-1].split('-'))

runtime, device = max(candidates, key=runtime_version)
udid = device['udid']
if device['state'] != 'Booted': subprocess.run(['xcrun', 'simctl', 'boot', udid], check=True)
subprocess.run(['xcrun', 'simctl', 'bootstatus', udid, '-b'], check=True)
with open(os.environ['GITHUB_ENV'], 'a', encoding='utf-8') as env:
    env.write(f'SIMULATOR_UDID={udid}\n')
print(f"Using {device['name']} ({runtime}): {udid}")
