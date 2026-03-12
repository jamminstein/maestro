-- ╔══════════════════════════════════════════════════════════╗
-- ║                   M A E S T R O                         ║
-- ║   Orchestral generative system                          ║
-- ║   OP-1 · OP-Z · OP-XY + MollyThePoly (internal)        ║
-- ║                                                          ║
-- ║   v4: bug-fixed                                         ║
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
-- ║     Row 8 cols 1–5 : gestures                           ║
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

-- BUG FIX #5: pad_phase advances every tick regardless of voice.active,
-- so deactivating/reactivating the Pad voice doesn't desynchronise its
-- period from the global phrase.
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
  -- BUG FIX #7: use ipairs (guaranteed order) not pairs on array tables
  for _, dn in ipairs{"op1","opz","opxy"} do
    local device = dev[dn]
    if device then
      for _, ck in ipairs{"filter","expr","reverb"} do
        local cur = cc_cur[dn][ck]
        local tgt = cc_tgt[dn][ck]
        local nxt = math.floor(cur + (tgt - cur) * CC_SLEW)
        -- Snap to target if within threshold so slew always lands
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
    engine.noteOn(note, musicutil.midi_to_hz(note), amp)
  end
  v.notes[note] = true
end

local function voice_note_off(v, note)
  note = math.max(0, math.min(127, math.floor(note)))
  if v.kind == "midi" then
    local d = dev[v.dev]
    if not d then return end
    d:note_off(note, 0, v.ch)
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
  -- Bump generation so any in-flight voice_lead coroutine aborts
  v.gen = v.gen + 1
end

local function all_notes_off()
  for _, v in ipairs(voices) do voice_clear(v) end
  mel_held  = nil
  last_bass = nil
end

-- BUG FIX #4: explicit noteOff for all held internal notes
-- (engine.noteOffAll is not a valid MollyThePoly command)
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
--
-- Common tones between old and new chord stay held.
-- Moving voices find their nearest destination note
-- (greedy nearest-neighbour by semitone distance).
--
-- BUG FIX #6: generation guard — if voice_clear() or a new
-- voice_lead() fires while this coroutine is sleeping between
-- stagger steps, the old coroutine detects the generation bump
-- and exits without sending any more notes.
-- ─────────────────────────────────────────────────────────
local function voice_lead(v, new_notes, base_vel, stagger)
  stagger = stagger or 0.032

  -- Capture current generation; if it changes mid-sleep, we abort
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

  -- Greedy nearest-neighbour matching
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
      if v.gen ~= my_gen then return end  -- abort: voice was cleared or retriggered
      voice_note_off(v, m.from)
      if m.to then
        voice_note_on(v, m.to, base_vel - math.random(0, 8))
      end
      clock.sleep(stagger)
    end
    for _, n in ipairs(fresh) do
      if v.gen ~= my_gen then return end  -- abort
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

local function vel(base)
  return math.max(8, math.min(127, math.floor(
    base * dynamics * (0.88 + math.random() * 0.24)
  )))
end

local function jitter(amount)
  return math.abs((math.random() - 0.5) * (amount or 0.014))
end

local function beat_sec()
  return clock.get_beat_sec()
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
    local bv = vel(72)
    clock.run(function()
      clock.sleep(jitter(0.02))
      for i, n in ipairs(chord) do
        voice_note_on(v, n, bv - (i-1)*6)
        clock.sleep(0.038)
      end
    end)
  else
    voice_lead(v, chord_to_notes(current_chord_degrees, v.oct), vel(70), 0.038)
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
    voice_note_on(v, note, vel(58))
    clock.sleep(dur)
    voice_note_off(v, note)
  end)
end

-- 3. PAD (OP-XY ch1)
local function engine_pad(step)
  local v = voices[3]
  -- BUG FIX #5: pad_phase advances every tick regardless of v.active
  pad_phase = pad_phase + 1
  if not v.active then return end
  if pad_phase % PAD_PERIOD ~= 1 then return end

  local chord = chord_to_notes(current_chord_degrees, v.oct)
  local bv    = vel(42)

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
    voice_note_on(v, note, vel(65))
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
    voice_note_on(v, note, vel(88))
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
    voice_note_on(v, note, vel(62))
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
  local bv        = vel(52)

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
  -- Guard: scale_notes might be short in exotic modes
  local lo    = math.max(1, #scale_notes - 10)
  local hi    = math.max(lo, #scale_notes)
  celesta_idx = util.clamp(celesta_idx + dir * sz, lo, hi)

  local note = scale_notes[celesta_idx]
  if not note then return end
  note = math.max(0, math.min(127, note + v.oct * 12))

  clock.run(function()
    clock.sleep(jitter(0.010))
    voice_note_on(v, note, vel(40))
    clock.sleep(0.075)
    voice_note_off(v, note)
  end)
end

-- ─────────────────────────────────────────────────────────
-- MAIN TICK
-- ─────────────────────────────────────────────────────────
local function step_tick()
  if not playing then return end

  global_step = global_step + 1
  phrase_step = ((global_step - 1) % 128) + 1

  -- BUG FIX #3: advance chord at end of bar (step % 32 == 0),
  -- not at start (step % 32 == 1), so voices always play the
  -- current chord on the downbeat — not the one being exited.
  -- Skip step 0 guard: global_step starts at 1 so % 32 == 0
  -- fires first at step 32, after a full 2 bars of chord 1.
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

  if swell_active then
    dynamics = math.min(1.0, dynamics + 0.003)
    if dynamics >= 1.0 then swell_active = false end
  end
  if release_active then
    dynamics = math.max(0.12, dynamics - 0.003)
    if dynamics <= 0.12 then release_active = false end
  end

  grid_dirty = true
  redraw()
end

-- ─────────────────────────────────────────────────────────
-- MAESTRO GESTURES
-- ─────────────────────────────────────────────────────────
local function gesture_swell()
  swell_active = true ; release_active = false
  -- BUG FIX #7: ipairs for ordered iteration
  for _, dn in ipairs{"op1","opz","opxy"} do
    cc_tgt[dn].filter = math.min(127, cc_tgt[dn].filter + 18)
    cc_tgt[dn].expr   = math.min(127, cc_tgt[dn].expr   + 12)
  end
end

local function gesture_release()
  release_active = true ; swell_active = false
  for _, dn in ipairs{"op1","opz","opxy"} do
    cc_tgt[dn].filter = math.max(0, cc_tgt[dn].filter - 18)
    cc_tgt[dn].expr   = math.max(0, cc_tgt[dn].expr   - 12)
  end
end

local function gesture_hush()
  for i, v in ipairs(voices) do
    if i ~= 3 and i ~= 7 then voice_clear(v) end
  end
  mel_held  = nil
  last_bass = nil
  dynamics  = math.min(dynamics, 0.28)
  cc_tgt.op1.reverb  = 88
  cc_tgt.opz.reverb  = 72
  cc_tgt.opxy.reverb = 100
end

local function gesture_cadence()
  local prog = get_mode_progression()
  chord_idx  = math.max(1, #prog - 1)
  current_chord_degrees = prog[chord_idx]
  all_notes_off()
  pad_phase = 0   -- triggers on next tick (1 % PAD_PERIOD == 1)
end

local function gesture_new_section()
  advance_chord() ; advance_chord()
  piano_pat_idx = (piano_pat_idx % #PIANO_PATTERNS) + 1
  if math.random() < 0.30 then
    root_note = root_note + 7
    if root_note > 67 then root_note = root_note - 12 end
    rebuild_scale()
    chord_idx = 1
    current_chord_degrees = get_mode_progression()[chord_idx]
  end
  all_notes_off()
  pad_phase = 0   -- triggers on next tick
end

-- ─────────────────────────────────────────────────────────
-- GRID
-- BUG FIX #1: grid.connect() can return nil if no grid is
-- attached. Assigning to nil.key crashes. All grid access
-- is now guarded. g.key is only set if g is non-nil.
-- ─────────────────────────────────────────────────────────
local g = grid.connect()

local function grid_draw()
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

    g:led(1, 8, swell_active   and 15 or 6)
    g:led(2, 8, release_active and 15 or 6)
    g:led(3, 8, 6)
    g:led(4, 8, 6)
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

-- BUG FIX #1 continued: only assign g.key if g is valid
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
        if     x == 1 then gesture_swell()
        elseif x == 2 then gesture_release()
        elseif x == 3 then gesture_hush()
        elseif x == 4 then gesture_cadence()
        elseif x == 5 then gesture_new_section()
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

  params:add_separator("VOICES")
  local vnames = {"Strings","Piano","Pad","Melody","Bass","Perc","InnerStr","Celesta"}
  for i, nm in ipairs(vnames) do
    -- NOTE: Lua 5.3 for-loop variables are local per-iteration,
    -- so each closure correctly captures its own i. (Bug #8 confirmed safe.)
    params:add_control("prob_"..i, nm.." prob",
      controlspec.new(0.0, 1.0, "lin", 0.01, voices[i].prob, ""))
    params:set_action("prob_"..i, function(v) voices[i].prob = v end)
  end

  -- CC Automation params
  params:add_separator("CC AUTOMATION")
  params:add_binary("cc_enable", "CC Auto Enable", "toggle", 1)
  params:set_action("cc_enable", function(v) cc_auto_enabled = (v == 1) end)

  local dev_labels  = { "OP-1",   "OP-Z",  "OP-XY" }
  local dev_keys    = { "op1",    "opz",   "opxy"  }
  local cc_labels   = { "filter", "expr",  "reverb" }
  local cc_defaults = { 74, 11, 91 }

  -- NOTE: inner-loop closures capture dn/ck which are Lua 5.3 per-iteration
  -- locals — each closure correctly captures its own dn and ck. (Bug #8)
  for di, dn in ipairs(dev_keys) do
    for ci, ck in ipairs(cc_labels) do
      local pname = "cc_"..dn.."_"..ck
      params:add_number(pname, dev_labels[di].." "..ck.." CC", 0, 127, cc_defaults[ci])
      params:set_action(pname, function(v) cc_nums[dn][ck] = v end)
    end
  end

  params:read()
  params:bang()

  -- ── BUG FIX #2: correct MollyThePoly param names ─────
  -- Wrapped in pcall so a wrong name prints a console warning
  -- instead of silently failing. Check maiden > log if timbre
  -- doesn't match expectations.
  -- Full MollyThePoly param list visible in PARAMS menu at runtime.
  clock.run(function()
    clock.sleep(0.5)
    local function try_set(name, value)
      local ok, err = pcall(function() params:set(name, value) end)
      if not ok then
        print("MAESTRO param warning: '" .. name .. "' — " .. tostring(err))
      end
    end
    -- Envelope (correct MollyThePoly IDs)
    try_set("amp_env_attack",  0.30)
    try_set("amp_env_decay",   0.20)
    try_set("amp_env_sustain", 0.85)
    try_set("amp_env_release", 2.60)
    -- Filter
    try_set("cutoff",          1400)
    try_set("resonance",       0.18)
    try_set("env_mod",         0.15)  -- filter envelope modulation amount
    -- LFO (pitch vibrato)
    try_set("lfo_freq",        0.35)
    try_set("lfo_to_pitch",    0.008)
    -- Oscillator / texture
    try_set("osc_wave_slew",   0.60)
    try_set("chorus_mix",      0.35)
  end)

  -- Push initial CC values to all connected devices
  clock.run(function()
    clock.sleep(1.0)
    cc_compute_targets()
    for _, dn in ipairs{"op1","opz","opxy"} do
      local device = dev[dn]
      if device then
        for _, ck in ipairs{"filter","expr","reverb"} do
          local val = cc_tgt[dn][ck]
          cc_cur[dn][ck] = val
          device:cc(cc_nums[dn][ck], val, 1)
        end
      end
    end
  end)

  rebuild_scale()
  current_chord_degrees = get_mode_progression()[chord_idx]

  local main_lattice = lattice:new({ auto=true, meter=4, ppqn=96 })
  main_lattice:new_sprocket({
    action = step_tick, division = 1/16, enabled = true,
  })
  main_lattice:start()

  clock.run(function()
    while true do
      clock.sleep(1/20)
      if grid_dirty then grid_draw() end
    end
  end)

  redraw()
end

-- ─────────────────────────────────────────────────────────
-- ENCODERS
-- ─────────────────────────────────────────────────────────
function enc(n, d)
  if n == 1 then
    params:delta("clock_tempo", d)
  elseif n == 2 then
    mode_idx = util.clamp(mode_idx + (d > 0 and 1 or -1), 1, #MODES)
    rebuild_scale() ; all_notes_off()
  elseif n == 3 then
    density = util.clamp(density + d * 0.02, 0.1, 1.0)
  end
  grid_dirty = true
  redraw()
end

-- ─────────────────────────────────────────────────────────
-- KEYS
-- ─────────────────────────────────────────────────────────
function key(n, z)
  if n == 1 then
    alt = (z == 1)
    grid_dirty = true
    grid_draw()
    redraw()
    return
  end
  if z ~= 1 then return end
  if n == 2 then
    playing = not playing
    if not playing then all_notes_off() end
  elseif n == 3 then
    gesture_new_section()
  end
  grid_dirty = true
  redraw()
end

-- ─────────────────────────────────────────────────────────
-- SCREEN
-- ─────────────────────────────────────────────────────────
function redraw()
  screen.clear()
  screen.aa(1)

  if alt then
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
    screen.move(28,63) ; screen.text("sw  rel  hsh  cad  sec")

  else
    screen.level(playing and 15 or 5) ; screen.font_size(8)
    screen.move(64, 8) ; screen.text_center("MAESTRO")

    screen.level(10) ; screen.font_size(6)
    screen.move(64, 17)
    screen.text_center(musicutil.note_num_to_name(root_note, false)
      .."  "..MODES[mode_idx].name)

    screen.level(2) ; screen.rect(4,21,120,2) ; screen.stroke()
    screen.level(7)
    screen.rect(4,21, math.floor((phrase_step/128)*120), 2) ; screen.fill()

    if swell_active then
      screen.level(15) ; screen.move(122,17) ; screen.text("↑")
    elseif release_active then
      screen.level(5)  ; screen.move(122,17) ; screen.text("↓")
    end

    screen.font_size(6)
    for i, v in ipairs(voices) do
      local col = (i <= 4) and 0 or 64
      local x, y = col + 4, 30 + ((i-1)%4)*9
      screen.level(v.active and 12 or 3)
      screen.move(x, y)
      local dot = v.active
        and (v.kind=="internal" and "◆ " or "● ")
        or  (v.kind=="internal" and "◇ " or "○ ")
      screen.text(dot..v.name)
    end

    screen.level(4) ; screen.font_size(5)
    screen.move(4,63)  ; screen.text("den")
    screen.move(46,63) ; screen.text("dyn")
    screen.move(88,63)
    screen.level(cc_auto_enabled and 6 or 2)
    screen.text("cc:"..math.floor(dynamics*100).."%")

    screen.level(8)
    screen.rect(14,59, math.floor(density*28),  3) ; screen.fill()
    screen.rect(56,59, math.floor(dynamics*28), 3) ; screen.fill()
    screen.level(2)
    screen.rect(14,59, 28, 3) ; screen.stroke()
    screen.rect(56,59, 28, 3) ; screen.stroke()
  end

  screen.update()
end

-- ─────────────────────────────────────────────────────────
-- CLEANUP
-- ─────────────────────────────────────────────────────────
function cleanup()
  -- BUG FIX #4: explicitly noteOff all held internal (MollyThePoly) notes
  -- engine.noteOffAll() is not a valid MollyThePoly command
  internal_notes_off()
  all_notes_off()
  -- Polite exit: zero expression CC on all MIDI devices
  for _, dn in ipairs{"op1","opz","opxy"} do
    local device = dev[dn]
    if device then device:cc(cc_nums[dn].expr, 0, 1) end
  end
end
