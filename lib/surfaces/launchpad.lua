-- The Novation Launchpad Pro [MK3] in Programmer mode, as a surface. Pads
-- are notes 11-88 (ten times the row plus the column, from 1 at the bottom
-- left), the buttons around them controllers, and every one is lit by the
-- same number (Launchpad Pro [MK3] Programmer's Reference).
--   rows 1-4   two octaves of piano, C3 to C5: white keys on rows 1 and 3,
--              black keys above them. With shift held these are CHOMPI's
--              shift menu as on its panel: slots on the white keys, the
--              shift jobs on the black ones.
--   rows 5-8   Magic, End, Start and Pitch (Pitch at the top), nudged: the
--              pads step the knob down on the left and up on the right, more
--              the further from the middle, and keep going while held. The
--              row shows where the knob is.
--   right of rows 5-8   push that knob (next page)
--   right of rows 1-4   the output level
--   row of 8 under the grid   Volume, nudged the same way
--   Shift      CHOMPI's shift
--   Record     record while held
--   Play, Fixed Length   PLAY, LOOP
--   Clear      PLAY and LOOP held together: hold to clear the looper or the
--              sequence
--   Up, Down   Transport faster, slower (held, it repeats); both: push it
--   Session    the Play/Record switch
--   Volume (under the track row)   push Volume

local common = include("lib/surfaces/common")

local surf = {name = "Launchpad Pro"}
surf.actions = nil -- set by lib/surfaces.lua

local HEAD = {0xF0, 0x00, 0x20, 0x29, 0x02, 0x0E}
local function sysex(...)
  local m = {table.unpack(HEAD)}
  for _, b in ipairs({...}) do m[#m + 1] = b end
  m[#m + 1] = 0xF7
  return m
end

local SHIFT, RECORD, PLAY, LOOP, CLEAR = 90, 10, 20, 30, 60
local UP, DOWN, SESSION, VOLUME_PUSH = 80, 70, 93, 4
local TRACK = 101 -- the first of the 8 under the grid
local KNOB_ROW = {[8] = 0, [7] = 1, [6] = 2, [5] = 3} -- grid row -> CHOMPI knob
local TRANSPORT, VOLUME = 4, 5
local NUDGE = {[1] = -8, -4, -2, -1, 1, 2, 4, 8} -- by column

-- Rows 1-4: the piano. White keys on rows 1 and 3, and on rows 2 and 4 each
-- black key over the white key above it (C# over D), leaving gaps over C, F
-- and the top C, as on a piano.
local KEY_AT = {} -- pad note -> CHOMPI key 0-24
do
  local WHITE = {0, 2, 4, 5, 7, 9, 11, 12}
  local SHARP = {[2] = 1, [3] = 3, [5] = 6, [6] = 8, [7] = 10}
  for oct = 0, 1 do
    local row = 1 + oct * 2
    for col = 1, 8 do KEY_AT[row * 10 + col] = oct * 12 + WHITE[col] end
    for col, k in pairs(SHARP) do KEY_AT[(row + 1) * 10 + col] = oct * 12 + k end
  end
end

-- each knob's own colour, for its row when its panel light is dark
local KNOB_COLOR = {[0] = {90, 30, 110}, {20, 90, 110}, {110, 60, 10}, {30, 110, 40}, nil, {100, 100, 100}}

local dev
local rx = {}
local sent = {}     -- LED -> "r,g,b" last sent
local down = {}     -- CHOMPI key -> pads holding it
local pressed = {}  -- pad -> the key it pressed
local repeating = {} -- pad or button -> its repeat clock
local arrows = {}
local arrow_push = false
local clear_held = false

function surf.match(name)
  if name == nil then return false end
  name = name:lower()
  -- Programmer mode answers on the first of its three ports
  return (name:find("launchpad pro") or name:find("lppromk3")) ~= nil
    and name:find("[23]$") == nil and name:find("din") == nil and name:find("daw") == nil
end

function surf.connected() return dev ~= nil end

local function send(m) if dev then dev:send(m) end end

local function stop_repeat(id)
  if repeating[id] then clock.cancel(repeating[id]); repeating[id] = nil end
end

local function on_event(status, d1, d2)
  local a = surf.actions
  local kind = status & 0xF0
  if kind == 0x90 or kind == 0x80 then
    local on = kind == 0x90 and d2 > 0
    local row = d1 // 10
    if KNOB_ROW[row] then
      local knob, col = KNOB_ROW[row], d1 % 10
      stop_repeat(d1)
      if on and NUDGE[col] then
        a.touch()
        repeating[d1] = common.hold(function() a.turn(knob, NUDGE[col]) end)
      end
      return
    end
    local k
    if on then
      k = KEY_AT[d1]
      pressed[d1] = k
    else
      k = pressed[d1]
      pressed[d1] = nil
    end
    if not k then return end
    a.touch()
    local n = down[k] or 0
    if on then
      down[k] = n + 1
      if n == 0 then a.key(k, 1) end
    elseif n > 0 then
      down[k] = n - 1
      if n == 1 then a.key(k, 0) end
    end
  elseif kind == 0xB0 then
    local z = d2 > 0 and 1 or 0
    if d1 >= TRACK and d1 < TRACK + 8 then
      stop_repeat(d1)
      if z == 1 then
        a.touch()
        local step = NUDGE[d1 - TRACK + 1]
        repeating[d1] = common.hold(function() a.turn(VOLUME, step) end)
      end
    elseif d1 % 10 == 9 and d1 >= 59 and d1 <= 89 then
      a.touch(); a.push(KNOB_ROW[d1 // 10], z)
    elseif d1 == SHIFT then
      a.touch(); a.shift(z)
    elseif d1 == RECORD then
      a.touch(); a.record(z)
    elseif d1 == PLAY then
      a.touch(); a.play(z)
    elseif d1 == LOOP then
      a.touch(); a.loop(z)
    elseif d1 == CLEAR then
      a.touch(); a.play(z); a.loop(z)
      clear_held = z == 1
    elseif d1 == SESSION and z == 1 then
      a.touch(); a.toggle_switch()
    elseif d1 == VOLUME_PUSH then
      a.touch(); a.push(VOLUME, z)
    elseif d1 == UP or d1 == DOWN then
      a.touch()
      arrows[d1] = z == 1 or nil
      stop_repeat("arrow")
      if arrows[UP] and arrows[DOWN] then
        arrow_push = true
        a.push(TRANSPORT, 1)
      elseif z == 1 and not arrow_push then
        local d = d1 == UP and 1 or -1
        repeating.arrow = common.hold(function() a.turn(TRANSPORT, d) end)
      elseif z == 0 and arrow_push then
        arrow_push = false
        a.push(TRANSPORT, 0)
      end
    end
  end
end

local function on_midi(data)
  if data[1] == 0xF0 or #rx > 0 then
    for _, b in ipairs(data) do
      if b == 0xF0 then rx = {b}
      elseif #rx > 0 then
        rx[#rx + 1] = b
        if b == 0xF7 then rx = {} end
      end
    end
    return
  end
  on_event(data[1] or 0, data[2] or 0, data[3] or 0)
end

function surf.connect()
  for i, v in ipairs(midi.vports) do
    if v.device and surf.match(v.name) then
      dev = midi.connect(i)
      dev.event = on_midi
      sent, down, rx, pressed, arrows, arrow_push, clear_held = {}, {}, {}, {}, {}, false, false
      send(sysex(0x0E, 0x01)) -- Programmer mode
      return true
    end
  end
  return false
end

function surf.lost()
  if dev then dev.event = nil end
  dev = nil
  for id in pairs(repeating) do stop_repeat(id) end
end

function surf.disconnect()
  send(sysex(0x0E, 0x00)) -- back to its own Live mode
  surf.lost()
end

function surf.refresh() sent = {} end

local function c7(r, g, b) return (r or 0) >> 1, (g or 0) >> 1, (b or 0) >> 1 end
local function scale(c, k) return math.floor(c[1] * k), math.floor(c[2] * k), math.floor(c[3] * k) end

-- A nudge row: a faint track in the knob's colour, the pad nearest its value
-- bright, and for Pitch its middle marked.
local function knob_row(set, first_led, value, color, middle)
  local at = util.clamp(math.floor(value * 8) + 1, 1, 8)
  for col = 1, 8 do
    local led = first_led + col - 1
    if col == at then set(led, scale(color, 1))
    elseif middle and (col == 4 or col == 5) then set(led, 14, 14, 14)
    else set(led, scale(color, 0.12)) end
  end
end

function surf.frame(st)
  local want = {}
  local function set(id, r, g, b) want[id] = {math.floor(r), math.floor(g), math.floor(b)} end
  -- everything starts dark
  for row = 1, 8 do for col = 1, 9 do set(row * 10 + col, 0, 0, 0) end end
  for id = 90, 98 do set(id, 0, 0, 0) end
  for id = 10, 80, 10 do set(id, 0, 0, 0) end
  for id = 1, 8 do set(id, 0, 0, 0) end
  for id = TRACK, TRACK + 7 do set(id, 0, 0, 0) end
  if st.saver then
    -- the dragon flows up the grid as it crosses the norns screen
    for row = 1, 8 do
      for col = 1, 8 do
        local r, g, b = st.saver_field(4 + (row - 1) * 17, 9 + (col - 1) * 3.3, (row - 1) / 7)
        set(row * 10 + col, c7(math.floor(r), math.floor(g), math.floor(b)))
      end
    end
  else
    for note, k in pairs(KEY_AT) do
      local r, g, b = c7(st.key(k))
      if r > 75 and g > 75 and b > 75 then
        set(note, 127, 127, 127) -- playing
      elseif not st.menu and k % 12 == 0 then
        set(note, st.bank[1] // 3, st.bank[2] // 3, st.bank[3] // 3) -- the Cs
      elseif r + g + b > 3 then
        set(note, r, g, b)
      else
        -- dark keys faintly, black dimmer than white
        local v = st.is_black(k) and 3 or 9
        set(note, v, v, v)
      end
    end
    for row, knob in pairs(KNOB_ROW) do
      local lr, lg, lb = c7(st.light(1 + knob))
      local color = (lr + lg + lb > 20) and {lr, lg, lb} or KNOB_COLOR[knob]
      knob_row(set, row * 10 + 1, st.knob(knob), color, knob == 0)
      -- its push button: amber when the knob is off its first page
      if st.page(knob) > 0 then set(row * 10 + 9, 110, 50, 0) else set(row * 10 + 9, scale(color, 0.3)) end
    end
    knob_row(set, TRACK, st.volume or 0, KNOB_COLOR[VOLUME], false)
    -- the output level up the right of the keys
    local lit = math.floor((st.meter_out or 0) * 4 + 0.5)
    for i = 1, 4 do
      local led = i * 10 + 9
      if i <= lit then
        if i < 3 then set(led, 0, 90, 20) elseif i == 3 then set(led, 100, 70, 0) else set(led, 120, 0, 0) end
      end
    end
    set(SHIFT, c7(st.light(0)))
    if surf.actions.recording() then set(RECORD, 127, 0, 0) else set(RECORD, 30, 0, 0) end
    set(PLAY, c7(st.light(7)))
    set(LOOP, c7(st.light(8)))
    if clear_held then set(CLEAR, 120, 0, 0) else set(CLEAR, 25, 0, 0) end
    if st.record then set(SESSION, 110, 0, 0) else set(SESSION, 12, 12, 12) end
    set(UP, 10, 10, 10)
    set(DOWN, 10, 10, 10)
    if st.page(VOLUME) > 0 then set(VOLUME_PUSH, 110, 50, 0) else set(VOLUME_PUSH, 10, 10, 10) end
  end
  -- send what changed, up to 64 LEDs a message
  local m, n = {0x03}, 0
  for id, c in pairs(want) do
    local key = table.concat(c, ",")
    if sent[id] ~= key then
      sent[id] = key
      m[#m + 1], m[#m + 2], m[#m + 3], m[#m + 4], m[#m + 5] = 0x03, id, c[1], c[2], c[3]
      n = n + 1
      if n == 64 then
        send(sysex(table.unpack(m)))
        m, n = {0x03}, 0
      end
    end
  end
  if n > 0 then send(sysex(table.unpack(m))) end
end

return surf
