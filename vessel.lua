-- vessel
-- v2.3.0 @tiago
-- llllllll.co
--
-- a conductor for all instruments
-- simple on the surface. complex underneath.
--
-- ┌─ NORNS CONTROLS ─────────────────────────────────┐
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
-- │  K1 + E3     morph A/B                                │
-- │                                                       │
-- │  K1 + K2     save preset A                            │
-- │  K1 + K3     save preset B                            │
-- │                                                       │
-- │  Audio follow mode (modulates tension)                │
-- │  Preset morphing A/B (smooth blending)                │
-- └───────────────────────────────────────────────────┘
--
-- ┌─ GRID (16x8) ────────────────────────────────────────┐
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
-- └────────────────────────────────────────────────────

engine.name = "VESSEL"

local scales  = include("vessel/lib/scales")
local groove  = include("vessel/lib/groove")
local oracle  = include("vessel/lib/oracle")
local tension = include("vessel/lib/tension")
local lattice_lib = require("lattice")
local musicutil = require("musicutil")

-- ────────────────────────────────────────────────────────────────────────────────
-- STATE
-- ────────────────────────────────────────────────────────────────────────────────
local state = {
  playing      = false,
  step         = 0,
  scale_idx    = scales.name_idx["dorian"] or 1,
  chord_idx    = 1,
  groove_idx   = 1,
  density      = 0.65,
  root_note    = 48,
  reverb       = 0.15,
  tape_sat     = 0.2,
  key1_down    = false,
  screen_dirty = true,
  grid_dirty   = true,
  bar          = 0,          -- bar counter for tension arc
  progression  = {0,0,0,0},  -- current harmonic offsets
  prog_step    = 1,          -- which step in progression
  beat_in_bar  = 0,          -- beat counter within current bar
}

-- ────────────────────────────────────────────────────────────────────────────────
-- SCREEN STATE (enhancements)
-- ────────────────────────────────────────────────────────────────────────────────
local screen_state = {
  show_detailed_tension = true,
  show_tutti_solo_state = true,
  show_section_marker   = true,
  section_name          = "A",
  midi_clock_indicator  = false,
}

-- ────────────────────────────────────────────────────────────────────────────────
-- AUDIO FOLLOW & MIDI CLOCK STATE
-- ────────────────────────────────────────────────────────────────────────────────
local audio_follow_mode = false
local midi_clock_ticks = 0
local midi_clock_ppq = 24  -- default: 24 ticks per quarter note
local is_receiving_midi_clock = false
local midi_out = nil

-- ────────────────────────────────────────────────────────────────────────────────
-- TUTTI/SOLI STATE (section orchestration)
-- ────────────────────────────────────────────────────────────────────────────────
local tutti_soli_state = {
  mode = "tutti",  -- "tutti" or "soli"
  soli_map = {},
  current_section = 1,
}

-- ────────────────────────────────────────────────────────────────────────────────
-- PRESET MORPHING (A/B blending)
-- ────────────────────────────────────────────────────────────────────────────────
local presets = {
  a = {
    scale_idx = 1,
    chord_idx = 1,
    groove_idx = 1,
    density = 0.65,
    root_note = 48,
  },
  b = {
    scale_idx = 2,
    chord_idx = 2,
    groove_idx = 2,
    density = 0.55,
    root_note = 45,
  },
  morph_amount = 0,  -- 0 = all A, 1 = all B
}

-- ────────────────────────────────────────────────────────────────────────────────
-- TENSION ARC
-- ────────────────────────────────────────────────────────────────────────────────
local tension_arc = {
  enabled = true,
  bars_per_cycle = 32,
  current_position = 0,  -- 0..1 within cycle
  visualization_data = {},
}

-- ────────────────────────────────────────────────────────────────────────────────
-- OP-XY MIDI MULTI-CHANNEL
-- ────────────────────────────────────────────────────────────────────────────────
local opxy_out = nil
local opxy_enabled = false
local opxy_device = 1
local opxy_voice_channels = {
  harm = 1,
  bass = 2,
  texture = 3,
  chord = 4,
}

-- ────────────────────────────────────────────────────────────────────────────────
-- ACTIVE NOTE TRACKING (for proper cleanup)
-- ────────────────────────────────────────────────────────────────────────────────
local active_notes = {}  -- {voice_name = {note1, note2, ...}}
local note_off_clocks = {}  -- clock ids for scheduled note-offs

local function track_note_on(voice_name, note)
  if not active_notes[voice_name] then
    active_notes[voice_name] = {}
  end
  active_notes[voice_name][note] = true
end

local function track_note_off(voice_name, note)
  if active_notes[voice_name] then
    active_notes[voice_name][note] = nil
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- OP-XY MIDI HELPERS
-- ────────────────────────────────────────────────────────────────────────────────

local function opxy_note_on(voice_name, note, vel)
  if opxy_out and opxy_enabled and opxy_voice_channels[voice_name] then
    local ch = opxy_voice_channels[voice_name]
    local n = util.clamp(math.floor(note), 0, 127)
    local v = util.clamp(math.floor(vel), 0, 127)
    opxy_out:note_on(n, v, ch)
  end
end

local function opxy_note_off(voice_name, note)
  if opxy_out and opxy_enabled and opxy_voice_channels[voice_name] then
    local ch = opxy_voice_channels[voice_name]
    local n = util.clamp(math.floor(note), 0, 127)
    opxy_out:note_off(n, 0, ch)
  end
end

local function opxy_cc(voice_name, cc_num, val)
  if opxy_out and opxy_enabled and opxy_voice_channels[voice_name] then
    local ch = opxy_voice_channels[voice_name]
    opxy_out:cc(util.clamp(math.floor(cc_num), 0, 127),
                util.clamp(math.floor(val), 0, 127), ch)
  end
end

local function opxy_all_notes_off()
  if opxy_out and opxy_enabled then
    for _, ch in pairs(opxy_voice_channels) do
      opxy_out:cc(123, 0, ch)
    end
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- GRID & ARC DEVICES
-- ────────────────────────────────────────────────────────────────────────────────
local g = nil  -- grid device
local a = nil  -- arc device

-- ────────────────────────────────────────────────────────────────────────────────
-- LATTICE & GROOVE STACK
-- ────────────────────────────────────────────────────────────────────────────────
local the_lattice = nil
local the_groove_stack = nil
local groove_preset_names = {"brown", "bossa", "aphex", "daft", "maya"}
local redraw_metro = nil

-- ────────────────────────────────────────────────────────────────────────────────
-- INIT / CLEANUP
-- ────────────────────────────────────────────────────────────────────────────────

function init()
  -- lattice setup
  the_lattice = lattice_lib:new{ppqn = 96}

  -- build initial groove stack
  rebuild_groove_stack()

  -- add lattice patterns
  -- 16th note pattern: drives groove engine
  the_lattice:new_pattern{
    action = function(t) on_step(t) end,
    division = 1/16,
  }

  -- bar-level pattern: drives tension arc
  the_lattice:new_pattern{
    action = function(t) on_bar(t) end,
    division = 1,  -- whole note = 1 bar
  }

  -- MIDI setup
  midi_out = midi.connect(1)

  -- ── Engine params ──
  params:add_separator("VESSEL Engine")

  params:add_control("reverb", "reverb depth",
    controlspec.new(0, 1, "lin", 0.01, 0.15))
  params:set_action("reverb", function(v)
    engine.set_rev(v)
    state.reverb = v
  end)

  params:add_control("tape_sat", "tape saturation",
    controlspec.new(0, 1, "lin", 0.01, 0.2))
  params:set_action("tape_sat", function(v)
    engine.set_tape(v)
    state.tape_sat = v
  end)

  -- ── Network params ──
  params:add_separator("Network")
  params:add_number("midi_out_device", "MIDI Out", 1, 16, 1)
  params:set_action("midi_out_device", function(val)
    midi_out = midi.connect(val)
  end)

  -- ── OP-XY params ──
  params:add_separator("OP-XY")
  params:add_option("opxy_enabled", "OP-XY output", {"off", "on"}, 1)
  params:set_action("opxy_enabled", function(x)
    opxy_enabled = (x == 2)
    if opxy_enabled and opxy_out == nil then
      opxy_out = midi.connect(params:get("opxy_device"))
    end
  end)
  params:add_number("opxy_device", "OP-XY MIDI device", 1, 4, 1)
  params:set_action("opxy_device", function(val)
    opxy_out = midi.connect(val)
  end)
  params:add_number("opxy_ch_harm", "OP-XY harm channel", 1, 16, 1)
  params:set_action("opxy_ch_harm", function(x) opxy_voice_channels.harm = x end)
  params:add_number("opxy_ch_bass", "OP-XY bass channel", 1, 16, 2)
  params:set_action("opxy_ch_bass", function(x) opxy_voice_channels.bass = x end)
  params:add_number("opxy_ch_texture", "OP-XY texture channel", 1, 16, 3)
  params:set_action("opxy_ch_texture", function(x) opxy_voice_channels.texture = x end)
  params:add_number("opxy_ch_chord", "OP-XY chord channel", 1, 16, 4)
  params:set_action("opxy_ch_chord", function(x) opxy_voice_channels.chord = x end)

  -- ── Audio follow ──
  params:add_separator("Audio Follow")
  params:add_option("audio_follow", "audio follow mode", {"off", "on"}, 1)
  params:set_action("audio_follow", function(x) audio_follow_mode = (x == 2) end)

  -- UI encoder sensitivity
  norns.enc.sens(1, 4)
  norns.enc.sens(2, 4)
  norns.enc.sens(3, 2)

  -- Screen redraw metro at 15fps
  redraw_metro = metro.init()
  redraw_metro.event = function()
    if state.screen_dirty then
      redraw()
      state.screen_dirty = false
    end
    -- Grid redraw
    if state.grid_dirty and g then
      grid_redraw()
      state.grid_dirty = false
    end
    -- Tension smooth update
    tension.update()
    oracle.update()
  end
  redraw_metro:start(1/15)

  -- Grid connect (with nil safety)
  g = grid.connect()
  if g then
    g.key = function(x, y, z)
      handle_grid_key(x, y, z)
    end
  end

  -- Arc connect (with nil safety)
  a = arc.connect()
  if a then
    a.delta = function(n, d)
      handle_arc_encoder(n, d)
    end
  end

  -- Start lattice (but don't play notes until state.playing = true)
  the_lattice:start()

  state.grid_dirty = true
  state.screen_dirty = true
end

-- ────────────────────────────────────────────────────────────────────────────────
-- GROOVE STACK REBUILD (when preset changes)
-- ────────────────────────────────────────────────────────────────────────────────

function rebuild_groove_stack()
  local preset_name = groove_preset_names[state.groove_idx] or "brown"
  local preset_def = groove.presets[preset_name]
  if preset_def then
    the_groove_stack = groove.make_stack(preset_def)
  else
    the_groove_stack = groove.make_stack(groove.presets["brown"])
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- LATTICE CALLBACKS
-- ────────────────────────────────────────────────────────────────────────────────

function on_step(t)
  if not state.playing then return end

  state.step = state.step + 1

  -- Track beats within bar (16 sixteenths per bar)
  state.beat_in_bar = ((state.step - 1) % 16) + 1

  -- Get groove events for this step
  if the_groove_stack then
    local division = clock.get_beat_sec() / 4  -- sixteenth note duration
    local events = the_groove_stack:tick(state.step, division)

    for _, ev in ipairs(events) do
      -- Map layer to voice
      if ev.layer == 1 then
        -- Harmonic voice
        local scale_name = scales.names[state.scale_idx] or "major"
        local root_hz = musicutil.note_num_to_freq(state.root_note)
        local degree = ((state.step - 1) % scales.length(scale_name)) + 1
        local offset = state.progression[state.prog_step] or 0
        local freq = scales.get_freq(root_hz, scale_name, degree)

        -- Density gate: skip some notes at low density
        if math.random() < state.density then
          local oct = tension.melody_octave()
          play_harm(freq * (2 ^ (oct - 1)), ev.vel / 127)
          local midi_note = util.clamp(state.root_note + offset + (degree - 1) + (oct - 1) * 12, 0, 127)
          opxy_note_on("harm", midi_note, ev.vel)
          track_note_on("harm", midi_note)
          -- Schedule note off
          local cid = clock.run(function()
            clock.sleep(division * 2)
            opxy_note_off("harm", midi_note)
            track_note_off("harm", midi_note)
          end)
          table.insert(note_off_clocks, cid)
        end

      elseif ev.layer == 2 then
        -- Bass voice
        local root_hz = musicutil.note_num_to_freq(state.root_note - 12)
        local offset = state.progression[state.prog_step] or 0
        local bass_hz = root_hz * (2 ^ (offset / 12))
        if math.random() < state.density * 1.2 then
          play_bass(bass_hz, ev.vel / 127)
          local midi_note = util.clamp(state.root_note - 12 + offset, 0, 127)
          opxy_note_on("bass", midi_note, ev.vel)
          track_note_on("bass", midi_note)
          local cid = clock.run(function()
            clock.sleep(division * 4)
            opxy_note_off("bass", midi_note)
            track_note_off("bass", midi_note)
          end)
          table.insert(note_off_clocks, cid)
        end

      elseif ev.layer == 3 then
        -- Percussion
        local perc_freq = 100 + (state.step % 8) * 50
        play_perc(perc_freq, ev.vel / 127, 0.5, 0.3, 0.3)

      elseif ev.layer == 4 then
        -- Texture / pad trigger (on beat 1 only, or at low density)
        if state.beat_in_bar == 1 then
          local root_hz = musicutil.note_num_to_freq(state.root_note)
          play_texture(root_hz, 0.25, 15, tension.filter_cc() * 20)
        end
      end
    end
  end

  -- Oracle word tick (once per beat = every 4 sixteenths)
  if state.step % 4 == 0 then
    local preset_name = groove_preset_names[state.groove_idx] or "brown"
    oracle.tick(preset_name, tension.value, "call")
  end

  state.screen_dirty = true
  state.grid_dirty = true
end

function on_bar(t)
  if not state.playing then return end

  state.bar = state.bar + 1

  -- Advance progression step every bar (4-step cycle)
  state.prog_step = ((state.bar - 1) % 4) + 1

  -- Tension arc: tick every bar
  local released = tension.tick_bar()

  if released then
    -- On tension release: get new progression, flash oracle
    state.progression = tension.get_progression()
    oracle.flash("RELEASE", 1.0)

    -- Trigger chord change on release
    local root_hz = musicutil.note_num_to_freq(state.root_note)
    local chord_name = scales.chord_names[state.chord_idx] or "maj7"
    local freqs = scales.get_chord(root_hz, chord_name)
    if #freqs >= 4 then
      play_chord(freqs[1], freqs[2], freqs[3], freqs[4], 0.3, 0.08, tension.filter_cc() * 20)
    end
  end

  -- Update tension arc position for visualization
  if tension_arc.bars_per_cycle > 0 then
    tension_arc.current_position = (state.bar % tension_arc.bars_per_cycle) / tension_arc.bars_per_cycle
  end

  -- Send tension-mapped CCs to OP-XY voices
  local tension_val = tension.value
  opxy_cc("bass", 32, util.linlin(0, 1, 40, 120, tension_val))
  opxy_cc("bass", 46, util.linlin(0, 1, 0, 100, tension_val))
  opxy_cc("harm", 32, util.linlin(0, 1, 80, 110, tension_val))
  opxy_cc("texture", 32, util.linlin(0, 1, 60, 127, tension_val))

  state.screen_dirty = true
end

-- ────────────────────────────────────────────────────────────────────────────────
-- ENGINE VOICE WRAPPERS
-- (match actual Engine_VESSEL addCommand signatures)
-- ────────────────────────────────────────────────────────────────────────────────

function play_harm(freq, amp)
  freq = math.max(20, math.min(freq, 16000))
  amp = util.clamp(amp, 0, 1)
  engine.harm_on(
    1,         -- voice id
    freq,      -- freq
    amp,       -- amp
    0.01,      -- atk
    0.1,       -- dec
    0.7,       -- sus
    0.8,       -- rel
    0.3,       -- fb
    2.0,       -- ratio
    0.5,       -- idx
    0,         -- pan
    tension.filter_cc() * 30  -- cutoff
  )
end

function play_bass(freq, amp)
  freq = math.max(20, math.min(freq, 4000))
  amp = util.clamp(amp, 0, 1)
  engine.bass_on(
    1,         -- voice id
    freq,      -- freq
    amp,       -- amp
    0.5,       -- brightness
    0.5,       -- damping
    0.4        -- sub_mix
  )
end

function play_texture(freq, amp, density_val, cutoff)
  freq = math.max(20, math.min(freq, 8000))
  amp = util.clamp(amp or 0.25, 0, 1)
  engine.texture_on(
    1,           -- voice id
    freq,        -- freq
    amp,         -- amp
    density_val or 15,  -- density
    cutoff or 1200      -- cutoff
  )
end

function play_perc(freq, amp, tone, body, decay)
  freq = math.max(20, math.min(freq, 8000))
  amp = util.clamp(amp, 0, 1)
  engine.perc(
    1,             -- voice id
    freq,          -- freq
    amp,           -- amp
    tone or 0.5,   -- tone
    body or 0.3,   -- body
    decay or 0.3   -- decay
  )
end

function play_chord(f1, f2, f3, f4, amp, atk, cutoff)
  amp = util.clamp(amp or 0.3, 0, 1)
  engine.chord_on(
    1,             -- voice id
    f1 or 261,     -- freq1
    f2 or 329,     -- freq2
    f3 or 392,     -- freq3
    f4 or 440,     -- freq4
    amp,           -- amp
    atk or 0.08,   -- atk
    cutoff or 3000 -- cutoff
  )
end

-- ────────────────────────────────────────────────────────────────────────────────
-- NOTE OFF / ALL NOTES OFF
-- ────────────────────────────────────────────────────────────────────────────────

function all_notes_off()
  -- Engine voices off
  pcall(function() engine.harm_off(1) end)
  pcall(function() engine.bass_off(1) end)
  pcall(function() engine.texture_off(1) end)
  pcall(function() engine.chord_off(1) end)

  -- OP-XY all notes off
  opxy_all_notes_off()

  -- Cancel all scheduled note-off clocks
  for _, cid in ipairs(note_off_clocks) do
    pcall(function() clock.cancel(cid) end)
  end
  note_off_clocks = {}

  -- Clear tracked notes with proper MIDI note-offs
  for voice_name, notes in pairs(active_notes) do
    for note, _ in pairs(notes) do
      opxy_note_off(voice_name, note)
    end
  end
  active_notes = {}
end

-- ────────────────────────────────────────────────────────────────────────────────
-- GRID DISPLAY
-- ────────────────────────────────────────────────────────────────────────────────

function grid_redraw()
  if not g.device then return end
  if not g then return end

  g:all(0)

  local scale_name = scales.names[state.scale_idx] or "major"
  local scale_len = scales.length(scale_name)
  local t_bright = tension.grid_bright()

  -- Row 1: melody playhead (shows current step position within 16)
  local playhead_col = ((state.step - 1) % 16) + 1
  for x = 1, 16 do
    if x == playhead_col and state.playing then
      g:led(x, 1, 15)
    else
      g:led(x, 1, 2)
    end
  end

  -- Row 2: scale degree map (highlight degrees that exist in scale)
  for x = 1, math.min(16, scale_len) do
    g:led(x, 2, 6)
  end

  -- Row 3-4: groove pattern visualization
  if the_groove_stack and the_groove_stack.layers then
    for layer_idx = 1, math.min(2, #the_groove_stack.layers) do
      local row = layer_idx + 2
      local layer = the_groove_stack.layers[layer_idx]
      if layer and layer.pattern then
        for x = 1, 16 do
          local is_hit = layer.pattern(x)
          local bright = is_hit and 8 or 1
          -- Highlight current step
          if x == playhead_col and state.playing then
            bright = is_hit and 15 or 4
          end
          g:led(x, row, bright)
        end
      end
    end
  end

  -- Row 5: chord voicing selector
  local chord_count = math.min(16, #scales.chord_names)
  for x = 1, chord_count do
    g:led(x, 5, x == state.chord_idx and 12 or 3)
  end

  -- Row 6: scale selector
  local scale_count = math.min(16, #scales.names)
  for x = 1, scale_count do
    g:led(x, 6, x == state.scale_idx and 12 or 3)
  end

  -- Row 7: density scrub
  local density_col = math.floor(state.density * 15) + 1
  for x = 1, 16 do
    g:led(x, 7, x <= density_col and t_bright or 1)
  end

  -- Row 8: transport + groove presets + mutate
  -- Col 1: play/stop
  g:led(1, 8, state.playing and 15 or 4)
  -- Col 3-8: groove presets (up to 5 presets + 1)
  for i = 1, #groove_preset_names do
    local x = i + 2
    if x <= 8 then
      g:led(x, 8, state.groove_idx == i and 12 or 4)
    end
  end
  -- Col 16: mutate
  g:led(16, 8, 8)

  g:refresh()
end

-- ────────────────────────────────────────────────────────────────────────────────
-- GRID KEY HANDLING
-- ────────────────────────────────────────────────────────────────────────────────

function handle_grid_key(x, y, z)
  if z ~= 1 then return end  -- only respond to key presses

  if y == 1 then
    -- melody playhead position
    state.step = x - 1
    state.screen_dirty = true

  elseif y == 2 then
    -- scale degree map (not directly selectable, informational)

  elseif y == 3 or y == 4 then
    -- groove pattern layers (future: pattern editing)
    state.grid_dirty = true

  elseif y == 5 then
    -- chord voicing selector
    local chord_count = #scales.chord_names
    if x >= 1 and x <= chord_count then
      state.chord_idx = x
      state.screen_dirty = true
    end

  elseif y == 6 then
    -- scale selector
    local scale_count = #scales.names
    if x >= 1 and x <= scale_count then
      state.scale_idx = x
      state.screen_dirty = true
    end

  elseif y == 7 then
    -- density scrub
    state.density = util.clamp((x - 1) / 15, 0, 1)
    state.screen_dirty = true

  elseif y == 8 then
    if x == 1 then
      -- play / stop
      toggle_play()
    elseif x >= 3 and x <= 2 + #groove_preset_names then
      -- groove preset
      local new_idx = x - 2
      if new_idx ~= state.groove_idx then
        state.groove_idx = new_idx
        rebuild_groove_stack()
      end
      state.grid_dirty = true
      state.screen_dirty = true
    elseif x == 16 then
      -- mutate everything
      mutate_all()
      state.screen_dirty = true
    end
  end

  state.grid_dirty = true
end

-- ────────────────────────────────────────────────────────────────────────────────
-- SCREEN / VISUALIZATION
-- ────────────────────────────────────────────────────────────────────────────────

function redraw()
  screen.clear()
  screen.aa(1)

  -- title
  screen.level(15)
  screen.move(8, 10)
  screen.text("VESSEL v2.3")

  -- state info
  screen.level(10)
  screen.move(8, 22)
  screen.text("Scale: " .. (scales.names[state.scale_idx] or "?"))

  screen.move(8, 32)
  local chord_name = scales.chord_names[state.chord_idx] or "?"
  local groove_name = groove_preset_names[state.groove_idx] or "?"
  screen.text(chord_name .. " | " .. groove_name)

  screen.move(8, 42)
  screen.text("Dens: " .. string.format("%.0f%%", state.density * 100))

  screen.move(8, 52)
  screen.text("Root: " .. musicutil.note_num_to_name(state.root_note))

  -- play state
  screen.level(state.playing and 15 or 5)
  screen.move(100, 10)
  screen.text(state.playing and "PLAY" or "STOP")

  -- tension bar (compact, within screen bounds)
  if screen_state.show_detailed_tension and tension_arc.enabled then
    draw_tension_bar()
  end

  -- section marker
  if screen_state.show_section_marker then
    screen.level(6)
    screen.move(100, 22)
    screen.text("S:" .. screen_state.section_name)
  end

  -- tutti/soli indicator
  if screen_state.show_tutti_solo_state then
    screen.level(6)
    screen.move(100, 32)
    screen.text(tutti_soli_state.mode == "tutti" and "TUT" or "SOL")
  end

  -- MIDI clock indicator
  if is_receiving_midi_clock then
    screen.level(4)
    screen.move(100, 42)
    screen.text("MCLK")
  end

  -- morph amount
  screen.level(6)
  screen.move(100, 52)
  screen.text("M:" .. string.format("%.0f", presets.morph_amount * 100))

  -- Oracle text overlay
  oracle.draw()

  -- Tension value as small bar at bottom of screen
  screen.level(3)
  local bar_w = tension.bar_width()
  if bar_w > 0 then
    screen.rect(8, 58, bar_w, 3)
    screen.fill()
  end

  screen.update()
end

function draw_tension_bar()
  -- Draw a compact tension arc indicator within screen bounds (max y = 63)
  local arc_y = 56
  local arc_x_start = 60
  local arc_width = 60

  screen.level(4)
  -- Draw background line
  screen.move(arc_x_start, arc_y)
  screen.line(arc_x_start + arc_width, arc_y)
  screen.stroke()

  -- Draw filled portion showing current tension position
  if tension_arc.current_position > 0 then
    screen.level(10)
    local fill_w = math.floor(tension_arc.current_position * arc_width)
    screen.move(arc_x_start, arc_y)
    screen.line(arc_x_start + fill_w, arc_y)
    screen.stroke()

    -- Marker dot
    screen.level(15)
    screen.rect(arc_x_start + fill_w - 1, arc_y - 1, 3, 3)
    screen.fill()
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- ENCODER HANDLING
-- ────────────────────────────────────────────────────────────────────────────────

function enc(n, delta)
  if state.key1_down then
    if n == 1 then
      state.root_note = util.clamp(state.root_note + delta, 0, 127)
    elseif n == 2 then
      local chord_count = #scales.chord_names
      state.chord_idx = util.clamp(state.chord_idx + delta, 1, chord_count)
    elseif n == 3 then
      -- Morph A/B
      morph_presets(util.clamp(presets.morph_amount + delta * 0.05, 0, 1))
    end
  else
    if n == 1 then
      local scale_list = scales.names
      state.scale_idx = util.clamp(state.scale_idx + delta, 1, #scale_list)
    elseif n == 2 then
      local old_idx = state.groove_idx
      state.groove_idx = util.clamp(state.groove_idx + delta, 1, #groove_preset_names)
      if state.groove_idx ~= old_idx then
        rebuild_groove_stack()
      end
    elseif n == 3 then
      state.density = util.clamp(state.density + delta * 0.05, 0, 1)
    end
  end
  state.screen_dirty = true
end

function handle_arc_encoder(n, d)
  if n == 1 then
    -- arc enc 1: density
    state.density = util.clamp(state.density + d * 0.002, 0, 1)
    state.screen_dirty = true
  elseif n == 2 then
    -- arc enc 2: tension manual override
    tension_arc.current_position = util.clamp(
      tension_arc.current_position + d * 0.002, 0, 1
    )
    state.screen_dirty = true
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- KEY HANDLING
-- ────────────────────────────────────────────────────────────────────────────────

function key(n, z)
  if n == 1 then
    state.key1_down = (z == 1)
  elseif n == 2 then
    if z == 1 then
      if state.key1_down then
        -- K1+K2: save preset A
        save_preset_a()
        oracle.flash("PRESET A", 1.0)
      else
        toggle_play()
      end
      state.screen_dirty = true
    end
  elseif n == 3 then
    if z == 1 then
      if state.key1_down then
        -- K1+K3: save preset B
        save_preset_b()
        oracle.flash("PRESET B", 1.0)
      else
        mutate_all()
        oracle.flash("MUTATE", 1.0)
      end
      state.screen_dirty = true
    end
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- TRANSPORT
-- ────────────────────────────────────────────────────────────────────────────────

function toggle_play()
  state.playing = not state.playing
  if state.playing then
    state.step = 0
    state.bar = 0
    state.beat_in_bar = 0
    state.prog_step = 1
    state.progression = tension.get_progression()
  else
    all_notes_off()
  end
  state.screen_dirty = true
  state.grid_dirty = true
end

-- ────────────────────────────────────────────────────────────────────────────────
-- MIDI CLOCK SYNC
-- ────────────────────────────────────────────────────────────────────────────────

function handle_midi_clock_tick()
  midi_clock_ticks = midi_clock_ticks + 1
  is_receiving_midi_clock = true

  if midi_clock_ticks >= midi_clock_ppq then
    midi_clock_ticks = 0
  end
end

function update_tension_from_audio()
  if audio_follow_mode then
    -- Use poll for input level if available
    local input_level = 0.5  -- fallback
    tension_arc.current_position = util.clamp(input_level, 0, 1)
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- TUTTI / SOLI ORCHESTRATION
-- ────────────────────────────────────────────────────────────────────────────────

function set_tutti()
  tutti_soli_state.mode = "tutti"
end

function set_soli(instrument_key)
  tutti_soli_state.mode = "soli"
  if not tutti_soli_state.soli_map[instrument_key] then
    tutti_soli_state.soli_map[instrument_key] = {}
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- PRESET MORPHING (A <-> B)
-- ────────────────────────────────────────────────────────────────────────────────

function save_preset_a()
  presets.a.scale_idx = state.scale_idx
  presets.a.chord_idx = state.chord_idx
  presets.a.groove_idx = state.groove_idx
  presets.a.density = state.density
  presets.a.root_note = state.root_note
  state.screen_dirty = true
end

function save_preset_b()
  presets.b.scale_idx = state.scale_idx
  presets.b.chord_idx = state.chord_idx
  presets.b.groove_idx = state.groove_idx
  presets.b.density = state.density
  presets.b.root_note = state.root_note
  state.screen_dirty = true
end

function morph_presets(amount)
  presets.morph_amount = util.clamp(amount, 0, 1)

  local scale_count = #scales.names
  local chord_count = #scales.chord_names

  state.scale_idx = util.clamp(
    math.floor(util.linlin(0, 1, presets.a.scale_idx, presets.b.scale_idx, presets.morph_amount) + 0.5),
    1, scale_count
  )
  state.chord_idx = util.clamp(
    math.floor(util.linlin(0, 1, presets.a.chord_idx, presets.b.chord_idx, presets.morph_amount) + 0.5),
    1, chord_count
  )
  local new_groove_idx = util.clamp(
    math.floor(util.linlin(0, 1, presets.a.groove_idx, presets.b.groove_idx, presets.morph_amount) + 0.5),
    1, #groove_preset_names
  )
  if new_groove_idx ~= state.groove_idx then
    state.groove_idx = new_groove_idx
    rebuild_groove_stack()
  end
  state.density = util.clamp(
    util.linlin(0, 1, presets.a.density, presets.b.density, presets.morph_amount),
    0, 1
  )
  state.root_note = util.clamp(
    math.floor(util.linlin(0, 1, presets.a.root_note, presets.b.root_note, presets.morph_amount) + 0.5),
    0, 127
  )

  state.screen_dirty = true
end

-- ────────────────────────────────────────────────────────────────────────────────
-- MUTATIONS & RANDOMIZATION
-- ────────────────────────────────────────────────────────────────────────────────

function mutate_all()
  local scale_list = scales.names
  state.scale_idx = math.random(1, #scale_list)
  state.chord_idx = math.random(1, #scales.chord_names)
  local old_groove = state.groove_idx
  state.groove_idx = math.random(1, #groove_preset_names)
  if state.groove_idx ~= old_groove then
    rebuild_groove_stack()
  end
  state.density = math.random() * 0.9 + 0.1
  state.root_note = util.clamp(state.root_note + math.random(-12, 12), 0, 127)
  state.progression = tension.get_progression()
end

-- ────────────────────────────────────────────────────────────────────────────────
-- CLEANUP
-- ────────────────────────────────────────────────────────────────────────────────

function cleanup()
  -- Stop everything safely
  all_notes_off()

  -- Cancel all clocks
  for _, cid in ipairs(note_off_clocks) do
    pcall(function() clock.cancel(cid) end)
  end
  note_off_clocks = {}

  -- Destroy lattice
  if the_lattice then
    the_lattice:destroy()
  end

  -- MIDI all-notes-off on all channels
  if midi_out then
    for ch = 1, 16 do
      midi_out:cc(123, 0, ch)
    end
  end

  -- OP-XY all-notes-off
  opxy_all_notes_off()

  -- Stop redraw metro
  if redraw_metro then
    redraw_metro:stop()
  end
end
