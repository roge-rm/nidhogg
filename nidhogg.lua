-- nidhogg
-- Chompi on norns
--
-- TAPE, TEMPO and WAVE: pick one
-- in PARAMS > firmware
-- OMX-27 in REMOTE mode: keys,
-- AUX = CHOMPI, encoder = transport,
-- pots = pitch start end magic volume
-- (a pot takes over once it passes
-- the knob's value)
-- K1 or the OMX's leftmost bottom key
-- held + move a pot: push that knob
-- (next page)
-- K2 play, K3 loop
-- E1 play/record switch
-- E2 transport, E3 volume

engine.name = "Nidhogg"

local install = include("lib/install")
local omx = include("lib/omx")
local view = include("lib/view")
local saver = include("lib/saver")
local options = include("lib/options")
local modes = include("lib/modes")

local M = modes.tape -- the firmware running now
local switch_firmware
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
local pot_anchor = {} -- pot position when it last woke the screensaver, by knob
-- Chompi knob -> hardware encoder, for pushes:
-- Pitch SW4, Start SW1, End SW2, Magic SW3, Transport SW5, Volume SW6
local KNOB_TO_ENC = {[0] = 3, 0, 1, 2, 4, 5}

local leds = string.rep("\0", 105)

-- Chompi's bank colours (NormalPage.h): purple, orange, teal, dark orange,
-- yellow-green; pink for the RAM slot in JAMMI.
local BANK_COLORS = {
  [0] = {148, 13, 255}, {255, 153, 61}, {36, 255, 235}, {196, 97, 15}, {180, 255, 0},
}
local PINK = {255, 92, 158}


local running = false -- true once the firmware is going
local load_avg, load_max = 0, 0

-- Firmware state from the bridge, plus what the screens need to know here.
local s
local function reset_state()
  s = {
    knob_page = {}, knob_value = {}, picked = {}, pot = {},
    menu = false, st = {}, looper_pos = 0, dub = 1, record_switch = false,
    focus = nil, focus_time = 0,
  }
end
reset_state()

local function bank_color()
  local bank = M.bank_color_slot(s)
  if bank == nil then return PINK end
  return BANK_COLORS[bank] or BANK_COLORS[0]
end

-- K1 or OMX key 11 held: moving a pot pushes its knob instead of turning it.
-- The push is released with the key, since Chompi acts on the release.
local OMX_PUSH_KEY = 11
local push_holds = {} -- which of K1 and the OMX key are down
local k1_held = false -- either is held
local pot_from = {} -- pot position when the hold began, by knob
local pushing = {}  -- encoders pushed during this hold

local function send(path, args)
  osc.send({"127.0.0.1", M.port}, path, args)
end

local function push_hold(who, held)
  push_holds[who] = held or nil
  local any = next(push_holds) ~= nil
  if any and not k1_held then
    for k, pos in pairs(s.pot) do pot_from[k] = pos end
  elseif not any and k1_held then
    for enc in pairs(pushing) do send("/push", {enc, 0}) end
    pushing = {}
    pot_from = {}
  end
  k1_held = any
end

local function focus(knob)
  s.focus = knob
  s.focus_time = util.time()
end

-- OMX-27 key that shows each Chompi key light: AUX shows the CHOMPI light.
local function omx_led_source(n)
  if n == 0 then return 0 end -- panel light 0
  if n >= 1 and n <= 10 then return 10 + (n - 1) end -- black keys: lights 0-9
  if n >= 12 then return 10 + (25 - (n - 11)) end -- white keys: lights 24-10
  return nil
end

local function start_omx()
  omx.key = function(n, ev)
    saver.touch()
    if n == OMX_PUSH_KEY then
      if ev == "down" then push_hold("omx", true)
      elseif ev == "up" then push_hold("omx", false) end
      return
    end
    local sw = OMX_TO_SW[n]
    if not sw then return end
    if ev == "down" then send("/key", {sw, 1})
    elseif ev == "up" then send("/key", {sw, 0}) end
  end
  omx.enc = function(d)
    saver.touch()
    send("/turn", {ENC.TRANSPORT, d})
    focus(4)
  end
  omx.enc_btn = function(z)
    saver.touch()
    send("/push", {ENC.TRANSPORT, z})
  end
  omx.pot = function(n, v, hires)
    local knob = POT_TO_KNOB[n]
    local pos = hires / 16383
    -- a jittering pot shouldn't keep the screensaver away: only count it once
    -- it has moved 1% from where it last counted
    if not pot_anchor[knob] or math.abs(pos - pot_anchor[knob]) > 0.01 then
      pot_anchor[knob] = pos
      saver.touch()
    end
    s.pot[knob] = pos
    if k1_held then
      local enc = KNOB_TO_ENC[knob]
      pot_from[knob] = pot_from[knob] or pos
      if not pushing[enc] and math.abs(pos - pot_from[knob]) > 0.03 then
        pushing[enc] = true
        send("/push", {enc, 1})
      end
      return
    end
    send("/pot", {knob, pos})
    focus(knob)
  end
  omx.connect()
end

local SAVER_TIMES = {60, 180, 600, math.huge}

-- MIDI: Chompi's MIDI out goes to a norns MIDI device, and notes and CCs from
-- another device go to Chompi as if from its USB port.
local midi_out_dev, midi_in_dev

local function midi_devices()
  local names = {"none"}
  for i = 1, #midi.vports do names[#names + 1] = midi.vports[i].name end
  return names
end

-- nidhogg's own settings, kept between runs. Chompi's options live in each
-- card's options.json instead, as on the hardware.
local SETTINGS_FILE = _path.data .. "nidhogg/settings.lua"
local SAVED = {"firmware", "saver", "midi_out", "midi_in"}

local function save_settings()
  local t = {}
  for _, id in ipairs(SAVED) do t[id] = params:get(id) end
  tab.save(t, SETTINGS_FILE)
end

local function load_settings()
  local t = tab.load(SETTINGS_FILE)
  if not t then return end
  for _, id in ipairs(SAVED) do
    if t[id] then params:set(id, t[id], true) end
  end
end

local function add_params()
  params:add_separator("nidhogg", "nidhogg")
  params:add_option("saver", "screensaver after", {"1 min", "3 min", "10 min", "off"}, 2)
  params:set_action("saver", function(i) saver.delay = SAVER_TIMES[i] end)

  local devs = midi_devices()
  params:add_option("midi_out", "midi out to", devs, 1)
  params:set_action("midi_out", function(i)
    midi_out_dev = i > 1 and midi.connect(i - 1) or nil
  end)
  params:add_option("midi_in", "midi in from", devs, 1)
  params:set_action("midi_in", function(i)
    if midi_in_dev then midi_in_dev.event = nil end
    midi_in_dev = i > 1 and midi.connect(i - 1) or nil
    if midi_in_dev then
      midi_in_dev.event = function(data)
        local msg = {"usb"}
        for _, b in ipairs(data) do msg[#msg + 1] = b end
        send("/midi", msg)
      end
    end
  end)

  params:add_option("firmware", "firmware", {"TAPE", "TEMPO", "WAVE"}, 1)
  params:set_action("firmware", function(i)
    if running then switch_firmware(modes.order[i]) end
  end)

  for _, fw in ipairs(modes.order) do
    options.add_params(fw, install.card_dir(fw))
  end

  load_settings()
  for _, id in ipairs(SAVED) do
    local action = params:lookup_param(id).action
    params:set_action(id, function(v)
      action(v)
      save_settings()
    end)
  end
  -- apply the loaded MIDI devices
  params:lookup_param("midi_out"):bang()
  params:lookup_param("midi_in"):bang()
end

-- Switches to another firmware. The one left behind pauses, keeping its
-- state, and carries on when chosen again.
switch_firmware = function(fw)
  M = modes[fw]
  reset_state()
  omx.screen_refresh()
  engine.start(fw)
  send("/switch", {0})
  clock.run(function()
    clock.sleep(0.3)
    send("/hello", {})
  end)
end

-- Runs the firmware once everything is in place.
local function start()
  M = modes[modes.order[params:get("firmware")]]
  engine.start(modes.order[params:get("firmware")])
  start_omx()
  running = true
  -- a reloaded script has none of the firmware's state yet
  clock.run(function()
    clock.sleep(0.5)
    send("/hello", {})
  end)
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      if saver.active() then
        for n, c in pairs(saver.leds(bank_color())) do
          omx.led(n, math.floor(c[1]), math.floor(c[2]), math.floor(c[3]))
        end
      else
        for n = 0, 26 do
          local i = omx_led_source(n)
          if i then
            local r, g, b = leds:byte(i * 3 + 1, i * 3 + 3)
            omx.led(n, r or 0, g or 0, b or 0)
          end
        end
        -- the push key: white while held, amber when a knob is off its first
        -- page, else dim
        local paged = false
        for k = 0, 5 do
          if (s.knob_page[k] or 0) > 0 then paged = true end
        end
        if k1_held then omx.led(OMX_PUSH_KEY, 255, 255, 255)
        elseif paged then omx.led(OMX_PUSH_KEY, 255, 120, 0)
        else omx.led(OMX_PUSH_KEY, 24, 24, 24) end
      end
      omx.led_show()
      redraw()
    end
  end)
end

-- Plugins next: a new or changed one needs SuperCollider restarted, as does
-- a first install, where SuperCollider hasn't seen the engine yet.
local function install_plugins()
  local changed = install.plugins()
  if changed or not tab.contains(engine.names or {}, "Nidhogg") then
    install.status = "restarting norns to load nidhogg"
    redraw()
    clock.run(function()
      clock.sleep(2)
      install.restart()
    end)
    return
  end
  start()
end

function init()
  add_params()
  saver.delay = SAVER_TIMES[params:get("saver")]

  clock.run(function()
    while not running do
      redraw()
      clock.sleep(0.25)
    end
  end)

  if not install.have_cards() then
    install.fetch_cards(function(ok)
      if ok then
        install_plugins()
      else
        install.status = "couldn't download the samples. check wifi, then reload nidhogg."
      end
    end)
  else
    install_plugins()
  end
end

function cleanup()
  omx.disconnect()
end

function osc.event(path, args, from)
  if path == "/leds" then
    leds = args[1]
  elseif path == "/knob" then
    local k = args[1]
    local changed = s.knob_page[k] ~= nil
      and (s.knob_page[k] ~= args[2] or math.abs(s.knob_value[k] - args[3]) > 0.001)
    s.knob_page[k], s.knob_value[k] = args[2], args[3]
    if changed and s.focus == k then s.focus_time = util.time() end
  elseif path == "/pickup" then
    s.picked[args[1]] = args[2] == 1
  elseif path == "/state" then
    s.menu = args[1] == 1
    for i = 1, 10 do s.st[i] = args[i + 1] end
  elseif path == "/looper" then
    s.looper_pos, s.dub = args[1], args[2]
  elseif path == "/midi" then
    -- Chompi sends the same to its TRS and USB ports; pass one stream on.
    if args[1] == "usb" and midi_out_dev then
      local bytes = args[2]
      local data = {}
      for k = 1, #bytes do data[k] = bytes:byte(k) end
      midi_out_dev:send(data)
    end
  elseif path == "/load" then
    load_avg, load_max = args[1], args[2]
  end
end

function key(n, z)
  saver.touch()
  if n == 1 then
    push_hold("k1", z == 1)
  elseif n == 2 then
    send("/key", {SW.PLAY, z})
  elseif n == 3 then
    send("/key", {SW.LOOP, z})
  end
end

function enc(n, d)
  saver.touch()
  if n == 1 then
    s.record_switch = d > 0
    send("/switch", {s.record_switch and 1 or 0})
  elseif n == 2 then
    send("/turn", {ENC.TRANSPORT, d})
    focus(4)
  elseif n == 3 then
    send("/turn", {ENC.VOLUME, d})
    focus(5)
  end
end

function redraw()
  screen.clear()
  screen.font_face(1)
  screen.font_size(8)
  if not running then
    screen.level(15)
    screen.move(64, 24)
    screen.text_center("nidhogg")
    screen.level(6)
    local msg = install.status or "starting"
    -- wrap long messages over two lines
    local cut = #msg > 30 and (msg:sub(1, 30):match(".*() ") or 30) or nil
    screen.move(64, 40)
    screen.text_center(cut and msg:sub(1, cut - 1) or msg)
    if cut then
      screen.move(64, 50)
      screen.text_center(msg:sub(cut + 1))
    end
    screen.update()
    return
  end
  -- The OMX-27 frame is drawn first and copied off with screen.peek; only
  -- what's drawn after the second clear reaches the norns screen.
  if saver.active() then
    saver.draw()
    omx.screen_send(0, 0)
    screen.clear()
    saver.draw()
  else
    view.omx(s, M)
    omx.screen_send(0, 0)
    screen.clear()
    view.info(s, M)
    view.panel(leds)
  end
  screen.update()
end
