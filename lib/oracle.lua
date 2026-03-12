-- lib/oracle.lua
-- VESSEL generative text engine
-- Words appear on screen timed to the music, fade with the beat
-- Each groove mode has its own vocabulary
-- Musical state (tension, phase, scale) shifts word selection
-- Inspired by: ORACLE script concept

local oracle = {}

-- -------------------------------------------------------------------------
-- WORD BANKS
-- Organized by: groove personality × tension level × call/response phase
-- Low tension = elemental, sparse. High tension = kinetic, breaking.
-- -------------------------------------------------------------------------

oracle.banks = {

  -- James Brown vocabulary: body, motion, economy, the groove as religion
  brown = {
    low  = {"feel","soul","one","down","stay","wait","now","it"},
    mid  = {"push","hold","break","hard","hit","lock","burn","stay"},
    high = {"FIRE","OUT","YES","NOW","HARD","BREAK","TAKE","DOWN"},
    call = {"say it","bring it","come on","right now","can you feel"},
    resp = {"that's it","get up","yeah","ow","I know","good god"},
  },

  -- Bossa Nova: intimacy, coastal light, suspended time
  bossa = {
    low  = {"agua","tarde","luz","mar","calma","brisa","vem","assim"},
    mid  = {"saudade","longe","dentro","espera","quase","talvez","voltar"},
    high = {"tempesta","fundo","perdido","fogo","escuro","demais"},
    call = {"você não","eu queria","ainda é","se for","como se"},
    resp = {"ficou","passou","então","sim","aqui","nunca mais"},
  },

  -- Aphex Twin: machines dreaming, fractured perception, pattern as hallucination
  aphex = {
    low  = {"drift","pulse","still","fold","loop","dim","far","cool"},
    mid  = {"phase","shift","glitch","blur","echo","ghost","bend","warp"},
    high = {"BREAK","SHRED","FEED","CRASH","SPLIT","BURST","ERASE","NULL"},
    call = {"are you","inside","what is","beneath","between"},
    resp = {"nothing","always","signal","dissolving","recursive","void"},
  },

  -- Daft Punk: repetition as transcendence, the machine with feeling
  daft = {
    low  = {"work","more","again","fresh","alive","make","feel","do"},
    mid  = {"harder","better","faster","stronger","human","after","long"},
    high = {"HARDER","BETTER","FASTER","STRONGER","NOW","AFTER","LONG"},
    call = {"work it","make it","do it","makes us"},
    resp = {"harder","better","faster","stronger","after","longer"},
  },

  -- Frusciante / Maya: jungle abstracted, body music at the edge of collapse
  maya = {
    low  = {"skin","breath","fall","ground","weight","heavy","close","slow"},
    mid  = {"faster","losing","fragment","scatter","pulse","tear","dissolve"},
    high = {"COLLAPSE","SCATTER","BREAK","CHAOS","SPLINTER","FLOOD","SHATTER"},
    call = {"can you","before the","at the edge","going down","inside the"},
    resp = {"falling","everything","I can't","it breaks","goes away"},
  },
}

-- -------------------------------------------------------------------------
-- WORD STATE
-- -------------------------------------------------------------------------
oracle.current_word   = ""
oracle.alpha          = 0      -- 0 = invisible, 1 = fully bright (0..15 for screen)
oracle.decay_rate     = 0.06   -- how fast words fade (per redraw tick)
oracle.x              = 20     -- screen x position
oracle.y              = 35     -- screen y position

-- Internal
local word_timer      = 0
local word_interval   = 8      -- beats between new words
local groove_idx      = 1
local groove_names    = {"brown","bossa","aphex","daft","maya"}

-- -------------------------------------------------------------------------
-- WORD SELECTION
-- Picks a word based on groove mode, tension (0..1), and phase
-- -------------------------------------------------------------------------
function oracle.pick_word(mode_name, tension, phase)
  local bank = oracle.banks[mode_name]
  if bank == nil then bank = oracle.banks["brown"] end

  -- Occasionally use full phrase (call/response sentences)
  if math.random() < 0.25 then
    local phrases = (phase == "call") and bank.call or bank.resp
    if phrases and #phrases > 0 then
      return phrases[math.random(#phrases)]
    end
  end

  -- Select tier by tension
  local tier
  if tension < 0.35 then
    tier = bank.low
  elseif tension < 0.70 then
    tier = bank.mid
  else
    tier = bank.high
  end

  if tier and #tier > 0 then
    return tier[math.random(#tier)]
  end
  return ""
end

-- -------------------------------------------------------------------------
-- TICK: call once per beat from lattice
-- mode_name: current groove name
-- tension: 0..1
-- phase: "call" or "response"
-- -------------------------------------------------------------------------
function oracle.tick(mode_name, tension, phase)
  word_timer = word_timer + 1

  -- New word every word_interval beats (faster at high tension)
  local interval = math.floor(word_interval * (1 - tension * 0.5))
  interval = math.max(2, interval)

  if word_timer >= interval then
    word_timer          = 0
    oracle.current_word = oracle.pick_word(mode_name, tension, phase)
    -- Position: drift slightly per word, constrained to screen
    oracle.x = math.random(8, 80)
    oracle.y = math.random(14, 54)
    -- Appear at brightness tied to tension
    oracle.alpha = 0.5 + tension * 0.5
  end
end

-- -------------------------------------------------------------------------
-- UPDATE: call every redraw tick to decay the word
-- -------------------------------------------------------------------------
function oracle.update()
  if oracle.alpha > 0 then
    oracle.alpha = oracle.alpha - oracle.decay_rate
    if oracle.alpha < 0 then oracle.alpha = 0 end
  end
end

-- -------------------------------------------------------------------------
-- DRAW: call inside screen redraw
-- Returns true if something was drawn
-- -------------------------------------------------------------------------
function oracle.draw()
  if oracle.current_word == "" or oracle.alpha <= 0 then return false end
  local brightness = math.floor(oracle.alpha * 12)
  if brightness < 1 then return false end
  screen.level(brightness)
  screen.font_size(8)
  screen.move(oracle.x, oracle.y)
  screen.text(oracle.current_word)
  return true
end

-- -------------------------------------------------------------------------
-- FORCE a specific word (e.g. on mutate, on key press)
-- -------------------------------------------------------------------------
function oracle.flash(word, brightness_override)
  oracle.current_word = word or ""
  oracle.alpha        = brightness_override or 1.0
  oracle.x            = 20
  oracle.y            = 32
end

return oracle
