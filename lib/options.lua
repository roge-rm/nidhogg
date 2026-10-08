-- Each firmware's options.json, as norns params. Chompi reads the file when it
-- starts, as a real one reads it from its SD card, so a change takes effect
-- the next time that firmware starts (after restarting norns).

local options = {}

local function bool(name, id, label, names, default)
  return {name = name, id = id, label = label, kind = "bool", names = names, default = default}
end
local function channel(name, id, label, default)
  return {name = name, id = id, label = label, kind = "int", min = 1, max = 16, default = default}
end
local ONOFF = {"off", "on"}
local MONITOR = {name = "Monitor Position", id = "monitor", label = "monitor", kind = "int",
  names = {"headphones", "both", "send/return"}, min = 1, max = 3, default = 1}

-- In each firmware's file order (its OptionsManager.h).
local LISTS = {
  tape = {
    bool("Record Latch", "record_latch", "record latch", {"hold to record", "press start/stop"}, false),
    channel("Midi In Channel", "midi_in_ch", "midi in ch", 1),
    channel("Midi Out Channel", "midi_out_ch", "midi out ch", 1),
    bool("Tape Slew On", "tape_slew", "tape slew", ONOFF, true),
    MONITOR,
    bool("Pitch Quantize In Shift Menu", "pitch_quant", "quantised pitch", {"normal page", "shift page"}, true),
    bool("Split Delay", "split_delay", "split delay", ONOFF, false),
  },
  tempo = {
    bool("Record Latch", "record_latch", "record latch", {"hold to record", "press start/stop"}, false),
    channel("Midi In Channel", "midi_in_ch", "midi in ch", 1),
    channel("Midi Out Channel Chromatic", "midi_out_chroma", "midi out ch chromatic", 1),
    channel("Midi Out Channel Slice", "midi_out_slice", "midi out ch slice", 2),
    bool("MIDI Clock Out", "clock_out", "midi clock out", ONOFF, true),
    MONITOR,
    bool("Pitch Quantize In Shift Menu", "pitch_quant", "quantised pitch", {"normal page", "shift page"}, true),
    bool("MIDI CC In", "cc_in", "midi cc in", ONOFF, true),
    bool("MIDI CC Out", "cc_out", "midi cc out", ONOFF, true),
    {name = "Midi Start-Stop Message Behavior", id = "start_stop", label = "midi start/stop",
      kind = "int", names = {"send + receive", "send", "receive", "neither"}, min = 1, max = 4, default = 1},
    bool("Delay Buffer Unfreeze Mute", "unfreeze_mute", "mute on unfreeze", ONOFF, false),
  },
  wave = {
    channel("Midi In Channel", "midi_in_ch", "midi in ch", 1),
    channel("Midi Out Channel", "midi_out_ch", "midi out ch", 1),
    bool("MIDI Clock Out", "clock_out", "midi clock out", ONOFF, true),
    bool("MIDI CC In", "cc_in", "midi cc in", ONOFF, true),
    bool("MIDI CC Out", "cc_out", "midi cc out", ONOFF, true),
  },
}

local function read(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local text = f:read("a")
  f:close()
  local out = {}
  for name, value in text:gmatch('"name"%s*:%s*"([^"]+)"%s*,%s*"value"%s*:%s*([%w%.]+)') do
    if value == "true" then out[name] = true
    elseif value == "false" then out[name] = false
    else out[name] = tonumber(value) end
  end
  return out
end

local function write(path, list, values)
  local lines = {}
  for i, o in ipairs(list) do
    local v = values[o.name]
    if v == nil then v = o.default end
    lines[i] = string.format('\t\t{\n\t\t\t"name": "%s",\n\t\t\t"value": %s\n\t\t}', o.name, tostring(v))
  end
  local f = io.open(path, "w")
  if not f then return end
  f:write('{\n\t"chompi": [\n' .. table.concat(lines, ",\n") .. '\n\t]\n}')
  f:close()
end

-- Adds a group of params for one firmware, filled from its card's options.json.
function options.add_params(fw, card)
  local list = LISTS[fw]
  local file = card .. "/options.json"
  local values = read(file)
  local function save() write(file, list, values) end
  params:add_group(fw .. "_options", fw .. " options (on restart)", #list)
  for _, o in ipairs(list) do
    local id = fw .. "_" .. o.id
    local v = values[o.name]
    if v == nil then v = o.default end
    if o.kind == "bool" then
      params:add_option(id, o.label, o.names, v and 2 or 1)
      params:set_action(id, function(i) values[o.name] = i == 2; save() end)
    elseif o.names then
      params:add_option(id, o.label, o.names, util.clamp(v, o.min, o.max))
      params:set_action(id, function(i) values[o.name] = i; save() end)
    else
      params:add_number(id, o.label, o.min, o.max, util.clamp(v, o.min, o.max))
      params:set_action(id, function(i) values[o.name] = i; save() end)
    end
  end
end

return options
