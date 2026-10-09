-- The Keith McMillen QuNexus, as a surface. Its 25 keys are CHOMPI's, C3 to
-- C5 (MIDI 48-72 at its default octave).
--   playing    keys go to CHOMPI as MIDI notes, so velocity counts (TAPE and
--              WAVE); pressure, if the QuNexus sends it, goes to the knob
--              chosen in "pressure to"
--   shift      the bend pad (bottom left): pressed past 3/4 either way it
--              holds CHOMPI's shift, back near the middle it lets go
--   octave     its own octave buttons move its notes; nidhogg can't see them
--              pressed. In JAMMI, CHOMPI plays MIDI notes two octaves below
--              its keys too, so octave down gives lower notes. The key
--              lights match the keys at the default octave.
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
local SHIFT_ON, SHIFT_OFF = 6000, 2000 -- bend from the middle (8192)
local shift_held = false

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
      if how == "key" then a.key(k, 0)
      elseif how == "midi" then a.midi({0x80, d1, 0}) end
    end
  elseif kind == 0xE0 then
    -- the bend pad is shift
    local bend = math.abs((d1 | (d2 << 7)) - 8192)
    if bend > SHIFT_ON and not shift_held then
      shift_held = true
      a.touch()
      a.shift(1)
    elseif bend < SHIFT_OFF and shift_held then
      shift_held = false
      a.shift(0)
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
      sent, held, shift_held = {}, {}, false
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
