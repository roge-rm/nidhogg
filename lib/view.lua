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

function view.omx(s, M)
  screen.font_face(1)
  screen.font_size(16)
  screen.level(15)
  if s.menu then
    text(0, 13, "SHIFT")
    text(127, 13, string.upper(M.shift_title(s)), "right")
  elseif knob_active(s) then
    local k = s.focus
    local page = s.knob_page[k] or 0
    local v = s.knob_value[k] or 0
    local knob = M.knobs[k]
    text(0, 13, knob.big[page + 1] or knob.name)
    local value = string.upper(M.value(k, page, v, s)):gsub(" REV", "<"):gsub(" BPM", "")
    text(127, 13, value, "right")
    bar(0, 19, 127, 12, v)
    if M.middle_mark(k, page) then
      screen.level(0)
      screen.rect(63, 21, 2, 9)
      screen.fill()
      screen.level(15)
    end
    local pot = s.pot[k]
    if pot and not s.picked[k] and k ~= 4 then
      -- where the pot is: a gap in the bar
      local x = math.floor(pot * 124 + 2)
      screen.level(0)
      screen.rect(x - 1, 19, 3, 13)
      screen.fill()
      screen.level(15)
      screen.rect(x, 19, 1, 13)
      screen.fill()
    end
  else
    M.omx_home(s, ui)
    -- TAPE's top right shows the switch; REC flashes while sampling
    if M.name == "TAPE" and s.record_switch then
      if not M.recording(s) or math.floor(util.time() * 3) % 2 == 0 then
        text(127, 13, "REC", "right")
      end
    end
  end
  screen.font_size(8)
end

-- ---- norns screen --------------------------------------------------------------

local function draw_shift(s, M)
  screen.level(15)
  text(1, 6, "SHIFT  " .. M.name)
  text(127, 6, M.shift_title(s), "right")
  for i = 1, 10 do
    local col = (i - 1) % 5
    chip(col * 25, i <= 5 and 15 or 24, 26, M.shift_keys[i], M.shift_on(s, i))
  end
  local x = 0
  for _, k in ipairs({0, 1, 2, 3, 5}) do
    local labels = M.shift_pots[k]
    if labels then
      text(x + 12, 32, labels[(s.knob_page[k] or 0) + 1] or labels[1], "center")
    end
    x = x + 25
  end
end

local function draw_knob(s, M, k)
  local knob = M.knobs[k]
  local page = s.knob_page[k] or 0
  local v = s.knob_value[k] or 0
  screen.level(15)
  text(1, 6, knob.name)
  text(127, 6, M.value(k, page, v, s), "right")
  bar(0, 10, 127, 8, v)
  if M.middle_mark(k, page) then
    screen.level(0)
    screen.rect(63, 11, 1, 7)
    screen.fill()
    screen.level(15)
    screen.rect(63, 19, 1, 2)
    screen.fill()
  end
  for p = 1, #knob.pages do
    screen.rect(2 + (p - 1) * 6, 25, 3, 3)
    if p == page + 1 then screen.fill() else screen.stroke() end
  end
  text(24, 30, knob.pages[page + 1] or "")
  local pot = s.pot[k]
  if pot and not s.picked[k] and k ~= 4 then
    local x = math.floor(pot * 126 + 1.5)
    screen.move(x - 2, 23)
    screen.line(x + 2, 23)
    screen.line(x, 20)
    screen.close()
    screen.fill()
    text(127, 30, pot < v and "sweep >" or "< sweep", "right")
  end
end

-- The top 128x32 of the norns screen: the details.
function view.info(s, M)
  if s.menu then
    draw_shift(s, M)
  elseif knob_active(s) then
    draw_knob(s, M, s.focus)
  else
    screen.level(15)
    M.home(s, ui)
    local label = s.record_switch and M.switch[2] or M.switch[1]
    if M.name == "TAPE" then
      chip(102, 6, 26, label, s.record_switch)
    else
      chip(96, 28, 32, label, s.record_switch)
    end
  end
end

-- Chompi's panel lights, from the 105-byte LED string: 10 panel lights, then
-- 25 key lights in Chompi's chain order.
local PANEL = {
  -- {light, x}: CHOMPI, Pitch, Start, End, Magic, Transport left/right, PLAY,
  -- LOOP, Volume
  {0, 6}, {1, 22}, {2, 34}, {3, 46}, {4, 58}, {5, 74}, {6, 80}, {7, 96}, {8, 108}, {9, 122},
}
-- Black keys sit after these white keys.
local BLACK_AFTER = {1, 2, 4, 5, 6, 8, 9, 11, 12, 13}

local function level_of(leds, i)
  local r, g, b = leds:byte(i * 3 + 1, i * 3 + 3)
  return math.floor(math.max(r or 0, g or 0, b or 0) / 17)
end

function view.panel(leds)
  for _, p in ipairs(PANEL) do
    screen.level(math.max(1, level_of(leds, p[1])))
    screen.circle(p[2], 38, 2.5)
    screen.fill()
  end
  -- white keys 1-15 use key lights 24 down to 10
  for w = 1, 15 do
    screen.level(math.max(1, level_of(leds, 10 + 25 - w)))
    screen.rect(4 + (w - 1) * 8, 54, 7, 10)
    screen.fill()
  end
  -- black keys 1-10 use key lights 0-9
  for b = 1, 10 do
    screen.level(math.max(1, level_of(leds, 10 + b - 1)))
    screen.rect(4 + BLACK_AFTER[b] * 8 - 3, 45, 6, 7)
    screen.fill()
  end
end

return view
