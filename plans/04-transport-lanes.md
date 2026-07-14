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

- **Phase 2 — eval (done, 2026-07-14).** Emit lanes are now evaluated. The value seam
  is one new public seam, `ExprTrack.emitValue(transport, tick, name)`: it reads the
  requested name straight out of the env `bindTime` already builds (no formula
  re-derived), so a lane and an equivalent `:expr` track share the exact same f64 →
  `@floatCast` path and land bit-identically. `Eval.evalTicks` writes the emit lanes
  FIRST (a new loop before the track loop, at the already-wrapped tick), so a `(track …)`
  or `(control …)` on the same target — written later — overrides the lane for in-order
  consumers; the `entries` buffer in `init` grew by `transport.emit.len`. `end`
  wrap/hold falls out for free: the loop reads the same wrapped `t` the tracks do
  (`:end hold` freezes `beat` at the score length, `:end loop` wraps it). Reds first
  (three tests, confirmed failing: bit-exact-vs-`:expr` saw `len 4≠8`, ordering saw
  `2≠3`, wrap/hold crashed on the empty buffer), then green. Gate: `zig build test` ✓,
  `zig build wasm` ✓.

- **Phase 3 — corpus + migration note (done, 2026-07-14).** New golden case
  `corpus/transport-emit/` (modelled on `controls-live/`): `(transport :bpm 120
  :meter [4 4] :dur 1bar :end hold :emit [beat bar phase])` plus an overriding
  `(track :target beat …)`. The join names the reserved lanes literally (emit
  resolves by exact name): `beat` id 0 also carries the track, `bar`/`phase` are
  emit-only. Four evals pin the three properties the plan asked for: (a) **emit-first
  ordering** — ids 0,1,2 in `:emit` order, then the track's `beat` write (id 0 again)
  lands last and wins; (b) **per-name lane values** — at 0.5 s beat 1.0 / bar 0.25 /
  phase 0.25, distinct; (c) **`:end hold` clamp** — t=2.0 s (exactly dur) and t=3.0 s
  (past dur) render **byte-identical** write blocks. Emit lanes are pinned via the
  `(eval …)` write buffers only — they are NOT in the `'PACM'` meta blob (no wire
  change this plan), so the golden's `(meta …)` shows just the overriding track.
  `zig build corpus -- --update` regenerated all 9 cases; diff reviewed — only
  `transport-emit/` changed (the 8 pre-existing goldens were byte-identical, confirming
  emit eval is isolated). Gate: `zig build verify` ✓ (inline tests + native corpus 9/9 +
  wasm parity `node --test` 39/39), npm gate ✓ (`biome check` 9 files, `tsc --noEmit`,
  `npm test` 39/39 against a fresh `pretest` wasm rebuild).

  **Follow-up (deferred to the Wave 0 studio-refresh step, NOT cross-repo here):**
  switch the studio starter score `~/Dev/pngine/studio/public/shaders/demoscene.score.sjon`
  from the identity-track idiom `(track :target beat :expr beat)` to `:emit [beat]` on
  its `(transport …)`, once the studio's `pacer.wasm` is rebuilt to a build that carries
  emit-lane eval. Byte-for-byte the rendered `beat` write is unchanged (emit routes the
  same env value through the same f32 truncation as the identity expr track), so the A/B
  is a no-op by construction — the win is deleting the boilerplate track.

- **Follow-up RESOLVED (2026-07-14, Wave 0 studio refresh) — but re-targeted.** This
  note assumed the *demoscene* starter score carried the identity-track idiom. It does
  not: that idiom (`(track :target beat :expr beat)`) and its `motion.beat` uniform live
  in the *impulse benchmark* score (`~/Dev/2026_impulse/live.score.sjon`), not the
  demoscene, whose `motion` buffer is `{sceneMix, spin, chromaAmt, _pad}` with no `beat`
  target. Adding `:emit [beat]` to the demoscene was proven to break its load
  (`unknown_target`, code 0 — `beat` in no host registry). Resolution (user's choice):
  the demoscene shader gained a real `beat` field (reclaiming the struct's `_pad` slot;
  buffer stays 16 B) so the studio's flagship template demonstrates `:emit` end to end —
  the pacer emit lane joins by name to `motion.beat` at offset 12 (confirmed via
  wgslender reflection). Committed in **pngine** (`46f492b`: `demoscene.sjon` +
  `demoscene.score.sjon` + `score-uniforms.test.js`, which now pins the emitted lane
  against the transport clock and cross-checks it vs the `spin` expr). Render output is
  unchanged (the shader can read `motion.beat` but doesn't yet). The impulse-score
  identity-track → `:emit [beat]` swap (a genuine boilerplate deletion, since that score
  has the real `motion.beat` uniform) is folded into **Wave 1's impulsos benchmark #1**
  ritual.
