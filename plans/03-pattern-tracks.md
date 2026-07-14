# 03 — Pattern tracks (`:pattern` via SJON PatternQuery)

**Repos:** pacer (+ possibly small SJON additions)
**Wire impact:** appends `Compile.Code` variants
**Gates:** `zig build verify`, `zig build audit-diagnostics`, npm gate

## Why

SJON already ships a deterministic Strudel-style pattern engine (`SJON/src/Pattern.zig`
tick core — the same `PPC = 720720` grid pacer uses — and `SJON/src/PatternQuery.zig`,
`query(window) → [Hap]` with seeded SplitMix64). Its own docs say it exists to be
consumed by "the animation driver". pacer doesn't consume it yet. This is the designed
path for authoring rhythmic structure (euclids, alternation, seeded choice) in the
score instead of WGSL.

## Design (freeze in Phase 1 — this plan has real open questions)

```
(track :target dotBurst :pattern (euclid 5 8 (pure (rand-range 0.2 1))))
```

- `:pattern` is a third track source, mutually exclusive with keys and `:expr`
  (extend the existing `track_source_conflict`).
- **Cycle mapping (decide in Phase 1, recommend):** 1 pattern cycle = 1 bar (from
  `:meter`), so patterns breathe with the transport. Exact integer math: bar length in
  ticks is already exact on the PPC grid.
- **Point-sample rule:** at eval tick T, query the enclosing cycle window once, take
  the hap active at T with the latest onset; no active hap → write omitted (same
  contract as expr NaN rejection). Hap value: evaluate its `(pure …)` Expr with
  hap-local bindings (cycle/tick/seed) + pacer env (t, beat, controls…) — check what
  PatternQuery already binds before duplicating.
- Determinism: seeded SplitMix64 + tick grid means goldens pin cross-host behavior —
  this feature's corpus case is itself a valuable determinism test of SJON's engine
  under wasm32.
- Memory: query through a per-track `FixedBufferAllocator` scratch like expr tracks
  (`ExprTrack.SCRATCH_BYTES`); measure whether 256 KiB suffices for realistic patterns.
- New diagnostics (append): `pattern_eval_failed`, `pattern_result_invalid`.

## Phases

### Phase 0 — feasibility spike (RED = a failing build/test, not prose)
Load: `build.zig.zon`, `build.zig`, `SJON/src/PatternQuery.zig` (public API + tests),
`SJON/src/Pattern.zig` (top comment only).
Reds: a pacer Zig test that imports `sjon.PatternQuery`, queries a trivial pattern over
one cycle, and asserts a hap — first failure will reveal whether the surface is
re-exported to path consumers and compiles under wasm32-freestanding with
`plugin-exec = false`.
Green: whatever minimal SJON re-export/pacer import wiring makes it pass on native AND
`zig build wasm`.
Decisions to record in this file: cycle↔bar mapping; hap-selection rule; env merge.
Gate: `zig build test` + `zig build wasm`.

### Phase 1 — schema + validation (RED first)
Load: `schema/pacer.sjon`, `src/Compile.zig` (Code enum, `:expr` handling as pattern).
Reds: track with both keys and `:pattern` → `track_source_conflict`; `:expr` +
`:pattern` → same; bare `:pattern` on a track validates clean (walk-opaque like
`:expr`); appended codes exist and are tested by name.
Green: schema field + appended `pattern_eval_failed` / `pattern_result_invalid`.
Gate: `zig build test`, `zig build audit-diagnostics`.

### Phase 2 — compile dry-run (RED first)
Load: `src/Compile.zig` (expr dry-run path), `src/ExprTrack.zig` (as the shape to
mirror — consider an `PatternTrack.zig` sibling so compile and eval share one
definition, the ExprTrack discipline).
Reds: a malformed pattern (bad combinator arity) → `pattern_eval_failed` diagnostic at
load, span on the pattern node; a pattern yielding a non-finite / wrong-arity value at
t=0 → `pattern_result_invalid`; a good pattern loads clean.
Green: dry-run query at tick 0 through the shared module.
Gate: `zig build test`.

### Phase 3 — frame eval (RED first)
Load: `src/Eval.zig`, the new `PatternTrack.zig`.
Reds: point-samples across one cycle hit each hap's value at its onset (structural —
exact tick landing); gaps between haps omit the write; cycle 2 with a seeded `rand01`
differs from cycle 1 but is bit-identical across two evaluator instances; runtime
failure increments `expr_failures` (or a sibling counter — decide and record) and omits
the write; scratch allocator never touches gpa (test with a failing-allocator gpa).
Green: eval arm querying the enclosing cycle, hap selection per the frozen rule.
Gate: `zig build test`.

### Phase 4 — corpus + parity
Load: `corpus/expr-control/` as template.
Work: `pattern-basic` case — euclid + alternation + seeded rand, times hitting onsets,
gaps, and a wrap; `zig build corpus -- --update`, review; wasm parity via
`zig build verify` is the real prize (pins SJON's pattern engine cross-target).
Gate: `zig build verify` + npm gate.

## Progress log
