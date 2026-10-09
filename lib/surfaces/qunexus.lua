-- The Keith McMillen QuNexus, as a surface. Its 25 keys are CHOMPI's, C3 to
-- C5 (MIDI 48-72 at its default octave).
--   playing    keys go to CHOMPI as MIDI notes, so velocity counts (TAPE and
--              WAVE); pressure, if the QuNexus sends it, goes to the knob
--              chosen in "pressure to"
--   shift      rock a held key hard upwards (its pitch bend past 3/4 up):
--              its note stops and that key holds CHOMPI's shift until let go
--              of. Playing rocks keys downwards a lot but seldom up past a
--              third, so this doesn't happen by accident.
--   shift menu while it's open the keys press CHOMPI's own keys, as the menu
--              takes no MIDI notes: slots on the white keys, the shift jobs
--              on the black ones.
-- Its keys light from notes sent back on channel 1, velocity setting the
-- brightness, so each key shows CHOMPI's light for it as a brightness.

local surf = {name = "QuNexus"}
surf.actions = nil -- set by lib/surfaces.lua

local LOW = 48 -- the note of its lowest key, at its default octave

local dev
local sent = {}    -- key -> brightness last sent
local held = {}    -- note -> "midi" or "key", how it was pressed
local menu_open = false
local SHIFT_BEND = 6000  -- pitch bend above the middle (8192) that is shift
local last_note = nil    -- the key pressed most recently, still held
local shift_note = nil  -- the key holding shift

function surf.match(name)
  if name == nil then return false end
  name = name:lower()
  -- the keys are on the first of its three ports
  return name:find("qunexus") ~= nil and name:find("[23]$") == nil
end

function surf.connected() return dev ~= nil end

local function on_midi(data)
  local a = surf.actions
  local status, d1, d2 = data[1] or 0, data[2] or 0, data[3] or 0
  local kind = status & 0xF0
  if kind == 0x90 or kind == 0x80 then
    local on = kind == 0x90 and d2 > 0
    local k = d1 - LOW
    if on then
      a.touch()
      last_note = d1
      if menu_open and k >= 0 and k <= 24 then
        held[d1] = "key"
        a.key(k, 1)
      else
        held[d1] = "midi"
        a.midi({0x90, d1, d2})
      end
    else
      local how = held[d1]
      held[d1] = nil
      if last_note == d1 then last_note = nil end
      if shift_note == d1 then
        shift_note = nil
        a.shift(0)
      elseif how == "key" then a.key(k, 0)
      elseif how == "midi" then a.midi({0x80, d1, 0}) end
    end
  elseif kind == 0xE0 then
    -- a held key rocked hard upwards becomes shift
    local bend = (d1 | (d2 << 7)) - 8192
    if bend > SHIFT_BEND and last_note and not shift_note then
      local n = last_note
      if held[n] == "midi" then a.midi({0x80, n, 0}) elseif held[n] == "key" then a.key(n - LOW, 0) end
      held[n] = "shift"
      shift_note = n
      a.touch()
      a.shift(1)
    end
  elseif kind == 0xA0 or kind == 0xD0 then
    a.midi(data)
  end
end

function surf.connect()
  for i, v in ipairs(midi.vports) do
    if v.device and surf.match(v.name) then
      dev = midi.connect(i)
      dev.event = on_midi
      sent, held, last_note, shift_note = {}, {}, nil, nil
      return true
    end
  end
  return false
end

function surf.lost()
  if dev then dev.event = nil end
  dev = nil
end

function surf.disconnect()
  if dev then
    for k = 0, 24 do dev:note_off(LOW + k, 0, 1) end
  end
  surf.lost()
end

function surf.refresh() sent = {} end

function surf.frame(st)
  menu_open = st.menu
  for k = 0, 24 do
    local r, g, b
    if st.saver then r, g, b = st.saver_key(k) else r, g, b = st.key(k) end
    -- its keys have one colour: CHOMPI's light as a brightness, 0-127
    local v = math.floor(math.max(r, g, b) / 2)
    if sent[k] ~= v then
      sent[k] = v
      if v > 0 then dev:note_on(LOW + k, v, 1) else dev:note_off(LOW + k, 0, 1) end
    end
  end
end

return surf
