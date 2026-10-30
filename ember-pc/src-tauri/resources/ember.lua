-- Ember: tells the Pi's progress store where you are, while you watch in mpv.
-- Options come from Ember as --script-opts=ember-feed=...,ember-imdb=...,ember-type=...,...
local mp = require 'mp'
local utils = require 'mp.utils'
local o = { feed = "", imdb = "", type = "movie", season = "", episode = "", device = "Ember PC", key = "", title = "" }
require('mp.options').read_options(o, "ember")
if o.feed == "" or o.imdb == "" then return end

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
    if sync then mp.command_native(cmd) else mp.command_native_async(cmd, function() end) end
end

mp.observe_property("time-pos", "number", function(_, v) if v then pos = v end end)
mp.observe_property("duration", "number", function(_, v) if v then dur = v end end)
mp.register_event("file-loaded", function() started = true end)
mp.observe_property("pause", "bool", function(_, p)
    if started and p ~= nil then post(p and "paused" or "playing") end
end)
mp.add_periodic_timer(15, function()
    if started and not mp.get_property_bool("pause") then post("playing") end
end)
mp.register_event("end-file", function(e)
    if sent_end then return end
    sent_end = true
    post("stopped", true, e.reason == "eof")
end)
