#!/usr/bin/env python3
"""Exercise the Swift adapter with independently encoded Grok cache fixtures."""
import base64
import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
now = 1_800_000_000_000
cache = {"schemaVersion": 2, "value": {
    "kind": "present", "selectedTeamId": None,
    "reading": {"usage": {"percentUsed": 12.34, "nextResetMs": now + 3600000,
                          "hasNonZeroIncludedLimit": True}, "readAtMs": now - 60000},
    "expiresAtMs": now + 7200000}}


def write(directory, key, value):
    name = base64.b32encode(key.encode()).decode().lower().rstrip("=") + ".blob"
    (directory / name).write_text(json.dumps(value))


with tempfile.TemporaryDirectory(prefix="grok-gauge-tests-") as temp:
    temp = Path(temp)
    for name in ("valid", "no-reset", "over-limit", "expired", "reset-passed", "too-old",
                 "missing", "absent", "no-allowance", "wrong-account", "signed-out",
                 "bad-schema", "bad-json", "negative", "future-reading"):
        directory = temp / name
        directory.mkdir()
        if name == "signed-out":
            continue
        write(directory, "sand.client.slice.client-meta.account-slot",
              {"schemaVersion": 1, "value": "grok|other" if name == "wrong-account" else "grok|test"})
        if name == "missing":
            continue
        value = copy.deepcopy(cache)
        usage = value["value"]["reading"]["usage"]
        if name == "no-reset": usage["nextResetMs"] = None
        if name == "over-limit": usage["percentUsed"] = 123.4
        if name == "expired": value["value"]["expiresAtMs"] = now - 1
        if name == "reset-passed": usage["nextResetMs"] = now - 1
        if name == "too-old": value["value"]["reading"]["readAtMs"] = now - 90000000
        if name == "absent": value["value"].update(kind="absent", reading=None)
        if name == "no-allowance": usage["hasNonZeroIncludedLimit"] = False
        if name == "bad-schema": value["schemaVersion"] = 99
        if name == "negative": usage["percentUsed"] = -1
        if name == "future-reading": value["value"]["reading"]["readAtMs"] = now + 120000
        if name == "bad-json": value = ["unexpected"]
        write(directory, "sand.client.slice.account.grok%7Ctest.weekly-usage.cache", value)
    env = dict(os.environ, CLANG_MODULE_CACHE_PATH="/tmp/ai-fuel-gauge-module-cache")
    executable = temp / "tests"
    subprocess.run(["swiftc", "-parse-as-library", str(root / "AIFuelGauge/Sources/Services/GrokFetcher.swift"),
                    str(root / "Tests/GrokFetcherTests.swift"), "-o", str(executable)], check=True, env=env)
    subprocess.run([str(executable), str(temp)], check=True)
    if "--live" in __import__("sys").argv:
        subprocess.run([str(executable), "--live"], check=True)
