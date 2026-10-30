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

// ---------------------------------------------------------------- navigation

const pages = { home: showHome, search: showSearch, films: () => showBrowse("movie"), series: () => showBrowse("series"),
  library: showLibrary, settings: showSettings };
let navStack = [];
function go(page, ...args) {
  document.querySelectorAll(".nav").forEach(b => b.classList.toggle("on", b.dataset.page === page));
  navStack.push([page, args]);
  if (navStack.length > 30) navStack.shift();
  const fn = page === "title" ? showTitle : pages[page];
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
    if (onPick) c.onclick = () => onPick(m); // home: a click puts it in the big space at the top
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

async function showHome() {
  clearInterval(heroTimer);
  const v = $("#view");
  v.innerHTML = "";
  const hero = h(`<header class="hero"><div class="bd a"></div><div class="bd b"></div><div class="info"></div><div class="dots"></div></header>`);
  const rows = h(`<div class="rows"></div>`);
  v.append(hero, rows);
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
  const startSlideshow = () => {
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

  await loadProgress();
  const cats = await catalogs();
  if (!cats.length) { rows.appendChild(h(`<div class="empty">No rows yet. Check lucapi's address in Settings.</div>`)); return; }
  const slots = cats.map(() => { const s = document.createElement("div"); rows.appendChild(s); return s; });
  const results = await Promise.all(cats.map(async (c, i) => {
    const metas = (await catalogRow(c)).map(m => ({ ...m, type: m.type || c.type }));
    if (metas.length) slots[i].replaceWith(row(homeRowName(c.name || c.id, c.type), metas, c.type, pick));
    return metas;
  }));
  // The slideshow: the top two from each row, no repeats, up to 10.
  const seen = new Set();
  for (let k = 0; k < 2; k++) for (const metas of results) {
    const m = metas[k];
    if (m && !seen.has(m.id) && pool.length < 10) { seen.add(m.id); pool.push(m); }
  }
  if (pool.length) startSlideshow();
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
  v.innerHTML = `<div class="page-h"><h1>${type === "movie" ? "Films" : "Series"}</h1></div>`;
  const rows = h(`<div class="rows"></div>`); v.appendChild(rows);
  await loadProgress();
  const mine = (await catalogs()).filter(c => c.type === type);
  const lists = [...mine.map(c => ({ name: c.name || c.id, load: () => catalogRow(c) })),
    { name: "Popular", load: () => getJson(`${CINEMETA}/catalog/${type}/top.json`).then(j => j.metas || []).catch(() => []) },
    { name: "Featured", load: () => getJson(`${CINEMETA}/catalog/${type}/imdbRating.json`).then(j => j.metas || []).catch(() => []) }];
  const slots = lists.map(() => { const s = document.createElement("div"); rows.appendChild(s); return s; });
  await Promise.all(lists.map(async (l, i) => {
    const metas = (await l.load()).map(m => ({ ...m, type }));
    if (metas.length) slots[i].replaceWith(row(l.name, metas, type));
  }));
}

// ---------------------------------------------------------------- library: everything you're part-way through

async function showLibrary() {
  const v = $("#view");
  v.innerHTML = `<div class="page-h"><h1>Library</h1><div class="muted">Everything you're part-way through, on any device</div></div>`;
  await loadProgress();
  const ids = Object.keys(progress);
  if (!ids.length) { v.appendChild(h(`<div class="empty">Nothing in progress yet.</div>`)); return; }
  const grid = h(`<div class="grid fade-in"></div>`); v.appendChild(grid);
  const metas = await Promise.all(ids.slice(0, 60).map(async id => ({ id, type: progress[id].type, ...(await meta(progress[id].type, id)) })));
  metas.forEach(m => grid.appendChild(card(m, m.type)));
}

// ---------------------------------------------------------------- title page

async function showTitle(type, id, hint = {}, opts = {}) {
  const v = $("#view");
  v.innerHTML = "";
  const page = h(`<div class="title"><div class="bd"></div><button class="back">‹ Back</button><div class="content fade-in">
      <section class="left"></section><section class="right"></section></div></div>`);
  v.appendChild(page);
  $(".back", page).onclick = back;
  const [m] = await Promise.all([meta(type, id), loadProgress()]);
  const mm = { ...hint, ...m, id, type };
  $(".bd", page).style.backgroundImage = `url('${backdrop(mm)}')`;
  let saved = {};
  try { (await getJson(`${feed()}/progress/${id}`, 6000)).positions.forEach(p => saved[(p.season ?? "") + ":" + (p.episode ?? "")] = p); } catch (e) {}

  const left = $(".left", page), right = $(".right", page);
  const p = progress[id];
  left.innerHTML = `${mm.logo ? `<img class="logoimg" style="max-width:440px;max-height:130px;display:block;margin:6px 0 12px" src="${esc(mm.logo)}" alt="">` : ""}
    <h1 style="font:600 34px 'Segoe UI Variable Display','Segoe UI';margin:0 0 4px;${mm.logo ? "display:none" : ""}">${esc(mm.name)}</h1>
    <div class="meta-line">${esc([mm.releaseInfo || mm.year, mm.runtime, mm.imdbRating && "★ " + mm.imdbRating].filter(Boolean).join("  ·  "))}</div>
    <div class="chips">${(mm.genres || []).map(g => `<span class="chip">${esc(g)}</span>`).join("")}</div>
    ${p ? `<div class="resume-note">${esc(progressLine(p))}</div>` : ""}
    <div class="desc" style="-webkit-line-clamp:6;max-width:640px">${esc(mm.description || "")}</div>
    <div class="eps-wrap"></div>`;

  const pick = (season, episode, title) => streamsPanel(right, mm, season, episode, title, saved, opts.autoplay);
  if (type === "series") {
    const eps = (mm.videos || []).filter(x => x.season > 0).sort((a, b) => a.season - b.season || a.episode - b.episode);
    const seasons = [...new Set(eps.map(e => e.season))];
    // Start on the episode you're on, or the first one you haven't finished.
    let cur = p && p.season ? { season: p.season, episode: p.episode }
      : (() => { const n = eps.find(e => !(saved[e.season + ":" + e.episode] || {}).finished); return n ? { season: n.season, episode: n.episode } : null; })();
    let season = cur ? cur.season : seasons[0];
    const wrap = $(".eps-wrap", left);
    const draw = () => {
      wrap.innerHTML = `<div class="panel" style="margin-top:8px"><div class="chips" style="margin:0 0 10px">${seasons.map(s =>
        `<span class="chip btn-chip ${s === season ? "on" : ""}" data-s="${s}">Season ${s}</span>`).join("")}</div><div class="eps"></div></div>`;
      wrap.querySelectorAll("[data-s]").forEach(c => c.onclick = () => { season = +c.dataset.s; draw(); });
      const list = $(".eps", wrap);
      eps.filter(e => e.season === season).forEach(e => {
        const sp = saved[e.season + ":" + e.episode];
        const mark = sp ? (sp.finished ? "✓ watched" : `${fmt(sp.position)} in`) : "";
        const el = h(`<div class="ep ${cur && cur.season === e.season && cur.episode === e.episode ? "sel" : ""}">
            <div class="thumb" style="background-image:url('${esc(e.thumbnail || "")}')">${sp && !sp.finished ? `<div class="bar"><i style="width:${sp.percent}%"></i></div>` : ""}</div>
            <div><div class="t">${e.episode}. ${esc(e.name || e.title || "Episode " + e.episode)}</div>
            <div class="d">${esc((e.released || "").slice(0, 10))}</div></div><div class="tick">${mark}</div></div>`);
        el.onclick = () => { list.querySelectorAll(".ep").forEach(x => x.classList.remove("sel")); el.classList.add("sel");
          cur = { season: e.season, episode: e.episode }; pick(e.season, e.episode, e.name || e.title || ""); };
        list.appendChild(el);
      });
      const sel = $(".ep.sel", list); if (sel) sel.scrollIntoView({ block: "center" });
    };
    draw();
    if (cur) { const e = eps.find(x => x.season === cur.season && x.episode === cur.episode); pick(cur.season, cur.episode, e ? e.name || e.title || "" : ""); }
    else right.innerHTML = `<div class="panel muted">Pick an episode.</div>`;
  } else {
    pick(null, null, "");
  }
}

// ---------------------------------------------------------------- streams

const BADGES = [
  [/\b(2160p|4k|uhd)\b/i, "4K", "q4k"], [/\b1080p\b/i, "1080p", ""], [/\b720p\b/i, "720p", ""],
  [/\b(dv|dovi|dolby ?vision)\b/i, "Dolby Vision", "hdr"], [/\bhdr10\+|hdr10plus\b/i, "HDR10+", "hdr"], [/\bhdr(10)?\b/i, "HDR", "hdr"],
  [/\batmos\b/i, "Atmos", "audio"], [/\btrue ?hd/i, "TrueHD", "audio"], [/\bdts[- :.]?(hd|x|ma)/i, "DTS-HD", "audio"], [/\bdts/i, "DTS", "audio"],
  [/\b(ddp|dd\+|e-?ac-?3)/i, "DD+", "audio"], [/\b(dd(?![p+])|ac-?3)/i, "DD", "audio"], [/\b(remux)\b/i, "Remux", ""],
];
function badges(text) {
  const out = []; const seen = new Set();
  for (const [re, label, cls] of BADGES) {
    if (!re.test(text)) continue;
    if ((label === "HDR" && (seen.has("HDR10+"))) || (label === "DTS" && seen.has("DTS-HD")) || (label === "DD" && seen.has("DD+"))) continue;
    if (["1080p", "720p"].includes(label) && seen.has("4K")) continue;
    seen.add(label); out.push(`<span class="badge ${cls}">${label}</span>`);
  }
  const size = text.match(/(\d+(?:\.\d+)?)\s?(GB|GiB|MB)/i);
  if (size) out.push(`<span class="badge">${size[1]} ${size[2].toUpperCase().replace("IB", "B")}</span>`);
  return out.join("");
}

async function streamsPanel(right, mm, season, episode, epTitle, saved, autoplay) {
  const id = mm.type === "series" ? `${mm.id}:${season}:${episode}` : mm.id;
  const sp = saved[(season ?? "") + ":" + (episode ?? "")];
  const resume = sp && !sp.finished && sp.position > 20 ? sp : null;
  right.innerHTML = `<div class="panel"><h3>Streams${mm.type === "series" ? ` · S${season} E${episode}` : ""}</h3>
    ${resume ? `<div class="resume-note">Resumes at ${fmt(resume.position)} <span class="muted">(${esc(resume.device)}, ${esc(resume.ago)} ago)</span>
      <label class="muted" style="margin-left:8px"><input type="checkbox" class="fromstart"> start from the beginning</label></div>` : ""}
    <div class="streams"><div class="muted">Finding streams…</div></div></div>`;
  const box = $(".streams", right);
  if (!aioBase()) { box.innerHTML = `<div class="muted">Add your AIOStreams link in Settings first.</div>`; return; }
  let streams = [];
  try { streams = ((await getJson(`${aioBase()}/stream/${mm.type}/${id}.json`, 30000)).streams || []).filter(s => s.url); }
  catch (e) { box.innerHTML = `<div class="muted">Couldn't reach AIOStreams: ${esc(e.message)}</div>`; return; }
  if (!streams.length) { box.innerHTML = `<div class="muted">No streams found.</div>`; return; }
  box.innerHTML = "";
  streams.forEach((s, i) => {
    const text = `${s.name || ""}\n${s.title || s.description || ""}`;
    const el = h(`<div class="stream"><div class="badges">${badges(text) || `<span class="badge">${esc((s.name || "Stream").split("\n")[0])}</span>`}</div>
      <div class="src">${esc(text.trim())}</div></div>`);
    el.onclick = () => {
      const fromStart = right.querySelector(".fromstart")?.checked;
      play(s.url, mm, season, episode, epTitle, resume && !fromStart ? resume.position : 0);
    };
    box.appendChild(el);
    if (autoplay && i === 0 && store.get("autoplayFirst", "0") === "1") el.click();
  });
}

// ---------------------------------------------------------------- playing

let watching = null;
async function play(url, mm, season, episode, epTitle, start) {
  if (!invoke) return toast("Playing only works inside the Ember app.");
  const embed = store.get("playMode", "window") === "window";
  const opts = [`ember-feed=${feed()}`, `ember-imdb=${mm.id}`, `ember-type=${mm.type}`, `ember-season=${season ?? ""}`,
    `ember-episode=${episode ?? ""}`, "ember-device=Ember PC"].join(",");
  try {
    await invoke("play", { url, start: start || 0, embed, passthrough: store.get("passthrough", "0") === "1", opts });
    toast(`${mm.name}${season ? ` S${season} E${episode}` : ""}${start ? " from " + fmt(start) : ""}. Esc goes back.`);
    sky.pause(true);
    clearInterval(watching);
    watching = setInterval(async () => {
      if (await invoke("playing")) return;
      clearInterval(watching); sky.pause(false);
      const cur = navStack[navStack.length - 1];
      if (cur && cur[0] === "title" && cur[1][1] === mm.id) { navStack.pop(); go("title", ...cur[1].slice(0, 3)); } // refresh resume points
    }, 2000);
  } catch (e) { toast("Couldn't start the player: " + e); }
}

// ---------------------------------------------------------------- settings

function showSettings() {
  const v = $("#view");
  v.innerHTML = `<div class="page-h"><h1>Settings</h1></div>
    <div class="form">
      <label>Your AIOStreams manifest link</label><input type="text" id="aio" placeholder="https://…/manifest.json">
      <label>lucapi (ember-feed)</label><input type="text" id="feed" placeholder="http://192.168.4.141:8090">
      <label>Playing</label>
      <label class="check"><input type="radio" name="pm" value="window"> In the Ember window</label>
      <label class="check"><input type="radio" name="pm" value="full"> Full screen</label>
      <label>Sound</label>
      <label class="check"><input type="checkbox" id="pt"> Send Dolby and DTS untouched to a receiver or soundbar (HDMI only; leave off for PC speakers and headphones)</label>
      <label>Background</label>
      <label class="check"><input type="checkbox" id="motion"> Moving background (stars at night, embers in the evening)</label>
      <div class="btns" style="margin-top:18px"><button class="btn primary" id="save">Save</button></div>
    </div>`;
  $("#aio").value = store.get("aio"); $("#feed").value = feed();
  document.querySelector(`input[name=pm][value=${store.get("playMode", "window")}]`).checked = true;
  $("#pt").checked = store.get("passthrough", "0") === "1";
  $("#motion").checked = store.get("motion", "1") === "1";
  $("#save").onclick = () => {
    store.set("aio", $("#aio").value.trim()); store.set("feed", $("#feed").value.trim());
    store.set("playMode", document.querySelector("input[name=pm]:checked").value);
    store.set("passthrough", $("#pt").checked ? "1" : "0"); store.set("motion", $("#motion").checked ? "1" : "0");
    addonCatalogs = null; sky.start(); toast("Saved");
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

// ---------------------------------------------------------------- start

sky.start();
if (!store.get("aio")) { go("settings"); toast("Paste your AIOStreams link to get streams."); } else go("home");
