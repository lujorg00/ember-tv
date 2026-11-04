// Ember PC: your addon rows, search, title pages, streams from AIOStreams, played in mpv, progress on the Pi.
"use strict";
const $ = (s, el = document) => el.querySelector(s);
const h = (html) => { const t = document.createElement("template"); t.innerHTML = html.trim(); return t.content.firstElementChild; };
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const store = {
  get: (k, d = "") => { try { const v = localStorage.getItem(k); return v === null ? d : v; } catch (e) { return d; } },
  set: (k, v) => { try { localStorage.setItem(k, v); } catch (e) {} },
};
const invoke = window.__TAURI__ ? window.__TAURI__.core.invoke : null;
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
  if (!metaCache.has(k)) metaCache.set(k, getJson(`${CINEMETA}/meta/${type}/${id}.json`).then(j => j.meta || {}).catch(() => ({})));
  return metaCache.get(k);
}
async function loadProgress() {
  try { progress = (await getJson(`${feed()}/progress`, 6000)).items || {}; } catch (e) { progress = progress || {}; }
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
  settings: showSettings, match: showMatch, year: showYear };
const hiddenRows = () => { try { return new Set(JSON.parse(store.get("hiddenRows", "[]"))); } catch (e) { return new Set(); } };
const setHiddenRows = (set) => store.set("hiddenRows", JSON.stringify([...set]));
const catKey = (c) => `cat:${c.type}:${c.id}`;
const deviceName = () => store.get("deviceName", "Ember PC") || "Ember PC";
let navStack = [];
function go(page, ...args) {
  document.querySelectorAll(".nav").forEach(b => b.classList.toggle("on", b.dataset.page === page));
  navStack.push([page, args]);
  if (navStack.length > 30) navStack.shift();
  const fn = page === "title" ? showTitle : page === "tile" ? showTile : pages[page];
  $("#view").scrollTop = 0;
  fn(...args);
}
function back() {
  navStack.pop();
  const prev = navStack.pop() || ["home", []];
  go(prev[0], ...prev[1]);
}
document.querySelectorAll(".nav").forEach(b => b.onclick = () => go(b.dataset.page));
document.addEventListener("keydown", e => {
  if (e.key === "Escape" && navStack.length && navStack[navStack.length - 1][0] === "title") back();
  if ((e.ctrlKey && e.key === "f") || (e.key === "/" && document.activeElement.tagName !== "INPUT")) { e.preventDefault(); go("search"); }
});

// ---------------------------------------------------------------- cards and rows

function card(m, type) {
  const p = progress[m.id];
  const el = h(`<div class="poster" title="${esc(m.name)}" style="background-image:url('${esc(poster(m))}')">
    ${poster(m) ? "" : `<div class="name">${esc(m.name)}</div>`}
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

// ---------------------------------------------------------------- home

let addonCatalogs = null;
async function catalogs() {
  if (!addonCatalogs) {
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
  if (!layoutP) layoutP = getJson(`${feed()}/browse/tiles`, 90000).catch(() => ({ groups: [] }));
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
function homeRowName(name, type) {
  if (/\b(films?|movies?|series|shows?|tv)\b/i.test(name)) return name;
  return { name, kind: type === "movie" ? "Films" : "Series" };
}

const HERO_EVERY_MS = 10000, HERO_HOLD_MS = 60000;
let heroTimer = 0;

/** The big slideshow at the top of Home, Films and Series. A page name ("Films") sits over it, blending in. */
function createHero(pageName) {
  clearInterval(heroTimer);
  const hero = h(`<header class="hero ${pageName ? "named" : ""}"><div class="bd a"></div><div class="bd b"></div>
    ${pageName ? `<div class="pagename">${esc(pageName)}</div>` : ""}<div class="info"></div><div class="dots"></div></header>`);
  let flip = false, heroFor = null, pool = [], idx = 0, heldUntil = 0;

  const setHero = async (m) => {
    if (!m || heroFor === m.id) return;
    heroFor = m.id;
    const type = m.type || "movie";
    const full = await meta(type, m.id);
    if (heroFor !== m.id) return;
    const mm = { ...m, ...full };
    const layers = hero.querySelectorAll(".bd"); flip = !flip;
    const on = layers[flip ? 0 : 1], off = layers[flip ? 1 : 0];
    const img = new Image(); img.src = backdrop(mm);
    img.onload = () => { if (heroFor !== m.id) return; on.style.backgroundImage = `url('${img.src}')`; on.classList.add("show"); off.classList.remove("show"); };
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
    setHero(pool[0]);
    clearInterval(heroTimer);
    heroTimer = setInterval(() => {
      if (!document.body.contains(hero)) return clearInterval(heroTimer);
      if (Date.now() < heldUntil || document.hidden || hero.matches(":hover")) return;
      idx = (idx + 1) % pool.length; setHero(pool[idx]);
    }, HERO_EVERY_MS);
  };
  return { el: hero, pick, start };
}

/** The top two from each row, in turn: the slideshow's titles. */
const slideshowFrom = (lists) => { const out = []; for (let k = 0; k < 2; k++) for (const l of lists) if (l[k]) out.push(l[k]); return out; };

async function showHome() {
  const v = $("#view");
  v.innerHTML = "";
  const hero = createHero("");
  const rows = h(`<div class="rows"></div>`);
  v.append(hero.el, rows);
  await loadProgress();
  const { rows: cats, hero: heroCats } = await homeCats();
  if (!cats.length) { rows.appendChild(h(`<div class="empty">No rows yet. Check lucapi's address in Settings.</div>`)); return; }
  const heroList = Promise.all(heroCats.map(c => catalogRow(c).then(ms => ms.map(m => ({ ...m, type: m.type || c.type })))));
  const isContinue = (c) => /pick up|left off|continue/i.test(c.name || "");
  const isTop = (c) => /\btop\b/i.test(c.name || "");
  // Order: continue watching, top 10s, out this week, your other rows, then the tiles.
  const slotCW = document.createElement("div"); rows.appendChild(slotCW);
  const hidden = hiddenRows();
  const shown = cats.filter(c => !hidden.has(catKey(c)));
  const tops = shown.filter(isTop), others = shown.filter(c => !isTop(c) && !isContinue(c));
  const topSlots = tops.map(() => { const d = document.createElement("div"); rows.appendChild(d); return d; });
  const otherSlots = others.map(() => { const d = document.createElement("div"); rows.appendChild(d); return d; });
  const slotTiles = document.createElement("div"); rows.appendChild(slotTiles);

  const cwCat = cats.filter(isContinue);
  if (!hidden.has("cw")) continueRow(cwCat).then(r => { if (r) slotCW.replaceWith(r); });
  if (!hidden.has("out")) weekCalendar().then(r => { if (r) hero.el.appendChild(r); });
  tileRows(hidden).then(r => { if (r) slotTiles.replaceWith(r); });
  const [topLists, otherLists] = await Promise.all([
    Promise.all(tops.map(async (c, i) => {
      const metas = (await catalogRow(c)).map(m => ({ ...m, type: m.type || c.type }));
      if (metas.length) topSlots[i].replaceWith(top10Row(homeRowName(c.name || c.id, c.type), metas, hero.pick));
      return metas;
    })),
    Promise.all(others.map(async (c, i) => {
      const metas = (await catalogRow(c)).map(m => ({ ...m, type: m.type || c.type }));
      if (metas.length) otherSlots[i].replaceWith(row(homeRowName(c.name || c.id, c.type), metas, c.type, hero.pick));
      return metas;
    })),
  ]);
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
    const el = h(`<div class="cw"><div class="cw-art"><div class="cw-label"></div><button class="cw-x" title="Remove from Continue watching">✕</button></div><div class="cw-name"></div></div>`);
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
        label = `▶ ${it.type === "series" && season ? `S${season} · E${episode}` : "Resume"}${left && left <= 10 ? ` · ${left}m left` : ""}`;
        el.querySelector(".cw-art").insertAdjacentHTML("beforeend", `<div class="bar"><i style="width:${Math.max(3, Math.min(100, it.p.progress))}%"></i></div>`);
      } else if (it.type === "series") {
        try { const n = await getJson(`${feed()}/next/${it.id}`, 6000); if (n.season) { season = n.season; episode = n.episode; label = `Next · S${season} · E${episode}`; } } catch (e) {}
      }
      $(".cw-label", el).textContent = label;
      const ep = season && (full.videos || []).find(x => x.season === season && x.episode === episode);
      const art = (ep && ep.thumbnail) || backdrop(full);
      if (art) $(".cw-art", el).style.backgroundImage = `url('${art}')`;
      el.onclick = () => go("title", it.type, it.id, full); // details first; Play starts it
    })();
  }
  return r;
}

/** Top 10: big rank numbers beside wide artwork. */
function top10Row(title, metas, onPick) {
  const label = typeof title === "object" ? `${esc(title.name)} <span class="kind">${title.kind}</span>` : esc(title);
  const r = h(`<section class="row fade-in"><h2>${label}</h2><div class="strip top10"></div></section>`);
  metas.slice(0, 10).forEach((m, i) => {
    const el = h(`<div class="t10"><b>${i + 1}</b><div class="t10-art" style="background-image:url('${esc(backdrop(m))}')"><span>${esc(m.name)}</span></div></div>`);
    el.onclick = () => go("title", m.type, m.id, m);
    $(".strip", r).appendChild(el);
  });
  return r;
}

/** Streaming services, genres, directors, studios, collections, decades (from TMDB, via the Pi). */
async function tileRows(hidden = new Set(), typ = "") {
  const t = await layout();
  if (!t.groups || !t.groups.length) return null;
  const box = h(`<div></div>`);
  for (const g of t.groups) {
    if (hidden.has("tiles:" + g.title)) continue;
    const list = g.tiles.filter(x => !typ || !x.types || x.types.includes(typ));
    if (!list.length) continue;
    const r = h(`<section class="row fade-in"><h2>${esc(g.title)}</h2><div class="strip tiles ${g.style}"></div></section>`);
    for (const tile of list) {
      if (tile.kind === "cat") tileInfo[tile.id] = tile;
      let inner;
      if (g.style === "logo") inner = `<div class="tile logo" style="background:${esc(tile.colour)}">${tile.logo ? `<img src="${esc(tile.logo)}" alt="">` : ""}<span>${esc(tile.title)}</span></div>`;
      else if (g.style === "person") inner = `<div class="tile person"><div class="face" style="background-image:url('${esc(tile.image)}')"></div><span>${esc(tile.title)}</span></div>`;
      else inner = `<div class="tile art" style="background-image:url('${esc(tile.image || "")}')">${g.style === "studio" && tile.logo ? `<img src="${esc(tile.logo)}" alt="">` : ""}<span>${esc(tile.title)}</span></div>`;
      const el = h(inner);
      const first = typ || (tile.types || ["movie"])[0];
      el.onclick = () => go("tile", tile.kind, tile.id, tile.title, (g.style === "person" ? "" : tile.image) || "", first);
      $(".strip", r).appendChild(el);
    }
    box.appendChild(r);
  }
  return box;
}

/** The page behind a tile: its titles, Films or Series where both exist. */
async function showTile(kind, id, title, image, typ) {
  const own = kind === "cat";
  const info = tileInfo[id] || {};
  const both = own ? (info.types || []).length > 1 : ["service", "genre", "company"].includes(kind);
  typ = typ || (own && info.types ? info.types[0] : "movie");
  const v = $("#view");
  v.innerHTML = "";
  const head = h(`<header class="tile-head" style="background-image:url('${esc(image)}')"><div class="shade"></div>
    <button class="back">‹ Back</button><h1>${esc(title)}</h1>
    ${both ? `<div class="chips"><span class="chip btn-chip ${typ === "movie" ? "on" : ""}" data-t="movie">Films</span><span class="chip btn-chip ${typ === "series" ? "on" : ""}" data-t="series">Series</span></div>` : ""}</header>`);
  const grid = h(`<div class="grid fade-in"></div>`);
  const more = h(`<div class="btns" style="padding:0 48px 60px"><button class="btn">More</button></div>`);
  v.append(head, grid, more);
  $(".back", head).onclick = back;
  head.querySelectorAll("[data-t]").forEach(c => c.onclick = () => { navStack[navStack.length - 1][1][4] = c.dataset.t; showTile(kind, id, title, image, c.dataset.t); });
  let page = 1, pages = 1, shown = 0;
  const ids = new Set();
  const load = async () => {
    more.querySelector("button").textContent = "Loading…";
    let r;
    const url = own ? `${feed()}/browse/cat/${id}?type=${typ}&skip=${shown}` : `${feed()}/browse/${kind}/${id}?type=${typ}&page=${page}`;
    try { r = await getJson(url, 60000); } catch (e) { toast("Couldn't load: " + e.message); return; }
    pages = r.pages || 1;
    const fresh = (r.metas || []).filter(m => !ids.has(m.id));
    fresh.forEach(m => { ids.add(m.id); grid.appendChild(card(m, m.type || typ)); });
    shown += (r.metas || []).length;
    if (own && !grid.children.length) grid.appendChild(h(`<div class="empty">Nothing in this list yet.</div>`));
    more.hidden = own ? !(r.more && fresh.length) : page >= pages;
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

async function showBrowse(type) {
  const v = $("#view");
  v.innerHTML = "";
  const hero = createHero(type === "movie" ? "Films" : "Series");
  const rows = h(`<div class="rows"></div>`);
  v.append(hero.el, rows);
  await loadProgress();
  const { rows: homeRows, hero: heroCats } = await homeCats();
  const mine = homeRows.filter(c => c.type === type && !/pick up|left off|continue/i.test(c.name || ""));
  const lists = [...mine.map(c => ({ name: c.name || c.id, load: () => catalogRow(c) })),
    { name: "Popular", load: () => getJson(`${CINEMETA}/catalog/${type}/top.json`).then(j => j.metas || []).catch(() => []) },
    { name: "Featured", load: () => getJson(`${CINEMETA}/catalog/${type}/imdbRating.json`).then(j => j.metas || []).catch(() => []) }];
  const slots = lists.map(() => { const s = document.createElement("div"); rows.appendChild(s); return s; });
  const slotTiles = document.createElement("div"); rows.appendChild(slotTiles);
  tileRows(hiddenRows(), type).then(r => { if (r) slotTiles.replaceWith(r); });
  const results = await Promise.all(lists.map(async (l, i) => {
    const metas = (await l.load()).map(m => ({ ...m, type }));
    if (metas.length) slots[i].replaceWith(/\btop\b/i.test(l.name) ? top10Row(l.name, metas, hero.pick) : row(l.name, metas, type, hero.pick));
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
    <header class="tp-head fade-in"></header>
    <div class="tp-body"><section class="tp-eps"></section><aside class="tp-streams"></aside></div></div>`);
  v.appendChild(page);
  $(".back", page).onclick = back;
  const [m] = await Promise.all([meta(type, id), loadProgress()]);
  const mm = { ...hint, ...m, id, type };
  const bdUrl = backdrop(mm);
  if (bdUrl) { const img = new Image(); img.onload = () => { $(".tp-bd", page).style.backgroundImage = `url('${bdUrl}')`; $(".tp-bd", page).classList.add("show"); }; img.src = bdUrl; }
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
    <div class="tp-meta">${esc([mm.releaseInfo || mm.year, mm.runtime, mm.imdbRating && "★ " + mm.imdbRating, (mm.genres || []).slice(0, 3).join(", ")].filter(Boolean).join("   ·   "))}</div>
    ${p ? `<div class="tp-progress">${esc(progressLine(p))}</div>` : ""}
    <p class="tp-desc">${esc(mm.description || "")}</p>
    <div class="btns"><button class="btn primary big" id="resumeBtn">▶  ${esc(resumeLabel())}</button>
      ${mm.trailers && mm.trailers.length ? "" : ""}</div>`;
  const logo = $(".tp-logo", head); if (logo) logo.onerror = () => logo.replaceWith(h(`<h1>${esc(mm.name)}</h1>`));
  // Resume: the streams for that episode, best first; one more click plays.
  const startBest = () => {
    if (type === "series" && !cur) return toast("Pick an episode first.");
    const sp = type === "series" ? saved[cur.season + ":" + cur.episode] : saved[":"];
    const e = type === "series" ? epOf(cur) : null;
    playBest(mm, cur ? cur.season : null, cur ? cur.episode : null, e ? e.name || e.title || "" : "", sp && !sp.finished && sp.position > 20 ? sp.position : 0);
  };
  $("#resumeBtn", head).onclick = startBest;
  if (opts.autoplay) setTimeout(startBest, 300);

  const pick = (season, episode, title) => streamsPanel(right, mm, season, episode, title, saved);

  if (type === "series") {
    const seasons = [...new Set(eps.map(e => e.season))];
    let season = cur ? cur.season : seasons[0];
    const drawEps = () => {
      const opt = seasons.map(s => `<option value="${s}" ${s === season ? "selected" : ""}>Season ${s}</option>`).join("");
      const count = eps.filter(e => e.season === season).length;
      epsBox.innerHTML = `<div class="tp-eps-head"><div class="select"><select>${opt}</select></div><span class="muted">${count} episodes</span></div><div class="ep-grid"></div>`;
      $("select", epsBox).onchange = (e) => { season = +e.target.value; drawEps(); };
      const grid = $(".ep-grid", epsBox);
      eps.filter(e => e.season === season).forEach(e => {
        const sp = saved[e.season + ":" + e.episode];
        const isCur = cur && cur.season === e.season && cur.episode === e.episode;
        const el = h(`<div class="epc ${isCur ? "sel" : ""}">
            <div class="thumb" style="background-image:url('${esc(e.thumbnail || "")}')">
              ${sp && sp.finished ? `<span class="watched">✓</span>` : ""}
              ${sp && !sp.finished ? `<div class="bar"><i style="width:${Math.max(3, sp.percent)}%"></i></div>` : ""}
              <span class="num">E${e.episode}</span></div>
            <div class="t">${esc(e.name || e.title || "Episode " + e.episode)}</div>
            <div class="d">${esc((e.released || "").slice(0, 10))}${sp && !sp.finished ? ` · <span class="acc">${fmt(sp.position)} in</span>` : ""}</div></div>`);
        el.onclick = () => { grid.querySelectorAll(".epc").forEach(x => x.classList.remove("sel")); el.classList.add("sel");
          cur = { season: e.season, episode: e.episode }; $("#resumeBtn", head).textContent = "▶  " + resumeLabel();
          pick(e.season, e.episode, e.name || e.title || ""); };
        grid.appendChild(el);
      });
    };
    drawEps();
    const e = epOf(cur);
    if (cur) pick(cur.season, cur.episode, e ? e.name || e.title || "" : "");
    else right.innerHTML = `<div class="panel muted">Pick an episode.</div>`;
  } else {
    epsBox.remove();
    page.querySelector(".tp-body").classList.add("film");
    pick(null, null, "");
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
    <div class="muted small">▶ Play picks the best one for you, or choose one here.</div></div>
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
/** This week: a small panel at the top right of the hero. Pick a day; its new episodes show underneath. */
async function weekCalendar() {
  let eps = [];
  try { eps = (await getJson(`${feed()}/upcoming?days=6`, 8000)).episodes || []; } catch (e) { return null; }
  if (!eps.length) return null;
  const day0 = new Date(); day0.setHours(0, 0, 0, 0); day0.setDate(day0.getDate() - 1);
  const days = Array.from({ length: 7 }, (_, i) => { const d = new Date(day0); d.setDate(d.getDate() + i); return d; });
  const key = (d) => d.toDateString();
  const today = key(new Date());
  const on = (d) => eps.filter(e => key(new Date(e.airs)) === key(d));
  const box = h(`<aside class="wk fade-in"><div class="wk-h">This week</div><div class="wk-days"></div><div class="wk-list"></div></aside>`);
  const list = $(".wk-list", box);
  const show = (d, btn) => {
    box.querySelectorAll(".wk-d").forEach(b => b.classList.toggle("on", b === btn));
    list.innerHTML = "";
    const these = on(d);
    if (!these.length) { list.appendChild(h(`<div class="wk-none">Nothing new ${key(d) === today ? "today" : "on " + d.toLocaleDateString("en-GB", { weekday: "long" })}</div>`)); return; }
    for (const e of these.slice(0, 4)) {
      const t = new Date(e.airs);
      const it = h(`<div class="wk-ep"><div class="wk-art"></div><div><div class="wk-t">${esc(e.show)}</div>
        <div class="wk-s">S${e.season} E${e.episode} · ${e.out ? "<span class='acc'>Out now</span>" : t.toLocaleTimeString("en-GB", { hour: "2-digit", minute: "2-digit" })}</div></div></div>`);
      it.onclick = () => go("title", "series", e.imdb, { name: e.show });
      list.appendChild(it);
      meta("series", e.imdb).then(m => {
        const ep = (m.videos || []).find(x => x.season === e.season && x.episode === e.episode);
        const art = (ep && ep.thumbnail) || backdrop({ ...m, id: e.imdb });
        if (art) $(".wk-art", it).style.backgroundImage = `url('${art}')`;
      });
    }
    if (these.length > 4) list.appendChild(h(`<div class="wk-none">and ${these.length - 4} more</div>`));
  };
  let first = null;
  for (const d of days) {
    const n = on(d).length;
    const b = h(`<button class="wk-d ${key(d) === today ? "today" : ""}" title="${n} new"><span>${d.toLocaleDateString("en-GB", { weekday: "short" }).slice(0, 2)}</span><b>${d.getDate()}</b>${n ? "<i></i>" : ""}</button>`);
    b.onclick = (ev) => { ev.stopPropagation(); show(d, b); };
    $(".wk-days", box).appendChild(b);
    if (key(d) === today) first = [d, b];
  }
  // Open on today, or the next day with something new if today has nothing.
  const next = days.map((d, i) => [d, box.querySelectorAll(".wk-d")[i]]).find(([d]) => d >= new Date(new Date().setHours(0, 0, 0, 0)) && on(d).length);
  show(...(first && on(first[0]).length ? first : next || first));
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

async function play(url, mm, season, episode, epTitle, start, chosen, retry) {
  if (!chosen) attempt = null; // picked by hand: no automatic switching
  if (!invoke) return toast("Playing only works inside the Ember app.");
  const embed = store.get("playMode", "window") === "window";
  const opts = [`ember-feed=${feed()}`, `ember-imdb=${mm.id}`, `ember-type=${mm.type}`, `ember-season=${season ?? ""}`,
    `ember-episode=${episode ?? ""}`, `ember-device=${deviceName().replace(/,/g, " ")}`].join(",");
  const title = mm.name + (season ? `  ·  S${season} E${episode}${epTitle ? "  ·  " + epTitle : ""}` : "");
  try {
    await invoke("play", { url, start: start || 0, embed, passthrough: store.get("passthrough", "0") === "1", opts, title });
    loader.hide(1600); // mpv's window is up and covering us by then
    if (!retry && !chosen) toast(`${mm.name}${season ? ` S${season} E${episode}` : ""}${start ? " from " + fmt(start) : ""}${chosen && chosen.filename ? " · " + chosen.filename.slice(0, 60) : ""}. Esc goes back.`, 5000);
    sky.pause(true);
    clearInterval(watching);
    watching = setInterval(async () => {
      if (await invoke("playing")) return;
      clearInterval(watching);
      const code = await invoke("last_exit");
      if (attempt && (code === 2 || code === 4) && await tryNext(code === 2 ? "wouldn't play" : "kept stalling")) return;
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
      <label class="check"><input type="checkbox" id="motion"> Moving background (stars at night, embers in the evening)</label>
      <div class="btns" style="margin-top:18px"><button class="btn primary" id="save">Save</button></div>
      <label style="margin-top:28px">Ember picks for Omni (or any app that takes Stremio addons)</label>
      <div class="muted" style="font-size:13px">Add this as an addon in Omni: it gives the same streams as AIOStreams, tested and sorted best first by lucapi. It works at home, where the Apple TV can reach the Pi. It contains your AIOStreams link, so keep it to yourself.</div>
      <div class="btns"><input type="text" id="picksUrl" readonly style="flex:1;min-width:380px"><button class="btn" id="copyPicks">Copy</button></div>
    </div>`;
  (async () => {
    const list = [{ key: "cw", name: "Continue watching" }];
    for (const c of (await homeCats()).rows) if (!/pick up|left off|continue/i.test(c.name || "")) list.push({ key: catKey(c), name: `${c.name || c.id} (${c.type === "movie" ? "films" : "series"})` });
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
  $("#save").onclick = () => {
    store.set("aio", $("#aio").value.trim()); store.set("feed", $("#feed").value.trim()); store.set("deviceName", $("#dev").value.trim().slice(0, 30));
    store.set("playMode", document.querySelector("input[name=pm]:checked").value);
    store.set("passthrough", $("#pt").checked ? "1" : "0"); store.set("quality", document.querySelector("input[name=q]:checked").value); store.set("motion", $("#motion").checked ? "1" : "0");
    addonCatalogs = null; sky.start(); $("#picksUrl").value = picksUrl(); toast("Saved");
  };
}

// ---------------------------------------------------------------- background: day, evening, night (quiet)

const sky = (() => {
  const cv = $("#sky"), g = cv.getContext("2d"), glow = $("#glow");
  let mode = "night", parts = [], raf = 0, paused = false, last = 0, rise = 7 * 60, set = 17 * 60;
  const size = () => { cv.width = innerWidth / 2; cv.height = innerHeight / 2; };
  const pickMode = () => {
    const d = new Date(), m = d.getHours() * 60 + d.getMinutes();
    return m < rise + 20 || m > set + 45 ? "night" : m > set - 75 ? "evening" : "day";
  };
  const seed = () => {
    parts = [];
    const n = mode === "night" ? 70 : mode === "evening" ? 26 : 0;
    for (let i = 0; i < n; i++) parts.push({ x: Math.random(), y: Math.random(), r: Math.random(), s: Math.random(), p: Math.random() * 6.28 });
    glow.style.background = mode === "day"
      ? "radial-gradient(1200px 700px at 88% -10%, rgba(255,214,150,.16), transparent 60%), linear-gradient(#17110D, #0E0B09)"
      : mode === "evening"
        ? "radial-gradient(900px 700px at 0% 110%, rgba(240,120,40,.20), transparent 60%), radial-gradient(600px 400px at 6% 100%, rgba(255,170,80,.10), transparent 70%)"
        : "radial-gradient(900px 600px at 85% -10%, rgba(90,105,170,.12), transparent 60%)";
  };
  const draw = (t) => {
    raf = requestAnimationFrame(draw);
    if (paused || t - last < 50) return; // 20 fps is plenty for this
    last = t;
    const W = cv.width, H = cv.height, s = t / 1000;
    g.clearRect(0, 0, W, H);
    for (const p of parts) {
      if (mode === "night") {
        const a = 0.25 + 0.55 * (0.5 + 0.5 * Math.sin(s * (0.4 + p.s) + p.p));
        g.fillStyle = `rgba(232,236,255,${a * 0.8})`; g.fillRect(p.x * W, p.y * H * 0.7, 1 + p.r, 1 + p.r);
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
