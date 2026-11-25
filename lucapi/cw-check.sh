#!/usr/bin/env bash
# Shows Continue watching as lucapi hands it to the apps: every show with when you last watched it, in the order
# the apps should put them (newest first). Run: cd ~/ember-feed-src && git pull -q && bash lucapi/cw-check.sh
cd ~/ember-feed-src
echo "lucapi code: $(git log -1 --format='%h %ad' --date=short)   running copy has watch times: $(grep -q watchedAt ~/ember-feed/feed.py && echo yes || echo NO - run feed-update.sh)"
python3 - <<'PY'
import json, urllib.request, urllib.parse
from datetime import datetime, timezone
B = "http://localhost:8090"
get = lambda p: json.load(urllib.request.urlopen(B + p, timeout=60))
def when(s):
    try: return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
    except Exception: return None
rows = []
for k, p in get("/progress").get("items", {}).items():
    rows.append((when(p.get("pausedAt", "")), k, "part-way", f"S{p.get('season')}E{p.get('episode')} {round(p.get('percent') or 0)}%" if p.get("season") else f"{round(p.get('percent') or 0)}%"))
seen = {r[1] for r in rows}
man = get("/addon/manifest.json")
import re
for c in man.get("catalogs", []):
    if c.get("type") == "series" and re.search(r"pick up|left off|continue", c.get("name", ""), re.I):
        for m in get(f"/addon/catalog/series/{urllib.parse.quote(c['id'])}.json").get("metas", []):
            if m.get("id") and m["id"] not in seen:
                seen.add(m["id"]); rows.append((when(m.get("watchedAt", "")), m["id"], "next ep", "" if m.get("watchedAt") else "NO TIME"))
rows.sort(key=lambda r: r[0] or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
def name(k):
    try: return json.load(urllib.request.urlopen(f"https://v3-cinemeta.strem.io/meta/series/{k}.json", timeout=8))["meta"]["name"]
    except Exception: return k
for t, k, kind, extra in rows[:20]:
    print(f"{t.strftime('%a %d %b %H:%M') if t else '   (no time)    '}  {kind:9} {name(k)[:34]:34} {extra}")
PY
