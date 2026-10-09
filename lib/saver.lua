-- Screensaver for the OMX-27 OLED and the norns screen, which can both burn
-- in. After a few minutes without input both go dark except for Nidhogg
-- winding across, and the OMX-27's bottom keys glow under it. Any
-- input wakes it; the input still does its job.

local saver = {}

saver.delay = 180 -- seconds without input

local last_input = util.time()

local SEGMENTS = 30
local SPACING = 2.5  -- pixels between segments
local SPEED = 9      -- pixels per second
local LENGTH = SEGMENTS * SPACING
-- One crossing: from the head just off the left edge to the tail off the right.
local PASS = (128 + LENGTH + 16) / SPEED

-- Each pass is followed by a random gap with nothing on screen.
local pass_start = util.time()
local gap = 1

function saver.touch()
  last_input = util.time()
  -- norns blanks its screen after 15 min without its own keys or encoders
  screen.ping()
end

function saver.active()
  return util.time() - last_input > saver.delay
end

-- Seconds until the screensaver starts, for the mascot to get sleepy.
function saver.remaining()
  -- The screensaver for a field of pads, one point at a time: (x, y) is where
-- the pad stands on the norns screen's top 128x32, and `along` (0-1) how far
-- it is along the controller, for a faint wave of the bank colour that rolls
-- slowly along it and fades through the gaps. The dragon's body glows over
-- that as it passes, brightest at the head. Returns r, g, b.
function saver.field(color, x, y, along)
  local wave = 0.5 + 0.5 * math.sin(util.time() * 2 * math.pi / 7 - along * 2 * math.pi)
  local v = (0.025 + 0.045 * wave) * top_keys_level()
  local t = pass_time()
  if t then
    for i = 0, SEGMENTS, 2 do
      local px, py = point(t, i)
      -- the body is long and thin: a pad sees it from further along than across
      local dx, dy = (px - x) / 11, (py - y) / 5
      local d = math.sqrt(dx * dx + dy * dy)
      if d < 1 then v = math.max(v, 0.6 * (1 - d) * (1 - i / (SEGMENTS + 1))) end
    end
  end
  return color[1] * v, color[2] * v, color[3] * v
end

return saver.delay - (util.time() - last_input)
end

-- Time since the current pass began, rolling over to a new pass once the
-- gap after it is done.
local function pass_clock()
  local now = util.time()
  if not saver.active() or now - last_input - saver.delay < 0.1 then
    -- just started: begin a pass from the left
    pass_start = now
  end
  local t = now - pass_start
  if t > PASS + gap then
    pass_start = now
    gap = 0.5 + math.random() * 4.5
    t = 0
  end
  return t
end

-- Time into the current pass, or nil during the gap after it.
local function pass_time()
  local t = pass_clock()
  if t > PASS then return nil end
  return t
end

-- How lit the breathing top keys are, 0-1: they fade out as a gap begins and
-- back in before the next pass.
local function top_keys_level()
  local t = pass_clock()
  if t <= PASS then return 1 end
  local into = t - PASS
  local fade = math.min(1, gap / 2)
  if into < fade then return 1 - into / fade end
  if gap - into < fade then return 1 - (gap - into) / fade end
  return 0
end

-- Head position: enters from just off the left edge.
local function head_x(t)
  return t * SPEED - 8
end

-- Body point i (0 is the head) at time t.
local function point(t, i)
  local x = head_x(t) - i * SPACING
  -- the wave grows towards the tail, so the head stays fairly level
  local a = 1.5 + 4 * math.min(1, i / 12)
  local y = 20 + a * math.sin(t * 0.8 - i * 0.28) + 1.5 * math.sin(t * 0.21 + i * 0.09)
  return x, y
end

local function poly(pts)
  screen.move(pts[1][1], pts[1][2])
  for k = 2, #pts do screen.line(pts[k][1], pts[k][2]) end
  screen.close()
  screen.fill()
end

-- Unit vector along the body at segment i, pointing towards the head.
local function tangent(t, i)
  local x0, y0 = point(t, i + 1)
  local x1, y1 = point(t, i)
  local dx, dy = x1 - x0, y1 - y0
  local l = math.sqrt(dx * dx + dy * dy)
  return dx / l, dy / l
end

local function radius(i)
  return 0.7 + 3.3 * (1 - i / SEGMENTS) ^ 0.9
end

-- The side of the body facing up the screen at segment i.
local function up(t, i)
  local tx, ty = tangent(t, i)
  local nx, ny = -ty, tx
  if ny > 0 then nx, ny = -nx, -ny end
  return nx, ny
end

-- Draws the dragon in the top 128x32 (the part the OMX-27 shows): a tapering
-- body with spines along its back, a bat wing, two pairs of legs, a horned
-- head with a gnawing jaw, and a barbed tail.
-- `t` (seconds into a pass) is for previews.
function saver.draw(t)
  t = t or pass_time()
  if not t then return end
  screen.level(15)
  screen.line_cap("round")
  screen.line_join("round")

  -- body: one tube, thick at the neck and thin at the tail
  for i = SEGMENTS - 1, 0, -1 do
    local x0, y0 = point(t, i + 1)
    local x1, y1 = point(t, i)
    if x1 > -6 and x0 < 134 then
      screen.line_width(2 * radius(i))
      screen.move(x0, y0)
      screen.line(x1, y1)
      screen.stroke()
    end
  end
  screen.line_width(1)

  -- spines along the back
  for i = 3, SEGMENTS - 8, 2 do
    local x, y = point(t, i)
    local tx, ty = tangent(t, i)
    local nx, ny = up(t, i)
    local r = radius(i) - 0.3
    local h = r + (i % 4 == 1 and 3.5 or 2.5)
    poly({
      {x + nx * r - tx * 1.6, y + ny * r - ty * 1.6},
      {x + nx * r + tx * 1.2, y + ny * r + ty * 1.2},
      {x + nx * h - tx * 1.5, y + ny * h - ty * 1.5},
    })
  end

  -- legs: thigh down and back, shin down and forward, stepping in turn
  screen.line_width(1.5)
  for n, i in ipairs({5, 15}) do
    local x, y = point(t, i)
    local tx = tangent(t, i)
    local fwd = tx >= 0 and 1 or -1
    local r = radius(i)
    local step = math.sin(t * 3.2 + n * math.pi) * 1.5
    screen.move(x, y + r - 1)
    screen.line(x - fwd * 1.5 + step, y + r + 2)
    screen.line(x + fwd * 0.5 + step, y + r + 4)
    screen.line(x + fwd * 2 + step, y + r + 4)
    screen.stroke()
  end
  screen.line_width(1)

  -- a bat wing above the front legs: three fingers and the skin between
  do
    local x, y = point(t, 6)
    local tx = tangent(t, 6)
    local back = tx >= 0 and -1 or 1
    local r = radius(6)
    local beat = math.sin(t * 2.4)
    local lift = 10 + 5 * beat     -- how high the wing tip reaches
    local sx, sy = x, y - r + 1    -- shoulder
    local ex, ey = sx + back * 4, sy - lift * 0.7 -- elbow
    local tips = {
      {ex + back * 3, ey - lift * 0.5},
      {ex + back * 9, ey - lift * 0.25},
      {ex + back * 13, ey + 1},
    }
    poly({{sx, sy}, {ex, ey}, tips[1], {ex + back * 4, ey + 2}, tips[2],
      {ex + back * 8, ey + 3}, tips[3], {sx + back * 10, sy + 1}})
    screen.move(sx, sy)
    screen.line(ex, ey)
    for _, tip in ipairs(tips) do
      screen.move(ex, ey)
      screen.line(tip[1], tip[2])
    end
    screen.stroke()
  end

  -- head: a skull, a long snout, horns swept back, and a jaw that drops open
  -- and snaps shut
  local hx, hy = point(t, 0)
  if hx > -12 and hx < 140 then
    local tx, ty = tangent(t, 0)
    local nx, ny = up(t, 0)
    local snout = 9
    local gape = math.max(0, math.sin(t * 1.3)) ^ 2 * 0.7
    -- skull
    screen.circle(hx + tx * 1.5, hy + ty * 1.5, 3.5)
    screen.fill()
    -- upper jaw
    poly({
      {hx + nx * 3, hy + ny * 3},
      {hx + tx * snout + nx * 1, hy + ty * snout + ny * 1},
      {hx + tx * (snout + 1) - nx * 0.5, hy + ty * (snout + 1) - ny * 0.5},
      {hx + tx * 2 - nx * 0.5, hy + ty * 2 - ny * 0.5},
    })
    -- lower jaw, turned down by `gape`
    local c, sn = math.cos(gape), math.sin(gape)
    local jx, jy = tx * c - nx * sn, ty * c - ny * sn
    local bx, by = hx + tx * 1 - nx * 1.5, hy + ty * 1 - ny * 1.5
    poly({
      {bx + nx * 0.5, by + ny * 0.5},
      {bx + jx * (snout - 1), by + jy * (snout - 1)},
      {bx + jx * (snout - 2) - nx * 1, by + jy * (snout - 2) - ny * 1},
      {bx - nx * 1.5, by - ny * 1.5},
    })
    -- horns
    screen.line_width(1.5)
    for _, k in ipairs({{2.5, 5, 5}, {1.5, 3, 4}}) do
      screen.move(hx + nx * k[1], hy + ny * k[1])
      screen.line(hx - tx * k[2] + nx * (k[1] + k[3]), hy - ty * k[2] + ny * (k[1] + k[3]))
      screen.stroke()
    end
    screen.line_width(1)
    -- the mouth: dark between the jaws when they're open
    if gape > 0.15 then
      screen.level(0)
      poly({
        {hx + tx * 3, hy + ty * 3},
        {hx + tx * (snout + 1) - nx * 0.5, hy + ty * (snout + 1) - ny * 0.5},
        {bx + jx * (snout - 1) + nx * 0.5, by + jy * (snout - 1) + ny * 0.5},
      })
      screen.level(15)
    end
    -- eye
    screen.level(0)
    screen.rect(math.floor(hx + tx * 3 + nx * 1.5), math.floor(hy + ty * 3 + ny * 1.5), 1, 1)
    screen.fill()
    screen.level(15)
  end

  -- barbed tail tip
  local ex, ey = point(t, SEGMENTS)
  local tx, ty = tangent(t, SEGMENTS - 1)
  poly({
    {ex - tx * 5, ey - ty * 5},
    {ex + ty * 2.5 + tx, ey - tx * 2.5 + ty},
    {ex - ty * 2.5 + tx, ey + tx * 2.5 + ty},
  })
  screen.line_cap("butt")
end

-- LED colours for the OMX-27's 27 keys while the saver runs. `color` is the
-- bank colour, {r, g, b} 0-255.
function saver.leds(color)
  local t = pass_time()
  local out = {}
  for n = 0, 26 do out[n] = {0, 0, 0} end
  -- top keys breathe, very faintly, fading through the gaps
  local tk = util.time()
  local b = (0.04 + 0.04 * (0.5 + 0.5 * math.sin(tk * 2 * math.pi / 6))) * top_keys_level()
  for n = 1, 10 do
    out[n] = {color[1] * b, color[2] * b, color[3] * b}
  end
  if not t then return out end
  -- bottom keys 11-26: glow under the head, fading along the body
  for n = 11, 26 do
    local kx = (n - 11) * 8 + 4 -- key centre across the 128-pixel screen
    local glow = 0
    for i = 0, SEGMENTS, 2 do
      local x = point(t, i)
      local d = math.abs(x - kx)
      if d < 8 then
        glow = math.max(glow, (1 - d / 8) * (1 - i / (SEGMENTS + 1)))
      end
    end
    out[n] = {color[1] * glow, color[2] * glow, color[3] * glow}
  end
  return out
end

return saver
