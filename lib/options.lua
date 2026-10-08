-- Chompi's options.json, as norns params. Chompi reads the file when it
-- starts, as a real one reads it from its SD card, so a change takes effect
-- the next time the firmware starts (after restarting norns).

local options = {}

-- TAPE's options, in the file's order (OptionsManager.h).
local TAPE = {
  {name = "Record Latch", id = "record_latch", label = "record latch",
    kind = "bool", names = {"hold to record", "press start/stop"}, default = false},
  {name = "Midi In Channel", id = "midi_in_ch", label = "chompi midi in ch",
    kind = "int", min = 1, max = 16, default = 1},
  {name = "Midi Out Channel", id = "midi_out_ch", label = "chompi midi out ch",
    kind = "int", min = 1, max = 16, default = 1},
  {name = "Tape Slew On", id = "tape_slew", label = "tape slew",
    kind = "bool", names = {"off", "on"}, default = true},
  {name = "Monitor Position", id = "monitor", label = "monitor",
    kind = "int", names = {"headphones", "both", "send/return"}, min = 1, max = 3, default = 1},
  {name = "Pitch Quantize In Shift Menu", id = "pitch_quant", label = "quantised pitch",
    kind = "bool", names = {"normal page", "shift page"}, default = true},
  {name = "Split Delay", id = "split_delay", label = "split delay",
    kind = "bool", names = {"off", "on"}, default = false},
}

local file
local values = {}

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

local function write(path)
  local lines = {}
  for i, o in ipairs(TAPE) do
    local v = values[o.name]
    if v == nil then v = o.default end
    lines[i] = string.format('\t\t{\n\t\t\t"name": "%s",\n\t\t\t"value": %s\n\t\t}', o.name, tostring(v))
  end
  local f = io.open(path, "w")
  if not f then return end
  f:write('{\n\t"chompi": [\n' .. table.concat(lines, ",\n") .. '\n\t]\n}')
  f:close()
end

-- Adds the params, filled from the card's options.json.
function options.add_params(card)
  file = card .. "/options.json"
  values = read(file)
  params:add_separator("chompi_options", "chompi options (on restart)")
  for _, o in ipairs(TAPE) do
    local v = values[o.name]
    if v == nil then v = o.default end
    if o.kind == "bool" then
      params:add_option(o.id, o.label, o.names, v and 2 or 1)
      params:set_action(o.id, function(i)
        values[o.name] = i == 2
        write(file)
      end)
    elseif o.names then
      params:add_option(o.id, o.label, o.names, util.clamp(v, o.min, o.max))
      params:set_action(o.id, function(i)
        values[o.name] = i
        write(file)
      end)
    else
      params:add_number(o.id, o.label, o.min, o.max, util.clamp(v, o.min, o.max))
      params:set_action(o.id, function(i)
        values[o.name] = i
        write(file)
      end)
    end
  end
end

return options
