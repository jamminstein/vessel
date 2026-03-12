-- lib/groove.lua
-- VESSEL groove engine v2
-- Encodes the rhythmic DNA of James Brown, Bossa Nova, Aphex Twin
-- BUG FIX: T/F locals now defined before any table that uses them
-- NEW: cr:peek() returns phase/pos without advancing state

local groove = {}

-- -------------------------------------------------------------------------
-- BOOLEAN ALIASES (must be at top, before any table uses them)
-- -------------------------------------------------------------------------
local T, F = true, false

-- -------------------------------------------------------------------------
-- EUCLIDEAN RHYTHM GENERATOR
-- Distributes k hits as evenly as possible over n steps (Bjorklund)
-- -------------------------------------------------------------------------
function groove.euclidean(steps, hits, offset)
  offset = offset or 0
  if hits <= 0 then
    return function(step) return false end
  end
  hits = math.min(hits, steps)

  local pattern = {}
  local bucket  = 0
  for i = 1, steps do
    bucket = bucket + hits
    if bucket >= steps then
      bucket = bucket - steps
      pattern[i] = true
    else
      pattern[i] = false
    end
  end

  if offset > 0 then
    for _ = 1, offset do
      table.insert(pattern, 1, table.remove(pattern))
    end
  end

  return function(step)
    local idx = ((step - 1) % steps) + 1
    return pattern[idx] or false
  end
end

-- -------------------------------------------------------------------------
-- BOSSA NOVA CLAVE
-- 3+3+2 Jobim rhythmic cell at 16th-note resolution
-- T/F now defined above before this table — bug fixed
-- -------------------------------------------------------------------------
groove.bossa_clave = {
  hi = {T,F,F,T,F,F,T,F,F,T,F,T,F,F,F,F},
  lo = {T,F,T,F,T,F,T,F,T,F,T,F,T,F,T,F},
}

-- -------------------------------------------------------------------------
-- JAMES BROWN TEMPLATES
-- Everything locked to beat ONE. Clyde Stubblefield ghost-note style.
-- -------------------------------------------------------------------------
groove.brown_templates = {
  kick  = {T,F,F,F, T,F,F,F, F,F,T,F, F,F,F,T},
  snare = {F,F,F,F, T,F,T,F, F,F,F,F, T,F,T,F},
  hihat = {T,F,T,F, T,F,T,T, T,F,T,F, T,T,T,F},
  bass  = {T,F,F,F, F,T,F,F, T,F,F,F, F,T,F,F},
}

-- -------------------------------------------------------------------------
-- MICROTIMING PROFILES
-- Returns an offset in seconds. Positive = late, negative = early.
-- -------------------------------------------------------------------------
groove.timing_profiles = {
  straight = function(step, division) return 0 end,

  shuffle = function(step, division)
    return (step % 2 == 0) and (division * 0.15) or 0
  end,

  -- Deterministic "random" per step via hash — same every cycle
  aphex = function(step, division)
    local hash = (step * 1613 + 7919) % 100
    return (hash / 100 - 0.5) * division * 0.08
  end,

  -- Frusciante: everything fractionally behind the beat
  behind = function(step, division)
    return division * 0.03
  end,

  -- Bossa: dotted-eighth lean
  bossa = function(step, division)
    local group = math.floor((step - 1) / 3) % 2
    return group == 0 and (division * 0.02) or (-division * 0.01)
  end,
}

-- -------------------------------------------------------------------------
-- PROBABILITY GATE
-- With streak logic — patterns feel musical, not coin-flip random
-- -------------------------------------------------------------------------
function groove.prob_gate(p, streak_min, streak_max)
  streak_min = streak_min or 1
  streak_max = streak_max or 4
  local current_streak = 0
  local current_state  = false

  return function()
    if current_streak <= 0 then
      current_state = math.random() < p
      if current_state then
        current_streak = math.random(streak_min, streak_max)
      else
        current_streak = math.random(1, math.max(1, math.floor((1-p)*3)))
      end
    end
    current_streak = current_streak - 1
    return current_state
  end
end

-- -------------------------------------------------------------------------
-- POLYRHYTHM STACK
-- -------------------------------------------------------------------------
function groove.make_stack(layers)
  local stack = { layers = {} }

  for _, l in ipairs(layers) do
    local layer = {
      pattern  = groove.euclidean(l.steps, l.hits, l.offset or 0),
      steps    = l.steps,
      prob     = l.prob or 1.0,
      timing   = groove.timing_profiles[l.timing or "straight"],
      vel_min  = l.vel_min or 80,
      vel_max  = l.vel_max or 127,
      gate_fn  = groove.prob_gate(l.prob or 1.0),
    }
    table.insert(stack.layers, layer)
  end

  function stack:tick(step, division)
    local events = {}
    for i, layer in ipairs(self.layers) do
      if layer.pattern(step) and layer.gate_fn() then
        local vel = math.floor(
          layer.vel_min + math.random() * (layer.vel_max - layer.vel_min)
        )
        local t_offset = layer.timing(step, division)
        table.insert(events, { layer=i, vel=vel, offset=t_offset })
      end
    end
    return events
  end

  return stack
end

-- -------------------------------------------------------------------------
-- GROOVE PRESETS
-- -------------------------------------------------------------------------
groove.presets = {
  brown = {
    {steps=16, hits=4, offset=0, timing="behind",   vel_min=100, vel_max=127},
    {steps=16, hits=2, offset=4, timing="straight",  vel_min=90,  vel_max=110},
    {steps=16, hits=8, offset=2, timing="shuffle",   vel_min=40,  vel_max=80},
    {steps=16, hits=4, offset=1, timing="behind",    vel_min=60,  vel_max=90},
  },
  bossa = {
    {steps=16, hits=3, offset=0, timing="bossa",    vel_min=70,  vel_max=100},
    {steps=16, hits=2, offset=4, timing="bossa",    vel_min=50,  vel_max=70},
    {steps=16, hits=3, offset=8, timing="bossa",    vel_min=60,  vel_max=80},
    {steps=8,  hits=2, offset=0, timing="behind",   vel_min=40,  vel_max=60},
  },
  aphex = {
    {steps=13, hits=5, offset=0, timing="aphex", vel_min=80,  vel_max=127, prob=0.85},
    {steps=11, hits=4, offset=2, timing="aphex", vel_min=60,  vel_max=100, prob=0.75},
    {steps=7,  hits=3, offset=1, timing="aphex", vel_min=40,  vel_max=80,  prob=0.90},
    {steps=16, hits=2, offset=0, timing="aphex", vel_min=100, vel_max=127, prob=0.70},
  },
  daft = {
    {steps=4,  hits=4, offset=0, timing="straight", vel_min=110, vel_max=127},
    {steps=8,  hits=2, offset=2, timing="straight", vel_min=80,  vel_max=100},
    {steps=16, hits=4, offset=1, timing="shuffle",  vel_min=50,  vel_max=90},
    {steps=16, hits=3, offset=0, timing="shuffle",  vel_min=40,  vel_max=70},
  },
  maya = {
    {steps=16, hits=9, offset=0, timing="aphex",  vel_min=60,  vel_max=127, prob=0.80},
    {steps=12, hits=7, offset=3, timing="behind", vel_min=50,  vel_max=100, prob=0.70},
    {steps=9,  hits=4, offset=1, timing="aphex",  vel_min=80,  vel_max=127, prob=0.85},
    {steps=16, hits=2, offset=8, timing="straight",vel_min=100, vel_max=127, prob=0.60},
  },
}

-- -------------------------------------------------------------------------
-- CALL AND RESPONSE ENGINE
-- BUG FIX v2: separate tick() (advances state) from peek() (read only)
-- -------------------------------------------------------------------------
function groove.make_call_response(call_length, response_length)
  local phase        = "call"
  local counter      = 0
  call_length        = call_length or 8
  response_length    = response_length or 8

  local obj = {}

  -- Advances the counter and flips phase at boundaries
  function obj:tick()
    counter = counter + 1
    if phase == "call" and counter > call_length then
      phase   = "response"
      counter = 1
    elseif phase == "response" and counter > response_length then
      phase   = "call"
      counter = 1
    end
    return phase, counter
  end

  -- Read current state without advancing — safe to call from redraw()
  function obj:peek()
    return phase, counter
  end

  function obj:is_call()     return phase == "call"     end
  function obj:is_response() return phase == "response" end

  function obj:progress()
    local len = (phase == "call") and call_length or response_length
    return counter / len
  end

  return obj
end

return groove
