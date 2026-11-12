-- Ember: tells the Pi's progress store where you are, while you watch in mpv.
-- Options come from Ember as --script-opts=ember-feed=...,ember-imdb=...,ember-type=...,...
local mp = require 'mp'
local utils = require 'mp.utils'
local msg = require 'mp.msg'
local o = { feed = "", imdb = "", type = "movie", season = "", episode = "", device = "Ember PC", key = "", title = "",
            together = "", who = "", show = "" }
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
-- (Esc is handled by ember_osc.lua: it closes the track panel first.)
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


-- Watch together (ember-together=host: start a room once the stream's playing; =CODE: join that room).
-- Pause / play / seek go to everyone in the room through lucapi; the host says where it is every 5 s, and
-- anyone more than 2 s off jumps back in line.
if o.together ~= "" and o.who ~= "" then
    local room = o.together ~= "host" and o.together or nil
    local since, quiet_until, made = nil, 0, false
    local ready_at = math.huge -- nothing goes to the room until you've been in it a few seconds (start-up seeks aren't yours)
    local function curl(method, path, body, cb)
        local args = { "curl", "-s", "-m", "4" }
        if method == "POST" then
            for _, a in ipairs({ "-X", "POST", "-H", "Content-Type: application/json", "-d", utils.format_json(body) }) do table.insert(args, a) end
        end
        if o.key ~= "" then table.insert(args, "-H"); table.insert(args, "X-Ember-Key: " .. o.key) end
        table.insert(args, o.feed .. path)
        mp.command_native_async({ name = "subprocess", args = args, playback_only = false, capture_stdout = true },
            function(ok, r)
                if cb then cb(ok and r and r.status == 0 and r.stdout and utils.parse_json(r.stdout) or nil) end
            end)
    end
    local function send(action)
        if not room or mp.get_time() < quiet_until or mp.get_time() < ready_at then return end -- (from someone else, or start-up)
        curl("POST", "/together/" .. room, { who = o.who, name = o.device, action = action, pos = pos or 0 })
    end
    local function quiet() quiet_until = mp.get_time() + 1.5 end
    local function clock(t) return string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60)) end
    local function apply(ev)
        quiet()
        local far = ev.pos and math.abs((pos or 0) - ev.pos) > 2
        if ev.action == "pause" then
            mp.set_property_bool("pause", true)
            if far then mp.commandv("seek", tostring(ev.pos), "absolute", "exact") end
            mp.osd_message("Paused by " .. ev.name, 2)
        elseif ev.action == "play" then
            if far then mp.commandv("seek", tostring(ev.pos), "absolute", "exact") end
            mp.set_property_bool("pause", false)
            mp.osd_message("Playing (" .. ev.name .. ")", 2)
        elseif ev.action == "seek" then
            mp.commandv("seek", tostring(ev.pos), "absolute", "exact")
            mp.osd_message(ev.name .. " jumped to " .. clock(ev.pos), 2)
        elseif ev.action == "hello" then
            mp.osd_message(ev.name .. " joined", 3)
        elseif ev.action == "bye" then
            mp.osd_message(ev.name .. " left", 3)
        end
    end
    -- the room: made by the host once its stream is really playing (so the others get a link that works)
    mp.add_periodic_timer(1, function()
        if not room then
            if made or not pos or pos < 1 then return end
            made = true
            local meta = { id = o.imdb, type = o.type, name = o.show, season = tonumber(o.season),
                           episode = tonumber(o.episode), epTitle = o.title }
            curl("POST", "/together/start", { who = o.who, name = o.device, url = mp.get_property("path"), pos = pos,
                paused = mp.get_property_bool("pause"), meta = meta }, function(j)
                if j and j.code then
                    room = j.code
                    mp.osd_message("Watching together: your other Ember devices are being asked to join", 4)
                else
                    mp.osd_message("Couldn't start watching together (lucapi didn't answer)", 4)
                end
            end)
            return
        end
        if since == nil then
            since = -1
            curl("POST", "/together/" .. room, { who = o.who, name = o.device, action = "hello", pos = pos or 0 })
            ready_at = mp.get_time() + 3
        end
        curl("GET", "/together/" .. room .. "?since=" .. math.max(since, 0) .. "&who=" .. o.who, nil, function(j)
            if not j or j.gone then return end
            if since == -1 then since = j.n -- don't replay what happened before you joined
            else
                since = j.n
                for _, ev in ipairs(j.events or {}) do apply(ev) end
            end
            -- in step with the host: same pause state, and no more than 2 s apart
            if not j.you_host and mp.get_time() >= quiet_until and pos then
                if j.paused ~= mp.get_property_bool("pause") then quiet(); mp.set_property_bool("pause", j.paused) end
                if math.abs(pos - j.expect) > 2 then
                    quiet()
                    mp.commandv("seek", tostring(j.expect + 0.3), "absolute", "exact")
                end
            end
            if j.you_host and not mp.get_property_bool("pause") then
                curl("POST", "/together/" .. room, { who = o.who, name = o.device, action = "tick", pos = pos or 0 })
            end
        end)
    end)
    mp.observe_property("pause", "bool", function(_, p)
        if started and p ~= nil then send(p and "pause" or "play") end
    end)
    -- a seek made here (not one that came from the room): the others follow
    mp.register_event("seek", function()
        if mp.get_time() >= quiet_until then mp.add_timeout(0.3, function() send("seek") end) end
    end)
    mp.register_event("shutdown", function()
        if room then curl("POST", "/together/" .. room, { who = o.who, name = o.device, action = "bye", pos = pos or 0 }) end
    end)
end

-- Safety net: if the ModernZ controls didn't load, switch on mpv's own controls so you're never left without any.
mp.add_timeout(3, function()
    local ok = false
    for _, b in ipairs(mp.get_property_native("input-bindings") or {}) do
        if b.owner and tostring(b.owner):lower():find("ember_osc") then ok = true; break end
    end
    if not ok then
        msg.warn("Ember controls not found: falling back to mpv's standard controls")
        mp.set_property_bool("osc", true)
    else
        msg.info("Ember controls loaded (checked)")
    end
end)
