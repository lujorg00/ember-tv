// Ember TV: the same page, driven by the remote. Does nothing on the PC.
//   arrows move between things (the nearest one that way), OK opens, hold OK on a poster to mark it watched,
//   Back closes a panel or goes back a page, the keyboard comes up for search.
"use strict";
(() => {
  if (!window.EmberTV) return;

  const SEL = [".nav", ".btn", ".btn-chip", ".poster", ".t10", ".cw", ".tile", ".epc", ".wk-ep", ".hn", ".stream",
    ".apptile", ".tp-dr-x", ".back", "input[type=text]", "input:not([type])", "select", "label.check", "label.toggle",
    ".ep-mark", ".match button"].join(",");
  let cur = null;

  const visible = (el) => {
    if (!el.isConnected || el.closest("[hidden]") || el.closest("#loader") || el.disabled) return false;
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
    const open = document.querySelector(".tp-drawer.open");
    const scope = open || document;
    return [...scope.querySelectorAll(SEL)].filter(visible);
  };

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
      if (r.left < s.left + 60) strip.scrollBy({ left: r.left - s.left - 60, behavior: "smooth" });
      else if (r.right > s.right - 60) strip.scrollBy({ left: r.right - s.right + 60, behavior: "smooth" });
    }
    if (!el.closest("#side")) {
      const view = document.getElementById("view"), r = el.getBoundingClientRect();
      const vh = window.innerHeight;
      if (el.closest(".hero") || el.closest(".tp-head")) view.scrollTo({ top: 0, behavior: "smooth" });
      else if (r.top < vh * 0.18 || r.bottom > vh * 0.88) view.scrollBy({ top: r.top + r.height / 2 - vh * 0.55, behavior: "smooth" });
    }
  }

  // The nearest thing in that direction: straight ahead counts far more than off to the side.
  function move(dir) {
    const items = all();
    if (!cur || !visible(cur) || !items.includes(cur)) { setFocus(first(items)); return; }
    const a = cur.getBoundingClientRect();
    const ax = a.left + a.width / 2, ay = a.top + a.height / 2;
    let best = null, bestScore = Infinity;
    const sameStrip = cur.closest(".strip");
    for (const el of items) {
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
    if (best) setFocus(best);
    else if (dir === "left" && !cur.closest("#side")) setFocus(document.querySelector("#side .nav.on") || document.querySelector("#side .nav"));
  }

  function first(items) {
    items = items || all();
    const inView = items.filter(el => !el.closest("#side"));
    const pick = document.querySelector(".tp-drawer.open .stream") || document.querySelector(".hero .btn.primary")
      || document.querySelector(".tp-head .btn.primary") || inView.find(el => el.getBoundingClientRect().top >= 0) || items[0];
    return pick;
  }

  // OK: open it. Held on a poster: mark it watched (the tick box on the PC).
  let okTimer = 0, okLong = false;
  function okDown(e) {
    if (e.repeat) return;
    okLong = false;
    clearTimeout(okTimer);
    const el = cur;
    if (el && (el.classList.contains("poster") || el.classList.contains("t10"))) {
      okTimer = setTimeout(() => {
        okLong = true;
        const b = el.querySelector(".wbadge");
        if (b) b.click();
      }, 650);
    }
  }
  function okUp() {
    clearTimeout(okTimer);
    if (okLong || !cur) return;
    const el = cur;
    if (el.matches("input[type=text], input:not([type])")) { el.focus(); EmberTV.showKeyboard(); return; }
    if (el.tagName === "SELECT") { el.focus(); return; }
    if (el.matches("label.check, label.toggle")) { const i = el.querySelector("input"); if (i) i.click(); return; }
    el.click();
  }

  document.addEventListener("keydown", (e) => {
    const typing = document.activeElement && document.activeElement.matches("input[type=text], input:not([type])") && document.activeElement === cur;
    const k = e.key;
    if (k === "ArrowUp" || k === "ArrowDown" || k === "ArrowLeft" || k === "ArrowRight") {
      if (typing && (k === "ArrowLeft" || k === "ArrowRight")) return; // moving the cursor in the search box
      e.preventDefault(); e.stopPropagation();
      if (typing) { document.activeElement.blur(); EmberTV.hideKeyboard(); }
      move(k.slice(5).toLowerCase());
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
    const dr = document.querySelector(".tp-drawer.open");
    if (dr) { dr.classList.remove("open"); setTimeout(() => setFocus(first()), 50); return true; }
    if (typeof navStack !== "undefined" && navStack.length > 1) { back(); return true; }
    const onHome = document.querySelector('#side .nav.on[data-page="home"]');
    if (!onHome) { go("home"); return true; }
    if (cur && cur.closest("#side")) return false;
    setFocus(document.querySelector('#side .nav[data-page="home"]'));
    return true;
  };
  window.emberTvHome = () => { go("home"); };
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
