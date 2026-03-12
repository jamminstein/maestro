# maestro

Orchestral generative system for norns + grid. Drives OP-1, OP-Z, and OP-XY via MIDI alongside an internal MollyThePoly voice. Multiple compositional modes, harmonic progressions, density/dynamics control, gestures, and per-voice mute/solo from the grid.

## Install

`;install https://github.com/jamminstein/maestro`

## Controls

**Norns:**
- E1: Tempo
- E2: Mode
- E3: Density
- K1 (hold): Maestro page
- K2: Play / Stop
- K3: New Section

**Grid (16x8) — Voices page (default):**
- Rows 1-8: Voices
- Col 15: Mute
- Col 16: Blink

**Grid — Maestro page (hold K1):**
- Row 1 cols 1-5: Mode select, col 16: play/stop
- Row 2 cols 1-12: Root semitone
- Row 3: Density bar
- Row 4: Dynamics bar
- Row 5 cols 1-4: Piano arpeggio pattern
- Row 6 cols 1-3: CC slew speed (slow/med/fast)
- Row 8 cols 1-5: Gestures

## Features

- Multiple compositional modes with harmonic progressions
- Drives OP-1, OP-Z, and OP-XY via MIDI
- Internal MollyThePoly voice
- Density and dynamics control
- Per-voice mute from grid
- Musical gestures system
- CC slew with adjustable speed

## Requirements

- norns
- grid 16x8
- MIDI devices (OP-1, OP-Z, OP-XY recommended)

## Author

@jamminstein
