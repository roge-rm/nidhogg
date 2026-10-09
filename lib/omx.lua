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

-- screen: one frame in flight; the OMX acks each frame with 52 04
local frame_pending = false
local frame_sent_at = 0
local KEEP_ALIVE = 30 -- seconds; the OMX's own screensaver starts after 3 min without a frame
local last_chunks = {}

local function send(cmd, payload)
  local m = {table.unpack(HEAD)}
  m[#m + 1] = cmd
  for _, b in ipairs(payload or {}) do m[#m + 1] = b end
  m[#m + 1] = 0xF7
  dev:send(m)
end

local function handle(m)
  -- m is a whole sysex message, F0 to F7
  if #m < 7 or m[2] ~= 0x7D then return end
  if m[5] == 0x52 then
    if m[6] == 0x04 then frame_pending = false end
    return
  end
  if m[5] ~= 0x51 then return end
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
      last_chunks = {}
      frame_pending = false
      return true
    end
  end
  return false
end

-- True if a device name is an OMX-27 (any board).
function omx.is_omx(name)
  return name ~= nil and name:find("omx%-27") ~= nil
end

-- The OMX-27 was unplugged: forget it without sending anything.
function omx.lost()
  if dev then dev.event = nil end
  dev = nil
  frame_pending = false
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

-- 8 bytes for every 7: a byte of high bits, then the 7 bytes' low 7 bits.
local function enc7(data)
  local out = {}
  for i = 1, #data, 7 do
    local hi, n = 0, #out + 1
    out[n] = 0
    for j = 0, 6 do
      local b = data[i + j]
      if b == nil then break end
      hi = hi | (((b >> 7) & 1) << j)
      out[#out + 1] = b & 0x7F
    end
    out[n] = hi
  end
  return out
end

-- Makes the next screen_send send the whole frame, not just what changed.
function omx.screen_refresh()
  last_chunks = {}
end

-- Sends the 128x32 region of the norns screen at (x, y) to the OMX screen.
-- Pixels at level 8 or above are lit. Returns false if the last frame isn't
-- shown yet, so drawing can never run ahead of the OMX.
function omx.screen_send(x, y)
  if not dev then return false end
  if frame_pending and util.time() - frame_sent_at < 0.25 then return false end
  local px = screen.peek(x or 0, y or 0, 128, 32)
  if not px then return false end
  -- SSD1306 pages, turned 180 degrees as the panel is mounted
  local fb = {}
  for i = 1, 512 do fb[i] = 0 end
  for yy = 0, 31 do
    local row = yy * 128
    for xx = 0, 127 do
      if px:byte(row + xx + 1) >= 8 then
        local rx, ry = 127 - xx, 31 - yy
        local i = rx + (ry >> 3) * 128 + 1
        fb[i] = fb[i] | (1 << (ry & 7))
      end
    end
  end
  local any = false
  for c = 0, 15 do
    local chunk, same = {}, last_chunks[c] ~= nil
    for i = 1, 32 do
      chunk[i] = fb[c * 32 + i]
      if same and last_chunks[c][i] ~= chunk[i] then same = false end
    end
    if not same then
      local payload = {c}
      for _, b in ipairs(enc7(chunk)) do payload[#payload + 1] = b end
      send(0x5C, payload)
      last_chunks[c] = chunk
      any = true
    end
  end
  if any or util.time() - frame_sent_at > KEEP_ALIVE then
    send(0x5D)
    frame_pending = true
    frame_sent_at = util.time()
  end
  return true
end

return omx
