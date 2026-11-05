#!/usr/bin/env python3
"""
ember-feed: the small service on lucapi that feeds Ember on the TV.

  GET /screensaver  -> calendar events, Pi service status, Pi health, photo list
  GET /status       -> cards for the projects strip on Ember's Apps page
  GET /photo/<name> -> a photo from your photos folder
  GET /cats         -> just the cats, in or out (polled often, for the pop-ups)
  GET /night        -> the next shift within 36 hours (the dimmer starts earlier before early shifts)
  GET /weather      -> current weather and today's sunrise/sunset (Open-Meteo)
  GET /progress     -> where you are in each title, newest first (the progress store, merged with Trakt)
  GET /progress/<imdb> -> every saved position for one title (episode lists)
  POST /progress/report -> a player reports where you are (Ember TV, Ember PC); passed on to Trakt
  GET /watchlist, POST /watchlist {imdb, type, add} -> your Trakt watchlist (what your Watchlist rows show)
  GET /cinemas -> films in UK cinemas now (for the "In cinemas" label)
  POST /release {ids} -> which of those are only in cinemas, or not out yet (labels on posters)
  GET/POST /settings/shared -> settings Ember PC shares with Ember TV (the AIOStreams link)
  GET /watched -> {imdb: "done" | "partial"} for the badges on posters
  GET /similar/<movie|series>/<imdb> -> "You may also like" (TMDB recommendations)
  GET /trailer/<movie|series>/<imdb> -> {"yt": YouTube id} of its trailer (TMDB), for "Watch trailer"
  GET /trailer/<movie|series>/<imdb>/play -> {"url": a stream of that trailer Ember's own player can play} (needs yt-dlp)
  POST /progress/watched -> mark a film or episodes (a season, a whole show) watched or unwatched; also on Trakt
  GET /next/<imdb>  -> the next episode of a show (Trakt)
  GET /alerts       -> calendar and reminder pop-ups (12h, 1h, 30 min before; early shifts 9h before)
  GET /pick/<type>/<id>?aio=&quality=4k&runtime=  -> streams best first, the top few tested for speed
  POST /pick/failed -> a player says a stream errored or stalled (it's pushed down next time)
  GET /upcoming     -> new and upcoming episodes of your shows (Trakt calendar)
  GET /wrapped?year= -> your year in watching (Trakt history)
  POST /match/new, GET /m/<code> (phones), GET /match/<code>, /match/<code>/qr.png -> "What shall we watch?"
  GET /picks/<code>/manifest.json -> "Ember picks", the picker as a Stremio addon for Omni and friends
  GET /browse/tiles -> your lists sorted into boxes (tiles), Home rows and the hero list
  GET /browse/cat/<tile>?type=&skip= -> a tile's titles; /browse/<kind>/<id> -> the old TMDB tiles
  GET /health       -> "ok"

Config lives in config.json next to this file (see config.example.json).
Needs: python3 -m pip install icalendar recurring-ical-events
"""
import hashlib
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


def _trakt(path, body=None, method=None):
    cid, tok = trakt_creds()
    if not cid or not tok:
        raise RuntimeError("no Trakt login found (see trakt in config.json)")
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request("https://api.trakt.tv" + path, data=data, method=method or ("POST" if data else "GET"), headers={
        "Content-Type": "application/json", "trakt-api-version": "2", "trakt-api-key": cid,
        "Authorization": "Bearer " + tok, "User-Agent": "ember-feed/1.0"})
    with urllib.request.urlopen(req, timeout=15) as r:
        raw = r.read()
        return json.loads(raw) if raw else {}


def _trakt_playback():
    """Films and episodes Trakt has a part-way point for (Omni writes these), newest first."""
    out = []
    for it in _trakt("/sync/playback?extended=full&limit=100"):
        pct = float(it.get("progress") or 0)
        if it.get("type") == "episode":
            show, ep = it.get("show", {}), it.get("episode", {})
            imdb = (show.get("ids") or {}).get("imdb")
            item = {"type": "series", "season": ep.get("season"), "episode": ep.get("number"),
                    "episodeTitle": ep.get("title") or "", "runtime": ep.get("runtime") or show.get("runtime")}
        else:
            mv = it.get("movie", {})
            imdb = (mv.get("ids") or {}).get("imdb")
            item = {"type": "movie", "runtime": mv.get("runtime")}
        if imdb:
            item.update(imdb=imdb, progress=pct, pausedAt=it.get("paused_at"))
            out.append(item)
    return out

# ------------------------------------------------------------------ the progress store
# Your own record of where you are in everything, to the second, kept on the Pi. Ember TV and Ember PC report to it
# while you watch; it also keeps copies of what Omni tells Trakt. Unlike Trakt it never throws a position away at 80%.

import sqlite3

DB_PATH = Path(os.environ.get("EMBER_PROGRESS_DB", HERE / "progress.db"))
_db_lock = threading.Lock()
_db = None
FINISHED_AT = CFG.get("progress", {}).get("finished_percent", 97)


def db():
    global _db
    if _db is None:
        _db = sqlite3.connect(str(DB_PATH), check_same_thread=False)
        _db.execute("""CREATE TABLE IF NOT EXISTS positions (
            key TEXT PRIMARY KEY,          -- movie:tt123 or series:tt123:2:6
            imdb TEXT NOT NULL, type TEXT NOT NULL, season INTEGER, episode INTEGER,
            position REAL NOT NULL,        -- seconds in
            duration REAL,                 -- seconds long (if known)
            percent REAL NOT NULL,
            updated INTEGER NOT NULL,      -- unix seconds
            device TEXT, source TEXT,      -- source: ember (our players) or trakt (Omni via Trakt)
            finished INTEGER NOT NULL DEFAULT 0,
            trakt_watched INTEGER NOT NULL DEFAULT 0,
            episode_title TEXT)""")
        _db.execute("CREATE INDEX IF NOT EXISTS positions_imdb ON positions(imdb, updated)")
        _db.commit()
    return _db


def _key(imdb, typ, season=None, episode=None):
    return f"series:{imdb}:{int(season)}:{int(episode)}" if typ == "series" and season is not None else f"movie:{imdb}"


def _row(r):
    cols = ["key", "imdb", "type", "season", "episode", "position", "duration", "percent", "updated", "device",
            "source", "finished", "trakt_watched", "episode_title"]
    return dict(zip(cols, r))


def _upsert(d):
    with _db_lock:
        db().execute("""INSERT INTO positions (key, imdb, type, season, episode, position, duration, percent, updated,
                            device, source, finished, trakt_watched, episode_title)
                        VALUES (:key,:imdb,:type,:season,:episode,:position,:duration,:percent,:updated,:device,
                                :source,:finished,:trakt_watched,:episode_title)
                        ON CONFLICT(key) DO UPDATE SET position=excluded.position,
                            duration=COALESCE(excluded.duration, positions.duration), percent=excluded.percent,
                            updated=excluded.updated, device=excluded.device, source=excluded.source,
                            finished=excluded.finished, trakt_watched=excluded.trakt_watched,
                            episode_title=COALESCE(NULLIF(excluded.episode_title,''), positions.episode_title)""", d)
        db().commit()


def _get(key):
    with _db_lock:
        r = db().execute("SELECT * FROM positions WHERE key=?", (key,)).fetchone()
    return _row(r) if r else None


def _iso_to_epoch(s):
    try:
        return int(datetime.fromisoformat(str(s).replace("Z", "+00:00")).timestamp())
    except Exception:
        return int(time.time())


def report(body):
    """A player says where you are. body: imdb, type (movie/series), season, episode, position (s), duration (s),
    device, state (playing / paused / stopped), finished (optional: the player saw the credits)."""
    imdb = str(body.get("imdb", ""))
    typ = "series" if body.get("type") == "series" else "movie"
    if not (imdb.startswith("tt") and imdb[2:].isdigit()):
        raise ValueError("imdb must look like tt1234567")
    season, episode = body.get("season"), body.get("episode")
    if typ == "series" and (season is None or episode is None):
        raise ValueError("series needs season and episode")
    pos = max(0.0, float(body.get("position", 0)))
    dur = float(body["duration"]) if body.get("duration") else None
    pct = min(100.0, pos / dur * 100) if dur else float(body.get("percent", 0))
    state = body.get("state", "playing")
    finished = bool(body.get("finished")) or pct >= FINISHED_AT
    d = {"key": _key(imdb, typ, season, episode), "imdb": imdb, "type": typ,
         "season": int(season) if typ == "series" else None, "episode": int(episode) if typ == "series" else None,
         "position": pos, "duration": dur, "percent": round(pct, 2), "updated": int(time.time()),
         "device": str(body.get("device", ""))[:40], "source": "ember", "finished": int(finished),
         "trakt_watched": 0, "episode_title": str(body.get("episodeTitle", ""))[:120]}
    _upsert(d)
    print(f"[ember-feed] report {d['key']} {state} {round(pos)}s from {d['device']}", flush=True)
    with _cache_lock:
        _cache.pop("progress", None)
    # Tell Trakt too (so Omni knows), but only when something changes - not on every tick.
    if state in ("playing", "paused", "stopped") and body.get("tell_trakt", True):
        prev_state = _last_state.get(d["key"])
        if state != prev_state or finished:
            _last_state[d["key"]] = "stopped" if finished else state
            verb = {"playing": "start", "paused": "pause", "stopped": "stop"}[state]
            if finished:
                verb = "stop"
                with _cache_lock:
                    _cache.pop("watched", None)  # the poster badges catch up
            threading.Thread(target=_scrobble, args=(verb, d, max(pct, 80.0) if finished else pct), daemon=True).start()
    return {"ok": True, "finished": finished, "percent": d["percent"]}


_last_state = {}


def _scrobble(verb, d, pct):
    target = ({"show": {"ids": {"imdb": d["imdb"]}}, "episode": {"season": d["season"], "number": d["episode"]}}
              if d["type"] == "series" else {"movie": {"ids": {"imdb": d["imdb"]}}})
    try:
        _trakt(f"/scrobble/{verb}", dict(target, progress=round(pct, 2), app_version="ember-1"))
    except urllib.error.HTTPError as e:
        if e.code == 409:
            return  # Trakt already has this one as watched (just now): nothing to do
        print(f"[ember-feed] Trakt scrobble {verb} failed: {e}", flush=True)
    except Exception as e:
        print(f"[ember-feed] Trakt scrobble {verb} failed: {e}", flush=True)


def snapshot_trakt():
    """Copies Trakt's part-way points (from Omni) into the store. If one vanishes because Trakt marked it watched
    while the copy was past 80%, the copy is kept as resumable and flagged, since that's the case Trakt loses."""
    items = _trakt_playback()
    seen = set()
    for it in items:
        k = _key(it["imdb"], it["type"], it.get("season"), it.get("episode"))
        seen.add(k)
        updated = _iso_to_epoch(it.get("pausedAt"))
        cur = _get(k)
        if cur and (cur["updated"] >= updated or (cur["source"] == "ember" and updated - cur["updated"] < 300)):
            continue  # ours is newer, or this is just our own report echoed back by Trakt
        rt = it.get("runtime")
        dur = float(rt) * 60 if rt else (cur or {}).get("duration")
        pct = float(it["progress"])
        _upsert({"key": k, "imdb": it["imdb"], "type": it["type"], "season": it.get("season"),
                 "episode": it.get("episode"), "position": (dur or 0) * pct / 100, "duration": dur,
                 "percent": round(pct, 2), "updated": updated, "device": "Trakt (Omni)", "source": "trakt",
                 "finished": int(pct >= FINISHED_AT), "trakt_watched": 0,
                 "episode_title": it.get("episodeTitle", "")})
    # Copies from Trakt that Trakt no longer has.
    with _db_lock:
        gone = [_row(r) for r in db().execute(
            "SELECT * FROM positions WHERE source='trakt' AND finished=0 AND trakt_watched=0").fetchall()]
    for g in gone:
        if g["key"] in seen:
            continue
        if g["percent"] >= 80:
            g.update(trakt_watched=1)  # Trakt counted it as watched; keep where you were
        else:
            g.update(finished=1)       # finished (or cleared) in Omni
        _upsert(g)
    with _cache_lock:
        _cache.pop("progress", None)


def _snapshot_loop():
    while True:
        try:
            snapshot_trakt()
        except Exception as e:
            print(f"[ember-feed] Trakt snapshot failed: {e}", flush=True)
        time.sleep(CFG.get("progress", {}).get("trakt_poll_seconds", 180))


def _dismissed():
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS dismissed (imdb TEXT PRIMARY KEY, at INTEGER)")
        return dict(db().execute("SELECT imdb, at FROM dismissed").fetchall())


def dismiss(body):
    """Take a title off Continue watching everywhere: the Pi's resume points, Trakt's (so Omni and Odin too), and the
    addon's 'pick up' row (hidden until you watch it again)."""
    imdb = str(body.get("imdb", ""))
    if not (imdb.startswith("tt") and imdb[2:].isdigit()):
        raise ValueError("imdb must look like tt1234567")
    now = int(time.time())
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS dismissed (imdb TEXT PRIMARY KEY, at INTEGER)")
        db().execute("DELETE FROM positions WHERE imdb=? AND finished=0", (imdb,))
        db().execute("INSERT OR REPLACE INTO dismissed VALUES (?, ?)", (imdb, now))
        db().commit()
    with _cache_lock:
        _cache.pop("progress", None)

    def clear_trakt():
        try:
            for it in _trakt("/sync/playback?limit=200"):
                ids = ((it.get("show") or it.get("movie") or {}).get("ids") or {})
                if ids.get("imdb") == imdb and it.get("id"):
                    _trakt(f"/sync/playback/{it['id']}", method="DELETE")
        except Exception as e:
            print(f"[ember-feed] couldn't clear Trakt resume point for {imdb}: {e}", flush=True)
    threading.Thread(target=clear_trakt, daemon=True).start()
    print(f"[ember-feed] removed {imdb} from continue watching", flush=True)
    return {"ok": True}


SHARED_PATH = HERE / "shared_settings.json"


def shared_settings(body=None):
    """Settings Ember PC shares with Ember TV, so they needn't be typed with a remote: {"aio": your AIOStreams link}.
    Kept on the Pi only (outside access to the Pi needs the api_key, as everything else)."""
    try:
        cur = json.loads(SHARED_PATH.read_text()) if SHARED_PATH.exists() else {}
    except Exception:
        cur = {}
    if body is not None:
        aio = str(body.get("aio", "")).strip()
        if aio.startswith("http") and len(aio) < 4000:
            cur["aio"] = aio
            SHARED_PATH.write_text(json.dumps(cur))
            try:
                os.chmod(SHARED_PATH, 0o600)
            except Exception:
                pass
    return cur


def _watchlist_ids():
    ids = set()
    for kind in ("movies", "shows"):
        for it in _trakt(f"/sync/watchlist/{kind}"):
            i = (((it.get("movie") or it.get("show")) or {}).get("ids") or {}).get("imdb")
            if i:
                ids.add(i)
    return sorted(ids)


def watchlist():
    """What's on your Trakt watchlist (which your Watchlist rows come from): {"items": [imdb, ...]}."""
    if not all(trakt_creds()):
        return {"items": [], "error": "no Trakt login"}
    try:
        return {"items": cached("watchlist", 300, _watchlist_ids)}
    except Exception as e:
        return {"items": [], "error": str(e)}


def watchlist_set(body):
    """Add a film or show to your Trakt watchlist, or take it off. body: {"imdb", "type": movie|series, "add": true|false}"""
    imdb = str(body.get("imdb", ""))
    if not (imdb.startswith("tt") and imdb[2:].isdigit()):
        raise ValueError("imdb must look like tt1234567")
    if not all(trakt_creds()):
        raise RuntimeError("no Trakt login on lucapi")
    add = body.get("add", True) is not False
    item = {"ids": {"imdb": imdb}}
    payload = {"shows": [item]} if body.get("type") == "series" else {"movies": [item]}
    _trakt("/sync/watchlist" if add else "/sync/watchlist/remove", payload)
    with _cache_lock:
        _cache.pop("watchlist", None)
    print(f"[ember-feed] Trakt watchlist: {imdb} {'added' if add else 'removed'}", flush=True)
    return {"ok": True, "on": add}


def _watched_status():
    """What you've watched, for the badges on posters: {imdb: "done" | "partial"}.
    Films: done once finished. Shows: done when you've seen every aired episode, partial if you've started.
    From your Trakt history (Omni, Odin, everything) plus the Pi's own record."""
    out = {}
    with _db_lock:
        rows = db().execute("SELECT imdb, type, finished, percent FROM positions").fetchall()
    for imdb, typ, fin, pct in rows:
        if typ == "movie":
            if fin:
                out[imdb] = "done"
            elif pct >= 1:
                out.setdefault(imdb, "partial")
        else:
            out.setdefault(imdb, "partial")
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS watched_all (imdb TEXT PRIMARY KEY, at INTEGER)")
        marked_all = dict(db().execute("SELECT imdb, at FROM watched_all").fetchall())
    for i in marked_all:
        out[i] = "done"
    if all(trakt_creds()):
        try:
            for it in _trakt("/sync/watched/movies"):
                i = ((it.get("movie") or {}).get("ids") or {}).get("imdb")
                if i:
                    out[i] = "done"
            for it in _trakt("/sync/watched/shows?extended=full"):
                show = it.get("show") or {}
                i = (show.get("ids") or {}).get("imdb")
                if not i:
                    continue
                seen = sum(len(se.get("episodes") or []) for se in (it.get("seasons") or []) if (se.get("number") or 0) > 0)
                aired = show.get("aired_episodes") or 0
                if aired and seen >= aired:
                    out[i] = "done"
                elif i in marked_all and time.time() - marked_all[i] < 6 * 3600:
                    out[i] = "done"  # just marked: Trakt may still be catching up
                else:
                    out[i] = "partial"
        except Exception as e:
            print(f"[ember-feed] watched list from Trakt failed: {e}", flush=True)
    return out


def watched_status():
    try:
        return {"items": cached("watched", 900, _watched_status)}
    except Exception as e:
        return {"items": {}, "error": str(e)}


def mark_watched(body):
    """Mark a film, or any episodes of a show (one, a season, the lot), as watched or not - for things you saw
    before Ember. Saved on the Pi (so Ember skips them) and in your Trakt history (so Omni, Odin and Up Next agree).
    body: {"imdb": "tt..", "type": "movie"|"series", "episodes": [[season, episode], ...], "watched": true|false,
           "all": true when it's the whole show (Trakt then marks every episode on its own list)}"""
    imdb = str(body.get("imdb", ""))
    if not (imdb.startswith("tt") and imdb[2:].isdigit()):
        raise ValueError("imdb must look like tt1234567")
    typ = "series" if body.get("type") == "series" else "movie"
    watched = body.get("watched", True) is not False
    whole = bool(body.get("all"))
    eps = []
    if typ == "series":
        for pair in (body.get("episodes") or [])[:3000]:
            s, e = int(pair[0]), int(pair[1])
            if s > 0 and e > 0:
                eps.append((s, e))
        if not eps:
            raise ValueError("no episodes given")
    now = int(time.time())
    keys = [_key(imdb, typ, s, e) for s, e in eps] if typ == "series" else [_key(imdb, "movie", None, None)]
    if watched:
        for k, se in zip(keys, eps or [(None, None)]):
            old = _get(k) or {}
            _upsert({"key": k, "imdb": imdb, "type": typ, "season": se[0], "episode": se[1],
                     "position": old.get("duration") or old.get("position") or 0, "duration": old.get("duration"),
                     "percent": 100.0, "updated": now, "device": "Marked as watched", "source": "ember",
                     "finished": 1, "trakt_watched": 1, "episode_title": old.get("episode_title") or ""})
    else:
        with _db_lock:
            db().executemany("DELETE FROM positions WHERE key=?", [(k,) for k in keys])
            db().commit()
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS watched_all (imdb TEXT PRIMARY KEY, at INTEGER)")
        if typ == "series" and whole and watched:
            db().execute("INSERT OR REPLACE INTO watched_all VALUES (?, ?)", (imdb, now))
        elif typ == "series" and (not watched or not whole):
            db().execute("DELETE FROM watched_all WHERE imdb=?", (imdb,))
        db().commit()
    with _cache_lock:
        _cache.pop("progress", None)
        _cache.pop("next:" + imdb, None)
        _cache.pop("watched", None)

    def to_trakt():
        try:
            if typ == "series" and whole:
                payload = {"shows": [{"ids": {"imdb": imdb}}]}  # the whole show, by Trakt's own episode list
            elif typ == "series":
                seasons = {}
                for s, e in eps:
                    seasons.setdefault(s, []).append({"number": e})
                item = {"ids": {"imdb": imdb}, "seasons": [{"number": s, "episodes": v} for s, v in sorted(seasons.items())]}
                payload = {"shows": [item]}
            else:
                payload = {"movies": [{"ids": {"imdb": imdb}}]}
            _trakt("/sync/history" if watched else "/sync/history/remove", payload)
            with _cache_lock:
                _cache.pop("watched", None)  # look again now Trakt has it
            print(f"[ember-feed] Trakt: {imdb} {'whole show' if whole else str(len(keys)) + ' item(s)'} marked {'watched' if watched else 'unwatched'}", flush=True)
        except Exception as e:
            print(f"[ember-feed] Trakt mark {'watched' if watched else 'unwatched'} failed: {e}", flush=True)
    if all(trakt_creds()):
        threading.Thread(target=to_trakt, daemon=True).start()
    return {"ok": True, "watched": watched, "count": len(keys)}


def _progress():
    """Where you are in each title, newest first, keyed by IMDb id: the most recent unfinished position on any device."""
    with _db_lock:
        rows = [_row(r) for r in db().execute(
            "SELECT * FROM positions ORDER BY updated DESC").fetchall()]
    gone = _dismissed()
    out, done = {}, set()
    for r in rows:
        if r["imdb"] in out or r["imdb"] in done:
            continue
        if gone.get(r["imdb"], 0) >= r["updated"]:
            continue  # you removed it; it comes back if you watch it again
        if r["finished"]:
            # the latest thing for this title is finished: nothing to resume (the continue row shows the next episode)
            done.add(r["imdb"])
            continue
        if r["percent"] < 1:
            continue
        item = {"type": r["type"], "progress": r["percent"], "position": round(r["position"]),
                "duration": round(r["duration"]) if r["duration"] else None,
                "runtime": round(r["duration"] / 60) if r["duration"] else None,
                "device": r["device"], "source": r["source"], "traktWatched": bool(r["trakt_watched"]),
                "pausedAt": datetime.fromtimestamp(r["updated"], TZ).isoformat(),
                "ago": _ago(r["updated"])}
        if r["type"] == "series":
            item.update(season=r["season"], episode=r["episode"], episodeTitle=r["episode_title"] or "")
        out[r["imdb"]] = item
    return out


def progress():
    try:
        return {"items": cached("progress", 30, _progress)}
    except Exception as e:
        return {"items": {}, "error": str(e)}


def title_positions(imdb):
    """Every episode (or the film) of one title: for the episode list on a title page."""
    with _db_lock:
        rows = [_row(r) for r in db().execute(
            "SELECT * FROM positions WHERE imdb=? ORDER BY season, episode", (imdb,)).fetchall()]
    return {"imdb": imdb, "positions": [
        {"season": r["season"], "episode": r["episode"], "position": round(r["position"]),
         "duration": round(r["duration"]) if r["duration"] else None, "percent": r["percent"],
         "finished": bool(r["finished"]), "device": r["device"], "ago": _ago(r["updated"])} for r in rows]}


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
    # New episodes of your shows, once, when they come out (or when the TV next comes on that day).
    try:
        for ep in upcoming(days=2, back=1)["episodes"]:
            at = datetime.fromisoformat(ep["airs"])
            until = at + timedelta(hours=14)
            if until <= now or at > horizon:
                continue
            out.append({"id": f"ep|{ep['imdb']}|{ep['season']}|{ep['episode']}", "at": at.isoformat(), "until": until.isoformat(),
                        "start": at.isoformat(), "title": f"New episode out: {ep['show']} S{ep['season']} E{ep['episode']}"
                        + (f" \u00b7 {ep['title']}" if ep.get("title") else ""), "where": "", "kind": "ep", "shift": False, "level": 1})
    except Exception as e:
        print(f"[ember-feed] episode alerts skipped: {e}", flush=True)
    out.sort(key=lambda x: x["at"])
    return {"now": now.isoformat(), "alerts": out}


# ------------------------------------------------------------------ the stream picker
# Scores every stream AIOStreams offers, tests the best few (does the link answer, how fast does it come in,
# is that comfortably faster than the file needs), and returns them best first. Players play the first one and,
# if it errors or stalls, tell us (/pick/failed) and move on to the next.

import re
import concurrent.futures

PICK = CFG.get("picker", {})
_RES = [(re.compile(r"\b(2160p|4k|uhd)\b", re.I), 2160), (re.compile(r"\b1440p\b", re.I), 1440),
        (re.compile(r"\b1080p\b", re.I), 1080), (re.compile(r"\b720p\b", re.I), 720), (re.compile(r"\b(480p|576p|sd)\b", re.I), 480)]
_BAD = re.compile(r"\b(cam|camrip|hdcam|ts|telesync|hdts|tc|telecine|scr|screener|dvdscr|workprint)\b", re.I)
_SIZE = re.compile(r"(\d+(?:\.\d+)?)\s?(GB|GiB|MB|MiB)\b", re.I)


def _fingerprint(text):
    """The release group (the bit after the last dash in a release name), used to remember which ones let you down."""
    for line in str(text).lower().split("\n"):
        line = re.sub(r"\.(mkv|mp4|avi|m2ts)$", "", line.strip())
        if "." in line or " " not in line:
            m = re.search(r"-([a-z0-9]{2,15})$", line)
            if m and not re.fullmatch(r"\d+|dl|web|hd|sd", m.group(1)):
                return m.group(1)
    return ""


def _failures():
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS stream_failures (fp TEXT PRIMARY KEY, n INTEGER, last INTEGER)")
        rows = db().execute("SELECT fp, n, last FROM stream_failures").fetchall()
    week = time.time() - 14 * 86400
    return {fp: n for fp, n, last in rows if last > week}


def stream_failed(body):
    fp = _fingerprint(str(body.get("text", "")))
    if not fp:
        return {"ok": False}
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS stream_failures (fp TEXT PRIMARY KEY, n INTEGER, last INTEGER)")
        db().execute("INSERT INTO stream_failures VALUES (?, 1, ?) ON CONFLICT(fp) DO UPDATE SET n = n + 1, last = excluded.last",
                     (fp, int(time.time())))
        db().commit()
    print(f"[ember-feed] stream failed: {fp} ({body.get('why', '')})", flush=True)
    return {"ok": True, "fingerprint": fp}


def _score(s, want_res, runtime_min, passthrough, fails):
    text = f"{s.get('name', '')}\n{s.get('title') or s.get('description') or ''}\n{(s.get('behaviorHints') or {}).get('filename', '')}"
    why, score = [], 0.0
    if _BAD.search(text):
        return -1e9, ["cam / screener"], text, None
    res = next((r for rx, r in _RES if rx.search(text)), 0)
    if not res and re.search(r"\bHD\b", text):
        res = 1080
    # Resolution: as close to what you want as possible, never above it.
    if res > want_res:
        score -= 400; why.append(f"{res}p is above your {want_res}p limit")
    elif res:
        score += {2160: 300, 1440: 240, 1080: 220, 720: 120, 480: 30}.get(res, 0) - (0 if res == want_res else 40)
    cached = bool(re.search(r"⚡|\[(AD|RD|PM|TB|DL|ED|OC)\+?\]|\bcached\b", text, re.I))
    if cached:
        score += 500; why.append("cached")
    elif re.search(r"⏳|\[(AD|RD|PM|TB|DL)\s*download\]|uncached|\bp2p\b", text, re.I):
        score -= 600; why.append("not cached")
    if re.search(r"\b(dv|dovi|dolby ?vision)\b", text, re.I):
        score += 40; why.append("Dolby Vision")
    elif re.search(r"\bhdr", text, re.I):
        score += 35; why.append("HDR")
    if re.search(r"\batmos\b", text, re.I):
        score += 30
    if re.search(r"\b(ddp|dd\+|e-?ac-?3)", text, re.I):
        score += 20
    if re.search(r"true ?hd|dts", text, re.I) and not passthrough:
        score -= 10  # fine on PC, decoded on the Chromecast
    if re.search(r"\b(english|eng)\b|🇬🇧|🇺🇸", text, re.I):
        score += 25
    elif re.search(r"\b(italian|spanish|french|german|portuguese|russian|hindi|latino)\b", text, re.I) and not re.search(r"\b(multi|dual)\b", text, re.I):
        score -= 120; why.append("not English")
    if re.search(r"\bremux\b", text, re.I):
        score -= 30  # huge: buffers more easily
    m = _SIZE.search(text)
    size_gb = (float(m.group(1)) / (1024 if m.group(2).upper().startswith("M") else 1)) if m else None
    need = None
    if size_gb and runtime_min:
        need = size_gb * 8 * 1024 / (runtime_min * 60)  # average Mbit/s the file needs
        if need > PICK.get("max_mbps", 80):
            score -= 200; why.append(f"very heavy ({need:.0f} Mbit/s)")
    f = fails.get(_fingerprint(text), 0)
    if f:
        score -= 150 * f; why.append(f"failed {f}x recently")
    return score, why, text, need


def _probe(url, timeout=6.0, want_bytes=6 * 1024 * 1024, max_s=2.5):
    """Asks for the start of the file and times it. Returns ok, time to first byte, Mbit/s."""
    t0 = time.time()
    try:
        req = urllib.request.Request(url, headers={"Range": f"bytes=0-{want_bytes - 1}", "User-Agent": "ember-feed/1.0"})
        with urllib.request.urlopen(req, timeout=timeout) as r:
            if r.status not in (200, 206):
                return {"ok": False, "why": f"HTTP {r.status}"}
            first = r.read(65536)
            ttfb = time.time() - t0
            got, t1 = len(first), time.time()
            while got < want_bytes and time.time() - t1 < max_s:
                chunk = r.read(262144)
                if not chunk:
                    break
                got += len(chunk)
            secs = max(0.05, time.time() - t1)
            ctype = r.headers.get("Content-Type", "")
        if got < 32768 or "text/html" in ctype:
            return {"ok": False, "why": "not a video"}
        return {"ok": True, "ttfb_ms": round(ttfb * 1000), "mbps": round((got - len(first)) * 8 / secs / 1e6, 1)}
    except Exception as e:
        return {"ok": False, "why": type(e).__name__}


def pick(typ, sid, aio, want="4k", runtime_min=None, passthrough=False, probe_top=4):
    aio = (aio or CFG.get("aiostreams_url", "")).strip()
    if not aio:
        raise ValueError("no AIOStreams link (pass ?aio= or set aiostreams_url in config.json)")
    base = re.sub(r"/manifest\.json.*$", "", aio)
    streams = [s for s in json.loads(http_get(f"{base}/stream/{typ}/{sid}.json", timeout=40)).get("streams", []) if s.get("url")]
    want_res = 2160 if str(want).lower() in ("4k", "2160", "2160p") else int(re.sub(r"\D", "", str(want)) or 1080)
    fails = _failures()
    scored = []
    for i, s in enumerate(streams):
        sc, why, text, need = _score(s, want_res, runtime_min, passthrough, fails)
        sc -= i * 0.5  # keep AIOStreams' own order as the tie-break
        scored.append({"i": i, "score": round(sc, 1), "why": why, "need_mbps": round(need, 1) if need else None, "url": s["url"],
                       "name": s.get("name", ""), "title": s.get("title") or s.get("description") or "",
                       "filename": (s.get("behaviorHints") or {}).get("filename", ""), "hints": s.get("behaviorHints") or {}})
    scored.sort(key=lambda x: -x["score"])
    top = [x for x in scored if x["score"] > -1e8][:probe_top]
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(top))) as ex:
        for x, pr in zip(top, ex.map(lambda x: _probe(x["url"]), top)):
            x["probe"] = pr
    # Best = highest score that answered and comes in comfortably faster than it plays.
    def verdict(x):
        pr = x.get("probe")
        if not pr:
            return 1  # untested: after the tested ones
        if not pr["ok"]:
            return 3
        if x["need_mbps"] and pr["mbps"] < x["need_mbps"] * 1.3:
            x["why"].append(f"line too slow for it ({pr['mbps']} vs {x['need_mbps']} Mbit/s)")
            return 2
        return 0
    ranked = sorted(scored, key=lambda x: (verdict(x), -x["score"]))
    ranked = [x for x in ranked if x["score"] > -1e8]
    print(f"[ember-feed] pick {typ} {sid}: {len(streams)} streams, best: {ranked[0]['filename'] or ranked[0]['title'][:60] if ranked else 'none'}", flush=True)
    return {"count": len(streams), "ranked": ranked[:12]}


# ------------------------------------------------------------------ new episodes (Trakt calendar)


def _calendar(start, days):
    return _trakt(f"/calendars/my/shows/{start}/{days}?extended=full")


def upcoming(days=7, back=1):
    """Episodes of shows you watch, from `back` days ago to `days` ahead: for the 'Out this week' row and alerts."""
    start = (datetime.now(TZ) - timedelta(days=back)).strftime("%Y-%m-%d")
    raw = cached(f"cal:{start}:{days + back}", 1800, lambda: _calendar(start, days + back))
    eps = []
    for it in raw or []:
        show, ep = it.get("show", {}), it.get("episode", {})
        imdb = (show.get("ids") or {}).get("imdb")
        if not imdb or not it.get("first_aired"):
            continue
        airs = datetime.fromisoformat(it["first_aired"].replace("Z", "+00:00")).astimezone(TZ)
        eps.append({"imdb": imdb, "show": show.get("title", ""), "season": ep.get("season"), "episode": ep.get("number"),
                    "title": ep.get("title") or "", "airs": airs.isoformat(), "day": airs.strftime("%a %-d %b"),
                    "time": airs.strftime("%H:%M"), "out": airs <= datetime.now(TZ)})
    eps.sort(key=lambda e: e["airs"])
    return {"episodes": eps}

# ------------------------------------------------------------------ your year in watching (Trakt history)


def _history(start_iso, end_iso):
    out, page = [], 1
    while page <= 40:
        batch = _trakt(f"/sync/history?start_at={start_iso}&end_at={end_iso}&extended=full&limit=250&page={page}")
        if not batch:
            break
        out += batch
        if len(batch) < 250:
            break
        page += 1
    return out


def wrapped(year=None):
    year = int(year or datetime.now(TZ).year)

    def build():
        items = _history(f"{year}-01-01T00:00:00.000Z", f"{year}-12-31T23:59:59.000Z")
        mins, shows, films, days, hours, weekdays = 0, {}, {}, {}, [0] * 24, [0] * 7
        for it in items:
            t = datetime.fromisoformat(it["watched_at"].replace("Z", "+00:00")).astimezone(TZ)
            if it.get("type") == "episode":
                rt = (it.get("episode") or {}).get("runtime") or (it.get("show") or {}).get("runtime") or 0
                sh = it.get("show") or {}
                k = (sh.get("ids") or {}).get("imdb") or sh.get("title")
                rec = shows.setdefault(k, {"imdb": (sh.get("ids") or {}).get("imdb"), "title": sh.get("title", ""), "episodes": 0, "minutes": 0})
                rec["episodes"] += 1; rec["minutes"] += rt
            else:
                mv = it.get("movie") or {}
                rt = mv.get("runtime") or 0
                k = (mv.get("ids") or {}).get("imdb") or mv.get("title")
                rec = films.setdefault(k, {"imdb": (mv.get("ids") or {}).get("imdb"), "title": mv.get("title", ""), "year": mv.get("year"), "plays": 0})
                rec["plays"] += 1
            mins += rt
            d = t.strftime("%Y-%m-%d")
            days[d] = days.get(d, 0) + rt
            hours[t.hour] += 1
            weekdays[t.weekday()] += 1
        names = ["Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays", "Sundays"]
        top_day = max(days.items(), key=lambda x: x[1]) if days else None
        top_hour = max(range(24), key=lambda h: hours[h]) if items else None
        return {
            "year": year, "plays": len(items), "hours": round(mins / 60), "days": round(mins / 1440, 1),
            "episodes": sum(s["episodes"] for s in shows.values()), "films": sum(f["plays"] for f in films.values()),
            "topShows": sorted(shows.values(), key=lambda s: -s["minutes"])[:10],
            "topFilms": sorted(films.values(), key=lambda f: -f["plays"])[:10],
            "rewatched": [f for f in sorted(films.values(), key=lambda f: -f["plays"]) if f["plays"] > 1][:5],
            "busiestDay": {"date": top_day[0], "hours": round(top_day[1] / 60, 1)} if top_day else None,
            "favouriteNight": names[max(range(7), key=lambda d: weekdays[d])] if items else None,
            "favouriteHour": top_hour, "byHour": hours, "byWeekday": weekdays,
            "byMonth": [round(sum(m for d, m in days.items() if int(d[5:7]) == mo) / 60) for mo in range(1, 13)],
        }
    return cached(f"wrapped:{year}", 6 * 3600, build)

# ------------------------------------------------------------------ "What shall we watch?" swipe match
# The TV or PC starts a session and shows a QR code; phones open /m/<code>, swipe the same deck, and anything
# everyone liked is a match. Sessions live in memory for 3 hours.

_matches = {}
_match_lock = threading.Lock()


def _deck():
    cards, seen = [], set()
    try:
        man = json.loads(http_get(CFG["addon_upstream"].rstrip("/") + "/manifest.json", timeout=15))
        cats = [c for c in man.get("catalogs", []) if not any(x.get("isRequired") for x in c.get("extra", []))]
        # recommendations first, then the top lists
        cats.sort(key=lambda c: 0 if re.search(r"for you|recommend", c.get("name", ""), re.I) else 1)
        for c in cats[:12]:
            try:
                metas = json.loads(http_get(f"{CFG['addon_upstream'].rstrip('/')}/catalog/{c['type']}/{c['id']}.json", timeout=15)).get("metas", [])
            except Exception:
                continue
            for m in metas[:20]:
                if m.get("id") in seen or not str(m.get("id", "")).startswith("tt"):
                    continue
                seen.add(m["id"])
                cards.append({"id": m["id"], "type": m.get("type") or c["type"], "name": m.get("name", ""),
                              "poster": m.get("poster") or f"https://images.metahub.space/poster/medium/{m['id']}/img",
                              "year": m.get("releaseInfo") or m.get("year") or "", "rating": m.get("imdbRating") or "",
                              "genres": (m.get("genres") or [])[:3], "description": (m.get("description") or "")[:240]})
    except Exception as e:
        print(f"[ember-feed] match deck failed: {e}", flush=True)
    random.shuffle(cards)
    films = [c for c in cards if c["type"] == "movie"][:50]
    series = [c for c in cards if c["type"] == "series"][:50]
    return films + series


def match_new(body):
    code = "".join(random.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(4))
    with _match_lock:
        for k in [k for k, v in _matches.items() if time.time() - v["created"] > 3 * 3600]:
            del _matches[k]
        _matches[code] = {"code": code, "created": time.time(), "deck": _deck(), "people": {}, "votes": {},
                          "kind": body.get("kind", "any")}
    return match_state(code)


def match_kind(code):
    with _match_lock:
        m = _matches.get(code.upper())
        return {"kind": m["kind"], "chooser": m.get("chooser", "")} if m else {"error": "no such session"}


def match_state(code):
    with _match_lock:
        m = _matches.get(code.upper())
        if not m:
            return {"error": "no such session"}
        people = list(m["people"].values())
        liked = {}
        for (pid, cid), v in m["votes"].items():
            if v:
                liked.setdefault(cid, set()).add(pid)
        need = set(m["people"].keys())
        matches = [c for c in m["deck"] if need and len(need) >= 2 and need <= liked.get(c["id"], set())]
        done = {pid: sum(1 for (p, _c) in m["votes"] if p == pid) for pid in m["people"]}
        deck = [c for c in m["deck"] if m["kind"] == "any" or c["type"] == m["kind"]]
        return {"code": m["code"], "kind": m["kind"], "people": [{"name": p["name"], "swiped": done.get(p["id"], 0)} for p in people],
                "deckSize": len(deck), "matches": [c for c in matches if m["kind"] == "any" or c["type"] == m["kind"]]}


def match_join(code, body):
    with _match_lock:
        m = _matches.get(code.upper())
        if not m:
            return {"error": "no such session"}
        pid = body.get("id") or "".join(random.choice("abcdef0123456789") for _ in range(10))
        m["people"][pid] = {"id": pid, "name": str(body.get("name", "Someone"))[:20] or "Someone"}
        # the first person to choose Films or Series decides for everyone
        if m["kind"] == "any" and body.get("kind") in ("movie", "series"):
            m["kind"] = body["kind"]
            m["chooser"] = m["people"][pid]["name"]
        deck = [c for c in m["deck"] if m["kind"] == "any" or c["type"] == m["kind"]]
        return {"id": pid, "deck": deck, "kind": m["kind"], "chooser": m.get("chooser", "")}


def match_vote(code, body):
    with _match_lock:
        m = _matches.get(code.upper())
        if not m or body.get("id") not in m["people"]:
            return {"error": "join first"}
        m["votes"][(body["id"], str(body.get("card")))] = bool(body.get("like"))
    return match_state(code)


def match_qr(code, base):
    """A QR code (PNG) for the phone page. Needs: pip install qrcode[pil]"""
    import io
    import qrcode
    img = qrcode.make(f"{base}/m/{code.upper()}", box_size=10, border=2)
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return buf.getvalue()


MATCH_PAGE = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
<title>What shall we watch?</title>
<style>
:root{--bg:#0E0B09;--card:#1C1612;--text:#F3E7DA;--muted:#A8968A;--accent:#F0A04B}
*{box-sizing:border-box}html,body{margin:0;height:100%;background:var(--bg);color:var(--text);font:16px/1.4 -apple-system,system-ui,sans-serif;overflow:hidden;touch-action:none}
header{padding:14px 18px 6px;display:flex;justify-content:space-between;align-items:baseline}header b{color:var(--accent);font-size:18px}
.pane{padding:24px 22px}input{width:100%;padding:14px;border-radius:12px;border:1px solid #3a2a1f;background:var(--card);color:var(--text);font-size:17px}
.big{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:18px}
.big button{height:150px;border-radius:20px;border:1px solid #3a2a1f;background:var(--card);color:var(--text);font:700 26px -apple-system,system-ui;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:8px}
.big button span{font-size:40px}.big button:active{background:#2a1f18;border-color:var(--accent)}
#stage{position:relative;height:calc(100% - 150px);margin:6px 16px}
.c{position:absolute;inset:0;border-radius:20px;background:var(--card) center/cover;box-shadow:0 10px 30px #0008;overflow:hidden;transition:transform .25s}
.c .i{position:absolute;inset:auto 0 0;padding:60px 16px 16px;background:linear-gradient(transparent,#000d)}
.c h2{margin:0 0 4px;font-size:22px}.c p{margin:4px 0 0;color:#ddd;font-size:13px;display:-webkit-box;-webkit-line-clamp:3;-webkit-box-orient:vertical;overflow:hidden}
.tag{position:absolute;top:22px;padding:6px 14px;border:3px solid;border-radius:10px;font-weight:800;font-size:22px;opacity:0}
.yes{left:18px;color:#7CE38B;transform:rotate(-12deg)}.no{right:18px;color:#FF7B7B;transform:rotate(12deg)}
#btns{display:flex;justify-content:center;gap:28px;padding:12px}#btns button{width:68px;height:68px;border-radius:50%;font-size:28px;padding:0;border:0}
#btns .n{background:#3a2420;color:#FF9A8E}#btns .y{background:#203a24;color:#9FF0A9}
.muted{color:var(--muted)}#done{display:none;padding:40px 22px;text-align:center}
</style></head><body>
<header><b>What shall we watch?</b><span class="muted" id="who"></span></header>
<div id="join" class="pane"><p class="muted" id="intro">Swipe right on anything you'd watch, left if not. Whatever you all like shows up on the TV.</p>
<input id="name" placeholder="Your name" maxlength="20">
<div class="big" id="choose"><button data-k="movie"><span>🎬</span>Films</button><button data-k="series"><span>📺</span>Series</button></div>
<p id="chosen" class="muted" hidden></p><p id="goWrap" hidden><button id="go" style="width:100%;padding:16px;border-radius:14px;border:0;background:var(--accent);color:#2A1606;font-weight:700;font-size:17px">Start swiping</button></p></div>
<div id="stage" hidden></div><div id="btns" hidden><button class="n" id="no">✕</button><button class="y" id="yes">♥</button></div>
<div id="done"><h2>That's all of them</h2><p class="muted">Your matches are on the TV.</p></div>
<script>
const code=location.pathname.split('/').pop().toUpperCase(),api='/match/'+code;let me=null,deck=[],i=0;
const $=id=>document.getElementById(id);
const ls={get:k=>{try{return localStorage.getItem(k)}catch(e){return null}},set:(k,v)=>{try{localStorage.setItem(k,v)}catch(e){}}};
$('name').value=ls.get('name')||'';
// if someone already chose, skip the choice
fetch(api+'/kind').then(r=>r.json()).then(k=>{if(k.error){$('intro').textContent='That session has ended. Start a new one on the TV.';return}
 if(k.kind&&k.kind!=='any'){$('choose').hidden=true;$('chosen').hidden=false;$('goWrap').hidden=false;
  $('chosen').textContent=(k.chooser||'Someone')+' picked '+(k.kind==='movie'?'films':'series')+'.'}});
async function join(kind){const name=$('name').value.trim()||'Someone';ls.set('name',name);
 const r=await (await fetch(api+'/join',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({name,kind,id:ls.get('id_'+code)})})).json();
 if(r.error){alert('That session has ended. Start a new one on the TV.');return}
 me=r.id;ls.set('id_'+code,me);deck=r.deck;$('who').textContent=name+' · '+(r.kind==='movie'?'Films':'Series');
 $('join').hidden=true;$('stage').hidden=false;$('btns').hidden=false;show()}
document.querySelectorAll('#choose button').forEach(b=>b.onclick=()=>join(b.dataset.k));
$('go').onclick=()=>join(null);
function esc(s){return String(s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
function show(){const st=$('stage');st.innerHTML='';
 if(i>=deck.length){st.hidden=true;$('btns').hidden=true;$('done').style.display='block';return}
 const d=deck[i],c=document.createElement('div');c.className='c';c.style.backgroundImage="url('"+d.poster+"')";
 c.innerHTML='<span class="tag yes">YES</span><span class="tag no">NOPE</span><div class="i"><h2>'+esc(d.name)+'</h2><div class="muted">'+esc([d.year,d.rating&&'★ '+d.rating,(d.genres||[]).join(', ')].filter(Boolean).join(' · '))+'</div><p>'+esc(d.description)+'</p></div>';
 st.appendChild(c);let x0=null,dx=0;
 c.addEventListener('pointerdown',e=>{x0=e.clientX;c.style.transition='none';c.setPointerCapture(e.pointerId)});
 c.addEventListener('pointermove',e=>{if(x0===null)return;dx=e.clientX-x0;c.style.transform='translateX('+dx+'px) rotate('+dx/20+'deg)';
  c.querySelector('.yes').style.opacity=Math.max(0,dx/100);c.querySelector('.no').style.opacity=Math.max(0,-dx/100)});
 c.addEventListener('pointerup',()=>{c.style.transition='';if(Math.abs(dx)>90)vote(dx>0);else c.style.transform='';x0=null;dx=0})}
async function vote(like){const c=document.querySelector('.c');if(c)c.style.transform='translateX('+(like?600:-600)+'px) rotate('+(like?30:-30)+'deg)';
 const d=deck[i++];fetch(api+'/vote',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:me,card:d.id,like})});setTimeout(show,180)}
$('yes').onclick=()=>vote(true);$('no').onclick=()=>vote(false);
</script></body></html>"""

# ------------------------------------------------------------------ "Ember picks": the picker as a Stremio addon
# For Omni (or any app that takes Stremio addons): the same streams as AIOStreams, but tested and best first,
# each labelled with why. Install from  http://<pi>:8090/picks/<code>/manifest.json  where <code> is your
# AIOStreams link, base64url-encoded (Ember PC's Settings shows the ready-made link).

import base64


def _aio_from_code(code):
    if code in ("", "default"):
        return CFG.get("aiostreams_url", "")
    pad = "=" * (-len(code) % 4)
    return base64.urlsafe_b64decode(code + pad).decode()


def picks_manifest(code):
    return {"id": "org.lucamedia.ember.picks", "version": "1.0.0", "name": "Ember picks",
            "description": "Your AIOStreams results, tested for speed and sorted best first by lucapi.",
            "resources": ["stream"], "types": ["movie", "series"], "idPrefixes": ["tt"], "catalogs": [],
            "behaviorHints": {"configurable": False}}


def _runtime_for(typ, imdb):
    """Running time in minutes, from Cinemeta, so the picker can tell how heavy a file is."""
    def get():
        m = json.loads(http_get(f"https://v3-cinemeta.strem.io/meta/{typ}/{imdb}.json", timeout=10)).get("meta", {})
        rt = re.search(r"\d+", str(m.get("runtime") or ""))
        return int(rt.group()) if rt else None
    try:
        return cached(f"rt:{typ}:{imdb}", 7 * 86400, get)
    except Exception:
        return None


def picks_streams(code, typ, sid):
    aio = _aio_from_code(code)
    q = CFG.get("picker", {}).get("addon_quality", "4k")
    r = cached(f"picks:{typ}:{sid}:{q}", 600, lambda: pick(typ, sid, aio, q, _runtime_for(typ, sid.split(":")[0])))
    out = []
    for n, x in enumerate(r["ranked"]):
        text = f"{x['name']}\n{x['title']}\n{x['filename']}"
        tags = [t for t, rx in [("4K", r"\b(2160p|4k|uhd)\b"), ("1080p", r"\b1080p\b"), ("DV", r"\b(dv|dovi|dolby ?vision)\b"),
                                ("HDR", r"\bhdr"), ("Atmos", r"\batmos\b"), ("DD+", r"\b(ddp|dd\+|e-?ac-?3)")] if re.search(rx, text, re.I)]
        if "4K" in tags and "1080p" in tags:
            tags.remove("1080p")
        if "DV" in tags and "HDR" in tags:
            tags.remove("HDR")
        size = _SIZE.search(text)
        pr = x.get("probe") or {}
        speed = f"tested {pr['mbps']:.0f} Mbit/s" if pr.get("ok") else ("didn't answer the test" if pr else "")
        head = ("★ Ember pick" if n == 0 else f"#{n + 1}") + (f"\n{tags[0]}" if tags else "")
        line1 = " · ".join(tags + ([f"{size.group(1)} {size.group(2).upper()}"] if size else []) + (["⚡ cached"] if "cached" in x["why"] else []))
        line2 = " · ".join([w for w in [speed] + [w for w in x["why"] if w not in ("cached", "HDR", "Dolby Vision")] if w])
        orig = (x["filename"] or x["title"].split("\n")[0])[:90]
        st = {"name": head, "description": "\n".join([l for l in [line1, line2, orig] if l]), "url": x["url"]}
        hints = dict(x.get("hints") or {})
        hints.setdefault("bingeGroup", "ember-picks")
        st["behaviorHints"] = hints
        out.append(st)
    return {"streams": out}


# ------------------------------------------------------------------ Jellyfin pass-through (step 1: watch only)
# Odin logs in to the Pi (port 8096); everything is relayed unchanged to your AIOStreams Jellyfin server, and the
# requests that matter (playback reports, resume points, stream info) are logged so we can see how it works.
# Passwords and tokens are never logged. Config: "jellyfin": {"upstream": "https://your-aiostreams/...", "port": 8096}

JF = CFG.get("jellyfin", {})
JF_LOG = HERE / "jellyfin-log.jsonl"
_jf_lock = threading.Lock()
_SECRET_KEYS = re.compile(r"(token|password|pw|api_?key|accesstoken|authorization|session(id)?|deviceid|secret)", re.I)
_INTERESTING = re.compile(r"/(Sessions/Playing|PlayingItems|PlayedItems|UserPlayedItems|UserData|PlaybackInfo|Resume|NextUp|"
                          r"Items/[^/]+$|Shows/[^/]+/(Episodes|Seasons)|Items\?|Latest|UserViews|Views)", re.I)


def _redact(obj):
    if isinstance(obj, dict):
        return {k: ("<hidden>" if _SECRET_KEYS.search(k) else _redact(v)) for k, v in obj.items()}
    if isinstance(obj, list):
        return [_redact(v) for v in obj[:6]] + (["…%d more" % (len(obj) - 6)] if len(obj) > 6 else [])
    if isinstance(obj, str) and len(obj) > 300:
        return obj[:300] + "…"
    return obj


def _jf_log(entry):
    with _jf_lock:
        try:
            if JF_LOG.exists() and JF_LOG.stat().st_size > 8 * 1024 * 1024:
                JF_LOG.replace(JF_LOG.with_suffix(".old"))
            with open(JF_LOG, "a") as f:
                f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        except Exception as e:
            print(f"[ember-feed] jellyfin log failed: {e}", flush=True)


class JellyfinProxy(BaseHTTPRequestHandler):
    server_version = "ember-jellyfin/1.0"
    protocol_version = "HTTP/1.1"

    def _relay(self):
        up = JF.get("upstream", "").rstrip("/")
        t0 = time.time()
        n = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(n) if n else None
        parsed = urllib.parse.urlparse(self.path)
        headers = {k: v for k, v in self.headers.items()
                   if k.lower() not in ("host", "accept-encoding", "connection", "content-length", "keep-alive")}
        req = urllib.request.Request(up + self.path, data=body, method=self.command, headers=headers)
        status, rh, out, streamed = 502, {}, b"", False
        try:
            class NoRedirect(urllib.request.HTTPRedirectHandler):
                def redirect_request(self, *a, **k):
                    return None
            opener = urllib.request.build_opener(NoRedirect)
            try:
                r = opener.open(req, timeout=60)
            except urllib.error.HTTPError as e:
                r = e
            status = r.status if hasattr(r, "status") else r.code
            rh = dict(r.headers.items())
            ctype = rh.get("Content-Type", "")
            big = not ("json" in ctype or "text" in ctype or "xml" in ctype)
            self.send_response(status)
            for k, v in rh.items():
                if k.lower() not in ("transfer-encoding", "connection", "keep-alive", "content-length"):
                    self.send_header(k, v)
            if big:  # video, images: stream them straight through
                streamed = True
                ln = rh.get("Content-Length")
                if ln:
                    self.send_header("Content-Length", ln)
                    self.end_headers()
                    shutil.copyfileobj(r, self.wfile, 256 * 1024)
                else:
                    self.send_header("Connection", "close")
                    self.end_headers()
                    shutil.copyfileobj(r, self.wfile, 256 * 1024)
                    self.close_connection = True
            else:
                out = r.read()
                self.send_header("Content-Length", str(len(out)))
                self.end_headers()
                self.wfile.write(out)
        except (BrokenPipeError, ConnectionResetError):
            return
        except Exception as e:
            try:
                self.send_response(502)
                msg = json.dumps({"error": f"couldn't reach AIOStreams' Jellyfin: {e}"}).encode()
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(msg)))
                self.end_headers()
                self.wfile.write(msg)
            except Exception:
                pass
            status = 502
        # log it (everything briefly; the interesting ones in detail)
        q = {k: ("<hidden>" if _SECRET_KEYS.search(k) else v[:3]) for k, v in urllib.parse.parse_qs(parsed.query).items()}
        entry = {"t": datetime.now(TZ).strftime("%H:%M:%S"), "m": self.command, "path": parsed.path, "q": q,
                 "status": status, "ms": round((time.time() - t0) * 1000), "client": self.headers.get("User-Agent", "")[:60]}
        if status in (301, 302, 303, 307, 308):
            entry["redirect_to"] = urllib.parse.urlparse(rh.get("Location", "")).netloc
        if _INTERESTING.search(parsed.path + ("?" if parsed.query else "")):
            for name, raw in (("sent", body), ("got", out)):
                if raw:
                    try:
                        entry[name] = _redact(json.loads(raw))
                    except Exception:
                        entry[name] = raw[:300].decode("utf-8", "replace")
        if streamed:
            entry["streamed"] = True
        _jf_log(entry)

    do_GET = do_POST = do_DELETE = do_PUT = do_HEAD = do_OPTIONS = _relay

    def log_message(self, fmt, *args):
        pass


def jellyfin_summary():
    """A short read-out of the log: which calls Odin makes, and samples of the ones about playback and resume."""
    if not JF_LOG.exists():
        return {"note": "nothing logged yet"}
    lines = JF_LOG.read_text(errors="ignore").splitlines()[-3000:]
    counts, samples = {}, {}
    for l in lines:
        try:
            e = json.loads(l)
        except Exception:
            continue
        key = f"{e['m']} " + re.sub(r"/[0-9a-f]{20,}|/tt\d+[^/]*|/\d{3,}", "/{id}", e["path"])
        counts[key] = counts.get(key, 0) + 1
        if ("sent" in e or "got" in e or "redirect_to" in e) and len(samples.get(key, [])) < 2:
            samples.setdefault(key, []).append(e)
    return {"calls": dict(sorted(counts.items(), key=lambda x: -x[1])[:60]), "samples": samples}


def start_jellyfin_proxy():
    if not JF.get("upstream"):
        return
    port = int(JF.get("port", 8096))
    srv = ThreadingHTTPServer(("0.0.0.0", port), JellyfinProxy)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    print(f"[ember-feed] Jellyfin pass-through on :{port} -> {urllib.parse.urlparse(JF['upstream']).netloc}", flush=True)


# ------------------------------------------------------------------ browse: TMDB tiles and lists (services, genres,
# directors, studios, collections, decades) for the Omni-style home. Uses your addon's TMDB key unless config.json has
# "tmdb": {"api_key": ...} (a v3 key) or {"token": ...} (a v4 read token).

TMDB = "https://api.themoviedb.org/3"
TMDB_IMG = "https://image.tmdb.org/t/p/"
_tmdb_cred = {}


def _tmdb_creds():
    if _tmdb_cred:
        return _tmdb_cred
    t = CFG.get("tmdb", {})
    if t.get("api_key") or t.get("token"):
        _tmdb_cred.update(t)
        return _tmdb_cred
    root = Path(CFG.get("trakt", {}).get("addon_dir", str(Path.home() / "lucaddon")))
    for env in [root / ".env"] + list(root.glob("*/.env")):
        if not env.exists():
            continue
        for line in env.read_text(errors="ignore").splitlines():
            k, _, v = line.partition("=")
            k, v = k.strip().upper(), v.strip().strip("'\"")
            if "TMDB" in k and v:
                if v.startswith("eyJ"):
                    _tmdb_cred.setdefault("token", v)  # v4 read access token
                elif re.fullmatch(r"[0-9a-f]{32}", v):
                    _tmdb_cred.setdefault("api_key", v)
    return _tmdb_cred


def _tmdb(path, **params):
    c = _tmdb_creds()
    if not c:
        raise RuntimeError("no TMDB key found (add \"tmdb\": {\"api_key\": ...} to config.json)")
    params.setdefault("language", "en-GB")
    if c.get("api_key"):
        params["api_key"] = c["api_key"]
    url = f"{TMDB}{path}?{urllib.parse.urlencode(params)}"
    headers = {"User-Agent": "ember-feed/1.0", "Accept": "application/json"}
    if not c.get("api_key"):
        headers["Authorization"] = "Bearer " + c["token"]
    req = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())


def _img(path, size="w780"):
    return f"{TMDB_IMG}{size}{path}" if path else ""


def _imdb_for(kind, tmdb_id):
    """TMDB id -> IMDb id (what Ember, Stremio and AIOStreams use). Remembered forever."""
    key = f"{kind}:{tmdb_id}"
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS tmdb_imdb (k TEXT PRIMARY KEY, imdb TEXT)")
        r = db().execute("SELECT imdb FROM tmdb_imdb WHERE k=?", (key,)).fetchone()
    if r:
        return r[0]
    try:
        imdb = (_tmdb(f"/{kind}/{tmdb_id}/external_ids") or {}).get("imdb_id") or ""
    except Exception:
        return None  # try again another time
    with _db_lock:
        db().execute("INSERT OR REPLACE INTO tmdb_imdb VALUES (?, ?)", (key, imdb))
        db().commit()
    return imdb


def _to_metas(results, kind):
    """TMDB results -> Ember metas with IMDb ids (anything without one is left out)."""
    items = [r for r in results if r.get("id")][:40]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        ids = list(ex.map(lambda r: _imdb_for(kind, r["id"]), items))
    out = []
    for r, imdb in zip(items, ids):
        if not imdb or not imdb.startswith("tt"):
            continue
        date = r.get("release_date") or r.get("first_air_date") or ""
        out.append({"id": imdb, "type": "movie" if kind == "movie" else "series", "name": r.get("title") or r.get("name") or "",
                    "poster": _img(r.get("poster_path"), "w342"), "background": _img(r.get("backdrop_path"), "w1280"),
                    "releaseInfo": date[:4], "imdbRating": f"{r['vote_average']:.1f}" if r.get("vote_average") else "",
                    "description": r.get("overview") or ""})
    return out


GENRES = {"movie": [("Action", 28), ("Comedy", 35), ("Drama", 18), ("Sci-Fi", 878), ("Thriller", 53), ("Horror", 27),
                    ("Crime", 80), ("Romance", 10749), ("Animation", 16), ("Documentary", 99), ("Fantasy", 14), ("War", 10752)],
          "tv": [("Action", 10759), ("Comedy", 35), ("Drama", 18), ("Sci-Fi", 10765), ("Crime", 80), ("Mystery", 9648),
                 ("Animation", 16), ("Documentary", 99), ("Reality", 10764)]}
SERVICES = [("Netflix", "#3A0E0B"), ("Disney Plus", "#0F1A3D"), ("Amazon Prime Video", "#0E2A33"), ("Apple TV", "#1E1E1E"),
            ("BBC iPlayer", "#1E1030"), ("ITVX", "#0F2A2A"), ("Channel 4", "#1B1B2E"), ("NOW", "#0D2B22"), ("Paramount Plus", "#0B1E3F")]
DIRECTORS = ["Denis Villeneuve", "Christopher Nolan", "Quentin Tarantino", "Greta Gerwig", "David Fincher", "Martin Scorsese",
             "Steven Spielberg", "Edgar Wright", "Ridley Scott", "Wes Anderson"]
STUDIOS = ["Marvel Studios", "DC Studios", "Pixar", "Walt Disney Animation Studios", "Studio Ghibli", "A24", "Lucasfilm", "Blumhouse Productions"]
COLLECTIONS = ["Star Wars Collection", "Harry Potter Collection", "The Lord of the Rings Collection", "James Bond Collection",
               "Mission: Impossible Collection", "The Dark Knight Collection", "Jurassic Park Collection", "Toy Story Collection",
               "Indiana Jones Collection", "Fast & Furious Collection"]
DECADES = [2020, 2010, 2000, 1990, 1980, 1970]


def _top_backdrop(**discover):
    try:
        r = _tmdb("/discover/movie", sort_by="popularity.desc", **discover).get("results", [])
        return _img(next((x["backdrop_path"] for x in r if x.get("backdrop_path")), None))
    except Exception:
        return ""


def _build_tmdb_tiles():
    """The old TMDB-only tiles: used only if your lists addon can't be reached."""
    groups = []
    # streaming services available in the UK
    try:
        provs = _tmdb("/watch/providers/movie", watch_region="GB").get("results", [])
        tiles = []
        for name, colour in SERVICES:
            p = next((x for x in provs if x.get("provider_name", "").lower() == name.lower()), None) \
                or next((x for x in provs if x.get("provider_name", "").lower().startswith(name.lower())), None)
            if p:
                tiles.append({"kind": "service", "id": p["provider_id"], "title": name.replace(" Plus", "+").replace("Amazon ", ""),
                              "logo": _img(p.get("logo_path"), "w154"), "colour": colour})
        groups.append({"title": "Streaming services", "style": "logo", "tiles": tiles})
    except Exception as e:
        print(f"[ember-feed] tiles: services failed: {e}", flush=True)
    groups.append({"title": "Genres", "style": "art", "tiles": [
        {"kind": "genre", "id": gid, "title": name, "image": _top_backdrop(with_genres=gid)} for name, gid in GENRES["movie"][:10]]})
    people = []
    for name in DIRECTORS:
        try:
            p = (_tmdb("/search/person", query=name).get("results") or [None])[0]
            if p:
                people.append({"kind": "person", "id": p["id"], "title": p["name"], "image": _img(p.get("profile_path"), "w342")})
        except Exception:
            pass
    groups.append({"title": "Directors", "style": "person", "tiles": people})
    studios = []
    for name in STUDIOS:
        try:
            c = next((x for x in _tmdb("/search/company", query=name).get("results", []) if x["name"].lower() == name.lower()),
                     None) or (_tmdb("/search/company", query=name).get("results") or [None])[0]
            if c:
                studios.append({"kind": "company", "id": c["id"], "title": name.replace(" Productions", ""),
                                "logo": _img(c.get("logo_path"), "w300"), "image": _top_backdrop(with_companies=c["id"])})
        except Exception:
            pass
    groups.append({"title": "Studios", "style": "studio", "tiles": studios})
    cols = []
    for name in COLLECTIONS:
        try:
            c = (_tmdb("/search/collection", query=name).get("results") or [None])[0]
            if c:
                cols.append({"kind": "collection", "id": c["id"], "title": c["name"].replace(" Collection", ""),
                             "image": _img(c.get("backdrop_path"))})
        except Exception:
            pass
    groups.append({"title": "Collections", "style": "art", "tiles": cols})
    groups.append({"title": "By decade", "style": "art", "tiles": [
        {"kind": "decade", "id": d, "title": f"{d}s", "image": _top_backdrop(**{"primary_release_date.gte": f"{d}-01-01",
                                                                                "primary_release_date.lte": f"{d + 9}-12-31",
                                                                                "vote_count.gte": 3000})} for d in DECADES]})
    return {"groups": [g for g in groups if g["tiles"]]}


# ------------------------------------------------------------------ your own lists, sorted into boxes
# Every catalogue in your lists addon is classified by its name. Films and Series catalogues with the same
# name become one tile (with Films / Series chips); several catalogues can share a tile through MERGE.
# Whatever isn't a category (For you, Watchlist, Top 20, ...) stays a row on Home.

TILE_ORDER = [("services", "Streaming services", "logo"), ("genres", "Genres", "art"), ("decades", "Decades", "art"),
              ("people", "Filmmakers", "person"), ("franchises", "Franchises", "art"), ("studios", "Studios", "studio"),
              ("animation", "Animation studios", "studio"), ("kids", "Kids", "art"), ("acclaim", "Awards & acclaim", "art")]
HOME_WORDS = re.compile(r"\b(for you|recommend\w*|watchlist|trending|top|popular|pick up|left off|continue|new|releases|hero)\b", re.I)
SERVICE_NAMES = {"netflix": "Netflix", "prime video": "Amazon Prime Video", "amazon prime": "Amazon Prime Video",
                 "apple tv+": "Apple TV", "apple tv": "Apple TV", "disney+": "Disney Plus", "hbo max": "HBO Max", "max": "Max",
                 "hulu": "Hulu", "paramount +": "Paramount Plus", "paramount+": "Paramount Plus", "peacock": "Peacock",
                 "discovery +": "discovery+", "discovery+": "discovery+", "crunchyroll": "Crunchyroll", "now": "NOW",
                 "bbc iplayer": "BBC iPlayer", "itvx": "ITVX", "channel 4": "Channel 4", "mubi": "MUBI", "shudder": "Shudder"}
SERVICE_COLOURS = {"Netflix": "#3A0E0B", "Amazon Prime Video": "#0E2A33", "Apple TV": "#1E1E1E", "Disney Plus": "#0F1A3D",
                   "HBO Max": "#1A1238", "Max": "#1A1238", "Hulu": "#0E2B1A", "Paramount Plus": "#0B1E3F", "Peacock": "#1B1B1B",
                   "discovery+": "#0B2238", "Crunchyroll": "#3A1E0B"}
GENRE_WORDS = {"action", "adventure", "animation", "comedy", "crime", "documentary", "drama", "family", "fantasy", "history",
               "horror", "music", "musical", "mystery", "romance", "sci-fi", "science fiction", "thriller", "war", "western",
               "reality", "kids", "talk", "news", "biography", "sport", "superhero", "anime"}
KIDS_WORDS = re.compile(r"cbeebies|cbbc|cartoon network|nickelodeon|disney kids|disney junior|nick jr|boomerang", re.I)
ACCLAIM_WORDS = re.compile(r"academy award|oscar|bafta|golden globe|cannes|venice|sundance|berlin|emmy|certified fresh|criterion|imdb top|palme", re.I)
ANIMATION_STUDIOS = re.compile(r"animation|pixar|ghibli|illumination|aardman|laika|cartoon saloon", re.I)
STUDIO_WORDS = re.compile(r"studios?\b|pictures|brothers|\bbros\b|lionsgate|miramax|\bmgm\b|^walt disney$|a24|blumhouse|lucasfilm|"
                          r"paramount pictures|legendary|neon|focus features|amblin|dreamworks|new line|20th century", re.I)
KNOWN_PEOPLE = {"alfred hitchcock", "christopher nolan", "denis villeneuve", "david fincher", "james cameron", "john carpenter",
                "martin scorsese", "paul thomas anderson", "quentin tarantino", "ridley scott", "stanley kubrick", "steven spielberg",
                "coen brothers", "wes anderson", "yorgos lanthimos", "david attenborough", "greta gerwig", "edgar wright"}
SERVICE_WIKI = {"netflix": "Netflix", "prime video": "Amazon Prime Video|Prime Video", "apple tv+": "Apple TV+|Apple TV",
                "disney+": "Disney+", "hbo max": "HBO Max|Max (streaming service)", "hulu": "Hulu",
                "paramount +": "Paramount+", "paramount+": "Paramount+", "peacock": "Peacock (streaming service)",
                "discovery +": "Discovery+", "discovery+": "Discovery+", "crunchyroll": "Crunchyroll", "now": "Now (Sky)",
                "bbc iplayer": "BBC iPlayer", "itvx": "ITVX", "channel 4": "Channel 4", "mubi": "Mubi"}
# The franchise's own Wikipedia article (its logo there is the franchise's, not one film's).
FRANCHISE_WIKI = {"007": "James Bond", "fast and furious": "Fast & Furious", "harry potter": "Harry Potter",
                  "indiana jones": "Indiana Jones", "mission impossible": "Mission: Impossible", "star trek": "Star Trek",
                  "star wars": "Star Wars", "x-men": "X-Men (film series)", "mad max": "Mad Max", "john wick": "John Wick (franchise)",
                  "bourne": "Bourne (franchise)|Jason Bourne", "die hard": "Die Hard (franchise)|Die Hard",
                  "terminator": "Terminator (franchise)", "rocky & creed": "Rocky (franchise)", "alien": "Alien (franchise)",
                  "predator": "Predator (franchise)", "jurassic park": "Jurassic Park", "planet of the apes": "Planet of the Apes",
                  "middle-earth": "The Lord of the Rings (film series)|The Lord of the Rings",
                  "pirates of the caribbean": "Pirates of the Caribbean (franchise)", "halloween": "Halloween (franchise)",
                  "scream": "Scream (franchise)", "the conjuring universe": "The Conjuring Universe", "saw": "Saw (franchise)",
                  "final destination": "Final Destination", "toy story": "Toy Story", "shrek": "Shrek (franchise)",
                  "despicable me & minions": "Despicable Me"}
STUDIO_QUERY = {"walt disney": "Walt Disney Pictures", "illumination studios": "Illumination", "illumination": "Illumination", "warner brothers": "Warner Bros. Pictures",
                "warner brothers animation": "Warner Bros. Pictures", "universal pictures": "Universal Pictures"}
PERSON_PHOTO = {"coen brothers": "Joel Coen"}  # a pair: show one of them
# Wikipedia article for a tile whose logo comes from Wikidata (the "logo image" on its entry).
WIKI_LOGO = {"imdb top 250": "IMDb", "oscar winners": "Academy Awards|Academy of Motion Picture Arts and Sciences",
             "academy award winners": "Academy Awards|Academy of Motion Picture Arts and Sciences",
             "bafta": "British Academy Film Awards|British Academy of Film and Television Arts",
             "golden globes": "Golden Globe Awards|Golden Globes|Hollywood Foreign Press Association", "cannes": "Cannes Film Festival",
             "certified fresh": "Rotten Tomatoes", "cbeebies": "CBeebies", "cartoon network": "Cartoon Network",
             "nickelodeon": "Nickelodeon", "disney kids": "Disney Channel", "cbbc": "CBBC", "disney junior": "Disney Junior"}
# Catalogues that should share one tile: tile title -> the catalogue names that go in it.
MERGE = {"IMDb Top 250": ["IMDb Top Movies", "IMDb Top Shows"], "Certified Fresh": ["100% Certified Fresh Movies"],
         "Oscar winners": ["Academy Award Winners"]}


def _classify(name, tmdb_ok=True):
    n = name.strip().lower()
    if n in KNOWN_PEOPLE:
        return "people"
    if ACCLAIM_WORDS.search(n):
        return "acclaim"
    if HOME_WORDS.search(n):
        return "home"
    if n in SERVICE_NAMES:
        return "services"
    if re.fullmatch(r"(19|20)\d0s", n):
        return "decades"
    if n in GENRE_WORDS:
        return "genres"
    if ACCLAIM_WORDS.search(n):
        return "acclaim"
    if KIDS_WORDS.search(n):
        return "kids"
    if ANIMATION_STUDIOS.search(n):
        return "animation"
    if STUDIO_WORDS.search(n):
        return "studios"
    if n in KNOWN_PEOPLE:
        return "people"
    if tmdb_ok:  # a name we haven't seen: is it a person? (exact match, and well known)
        try:
            p = (_tmdb("/search/person", query=name).get("results") or [None])[0]
            if p and p.get("name", "").lower() == n and p.get("popularity", 0) > 2 and \
                    p.get("known_for_department") in ("Directing", "Writing", "Production", "Acting"):
                return "people"
        except Exception:
            pass
    return "franchises"  # what's left is a series of films: 007, Alien, Toy Story...


def _slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def _addon_json(rest, timeout=15):
    return json.loads(http_get(CFG["addon_upstream"].rstrip("/") + rest, timeout=timeout))


def _cat_metas(c, skip=0):
    extra = f"/skip={skip}" if skip else ""
    try:
        return _addon_json(f"/catalog/{c['type']}/{urllib.parse.quote(c['id'])}{extra}.json").get("metas", [])
    except Exception:
        return []


def _bg(m):
    if m.get("background"):
        return m["background"]
    return f"https://images.metahub.space/background/medium/{m['id']}/img" if str(m.get("id", "")).startswith("tt") else ""


def _wikidata_logo(article):
    """The logo on a Wikipedia article's Wikidata entry, as a PNG from Wikimedia Commons ("" if it has none)."""
    def get():
        q = urllib.parse.urlencode({"action": "wbgetentities", "sites": "enwiki", "titles": article, "props": "claims",
                                    "format": "json", "redirects": "yes"})
        req = urllib.request.Request(f"https://www.wikidata.org/w/api.php?{q}",
                                     headers={"User-Agent": WIKI_UA})
        with urllib.request.urlopen(req, timeout=12) as r:
            ents = json.loads(r.read()).get("entities", {})
        for e in ents.values():
            for c in e.get("claims", {}).get("P154", []):
                f = c.get("mainsnak", {}).get("datavalue", {}).get("value")
                if f:
                    return "https://commons.wikimedia.org/wiki/Special:FilePath/" + urllib.parse.quote(f.replace(" ", "_")) + "?width=500"
        return ""
    try:
        return cached(f"wikilogo:{article}", 30 * 24 * 3600, get)
    except Exception:
        return ""


def _franchise_logo(title, metas):
    """A franchise's title logo: the first film of its TMDB collection, else the top title in your list."""
    try:
        res = _tmdb("/search/collection", query=title).get("results", [])
        want = re.sub(r"[^a-z0-9 ]", "", title.lower()).strip()
        col = next((c for c in res if re.sub(r"[^a-z0-9 ]", "", c.get("name", "").lower()).replace(" collection", "").strip() == want), None) \
            or next((c for c in res if c.get("name", "").lower().startswith(title.lower())), None) \
            or next((c for c in res if title.lower().split()[0] in c.get("name", "").lower()), None)
        if col:
            parts = sorted(_tmdb(f"/collection/{col['id']}").get("parts", []), key=lambda x: x.get("release_date") or "9999")
            # the film called just the franchise's name (Jurassic Park, Toy Story, Star Trek) has the plainest logo
            plain = lambda t: re.sub(r"^the ", "", re.sub(r"[^a-z0-9 ]", "", (t or "").lower())).strip()
            named = [p for p in parts if plain(p.get("title")) == plain(title)]
            parts = named + [p for p in parts if p not in named]
            for part in parts[:2]:
                logos = _tmdb(f"/movie/{part['id']}/images", include_image_language="en,null").get("logos", [])
                logos.sort(key=lambda l: (l.get("iso_639_1") != "en", -l.get("vote_average", 0)))
                if logos:
                    return _img(logos[0]["file_path"], "w500")
    except Exception:
        pass
    m = next((x for x in metas if str(x.get("id", "")).startswith("tt")), None)
    return f"https://images.metahub.space/logo/medium/{m['id']}/img" if m else ""


LOGO_DIR = HERE / "logo-cache"
# Wikimedia asks for a User-Agent that says who's asking and how to get in touch
WIKI_UA = "ember-feed/1.0 (personal home media server; non-commercial) python-urllib"


def _knockout(data):
    """An app icon (a logo on a coloured square) -> just the logo: the square's colours become transparent
    (soft-edged, so it stays smooth), then it's cropped to what's left."""
    import io
    from PIL import Image
    im = Image.open(io.BytesIO(data)).convert("RGBA")
    im.thumbnail((360, 360))  # plenty for a tile, and quick on the Pi
    w, h = im.size
    px = im.load()
    ring = []
    for k in range(0, w, max(1, w // 24)):
        ring += [px[k, 1], px[k, h - 2]]
    for k in range(0, h, max(1, h // 24)):
        ring += [px[1, k], px[w - 2, k]]
    solid_ring = [c for c in ring if c[3] > 200]
    if len(solid_ring) < len(ring) * 0.8:
        return data  # already on a transparent background: nothing to cut away
    ring = list({(c[0] // 8 * 8, c[1] // 8 * 8, c[2] // 8 * 8, 255) for c in solid_ring})
    near, far = 40.0, 90.0
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a == 0:
                continue
            d = min(((r - c[0]) ** 2 + (g - c[1]) ** 2 + (b - c[2]) ** 2) ** 0.5 for c in ring)
            if d < far:
                px[x, y] = (r, g, b, int(a * max(0.0, (d - near) / (far - near))))
    box = im.getbbox()
    if box:
        pad = 4
        im = im.crop((max(0, box[0] - pad), max(0, box[1] - pad), min(w, box[2] + pad), min(h, box[3] + pad)))
    out = io.BytesIO()
    im.save(out, "PNG")
    return out.getvalue()


def _whiten_right(data):
    """Logo with a badge on the left and a word on the right (MARVEL | STUDIOS, DC | STUDIOS):
    everything after the first clear gap turns white, so the word matches the other tiles."""
    import io
    from PIL import Image
    im = Image.open(io.BytesIO(data)).convert("RGBA")
    w, h = im.size
    px = im.load()
    filled = [any(px[x, y][3] > 40 for y in range(h)) for x in range(w)]
    start = next((x for x in range(w) if filled[x]), 0)
    gap, x = None, start
    while x < w:
        if not filled[x]:
            run = x
            while run < w and not filled[run]:
                run += 1
            if run - x >= max(2, w // 80) and run < w:
                gap = run
                break
            x = run
        x += 1
    if gap is None:
        return data
    for yy in range(h):
        for xx in range(gap, w):
            r, g, b, a = px[xx, yy]
            if a:
                px[xx, yy] = (255, 255, 255, a)
    out = io.BytesIO()
    im.save(out, "PNG")
    return out.getvalue()


def _logo_look(data):
    """How a logo should be shown in black and white, and its border colour:
    "mono" - one colour on transparent (Nickelodeon, Harry Potter): shown solid white
    "duo"  - two-tone, e.g. white lettering inside a coloured shape (Marvel, DC): shown in greyscale
    "box"  - its own solid background (IMDb, Cartoon Network): shown in greyscale"""
    import io
    from PIL import Image
    im = Image.open(io.BytesIO(data)).convert("RGBA")
    alpha_box = im.getchannel("A").point(lambda a: 255 if a > 24 else 0).getbbox()
    if alpha_box and alpha_box != (0, 0, im.width, im.height):
        pad = max(2, min(im.size) // 60)
        im = im.crop((max(0, alpha_box[0] - pad), max(0, alpha_box[1] - pad),
                      min(im.width, alpha_box[2] + pad), min(im.height, alpha_box[3] + pad)))
    sm = im.copy()
    sm.thumbnail((96, 96))
    px = list(sm.getdata())
    solid = [p for p in px if p[3] > 40]
    clear = 1 - len(solid) / max(1, len(px))
    lum = lambda p: (0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2]) / 255
    sat = lambda p: (max(p[:3]) - min(p[:3])) / 255
    n = max(1, len(solid))
    light = sum(1 for p in solid if lum(p) > 0.75 and sat(p) < 0.2) / n
    dark = sum(1 for p in solid if lum(p) < 0.25) / n
    colour = sum(1 for p in solid if sat(p) > 0.3 and 0.12 < lum(p) <= 0.75) / n
    if clear < 0.04:
        mode = "box"
    elif light > 0.04 and (colour > 0.2 or dark > 0.2):
        mode = "duo"
    elif colour > 0.25:
        mode = "colour"   # a coloured logo (Jurassic Park, Toy Story): keep its colours
    elif sum(lum(p) for p in solid) / n > 0.55:
        mode = "light"    # already white or pale
    else:
        mode = "dark"     # dark and one colour: shown white
    w, h = sm.size
    corners = [sm.getpixel((x, y)) for x, y in ((1, 1), (w - 2, 1), (1, h - 2), (w - 2, h - 2))]
    edge = ""
    if all(c[3] > 200 for c in corners):
        edge = "#%02x%02x%02x" % tuple(sum(c[i] for c in corners) // 4 for i in range(3))
    out = io.BytesIO()
    im.save(out, "PNG")
    return mode, edge, out.getvalue()


LOGO_VERSION = 4


def _logo(url, knockout=False, whiten_right=False):
    """Downloads a logo once and keeps it on the Pi (served at /logo/<key>), with how to show it (see _logo_look).
    knockout: it's an app icon; cut away its square background first."""
    if not url:
        return None
    key = hashlib.sha1((url + ("#knockout" if knockout else "") + ("#whiten" if whiten_right else "")).encode()).hexdigest()[:20]
    info_path, img_path = LOGO_DIR / f"{key}.json", LOGO_DIR / key
    if info_path.exists():
        try:
            info = json.loads(info_path.read_text())
            if info.get("v") == LOGO_VERSION:
                return info
            if img_path.exists():  # kept from before: look at it again (and trim it)
                raw = img_path.read_bytes()
                if knockout:
                    raw = _knockout(raw)
                if whiten_right:
                    raw = _whiten_right(raw)
                mode, edge, raw = _logo_look(raw)
                img_path.write_bytes(raw)
                info.update(mode=mode, edge=edge, v=LOGO_VERSION)
                info_path.write_text(json.dumps(info))
                return info
        except Exception:
            pass
    LOGO_DIR.mkdir(parents=True, exist_ok=True)
    req = urllib.request.Request(url, headers={"User-Agent": WIKI_UA})
    with urllib.request.urlopen(req, timeout=20) as r:
        data = r.read()
    info = {"src": f"/logo/{key}", "mode": "light", "edge": "", "v": LOGO_VERSION}
    try:
        if knockout:
            data = _knockout(data)
        if whiten_right:
            data = _whiten_right(data)
        info["mode"], info["edge"], data = _logo_look(data)
    except Exception as e:
        print(f"[ember-feed] logo {url[:60]}: kept as it is ({e})", flush=True)
    img_path.write_bytes(data)
    info_path.write_text(json.dumps(info))
    return info


def _service_logos():
    out = {}
    for region in ("US", "GB"):
        try:
            for x in _tmdb("/watch/providers/movie", watch_region=region).get("results", []):
                out.setdefault(x.get("provider_name", "").lower(), _img(x.get("logo_path"), "w154"))
        except Exception:
            pass
    return out


def _build_tiles():
    try:
        man = _addon_json("/manifest.json")
    except Exception as e:
        print(f"[ember-feed] tiles: lists addon unreachable ({e}); using TMDB tiles", flush=True)
        return _build_tmdb_tiles()
    cats = [c for c in man.get("catalogs", []) if c.get("type") in ("movie", "series")
            and not any(x.get("isRequired") for x in c.get("extra", []))]
    merged_into = {src.lower(): title for title, srcs in MERGE.items() for src in srcs}
    tmdb_ok = bool(_tmdb_creds())  # from config.json, or found in your addon's .env
    home, hero, tiles = [], [], {}
    for c in cats:
        name = (c.get("name") or c["id"]).strip()
        box = _classify(name, tmdb_ok)
        if name.lower() == "hero":
            hero.append({"type": c["type"], "id": c["id"]})
            continue
        if box == "home":
            home.append({"type": c["type"], "id": c["id"], "name": name,
                         "style": "continue" if re.search(r"pick up|left off|continue", name, re.I)
                         else "top10" if re.search(r"\btop\b", name, re.I) else "row"})
            continue
        title = merged_into.get(name.lower(), name)
        t = tiles.setdefault((box, title), {"kind": "cat", "id": _slug(title), "title": title, "box": box, "cats": {}})
        t["cats"].setdefault(c["type"], []).append({"type": c["type"], "id": c["id"],
                                                     "skip": any(x.get("name") == "skip" for x in c.get("extra", []))})
    # Artwork: the top title of each list (a different one per tile where possible), logos and faces from TMDB.
    tl = list(tiles.values())
    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        firsts = list(ex.map(lambda t: _cat_metas((t["cats"].get("movie") or t["cats"].get("series"))[0])[:12], tl))
    used = set()
    tops = {}
    for t, metas in zip(tl, firsts):
        tops[t["id"]] = metas
        m = next((x for x in metas if x.get("id") not in used and _bg(x)), metas[0] if metas else None)
        if m:
            used.add(m.get("id"))
            t["image"] = _bg(m)
    logos = _service_logos() if tmdb_ok else {}
    def art(t):
        if t["box"] == "services":
            pname = SERVICE_NAMES.get(t["title"].lower(), t["title"])
            t["colour"] = SERVICE_COLOURS.get(pname, "#1E1A17")
            # the wordmark (NETFLIX, prime video...) from Wikidata; TMDB's square app icon if there isn't one
            for article in SERVICE_WIKI.get(t["title"].lower(), t["title"]).split("|"):
                t["logo"] = _wikidata_logo(article)
                if t["logo"]:
                    t["logo_kind"] = "wordmark"
                    break
            if not t.get("logo"):
                t["logo"] = logos.get(pname.lower()) or next((v for k, v in logos.items() if k.startswith(pname.lower())), "")
                t["logo_kind"] = "icon"
        elif t["box"] == "people" and tmdb_ok:
            try:
                q = PERSON_PHOTO.get(t["title"].lower(), t["title"])
                p = (_tmdb("/search/person", query=q).get("results") or [None])[0]
                if p and p.get("profile_path"):
                    t["image"] = _img(p["profile_path"], "w342")
            except Exception:
                pass
        elif t["box"] in ("kids", "acclaim"):
            for article in WIKI_LOGO.get(t["title"].lower(), t["title"]).split("|"):  # first article that has a logo
                t["logo"] = _wikidata_logo(article)
                if t["logo"]:
                    break
        elif t["box"] == "franchises":
            for article in FRANCHISE_WIKI.get(t["title"].lower(), t["title"]).split("|"):
                t["logo"] = _wikidata_logo(article)
                if t["logo"]:
                    break
            if not t.get("logo") and tmdb_ok:
                t["logo"] = _franchise_logo(t["title"], tops.get(t["id"], []))
        elif t["box"] in ("studios", "animation") and tmdb_ok:
            try:
                q = STUDIO_QUERY.get(t["title"].lower(), t["title"])
                res = _tmdb("/search/company", query=q).get("results", [])
                co = next((x for x in res if x["name"].lower() == q.lower() and x.get("logo_path")), None) \
                    or next((x for x in res if x.get("logo_path")), None)
                if co:
                    t["logo"] = _img(co["logo_path"], "w300")
            except Exception:
                pass
        if t["box"] in ("studios", "animation") and not t.get("logo"):
            t["logo"] = _wikidata_logo(t["title"])
        if t.get("logo"):
            try:
                info = _logo(t["logo"], knockout=t.get("logo_kind") == "icon" or t["box"] == "franchises",
                             whiten_right=t["title"].lower() in ("marvel studios", "dc studios"))
                t["logo"], t["logo_mode"] = info["src"], info["mode"]
                if t["box"] == "services" and info.get("edge") and t.get("logo_kind") == "icon":
                    t["colour"] = info["edge"]
            except Exception as e:
                print(f"[ember-feed] logo for {t['title']} failed: {e}", flush=True)

    with concurrent.futures.ThreadPoolExecutor(8) as ex:
        list(ex.map(art, tl))
    groups = []
    for key, title, style in TILE_ORDER:
        its = [{k: v for k, v in t.items() if k != "cats"} | {"types": [x for x in ("movie", "series") if x in t["cats"]]}
               for t in tl if t["box"] == key]
        if its:
            groups.append({"title": title, "style": style, "tiles": its})
    _TILE_CATS.clear()
    _TILE_CATS.update({t["id"]: t["cats"] for t in tl})
    return {"groups": groups, "home": home, "hero": hero, "source": "lists"}


_TILE_CATS = {}


def _year(m):
    for k in ("releaseInfo", "year", "released"):
        y = re.search(r"(18|19|20)\d\d", str(m.get(k) or ""))
        if y:
            return int(y.group(0))
    return 0


def _rating(m):
    try:
        return float(m.get("imdbRating") or 0)
    except (TypeError, ValueError):
        return 0.0


SORTS = {"new": (lambda m: (_year(m) == 0, -_year(m))), "old": (lambda m: (_year(m) == 0, _year(m))),
         "rating": (lambda m: -_rating(m)), "az": (lambda m: re.sub(r"^(the|a|an) ", "", (m.get("name") or "").lower()))}


def browse_cat(tid, typ="movie", skip=0, sort=""):
    """The titles behind one of your own tiles: its catalogues for that type, merged, without repeats.
    With a sort, the whole list (up to 600) is fetched and sorted, in one go."""
    if not _TILE_CATS:
        browse_tiles()
    cats = _TILE_CATS.get(tid, {}).get("movie" if typ == "movie" else "series", [])
    if not cats:
        return {"metas": [], "more": False}

    if sort in SORTS:
        def build_all():
            out, seen = [], set()
            for c in cats:
                at = 0
                while len(out) < 600:
                    page = _cat_metas(c, at)
                    fresh = [m for m in page if m.get("id") not in seen]
                    for m in fresh:
                        seen.add(m.get("id"))
                        out.append({**m, "type": m.get("type") or c["type"]})
                    if not c["skip"] or not fresh:
                        break
                    at += len(page)
            out.sort(key=SORTS[sort])
            return {"metas": out, "more": False}
        return cached(f"browse:cat:{tid}:{typ}:all:{sort}", 3600, build_all)

    def build():
        out, seen, more = [], set(), False
        for c in cats:
            if skip and not c["skip"]:
                continue
            for m in _cat_metas(c, skip):
                if m.get("id") not in seen:
                    seen.add(m.get("id"))
                    out.append({**m, "type": m.get("type") or c["type"]})
            more = more or (c["skip"] and len(out) > 0)
        return {"metas": out, "more": more}
    return cached(f"browse:cat:{tid}:{typ}:{skip}", 3600, build)


def _release_one(imdb):
    """{"s": "cinema" | "soon" | "", "d": "YYYY-MM-DD"} for one title, from TMDB's release dates (UK, else US).
    cinema: out at the cinema but not yet to watch at home (d = its digital date, if known)
    soon:   not out yet (d = when it comes out)"""
    found = _tmdb(f"/find/{imdb}", external_source="imdb_id")
    today = datetime.now(TZ).date().isoformat()
    tv = (found.get("tv_results") or [None])[0]
    mv = (found.get("movie_results") or [None])[0]
    if tv and not mv:
        first = tv.get("first_air_date") or ""
        return {"s": "soon", "d": first} if first and first > today else {"s": "", "d": ""}
    if not mv:
        return {"s": "", "d": ""}
    rd = _tmdb(f"/movie/{mv['id']}/release_dates").get("results", [])
    def dates(country, kinds):
        for c in rd:
            if c.get("iso_3166_1") == country:
                ds = sorted((x.get("release_date") or "")[:10] for x in c.get("release_dates", []) if x.get("type") in kinds)
                return [d for d in ds if d]
        return []
    cinema = dates("GB", (2, 3)) or dates("US", (2, 3))
    home = dates("GB", (4, 5, 6)) or dates("US", (4, 5, 6))
    first_home = home[0] if home else ""
    if first_home and first_home <= today:
        return {"s": "", "d": ""}  # you can watch it at home
    if cinema and cinema[0] > today:
        return {"s": "soon", "d": cinema[0]}
    if not cinema and not home:
        rel = mv.get("release_date") or ""
        return {"s": "soon", "d": rel} if rel and rel > today else {"s": "", "d": ""}
    if cinema and cinema[0] <= today:
        days = (datetime.now(TZ).date() - datetime.fromisoformat(cinema[0]).date()).days
        if days <= 180:
            return {"s": "cinema", "d": first_home}
    if first_home and first_home > today:
        return {"s": "soon", "d": first_home}
    return {"s": "", "d": ""}


def release_status(body):
    """For the labels on posters: {imdb: {"s", "d"}} for the ids asked about (recent titles only, kept for 12 hours)."""
    ids = [i for i in (body.get("ids") or [])[:150] if isinstance(i, str) and i.startswith("tt") and i[2:].isdigit()]
    now = int(time.time())
    with _db_lock:
        db().execute("CREATE TABLE IF NOT EXISTS release_cache (imdb TEXT PRIMARY KEY, s TEXT, d TEXT, at INTEGER)")
        marks = ",".join("?" * len(ids)) or "''"
        have = {r[0]: {"s": r[1], "d": r[2]} for r in db().execute(
            "SELECT imdb, s, d, at FROM release_cache WHERE imdb IN (" + marks + ")", ids).fetchall()
            if now - r[3] < 12 * 3600}
    todo = [i for i in ids if i not in have]
    if todo and _tmdb_creds():
        def one(i):
            try:
                return i, _release_one(i)
            except Exception:
                return i, None
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            got = [x for x in ex.map(one, todo) if x[1] is not None]
        with _db_lock:
            db().executemany("INSERT OR REPLACE INTO release_cache VALUES (?, ?, ?, ?)", [(i, r["s"], r["d"], now) for i, r in got])
            db().commit()
        have.update(dict(got))
    return {"items": {i: r for i, r in have.items() if r.get("s")}}


def similar(typ, imdb):
    """'You may also like' for a film or show: TMDB's recommendations (people who liked this also liked),
    topped up with its 'similar' list if that's short. Cached for a day."""
    kind = "movie" if typ == "movie" else "tv"

    def build():
        found = _tmdb(f"/find/{imdb}", external_source="imdb_id")
        hits = found.get("movie_results" if kind == "movie" else "tv_results") or []
        if not hits:
            return {"metas": []}
        tid = hits[0]["id"]
        res = _tmdb(f"/{kind}/{tid}/recommendations").get("results", [])
        if len(res) < 12:
            seen = {r["id"] for r in res}
            res += [r for r in _tmdb(f"/{kind}/{tid}/similar").get("results", []) if r["id"] not in seen]
        res = [r for r in res if r.get("poster_path") and (r.get("vote_count") or 0) >= 20][:20]
        return {"metas": [m for m in _to_metas(res, kind) if m["id"] != imdb]}
    try:
        return cached(f"similar:{kind}:{imdb}", 24 * 3600, build)
    except Exception as e:
        return {"metas": [], "error": str(e)}


def trailer(typ, imdb):
    """The YouTube id of a film's or show's trailer (TMDB): an official English trailer first, then any trailer,
    then a teaser. Cached for a week."""
    kind = "movie" if typ == "movie" else "tv"

    def build():
        found = _tmdb(f"/find/{imdb}", external_source="imdb_id")
        hits = found.get("movie_results" if kind == "movie" else "tv_results") or []
        if not hits:
            return {"yt": ""}
        vids = [v for v in _tmdb(f"/{kind}/{hits[0]['id']}/videos").get("results", [])
                if v.get("site") == "YouTube" and re.fullmatch(r"[A-Za-z0-9_-]{6,20}", v.get("key") or "")]
        order = {"Trailer": 0, "Teaser": 1}
        vids = sorted((v for v in vids if v.get("type") in order),
                      key=lambda v: (order[v["type"]], not v.get("official"), v.get("iso_639_1") != "en"))
        return {"yt": vids[0]["key"] if vids else ""}
    try:
        return cached(f"trailer:{kind}:{imdb}", 7 * 24 * 3600, build)
    except Exception as e:
        return {"yt": "", "error": str(e)}


def _ytdlp():
    exe = shutil.which("yt-dlp") or str(Path.home() / ".local/bin/yt-dlp")
    return [exe] if Path(exe).exists() else ["python3", "-m", "yt_dlp"]


def trailer_play(typ, imdb):
    """A playable stream of the trailer (yt-dlp on the Pi): Ember for Apple TV plays it in its own player.
    YouTube's links are tied to the address that asked, which is your home's, so the TV can use them. Kept 3 hours."""
    yt = trailer(typ, imdb).get("yt", "")
    if not yt:
        return {"yt": "", "url": ""}

    def build():
        cmd = _ytdlp() + ["-g", "--no-warnings", "--no-playlist",
                          "-f", "best[height<=1080][vcodec!=none][acodec!=none]/best",
                          f"https://www.youtube.com/watch?v={yt}"]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        urls = [u for u in out.stdout.split() if u.startswith("http")]
        if not urls:
            raise RuntimeError((out.stderr or "yt-dlp found nothing").strip().splitlines()[-1][:200])
        return {"yt": yt, "url": urls[0]}
    try:
        return cached(f"trailerplay:{yt}", 3 * 3600, build)
    except Exception as e:
        return {"yt": yt, "url": "", "error": str(e)}


def in_cinemas():
    """Films showing in UK cinemas now (TMDB 'now playing', GB): {"items": [imdb, ...]}. Refreshed every 6 hours."""
    def build():
        res = []
        for page in (1, 2, 3, 4, 5):
            r = _tmdb("/movie/now_playing", region="GB", page=page)
            res += r.get("results", [])
            if page >= (r.get("total_pages") or 1):
                break
        with concurrent.futures.ThreadPoolExecutor(8) as ex:
            ids = list(ex.map(lambda x: _imdb_for("movie", x["id"]), res))
        return sorted({i for i in ids if i and i.startswith("tt")})
    try:
        return {"items": cached("cinemas", 6 * 3600, build)}
    except Exception as e:
        return {"items": [], "error": str(e)}


def browse_tiles():
    try:
        return cached("browse:tiles", 24 * 3600, _build_tiles)
    except Exception as e:
        return {"groups": [], "error": str(e)}


def browse_list(kind, tid, typ="movie", page=1):
    """The titles behind a tile. typ: movie or series."""
    k = "movie" if typ == "movie" else "tv"

    def build():
        if kind == "service":
            r = _tmdb(f"/discover/{k}", with_watch_providers=tid, watch_region="GB", sort_by="popularity.desc", page=page)
            return {"title": "", "metas": _to_metas(r.get("results", []), k), "pages": r.get("total_pages", 1)}
        if kind == "genre":
            gid = int(tid)
            if k == "tv":  # film genre -> the closest TV genre
                gid = {28: 10759, 878: 10765, 14: 10765, 53: 9648, 27: 9648, 10752: 10768}.get(gid, gid)
            r = _tmdb(f"/discover/{k}", with_genres=gid, sort_by="popularity.desc", page=page, **{"vote_count.gte": 50})
            return {"title": "", "metas": _to_metas(r.get("results", []), k), "pages": r.get("total_pages", 1)}
        if kind == "company":
            r = _tmdb(f"/discover/{k}", with_companies=tid, sort_by="popularity.desc", page=page)
            return {"title": "", "metas": _to_metas(r.get("results", []), k), "pages": r.get("total_pages", 1)}
        if kind == "decade":
            d = int(tid)
            r = _tmdb("/discover/movie", sort_by="vote_count.desc", page=page, **{"primary_release_date.gte": f"{d}-01-01",
                                                                               "primary_release_date.lte": f"{d + 9}-12-31"})
            return {"title": f"{d}s", "metas": _to_metas(r.get("results", []), "movie"), "pages": r.get("total_pages", 1)}
        if kind == "person":
            cr = _tmdb(f"/person/{tid}/movie_credits")
            films = [c for c in cr.get("crew", []) if c.get("job") == "Director"]
            films.sort(key=lambda c: c.get("release_date") or "", reverse=True)
            return {"title": "", "metas": _to_metas(films, "movie"), "pages": 1}
        if kind == "collection":
            c = _tmdb(f"/collection/{tid}")
            parts = sorted(c.get("parts", []), key=lambda x: x.get("release_date") or "9999")
            return {"title": c.get("name", ""), "metas": _to_metas(parts, "movie"), "pages": 1, "overview": c.get("overview", "")}
        raise ValueError("unknown tile kind")
    return cached(f"browse:{kind}:{tid}:{k}:{page}", 6 * 3600, build)


# ------------------------------------------------------------------ HTTP


class Handler(BaseHTTPRequestHandler):
    server_version = "ember-feed/1.0"

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Access-Control-Allow-Origin", "*")  # Ember PC reads this from its own window
        self.end_headers()
        self.wfile.write(body)

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type, X-Ember-Key")
        self.end_headers()

    def _base(self):
        host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host") or f"localhost:{CFG['port']}"
        proto = self.headers.get("X-Forwarded-Proto", "http")
        return f"{proto}://{host}"

    def _allowed(self):
        """At home everything is open. Through the Cloudflare tunnel (lucamedia.org) every request needs the key
        from config.json ("api_key"), sent as the X-Ember-Key header - and with no key set, outside access is refused."""
        if not self.headers.get("CF-Connecting-IP"):
            return True
        key = CFG.get("api_key", "")
        return bool(key) and self.headers.get("X-Ember-Key", "") == key

    def do_POST(self):
        path = urllib.parse.urlparse(self.path).path
        if not self._allowed():
            self._json({"error": "key needed"}, 401)
            return
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
            body = json.loads(self.rfile.read(min(n, 65536)) or b"{}")
            if path == "/progress/report":
                self._json(report(body))
            elif path == "/progress/dismiss":
                self._json(dismiss(body))
            elif path == "/watchlist":
                self._json(watchlist_set(body))
            elif path == "/release":
                self._json(release_status(body))
            elif path == "/settings/shared":
                self._json(shared_settings(body))
            elif path == "/progress/watched":
                self._json(mark_watched(body))
            elif path == "/pick/failed":
                self._json(stream_failed(body))
            elif path == "/match/new":
                self._json(match_new(body))
            elif re.fullmatch(r"/match/[A-Za-z0-9]{4}/join", path):
                self._json(match_join(path.split("/")[2], body))
            elif re.fullmatch(r"/match/[A-Za-z0-9]{4}/vote", path):
                self._json(match_vote(path.split("/")[2], body))

            else:
                self._json({"error": "not found"}, 404)
        except ValueError as e:
            self._json({"error": str(e)}, 400)
        except Exception as e:
            self._json({"error": str(e)}, 500)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path != "/health" and not self._allowed():
            self._json({"error": "key needed"}, 401)
            return
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
            elif re.fullmatch(r"/picks/[A-Za-z0-9_=-]+/manifest\.json", path):
                self._json(picks_manifest(path.split("/")[2]))
            elif re.fullmatch(r"/picks/[A-Za-z0-9_=-]+/stream/(movie|series)/tt[0-9:]+\.json", path):
                parts = path.split("/")
                self._json(picks_streams(parts[2], parts[4], parts[5][:-5]))
            elif re.fullmatch(r"/logo/[0-9a-f]{20}", path):
                f = LOGO_DIR / path.split("/")[2]
                if not f.exists():
                    self._json({"error": "not found"}, 404)
                    return
                body = f.read_bytes()
                ctype = "image/png" if body[:4] == b"\x89PNG" else "image/jpeg" if body[:2] == b"\xff\xd8" \
                    else "image/svg+xml" if body.lstrip()[:1] == b"<" else "application/octet-stream"
                self.send_response(200)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "public, max-age=2592000")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(body)
            elif path == "/jellyfin/summary":
                self._json(jellyfin_summary())
            elif path == "/watchlist":
                self._json(watchlist())
            elif path == "/settings/shared":
                self._json(shared_settings())
            elif path == "/cinemas":
                self._json(in_cinemas())
            elif path == "/watched":
                self._json(watched_status())
            elif path == "/progress/dismissed":
                self._json({"dismissed": _dismissed()})
            elif re.fullmatch(r"/similar/(movie|series)/tt\d+", path):
                _, _, typ, imdb = path.split("/")
                self._json(similar(typ, imdb))
            elif re.fullmatch(r"/trailer/(movie|series)/tt\d+/play", path):
                _, _, typ, imdb, _ = path.split("/")
                self._json(trailer_play(typ, imdb))
            elif re.fullmatch(r"/trailer/(movie|series)/tt\d+", path):
                _, _, typ, imdb = path.split("/")
                self._json(trailer(typ, imdb))
            elif path == "/browse/tiles":
                self._json(browse_tiles())
            elif re.fullmatch(r"/browse/cat/[a-z0-9-]+", path):
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                self._json(browse_cat(path.split("/")[3], (q.get("type") or ["movie"])[0], int((q.get("skip") or [0])[0]),
                                     (q.get("sort") or [""])[0]))
            elif re.fullmatch(r"/browse/(service|genre|company|decade|person|collection)/\d+", path):
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                _, _, kind, tid = path.split("/")
                self._json(browse_list(kind, tid, (q.get("type") or ["movie"])[0], int((q.get("page") or [1])[0])))
            elif path == "/upcoming":
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                self._json(upcoming(days=int((q.get("days") or [7])[0])))
            elif path == "/wrapped":
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                self._json(wrapped((q.get("year") or [None])[0]))
            elif re.fullmatch(r"/m/[A-Za-z0-9]{4}", path):
                body = MATCH_PAGE.encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            elif re.fullmatch(r"/match/[A-Za-z0-9]{4}", path):
                self._json(match_state(path.split("/")[2]))
            elif re.fullmatch(r"/match/[A-Za-z0-9]{4}/kind", path):
                self._json(match_kind(path.split("/")[2]))
            elif re.fullmatch(r"/match/[A-Za-z0-9]{4}/qr.png", path):
                png = match_qr(path.split("/")[2], self._base())
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Content-Length", str(len(png)))
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                self.wfile.write(png)
            elif path.startswith("/pick/"):
                parts = path.split("/")  # /pick/<type>/<id>
                q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
                g = lambda k, d=None: (q.get(k) or [d])[0]
                rt = g("runtime")
                args = (parts[2], urllib.parse.unquote(parts[3]), g("aio"), g("quality", "4k"),
                        float(rt) if rt else None, g("passthrough") == "1")
                # the same question within 90 seconds gets the same answer (no flip-flopping between tests)
                self._json(cached("pick:" + "|".join(map(str, args)), 90, lambda: pick(*args)))
            elif path.startswith("/progress/tt") and path[len("/progress/tt"):].isdigit():
                self._json(title_positions(path[len("/progress/"):]))
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
    db()  # create the progress store if it's new
    if all(trakt_creds()):
        threading.Thread(target=_snapshot_loop, daemon=True).start()
    else:
        print("[ember-feed] no Trakt login found: progress store runs without Trakt", flush=True)
    start_jellyfin_proxy()
    srv = ThreadingHTTPServer(("0.0.0.0", CFG["port"]), Handler)
    print(f"[ember-feed] listening on :{CFG['port']}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
