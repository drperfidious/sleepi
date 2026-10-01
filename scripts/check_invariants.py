#!/usr/bin/env python3
"""Static architectural checks; these do not certify overnight device behavior."""
from pathlib import Path
import json
import plistlib
import re
import subprocess

root = Path(__file__).resolve().parent.parent
files = list((root / 'Apps').rglob('*.swift')) + list((root / 'Sources').rglob('*.swift'))
for path in files:
    source = path.read_text()
    for forbidden in [r'\bHKWorkoutSession\b', r'\bHKLiveWorkoutBuilder\b', r'\.activeEnergyBurned\b',
                      r'\.basalEnergyBurned\b', r'\bimport CloudKit\b', r'\bURLSession\b',
                      r'\bNSUbiquitousKeyValueStore\b', r'\bimport AlarmKit\b']:
        assert not re.search(forbidden, source), f'{path}: prohibited API {forbidden}'
recorder = (root / 'Apps/iOS/AudioRecorder.swift').read_text()
# The audio tap runs on a real-time thread; built inside the @MainActor class it crashed on Swift 6's isolation check.
assert recorder.count('installTap(onBus') == 1 and 'nonisolated private static func installTap' in recorder, 'audio tap must be built nonisolated'
watch_home = (root / 'Apps/Watch/SleepiWatchApp.swift').read_text()
# Plain nights stay plain: gentle wake and motion recording are off each time the start sheet opens.
assert '@State private var gentle = false' in watch_home and '@State private var recordMotion = false' in watch_home
assert 'if open { gentle = false; recordMotion = false }' in watch_home, 'Watch experiments must reset to off each night'
health = (root / 'Apps/iOS/HealthKitReader.swift').read_text()
assert 'requestAuthorization(toShare: [], read: read)' in health
assert not re.search(r'\bstore\.(save|delete|startWorkoutSession)\s*\(', health)
assert '.appleSleepingBreathingDisturbances, "count"' in health
for path in (root / 'Config').glob('*.plist'):
    plistlib.loads(path.read_bytes())
entitlements = plistlib.loads((root / 'Config/Sleepi.entitlements').read_bytes())
assert set(entitlements) == {'com.apple.developer.healthkit', 'com.apple.developer.healthkit.background-delivery'}
watch = plistlib.loads((root / 'Config/Watch-Info.plist').read_bytes())
assert watch['WKBackgroundModes'] == ['alarm']
phone = plistlib.loads((root / 'Config/iOS-Info.plist').read_bytes())
assert 'NSHealthUpdateUsageDescription' not in phone
assert phone['UIBackgroundModes'] == ['audio']
project = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', str(root / 'Sleepi.xcodeproj/project.pbxproj')]))
objects = project['objects']
targets = [v for v in objects.values() if v['isa'] == 'PBXNativeTarget']
assert {v['name'] for v in targets} == {'Sleepi', 'SleepiWatch', 'SleepiWidgets', 'SleepiWatchWidgets'}
for settings in [v.get('buildSettings', {}) for v in objects.values()]:
    assert '26.0' == settings.get('IPHONEOS_DEPLOYMENT_TARGET', '26.0')
    assert '26.0' == settings.get('WATCHOS_DEPLOYMENT_TARGET', '26.0')
print(f'Architecture checks passed: {len(files)} Swift files, 4 native targets, no Health writes/workouts/network clients, Watch experiments off by default.')
