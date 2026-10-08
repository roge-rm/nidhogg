-- Drawing for TAPE. The top 128x32 of the norns screen is also what the
-- OMX-27 shows, so it's drawn at full brightness only; the bottom half is the
-- norns' own copy of Chompi's panel lights.

local view = {}

local KNOBS = {
  [0] = {name = "PITCH", pages = {"speed", "gain"}},
  [1] = {name = "START", pages = {"start", "attack"}},
  [2] = {name = "END", pages = {"end", "release"}},
  [3] = {name = "MAGIC", pages = {"verb + delay", "lo-fi", "filter"}},
  [4] = {name = "TRANSPORT", pages = {"speed"}},
  [5] = {name = "VOLUME", pages = {"volume", "input gain"}},
}
-- What each pot does with CHOMPI held, by knob page.
local SHIFT_POTS = {
  [0] = {"tune", "pan"},
  [1] = {"move", "a + r"},
  [2] = {"move", "a + r"},
  [3] = {"time", "warble", "reso"},
  [5] = {"comp", "comp"},
}
local SHIFT_KEYS = {"jammi", "cubbi", "mic", "line", "rsmp", "pre", "post", "erase", "copy", "save"}
local MODES = {[0] = "JAMMI", "CUBBI"}
local BANKS = {[0] = "a", "b", "c", "d", "e"}
local INPUTS = {[0] = "mic", "line", "resample"}
local LOOPER = {[0] = "empty", "armed", "recording", "overdub", "playing", "paused"}

-- Chompi's free pitch curve (DSPEngine.h): knob 0-1 to speed, negative is
-- reverse.
local function pitch_speed(v)
  local x = 2 * v - 1
  local s = x < 0 and -1 or 1
  local a = math.abs(x)
  if a < 0.33 then return x * 1.484848 + 0.01 * s end
  if a < 0.66 then return (x - 0.33 * s) * 1.515151 + 0.5 * s end
  return (x - 0.66 * s) * 2.941176 + 1.0 * s
end

local function speed_text(p)
  return string.format("%.2fx%s", math.abs(p), p < 0 and " rev" or "")
end

local function value_text(k, page, v)
  if k == 0 and page == 0 then return speed_text(pitch_speed(v)) end
  if k == 4 then return speed_text(4 * v - 2) end
  if k == 3 and page == 2 then
    if math.abs(v - 0.5) < 0.02 then return "off" end
    return string.format("%s %d", v < 0.5 and "low" or "high", math.floor(math.abs(v - 0.5) * 200 + 0.5))
  end
  return string.format("%d", math.floor(v * 100 + 0.5))
end

local function text(x, y, s, align)
  screen.move(x, y)
  if align == "right" then screen.text_right(s)
  elseif align == "center" then screen.text_center(s)
  else screen.text(s) end
end

-- A label in a box, filled when `on`.
local function chip(x, y, w, s, on)
  if on then
    screen.level(15)
    screen.rect(x, y - 6, w - 1, 8)
    screen.fill()
    screen.level(0)
  else
    screen.level(15)
  end
  text(x + (w - 1) / 2, y, s, "center")
  screen.level(15)
end

local function draw_shift(s)
  screen.level(15)
  text(0, 6, "SHIFT")
  text(127, 6, (MODES[s.mode] or "") .. " " .. (BANKS[s.bank] or ""), "right")
  for i = 1, 10 do
    local on = (i == 1 and s.mode == 0) or (i == 2 and s.mode == 1)
      or (i >= 3 and i <= 5 and s.input == i - 3)
      or (i == 6 and s.fx_pre) or (i == 7 and not s.fx_pre)
    local col = (i - 1) % 5
    chip(col * 25, i <= 5 and 15 or 24, 26, SHIFT_KEYS[i], on)
  end
  screen.level(15)
  local x = 0
  for _, k in ipairs({0, 1, 2, 3, 5}) do
    local labels = SHIFT_POTS[k]
    text(x + 12, 32, labels[(s.knob_page[k] or 0) + 1] or labels[1], "center")
    x = x + 25
  end
end

local function draw_knob(s, k)
  local knob = KNOBS[k]
  local page = s.knob_page[k] or 0
  local v = s.knob_value[k] or 0
  screen.level(15)
  text(0, 6, knob.name)
  text(127, 6, value_text(k, page, v), "right")
  -- the bar
  screen.rect(0.5, 10.5, 127, 8)
  screen.stroke()
  screen.rect(1, 11, math.floor(v * 126 + 0.5), 7)
  screen.fill()
  if (k == 3 and page == 2) or (k == 0 and page == 0) or k == 4 then
    -- middle mark: filter off, pitch and transport stopped
    screen.level(0)
    screen.rect(63, 11, 1, 7)
    screen.fill()
    screen.level(15)
    screen.rect(63, 19, 1, 2)
    screen.fill()
  end
  -- page dots
  for p = 1, #knob.pages do
    screen.rect(2 + (p - 1) * 6, 25, 3, 3)
    if p == page + 1 then screen.fill() else screen.stroke() end
  end
  text(24, 30, knob.pages[page + 1] or "")
  -- a pot that hasn't taken over yet: where it is, and which way to sweep
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

local function draw_home(s)
  screen.level(15)
  local slot = s.slot == 15 and "RAM" or tostring(s.slot)
  text(1, 6, string.format("%s  %s  %s", MODES[s.mode] or "", BANKS[s.voice_bank] or "", slot))
  chip(102, 6, 26, s.record_switch and "REC" or "PLAY", s.record_switch)
  local fx = s.fx_pre and "fx > looper" or "looper > fx"
  text(1, 16, "in " .. (INPUTS[s.input] or ""))
  text(127, 16, fx, "right")
  -- looper
  text(1, 28, LOOPER[s.looper] or "")
  if s.looper ~= 0 and s.looper ~= 1 then
    screen.rect(54.5, 22.5, 73, 6)
    screen.stroke()
    screen.rect(55, 23, math.floor((s.looper_pos or 0) * 72 + 0.5), 5)
    screen.fill()
  end
  if s.sample_rec then
    chip(54, 28, 46, "SAMPLING", true)
  end
end

-- The top 128x32, shared with the OMX-27.
function view.info(s)
  if s.menu then
    draw_shift(s)
  elseif s.focus and util.time() - s.focus_time < 2 then
    draw_knob(s, s.focus)
  else
    draw_home(s)
  end
end

-- Chompi's panel lights, from the 105-byte LED string: 10 panel lights, then
-- 25 key lights in Chompi's chain order.
local PANEL = {
  -- {led, x}: CHOMPI, Pitch, Start, End, Magic, Transport rev/fwd, PLAY,
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
