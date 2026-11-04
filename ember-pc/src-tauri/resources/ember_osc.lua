-- Ember's player controls, laid out like Disney+:
--   ✕ top left (back to Ember), audio & subtitles top right,
--   ⟲10  ▶/❚❚  ⟳10 in the middle, episode + title bottom left, next episode bottom right,
--   a thin seek bar with the times at each end. Everything dims the picture while it's showing.
-- Icons come from the ModernZ icon font (fonts/modernz-icons.ttf); text is Segoe UI.

local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"

local opts = { next = false, accent = "F0A04B" }
options.read_options(opts, "ember_osc")

local ICON, FONT = "modernz-icons", "Segoe UI"
local ov = mp.create_osd_overlay("ass-events")
local W, H, S = 1920, 1080, 1
local visible, last_move = true, mp.get_time()
local panel, dragging, seek_hover = false, false, nil
local scroll = { audio = 0, sub = 0 }
local hits, out = {}, {}
local mx, my = -1, -1

local function bgr(hex) return hex:sub(5, 6) .. hex:sub(3, 4) .. hex:sub(1, 2) end
local ACCENT = bgr(opts.accent)

local function clean(s) return (tostring(s or ""):gsub("[{}]", ""):gsub("\\", "/"):gsub("\n", " ")) end
local function add(s) out[#out + 1] = s end

local function shape(path, c, a)
    add(string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c&H%s&\\1a&H%s&\\p1}%s{\\p0}", c, a or "00", path))
end

local function rrect(x, y, w, h, r, c, a)
    r = math.min(r or 0, w / 2, h / 2)
    if r <= 0 then
        return shape(string.format("m %.1f %.1f l %.1f %.1f l %.1f %.1f l %.1f %.1f", x, y, x + w, y, x + w, y + h, x, y + h), c, a)
    end
    local k = r * 0.5523
    shape(string.format(
        "m %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f " ..
        "l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f",
        x + r, y, x + w - r, y, x + w - r + k, y, x + w, y + r - k, x + w, y + r,
        x + w, y + h - r, x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h,
        x + r, y + h, x + r - k, y + h, x, y + h - r + k, x, y + h - r,
        x, y + r, x, y + r - k, x + r - k, y, x + r, y), c, a)
end

local function circle(cx, cy, r, c, a) rrect(cx - r, cy - r, 2 * r, 2 * r, r, c, a) end

local function text(x, y, an, size, str, opt)
    opt = opt or {}
    add(string.format("{\\an%d\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\b%d\\bord0\\shad%s\\4c&H000000&\\4a&H70&\\1c&H%s&\\1a&H%s&}%s",
        an, x, y, opt.font or FONT, size, opt.bold and 1 or 0, opt.shadow == false and "0" or "1",
        opt.c or "FFFFFF", opt.a or "00", clean(str)))
end

local function icon(x, y, size, name, c, a) text(x, y, 5, size, name, { font = ICON, c = c, a = a, shadow = false }) end

local function hit(x1, y1, x2, y2, fn) hits[#hits + 1] = { x1, y1, x2, y2, fn } end
local function over(x1, y1, x2, y2) return mx >= x1 and mx <= x2 and my >= y1 and my <= y2 end

local function fmt(t)
    t = math.max(0, math.floor(t or 0))
    local h, m, s = math.floor(t / 3600), math.floor(t / 60) % 60, t % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

-- "Silo  ·  S2 E6  ·  Barricades" -> "Silo", "S2:E6 Barricades"
local function titles()
    local t = mp.get_property("media-title") or ""
    local parts = {}
    for p in (t .. "  ·  "):gmatch("(.-)%s+·%s+") do parts[#parts + 1] = p end
    if #parts >= 2 then
        local ep = parts[2]:gsub("^S(%d+)%s*E(%d+)$", "S%1:E%2")
        return parts[1], ep .. (parts[3] and (" " .. parts[3]) or "")
    end
    return t, ""
end

local LANG = { eng = "English", en = "English", fre = "French", fra = "French", fr = "French", ger = "German", deu = "German",
    de = "German", spa = "Spanish", es = "Spanish", ita = "Italian", it = "Italian", por = "Portuguese", pt = "Portuguese",
    jpn = "Japanese", ja = "Japanese", kor = "Korean", ko = "Korean", chi = "Chinese", zho = "Chinese", zh = "Chinese",
    rus = "Russian", ru = "Russian", dut = "Dutch", nld = "Dutch", nl = "Dutch", swe = "Swedish", sv = "Swedish",
    nor = "Norwegian", nob = "Norwegian", no = "Norwegian", dan = "Danish", da = "Danish", fin = "Finnish", fi = "Finnish",
    pol = "Polish", pl = "Polish", tur = "Turkish", tr = "Turkish", ara = "Arabic", ar = "Arabic", hin = "Hindi",
    heb = "Hebrew", gre = "Greek", ell = "Greek", cze = "Czech", ces = "Czech", hun = "Hungarian", rum = "Romanian",
    ron = "Romanian", tha = "Thai", vie = "Vietnamese", ind = "Indonesian", may = "Malay", msa = "Malay", ukr = "Ukrainian",
    hrv = "Croatian", srp = "Serbian", slv = "Slovenian", slk = "Slovak", bul = "Bulgarian", est = "Estonian",
    lav = "Latvian", lit = "Lithuanian", ice = "Icelandic", isl = "Icelandic", tam = "Tamil", tel = "Telugu", fil = "Filipino" }
local CODEC = { eac3 = "Dolby Digital+", ac3 = "Dolby Digital", truehd = "Dolby TrueHD", dts = "DTS", ["dts-hd"] = "DTS-HD",
    aac = "AAC", opus = "Opus", flac = "FLAC", mp3 = "MP3" }

local function label(t)
    local name = LANG[(t.lang or ""):lower()] or (t.lang and t.lang:upper()) or ("Track " .. t.id)
    local extra = {}
    local title = t.title or ""
    if title:lower():find("sdh") or title:lower():find("hearing") then extra[#extra + 1] = "SDH"
    elseif t.forced or title:lower():find("forced") then extra[#extra + 1] = "Forced"
    elseif title ~= "" and not title:lower():find(name:lower(), 1, true) and #title < 22 then extra[#extra + 1] = title end
    if t.type == "audio" then
        local ch = t["demux-channel-count"]
        if CODEC[t.codec or ""] then extra[#extra + 1] = CODEC[t.codec] end
        if ch == 8 then extra[#extra + 1] = "7.1" elseif ch == 6 then extra[#extra + 1] = "5.1" elseif ch == 2 then extra[#extra + 1] = "Stereo" end
    end
    local s = name .. (#extra > 0 and ("  ·  " .. table.concat(extra, " · ")) or "")
    if #s > 40 then s = s:sub(1, 39) .. "…" end
    return s
end

local function tracks(kind)
    local list = {}
    for _, t in ipairs(mp.get_property_native("track-list") or {}) do
        if t.type == kind then list[#list + 1] = t end
    end
    return list
end

-- The Audio & Subtitles panel, on the right.
local function draw_panel()
    local pw, ph = 760 * S, math.min(H - 300 * S, 640 * S)
    local px, py = W - 100 * S - pw, 170 * S
    rrect(px, py, pw, ph, 22 * S, "141414", "18")
    hit(px, py, px + pw, py + ph, function() end) -- clicks inside don't close it
    local row, colw = 54 * S, pw / 2
    for ci, kind in ipairs({ "audio", "sub" }) do
        local x = px + (ci - 1) * colw + 34 * S
        text(x, py + 34 * S, 7, 30 * S, kind == "audio" and "Audio" or "Subtitles", { bold = true })
        local items = {}
        if kind == "sub" then items[1] = { id = "no", label = "Off", selected = not mp.get_property_native("sid") } end
        for _, t in ipairs(tracks(kind)) do items[#items + 1] = { id = t.id, label = label(t), selected = t.selected } end
        local top = py + 96 * S
        local fit = math.floor((py + ph - 24 * S - top) / row)
        scroll[kind] = math.max(0, math.min(scroll[kind], #items - fit))
        for i = 1, math.min(fit, #items - scroll[kind]) do
            local it = items[i + scroll[kind]]
            local y = top + (i - 1) * row
            local hov = over(x - 14 * S, y, x + colw - 40 * S, y + row)
            if hov then rrect(x - 14 * S, y + 4 * S, colw - 30 * S, row - 8 * S, 10 * S, "FFFFFF", "E6") end
            if it.selected then text(x + 6 * S, y + row / 2, 5, 28 * S, "✓", { c = ACCENT, bold = true, shadow = false }) end
            text(x + 34 * S, y + row / 2, 4, 25 * S, it.label,
                { bold = it.selected, c = it.selected and "FFFFFF" or "D8D8D8", shadow = false })
            hit(x - 14 * S, y, x + colw - 40 * S, y + row, function()
                mp.set_property(kind == "audio" and "aid" or "sid", tostring(it.id))
            end)
        end
        if #items > fit then
            text(x, py + ph - 14 * S, 1, 20 * S, string.format("Scroll for more  ·  %d", #items), { c = "9A9A9A", shadow = false })
        end
    end
end

-- Subtitles sit above the seek bar while the controls are showing, and drop back down when they hide.
local sub_base = mp.get_property_number("sub-pos", 100)
local subs_up = nil
local function lift_subs(up)
    if subs_up == up then return end
    subs_up = up
    mp.set_property_number("sub-pos", up and math.min(sub_base, 85) or sub_base)
end

local function render()
    local d = mp.get_property_native("osd-dimensions") or {}
    W, H = d.w or 0, d.h or 0
    if W < 50 or H < 50 then return end
    S = H / 1080
    out, hits = {}, {}
    ov.res_x, ov.res_y = W, H
    lift_subs(visible or panel)
    if not (visible or panel) then ov.data = ""; ov:update(); return end

    rrect(0, 0, W, H, 0, "000000", "78") -- dim the picture
    local paused = mp.get_property_native("pause")

    -- top left: back to Ember
    local cx, cy, r = 110 * S, 105 * S, 44 * S
    circle(cx, cy, r, "FFFFFF", over(cx - r, cy - r, cx + r, cy + r) and "B0" or "C8")
    icon(cx, cy, 40 * S, "window_close")
    hit(cx - r, cy - r, cx + r, cy + r, function() mp.commandv("quit") end)

    -- top right: audio and subtitles
    local cell, pill_h = 96 * S, 88 * S
    local px2, py = W - 100 * S, 61 * S
    rrect(px2 - 2 * cell, py, 2 * cell, pill_h, pill_h / 2, "FFFFFF", "C8")
    for i, name in ipairs({ "fluent_subtitles", "fluent_surround_sound" }) do
        local ix = px2 - 2 * cell + (i - 0.5) * cell
        local hov = over(ix - cell / 2, py, ix + cell / 2, py + pill_h)
        icon(ix, py + pill_h / 2, 44 * S, name, (panel or hov) and ACCENT or "FFFFFF")
        hit(ix - cell / 2, py, ix + cell / 2, py + pill_h, function() panel = not panel end)
    end

    -- middle: back 10, play/pause, forward 10
    local mxc, myc = W / 2, H / 2
    local gap = 250 * S
    local big, small = 150 * S, 92 * S
    for _, b in ipairs({
        { mxc - gap, small, "fluent_replay_10_filled", function() mp.commandv("seek", "-10", "relative", "exact") end },
        { mxc, big, paused and "fluent_play_arrow_filled" or "fluent_pause_filled", function() mp.commandv("cycle", "pause") end },
        { mxc + gap, small, "fluent_forward_10_filled", function() mp.commandv("seek", "10", "relative", "exact") end },
    }) do
        local x, size, name, fn = b[1], b[2], b[3], b[4]
        local hov = over(x - size / 2, myc - size / 2, x + size / 2, myc + size / 2)
        icon(x, myc, size * (hov and 1.06 or 1), name, hov and ACCENT or "FFFFFF")
        hit(x - size / 2, myc - size / 2, x + size / 2, myc + size / 2, fn)
    end

    -- bottom: episode line and title, next episode, seek bar
    local M = 140 * S
    local show, ep = titles()
    if ep ~= "" then text(M, H - 236 * S, 1, 30 * S, ep, { c = "E8E8E8" }) end
    text(M, H - 168 * S, 1, 50 * S, show, { bold = true })
    if opts.next then
        local nx, ny, ns = W - M - 30 * S, H - 196 * S, 66 * S
        local hov = over(nx - ns / 2, ny - ns / 2, nx + ns / 2, ny + ns / 2)
        icon(nx, ny, ns, "fluent_skip_next_filled", hov and ACCENT or "FFFFFF")
        hit(nx - ns / 2, ny - ns / 2, nx + ns / 2, ny + ns / 2, function() mp.commandv("quit", "5") end)
    end

    local pos, dur = mp.get_property_number("time-pos", 0), mp.get_property_number("duration", 0)
    local by = H - 104 * S
    local x1, x2 = M + 118 * S, W - M - 118 * S
    text(M, by, 4, 30 * S, fmt(pos), { c = "E8E8E8" })
    text(W - M, by, 6, 30 * S, fmt(dur), { c = "E8E8E8" })
    rrect(x1, by - 4 * S, x2 - x1, 8 * S, 4 * S, "FFFFFF", "B0")
    -- what's buffered ahead
    local cache = mp.get_property_native("demuxer-cache-state")
    if cache and cache["cache-end"] and dur > 0 then
        local ce = math.min(1, cache["cache-end"] / dur)
        local cp = math.min(1, pos / dur)
        if ce > cp then rrect(x1 + (x2 - x1) * cp, by - 4 * S, (x2 - x1) * (ce - cp), 8 * S, 4 * S, "FFFFFF", "90") end
    end
    local frac = dur > 0 and math.min(1, pos / dur) or 0
    rrect(x1, by - 4 * S, (x2 - x1) * frac, 8 * S, 4 * S, "FFFFFF", "00")
    local bar_hov = over(x1 - 10 * S, by - 30 * S, x2 + 10 * S, by + 30 * S)
    circle(x1 + (x2 - x1) * frac, by, (bar_hov or dragging) and 20 * S or 16 * S, "FFFFFF", "00")
    if (bar_hov or dragging) and dur > 0 then
        local f = math.max(0, math.min(1, (mx - x1) / (x2 - x1)))
        text(x1 + (x2 - x1) * f, by - 34 * S, 2, 26 * S, fmt(f * dur), { bold = true })
    end
    seek_hover = { x1 = x1, x2 = x2 }
    hit(x1 - 10 * S, by - 30 * S, x2 + 10 * S, by + 30 * S, function()
        dragging = true
        local f = math.max(0, math.min(1, (mx - x1) / (x2 - x1)))
        mp.commandv("seek", tostring(f * 100), "absolute-percent", "keyframes")
    end)

    if panel then draw_panel() end
    ov.data = table.concat(out, "\n")
    ov:update()
end

local function poke()
    last_move = mp.get_time()
    if not visible then visible = true end
    render()
end

mp.observe_property("mouse-pos", "native", function(_, p)
    if not p then return end
    local moved = p.x ~= mx or p.y ~= my
    mx, my = p.x, p.y
    if dragging and seek_hover then
        local dur = mp.get_property_number("duration", 0)
        if dur > 0 then
            local f = math.max(0, math.min(1, (mx - seek_hover.x1) / (seek_hover.x2 - seek_hover.x1)))
            mp.commandv("seek", tostring(f * 100), "absolute-percent", "keyframes")
        end
    end
    if moved then poke() end
end)

mp.add_forced_key_binding("MBTN_LEFT", "ember_osc_click", function(e)
    if e.event == "up" then
        if dragging then
            dragging = false
            if seek_hover then
                local f = math.max(0, math.min(1, (mx - seek_hover.x1) / (seek_hover.x2 - seek_hover.x1)))
                mp.commandv("seek", tostring(f * 100), "absolute-percent", "exact")
            end
            render()
        end
        return
    end
    if e.event ~= "down" and e.event ~= "press" then return end
    if not (visible or panel) then poke(); return end
    last_move = mp.get_time()
    for i = #hits, 1, -1 do
        local h = hits[i]
        if mx >= h[1] and mx <= h[3] and my >= h[2] and my <= h[4] then
            h[5]()
            render()
            return
        end
    end
    if panel then panel = false; render(); return end
    mp.commandv("cycle", "pause") -- a click anywhere else: pause / play
    render()
end, { complex = true })
mp.add_forced_key_binding("MBTN_LEFT_DBL", "ember_osc_dbl", function() end)

-- In the panel, the mouse wheel scrolls the list under it; elsewhere it does what mpv normally does.
local function wheel(dir)
    return function()
        if panel then
            local pw = 760 * S
            local px = W - 100 * S - pw
            scroll[(mx < px + pw / 2) and "audio" or "sub"] = scroll[(mx < px + pw / 2) and "audio" or "sub"] + dir
            render()
        else
            mp.commandv("seek", tostring(dir * -10), "relative")
        end
    end
end
mp.add_forced_key_binding("WHEEL_UP", "ember_osc_wup", wheel(-1))
mp.add_forced_key_binding("WHEEL_DOWN", "ember_osc_wdown", wheel(1))

-- Hide after 3 seconds without the mouse moving (never while paused, dragging or choosing tracks).
mp.add_periodic_timer(0.25, function()
    if visible and not panel and not dragging and not mp.get_property_native("pause")
        and mp.get_time() - last_move > 3 then
        visible = false
    end
    render()
end)
mp.observe_property("pause", "bool", function() poke() end)
mp.observe_property("osd-dimensions", "native", function() render() end)
mp.observe_property("track-list", "native", function() if panel then render() end end)

-- Esc closes the track panel first; otherwise ember.lua takes you back to Ember.
mp.add_forced_key_binding("ESC", "ember_osc_esc", function()
    if panel then panel = false; render() else mp.commandv("quit") end
end)

mp.register_script_message("ember-panel", function() panel = true; poke() end) -- for testing
msg.info("Ember controls loaded")
