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
# The addon's address includes its ADDON_TOKEN (read here on the Pi, never printed).
token = ""
for env in (app_dir / ".env",):
    if env.exists():
        for line in env.read_text(errors="replace").splitlines():
            m = re.match(r"\s*ADDON_TOKEN\s*=\s*['\"]?([^'\"\s#]+)", line)
            if m:
                token = m.group(1)
if not token:
    try:
        import importlib.util, os
        spec = importlib.util.spec_from_file_location("lucaddon_config", app_dir / "config.py")
        mod = importlib.util.module_from_spec(spec)
        cwd = os.getcwd()
        os.chdir(app_dir)
        spec.loader.exec_module(mod)
        os.chdir(cwd)
        token = getattr(mod, "ADDON_TOKEN", "") or ""
    except Exception:
        pass
if token:
    prefixes.add("/" + token)
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
    print("Couldn't find the manifest (tried", len(prefixes), "addresses)")
    raise SystemExit(1)
cfg_path = Path.home() / "ember-feed" / "config.json"
cfg = json.loads(cfg_path.read_text())
cfg["addon_upstream"] = "http://127.0.0.1:7010" + found
cfg_path.write_text(json.dumps(cfg, indent=2))
print("Addon manifest found" + (" (behind its token)" if found else "") + " - saved")
