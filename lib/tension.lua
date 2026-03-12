-- lib/tension.lua
-- VESSEL harmonic arc system
-- Tension builds over 8-bar cycles and releases on the ONE
-- Affects: chord complexity, density multiplier, filter automation,
--          reverb depth, melody register
-- Inspired by: Daft Punk's slow automation, Bossa Nova's unresolved tension,
--              James Brown's building to a break

local tension = {}

-- -------------------------------------------------------------------------
-- STATE
-- -------------------------------------------------------------------------
tension.value         = 0.0    -- current tension 0..1
tension.target        = 0.0    -- where we're headed
tension.rise_rate     = 0.008  -- per beat increase
tension.fall_rate     = 0.25   -- on release: fast drop
tension.bar           = 0      -- current bar count
tension.release_bar   = 8      -- release every N bars (adjustable)
tension.just_released = false  -- true for one tick after a release

-- Internal
local bars_in_cycle   = 0
local pre_release_val = 0      -- value at moment of release (for flash)

-- -------------------------------------------------------------------------
-- TICK: call once per bar (every 4 beats in the lattice)
-- Returns true on the bar of release (for scripted events)
-- -------------------------------------------------------------------------
function tension.tick_bar()
  tension.just_released = false
  bars_in_cycle         = bars_in_cycle + 1
  tension.bar           = bars_in_cycle

  if bars_in_cycle >= tension.release_bar then
    -- RELEASE — the tension breaks
    pre_release_val       = tension.value
    tension.target        = 0.0
    bars_in_cycle         = 0
    tension.just_released = true
    return true  -- signal to caller: something should happen musically
  else
    -- BUILD — tension rises toward target
    tension.target = math.min(1.0, bars_in_cycle / tension.release_bar)
    return false
  end
end

-- -------------------------------------------------------------------------
-- SMOOTH UPDATE: call every redraw tick (lerp toward target)
-- -------------------------------------------------------------------------
function tension.update()
  if tension.just_released then
    -- Fast fall on release
    tension.value = tension.value - tension.fall_rate
    if tension.value < tension.target then
      tension.value = tension.target
    end
  else
    -- Slow rise
    tension.value = tension.value + (tension.target - tension.value) * 0.05
  end
  tension.value = math.max(0, math.min(1, tension.value))
end

-- -------------------------------------------------------------------------
-- DERIVED VALUES
-- All values are functions of tension.value — computed on demand
-- -------------------------------------------------------------------------

-- Melody register: low tension = lower octave, high = upper register
function tension.melody_octave()
  return (tension.value > 0.6) and 2 or 1
end

-- Filter cutoff for OP-XY: opens as tension rises, snaps closed on release
function tension.filter_cc()
  if tension.just_released then return 20 end  -- snap closed
  return math.floor(20 + tension.value * 107)  -- 20..127
end

-- Reverb depth: more space at high tension (things start to blur)
function tension.reverb_depth()
  return 0.1 + tension.value * 0.35
end

-- Chord complexity: low = simple triads, high = extended voicings
-- Returns 0..3 where 0=triad, 1=7th, 2=9th, 3=full extension
function tension.chord_complexity()
  if tension.value < 0.25 then return 0
  elseif tension.value < 0.5 then return 1
  elseif tension.value < 0.75 then return 2
  else return 3 end
end

-- Density multiplier: more events at high tension
function tension.density_mult()
  return 0.7 + tension.value * 0.6
end

-- Harmonic transposition tendency:
-- Returns a semitone offset that creates increasing harmonic tension
-- Low: stay on tonic; high: tritone substitute / augmented chord territory
function tension.harm_offset()
  if tension.value < 0.3 then return 0
  elseif tension.value < 0.6 then return 7   -- dominant
  elseif tension.value < 0.85 then return 11  -- leading tone
  else return 6 end                            -- tritone — maximum tension
end

-- Visual bar representation for screen (width in pixels, max=46)
function tension.bar_width()
  return math.floor(tension.value * 46)
end

-- Brightness for grid (0..15)
function tension.grid_bright()
  return math.floor(3 + tension.value * 12)
end

-- -------------------------------------------------------------------------
-- HARMONIC PROGRESSION TABLES
-- Indexed by tension.chord_complexity()
-- Each entry: list of scale-degree transpositions for a 4-bar cycle
-- -------------------------------------------------------------------------
tension.progressions = {
  -- 0: Simple — stay near tonic
  [0] = { {0,0,0,0}, {0,5,7,0} },
  -- 1: 7th territory — Daft Punk/modal
  [1] = { {0,-2,5,7}, {0,5,-7,3} },
  -- 2: Extended — Bossa Nova / jazz substitution
  [2] = { {0,-2,5,-5}, {0,3,-4,7}, {0,-5,4,-2} },
  -- 3: Full tension — tritone subs, chromatic voice leading
  [3] = { {0,6,-1,5}, {0,-6,11,-5}, {1,6,-2,7} },
}

function tension.get_progression()
  local complexity = tension.chord_complexity()
  local pool       = tension.progressions[complexity]
  if pool and #pool > 0 then
    return pool[math.random(#pool)]
  end
  return {0,0,0,0}
end

return tension
