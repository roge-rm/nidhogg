-- The Intuitive Instruments Exquis, as a surface, through its Developer Mode
-- (Exquis firmware 2.1 or newer; "Developer Mode MIDI specification",
-- dualo.com/en/exquis-resources).
--   pads                CHOMPI's keys C3 to C5, laid out as the Exquis
--                       lays out notes: semitones to the right, a major third
--                       up-right, a minor third up-left
--   encoders 1-4        Pitch, Start, End, Magic; click to push (next page)
--   record button       the CHOMPI key
--   play, loop          PLAY, LOOP
--   clips               the Play/Record switch
--   slider              the output level
-- Settings, sound and the octave buttons do nothing for now; the Exquis has
-- them back when nidhogg lets it go.

local surf = {name = "Exquis"}
surf.actions = nil -- set by lib/surfaces.lua

local function sysex(...)
  local m = {0xF0, 0x00, 0x21, 0x7E, 0x7F}
  for _, b in ipairs({...}) do m[#m + 1] = b end
  m[#m + 1] = 0xF7
  return m
end

-- Developer Mode zones: all of them (pads 01, encoders 02, slider 04, up and
-- down 08, settings and sound 10, the other buttons 20). Settings and sound
-- are taken too, as the Exquis's own menu can't show on pads taken over and
-- would look like a blank Exquis until closed again.
local ZONES = 0x3F
local BTN_RECORD, BTN_LOOP, BTN_CLIPS, BTN_PLAY = 102, 103, 104, 105
local ENCODERS, ENC_BUTTONS = 110, 114 -- the first of 4
local SLIDER = 80                      -- the first of 6

-- Pads 0-60 run left to right, bottom to top, in rows of 6 and 5 (the rows
-- of 5 sit between those of 6). ROW[r] = {first pad, count}.
local ROW = {}
do
  local pad = 0
  for r = 0, 10 do
    ROW[r] = {pad, r % 2 == 0 and 6 or 5}
    pad = pad + ROW[r][2]
  end
end

-- Playing: the notes as the Exquis lays them out (+1 to the right, +4
-- up-right, +3 up-left from the bottom left pad). Most notes are on two pads;
-- only the one nearer the middle is used, which leaves a block of 4 and 3
-- pads going up: C3 at its bottom left, C4 in its middle, C5 at its top right.
local PLAY = {} -- pad -> CHOMPI key 0-24
local C3 = 8    -- C3's place above the bottom left pad
do
  local best = {} -- key -> {distance from the middle, pad}
  for r = 0, 10 do
    local first, n = ROW[r][1], ROW[r][2]
    local note = (r // 2) * 7 + (r % 2 == 1 and 4 or 0)
    for c = 0, n - 1 do
      local k = note + c - C3
      if k >= 0 and k <= 24 then
        local d = math.abs(c + (r % 2 == 1 and 0.5 or 0) - 2.5)
        if not best[k] or d < best[k][1] then best[k] = {d, first + c} end
      end
    end
  end
  for k, b in pairs(best) do PLAY[b[2]] = k end
end

-- The shift menu, laid out like CHOMPI's panel: slots 1-15 on the rows of 5
-- in the middle (1-5, 6-10, 11-15 going up), and the 10 functions on two rows
-- of 6 above them, in CHOMPI's groups of 2, 3 / 2, 3 with a gap between.
local MENU = {} -- pad -> CHOMPI key 0-24
do
  local whites, blacks = {}, {}
  for k = 0, 24 do
    local pc = k % 12
    if pc == 1 or pc == 3 or pc == 6 or pc == 8 or pc == 10 then blacks[#blacks + 1] = k
    else whites[#whites + 1] = k end
  end
  for i, r in ipairs({3, 5, 7}) do
    for c = 0, 4 do MENU[ROW[r][1] + c] = whites[(i - 1) * 5 + c + 1] end
  end
  for i, r in ipairs({8, 10}) do
    local f = (i - 1) * 5
    for c, j in pairs({[0] = 1, 2, nil, 3, 4, 5}) do MENU[ROW[r][1] + c] = blacks[f + j] end
  end
end

local menu_open = false -- as of the last frame
local in_settings = false -- the Exquis's own settings menu is showing
local pressed = {}      -- pad -> the key it pressed, so it's let go of the
                        -- same key if the layout changes while it's held

local dev
local rx = {}
local sent = {}  -- LED id -> "r,g,b,fx" last sent
local down = {}  -- CHOMPI key -> pads holding it

function surf.match(name)
  if name == nil then return false end
  name = name:lower()
  -- Developer Mode answers only on the first of its two USB ports
  return name:find("^exquis") ~= nil and name:find("2$") == nil
end

function surf.connected() return dev ~= nil end

local function send(m) if dev then dev:send(m) end end

local function on_event(status, d1, d2)
  local a = surf.actions
  if status == 0x9F or status == 0x8F then
    local on = status == 0x9F and d2 > 0
    local k
    if on then
      k = (menu_open and MENU or PLAY)[d1]
      pressed[d1] = k
    else
      k = pressed[d1]
      pressed[d1] = nil
    end
    if not k then return end
    a.touch()
    -- a key can be held from two pads (across a layout change): it's down
    -- while either is
    local n = down[k] or 0
    if on then
      down[k] = n + 1
      if n == 0 then a.key(k, 1) end
    elseif n > 0 then
      down[k] = n - 1
      if n == 1 then a.key(k, 0) end
    end
  elseif status == 0xBF then
    local z = d2 > 0 and 1 or 0
    if d1 >= ENCODERS and d1 < ENCODERS + 4 then
      a.touch()
      a.turn(d1 - ENCODERS, d2 - 64)
    elseif d1 >= ENC_BUTTONS and d1 < ENC_BUTTONS + 4 then
      a.touch()
      a.push(d1 - ENC_BUTTONS, z)
    elseif d1 == BTN_RECORD then
      a.touch(); a.chompi(z)
    elseif d1 == BTN_PLAY then
      a.touch(); a.play(z)
    elseif d1 == BTN_LOOP then
      a.touch(); a.loop(z)
    elseif d1 == BTN_CLIPS and z == 1 then
      a.touch(); a.toggle_switch()
    end
  end
end

local function on_midi(data)
  -- sysex can come in pieces; put whole messages back together
  if data[1] == 0xF0 or #rx > 0 then
    for _, b in ipairs(data) do
      if b == 0xF0 then rx = {b}
      elseif #rx > 0 then
        rx[#rx + 1] = b
        if b == 0xF7 then
          -- F0 00 21 7E 7F 03 page F7: the Exquis is entering its settings
          -- menu (page 7F), which draws over the LEDs, or has left it and
          -- wants them all again
          if rx[5] == 0x7F and rx[6] == 0x03 then
            in_settings = rx[7] == 0x7F
            sent = {}
          end
          rx = {}
        end
      end
    end
    return
  end
  on_event(data[1], data[2] or 0, data[3] or 0)
end

function surf.connect()
  for i, v in ipairs(midi.vports) do
    if v.device and surf.match(v.name) then
      dev = midi.connect(i)
      dev.event = on_midi
      sent, down, rx, pressed, in_settings = {}, {}, {}, {}, false
      send(sysex(0x00, ZONES))
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
  send(sysex(0x00, 0x00))
  surf.lost()
end

function surf.refresh() sent = {} end

-- CHOMPI's lights are 0-255, the Exquis's 0-127
local function c7(r, g, b) return (r or 0) >> 1, (g or 0) >> 1, (b or 0) >> 1 end

function surf.frame(st)
  if in_settings then return end
  local want = {} -- LED id -> {r, g, b, fx}
  local function set(id, r, g, b, fx) want[id] = {r, g, b, fx or 0} end
  menu_open = st.menu
  if st.saver then
    -- every pad: the dragon flows up the Exquis as it crosses the norns
    -- screen, rows along its path and columns across its wave
    for r = 0, 10 do
      local first, n = ROW[r][1], ROW[r][2]
      for c = 0, n - 1 do
        local across = c + (r % 2 == 1 and 0.5 or 0) -- 0-5
        local cr, cg, cb = st.saver_field(4 + r * 12, 9 + across * 4.6, r / 10)
        set(first + c, c7(math.floor(cr), math.floor(cg), math.floor(cb)))
      end
    end
    for id = SLIDER, SLIDER + 5 do set(id, 0, 0, 0) end
    for id = ENCODERS, ENCODERS + 3 do set(id, 0, 0, 0) end
    for _, id in ipairs({BTN_RECORD, BTN_LOOP, BTN_CLIPS, BTN_PLAY}) do set(id, 0, 0, 0) end
  else
    local layout = st.menu and MENU or PLAY
    for pad = 0, 60 do
      local k = layout[pad]
      if not k then
        set(pad, 0, 0, 0)
      elseif st.menu then
        -- functions and slots in CHOMPI's colours; ones it leaves dark faintly,
        -- so the layout can be seen
        local r, g, b = c7(st.key(k))
        if r + g + b < 3 then r, g, b = 5, 5, 5 end
        set(pad, r, g, b)
      else
        local r, g, b = st.key(k)
        if r > 150 and g > 150 and b > 150 then
          set(pad, 127, 127, 127) -- playing
        elseif k % 12 == 0 then
          -- the Cs, in the bank colour, so the octaves can be found
          local c = st.bank
          set(pad, c[1] // 3, c[2] // 3, c[3] // 3)
        elseif r + g + b > 6 then
          set(pad, c7(r, g, b))
        else
          -- the rest faintly, C3's octave cool and C4's warm, the black keys
          -- dimmer
          local tint = k < 12 and {5, 7, 12} or {12, 8, 4}
          local d = st.is_black(k) and 2 or 1
          set(pad, tint[1] // d, tint[2] // d, tint[3] // d)
        end
      end
    end
    for i = 0, 3 do set(ENCODERS + i, c7(st.light(1 + i))) end
    set(BTN_RECORD, c7(st.light(0)))
    set(BTN_PLAY, c7(st.light(7)))
    set(BTN_LOOP, c7(st.light(8)))
    if st.record then set(BTN_CLIPS, 110, 0, 0) else set(BTN_CLIPS, 12, 12, 12) end
    -- the output level, green then amber then red
    local lit = math.floor((st.meter_out or 0) * 6 + 0.5)
    for i = 0, 5 do
      if i < lit then
        if i < 4 then set(SLIDER + i, 0, 90, 20) elseif i == 4 then set(SLIDER + i, 100, 70, 0) else set(SLIDER + i, 120, 0, 0) end
      else
        set(SLIDER + i, 0, 0, 0)
      end
    end
  end
  -- send what changed, a run of neighbouring LEDs per message
  local ids = {}
  for id, c in pairs(want) do
    local key = table.concat(c, ",")
    if sent[id] ~= key then ids[#ids + 1] = id end
  end
  table.sort(ids)
  local i = 1
  while i <= #ids do
    local start, m = ids[i], {0x04, ids[i]}
    local id = start
    while i <= #ids and ids[i] == id do
      local c = want[id]
      m[#m + 1], m[#m + 2], m[#m + 3], m[#m + 4] = c[1], c[2], c[3], c[4]
      sent[id] = table.concat(c, ",")
      id, i = id + 1, i + 1
    end
    send(sysex(table.unpack(m)))
  end
end

return surf
