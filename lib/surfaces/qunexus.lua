-- The Keith McMillen QuNexus, as a surface. Its 25 keys are CHOMPI's, C3 to
-- C5 (MIDI 48-72 at its default octave).
--   playing    keys go to CHOMPI as MIDI notes, so velocity counts (TAPE and
--              WAVE); pressure, if the QuNexus sends it, goes to the knob
--              chosen in "pressure to"
--   shift      the bend pad (bottom left) held left, past 3/4: CHOMPI's
--              shift, until it's back near the middle
--   knobs      the bend pad held right: the keys turn the knobs, in threes
--              of down, push, up: Pitch C3 C#3 D3, Start F3 F#3 G3, End A3
--              A#3 B3, Magic C4 C#4 D4, Transport F4 F#4 G4, Volume A4 A#4
--              B4. Pressing harder makes a bigger step, and holding keeps
--              turning.
--   octave     its own octave buttons move its notes; nidhogg can't see them
--              pressed. In JAMMI, CHOMPI plays MIDI notes two octaves below
--              its keys too, so octave down gives lower notes. The key
--              lights match the keys at the default octave.
--   shift menu while it's open the keys press CHOMPI's own keys, as the menu
--              takes no MIDI notes: slots on the white keys, the shift jobs
--              on the black ones.
-- Its keys light from notes sent back on channel 1, velocity setting the
-- brightness, so each key shows CHOMPI's light for it as a brightness.

local common = include("lib/surfaces/common")

local surf = {name = "QuNexus"}
surf.actions = nil -- set by lib/surfaces.lua

local LOW = 48 -- the note of its lowest key, at its default octave

local dev
local sent = {}    -- key -> brightness last sent
local held = {}    -- note -> "midi" or "key", how it was pressed
local menu_open = false
local BEND_ON, BEND_OFF = 6000, 2000 -- bend from the middle (8192)
local shift_held = false
local knob_mode = false
local repeating = {} -- note -> its repeat clock

-- knob mode: key (0-24) -> {knob, -1 down / 0 push / 1 up}
local KNOB_KEY = {}
for i, start in ipairs({0, 5, 9, 12, 17, 21}) do
  local knob = i - 1
  KNOB_KEY[start], KNOB_KEY[start + 1], KNOB_KEY[start + 2] = {knob, -1}, {knob, 0}, {knob, 1}
end

local function stop_repeat(n)
  if repeating[n] then clock.cancel(repeating[n]); repeating[n] = nil end
end

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
      if knob_mode then
        local job = KNOB_KEY[k]
        if job then
          held[d1] = "knob"
          if job[2] == 0 then
            a.push(job[1], 1)
          else
            local step = job[2] * (d2 > 100 and 4 or (d2 > 60 and 2 or 1))
            repeating[d1] = common.hold(function() a.turn(job[1], step) end)
          end
        end
      elseif menu_open and k >= 0 and k <= 24 then
        held[d1] = "key"
        a.key(k, 1)
      else
        held[d1] = "midi"
        a.midi({0x90, d1, d2})
      end
    else
      local how = held[d1]
      held[d1] = nil
      stop_repeat(d1)
      if how == "knob" then
        local job = KNOB_KEY[k]
        if job and job[2] == 0 then a.push(job[1], 0) end
      elseif how == "key" then a.key(k, 0)
      elseif how == "midi" then a.midi({0x80, d1, 0}) end
    end
  elseif kind == 0xE0 then
    -- the bend pad: left is shift, right the knobs
    local bend = (d1 | (d2 << 7)) - 8192
    if bend < -BEND_ON and not shift_held then
      shift_held = true
      a.touch()
      a.shift(1)
    elseif bend > BEND_ON and not knob_mode then
      knob_mode = true
      a.touch()
    elseif math.abs(bend) < BEND_OFF then
      if shift_held then shift_held = false; a.shift(0) end
      knob_mode = false
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
      sent, held, shift_held, knob_mode = {}, {}, false, false
      return true
    end
  end
  return false
end

function surf.lost()
  if dev then dev.event = nil end
  dev = nil
  for n in pairs(repeating) do stop_repeat(n) end
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
    local v
    if knob_mode then
      -- the knob keys: down and up lit, push brighter when its knob is off
      -- its first page
      local job = KNOB_KEY[k]
      if not job then v = 0
      elseif job[2] == 0 then v = st.page(job[1]) > 0 and 127 or 40
      else v = 20 end
    else
      local r, g, b
      if st.saver then r, g, b = st.saver_key(k) else r, g, b = st.key(k) end
      -- its keys have one colour: CHOMPI's light as a brightness, 0-127.
      -- CHOMPI lights its shift menu at full strength in colour, which as
      -- white outshines the rest, so the menu is a third as bright.
      v = math.floor(math.max(r, g, b) / 2)
      if st.menu then v = math.floor(v * 0.33) end
    end
    if sent[k] ~= v then
      sent[k] = v
      if v > 0 then dev:note_on(LOW + k, v, 1) else dev:note_off(LOW + k, 0, 1) end
    end
  end
end

return surf
