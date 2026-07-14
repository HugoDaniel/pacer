# 04 — Built-in transport lanes (`(transport :emit …)`)

**Repo:** pacer
**Wire impact:** none beyond schema (writes go to ordinary host-registered targets)
**Gates:** `zig build verify`, npm gate
**Size:** small — a good first plan to execute.

## Why

Every host writes the identity track today: the impulsos score ships
`(track :target beat :expr beat)` with the comment "master musical clock →
motion.beat". Make the clock a declared transport output instead of expr boilerplate.

## Design

```
(transport :bpm 125 :meter [4 4] :dur 400b :end loop :emit [beat bar phase])
```

- `:emit` is an optional list of the reserved time names, each resolved against the
  host registries **by that exact name** (the demo's uniform is literally
  `motion.beat`). Allowed: `beat`, `bar`, `phase`, `bpm`, `t`. Values are the same
  numbers the expr env binds (one definition — reuse `ExprTrack`'s env table, do not
  duplicate formulas).
- Emit writes land **first** in the write buffer (before tracks), so an explicit track
  on the same target overrides an emitted lane; controls still land last. Pin this
  ordering in the corpus golden.
- Unknown name in registries → existing `unknown_target` diagnostic (with span on the
  emit entry). Non-scalar registry arity for an emitted name → `target_arity_mismatch`.
- Duplicate names in the list → `transport_invalid`.

## Phases

### Phase 1 — schema + validation (RED first)
Load: `schema/pacer.sjon` (transport form), `src/Compile.zig` (transport handling +
Code enum), one diagnostic test as pattern.
Reds: `:emit [beat beat]` → `transport_invalid`; `:emit [nonsense-name]` →
`transport_invalid` (not a reserved time name); `:emit [beat]` against a registry
without `beat` → `unknown_target`; `beat` registered ncomp-2 →
`target_arity_mismatch`; clean case validates.
Green: schema `:emit` field (list of symbols); validation + target join at compile.
Gate: `zig build test`, `zig build audit-diagnostics` (no new codes expected — confirm
reuse keeps the audit green).

### Phase 2 — eval (RED first)
Load: `src/Eval.zig`, `src/ExprTrack.zig` (env value functions), `src/TrackTable.zig`.
Reds: eval at a known seconds value writes `beat`/`bar`/`phase` entries equal to the
env-binding values at that tick (compare against an equivalent `:expr` track,
bit-exact); write order emit → tracks → controls (a track targeting `beat` wins);
wrap/hold behavior matches the clock (`:end hold` clamps).
Green: emitted-lane rows in the table (internal source variant or a small dedicated
slice — pick the smaller diff) evaluated before the track loop.
Gate: `zig build test`.

### Phase 3 — corpus + migration note
Load: `corpus/controls-live/` as template (it already pins transport meta).
Work: `transport-emit` corpus case (emit + override + hold edge);
`zig build corpus -- --update` + review. Then update the studio's starter score
`~/Dev/pngine/studio/public/shaders/demoscene.score.sjon` in the pngine repo: replace
the identity-track idiom with `:emit [beat]` once the studio's pacer.wasm is rebuilt —
record this as a follow-up item in the progress log rather than doing it cross-repo in
the same phase.
Gate: `zig build verify` + npm gate.

## Progress log

- **Phase 1 — schema + validation (done, 2026-07-14).** Added the `emit-lanes`
  value-kind (`(vector-shape :element symbol)`, unconstrained so membership stays a
  pacer diagnostic) and the optional `:emit` key on the `(transport …)` form. Compile
  side: `TrackTable.EmitName { beat, bar, phase, bpm, t }` + `EmitLane { name,
  target_id, registry }`, an `emit: []const EmitLane = &.{}` slice on `Transport`, and
  `Builder.buildEmit` (called from `buildTransport`, which now takes the table arena).
  Each entry is checked for emittable membership (`std.meta.stringToEnum` is the single
  source of truth — `tick`/`cycle`/`dur` are reserved but *not* emittable, so they hit
  `transport_invalid`), duplicates (`transport_invalid`), target join (`unknown_target`),
  and scalar arity (`target_arity_mismatch`) — every diagnostic carries the offending
  entry's own span. No new `Code` variants (all four reused). Reds written first (three
  tests, confirmed failing because `:emit` was unknown to the schema), then green.
  Gate: `zig build test` ✓, `zig build audit-diagnostics` ✓ (23/23, unchanged),
  `zig build wasm` ✓ (shared `TrackTable` still compiles freestanding).
