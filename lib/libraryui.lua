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
    install.restart(lib.presets_cmd(fw))
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
local function span(fw, pack)
  local n = picked(pack)
  if fw == "wave" then return math.max(1, n) end
  return math.max(1, math.ceil(n / SLOTS))
end

local function mode_of(bank) return bank.id:match("^(%a+)") end

-- the banks other ticked packs are going to
local function taken(except)
  local t = {}
  for _, p in ipairs(st.packs) do
    if p ~= except and p.tick and p.target > 0 then
      for i = p.target, p.target + span(st.fw, p) - 1 do t[i] = true end
    end
  end
  return t
end

-- The first run of empty banks that fits the pack, in the mode its files are
-- named for; 0 (the library) if there's none. Samples can't go in WAVE's
-- tables, so on WAVE they only go in the library.
local function default_target(pack)
  if st.fw == "wave" and not pack.tables then return 0 end
  local used = taken(pack)
  local need = span(st.fw, pack)
  for _, strict in ipairs({true, false}) do
    for i = 1, #st.banks - need + 1 do
      local ok = true
      for j = i, i + need - 1 do
        local b = st.banks[j]
        if used[j] or b.count > 0 or mode_of(b) ~= mode_of(st.banks[i])
          or (strict and pack.kind and mode_of(b) ~= pack.kind) then ok = false end
      end
      if ok then return i end
    end
  end
  return 0
end

local function target_label(pack)
  if pack.target == 0 then return "library" end
  local a, n = st.banks[pack.target], span(st.fw, pack)
  if n == 1 then return a.label end
  local b = st.banks[math.min(#st.banks, pack.target + n - 1)]
  return a.label .. "-" .. (b.label:match("(%S+)$"))
end

function ui.open_import(fw)
  if st and (st.state == "working" or st.waiting) then return end
  lib.remount()
  st = {mode = "import", fw = fw, state = "scanning", cursor = 1, top = 1}
  lib.scan(function(packs, bad)
    if not st or st.mode ~= "import" then return end
    lib.banks(fw, function(banks)
      if not st or st.mode ~= "import" then return end
      st.banks, st.bad = banks, bad
      st.packs = packs
      for _, p in ipairs(packs) do
        -- on WAVE a pack is wavetables, unless it's named for TAPE or TEMPO
        p.tables = fw == "wave" and not p.kind
        p.on = {}
        for _, f in ipairs(p.files) do p.on[f] = true end
        p.target = 0
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
    if p.target > 0 then
      for i = p.target, math.min(#st.banks, p.target + span(st.fw, p) - 1) do
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
    local target = p.target > 0 and st.banks[p.target].id or "library"
    any_bank = any_bank or p.target > 0
    jobs[#jobs + 1] = {"import", p, target, files}
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
      if p.tick and p.target > 0 then p.target = default_target(p) end
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
    if not (p and p.tick) or (s.fw == "wave" and not p.tables) then return end
    -- step through the library and each bank the pack fits from
    local need = span(s.fw, p)
    local t = p.target
    repeat
      t = t + (d > 0 and 1 or -1)
      if t < 0 or t > #s.banks then return end
    until t == 0 or (t + need - 1 <= #s.banks and mode_of(s.banks[t]) == mode_of(s.banks[t + need - 1]))
    p.target = t
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
  if p and p.tick and not (s.fw == "wave" and not p.tables) then
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
  lib.banks(fw, function(banks, items)
    if not st or st.mode ~= "library" then return end
    st.banks, st.items = banks, items
    for _, b in ipairs(banks) do b.choice = 0 end -- 0 keeps what's there
    st.state = "list"
  end)
end

local function item_label(id)
  for _, it in ipairs(st.items) do if it.id == id then return it.label end end
  return id
end

local function bank_tag(b)
  if b.choice > 0 then return item_label(st.items[b.choice].id) end
  if b.loaded then return item_label(b.loaded) end
  return b.count > 0 and "own samples" or "empty"
end

local function changes()
  local t = {}
  for _, b in ipairs(st.banks) do
    if b.choice > 0 and st.items[b.choice].id ~= b.loaded then t[#t + 1] = b end
  end
  return t
end

local function library_key(n)
  local s = st
  if s.state == "failed" then close(); return end
  if s.state ~= "list" then return end
  if n == 2 then
    close()
  elseif n == 3 and s.cursor > #s.banks then
    local c = changes()
    if #c == 0 then return end
    local jobs = {}
    for _, b in ipairs(c) do jobs[#jobs + 1] = {"load", s.items[b.choice].id, b.id} end
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
  if s.state ~= "list" then return end
  if n == 2 then
    s.cursor = util.clamp(s.cursor + d, 1, #s.banks + 1)
    s.top = scroll(s.cursor, s.top, #s.banks + 1)
  elseif n == 3 then
    local b = s.banks[s.cursor]
    if b then b.choice = util.clamp(b.choice + d, 0, #s.items) end
  end
end

local function draw_library()
  local s = st
  screen.level(15)
  screen.move(2, 8)
  screen.text("LIBRARY")
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
      local changed = b.choice > 0 and s.items[b.choice].id ~= b.loaded
      screen.level(i == s.cursor and 15 or 6)
      screen.move(2, y)
      screen.text(b.label)
      local tag = (changed and "* " or "") .. bank_tag(b)
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
  screen.text(s.cursor > #s.banks and "K3 load  K2 back" or "E3 choose  K2 back")
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
