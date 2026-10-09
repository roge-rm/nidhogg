-- Controllers ("surfaces") for nidhogg. Each one is a module in
-- lib/surfaces/ that turns its own hardware into CHOMPI actions and shows
-- CHOMPI's lights on its own LEDs (and its screen, if it has one). More than
-- one can be plugged in at once.
--
-- A surface module has:
--   name                     shown in messages
--   match(name)              true for a MIDI port it drives
--   connect()                finds its port in midi.vports and takes it over;
--                            true if it did
--   lost()                   it was unplugged: forget it, sending nothing
--   disconnect()             hand it back, on the script's cleanup
--   connected()              true while it's in use
--   frame(state)             15 times a second: show `state` (see below)
--   and optionally
--   screen_send(x, y)        sends that 128x32 part of the norns screen to it
--   refresh()                draw everything again (a firmware change)
-- It calls the functions in surfaces.actions for what's played on it.
--
-- `state` for frame():
--   key(k)       r, g, b of CHOMPI key k (0-24, C3 to C5), 0-255
--   light(i)     r, g, b of panel light i: 0 CHOMPI, 1-4 the Pitch, Start,
--                End and Magic knobs, 5 and 6 transport, 7 PLAY, 8 LOOP,
--                9 volume
--   saver        true while the screensaver runs; bank, its bank colour;
--                saver_key(k), r, g, b of key k in its animation as the
--                OMX shows it; saver_field(x, y, along), r, g, b for a pad
--                at (x, y) on the screen's top 128x32 and `along` (0-1) the
--                controller, for controllers with a field of pads
--   held         a push-hold key or K1 is down
--   paged        a knob is off its first page
--   record       the switch is on Record
--   menu         CHOMPI's shift menu is open: its black keys are functions
--                and its white keys slots 1-15
--   meter_in, meter_out   levels, 0-1

local S = {}

S.kinds = {
  include("lib/surfaces/omx27"),
  include("lib/surfaces/exquis"),
}

-- Set by the script. k is a CHOMPI key 0-24, z 1 down or 0 up, knob 0-5
-- (Pitch, Start, End, Magic, Transport, Volume).
S.actions = {
  key = function(k, z) end,
  chompi = function(z) end,    -- the CHOMPI key
  play = function(z) end,
  loop = function(z) end,
  switch = function(on) end,   -- true for Record
  toggle_switch = function() end,
  turn = function(knob, d) end, -- relative, in detents
  push = function(knob, z) end,
  pot = function(knob, pos) end, -- absolute, 0-1, for controllers with fixed pots
  push_hold = function(who, held) end, -- a key that makes pots push their knobs
  touch = function() end,      -- anything played, for the screensaver
}

-- CHOMPI's keys, C3 to C5: k -> the firmware's switch id and key light.
-- White keys are switches 15, 8-11, 16-20, 24-28 and lights 34 down to 20;
-- black keys are 7, 12-14, 21-23, 29-31 and lights 10-19.
local WHITE = {[0] = 0, [2] = 1, [4] = 2, [5] = 3, [7] = 4, [9] = 5, [11] = 6}
local BLACK = {[1] = 0, [3] = 1, [6] = 2, [8] = 3, [10] = 4}
local WHITE_SW = {[0] = 15, 8, 9, 10, 11, 16, 17, 18, 19, 20, 24, 25, 26, 27, 28}
local BLACK_SW = {[0] = 7, 12, 13, 14, 21, 22, 23, 29, 30, 31}
S.KEY_SW, S.KEY_LED, S.IS_BLACK = {}, {}, {}
for k = 0, 24 do
  local oct, pc = k // 12, k % 12
  if WHITE[pc] then
    local w = oct * 7 + WHITE[pc]
    S.KEY_SW[k], S.KEY_LED[k] = WHITE_SW[w], 34 - w
  else
    local b = oct * 5 + BLACK[pc]
    S.KEY_SW[k], S.KEY_LED[k], S.IS_BLACK[k] = BLACK_SW[b], 10 + b, true
  end
end
S.CHOMPI_SW = 5

-- CHOMPI key -> OMX-27 key, as the screensaver animation (lib/saver.lua) is
-- drawn on the OMX's keys: the white keys are its bottom keys 12-26, the
-- black keys its top keys 1-10
S.KEY_OMX = {}
do
  local w, b = 0, 0
  for k = 0, 24 do
    if S.IS_BLACK[k] then S.KEY_OMX[k], b = 1 + b, b + 1
    else S.KEY_OMX[k], w = 12 + w, w + 1 end
  end
end

function S.connect_all()
  for _, kind in ipairs(S.kinds) do
    kind.actions = S.actions
    if not kind.connected() then kind.connect() end
  end
end

-- A MIDI device came or went (norns' midi.add and midi.remove).
function S.added(dev)
  for _, kind in ipairs(S.kinds) do
    if kind.match(dev.name) then
      clock.run(function()
        clock.sleep(0.5) -- let norns finish setting the port up
        kind.connect()
      end)
    end
  end
end

function S.removed(dev)
  for _, kind in ipairs(S.kinds) do
    if kind.match(dev.name) then kind.lost() end
  end
end

-- true for ports nidhogg uses as controllers, so they aren't offered for MIDI in
function S.is_surface(name)
  for _, kind in ipairs(S.kinds) do
    if kind.match(name) then return true end
  end
  return false
end

function S.frame(state)
  for _, kind in ipairs(S.kinds) do
    if kind.connected() then kind.frame(state) end
  end
end

-- whether any connected surface has a screen
function S.wants_screen()
  for _, kind in ipairs(S.kinds) do
    if kind.connected() and kind.screen_send then return true end
  end
  return false
end

function S.screen_send(x, y)
  for _, kind in ipairs(S.kinds) do
    if kind.connected() and kind.screen_send then kind.screen_send(x, y) end
  end
end

function S.refresh()
  for _, kind in ipairs(S.kinds) do
    if kind.connected() and kind.refresh then kind.refresh() end
  end
end

function S.disconnect()
  for _, kind in ipairs(S.kinds) do
    if kind.connected() then kind.disconnect() end
  end
end

return S
