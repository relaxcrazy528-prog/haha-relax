#!/usr/bin/env python3
"""Read-only, allowlisted macOS research inventory. Python 3 standard library only.

Prints JSON; does not change power policy, create assertions, collect identifiers,
open user files, or contact a network. Run from the project root:
    python3 Research/inventory.py > Research/inventory/current.json
"""

import argparse
import datetime
import json
import plistlib
import re
import subprocess
import sys


IOREG_BOOLEAN_KEYS = (
    "AppleClamshellState",
    "AppleClamshellCausesSleep",
    "SleepDisabled",
)


def run_readonly(argv, source, errors):
    """Capture privately. Raw command output and exception messages never escape."""
    try:
        result = subprocess.run(
            argv,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
            env={"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"},
        )
    except subprocess.TimeoutExpired:
        errors.append({"source": source, "reason": "timeout"})
        return None
    except OSError:
        errors.append({"source": source, "reason": "unavailable"})
        return None
    if result.returncode:
        errors.append({"source": source, "reason": "command_failed", "exit_code": result.returncode})
        return None
    return result.stdout


def validated_text(argv, source, pattern, errors):
    data = run_readonly(argv, source, errors)
    if data is None:
        return None
    try:
        value = data.decode("ascii").strip()
    except UnicodeDecodeError:
        value = ""
    if not re.fullmatch(pattern, value):
        errors.append({"source": source, "reason": "unexpected_output"})
        return None
    return value


def select_ioreg_properties(data, errors):
    """Only root-node Boolean power flags; drop all other keys and value types."""
    values = {}
    if data is None:
        return {"properties": values, "unavailable_properties": list(IOREG_BOOLEAN_KEYS)}
    try:
        nodes = plistlib.loads(data)
    except (plistlib.InvalidFileException, ValueError, TypeError, OverflowError):
        errors.append({"source": "ioreg.root_domain", "reason": "invalid_plist"})
        return {"properties": values, "unavailable_properties": list(IOREG_BOOLEAN_KEYS)}
    if isinstance(nodes, list) and len(nodes) == 1 and isinstance(nodes[0], dict):
        for key in IOREG_BOOLEAN_KEYS:
            value = nodes[0].get(key)
            if type(value) is bool:
                values[key] = value
    else:
        errors.append({"source": "ioreg.root_domain", "reason": "unexpected_structure"})
    return {
        "properties": values,
        "unavailable_properties": [key for key in IOREG_BOOLEAN_KEYS if key not in values],
    }


def collect_inventory():
    errors = []
    result = {
        "schema_version": 1,
        "collected_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
        "collection_mode": "read_only",
        "os": {},
        "hardware": {},
        "root_domain_observation": {},
        "errors": errors,
        "lid_capability_verdict": "not_validated",
    }
    if sys.platform != "darwin":
        errors.append({"source": "platform", "reason": "requires_macos"})
        return result

    for field, arg, pattern in (
        ("product_version", "-productVersion", r"[0-9]+(?:\.[0-9]+){1,2}"),
        ("build", "-buildVersion", r"[0-9]+[A-Z][0-9]+[a-z]?"),
    ):
        result["os"][field] = validated_text(
            ["/usr/bin/sw_vers", arg], "sw_vers." + field, pattern, errors
        )

    for section, field, key, pattern in (
        ("os", "kernel_release", "kern.osrelease", r"[0-9]+(?:\.[0-9]+){1,2}"),
        ("hardware", "model_identifier", "hw.model", r"(?:Mac|MacBookPro|MacBookAir|MacBook|Macmini|MacPro|iMac|iMacPro|Xserve)[0-9]+,[0-9]+"),
        ("hardware", "architecture", "hw.machine", r"arm64|x86_64"),
        ("hardware", "physical_cores", "hw.physicalcpu", r"[0-9]{1,3}"),
        ("hardware", "logical_cores", "hw.logicalcpu", r"[0-9]{1,3}"),
    ):
        value = validated_text(["/usr/sbin/sysctl", "-n", key], "sysctl." + key, pattern, errors)
        if field in ("physical_cores", "logical_cores") and value is not None:
            value = int(value)
        result[section][field] = value

    data = run_readonly(
        ["/usr/sbin/ioreg", "-a", "-r", "-d", "1", "-c", "IOPMrootDomain"],
        "ioreg.root_domain", errors,
    )
    result["root_domain_observation"] = select_ioreg_properties(data, errors)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compact", action="store_true", help="emit JSON without indentation")
    args = parser.parse_args()
    print(json.dumps(collect_inventory(), ensure_ascii=True, indent=None if args.compact else 2))


if __name__ == "__main__":
    main()
