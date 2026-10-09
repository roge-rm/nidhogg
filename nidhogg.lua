-- nidhogg
-- Chompi on norns
--
-- TAPE, TEMPO and WAVE: pick one
-- in PARAMS > firmware
-- played from an OMX-27 or an
-- Exquis (see the README)
-- K1 held + move a pot: push that
-- knob (next page)
-- K2 play, K3 loop
-- E1 play/record switch
-- E2 transport, E3 volume

engine.name = "Nidhogg"

local install = include("lib/install")
local surfaces = include("lib/surfaces")
local view = include("lib/view")
local saver = include("lib/saver")
local options = include("lib/options")
local modes = include("lib/modes")
local omxupdate = include("lib/omxupdate")
local library = include("lib/library")
local libui = include("lib/libraryui")

local M = modes.tape -- the firmware running now
local switch_firmware
-- set when the OMX-27's firmware is too old: {version, found, board, state}
local update_prompt = nil
local detent
local SW = {PLAY = 33, LOOP = 34}
local ENC = {TRANSPORT = 4, VOLUME = 5} -- hardware encoders SW5, SW6

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
    meter_in = 0, meter_out = 0, ticks = 0, playheads = {},
    omx_view = s and s.omx_view or "knobs", view_flash = nil,
  }
end
reset_state()

local function bank_color()
  local bank = M.bank_color_slot(s)
  if bank == nil then return PINK end
  return BANK_COLORS[bank] or BANK_COLORS[0]
end

-- K1 or a controller's push key held: moving a pot pushes its knob instead
-- of turning it. The push is released with the key, since Chompi acts on the
-- release.
local push_holds = {} -- which of K1 and the push keys are down
local k1_held = false -- either is held
local pot_from = {} -- pot position when the hold began, by knob
local pushing = {}  -- encoders pushed during this hold

local function send(path, args)
  osc.send({"127.0.0.1", M.port}, path, args)
end

-- A tap on PUSH (down and up quickly, no pot moved) steps the OMX screen's
-- default view.
local omx_push_down_at = 0

local function next_omx_view()
  local views = view.OMX_VIEWS
  local i = 1
  for n, v in ipairs(views) do if v == s.omx_view then i = n end end
  for _ = 1, #views do
    i = i % #views + 1
    local v = views[i]
    if (v ~= "window" or M.has_window) and (v ~= "beat" or M.bpm) then break end
  end
  s.omx_view = views[i]
  s.view_flash = util.time() + 0.8
end

local function push_hold(who, held)
  if who == "omx" then
    if held then
      omx_push_down_at = util.time()
    elseif next(pushing) == nil and util.time() - omx_push_down_at < 0.4 then
      next_omx_view()
    end
  end
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

-- Sticky points: a pot holds its knob exactly on a detent across a small
-- zone around it, and the rest of the travel stretches to still reach 0 and 1.
local DETENT_ZONE = 0.035

detent = function(knob, pos)
  local pages = M.detents and M.detents[knob]
  local points = pages and pages[s.knob_page[knob] or 0]
  if not points then return pos end
  -- knots of a piecewise-linear map from pot position to knob value
  local xs, ys = {0}, {0}
  for _, d in ipairs(points) do
    xs[#xs + 1] = d - DETENT_ZONE; ys[#ys + 1] = d
    xs[#xs + 1] = d + DETENT_ZONE; ys[#ys + 1] = d
  end
  xs[#xs + 1] = 1; ys[#ys + 1] = 1
  for i = 2, #xs do
    if pos <= xs[i] then
      local span = xs[i] - xs[i - 1]
      if span <= 0 then return ys[i] end
      return ys[i - 1] + (ys[i] - ys[i - 1]) * (pos - xs[i - 1]) / span
    end
  end
  return 1
end

-- What's played on any controller (lib/surfaces.lua).
local function start_surfaces()
  local a = surfaces.actions
  a.touch = function() saver.touch() end
  a.key = function(k, z) send("/key", {surfaces.KEY_SW[k], z}) end
  a.chompi = function(z) send("/key", {surfaces.CHOMPI_SW, z}) end
  a.play = function(z) send("/key", {SW.PLAY, z}) end
  a.loop = function(z) send("/key", {SW.LOOP, z}) end
  a.switch = function(on)
    s.record_switch = on
    send("/switch", {on and 1 or 0})
  end
  a.toggle_switch = function() a.switch(not s.record_switch) end
  a.turn = function(knob, d)
    if k1_held then
      -- a push key is held: turning a knob pushes it instead
      local enc = KNOB_TO_ENC[knob]
      if not pushing[enc] then
        pushing[enc] = true
        send("/push", {enc, 1})
      end
      return
    end
    send("/turn", {KNOB_TO_ENC[knob], d})
    focus(knob)
  end
  a.push = function(knob, z) send("/push", {KNOB_TO_ENC[knob], z}) end
  a.push_hold = function(who, held) push_hold(who, held) end
  a.pot = function(knob, raw)
    local pos = detent(knob, raw)
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
  surfaces.kinds[1].old_firmware = function(version)
    local found = omxupdate.find() or {}
    update_prompt = {version = version, found = found, board = found.board or "teensy40", state = "ask"}
  end
  surfaces.connect_all()

  -- plugged in later, or unplugged and plugged back in
  midi.add = function(dev) surfaces.added(dev) end
  -- norns also calls this again with no device, through the device's metatable
  midi.remove = function(dev)
    if dev then surfaces.removed(dev) end
  end
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

  params:add_trigger("import", "import samples")
  params:set_action("import", function() libui.open_import(modes.order[params:get("firmware")]) end)
  params:add_trigger("library", "sample library")
  params:set_action("library", function() libui.open_library(modes.order[params:get("firmware")]) end)

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
  surfaces.refresh()
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
  start_surfaces()
  library.watch(function() libui.open_import(modes.order[params:get("firmware")]) end, libui.removed)
  local notice = library.take_notice()
  if notice then libui.notice(notice) end
  running = true
  -- a reloaded script has none of the firmware's state yet
  clock.run(function()
    clock.sleep(0.5)
    send("/hello", {})
  end)
  -- what the controllers show, 15 times a second
  local function rgb(i)
    local r, g, b = leds:byte(i * 3 + 1, i * 3 + 3)
    return r or 0, g or 0, b or 0
  end
  local state = {
    key = function(k) return rgb(surfaces.KEY_LED[k]) end,
    light = rgb,
    is_black = function(k) return surfaces.IS_BLACK[k] == true end,
    saver_leds = function() return saver.leds(bank_color()) end,
    saver_field = function(x, y, along) return saver.field(bank_color(), x, y, along) end,
  }
  -- the screensaver as drawn on the OMX's keys, worked out once a frame
  local saver_frame = {}
  state.saver_key = function(k)
    local c = saver_frame[surfaces.KEY_OMX[k]]
    if not c then return 0, 0, 0 end
    return math.floor(c[1]), math.floor(c[2]), math.floor(c[3])
  end
  clock.run(function()
    while true do
      clock.sleep(1 / 15)
      state.saver = saver.active()
      if state.saver then saver_frame = saver.leds(bank_color()) end
      state.bank = bank_color()
      state.held = k1_held
      state.paged = false
      for k = 0, 5 do
        if (s.knob_page[k] or 0) > 0 then state.paged = true end
      end
      state.record = s.record_switch
      state.menu = s.menu
      state.meter_in, state.meter_out = s.meter_in, s.meter_out
      state.volume = s.knob_value[5] or 0
      surfaces.frame(state)
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
  surfaces.disconnect()
  library.unmount()
end

function osc.event(path, args, from)
  if path == "/leds" then
    -- a key light turning white is a note starting: the dragon chomps
    local new = args[1]
    for i = 10, 34 do
      local was = leds:byte(i * 3 + 1) or 0
      local now = new:byte(i * 3 + 1) or 0
      if now > 200 and was <= 200 and (new:byte(i * 3 + 2) or 0) > 200 then
        view.mascot.note()
        break
      end
    end
    leds = new
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
  elseif path == "/meter" then
    s.meter_in, s.meter_out = args[1], args[2]
  elseif path == "/clock" then
    s.ticks = args[1]
  elseif path == "/play" then
    s.playheads = args
  elseif path == "/load" then
    load_avg, load_max = args[1], args[2]
  end
end

local function update_key(n, z)
  if z == 0 then return end
  local u = update_prompt
  if u.state == "ask" then
    if n == 3 then
      u.state = "updating"
      local found = {board = u.board, tty = u.found.tty}
      omxupdate.start(found, function(ok)
        u.state = ok and "done" or "failed"
        if ok then
          clock.run(function()
            clock.sleep(3)
            if update_prompt == u then update_prompt = nil end
          end)
        end
      end)
    elseif n == 2 then
      update_prompt = nil
    end
  elseif u.state == "failed" or u.state == "done" then
    update_prompt = nil
  end
end

function key(n, z)
  saver.touch()
  if libui.active() then
    libui.key(n, z)
    return
  end
  if update_prompt then
    update_key(n, z)
    return
  end
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
  if libui.active() then
    libui.enc(n, d)
    return
  end
  if update_prompt then
    -- a Teensy's model, in case the guess is wrong
    local u = update_prompt
    if u.state == "ask" and u.found.teensy and n == 2 then
      u.board = d > 0 and "teensy40" or "teensy32"
    end
    return
  end
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
  if libui.active() then
    libui.draw()
    screen.update()
    return
  end
  if update_prompt then
    local u = update_prompt
    local names = {rp2040 = "RP2040 (v3)", teensy40 = "Teensy 4.0 (v2)", teensy32 = "Teensy 3.2 (v1)"}
    screen.level(15)
    screen.move(64, 10)
    screen.text_center("OMX-27 firmware")
    screen.level(8)
    screen.move(64, 21)
    if u.version then
      screen.text_center(string.format("is %d.%d.%d, needs 1.15.4", u.version[1], u.version[2], u.version[3]))
    else
      screen.text_center("didn't answer, may be too old")
    end
    screen.move(64, 31)
    screen.text_center(names[u.board] .. (u.found.teensy and u.state == "ask" and "  (E2)" or ""))
    screen.level(15)
    screen.move(64, 46)
    if u.state == "ask" then
      screen.text_center("K3 update    K2 skip")
      screen.level(5)
      screen.move(64, 58)
      screen.text_center("clears its saved patterns")
    elseif u.state == "updating" then
      screen.text_center(omxupdate.status or "updating")
    elseif u.state == "done" then
      screen.text_center("updated")
    else
      screen.text_center("update failed")
      screen.level(5)
      screen.move(64, 58)
      screen.text_center("see data/nidhogg/omx-update/log")
    end
    screen.update()
    return
  end

  -- A controller's screen (the OMX-27's) is drawn first and copied off with
  -- screen.peek; only what's drawn after the clear reaches the norns screen.
  local small = surfaces.wants_screen()
  if saver.active() then
    if small then
      saver.draw()
      surfaces.screen_send(0, 0)
      screen.clear()
    end
    saver.draw()
  else
    if small then
      view.omx(s, M)
      surfaces.screen_send(0, 0)
      screen.clear()
    end
    local left = saver.remaining()
    local sleepy = left < 20 and util.clamp(1 - left / 20, 0, 1) or 0
    view.norns(s, M, leds, sleepy)
  end
  screen.update()
end
