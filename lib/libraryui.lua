-- The norns screens for the sample library.
--
-- Import: a list of packs on the stick and in the import folder. E2 moves,
-- K3 ticks a pack, K1 opens it to tick single samples, E3 sets where a ticked
-- pack goes (a bank, or just the library). The last row imports them all.
-- Library: one row per bank. E3 picks the library pack for the bank under
-- the cursor; the last row loads the changes.
-- Either way the stick is let go of when done, and SuperCollider restarts if
-- any bank changed.

local lib = include("lib/library")
local install = include("lib/install")

local ui = {}
local st = nil -- the open screen, or nil
local SLOTS = 14
local ROWS = 5

local function fit(text, w)
  w = w or 124
  if screen.text_extents(text) <= w then return text end
  while #text > 1 and screen.text_extents("..." .. text) > w do text = text:sub(2) end
  return "..." .. text
end

local function right(x, y, text)
  screen.move(x, y)
  screen.text_right(text)
end

function ui.active() return st ~= nil end

local function close()
  local released = lib.release()
  st = released and {mode = "notice", lines = {"safe to remove the stick"}} or nil
end

local function finish(fw, changed_banks, lines)
  local released = lib.release()
  if released then lines[#lines + 1] = "safe to remove the stick" end
  if changed_banks then
    lib.set_notice(lines)
    st = {mode = "notice", lines = {lines[1], "restarting to load them"}, waiting = true}
    install.restart(lib.presets_cmd())
  else
    st = {mode = "notice", lines = lines}
  end
end

-- import ---------------------------------------------------------------------

local function picked(pack)
  local n = 0
  for _, f in ipairs(pack.files) do if pack.on[f] then n = n + 1 end end
  return n
end

-- banks a pack needs: one per 14 samples, or one per table for WAVE
local function span(pack, fw)
  local n = picked(pack)
  if fw == "wave" then return math.max(1, n) end
  return math.max(1, math.ceil(n / SLOTS))
end

local function mode_of(bank) return bank.id:match("^(%a+)") end

-- Where a pack can go: {kind = "library"}, {kind = "replace", bank = i}
-- (replacing that bank, and the ones after if the pack needs more), or
-- {kind = "add", bank = i} (into that bank's empty slots).
local LIBRARY = {kind = "library"}

-- Every firmware's banks are offered. WAVE's tables only take packs that
-- aren't named for TAPE or TEMPO.
local function options(pack)
  local out = {LIBRARY}
  local n = picked(pack)
  for i, b in ipairs(st.banks) do
    if b.fw ~= "wave" or not pack.kind then
      local last = st.banks[i + span(pack, b.fw) - 1]
      if last and mode_of(last) == mode_of(b) then out[#out + 1] = {kind = "replace", bank = i} end
      if b.fw ~= "wave" and b.count > 0 and SLOTS - b.count >= n then
        out[#out + 1] = {kind = "add", bank = i}
      end
    end
  end
  return out
end

local function same(a, b) return a.kind == b.kind and a.bank == b.bank end

-- the banks other ticked packs are going to
local function taken(except)
  local t = {}
  for _, p in ipairs(st.packs) do
    if p ~= except and p.tick and p.target.bank then
      local last = p.target.kind == "add" and p.target.bank
        or p.target.bank + span(p, st.banks[p.target.bank].fw) - 1
      for i = p.target.bank, last do t[i] = true end
    end
  end
  return t
end

-- Empty banks first, in the mode the pack's files are named for (or, if
-- they aren't, the firmware that's running), then room in a bank that has
-- some, then the library.
local function default_target(pack)
  local used = taken(pack)
  local opts = options(pack)
  for _, want in ipairs({"replace", "add"}) do
    for _, strict in ipairs({true, false}) do
      for _, o in ipairs(opts) do
        local ob = st.banks[o.bank]
        if o.kind == want and (not strict or pack.kind or ob.fw == st.fw) then
          local ok = true
          local last = want == "add" and o.bank or o.bank + span(pack, ob.fw) - 1
          for j = o.bank, last do
            local b = st.banks[j]
            if used[j] or (want == "replace" and b.count > 0)
              or (strict and pack.kind and mode_of(b) ~= pack.kind) then ok = false end
          end
          if ok then return o end
        end
      end
    end
  end
  return LIBRARY
end

local function target_label(pack)
  local t = pack.target
  if t.kind == "library" then return "library" end
  local a = st.banks[t.bank]
  if t.kind == "add" then return "+ " .. a.label end
  local n = span(pack, a.fw)
  if n == 1 then return a.label end
  local b = st.banks[math.min(#st.banks, t.bank + n - 1)]
  return a.label .. "-" .. (b.label:match("(%S+)$"))
end

function ui.open_import(fw)
  if st and (st.state == "working" or st.waiting) then return end
  lib.remount()
  st = {mode = "import", fw = fw, state = "scanning", cursor = 1, top = 1}
  lib.scan(function(packs, bad)
    if not st or st.mode ~= "import" then return end
    lib.banks("all", function(banks)
      if not st or st.mode ~= "import" then return end
      st.banks, st.bad = banks, bad
      st.packs = packs
      for _, p in ipairs(packs) do
        -- on WAVE a pack is wavetables, unless it's named for TAPE or TEMPO
        p.tables = fw == "wave" and not p.kind
        p.on = {}
        for _, f in ipairs(p.files) do p.on[f] = true end
        p.target = LIBRARY
      end
      st.state = #packs > 0 and "list" or "empty"
    end)
  end)
end

local function ticked()
  local t = {}
  for _, p in ipairs(st.packs) do if p.tick and picked(p) > 0 then t[#t + 1] = p end end
  return t
end

-- banks with samples in them that the ticked packs would replace
local function replacing()
  local out = {}
  for _, p in ipairs(ticked()) do
    if p.target.kind == "replace" then
      for i = p.target.bank, math.min(#st.banks, p.target.bank + span(p, st.banks[p.target.bank].fw) - 1) do
        if st.banks[i].count > 0 then out[#out + 1] = st.banks[i].label end
      end
    end
  end
  return out
end

local function do_import()
  local jobs, any_bank = {}, false
  for _, p in ipairs(ticked()) do
    local files = {}
    for _, f in ipairs(p.files) do if p.on[f] then files[#files + 1] = f end end
    local t = p.target
    local b = st.banks[t.bank or 0]
    local target = t.kind == "library" and "library"
      or ((t.kind == "add" and "add:" or "") .. b.fw .. "/" .. b.id)
    any_bank = any_bank or t.kind ~= "library"
    -- converted as wavetables for WAVE's tables, as samples for the rest
    local tables = (b and b.fw == "wave") or (not b and p.tables)
    jobs[#jobs + 1] = {"import", p, target, files, tables and "tables" or "samples"}
  end
  st.state = "working"
  local fw = st.fw
  lib.start(fw, jobs, function(ok)
    if not ok then
      st.state = "failed"
      return
    end
    finish(fw, any_bank, {lib.status or "imported"})
  end)
end

local function import_key(n)
  local s = st
  if s.state == "files" then
    local p = s.packs[s.open]
    if n == 3 then
      local f = p.files[s.fcursor]
      p.on[f] = not p.on[f]
      -- a different count may not fit where it was going
      if p.tick then
        local fits = false
        for _, o in ipairs(options(p)) do fits = fits or same(o, p.target) end
        if not fits then p.target = default_target(p) end
      end
    elseif n == 2 then
      s.state = "list"
    end
    return
  end
  if s.state == "confirm" then
    if n == 3 then do_import() elseif n == 2 then s.state = "list" end
    return
  end
  if s.state == "failed" then
    if n == 3 or n == 2 then close() end
    return
  end
  if n == 2 then
    close()
    return
  end
  if s.state ~= "list" then return end
  local p = s.packs[s.cursor]
  if n == 3 then
    if p then
      p.tick = not p.tick
      if p.tick then p.target = default_target(p) end
    elseif #ticked() > 0 then
      if #replacing() > 0 then s.state = "confirm" else do_import() end
    end
  elseif n == 1 and p then
    s.state, s.open, s.fcursor, s.ftop = "files", s.cursor, 1, 1
  end
end

local function scroll(cur, top, n)
  if cur < top then top = cur end
  if cur > top + ROWS - 1 then top = cur - ROWS + 1 end
  return math.max(1, math.min(top, math.max(1, n - ROWS + 1)))
end

local function import_enc(n, d)
  local s = st
  if s.state == "files" then
    local p = s.packs[s.open]
    if n == 2 then
      s.fcursor = util.clamp(s.fcursor + d, 1, #p.files)
      s.ftop = scroll(s.fcursor, s.ftop, #p.files)
    end
    return
  end
  if s.state ~= "list" then return end
  if n == 2 then
    s.cursor = util.clamp(s.cursor + d, 1, #s.packs + 1)
    s.top = scroll(s.cursor, s.top, #s.packs + 1)
  elseif n == 3 then
    local p = s.packs[s.cursor]
    if not (p and p.tick) then return end
    local opts = options(p)
    local i = 1
    for j, o in ipairs(opts) do if same(o, p.target) then i = j end end
    p.target = opts[util.clamp(i + d, 1, #opts)]
  end
end

local function row(i, y, selected, tick, name, tag, dim)
  screen.level(selected and 15 or (dim and 3 or 6))
  if tick ~= nil then
    screen.rect(1.5, y - 5.5, 5, 5)
    if tick then screen.fill() else screen.stroke() end
  end
  screen.move(tick ~= nil and 10 or 2, y)
  local tw = tag and screen.text_extents(tag) or 0
  screen.text(fit(name, 116 - tw - (tick ~= nil and 10 or 2)))
  if tag then right(127, y, tag) end
end

local function draw_import()
  local s = st
  screen.level(15)
  screen.move(2, 8)
  screen.text("IMPORT")
  if s.state == "scanning" then
    screen.level(8)
    screen.move(64, 34)
    screen.text_center("looking for samples")
    return
  elseif s.state == "empty" then
    screen.level(8)
    screen.move(64, 28)
    if #s.bad > 0 then
      screen.text_center(fit("couldn't read " .. s.bad[1]))
      screen.move(64, 38)
      screen.text_center("it may not have copied fully")
    else
      screen.text_center("no samples found on the stick")
      screen.move(64, 38)
      screen.text_center("or in audio/nidhogg/import")
    end
    return
  elseif s.state == "working" then
    screen.level(8)
    screen.move(64, 34)
    screen.text_center(lib.status or "importing")
    return
  elseif s.state == "failed" then
    screen.level(8)
    screen.move(64, 28)
    screen.text_center(lib.status or "import failed")
    screen.move(64, 38)
    screen.level(4)
    screen.text_center("see data/nidhogg/library/log")
    return
  elseif s.state == "confirm" then
    local r = replacing()
    screen.level(8)
    screen.move(64, 24)
    screen.text_center(fit("replaces " .. table.concat(r, ", ")))
    screen.move(64, 34)
    screen.level(5)
    screen.text_center("(they're kept in the library)")
    screen.level(15)
    screen.move(64, 52)
    screen.text_center("K3 replace    K2 back")
    return
  elseif s.state == "files" then
    local p = s.packs[s.open]
    screen.level(6)
    right(127, 8, string.format("%d of %d", picked(p), #p.files))
    for i = s.ftop, math.min(#p.files, s.ftop + ROWS - 1) do
      local f = p.files[i]
      row(i, 18 + (i - s.ftop) * 9, i == s.fcursor, p.on[f] and true or false, f)
    end
    screen.level(4)
    screen.move(2, 63)
    screen.text("K3 pick   K2 back")
    return
  end
  local n = #ticked()
  screen.level(6)
  right(127, 8, n > 0 and (n .. " picked") or "")
  for i = s.top, math.min(#s.packs + 1, s.top + ROWS - 1) do
    local y = 18 + (i - s.top) * 9
    local p = s.packs[i]
    if p then
      local tag = p.tick and target_label(p) or (p.inlib and "in library" or tostring(picked(p)))
      row(i, y, i == s.cursor, p.tick and true or false, p.name, tag, p.inlib and not p.tick)
    else
      screen.level(i == s.cursor and 15 or (n > 0 and 6 or 3))
      screen.move(64, y)
      screen.text_center(n > 0 and string.format("import %d pack%s", n, n == 1 and "" or "s") or "tick packs to import")
    end
  end
  screen.level(4)
  screen.move(2, 63)
  local p = s.packs[s.cursor]
  if p and p.tick and #options(p) > 1 then
    screen.text("E3 where   K1 samples")
  elseif p then
    screen.text("K3 tick   K1 samples")
  else
    screen.text("K3 import  K2 back")
  end
end

-- library --------------------------------------------------------------------

function ui.open_library(fw)
  if st and (st.state == "working" or st.waiting) then return end
  st = {mode = "library", fw = fw, state = "loading", cursor = 1, top = 1}
  lib.banks(fw, function(banks, items, samples)
    if not st or st.mode ~= "library" then return end
    st.banks, st.items, st.samples = banks, items, samples
    for _, b in ipairs(banks) do
      b.choice = 0 -- 0 keeps what's there
      b.pick = {}  -- slot -> sample index, for single slots
    end
    st.state = "list"
  end)
end

local function item_label(id)
  for _, it in ipairs(st.items) do if it.id == id then return it.label end end
  -- factory banks are only copied into the library when they're replaced
  if id:match("^factory/") then return "factory" end
  return (id:gsub("[#@]%d+$", ""))
end

local function bank_tag(b)
  if b.choice > 0 then return item_label(st.items[b.choice].id) end
  if b.loaded then return item_label(b.loaded) end
  return b.count > 0 and "own samples" or "empty"
end

local function slot_changes(b)
  local n = 0
  if b.choice == 0 then
    for _, v in pairs(b.pick) do if v > 0 then n = n + 1 end end
  end
  return n
end

local function bank_changed(b)
  return (b.choice > 0 and st.items[b.choice].id ~= b.loaded) or slot_changes(b) > 0
end

local function changes()
  local t = {}
  for _, b in ipairs(st.banks) do if bank_changed(b) then t[#t + 1] = b end end
  return t
end

local function library_key(n)
  local s = st
  if s.state == "failed" then close(); return end
  if s.state == "slots" then
    if n == 2 then s.state = "list" end
    return
  end
  if s.state ~= "list" then return end
  local b = s.banks[s.cursor]
  if n == 2 then
    close()
  elseif n == 1 and b and s.fw ~= "wave" and b.choice == 0 then
    s.state, s.open, s.scursor, s.stop = "slots", s.cursor, 1, 1
  elseif n == 3 and not b then
    local c = changes()
    if #c == 0 then return end
    local jobs = {}
    for _, cb in ipairs(c) do
      if cb.choice > 0 then
        jobs[#jobs + 1] = {"load", s.items[cb.choice].id, cb.id}
      else
        for slot, v in pairs(cb.pick) do
          if v > 0 then jobs[#jobs + 1] = {"slot", s.samples[v].id, cb.id, tostring(slot)} end
        end
      end
    end
    s.state = "working"
    local fw = s.fw
    lib.start(fw, jobs, function(ok)
      if not ok then s.state = "failed"; return end
      finish(fw, true, {lib.status or "loaded"})
    end)
  end
end

local function library_enc(n, d)
  local s = st
  if s.state == "slots" then
    local b = s.banks[s.open]
    if n == 2 then
      s.scursor = util.clamp(s.scursor + d, 1, SLOTS)
      s.stop = scroll(s.scursor, s.stop, SLOTS)
    elseif n == 3 then
      b.pick[s.scursor] = util.clamp((b.pick[s.scursor] or 0) + d, 0, #s.samples)
    end
    return
  end
  if s.state ~= "list" then return end
  if n == 2 then
    s.cursor = util.clamp(s.cursor + d, 1, #s.banks + 1)
    s.top = scroll(s.cursor, s.top, #s.banks + 1)
  elseif n == 3 then
    local b = s.banks[s.cursor]
    if b then b.choice = util.clamp(b.choice + d, 0, #s.items) end
  end
end

local function draw_slots()
  local s = st
  local b = s.banks[s.open]
  screen.level(6)
  right(127, 8, b.label)
  for i = s.stop, math.min(SLOTS, s.stop + ROWS - 1) do
    local y = 18 + (i - s.stop) * 9
    local v = b.pick[i] or 0
    local name = v > 0 and ("* " .. s.samples[v].label) or (b.slots[i] or "empty")
    screen.level(i == s.scursor and 15 or (v > 0 and 10 or (b.slots[i] and 5 or 3)))
    screen.move(2, y)
    screen.text(tostring(i))
    screen.move(16, y)
    screen.text(fit(name, 110))
  end
  screen.level(4)
  screen.move(2, 63)
  screen.text("E3 sample   K2 back")
end

local function draw_library()
  local s = st
  screen.level(15)
  screen.move(2, 8)
  screen.text("LIBRARY")
  if s.state == "slots" then
    draw_slots()
    return
  end
  if s.state ~= "list" then
    screen.level(8)
    screen.move(64, 34)
    screen.text_center(s.state == "working" and (lib.status or "loading")
      or s.state == "failed" and (lib.status or "loading failed") or "reading the library")
    return
  end
  local c = changes()
  for i = s.top, math.min(#s.banks + 1, s.top + ROWS - 1) do
    local y = 18 + (i - s.top) * 9
    local b = s.banks[i]
    if b then
      local changed = bank_changed(b)
      screen.level(i == s.cursor and 15 or 6)
      screen.move(2, y)
      screen.text(b.label)
      local tag = bank_tag(b)
      if slot_changes(b) > 0 then tag = string.format("%d slot%s", slot_changes(b), slot_changes(b) == 1 and "" or "s") end
      if changed then tag = "* " .. tag end
      screen.level(i == s.cursor and 15 or (changed and 10 or 4))
      right(127, y, fit(tag, 80))
    else
      screen.level(i == s.cursor and 15 or (#c > 0 and 6 or 3))
      screen.move(64, y)
      screen.text_center(#c > 0 and string.format("load %d bank%s", #c, #c == 1 and "" or "s") or "turn E3 to choose")
    end
  end
  screen.level(4)
  screen.move(2, 63)
  if s.cursor > #s.banks then
    screen.text("K3 load   K2 back")
  elseif s.fw ~= "wave" then
    screen.text("E3 pack   K1 slots")
  else
    screen.text("E3 table   K2 back")
  end
end

-- both -----------------------------------------------------------------------

-- A message from before a restart, or "safe to remove".
function ui.notice(lines)
  st = {mode = "notice", lines = lines}
end

function ui.key(n, z)
  if z == 0 or not st then return end
  if st.mode == "notice" then
    if not st.waiting and (n == 2 or n == 3) then st = nil end
  elseif st.mode == "import" then
    import_key(n)
  else
    library_key(n)
  end
end

function ui.enc(n, d)
  if not st then return end
  if st.mode == "import" then import_enc(n, d) elseif st.mode == "library" then library_enc(n, d) end
end

-- the stick was pulled out
function ui.removed()
  if not st then return end
  if st.mode == "notice" and not st.waiting then st = nil
  elseif st.mode == "import" and st.state ~= "working" then st = nil end
end

function ui.draw()
  if st.mode == "notice" then
    screen.level(15)
    for i, l in ipairs(st.lines) do
      screen.move(64, 22 + (i - 1) * 11)
      screen.text_center(fit(l))
    end
    if not st.waiting then
      screen.level(4)
      screen.move(64, 62)
      screen.text_center("K3 ok")
    end
  elseif st.mode == "import" then
    draw_import()
  else
    draw_library()
  end
end

return ui
