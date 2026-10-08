-- The baby dragon in the top-left of the norns screen, about 24x20 pixels,
-- facing right. It acts out what's happening: blinks and sways when idle,
-- chomps when a note plays, wears headphones while recording, bobs on the
-- beat while something plays, nods off before the screensaver.

local mascot = {}

local chomp_until = 0
local next_blink = util.time() + 3
local blink_until = 0

-- A note has started.
function mascot.note()
  chomp_until = util.time() + 0.15
end

-- The dragon as pixel art, 24x18, facing right. Each character is a pixel:
-- "." nothing, "B" body, "D" wing, "S" spines and horns, "W" white (eye,
-- teeth), "K" black (pupil, nostril), "L" belly, lit with the CHOMPI light.
local BODY = {
  "...............S...S....",
  "..............SS..SS....",
  ".............BBBBBBB....",
  "............BBBBBBBBB...",
  "...DD......BBBBBWWBBBB..",
  "..DDDD.....BBBBWWKBBBBBB",
  ".DDDDDD....BBBBWWKBBBBKB",
  "DDDDDDDD...BBBBBBBBBBBBB",
  "..DDDDDDS..BBBBBBBBBBBB.",
  "....SBSBBBBBBBBBBWBWB...",
  "...SBBBBBBBBBBBBB.......",
  "..BBBBBBBBLLLLBB........",
  ".BBBBBBBBLLLLLLBB.......",
  "BB..BBBBBLLLLLLBB.......",
  "BS...BBBBLLLLLBB........",
  ".B....BBBBBBBBB.........",
  "......BB....BB..........",
  "......BB....BB..........",
}
-- Rows swapped in for the other poses.
local BLINK = {[5] = "..DDDD.....BBBBBBBBBBBBB", [6] = ".DDDDDD....BBBBKKKBBBBKB"}
local CHOMP = {
  [6] = ".DDDDDD....BBBBWWKBBBBBB",
  [7] = "DDDDDDDD...BBBBBBBBBB.KB",
  [8] = "..DDDDDDS..BBBBBBBKKKKKK",
  [9] = "....SBSBBBBBBBBBBWKWKW..",
}
-- The wing up a pixel, for flapping.
local WING_UP = {
  [3] = "..DD........BBBBBBBBB...",
  [4] = ".DDDD......BBBBBWWBBBB..",
  [5] = "DDDDDD.....BBBBWWKBBBBBB",
  [6] = "DDDDDDDD...BBBBWWKBBBBKB",
  [7] = "..DDDDDD...BBBBBBBBBBBBB",
}

local LEVELS = {B = 10, D = 5, S = 14, W = 15, K = 0}

-- Draws the sprite, one fill per grey level.
local function sprite(x, y, rows, belly)
  for ch, lvl in pairs({B = LEVELS.B, D = LEVELS.D, S = LEVELS.S, W = LEVELS.W, K = LEVELS.K, L = belly}) do
    local any = false
    for r = 1, #rows do
      local row = rows[r]
      local c = row:find(ch, 1, true)
      while c do
        screen.rect(x + c - 1, y + r - 1, 1, 1)
        any = true
        c = row:find(ch, c + 1, true)
      end
    end
    if any then
      screen.level(lvl)
      screen.fill()
    end
  end
end

-- st: {recording, playing, beat (0-1 phase), sleepy (0-1), belly (0-15)}
function mascot.draw(x0, y0, st)
  local now = util.time()
  if now > next_blink then
    blink_until = now + 0.12
    next_blink = now + 3 + math.random() * 3
  end
  local chomp = now < chomp_until
  local blink = now < blink_until or (st.sleepy or 0) > 0.6

  -- bob on the beat while playing, sway gently otherwise
  local oy
  if st.playing then
    oy = (st.beat or 0) < 0.25 and 1 or 0
  else
    oy = math.floor(math.sin(now * 1.3) * 0.6 + 0.5)
  end

  local rows = {}
  for r = 1, #BODY do rows[r] = BODY[r] end
  if math.sin(now * 2.4) > 0.3 then
    for r, row in pairs(WING_UP) do rows[r] = row end
  end
  if chomp then
    for r, row in pairs(CHOMP) do rows[r] = row end
  end
  if blink then
    for r, row in pairs(BLINK) do rows[r] = row end
  end
  sprite(x0, y0 + 1 + oy, rows, math.max(5, st.belly or 0))

  local x, y = x0, y0 + 1 + oy
  -- headphones while recording: a band over the head and a cup by the ear
  if st.recording then
    screen.level(15)
    screen.rect(x + 12, y + 1, 9, 1)
    screen.rect(x + 11, y + 2, 1, 2)
    screen.rect(x + 21, y + 2, 1, 2)
    screen.rect(x + 10, y + 4, 2, 4)
    screen.fill()
  end

  -- dozing off before the screensaver
  local sleepy = st.sleepy or 0
  if sleepy > 0.3 then
    screen.level(math.floor(4 + 11 * sleepy))
    screen.font_face(1)
    screen.font_size(8)
    local zy = y + 4 - math.floor((now * 2) % 3)
    screen.move(x + 21, zy)
    screen.text("z")
  end
end

return mascot
