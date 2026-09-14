#!/usr/bin/env python3
"""Explicit, read-only snapshot for local QA. Never loads ProfileStore/migrations."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

values = plistlib.loads(subprocess.run(
    ["defaults", "export", "com.tapir132.typer", "-"], capture_output=True, check=True).stdout)
profiles = json.loads(values.get("typer.profiles.v1", b"[]"))
active = str(values.get("typer.activeProfile.v1", "")).lower()
profile = next((p for p in profiles if str(p["id"]).lower() == active and p.get("evidence")), None)
if profile is None:
    raise SystemExit("Select a learned profile in Typer before snapshotting it. No preferences were changed.")
snapshot = {"profile": profile, "samples": json.loads(values.get("typer.samples.v1", b"[]")),
            "settings": json.loads(values.get("typer.settings.v1", b"{}"))}
destination = Path(sys.argv[1])
# Create privately from the first byte; do not print raw training data.
with os.fdopen(os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
    json.dump(snapshot, file)
print(f"Private QA snapshot: {profile['sampleCount']} learned samples. User data is unchanged.")
