-- The sample library: importing from a USB stick (or from
-- dust/audio/nidhogg/import, for uploads through maiden) and loading library
-- packs into banks. lib/library.py does the work in the background; this
-- mounts the stick and reads back what it says. After any change to the
-- banks SuperCollider restarts, so the firmware boots and reads its card
-- afresh.

local lib = {}

lib.MOUNT = "/mnt/nidhogg-usb"
lib.DROP = _path.audio .. "nidhogg/import"
local CARDS = _path.audio .. "nidhogg"
local WORK = _path.data .. "nidhogg/library"
local RELEASED = WORK .. "/released" -- the stick let go of, until it's pulled out
local NOTICE = WORK .. "/notice"     -- shown once nidhogg is back after a restart
local PY = norns.state.path .. "lib/library.py"

lib.device = nil -- the stick's partition while it's mounted
lib.status = nil -- progress text while working

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

local function write(path, s)
  local f = io.open(path, "w")
  if f then f:write(s); f:close() end
end

local function capture(cmd)
  local p = io.popen(cmd)
  local s = p:read("a")
  p:close()
  return s
end

-- The first partition of the first USB disk, or the disk itself if it has none.
local function find_device()
  local disk, part
  for d in capture("ls /dev/sd[a-z]* 2>/dev/null"):gmatch("[^\n]+") do
    if d:match("^/dev/sd[a-z]$") then disk = disk or d
    elseif d:match("^/dev/sd[a-z]%d+$") then part = part or d end
  end
  return part or disk
end

local function uuid(dev)
  return (capture("lsblk -no UUID " .. dev .. " 2>/dev/null"):gsub("%s", ""))
end

-- Read-only where possible. norns' usbmount may already have the stick
-- mounted read-write, out of sight in udev's own namespace, and then only a
-- mount with the same options is allowed. nidhogg never writes to it either way.
local function mount(dev)
  os.execute("sudo umount " .. lib.MOUNT .. " 2>/dev/null")
  os.execute("sudo mkdir -p " .. lib.MOUNT)
  return os.execute("sudo mount -o ro " .. dev .. " " .. lib.MOUNT .. " 2>/dev/null")
    or os.execute("sudo mount " .. dev .. " " .. lib.MOUNT .. " 2>/dev/null")
end

-- Unmounts the stick, usbmount's mount too, so it's safe to pull out and
-- comes out clean. Returns true if there was a stick.
function lib.release()
  local dev = lib.device
  if not dev then return false end
  os.execute("sudo umount " .. lib.MOUNT .. " 2>/dev/null")
  os.execute("sudo nsenter -t $(pgrep -xo systemd-udevd) -m umount " .. dev .. " 2>/dev/null")
  write(RELEASED, uuid(dev))
  lib.device = nil
  return true
end

-- Mounts a stick that was let go of but is still in.
function lib.remount()
  if lib.device then return end
  local dev = find_device()
  if dev and mount(dev) then
    os.remove(RELEASED)
    lib.device = dev
  end
end

-- Watches for a stick going in or out. A stick already in when the script
-- starts is mounted without calling on_insert, unless it was let go of.
function lib.watch(on_insert, on_remove)
  os.execute("mkdir -p " .. q(lib.DROP) .. " " .. q(WORK))
  local first = true
  local failed = nil -- a stick that wouldn't mount, left alone until it's out
  clock.run(function()
    while true do
      local dev = find_device()
      if dev and dev ~= lib.device and dev ~= failed then
        local released = read_all(RELEASED)
        if released and released == uuid(dev) then
          failed = dev
        elseif mount(dev) then
          os.remove(RELEASED)
          lib.device = dev
          if not first then on_insert() end
        else
          failed = dev
        end
      elseif not dev then
        failed = nil
        os.remove(RELEASED)
        if lib.device then
          lib.device = nil
          os.execute("sudo umount -l " .. lib.MOUNT .. " 2>/dev/null")
          on_remove()
        end
      end
      first = false
      clock.sleep(2)
    end
  end)
end

-- Runs a shell command in the background and calls done(ok, output).
local function run(cmd, done)
  local out, marker = WORK .. "/out", WORK .. "/done"
  os.remove(marker)
  os.execute("(" .. cmd .. " > " .. q(out) .. " 2> " .. q(WORK .. "/log") .. "; echo $? > " .. q(marker) .. ") &")
  clock.run(function()
    while true do
      clock.sleep(0.25)
      local code = read_all(marker)
      if code then
        done(tonumber(code) == 0, read_all(out) or "")
        return
      end
    end
  end)
end

local function fields(line)
  local t = {}
  for f in (line .. "\t"):gmatch("([^\t]*)\t") do t[#t + 1] = f end
  return t
end

-- Packs on the stick and in the import folder. done(packs, bad): packs
-- {name, source, files, kind, inlib}, kind being the CHOMPI mode the files
-- are named for and inlib the library pack they're already in, if any; bad
-- the zips that couldn't be read.
function lib.scan(done)
  local roots = q(lib.DROP)
  if lib.device then roots = q(lib.MOUNT) .. " " .. roots end
  run("python3 " .. q(PY) .. " scan " .. q(CARDS) .. " " .. roots, function(_, out)
    local packs, bad = {}, {}
    for line in out:gmatch("[^\n]+") do
      local f = fields(line)
      if f[1] == "pack" then
        packs[#packs + 1] = {name = f[2], source = f[3], files = {},
          kind = f[5] ~= "-" and f[5] or nil, inlib = f[6] ~= "-" and f[6] or nil}
      elseif f[1] == "file" and #packs > 0 then
        table.insert(packs[#packs].files, f[2])
      elseif f[1] == "bad" then
        bad[#bad + 1] = f[2]
      end
    end
    done(packs, bad)
  end)
end

-- fw's banks and the library items that fit them. done(banks, items):
-- banks {id, label, loaded, count}, loaded being the item in it (nil if it
-- isn't from the library); items {id, label}.
function lib.banks(fw, done)
  run("python3 " .. q(PY) .. " banks " .. fw .. " " .. q(CARDS), function(_, out)
    local banks, items = {}, {}
    for line in out:gmatch("[^\n]+") do
      local f = fields(line)
      if f[1] == "bank" then
        banks[#banks + 1] = {id = f[2], label = f[3], loaded = f[4] ~= "-" and f[4] or nil,
          count = tonumber(f[5])}
      elseif f[1] == "item" then
        items[#items + 1] = {id = f[2], label = f[3]}
      end
    end
    done(banks, items)
  end)
end

-- Runs jobs: {"import", pack, target, files} or {"load", item, bank}.
-- done(ok) once the files are in place; the restart is up to the caller.
function lib.start(fw, jobs, done)
  local lines = {}
  for _, j in ipairs(jobs) do
    if j[1] == "import" then
      lines[#lines + 1] = table.concat({"import", j[2].source, j[3], table.concat(j[4], "|"), j[2].name,
        j[2].tables and "tables" or "samples"}, "\t")
    else
      lines[#lines + 1] = table.concat(j, "\t")
    end
  end
  write(WORK .. "/jobs", table.concat(lines, "\n") .. "\n")
  local status = WORK .. "/status"
  os.remove(status)
  lib.status = "starting"
  local finished = false
  run(string.format("python3 %s run %s %s %s %s %s", q(PY), fw, q(CARDS), q(WORK .. "/jobs"),
    q(status), q(WORK .. "/slots")), function(ok)
    finished = true
    lib.status = (read_all(status) or ""):gsub("\n", "")
    done(ok)
  end)
  clock.run(function()
    while not finished do
      local s = read_all(status)
      if s then lib.status = s:gsub("\n", "") end
      clock.sleep(0.25)
    end
  end)
end

-- The command that resets the changed banks' presets, run while the
-- firmware is stopped.
function lib.presets_cmd(fw)
  return string.format("python3 %s presets %s %s %s", q(PY), fw, q(CARDS), q(WORK .. "/slots"))
end

-- A message to show when nidhogg is back after the restart.
function lib.set_notice(lines) write(NOTICE, table.concat(lines, "\n")) end

function lib.take_notice()
  local s = read_all(NOTICE)
  os.remove(NOTICE)
  if not s or s == "" then return nil end
  local t = {}
  for l in s:gmatch("[^\n]+") do t[#t + 1] = l end
  return t
end

function lib.unmount()
  if lib.device then os.execute("sudo umount -l " .. lib.MOUNT .. " 2>/dev/null") end
end

return lib
