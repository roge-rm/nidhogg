-- Drawing, for whichever firmware is running (lib/modes.lua). view.omx draws
-- the OMX-27's 128x32 screen: only the basics, in double-size text, at full
-- brightness. view.info and view.panel draw the norns screen: the details,
-- then Chompi's panel lights.

local view = {}

local function text(x, y, s, align)
  screen.move(x, y)
  if align == "right" then screen.text_right(s)
  elseif align == "center" then screen.text_center(s)
  else screen.text(s) end
end

-- A label in a box, filled when `on`.
local function chip(x, y, w, s, on)
  screen.level(15)
  if on then
    screen.rect(x, y - 6, w - 1, 8)
    screen.fill()
    screen.level(0)
  end
  text(x + (w - 1) / 2, y, s, "center")
  screen.level(15)
end

-- An outlined bar filled to v.
local function bar(x, y, w, h, v)
  screen.rect(x + 0.5, y + 0.5, w, h)
  screen.stroke()
  screen.rect(x + 1, y + 1, math.floor(v * (w - 1) + 0.5), h - 1)
  screen.fill()
end

-- Looper state as a shape in the 12x12 box at (x, 19).
local function looper_icon(state, x)
  if state == 1 then -- armed: hollow dot
    screen.circle(x + 6, 25, 4.5)
    screen.stroke()
  elseif state == 2 or state == 3 then -- recording: dot
    screen.circle(x + 6, 25, 5)
    screen.fill()
  elseif state == 4 then -- playing: triangle
    screen.move(x + 2, 19)
    screen.line(x + 12, 25)
    screen.line(x + 2, 31)
    screen.close()
    screen.fill()
  elseif state == 5 then -- paused: two bars
    screen.rect(x + 2, 19, 3, 12)
    screen.rect(x + 8, 19, 3, 12)
    screen.fill()
  end
end

-- For the firmware's own home screens.
local ui = {text = text, chip = chip, bar = bar}

-- The OMX looper line: symbol and a thick position bar, or EMPTY.
function ui.looper(state, pos)
  looper_icon(state, 0)
  if state and state >= 2 then
    bar(16, 19, 111, 12, pos or 0)
  elseif state == 0 then
    text(18, 30, "EMPTY")
  end
end

local function knob_active(s)
  return s.focus and util.time() - s.focus_time < 2
end

-- ---- OMX-27 screen -----------------------------------------------------------
--
-- The OMX screen sits among the pots, so it shows what helps while playing
-- and leaves the details to the norns. What you're doing picks the view:
-- shift, then recording (levels), then Start or End (the sample window), then
-- any other knob (the knob strip). Otherwise it shows the view chosen with a
-- tap on PUSH (s.omx_view).

view.OMX_VIEWS = {"knobs", "levels", "window", "beat"}

-- Pot order on the OMX, left to right, as Chompi knobs.
local POT_KNOBS = {0, 1, 2, 3, 5}

local function big()
  screen.font_face(1)
  screen.font_size(16)
  screen.level(15)
end

-- Level 0-1 as a bar fraction: -48 dB to 0 dB.
local function meter(v)
  if not v or v <= 0 then return 0 end
  local db = 20 * math.log(v, 10)
  return util.clamp((db + 48) / 48, 0, 1)
end

-- Five columns, one per pot: the knob's value as a full-height bar, and a
-- line where a pot is that hasn't taken over yet. A knob off its first page
-- gets its page number in a box at the top.
local function omx_knobs(s, M, focus)
  for col, k in ipairs(POT_KNOBS) do
    local x = (col - 1) * 26
    local v = s.knob_value[k] or 0
    local page = s.knob_page[k] or 0
    screen.level(15)
    screen.rect(x + 0.5, 0.5, 22, 31)
    screen.stroke()
    local h = math.floor(v * 30 + 0.5)
    screen.rect(x + 1, 31 - h, 21, h)
    screen.fill()
    local pot = s.pot[k]
    if pot and not s.picked[k] then
      local y = 31 - math.floor(pot * 30 + 0.5)
      screen.level(0)
      screen.rect(x + 1, y - 1, 21, 3)
      screen.fill()
      screen.level(15)
      screen.rect(x + 1, y, 21, 1)
      screen.fill()
    end
    if page > 0 then
      screen.level(15)
      screen.rect(x + 2, 2, 19, 14)
      screen.fill()
      screen.level(0)
      text(x + 12, 14, tostring(page + 1), "center")
      screen.level(15)
    end
    if k == focus then
      -- the knob being turned: a second outline
      screen.rect(x - 1.5, -0.5, 26, 33)
      screen.stroke()
    end
  end
end

local function omx_levels(s, recording)
  big()
  local flash = recording and math.floor(util.time() * 3) % 2 == 0
  if recording then
    -- the IN label as a red-light REC
    screen.rect(0, 0, 30, 15)
    if flash then screen.fill() else screen.stroke() end
    screen.level(flash and 0 or 15)
    text(15, 12, "IN", "center")
    screen.level(15)
  else
    text(0, 13, "IN")
  end
  text(0, 30, "OUT")
  bar(34, 1, 93, 12, meter(s.meter_in))
  bar(34, 18, 93, 12, meter(s.meter_out))
end

local function omx_window(s, M)
  big()
  local a, b = s.knob_value[1] or 0, s.knob_value[2] or 1
  text(0, 13, string.format("%d", math.floor(a * 100 + 0.5)))
  text(127, 13, string.format("%d", math.floor(b * 100 + 0.5)), "right")
  text(64, 13, "WINDOW", "center")
  screen.rect(0.5, 18.5, 127, 13)
  screen.stroke()
  local x0, x1 = math.floor(a * 125 + 1.5), math.floor(b * 125 + 1.5)
  screen.rect(x0, 20, math.max(1, x1 - x0), 10)
  screen.fill()
  -- brackets at the ends
  screen.rect(x0 - 1, 16, 1, 16)
  screen.rect(x1, 16, 1, 16)
  screen.fill()
  -- a gap in the bar where each voice is playing
  for _, p in ipairs(s.playheads or {}) do
    local x = math.floor(p * 125 + 1.5)
    screen.level(x >= x0 and x < x1 and 0 or 15)
    screen.rect(x, 20, 1, 10)
    screen.fill()
  end
  screen.level(15)
end

local function omx_beat(s, M)
  big()
  local bpm = M.bpm and M.bpm(s) or 0
  text(0, 13, tostring(bpm))
  text(0, 30, "BPM")
  local ticks = s.ticks or 0
  local beat = (ticks // 24) % 4
  for i = 0, 3 do
    local x = 54 + i * 19
    screen.rect(x + 0.5, 4.5, 15, 15)
    if i == beat then screen.fill() else screen.stroke() end
  end
  -- progress through the beat
  local frac = (ticks % 24) / 24
  screen.rect(54, 26, math.floor(frac * 72), 4)
  screen.fill()
end

function view.omx(s, M)
  big()
  local active = knob_active(s) and s.focus
  local recording = M.audio_recording and M.audio_recording(s)
  if s.view_flash and util.time() < s.view_flash then
    text(64, 22, string.upper(s.omx_view), "center")
  elseif s.menu then
    text(0, 13, "SHIFT")
    text(127, 13, string.upper(M.shift_title(s)), "right")
    text(0, 30, M.name)
  elseif recording then
    omx_levels(s, true)
  elseif active and (active == 1 or active == 2) and M.has_window then
    omx_window(s, M)
  elseif active and active ~= 4 then
    omx_knobs(s, M, active)
  elseif s.omx_view == "levels" then
    omx_levels(s, false)
  elseif s.omx_view == "window" and M.has_window then
    omx_window(s, M)
  elseif s.omx_view == "beat" and M.bpm then
    omx_beat(s, M)
  else
    omx_knobs(s, M, nil)
  end
  screen.font_size(8)
end

-- ---- norns screen --------------------------------------------------------------
--
-- A little Chompi panel: the baby dragon and status pills on top, six round
-- knobs whose rings glow like Chompi's knob lights, and a rounded keyboard
-- lit like Chompi's keys. Turning a knob zooms it; holding AUX shows the shift
-- jobs.

local icons = include("lib/icons")
local mascot = include("lib/mascot")
view.mascot = mascot

local function level_of(leds, i)
  local r, g, b = leds:byte(i * 3 + 1, i * 3 + 3)
  return math.floor(math.max(r or 0, g or 0, b or 0) / 17)
end

local function lit_white(leds, i)
  local r, g, b = leds:byte(i * 3 + 1, i * 3 + 3)
  return (r or 0) > 200 and (g or 0) > 200 and (b or 0) > 200
end

local function width_of(str)
  return (screen.text_extents(str))
end

-- A rounded box: a rectangle with its corner pixels left out.
local function rounded(x, y, w, h, fill_level, edge_level)
  if fill_level then
    screen.level(fill_level)
    screen.rect(x + 1, y, w - 2, h)
    screen.rect(x, y + 1, 1, h - 2)
    screen.rect(x + w - 1, y + 1, 1, h - 2)
    screen.fill()
  end
  if edge_level then
    screen.level(edge_level)
    screen.rect(x + 1, y, w - 2, 1)
    screen.rect(x + 1, y + h - 1, w - 2, 1)
    screen.rect(x, y + 1, 1, h - 2)
    screen.rect(x + w - 1, y + 1, 1, h - 2)
    screen.fill()
  end
end

-- A pill with text and/or an icon. Returns its width. `on` fills it.
local function pill(x, y, item)
  local tw = item.text and width_of(item.text) or 0
  local iw = item.icon and 7 or 0
  local w = tw + iw + (item.text and item.icon and 2 or 0) + 6
  local on = item.on
  rounded(x, y, w, 9, on and 15 or nil, on and nil or (item.dim and 4 or 8))
  local ink = on and 0 or (item.dim and 6 or 15)
  local cx = x + 3
  if item.icon then
    icons.draw(item.icon, cx, y + 2, ink)
    cx = cx + 9
  end
  if item.text then
    screen.level(ink)
    screen.move(cx, y + 7)
    screen.text(item.text)
  end
  return w
end

-- Knob centres along the knob row, and the panel light that rings each.
-- Centres sit on half pixels so circles land on whole pixels and a 7-pixel
-- icon centres under them; six knobs 21 apart leave 3 pixels each side.
local KNOB_X = {[0] = 11.5, 32.5, 53.5, 74.5, 95.5, 116.5}
local KNOB_Y = 29.5
local RING = {[0] = 1, 2, 3, 4, nil, 9}

local function pointer(cx, cy, r, v, level)
  local a = math.rad(-135 + 270 * v) - math.pi / 2
  screen.level(level)
  screen.move(cx, cy)
  screen.line(cx + math.cos(a) * r, cy + math.sin(a) * r)
  screen.stroke()
end

local function knob(k, s, M, leds)
  local cx, cy = KNOB_X[k], KNOB_Y
  local v = s.knob_value[k] or 0
  -- the glow ring: Chompi's knob light, or the transport pair as two halves
  if k == 4 then
    screen.level(math.max(1, level_of(leds, 5)))
    screen.arc(cx, cy, 8, math.pi * 0.5, math.pi * 1.5)
    screen.stroke()
    screen.level(math.max(1, level_of(leds, 6)))
    screen.arc(cx, cy, 8, math.pi * 1.5, math.pi * 2.5)
    screen.stroke()
  else
    screen.level(math.max(1, level_of(leds, RING[k])))
    screen.circle(cx, cy, 8)
    screen.stroke()
  end
  -- the cap
  screen.level(3)
  screen.circle(cx, cy, 5.5)
  screen.fill()
  pointer(cx, cy, 5, v, 15)
  -- page pip
  local page = s.knob_page[k] or 0
  if page > 0 then
    screen.level(15)
    screen.rect(cx + 5.5, cy + 5.5, 2, 2 * page)
    screen.fill()
  end
  icons.draw(M.knob_icons[k][page + 1] or M.knob_icons[k][1], cx - 3.5, 39, 10)
end

local function zoomed_knob(k, s, M, leds)
  local knob_t = M.knobs[k]
  local page = s.knob_page[k] or 0
  local v = s.knob_value[k] or 0
  local cx, cy = 14.5, 31.5
  local glow = k == 4 and math.max(level_of(leds, 5), level_of(leds, 6)) or level_of(leds, RING[k])
  screen.level(math.max(2, glow))
  screen.circle(cx, cy, 12)
  screen.stroke()
  screen.level(3)
  screen.circle(cx, cy, 9)
  screen.fill()
  pointer(cx, cy, 9, v, 15)
  local pot = s.pot[k]
  if pot and not s.picked[k] and k ~= 4 then
    -- where the pot is: a dot on the ring
    local a = math.rad(-135 + 270 * pot) - math.pi / 2
    screen.level(15)
    screen.circle(cx + math.cos(a) * 12, cy + math.sin(a) * 12, 1.5)
    screen.fill()
  end
  screen.font_face(1)
  screen.font_size(8)
  screen.level(8)
  screen.move(32, 26)
  screen.text(knob_t.name)
  screen.font_size(16)
  screen.level(15)
  screen.move(32, 40)
  screen.text(M.value(k, page, v, s))
  screen.font_size(8)
  -- page dots and name
  for p = 1, #knob_t.pages do
    screen.level(p == page + 1 and 15 or 4)
    screen.rect(120 - (#knob_t.pages - p) * 5, 21, 3, 3)
    screen.fill()
  end
  screen.level(8)
  screen.move(127, 31)
  screen.text_right(knob_t.pages[page + 1] or "")
end

-- Shift: the ten jobs on the top keys, grouped like the keys (2-3, 2-3).
local function shift_chips(s, M)
  screen.font_face(1)
  screen.font_size(8)
  local slots = {{0, 22}, {25, 22}, {53, 22}, {78, 22}, {103, 22},
                 {0, 33}, {25, 33}, {53, 33}, {78, 33}, {103, 33}}
  for i = 1, 10 do
    local x, y = slots[i][1], slots[i][2]
    local on = M.shift_on(s, i)
    rounded(x, y, 24, 10, on and 15 or nil, on and nil or 6)
    screen.level(on and 0 or 15)
    screen.move(x + 12, y + 7)
    screen.text_center(M.shift_keys[i])
  end
end

-- Black keys sit after these white keys.
local BLACK_AFTER = {1, 2, 4, 5, 6, 8, 9, 11, 12, 13}

local function keyboard(leds)
  -- white keys 1-15 use key lights 24 down to 10
  for w = 1, 15 do
    local i = 10 + 25 - w
    local lvl = level_of(leds, i)
    local down = lit_white(leds, i) and 1 or 0
    local x = 4 + (w - 1) * 8
    rounded(x, 46 + down, 7, 18 - down, math.max(2, lvl), nil)
  end
  -- black keys 1-10 use key lights 0-9
  for b = 1, 10 do
    local i = 10 + b - 1
    local lvl = level_of(leds, i)
    local down = lit_white(leds, i) and 1 or 0
    local x = 4 + BLACK_AFTER[b] * 8 - 3
    screen.level(0)
    screen.rect(x - 1, 45, 7, 11)
    screen.fill()
    rounded(x, 45 + down, 5, 10, math.max(1, lvl), nil)
  end
end

-- The norns screen.
function view.norns(s, M, leds, sleepy)
  screen.font_face(1)
  screen.font_size(8)

  -- the dragon
  local ticks = s.ticks or 0
  mascot.draw(0, 0, {
    recording = M.audio_recording and M.audio_recording(s),
    playing = M.playing and M.playing(s),
    beat = (ticks % 24) / 24,
    sleepy = sleepy,
    belly = level_of(leds, 0),
  })

  -- top row: firmware, what's loaded, the switch
  local x = 26
  if s.menu then
    -- a speech bubble from the dragon
    rounded(26, 1, 40, 10, 15, nil)
    screen.level(15)
    screen.move(24, 7)
    screen.line(27, 5)
    screen.line(27, 9)
    screen.close()
    screen.fill()
    screen.level(0)
    screen.move(46, 8)
    screen.text_center("SHIFT")
    screen.level(15)
    screen.move(127, 8)
    screen.text_right(M.shift_title(s))
  else
    pill(x, 1, {text = M.title(s)})
    local sw = s.record_switch and M.switch[2] or M.switch[1]
    local w = width_of(sw) + 6
    pill(127 - w, 1, {text = sw, on = s.record_switch})
    -- second row: the firmware, details as far as they fit, then the PLAY and
    -- LOOP lights
    x = 26
    x = x + pill(x, 11, {text = M.name, on = true, small = true}) + 2
    for _, item in ipairs(M.pills(s)) do
      local tw = (item.text and width_of(item.text) or 0) + (item.icon and 7 or 0) + 6
      if x + tw > 105 then break end
      x = x + pill(x, 11, item) + 2
    end
    icons.draw("play", 108, 13, math.max(2, level_of(leds, 7)))
    icons.draw("loop", 119, 13, math.max(2, level_of(leds, 8)))
  end

  -- middle: knobs, one knob up close, or the shift jobs
  if s.menu then
    shift_chips(s, M)
  elseif knob_active(s) then
    zoomed_knob(s.focus, s, M, leds)
  else
    for k = 0, 5 do knob(k, s, M, leds) end
  end

  keyboard(leds)
end

return view
