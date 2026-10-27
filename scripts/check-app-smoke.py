#!/usr/bin/env python3
"""Run the internal startup/start/stop/quit check in an active macOS desktop session."""
from pathlib import Path
import argparse
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
args = parser.parse_args()
binary = args.app.resolve() / 'Contents/MacOS/KeepOnline'
result = subprocess.run([str(binary), '--smoke-test'], text=True, capture_output=True, timeout=15)
if result.returncode or 'SMOKE_PASS:' not in result.stdout:
    raise SystemExit('Application check failed: ' + result.stdout + result.stderr)
print(result.stdout.strip())
