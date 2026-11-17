#!/usr/bin/env python3
"""Print the UDID of an available iPhone simulator on the newest iOS runtime.

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


def version(runtime: str) -> tuple:
    # com.apple.CoreSimulator.SimRuntime.iOS-26-5 -> (26, 5)
    tail = runtime.rsplit(".", 1)[-1]
    if not tail.startswith("iOS-"):
        return ()
    return tuple(int(x) for x in tail[4:].split("-"))


candidates = [
    (version(rt), d["name"], d["udid"])
    for rt, ds in devices.items() if version(rt)
    for d in ds if d["name"].startswith("iPhone")
]
if not candidates:
    sys.exit("No iPhone simulator available")
best = max(candidates)
print(f"Using {best[1]} (iOS {'.'.join(map(str, best[0]))})", file=sys.stderr)
print(best[2])
