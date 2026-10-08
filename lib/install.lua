-- Copies nidhogg's SuperCollider plugins into SuperCollider's Extensions
-- folder, where scsynth looks for them. scsynth only loads plugins when it
-- starts, so a changed plugin needs a restart.

local install = {}

local EXT = "/home/we/.local/share/SuperCollider/Extensions/nidhogg/"
local PLUGINS = {"NidhoggTape.so"}

-- Returns true if anything was copied, meaning norns needs a restart.
function install.plugins()
  local src = norns.state.path .. "bin/"
  local changed = false
  os.execute("mkdir -p " .. EXT)
  for _, name in ipairs(PLUGINS) do
    local same = os.execute("cmp -s " .. src .. name .. " " .. EXT .. name)
    if not same then
      os.execute("cp " .. src .. name .. " " .. EXT .. name)
      changed = true
    end
  end
  return changed
end

return install
