#!/usr/bin/env python3
"""Prints the UDID of the best available iPhone simulator.

Reads `xcrun simctl list devices available -j` on stdin: the newest iOS
runtime wins, and within it a plain iPhone (not Pro, Plus, Max, SE or Air) is
preferred because it is the smallest screen the layouts must survive.
"""
import json
import sys


def runtime_version(runtime: str):
    tail = runtime.split("iOS-")[-1]
    return tuple(int(p) for p in tail.split("-") if p.isdigit())


def score(name: str) -> int:
    plain = not any(word in name for word in ("Pro", "Plus", "Max", "SE", "Air"))
    return 1 if plain else 0


def pick(devices_by_runtime: dict):
    best = None
    for runtime, devices in devices_by_runtime.items():
        if "iOS" not in runtime:
            continue
        version = runtime_version(runtime)
        for device in devices:
            if not device.get("isAvailable", False) or "iPhone" not in device["name"]:
                continue
            key = (version, score(device["name"]))
            if best is None or key > best[0]:
                best = (key, device["udid"], device["name"])
    return best


if __name__ == "__main__":
    result = pick(json.load(sys.stdin)["devices"])
    if result:
        print(result[1])
        print(f"picked {result[2]}", file=sys.stderr)
