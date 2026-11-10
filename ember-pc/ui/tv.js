// Ember TV: the same page, driven by the remote. Does nothing on the PC.
//   arrows move between things (the nearest one that way), OK opens, hold OK on a poster or episode to mark it watched,
//   Back closes a panel or goes back a page, the keyboard comes up for search.
"use strict";
(() => {
  if (!window.EmberTV) return;

  const SEL = [".nav", ".btn", ".btn-chip", ".poster", ".t10", ".cw", ".tile", ".epc", ".wk-ep", ".wk-more", ".hn", ".stream",
    ".apptile", ".tp-dr-x", ".back", "input[type=text]", "input:not([type])", "select", "label.check", "label.toggle",
    ".ep-mark", ".match button", ".tvm-b"].join(",");
  let cur = null;

  const visible = (el) => {
    if (!el.isConnected || el.closest("[hidden]") || el.disabled) return false;
    if (el.closest("#loader") && !el.classList.contains("ld-cancel")) return false;   // only Cancel, on the loading screen
    const r = el.getBoundingClientRect();
    if (r.width < 4 || r.height < 4) return false;
    const st = getComputedStyle(el);
    if (st.visibility === "hidden" || st.display === "none" || +st.opacity === 0) return false;
    // inside a closed drawer?
    const dr = el.closest(".tp-drawer");
    if (dr && !dr.classList.contains("open")) return false;
    return true;
  };
  const all = () => {
    const open = document.querySelector(".tvm") || document.querySelector(".tp-drawer.open");
    const scope = open || document;
    return [...scope.querySelectorAll(SEL)].filter(visible);
  };

  let quick = false; // a held arrow: jump straight there, no smooth scrolling to fall behind
  function setFocus(el, scroll = true) {
    if (!el) return;
    if (cur) cur.classList.remove("tvf");
    cur = el;
    if (!el.hasAttribute("tabindex") && !/^(BUTTON|INPUT|SELECT|A)$/.test(el.tagName)) el.setAttribute("tabindex", "-1");
    el.classList.add("tvf");
    el.focus({ preventScroll: true });
    if (!scroll) return;
    // rows scroll sideways to keep the item in view; the page scrolls to keep its row in the middle
    const strip = el.closest(".strip");
    if (strip) {
      const r = el.getBoundingClientRect(), s = strip.getBoundingClientRect();
      if (r.left < s.left + 60) strip.scrollBy({ left: r.left - s.left - 60, behavior: quick ? "instant" : "smooth" });
      else if (r.right > s.right - 60) strip.scrollBy({ left: r.right - s.right + 60, behavior: quick ? "instant" : "smooth" });
    }
    if (!el.closest("#side")) {
      const view = document.getElementById("view"), r = el.getBoundingClientRect();
      const vh = window.innerHeight;
      if (el.closest(".hero") || el.closest(".tp-head")) view.scrollTo({ top: 0, behavior: quick ? "instant" : "smooth" });
      else if (r.top < vh * 0.18 || r.bottom > vh * 0.88) view.scrollBy({ top: r.top + r.height / 2 - vh * 0.55, behavior: quick ? "instant" : "smooth" });
    }
  }

  // The nearest thing in that direction: straight ahead counts far more than off to the side.
  // Left/right stays on the same row: at the end of a row it stops (it never wraps onto another row).
  function move(dir, held) {
    const items = all();
    if (!cur || !visible(cur) || !items.includes(cur)) { setFocus(first(items)); return; }
    const a = cur.getBoundingClientRect();
    const ax = a.left + a.width / 2, ay = a.top + a.height / 2;
    const sameStrip = cur.closest(".strip");
    const sideways = dir === "left" || dir === "right";
    const level = (el) => { const b = el.getBoundingClientRect(); return b.top < a.bottom - 4 && b.bottom > a.top + 4; };
    let pool = items;
    if (sideways && sameStrip) pool = items.filter(el => el.closest(".strip") === sameStrip);
    else if (sideways && !cur.closest("#side")) {
      const row = items.filter(el => !el.closest("#side") && level(el));
      if (held || row.some(el => el !== cur && (dir === "right" ? el.getBoundingClientRect().left > a.left : el.getBoundingClientRect().left < a.left))) pool = row;
    }
    let best = null, bestScore = Infinity;
    for (const el of pool) {
      if (el === cur) continue;
      const b = el.getBoundingClientRect();
      const bx = b.left + b.width / 2, by = b.top + b.height / 2;
      let along, side;
      if (dir === "right") { along = b.left - a.right; side = Math.abs(by - ay); if (bx <= ax + 2) continue; }
      else if (dir === "left") { along = a.left - b.right; side = Math.abs(by - ay); if (bx >= ax - 2) continue; }
      else if (dir === "down") { along = b.top - a.bottom; side = Math.abs(bx - ax); if (by <= ay + 2) continue; }
      else { along = a.top - b.bottom; side = Math.abs(bx - ax); if (by >= ay - 2) continue; }
      along = Math.max(along, -Math.min(a.width, a.height) / 2);
      let score = Math.max(0, along) + side * (dir === "left" || dir === "right" ? 3 : 0.6);
      // left/right stays in the same row when it can
      if ((dir === "left" || dir === "right") && sameStrip && el.closest(".strip") !== sameStrip) score += 4000;
      // up/down in the sidebar stays in the sidebar
      if ((dir === "up" || dir === "down") && !!cur.closest("#side") !== !!el.closest("#side")) continue;
      // right from the page never jumps into the sidebar either
      if (dir === "right" && el.closest("#side") && !cur.closest("#side")) continue;
      // up/down to another row lands near the left of what's showing, like TV apps
      if (score < bestScore) { bestScore = score; best = el; }
    }
    // the two watchlists side by side: at the end of one, left/right carries on into the other
    if (!best && sideways && sameStrip && cur.closest(".wl-pair")) {
      const pair = cur.closest(".wl-pair");
      const other = items.filter(el => el.closest(".wl-pair") === pair && el.closest(".strip") !== sameStrip && level(el));
      other.sort((x, y) => dir === "right" ? x.getBoundingClientRect().left - y.getBoundingClientRect().left : y.getBoundingClientRect().left - x.getBoundingClientRect().left);
      best = other.find(el => dir === "right" ? el.getBoundingClientRect().left > a.left : el.getBoundingClientRect().left < a.left) || null;
    }
    if (best) setFocus(best);
    // the start of a row: a fresh press of left goes to the sidebar; holding left just stops there
    else if (dir === "left" && !held && !cur.closest("#side")) setFocus(document.querySelector("#side .nav.on") || document.querySelector("#side .nav"));
  }

  function first(items) {
    items = items || all();
    const inView = items.filter(el => !el.closest("#side"));
    const pick = document.querySelector(".tp-drawer.open .stream") || document.querySelector(".hero .btn.primary")
      || document.querySelector(".tp-head .btn.primary") || inView.find(el => el.getBoundingClientRect().top >= 0) || items[0];
    return pick;
  }

  // OK: open it. Held (Android tells us, see WebHomeActivity): mark a poster or episode watched.
  let okLong = false;
  function okDown(e) { if (!e.repeat) okLong = false; }
  window.emberTvLongOk = () => {
    okLong = true;
    if (!cur) return;
    // a poster, a wide card, the spotlight or Continue watching: a menu (watched, love, and remove for Continue watching)
    const holder = cur.matches("[data-wid], [data-tid]") ? cur
      : cur.querySelector("[data-wid]") || (cur.closest(".spot, [data-wid]"));
    if (holder && window.emberTitle) return titleMenu(cur, holder);
    const b = cur.querySelector(".ep-mark"); // an episode's tick
    if (b) b.click();
  };

  // A small TV menu (held OK on Continue watching): the remote stays inside it until it closes.
  let menuFrom = null;
  function closeMenu() {
    const m = document.querySelector(".tvm");
    if (!m) return false;
    m.remove();
    if (menuFrom && visible(menuFrom)) setFocus(menuFrom, false); else setFocus(first());
    menuFrom = null;
    return true;
  }
  function titleMenu(from, holder) {
    closeMenu();
    menuFrom = from;
    const id = holder.dataset.wid || holder.dataset.tid, type = holder.dataset.wtype || holder.dataset.ttype || "movie";
    const name = holder.dataset.wname || holder.dataset.tname || (from.querySelector(".cw-name") || {}).textContent || "this";
    const st = window.emberTitle.state(id), wall = !!holder.closest(".strip.wall"), cw = from.matches(".cw");
    const m = document.createElement("div");
    m.className = "tvm";
    m.innerHTML = `<div class="tvm-box"><div class="tvm-t"></div></div>`;
    m.querySelector(".tvm-t").textContent = name;
    const box = m.querySelector(".tvm-box");
    const add = (label, fn, cls) => { const b = document.createElement("button"); b.className = "tvm-b" + (cls ? " " + cls : ""); b.textContent = label;
      b.onclick = () => { closeMenu(); fn(); }; box.appendChild(b); return b; };
    const firstBtn = add(st.watched ? "Mark as unwatched" : wall ? "Mark as watched (takes it off your watchlist)" : "Mark as watched",
      () => window.emberTitle.watched(type, id, name, !st.watched, wall));
    add(st.loved ? "Take the love off" : "Love it (steers your recommendations)", () => window.emberTitle.love(type, id, name, !st.loved));
    if (cw) add("Remove from Continue watching", () => { const x = from.querySelector(".cw-x"); const next = from.nextElementSibling || from.previousElementSibling;
      if (x) x.click(); setTimeout(() => setFocus(next && visible(next) ? next : first()), 300); }, "danger");
    add("Cancel", () => {});
    document.body.appendChild(m);
    setFocus(firstBtn, false);
  }
  function cwMenu(card) {
    closeMenu();
    menuFrom = card;
    const name = (card.querySelector(".cw-name") || {}).textContent || "this";
    const m = document.createElement("div");
    m.className = "tvm";
    m.innerHTML = `<div class="tvm-box"><div class="tvm-t"></div><button class="tvm-b danger">Remove from Continue watching</button><button class="tvm-b">Cancel</button></div>`;
    m.querySelector(".tvm-t").textContent = name;
    const [rm, cancel] = m.querySelectorAll(".tvm-b");
    rm.onclick = () => { const x = card.querySelector(".cw-x"); const next = card.nextElementSibling || card.previousElementSibling;
      m.remove(); menuFrom = null; if (x) x.click(); setTimeout(() => setFocus(next && visible(next) ? next : first()), 300); };
    cancel.onclick = closeMenu;
    document.body.appendChild(m);
    setFocus(rm, false);
  }
  window.emberTvOkCancel = () => { okLong = true; };
  function okUp() {
    if (okLong || !cur) { okLong = false; return; }
    const el = cur;
    if (el.matches("input[type=text], input:not([type])")) { el.focus(); EmberTV.showKeyboard(); return; }
    if (el.tagName === "SELECT") { el.focus(); return; }
    if (el.matches("label.check, label.toggle")) { const i = el.querySelector("input"); if (i) i.click(); return; }
    el.click();
  }

  let lastMove = 0, lastKey = "", lastKeyAt = 0;
  document.addEventListener("keydown", (e) => {
    const typing = document.activeElement && document.activeElement.matches("input[type=text], input:not([type])") && document.activeElement === cur;
    const k = e.key;
    if (k === "ArrowUp" || k === "ArrowDown" || k === "ArrowLeft" || k === "ArrowRight") {
      if (typing && (k === "ArrowLeft" || k === "ArrowRight")) return; // moving the cursor in the search box
      e.preventDefault(); e.stopPropagation();
      // held down: a steady 7 moves a second, scrolling instantly, so it can't run ahead of itself.
      // (Judged by time as well as e.repeat: the TV doesn't always mark the repeats.)
      const now = performance.now();
      const held = e.repeat || (k === lastKey && now - lastKeyAt < 250);
      lastKey = k; lastKeyAt = now;
      if (held && now - lastMove < 140) return;
      lastMove = now;
      quick = held;
      if (typing) { document.activeElement.blur(); EmberTV.hideKeyboard(); }
      move(k.slice(5).toLowerCase(), held);
    } else if (k === "Enter" || k === "NumpadEnter") {
      if (typing) { e.preventDefault(); EmberTV.hideKeyboard(); return; } // keyboard's "done"
      e.preventDefault(); e.stopPropagation();
      okDown(e);
    }
  }, true);
  document.addEventListener("keyup", (e) => {
    if (e.key === "Enter" || e.key === "NumpadEnter") {
      const typing = document.activeElement && document.activeElement.matches("input[type=text], input:not([type])");
      if (typing && document.activeElement === cur) return;
      e.preventDefault(); okUp();
    }
  }, true);

  // Back (from Android): close the streams panel, else go back a page, else go Home.
  window.emberTvBack = () => {
    // the stream loading screen: Back cancels it
    const cancel = document.querySelector("#loader:not([hidden]) .ld-cancel:not([hidden])");
    if (cancel && typeof cancelLoading === "function") { cancelLoading(); return true; }
    if (closeMenu()) return true;
    const dr = document.querySelector(".tp-drawer.open");
    if (dr) { dr.classList.remove("open"); setTimeout(() => setFocus(first()), 50); return true; }
    // anywhere but Home: straight back to Home (kept as you left it)
    const top = typeof navStack !== "undefined" && navStack.length ? navStack[navStack.length - 1][0] : "home";
    if (top !== "home") {
      if (navStack.length && navStack[0][0] === "home") { navStack.splice(1); navStack.push(["", []]); back(); }
      else go("home");
      return true;
    }
    if (cur && cur.closest("#side")) return false;
    setFocus(document.querySelector('#side .nav[data-page="home"]'));
    return true;
  };
  window.emberTvHome = () => { go("home"); };
  // for Back: where the focus was, and putting it back there
  window.emberTvCurrent = () => cur;
  window.emberTvFocus = (el) => { if (el && el.isConnected) setFocus(el); };
  window.emberTvResumed = () => { if (cur && !visible(cur)) cur = null; };

  // New page drawn: move the focus into it (from the sidebar too, as TV apps do) once it has settled.
  const view = document.getElementById("view");
  let settle = 0;
  new MutationObserver(() => {
    clearTimeout(settle);
    settle = setTimeout(() => {
      // Search: straight into the box with the keyboard up
      const inp = view.querySelector(".search input");
      if (inp && visible(inp)) { setFocus(inp, false); EmberTV.showKeyboard(); return; }
      if (cur && visible(cur) && document.contains(cur) && !cur.closest("#side")) return;
      // the page's content may still be loading: try again for a few seconds
      let tries = 0;
      const attempt = () => {
        const items = all().filter(el => !el.closest("#side"));
        if (items.length) { setFocus(first(items), false); return; }
        if (++tries < 12) setTimeout(attempt, 350);
      };
      attempt();
    }, 300);
  }).observe(view, { childList: true, subtree: false });

  // a click with the mouse/pointer (some remotes) moves the focus there too
  document.addEventListener("focusin", (e) => { const el = e.target.closest && e.target.closest(SEL); if (el && el !== cur && visible(el)) setFocus(el, false); });

  setTimeout(() => setFocus(first()), 800);
})();
