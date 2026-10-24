#!/usr/bin/env python3
"""
ember-feed: the small service on lucapi that feeds Ember on the TV.

  GET /screensaver  -> calendar events, Pi service status, Pi health, photo list
  GET /status       -> cards for the projects strip on Ember's Apps page
  GET /photo/<name> -> a photo from your photos folder
  GET /health       -> "ok"

Config lives in config.json next to this file (see config.example.json).
Needs: python3 -m pip install icalendar recurring-ical-events
"""
import json
import os
import random
import shutil
import subprocess
import threading
import time
import urllib.parse
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from zoneinfo import ZoneInfo

HERE = Path(__file__).resolve().parent
CONFIG_PATH = Path(os.environ.get("EMBER_FEED_CONFIG", HERE / "config.json"))
PHOTO_EXT = {".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif"}


def load_config():
    with open(CONFIG_PATH) as f:
        cfg = json.load(f)
    cfg.setdefault("port", 8090)
    cfg.setdefault("timezone", "Europe/London")
    cfg.setdefault("calendars", [])
    cfg.setdefault("days_ahead", 7)
    cfg.setdefault("max_events", 10)
    cfg.setdefault("services", {})
    cfg["services"].setdefault("auto", True)
    cfg["services"].setdefault("hide", [])
    cfg["services"].setdefault("names", {})
    cfg["services"].setdefault("http", [])
    cfg.setdefault("photos", {})
    cfg["photos"].setdefault("folder", "")
    cfg["photos"].setdefault("bing", True)
    cfg["photos"].setdefault("seconds_per_photo", 30)
    cfg.setdefault("extra_cards_urls", [])
    cfg.setdefault("cats", {})
    cfg["cats"].setdefault("url", "")
    cfg.setdefault("ticker_others", 3)
    cfg.setdefault("addon_upstream", "http://127.0.0.1:7010")
    return cfg


CFG = load_config()
TZ = ZoneInfo(CFG["timezone"])

# ------------------------------------------------------------------ small cache helper

_cache = {}
_cache_lock = threading.Lock()


def cached(key, ttl, fn):
    now = time.time()
    with _cache_lock:
        hit = _cache.get(key)
        if hit and now - hit[0] < ttl:
            return hit[1]
    try:
        value = fn()
    except Exception as e:  # keep serving the last good value if a source blips
        print(f"[ember-feed] {key} failed: {e}", flush=True)
        if hit:
            return hit[1]
        raise
    with _cache_lock:
        _cache[key] = (now, value)
    return value


def http_get(url, timeout=10):
    req = urllib.request.Request(url, headers={"User-Agent": "ember-feed/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()

# ------------------------------------------------------------------ calendar


def _fetch_events():
    import icalendar
    import recurring_ical_events

    now = datetime.now(TZ)
    start = now - timedelta(hours=2)          # keep something that started a moment ago
    end = now + timedelta(days=CFG["days_ahead"])
    out = []
    for cal in CFG["calendars"]:
        url = cal["url"].replace("webcal://", "https://")
        try:
            ics = icalendar.Calendar.from_ical(http_get(url, timeout=15))
        except Exception as e:
            print(f"[ember-feed] calendar {cal.get('name')} failed: {e}", flush=True)
            continue
        for ev in recurring_ical_events.of(ics).between(start, end):
            dtstart = ev.get("DTSTART").dt
            dtend = ev.get("DTEND").dt if ev.get("DTEND") else None
            all_day = not isinstance(dtstart, datetime)
            if all_day:
                s = datetime.combine(dtstart, datetime.min.time(), TZ)
                e = datetime.combine(dtend, datetime.min.time(), TZ) if dtend else s + timedelta(days=1)
            else:
                s = dtstart.astimezone(TZ) if dtstart.tzinfo else dtstart.replace(tzinfo=TZ)
                e = (dtend.astimezone(TZ) if dtend.tzinfo else dtend.replace(tzinfo=TZ)) if isinstance(dtend, datetime) else s + timedelta(hours=1)
            if e <= now:
                continue  # already over
            out.append({
                "start": s.isoformat(),
                "end": e.isoformat(),
                "allDay": all_day,
                "title": str(ev.get("SUMMARY", "")).strip() or "(no title)",
                "location": str(ev.get("LOCATION", "")).strip(),
                "calendar": cal.get("name", ""),
                "colour": cal.get("colour", "#F0A04B"),
                "shift": bool(cal.get("shifts", False)),
            })
    out.sort(key=lambda x: (x["start"], not x["allDay"]))
    return out


def events():
    evs = cached("events", 300, _fetch_events)
    now = datetime.now(TZ)
    today = now.date()
    shaped = []
    for ev in evs:
        s = datetime.fromisoformat(ev["start"])
        e = datetime.fromisoformat(ev["end"])
        if e <= now:
            continue
        d = s.date() if s > now else today
        if d == today:
            day = "Today"
        elif d == today + timedelta(days=1):
            day = "Tomorrow"
        else:
            day = d.strftime("%a %-d %b")
        if ev["allDay"]:
            when = "All day"
        elif s <= now:
            when = "Now"
        else:
            when = s.strftime("%H:%M")
        shaped.append(dict(ev, day=day, time=when,
                           endTime="" if ev["allDay"] else e.strftime("%H:%M")))
        if len(shaped) >= CFG["max_events"]:
            break
    return shaped

# ------------------------------------------------------------------ services


def _run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def _systemd_services():
    """Your own services: regular unit files in /etc/systemd/system that are enabled."""
    found = []
    base = Path("/etc/systemd/system")
    if not base.is_dir():
        return found
    for f in sorted(base.glob("*.service")):
        if f.is_symlink() or "@" in f.name:
            continue
        unit = f.stem
        if unit in CFG["services"]["hide"]:
            continue
        try:
            if "type=oneshot" in f.read_text().lower().replace(" ", ""):
                continue  # backup jobs etc. finish and stop; they aren't "down"
        except OSError:
            pass
        if (base / f"{unit}.timer").exists() or Path(f"/lib/systemd/system/{unit}.timer").exists():
            continue  # run by a timer (updaters and the like), so not meant to stay running
        if _run(["systemctl", "is-enabled", unit]) not in ("enabled", "static"):
            continue
        state = _run(["systemctl", "is-active", unit])
        found.append({"name": CFG["services"]["names"].get(unit, unit), "id": unit,
                      "kind": "service", "up": state == "active", "state": state or "unknown"})
    return found


def _docker_containers():
    if not shutil.which("docker"):
        return []
    out = _run(["docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}"])
    found = []
    for line in out.splitlines():
        if "\t" not in line:
            continue
        name, state = line.split("\t", 1)
        if name in CFG["services"]["hide"]:
            continue
        found.append({"name": CFG["services"]["names"].get(name, name), "id": name,
                      "kind": "docker", "up": state == "running", "state": state})
    return found


def _http_checks():
    found = []
    for chk in CFG["services"]["http"]:
        up = False
        try:
            req = urllib.request.Request(chk["url"], method="GET", headers={"User-Agent": "ember-feed/1.0"})
            with urllib.request.urlopen(req, timeout=5) as r:
                up = 200 <= r.status < 400
        except Exception:
            up = False
        found.append({"name": chk["name"], "id": chk["url"], "kind": "http",
                      "up": up, "state": "up" if up else "down"})
    return found


def _services():
    svcs = []
    if CFG["services"]["auto"]:
        svcs += _systemd_services() + _docker_containers()
    svcs += _http_checks()
    return svcs


def services():
    return cached("services", 30, _services)


def pi_health():
    def _h():
        h = {}
        try:
            h["tempC"] = round(int(Path("/sys/class/thermal/thermal_zone0/temp").read_text()) / 1000)
        except Exception:
            pass
        try:
            du = shutil.disk_usage("/")
            h["diskPct"] = round(du.used / du.total * 100)
        except Exception:
            pass
        try:
            secs = float(Path("/proc/uptime").read_text().split()[0])
            d, rem = divmod(int(secs), 86400)
            h["uptime"] = f"{d}d {rem // 3600}h" if d else f"{rem // 3600}h {rem % 3600 // 60}m"
        except Exception:
            pass
        try:
            h["load"] = round(os.getloadavg()[0], 2)
        except Exception:
            pass
        return h
    return cached("health", 30, _h)

# ------------------------------------------------------------------ photos


def _folder_photos():
    folder = CFG["photos"]["folder"]
    if not folder or not os.path.isdir(folder):
        return []
    return sorted(p.name for p in Path(folder).iterdir()
                  if p.is_file() and p.suffix.lower() in PHOTO_EXT and not p.name.startswith("."))


def _bing_photos():
    raw = http_get("https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-GB")
    data = json.loads(raw)
    return [{"url": "https://www.bing.com" + img["url"], "credit": img.get("copyright", "")}
            for img in data.get("images", []) if img.get("url")]


def photos(base_url):
    out = [{"url": f"{base_url}/photo/{urllib.parse.quote(n)}", "credit": ""}
           for n in cached("folder", 60, _folder_photos)]
    if CFG["photos"]["bing"] and (not out or CFG["photos"].get("mix_bing", False)):
        try:
            out += cached("bing", 6 * 3600, _bing_photos)
        except Exception:
            pass
    random.shuffle(out)
    return out

# ------------------------------------------------------------------ status cards (Apps page strip)


def _ago(value):
    """'40m', '3h', '2d' from an ISO time or epoch seconds; '' if unknown."""
    if value in (None, ""):
        return ""
    try:
        if isinstance(value, (int, float)) or str(value).replace(".", "", 1).isdigit():
            t = datetime.fromtimestamp(float(value), TZ)
        else:
            t = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            if t.tzinfo is None:
                t = t.replace(tzinfo=TZ)
        mins = max(0, int((datetime.now(TZ) - t).total_seconds() // 60))
    except Exception:
        return ""
    if mins < 60:
        return f"{mins}m"
    if mins < 48 * 60:
        return f"{mins // 60}h"
    return f"{mins // 1440}d"


def _cats():
    """Reads the cat tracker and normalises it to [{name, home, detail}].
    Accepts a list, or a dict keyed by cat name, with fields like home/present/state/location/since."""
    url = CFG["cats"].get("url", "")
    path = CFG["cats"].get("file", "")
    if path and os.path.exists(path):
        raw = json.loads(Path(path).read_text())
    elif url:
        raw = json.loads(http_get(url, timeout=5))
    else:
        return []
    if isinstance(raw, dict) and "cats" in raw:
        raw = raw["cats"]
    elif isinstance(raw, dict) and "pets" in raw:  # the wall dashboard's /api/cats (Sure Petcare flap)
        raw = raw["pets"]
    items = [dict(v, name=v.get("name", k)) for k, v in raw.items()] if isinstance(raw, dict) else list(raw)
    out = []
    outdoor = [r.lower() for r in CFG["cats"].get("outdoor_rooms", ["fence"])]
    for c in items:
        if "zone" in c:  # catwatch's own format
            zone = str(c.get("zone") or "")
            room = str(c.get("room") or "").lower()
            home = bool(zone) and "unreachable" not in zone and room not in outdoor
            since = _ago(c.get("since"))
            out.append({"name": str(c.get("name", "?")), "home": home,
                        "detail": ("In" if home else "Out") + (f" \u00b7 {since}" if since else "")})
            continue
        state = str(c.get("state", c.get("status", ""))).lower()
        home = c.get("home", c.get("present", c.get("inside")))
        if home is None and "inside" not in c:
            home = state in ("home", "in", "inside", "present")
        since = _ago(c.get("since", c.get("last_seen", c.get("changed"))))
        if home is None and "inside" in c:
            out.append({"name": str(c.get("name", "?")), "home": False, "detail": "Unknown"})
            continue
        detail = ("In" if home else "Out") + (f" · {since}" if since else "")
        out.append({"name": str(c.get("name", "?")), "home": bool(home), "detail": detail})
    return out


def _when(e):
    return f"{e['day']} {e['time']}" if e["time"] not in ("All day",) else f"{e['day']} (all day)"


def status_cards():
    """Everything the Apps page shows: calendar ticker, lucapi status, cats (+ legacy cards)."""
    evs = events()
    ticker = []
    shifts = [e for e in evs if e.get("shift")]
    if shifts:
        ticker.append({"prefix": "Next shift:", "text": f"{shifts[0]['title']} \u00b7 {_when(shifts[0])}"})
    for e in [e for e in evs if not e.get("shift")][:CFG["ticker_others"]]:
        ticker.append({"prefix": "", "text": f"{e['title']} \u00b7 {_when(e)}"})

    svcs = services()
    down = [s["name"] for s in svcs if not s["up"]]
    h = pi_health()
    if not svcs:
        text = "lucapi \u00b7 no services found"
    elif down:
        text = f"lucapi \u00b7 {len(down)} down: " + ", ".join(down[:2]) + ("\u2026" if len(down) > 2 else "")
    else:
        text = f"lucapi \u00b7 all {len(svcs)} up" + (f" \u00b7 {h['tempC']}\u00b0C" if "tempC" in h else "")

    try:
        cats = cached("cats", 30, _cats)
    except Exception:
        cats = []

    cards = [{"label": "lucapi", "value": text, "sub": "", "alert": bool(down)}]
    for url in CFG["extra_cards_urls"]:
        try:
            extra = cached("extra:" + url, 60, lambda u=url: json.loads(http_get(u, timeout=5)))
            cards += extra.get("cards", [])
        except Exception:
            pass
    return {"ticker": ticker, "lucapi": {"ok": not down, "text": text}, "cats": cats, "cards": cards[:5]}


def screensaver(base_url):
    return {
        "generated": datetime.now(TZ).isoformat(),
        "events": events(),
        "services": services(),
        "health": pi_health(),
        "photos": photos(base_url),
        "secondsPerPhoto": CFG["photos"]["seconds_per_photo"],
    }

# ------------------------------------------------------------------ HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "ember-feed/1.0"

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _base(self):
        host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or f"localhost:{CFG['port']}"
        proto = self.headers.get("X-Forwarded-Proto", "http")
        return f"{proto}://{host}"

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        try:
            if path == "/health":
                body = b"ok"
                self.send_response(200)
                self.send_header("Content-Type", "text/plain")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif path == "/status":
                self._json(status_cards())
            elif path == "/screensaver":
                self._json(screensaver(self._base()))
            elif path == "/addon" or path.startswith("/addon/"):
                self._addon(self.path[len("/addon"):] or "/")
            elif path.startswith("/photo/"):
                self._photo(urllib.parse.unquote(path[len("/photo/"):]))
            else:
                self._json({"error": "not found"}, 404)
        except Exception as e:
            self._json({"error": str(e)}, 500)

    def _addon(self, rest):
        """Passes requests through to your Stremio addon, which only listens inside the Pi."""
        up = CFG["addon_upstream"].rstrip("/")
        try:
            req = urllib.request.Request(up + rest, headers={"User-Agent": "ember-feed/1.0", "Accept": "application/json"})
            with urllib.request.urlopen(req, timeout=20) as r:
                body = r.read()
                ctype = r.headers.get("Content-Type", "application/json")
                code = r.status
        except urllib.error.HTTPError as e:
            body, ctype, code = e.read(), e.headers.get("Content-Type", "text/plain"), e.code
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _photo(self, name):
        folder = CFG["photos"]["folder"]
        # Only plain file names from the photos folder: no paths, no escaping it.
        if not folder or "/" in name or "\\" in name or name.startswith(".") or name not in _folder_photos():
            self._json({"error": "not found"}, 404)
            return
        p = Path(folder) / name
        ext = p.suffix.lower()
        ctype = {".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".webp": "image/webp",
                 ".heic": "image/heic", ".heif": "image/heif"}.get(ext, "application/octet-stream")
        size = p.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", "public, max-age=86400")
        self.end_headers()
        with open(p, "rb") as f:
            shutil.copyfileobj(f, self.wfile)

    def log_message(self, fmt, *args):
        pass  # quiet; errors still print


def main():
    srv = ThreadingHTTPServer(("0.0.0.0", CFG["port"]), Handler)
    print(f"[ember-feed] listening on :{CFG['port']}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
