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

### Phase 1 — schema + validation (done, 2026-07-14)

**RED first.** Appended `trigger_invalid` (= **26**) to `Compile.Code` (so the tests
compile), then wrote five tests and ran `zig build test` → 4 fail + 1 crash: with no
schema `trigger` form, `(trigger …)` is an unknown head, so SJON rejects the doc and
*no* pacer diagnostic is emitted (`findDiag(.trigger_invalid)` is null, the valid case
never reaches `ok()`). Green after the schema form + a `validateTriggers` stage.

**Design frozen.** `(trigger :target T :every Nb :offset Mb)` (periodic) XOR
`(trigger :target T :at [P …])` (explicit hits). Both `:every` and `:at` are
**schema-optional**, so every trigger-shape defect routes through the pacer
`trigger_invalid` code (with a span), not a bare SJON missing-key error — the scene
discipline. Rules validated in Phase 1:
- **Source XOR** — neither or both → `trigger_invalid` (span on the form).
- **`:every` > 0 ticks** — a non-positive interval → `trigger_invalid` (span on the
  `:every` value). Overflow is `tick_overflow` via `posToTick`.
- **`:at` non-empty + strictly ascending in TICK order** — empty, descending, or a
  tie → `trigger_invalid` (span on the list). NOTE this DIFFERS from tracks, which
  *sort* their keys; triggers *reject* unsorted `:at` (so `[1bar 2b]`, descending once
  converted, is rejected). Overflow of any element is `tick_overflow`.
- **Unknown target reuses `unknown_target`** — no trigger-specific target code (per
  the design). `:offset` is unvalidated in Phase 1 (any tick; ignored without
  `:every`); it resolves in Phase 2.

**Validation-only.** A well-formed trigger emits nothing and builds *no* table row yet
(Phase 2) — it just passes the diag gate, so a `(transport …)` + valid triggers with no
tracks compiles clean (`ok()`, 0 diagnostics). Any trigger defect nulls the whole table
via the existing `build()` diag-count gate.

**Schema.** Added the `trigger` top-level form + a `time-pos-list` value-kind (a
`(vector-shape :element time-pos)` with **no** min-len, so an empty `:at` reaches pacer
rather than tripping a schema type error). Header comment now lists `trigger`.

**Carry-forward for Phase 2 (compile).** (1) **Scened triggers are DEFERRED to Phase
2**: the `scene` form's `:positional track-section` still allows only `track` heads, so
a `(trigger …)` inside a `(scene …)` is currently a schema error. Phase 2 widens that
positional AND walks scene-child triggers scene-relative (reusing the scene start offset
+ `tick_overflow` fold from `buildTrackForm`), so the schema widening and the compile
walk land together. `validateTriggers` walks the top-level forest only for now. (2) The
Phase 2 table row reuses `Track` with a new `source` variant (periodic params or an
arena-owned sorted tick slice) + `Track.scene` for the owning window.

**Gate.** `zig build test` exit 0 (5 new trigger tests green); `zig build
audit-diagnostics` **27/27** (`trigger_invalid` referenced by name); `zig build verify`
green — native corpus **14/14 byte-identical** (the schema addition shifted no golden;
user coords are manifest-independent) + wasm parity **46/46**. No wire surface beyond the
appended `Compile.Code` variant; `'PACT'`/`'PACD'`/`'PACM'`/`'PACW'` bytes unmoved.
