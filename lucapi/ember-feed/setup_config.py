#!/usr/bin/env python3
"""
Fills in ember-feed's config.json with the iCloud calendars found on this Pi.
Each calendar is named from its own title; one with "shift" in its name drives "Next shift:".
Usage: python3 setup_config.py URL [URL ...]
"""
import json
import re
import sys
import urllib.request
from pathlib import Path

CONFIG = Path.home() / "ember-feed" / "config.json"


def calendar_name(url):
    try:
        req = urllib.request.Request(url.replace("webcal://", "https://"), headers={"User-Agent": "ember-feed/1.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            head = r.read(4096).decode("utf-8", "replace")
        m = re.search(r"X-WR-CALNAME:(.+)", head)
        return m.group(1).strip() if m else ""
    except Exception as e:
        print("  couldn't read", url[:50] + "...", e)
        return ""


cfg = json.loads(CONFIG.read_text())
cals = []
for i, url in enumerate(dict.fromkeys(sys.argv[1:])):
    name = calendar_name(url) or f"Calendar {i + 1}"
    low = name.lower()
    is_shift = "shift" in low
    colour = "#F0A04B" if is_shift else "#E8833A" if ("dog" in low or "walk" in low) else "#C9B6A6"
    cals.append({"name": name, "url": url, "colour": colour, "shifts": is_shift})
    print(f"  {name}{'  <- shifts' if is_shift else ''}")
cfg["calendars"] = cals
cfg.setdefault("addon_upstream", "http://127.0.0.1:7010")
CONFIG.write_text(json.dumps(cfg, indent=2))
print("Saved", CONFIG)
