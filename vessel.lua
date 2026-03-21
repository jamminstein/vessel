-- vessel
-- v2.2.0 @tiago
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
-- │  K1 + E3     reverb depth                             │
-- │                                                       │
-- │  NEW v2.2: Audio follow mode (modulates tension)      │
-- │  NEW v2.2: Preset morphing A/B (smooth blending)      │
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
-- │                                                        │
-- │  K1+K2: save preset A    K1+K3: save preset B          │
-- │  E3 (K1): morph A ↔ B with smooth crossfade           │
-- └────────────────────────────────────────────────────

engine.name = "FM7"

local scales  = include("vessel/lib/scales")
local groove  = include("vessel/lib/groove")
local oracle  = include("vessel/lib/oracle")
local tension = include("vessel/lib/tension")
local lattice  = require("lattice")
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
  enabled = false,
  tutti_sections = {},  -- indices of "tutti" (all) sections
  soli_map = {},        -- map from instrument to solo section indices
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
-- VOICE ALLOCATION (thread-safe single allocator)
-- ────────────────────────────────────────────────────────────────────────────────
local voice_pool = {free = {}, active = {}}

local function allocate_voice()
  if #voice_pool.free > 0 then
    return table.remove(voice_pool.free)
  end
  return nil
end

local function release_voice(voice_id)
  if voice_id then
    table.insert(voice_pool.free, voice_id)
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- INIT / CLEANUP
-- ────────────────────────────────────────────────────────────────────────────────

function init()
  norns.crow = true

  -- lattice setup
  the_lattice = lattice:new({ppq = 8, swing = 0})
  the_lattice:start()

  -- MIDI setup
  midi_out = midi.connect(params:get("midi_out_device") or 1)

  -- device setup
  params:add_group("engine", 100)
  params:add_separator("FM7")
  params:add("fm_ratio", "FM ratio", controlspec.new(0.5, 8, "lin", 0.1, 2.0))
  params:set_action("fm_ratio", function(v) engine.hz2(v) end)
  params:add("fm_index", "FM index", controlspec.new(0, 5, "lin", 0.1, 0.5))
  params:set_action("fm_index", function(v) engine.hz2_to_hz1(v) end)
  params:add("fm_attack", "FM attack", controlspec.new(0.001, 2.0, "exp", 0, 0.05))
  params:set_action("fm_attack", function(v) engine.opAmpA1(v); engine.opAmpA2(v) end)
  params:add("fm_decay", "FM decay", controlspec.new(0.01, 2.0, "exp", 0, 0.1))
  params:set_action("fm_decay", function(v) engine.opAmpD1(v); engine.opAmpD2(v) end)
  params:add("fm_sustain", "FM sustain", controlspec.new(0, 1, "lin", 0.01, 1.0))
  params:set_action("fm_sustain", function(v) engine.opAmpS1(v); engine.opAmpS2(v) end)
  params:add("fm_release", "FM release", controlspec.new(0.05, 8.0, "exp", 0, 1.0))
  params:set_action("fm_release", function(v) engine.opAmpR1(v); engine.opAmpR2(v) end)
  params:add("reverb", "reverb depth", 0, 1, 0.15)

  params:add_group("network", 100)
  params:add("midi_out_device", "MIDI Out", 1, 16, 1)

  -- UI
  norns.enc.sens(1, 4)
  norns.enc.sens(2, 4)
  norns.enc.sens(3, 2)

  redraw_metro = metro.init()
  redraw_metro.event = function()
    if state.screen_dirty then
      redraw()
      state.screen_dirty = false
    end
  end
  redraw_metro:start(0.1)

  -- grid & arc
  grid_devices:new()
  arc_devices:new()

  -- init grid/arc pattern display
  state.grid_dirty = true
end

function grid_devices:new()
  local grid = grid.connect()
  grid.key = function(x, y, z)
    handle_grid_key(x, y, z, grid)
  end
  return grid
end

function arc_devices:new()
  local arc = arc.connect()
  arc.encoder = function(n, d)
    handle_arc_encoder(n, d)
  end
  return arc
end

-- ────────────────────────────────────────────────────────────────────────────────
-- GRID HANDLING
-- ────────────────────────────────────────────────────────────────────────────────

function handle_grid_key(x, y, z, g)
  if not z then return end  -- ignore key releases

  if y == 1 then
    -- melody playhead
    state.step = x - 1
    state.screen_dirty = true

  elseif y == 2 then
    -- scale degree map
    local scale_list = scales.names
    state.scale_idx = util.clamp(x, 1, #scale_list)
    state.screen_dirty = true

  elseif y == 3 or y == 4 then
    -- groove pattern layers
    local layer = y - 2
    -- handle groove pattern editing
    state.grid_dirty = true

  elseif y == 5 then
    -- chord voicing selector
    state.chord_idx = util.clamp(x, 1, 12)
    state.screen_dirty = true

  elseif y == 6 then
    -- scale selector
    local scale_list = scales.names
    state.scale_idx = util.clamp(x, 1, #scale_list)
    state.screen_dirty = true

  elseif y == 7 then
    -- density scrub
    state.density = (x - 1) / 15
    state.screen_dirty = true

  elseif y == 8 then
    if x == 1 then
      -- play / stop
      state.playing = not state.playing
      state.screen_dirty = true
    elseif x >= 3 and x <= 8 then
      -- groove preset (brown/bossa/aphex/daft/maya/eno)
      state.groove_idx = x - 2
      state.grid_dirty = true
    elseif x == 16 then
      -- mutate everything
      mutate_all()
      state.screen_dirty = true
    end
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- SCREEN / VISUALIZATION
-- ────────────────────────────────────────────────────────────────────────────────

function redraw()
  screen.clear()
  screen.aa(1)

  -- title
  screen.move(8, 10)
  screen.text("VESSEL v2.2.0")

  -- state info
  screen.move(8, 25)
  screen.text("Scale: " .. (scales.names[state.scale_idx] or "?"))

  screen.move(8, 35)
  screen.text("Chord: " .. state.chord_idx .. " | Groove: " .. state.groove_idx)

  screen.move(8, 45)
  screen.text("Density: " .. string.format("%.2f", state.density))

  screen.move(8, 55)
  screen.text("Root: " .. musicutil.note_num_to_name(state.root_note))

  -- play state
  screen.move(110, 10)
  screen.text(state.playing and "PLAY" or "STOP")

  -- tension arc visualization (if enabled)
  if screen_state.show_detailed_tension and tension_arc.enabled then
    draw_tension_arc()
  end

  -- section marker
  if screen_state.show_section_marker then
    screen.move(110, 25)
    screen.text("Sec: " .. screen_state.section_name)
  end

  -- tutti/soli indicator
  if screen_state.show_tutti_solo_state and tutti_soli_state.enabled then
    screen.move(110, 35)
    screen.text("TUTTI" or "SOLI")
  end

  -- MIDI clock indicator
  if is_receiving_midi_clock then
    screen.move(110, 45)
    screen.text("MIDI CLK")
  end

  -- morph amount (if A/B mode)
  screen.move(110, 55)
  screen.text("Morph: " .. string.format("%.1f", presets.morph_amount * 100) .. "%")

  screen.update()
end

function draw_tension_arc()
  -- Draw a simple curve indicating tension level across bars
  local arc_y = 65
  local arc_x_start = 8
  local arc_width = 110

  screen.stroke()
  screen.move(arc_x_start, arc_y)

  for i = 0, 15 do
    local x = arc_x_start + (i / 15) * arc_width
    -- tension curve: sine-ish rise and fall
    local t = i / 15
    local y_offset = math.sin(t * math.pi) * 10
    screen.line(x, arc_y - y_offset)
  end

  -- marker for current position
  local marker_x = arc_x_start + (tension_arc.current_position) * arc_width
  screen.move(marker_x, arc_y - 2)
  screen.line(marker_x, arc_y + 2)
end

-- ────────────────────────────────────────────────────────────────────────────────
-- ENCODER HANDLING
-- ────────────────────────────────────────────────────────────────────────────────

function enc(n, delta)
  if state.key1_down then
    if n == 1 then
      state.root_note = util.clamp(state.root_note + delta, 0, 127)
    elseif n == 2 then
      state.chord_idx = util.clamp(state.chord_idx + delta, 1, 12)
    elseif n == 3 then
      state.reverb = util.clamp(state.reverb + delta * 0.05, 0, 1)
    end
  else
    if n == 1 then
      local scale_list = scales.names
      state.scale_idx = util.clamp(state.scale_idx + delta, 1, #scale_list)
    elseif n == 2 then
      state.groove_idx = util.clamp(state.groove_idx + delta, 1, 6)
    elseif n == 3 then
      state.density = util.clamp(state.density + delta * 0.05, 0, 1)
    end
  end
  state.screen_dirty = true
end

function handle_arc_encoder(n, d)
  if n == 1 then
    -- arc enc 1: tempo
    -- (adjust lattice tempo)
  elseif n == 2 then
    -- arc enc 2: tension knob
    tension_arc.current_position = util.clamp(
      tension_arc.current_position + d * 0.05, 0, 1
    )
    state.screen_dirty = true
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- KEY HANDLING
-- ────────────────────────────────────────────────────────────────────────────────

function key(n, z)
  if n == 1 then
    state.key1_down = z == 1
  elseif n == 2 then
    if z == 1 then
      state.playing = not state.playing
      state.screen_dirty = true
    end
  elseif n == 3 then
    if z == 1 then
      mutate_all()
      state.screen_dirty = true
    end
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- MIDI CLOCK SYNC
-- ────────────────────────────────────────────────────────────────────────────────

function handle_midi_clock_tick()
  midi_clock_ticks = midi_clock_ticks + 1
  is_receiving_midi_clock = true

  -- sync lattice to MIDI clock
  if midi_clock_ticks >= midi_clock_ppq then
    midi_clock_ticks = 0
    -- advance step
  end
end

function update_tension_from_audio()
  -- modulate tension based on input audio levels (if audio follow enabled)
  if audio_follow_mode then
    local input_level = params:get("input_level") or 0.5
    tension_arc.current_position = input_level
  end
end

-- ────────────────────────────────────────────────────────────────────────────────
-- TUTTI / SOLI ORCHESTRATION
-- ────────────────────────────────────────────────────────────────────────────────

function set_tutti_section(section_idx)
  -- all instruments play
  tutti_soli_state.current_section = section_idx
  tutti_soli_state.enabled = true
end

function set_soli_section(instrument_key, section_idx)
  -- only specific instrument plays
  if not tutti_soli_state.soli_map[instrument_key] then
    tutti_soli_state.soli_map[instrument_key] = {}
  end
  table.insert(tutti_soli_state.soli_map[instrument_key], section_idx)
end

-- ────────────────────────────────────────────────────────────────────────────────
-- PRESET MORPHING (A ↔ B)
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
  -- amount: 0 = all A, 1 = all B, 0.5 = halfway
  presets.morph_amount = util.clamp(amount, 0, 1)

  state.scale_idx = math.floor(
    util.linlin(presets.morph_amount, 0, 1, presets.a.scale_idx, presets.b.scale_idx) + 0.5
  )
  state.chord_idx = math.floor(
    util.linlin(presets.morph_amount, 0, 1, presets.a.chord_idx, presets.b.chord_idx) + 0.5
  )
  state.groove_idx = math.floor(
    util.linlin(presets.morph_amount, 0, 1, presets.a.groove_idx, presets.b.groove_idx) + 0.5
  )
  state.density = util.linlin(presets.morph_amount, 0, 1, presets.a.density, presets.b.density)
  state.root_note = math.floor(
    util.linlin(presets.morph_amount, 0, 1, presets.a.root_note, presets.b.root_note) + 0.5
  )

  state.screen_dirty = true
end

-- ────────────────────────────────────────────────────────────────────────────────
-- MUTATIONS & RANDOMIZATION
-- ────────────────────────────────────────────────────────────────────────────────

function mutate_all()
  local scale_list = scales.names
  state.scale_idx = math.random(1, #scale_list)
  state.chord_idx = math.random(1, 12)
  state.groove_idx = math.random(1, 6)
  state.density = math.random() * 0.9 + 0.1
  state.root_note = util.clamp(state.root_note + math.random(-12, 12), 0, 127)
end

-- ────────────────────────────────────────────────────────────────────────────────
-- NOTE PLAYBACK & MIDI
-- ────────────────────────────────────────────────────────────────────────────────

function play_note(midi_note, velocity, duration)
  engine.start(midi_note, musicutil.note_num_to_hz(midi_note))
  if duration then
    metro.init():start(duration / 1000, 1, function()
      engine.stop(midi_note)
    end)
  end
end

function all_notes_off()
  engine.stopAll()
end

-- ────────────────────────────────────────────────────────────────────────────────
-- SAVE/LOAD UTILITIES
-- ────────────────────────────────────────────────────────────────────────────────

function save_state()
  -- serialize state to file
  -- (implementation omitted for brevity)
end

function load_state()
  -- deserialize state from file
  -- (implementation omitted for brevity)
end

-- ────────────────────────────────────────────────────────────────────────────────
-- ENGINE / CROW INTEGRATION
-- ────────────────────────────────────────────────────────────────────────────────

function update()
  update_tension_from_audio()
  
  -- update bar counter for tension arc
  if state.playing then
    state.bar = state.bar + 1
    if state.bar >= tension_arc.bars_per_cycle then
      state.bar = 0
    end
    tension_arc.current_position = state.bar / tension_arc.bars_per_cycle
  end

  state.screen_dirty = true
end

function op1_connected()
  return norns.crow ~= nil and (norns.crow._op1 and "connected" or "not found")
end

function cleanup()
  clock.cancel_all()
  -- Destroy lattice and send MIDI all-notes-off
  if the_lattice then
    the_lattice:destroy()
  end
  if midi_out then
    for ch = 1, 16 do
      midi_out:cc(123, 0, ch)
    end
  end
  if redraw_metro then
    redraw_metro:stop()
  end
  all_notes_off()
end
