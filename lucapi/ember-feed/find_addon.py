#!/usr/bin/env python3
"""Finds the addon's manifest address on this Pi and points ember-feed at it."""
import json
import re
import urllib.request
from pathlib import Path

app_dir = Path.home() / "lucaddon"
prefixes = {""}
for f in app_dir.glob("*.py"):
    for m in re.finditer(r"url_prefix\s*=\s*['\"]([^'\"]*)['\"]", f.read_text(errors="replace")):
        prefixes.add(m.group(1).rstrip("/"))
found = None
for pre in sorted(prefixes, key=len, reverse=True):
    url = "http://127.0.0.1:7010" + pre + "/manifest.json"
    try:
        with urllib.request.urlopen(url, timeout=8) as r:
            if b'"catalogs"' in r.read(200000):
                found = pre
                break
    except Exception:
        pass
if found is None:
    print("Couldn't find the manifest. Prefixes tried:", sorted(prefixes))
    raise SystemExit(1)
cfg_path = Path.home() / "ember-feed" / "config.json"
cfg = json.loads(cfg_path.read_text())
cfg["addon_upstream"] = "http://127.0.0.1:7010" + found
cfg_path.write_text(json.dumps(cfg, indent=2))
print("Addon manifest found at prefix", repr(found or "/"), "- saved")
