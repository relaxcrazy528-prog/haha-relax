#!/usr/bin/env python3
"""Opt-in real IOPM integration check. No root or global preference writes."""
import argparse
import json
import os
import select
import signal
import subprocess
import time


def read_line(process, timeout=5):
    ready, _, _ = select.select([process.stdout], [], [], timeout)
    if not ready:
        raise RuntimeError('integration fixture did not respond in time')
    return process.stdout.readline().strip()


def request(process, message):
    process.stdin.write(message + '\n')
    process.stdin.flush()
    return read_line(process)


def verify(binary, disk=False):
    p = subprocess.Popen([binary] + (['--disk'] if disk else []), stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        ready = read_line(p)
        assert ready.startswith('READY '), ready
        assert request(p, 'inspect') == 'ACTIVE'
        assert request(p, 'renew') == 'RENEWED'
        os.kill(p.pid, signal.SIGSTOP)
        time.sleep(6)
        # pmset is read-only here; verify native expiration while the owner is suspended.
        assertions = subprocess.check_output(['/usr/bin/pmset', '-g', 'assertions'], text=True)
        assert f'pid {p.pid}(' not in assertions, 'suspended fixture still owns assertions'
        os.kill(p.pid, signal.SIGCONT)
        assert request(p, 'inspect') == 'ABSENT'
        late = request(p, 'renew')
        assert late.startswith('ERROR '), late
        assert request(p, 'inspect') == 'ABSENT', 'late renewal recreated assertion'
        assert request(p, 'stop') == 'STOPPED', 'expired assertion could not be cleaned idempotently'
        p.wait(timeout=5)
        assert p.returncode == 0
        return {'kind': 'diskIdle' if disk else 'systemIdle', 'result': 'pass',
                'suspended_owner_expiry': True, 'late_renewal_did_not_recreate': True}
    finally:
        if p.poll() is None:
            p.kill()
        p.wait(timeout=5)
        for stream in (p.stdin, p.stdout, p.stderr):
            if stream:
                stream.close()


def crash_cleanup(binary):
    p = subprocess.Popen([binary], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, bufsize=1)
    try:
        assert read_line(p).startswith('READY ')
        assert request(p, 'inspect') == 'ACTIVE'
        p.kill()
        p.wait(timeout=5)
        deadline = time.monotonic() + 3
        while True:
            output = subprocess.check_output(['/usr/bin/pmset', '-g', 'assertions'], text=True)
            if f'pid {p.pid}(' not in output:
                break
            assert time.monotonic() < deadline, 'assertions not released after process exit'
            time.sleep(.1)
        return {'forced_process_exit_cleanup': 'pass'}
    finally:
        if p.poll() is None:
            p.kill()
        p.wait(timeout=5)
        for stream in (p.stdin, p.stdout, p.stderr):
            if stream:
                stream.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', help='absolute path to the internal LeaseProbe executable')
    args = parser.parse_args()
    print(json.dumps({'tests': [verify(args.probe), verify(args.probe, True), crash_cleanup(args.probe)],
                      'global_power_preferences_modified': False}, ensure_ascii=False, indent=2))
