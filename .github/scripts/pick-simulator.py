#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime
that the selected Xcode's SDK supports (runner images also ship runtimes for
newer Xcodes, which an older xcodebuild can't run).

Used by CI so the workflow does not hard-code a device name that changes
with every Xcode release.
"""
import json
import subprocess
import sys

out = subprocess.run(
    ["xcrun", "simctl", "list", "devices", "available", "-j"],
    check=True, capture_output=True, text=True,
).stdout
devices = json.loads(out)["devices"]
sdk = tuple(int(x) for x in subprocess.run(
    ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
    check=True, capture_output=True, text=True,
).stdout.strip().split("."))


def version(runtime: str) -> tuple:
    # com.apple.CoreSimulator.SimRuntime.iOS-26-5 -> (26, 5)
    # Device-specific runtimes carry a suffix, e.g. iOS-27-1-iPhone19-4 -> (27, 1)
    tail = runtime.rsplit(".", 1)[-1]
    if not tail.startswith("iOS-"):
        return ()
    parts = []
    for x in tail[4:].split("-"):
        if not x.isdigit():
            break
        parts.append(int(x))
    return tuple(parts)


candidates = [
    (version(rt), d["name"], d["udid"])
    for rt, ds in devices.items() if version(rt) and version(rt) <= sdk
    # Skip the foldable iPhone Duo: its screen depends on hinge posture.
    for d in ds if d["name"].startswith("iPhone") and "Duo" not in d["name"]
]
if not candidates:
    sys.exit("No iPhone simulator available")
best = max(candidates)
print(f"Using {best[1]} (iOS {'.'.join(map(str, best[0]))})", file=sys.stderr)
print(best[2])
