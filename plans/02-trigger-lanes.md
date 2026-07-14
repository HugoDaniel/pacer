# 02 — Trigger / event lanes

**Repo:** pacer
**Wire impact:** appends `Compile.Code` variants; **no** `'PACW'` change (triggers write
ordinary entries to host-registered targets)
**Gates:** `zig build verify`, `zig build audit-diagnostics`, npm gate

## Why

The demo hand-rolls the same event idioms in five WGSL modules: per-beat pulse
`pow(1.0 - fract(beat), 4.0)`, backbeat gate `f32(i32(floor(beat)) & 1)`, "beats since
the tap" `fract((beat - 1.5) / 4.0) * 4.0`. A `(trigger …)` form emits those as lanes
so the shader reads a value instead of re-deriving clock math.

## Design (freeze in Phase 1)

```
(trigger :target snare :every 2b :offset 1b)          ; periodic
(trigger :target drop  :at [160b 220b 256b])          ; explicit hits
```

- Events are exact integer ticks: `offset + k·every` (periodic) or the sorted `:at`
  list. `:every` must be > 0 ticks; positions use existing time-pos units.
- At eval tick T the trigger finds the last event ≤ T (none yet → write omitted) and
  writes lanes **in this fixed order, truncated to the target's registry ncomp**:
  1. `phase` — 0..1 progress from that event to the next (explicit-list last event or
     one-shot: seconds-based decay is host business; phase holds 1.0)
  2. `count` — 0-based event index as f32
  3. `gate` — 1.0 on the exact event tick, else 0.0 (structural, like key landing)
  4. `beats-since` — beats elapsed since the event
  So an ncomp-1 target gets just `phase`; ncomp-4 gets all four.
- Phase/beats-since derive from tick deltas through the one documented f64 seam —
  specify the op order in the plan's Phase 3 test names so the golden pins it.
- Loop wrap: event schedule is defined on the unwrapped local timeline (wrap first,
  then resolve), matching track semantics.
- Trigger is a third kind of table row: reuse `Track` with a new `source` variant
  (internal representation, not wire). Counts against `MAX_TRACKS`.
- Scened triggers (if plan 01 landed): positions scene-relative, active only in-window.
- New diagnostics (append): `trigger_invalid` (missing/duplicate source, `:every` ≤ 0,
  empty/unsorted `:at`), `trigger_target_unknown` NOT added — reuse `unknown_target`.

## Phases

### Phase 1 — schema + validation (RED first)
Load: `schema/pacer.sjon`, `src/Compile.zig` (Code enum + validate stage), an existing
diagnostic test as pattern.
Reds: `(trigger)` with no `:every` and no `:at` → `trigger_invalid`; both →
`trigger_invalid`; `:every 0b` → `trigger_invalid`; unknown target → `unknown_target`;
valid periodic + valid list compile clean.
Green: schema form + appended `trigger_invalid`; validation only.
Gate: `zig build test`, `zig build audit-diagnostics`.

### Phase 2 — compile (RED first)
Load: `src/Compile.zig` (track walk), `src/TrackTable.zig`.
Reds: compiled table holds the trigger row with resolved tick schedule (periodic params
or an owned sorted tick slice), correct target/registry/ncomp join; schedule ticks past
2^53 → `tick_overflow`; trigger + 255 tracks → `track_cap_exceeded`.
Green: `Track.source` gains the trigger variant; arena-owned tick list.
Gate: `zig build test`.

### Phase 3 — eval (RED first)
Load: `src/Eval.zig`, `src/TimeMap.zig` (seconds seam reference).
Reds: point-sample tests — before first event: no write; on the exact event tick:
gate=1, phase=0, count=k; mid-interval: gate=0, phase in (0,1), beats-since exact;
after the last `:at` event: phase=1 held; ncomp truncation (ncomp-1 target gets phase
only, lanes above ncomp zeroed in the entry); loop wrap resets count per local
timeline; f64→f32 truncation only at emission.
Green: eval arm for the trigger source; binary-search or cached-cursor event lookup
(reuse the last-segment cache idea for O(1) near-monotonic sampling).
Gate: `zig build test`.

### Phase 4 — corpus + parity + docs
Load: `corpus/expr-control/` as template.
Work: new case `trigger-basic` (periodic ncomp-4, explicit-list ncomp-1, wrap, exact
event ticks in `times.sjon`); `zig build corpus -- --update` + diff review; npm needs
no code change (entries are ordinary writes) but add one `npm/pacer` test asserting a
trigger write flows through `toUniforms`; update `CLAUDE.md` surface table if needed.
Gate: `zig build verify` + npm gate.

## Progress log
