-- vessel
-- v2.2.0 @tiago
-- llllllll.co
--
-- a conductor for all instruments
-- simple on the surface. complex underneath.
--
-- ┌─ NORNS CONTROLS ──────────────────────────────────────┐
-- │  K2          play / stop                              │
-- │  K3          mutate everything                        │
-- │  K1 (hold)   modifier for encoders                    │
-- │                                                       │
-- │  E1          scale / mode                             │
-- │  E2          groove preset                            │
-- │  E3          density                                  │
-- │                                                       │
-- │  K1 + E1     root note (semitones)                    │
-- │  K1 + E2     chord voicing                            │
-- │  K1 + E3     reverb depth                             │
-- │                                                       │
-- │  NEW v2.2: Audio follow mode (modulates tension)      │
-- │  NEW v2.2: Preset morphing A/B (smooth blending)      │
-- └───────────────────────────────────────────────────────┘
--
-- ┌─ GRID (16x8) ──────────────────────────────────────────┐
-- │  Row 1       melody playhead                           │
-- │  Row 2       scale degree map                          │
-- │  Row 3-4     groove pattern layers                     │
-- │  Row 5       chord voicing selector (tap to choose)    │
-- │  Row 6       scale selector (tap to choose)            │
-- │  Row 7       density scrub (tap column = set density)  │
-- │  Row 8 col1  play / stop                               │
-- │  Row 8 c3-8  groove preset                             │
-- │              (brown/bossa/aphex/daft/maya/eno)         │
-- │  Row 8 c16   mutate                                    │
-- │                                                        │
-- │  K1+K2: save preset A    K1+K3: save preset B          │
-- │  E3 (K1): morph A ↔ B with smooth crossfade           │
-- └────────────────────────────────────────────────────────┘

engine.name = "VESSEL"

local scales  = include("vessel/lib/scales")
local groove  = include("vessel/lib/groove")
local oracle  = include("vessel/lib/oracle")
local tension = include("vessel/lib/tension")
local lattice  = require("lattice")
local musicutil = require("musicutil")