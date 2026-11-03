-- Ember: tells the Pi's progress store where you are, while you watch in mpv.
-- Options come from Ember as --script-opts=ember-feed=...,ember-imdb=...,ember-type=...,...
local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local o = { feed = "", imdb = "", type = "movie", season = "", episode = "", device = "Ember PC", key = "", title = "",
            room = "", who = "" }
require('mp.options').read_options(o, "ember")
if o.feed == "" or o.imdb == "" then
    msg.error("no Pi address or title given, so progress won't be saved (feed='" .. o.feed .. "', imdb='" .. o.imdb .. "')")
    return
end
msg.info("reporting " .. o.type .. " " .. o.imdb .. " to " .. o.feed)

local pos, dur, started, sent_end = nil, nil, false, false

local function post(state, sync, finished)
    if not pos then return end
    local body = utils.format_json({
        imdb = o.imdb, type = o.type, season = tonumber(o.season), episode = tonumber(o.episode),
        position = pos, duration = dur, device = o.device, state = state, finished = finished or false,
        episodeTitle = o.title,
    })
    local args = { "curl", "-s", "-m", "6", "-X", "POST", "-H", "Content-Type: application/json", "-d", body }
    if o.key ~= "" then
        table.insert(args, "-H"); table.insert(args, "X-Ember-Key: " .. o.key)
    end
    table.insert(args, o.feed .. "/progress/report")
    local cmd = { name = "subprocess", args = args, playback_only = false, capture_stdout = true, capture_stderr = true }
    local function done(ok, r)
        if r and r.status == 0 then
            msg.info(state .. " at " .. math.floor(pos) .. "s -> " .. (r.stdout or ""))
        else
            msg.error(state .. " report failed: status " .. tostring(r and r.status) .. " " .. tostring(r and r.error_string) .. " " .. tostring(r and r.stderr))
        end
    end
    if sync then done(true, mp.command_native(cmd)) else mp.command_native_async(cmd, done) end
end

-- Esc or Backspace: stop and go back to Ember (progress is saved as it stops).
mp.add_forced_key_binding("ESC", "ember-back", function() mp.command("quit") end)
mp.add_forced_key_binding("BS", "ember-back-bs", function() mp.command("quit") end)

mp.observe_property("time-pos", "number", function(_, v) if v then pos = v end end)
mp.observe_property("duration", "number", function(_, v) if v then dur = v end end)
mp.register_event("file-loaded", function() started = true end)
mp.observe_property("pause", "bool", function(_, p)
    if started and p ~= nil then post(p and "paused" or "playing") end
end)
mp.add_periodic_timer(15, function()
    if started and not mp.get_property_bool("pause") then post("playing") end
end)
-- Stalled: waiting on the network for more than 12 seconds. Save where you are and quit with code 4,
-- so Ember moves you to the next-best stream from the same point.
local stall_since = nil
mp.observe_property("paused-for-cache", "bool", function(_, waiting)
    if waiting then stall_since = stall_since or mp.get_time() else stall_since = nil end
end)
mp.add_periodic_timer(2, function()
    if stall_since and mp.get_time() - stall_since > 12 then
        msg.warn("stalled for " .. math.floor(mp.get_time() - stall_since) .. "s: asking Ember for another stream")
        sent_end = true
        post("stopped", true, false)
        mp.commandv("quit", "4")
    end
end)
-- Never got going at all (no picture after 25 seconds): same.
mp.add_timeout(25, function()
    if not pos or pos < 1 then
        if mp.get_property_bool("pause") then return end
        msg.warn("no playback after 25s: asking Ember for another stream")
        sent_end = true
        mp.commandv("quit", "4")
    end
end)

mp.register_event("end-file", function(e)
    if sent_end then return end
    sent_end = true
    post("stopped", true, e.reason == "eof")
end)

-- Watch together: share pause / play / seek with everyone in the same room (via the Pi).
if o.room ~= "" then
    local since, quiet_until = 0, 0
    local function send(action)
        if mp.get_time() < quiet_until then return end -- this change came from someone else
        local body = utils.format_json({ from = o.who, action = action, pos = pos or 0 })
        mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
            args = { "curl", "-s", "-m", "4", "-X", "POST", "-H", "Content-Type: application/json", "-d", body,
                     o.feed .. "/together/" .. o.room } }, function() end)
    end
    local function apply(ev)
        quiet_until = mp.get_time() + 1.5
        if ev.action == "pause" then
            mp.set_property_bool("pause", true)
            if ev.pos and math.abs((pos or 0) - ev.pos) > 2 then mp.commandv("seek", tostring(ev.pos), "absolute") end
            mp.osd_message("Paused by " .. ev.from, 2)
        elseif ev.action == "play" then
            if ev.pos and math.abs((pos or 0) - ev.pos) > 2 then mp.commandv("seek", tostring(ev.pos), "absolute") end
            mp.set_property_bool("pause", false)
            mp.osd_message("Playing (" .. ev.from .. ")", 2)
        elseif ev.action == "seek" then
            mp.commandv("seek", tostring(ev.pos), "absolute")
            mp.osd_message(ev.from .. " jumped to " .. math.floor(ev.pos / 60) .. ":" .. string.format("%02d", math.floor(ev.pos % 60)), 2)
        elseif ev.action == "hello" then
            mp.osd_message(ev.from .. " joined", 3)
        end
    end
    local loaded_at = 1e9
    mp.register_event("file-loaded", function() loaded_at = mp.get_time(); send("hello") end)
    mp.observe_property("pause", "bool", function(_, p)
        if started and p ~= nil then send(p and "pause" or "play") end
    end)
    local seeking_by_user = false
    mp.observe_property("seeking", "bool", function(_, s)
        if s then seeking_by_user = mp.get_time() >= quiet_until and mp.get_time() > loaded_at + 3
        elseif seeking_by_user then seeking_by_user = false; send("seek") end
    end)
    mp.add_periodic_timer(1, function()
        mp.command_native_async({ name = "subprocess", playback_only = false, capture_stdout = true,
            args = { "curl", "-s", "-m", "3", o.feed .. "/together/" .. o.room .. "?since=" .. since .. "&who=" .. o.who } },
            function(ok, r)
                if not (ok and r and r.status == 0 and r.stdout) then return end
                local j = utils.parse_json(r.stdout)
                if not j then return end
                if since == 0 then since = j.n; return end -- don't replay what happened before you joined
                since = j.n
                for _, ev in ipairs(j.events or {}) do apply(ev) end
            end)
    end)
    mp.register_event("shutdown", function() send("bye") end)
end
