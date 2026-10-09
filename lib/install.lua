-- First run and updates: the factory sample cards and the SuperCollider
-- plugins.
--
-- The cards come from the Chompi repo (MIT) with a sparse clone, so only the
-- card folders download. Each firmware's card ends up in
-- ~/dust/audio/nidhogg/<firmware>, laid out as on a Chompi SD card.
--
-- The plugins go into SuperCollider's Extensions folder, where scsynth looks
-- for them. scsynth only loads plugins when it starts, so a new plugin means
-- restarting norns.

local install = {}

local EXT = "/home/we/.local/share/SuperCollider/Extensions/nidhogg/"
local PLUGINS = {"NidhoggTape.so", "NidhoggTempo.so", "NidhoggWave.so"}
local CARDS = _path.audio .. "nidhogg/"
local REPO = "https://github.com/CHOMPI-Club/CHOMPI"
local PROFILES = {tape = "tape-2.0", tempo = "tempo-1.0", wave = "wave-1.0"}
local WORK = _path.data .. "nidhogg/download"

install.status = nil -- text for the screen while something is happening

local function exists(path)
  return os.execute("test -e '" .. path .. "'") == true
end

function install.card_dir(fw)
  return CARDS .. fw
end

-- True if every firmware's card folder is there.
function install.have_cards()
  for fw in pairs(PROFILES) do
    if not exists(CARDS .. fw .. "/options.json") then return false end
  end
  return true
end

-- Downloads the factory cards in the background and calls done(ok) when
-- finished. Cards already present are left alone, so your own samples and
-- settings are never overwritten.
function install.fetch_cards(done)
  local sets = {}
  for _, p in pairs(PROFILES) do sets[#sets + 1] = "firmware/card-profiles/" .. p end
  local copy = {}
  for fw, p in pairs(PROFILES) do
    copy[#copy + 1] = string.format(
      "[ -e '%s%s' ] || { mkdir -p '%s' && cp -r 'repo/firmware/card-profiles/%s' '%s%s' && rm -f '%s%s'/*.bin; }",
      CARDS, fw, CARDS, p, CARDS, fw, CARDS, fw)
  end
  local script = table.concat({
    "set -e",
    "rm -rf '" .. WORK .. "'",
    "mkdir -p '" .. WORK .. "'",
    "cd '" .. WORK .. "'",
    "git clone -q --depth 1 --filter=blob:none --sparse " .. REPO .. " repo",
    "git -C repo sparse-checkout set " .. table.concat(sets, " "),
    table.concat(copy, "\n"),
    "cd /",
    "rm -rf '" .. WORK .. "'",
  }, "\n")
  local log = _path.data .. "nidhogg/download.log"
  local marker = _path.data .. "nidhogg/download.done"
  os.execute("mkdir -p '" .. _path.data .. "nidhogg' && rm -f '" .. marker .. "'")
  local f = io.open(_path.data .. "nidhogg/download.sh", "w")
  f:write(script .. "\n")
  f:close()
  os.execute("(sh '" .. _path.data .. "nidhogg/download.sh' > '" .. log .. "' 2>&1; echo $? > '" .. marker .. "') &")
  install.status = "downloading samples"
  clock.run(function()
    local dots = 0
    while true do
      clock.sleep(0.5)
      local m = io.open(marker, "r")
      if m then
        local code = tonumber(m:read("l"))
        m:close()
        install.status = nil
        done(code == 0)
        return
      end
      dots = (dots + 1) % 4
      install.status = "downloading samples" .. string.rep(".", dots)
    end
  end)
end

-- Copies changed plugins into Extensions. Returns true if anything changed.
function install.plugins()
  local src = norns.state.path .. "bin/"
  local changed = false
  os.execute("mkdir -p " .. EXT)
  for _, name in ipairs(PLUGINS) do
    if not os.execute("cmp -s " .. src .. name .. " " .. EXT .. name) then
      os.execute("cp " .. src .. name .. " " .. EXT .. name)
      changed = true
    end
  end
  return changed
end

-- Restarts SuperCollider so it loads new plugins and engine classes, then
-- reloads this script into it. matron keeps running through this, so the
-- script waits for the new server and reloads itself. A shell command in
-- `between` runs while SuperCollider is stopped.
function install.restart(between)
  local script = norns.state.script
  if between then
    os.execute("(sudo systemctl stop norns-sclang.service; " .. between
      .. "; sudo systemctl start norns-sclang.service) > /dev/null 2>&1 &")
  else
    os.execute("sudo systemctl restart norns-sclang.service &")
  end
  clock.run(function()
    -- give the old server time to go, then wait for the new one
    clock.sleep(5)
    for _ = 1, 60 do
      if os.execute("pgrep -x scsynth > /dev/null") then break end
      clock.sleep(1)
    end
    clock.sleep(4)
    norns.script.load(script)
  end)
end

return install
