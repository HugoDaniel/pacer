# binary — the playback-runtime wave

**Start at [00-strategy.md](00-strategy.md)** — waves, status board, decision log,
"what's next" pointer. This file holds the scope, the naming, and the plan index.

Created 2026-10-18. **Execution started 2026-10-18** — plan 01 Phase 1
(T1.1, the `'PACT'` codec leaf) and Phase 2 COMPLETE (T2.1–T2.8:
container skeleton, transport, registry identity, record sections,
ease/control, payload walk, std-only `'PACM'` reader, and T2.8's
whole-blob `decode`/`DecodedScore` with the PACM coherence cross-check
and the clobber-proof ownership proof, landed 2026-10-19), with
the interim decoder review's correction (folded-tick envelope
`MAX_FOLDED_TICK = 2·MAX_TICK`, batched canonical hardening —
EASE-refs/features-bit/DECL-presence/KEYS-overlap/EMIT-scalar — and
the mismatched-directory defense for the early stage reads) landed
before it; Phase 3 PARTIAL (T3.1, the `src/PacbEncode.zig` encoder
core — canonical assembly, verbatim `'PACM'`-pass `'EASE'`/`'TMPO'`
slices, `cloneNode`+compact payloads, compiled-fixture round-trips —
landed 2026-10-19; T3.2, the pack refusals — the head-walk position
classifier, the full-outcome core-vs-eval-schema head compare, the
interim `:pattern` refusal, and the three measured caps on
`Compile.Code` 31–33 — landed 2026-10-19); the
tree-trailing-comments acceptance gap stays an explicitly deferred
owner decision (SJON cross-repo edit vs approved narrowing), pinned by
a KNOWN-GAP test. Plan 01 as a whole is NOT done: the rest of phases
3–4 (the `pacer pack` verb, codes/fuzz/docs) remain
open, as do plans
02–04. The wave was
independently reviewed twice the same day; this revision
applies the first review's blockers and important findings (B1–B4, I1–I11),
the final review's three findings (HIGH-1 the closure gate's module blind
spot, MEDIUM-2 the unstated PACM trust model, LOW-3 canonical section
presence), and its grammar-context fixups — dated observations about the
plan text, not gate claims about code that does not exist yet.

**Plan 02 execution started 2026-10-19 — P1 COMPLETE; P2 under way
(T2.1 landed).** T1.1 landed the binary expr leaf
(`ExprTrack.evalAtBinary`, bit-equal to the tree arm; commit `b717d3c`);
T1.2 extracted the one engine into `src/EvalCore.zig` over a
tree|binary `LeafSource` with `src/Eval.zig`
as the alias facade — the exact public call
`Eval.Evaluator.init(gpa, &result)` and every caller survive unmodified
(zero respells), zero behavior change: gates `zig build test` 486/486,
`zig build verify` 15/15 with an empty golden diff, `zig build fuzz`
5/5 361/361. T2.1 then rerouted the runtime closure through
`src/RtSjon.zig` — the closure's single SJON import behind the frozen
nine-row re-export table, `Pacb`'s frozen `MAX_TREE_DEPTH` copy pinned
in root's frozen-copy family, write-side test uses on indented imports
— pure indirection, zero corpus/CLI drift (test 487/487 with the new
equality gate). Next: **T2.2** — `rt_entry.zig`, the `wasm-rt`
artifact, the transactional load; then the closure gate (T2.3/T2.4)
and the preliminary size trend close P2 — see
[00-strategy.md](00-strategy.md)'s status board.

Production animations must not ship the Pacer source compiler. Today
`pacer.wasm` (661,334 B raw / 238,810 B gzip9 / 194,275 B Brotli in the
Meridian export, `animader/animader/.agent/releases/meridian.size.json`)
compiles score *text* in the browser on every load (`drv_load`,
`src/wasm_entry.zig:192-228`). This wave splits the artifact the way SJON
already splits its own (`sjon.wasm` vs the read-only `sjon-binary.wasm`,
`SJON/src/wasm_binary.zig:1-18`): an **offline packer** compiles a score into
a versioned binary (`'PACB'`), and a **playback-only `pacer-rt.wasm`** loads
it — one evaluation engine shared with the compiler, same write buffers, no
parser, no validator, no manifest loader, no metadata encoder (a std-only
metadata READER with a bounded routing cross-check is the one deliberate
addition, 01), and no fallback to the compiler anywhere in the artifact.

1. `'PACB'` — the compiled-score format, the `'PACT'` codec leaf, the
   decoder/validator, and the `pacer pack` producer → [01](01-pacb-format.md).
2. `pacer-rt.wasm` — the Eval layering, the runtime artifact, its
   transactional load contract, and `pacer/rt` JS → [02](02-binary-runtime.md).
3. Byte-level text-vs-binary parity, the anchor corpus cases, the negative
   suites, and fuzz → [03](03-playback-parity.md).
4. Measurement procedure, the user checkpoint, and the pacer-local
   acceptance smoke → [04](04-measurement-acceptance.md).

Cross-owner prerequisite: pattern tracks on the binary path need one SJON
change (`PatternQuery.queryBinary` takes no outer env and degrades every
`(pure …)` leaf to silence — `SJON/src/PatternQuery.zig:946-955, 1928-1966`).
The prerequisite lives as a **pacer-local handoff document**,
[handoff-binary-pattern-query-env.md](handoff-binary-pattern-query-env.md) —
drafted, unfiled; SJON's owner decides if/when it becomes an ask in SJON's
own tree. **Full binary pattern parity (host env + pure-expr leaves) is
required for wave completion** — the pattern-free stages are an explicit
prototype, not a full-feature or production-complete state, and an owner
refusal blocks the pattern class and escalates to the user rather than
permanently dropping it. Everything else is unblocked: plan 01 and plan 02
P1–P3 touch no patterns.

## Naming (proposed here; the plans freeze it)

| Name | What |
|---|---|
| `'PACB'` / `*.pacb` | compiled-score container, data at rest; `docs/binary-score.md` (created by 01) is its doc of record |
| `pacer pack` | new CLI verb emitting `.pacb` (builds on `zig build cli`) |
| `pacer-rt.wasm` | playback artifact; `zig build wasm-rt` (new verb) |
| `prt_*` | its export surface; `prt_abiVersion() = 1`, a separate lineage from `drv_abiVersion` |
| `pacer/rt` | new npm entry, `PacerRt` class; `route.js`/`lane.js` reused verbatim |
| `zig build parity` | new native text-vs-binary corpus walk (proposed verb) |
| `zig build audit-rt-imports` | the closure gate over the one SJON window (`RtSjon`): layer-1 source auditor + layer-2 shipped-artifact check (proposed verb) |

Every spelling marked "new"/"proposed" above is created by this wave; nothing
pretends these commands exist today.

## Execution discipline

Inherited whole from [`../README.md`](../README.md): TDD reds first · one
phase per context window with a progress-log entry + commit per phase · wire
surfaces (`'PACT'`/`'PACD'`/`'PACM'`/`'PACW'`, `Compile.Code`, `Easing.Op`,
`drv_*`) append-only — `'PACB'`/`prt_*` join that set at their birth,
versioned from day one · failures are diagnostics offline, small refusal
reasons at runtime · every score-language-visible behavior lands with a
golden corpus case.

Gates: pacer core `zig build verify` (+ `zig build audit-diagnostics` when
codes change) · `zig build fuzz` · npm `cd npm/pacer && npm run lint && npm
run typecheck && npm test`. New from this wave (all proposed, created by
their phases): `zig build parity`, `zig build wasm-rt`, `zig build
audit-rt-imports`. Native Zig runs ONLY via
`obs sh -c 'cd /home/agent/worktrees/animader-init/pacer && …'` — no Linux
Zig; the plugin-exec (libwasmtime) SJON CLI build is unavailable on this
host — the plugin-exec=false SJON CLI builds from the path dependency and
runs on obs (pacer's own `verify` score-docs leg uses it, `build.zig`).
Browser
acceptance uses the real-GPU OpenCode browser-tester with the parent starting
servers; no plan here claims a browser result.

## The plans

| # | Plan | Repo(s) | Depends on |
|---|---|---|---|
| 00 | [strategy](00-strategy.md) — waves, status, decisions, open issues | — | — |
| 01 | [pacb-format](01-pacb-format.md) — `'PACT'` codec leaf, `'PACB'` format + validation, `pacer pack` | pacer | — |
| 02 | [binary-runtime](02-binary-runtime.md) — Eval layering, `pacer-rt.wasm`, closure gate, `pacer/rt` | pacer | 01; SJON prerequisite for P4 only |
| 03 | [playback-parity](03-playback-parity.md) — parity runner, anchors, negatives, fuzz | pacer | 01, 02 |
| 04 | [measurement-acceptance](04-measurement-acceptance.md) — measurement procedure, user checkpoint, local smoke, consumer handoff | pacer | 02 (P2), 03 |
| — | [handoff-binary-pattern-query-env](handoff-binary-pattern-query-env.md) — the unfiled SJON prerequisite | pacer (SJON decides later) | — |
