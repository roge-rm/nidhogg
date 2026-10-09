-- Sample import: from a USB stick, or from dust/audio/nidhogg/import for
-- uploads through maiden. The converting is done by lib/import.py in the
-- background. After an import SuperCollider restarts, so the firmware boots
-- again and reads its card afresh.

local imp = {}

imp.MOUNT = "/mnt/nidhogg-usb"
imp.DROP = _path.audio .. "nidhogg/import"
local WORK = _path.data .. "nidhogg/import"
local PY = norns.state.path .. "lib/import.py"

imp.device = nil -- the stick's partition while it's mounted

local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function read_all(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("a")
  f:close()
  return s
end

-- The first partition of the first USB disk, or the disk itself if it has none.
local function find_device()
  local p = io.popen("ls /dev/sd[a-z]* 2>/dev/null")
  local list = p:read("a")
  p:close()
  local disk, part
  for d in list:gmatch("[^\n]+") do
    if d:match("^/dev/sd[a-z]$") then disk = disk or d
    elseif d:match("^/dev/sd[a-z]%d+$") then part = part or d end
  end
  return part or disk
end

-- Read-only where possible. norns' usbmount may already have the stick
-- mounted read-write, out of sight in udev's own namespace, and then only a
-- mount with the same options is allowed. nidhogg never writes to it either way.
local function mount(dev)
  os.execute("sudo umount -l " .. imp.MOUNT .. " 2>/dev/null")
  os.execute("sudo mkdir -p " .. imp.MOUNT)
  return os.execute("sudo mount -o ro " .. dev .. " " .. imp.MOUNT .. " 2>/dev/null")
    or os.execute("sudo mount " .. dev .. " " .. imp.MOUNT .. " 2>/dev/null")
end

function imp.unmount()
  if imp.device then
    os.execute("sudo umount -l " .. imp.MOUNT .. " 2>/dev/null")
    imp.device = nil
  end
end

-- Watches for a stick going in or out. A stick already in when the script
-- starts is mounted without calling on_insert.
function imp.watch(on_insert, on_remove)
  os.execute("mkdir -p " .. q(imp.DROP) .. " " .. q(WORK))
  local first = true
  local failed = nil -- a stick that wouldn't mount, left alone until it's out
  clock.run(function()
    while true do
      local dev = find_device()
      if dev and dev ~= imp.device and dev ~= failed then
        if mount(dev) then
          imp.device = dev
          if not first then on_insert() end
        else
          failed = dev
        end
      elseif not dev then
        failed = nil
        if imp.device then
          imp.unmount()
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

-- Finds packs on the stick and in the import folder, and the places firmware
-- fw can take them. done(packs, targets): packs {name, source, count, kind},
-- kind being what CHOMPI mode the files are named for, if any;
-- targets {id, label, count}, count being the samples already there, and
-- bad the zips that couldn't be read.
function imp.scan(fw, card, done)
  local roots = q(imp.DROP)
  if imp.device then roots = q(imp.MOUNT) .. " " .. roots end
  run("python3 " .. q(PY) .. " scan " .. fw .. " " .. q(card) .. " " .. roots, function(_, out)
    local packs, targets, bad = {}, {}, {}
    for line in out:gmatch("[^\n]+") do
      local kind, a, b, n, hint = line:match("^(%a+)\t([^\t]*)\t([^\t]*)\t(%d+)\t?(.*)$")
      if kind == "bad" then
        bad[#bad + 1] = a
      elseif kind == "pack" then
        packs[#packs + 1] = {name = a, source = b, count = tonumber(n), kind = hint ~= "-" and hint or nil}
      elseif kind == "target" then
        targets[#targets + 1] = {id = a, label = b, count = tonumber(n)}
      end
    end
    done(packs, targets, bad)
  end)
end

imp.status = nil -- progress text while importing

-- Converts a pack into a target; done(ok).
function imp.start(fw, card, pack, target, done)
  local status = WORK .. "/status"
  os.remove(status)
  imp.status = "starting"
  local finished = false
  run(string.format("python3 %s import %s %s %s %s %s %s", q(PY), fw, q(card), q(pack.source),
    q(target.id), q(status), q(WORK .. "/slots")), function(ok)
    finished = true
    imp.status = (read_all(status) or ""):gsub("\n", "")
    done(ok)
  end)
  clock.run(function()
    while not finished do
      local s = read_all(status)
      if s then imp.status = s:gsub("\n", "") end
      clock.sleep(0.25)
    end
  end)
end

-- The command that resets the imported slots' presets, run while the
-- firmware is stopped.
function imp.presets_cmd(fw, card)
  return string.format("python3 %s presets %s %s %s", q(PY), fw, q(card), q(WORK .. "/slots"))
end

return imp
