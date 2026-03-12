-- lib/scales.lua
-- VESSEL custom scale library
-- Beyond musicutil: microtonal, world, and invented scales
-- All scales defined as Hz ratios from root (1.0 = root)
-- Use: scales.get_freq(root_hz, scale_name, degree)

local scales = {}

-- Equal temperament helper
local function et(semitones)
  return 2 ^ (semitones / 12)
end

-- Just intonation ratios
local function ji(num, den)
  return num / den
end

-- Equal division of any interval
local function ed(steps, total_steps, interval)
  return interval ^ (steps / total_steps)
end

-- -------------------------------------------------------------------------
-- SCALE DEFINITIONS
-- Each scale = array of ratios from root (root = 1.0)
-- -------------------------------------------------------------------------

scales.defs = {

  -- Standard (for reference)
  chromatic     = {1, et(1), et(2), et(3), et(4), et(5), et(6), et(7), et(8), et(9), et(10), et(11), 2},
  major         = {1, et(2), et(4), et(5), et(7), et(9), et(11), 2},
  minor         = {1, et(2), et(3), et(5), et(7), et(8), et(10), 2},
  dorian        = {1, et(2), et(3), et(5), et(7), et(9), et(10), 2},
  phrygian      = {1, et(1), et(3), et(5), et(7), et(8), et(10), 2},
  lydian        = {1, et(2), et(4), et(6), et(7), et(9), et(11), 2},
  mixolydian    = {1, et(2), et(4), et(5), et(7), et(9), et(10), 2},

  -- Pentatonics
  pentatonic_maj = {1, et(2), et(4), et(7), et(9), 2},
  pentatonic_min = {1, et(3), et(5), et(7), et(10), 2},
  pentatonic_blues = {1, et(3), et(5), et(6), et(7), et(10), 2},

  -- Just Intonation — pure intervals, beautiful beating
  just_major    = {1, ji(9,8), ji(5,4), ji(4,3), ji(3,2), ji(5,3), ji(15,8), 2},
  just_minor    = {1, ji(9,8), ji(6,5), ji(4,3), ji(3,2), ji(8,5), ji(9,5), 2},
  harmonic_series = {1, ji(9,8), ji(5,4), ji(11,8), ji(3,2), ji(13,8), ji(7,4), 2},
  -- The 7th harmonic (7/4) is the "blue note" — between minor and major 7th

  -- Quarter-tone scale (24-TET subset) — Arabic maqam territory
  maqam_rast    = {1, et(2), et(3.5), et(5), et(7), et(9), et(10.5), 2},
  maqam_bayati  = {1, et(1.5), et(3), et(5), et(7), et(8), et(10), 2},
  maqam_hijaz   = {1, et(1), et(4), et(5), et(7), et(8), et(11), 2},

  -- Gamelan tunings (approximate — intentionally irrational)
  -- Pelog: 7-tone unequal, use 5 of 7 in practice
  pelog         = {1, 1.080, 1.210, 1.350, 1.517, 1.680, 1.882, 2},
  -- Slendro: 5-tone near-equal but not quite
  slendro       = {1, 1.136, 1.290, 1.503, 1.706, 2},

  -- Bohlen-Pierce: tritave-based (3:1 not 2:1), 13 steps per tritave
  -- Profoundly alien. No octave. Ever.
  bohlen_pierce = {
    1,
    ed(1,13,3), ed(2,13,3), ed(3,13,3), ed(4,13,3),
    ed(5,13,3), ed(6,13,3), ed(7,13,3), ed(8,13,3),
    ed(9,13,3), ed(10,13,3), ed(11,13,3), ed(12,13,3),
    3  -- tritave, not octave
  },

  -- Invented scales --------------------------------------------------------

  -- VESSEL: A 9-tone scale built from alternating minor 2nds and minor 3rds
  -- Creates a dense, chromatic-but-not feeling. Good for ambient.
  vessel_9      = {1, et(1), et(4), et(5), et(8), et(9), et(12), et(13), et(16), 2},

  -- GRAVITY: Descending bias — intervals get smaller going up
  -- Like a musical black hole
  gravity       = {1, et(3), et(5), et(6), et(7), et(7.5), et(8), et(8.5), 2},

  -- BOSSA GHOST: Extended Bossa voicings as a scale
  -- maj9, sus4, dim7 tones coexisting
  bossa_ghost   = {1, et(2), et(4), et(5), et(6), et(7), et(9), et(11), 2},

  -- BROWN: James Brown funk scale — blues + mixolydian hybrid
  -- The "money" pentatonic with added flat 7 and flat 5
  brown         = {1, et(3), et(5), et(6), et(7), et(10), et(11), 2},

  -- APHEX: Whole tone + chromatic intrusions
  -- Dreamlike, no strong tonal center
  aphex         = {1, et(2), et(4), et(6), et(7), et(8), et(10), 2},

  -- DAFT: Disco-funk major with all the extensions present as a scale
  -- Every degree is a potential chord tone
  daft          = {1, et(2), et(4), et(5), et(7), et(9), et(10), et(11), 2},

  -- FRUSCIANTE: Phrygian dominant (Spanish/flamenco feeling + rock edge)
  frusciante    = {1, et(1), et(4), et(5), et(7), et(8), et(10), 2},

  -- DRIFT: Microtonal 19-TET subset — "almost major but not quite"
  -- Pitches drift between familiar and alien
  drift         = {
    1,
    2^(2/19), 2^(3/19), 2^(5/19),
    2^(8/19), 2^(11/19), 2^(13/19),
    2^(16/19), 2
  },
}

-- -------------------------------------------------------------------------
-- SCALE NAMES for UI display
-- -------------------------------------------------------------------------
scales.names = {}
for k, _ in pairs(scales.defs) do
  table.insert(scales.names, k)
end
table.sort(scales.names)

-- Get scale index by name
scales.name_idx = {}
for i, name in ipairs(scales.names) do
  scales.name_idx[name] = i
end

-- -------------------------------------------------------------------------
-- CHORD VOICINGS
-- Returns 4-note chord as ratios
-- Based on Daft Punk + Bossa Nova extended harmony
-- -------------------------------------------------------------------------
scales.chords = {
  maj7    = {1, ji(5,4), ji(3,2), ji(15,8)},
  min7    = {1, ji(6,5), ji(3,2), ji(9,5)},
  dom7    = {1, ji(5,4), ji(3,2), ji(7,4)},  -- pure 7th harmonic!
  maj9    = {1, ji(5,4), ji(3,2), ji(9,8) * 2},
  min9    = {1, ji(6,5), ji(3,2), ji(9,8) * 2},
  sus2    = {1, ji(9,8), ji(3,2), 2},
  sus4    = {1, ji(4,3), ji(3,2), 2},
  add9    = {1, ji(5,4), ji(3,2), ji(9,8) * 2},
  dim7    = {1, et(3), et(6), et(9)},
  aug     = {1, et(4), et(8), 2},
  -- Invented
  vessel_chord = {1, ji(9,8), ji(11,8), ji(7,4)},  -- 2nd + tritone + blue 7th
  bossa_chord  = {1, ji(5,4), ji(4,3), ji(7,4)},   -- maj3 + 4th + blue 7th
  brown_chord  = {1, et(3), ji(3,2), et(10)},       -- min3 + 5th + min7
  drift_chord  = {1, 2^(5/19) * 1, 2^(11/19), 2^(16/19)},
}

scales.chord_names = {}
for k, _ in pairs(scales.chords) do
  table.insert(scales.chord_names, k)
end
table.sort(scales.chord_names)

-- -------------------------------------------------------------------------
-- CORE FUNCTIONS
-- -------------------------------------------------------------------------

-- Get frequency from root Hz, scale name, and degree (1-based)
function scales.get_freq(root_hz, scale_name, degree)
  local def = scales.defs[scale_name]
  if def == nil then
    def = scales.defs["major"]
  end
  local len = #def
  local octave = math.floor((degree - 1) / (len - 1))
  local idx = ((degree - 1) % (len - 1)) + 1
  local ratio = def[idx]
  -- Handle Bohlen-Pierce (tritave, not octave)
  local period = (scale_name == "bohlen_pierce") and 3 or 2
  return root_hz * ratio * (period ^ octave)
end

-- Get chord frequencies from root Hz, chord name
function scales.get_chord(root_hz, chord_name)
  local def = scales.chords[chord_name]
  if def == nil then def = scales.chords["maj7"] end
  local freqs = {}
  for _, ratio in ipairs(def) do
    table.insert(freqs, root_hz * ratio)
  end
  return freqs
end

-- Scale length (without octave endpoint)
function scales.length(scale_name)
  local def = scales.defs[scale_name]
  if def == nil then return 7 end
  return #def - 1
end

-- Nearest scale degree to a given ratio
function scales.nearest_degree(scale_name, ratio)
  local def = scales.defs[scale_name]
  if def == nil then return 1 end
  local best, best_dist = 1, math.huge
  for i, r in ipairs(def) do
    local dist = math.abs(r - ratio)
    if dist < best_dist then best, best_dist = i, dist end
  end
  return best
end

-- MIDI note to microtonal Hz via pitch bend
-- Returns {note, bend} where bend is -8192 to 8191 (assuming 2-semitone range)
-- Use params.midi_bend_range to set range on receiving device
function scales.freq_to_midi_bend(freq, bend_range)
  bend_range = bend_range or 2
  local exact = 69 + 12 * math.log(freq / 440, 2)
  local note = math.floor(exact + 0.5)
  local cents = (exact - note) * 100
  local bend = math.floor((cents / (bend_range * 100)) * 8191)
  bend = math.max(-8191, math.min(8191, bend))
  return note, bend
end

return scales
