-- OMX-27 in REMOTE mode (Quixotic7 firmware 1.15.4 and later). The script
-- gets every key, the encoder, its button and the pots, and sets the 27 key
-- LEDs. Protocol: SYSEX_SPEC.md "REMOTE mode" in github.com/Quixotic7/OMX-27.

local omx = {}

local HEAD = {0xF0, 0x7D, 0x00, 0x00}
local MODE_MI, MODE_REMOTE = 0, 9
local EVENTS = {[0] = "up", "down", "hold", "quick"}

-- callbacks, set by the script
omx.key = function(n, ev) end -- n 0-26 (0 is AUX), ev "down" "up" "hold" "quick"
omx.enc = function(d) end
omx.enc_btn = function(z) end
omx.pot = function(n, v, hires) end -- n 0-4, v 0-127, hires 0-16383

local dev
local rx = {}
local leds, shown = {}, {}

local function send(cmd, payload)
  local m = {table.unpack(HEAD)}
  m[#m + 1] = cmd
  for _, b in ipairs(payload or {}) do m[#m + 1] = b end
  m[#m + 1] = 0xF7
  dev:send(m)
end

local function handle(m)
  -- m is a whole sysex message, F0 to F7
  if #m < 7 or m[2] ~= 0x7D or m[5] ~= 0x51 then return end
  local kind = m[6]
  if kind == 0x00 then
    omx.key(m[7], EVENTS[m[8]])
  elseif kind == 0x01 then
    omx.enc((m[7] == 2 and 1 or -1) * m[8])
  elseif kind == 0x02 then
    omx.enc_btn(m[7])
  elseif kind == 0x03 then
    omx.pot(m[7], m[8], (m[9] << 7) | m[10])
  end
end

local function on_midi(data)
  -- matron hands sysex over in pieces; put whole messages back together
  for _, b in ipairs(data) do
    if b == 0xF0 then
      rx = {b}
    elseif #rx > 0 then
      rx[#rx + 1] = b
      if b == 0xF7 then
        handle(rx)
        rx = {}
      end
    end
  end
end

function omx.connect()
  for i, v in pairs(midi.vports) do
    if v.name and v.name:find("omx%-27") then
      dev = midi.connect(i)
      dev.event = on_midi
      send(0x51, {0x05, MODE_REMOTE})
      for n = 0, 26 do leds[n] = {0, 0, 0}; shown[n] = {-1, -1, -1} end
      return true
    end
  end
  return false
end

function omx.disconnect()
  if dev then
    send(0x51, {0x05, MODE_MI})
    dev.event = nil
    dev = nil
  end
end

-- r, g, b 0-255
function omx.led(n, r, g, b)
  leds[n] = {r >> 1, g >> 1, b >> 1}
end

-- Sends the LEDs that changed since the last call.
function omx.led_show()
  if not dev then return end
  local payload, any = {0, 27}, false
  for n = 0, 26 do
    local c, s = leds[n], shown[n]
    if c[1] ~= s[1] or c[2] ~= s[2] or c[3] ~= s[3] then any = true end
    payload[#payload + 1] = c[1]
    payload[#payload + 1] = c[2]
    payload[#payload + 1] = c[3]
  end
  if not any then return end
  send(0x5A, payload)
  send(0x5B)
  for n = 0, 26 do shown[n] = {leds[n][1], leds[n][2], leds[n][3]} end
end

return omx
