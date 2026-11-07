// Ember PC: your addon rows, search, title pages, streams from AIOStreams, played in mpv, progress on the Pi.
"use strict";
const $ = (s, el = document) => el.querySelector(s);
const h = (html) => { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstElementChild; };
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const store = {
  get: (k, d = "") => { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch (e) {} },
};
// On the Chromecast the same page runs in Ember TV: window.EmberTV plays streams in the TV's player instead of mpv.
const TV = !!window.EmberTV;
const tvInvoke = async (cmd, a = {}) => {
  if (cmd === "play") { const r = EmberTV.play(JSON.stringify(a)); if (String(r).startsWith("error")) throw new Error(r); return r; }
  if (cmd === "playing") return EmberTV.playing();
  if (cmd === "last_exit") return EmberTV.lastExit();
  if (cmd === "open_trailer") return EmberTV.openTrailer(a.id);
  if (cmd === "player_log") return "The TV player doesn't keep a log here.";
  return null;
};
const invoke = window.__TAURI__ ? window.__TAURI__.core.invoke : TV ? tvInvoke : null;
if (TV) {
  document.documentElement.classList.add("tv");
  // lay the page out 1600 wide and let the TV scale it up: everything about 20% bigger than on a 1080p PC screen
  const vp = document.createElement("meta"); vp.name = "viewport"; vp.content = "width=1600, user-scalable=no";
  document.head.appendChild(vp);
  try { if (localStorage.getItem("motion") === null) localStorage.setItem("motion", "0"); } catch (e) {}
}
const CINEMETA = "https://v3-cinemeta.strem.io";
const feed = () => store.get("feed", "http://192.168.4.141:8090").replace(/\/+$/, "");
const aioBase = () => store.get("aio").replace(/\/manifest\.json.*$/, "");

let progress = {};          // imdb -> where you are (from the Pi)
const metaCache = new Map();

function toast(msg, ms = 3500) {
  const t = $("#toast"); t.textContent = msg; t.classList.add("show");
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove("show"), ms);
}
async function getJson(url, ms = 15000) {
  const c = new AbortController(); const timer = setTimeout(() => c.abort(), ms);
  try { const r = await fetch(url, { signal: c.signal }); if (!r.ok) throw new Error("HTTP " + r.status); return await r.json(); }
  finally { clearTimeout(timer); }
}
const fmt = (s) => { s = Math.round(s || 0); const hh = Math.floor(s / 3600), m = Math.floor(s / 60) % 60, x = s % 60;
  return (hh ? hh + ":" + String(m).padStart(2, "0") : m) + ":" + String(x).padStart(2, "0"); };
const poster = (m) => m.poster || (m.id && m.id.startsWith("tt") ? `https://images.metahub.space/poster/medium/${m.id}/img` : "");
const backdrop = (m) => m.background || (m.id && m.id.startsWith("tt") ? `https://images.metahub.space/background/medium/${m.id}/img` : "");

async function meta(type, id) {
  const k = type + ":" + id;
  const hit = metaCache.get(k);
  if (hit && Date.now() - hit.t < 6 * 3600e3) return hit.p; // details (and episode lists) refresh every 6 hours
  const p = getJson(`${CINEMETA}/meta/${type}/${id}.json`).then(j => j.meta || {}).catch(() => ({}));
  metaCache.set(k, { t: Date.now(), p });
  return p;
}
// What you've watched (all of it: ✓) or started (◐), for the badge in the corner of every poster.
let watchedMap = {}, watchedAt = 0;
async function loadWatched() {
  if (Date.now() - watchedAt < 120e3) return;
  try { watchedMap = (await getJson(`${feed()}/watched`, 8000)).items || {}; watchedAt = Date.now(); } catch (e) {}
}
// A drawn play triangle: the ▶ character turns into a blue emoji box on the Chromecast.
const PLAY = `<svg class="pl" viewBox="0 0 24 24" aria-hidden="true"><path d="M7 4.5v15l12.5-7.5z"/></svg>`;

// Loves: watched isn't the same as liked. Double-click the tick for a heart; it steers the recommendation rows.
let lovedIds = new Set();
const HEART = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 21s-7.5-4.6-9.6-9.3C.9 8.3 3 4.5 6.7 4.5c2.1 0 3.6 1.2 4.3 2.4h2c.7-1.2 2.2-2.4 4.3-2.4 3.7 0 5.8 3.8 4.3 7.2C19.5 16.4 12 21 12 21z"/></svg>`;
async function loadLoves() { try { lovedIds = new Set((await getJson(`${feed()}/loves`, 8000)).items || []); refreshBadges(); } catch (e) {} }
const badgeHtml = (id) => lovedIds.has(id) ? HEART : watchedMap[id] === "done" ? `✓` : watchedMap[id] === "partial" ? `<i></i>` : `✓`;
const badgeClass = (id) => lovedIds.has(id) ? "loved" : watchedMap[id] === "done" ? "done" : watchedMap[id] === "partial" ? "part" : "add";
const badgeTitle = (id) => lovedIds.has(id) ? "Loved (double-click to take the love off)" : watchedMap[id] === "done" ? "Watched (click to undo, double-click to love it)" : watchedMap[id] === "partial" ? "Started (click to mark it all watched)" : "Mark as watched (double-click to love it)";
function refreshBadges(id) {
  document.querySelectorAll(id ? `[data-wid="${id}"] .wbadge` : "[data-wid] .wbadge").forEach(x => {
    const i = x.closest("[data-wid]").dataset.wid;
    x.className = "wbadge " + badgeClass(i); x.innerHTML = badgeHtml(i); x.title = badgeTitle(i);
  });
}
/** Love a title (or take the love off): on the Pi and Trakt (a 10/10); loving it also marks it watched. */
async function setLove(type, id, name, on) {
  try {
    const r = await fetch(`${feed()}/love`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ imdb: id, type, on }) });
    if (!r.ok) throw new Error("HTTP " + r.status);
  } catch (e) { toast("Couldn't save that: " + e.message); return false; }
  if (on) lovedIds.add(id); else lovedIds.delete(id);
  if (on && watchedMap[id] !== "done") await markTitle(type, id, true);
  refreshBadges(id);
  toast(on ? `Loved ${name}. Your recommendations will lean towards it.` : `Took the love off ${name}.`);
  return true;
}
loadLoves();
const badge = (id) => `<button class="wbadge ${badgeClass(id)}" title="${badgeTitle(id)}">${badgeHtml(id)}</button>`;

/** Marks a whole film or show watched (or not) from its poster: on the Pi and in Trakt. */
async function markTitle(type, id, watched) {
  let episodes = [];
  if (type === "series") {
    const m = await meta("series", id);
    const now = new Date();
    episodes = (m.videos || []).filter(v => v.season > 0 && (!v.released || new Date(v.released) <= now)).map(v => [v.season, v.episode]);
    if (!episodes.length) { toast("Couldn't find its episodes to mark."); return false; }
  }
  try {
    const r = await fetch(`${feed()}/progress/watched`, { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ imdb: id, type, watched, episodes, all: type === "series" }) });
    if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || "HTTP " + r.status);
  } catch (e) { toast("Couldn't update lucapi: " + e.message); return false; }
  if (watched) watchedMap[id] = "done"; else delete watchedMap[id];
  if (watched) delete progress[id];
  return true;
}
// One click handler for every badge on every page: a click marks it watched (or not); a double-click loves it.
const badgeClicks = new WeakMap();
document.addEventListener("click", async (e) => {
  const b = e.target.closest(".wbadge");
  if (!b) return;
  e.stopPropagation(); e.preventDefault();
  const holder = b.closest("[data-wid]");
  if (!holder) return;
  const id = holder.dataset.wid, type = holder.dataset.wtype, name = holder.dataset.wname || "it";
  if (badgeClicks.has(b)) { // the second click: love it (or take the love off)
    clearTimeout(badgeClicks.get(b)); badgeClicks.delete(b);
    b.classList.add("busy"); await setLove(type, id, name, !lovedIds.has(id)); b.classList.remove("busy");
    return;
  }
  badgeClicks.set(b, setTimeout(() => { badgeClicks.delete(b); badgeClick(b, holder, id, type, name); }, 280));
}, true);
/** Mark a title watched or unwatched from anywhere (a tick, the TV's hold-OK menu); on a watchlist row, watched
 *  also takes it off the watchlist. */
async function setWatched(type, id, name, on, fromWall) {
  if (!(await markTitle(type, id, on))) return false;
  refreshBadges(id);
  if (on && fromWall) {
    try {
      const r = await fetch(`${feed()}/watchlist`, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ imdb: id, type, add: false }) });
      if (!r.ok) throw new Error("HTTP " + r.status);
      watchlistIds.delete(id); applyBookmarks();
      document.querySelectorAll(`.strip.wall [data-wid="${id}"]`).forEach(p => {
        const row = p.closest(".row"), n = row && $("h2 small", row);
        p.style.transition = "opacity .3s, transform .3s"; p.style.opacity = "0"; p.style.transform = "scale(.9)";
        setTimeout(() => { p.remove(); if (n) n.textContent = Math.max(0, (+n.textContent || 1) - 1); }, 300);
      });
      toast(`Marked ${name} as watched and took it off your watchlist.`);
    } catch (err) { toast(`Marked ${name} as watched, but couldn't take it off your watchlist.`); }
  } else toast(on ? `Marked ${name} as watched.` : `${name} is unwatched again.`);
  return true;
}
// for the TV's hold-OK menu (tv.js)
window.emberTitle = {
  state: (id) => ({ watched: watchedMap[id] === "done", loved: lovedIds.has(id) }),
  watched: (type, id, name, on, fromWall) => setWatched(type, id, name, on, fromWall),
  love: (type, id, name, on) => setLove(type, id, name, on),
};

async function badgeClick(b, holder, id, type, name) {
  if (lovedIds.has(id)) { toast(`${name} is loved. Double-click to take the love off.`); return; }
  const undo = watchedMap[id] === "done";
  if (undo && type === "series" && !b.dataset.armed) { // a whole show: ask with a second click
    b.dataset.armed = "1"; b.classList.add("ask"); b.title = "Click again to mark it unwatched";
    setTimeout(() => { delete b.dataset.armed; b.classList.remove("ask"); }, 4000);
    return;
  }
  b.classList.add("busy");
  await setWatched(type, id, name, !undo, !!b.closest(".strip.wall"));
  b.classList.remove("busy");
}
async function loadProgress() {
  const w = loadWatched();
  try { progress = (await getJson(`${feed()}/progress`, 6000)).items || {}; } catch (e) { progress = progress || {}; }
  await w;
}
function progressLine(p) {
  if (!p) return "";
  const ep = p.type === "series" && p.season ? `S${p.season} · E${p.episode}${p.episodeTitle ? " · " + p.episodeTitle : ""}  ·  ` : "";
  const left = p.duration ? Math.max(1, Math.round((p.duration - p.position) / 60)) + " min left" : Math.round(p.progress) + "% through";
  return `${ep}${fmt(p.position)} in, ${left}  ·  ${p.device || ""}${p.ago ? ", " + p.ago + " ago" : ""}`;
}

// ---------------------------------------------------------------- loading screen

const loader = (() => {
  const el = $("#loader");
  let steps = [], hideTimer = 0;
  return {
    /** opts: { art, logo, title, sub, steps: ["Finding streams", ...] } */
    show(o = {}) {
      clearTimeout(hideTimer);
      $(".ld-bg", el).style.backgroundImage = o.art ? `url('${o.art}')` : "none";
      $(".ld-title", el).innerHTML = (o.logo ? `<img src="${esc(o.logo)}" alt="">` : `<h2>${esc(o.title || "Ember")}</h2>`)
        + (o.sub ? `<div class="sub">${esc(o.sub)}</div>` : "");
      const img = $(".ld-title img", el); if (img) img.onerror = () => img.replaceWith(h(`<h2>${esc(o.title || "")}</h2>`));
      steps = o.steps || [];
      $(".ld-steps", el).innerHTML = steps.map(t => `<div>${esc(t)}</div>`).join("");
      $(".ld-note", el).textContent = "";
      el.hidden = false; requestAnimationFrame(() => el.classList.add("show"));
      this.step(0);
    },
    step(i, label) {
      $(".ld-steps", el).querySelectorAll("div").forEach((d, k) => {
        d.classList.toggle("done", k < i); d.classList.toggle("on", k === i);
        if (k === i && label) d.innerHTML = label;
      });
    },
    note(t) { $(".ld-note", el).textContent = t || ""; },
    hide(delay = 0) {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => { el.classList.remove("show"); setTimeout(() => { if (!el.classList.contains("show")) el.hidden = true; }, 380); }, delay);
    },
  };
})();

// ---------------------------------------------------------------- navigation

const pages = { home: showHome, search: showSearch, films: () => showBrowse("movie"), series: () => showBrowse("series"),
  settings: showSettings, match: showMatch, year: showYear, apps: showApps };

/** Ember TV only: the apps on the TV (Netflix, YouTube...), most used first. */
async function showApps() {
  const v = $("#view");
  v.innerHTML = `<div class="page-h"><h1>Apps</h1><div class="muted">Everything installed on this TV</div></div><div class="apps fade-in"></div>`;
  if (!TV) { $(".apps", v).innerHTML = `<div class="empty">Apps are on Ember TV.</div>`; return; }
  let list = [];
  try { list = JSON.parse(EmberTV.apps()); } catch (e) {}
  const box = $(".apps", v);
  // the Chromecast's own Settings and the Play Store aren't in Google TV's app list, so they're always first here
  if (EmberTV.openSystem) {
    const sys = [["settings", "Settings", `<svg viewBox="0 0 24 24"><path d="M12 8.5a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7Zm8.6 4.9-1.9-.4a7 7 0 0 1-.6 1.5l1.1 1.6-1.8 1.8-1.6-1.1c-.5.3-1 .5-1.5.6l-.4 1.9h-2.6l-.4-1.9a7 7 0 0 1-1.5-.6l-1.6 1.1-1.8-1.8 1.1-1.6c-.3-.5-.5-1-.6-1.5l-1.9-.4v-2.6l1.9-.4c.1-.5.3-1 .6-1.5L4.6 6.9l1.8-1.8 1.6 1.1c.5-.3 1-.5 1.5-.6l.4-1.9h2.6l.4 1.9c.5.1 1 .3 1.5.6l1.6-1.1 1.8 1.8-1.1 1.6c.3.5.5 1 .6 1.5l1.9.4v2.8Z"/></svg>`],
                 ["store", "Play Store", `<svg viewBox="0 0 24 24"><path d="M4.5 3.2 13.4 12l-8.9 8.8c-.3-.2-.5-.6-.5-1V4.2c0-.4.2-.8.5-1Zm10 7.7L6.6 3l10.1 5.7-2.2 2.2Zm0 2.2 2.2 2.2L6.6 21l7.9-7.9Zm3.4-3.7 2.6 1.5c.7.4.7 1.4 0 1.8l-2.6 1.5-2.4-2.4 2.4-2.4Z"/></svg>`]];
    for (const [what, label, icon] of sys) {
      const el = h(`<button class="apptile sys" title="${label}"><span class="ai">${icon}<b>${label}</b></span></button>`);
      el.onclick = () => EmberTV.openSystem(what);
      box.appendChild(el);
    }
    list = list.filter((a) => !/^com\.android\.(vending|tv\.settings)$/.test(a.pkg));
  }
  for (const a of list) {
    const el = h(`<button class="apptile" title="${esc(a.label)}">${a.banner ? `<img src="${a.banner}" alt="">` : `<span class="ai">${a.icon ? `<img src="${a.icon}" alt="">` : ""}<b>${esc(a.label)}</b></span>`}</button>`);
    el.onclick = () => EmberTV.launchApp(a.pkg);
    box.appendChild(el);
  }
  if (!list.length) box.innerHTML = `<div class="empty">No apps found.</div>`;
}
const hiddenRows = () => { try { return new Set(JSON.parse(store.get("hiddenRows", "[]"))); } catch (e) { return new Set(); } };
const setHiddenRows = (set) => store.set("hiddenRows", JSON.stringify([...set]));
const catKey = (c) => `cat:${c.type}:${c.id}`;
const deviceName = () => store.get("deviceName", TV ? "Ember TV" : "Ember PC") || (TV ? "Ember TV" : "Ember PC");
let navStack = [];
// Home, Films and Series are kept when you leave them (for 10 minutes, or until something is played):
// Back, or coming back to the tab, shows them again as they were, on the same row and item.
const KEEP = new Set(["home", "films", "series"]);
const kept = {};
const keptPages = new Set();
function keepPage() {
  const cur = navStack[navStack.length - 1];
  const v = $("#view");
  if (!cur || !KEEP.has(cur[0]) || !v.firstChild) return;
  const snap = { nodes: [...v.childNodes], top: v.scrollTop, strips: [...v.querySelectorAll(".strip")].map(x => x.scrollLeft),
                 focus: window.emberTvCurrent ? window.emberTvCurrent() : null, at: Date.now() };
  kept[cur[0]] = snap;
  keptPages.clear(); Object.values(kept).forEach(k => k.nodes.forEach(n => n.querySelectorAll && n.querySelectorAll(".hero").forEach(x => keptPages.add(x))));
  snap.nodes.forEach(n => n.classList && n.classList.contains("hero") && keptPages.add(n));
}
function forgetKept() { for (const k of Object.keys(kept)) delete kept[k]; keptPages.clear(); }
function restorePage(page, where) {
  const snap = kept[page];
  if (!snap || Date.now() - snap.at > 10 * 60 * 1000) return false;
  const v = $("#view");
  v.replaceChildren(...snap.nodes);
  delete kept[page];
  [...v.querySelectorAll(".strip")].forEach((x, i) => { x.scrollLeft = where ? (snap.strips[i] || 0) : 0; });
  v.scrollTop = where ? snap.top : 0;
  if (where && snap.focus && snap.focus.isConnected && window.emberTvFocus) setTimeout(() => window.emberTvFocus(snap.focus), 30);
  return true;
}
function go(page, ...args) {
  document.querySelectorAll(".nav").forEach(b => b.classList.toggle("on", b.dataset.page === page));
  keepPage();
  navStack.push([page, args]);
  if (navStack.length > 30) navStack.shift();
  if (KEEP.has(page) && !args.length && restorePage(page, false)) return;
  const fn = page === "title" ? showTitle : page === "tile" ? showTile : pages[page];
  $("#view").scrollTop = 0;
  fn(...args);
}
function back() {
  navStack.pop();
  const prev = navStack[navStack.length - 1] || ["home", []];
  if (KEEP.has(prev[0])) {
    document.querySelectorAll(".nav").forEach(b => b.classList.toggle("on", b.dataset.page === prev[0]));
    if (!navStack.length) navStack.push(prev);
    if (restorePage(prev[0], true)) return;
  }
  navStack.pop();
  go(prev[0], ...prev[1]);
}
document.querySelectorAll(".nav").forEach(b => b.onclick = () => go(b.dataset.page));
document.addEventListener("keydown", e => {
  if (e.key === "Escape" && navStack.length && navStack[navStack.length - 1][0] === "title") back();
  if ((e.ctrlKey && e.key === "f") || (e.key === "/" && document.activeElement.tagName !== "INPUT")) { e.preventDefault(); go("search"); }
});

// ---------------------------------------------------------------- cards and rows

// Your watchlist (Trakt, through lucapi): every poster of a title on it carries an amber bookmark, on every page.
let watchlistIds = new Set();
const BOOKMARK = `<i class="bmk" aria-hidden="true"><svg viewBox="0 0 24 32"><path d="M0 0h24v32l-12-8-12 8z"/></svg></i>`;
async function loadWatchlist() {
  try { watchlistIds = new Set((await getJson(`${feed()}/watchlist`, 8000)).items || []); applyBookmarks(); } catch (e) {}
}
function applyBookmarks(root = document) {
  root.querySelectorAll(".poster[data-wid], .t10-art[data-wid], .spot[data-wid]").forEach(el => {
    const on = watchlistIds.has(el.dataset.wid), has = el.querySelector(":scope > .bmk");
    el.classList.toggle("bm", on);
    if (on && !has) el.insertAdjacentHTML("afterbegin", BOOKMARK); else if (!on && has) has.remove();
  });
}
loadWatchlist();

// Titles as their logos (the film's or show's own lettering), loaded once and remembered; the name only when
// there's no logo. Either fades in, never pops.
const logoP = new Map(), logoReady = new Map();
function logoFor(m, type) {
  if (!m || !m.id) return Promise.resolve("");
  if (logoP.has(m.id)) return logoP.get(m.id);
  const tryUrl = (u) => new Promise(res => {
    if (!u) return res("");
    const i = new Image();
    i.onload = () => res(i.naturalWidth > 4 ? u : "");
    i.onerror = () => res("");
    i.src = u;
  });
  const p = (async () => {
    if (m.logo) { const u = await tryUrl(m.logo); if (u) return u; }
    if (m.id.startsWith("tt")) { const u = await tryUrl(`https://images.metahub.space/logo/medium/${m.id}/img`); if (u) return u; }
    const full = await meta(m.type || type, m.id).catch(() => ({}));
    return full && full.logo ? tryUrl(full.logo) : "";
  })().then(u => { logoReady.set(m.id, u); return u; });
  logoP.set(m.id, p);
  return p;
}
/** The title for a card: <div class="ttl"> holding the logo, or the name if there isn't one. */
function titleArt(m, type) {
  const box = h(`<div class="ttl"></div>`);
  const name = () => h(`<span class="ttl-name">${esc(m.name || "")}</span>`);
  const logo = (u) => h(`<img class="ttl-logo" src="${esc(u)}" alt="${esc(m.name || "")}">`);
  if (logoReady.has(m.id)) { // known already: straight in, no fade
    const u = logoReady.get(m.id), el = u ? logo(u) : name();
    el.classList.add("on", "now"); box.appendChild(el); return box;
  }
  let shown = null;
  const show = (el) => {
    if (shown) shown.remove();
    shown = el; box.appendChild(el);
    requestAnimationFrame(() => requestAnimationFrame(() => el.classList.add("on")));
  };
  const late = setTimeout(() => { if (!shown) show(name()); }, 1200);
  logoFor(m, type).then(u => { clearTimeout(late); if (u) show(logo(u)); else if (!shown) show(name()); });
  return box;
}

function card(m, type) {
  const p = progress[m.id];
  const yr = (String(m.releaseInfo || m.year || "").match(/\d{4}/) || [""])[0];
  const el = h(`<div class="poster${watchlistIds.has(m.id) ? " bm" : ""}" title="${esc(m.name)}" data-wid="${esc(m.id)}" data-wtype="${esc(m.type || type)}" data-wname="${esc(m.name)}" data-year="${yr}" style="background-image:url('${esc(poster(m))}')">
    ${watchlistIds.has(m.id) ? BOOKMARK : ""}${poster(m) ? "" : `<div class="name">${esc(m.name)}</div>`}${badge(m.id)}
    ${p ? `<div class="bar"><i style="width:${Math.max(3, Math.min(100, p.progress))}%"></i></div>` : ""}</div>`);
  el.onclick = () => go("title", m.type || type, m.id, m);
  return el;
}
function row(title, metas, type, onPick) {
  const label = typeof title === "object" ? `${esc(title.name)} <span class="kind">${title.kind}</span>` : esc(title);
  const r = h(`<section class="row fade-in"><h2>${label} <small>${metas.length}</small></h2><div class="strip"></div></section>`);
  const strip = $(".strip", r);
  metas.forEach(m => {
    const c = card(m, type);
    strip.appendChild(c);
  });
  // mouse wheel scrolls the row sideways
  strip.addEventListener("wheel", e => { if (Math.abs(e.deltaY) > Math.abs(e.deltaX) && e.shiftKey) { strip.scrollLeft += e.deltaY; e.preventDefault(); } }, { passive: false });
  return r;
}

// ---------------------------------------------------------------- in cinemas / coming soon
// Recent titles are checked with lucapi (TMDB release dates); the label sits top left of the poster.
const relCache = {};
const relDate = (d) => {
  if (!d) return "";
  const t = new Date(d + "T12:00:00"), same = t.getFullYear() === new Date().getFullYear();
  return t.toLocaleDateString("en-GB", same ? { day: "numeric", month: "short" } : { day: "numeric", month: "short", year: "numeric" });
};
const relLabel = (r) => !r || !r.s ? "" : r.s === "cinema" ? "In cinemas" : r.d ? `Coming ${relDate(r.d)}` : "Coming soon";
const relLine = (r) => !r || !r.s ? "" : r.s === "cinema"
  ? `In cinemas now${r.d ? ` · to watch at home from ${relDate(r.d)}` : " · not yet out to watch at home"}`
  : `Not out yet${r.d ? ` · comes out ${relDate(r.d)}` : ""}`;
function relApply(el) {
  const r = relCache[el.dataset.wid];
  if (!r || !r.s || el.querySelector(".rel")) return;
  el.insertAdjacentHTML("beforeend", `<span class="rel ${r.s}">${esc(relLabel(r))}</span>`);
}
let relQueue = new Set(), relTimer = 0;
async function relFlush() {
  const ids = [...relQueue].filter(i => !(i in relCache)).slice(0, 150);
  relQueue = new Set();
  if (ids.length) {
    try {
      const r = await fetch(`${feed()}/release`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ ids }) });
      const items = (await r.json()).items || {};
      for (const i of ids) relCache[i] = items[i] || { s: "" };
    } catch (e) { return; }
  }
  document.querySelectorAll(".poster[data-wid]").forEach(relApply);
}
function relScan() {
  if (watchlistIds.size) applyBookmarks(document.getElementById("view"));
  const thisYear = new Date().getFullYear();
  document.querySelectorAll("#view .poster[data-wid]:not([data-rel]), #view .t10-art[data-wid]:not([data-rel]), #view .spot[data-wid]:not([data-rel])").forEach(el => {
    el.dataset.rel = "1";
    const y = +el.dataset.year;
    if (y && y < thisYear - 1) return; // older titles are out everywhere
    if (el.dataset.wid in relCache) relApply(el); else relQueue.add(el.dataset.wid);
  });
  if (relQueue.size) { clearTimeout(relTimer); relTimer = setTimeout(relFlush, 400); }
}
new MutationObserver(relScan).observe(document.getElementById("view"), { childList: true, subtree: true });

// ---------------------------------------------------------------- row arrows
// Every sideways row gets ‹ › buttons (shown on hover, hidden at either end); added automatically to any row on any page.
function arrowize(strip) {
  if (strip.dataset.arrows) return;
  strip.dataset.arrows = "1";
  const wrap = document.createElement("div"); wrap.className = "strip-wrap";
  strip.parentNode.insertBefore(wrap, strip); wrap.appendChild(strip);
  const l = h(`<button class="sa left" aria-label="Scroll left">‹</button>`), r = h(`<button class="sa right" aria-label="Scroll right">›</button>`);
  wrap.append(l, r);
  const by = () => Math.max(300, strip.clientWidth * 0.8);
  l.onclick = () => strip.scrollBy({ left: -by(), behavior: "smooth" });
  r.onclick = () => strip.scrollBy({ left: by(), behavior: "smooth" });
  const upd = () => { l.classList.toggle("off", strip.scrollLeft < 5); r.classList.toggle("off", strip.scrollLeft + strip.clientWidth >= strip.scrollWidth - 5); };
  strip.addEventListener("scroll", upd, { passive: true });
  new ResizeObserver(upd).observe(strip);
  new MutationObserver(upd).observe(strip, { childList: true });
  setTimeout(upd, 400);
}
new MutationObserver(() => document.querySelectorAll("#view .strip:not([data-arrows])").forEach(arrowize))
  .observe(document.getElementById("view"), { childList: true, subtree: true });

// ---------------------------------------------------------------- home

// Kept while Ember is open, but fetched again after an hour so new or renamed lists show up without a restart.
const loadedAt = {};
const stale = (k, ms = 3600e3) => { if (!loadedAt[k] || Date.now() - loadedAt[k] > ms) { loadedAt[k] = Date.now(); return true; } return false; };
let addonCatalogs = null;
async function catalogs() {
  if (stale("cats") || !addonCatalogs) {
    addonCatalogs = getJson(`${feed()}/addon/manifest.json`).then(man => (man.catalogs || [])
      .filter(c => !(c.extra || []).some(x => x.isRequired)))
      .catch(e => { toast("Couldn't reach your addon through lucapi: " + e.message); return []; });
  }
  return addonCatalogs;
}
/** How lucapi sorted your lists: which are Home rows, which feed the hero, and the boxes (tiles). */
let layoutP = null;
const tileInfo = {};
function layout() {
  if (stale("layout") || !layoutP) layoutP = getJson(`${feed()}/browse/tiles`, 90000).catch(() => ({ groups: [] }));
  return layoutP;
}
/** Home rows: your personal lists when lucapi has sorted them, otherwise every catalogue. */
async function homeCats() {
  const [cats, lay] = await Promise.all([catalogs(), layout()]);
  if (!lay.home || !lay.home.length) return { rows: cats, hero: [] };
  const byKey = new Map(cats.map(c => [c.type + ":" + c.id, c]));
  const pick = (x) => byKey.get(x.type + ":" + x.id) || { type: x.type, id: x.id, name: x.name };
  return { rows: lay.home.map(pick), hero: (lay.hero || []).map(pick) };
}
async function catalogRow(c) {
  try { return (await getJson(`${feed()}/addon/catalog/${c.type}/${c.id}.json`)).metas || []; } catch (e) { return []; }
}

/** Home rows get "Films" or "Series" on the end, unless the name already says which. */
/** Friendlier names for the addon's lists: "Top 20 Trending Films" is "Trending Today", "All-Time" loses its hyphen. */
function niceName(name) {
  return String(name || "").replace(/^\s*top\s*\d+\s*trending\b.*$/i, "Trending Today").replace(/all-time/ig, "All Time");
}
function homeRowName(name, type) {
  name = niceName(name);
  if (/\b(films?|movies?|series|shows?|tv)\b/i.test(name)) return name;
  return { name, kind: type === "movie" ? "Films" : "Series" };
}

const HERO_EVERY_MS = 15000, HERO_HOLD_MS = 60000;
let heroTimer = 0;

/** The big slideshow at the top of Home, Films and Series. A page name ("Films") sits over it, blending in. */
function createHero(pageName) {
  const hero = h(`<header class="hero ${pageName ? "named" : ""}"><div class="bd a"></div><div class="bd b"></div>
    ${pageName ? `<div class="pagename">${esc(pageName)}</div>` : ""}<div class="info"></div>
    <div class="hnav"><button class="hn prev" aria-label="Previous">‹</button><div class="dots"></div><button class="hn next" aria-label="Next">›</button></div></header>`);
  let flip = false, heroFor = null, pool = [], idx = 0, heldUntil = 0, changedAt = Date.now();
  const loadImg = (src) => new Promise((ok) => { if (!src) return ok(); const i = new Image(); i.onload = i.onerror = () => ok(); i.src = src; setTimeout(ok, 2500); });

  const setHero = async (m) => {
    if (!m || heroFor === m.id) return;
    heroFor = m.id;
    const type = m.type || "movie";
    const full = await meta(type, m.id);
    if (heroFor !== m.id) return;
    const mm = { ...m, ...full };
    // the picture and the logo arrive together: both loaded first, then faded in at once
    await Promise.all([loadImg(backdrop(mm)), loadImg(mm.logo)]);
    if (heroFor !== m.id) return;
    changedAt = Date.now();
    const layers = hero.querySelectorAll(".bd"); flip = !flip;
    const on = layers[flip ? 0 : 1], off = layers[flip ? 1 : 0];
    on.style.backgroundImage = `url('${backdrop(mm)}')`; on.classList.add("show"); off.classList.remove("show");
    const p = progress[m.id];
    const info = $(".info", hero);
    info.classList.remove("fade-in"); void info.offsetWidth; info.classList.add("fade-in");
    info.innerHTML = `${mm.logo ? `<img class="logoimg" src="${esc(mm.logo)}" alt="${esc(mm.name)}">` : `<h1>${esc(mm.name)}</h1>`}
      <div class="sub">${esc(p ? progressLine(p) : [mm.releaseInfo, mm.imdbRating && "★ " + mm.imdbRating, (mm.genres || []).slice(0, 3).join(", ")].filter(Boolean).join("  ·  "))}</div>
      <div class="desc">${esc(mm.description || "")}</div>
      <div class="btns"><button class="btn primary">${p ? "Resume " + fmt(p.position) : "Watch"}</button><button class="btn">Details</button></div>`;
    const logo = $(".logoimg", info);
    if (logo) logo.onerror = () => logo.replaceWith(h(`<h1>${esc(mm.name)}</h1>`));
    const [watch, details] = info.querySelectorAll("button");
    watch.onclick = () => go("title", type, m.id, m, { autoplay: true });
    details.onclick = () => go("title", type, m.id, m);
    const i = pool.findIndex(x => x.id === m.id);
    hero.querySelectorAll(".dots i").forEach((d, k) => d.classList.toggle("on", k === i));
  };
  // A poster you click goes to the top and stays a minute before the slideshow carries on.
  const pick = (m) => { heldUntil = Date.now() + HERO_HOLD_MS; setHero(m); $("#view").scrollTo({ top: 0, behavior: "smooth" }); };
  const start = (items) => {
    const seen = new Set();
    pool = items.filter(m => m && !seen.has(m.id) && seen.add(m.id)).slice(0, 10);
    if (!pool.length) return;
    hero.querySelector(".dots").innerHTML = pool.map(() => "<i></i>").join("");
    hero.querySelectorAll(".dots i").forEach((d, k) => d.onclick = () => { idx = k; pick(pool[k]); });
    // skipping by hand: the slideshow carries on from there (15 s later), it doesn't stop
    const step = (dir) => { idx = (idx + dir + pool.length) % pool.length; changedAt = Date.now(); setHero(pool[idx]); };
    hero.querySelector(".hn.prev").onclick = () => step(-1);
    hero.querySelector(".hn.next").onclick = () => step(1);
    setHero(pool[0]);
    clearInterval(hero._timer);
    hero._timer = setInterval(() => {
      if (!hero.isConnected) { if (!keptPages.has(hero)) clearInterval(hero._timer); return; } // a page kept for Back waits
      if (Date.now() < heldUntil || Date.now() - changedAt < HERO_EVERY_MS || document.hidden || (!TV && hero.matches(":hover"))) return;
      idx = (idx + 1) % pool.length; changedAt = Date.now(); setHero(pool[idx]);
    }, 1000);
  };
  return { el: hero, pick, start };
}

/** The top two from each row, in turn: the slideshow's titles. */
const slideshowFrom = (lists) => { const out = []; for (let k = 0; k < 2; k++) for (const l of lists) if (l[k]) out.push(l[k]); return out; };

/** Top right of Home, small: the cats (in or out) and what's next today or tomorrow. Refreshes every minute. */
function glance(heroEl) {
  const box = h(`<div class="glance" hidden></div>`);
  heroEl.appendChild(box);
  const cat = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 3l3.5 4h7L19 3v8a7 7 0 0 1-14 0z"/></svg>`;
  const draw = async () => {
    if (!box.isConnected && !keptPages.has(heroEl)) return clearInterval(timer);
    let g;
    try { g = await getJson(`${feed()}/glance`, 8000); } catch (e) { return; }
    const parts = [];
    if ((g.cats || []).length) parts.push(`<span class="gl-cats">${g.cats.map(c => `<span class="gl-cat ${c.home ? "in" : "out"}" title="${esc(c.name)} is ${c.home ? "in" : "out"}">${cat}${esc(c.name)} <i>${c.home ? "in" : "out"}</i></span>`).join("")}</span>`);
    if (g.next) parts.push(`<span class="gl-next ${g.next.shift ? "shift" : ""}">${esc(g.next.title)} <i>${esc(g.next.day === "Today" ? "" : g.next.day + " ")}${esc(g.next.time)}</i></span>`);
    box.innerHTML = parts.join(`<span class="gl-sep"></span>`);
    box.hidden = !parts.length;
  };
  const timer = setInterval(draw, 60000);
  draw();
}

async function showHome() {
  const v = $("#view");
  v.innerHTML = "";
  const hero = createHero("");
  const rows = h(`<div class="rows"></div>`);
  v.append(hero.el, rows);
  glance(hero.el);
  await loadProgress();
  const { rows: cats, hero: heroCats } = await homeCats();
  if (!cats.length) { rows.appendChild(h(`<div class="empty">No rows yet. Check lucapi's address in Settings.</div>`)); return; }
  const heroList = Promise.all(heroCats.map(c => catalogRow(c).then(ms => ms.map(m => ({ ...m, type: m.type || c.type })))));
  const isContinue = (c) => /pick up|left off|continue/i.test(c.name || "");
  const isTop = (c) => /\btop\b/i.test(c.name || "");
  // Order: continue watching, top 10s, out this week, your other rows, then the tiles.
  const slotCW = document.createElement("div"); rows.appendChild(slotCW);
  const hidden = hiddenRows();
  const shown = cats.filter(c => !hidden.has(catKey(c)) && !/all.?time/i.test(c.name || "")); // all-time picks live on Films and Series
  // Trending Today first (wide pictures, no numbers), then the Top 10s
  const isTrend = (c) => /trending/i.test(c.name || "");
  const tops = shown.filter(isTop).sort((a, b) => isTrend(b) - isTrend(a)), others = shown.filter(c => !isTop(c) && !isContinue(c));
  const topSlots = tops.map(() => { const d = document.createElement("div"); rows.appendChild(d); return d; });
  const otherSlots = others.map(() => { const d = document.createElement("div"); rows.appendChild(d); return d; });
  const slotTiles = document.createElement("div"); rows.appendChild(slotTiles);

  const cwCat = cats.filter(isContinue);
  if (!hidden.has("cw")) continueRow(cwCat).then(r => { if (r) slotCW.replaceWith(r); });
  if (!hidden.has("out")) weekCalendar().then(r => { if (r) hero.el.appendChild(r); });
  tileRows(hidden).then(r => { if (r) slotTiles.replaceWith(r); });
  const [topLists, otherLists] = await Promise.all([
    Promise.all(tops.map(async (c, i) => {
      const metas = (await (isTrend(c) ? catalogRow(c) : topList(c))).map(m => ({ ...m, type: m.type || c.type }));
      if (metas.length) topSlots[i].replaceWith(isTrend(c) ? wideRow(homeRowName(c.name || c.id, c.type), metas)
        : top10Row(homeRowName(c.name || c.id, c.type), metas, hero.pick));
      return metas;
    })),
    Promise.all(others.map(async (c, i) => {
      const metas = (await catalogRow(c)).map(m => ({ ...m, type: m.type || c.type }));
      if (metas.length) otherSlots[i].replaceWith(/watchlist/i.test(c.name || "") ? wallRow(homeRowName(c.name || c.id, c.type), metas, c.type)
        : spotRow(homeRowName(c.name || c.id, c.type), metas, c.type));
      return metas;
    })),
  ]);
  pairWalls(rows);
  const own = (await heroList).flat();
  hero.start(own.length ? own : slideshowFrom([...topLists, ...otherLists]));
}

/** Continue watching: what you're part-way through (any device), then what's next, as wide cards with episode stills. */
async function continueRow(cwCat) {
  const items = [];
  const seen = new Set();
  for (const [id, p] of Object.entries(progress)) { items.push({ id, type: p.type, p }); seen.add(id); }
  items.sort((a, b) => (b.p.pausedAt || "").localeCompare(a.p.pausedAt || ""));
  let gone = {};
  try { gone = (await getJson(`${feed()}/progress/dismissed`, 5000)).dismissed || {}; } catch (e) {}
  for (const c of [].concat(cwCat || [])) {
    try { for (const m of await catalogRow(c)) if (!seen.has(m.id) && !gone[m.id]) { items.push({ id: m.id, type: m.type || c.type, m }); seen.add(m.id); } } catch (e) {}
  }
  if (!items.length) return null;
  const r = h(`<section class="row fade-in"><h2>Continue watching <small>${items.length}</small></h2><div class="strip"></div></section>`);
  const strip = $(".strip", r);
  for (const it of items.slice(0, 20)) {
    const el = h(`<div class="cw" data-tid="${esc(it.id)}" data-ttype="${esc(it.type)}" data-tname="${esc((it.m && it.m.name) || "")}"><div class="cw-art"><div class="cw-label"></div><button class="cw-x" title="Remove from Continue watching">✕</button></div><div class="cw-name"></div></div>`);
    strip.appendChild(el);
    $(".cw-x", el).onclick = async (e) => {
      e.stopPropagation();
      el.classList.add("going");
      try {
        await fetch(`${feed()}/progress/dismiss`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ imdb: it.id }) });
        delete progress[it.id];
        setTimeout(() => el.remove(), 250);
        toast(`Removed ${$(".cw-name", el).textContent || "it"} from Continue watching.`);
      } catch (err) { el.classList.remove("going"); toast("Couldn't reach lucapi: " + err.message); }
    };
    (async () => {
      const full = { ...(it.m || {}), ...(await meta(it.type, it.id)) };
      $(".cw-name", el).textContent = full.name || "";
      let season = it.p && it.p.season, episode = it.p && it.p.episode, label = "";
      if (it.p) {
        const left = it.p.duration ? Math.max(1, Math.round((it.p.duration - it.p.position) / 60)) : 0;
        label = `${it.type === "series" && season ? `S${season} · E${episode}` : "Resume"}${left && left <= 10 ? ` · ${left}m left` : ""}`;
        el.querySelector(".cw-art").insertAdjacentHTML("beforeend", `<div class="bar"><i style="width:${Math.max(3, Math.min(100, it.p.progress))}%"></i></div>`);
      } else if (it.type === "series") {
        try { const n = await getJson(`${feed()}/next/${it.id}`, 6000); if (n.season) { season = n.season; episode = n.episode; label = `Next · S${season} · E${episode}`; } } catch (e) {}
      }
      $(".cw-label", el).innerHTML = (label.startsWith("Next") ? "" : PLAY) + esc(label);
      const ep = season && (full.videos || []).find(x => x.season === season && x.episode === episode);
      const art = (ep && ep.thumbnail) || backdrop(full);
      if (art) $(".cw-art", el).style.backgroundImage = `url('${art}')`;
      el.onclick = () => go("title", it.type, it.id, full); // details first; Play starts it
    })();
  }
  return r;
}

/** A title shown large: its picture, logo or name, a line about it, Watch and Details. */
function spotCard(m, type) {
  const t = m.type || type, p = progress[m.id];
  const sp = h(`<div class="spot" data-wid="${esc(m.id)}" data-wtype="${esc(t)}" data-wname="${esc(m.name)}" style="background-image:url('${esc(backdrop(m))}')">
    <div class="spot-pimg" style="background-image:url('${esc(poster(m))}')"></div>
    ${watchlistIds.has(m.id) ? BOOKMARK : ""}${badge(m.id)}
    <div class="spot-in"><span class="spot-k">Top pick</span><div class="spot-t"></div>
      <div class="spot-m">${esc([m.releaseInfo, m.imdbRating && "★ " + m.imdbRating].filter(Boolean).join("  ·  "))}</div>
      <div class="spot-d">${esc(m.description || "")}</div>
      <div class="btns"><button class="btn primary">${p ? "Resume " + fmt(p.position) : "Watch"}</button><button class="btn">Details</button></div></div></div>`);
  if (watchlistIds.has(m.id)) sp.classList.add("bm");
  const [watch, details] = sp.querySelectorAll("button");
  watch.onclick = (e) => { e.stopPropagation(); go("title", t, m.id, m, { autoplay: true }); };
  details.onclick = (e) => { e.stopPropagation(); go("title", t, m.id, m); };
  sp.onclick = () => go("title", t, m.id, m);
  // The title's logo in place of its name: the name waits hidden while the logo loads (at most 0.8 s), so it
  // doesn't flash up first; if there's no logo, the name shows.
  $(".spot-t", sp).replaceWith(titleArt(m, t));
  // the full details (logo, description, genres) arrive a moment later
  meta(t, m.id).then(full => {
    if (!full) return;
    const mm = { ...m, ...full };
    if (!m.description && mm.description) $(".spot-d", sp).textContent = mm.description;
    $(".spot-m", sp).textContent = [mm.releaseInfo || mm.year, mm.imdbRating && "★ " + mm.imdbRating, (mm.genres || []).slice(0, 2).join(", ")].filter(Boolean).join("  ·  ");
    if (!m.background && mm.background) sp.style.backgroundImage = `url('${mm.background}')`;
  });
  return sp;
}

/** The ordinary rows. On the TVs: the first title large, then the posters. On the PC: plain posters, and the one
 *  the mouse rests on opens out into that large card in place (and folds back when the mouse moves on). */
function spotRow(title, metas, type) {
  if (!TV) return hoverRow(title, metas, type);
  if (metas.length < 4) return row(title, metas, type);
  const r = row(title, metas.slice(1), type);
  const sp = spotCard(metas[0], type);
  sp.querySelector(".spot-k").textContent = "Top pick";
  $(".strip", r).prepend(sp);
  $(".strip", r).classList.add("spotted");
  $("h2 small", r).textContent = metas.length;
  return r;
}

function hoverRow(title, metas, type) {
  const r = row(title, metas, type);
  const strip = $(".strip", r);
  strip.classList.add("hoverspot");
  const byId = new Map(metas.map(m => [m.id, m]));
  let timer = 0, open = null;
  const close = () => {
    if (!open) return;
    const { sp, poster } = open; open = null;
    sp.classList.remove("open");
    setTimeout(() => { sp.remove(); poster.hidden = false; }, 260);
  };
  strip.addEventListener("mouseover", (e) => {
    const poster = e.target.closest(".poster");
    if (!poster || !strip.contains(poster) || e.target.closest(".wbadge")) return;
    const hm = byId.get(poster.dataset.wid);
    logoFor(hm, type);   // logo and picture ready by the time the card opens
    if (hm && backdrop(hm)) new Image().src = backdrop(hm);
    clearTimeout(timer);
    timer = setTimeout(() => {
      if (open && open.poster === poster) return;
      close();
      const m = byId.get(poster.dataset.wid);
      if (!m) return;
      const sp = spotCard(m, type);
      sp.querySelector(".spot-k").remove();
      poster.hidden = true;
      poster.before(sp);
      open = { sp, poster };
      sp.addEventListener("mouseleave", () => { clearTimeout(timer); timer = setTimeout(close, 180); });
      sp.addEventListener("mouseenter", () => clearTimeout(timer));
      requestAnimationFrame(() => requestAnimationFrame(() => sp.classList.add("open")));
      // keep the opened card in view at the right-hand end of the row
      setTimeout(() => {
        const a = sp.getBoundingClientRect(), b = strip.getBoundingClientRect();
        if (a.right > b.right - 20) strip.scrollBy({ left: a.right - b.right + 40, behavior: "smooth" });
      }, 300);
    }, 380);
  });
  strip.addEventListener("mouseleave", () => { clearTimeout(timer); timer = setTimeout(close, 180); });
  return r;
}

/** The two watchlists (films and series) side by side, where the first of them was. */
function pairWalls(container) {
  const walls = [...container.querySelectorAll(":scope > .row")].filter(r => r.querySelector(".strip.wall"));
  if (walls.length < 2) return;
  const pair = h(`<div class="wl-pair"></div>`);
  walls[0].before(pair);
  pair.append(walls[0], walls[1]);
}

/** Your watchlists: posters two rows deep, so they stand apart from the other rows (each carries its bookmark). */
function wallRow(title, metas, type) {
  const r = row(title, metas, type);
  $(".strip", r).classList.add("wall");
  return r;
}

/** Top 10: big rank numbers beside wide artwork. */
/** Wide pictures with the title on them (no longer used for watchlists). */
function wideRow(title, metas) {
  const label = typeof title === "object" ? `${esc(title.name)} <span class="kind">${title.kind}</span>` : esc(title);
  const r = h(`<section class="row fade-in"><h2>${label} <small>${metas.length}</small></h2><div class="strip wide"></div></section>`);
  metas.forEach((m) => {
    const bm = watchlistIds.has(m.id);
    const el = h(`<div class="t10"><div class="t10-art${bm ? " bm" : ""}" data-wid="${esc(m.id)}" data-wtype="${esc(m.type)}" data-wname="${esc(m.name)}" style="background-image:url('${esc(backdrop(m))}')">${bm ? BOOKMARK : ""}${badge(m.id)}</div></div>`);
    $(".t10-art", el).appendChild(titleArt(m, m.type));
    el.onclick = () => go("title", m.type, m.id, m);
    $(".strip", r).appendChild(el);
  });
  return r;
}

function top10Row(title, metas, onPick) {
  const label = typeof title === "object" ? `${esc(title.name)} <span class="kind">${title.kind}</span>` : esc(title);
  const r = h(`<section class="row fade-in"><h2>${label}</h2><div class="strip top10"></div></section>`);
  metas.slice(0, 25).forEach((m, i) => {
    const bm = watchlistIds.has(m.id);
    const el = h(`<div class="t10"><b>${i + 1}</b><div class="t10-art${bm ? " bm" : ""}" data-wid="${esc(m.id)}" data-wtype="${esc(m.type)}" data-wname="${esc(m.name)}" style="background-image:url('${esc(backdrop(m))}')">${bm ? BOOKMARK : ""}${badge(m.id)}</div></div>`);
    $(".t10-art", el).appendChild(titleArt(m, m.type));
    el.onclick = () => go("title", m.type, m.id, m);
    $(".strip", r).appendChild(el);
  });
  return r;
}

// Designed tiles (Omni-style): a brand-colour gradient with the logo big in the middle, no film artwork.
// [gradient from, gradient to, logo ink, (logo kept in Ember), (caption under it)]: w = white, k = black, o = its own colours, W = always white
const BRAND = {
  "netflix": ["#3a0606", "#0c0202", "o", "brands/netflix.svg"], "prime video": ["#1f8fff", "#0a3f8a", "w", "brands/prime-video.svg"], "apple tv+": ["#3a3a3a", "#050505", "w", "brands/apple-tv-plus.svg"],
  "disney+": ["#1d3a9c", "#070f33", "w"], "hbo max": ["#262626", "#000000", "w"], "hulu": ["#1ed27a", "#0a6b3b", "w", "brands/hulu.svg"],
  "paramount +": ["#3c7bff", "#1238b8", "w"], "paramount+": ["#3c7bff", "#1238b8", "w"], "peacock": ["#2a2a2a", "#000000", "w"],
  "discovery +": ["#2468e8", "#0a2a7a", "w", "brands/discovery-plus.svg"], "discovery+": ["#2468e8", "#0a2a7a", "w", "brands/discovery-plus.svg"],
  "crunchyroll": ["#ff8a3d", "#c24a0c", "w", "brands/crunchyroll.svg"],
  "marvel studios": ["#d3191f", "#5c080b", "o"], "dc studios": ["#2a6be8", "#0a2a72", "o"], "pixar": ["#3a3a3a", "#0a0a0a", "w"],
  "walt disney": ["#1a2f80", "#070d29", "w"], "walt disney animation studios": ["#1a2f80", "#070d29", "w"],
  "dreamworks animation": ["#2a62c9", "#0a1f4f", "w"], "illumination studios": ["#ffd23a", "#d39a00", "k"],
  "sony pictures animation": ["#4b7fe0", "#13306e", "w"], "sony pictures": ["#2a2a2a", "#000000", "W"],
  "studio ghibli": ["#72b6e3", "#1f5f8f", "w"], "universal pictures": ["#14284f", "#02060f", "w"],
  "warner brothers": ["#2357b0", "#0a2350", "w", "brands/warner-bros.svg"], "warner brothers animation": ["#2357b0", "#0a2350", "w", "brands/warner-bros.svg", "ANIMATION"],
  "lionsgate": ["#4a4a4a", "#111111", "w"], "miramax": ["#2a2a2a", "#000000", "w"], "mgm": ["#8a6a24", "#2b1d06", "w"],
  "searchlight pictures": ["#24384e", "#070d14", "w"],
  "cbeebies": ["#22307a", "#0b1238", "o", "brands/cbeebies.png"], "cartoon network": ["#9a9a9a", "#4a4a4a", "o", "brands/cartoon-network.png"],
  "nickelodeon": ["#2a2a2a", "#050505", "o", "brands/nickelodeon.png"], "disney kids": ["#4b33b5", "#1a1150", "o", "brands/disney-channel.png"], "imdb top 250": ["#2a2a2a", "#000000", "o", "brands/imdb.svg", "TOP 250"],
};
/** A tile's brand, also when the list's name has grown a word ("Hulu Shows", "Crunchyroll Anime", "Peacock TV"). */
function brandOf(key) {
  if (BRAND[key]) return BRAND[key];
  const n = key.replace(/\b(shows?|series|movies?|films?|tv|anime|originals?|uk|us)\b/g, "").replace(/\s+/g, " ").trim();
  if (BRAND[n]) return BRAND[n];
  const k = Object.keys(BRAND).filter(b => n.startsWith(b + " ") || n === b).sort((a, b) => b.length - a.length)[0];
  return k ? BRAND[k] : null;
}
// Awards: [gradient from, to, small line, big title]
const AWARD = {
  "oscar winners": ["#432466", "#120a22", "The Academy Awards", "OSCARS", "oscar"],
  "academy award winners": ["#432466", "#120a22", "The Academy Awards", "OSCARS", "oscar"],
  "bafta": ["#2e2142", "#0d0914", "The British Academy Film Awards", "BAFTA", "bafta"],
  "golden globes": ["#7a4416", "#2a1505", "Golden Globe Awards", "GOLDEN GLOBES", "globe"],
  "cannes": ["#14295a", "#060f28", "Festival de Cannes", "CANNES", "palme"],
  "certified fresh": ["#1f4a22", "#071509", "Rotten Tomatoes", "CERTIFIED FRESH", "tomato"],
};

/** Streaming services, genres, directors, studios, collections, decades (from TMDB, via the Pi). */
async function tileRows(hidden = new Set(), typ = "") {
  const t = await layout();
  if (!t.groups || !t.groups.length) return null;
  const box = h(`<div></div>`);
  for (const g of t.groups) {
    if (hidden.has("tiles:" + g.title)) continue;
    if (typ === "series" && (g.style === "person" || g.title === "Franchises")) continue; // directors and franchises are for films
    const list = g.tiles.filter(x => !typ || !x.types || x.types.includes(typ));
    if (!list.length) continue;
    const r = h(`<section class="row fade-in"><h2>${esc(g.title)}</h2><div class="strip tiles ${g.style}"></div></section>`);
    for (let tile of list) {
      if (tile.kind === "cat") tileInfo[tile.id] = tile;
      if (tile.logo && tile.logo.startsWith("/")) tile = { ...tile, logo: feed() + tile.logo }; // kept on the Pi
      let inner;
      const key = (tile.title || "").toLowerCase().trim(), br = brandOf(key), aw = AWARD[key];
      if (aw) inner = `<div class="tile brand award ${aw[3].length > 9 ? "long" : ""} ${aw[5] || ""}" style="--a:${aw[0]};--b:${aw[1]}"><img class="aw-art aw-${aw[4]}" src="awards/${aw[4]}.svg" alt="">${aw[4] === "tomato" ? `<em class="aw-pct">100%</em>` : ""}<small>${esc(aw[2])}</small><b>${esc(aw[3])}</b></div>`;
      else if (br) {
        // an app icon has had its square cut away on the Pi, so it's shown in its own colours
        const logo = br[3] || tile.logo, cut = !br[3] && tile.logo_kind === "icon";
        const ink = br[2] === "W" ? "w" : cut ? "o" : !br[3] && ["duo", "box"].includes(tile.logo_mode) && br[2] === "w" ? "o" : br[2];
        inner = `<div class="tile brand ink-${ink} ${br[4] ? "withsub" : ""}" style="--a:${br[0]};--b:${br[1]}">${logo ? `<img src="${esc(logo)}" alt="">` : ""}${br[4] ? `<em class="br-sub">${esc(br[4])}</em>` : ""}<span>${esc(tile.title)}</span></div>`;
      }
      else if (g.style === "person") {
        const parts = (tile.title || "").split(" "), last = parts.length > 1 ? parts.pop() : "";
        inner = `<div class="tile director"><div class="ph" style="background-image:url('${esc(tile.image)}')"></div><b>${esc(parts.join(" "))}<br>${esc(last)}</b></div>`;
      }
      else if (key === "007") // the 007 logo on the gun barrel
        inner = `<div class="tile art bondimg" style="background-image:url('brands/007.jpg')"><span>James Bond</span></div>`;
      else if (g.style === "logo") inner = `<div class="tile logo ${tile.logo ? "haslogo" : ""}" style="background:${esc(tile.colour)}">${tile.logo ? `<img src="${esc(tile.logo)}" alt="">` : ""}<span>${esc(tile.title)}</span></div>`;
      else if (g.style === "person") inner = `<div class="tile person"><div class="face" style="background-image:url('${esc(tile.image)}')"></div><span>${esc(tile.title)}</span></div>`;
      else inner = `<div class="tile art ${tile.logo ? "haslogo" : ""}" style="background-image:url('${esc(tile.image || "")}')">${tile.logo ? `<img src="${esc(tile.logo)}" alt="">` : ""}<span>${esc(tile.title)}</span></div>`;
      const el = h(inner);
      // A logo that doesn't load: show the name instead.
      el.querySelectorAll("img").forEach(img => {
        img.onerror = () => { img.closest(".haslogo")?.classList.remove("haslogo"); img.remove(); };
        if (br) return; // designed tile: its colours are set
        // dark one-colour logos turn white; everything else keeps its own colours
        // dark logos are inverted (light, with their detail kept); everything else keeps its own colours
        const mode = { dark: "lg-inv", mono: "lg-inv", colour: "lg-orig", light: "lg-orig", duo: "lg-orig", box: "lg-orig", ok: "lg-orig" }[tile.logo_mode];
        if (g.style === "logo") { img.classList.add("lg-full"); if (!tile.logo_mode) serviceTile(img, el); }
        else if (mode) img.classList.add(mode);
        else smartLogo(img); // an older lucapi: work it out here
      });
      const first = typ || (tile.types || ["movie"])[0];
      el.onclick = () => go("tile", tile.kind, tile.id, tile.title, (g.style === "person" ? "" : tile.image) || "", first);
      $(".strip", r).appendChild(el);
    }
    box.appendChild(r);
  }
  return box;
}

/** Looks at a logo's pixels: a solid badge stays as it is, a dark logo turns white, a light or coloured one keeps its colours. */
function logoPixels(src) {
  return new Promise((ok) => {
    const im = new Image(); im.crossOrigin = "anonymous";
    im.onload = () => {
      try {
        const w = 64, hh = Math.max(1, Math.round(64 * im.naturalHeight / Math.max(1, im.naturalWidth)));
        const c = document.createElement("canvas"); c.width = w; c.height = hh;
        const x = c.getContext("2d"); x.drawImage(im, 0, 0, w, hh);
        ok({ data: x.getImageData(0, 0, w, hh).data, w, h: hh });
      } catch (e) { ok(null); }
    };
    im.onerror = () => ok(null);
    im.src = src;
  });
}
async function smartLogo(img) {
  const px = await logoPixels(img.src);
  if (!px) { img.classList.add("lg-dark"); return; } // can't look: white is safest on dark artwork
  const d = px.data; let clear = 0, n = 0, lum = 0;
  for (let i = 0; i < d.length; i += 4) {
    if (d[i + 3] < 40) { clear++; continue; }
    n++; lum += (0.2126 * d[i] + 0.7152 * d[i + 1] + 0.0722 * d[i + 2]) / 255;
  }
  lum = n ? lum / n : 1;
  img.classList.add(clear / (d.length / 4) < 0.04 ? "lg-box" : lum < 0.4 ? "lg-dark" : "lg-ok");
}
/** Streaming services: the logo fills the tile, on its own background colour. */
async function serviceTile(img, tile) {
  const px = await logoPixels(img.src);
  if (px) {
    const d = px.data, at = (x, y) => (y * px.w + x) * 4;
    const pts = [at(1, 1), at(px.w - 2, 1), at(1, px.h - 2), at(px.w - 2, px.h - 2)];
    const avg = (k) => Math.round(pts.reduce((s, p) => s + d[p + k], 0) / pts.length);
    tile.style.background = `rgb(${avg(0)},${avg(1)},${avg(2)})`;
  }
  img.classList.add("lg-full");
}

/** The page behind a tile: its titles, Films or Series where both exist. */
const TILE_SORTS = [["", "List order"], ["new", "Newest"], ["old", "Oldest"], ["rating", "Top rated"], ["az", "A–Z"]];
async function showTile(kind, id, title, image, typ, sort = "") {
  const own = kind === "cat";
  const info = tileInfo[id] || {};
  const both = own ? (info.types || []).length > 1 : ["service", "genre", "company"].includes(kind);
  typ = typ || (own && info.types ? info.types[0] : "movie");
  // a streaming service: its own shows and films too ("Netflix Originals")
  const hasOriginals = own && /^(netflix|prime video|amazon|disney\s*\+|apple tv\s*\+|hbo max|max|hulu|paramount\s*\+|peacock)\b/i.test(title || "");
  const origName = `${(title || "").replace(/\s*(shows?|series|films?|movies?)$/i, "").replace(/^prime video$/i, "Amazon")} Originals`;
  const v = $("#view");
  v.innerHTML = "";
  const head = h(`<header class="tile-head" style="background-image:url('${esc(image)}')"><div class="shade"></div>
    <button class="back">‹ Back</button><h1>${esc(title)}</h1>
    <div class="tile-bar">${both ? `<div class="chips"><span class="chip btn-chip ${typ === "movie" ? "on" : ""}" data-t="movie">Films</span><span class="chip btn-chip ${typ === "series" ? "on" : ""}" data-t="series">Series</span></div>` : "<div></div>"}
    ${own ? `<div class="chips sorts">${hasOriginals ? `<span class="chip btn-chip orig ${sort === "orig" ? "on" : ""}" data-s="${sort === "orig" ? "" : "orig"}">${esc(origName)}</span>` : ""}${TILE_SORTS.map(([k, l]) => `<span class="chip btn-chip ${k === sort ? "on" : ""}" data-s="${k}">${l}</span>`).join("")}</div>` : ""}</div></header>`);
  const grid = h(`<div class="grid fade-in"></div>`);
  const more = h(`<div class="btns" style="padding:0 48px 60px"><button class="btn">More</button></div>`);
  v.append(head, grid, more);
  $(".back", head).onclick = back;
  head.querySelectorAll("[data-t]").forEach(c => c.onclick = () => { navStack[navStack.length - 1][1][4] = c.dataset.t; showTile(kind, id, title, image, c.dataset.t, sort); });
  head.querySelectorAll("[data-s]").forEach(c => c.onclick = () => { navStack[navStack.length - 1][1][5] = c.dataset.s; showTile(kind, id, title, image, typ, c.dataset.s); });
  let page = 1, pages = 1, shown = 0;
  const ids = new Set();
  const load = async () => {
    more.querySelector("button").textContent = "Loading…";
    const orig = sort === "orig";
    if (own && sort && !orig && !shown) grid.innerHTML = `<div class="empty">Sorting the whole list…</div>`;
    let r;
    const url = orig ? `${feed()}/browse/originals/${encodeURIComponent(title)}?type=${typ}&page=${page}`
      : own ? `${feed()}/browse/cat/${id}?type=${typ}&skip=${shown}&sort=${sort}` : `${feed()}/browse/${kind}/${id}?type=${typ}&page=${page}`;
    try { r = await getJson(url, 60000); } catch (e) { toast("Couldn't load: " + e.message); return; }
    pages = r.pages || 1;
    if (own && sort && !orig && !shown) grid.innerHTML = "";
    if (orig && r.unsupported && !grid.children.length) grid.appendChild(h(`<div class="empty">No ${esc(origName)} list for ${typ === "movie" ? "films" : "series"} yet.</div>`));
    const fresh = (r.metas || []).filter(m => !ids.has(m.id));
    fresh.forEach(m => { ids.add(m.id); grid.appendChild(card(m, m.type || typ)); });
    shown += (r.metas || []).length;
    if (own && !orig && !grid.children.length) grid.appendChild(h(`<div class="empty">Nothing in this list yet.</div>`));
    more.hidden = orig ? page >= pages || !fresh.length : own ? !(r.more && fresh.length) : page >= pages;
    more.querySelector("button").textContent = "More";
  };
  more.querySelector("button").onclick = () => { page++; load(); };
  await loadProgress();
  load();
}

// ---------------------------------------------------------------- search

async function showSearch(q = "") {
  const v = $("#view");
  v.innerHTML = "";
  const head = h(`<div class="page-h"><div class="search"><span class="muted">⌕</span><input placeholder="Search films and series" value="${esc(q)}"></div></div>`);
  const out = h(`<div class="rows" style="padding-top:12px"></div>`);
  v.append(head, out);
  const input = $("input", head); input.focus();
  let timer, gen = 0;
  const run = async () => {
    const term = input.value.trim(); const my = ++gen;
    if (term.length < 2) { out.innerHTML = ""; return; }
    const enc = encodeURIComponent(term);
    const [s, m] = await Promise.all(["series", "movie"].map(t =>
      getJson(`${CINEMETA}/catalog/${t}/top/search=${enc}.json`).then(j => (j.metas || []).map(x => ({ ...x, type: t }))).catch(() => [])));
    if (my !== gen) return;
    out.innerHTML = "";
    if (!s.length && !m.length) { out.appendChild(h(`<div class="empty">Nothing found for “${esc(term)}”.</div>`)); return; }
    if (s.length) out.appendChild(row("Series", s, "series"));
    if (m.length) out.appendChild(row("Films", m, "movie"));
    navStack[navStack.length - 1][1] = [term];
  };
  input.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(run, 350); });
  if (q) run();
}

// ---------------------------------------------------------------- films / series

/** AIOStreams' own catalogues (for the Disney+, Apple TV+ and Amazon charts, when it has them). */
let aioCatalogsP = null;
function aioCatalogs() {
  if (!aioBase()) return Promise.resolve([]);
  if (stale("aio") || !aioCatalogsP) aioCatalogsP = getJson(`${aioBase()}/manifest.json`, 20000)
    .then(m => (m.catalogs || []).filter(c => !(c.extra || []).some(x => x.isRequired)).map(c => ({ ...c, aio: true }))).catch(() => []);
  return aioCatalogsP;
}
/** One score, small: IMDb 7.8, the tomato and 92%, Metacritic's coloured square, TMDB, Trakt. */
function scoreChip(r) {
  // each source's logo, then its score (Metacritic's in its coloured square)
  const v = esc(String(r.value || ""));
  const logo = { imdb: "brands/imdb.svg", mc: "brands/metacritic.svg", tmdb: "brands/tmdb.svg", trakt: "brands/trakt.svg" }[r.src];
  let mark = logo ? `<img class="sc-${r.src === "mc" ? "metacritic" : r.src}" src="${logo}" alt="${esc(r.label)}">` : `<em>${esc(r.label)}</em>`, val = v;
  if (r.src === "rt") { const n = parseInt(r.value, 10); mark = `<img class="sc-rt${n < 60 ? " rotten" : ""}" src="awards/tomato.svg" alt="Rotten Tomatoes">`; }
  if (r.src === "mc") { const n = parseInt(r.value, 10); val = `<b class="sc-mc ${n >= 61 ? "hi" : n >= 40 ? "mid" : "lo"}">${v}</b>`; }
  return `<div class="sc" title="${esc(r.label)}"><span class="sc-m">${mark}</span><span class="sc-v">${val}</span></div>`;
}

/** A Top list, 25 long: the service's own Top 10, then what was in it on recent days (kept by lucapi). */
async function topList(c) {
  try {
    const j = await getJson(`${feed()}/toplist/${c.type}/${encodeURIComponent(c.id)}.json${c.aio ? "?aio=1" : ""}`, 20000);
    if (j.metas && j.metas.length) return j.metas;
  } catch (e) {}
  return anyCatalogRow(c);
}
async function anyCatalogRow(c) {
  if (!c.aio) return catalogRow(c);
  try { return (await getJson(`${aioBase()}/catalog/${c.type}/${c.id}.json`, 20000)).metas || []; } catch (e) { return []; }
}

/** Films and Series: Trending Now, New for you, then the Top 10s of each service, then the boxes. */
async function showBrowse(type) {
  const v = $("#view");
  v.innerHTML = "";
  const kind = type === "movie" ? "Films" : "Series";
  const hero = createHero(kind);
  const rows = h(`<div class="rows"></div>`);
  v.append(hero.el, rows);
  await loadProgress();
  const [lists, aio, { hero: heroCats }] = await Promise.all([catalogs(), aioCatalogs(), homeCats()]);
  const mine = lists.filter(c => c.type === type), theirs = aio.filter(c => c.type === type);
  const find = (re, ...pools) => { for (const p of pools) { const c = p.find(x => re.test((x.name || "").trim())); if (c) return c; } return null; };
  const plan = [
    { name: "Trending Today", cat: find(/trending/i, mine, theirs) },
    { name: `New ${kind} For You`, cat: find(/^new .*for you/i, mine) },
    { name: "All Time Recommendations", cat: find(/all.?time/i, mine) },
    { name: `Netflix Top ${kind}`, cat: find(/netflix top/i, mine, theirs), top: true },
    { name: `Disney+ Top ${kind}`, cat: find(/disney\s*\+/i, theirs, mine), top: true },
    { name: `Apple TV+ Top ${kind}`, cat: find(/apple tv\s*\+/i, theirs, mine), top: true },
    { name: `Amazon Top ${kind}`, cat: find(/prime video|amazon/i, theirs, mine), top: true },
  ].filter(p => p.cat);
  const slots = plan.map(() => { const s = document.createElement("div"); rows.appendChild(s); return s; });
  const slotTiles = document.createElement("div"); rows.appendChild(slotTiles);
  tileRows(hiddenRows(), type).then(r => { if (r) slotTiles.replaceWith(r); });
  const results = await Promise.all(plan.map(async (p, i) => {
    const metas = (await (p.top ? topList(p.cat) : anyCatalogRow(p.cat))).map(m => ({ ...m, type }));
    if (metas.length) slots[i].replaceWith(p.top ? top10Row(p.name, metas) : /watchlist/i.test(p.name || "") ? wallRow(p.name, metas, type) : spotRow(p.name, metas, type));
    return metas;
  }));
  const own = (await Promise.all(heroCats.filter(c => c.type === type).map(c => catalogRow(c)))).flat().map(m => ({ ...m, type }));
  hero.start(own.length ? own : slideshowFrom(results));
}

// ---------------------------------------------------------------- title page

async function showTitle(type, id, hint = {}, opts = {}) {
  const v = $("#view");
  v.innerHTML = "";
  const page = h(`<div class="tp"><div class="tp-bd"></div><div class="tp-scrim"></div>
    <button class="back">‹ Back</button>
    <div class="tp-top"><header class="tp-head fade-in"></header><aside class="tp-scores" hidden></aside></div>
    <div class="tp-body"><section class="tp-eps"></section></div>
    <section class="tp-more"></section>
    <div class="tp-drawer"><div class="tp-dr-shade"></div><aside class="tp-dr"><button class="tp-dr-x" title="Close">✕</button><div class="tp-streams"></div></aside></div></div>`);
  v.appendChild(page);
  setTimeout(() => page.classList.add("ready"), 700); // never waits longer than this for the picture
  $(".back", page).onclick = back;
  const [m] = await Promise.all([meta(type, id), loadProgress()]);
  const mm = { ...hint, ...m, id, type };
  const bdUrl = backdrop(mm);
  if (bdUrl) { const img = new Image(); img.onload = () => { $(".tp-bd", page).style.backgroundImage = `url('${bdUrl}')`; $(".tp-bd", page).classList.add("show"); page.classList.add("ready"); }; img.src = bdUrl; }
  setTimeout(() => page.classList.add("ready"), bdUrl ? 450 : 0);
  let saved = {};
  try { (await getJson(`${feed()}/progress/${id}`, 6000)).positions.forEach(p => saved[(p.season ?? "") + ":" + (p.episode ?? "")] = p); } catch (e) {}

  const head = $(".tp-head", page), epsBox = $(".tp-eps", page), right = $(".tp-streams", page);
  const p = progress[id];
  const eps = type === "series" ? (mm.videos || []).filter(x => x.season > 0).sort((a, b) => a.season - b.season || a.episode - b.episode) : [];
  // The episode you're on, or the first you haven't finished.
  let cur = p && p.season ? { season: p.season, episode: p.episode }
    : (() => { const n = eps.find(e => !(saved[e.season + ":" + e.episode] || {}).finished); return n ? { season: n.season, episode: n.episode } : null; })();
  const epOf = (c) => c && eps.find(x => x.season === c.season && x.episode === c.episode);

  const resumeLabel = () => {
    if (type === "series") {
      if (!cur) return "Play";
      const sp = saved[cur.season + ":" + cur.episode];
      return `${sp && !sp.finished && sp.position > 20 ? "Resume" : "Play"} S${cur.season} E${cur.episode}${sp && !sp.finished && sp.position > 20 ? " · " + fmt(sp.position) : ""}`;
    }
    const sp = saved[":"];
    return sp && !sp.finished && sp.position > 20 ? "Resume · " + fmt(sp.position) : "Play";
  };
  head.innerHTML = `${mm.logo ? `<img class="tp-logo" src="${esc(mm.logo)}" alt="${esc(mm.name)}">` : `<h1>${esc(mm.name)}</h1>`}
    <div class="tp-meta">${esc([mm.releaseInfo || mm.year, mm.runtime, (mm.genres || []).slice(0, 3).join(", ")].filter(Boolean).join("   ·   "))}</div>
    ${p ? `<div class="tp-progress">${esc(progressLine(p))}</div>` : ""}
    <p class="tp-desc">${esc(mm.description || "")}</p>
    <div class="btns"><button class="btn primary big" id="resumeBtn">${PLAY}${esc(resumeLabel())}</button><button class="btn big" id="chooseBtn">Choose stream</button><button class="btn big" id="wlBtn">＋  Watchlist</button><button class="btn big" id="trailerBtn" hidden>${PLAY}Watch trailer</button>${type === "movie" ? `<button class="btn big" id="markBtn"></button>` : ""}<button class="btn big" id="loveBtn"></button></div>`;
  const logo = $(".tp-logo", head); if (logo) logo.onerror = () => logo.replaceWith(h(`<h1>${esc(mm.name)}</h1>`));
  // In cinemas / not out yet
  (id in relCache ? Promise.resolve(relCache[id]) : fetch(`${feed()}/release`, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ ids: [id] }) }).then(r => r.json()).then(j => (relCache[id] = (j.items || {})[id] || { s: "" })))
    .then(r => { if (r && r.s && document.body.contains(head)) $(".tp-meta", head).insertAdjacentHTML("afterend", `<div class="tp-rel ${r.s}">${esc(relLine(r))}</div>`); })
    .catch(() => {});
  // Resume: the streams for that episode, best first; one more click plays.
  const startBest = () => {
    if (type === "series" && !cur) return toast("Pick an episode first.");
    const sp = type === "series" ? saved[cur.season + ":" + cur.episode] : saved[":"];
    const e = type === "series" ? epOf(cur) : null;
    playBest(mm, cur ? cur.season : null, cur ? cur.episode : null, e ? e.name || e.title || "" : "", sp && !sp.finished && sp.position > 20 ? sp.position : 0);
  };
  $("#resumeBtn", head).onclick = startBest;
  // Watch trailer: Cinemeta's YouTube trailer, else TMDB's (from lucapi); the button only shows when there is one.
  {
    const tb = $("#trailerBtn", head);
    const known = ((mm.trailerStreams || [])[0] || {}).ytId || ((mm.trailers || []).find(t => t.type === "Trailer") || {}).source || "";
    const show = (yt) => { if (!yt || !/^[\w-]{6,20}$/.test(yt) || !invoke) return;
      tb.hidden = false; tb.onclick = () => invoke("open_trailer", { id: yt }).catch(e => toast("Couldn't open the trailer: " + e)); };
    if (known) show(known);
    else getJson(`${feed()}/trailer/${type}/${id}`, 15000).then(r => show(r.yt)).catch(() => {});
  }
  if (opts.autoplay) setTimeout(startBest, 300);

  // Streams stay out of the way: "Choose stream" slides them in from the right for the selected episode.
  const drawer = $(".tp-drawer", page);
  const isOpen = () => drawer.classList.contains("open");
  const close = () => drawer.classList.remove("open");
  const pick = (season, episode, title) => streamsPanel(right, mm, season, episode, title, saved);
  const openStreams = () => {
    if (type === "series" && !cur) return toast("Pick an episode first.");
    const e = epOf(cur);
    pick(cur ? cur.season : null, cur ? cur.episode : null, e ? e.name || e.title || "" : "");
    drawer.classList.add("open");
  };
  $("#chooseBtn", head).onclick = openStreams;
  // Love: watched isn't the same as liked; loved titles steer your recommendation rows
  const lb = $("#loveBtn", head);
  const loveLabel = () => { const on = lovedIds.has(id); lb.innerHTML = `${HEART}<span>${on ? "Loved" : "Love"}</span>`; lb.classList.toggle("loved", on); };
  loveLabel();
  lb.onclick = async () => { lb.disabled = true; await setLove(type, id, mm.name, !lovedIds.has(id)); loveLabel(); lb.disabled = false; };
  $(".tp-dr-x", page).onclick = close;
  $(".tp-dr-shade", page).onclick = close;
  const onKey = (ev) => { if (!document.body.contains(page)) return document.removeEventListener("keydown", onKey, true);
    if (ev.key === "Escape" && isOpen()) { ev.stopPropagation(); close(); } };
  document.addEventListener("keydown", onKey, true);

  // Scores (IMDb, Rotten Tomatoes, Metacritic, TMDB, Trakt), small, under the line about it
  getJson(`${feed()}/ratings/${type}/${id}`, 15000).then(r => {
    const items = r.items || [], box = $(".tp-scores", page);
    if (!items.length || !box) return;
    const order = ["imdb", "rt", "mc", "tmdb", "trakt"];
    items.sort((a, b) => order.indexOf(a.src) - order.indexOf(b.src));
    box.innerHTML = `<h3>Ratings</h3>` + items.map(scoreChip).join("");
    box.hidden = false;
    box.classList.add("fade-in");
  }).catch(() => {});

  // You may also like: under the episodes (or the buttons, for a film); scroll down to it on long series.
  getJson(`${feed()}/similar/${type}/${id}`, 30000).then(r => {
    const metas = (r.metas || []).filter(m => m.id !== id);
    if (metas.length && document.body.contains(page)) $(".tp-more", page).appendChild(row("You may also like", metas, type));
  }).catch(() => {});

  // Watchlist: your Trakt watchlist, which your Watchlist rows are built from.
  const wl = $("#wlBtn", head);
  let onList = false;
  const wlLabel = () => { wl.textContent = onList ? "✓  On watchlist" : "＋  Watchlist"; wl.classList.toggle("done", onList); };
  getJson(`${feed()}/watchlist`, 8000).then(r => { onList = (r.items || []).includes(id); wlLabel(); }).catch(() => {});
  wl.onclick = async () => {
    wl.disabled = true;
    try {
      const r = await fetch(`${feed()}/watchlist`, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ imdb: id, type, add: !onList }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.error || "HTTP " + r.status);
      onList = j.on; wlLabel();
      if (onList) watchlistIds.add(id); else watchlistIds.delete(id);
      applyBookmarks();
      toast(onList ? `Added ${mm.name} to your watchlist.` : `Took ${mm.name} off your watchlist.`);
    } catch (err) { toast("Couldn't change your watchlist: " + err.message); }
    wl.disabled = false;
  };

  // Marking what you watched before Ember: saved on the Pi and in your Trakt history.
  const isDone = (k) => !!(saved[k] || {}).finished;
  const aired = (e) => !e.released || new Date(e.released) <= new Date();
  const mark = async (list, watched, all = false) => {
    try {
      const r = await fetch(`${feed()}/progress/watched`, { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ imdb: id, type, watched, all, episodes: list.map(e => [e.season, e.episode]) }) });
      if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error || "HTTP " + r.status);
    } catch (err) { toast("Couldn't update lucapi: " + err.message); return false; }
    const keys = type === "series" ? list.map(e => e.season + ":" + e.episode) : [":"];
    for (const k of keys) { if (watched) saved[k] = { ...(saved[k] || {}), finished: true, percent: 100 }; else delete saved[k]; }
    // the badge on this title's posters
    if (type === "movie") { if (watched) watchedMap[id] = "done"; else delete watchedMap[id]; }
    else {
      const airedEps = eps.filter(aired), seen = airedEps.filter(e => isDone(e.season + ":" + e.episode)).length;
      if (seen && seen >= airedEps.length) watchedMap[id] = "done"; else if (seen) watchedMap[id] = "partial"; else delete watchedMap[id];
    }
    const pk = p ? (type === "series" ? p.season + ":" + p.episode : ":") : null;
    if (pk && keys.includes(pk)) delete progress[id];
    if (type === "series" && (!cur || isDone(cur.season + ":" + cur.episode))) {
      const n = eps.find(e => aired(e) && !isDone(e.season + ":" + e.episode));
      if (n) cur = { season: n.season, episode: n.episode };
    }
    $("#resumeBtn", head).innerHTML = PLAY + esc(resumeLabel());
    return true;
  };
  // A second click within 4 seconds confirms (for big changes, like a whole show).
  const twice = (btn, ask, fn) => {
    if (btn.dataset.armed) { delete btn.dataset.armed; return fn(); }
    btn.dataset.armed = "1"; const was = btn.textContent; btn.textContent = ask;
    setTimeout(() => { if (btn.dataset.armed) { delete btn.dataset.armed; btn.textContent = was; } }, 4000);
  };
  if (type === "movie") {
    const mb = $("#markBtn", head);
    const label = () => { mb.textContent = isDone(":") ? "✓  Watched" : "Mark as watched"; mb.classList.toggle("done", isDone(":")); };
    label();
    mb.onclick = async () => { if (await mark([], !isDone(":"))) { label(); toast(isDone(":") ? `Marked ${mm.name} as watched.` : `${mm.name} is unwatched again.`); } };
  }

  if (type === "series") {
    const seasons = [...new Set(eps.map(e => e.season))];
    let season = cur ? cur.season : seasons[0];
    const drawEps = () => {
      const opt = seasons.map(s => `<option value="${s}" ${s === season ? "selected" : ""}>Season ${s}</option>`).join("");
      const count = eps.filter(e => e.season === season).length;
      const inSeason = eps.filter(e => e.season === season && aired(e));
      const seasonDone = inSeason.length && inSeason.every(e => isDone(e.season + ":" + e.episode));
      const allAired = eps.filter(aired);
      const showDone = allAired.length && allAired.every(e => isDone(e.season + ":" + e.episode));
      epsBox.innerHTML = `<div class="tp-eps-head"><div class="select"><select>${opt}</select></div><span class="muted">${count} episodes</span>
        <div class="grow"></div>
        <button class="btn sm ${seasonDone ? "done" : ""}" id="markSeason">${seasonDone ? "✓  Season watched" : "Mark season watched"}</button>
        <button class="btn sm ghost" id="markShow">${showDone ? "Mark show unwatched" : "Mark whole show watched"}</button></div><div class="ep-grid"></div>`;
      $("select", epsBox).onchange = (e) => { season = +e.target.value; drawEps(); };
      $("#markSeason", epsBox).onclick = async () => {
        if (!inSeason.length) return toast("Nothing in this season has aired yet.");
        if (await mark(inSeason, !seasonDone)) { toast(seasonDone ? `Season ${season} is unwatched again.` : `Marked season ${season} as watched.`); drawEps(); }
      };
      $("#markShow", epsBox).onclick = (ev) => twice(ev.currentTarget, showDone ? "Click again: unwatch all" : `Click again: mark all ${allAired.length}`, async () => {
        if (await mark(allAired, !showDone, true)) { toast(showDone ? `${mm.name} is unwatched again.` : `Marked all of ${mm.name} as watched.`); drawEps(); }
      });
      const grid = $(".ep-grid", epsBox);
      eps.filter(e => e.season === season).forEach(e => {
        const sp = saved[e.season + ":" + e.episode];
        const isCur = cur && cur.season === e.season && cur.episode === e.episode;
        const soon = !aired(e);
        const el = h(`<div class="epc ${isCur ? "sel" : ""} ${soon ? "notyet" : ""}">
            <div class="thumb" style="background-image:url('${esc(e.thumbnail || "")}')">
              ${soon ? `<span class="rel soon">${e.released ? "Coming " + esc(relDate(e.released.slice(0, 10))) : "Coming soon"}</span>` : ""}
              ${aired(e) ? `<button class="ep-mark ${sp && sp.finished ? "on" : ""}" title="${sp && sp.finished ? "Watched (click to undo)" : "Mark as watched"}">✓</button>` : ""}
              ${sp && !sp.finished ? `<div class="bar"><i style="width:${Math.max(3, sp.percent)}%"></i></div>` : ""}
              <span class="num">E${e.episode}</span></div>
            <div class="t">${esc(e.name || e.title || "Episode " + e.episode)}</div>
            <div class="d">${esc((e.released || "").slice(0, 10))}${sp && !sp.finished ? ` · <span class="acc">${fmt(sp.position)} in</span>` : ""}</div></div>`);
        const mk = $(".ep-mark", el);
        if (mk) mk.onclick = async (ev) => { ev.stopPropagation(); const done = isDone(e.season + ":" + e.episode); if (await mark([e], !done)) drawEps(); };
        el.onclick = () => { grid.querySelectorAll(".epc").forEach(x => x.classList.remove("sel")); el.classList.add("sel");
          cur = { season: e.season, episode: e.episode }; $("#resumeBtn", head).innerHTML = PLAY + esc(resumeLabel());
          if (isOpen()) pick(e.season, e.episode, e.name || e.title || ""); };
        grid.appendChild(el);
      });
    };
    drawEps();
  } else {
    epsBox.remove();
    page.querySelector(".tp-body").classList.add("film");
  }
}

// ---------------------------------------------------------------- streams

const BADGES = [
  [/\b(2160p|4k|uhd)\b/i, "4K", "q4k"], [/\b1080p\b/i, "1080p", "q"], [/\b720p\b/i, "720p", "q"], [/\b480p\b/i, "SD", "q"],
  [/\b(dv|dovi|dolby ?vision)\b/i, "Dolby Vision", "hdr"], [/\bhdr10\+|hdr10plus\b/i, "HDR10+", "hdr"], [/\bhdr(10)?\b/i, "HDR", "hdr"],
  [/\batmos\b/i, "Atmos", "audio"], [/\btrue ?hd/i, "TrueHD", "audio"], [/\bdts[- :.]?(hd|x|ma)/i, "DTS-HD", "audio"], [/\bdts/i, "DTS", "audio"],
  [/\b(ddp|dd\+|e-?ac-?3)/i, "DD+", "audio"], [/\b(dd(?![p+])|ac-?3)/i, "DD", "audio"], [/\b(remux)\b/i, "Remux", ""],
];
function badges(text) {
  const out = []; const seen = new Set();
  for (const [re, label, cls] of BADGES) {
    if (!re.test(text)) continue;
    if ((label === "HDR" && seen.has("HDR10+")) || (label === "DTS" && seen.has("DTS-HD")) || (label === "DD" && seen.has("DD+"))) continue;
    if (["1080p", "720p", "SD"].includes(label) && seen.has("4K")) continue;
    seen.add(label); out.push(`<span class="badge ${cls}">${label}</span>`);
  }
  if (!seen.has("4K") && !seen.has("1080p") && !seen.has("720p") && !seen.has("SD") && /\bHD\b/.test(text)) out.unshift(`<span class="badge q">HD</span>`);
  return out.join("");
}

/** Turns AIOStreams' many-line description into: a release name, a short line of extras, size, cached or not. */
function describe(s) {
  const raw = `${s.name || ""}\n${s.title || s.description || ""}`;
  const lines = raw.split("\n").map(l => l.replace(/[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}\u{2B00}-\u{2BFF}]/gu, "").replace(/\s+/g, " ").trim()).filter(Boolean);
  const file = (s.behaviorHints && s.behaviorHints.filename) || lines.find(l => /\.\w{2,4}$|\.(S\d|\d{3,4}p)/i.test(l) && l.includes(".")) || "";
  const size = (raw.match(/(\d+(?:\.\d+)?)\s?(GB|GiB|MB|MiB)\b/i) || []);
  const cached = /⚡|\[(AD|RD|PM|TB|DL)\+?\]/.test(raw);
  const langs = lines.find(l => /\b(english|italian|spanish|french|german|portuguese|japanese|multi|dual audio)\b/i.test(l) && l.length < 60) || "";
  // No file name: use the descriptive lines (show, episode), skipping the addon tag, quality, size, cache and language lines.
  const junk = (l) => l === langs || /^(aio|aiostreams)$/i.test(l) || /^(HD|SD|4K|UHD|\d{3,4}p)$/i.test(l) || /\d\s?(GB|MB|GiB|MiB)\b/i.test(l)
    || /^\[?(AD|RD|PM|TB|DL)\]?\+?$/i.test(l.replace(/[⚡\s]/g, "")) || /^(DD\+?|DDP|AAC|AC3|DTS.*|TrueHD.*|Atmos|English|10bit.*)$/i.test(l);
  const name = file || lines.filter(l => !junk(l)).slice(0, 2).join(" · ") || lines[0] || "Stream";
  return { raw, name, size: size[1] ? `${size[1]} ${size[2].toUpperCase().replace("IB", "B")}` : "", cached, langs };
}

async function streamsPanel(right, mm, season, episode, epTitle, saved, autoplay) {
  const id = mm.type === "series" ? `${mm.id}:${season}:${episode}` : mm.id;
  const sp = saved[(season ?? "") + ":" + (episode ?? "")];
  const resume = sp && !sp.finished && sp.position > 20 ? sp : null;
  right.innerHTML = `<div class="panel sticky"><div class="sp-head"><h3>${mm.type === "series" ? `S${season} E${episode}${epTitle ? " · " + esc(epTitle) : ""}` : "Streams"}</h3>
    ${resume ? `<div class="resume-note">Resumes at <b>${fmt(resume.position)}</b> <span class="muted">· ${esc(resume.device)}, ${esc(resume.ago)} ago</span></div>
      <label class="muted small"><input type="checkbox" class="fromstart"> Start from the beginning</label>` : ""}
    <div class="muted small">Pick one to play it. Play on the page picks the best for you.</div></div>
    <div class="streams"><div class="muted">Finding streams…</div></div></div>`;
  const box = $(".streams", right);
  if (!aioBase()) { box.innerHTML = `<div class="muted">Add your AIOStreams link in Settings first.</div>`; return; }
  let streams = [];
  try { streams = ((await getJson(`${aioBase()}/stream/${mm.type}/${id}.json`, 30000)).streams || []).filter(s => s.url); }
  catch (e) { box.innerHTML = `<div class="muted">Couldn't reach AIOStreams: ${esc(e.message)}</div>`; return; }
  if (!streams.length) { box.innerHTML = `<div class="muted">No streams found.</div>`; return; }
  box.innerHTML = "";
  streams.forEach((s, i) => {
    const d = describe(s);
    const el = h(`<div class="stream" title="${esc(d.raw)}">
      <div class="badges">${badges(d.raw)}${d.size ? `<span class="badge">${d.size}</span>` : ""}${d.cached ? `<span class="badge cached">⚡ Cached</span>` : ""}</div>
      <div class="sname">${esc(d.name)}</div>${d.langs ? `<div class="src">${esc(d.langs)}</div>` : ""}</div>`);
    el.onclick = () => {
      const fromStart = right.querySelector(".fromstart")?.checked;
      play(s.url, mm, season, episode, epTitle, resume && !fromStart ? resume.position : 0);
    };
    box.appendChild(el);
  });
}

// ---------------------------------------------------------------- playing

let watching = null;
let attempt = null; // { mm, season, episode, epTitle, ranked, n } while the picker is in charge

/** Plays the best stream the Pi's picker finds; if it errors or stalls, the next best, from the same point. */
let picking = false;
async function playBest(mm, season, episode, epTitle, start) {
  if (picking) return; // already finding one: ignore the second press
  picking = true;
  try { return await playBestInner(mm, season, episode, epTitle, start); } finally { setTimeout(() => { picking = false; }, 1500); }
}
async function playBestInner(mm, season, episode, epTitle, start) {
  if (!aioBase()) { go("settings"); return toast("Add your AIOStreams link first."); }
  const full = { ...(await meta(mm.type, mm.id)), ...mm };
  loader.show({ art: backdrop(full), logo: full.logo, title: full.name,
    sub: season ? `S${season} · E${episode}${epTitle ? " · " + epTitle : ""}${start ? "  ·  from " + fmt(start) : ""}` : (start ? "from " + fmt(start) : ""),
    steps: ["Finding streams", "Testing the best ones for speed", "Starting playback"] });
  const t2 = setTimeout(() => loader.step(1), 1800);
  const id = mm.type === "series" ? `${mm.id}:${season}:${episode}` : mm.id;
  const runtime = parseInt(mm.runtime) || "";
  let res;
  try {
    res = await getJson(`${feed()}/pick/${mm.type}/${encodeURIComponent(id)}?aio=${encodeURIComponent(store.get("aio"))}` +
      `&quality=${store.get("quality", "4k")}&runtime=${runtime}&passthrough=${store.get("passthrough", "0")}`, 60000);
  } catch (e) { clearTimeout(t2); loader.hide(); return toast("Couldn't ask lucapi for the best stream: " + e.message); }
  clearTimeout(t2);
  const ranked = (res.ranked || []).filter(x => !x.probe || x.probe.ok);
  if (!ranked.length) { loader.hide(); return toast("No working streams found for this one."); }
  attempt = { mm, season, episode, epTitle, ranked, n: 0 };
  const b = ranked[0], btext = `${b.name}\n${b.title}\n${b.filename}`;
  loader.step(2, `Starting <span class="ld-badges">${badges(btext)}</span>`);
  loader.note(`${b.probe && b.probe.ok ? `tested ${Math.round(b.probe.mbps)} Mbit/s · ` : ""}${(b.filename || b.title.split("\n")[0]).slice(0, 80)}`);
  return play(ranked[0].url, mm, season, episode, epTitle, start, ranked[0]);
}

async function tryNext(why) {
  const a = attempt;
  if (!a) return false;
  const failed = a.ranked[a.n];
  fetch(`${feed()}/pick/failed`, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text: `${failed.name}\n${failed.title}\n${failed.filename}`, why }) }).catch(() => {});
  a.n += 1;
  if (a.n >= a.ranked.length || a.n >= 4) { attempt = null; toast("None of the streams would play properly. Try one from the list."); return false; }
  // carry on from wherever the last one got to
  let start = 0;
  try {
    const r = await getJson(`${feed()}/progress/${a.mm.id}`, 5000);
    const p = r.positions.find(p => a.mm.type === "movie" ? p.season == null : (p.season == a.season && p.episode == a.episode));
    if (p && !p.finished) start = p.position;
  } catch (e) {}
  const full = { ...(await meta(a.mm.type, a.mm.id)), ...a.mm };
  loader.show({ art: backdrop(full), logo: full.logo, title: full.name, sub: `That stream ${why}`,
    steps: [`Switching to the next best (${a.n + 1} of ${Math.min(4, a.ranked.length)})`, "Starting playback"] });
  loader.note((a.ranked[a.n].filename || a.ranked[a.n].title.split("\n")[0]).slice(0, 80));
  await play(a.ranked[a.n].url, a.mm, a.season, a.episode, a.epTitle, start, a.ranked[a.n], true);
  return true;
}

// ---------------------------------------------------------------- new episodes: "Out this week"

async function outThisWeek() {
  let eps = [];
  try { eps = (await getJson(`${feed()}/upcoming?days=7`, 8000)).episodes || []; } catch (e) { return null; }
  if (!eps.length) return null;
  // one card per show: the newest episode that's out, otherwise the next one coming
  const byShow = new Map();
  for (const e of eps) { const cur = byShow.get(e.imdb); if (!cur || (e.out && (!cur.out || e.airs > cur.airs))) byShow.set(e.imdb, e); }
  const r = h(`<section class="row fade-in"><h2>Out this week <span class="kind">Series</span> <small>${byShow.size}</small></h2><div class="strip"></div></section>`);
  for (const e of [...byShow.values()].sort((a, b) => (b.out - a.out) || (a.out ? b.airs.localeCompare(a.airs) : a.airs.localeCompare(b.airs)))) {
    const m = { id: e.imdb, type: "series", name: e.show };
    const c = card(m, "series");
    c.appendChild(h(`<div class="airs ${e.out ? "out" : ""}">${e.out ? "New" : esc(e.day)} · S${e.season} E${e.episode}</div>`));
    c.onclick = () => go("title", "series", e.imdb, m);
    $(".strip", r).appendChild(c);
  }
  return r;
}

/** This week, as a calendar: seven days from yesterday, each with the new episodes of your shows that day. */
/** New This Week: a small list at the bottom right of the hero. "Out now", or when it lands ("Fri 2am"). */
async function weekCalendar() {
  let eps = [];
  try { eps = (await getJson(`${feed()}/upcoming?days=6`, 8000)).episodes || []; } catch (e) { return null; }
  const from = new Date(); from.setHours(0, 0, 0, 0); from.setDate(from.getDate() - 1);
  eps = eps.filter(e => new Date(e.airs) >= from).sort((a, b) => new Date(a.airs) - new Date(b.airs));
  if (!eps.length) return null;
  const when = (e) => {
    if (e.out) return "<span class='acc'>Out now</span>";
    const t = new Date(e.airs), d0 = new Date(); d0.setHours(0, 0, 0, 0);
    const days = Math.round((new Date(t).setHours(0, 0, 0, 0) - d0) / 864e5);
    const hm = t.toLocaleTimeString("en-GB", { hour: "numeric", minute: "2-digit", hour12: true }).replace(":00", "").replace(" ", "").toLowerCase();
    const day = days === 0 ? "Today" : days === 1 ? "Tomorrow" : t.toLocaleDateString("en-GB", { weekday: "short" });
    return `${day} ${hm}`;
  };
  const box = h(`<aside class="wk fade-in"><div class="wk-h">New This Week</div><div class="wk-list"></div></aside>`);
  const list = $(".wk-list", box);
  // Compact: a small picture, the show, and when (the first 4; "and N more" opens the rest)
  const addEp = (e) => {
    const it = h(`<div class="wk-ep"><div class="wk-art"></div><div class="wk-tx"><div class="wk-t">${esc(e.show)}</div>
      <div class="wk-s">${when(e)} · S${e.season} E${e.episode}</div></div></div>`);
    const art = $(".wk-art", it);
    // The show's artwork straight away; the episode still on top once there is one.
    const show = `url('https://images.metahub.space/background/small/${e.imdb}/img'), url('https://images.metahub.space/poster/small/${e.imdb}/img')`;
    art.style.backgroundImage = show;
    it.onclick = () => go("title", "series", e.imdb, { name: e.show });
    list.appendChild(it);
    meta("series", e.imdb).then(m => {
      const ep = (m.videos || []).find(x => x.season === e.season && x.episode === e.episode);
      const better = (ep && ep.thumbnail) || m.background || "";
      if (better) art.style.backgroundImage = `url('${better}'), ${show}`;
    }).catch(() => {});
    return it;
  };
  eps.slice(0, 4).forEach(addEp);
  if (eps.length > 4) {
    const more = h(`<button class="wk-more">and ${eps.length - 4} more</button>`);
    more.onclick = () => {
      more.remove();
      box.classList.add("open");
      const added = eps.slice(4).map(addEp);
      marquee();
      if (TV && window.emberTvFocus && added[0]) window.emberTvFocus(added[0]);
    };
    list.appendChild(more);
  }
  // Names too long for the panel scroll slowly back and forth so you can read them.
  const marquee = () => box.querySelectorAll(".wk-t").forEach(t => {
    if (t.querySelector("span")) return;
    const over = t.scrollWidth - t.clientWidth;
    if (over <= 2) return;
    t.innerHTML = `<span>${t.innerHTML}</span>`;
    t.classList.add("marq");
    t.style.setProperty("--dist", `-${over + 6}px`);
    t.style.setProperty("--dur", `${Math.max(6, over / 12 + 4)}s`);
  });
  setTimeout(marquee, 500); setTimeout(marquee, 2000);
  return box;
}

// ---------------------------------------------------------------- your year in watching

async function showYear(year) {
  year = year || new Date().getFullYear();
  const v = $("#view");
  v.innerHTML = `<div class="page-h"><h1>Your ${year} in watching</h1><div class="muted">From your Trakt history: Omni, Ember TV and Ember PC</div></div><div class="empty">Adding it all up…</div>`;
  let w;
  try { w = await getJson(`${feed()}/wrapped?year=${year}`, 90000); } catch (e) { $(".empty", v).textContent = "Couldn't get your history from lucapi: " + e.message; return; }
  const hr = (x) => x == null ? "" : `${((x + 11) % 12) + 1}${x < 12 ? "am" : "pm"}`;
  const maxM = Math.max(1, ...w.byMonth);
  const months = "JFMAMJJASOND".split("");
  v.innerHTML = `<div class="page-h"><h1>Your ${year} in watching</h1>
      <div class="btns" style="margin-top:8px">${[year - 1, year].map(y => `<button class="chip btn-chip ${y === year ? "on" : ""}" data-y="${y}">${y}</button>`).join("")}</div></div>
    <div class="wrap fade-in">
      <div class="big"><b>${w.hours.toLocaleString()}</b><span>hours watched</span></div>
      <div class="big"><b>${w.episodes.toLocaleString()}</b><span>episodes</span></div>
      <div class="big"><b>${w.films.toLocaleString()}</b><span>films</span></div>
      <div class="big"><b>${w.days}</b><span>whole days of telly</span></div>
      <div class="card2 wide"><h3>By month</h3><div class="months">${w.byMonth.map((m, i) => `<div><i style="height:${Math.round(m / maxM * 100)}%" title="${m} hours"></i><span>${months[i]}</span></div>`).join("")}</div></div>
      <div class="card2"><h3>Your habits</h3>
        <p>Your favourite night is <b>${esc(w.favouriteNight || "—")}</b>, and you usually start around <b>${hr(w.favouriteHour)}</b>.</p>
        ${w.busiestDay ? `<p>Your biggest day was <b>${new Date(w.busiestDay.date).toLocaleDateString("en-GB", { day: "numeric", month: "long" })}</b>: ${w.busiestDay.hours} hours.</p>` : ""}
        ${w.rewatched.length ? `<p>You couldn't stop rewatching <b>${esc(w.rewatched[0].title)}</b> (${w.rewatched[0].plays} times).</p>` : ""}</div>
      <div class="card2"><h3>Top shows</h3><ol>${w.topShows.slice(0, 8).map(x => `<li data-id="${esc(x.imdb || "")}" data-t="series">${esc(x.title)} <span class="muted">${x.episodes} eps · ${Math.round(x.minutes / 60)}h</span></li>`).join("")}</ol></div>
      <div class="card2"><h3>Top films</h3><ol>${w.topFilms.slice(0, 8).map(x => `<li data-id="${esc(x.imdb || "")}" data-t="movie">${esc(x.title)} <span class="muted">${x.year || ""}${x.plays > 1 ? " · " + x.plays + "×" : ""}</span></li>`).join("")}</ol></div>
    </div>`;
  v.querySelectorAll("[data-y]").forEach(b => b.onclick = () => { navStack[navStack.length - 1][1] = [+b.dataset.y]; showYear(+b.dataset.y); });
  v.querySelectorAll("li[data-id]").forEach(li => { if (li.dataset.id) li.onclick = () => go("title", li.dataset.t, li.dataset.id, { name: li.textContent }); });
}

// ---------------------------------------------------------------- "What shall we watch?"

let matchPoll = 0;
async function showMatch() {
  clearInterval(matchPoll);
  const v = $("#view");
  v.innerHTML = `<div class="page-h"><h1>What shall we watch?</h1><div class="muted">Everyone swipes on their phone. Anything you all like appears here.</div></div><div class="empty">Shuffling the deck…</div>`;
  let m;
  try { m = await (await fetch(`${feed()}/match/new`, { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })).json(); }
  catch (e) { $(".empty", v).textContent = "Couldn't reach lucapi: " + e.message; return; }
  v.innerHTML = `<div class="page-h"><h1>What shall we watch?</h1><div class="muted">Everyone swipes on their phone. Anything you all like appears here.</div></div>
    <div class="match fade-in">
      <div class="card2 qr"><img src="${feed()}/match/${m.code}/qr.png" alt="QR code" onerror="this.remove()">
        <div>Scan with your phone's camera, or go to<br><b>${esc(feed().replace(/^https?:\/\//, ""))}/m/${m.code}</b></div>
        <div class="code">${m.code}</div><div class="people muted">Waiting for people to join…</div>
        <button class="btn" id="again">New deck</button></div>
      <div class="matches"><h3>Matches</h3><div class="grid tight"><div class="muted">None yet. Needs at least two people.</div></div></div>
    </div>`;
  $("#again", v).onclick = showMatch;
  let shown = "";
  const tick = async () => {
    if (!document.body.contains($(".match", v))) return clearInterval(matchPoll);
    let st; try { st = await getJson(`${feed()}/match/${m.code}`, 5000); } catch (e) { return; }
    $(".people", v).innerHTML = st.people.length ? st.people.map(p => `<span class="chip">${esc(p.name)} · ${p.swiped}/${st.deckSize}</span>`).join(" ") : "Waiting for people to join…";
    const key = st.matches.map(x => x.id).join();
    if (key === shown) return;
    shown = key;
    const g = $(".matches .grid", v); g.innerHTML = "";
    if (!st.matches.length) g.innerHTML = `<div class="muted">None yet${st.people.length < 2 ? ". Needs at least two people." : "."}</div>`;
    st.matches.forEach(x => g.appendChild(card({ ...x }, x.type)));
    if (st.matches.length) toast(`It's a match: ${st.matches[st.matches.length - 1].name}`);
  };
  tick(); matchPoll = setInterval(tick, 2000);
}

/** The episode after this one (the next season's first, at the end of a season), or null. */
function nextEpisode(mm, season, episode) {
  if (mm.type !== "series" || !season) return null;
  const eps = (mm.videos || []).filter(x => x.season > 0).sort((a, b) => a.season - b.season || a.episode - b.episode);
  const i = eps.findIndex(x => x.season === season && x.episode === episode);
  return i >= 0 && i + 1 < eps.length ? eps[i + 1] : null;
}

async function play(url, mm, season, episode, epTitle, start, chosen, retry) {
  forgetKept(); // Continue watching will have changed: Home is drawn fresh after this
  if (!chosen) attempt = null; // picked by hand: no automatic switching
  if (!invoke) return toast("Playing only works inside the Ember app.");
  const embed = store.get("playMode", "window") === "window";
  const next = nextEpisode(mm, season, episode);
  const opts = [`ember-feed=${feed()}`, `ember-imdb=${mm.id}`, `ember-type=${mm.type}`, `ember-season=${season ?? ""}`,
    `ember-episode=${episode ?? ""}`, `ember-device=${deviceName().replace(/,/g, " ")}`, `ember_osc-next=${next ? "yes" : "no"}`].join(",");
  const title = mm.name + (season ? `  ·  S${season} E${episode}${epTitle ? "  ·  " + epTitle : ""}` : "");
  try {
    await invoke("play", { url, start: start || 0, embed, passthrough: store.get("passthrough", "0") === "1", opts, title });
    loader.hide(1600); // mpv's window is up and covering us by then
    if (!retry && !chosen) toast(`${mm.name}${season ? ` S${season} E${episode}` : ""}${start ? " from " + fmt(start) : ""}${chosen && chosen.filename ? " · " + chosen.filename.slice(0, 60) : ""}. Esc goes back.`, 5000);
    sky.pause(true);
    document.body.classList.add("playing"); // anything showing round the picture is black
    clearInterval(watching);
    watching = setInterval(async () => {
      if (await invoke("playing")) return;
      clearInterval(watching);
      document.body.classList.remove("playing");
      const code = await invoke("last_exit");
      if (attempt && (code === 2 || code === 4) && await tryNext(code === 2 ? "wouldn't play" : "kept stalling")) return;
      if (code === 5 && next) { // "Next episode" in the player
        attempt = null;
        return playBest(mm, next.season, next.episode, next.name || next.title || "", 0);
      }
      attempt = null; sky.pause(false);
      const cur = navStack[navStack.length - 1];
      if (cur && cur[0] === "title" && cur[1][1] === mm.id) { navStack.pop(); go("title", ...cur[1].slice(0, 3)); } // refresh resume points
    }, 2000);
  } catch (e) { loader.hide(); toast("Couldn't start the player: " + e); }
}

// ---------------------------------------------------------------- settings

function showSettings() {
  const v = $("#view");
  v.innerHTML = `<div class="page-h"><h1>Settings</h1></div>
    <div class="form">
      <label>Your AIOStreams manifest link</label><input type="text" id="aio" placeholder="https://…/manifest.json">
      <label>lucapi (ember-feed)</label><input type="text" id="feed" placeholder="http://192.168.4.141:8090">
      <label>This computer's name (shown in resume points)</label><input type="text" id="dev" placeholder="Ember PC">
      <label>Home rows</label>
      <div class="muted" style="font-size:13px">Untick anything you don't want on the home screen.</div>
      <div id="rowToggles" class="toggles"><span class="muted">Loading your rows…</span></div>
      <label>Playing</label>
      <label class="check"><input type="radio" name="pm" value="window"> In the Ember window</label>
      <label class="check"><input type="radio" name="pm" value="full"> Full screen</label>
      <label>Best stream picker: highest quality</label>
      <label class="check"><input type="radio" name="q" value="4k"> 4K when it's available and your connection keeps up</label>
      <label class="check"><input type="radio" name="q" value="1080p"> 1080p (smaller files, safest)</label>
      <label>Sound</label>
      <label class="check"><input type="checkbox" id="pt"> Send Dolby and DTS untouched to a receiver or soundbar (HDMI only; leave off for PC speakers and headphones)</label>
      <label>Background</label>
      <label class="check"><input type="checkbox" id="motion"> Moving background (dust in the sunlight by day, embers in the evening, stars at night)</label>
      <div class="btns" style="margin-top:18px"><button class="btn primary" id="save">Save</button></div>
      <label style="margin-top:28px">Ember picks for Omni (or any app that takes Stremio addons)</label>
      <div class="muted" style="font-size:13px">Add this as an addon in Omni: it gives the same streams as AIOStreams, tested and sorted best first by lucapi. It works at home, where the Apple TV can reach the Pi. It contains your AIOStreams link, so keep it to yourself.</div>
      <div class="btns"><input type="text" id="picksUrl" readonly style="flex:1;min-width:380px"><button class="btn" id="copyPicks">Copy</button></div>
    </div>`;
  (async () => {
    const list = [{ key: "cw", name: "Continue watching" }];
    for (const c of (await homeCats()).rows) if (!/pick up|left off|continue/i.test(c.name || "")) list.push({ key: catKey(c), name: `${niceName(c.name || c.id)} (${c.type === "movie" ? "films" : "series"})` });
    list.push({ key: "out", name: "This week (top right of Home)" });
    try { for (const g of (await layout()).groups || []) list.push({ key: "tiles:" + g.title, name: g.title }); } catch (e) {}
    const hid = hiddenRows();
    const box = $("#rowToggles"); if (!box) return;
    box.innerHTML = "";
    for (const it of list) {
      const el = h(`<label class="toggle"><input type="checkbox" ${hid.has(it.key) ? "" : "checked"}><span>${esc(it.name)}</span></label>`);
      $("input", el).onchange = (e) => { const s = hiddenRows(); e.target.checked ? s.delete(it.key) : s.add(it.key); setHiddenRows(s); toast("Saved. It shows next time you open Home."); };
      box.appendChild(el);
    }
  })();
  $("#aio").value = store.get("aio"); $("#feed").value = feed(); $("#dev").value = deviceName();
  document.querySelector(`input[name=pm][value="${store.get("playMode", "window")}"]`).checked = true;
  $("#pt").checked = store.get("passthrough", "0") === "1";
  document.querySelector(`input[name=q][value="${store.get("quality", "4k")}"]`).checked = true;
  $("#motion").checked = store.get("motion", "1") === "1";
  const picksUrl = () => {
    const aio = store.get("aio"); if (!aio) return "Add your AIOStreams link above first";
    const b64 = btoa(unescape(encodeURIComponent(aio))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
    return `${feed()}/picks/${b64}/manifest.json`;
  };
  $("#picksUrl").value = picksUrl();
  $("#copyPicks").onclick = async () => { try { await navigator.clipboard.writeText($("#picksUrl").value); toast("Copied"); } catch (e) { $("#picksUrl").select(); } };
  if (TV) {
    $(".form", v)?.insertAdjacentHTML("afterbegin", `<label>This TV</label><div class="btns" style="margin-bottom:14px"><button class="btn" id="tvSettings">Dimmer, screensaver and home screen…</button>${EmberTV.openSystem ? `<button class="btn" id="sysSettings">Chromecast settings</button><button class="btn" id="playStore">Play Store</button>` : ""}${EmberTV.testNotices ? `<button class="btn" id="testNotices">Test notifications</button>` : ""}</div>`);
    $("#tvSettings").onclick = () => EmberTV.openTvSettings();
    if ($("#testNotices")) $("#testNotices").onclick = () => {
      if (!EmberTV.testNotices()) toast("Ember's notifications are off: run tv-update.sh on lucapi to switch them back on.");
    };
    if ($("#sysSettings")) { $("#sysSettings").onclick = () => EmberTV.openSystem("settings"); $("#playStore").onclick = () => EmberTV.openSystem("store"); }
  }
  $("#save").onclick = () => {
    store.set("aio", $("#aio").value.trim());
    shareSettings(); store.set("feed", $("#feed").value.trim()); store.set("deviceName", $("#dev").value.trim().slice(0, 30));
    store.set("playMode", document.querySelector("input[name=pm]:checked").value);
    store.set("passthrough", $("#pt").checked ? "1" : "0"); store.set("quality", document.querySelector("input[name=q]:checked").value); store.set("motion", $("#motion").checked ? "1" : "0");
    addonCatalogs = null; sky.start(); $("#picksUrl").value = picksUrl(); toast("Saved");
  };
}

// ---------------------------------------------------------------- shared settings
// Your AIOStreams link is kept on lucapi too, so Ember TV picks it up without typing it with the remote.
function shareSettings() {
  const aio = store.get("aio"); if (!aio) return;
  fetch(`${feed()}/settings/shared`, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ aio }) }).catch(() => {});
}
async function fetchSharedSettings() {
  if (store.get("aio")) { shareSettings(); return; }
  try {
    const s = await getJson(`${feed()}/settings/shared`, 5000);
    if (s.aio) { store.set("aio", s.aio); aioCatalogsP = null; }
  } catch (e) {}
}
fetchSharedSettings();

// ---------------------------------------------------------------- background: day, evening, night (quiet)

const sky = (() => {
  const cv = $("#sky"), g = cv.getContext("2d"), glow = $("#glow");
  let mode = "night", parts = [], raf = 0, paused = false, last = 0, rise = 7 * 60, set = 17 * 60;
  // on the Chromecast: a third of the size and 12 frames a second, so rows still scroll smoothly over it
  const size = () => { const k = TV ? 3 : 2; cv.width = Math.round(innerWidth / k); cv.height = Math.round(innerHeight / k); };
  const pickMode = () => {
    const d = new Date(), m = d.getHours() * 60 + d.getMinutes();
    return m < rise + 20 || m > set + 45 ? "night" : m > set - 75 ? "evening" : "day";
  };
  // A soft glow: the light falls off smoothly (many stops on an eased curve) instead of in visible rings, and a
  // faint grain over everything breaks up the last of the banding a dark screen shows.
  const soft = (size, at, rgb, a, reach = 1) => {
    const st = [];
    for (let k = 0; k <= 16; k++) { const t = k / 16, f = Math.pow(1 - t, 2.2) * (1 - t * 0.15); st.push(`rgba(${rgb},${(a * f).toFixed(4)}) ${(t * 100 * reach).toFixed(1)}%`); }
    return `radial-gradient(${size} at ${at}, ${st.join(", ")})`;
  };
  const grain = (() => {
    try {
      const c = document.createElement("canvas"); c.width = c.height = 160;
      const x = c.getContext("2d"), d = x.createImageData(160, 160);
      for (let i = 0; i < d.data.length; i += 4) { const v = Math.random() * 255; d.data[i] = d.data[i + 1] = d.data[i + 2] = v; d.data[i + 3] = 9; }
      x.putImageData(d, 0, 0);
      return `url(${c.toDataURL()})`;
    } catch (e) { return ""; }
  })();
  const seed = () => {
    parts = [];
    // day: a few motes drifting in the sunlight; evening: embers; night: stars
    const n = mode === "night" ? (TV ? 50 : 70) : mode === "evening" ? (TV ? 20 : 26) : (TV ? 22 : 36);
    for (let i = 0; i < n; i++) parts.push({ x: Math.random(), y: Math.random(), r: Math.random(), s: Math.random(), p: Math.random() * 6.28 });
    const layers = mode === "day"
      ? [soft("1500px 1000px", "92% -12%", "255,206,140", 0.30), soft("900px 600px", "100% 0%", "255,230,190", 0.14), "linear-gradient(#1C140E, #120D0A 55%, #0E0B09)"]
      : mode === "evening"
        ? [soft("1100px 800px", "0% 108%", "240,120,40", 0.24), soft("650px 450px", "6% 100%", "255,170,80", 0.12)]
        : [soft("1100px 700px", "86% -12%", "90,105,170", 0.15)];
    glow.style.background = [grain, ...layers].filter(Boolean).join(", ");
  };
  const draw = (t) => {
    raf = requestAnimationFrame(draw);
    if (paused || t - last < (TV ? 80 : 50)) return; // 20 fps is plenty for this (12 on the TV)
    last = t;
    const W = cv.width, H = cv.height, s = t / 1000;
    g.clearRect(0, 0, W, H);
    for (const p of parts) {
      if (mode === "day") {
        // motes of dust drifting slowly down through the light at the top right
        const life = (s * (0.012 + p.s * 0.014) + p.p) % 1;
        const x = (0.55 + p.x * 0.45) * W + Math.sin(s * 0.3 + p.p) * 14 - life * W * 0.08, y = (p.y * 0.25 + life * 0.6) * H;
        const a = Math.sin(life * Math.PI) * 0.6, r = 0.8 + p.r * 1.3;
        // a soft glow round each mote (blurred, so no hard edge); the TV skips the blur to stay smooth
        if (!TV) { g.shadowColor = `rgba(255,214,150,${a})`; g.shadowBlur = 6; }
        g.fillStyle = `rgba(255,236,200,${a})`;
        g.beginPath(); g.arc(x, y, r, 0, 6.28); g.fill();
        g.shadowBlur = 0;
      } else if (mode === "night") {
        const a = 0.25 + 0.55 * (0.5 + 0.5 * Math.sin(s * (0.4 + p.s) + p.p));
        g.fillStyle = `rgba(232,236,255,${a * 0.8})`; g.fillRect(p.x * W, p.y * H * 0.7, (TV ? 0.8 : 1) + p.r * (TV ? 0.7 : 1), (TV ? 0.8 : 1) + p.r * (TV ? 0.7 : 1));
      } else {
        const life = (s * (0.03 + p.s * 0.04) + p.p) % 1;
        const x = (p.x * 0.35) * W + Math.sin(s * 0.6 + p.p) * 12 + life * W * 0.12, y = H - life * H * 0.85;
        g.fillStyle = `rgba(255,${150 + p.r * 60},70,${(1 - life) * 0.55})`;
        g.beginPath(); g.arc(x, y, 0.8 + p.r * 1.4, 0, 6.28); g.fill();
      }
    }
  };
  async function start() {
    try { const w = await getJson(`${feed()}/weather`, 5000); const hm = (x) => { const [a, b] = (x || "").split(":").map(Number); return a * 60 + b; };
      if (w.sunrise) { rise = hm(w.sunrise); set = hm(w.sunset); } } catch (e) {}
    mode = pickMode(); size(); seed();
    cancelAnimationFrame(raf);
    if (store.get("motion", "1") === "1" && parts.length) raf = requestAnimationFrame(draw); else g.clearRect(0, 0, cv.width, cv.height);
  }
  addEventListener("resize", () => { size(); });
  setInterval(() => { if (pickMode() !== mode) start(); }, 60000);
  document.addEventListener("visibilitychange", () => { paused = document.hidden; });
  return { start, pause: (p) => { paused = p; } };
})();

// ---------------------------------------------------------------- full screen (button top right, or F11)

async function toggleFullscreen() {
  const w = window.__TAURI__ && window.__TAURI__.window && window.__TAURI__.window.getCurrentWindow();
  if (w) {
    try { const on = !(await w.isFullscreen()); await w.setFullscreen(on); $("#fullscreen").classList.toggle("on", on); return; }
    catch (e) { /* fall back to the page's own full screen */ }
  }
  if (document.fullscreenElement) document.exitFullscreen(); else document.documentElement.requestFullscreen().catch(() => {});
}
$("#fullscreen").onclick = toggleFullscreen;
document.addEventListener("keydown", e => { if (e.key === "F11") { e.preventDefault(); toggleFullscreen(); } });

// ---------------------------------------------------------------- start

sky.start();
loader.show({ title: "Ember", steps: [] });
loader.hide(1400);
if (!store.get("aio")) { go("settings"); toast("Paste your AIOStreams link to get streams."); } else go("home");
