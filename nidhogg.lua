-- nidhogg
-- Chompi on norns
--
-- test build: TAPE only
-- OMX-27 in REMOTE mode: keys,
-- AUX = CHOMPI, encoder = transport,
-- pots = pitch start end magic volume
-- (a pot takes over once it passes
-- the knob's value)
-- K2 play, K3 loop
-- E1 play/record switch
-- E2 transport, E3 volume

engine.name = "Nidhogg"

local install = include("lib/install")
local omx = include("lib/omx")

local OSC_PORT = 57140 -- TAPE
local SW = {PLAY = 33, LOOP = 34}
local ENC = {TRANSPORT = 4, VOLUME = 5} -- hardware encoders SW5, SW6

-- OMX-27 key -> Chompi switch id (Hardware::SwId). Bottom keys 12-26 are
-- Chompi's white keys C3-C5, top keys 1-10 its black keys, AUX the CHOMPI key.
local OMX_TO_SW = {
  [0] = 5,
  [1] = 7, [2] = 12, [3] = 13, [4] = 14, [5] = 21,
  [6] = 22, [7] = 23, [8] = 29, [9] = 30, [10] = 31,
  [12] = 15, [13] = 8, [14] = 9, [15] = 10, [16] = 11, [17] = 16, [18] = 17,
  [19] = 18, [20] = 19, [21] = 20, [22] = 24, [23] = 25, [24] = 26, [25] = 27,
  [26] = 28,
}
-- OMX pot -> Chompi knob: Pitch 0, Start 1, End 2, Magic 3, Volume 5
local POT_TO_KNOB = {[0] = 0, 1, 2, 3, 5}

-- Chompi key LED (0-24) for an OMX key, and AUX shows the CHOMPI LED.
local function omx_led_source(n)
  if n == 0 then return 0 end -- panel LED 0
  if n >= 1 and n <= 10 then return 10 + (n - 1) end -- black keys: SMT 0-9
  if n >= 12 then return 10 + (25 - (n - 11)) end -- white keys: SMT 24-10
  return nil
end

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

  omx.key = function(n, ev)
    local sw = OMX_TO_SW[n]
    if not sw then return end
    if ev == "down" then send("/key", {sw, 1})
    elseif ev == "up" then send("/key", {sw, 0}) end
  end
  omx.enc = function(d) send("/turn", {ENC.TRANSPORT, d}) end
  omx.enc_btn = function(z) send("/push", {ENC.TRANSPORT, z}) end
  omx.pot = function(n, v, hires)
    send("/pot", {POT_TO_KNOB[n], hires / 16383})
  end
  omx.connect()

  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      for n = 0, 26 do
        local i = omx_led_source(n)
        if i then
          local r, g, b = leds:byte(i * 3 + 1, i * 3 + 3)
          omx.led(n, r or 0, g or 0, b or 0)
        end
      end
      omx.led_show()
      redraw()
    end
  end)
end

function cleanup()
  omx.disconnect()
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
