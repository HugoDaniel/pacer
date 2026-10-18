# binary — the playback-runtime wave

**Start at [00-strategy.md](00-strategy.md)** — waves, status board, decision log,
"what's next" pointer. This file holds the scope, the naming, and the plan index.

Created 2026-10-18. **Execution has not started** — every item on the board is
open. The wave was independently reviewed the same day; this revision applies
that review's blockers and important findings (B1–B4, I1–I11) — a dated
observation about the plan text, not a gate claim about code that does not
exist yet.

Production animations must not ship the Pacer source compiler. Today
`pacer.wasm` (661,334 B raw / 238,810 B gzip9 / 194,275 B Brotli in the
Meridian export, `animader/animader/.agent/releases/meridian.size.json`)
compiles score *text* in the browser on every load (`drv_load`,
`src/wasm_entry.zig:192-228`). This wave splits the artifact the way SJON
already splits its own (`sjon.wasm` vs the read-only `sjon-binary.wasm`,
`SJON/src/wasm_binary.zig:1-18`): an **offline packer** compiles a score into
a versioned binary (`'PACB'`), and a **playback-only `pacer-rt.wasm`** loads
it — one evaluation engine shared with the compiler, same write buffers, no
parser, no validator, no manifest loader, no metadata encoder, and no
fallback to the compiler anywhere in the artifact.

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
| `zig build audit-rt-imports` | new import-closure allowlist gate (proposed verb) |

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
Zig; the full SJON CLI is unavailable on this host (libwasmtime). Browser
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
