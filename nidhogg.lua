-- nidhogg
-- Chompi on norns
--
-- test build: TAPE only
-- K2 play, K3 loop
-- E1 play/record switch
-- E2 transport, E3 volume

engine.name = "Nidhogg"

local install = include("lib/install")

local OSC_PORT = 57140 -- TAPE
local SW = {PLAY = 33, LOOP = 34}
local ENC = {TRANSPORT = 4, VOLUME = 5} -- hardware encoders SW5, SW6

local leds = string.rep("\0", 105)
local recording = false
local needs_restart = false
local load_avg, load_max = 0, 0

local function send(path, args)
  osc.send({"127.0.0.1", OSC_PORT}, path, args)
end

function init()
  needs_restart = install.plugins()
  if needs_restart then
    redraw()
    return
  end
  engine.start("tape")
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      redraw()
    end
  end)
end

function osc.event(path, args, from)
  if path == "/leds" then
    leds = args[1]
  elseif path == "/load" then
    load_avg, load_max = args[1], args[2]
  end
end

function key(n, z)
  if n == 2 then
    send("/key", {SW.PLAY, z})
  elseif n == 3 then
    send("/key", {SW.LOOP, z})
  end
end

function enc(n, d)
  if n == 1 then
    recording = d > 0
    send("/switch", {recording and 1 or 0})
  elseif n == 2 then
    send("/turn", {ENC.TRANSPORT, d})
  elseif n == 3 then
    send("/turn", {ENC.VOLUME, d})
  end
end

-- Screen level for an LED colour: the brightest channel, 0-15.
local function level(i)
  local r, g, b = leds:byte(i * 3 + 1, i * 3 + 3)
  return math.floor(math.max(r or 0, g or 0, b or 0) / 17)
end

function redraw()
  screen.clear()
  if needs_restart then
    screen.level(15)
    screen.move(64, 28)
    screen.text_center("nidhogg installed its engine.")
    screen.move(64, 40)
    screen.text_center("restart norns to use it.")
    screen.update()
    return
  end
  -- 10 panel LEDs along the top
  for i = 0, 9 do
    screen.level(level(i))
    screen.circle(8 + i * 12, 10, 4)
    screen.fill()
  end
  -- 25 key LEDs in Chompi's order
  for i = 0, 24 do
    screen.level(level(10 + i))
    screen.rect(2 + i * 5, 40, 4, 8)
    screen.fill()
  end
  screen.level(4)
  screen.move(0, 62)
  screen.text(recording and "record" or "play")
  screen.move(127, 62)
  screen.text_right(string.format("dsp %.0f%% / %.0f%%", load_avg, load_max))
  screen.update()
end
