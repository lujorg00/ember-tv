#!/usr/bin/env python3
"""
Adds a status file to catwatch so Ember can show each cat as In / Out and for how long.
Writes ~/.catwatch_state.json every evaluation: {name: {zone, room, since}}.
Makes a backup first (catwatch.py.bak-ember). Safe to run twice.
"""
import shutil
from pathlib import Path

p = Path.home() / "catwatch.py"
s = p.read_text()
if "EMBER_STATE_FILE" in s:
    print("catwatch already patched")
    raise SystemExit(0)
shutil.copy(p, p.with_name("catwatch.py.bak-ember"))

def swap(old, new):
    global s
    if s.count(old) != 1:
        raise SystemExit(f"catwatch.py looks different than expected near: {old.strip()[:60]!r} - nothing changed")
    s = s.replace(old, new)

swap("import json\n", "import json\nimport os\n")
swap('state = {}   # name -> {"zone": str|None, "rooms": {room: {"rssi": f, "t": f}}}',
     'state = {}   # name -> {"zone": str|None, "rooms": {room: {"rssi": f, "t": f}}}\n'
     'EMBER_STATE_FILE = os.path.expanduser("~/.catwatch_state.json")  # read by ember-feed for the TV')
swap('                s["zone"] = "is unreachable"   # startup: stay quiet\n',
     '                s["zone"] = "is unreachable"   # startup: stay quiet\n'
     '                s["since"] = now\n')
swap('                notify(f"{name} {new_zone}", priority="default", tags="cat")\n            s["zone"] = new_zone\n',
     '                notify(f"{name} {new_zone}", priority="default", tags="cat")\n            s["zone"] = new_zone\n'
     '            s["since"] = now\n'
     '            s["room"] = best_room if fresh else None\n')
swap("\n\ndef main():",
     '''

def write_ember_state():
    out = {n: {"zone": v.get("zone"), "room": v.get("room"), "since": v.get("since")} for n, v in state.items()}
    tmp = EMBER_STATE_FILE + ".tmp"
    try:
        with open(tmp, "w") as f:
            json.dump(out, f)
        os.replace(tmp, EMBER_STATE_FILE)
    except OSError as e:
        print("[catwatch] couldn't write ember state:", e, flush=True)


def main():''')
swap("            time.sleep(EVAL_EVERY)\n",
     "            time.sleep(EVAL_EVERY)\n            write_ember_state()\n")
p.write_text(s)
compile(s, str(p), "exec")
print("catwatch patched (backup: catwatch.py.bak-ember)")
