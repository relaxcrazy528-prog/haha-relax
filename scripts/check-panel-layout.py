#!/usr/bin/env python3
"""Compile and run a power-free native panel check in an active macOS desktop."""
import argparse
from pathlib import Path
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-dir', type=Path)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
build = (args.build_dir or repo / 'build' / 'panel-layout').resolve()
build.mkdir(parents=True, exist_ok=True)
app = build / 'PanelLayoutProbe.app'
binary = app / 'Contents/MacOS/PanelLayoutProbe'
binary.parent.mkdir(parents=True, exist_ok=True)
with (app / 'Contents/Info.plist').open('wb') as handle:
    plistlib.dump({'CFBundleExecutable': 'PanelLayoutProbe',
                  'CFBundleIdentifier': 'local.keep-online.panel-layout-check',
                  'CFBundlePackageType': 'APPL', 'LSUIElement': True}, handle)
subprocess.run(['swiftc', '-parse-as-library', '-swift-version', '6',
                '-module-cache-path', str(build / 'module-cache'),
                str(repo / 'Sources/KeepOnlineApp/PanelLayout.swift'),
                str(repo / 'Sources/KeepOnlineApp/PanelView.swift'),
                str(repo / 'Tools/PanelLayoutProbe/main.swift'),
                '-o', str(binary)], check=True, timeout=180)
subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(app)], check=True)
subprocess.run([str(binary), str(build / 'results')], check=True, timeout=30)
