-- What differs between Chompi's three firmwares, for the screens and the
-- controls: OSC port, knob and page names, shift-layer labels, the switch, and
-- each firmware's status pills. State values (s.st[1..10]) are the firmware's
-- own, in the order its board file sends them.

local modes = {}

local BANKS = {[0] = "a", "b", "c", "d", "e"}

-- Chompi's free pitch curve (TAPE's DSPEngine.h): knob 0-1 to speed, negative
-- is reverse.
local function pitch_speed(v)
  local x = 2 * v - 1
  local sg = x < 0 and -1 or 1
  local a = math.abs(x)
  if a < 0.33 then return x * 1.484848 + 0.01 * sg end
  if a < 0.66 then return (x - 0.33 * sg) * 1.515151 + 0.5 * sg end
  return (x - 0.66 * sg) * 2.941176 + 1.0 * sg
end

local function speed_text(p)
  return string.format("%.2fx%s", math.abs(p), p < 0 and " rev" or "")
end

local function pct(v)
  return string.format("%d", math.floor(v * 100 + 0.5))
end

local function bipolar(v, left, right)
  if math.abs(v - 0.5) < 0.02 then return "off" end
  return string.format("%s %d", v < 0.5 and left or right, math.floor(math.abs(v - 0.5) * 200 + 0.5))
end

-- ---- TAPE ---------------------------------------------------------------------

local LOOPER = {[0] = "empty", "armed", "recording", "overdub", "playing", "paused"}

modes.tape = {
  name = "TAPE",
  -- sticky points for the pots, by knob and page: 1x reverse and forward speed
  detents = {[0] = {[0] = {0.17, 0.83}}},
  knob_icons = {[0] = {"note", "gain"}, {"start", "attack"}, {"end", "release"}, {"magic", "wave", "filter"}, {"reels"}, {"volume", "mic"}},
  title = function(s)
    local slot = s.st[4] == 15 and "RAM" or tostring(s.st[4] or "")
    return string.format("%s %s %s", s.st[1] == 1 and "CUBBI" or "JAMMI", BANKS[s.st[3]] or "", slot)
  end,
  pills = function(s)
    local looper = s.st[8] or 0
    return {
      {icon = ({[0] = "mic", "line", "resample"})[s.st[5]] or "line"},
      {text = s.st[6] == 1 and "fx>" or ">fx", dim = true},
      {icon = ({[0] = "empty", "armed", "recdot", "recdot", "play", "pause"})[looper], on = looper == 2 or looper == 3, dim = looper == 0},
    }
  end,
  playing = function(s) return s.st[8] == 3 or s.st[8] == 4 end,
  has_window = true,
  audio_recording = function(s) return s.st[9] == 1 or s.st[8] == 2 or s.st[8] == 3 end,
  port = 57140,
  switch = {"PLAY", "REC"},
  knobs = {
    [0] = {name = "PITCH", pages = {"speed", "gain"}, big = {"PITCH", "GAIN"}},
    [1] = {name = "START", pages = {"start", "attack"}, big = {"START", "ATTACK"}},
    [2] = {name = "END", pages = {"end", "release"}, big = {"END", "RELEASE"}},
    [3] = {name = "MAGIC", pages = {"verb + delay", "lo-fi", "filter"}, big = {"VERB", "LO-FI", "FILTER"}},
    [4] = {name = "TRANSPORT", pages = {"speed"}, big = {"SPEED"}},
    [5] = {name = "VOLUME", pages = {"volume", "input gain"}, big = {"VOLUME", "INPUT"}},
  },
  shift_pots = {[0] = {"tune", "pan"}, {"move", "a + r"}, {"move", "a + r"}, {"time", "warble", "reso"}, nil, {"comp", "comp"}},
  shift_keys = {"jam", "cub", "mic", "line", "rsmp", "pre", "post", "erase", "copy", "save"},
  value = function(k, page, v)
    if k == 0 and page == 0 then return speed_text(pitch_speed(v)) end
    if k == 4 then return speed_text(4 * v - 2) end
    if k == 3 and page == 2 then return bipolar(v, "low", "high") end
    return pct(v)
  end,
  middle_mark = function(k, page) return (k == 3 and page == 2) or (k == 0 and page == 0) or k == 4 end,
  -- which shift chips are lit
  shift_on = function(s, i)
    local mode, input, fx_pre = s.st[1], s.st[5], s.st[6] == 1
    return (i == 1 and mode == 0) or (i == 2 and mode == 1)
      or (i >= 3 and i <= 5 and input == i - 3) or (i == 6 and fx_pre) or (i == 7 and not fx_pre)
  end,
  shift_title = function(s)
    return (s.st[1] == 1 and "CUBBI " or "JAMMI ") .. (BANKS[s.st[2]] or "")
  end,
  bank_color_slot = function(s)
    -- JAMMI on the RAM slot shows pink; otherwise the bank of the loaded slot
    if s.st[1] == 0 and s.st[4] == 15 then return nil end
    return s.st[3]
  end,
  looper = function(s) return s.st[8], s.looper_pos end,
  recording = function(s) return s.st[9] == 1 end,
}

-- ---- TEMPO ----------------------------------------------------------------------

local PATTERNS = {[0] = "seq", "up", "down", "pingpong", "random"}

modes.tempo = {
  name = "TEMPO",
  detents = {[0] = {[0] = {0.17, 0.83}}},
  knob_icons = {[0] = {"note", "gain", "filter"}, {"start", "attack"}, {"end", "release"}, {"delay", "magic"}, {"tempo"}, {"volume", "mic"}},
  title = function(s)
    return string.format("%s %d", s.st[1] == 1 and "SLICE" or "CHROMA", math.floor((s.st[5] or 320) / 2 + 0.5))
  end,
  pills = function(s)
    return {
      {text = PATTERNS[s.st[9]] or "seq", dim = not (s.st[7] and s.st[7] > 0)},
      {icon = "latch", on = s.st[8] == 1, dim = s.st[8] ~= 1},
    }
  end,
  playing = function(s) return s.st[7] and s.st[7] > 0 end,
  has_window = true,
  bpm = function(s) return math.floor((s.st[5] or 320) / 2 + 0.5) end,
  audio_recording = function(s) return s.st[4] == 1 end,
  port = 57141,
  switch = {"SHIFT", "REC"},
  knobs = {
    [0] = {name = "PITCH", pages = {"speed", "volume", "filter"}, big = {"PITCH", "VOLUME", "FILTER"}},
    [1] = {name = "START", pages = {"start", "attack"}, big = {"START", "ATTACK"}},
    [2] = {name = "END", pages = {"end", "release"}, big = {"END", "RELEASE"}},
    [3] = {name = "MAGIC", pages = {"delay", "delay mix"}, big = {"DELAY", "MIX"}},
    [4] = {name = "TEMPO", pages = {"tempo"}, big = {"TEMPO"}},
    [5] = {name = "VOLUME", pages = {"volume", "input gain"}, big = {"VOLUME", "INPUT"}},
  },
  shift_pots = {[0] = {"tune", "pan", "redux"}, {"move", "loop"}, {"zoom", "sustain"}, {"random", "feedbk"}, nil, {"comp", "comp"}},
  shift_keys = {"chro", "slice", "mic", "line", "rsmp", "A", "B", "erase", "copy", "save"},
  value = function(k, page, v, s)
    if k == 0 and page == 0 then return speed_text(pitch_speed(v)) end
    if k == 0 and page == 2 then return bipolar(v, "low", "high") end
    if k == 4 then return string.format("%d bpm", math.floor((s.st[5] or 320) / 2 + 0.5)) end
    return pct(v)
  end,
  middle_mark = function(k, page) return (k == 0 and (page == 0 or page == 2)) end,
  shift_on = function(s, i)
    local engine, input = s.st[1], s.st[2]
    return (i == 1 and engine == 0) or (i == 2 and engine == 1) or (i >= 3 and i <= 5 and input == i - 3)
  end,
  shift_title = function(s) return s.st[1] == 1 and "SLICE" or "CHROMA" end,
  bank_color_slot = function(s) return 0 end,
  looper = function(s) return nil end,
  recording = function(s) return s.st[4] == 1 end,
}

-- ---- WAVE ----------------------------------------------------------------------

modes.wave = {
  name = "WAVE",
  -- in tune is the middle of fine tune
  detents = {[0] = {[0] = {0.5}}},
  knob_icons = {[0] = {"note", "wave"}, {"attack", "note"}, {"release", "filter"}, {"magic", "filter"}, {"tempo"}, {"gain", "volume"}},
  title = function(s)
    return string.format("%s %d", s.st[1] == 15 and "INIT" or ("P" .. (s.st[1] or 0)), math.floor((s.st[2] or 320) / 2 + 0.5))
  end,
  pills = function(s)
    local o = s.st[5] or 0
    return {
      {text = "oct " .. (o > 0 and "+" or "") .. o, dim = o == 0},
      {icon = "recdot", on = s.st[4] == 1, dim = s.st[4] ~= 1},
    }
  end,
  playing = function(s) return s.st[3] == 1 end,
  bpm = function(s) return math.floor((s.st[2] or 320) / 2 + 0.5) end,
  port = 57142,
  switch = {"SHIFT", "PERF"},
  knobs = {
    [0] = {name = "PITCH", pages = {"fine tune", "frame"}, big = {"TUNE", "FRAME"}},
    [1] = {name = "ATTACK", pages = {"attack", "pitch lfo"}, big = {"ATTACK", "P LFO"}},
    [2] = {name = "RELEASE", pages = {"release", "filter lfo"}, big = {"RELEASE", "F LFO"}},
    [3] = {name = "FX", pages = {"delay | verb", "filter"}, big = {"FX", "FILTER"}},
    [4] = {name = "TEMPO", pages = {"tempo"}, big = {"TEMPO"}},
    [5] = {name = "GAIN", pages = {"gain", "pan"}, big = {"GAIN", "PAN"}},
  },
  shift_pots = {[0] = {"semis", "table"}, {"attack", "p rate"}, {"release", "f rate"}, {"time", "reso"}, nil, {"comp", "comp"}},
  shift_keys = {"oct-", "oct+", "g 10", "g 50", "g100", "plfo", "flfo", "erase", "copy", "save"},
  value = function(k, page, v, s)
    if k == 0 and page == 1 then return tostring(s.st[6] or 0) end
    if k == 3 and page == 0 then return bipolar(v, "delay", "verb") end
    if k == 3 and page == 1 then return bipolar(v, "low", "high") end
    if k == 5 and page == 1 then return bipolar(v, "left", "right") end
    if k == 4 then return string.format("%d bpm", math.floor((s.st[2] or 320) / 2 + 0.5)) end
    return pct(v)
  end,
  middle_mark = function(k, page) return (k == 0 and page == 0) or k == 3 or (k == 5 and page == 1) end,
  shift_on = function(s, i)
    local gate = s.st[10] or 50
    return (i == 3 and gate <= 25) or (i == 4 and gate > 25 and gate <= 75) or (i == 5 and gate > 75)
      or (i == 6 and s.st[8] == 1) or (i == 7 and s.st[9] == 1)
  end,
  shift_title = function(s)
    local o = s.st[5] or 0
    return "OCT " .. (o > 0 and "+" or "") .. o
  end,
  bank_color_slot = function(s) return 0 end,
  looper = function(s) return nil end,
  recording = function(s) return s.st[4] == 1 end,
}

modes.order = {"tape", "tempo", "wave"}

return modes
