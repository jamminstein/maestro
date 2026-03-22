-- ╔══════════════════════════════════════════════════════════╗
-- ║                   M A E S T R O                         ║
-- ║   Orchestral generative system                          ║
-- ║   OP-1 · OP-Z · OP-XY + MollyThePoly (internal)        ║
-- ║                                                          ║
-- ║   v4.1: conductor gestures + score view                ║
-- ║                                                          ║
-- ║   E1: Tempo           K1 (hold): Maestro page           ║
-- ║   E2: Mode            K2: Play / Stop                   ║
-- ║   E3: Density         K3: New Section                   ║
-- ║                                                          ║
-- ║   VOICES page (default):                                ║
-- ║     Grid rows 1–8  : voices  col15=mute  col16=blink    ║
-- ║                                                          ║
-- ║   MAESTRO page (hold K1):                               ║
-- ║     Row 1 cols 1–5 : mode          col16=play/stop      ║
-- ║     Row 2 cols 1–12: root semitone                      ║
-- ║     Row 3          : density bar                        ║
-- ║     Row 4          : dynamics bar                       ║
-- ║     Row 5 cols 1–4 : piano arpeggio pattern             ║
-- ║     Row 6 cols 1–3 : CC slew speed (slow/med/fast)      ║
-- ║     Row 8 cols 1–5 : gestures (swell/release/hush/...)  ║
-- ║                                                          ║
-- ║   NEW v4.1: Conductor gestures via grid + encoders      ║
-- ║   Accelerando/Ritardando: E1 w/ K1 (smooth tempo ramp)  ║
-- ║   Crescendo/Diminuendo: E2 w/ K1 (velocity dynamics)    ║
-- ║   Score View: horizontal scrolling note recorder/viz    ║
-- ║                                                          ║
-- ║   SCREEN REDESIGN: Conductor's view with 5-zone layout  ║
-- ║   STATUS STRIP (y0-8): Title, mood, score indicator     ║
-- ║   LIVE ZONE (y9-52): Voice ensemble activity bars       ║
-- ║   CONTEXT BAR (y53-58): Mood, BPM, voices, gesture      ║
-- ╚══════════════════════════════════════════════════════════╝

engine.name = "MollyThePoly"

local musicutil = require "musicutil"
local lattice   = require "lattice"

-- ─────────────────────────────────────────────────────────
-- MIDI DEVICES
-- Defaults: port 1=OP-1  port 2=OP-Z  port 3=OP-XY
-- Adjust in PARAMS > MAESTRO if your routing differs.
-- ─────────────────────────────────────────────────────────
local dev = { op1 = nil, opz = nil, opxy = nil }

-- ─────────────────────────────────────────────────────────
-- MODES & PROGRESSIONS
-- ─────────────────────────────────────────────────────────
local MODES = {
  { name = "Lydian",     scale = "lydian"        },
  { name = "Dorian",     scale = "dorian"        },
  { name = "Mixolydian", scale = "mixolydian"    },
  { name = "Aeolian",    scale = "natural minor" },
  { name = "Phrygian",   scale = "phrygian"      },
}

local PROGRESSIONS = {
  lydian            = { {1,3,5}, {4,6,8}, {5,7,9}, {2,4,6}, {1,3,5} },
  dorian            = { {1,3,5}, {4,6,8}, {5,7,9}, {6,8,10},{1,3,5} },
  mixolydian        = { {1,3,5}, {5,7,9}, {4,6,8}, {2,4,6}, {1,3,5} },
  ["natural minor"] = { {1,3,5}, {6,8,10},{4,6,8}, {5,7,9}, {1,3,5} },
  phrygian          = { {1,3,5}, {2,4,6}, {5,7,9}, {4,6,8}, {1,3,5} },
}

-- ─────────────────────────────────────────────────────────
-- GESTURE STATE
-- ─────────────────────────────────────────────────────────
local accelerando_active = false
local ritardando_active = false
local crescendo_active = false
local diminuendo_active = false
local gesture_start_tempo = 120
local gesture_start_dynamics = 0.65
local gesture_bars = 0
local gesture_bars_total = 2  -- 2 bars default
local gesture_flash_time = 0  -- for displaying gesture name briefly
local current_gesture_name = ""

-- ─────────────────────────────────────────────────────────
-- SCREEN STATE VARIABLES
-- ─────────────────────────────────────────────────────────
local beat_phase = 0  -- 0-1 for visual beat pulse
local popup_param = ""  -- encoder popup content
local popup_val = ""    -- encoder popup value
local popup_time = 0    -- remaining popup display time
local voice_activity = {0,0,0,0,0,0,0,0}  -- last note time for each voice
local score_view_enabled = false  -- toggle via params or gesture

-- ─────────────────────────────────────────────────────────
-- SCORE VIEW (ring buffer of recent note events)
-- ─────────────────────────────────────────────────────────
local score_view = {
  max_events = 64,
  events = {},  -- {voice_idx, note, time_beat}
  display_range = 32,  -- how many beats to show
}

local function record_score_event(voice_idx, note)
  table.insert(score_view.events, {
    voice = voice_idx,
    note = note,
    beat = global_step,
  })
  if #score_view.events > score_view.max_events then
    table.remove(score_view.events, 1)
  end
end

-- ─────────────────────────────────────────────────────────
-- GLOBAL STATE
-- ─────────────────────────────────────────────────────────
local playing     = false
local mode_idx    = 1
local root_note   = 60
local scale_notes = {}
local chord_idx   = 1
local current_chord_degrees = {1, 3, 5}

local density     = 0.65
local dynamics    = 0.65
local phrase_step = 0
local global_step = 0

local alt        = false
local grid_dirty = true
local main_lattice = nil
local screen_clock_id = nil

-- ─────────────────────────────────────────────────────────
-- NEW: DYNAMICS MODE, TUTTI/SOLI, FERMATA, REHEARSAL MARKS
-- ─────────────────────────────────────────────────────────
local dynamics_mode = "mf"  -- pp, mp, mf, f, ff
local dynamics_map = {
  pp = 0.35,
  mp = 0.55,
  mf = 0.75,
  f  = 0.9,
  ff = 1.0,
}
local dynamics_idx = 3  -- default to "mf"

local mode_tutti_soli = "tutti"  -- "tutti" or "soli"
local fermata_active = false
local k3_held = false

local marks = {}  -- table of bar numbers marked as rehearsal points
local k1_held = false

-- ─────────────────────────────────────────────────────────
-- VOICE TABLE
-- kind="midi"     → MIDI out via dev[]/channel
-- kind="internal" → MollyThePoly engine.noteOn/Off
-- gen             → generation counter for voice_lead guard
-- ─────────────────────────────────────────────────────────
local voices = {
  { name="Strings",  kind="midi",     dev="op1",  ch=1,  active=true,  prob=0.90, oct=0,  notes={}, gen=0 },
  { name="Piano",    kind="midi",     dev="op1",  ch=2,  active=true,  prob=0.55, oct=1,  notes={}, gen=0 },
  { name="Pad",      kind="midi",     dev="opxy", ch=1,  active=true,  prob=1.00, oct=-1, notes={}, gen=0 },
  { name="Melody",   kind="midi",     dev="opz",  ch=1,  active=false, prob=0.35, oct=2,  notes={}, gen=0 },
  { name="Bass",     kind="midi",     dev="opz",  ch=2,  active=true,  prob=0.70, oct=-2, notes={}, gen=0 },
  { name="Perc",     kind="midi",     dev="opz",  ch=10, active=false, prob=0.18, oct=0,  notes={}, gen=0 },
  { name="InnerStr", kind="internal", dev=nil,    ch=0,  active=true,  prob=0.85, oct=0,  notes={}, gen=0 },
  { name="Celesta",  kind="internal", dev=nil,    ch=0,  active=true,  prob=0.38, oct=2,  notes={}, gen=0 },
}

-- ─────────────────────────────────────────────────────────
-- RHYTHMIC / MELODIC STATE
-- ─────────────────────────────────────────────────────────
local BASS_RHYTHM = { 1,0,0,0, 0,0,0,0, 1,0,0,0, 0,0,1,0 }
local PERC_RHYTHM = { 1,0,0,0, 0,0,0,0, 0,0,0,0, 0,0,0,0 }

local PIANO_PATTERNS = {
  { 1,2,3,2 },
  { 1,3,2,3 },
  { 3,2,1,2 },
  { 1,2,3,1,2,3,2,1 },
}
local piano_pat_idx = 1

local mel_idx  = 5
local mel_dir  = 1
local mel_held = nil

local pad_phase  = 0
local PAD_PERIOD = 8 * 16   -- re-trigger every 8 bars of 16ths

local celesta_idx = 18
local last_bass   = nil

local swell_active   = false
local release_active = false

-- ─────────────────────────────────────────────────────────
-- MIDI CC AUTOMATION
-- ─────────────────────────────────────────────────────────
local cc_auto_enabled = true

local cc_cur = {
  op1  = { filter=64, expr=80, reverb=25 },
  opz  = { filter=64, expr=80, reverb=20 },
  opxy = { filter=80, expr=80, reverb=35 },
}
local cc_tgt = {
  op1  = { filter=64, expr=80, reverb=25 },
  opz  = { filter=64, expr=80, reverb=20 },
  opxy = { filter=80, expr=80, reverb=35 },
}
local cc_nums = {
  op1  = { filter=74, expr=11, reverb=91 },
  opz  = { filter=74, expr=11, reverb=91 },
  opxy = { filter=74, expr=11, reverb=91 },
}
local CC_SLEW   = 0.14
local CC_THRESH = 2

local function cc_compute_targets()
  local dyn = dynamics
  cc_tgt.op1.filter  = math.floor(util.linlin(0,1, 32, 114, dyn))
  cc_tgt.opz.filter  = math.floor(util.linlin(0,1, 26, 106, dyn))
  cc_tgt.opxy.filter = math.floor(util.linlin(0,1, 48, 120, dyn))
  cc_tgt.op1.expr    = math.floor(util.linlin(0,1, 32, 110, dyn))
  cc_tgt.opz.expr    = math.floor(util.linlin(0,1, 32, 110, dyn))
  cc_tgt.opxy.expr   = math.floor(util.linlin(0,1, 38, 114, dyn))
  cc_tgt.op1.reverb  = math.floor(util.linlin(0,1,  8,  52, dyn))
  cc_tgt.opz.reverb  = math.floor(util.linlin(0,1,  6,  42, dyn))
  cc_tgt.opxy.reverb = math.floor(util.linlin(0,1, 18,  62, dyn))
end

local function cc_tick()
  if not cc_auto_enabled then return end
  cc_compute_targets()
  for _, dn in ipairs({"op1","opz","opxy"}) do
    local device = dev[dn]
    if device then
      for _, ck in ipairs({"filter","expr","reverb"}) do
        local cur = cc_cur[dn][ck]
        local tgt = cc_tgt[dn][ck]
        local nxt = math.floor(cur + (tgt - cur) * CC_SLEW)
        if math.abs(tgt - nxt) < CC_THRESH then nxt = tgt end
        nxt = util.clamp(nxt, 0, 127)
        if math.abs(nxt - cur) >= CC_THRESH then
          cc_cur[dn][ck] = nxt
          device:cc(cc_nums[dn][ck], nxt, 1)
        end
      end
    end
  end
end

-- ─────────────────────────────────────────────────────────
-- UNIFIED NOTE HELPERS
-- ─────────────────────────────────────────────────────────
local function voice_note_on(v, note, velocity)
  note = math.max(0, math.min(127, math.floor(note)))
  if v.kind == "midi" then
    local d = dev[v.dev]
    if not d then return end
    velocity = math.max(1, math.min(127, math.floor(velocity)))
    d:note_on(note, velocity, v.ch)
  else
    local amp = math.max(0.01, math.min(1.0, velocity / 127.0))
    engine.noteOn(note, musicutil.note_num_to_freq(note), amp)
  end
  v.notes[note] = true
  -- Update voice activity
  for i, voice in ipairs(voices) do
    if voice == v then voice_activity[i] = 4; break end
  end
  -- Record in score view
  for i, voice in ipairs(voices) do
    if voice == v then record_score_event(i, note); break end
  end
end

local function voice_note_off(v, note)
  note = math.max(0, math.min(127, math.floor(note)))
  if v.kind == "midi" then
    local d = dev[v.dev]
    if d then d:note_off(note, 0, v.ch) end
  else
    engine.noteOff(note)
  end
  v.notes[note] = nil
end

local function voice_clear(v)
  for note, _ in pairs(v.notes) do
    if v.kind == "midi" then
      local d = dev[v.dev]
      if d then d:note_off(note, 0, v.ch) end
    else
      engine.noteOff(note)
    end
  end
  v.notes = {}
  v.gen = v.gen + 1
end

local function all_notes_off()
  for _, v in ipairs(voices) do voice_clear(v) end
  mel_held  = nil
  last_bass = nil
end

local function internal_notes_off()
  for _, v in ipairs(voices) do
    if v.kind == "internal" then
      for note, _ in pairs(v.notes) do
        engine.noteOff(note)
      end
      v.notes = {}
      v.gen   = v.gen + 1
    end
  end
end

-- ─────────────────────────────────────────────────────────
-- VOICE LEADING
-- ─────────────────────────────────────────────────────────
local function voice_lead(v, new_notes, base_vel, stagger)
  stagger = stagger or 0.032

  local my_gen = v.gen

  local new_set = {}
  for _, n in ipairs(new_notes) do new_set[n] = true end

  local departing = {}
  for held, _ in pairs(v.notes) do
    if not new_set[held] then table.insert(departing, held) end
  end

  local arriving = {}
  for _, n in ipairs(new_notes) do
    if not v.notes[n] then table.insert(arriving, n) end
  end

  local claimed = {}
  local moves   = {}
  for _, dep in ipairs(departing) do
    local best_i, best_d = nil, 999
    for i, arr in ipairs(arriving) do
      if not claimed[i] then
        local d = math.abs(arr - dep)
        if d < best_d then best_d = d ; best_i = i end
      end
    end
    if best_i then
      claimed[best_i] = true
      table.insert(moves, { from=dep, to=arriving[best_i] })
    else
      table.insert(moves, { from=dep, to=nil })
    end
  end

  local fresh = {}
  for i, arr in ipairs(arriving) do
    if not claimed[i] then table.insert(fresh, arr) end
  end

  clock.run(function()
    clock.sleep(math.abs((math.random() - 0.5) * 0.016))
    for _, m in ipairs(moves) do
      if v.gen ~= my_gen then return end
      voice_note_off(v, m.from)
      if m.to then
        voice_note_on(v, m.to, base_vel - math.random(0, 8))
      end
      clock.sleep(stagger)
    end
    for _, n in ipairs(fresh) do
      if v.gen ~= my_gen then return end
      voice_note_on(v, n, base_vel - math.random(0, 10))
      clock.sleep(stagger)
    end
  end)
end

-- ─────────────────────────────────────────────────────────
-- SCALE / HARMONY HELPERS
-- ─────────────────────────────────────────────────────────
local function rebuild_scale()
  scale_notes = musicutil.generate_scale(root_note, MODES[mode_idx].scale, 4)
end

local function get_mode_progression()
  return PROGRESSIONS[MODES[mode_idx].scale] or PROGRESSIONS["dorian"]
end

local function advance_chord()
  local prog = get_mode_progression()
  chord_idx = (chord_idx % #prog) + 1
  current_chord_degrees = prog[chord_idx]
end

local function chord_to_notes(degrees, oct_offset)
  local result = {}
  for _, deg in ipairs(degrees) do
    local n = scale_notes[deg]
    if n then table.insert(result, n + (oct_offset or 0) * 12) end
  end
  return result
end

local function vel(base, voice_idx)
  -- Apply dynamics mode multiplier (pp, mp, mf, f, ff)
  local dyn_mult = dynamics_map[dynamics_mode] or 0.75
  local base_vel = base * dynamics * dyn_mult * (0.88 + math.random() * 0.24)

  -- Apply tutti/soli mode: in soli, only voice 1 (lead) is full velocity
  if mode_tutti_soli == "soli" then
    if voice_idx and voice_idx ~= 1 then
      base_vel = base_vel * 0.30  -- reduce non-lead voices to 30%
    end
  end

  return math.max(8, math.min(127, math.floor(base_vel)))
end

local function jitter(amount)
  return math.abs((math.random() - 0.5) * (amount or 0.014))
end

local function beat_sec()
  return clock.get_beat_sec()
end

-- ─────────────────────────────────────────────────────────
-- CONDUCTOR GESTURES
-- ─────────────────────────────────────────────────────────

local function start_accelerando()
  accelerando_active = true
  ritardando_active = false
  gesture_start_tempo = params:get("clock_tempo")
  gesture_bars = 0
  gesture_bars_total = 2
  gesture_flash_time = 0.5
  current_gesture_name = "Accelerando"
end

local function start_ritardando()
  ritardando_active = true
  accelerando_active = false
  gesture_start_tempo = params:get("clock_tempo")
  gesture_bars = 0
  gesture_bars_total = 2
  gesture_flash_time = 0.5
  current_gesture_name = "Ritardando"
end

local function start_crescendo()
  crescendo_active = true
  diminuendo_active = false
  gesture_start_dynamics = dynamics
  gesture_bars = 0
  gesture_bars_total = 4
  gesture_flash_time = 0.5
  current_gesture_name = "Crescendo"
end

local function start_diminuendo()
  diminuendo_active = true
  crescendo_active = false
  gesture_start_dynamics = dynamics
  gesture_bars = 0
  gesture_bars_total = 4
  gesture_flash_time = 0.5
  current_gesture_name = "Diminuendo"
end

-- ─────────────────────────────────────────────────────────
-- VOICE ENGINES
-- ─────────────────────────────────────────────────────────

-- 1. STRINGS (OP-1 ch1)
local function engine_strings(step)
  local v = voices[1]
  if not v.active or step % 32 ~= 0 then return end
  if math.random() > v.prob * math.max(0.5, density) then return end

  if next(v.notes) == nil then
    local chord = chord_to_notes(current_chord_degrees, v.oct)
    local bv = vel(72, 1)
    clock.run(function()
      clock.sleep(jitter(0.02))
      for i, n in ipairs(chord) do
        voice_note_on(v, n, bv - (i-1)*6)
        clock.sleep(0.038)
      end
    end)
  else
    voice_lead(v, chord_to_notes(current_chord_degrees, v.oct), vel(70, 1), 0.038)
  end
end

-- 2. PIANO (OP-1 ch2)
local function engine_piano(step)
  local v = voices[2]
  if not v.active or step % 2 ~= 0 then return end
  if math.random() > v.prob * density then return end

  local chord = chord_to_notes(current_chord_degrees, v.oct)
  if #chord == 0 then return end

  local pat  = PIANO_PATTERNS[piano_pat_idx]
  local beat = ((step - 1) % #pat) + 1
  local note = chord[math.max(1, math.min(#chord, pat[beat]))]
  if not note then return end

  local dur = beat_sec() * (0.45 + math.random() * 0.8)
  clock.run(function()
    clock.sleep(jitter(0.014))
    voice_note_on(v, note, vel(58, 2))
    clock.sleep(dur)
    voice_note_off(v, note)
  end)
end

-- 3. PAD (OP-XY ch1)
local function engine_pad(step)
  local v = voices[3]
  pad_phase = pad_phase + 1
  if not v.active then return end
  if pad_phase % PAD_PERIOD ~= 1 then return end

  local chord = chord_to_notes(current_chord_degrees, v.oct)
  local bv    = vel(42, 3)

  if next(v.notes) == nil then
    clock.run(function()
      clock.sleep(1.3)
      for _, n in ipairs(chord) do
        voice_note_on(v, n, bv)
        clock.sleep(0.09)
      end
    end)
  else
    clock.run(function()
      clock.sleep(0.4)
      voice_lead(v, chord, bv, 0.12)
    end)
  end
end

-- 4. MELODY (OP-Z ch1)
local function engine_melody(step)
  local v = voices[4]
  if not v.active or step % 4 ~= 0 then return end
  if math.random() > v.prob * density then
    if mel_held then voice_note_off(v, mel_held) ; mel_held = nil end
    return
  end

  local step_size = math.random() < 0.75 and 1 or math.random(2, 3)
  mel_idx = mel_idx + mel_dir * step_size
  if mel_idx >= #scale_notes - 3 then
    mel_dir = -1 ; mel_idx = #scale_notes - 4
  elseif mel_idx <= 3 then
    mel_dir = 1 ; mel_idx = 4
  end

  local note = scale_notes[mel_idx]
  if not note then return end
  note = math.max(0, math.min(127, note + v.oct * 12))

  if mel_held then voice_note_off(v, mel_held) ; mel_held = nil end

  local dur = beat_sec() * (1.0 + math.random() * 2.5)
  clock.run(function()
    clock.sleep(jitter(0.018))
    voice_note_on(v, note, vel(65, 4))
    mel_held = note
    clock.sleep(dur)
    if mel_held == note then voice_note_off(v, note) ; mel_held = nil end
  end)
end

-- 5. BASS (OP-Z ch2)
local function engine_bass(step)
  local v = voices[5]
  if not v.active then return end
  if BASS_RHYTHM[((step-1) % #BASS_RHYTHM) + 1] == 0 then return end
  if math.random() > v.prob * density then return end

  local note = scale_notes[current_chord_degrees[1] or 1]
  if not note then return end
  note = math.max(0, math.min(127, note + v.oct * 12))

  if last_bass then voice_note_off(v, last_bass) end
  local dur = beat_sec() * (0.65 + math.random() * 0.4)
  clock.run(function()
    clock.sleep(jitter(0.008))
    voice_note_on(v, note, vel(88, 5))
    last_bass = note
    clock.sleep(dur)
    voice_note_off(v, note)
    if last_bass == note then last_bass = nil end
  end)
end

-- 6. PERC (OP-Z ch10)
local PERC_PITCHES = { 36, 38, 42 }
local function engine_perc(step)
  local v = voices[6]
  if not v.active then return end
  if PERC_RHYTHM[((step-1) % #PERC_RHYTHM) + 1] == 0 then return end
  if math.random() > v.prob * density then return end
  local note = PERC_PITCHES[math.random(#PERC_PITCHES)]
  clock.run(function()
    clock.sleep(jitter(0.006))
    voice_note_on(v, note, vel(62, 6))
    clock.sleep(0.07)
    voice_note_off(v, note)
  end)
end

-- 7. INNER STRINGS (MollyThePoly) — root + 5th, enters 1 bar after strings
local function engine_inner_strings(step)
  local v = voices[7]
  if not v.active or step % 32 ~= 16 then return end
  if math.random() > v.prob * density then return end

  local root_deg  = current_chord_degrees[1]
  local fifth_deg = current_chord_degrees[3] or current_chord_degrees[1]
  local chord     = chord_to_notes({root_deg, fifth_deg}, v.oct)
  local bv        = vel(52, 7)

  if next(v.notes) == nil then
    clock.run(function()
      clock.sleep(jitter(0.022))
      for i, n in ipairs(chord) do
        voice_note_on(v, n, bv - (i-1)*4)
        clock.sleep(0.055)
      end
    end)
  else
    voice_lead(v, chord, bv, 0.055)
  end
end

-- 8. CELESTA (MollyThePoly) — high shimmer, short noteOn + long release tail
local function engine_celesta(step)
  local v = voices[8]
  if not v.active or step % 3 ~= 0 then return end
  if math.random() > v.prob * density then return end

  local dir   = math.random() < 0.55 and 1 or -1
  local sz    = math.random() < 0.7  and 1 or 2
  local lo    = math.max(1, #scale_notes - 10)
  local hi    = math.max(lo, #scale_notes)
  celesta_idx = util.clamp(celesta_idx + dir * sz, lo, hi)

  local note = scale_notes[celesta_idx]
  if not note then return end
  note = math.max(0, math.min(127, note + v.oct * 12))

  clock.run(function()
    clock.sleep(jitter(0.010))
    voice_note_on(v, note, vel(40, 8))
    clock.sleep(0.075)
    voice_note_off(v, note)
  end)
end

-- ─────────────────────────────────────────────────────────
-- MAIN TICK
-- ─────────────────────────────────────────────────────────
local function step_tick()
  if not playing then return end

  -- Fermata — skip engine calls if K3 held
  if fermata_active then
    -- Don't advance sequencer; voices sustain
    return
  end

  global_step = global_step + 1
  phrase_step = ((global_step - 1) % 128) + 1
  beat_phase = (beat_phase + 1/16) % 1  -- update beat phase

  if global_step % 32 == 0 then advance_chord() end

  engine_strings(global_step)
  engine_piano(global_step)
  engine_pad(global_step)
  engine_melody(global_step)
  engine_bass(global_step)
  engine_perc(global_step)
  engine_inner_strings(global_step)
  engine_celesta(global_step)

  if global_step % 8 == 0 then cc_tick() end

  -- Decay voice activity meters
  for i = 1, 8 do
    voice_activity[i] = math.max(0, voice_activity[i] - 0.25)
  end

  -- Conductor gestures
  if accelerando_active then
    gesture_bars = gesture_bars + (1 / 32)
    local progress = math.min(1.0, gesture_bars / gesture_bars_total)
    local new_tempo = gesture_start_tempo + (progress * 30)
    params:set("clock_tempo", new_tempo)
    if progress >= 1.0 then accelerando_active = false end
  end
  if ritardando_active then
    gesture_bars = gesture_bars + (1 / 32)
    local progress = math.min(1.0, gesture_bars / gesture_bars_total)
    local new_tempo = gesture_start_tempo - (progress * 30)
    params:set("clock_tempo", new_tempo)
    if progress >= 1.0 then ritardando_active = false end
  end
  if crescendo_active then
    gesture_bars = gesture_bars + (1 / 64)
    local progress = math.min(1.0, gesture_bars / gesture_bars_total)
    dynamics = gesture_start_dynamics + (progress * 0.3)
    dynamics = math.min(1.0, dynamics)
    if progress >= 1.0 then crescendo_active = false end
  end
  if diminuendo_active then
    gesture_bars = gesture_bars + (1 / 64)
    local progress = math.min(1.0, gesture_bars / gesture_bars_total)
    dynamics = gesture_start_dynamics - (progress * 0.3)
    dynamics = math.max(0.2, dynamics)
    if progress >= 1.0 then diminuendo_active = false end
  end

  if gesture_flash_time > 0 then
    gesture_flash_time = gesture_flash_time - (1/15)  -- ~15fps for decay
  end


  -- NEW: Check rehearsal marks at bar boundaries
  local current_bar = math.floor(global_step / 96)  -- 96 steps per bar (16 * 6)
  for _, mark_bar in ipairs(marks) do
    if current_bar == mark_bar then
      -- Force section/groove change
      advance_chord()
      gesture_flash_time = 0.5
      current_gesture_name = "Mark"
      break
    end
  end

  grid_dirty = true
  redraw()
end

-- ─────────────────────────────────────────────────────────
-- GRID
-- ─────────────────────────────────────────────────────────
local g = grid.connect()

local function grid_draw()
  if not g.device then return end
  if not g then return end
  g:all(0)

  if alt then
    -- MAESTRO PAGE ─────────────────────────────────────────
    for x = 1, #MODES do
      g:led(x, 1, x == mode_idx and 15 or 4)
    end
    g:led(16, 1, playing and 15 or 5)

    local semi = root_note % 12
    for x = 0, 11 do
      g:led(x+1, 2, x == semi and 15 or 3)
    end

    local df = math.floor(density * 16)
    for x = 1, 16 do g:led(x, 3, x <= df and 8 or 2) end

    local dynf = math.floor(dynamics * 16)
    for x = 1, 16 do g:led(x, 4, x <= dynf and 10 or 2) end

    for x = 1, #PIANO_PATTERNS do
      g:led(x, 5, x == piano_pat_idx and 15 or 4)
    end

    local slew_btn = CC_SLEW < 0.10 and 1 or (CC_SLEW < 0.20 and 2 or 3)
    g:led(1, 6, slew_btn == 1 and 12 or 4)
    g:led(2, 6, slew_btn == 2 and 12 or 4)
    g:led(3, 6, slew_btn == 3 and 12 or 4)
    g:led(5, 6, cc_auto_enabled and 10 or 3)

    -- Conductor gestures
    g:led(1, 8, accelerando_active   and 15 or 6)
    g:led(2, 8, ritardando_active    and 15 or 6)
    g:led(3, 8, crescendo_active     and 15 or 6)
    g:led(4, 8, diminuendo_active    and 15 or 6)
    g:led(5, 8, 6)

  else
    -- VOICES PAGE ──────────────────────────────────────────
    for i, v in ipairs(voices) do
      local fill = math.floor(v.prob * density * 12)
      for x = 1, 12 do
        g:led(x, i, (x <= fill) and (v.active and 6 or 2) or 0)
      end
      if v.kind == "internal" then
        g:led(13, i, v.active and 4 or 1)
      end
      g:led(15, i, v.active and 10 or 2)
      g:led(16, i, (playing and (global_step%8 < 4) and v.active) and 15 or 0)
    end
  end

  g:refresh()
  grid_dirty = false
end

if g then
  g.key = function(x, y, z)
    if z ~= 1 then return end

    if alt then
      if y == 1 then
        if x <= #MODES then
          mode_idx = x ; rebuild_scale() ; all_notes_off()
        elseif x == 16 then
          playing = not playing
          if not playing then all_notes_off() end
        end
      elseif y == 2 and x <= 12 then
        root_note = util.clamp(math.floor(root_note/12)*12 + (x-1), 48, 72)
        rebuild_scale()
      elseif y == 3 then
        density  = x / 16.0
      elseif y == 4 then
        dynamics = x / 16.0
      elseif y == 5 and x <= #PIANO_PATTERNS then
        piano_pat_idx = x
      elseif y == 6 then
        if     x == 1 then CC_SLEW = 0.07
        elseif x == 2 then CC_SLEW = 0.14
        elseif x == 3 then CC_SLEW = 0.30
        elseif x == 5 then cc_auto_enabled = not cc_auto_enabled
        end
      elseif y == 8 then
        if     x == 1 then start_accelerando()
        elseif x == 2 then start_ritardando()
        elseif x == 3 then start_crescendo()
        elseif x == 4 then start_diminuendo()
        end
      end

    else
      if y >= 1 and y <= #voices and x == 15 then
        local v = voices[y]
        v.active = not v.active
        if not v.active then
          voice_clear(v)
          if y == 4 then mel_held  = nil end
          if y == 5 then last_bass = nil end
        end
      end
    end

    grid_dirty = true
    grid_draw()
    redraw()
  end
end

-- ─────────────────────────────────────────────────────────
-- INIT
-- ─────────────────────────────────────────────────────────
function init()
  dev.op1  = midi.connect(1)
  dev.opz  = midi.connect(2)
  dev.opxy = midi.connect(3)

  params:add_separator("MAESTRO")

  params:add_number("op1_port",  "OP-1 Port",  1, 16, 1)
  params:add_number("opz_port",  "OP-Z Port",  1, 16, 2)
  params:add_number("opxy_port", "OP-XY Port", 1, 16, 3)
  params:set_action("op1_port",  function(v) dev.op1  = midi.connect(v) end)
  params:set_action("opz_port",  function(v) dev.opz  = midi.connect(v) end)
  params:set_action("opxy_port", function(v) dev.opxy = midi.connect(v) end)

  params:add_separator("ORCHESTRATION")

  params:add_option("mode", "Mode",
    {"Lydian","Dorian","Mixolydian","Aeolian","Phrygian"}, mode_idx)
  params:set_action("mode", function(v)
    mode_idx = v ; rebuild_scale() ; all_notes_off()
  end)
  params:add_number("root", "Root (MIDI)", 48, 72, root_note)
  params:set_action("root", function(v) root_note = v ; rebuild_scale() end)
  params:add_control("density", "Density",
    controlspec.new(0.1, 1.0, "lin", 0.01, density, ""))
  params:set_action("density", function(v) density = v end)
  params:add_control("dynamics", "Dynamics",
    controlspec.new(0.1, 1.0, "lin", 0.01, dynamics, ""))
  params:set_action("dynamics", function(v) dynamics = v end)

  -- NEW: Dynamics mode (pp, mp, mf, f, ff)
  params:add_option("dynamics_mode", "Dynamics Mode",
    {"pp", "mp", "mf", "f", "ff"}, dynamics_idx)
  params:set_action("dynamics_mode", function(v)
    dynamics_idx = v
    local modes = {"pp", "mp", "mf", "f", "ff"}
    dynamics_mode = modes[v]
  end)

  -- NEW: Tutti/Soli mode
  params:add_option("tutti_soli", "Tutti/Soli",
    {"Tutti", "Soli"}, mode_tutti_soli == "tutti" and 1 or 2)
  params:set_action("tutti_soli", function(v)
    mode_tutti_soli = v == 1 and "tutti" or "soli"
  end)

  params:add_separator("VOICES")
  local vnames = {"Strings","Piano","Pad","Melody","Bass","Perc","InnerStr","Celesta"}
  for i, nm in ipairs(vnames) do
    params:add_control("prob_"..i, nm.." prob",
      controlspec.new(0.0, 1.0, "lin", 0.01, voices[i].prob, ""))
    params:set_action("prob_"..i, function(v) voices[i].prob = v end)
  end

  params:add_separator("CC AUTOMATION")
  params:add_binary("cc_enable", "CC Auto Enable", "toggle", 1)
  params:set_action("cc_enable", function(v) cc_auto_enabled = (v == 1) end)

  local dev_labels  = { "OP-1",   "OP-Z",  "OP-XY" }
  local dev_keys    = { "op1",    "opz",   "opxy"  }
  local cc_labels   = { "filter", "expr",  "reverb" }
  local cc_defaults = { 74, 11, 91 }

  for di, dn in ipairs(dev_keys) do
    for ci, ck in ipairs(cc_labels) do
      local pname = "cc_"..dn.."_"..ck
      params:add_number(pname, dev_labels[di].." "..ck.." CC", 0, 127, cc_defaults[ci])
      params:set_action(pname, function(v) cc_nums[dn][ck] = v end)
    end
  end

  params:read()
  params:bang()

  clock.run(function()
    clock.sleep(0.5)
    local function try_set(name, value)
      local ok, err = pcall(function() params:set(name, value) end)
      if not ok then
        print("MAESTRO param warning: '" .. name .. "' — " .. tostring(err))
      end
    end
    try_set("amp_env_attack",  0.30)
    try_set("amp_env_decay",   0.20)
    try_set("amp_env_sustain", 0.85)
    try_set("amp_env_release", 2.60)
    try_set("cutoff",          1400)
    try_set("resonance",       0.18)
    try_set("env_mod",         0.15)
    try_set("lfo_freq",        0.35)
    try_set("lfo_to_pitch",    0.008)
    try_set("osc_wave_slew",   0.60)
    try_set("chorus_mix",      0.35)
  end)

  clock.run(function()
    clock.sleep(1.0)
    cc_compute_targets()
    for _, dn in ipairs({"op1","opz","opxy"}) do
      local device = dev[dn]
      if device then
        for _, ck in ipairs({"filter","expr","reverb"}) do
          local val = cc_tgt[dn][ck]
          cc_cur[dn][ck] = val
          device:cc(cc_nums[dn][ck], val, 1)
        end
      end
    end
  end)

  rebuild_scale()
  current_chord_degrees = get_mode_progression()[chord_idx]

  main_lattice = lattice:new({ auto=true, meter=4, ppqn=96 })
  main_lattice:new_sprocket({
    action = step_tick, division = 1/16, enabled = true,
  })
  main_lattice:start()

  screen_clock_id = clock.run(function()
    while true do
      clock.sleep(1/15)  -- 15fps refresh for score view scrolling
      if grid_dirty then grid_draw() end
      redraw()
    end
  end)

  redraw()
end

-- ─────────────────────────────────────────────────────────
-- ENCODERS
-- ─────────────────────────────────────────────────────────
function enc(n, d)
  if n == 1 then
    if alt then
      -- E1 + K1: accelerando/ritardando
      if d > 0 then start_accelerando()
      else start_ritardando() end
    else
      params:delta("clock_tempo", d)
      popup_param = "Tempo"
      popup_val = math.floor(params:get("clock_tempo"))
      popup_time = 0.8
    end
  elseif n == 2 then
    if alt then
      -- E2 + K1: crescendo/diminuendo
      if d > 0 then start_crescendo()
      else start_diminuendo() end
    else
      mode_idx = util.clamp(mode_idx + (d > 0 and 1 or -1), 1, #MODES)
      rebuild_scale() ; all_notes_off()
      popup_param = "Mode"
      popup_val = MODES[mode_idx].name
      popup_time = 0.8
    end
  elseif n == 3 then
    density = util.clamp(density + d * 0.02, 0.1, 1.0)
    popup_param = "Density"
    popup_val = math.floor(density * 100)
    popup_time = 0.8
  end
  grid_dirty = true
  redraw()
end

-- ─────────────────────────────────────────────────────────
-- KEYS
-- ─────────────────────────────────────────────────────────
function key(n, z)
  if n == 1 then
    k1_held = (z == 1)
    alt = (z == 1)
    grid_dirty = true
    grid_draw()
    redraw()
    return
  end

  -- NEW: K3 hold for fermata
  if n == 3 then
    k3_held = (z == 1)
    if z == 1 then
      fermata_active = true
    else
      fermata_active = false
    end
    redraw()
    return
  end

  if z ~= 1 then return end

  -- NEW: K1 + K3 for rehearsal marks
  if n == 1 and k1_held and k3_held then
    local current_bar = math.floor(global_step / 96)
    table.insert(marks, current_bar)
    gesture_flash_time = 0.3
    current_gesture_name = "Mark added"
    redraw()
    return
  end

  if n == 2 then
    -- NEW: K2 toggles tutti/soli mode
    if mode_tutti_soli == "tutti" then
      mode_tutti_soli = "soli"
      gesture_flash_time = 0.5
      current_gesture_name = "SOLI"
    else
      mode_tutti_soli = "tutti"
      gesture_flash_time = 0.5
      current_gesture_name = "TUTTI"
    end
    playing = not playing
    if not playing then all_notes_off() end
  elseif n == 3 then
    advance_chord()
  end
  grid_dirty = true
  redraw()
end

-- ─────────────────────────────────────────────────────────
-- SCREEN: CONDUCTOR'S VIEW DESIGN
-- ─────────────────────────────────────────────────────────
function redraw()
  screen.clear()
  screen.aa(0)

  if alt then
    -- MAESTRO EDIT PAGE (unchanged)
    screen.level(7) ; screen.font_size(8)
    screen.move(64, 8) ; screen.text_center("─ MAESTRO ─")
    screen.font_size(6)

    screen.level(4)
    screen.move(2,18) ; screen.text("mode")
    screen.move(2,27) ; screen.text("root")
    screen.move(2,36) ; screen.text("den")
    screen.move(2,45) ; screen.text("dyn")
    screen.move(2,54) ; screen.text("pat")
    screen.move(2,63) ; screen.text("gest")

    screen.level(14)
    screen.move(28,18) ; screen.text(MODES[mode_idx].name)
    screen.move(28,27) ; screen.text(musicutil.note_num_to_name(root_note, false))
    screen.move(28,54) ; screen.text("["..piano_pat_idx.."]")

    screen.level(8)
    screen.rect(28,32, math.floor(density*98), 4) ; screen.fill()
    screen.level(3)
    screen.rect(28,32, 98, 4) ; screen.stroke()

    screen.level(10)
    screen.rect(28,41, math.floor(dynamics*98), 4) ; screen.fill()
    screen.level(3)
    screen.rect(28,41, 98, 4) ; screen.stroke()

    screen.level(cc_auto_enabled and 10 or 3) ; screen.font_size(5)
    screen.move(108, 8) ; screen.text(cc_auto_enabled and "CC:on" or "CC:off")

    screen.level(5) ; screen.font_size(5)
    screen.move(28,63) ; screen.text("accel  ritar  cresc  dimin")

  else
    -- CONDUCTOR'S VIEW: 5-ZONE LAYOUT

    -- ─ ZONE 1: STATUS STRIP (y 0-8) ─────────────────────
    screen.level(4)
    screen.rect(0, 0, 128, 8)
    screen.stroke()

    screen.level(playing and 15 or 5) ; screen.font_size(7)
    screen.move(4, 6) ; screen.text("MAESTRO")

    screen.level(8) ; screen.font_size(6)
    local mood_name = MODES[mode_idx].name
    screen.move(64, 6) ; screen.text_center(mood_name)

    -- Beat pulse dot at x=124
    local pulse = math.sin(beat_phase * math.pi) * 0.5 + 0.5
    screen.level(math.floor(2 + pulse * 13))
    screen.circle(124, 4, 1.5)
    screen.fill()

    -- ─ ZONE 2: LIVE ZONE (y 9-52) ──────────────────────
    -- 8 voices as horizontal activity bars
    for i = 1, 8 do
      local v = voices[i]
      local y_base = 9 + (i-1) * 5.5
      local bar_height = 4

      -- Voice label at level 5 on left
      screen.level(5) ; screen.font_size(5)
      screen.move(2, y_base + 3)
      local abbrev = v.name:sub(1,3)
      screen.text(abbrev)

      -- Activity bar background (level 2)
      screen.level(2)
      screen.rect(16, y_base, 110, bar_height)
      screen.stroke()

      -- Activity bar fill: brightens on note fire, decays
      local activity = voice_activity[i]
      local bar_width = math.floor(110 * (v.prob * density * math.max(0.1, activity / 4)))
      local brightness = 2 + (activity / 4) * 13  -- decays from 15 to 2
      screen.level(math.floor(brightness))
      screen.rect(16, y_base, bar_width, bar_height)
      screen.fill()

      -- Active indicator
      if v.active then
        screen.level(10)
      else
        screen.level(3)
      end
      screen.move(15, y_base + 2.5)
      screen.text("●")
    end

    -- ─ SCORE VIEW ZONE (if enabled) ──────────────────────
    -- Simplified notation: horizontal staff lines, recent notes as dots
    if score_view_enabled then
      screen.level(2)
      for staff_idx = 0, 4 do
        local y = 9 + staff_idx * 9
        screen.move(16, y) ; screen.line(126, y) ; screen.stroke()
      end

      -- Plot recent notes as small dots
      for _, ev in ipairs(score_view.events) do
        local beat_offset = ev.beat - (global_step - score_view.display_range)
        if beat_offset >= 0 and beat_offset <= score_view.display_range then
          local x = 16 + (beat_offset / score_view.display_range) * 110
          -- Map note to staff position
          local staff_y = 9 + (120 - ev.note) * 9 / 120
          screen.level(8)
          screen.circle(x, staff_y, 0.8)
          screen.fill()
        end
      end
    end

    -- ─ ZONE 3: CONDUCTOR GESTURE FLASH ──────────────────
    if gesture_flash_time > 0 then
      local alpha = gesture_flash_time / 0.5  -- fade over 0.5s
      screen.level(math.floor(15 * alpha))
      screen.font_size(8)
      screen.move(64, 32) ; screen.text_center(current_gesture_name)
    end

    -- ─ ZONE 4: CONTEXT BAR (y 53-58) ────────────────────
    screen.level(6) ; screen.font_size(5)
    screen.move(2, 58)  ; screen.text(MODES[mode_idx].name)

    -- NEW: Display dynamics mode
    screen.level(fermata_active and 15 or 6)
    screen.move(32, 58) ; screen.text(dynamics_mode:upper().." "..mode_tutti_soli:sub(1,1):upper())

    screen.level(6)
    screen.move(32, 48) ; screen.text("BPM "..math.floor(params:get("clock_tempo")))

    local active_count = 0
    for _, v in ipairs(voices) do if v.active then active_count = active_count + 1 end end
    screen.move(68, 48) ; screen.text(active_count.." voices")

    -- NEW: Display rehearsal marks as dots on timeline
    local current_bar = math.floor(global_step / 96)
    screen.level(8)
    for _, mark_bar in ipairs(marks) do
      local x_pos = 68 + ((mark_bar % 8) * 6)
      screen.circle(x_pos, 56, 1.2)
      screen.fill()
    end

    screen.level(5) ; screen.font_size(4)
    local gesture_text = ""
    if accelerando_active then gesture_text = "accel"
    elseif ritardando_active then gesture_text = "ritar"
    elseif crescendo_active then gesture_text = "cresc"
    elseif diminuendo_active then gesture_text = "dimin"
    end
    screen.move(108, 58) ; screen.text(gesture_text)

    -- ─ ZONE 5: ENCODER POPUP ────────────────────────────
    if popup_time > 0 then
      popup_time = popup_time - (1/15)  -- decay
      local popup_alpha = popup_time / 0.8
      screen.level(math.floor(10 * popup_alpha))
      screen.font_size(6)
      screen.move(64, 24)
      if type(popup_val) == "string" then
        screen.text_center(popup_param.." : "..popup_val)
      else
        screen.text_center(popup_param.." : "..popup_val..("%" or ""))
      end
    end
  end

  screen.update()
end

-- ─────────────────────────────────────────────────────────
-- CLEANUP
-- ─────────────────────────────────────────────────────────
function cleanup()
  playing = false
  internal_notes_off()
  all_notes_off()
  if main_lattice then main_lattice:destroy() end
  if screen_clock_id then clock.cancel(screen_clock_id) end
  engine.noteKillAll()
  for _, dn in ipairs({"op1","opz","opxy"}) do
    local device = dev[dn]
    if device then
      for ch = 1, 16 do
        device:cc(123, 0, ch)
      end
      device:cc(cc_nums[dn].expr, 0, 1)
    end
  end
end
