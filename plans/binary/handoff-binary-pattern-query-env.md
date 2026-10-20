# Handoff — the binary pattern query needs the host's outer env (and its `(pure …)` leaves back)

> **Status (current) — 2026-10-20: OWNER FEATURE DELIVERED — the SJON side
> is implemented and independently review READY (native-qualified gates);
> pacer consumer adoption is NOT DONE. This is a handoff, not
> integration.** The SJON owner authorized both ask29 plans on
> 2026-10-19; the env-carrying binary query is delivered — consumers MUST
> select `queryBinaryWithEnv` / `queryBinaryWithBudgetAndEnv` (null-free
> env required; the entry selects eval semantics). The legacy
> `queryBinary` / `queryBinaryWithBudget` **remain frozen** as the
> qualified, semantically non-equivalent control — a `(pure <form>)` leaf
> is still silence there — and must not be adopted for pattern scores.
> The tree-trailing `BinaryCursor` gap is closed at SJON `8b8a38ee`: a
> payload walker MUST drain the `RootIter` through `null` — exact-end
> exhaustion now consumes the tree-trailing comment block — before
> treating leftovers as invalid. SJON commit chain: delivery source
> feature `f207113e`, final adversarial tests `661d2f15`, fuzz leg
> `7f364501`, cursor drain `8b8a38ee`, review-closure docs `bad5cddf`;
> current records:
> [`29-validation/pattern-plan.md`](../../../SJON/docs/plans/asks/29-validation/pattern-plan.md)
> and the timing artifact
> [`29-validation/perf/performance.md`](../../../SJON/docs/plans/asks/29-validation/perf/performance.md)
> (review disposition and parent verification record:
> [`29-validation/README.md`](../../../SJON/docs/plans/asks/29-validation/README.md)).
> SJON-side qualification: build test 4124/4127 (3 skipped), fuzz
> 102/102, audit-fmt / audit-docs / audit-wasm-imports OK, `wasm-binary`
> green without libwasmtime; full merge acceptance
> (`zig build verify`, `audit-diagnostics`, `audit-format-versions`,
> wasmtime-side audits) is deferred on SJON's host — not claimed. **No
> pacer-side claim is made or implied**: `pacer pack` still refuses
> `:pattern` scores, the plan-03 P4 binary replay of the `pattern-env`
> corpus case has NOT run, and no pack-pattern support, parity result, or
> runtime integration exists. The binary wave's missing-scene-name owner
> decision is unrelated to this handoff and still open. The original
> filing below is historical and stands verbatim.

**Status: filed as SJON
[`docs/plans/asks/29-binary-pattern-query-env.md`](../../../SJON/docs/plans/asks/29-binary-pattern-query-env.md)
on 2026-10-19 — awaiting the SJON verdict.** This is the pacer-local
prerequisite handoff for the [binary wave](README.md); pacer does not
number, verdict or implement it. Evidence was re-verified 2026-10-19
against pacer `aaf88b2` and SJON `ab1a2cc5`: the tree env path and the
`cycle`/`tick`/`seed` shadow are green (`queryTreeWithEnv`); the binary
entries still take no `outer_env` and a `(pure <form>)` leaf still compiles
to `silence` (three haps become two; three become zero with `dropped`
1 → 0; a static diagnostic disappears; a haps-budget trip becomes a
success). The tree-trailing `BinaryCursor` gap is filed as a
self-contained companion section in the same ask. Native probe logs:
`SJON/.agent/control/probe-pattern-env.log` and
`SJON/.agent/control/probe-tree-trailing.log`.

**Priority (pacer's view): High — blocking.** Full binary pattern parity
(expr leaves reading the host env, `(pure …)` included) is REQUIRED for the
binary wave's completion: the pattern-free stages are an explicit prototype,
not a full-feature state. If the answer is "no", the pattern class of
scores is blocked on the binary path and pacer escalates to its user with
the measured cost — a refusal never silently becomes a permanent subset.

## The claim in one sentence

`PatternQuery.queryBinary` cannot serve the host `queryTreeWithEnv` was
built for: it takes no outer `Expr.Env`, and its compile path degrades every
`(pure <form>)` leaf to silence — so a pattern whose hap values read the
host's clock or controls plays *different haps* from text and binary, and
the divergence is silent.

## What it looks like from outside

pacer's `:pattern` track evaluation is `PatternTrack.queryCycle` →
`queryTreeWithEnv(gpa, tree, node, schema, window, seed, outer_env)` where
`outer_env` binds the transport clock and live control values
(`pacer/src/PatternTrack.zig:102-111`); hap `(pure …)` exprs read it under
the pattern-local shadows (`cycle`/`tick`/`seed` win — the rule
`queryTreeWithEnv`'s doc freezes, `SJON/src/PatternQuery.zig:1864-1871`).
The corpus case `corpus/pattern-env` pins all three flavors: a time name
tracked across the bar wrap (`(pure (* beat 2))`), the `tick` shadow
(`(pure (+ tick 0))`), and a control read through the parent scope
(`(pure (* sway 2))` over `(control :id sway :value 0.25)`). pacer's
playback runtime ships patterns as binary IR and can only call the binary
query — which today (1) has no env parameter (`queryBinary` /
`queryBinaryWithBudget`, `SJON/src/PatternQuery.zig:1928-1966`) and (2)
emits no `pure_expr` node at all: "the binary path deliberately degrades a
`(pure <form>)` leaf to `silence` … the one intentional tree/binary
divergence; it is locked by a dedicated test" (`:946-955`; reconfirmed in
`queryBinaryWithBudget` at `:1954-1958` — `tree = null`, `dropped` stays
0). SJON's own read-only artifact inherits both gaps
(`sjon_query_pattern_binary`, `SJON/src/wasm_binary.zig:71-96`).

## The same thing, in SJON's own terms, with nothing of pacer in it

```sjon
;; repro: one pattern, one env name
(stack (pure (* base 2)) [0.1 0.2])
```

Tree path: `queryTreeWithEnv` with `base = 3` → hap values `{6, 0.1, 0.2}`.
Binary path: `toBinary` the pattern, `queryBinary` → the `(pure …)` leaf is
silence, so the stack's first layer vanishes and `{0.1, 0.2}` shift up — a
different hap list, no diagnostic, and no way to supply `base` at all.
(The reproduction harness is the existing `roundTrip`/property-test shape
in `PatternQuery.zig`, which today *excludes* expression patterns.)

## Why this looks cheap from outside (SJON decides whether it is)

Both halves already exist separately. The env mechanism is
`queryTreeWithEnv`'s: chain the host env as the parent of every leaf's
pattern-locals, in the compile dry-run and the per-hap eval alike. The
tree-free expr evaluator is `Expr.evalBinary`'s `FrameBinary` machinery over
`BinaryCursor` (`SJON/src/Expr.zig:1847-1899`) — the same node codec
`compileBinary` already walks. The work reads as: carry an `outer_env`
through the binary compile/query path exactly where the tree path carries
it, and on a `(pure <form>)` leaf decode the form and evaluate it via the
binary expr walk with the pattern-locals shadowing the outer env — producing
`Node.pure_expr` (or its runtime equivalent) instead of silence, with the
compile-time dry-run at cycle 0 preserved so acceptance and per-hap
semantics cannot drift. The "one intentional divergence" note and the
property-test exclusion are the two places that would then say so.

## What must not change, and why pacer thinks it does not

- The tree path is untouched — every existing `queryTree*` signature and
  behavior, including the shadow rule.
- Literal-atom `tree ≡ binary` stays a property test; the change extends
  the equivalence to expression patterns rather than weakening it.
- Budgets and the `PATTERN_EXPR_SCRATCH` discipline are identical on both
  paths (`SJON/src/PatternQuery.zig:88`).
- Binary IR format: unchanged — `(pure <form>)` is ordinary form/vector
  vocabulary the wire already carries; only the reader's interpretation
  moves.
- No new error variants outside the existing `BinaryError` composition;
  `result.dropped` gains the same meaning the tree path gives it.

## If the answer is no

pacer does not build a second pattern interpreter. `pacer pack` keeps
refusing `:pattern` scores (an explicit, spanned diagnostic — the refusal
already exists as the wave's interim state), and per the wave's decision
log the pattern class is **blocked** on the binary path: pacer escalates to
its user with the measured cost of the gap, and "patterns stay
text-path-only permanently" is the user's decision to record — never the
owner's refusal alone.

## Acceptance pacer asks the verdict to name

An env-carrying `queryBinary` (e.g. `queryBinaryWithEnv`, mirroring
`queryTreeWithEnv`'s signature) over the `toBinary` of any pattern the tree
path accepts returns identical haps, diagnostics, and `dropped` — including
`(pure …)` leaves with a host env, shadows intact — with the property
test's expression-pattern exclusion deleted. pacer's acceptance fixture is
its `pattern-env` corpus document (beat-tracking across the wrap, the
`tick` shadow, a control through the parent scope), replayed through the
binary path by the wave's parity runner (plan 03 P4); the SJON-side repro
above is the same three cases without pacer.
