-- Updating an OMX-27 to Quixotic7's firmware from the norns, for units whose
-- firmware is too old for REMOTE mode. Works out which board it is, fetches
-- the latest release, and flashes it:
-- - RP2040 (v3): the 1200-baud reset into its USB bootloader, then the .uf2
--   copied onto the drive that appears.
-- - Teensy 3.2 (v1) and 4.0 (v2): the 134-baud reset into the Teensy
--   bootloader, then teensy_loader_cli (installed with apt if missing). If
--   the reset doesn't take, pressing the Teensy's button does the same.
-- Updating clears the OMX-27's saved patterns and settings.

local up = {}

up.MIN = {1, 15, 4}
local RELEASES = "https://api.github.com/repos/Quixotic7/OMX-27/releases/latest"
-- used if the latest release can't be read
local FALLBACK = "https://github.com/Quixotic7/OMX-27/releases/download/v1.15.7/OMX-27-1.15.7-"
local ASSETS = {rp2040 = "RP2040_FormSeq.uf2", teensy40 = "T4_FormSeq.hex", teensy32 = "T31_FormSeq.hex"}
local MCU = {teensy40 = "TEENSY40", teensy32 = "TEENSY31"}
local WORK = _path.data .. "nidhogg/omx-update"

up.status = nil -- progress text while updating

function up.new_enough(v)
  if not v then return false end
  for i = 1, 3 do
    if v[i] ~= up.MIN[i] then return v[i] > up.MIN[i] end
  end
  return true
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("l")
  f:close()
  return s
end

-- The OMX-27 on USB: {board = "rp2040" | "teensy40" | "teensy32" | nil, tty}.
-- A Teensy's model comes from its bcdDevice (Teensyduino: 0x0275 for 3.2,
-- 0x0280 for 4.0).
function up.find()
  local p = io.popen("ls -d /sys/bus/usb/devices/*-* 2>/dev/null")
  local list = p:read("a")
  p:close()
  for d in list:gmatch("[^\n]+") do
    local vendor = read(d .. "/idVendor")
    local product = read(d .. "/product") or ""
    local board
    if vendor == "2e8a" and product:lower():find("omx") then
      board = "rp2040"
    elseif vendor == "16c0" then
      local bcd = read(d .. "/bcdDevice") or ""
      board = bcd == "0275" and "teensy32" or "teensy40"
      if bcd ~= "0275" and bcd ~= "0280" then board = nil end
    end
    if vendor == "2e8a" or vendor == "16c0" then
      local t = io.popen("ls " .. d .. "/*/tty 2>/dev/null")
      local tty = t:read("l")
      t:close()
      return {board = board, tty = tty and ("/dev/" .. tty) or nil, teensy = vendor == "16c0"}
    end
  end
  return nil
end

-- Flashes `board` in the background and calls done(ok) when finished.
function up.start(found, done)
  local board = found.board
  local status = WORK .. "/status"
  local marker = WORK .. "/done"
  local asset = ASSETS[board]
  local file = board == "rp2040" and "fw.uf2" or "fw.hex"
  local lines = {
    "set -e",
    "say() { echo \"$1\" > '" .. status .. "'; }",
    "cd '" .. WORK .. "'",
    "say 'getting the firmware'",
    "url=$(curl -sL '" .. RELEASES .. "' | grep -o 'https://[^\"]*" .. asset .. "' | head -1)",
    "[ -n \"$url\" ] || url='" .. FALLBACK .. asset .. "'",
    "curl -sfL -o " .. file .. " \"$url\"",
  }
  if board == "rp2040" then
    for _, l in ipairs({
      "say 'restarting the OMX-27'",
      "stty -F " .. found.tty .. " 1200 && python3 -c \"open('" .. found.tty .. "','rb',buffering=0).close()\" || true",
      "for i in $(seq 1 40); do [ -e /dev/disk/by-label/RPI-RP2 ] && break; sleep 0.5; done",
      "[ -e /dev/disk/by-label/RPI-RP2 ] || { say 'hold BOOTSEL on the OMX-27 while plugging it in'; for i in $(seq 1 120); do [ -e /dev/disk/by-label/RPI-RP2 ] && break; sleep 0.5; done; }",
      "say 'writing the firmware'",
      "sudo mkdir -p /mnt/omx27",
      "sudo mount /dev/disk/by-label/RPI-RP2 /mnt/omx27",
      "sudo cp " .. file .. " /mnt/omx27/ && sync",
      "sudo umount /mnt/omx27 || true",
    }) do lines[#lines + 1] = l end
  else
    for _, l in ipairs({
      "command -v teensy_loader_cli > /dev/null || { say 'installing the Teensy loader'; sudo apt-get install -y teensy-loader-cli > /dev/null 2>&1 || { sudo apt-get update > /dev/null && sudo apt-get install -y teensy-loader-cli > /dev/null; }; }",
      "say 'restarting the OMX-27'",
      (found.tty and ("stty -F " .. found.tty .. " 134 || true") or "true"),
      "say 'writing the firmware (press the Teensy button if this waits)'",
      "sudo teensy_loader_cli --mcu=" .. MCU[board] .. " -w -v " .. file .. " > /dev/null",
    }) do lines[#lines + 1] = l end
  end
  lines[#lines + 1] = "say 'done'"
  os.execute("rm -rf '" .. WORK .. "' && mkdir -p '" .. WORK .. "'")
  local f = io.open(WORK .. "/update.sh", "w")
  f:write(table.concat(lines, "\n") .. "\n")
  f:close()
  os.execute("(sh '" .. WORK .. "/update.sh' > '" .. WORK .. "/log' 2>&1; echo $? > '" .. marker .. "') &")
  up.status = "starting"
  clock.run(function()
    while true do
      clock.sleep(0.5)
      up.status = read(status) or up.status
      local code = read(marker)
      if code then
        done(tonumber(code) == 0)
        return
      end
    end
  end)
end

return up
