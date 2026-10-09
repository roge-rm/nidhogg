-- The OMX-27 in REMOTE mode (lib/omx.lua), as a surface.
--   bottom keys 12-26   CHOMPI's white keys, C3 to C5
--   top keys 1-10       its black keys
--   AUX (0)             the CHOMPI key
--   key 11              PUSH: hold and move a pot to push that knob; a tap
--                       steps the OMX screen's view
--   pots 0-4            Pitch, Start, End, Magic, Volume
--   encoder             Transport, push for normal speed

local omx = include("lib/omx")

local surf = {name = "OMX-27"}
surf.actions = nil -- set by lib/surfaces.lua
surf.old_firmware = function(version) end -- set by the script

local PUSH_KEY = 11
local POT_TO_KNOB = {[0] = 0, 1, 2, 3, 5}

-- OMX key <-> CHOMPI key (0-24)
local KEY_OF, OMX_OF = {}, {}
do
  local w, b = 0, 0
  for k = 0, 24 do
    local pc = k % 12
    if pc == 1 or pc == 3 or pc == 6 or pc == 8 or pc == 10 then
      KEY_OF[1 + b], OMX_OF[k] = k, 1 + b
      b = b + 1
    else
      KEY_OF[12 + w], OMX_OF[k] = k, 12 + w
      w = w + 1
    end
  end
end

surf.match = omx.is_omx
surf.lost = omx.lost
surf.disconnect = omx.disconnect
surf.refresh = omx.screen_refresh
surf.screen_send = omx.screen_send
function surf.connected() return omx.port_open() end

function surf.connect()
  local a = surf.actions
  omx.key = function(n, ev)
    a.touch()
    local z = ev == "down" and 1 or (ev == "up" and 0 or nil)
    if z == nil then return end
    if n == PUSH_KEY then
      a.push_hold("omx", z == 1)
    elseif n == 0 then
      a.chompi(z)
    elseif KEY_OF[n] then
      a.key(KEY_OF[n], z)
    end
  end
  omx.enc = function(d)
    a.touch()
    a.turn(4, d)
  end
  omx.enc_btn = function(z)
    a.touch()
    a.push(4, z)
  end
  omx.pot = function(n, v, hires)
    a.pot(POT_TO_KNOB[n], hires / 16383)
  end
  omx.old_firmware = function(version) surf.old_firmware(version) end
  return omx.connect()
end

function surf.frame(st)
  if st.saver then
    for n, c in pairs(st.saver_leds()) do
      omx.led(n, math.floor(c[1]), math.floor(c[2]), math.floor(c[3]))
    end
  else
    omx.led(0, st.light(0))
    for k = 0, 24 do omx.led(OMX_OF[k], st.key(k)) end
    -- PUSH: white while held, amber when a knob is off its first page, else dim
    if st.held then omx.led(PUSH_KEY, 255, 255, 255)
    elseif st.paged then omx.led(PUSH_KEY, 255, 120, 0)
    else omx.led(PUSH_KEY, 24, 24, 24) end
  end
  omx.led_show()
end

return surf
