-- vessel
-- v2.1.0 @tiago
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
-- └────────────────────────────────────────────────────────┘

engine.name = "VESSEL"

local scales  = include("vessel/lib/scales")
local groove  = include("vessel/lib/groove")
local oracle  = include("vessel/lib/oracle")
local tension = include("vessel/lib/tension")
local lattice  = require("lattice")
local musicutil = require("musicutil")

-- -------------------------------------------------------------------------
-- STATE
-- -------------------------------------------------------------------------
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
  bar          = 0,         -- bar counter for tension arc
  progression  = {0,0,0,0}, -- current harmonic offsets
  prog_step    = 1,         -- which step in progression
}

local groove_stack = nil
local cr = groove.make_call_response(8, 8)

local the_lattice = nil
local sprockets   = {}

local g = grid.connect()

local midi_opxy = nil
local midi_opz  = nil
local midi_op1  = nil

-- ENO added as 6th preset: Brian Eno ambient mode
local groove_names = {"brown","bossa","aphex","daft","maya","eno"}
local scale_names  = scales.names
local chord_names  = scales.chord_names

-- -------------------------------------------------------------------------
-- HELPERS
-- -------------------------------------------------------------------------
local function root_hz()
  return musicutil.note_num_to_freq(state.root_note)
end

local function get_scale_freq(degree, offset_st)
  offset_st = offset_st or 0
  local base = root_hz() * (2 ^ (offset_st / 12))
  return scales.get_freq(base, scale_names[state.scale_idx], degree)
end

local function get_chord_freqs(offset_st)
  offset_st = offset_st or 0
  local base = root_hz() * (2 ^ (offset_st / 12))
  return scales.get_chord(base, chord_names[state.chord_idx])
end

local function scale_len()
  return scales.length(scale_names[state.scale_idx])
end

-- ENO MODE: true when Brian Eno ambient preset is active
local function is_eno()
  return groove_names[state.groove_idx] == "eno"
end

local function find_midi_device(partial_name)
  for i = 1, #midi.devices do
    local d = midi.devices[i]
    if d.name and string.find(string.lower(d.name), string.lower(partial_name)) then
      return midi.connect(i)
    end
  end
  return nil
end

-- -------------------------------------------------------------------------
-- MIDI HELPERS
-- -------------------------------------------------------------------------
local function send_note_on(device, channel, freq, vel)
  if device == nil then return end
  local bend_range = params:get("midi_bend_range")
  local note, bend = scales.freq_to_midi_bend(freq, bend_range)
  note = math.max(0, math.min(127, note))
  vel  = math.max(1, math.min(127, vel))
  device:pitchbend(math.floor(bend + 8192), channel)
  device:note_on(note, vel, channel)
end

local function send_note_off(device, channel, freq)
  if device == nil then return end
  local bend_range = params:get("midi_bend_range")
  local note, _ = scales.freq_to_midi_bend(freq, bend_range)
  note = math.max(0, math.min(127, note))
  device:note_off(note, 0, channel)
end

local function send_cc(device, channel, cc, val)
  if device == nil then return end
  device:cc(cc, math.floor(math.max(0, math.min(127, val))), channel)
end

local function all_notes_off()
  for ch = 1, 16 do
    if midi_opxy then midi_opxy:cc(123, 0, ch) end
    if midi_opz  then midi_opz:cc(123, 0, ch)  end
    if midi_op1  then midi_op1:cc(123, 0, ch)  end
  end
end

-- -------------------------------------------------------------------------
-- SOUND EVENTS — each voice fans to Norns engine + all devices
-- -------------------------------------------------------------------------

local function play_harm(degree, vel, gate_time, harm_offset)
  -- ENO: stretch every note into a long, breathing ambient tone
  -- inspired by Music for Airports / Discreet Music tape loop philosophy
  if is_eno() then
    gate_time = 1.8 + math.random() * 2.6
    vel       = math.max(28, math.min(62, vel))
  end
  local freq = get_scale_freq(degree, harm_offset or 0)
  local amp  = (vel / 127) * 0.8
  -- Melody register rises with tension
  if tension.melody_octave() == 2 then freq = freq * 2 end
  engine.harm_on(0, freq, amp, 0.01, 0.1, 0.7, 0.8, 0.3, 2.0, 2.0, 0, 3000)
  clock.run(function()
    clock.sleep(gate_time)
    engine.harm_off(0)
  end)
  -- OP-XY lead track
  local ch = params:get("opxy_ch_lead")
  send_note_on(midi_opxy, ch, freq, vel)
  clock.run(function()
    clock.sleep(gate_time)
    send_note_off(midi_opxy, ch, freq)
  end)
end

local function play_bass(degree, vel, gate_time)
  -- ENO: sparse slow drone rather than rhythmic bass pulse
  if is_eno() then
    gate_time = 2.2 + math.random() * 2.0
    vel       = math.floor(vel * 0.5)
  end
  -- Current progression step's harmonic offset
  local offset = state.progression[state.prog_step] or 0
  local freq = get_scale_freq(degree, offset) * 0.5
  local amp  = (vel / 127) * 1.1
  engine.bass_on(0, freq, amp, 0.5, 0.4, 0.5)
  clock.run(function()
    clock.sleep(gate_time)
    engine.bass_off(0)
  end)
  local ch_z = params:get("opz_ch_bass")
  local ch_x = params:get("opxy_ch_bass")
  send_note_on(midi_opz,  ch_z, freq, vel)
  send_note_on(midi_opxy, ch_x, freq, vel)
  clock.run(function()
    clock.sleep(gate_time)
    send_note_off(midi_opz,  ch_z, freq)
    send_note_off(midi_opxy, ch_x, freq)
  end)
end

local function play_chord(vel, gate_time)
  local offset = state.progression[state.prog_step] or 0
  local freqs  = get_chord_freqs(offset)
  if #freqs < 4 then return end
  local amp = (vel / 127) * 0.35
  engine.chord_on(0, freqs[1], freqs[2], freqs[3], freqs[4], amp, 0.08, 2000 + tension.value * 1000)
  clock.run(function()
    clock.sleep(gate_time)
    engine.chord_off(0)
  end)
  local ch_op1 = params:get("op1_ch_chord")
  local ch_xy  = params:get("opxy_ch_chord")
  for _, f in ipairs(freqs) do
    send_note_on(midi_op1, ch_op1, f, vel - 20)
    send_note_on(midi_opxy, ch_xy, f, vel - 10)
  end
  clock.run(function()
    clock.sleep(gate_time)
    for _, f in ipairs(freqs) do
      send_note_off(midi_op1, ch_op1, f)
      send_note_off(midi_opxy, ch_xy, f)
    end
  end)
end

local function play_texture(degree)
  local freq = get_scale_freq(degree)
  -- ENO: longer, slower texture pads — the primary voice in ambient mode
  local tex_amp   = is_eno() and (0.22 + math.random() * 0.12) or (0.15 + tension.value * 0.1)
  local tex_rate  = is_eno() and (4 + math.random() * 8) or (10 + tension.value * 15)
  local tex_cutoff= is_eno() and (400 + math.random() * 600) or (800 + tension.value * 800)
  engine.texture_on(0, freq, tex_amp, tex_rate, tex_cutoff)
  -- OP-XY arp track: slow filter sweep driven by tension
  local sleep_time = is_eno() and 0.8 or 0.4
  local iterations = is_eno() and 16 or 24
  clock.run(function()
    for i = 1, iterations do
      send_cc(midi_opxy, params:get("opxy_ch_arp"), 74, tension.filter_cc())
      clock.sleep(sleep_time)
    end
    engine.texture_off(0)
  end)
end

local function play_perc(slot, freq, vel, tone, body, decay)
  engine.perc(0, freq, vel/127, tone, body, decay)
  local ch = math.min(4, math.max(1, slot))
  if midi_opz then
    local drum_notes = {36, 38, 42, 47}
    midi_opz:note_on(drum_notes[ch], vel, ch)
    clock.run(function()
      clock.sleep(0.05)
      midi_opz:note_off(drum_notes[ch], 0, ch)
    end)
  end
end

-- -------------------------------------------------------------------------
-- GROOVE STACK
-- -------------------------------------------------------------------------
local function build_groove_stack()
  local preset_name = groove_names[state.groove_idx]
  -- ENO falls back to "brown" pattern — drums are silenced at sprocket level
  local preset      = groove.presets[preset_name] or groove.presets["brown"]
  local dens_mult   = tension.density_mult()
  local scaled      = {}
  for _, layer in ipairs(preset) do
    local l = {}
    for k, v in pairs(layer) do l[k] = v end
    l.prob = math.min(1.0, (l.prob or 1.0) * state.density * dens_mult)
    table.insert(scaled, l)
  end
  groove_stack = groove.make_stack(scaled)
end

-- -------------------------------------------------------------------------
-- LATTICE
-- -------------------------------------------------------------------------
local function build_lattice()
  if the_lattice then the_lattice:destroy() end
  the_lattice = lattice:new({ ppqn = 96 })

  -- BAR CLOCK: fires every 4 beats — drives tension arc + chord changes
  sprockets.bar = the_lattice:new_sprocket({
    action = function(t)
      if not state.playing then return end
      state.bar = state.bar + 1

      -- Advance progression step every bar
      state.prog_step = (state.prog_step % 4) + 1

      -- Tension arc tick
      local released = tension.tick_bar()

      -- On release: break + rebuild groove + oracle flash
      if released then
        build_groove_stack()
        state.progression = tension.get_progression()
        local groove_name = groove_names[state.groove_idx]
        local phase, _    = cr:peek()
        oracle.flash(oracle.pick_word(groove_name, 0.9, phase), 1.0)
      else
        -- Every 4 bars: advance progression
        if state.bar % 4 == 0 then
          state.progression = tension.get_progression()
          play_chord(60 + tension.value * 30, 1.8)
        end
      end

      -- Oracle tick (new word every N beats based on tension)
      local groove_name = groove_names[state.groove_idx]
      local phase, _    = cr:peek()
      oracle.tick(groove_name, tension.value, phase)

      -- OP-Z automation: FX + master
      local rev_val  = math.floor(tension.reverb_depth() * 127)
      send_cc(midi_opz, 9,  19, rev_val)           -- FX1 reverb
      send_cc(midi_opz, 10, 16, math.floor(tension.value * 100)) -- FX2 distortion
      -- OP-XY filter automation tied to tension
      local filt_val = tension.filter_cc()
      send_cc(midi_opxy, params:get("opxy_ch_lead"), 74, filt_val)

      state.screen_dirty = true
    end,
    division = 1/1,  -- once per beat; we count internally for bars
    enabled  = true,
  })

  -- Actually: trigger bar logic every 4 beats = every bar
  -- Override: use a slower sprocket division
  sprockets.bar.division = 1/4  -- fires 4x per beat; bar counter handles 4-beat grouping
  -- Correction: let's just fire once per beat and count to 4
  -- Rebuild with correct approach:
  the_lattice:destroy()
  the_lattice = lattice:new({ ppqn = 96 })

  -- PULSE: fires every beat (quarter note)
  local beat_count = 0
  sprockets.pulse = the_lattice:new_sprocket({
    action = function(t)
      if not state.playing then return end
      beat_count = beat_count + 1

      -- The ONE (James Brown): beat 1 of each bar
      if beat_count % 4 == 1 then
        -- ENO: occasional slow drone bass instead of rhythmic pulse
        if is_eno() then
          if math.random() < 0.28 then
            play_bass(math.random(1, 3), 42 + math.floor(tension.value * 12), 2.0)
          end
        else
          play_bass(1, 105 + math.floor(tension.value * 20), 0.35)
        end

        -- Bar-level logic every 4 beats (shared by all modes)
        state.bar       = state.bar + 1
        state.prog_step = (state.prog_step % 4) + 1

        local released  = tension.tick_bar()
        local gname     = groove_names[state.groove_idx]
        local phase, _  = cr:peek()

        oracle.tick(gname, tension.value, phase)

        if released then
          build_groove_stack()
          state.progression = tension.get_progression()
          oracle.flash(oracle.pick_word(gname, 0.9, phase), 1.0)
        elseif state.bar % 4 == 0 then
          state.progression = tension.get_progression()
          -- ENO: quieter, longer chord swells
          if is_eno() then
            play_chord(38 + math.floor(tension.value * 18), 3.2)
          else
            play_chord(55 + math.floor(tension.value * 25), 1.6)
          end
        end

        -- Device automation on bar 1
        send_cc(midi_opz,  9,  19, math.floor(tension.reverb_depth() * 127))
        send_cc(midi_opz,  10, 16, math.floor(tension.value * 90))
        send_cc(midi_opxy, params:get("opxy_ch_lead"), 74, tension.filter_cc())
      end

      state.screen_dirty = true
    end,
    division = 1/1,
    enabled  = true,
  })

  -- MELODY: 16th-note grid
  sprockets.melody = the_lattice:new_sprocket({
    action = function(t)
      if not state.playing then return end
      state.step = state.step + 1

      -- ENO: chance-based sparse ambient melody
      -- "I am the beach" — notes drift in and out like fog
      -- Inspired by Music for Airports and Discreet Music
      if is_eno() then
        if math.random() < 0.07 then
          local eno_degree = math.random(scale_len())
          play_harm(eno_degree, math.random(28, 58), 0.1) -- gate overridden inside play_harm
        end
        state.grid_dirty = true
        return
      end

      -- Call/response: only tick here (not in redraw)
      local phase, pos = cr:tick()
      local s_len      = scale_len()

      local degree
      if phase == "call" then
        degree = (pos % s_len) + 1
      else
        degree = math.max(1, s_len - (pos % s_len))
      end

      -- Probability: density × tension multiplier, boosted in aphex mode
      local fire_prob = state.density * tension.density_mult() * 0.65
      if state.groove_idx == 3 then fire_prob = fire_prob * 1.3 end
      fire_prob = math.min(0.98, fire_prob)

      if math.random() < fire_prob then
        -- Frusciante-style velocity arc
        local vel
        if phase == "call" then
          vel = math.floor(55 + (pos / 8) * 45)
        else
          vel = math.floor(100 - (pos / 8) * 35)
        end
        vel = math.max(40, math.min(127, vel))

        local h_offset = tension.harm_offset()
        play_harm(degree, vel, 0.11, h_offset)
      end

      state.grid_dirty = true
    end,
    division = 1/4,
    enabled  = true,
  })

  -- DRUMS: 16th-note grid, uses groove stack
  sprockets.drums = the_lattice:new_sprocket({
    action = function(t)
      if not state.playing then return end
      -- ENO: silence is an instrument — no drums in ambient mode
      if is_eno() then return end

      local div_sec = clock.get_beat_sec() / 4

      if groove_stack then
        local events = groove_stack:tick(state.step, div_sec)
        for _, evt in ipairs(events) do
          local layer  = evt.layer
          local freqs  = {75, 195, 580, 340}
          local tones  = {0.1, 0.5, 0.9, 0.4}
          local bodies = {0.9, 0.4, 0.1, 0.6}
          local decays = {0.4, 0.2, 0.08, 0.18}

          local f = freqs[layer] or 200
          -- Aphex: per-hit pitch variation
          if state.groove_idx == 3 then
            f = f * (0.88 + math.random() * 0.44)
          end
          -- Tension: all drum pitches rise slightly under pressure
          f = f * (1 + tension.value * 0.12)

          local offset = evt.offset or 0
          if math.abs(offset) > 0.001 then
            clock.run(function()
              clock.sleep(math.max(0, offset))
              play_perc(layer, f, evt.vel, tones[layer] or 0.5, bodies[layer] or 0.5, decays[layer] or 0.2)
            end)
          else
            play_perc(layer, f, evt.vel, tones[layer] or 0.5, bodies[layer] or 0.5, decays[layer] or 0.2)
          end
        end
      end
    end,
    division = 1/4,
    enabled  = true,
  })

  -- TEXTURE: slow evolving pad, every half note
  sprockets.texture = the_lattice:new_sprocket({
    action = function(t)
      if not state.playing then return end
      -- ENO: texture IS the music — pads are the primary melodic voice
      -- Chance-based, independent of tension, always evolving
      if is_eno() then
        if math.random() < 0.62 then
          play_texture(math.random(1, scale_len()))
        end
        return
      end
      -- Fire texture only at high tension or on release
      if tension.value > 0.55 or tension.just_released then
        if math.random() < 0.3 then
          play_texture(math.random(2, scale_len()))
        end
      end
    end,
    division = 1/2,
    enabled  = true,
  })

  the_lattice:start()
end

-- -------------------------------------------------------------------------
-- GRID
-- -------------------------------------------------------------------------
local function grid_redraw()
  if g.device == nil then return end
  g:all(0)

  local step  = state.step % 16 + 1
  local s_len = scale_len()
  local t_bright = tension.grid_bright()

  -- Row 1: Playhead (ENO: slow pulse, dimmer)
  for col = 1, 16 do
    local bright = col == step and (is_eno() and 8 or 15) or (is_eno() and 1 or 2)
    g:led(col, 1, bright)
  end

  -- Row 2: Scale degree map (which cols are valid scale degrees)
  for col = 1, 16 do
    local bright = (col <= s_len) and 6 or 1
    if col == step then bright = math.max(bright, 10) end
    g:led(col, 2, bright)
  end

  -- Rows 3-4: Groove layers (ENO: dimmed — drums are off)
  if groove_stack then
    for li = 1, math.min(4, #groove_stack.layers) do
      local row   = li + 2
      local layer = groove_stack.layers[li]
      for col = 1, 16 do
        local active = layer.pattern(col)
        local bright
        if is_eno() then
          bright = active and 2 or 0  -- ENO: faint ghost pattern
        else
          bright = active and (col == step and 15 or t_bright) or 1
        end
        g:led(col, row, bright)
      end
    end
  end

  -- Row 5: Chord voicings
  for i = 1, math.min(16, #chord_names) do
    g:led(i, 5, i == state.chord_idx and 15 or 3)
  end

  -- Row 6: Scales
  for i = 1, math.min(16, #scale_names) do
    g:led(i, 6, i == state.scale_idx and 15 or 3)
  end

  -- Row 7: Density scrub bar (ENO: very dim — density is intentionally low)
  local den_cols = math.floor(state.density * 16)
  for col = 1, 16 do
    local bright = col <= den_cols and t_bright or 1
    if is_eno() then bright = col <= den_cols and 3 or 0 end
    g:led(col, 7, bright)
  end

  -- Row 8: Transport + groove presets + mutate
  g:led(1, 8, state.playing and 15 or 5)
  for i, _ in ipairs(groove_names) do
    -- ENO slot glows softer (ambient glow vs bright)
    local on_bright  = (i == 6) and 10 or 15
    local off_bright = (i == 6) and 3 or 4
    g:led(i + 2, 8, i == state.groove_idx and on_bright or off_bright)
  end
  g:led(16, 8, 7)

  g:refresh()
end

g.key = function(x, y, z)
  if z == 0 then return end

  if y == 5 then
    state.chord_idx = util.clamp(x, 1, #chord_names)
    play_chord(75, 0.6)

  elseif y == 6 then
    state.scale_idx = util.clamp(x, 1, #scale_names)

  elseif y == 7 then
    state.density = x / 16
    build_groove_stack()

  elseif y == 8 then
    if x == 1 then
      state.playing = not state.playing
      if state.playing then
        build_groove_stack()
        if the_lattice then the_lattice:start() end
      else
        if the_lattice then the_lattice:stop() end
        all_notes_off()
      end
    elseif x >= 3 and x <= 8 then  -- extended to col 8 for ENO (6th preset)
      state.groove_idx = x - 2
      build_groove_stack()
      -- ENO: auto-configure ambient parameters when selected
      -- Brian Eno's philosophy: let the room do the work
      if is_eno() then
        state.reverb  = 0.55
        state.density = 0.12
        engine.set_rev(state.reverb)
        build_groove_stack()
        oracle.flash("eno", 1.8)
      end
    elseif x == 16 then
      -- Mutate
      state.density    = 0.3 + math.random() * 0.65
      state.groove_idx = math.random(#groove_names)
      state.scale_idx  = math.random(#scale_names)
      build_groove_stack()
      if is_eno() then
        -- Mutate into ENO: honour the ambient intention
        state.density = 0.1 + math.random() * 0.15
        state.reverb  = 0.45 + math.random() * 0.15
        engine.set_rev(state.reverb)
        build_groove_stack()
      end
      local gname = groove_names[state.groove_idx]
      local p, _  = cr:peek()
      oracle.flash(oracle.pick_word(gname, tension.value, p))
    end
  end

  state.screen_dirty = true
  state.grid_dirty   = true
end

-- -------------------------------------------------------------------------
-- SCREEN
-- -------------------------------------------------------------------------
local function redraw()
  screen.clear()

  -- Background: tension level as a subtle gradient
  if tension.value > 0.1 then
    screen.level(math.floor(tension.value * 3))
    screen.rect(0, 0, 128, 64)
    screen.fill()
  end

  -- Oracle word — drawn first so UI sits on top
  oracle.update()
  oracle.draw()

  -- Top bar
  screen.level(15)
  screen.font_size(8)
  screen.move(2, 8)
  screen.text("VESSEL")

  screen.level(state.playing and 12 or 5)
  screen.move(52, 8)
  screen.text(state.playing and "▶" or "■")

  -- Tension bar (top right)
  screen.level(3)
  screen.move(70, 5)
  screen.text("T")
  screen.level(math.floor(3 + tension.value * 12))
  screen.rect(78, 2, tension.bar_width(), 5)
  screen.fill()

  -- Current scale + root (bottom left)
  screen.level(9)
  screen.font_size(8)
  screen.move(2, 54)
  screen.text(scale_names[state.scale_idx] or "?")

  screen.level(5)
  screen.move(2, 63)
  screen.text(musicutil.note_num_to_name(state.root_note, true))

  -- Groove + chord (bottom right)
  -- ENO: display with a subtle wave indicator
  if is_eno() then
    screen.level(10)
    screen.move(80, 54)
    screen.text("eno ~")
    screen.level(3)
    screen.move(80, 63)
    screen.text("ambient")
  else
    screen.level(7)
    screen.move(80, 54)
    screen.text(groove_names[state.groove_idx] or "?")
    screen.level(4)
    screen.move(80, 63)
    screen.text(chord_names[state.chord_idx] or "?")
  end

  -- Phase indicator (call / resp) — hidden in ENO (no call/response structure)
  if not is_eno() then
    local phase, pos = cr:peek()   -- safe: no side effects
    screen.level(phase == "call" and 8 or 4)
    screen.move(110, 8)
    screen.text(phase == "call" and "C" or "R")
  end

  -- Devices connected
  screen.level(3)
  screen.move(2, 44)
  screen.text(
    (midi_opxy and "XY" or "--") .. " " ..
    (midi_opz  and "OZ" or "--") .. " " ..
    (midi_op1  and "O1" or "--")
  )

  screen.update()
end

local function start_redraw_clocks()
  clock.run(function()
    while true do
      clock.sleep(1/20)
      tension.update()
      if state.screen_dirty then
        redraw()
        state.screen_dirty = false
      end
    end
  end)
  clock.run(function()
    while true do
      clock.sleep(1/15)
      if state.grid_dirty then
        grid_redraw()
        state.grid_dirty = false
      end
    end
  end)
end

-- -------------------------------------------------------------------------
-- ENCODERS + KEYS
-- -------------------------------------------------------------------------
function enc(n, d)
  if state.key1_down then
    if n == 1 then
      state.root_note = util.clamp(state.root_note + d, 24, 72)
    elseif n == 2 then
      state.chord_idx = util.clamp(state.chord_idx + d, 1, #chord_names)
    elseif n == 3 then
      local rev = util.clamp(state.reverb + d * 0.02, 0, 0.6)
      state.reverb = rev
      engine.set_rev(rev)
    end
  else
    if n == 1 then
      state.scale_idx = util.clamp(state.scale_idx + d, 1, #scale_names)
    elseif n == 2 then
      state.groove_idx = util.clamp(state.groove_idx + d, 1, #groove_names)
      build_groove_stack()
      -- ENO: auto-configure when scrolled into
      if is_eno() then
        state.reverb  = 0.55
        state.density = 0.12
        engine.set_rev(state.reverb)
        build_groove_stack()
        oracle.flash("eno", 1.8)
      end
    elseif n == 3 then
      state.density = util.clamp(state.density + d * 0.03, 0.05, 1.0)
      build_groove_stack()
    end
  end
  state.screen_dirty = true
  state.grid_dirty   = true
end

function key(n, z)
  if n == 1 then
    state.key1_down = (z == 1)

  elseif n == 2 and z == 1 then
    state.playing = not state.playing
    if state.playing then
      build_groove_stack()
      if the_lattice then the_lattice:start() end
    else
      if the_lattice then the_lattice:stop() end
      all_notes_off()
    end

  elseif n == 3 and z == 1 then
    state.density    = 0.3 + math.random() * 0.65
    state.groove_idx = math.random(#groove_names)
    build_groove_stack()
    local gname = groove_names[state.groove_idx]
    local p, _  = cr:peek()
    oracle.flash(oracle.pick_word(gname, tension.value, p))
  end

  state.screen_dirty = true
  state.grid_dirty   = true
end

-- -------------------------------------------------------------------------
-- PARAMS
-- -------------------------------------------------------------------------
local function add_params()
  params:add_separator("VESSEL")

  params:add_number("root_note", "root note", 24, 72, 48,
    function(p) return musicutil.note_num_to_name(p:get(), true) end)
  params:set_action("root_note", function(v)
    state.root_note = v
    state.screen_dirty = true
  end)

  params:add_option("scale", "scale", scale_names, state.scale_idx)
  params:set_action("scale", function(v)
    state.scale_idx = v; state.grid_dirty = true
  end)

  params:add_option("chord", "chord voicing", chord_names, state.chord_idx)
  params:set_action("chord", function(v) state.chord_idx = v end)

  params:add_option("groove", "groove preset", groove_names, state.groove_idx)
  params:set_action("groove", function(v)
    state.groove_idx = v; build_groove_stack()
  end)

  params:add_control("density", "density",
    controlspec.new(0.05, 1.0, "lin", 0.01, 0.65))
  params:set_action("density", function(v)
    state.density = v; build_groove_stack(); state.grid_dirty = true
  end)

  params:add_number("tension_bars", "tension release every N bars", 2, 32, 8)
  params:set_action("tension_bars", function(v)
    tension.release_bar = v
  end)

  params:add_control("reverb", "reverb",
    controlspec.new(0, 0.6, "lin", 0.01, 0.15))
  params:set_action("reverb", function(v)
    state.reverb = v; engine.set_rev(v)
  end)

  params:add_control("tape_sat", "tape saturation",
    controlspec.new(0, 0.8, "lin", 0.01, 0.2))
  params:set_action("tape_sat", function(v)
    engine.set_tape(v)
  end)

  params:add_separator("MIDI")
  params:add_number("opxy_ch_lead",  "OP-XY lead ch",   1, 16, 6)
  params:add_number("opxy_ch_bass",  "OP-XY bass ch",   1, 16, 5)
  params:add_number("opxy_ch_arp",   "OP-XY arp ch",    1, 16, 7)
  params:add_number("opxy_ch_chord", "OP-XY chord ch",  1, 16, 8)
  params:add_number("opz_ch_bass",   "OP-Z bass ch",    1, 16, 5)
  params:add_number("opz_ch_master", "OP-Z master ch",  1, 16, 13)
  params:add_number("op1_ch_chord",  "OP-1 chord ch",   1, 16, 1)
  params:add_number("midi_bend_range","MIDI bend range (semitones)", 1, 48, 2)

  params:bang()
end

-- -------------------------------------------------------------------------
-- INIT / CLEANUP
-- -------------------------------------------------------------------------
function init()
  math.randomseed(os.time())

  midi_opxy = find_midi_device("op-xy") or find_midi_device("opxy")
  midi_opz  = find_midi_device("op-z")  or find_midi_device("opz")
  midi_op1  = find_midi_device("op-1")  or find_midi_device("field")

  tension.release_bar = 8

  add_params()
  build_groove_stack()
  build_lattice()
  start_redraw_clocks()

  engine.set_rev(state.reverb)
  engine.set_tape(state.tape_sat)

  oracle.flash("vessel", 0.6)

  state.screen_dirty = true
  state.grid_dirty   = true

  print("VESSEL v2.1 initialized")
  print("ENO mode available — grid row 8 col 8")
  print("OP-XY: " .. (midi_opxy and "connected" or "not found"))
  print("OP-Z:  " .. (midi_opz  and "connected" or "not found"))
  print("OP-1 Field: " .. (midi_op1 and "connected" or "not found"))
end

function cleanup()
  state.playing = false
  if the_lattice then the_lattice:destroy() end
  all_notes_off()
  clock.cancel_all()
end
