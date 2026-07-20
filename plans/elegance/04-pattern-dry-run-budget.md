# 04 — Dry-runs run under the frame budget (load acceptance ⊆ runtime capability)

**Repo:** pacer
**Wire impact:** none (diagnostic codes reused; acceptance gets STRICTER — a
behavior change, recorded in the log, not a wire change)
**Gates:** `zig build verify` + corpus regen review, npm gate
**Size:** medium — small code delta, but it changes what loads.

## Why

The pattern dry-run queries with the real gpa under SJON's 64 MiB budget; the frame
path runs the SAME query in a 1 MiB `FixedBufferAllocator`
(`PatternTrack.zig:60-68`). So "compiles clean" does not imply "plays": a
dense-but-loadable pattern deterministically omits every write at runtime. The
`SCRATCH_BYTES` comment owns this openly ("Raise this (or bound the dry-run to
match) if silent runtime omission… becomes a problem") — this plan takes the
comment's second option. The expr dry-run has the identical asymmetry
(`Compile.dryRunExpr` on gpa vs `ExprTrack.SCRATCH_BYTES` = 256 KiB on the frame
path); fix both under one doctrine: **a dry-run evaluates under exactly the
resources the frame path will have.** One code path was always the point — the
allocator was the last difference.

## Design

- `Builder` gains a lazily-allocated scratch buffer, sized like `Evaluator.init`
  sizes its (max of `ExprTrack.SCRATCH_BYTES` / `PatternTrack.SCRATCH_BYTES` over
  sources actually present), allocated on first dry-run. **Gpa-allocated and freed
  at the end of `build()`** — NOT compile-arena-backed: the compile arena lives
  exactly as long as the result (`Compile.zig:237`), so an arena-backed scratch
  would pin ~1 MiB to every loaded pattern score for its whole lifetime; the
  dry-run scratch is build-scoped by nature. `dryRunExpr` / `dryRunPattern` front
  their calls with a fresh `FixedBufferAllocator` over it — mirroring
  `Eval.evalExprTrack` / `evalPatternTrack` exactly.
- With an FBA fronting the call, `error.OutOfMemory` can only mean the budget (the
  query allocates solely from the handed-in allocator), so the dry-runs stop mapping
  it to compile-aborting `Error.OutOfMemory` and instead emit a diagnostic at the
  track's span: reuse `pattern_eval_failed` / `expr_eval_failed` with a message
  naming the frame scratch budget ("pattern exceeds the {d}-KiB frame evaluation
  budget" — no new `Code`; the audit stays at its current count).
- **Honest residual, restated in both module headers:** the dry-run still only sees
  cycle 0 / t = 0 (a pattern dense only on a later cycle, an expr failing at a later
  tick, remain runtime omissions — inherent to sampling time). What this plan
  removes is the *chosen* inconsistency: two resource models for the same
  computation at the same tick.
- Determinism note for the log: FBA exhaustion is deterministic (same allocation
  sequence on every host), so acceptance stays a pure function of the document.

## Phases

### Phase 1 — pattern budget (RED first)
Load: `src/Compile.zig` (`dryRunPattern`, Builder fields), `src/PatternTrack.zig`
(SCRATCH_BYTES comment), `src/Eval.zig` (`evalPatternTrack` — the shape to mirror).
Reds: a pattern whose cycle-0 query exceeds 1 MiB — e.g. `(fast 8000 (pure 1))`
(~8000 haps × ~200 B + SJON's 256 KiB internal scratch clears the budget; verify
empirically, adjust N) — currently loads clean; the red asserts it produces
`pattern_eval_failed` with the budget message and a span on the `:pattern` node.
A comfortably-dense-but-fitting pattern must still load (guard against
over-tightening).
Green: FBA-fronted `dryRunPattern` per the design; update the `SCRATCH_BYTES`
comment (the "MORE permissive than this buffer" paragraph flips to "the dry-run runs
under this same budget — load acceptance ⊆ cycle-0 runtime capability").
Gate: `zig build test`, `zig build audit-diagnostics` (count unchanged).

### Phase 2 — expr budget + corpus pin
Load: `src/Compile.zig` (`dryRunExpr`), `src/ExprTrack.zig` (SCRATCH_BYTES doc),
one corpus case as template.
Reds: an expr exceeding 256 KiB at t = 0 — IF constructible: SJON `Expr`'s own
step/memory ceilings may trip first and already surface as `expr_eval_failed`. Probe
once; if no such expr exists below Expr's own ceilings, record that in the log (the
FBA is then a doctrine tie with no reachable new rejection) and keep the change for
symmetry — the invariant is "same resources", not "new rejections".
Green: FBA-fronted `dryRunExpr`; new corpus case `pattern-budget` pinning the
over-budget pattern's `(load :ok false)` + diagnostic ordinal, so the acceptance
change is held by the golden and the JS parity walk both.
Gate: `zig build verify` (regen corpus, review diff — ONLY the new case may
appear), npm gate.

## Progress log

(empty)
