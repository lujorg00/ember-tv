-- Ember's player controls, laid out like Disney+:
--   ✕ top left (back to Ember), audio & subtitles top right,
--   ⟲10  ▶/❚❚  ⟳10 in the middle, episode + title bottom left, next episode bottom right,
--   a thin seek bar with the times at each end. Everything dims the picture while it's showing.
-- Icons are drawn as shapes; text is Segoe UI.

local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"

local opts = { next = false, accent = "F0A04B", statefile = "" }
options.read_options(opts, "ember_osc")

local ICON, FONT = "modernz-icons", "Segoe UI"
local ov = mp.create_osd_overlay("ass-events")
local W, H, S = 1920, 1080, 1
local visible, last_move = true, mp.get_time()
local panel = false
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

-- Icons are drawn as shapes (no icon font needed, so they can't go missing).
local function poly(pts, c, a, bord)
    local p = string.format("m %.1f %.1f", pts[1], pts[2])
    for i = 3, #pts, 2 do p = p .. string.format(" l %.1f %.1f", pts[i], pts[i + 1]) end
    add(string.format("{\\an7\\pos(0,0)\\bord%.1f\\shad0\\3c&H%s&\\3a&H%s&\\1c&H%s&\\1a&H%s&\\p1}%s{\\p0}",
        bord or 0, c, a or "00", c, a or "00", p))
end
-- a line through the points, t thick, with round ends
local function stroke(pts, t, c, a)
    local p = string.format("m %.1f %.1f", pts[1], pts[2])
    for i = 3, #pts, 2 do p = p .. string.format(" l %.1f %.1f", pts[i], pts[i + 1]) end
    for i = #pts - 3, 1, -2 do p = p .. string.format(" l %.1f %.1f", pts[i], pts[i + 1]) end
    add(string.format("{\\an7\\pos(0,0)\\bord%.1f\\shad0\\3c&H%s&\\3a&H%s&\\1a&HFF&\\p1}%s{\\p0}", t / 2, c, a or "00", p))
end
local function rrect_line(x, y, w, h, r, t, c)
    local k = r * 0.5523
    add(string.format("{\\an7\\pos(0,0)\\bord%.1f\\shad0\\3c&H%s&\\1a&HFF&\\p1}" ..
        "m %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f " ..
        "l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f l %.1f %.1f b %.1f %.1f %.1f %.1f %.1f %.1f{\\p0}", t / 2, c,
        x + r, y, x + w - r, y, x + w - r + k, y, x + w, y + r - k, x + w, y + r,
        x + w, y + h - r, x + w, y + h - r + k, x + w - r + k, y + h, x + w - r, y + h,
        x + r, y + h, x + r - k, y + h, x, y + h - r + k, x, y + h - r,
        x, y + r, x, y + r - k, x + r - k, y, x + r, y))
end
-- the circular arrow round "10": dir -1 = back, 1 = forward
local function jump_icon(cx, cy, s, dir, c)
    local r, t = 0.34 * s, 0.075 * s
    local pts = {}
    for d = -80, 200, 10 do
        local th = math.rad(d)
        pts[#pts + 1] = cx + r * math.cos(th)
        pts[#pts + 1] = cy + r * math.sin(th)
    end
    -- mirror for "forward" so the gap and arrow sit top right
    if dir > 0 then for i = 1, #pts, 2 do pts[i] = 2 * cx - pts[i] end end
    stroke(pts, t, c)
    local th = math.rad(-80)
    local px, py = cx + r * math.cos(th), cy + r * math.sin(th)
    local tx, ty = math.sin(th), -math.cos(th) -- along the circle, backwards
    local nx, ny = math.cos(th), math.sin(th)  -- out from the centre
    local tip = { px + tx * 0.17 * s, py + ty * 0.17 * s }
    local a1 = { px + nx * 0.13 * s, py + ny * 0.13 * s }
    local a2 = { px - nx * 0.13 * s, py - ny * 0.13 * s }
    local tri = { tip[1], tip[2], a1[1], a1[2], a2[1], a2[2] }
    if dir > 0 then for i = 1, #tri, 2 do tri[i] = 2 * cx - tri[i] end end
    poly(tri, c, "00", 0.02 * s)
    text(cx, cy + 0.03 * s, 5, 0.42 * s, "10", { bold = true, c = c, shadow = false })
end

local function icon(x, y, size, name, c, a)
    c = c or "FFFFFF"
    local s = size
    if name == "close" then
        local d = 0.26 * s
        stroke({ x - d, y - d, x + d, y + d }, 0.075 * s, c, a)
        stroke({ x - d, y + d, x + d, y - d }, 0.075 * s, c, a)
    elseif name == "play" then
        poly({ x - 0.26 * s, y - 0.36 * s, x + 0.38 * s, y, x - 0.26 * s, y + 0.36 * s }, c, a, 0.04 * s)
    elseif name == "pause" then
        rrect(x - 0.30 * s, y - 0.36 * s, 0.22 * s, 0.72 * s, 0.05 * s, c, a)
        rrect(x + 0.08 * s, y - 0.36 * s, 0.22 * s, 0.72 * s, 0.05 * s, c, a)
    elseif name == "next" then
        poly({ x - 0.30 * s, y - 0.30 * s, x + 0.16 * s, y, x - 0.30 * s, y + 0.30 * s }, c, a, 0.03 * s)
        rrect(x + 0.19 * s, y - 0.30 * s, 0.09 * s, 0.60 * s, 0.03 * s, c, a)
    elseif name == "back10" then jump_icon(x, y, s, -1, c)
    elseif name == "fwd10" then jump_icon(x, y, s, 1, c)
    elseif name == "subtitles" then
        rrect_line(x - 0.40 * s, y - 0.28 * s, 0.80 * s, 0.56 * s, 0.10 * s, 0.06 * s, c)
        stroke({ x - 0.24 * s, y + 0.08 * s, x + 0.24 * s, y + 0.08 * s }, 0.06 * s, c)
        stroke({ x - 0.24 * s, y - 0.07 * s, x + 0.04 * s, y - 0.07 * s }, 0.06 * s, c)
    elseif name == "audio" then
        local hs = { 0.18, 0.36, 0.52, 0.36, 0.18 }
        for i, h in ipairs(hs) do
            local bx = x + (i - 3) * 0.16 * s
            stroke({ bx, y - h * s / 2, bx, y + h * s / 2 }, 0.07 * s, c)
        end
    elseif name == "back" then
        stroke({ x + 0.32 * s, y, x - 0.30 * s, y }, 0.08 * s, c)
        stroke({ x - 0.06 * s, y - 0.26 * s, x - 0.32 * s, y, x - 0.06 * s, y + 0.26 * s }, 0.08 * s, c)
    elseif name == "volume" or name == "muted" then
        poly({ x - 0.40 * s, y - 0.13 * s, x - 0.22 * s, y - 0.13 * s, x + 0.0 * s, y - 0.34 * s,
            x + 0.0 * s, y + 0.34 * s, x - 0.22 * s, y + 0.13 * s, x - 0.40 * s, y + 0.13 * s }, c, a, 0.02 * s)
        if name == "muted" then
            stroke({ x + 0.12 * s, y - 0.14 * s, x + 0.40 * s, y + 0.14 * s }, 0.07 * s, c)
            stroke({ x + 0.12 * s, y + 0.14 * s, x + 0.40 * s, y - 0.14 * s }, 0.07 * s, c)
        else
            for _, rr in ipairs({ 0.17, 0.33 }) do
                local pts = {}
                for dg = -50, 50, 10 do
                    local th = math.rad(dg)
                    pts[#pts + 1] = x + 0.04 * s + rr * s * math.cos(th)
                    pts[#pts + 1] = y + rr * s * math.sin(th)
                end
                stroke(pts, 0.065 * s, c)
            end
        end
    elseif name == "check" then
        stroke({ x - 0.30 * s, y, x - 0.08 * s, y + 0.22 * s, x + 0.32 * s, y - 0.22 * s }, 0.11 * s, c)
    end
end

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

-- Subtitle size: chosen in the panel, remembered between plays (in Ember's own folder).
local SUB_SIZES = { { "S", 0.6 }, { "M", 0.75 }, { "L", 0.9 } }
local SUB_DEFAULT = 0.75
local function load_sub_size()
    local v
    local f = opts.statefile ~= "" and io.open(opts.statefile, "r")
    if f then v = tonumber((f:read("*l") or "")); f:close() end
    -- not one of the sizes (nothing saved yet, or an old one): use the nearest, Medium if none
    local best, bd = SUB_DEFAULT, math.huge
    if v then for _, z in ipairs(SUB_SIZES) do if math.abs(z[2] - v) < bd then best, bd = z[2], math.abs(z[2] - v) end end end
    mp.set_property_number("sub-scale", best)
end
local function save_sub_size(v)
    mp.set_property_number("sub-scale", v)
    if opts.statefile == "" then return end
    local f = io.open(opts.statefile, "w")
    if f then f:write(tostring(v)); f:close() end
end
load_sub_size()

-- The Audio & Subtitles panel: opens above the controls, bottom right.
local function panel_box()
    local n = math.max(#tracks("audio"), #tracks("sub") + 1)
    local pw, ph = 540 * S, math.min(H - 300 * S, 500 * S, (58 + 38 * n + 36 + 70) * S)
    return W - 40 * S - pw, H - 128 * S - ph, pw, ph
end
local function draw_panel()
    local px, py, pw, ph = panel_box()
    rrect(px, py, pw, ph, 14 * S, "161616", "1A")
    hit(px, py, px + pw, py + ph, function() end) -- clicks inside don't close it
    local row, colw = 38 * S, pw / 2
    for ci, kind in ipairs({ "audio", "sub" }) do
        local x = px + (ci - 1) * colw + 22 * S
        text(x, py + 20 * S, 7, 19 * S, kind == "audio" and "Audio" or "Subtitles", { bold = true, shadow = false })
        local items = {}
        if kind == "sub" then items[1] = { id = "no", label = "Off", selected = not mp.get_property_native("sid") } end
        for _, t in ipairs(tracks(kind)) do items[#items + 1] = { id = t.id, label = label(t), selected = t.selected } end
        local top = py + 58 * S
        local fit = math.floor((py + ph - 100 * S - top) / row)
        scroll[kind] = math.max(0, math.min(scroll[kind], #items - fit))
        for k = 1, math.min(fit, #items - scroll[kind]) do
            local it = items[k + scroll[kind]]
            local y = top + (k - 1) * row
            local hov = over(x - 10 * S, y, x + colw - 30 * S, y + row)
            if hov then rrect(x - 10 * S, y + 3 * S, colw - 22 * S, row - 6 * S, 7 * S, "FFFFFF", "E6") end
            if it.selected then icon(x + 4 * S, y + row / 2, 17 * S, "check", ACCENT) end
            text(x + 22 * S, y + row / 2, 4, 16 * S, it.label,
                { bold = it.selected, c = it.selected and "FFFFFF" or "D0D0D0", shadow = false })
            hit(x - 10 * S, y, x + colw - 30 * S, y + row, function()
                mp.set_property(kind == "audio" and "aid" or "sid", tostring(it.id))
            end)
        end
        if #items > fit then
            text(x, py + ph - 82 * S, 1, 14 * S, string.format("Scroll for more  ·  %d", #items), { c = "8A8A8A", shadow = false })
        end
    end
    -- Text size, along the bottom of the Subtitles side
    local sx = px + colw + 22 * S
    local sy = py + ph - 44 * S
    rrect(px + 18 * S, sy - 30 * S, pw - 36 * S, 1 * S, 0, "FFFFFF", "D0")
    text(sx, sy, 4, 15 * S, "Text size", { c = "B0B0B0", shadow = false })
    local cur = mp.get_property_number("sub-scale", 1)
    local bx = sx + 78 * S
    for _, z in ipairs(SUB_SIZES) do
        local w = 36 * S
        local on = math.abs(cur - z[2]) < 0.01
        local hov = over(bx, sy - 15 * S, bx + w, sy + 15 * S)
        rrect(bx, sy - 15 * S, w, 30 * S, 8 * S, on and ACCENT or "FFFFFF", on and "00" or (hov and "C8" or "E4"))
        text(bx + w / 2, sy, 5, 14 * S, z[1], { bold = true, c = on and "1A0F08" or "FFFFFF", shadow = false })
        hit(bx, sy - 15 * S, bx + w, sy + 15 * S, function() save_sub_size(z[2]) end)
        bx = bx + w + 6 * S
    end
end

-- Subtitles sit above the controls while they're showing, and drop back down when they hide.
local sub_base = mp.get_property_number("sub-pos", 100)
local subs_up = nil
local function lift_subs(up)
    if subs_up == up then return end
    subs_up = up
    mp.set_property_number("sub-pos", up and math.min(sub_base, 88) or sub_base)
end

-- A soft fade (top or bottom) so the controls read without dimming the whole picture.
local function fade(y1, y2, a1, a2)
    local steps = 32
    for k = 0, steps - 1 do
        local f = (k + 0.5) / steps
        local a = math.floor(a1 + (a2 - a1) * f)
        rrect(0, y1 + (y2 - y1) * k / steps, W, (y2 - y1) / steps + 1, 0, "000000", string.format("%02X", a))
    end
end

local drag = nil -- "seek" or "volume" while the mouse button is held on one
local bars = {}

local function set_from_mouse(final)
    if drag == "seek" and bars.seek then
        local b = bars.seek
        local f = math.max(0, math.min(1, (mx - b.x1) / (b.x2 - b.x1)))
        mp.commandv("seek", tostring(f * 100), "absolute-percent", final and "exact" or "keyframes")
    elseif drag == "volume" and bars.vol then
        local b = bars.vol
        local f = math.max(0, math.min(1, (mx - b.x1) / (b.x2 - b.x1)))
        mp.set_property_number("volume", math.floor(f * 100 + 0.5))
        if f > 0 then mp.set_property_bool("mute", false) end
    end
end

local function button(x, y, size, name, fn, active)
    local h2 = size * 0.75
    local hov = over(x - h2, y - h2, x + h2, y + h2)
    if hov then circle(x, y, h2, "FFFFFF", "E0") end
    icon(x, y, size, name, (hov or active) and ACCENT or "FFFFFF")
    hit(x - h2, y - h2, x + h2, y + h2, fn)
end

local function render()
    local d = mp.get_property_native("osd-dimensions") or {}
    W, H = d.w or 0, d.h or 0
    if W < 50 or H < 50 then return end
    S = math.max(0.6, H / 1080)
    out, hits = {}, {}
    ov.res_x, ov.res_y = W, H
    lift_subs(visible or panel)
    if not (visible or panel) then ov.data = ""; ov:update(); return end

    fade(0, 130 * S, 0x70, 0xFF)
    fade(H - 210 * S, H, 0xFF, 0x48)
    local paused = mp.get_property_native("pause")
    local M = 40 * S

    -- top left: back to Ember
    button(M + 18 * S, 46 * S, 30 * S, "back", function() mp.commandv("quit") end)

    -- seek bar, with the time left at its right
    local pos, dur = mp.get_property_number("time-pos", 0), mp.get_property_number("duration", 0)
    local by = H - 96 * S
    local x1, x2 = M + 6 * S, W - M - 92 * S
    text(W - M, by, 6, 18 * S, dur > 0 and ("-" .. fmt(dur - pos)) or fmt(pos), { c = "E0E0E0" })
    rrect(x1, by - 2.5 * S, x2 - x1, 5 * S, 2.5 * S, "FFFFFF", "B8")
    local cache = mp.get_property_native("demuxer-cache-state")
    if cache and cache["cache-end"] and dur > 0 then
        local ce, cp = math.min(1, cache["cache-end"] / dur), math.min(1, pos / dur)
        if ce > cp then rrect(x1 + (x2 - x1) * cp, by - 2.5 * S, (x2 - x1) * (ce - cp), 5 * S, 2.5 * S, "FFFFFF", "98") end
    end
    local frac = dur > 0 and math.min(1, pos / dur) or 0
    rrect(x1, by - 2.5 * S, (x2 - x1) * frac, 5 * S, 2.5 * S, ACCENT, "00")
    local bar_hov = over(x1 - 6 * S, by - 14 * S, x2 + 6 * S, by + 14 * S)
    circle(x1 + (x2 - x1) * frac, by, (bar_hov or drag == "seek") and 9 * S or 7 * S, "FFFFFF", "00")
    if (bar_hov or drag == "seek") and dur > 0 then
        local f = math.max(0, math.min(1, (mx - x1) / (x2 - x1)))
        local tx = math.max(x1 + 30 * S, math.min(x2 - 30 * S, x1 + (x2 - x1) * f))
        rrect(tx - 34 * S, by - 46 * S, 68 * S, 26 * S, 6 * S, "000000", "40")
        text(tx, by - 33 * S, 5, 16 * S, fmt(f * dur), { bold = true, shadow = false })
    end
    bars.seek = { x1 = x1, x2 = x2 }
    hit(x1 - 6 * S, by - 14 * S, x2 + 6 * S, by + 14 * S, function() drag = "seek"; set_from_mouse(false) end)

    -- controls row
    local ry = H - 46 * S
    local x = M + 18 * S
    button(x, ry, 30 * S, paused and "play" or "pause", function() mp.commandv("cycle", "pause") end)
    x = x + 56 * S
    button(x, ry, 34 * S, "back10", function() mp.commandv("seek", "-10", "relative", "exact") end)
    x = x + 52 * S
    button(x, ry, 34 * S, "fwd10", function() mp.commandv("seek", "10", "relative", "exact") end)
    x = x + 54 * S
    local muted = mp.get_property_native("mute")
    local vol = mp.get_property_number("volume", 100)
    button(x, ry, 28 * S, (muted or vol == 0) and "muted" or "volume", function() mp.commandv("cycle", "mute") end)
    local vx1, vx2 = x + 26 * S, x + 116 * S
    rrect(vx1, ry - 2 * S, vx2 - vx1, 4 * S, 2 * S, "FFFFFF", "B8")
    local vf = muted and 0 or math.min(1, vol / 100)
    rrect(vx1, ry - 2 * S, (vx2 - vx1) * vf, 4 * S, 2 * S, "FFFFFF", "00")
    if over(vx1 - 6 * S, ry - 14 * S, vx2 + 6 * S, ry + 14 * S) or drag == "volume" then
        circle(vx1 + (vx2 - vx1) * vf, ry, 6 * S, "FFFFFF", "00")
    end
    bars.vol = { x1 = vx1, x2 = vx2 }
    hit(vx1 - 6 * S, ry - 14 * S, vx2 + 6 * S, ry + 14 * S, function() drag = "volume"; set_from_mouse(false) end)

    -- middle of the row: the title
    local show, ep = titles()
    add(string.format("{\\an5\\pos(%.1f,%.1f)\\fn%s\\fs%.1f\\bord0\\shad1\\4c&H000000&\\4a&H70&\\1c&HFFFFFF&\\b1}%s%s",
        W / 2, ry, FONT, 20 * S, clean(show),
        ep ~= "" and string.format("{\\b0\\1c&HB8B8B8&}   %s", clean(ep)) or ""))

    -- right: next episode, audio & subtitles
    local rx = W - M - 16 * S
    button(rx, ry, 30 * S, "subtitles", function() panel = not panel end, panel)
    if opts.next then
        button(rx - 58 * S, ry, 28 * S, "next", function() mp.commandv("quit", "5") end)
    end

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
    if drag then set_from_mouse(false) end
    if moved then poke() end
end)

mp.add_forced_key_binding("MBTN_LEFT", "ember_osc_click", function(e)
    if e.event == "up" then
        if drag then set_from_mouse(true); drag = nil; render() end
        return
    end
    if e.event ~= "down" and e.event ~= "press" then return end
    if not (visible or panel) then poke(); return end
    last_move = mp.get_time()
    for k = #hits, 1, -1 do
        local h = hits[k]
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

-- Mouse wheel: in the panel it scrolls the list under it; elsewhere it's volume.
local function wheel(dir)
    return function()
        if panel then
            local px, _, pw = panel_box()
            local k = (mx < px + pw / 2) and "audio" or "sub"
            scroll[k] = scroll[k] + dir
            render()
        else
            mp.commandv("add", "volume", tostring(-dir * 5))
            poke()
        end
    end
end
mp.add_forced_key_binding("WHEEL_UP", "ember_osc_wup", wheel(-1))
mp.add_forced_key_binding("WHEEL_DOWN", "ember_osc_wdown", wheel(1))

-- Hide after 3 seconds without the mouse moving (never while paused, dragging or choosing tracks).
mp.add_periodic_timer(0.25, function()
    if visible and not panel and not drag and not mp.get_property_native("pause")
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
