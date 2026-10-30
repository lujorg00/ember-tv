#!/usr/bin/env python3
"""
ember-feed: the small service on lucapi that feeds Ember on the TV.

  GET /screensaver  -> calendar events, Pi service status, Pi health, photo list
  GET /status       -> cards for the projects strip on Ember's Apps page
  GET /photo/<name> -> a photo from your photos folder
  GET /cats         -> just the cats, in or out (polled often, for the pop-ups)
  GET /night        -> the next shift within 36 hours (the dimmer starts earlier before early shifts)
  GET /weather      -> current weather and today's sunrise/sunset (Open-Meteo)
  GET /progress     -> where you stopped part-way through films and episodes (Trakt)
  GET /next/<imdb>  -> the next episode of a show (Trakt)
  GET /alerts       -> calendar and reminder pop-ups (12h, 1h, 30 min before; early shifts 9h before)
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
            alarms = []
            for al in ev.walk("VALARM"):
                trig = al.get("TRIGGER")
                d = getattr(trig, "dt", None)
                if isinstance(d, timedelta):
                    alarms.append(int(-d.total_seconds() // 60))  # minutes before the start
            out.append({
                "start": s.isoformat(),
                "end": e.isoformat(),
                "allDay": all_day,
                "title": str(ev.get("SUMMARY", "")).strip() or "(no title)",
                "location": str(ev.get("LOCATION", "")).strip(),
                "calendar": cal.get("name", ""),
                "colour": cal.get("colour", "#F0A04B"),
                "shift": bool(cal.get("shifts", False)),
                "alarms": alarms,
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
    return {"ticker": ticker, "lucapi": {"ok": not down, "text": text}, "cats": cats, "cards": cards[:5],
            "weather": weather()}


def screensaver(base_url):
    return {
        "generated": datetime.now(TZ).isoformat(),
        "events": events(),
        "services": services(),
        "health": pi_health(),
        "photos": photos(base_url),
        "secondsPerPhoto": CFG["photos"]["seconds_per_photo"],
        "weather": weather(),
    }

# ------------------------------------------------------------------ night: the next shift (for the dimmer)


def night():
    """The next shift that starts within 36 hours, so the TV can dim earlier before an early start."""
    now = datetime.now(TZ)
    for e in cached("events", 300, _fetch_events):
        if not e.get("shift") or e.get("allDay"):
            continue
        s = datetime.fromisoformat(e["start"])
        if now < s <= now + timedelta(hours=36):
            return {"shift": {"title": e["title"], "start": s.isoformat()}}
    return {"shift": None}

# ------------------------------------------------------------------ weather (Open-Meteo, no key needed)

_WMO = {0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Cloudy", 45: "Fog", 48: "Fog",
        51: "Drizzle", 53: "Drizzle", 55: "Drizzle", 56: "Freezing drizzle", 57: "Freezing drizzle",
        61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Freezing rain",
        71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains",
        80: "Showers", 81: "Showers", 82: "Heavy showers", 85: "Snow showers", 86: "Snow showers",
        95: "Thunderstorms", 96: "Thunderstorms", 99: "Thunderstorms"}


def _weather():
    w = CFG.get("weather", {})
    lat, lon = w.get("lat", 53.48), w.get("lon", -2.29)
    url = ("https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s"
           "&current=temperature_2m,weather_code,is_day&daily=temperature_2m_max,temperature_2m_min,"
           "sunrise,sunset,precipitation_probability_max&timezone=%s&forecast_days=1"
           % (lat, lon, urllib.parse.quote(CFG["timezone"])))
    d = json.loads(http_get(url, timeout=10))
    cur, day = d["current"], d["daily"]
    code = int(cur.get("weather_code", 0))
    return {"tempC": round(cur["temperature_2m"]), "code": code, "text": _WMO.get(code, ""),
            "isDay": bool(cur.get("is_day", 1)),
            "highC": round(day["temperature_2m_max"][0]), "lowC": round(day["temperature_2m_min"][0]),
            "rainChance": day.get("precipitation_probability_max", [None])[0],
            "sunrise": day["sunrise"][0][-5:], "sunset": day["sunset"][0][-5:]}


def weather():
    try:
        return cached("weather", 900, _weather)
    except Exception:
        return {}

# ------------------------------------------------------------------ Trakt: where you are in things
# Reuses your addon's Trakt login (it refreshes its own token; we re-read it each time) unless
# config.json has "trakt": {"client_id": ..., "access_token": ...}.

_trakt_files = {}


def _scan_addon_for_trakt():
    root = Path(CFG.get("trakt", {}).get("addon_dir", str(Path.home() / "lucaddon")))
    client, token_file = None, None
    for env in [root / ".env"] + list(root.glob("*/.env")):
        if env.exists():
            for line in env.read_text(errors="ignore").splitlines():
                k, _, v = line.partition("=")
                k = k.strip().upper()
                if "TRAKT" in k and "CLIENT_ID" in k and v.strip():
                    client = v.strip().strip("'\"")
                if "TRAKT" in k and "ACCESS_TOKEN" in k and v.strip():
                    _trakt_files["env_token"] = v.strip().strip("'\"")
    skip = {"node_modules", ".git", "venv", ".venv", "__pycache__"}
    for p in sorted(root.rglob("*.json"), key=lambda x: len(x.parts)):
        if any(part in skip for part in p.parts) or p.stat().st_size > 200_000:
            continue
        try:
            j = json.loads(p.read_text(errors="ignore"))
        except Exception:
            continue
        if isinstance(j, dict) and "access_token" in j and ("trakt" in str(p).lower() or "refresh_token" in j):
            token_file = p
            break
    _trakt_files.update(client=client, token_file=token_file)


def trakt_creds():
    t = CFG.get("trakt", {})
    if t.get("client_id") and t.get("access_token"):
        return t["client_id"], t["access_token"]
    if "client" not in _trakt_files:
        _scan_addon_for_trakt()
    token = None
    f = _trakt_files.get("token_file")
    if f and Path(f).exists():
        token = json.loads(Path(f).read_text()).get("access_token")
    token = token or _trakt_files.get("env_token")
    return _trakt_files.get("client") or t.get("client_id"), token


def _trakt(path):
    cid, tok = trakt_creds()
    if not cid or not tok:
        raise RuntimeError("no Trakt login found (see trakt in config.json)")
    req = urllib.request.Request("https://api.trakt.tv" + path, headers={
        "Content-Type": "application/json", "trakt-api-version": "2", "trakt-api-key": cid,
        "Authorization": "Bearer " + tok, "User-Agent": "ember-feed/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def _progress():
    """Films and episodes you stopped part-way through, newest first, keyed by IMDb id."""
    out = {}
    for it in _trakt("/sync/playback?extended=full&limit=60"):
        pct = float(it.get("progress") or 0)
        if pct <= 1 or pct >= 95:
            continue
        if it.get("type") == "episode":
            show, ep = it.get("show", {}), it.get("episode", {})
            imdb = (show.get("ids") or {}).get("imdb")
            info = {"type": "series", "season": ep.get("season"), "episode": ep.get("number"),
                    "episodeTitle": ep.get("title") or "", "runtime": ep.get("runtime") or show.get("runtime")}
        else:
            mv = it.get("movie", {})
            imdb = (mv.get("ids") or {}).get("imdb")
            info = {"type": "movie", "runtime": mv.get("runtime")}
        if not imdb or imdb in out:
            continue  # the list is newest first: keep the latest
        info.update(progress=round(pct, 1), pausedAt=it.get("paused_at"), ago=_ago(it.get("paused_at")))
        out[imdb] = info
    return out


def progress():
    try:
        return {"items": cached("progress", 120, _progress)}
    except Exception as e:
        return {"items": {}, "error": str(e)}


def next_episode(imdb):
    """The next episode of a show you're watching (when you're not part-way through one)."""
    def _n():
        p = _trakt(f"/shows/{imdb}/progress/watched?hidden=false&specials=false")
        ne = p.get("next_episode") or {}
        if not ne:
            return {}
        return {"season": ne.get("season"), "episode": ne.get("number"), "episodeTitle": ne.get("title") or ""}
    try:
        return cached("next:" + imdb, 600, _n)
    except Exception as e:
        return {"error": str(e)}

# ------------------------------------------------------------------ alerts: calendar and reminder pop-ups on the TV


def _reminders():
    """Apple Reminders that are due, over iCloud CalDAV. Off unless config.json has
    "reminders": {"username": "you@icloud.com", "app_password": "xxxx-xxxx-xxxx-xxxx"}  (an app-specific password)."""
    r = CFG.get("reminders", {})
    if not r.get("username") or not r.get("app_password"):
        return []
    import caldav
    client = caldav.DAVClient(url=r.get("url", "https://caldav.icloud.com"),
                              username=r["username"], password=r["app_password"])
    wanted = [x.lower() for x in r.get("lists", [])]
    out = []
    for cal in client.principal().calendars():
        try:
            if "VTODO" not in (cal.get_supported_components() or []):
                continue
        except Exception:
            pass
        name = str(cal.name or "")
        if wanted and name.lower() not in wanted:
            continue
        try:
            todos = cal.todos(include_completed=False)
        except Exception:
            continue
        for t in todos:
            comp = t.icalendar_component
            due = comp.get("DUE")
            if not due:
                continue
            d = due.dt
            if not isinstance(d, datetime):
                d = datetime.combine(d, datetime.min.time(), TZ).replace(hour=r.get("all_day_hour", 9))
            elif d.tzinfo is None:
                d = d.replace(tzinfo=TZ)
            out.append({"title": str(comp.get("SUMMARY", "")).strip() or "Reminder",
                        "due": d.astimezone(TZ).isoformat(), "list": name})
    return out


def alerts():
    """Pop-ups for everything with a time: 12 hours before, 1 hour before, then 30 minutes before, each more urgent.
    A shift starting before midday gets its first pop-up 9 hours before instead, saying when you need to be up
    (1 hour before the shift). Each stage carries the window it's valid for, so if the TV was off when it was due
    it still shows when the TV comes on - until the next stage takes over."""
    a = CFG.get("alerts", {})
    stages = a.get("stages_minutes", [720, 60, 30])
    early_first = a.get("early_shift_first_minutes", 540)
    wake_before = a.get("wake_minutes_before_shift", 60)
    early_before_hour = a.get("early_shift_before_hour", 12)
    now = datetime.now(TZ)
    horizon = now + timedelta(minutes=70)

    items = []
    for e in cached("events", 300, _fetch_events):
        if not e.get("allDay"):
            items.append(("cal", e["title"], datetime.fromisoformat(e["start"]), bool(e.get("shift")),
                          (e.get("location") or "").splitlines()[0][:40] if e.get("location") else ""))
    try:
        for r in cached("reminders", 300, _reminders):
            items.append(("rem", r["title"], datetime.fromisoformat(r["due"]), False, ""))
    except Exception:
        pass

    out = []
    for kind, title, start, shift, where in items:
        if start <= now:
            continue
        early = shift and start.hour < early_before_hour
        mins = sorted([early_first] + [m for m in stages if m < early_first] if early else stages, reverse=True)
        times = [start - timedelta(minutes=m) for m in mins]
        for i, (m, at) in enumerate(zip(mins, times)):
            until = times[i + 1] if i + 1 < len(times) else start
            if until <= now or at > horizon:
                continue
            item = {"id": f"{kind}|{title}|{start.isoformat()}|{m}", "at": at.isoformat(), "until": until.isoformat(),
                    "start": start.isoformat(), "title": title, "where": where, "kind": kind,
                    "shift": shift, "level": min(3, i + 1)}  # 1 calm, 2 firmer, 3 urgent
            if early and i == 0:
                item["wake"] = (start - timedelta(minutes=wake_before)).isoformat()
            out.append(item)
    out.sort(key=lambda x: x["at"])
    return {"now": now.isoformat(), "alerts": out}


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
            elif path == "/cats":
                try:
                    self._json({"cats": cached("cats", 15, _cats)})
                except Exception:
                    self._json({"cats": []})
            elif path == "/night":
                self._json(night())
            elif path == "/alerts":
                self._json(alerts())
            elif path == "/weather":
                self._json(weather())
            elif path == "/progress":
                self._json(progress())
            elif path.startswith("/next/"):
                imdb = path[len("/next/"):]
                self._json(next_episode(imdb) if imdb.startswith("tt") and imdb[2:].isdigit() else {})
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
