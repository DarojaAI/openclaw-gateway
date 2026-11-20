#!/usr/bin/env python3
"""Validate the product manifests the platform repo (linux-desktop-seed)
will consume as a pinned gateway release.

Checks (docs/plans/2026-11-20-gateway-product-boundary.md in
linux-desktop-seed, phase 1):
  * every product JSON file under config/ parses;
  * config/openclaw-plugins.json: gateway_release is x.y.z and has a digest in
    config/openclaw-official-digests.json, every plugin has a package, and no
    retired id is still a plugin;
  * every digest is a sha256:<64 hex> value;
  * config/openclaw-version.<env> hold x.y.z.
Exit 0 when clean, 1 with one line per problem.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
CFG = ROOT / "config"
JSON_FILES = [
    "openclaw-ideal-config.json",
    "openclaw-config-policy-pins.json",
    "openclaw-cli-surfaces.json",
    "openclaw-plugins.json",
    "openclaw-official-digests.json",
    "openclaw-test.json",
    "openclaw-head.json",
]
VER = re.compile(r"^\d+\.\d+\.\d+$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
errors = []
docs = {}

for name in JSON_FILES:
    path = CFG / name
    try:
        docs[name] = json.loads(path.read_text())
    except (OSError, ValueError) as exc:
        errors.append(f"{name}: unreadable or invalid JSON ({exc})")

plugins = docs.get("openclaw-plugins.json")
digests = docs.get("openclaw-official-digests.json")
if digests is not None:
    for ver, dig in digests.get("digests", {}).items():
        if not VER.match(ver) or not DIGEST.match(str(dig)):
            errors.append(f"openclaw-official-digests.json: bad entry {ver!r}: {dig!r}")
if plugins is not None:
    rel = plugins.get("gateway_release", "")
    if not VER.match(rel):
        errors.append(f"openclaw-plugins.json: gateway_release {rel!r} is not x.y.z")
    elif digests is not None and rel not in digests.get("digests", {}):
        errors.append(f"openclaw-plugins.json: gateway_release {rel} has no digest in openclaw-official-digests.json")
    for pid, spec in plugins.get("plugins", {}).items():
        if not isinstance(spec, dict) or not spec.get("package"):
            errors.append(f"openclaw-plugins.json: plugin {pid!r} has no package")
    for pid in plugins.get("retired", []):
        if pid in plugins.get("plugins", {}):
            errors.append(f"openclaw-plugins.json: retired id {pid!r} is still listed in plugins")

for pin in sorted(CFG.glob("openclaw-version.*")):
    raw = pin.read_text().strip()
    if not VER.match(raw):
        errors.append(f"{pin.name}: {raw!r} is not x.y.z")

for line in errors:
    print(f"ERROR: {line}", file=sys.stderr)
print("product manifests: " + ("FAIL" if errors else "ok"))
sys.exit(1 if errors else 0)
