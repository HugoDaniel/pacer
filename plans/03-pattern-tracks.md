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

- **Phase 0 — feasibility spike (done, 2026-07-14). VERDICT: FEASIBLE, no
  SJON change needed.** The `Pattern`/`PatternQuery` surface is already
  re-exported to path consumers (`sjon.Pattern`, `sjon.PatternQuery` in SJON's
  `root.zig`), so no re-export wiring was required. Kept artifact: one native
  Zig test in pacer's `src/root.zig` (sibling to the existing sjon-wiring test)
  that parses `[bd hh sn cp]`, calls `PatternQuery.queryTree(gpa, &tree,
  tree.root[0], Schema.init(&.{}), Span.init(0, PPC), 0)`, and asserts the
  fastcat's four haps land on exact quarter-bar tick boundaries (`i·PPC/4`)
  carrying symbols `bd/hh/sn/cp`, zero diagnostics. Green native first run
  (`zig build test`).
  - **wasm32-freestanding proof.** `zig build test` only compiles native and Zig
    is lazy, so a green test does *not* prove the engine links freestanding. To
    force it, a TEMPORARY probe `_ = &sjon.PatternQuery.queryTree;` was added to
    `wasm_entry.zig`'s comptime block and `zig build wasm` run: it built clean,
    proving `queryTree`'s whole transitive closure (compileTree + the query
    walker + all combinators + the per-hap `Expr` leaf eval + `Pattern` tick
    math + `Schema`) **semantically compiles for wasm32-freestanding under
    `plugin-exec = false`** — nothing in the pattern surface reaches for
    libwasmtime / the filesystem / a native-only builtin. The probe was then
    removed (`wasm_entry.zig` is byte-identical to HEAD); Phase 3 re-adds a real
    call site.
  - **Code-size finding.** Baseline `pacer.wasm` 455941 B → with the probe
    455943 B (**+2 B**). Nearly the entire engine was *already* linked, because
    pacer already consumes SJON's `Expr`/`Schema`/`Ast`/`Pattern` — exactly the
    closure PatternQuery imports. So `:pattern` adds only the engine's own code
    (compile/query walkers, combinators, hap machinery) on top of dependencies
    already present; the shipped delta (measured for real once Phase 3 *calls*
    queryTree) is bounded and modest, not a new subsystem.
  - **Design bearing (record now; freeze in Phase 1).**
    - *Cycle↔bar mapping — SETTLED as identity.* `Pattern.PPC` (720720) IS
      pacer's per-bar tick count, so "1 pattern cycle = 1 bar" is not a
      conversion — it is identity on the shared grid. The spike's window
      `Span.init(0, PPC)` == one bar == one cycle, and the four haps fell on
      exact `PPC/4` boundaries with pure integer math (no f64). Recommend
      freezing 1 cycle = 1 bar in Phase 1; it is the zero-cost choice.
    - *Env merge — OPEN, and the spike sharpened it.* PatternQuery evaluates a
      `(pure <form>)` leaf as an `Expr` with `cycle` (f64), `tick` (i64), `seed`
      (i64) bound; pacer's expr env (`ExprTrack.bindTime`) binds
      `t/tick/beat/bar/cycle/phase/bpm/dur` + controls. `cycle` and `tick`
      **collide by name** between the two envs — Phase 1 must decide the merge
      (recommend: pattern-local `cycle`/`tick`/`seed` shadow pacer's inside a
      hap value, since a hap's cycle is the pattern's, not the transport's; the
      names still agree numerically when 1 cycle = 1 bar). The spike used a
      pure-*literal* pattern, so it did not exercise this path — it only
      surfaced the collision.
    - *Hap-selection rule — UNTOUCHED (still the plan's recommendation).* The
      spike queried the whole cycle and read all haps; it did not implement the
      eval-time point-sample. The plan's rule (at tick T, take the hap active at
      T with the latest onset; no active hap → omit the write, mirroring expr
      NaN rejection) stands as the Phase 1 freeze target.
  Gate: `zig build test` ✓ + `zig build wasm` ✓. No JS/TS touched. **STOP** —
  per Wave 0 this is the spike only; Phases 1–4 are scheduled in Wave 3,
  informed by this verdict.

- **Phase 1 — schema + validation (done, 2026-07-16).** TDD reds first
  (missing enum members → compile error; `:pattern` unknown schema key →
  validation failure; conflict diag absent), then green in compiler-driven
  steps. Landed:
  - **Schema**: `(key :name pattern :type any :optional true :walk-opaque
    true)` on the track form — same walk-opaque discipline as `:expr`
    (interior is SJON Pattern vocabulary, checked by the Phase 2 dry-run,
    never by the schema). Track form + `:expr` descriptions updated to name
    the three-way exclusivity.
  - **Codes appended** (wire-stable, ride in `'PACD'`): `pattern_eval_failed`
    = 27, `pattern_result_invalid` = 28 — values pinned by a dedicated test
    ("wire-stable appendices") ahead of their Phase 2 emission paths, so
    `audit-diagnostics` passes honestly (29/29) and the appendix can never
    silently renumber.
  - **`TrackTable.Source.pattern`** (node index, like `.expr`). The exhaustive
    switches drove the rest: `Abi.encodeMeta` emits append-only source byte
    **3** (npm glue's `TRACK_SOURCES` + `MetaTrack` typedef mirror it in
    lockstep); `Eval` has a placeholder omit arm (no writes until Phase 3 —
    the same shape as its eventual no-active-hap contract).
  - **`buildTrackForm`**: three-way source dispatch — `:expr`+`:pattern`,
    keys+`:expr`, keys+`:pattern` each emit one `track_source_conflict` at
    the later source's span; bare `:pattern` records the track (dry-run slot
    marked for Phase 2); `track_empty` message now names all three sources.
  - **DESIGN FROZEN** (the plan's three open questions):
    1. *Cycle↔bar = identity.* 1 pattern cycle = 1 bar; `Pattern.PPC` IS
       pacer's per-bar tick count — no conversion exists.
    2. *Env merge = pattern-local shadows.* Inside a hap's value expr,
       PatternQuery's `cycle`/`tick`/`seed` bindings SHADOW pacer's time env
       names; pacer's env supplies everything else (t, beat, bar, phase,
       bpm, dur + controls). With identity mapping the shadowed names agree
       numerically anyway; the seed is the binding only the pattern can give.
    3. *Hap selection = latest-onset active hap at T.* Query the enclosing
       cycle once; take the hap active at T with the greatest onset; no
       active hap → the write is OMITTED (the expr-NaN contract).
  Gate: `zig build test` ✓ (126) · `zig build audit-diagnostics` ✓ 29/29 ·
  `zig build verify` ✓ (corpus + wasm parity, 48 node tests — no golden
  changed; the new source byte only appears for pattern tracks) · npm lint +
  typecheck ✓. Next: **Phase 2 — compile dry-run** (`PatternTrack.zig`
  sibling to ExprTrack; malformed pattern → `pattern_eval_failed`, bad t=0
  value → `pattern_result_invalid`).

- **Phase 2 — compile dry-run (done, 2026-07-16).** TDD reds first (four
  new Compile tests, all failing on the missing dry-run), then green via
  the shared module + one Builder method. Landed:
  - **`src/PatternTrack.zig`** — the ExprTrack discipline: one definition
    of "query a `:pattern` node on the tick grid" shared by `Compile`
    (dry-run) and `Eval` (Phase 3 frame path). `SEED = 0` pinned (a future
    `:seed` threads through here); `cycleWindowOf(tick)` — the frozen
    identity as exact integer math, transport-independent because
    `TimeMap` pins one bar = `PPC` ticks for EVERY meter (the meter
    divides beats within the bar); `queryCycle` (window + `queryTree`);
    `coerce(PatValue) → ?[4]f32` — finite number into lane 0, lanes 1–3
    zero, everything else null.
  - **`Compile.dryRunPattern`** (mirrors `dryRunExpr`): a top-level track
    dry-runs cycle 0, a scened track the cycle containing its scene start
    — locked by a test where `(slowcat 0.5 bd)` passes top-level (cycle 0
    = 0.5) but fails inside a scene at bar 1 (cycle 1 = symbol `bd`).
    Engine errors (deterministic depth/hap/byte ceilings, tick overflow)
    → `pattern_eval_failed` at the pattern node; engine DIAGNOSTICS
    (malformed combinators, broken expr leaves — collection over abort,
    the node degrades to silence) are forwarded each with their OWN span
    (same combined tree — a `(fast 2)` arity defect lands on `fast` in
    user coordinates, asserted by test); `dropped > 0` → belt-and-braces
    `pattern_eval_failed`. **Strictness decision:** the sweep checks EVERY
    hap in the dry-run cycle against the result contract (stricter than
    expr's single point; zero drift risk — any accepted hap coerces
    identically at frame time), so `[0.5 bd]` fails at load even though
    tick 0's hap is sound. Later-cycle content stays beyond the dry-run
    (the expr-at-t=0 limitation).
  - **ncomp ≠ 1 statically rejected** (`pattern_result_invalid`):
    `PatValue` has no vector variant, so a pattern can never drive a
    multi-component target this slice — the impossible pairing fails at
    load regardless of pattern content.
  - **DISCOVERY — `euclid` is not in the engine vocabulary.** SJON's
    combinator set this slice is `silence` / `pure` / `fast` / `slow` /
    `stack` / `slowcat` / `cat` + vectors (fastcat) + bare atoms (pure).
    Phase 1's `(euclid …)` fixtures only compiled because nothing dry-ran
    them; they moved to real vocabulary. The plan's headline example
    depends on euclid ⇒ **SJON-side follow-up** (its own conformance
    fixtures live there; pacer inherits it for free once it lands).
  - **DISCOVERY — env threading needs a small SJON addition (Phase 3
    pre-req).** `queryTree` takes no outer env: hap value exprs bind ONLY
    the pattern-locals `cycle`/`tick`/`seed` (exactly the frozen shadow
    set), so `(pure (* beat 2))` fails the engine's own static leaf check
    (UnknownBinding → diagnostic → `pattern_eval_failed` at load — honest,
    not silent). Frozen design #2 (pacer's env under the shadows) needs a
    `queryTree` variant accepting an outer `Expr.Env` for both the static
    check and the runtime leaf eval.
  - **Code size, the real number:** `pacer.wasm` 471235 → 489776 B
    (**+18.5 KiB, +3.9%**) — the dry-run CALLS the engine, superseding
    the P0 probe's +2 B (a reference isn't a call; ReleaseSmall kept the
    uncalled closure out).
  Gate: `zig build test` ✓ (133) · `zig build audit-diagnostics` ✓ 29/29
  (both pattern codes now covered by real emission tests) · `zig build
  verify` ✓ (no golden changed — no corpus case uses `:pattern` until
  Phase 4). No JS/TS touched. Next: **Phase 3 — frame eval** (point-sample
  in `Eval`'s `.pattern` arm via the shared module; pre-reqs: the SJON
  outer-env addition above; extend `Eval`'s `has_expr` scratch-allocation
  check to pattern tracks; freeze the hap-selection tie-break — latest
  onset is frozen, equal-onset ties need a pinned order).

- **Phase 3 — frame eval (done, 2026-07-17).** TDD reds first (5 `Eval`
  integration tests failing on the omit-everything `.pattern` arm + 4
  `PatternTrack.sampleAt` unit tests that would not compile), then green
  via the shared module + the eval arm. Landed:
  - **`PatternTrack.sampleAt(haps, t)`** — the point-sample: the hap whose
    PART span contains `t` (half-open `[begin, end)`, so an exact onset
    lands on the hap STARTING there — structural, like a keyframe on its
    key) with the LATEST onset (`whole.begin` when present, else
    `part.begin`). No active hap → null (a gap, write omitted). Because it
    reads the deterministic hap list `queryCycle` returned, selection is a
    pure function of `(haps, t)` — no float, no host-order hazard.
  - **`PatternTrack.SCRATCH_BYTES = 1 MiB`** — answers the plan's open
    memory question: **256 KiB does NOT suffice.** `queryTree` allocates
    SJON's own 256 KiB per-query expr scratch *from the allocator handed
    in*, plus the compiled-`Node`/hap arena and work stacks, all live at
    once, and a `FixedBufferAllocator` reclaims only LIFO — so the buffer
    holds the whole call's high-water mark. The `(fast 16 (pure …))` frame
    test measured a floor between 256 and 320 KiB; 1 MiB leaves room for ~a
    few thousand haps past the SJON scratch — comfortably beyond realistic
    patterns (dozens–hundreds of haps/cycle), allocated once per evaluator
    only when a pattern track is present. It is NOT sized for a max-hap
    cycle (`MAX_HAPS` 64k ≈ 8 MiB), and the load-time dry-run uses the real
    gpa (SJON's 64 MiB budget) so it is MORE permissive — a thousands-of-hap
    pattern can load yet exhaust this buffer at runtime. That stays a
    deterministic, counted omission (never a process OOM, never
    nondeterminism), so the byte-identical claim holds; a review-flagged
    ceiling to raise (or bound the dry-run to match) only if silent runtime
    omission of a load-accepted dense pattern ever bites.
  - **`Eval`'s `.pattern` arm** fronts `queryCycle` with a fresh
    `FixedBufferAllocator` over `self.scratch` (so the frame path never
    touches the gpa — `evalTicks` takes no allocator), point-samples, and
    coerces. The old `has_expr` bool became a `scratch_need = max(…)` sweep
    over expr (`ExprTrack.SCRATCH_BYTES`) and pattern (the larger) sources
    — a pattern track dominates the sizing.
  - **DECISION — hap-selection tie-break PINNED: equal onsets → the LAST
    hap in query order.** A `stack` concatenates its layers in child order,
    so the top-most declared layer wins; `sampleAt` keeps the last on a tie
    (`onset >= best_onset`). Locked by a `(stack 0.1 0.2)` unit test (→
    0.2). This completes the frozen hap-selection rule (latest onset was
    already frozen; this pins the remaining ambiguity).
  - **DECISION — the failure counter is `expr_failures`, SHARED, and
    counts OMITTED writes only.** A pattern bumps the same probe as an expr
    track when — and only when — its write is actually omitted: a query
    refusal, an uncoercible selected value, or an empty sample in a cycle
    the engine dropped a hap in. A frame that still produces a write never
    counts, even if another hap in the cycle dropped (locked by a
    `(stack 0.5 (pure …÷0))` test: the surviving 0.5 layer writes and the
    counter stays 0 — a review catch; the first cut counted `dropped > 0`
    unconditionally and inflated the probe on every writing frame). The
    signal is cycle-coarse (`result.dropped` is per-cycle), so a real
    silence gap in a cycle that also dropped elsewhere is counted — but no
    writing frame is ever miscounted. Rejected a separate
    `drv_patternFailures` export: the counter is a debugging probe the
    determinism claim never reads, and a new wire export (wasm_entry + npm
    glue + types + exports test) is not worth it for one slice.
  - **SCOPE CORRECTION — pacer's time env in hap exprs is a SEPARATE
    slice, NOT a Phase 3 blocker.** The Phase 2 log framed the SJON
    outer-`Expr.Env` `queryTree` variant as a Phase 3 pre-req, but
    re-reading Phase 3's actual spec, none of its reds need it: hap value
    exprs bind the pattern-locals `cycle`/`tick`/`seed` only, and that is
    already expressive (seeded `rand01`, oscillators on `cycle`). So
    `(pure (* beat 2))` still fails at load (honest — `beat` is unbound in
    the engine). Threading pacer's env under the frozen shadows — the SJON
    `queryTreeWithEnv` addition + the compile dry-run env + an
    `ExprTrack.buildEnv` reuse — is a cohesive cross-repo follow-up on its
    own, scheduled AFTER Wave 3's 03 closes (or folded into a later wave).
  - **Code size:** `pacer.wasm` 489776 → 490716 B (**+940 B**) — the query
    engine was already linked by the Phase 2 dry-run, so Phase 3 adds only
    `sampleAt` + the eval arm.
  Gate: `zig build test` ✓ (142) · `zig build audit-diagnostics` ✓ 29/29
  (no new codes) · `zig build verify` ✓ (corpus 15/15 unchanged — no
  `:pattern` corpus case until Phase 4 — + wasm parity 48 node tests). No
  JS/TS touched. Next: **Phase 4 — corpus + parity** (a `pattern-basic`
  case: fastcat + alternation + seeded rand + a silence gap + a cycle
  wrap; `zig build corpus -- --update`, review; wasm parity via `zig build
  verify` is the prize — it pins SJON's pattern engine cross-target).

- **Phase 4 — corpus + parity (done, 2026-07-17). Plan 03 COMPLETE; Wave 3
  CLOSED.** The `pattern-basic` golden lands `:pattern` in the determinism
  gate. Three tracks under `(transport :bpm 120 :meter [4 4])` — deliberately
  NO `:dur`/`:end loop`, so the clock advances freely and the pattern's own
  `tick mod PPC` math drives the bar wrap (a transport loop would pin every
  frame to cycle 0 and erase the alternation / rand-across-cycles signal, the
  whole point of the case):
  - `grid` `[0.1 0.2 (silence) 0.4]` — fastcat, four quarter-bar slots, the
    third silent;
  - `alt` `(slowcat 0.25 0.75)` — one child per cycle, alternating across the
    wrap;
  - `noise` `(pure (rand01 seed cycle))` — one seeded hap per cycle.
  Six eval times pin every behavior: structural landing on slot onsets
  (t = 0, 0.5, 2.0 s land the exact authored f32 — integer tick math, no
  float drift), a mid-slot HOLD (t = 0.75 s still 0.2), the SILENCE gap
  (t = 1.0 s — `grid`'s write is OMITTED while `alt`/`noise` still land, and
  it is NOT counted: `dropped` is 0), and two bar WRAPS (t = 2.0 → cycle 1,
  t = 4.0 → cycle 2) where `alt` flips 0.25 → 0.75 → 0.25 and `noise` is
  identical within a cycle (0.0 across all four cycle-0 frames) yet distinct
  per cycle (`3EF5681C` ≈ 0.479, `3EA5D5B0` ≈ 0.324). The generated golden was
  human-reviewed hex-by-hex against these hand predictions before committing —
  every one matched.
  - **TDD red (the honest one):** the FIRST `zig build corpus` panicked at
    `renderMeta`'s `:source` switch — `else => unreachable` on source byte 3.
    The golden renderer had never seen a pattern track. Fixed with `3 =>
    "pattern"`; two `Abi.zig` doc comments (`0 keys / 1 expr / 2 trigger`) now
    also list `3 pattern` — the encoder already emitted 3 (`.pattern => 3`) and
    JS `TRACK_SOURCES` already carried `'pattern'` at index 3, so only the
    native renderer + docs lagged.
  - **euclid dropped.** The plan text named `euclid` for this case, but it is
    NOT in SJON's pattern vocabulary yet (established in P0/P1). The case uses
    the available fastcat / slowcat / `rand01` forms instead; `euclid` stays a
    SJON-side follow-up.
  - **wasm parity is the prize, and it is GREEN.** `corpus parity:
    pattern-basic` re-derives the identical golden text from `pacer.wasm`
    output — so SJON's whole pattern closure (compile + query walker + every
    combinator + the per-hap `Expr` leaf + `rand01`'s deterministic kernel +
    `Pattern` tick math) is byte-identical native vs wasm32.
  - **Code size:** `pacer.wasm` UNCHANGED at 490710 B — P4 is a native-only
    corpus case + doc/runner edits; the eval path shipped in P3.
  Gate: `zig build test` ✓ (143) · `zig build audit-diagnostics` ✓ 29/29 (no
  new codes) · `zig build verify` ✓ (native corpus 16/16 + wasm parity 49 node
  tests). No JS/TS touched. **Plan 03 is done.** Carried follow-ups (both
  cross-repo, neither a Wave-4 blocker): `euclid` in SJON's vocabulary, and
  pacer's time env in hap exprs (the SJON `queryTreeWithEnv` outer-`Expr.Env`
  variant). Next per strategy: the end-of-wave studio refresh, then Wave 4.
