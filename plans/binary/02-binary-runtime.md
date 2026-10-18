# binary 02 — `pacer-rt.wasm`: the playback-only runtime

**Repos:** pacer
**Wire impact:** new artifact + new append-only surfaces: `prt_*` exports,
`prt_abiVersion() = 1` (a new lineage), a load-refusal reason enum (u16,
append-only). No `drv_*`/`'PAC*'` byte moves. npm gains `./rt` (append-only
exports map; triple-pin unchanged until publish).
**Gates:** `zig build verify` every phase; P2 adds the new verbs
`zig build wasm-rt` + `zig build audit-rt-imports` (proposed spellings,
created by P2) and ends in a **preliminary, non-binding size trend**; P3
adds the npm gate.
**Created 2026-10-18; not started.**

## Why

Plan 01 gives the score a deployable body; this plan gives it a player. The
full artifact's frame path is already pure (`src/Eval.zig:317-434`) but its
evaluator is welded to the compiler: `Evaluator.init` takes
`*const Compile.CompileResult` (`src/Eval.zig:180`; the import at `:75`)
because expr/pattern leaves re-read the tree (`src/Eval.zig:132-133`). The
decoupling is layering — one engine, two leaf sources — never a second
engine.

## Design

### P1 — the Eval layering: one engine, a compiler-side facade

**`src/EvalCore.zig`** (new leaf; the ONE engine) carries everything
`Evaluator` is today — frame path, control slots, dynamic slots, `setBpm`,
`expr_failures`, `last_tick` — importing only `TrackTable`, `TimeMap`,
`Writes`, `Easing`, `ExprTrack`, `PatternTrack`, sjon. Never `Compile`.

```zig
/// Mutually exclusive BY CONSTRUCTION — a mixed context is unrepresentable.
pub const LeafSource = union(enum) {
    tree: *const sjon.Ast.Tree,                 // today's path, verbatim
    binary: struct {
        expr: []const ?[]const u8,               // parallel to table.tracks
        pattern: []const ?[]const u8,            // empty until P4
    },
};
pub const Context = struct {
    table: *const TrackTable,
    source: LeafSource,
    schema: sjon.Schema.Schema,                  // core [+pattern]; never user plugins
};
pub fn init(gpa: std.mem.Allocator, ctx: *const Context) InitError!Evaluator;
```

The leaf switch lives in `evalExprTrack`/`evalPatternTrack` exactly as the
engine's two arms: `ExprTrack` gains `evalAtBinary` (same `buildEnv`, then
`Expr.evalBinary` — `SJON/src/Expr.zig:1847-1854` — same `coerce`);
`PatternTrack` gains `queryCycleBinary` in P4 only.

**`src/Eval.zig`** stays the public path as a compiler-side
facade/adapter (outside the runtime closure — it imports `EvalCore` +
`Compile`): `Eval.Evaluator` remains the exported name with **every existing
pub decl spelled as today**, including `init(gpa, result: *const
Compile.CompileResult)` (deprecated in doc only), implemented as a thin
adapter that vends the tree-arm `Context` — `Compile.CompileResult` gains
`evalContext()` for it. The public surface is load-bearing: `root.zig:43`
exports `Eval`, the CLI consumes `pacer.Eval.Evaluator`
(`src/cli/Frames.zig:40, 153`), and `Driver` constructs it
(`src/Driver.zig:67-72`). A comptime assertion walks
`@typeInfo(EvalCore.Evaluator)`'s decls and fails the build if the facade
forgets one — the adapter cannot drift silently, and the zero-byte corpus
diff plus the CLI's own tests exercise the forwarded paths. The
nullable-branch pseudo-context and the column-0-hidden-import trick are both
rejected by design: the union makes invalid mixtures unrepresentable, and
the facade never appears in the runtime's import graph at all.

**P1's gate is a zero-byte corpus diff** (the plan-14 discipline,
`plans/14-cli.md:80-92`): same engine, same seams, same bytes.

### P2 — the artifact, the transactional load contract, the closure gate

**`src/rt_entry.zig`** — zone plumbing only (the `wasm_entry.zig`
discipline, restated): PACB in (cap = `Pacb.pacbWorstCase()`, comptime
assert à la `src/wasm_entry.zig:85-100`), `'PACT'` in (64 KiB, unchanged),
meta out = pointer/len into the decoded score's OWN copy, writes out sized
by `Writes.encodedLen(EvalCore.MAX_FRAME_ENTRIES)` (`src/wasm_entry.zig:76-80`).
Exports (`prt_*`, all new): `prt_abiVersion` (1), `prt_pacbPtr/Cap`,
`prt_targetsPtr/Cap`, `prt_metaPtr/Len`, `prt_writesPtr`, `prt_load`,
`prt_loadError`, `prt_eval`, `prt_evalTicks`, `prt_setControl`,
`prt_clearControl`, `prt_registerControl`, `prt_setBpm`,
`prt_exprFailures`. Same shapes/semantics as the `drv_*` twins — including
the `drv_evalTicks` 2^53 gate (`src/wasm_entry.zig:269-274`), the
`registerControl` range checks (`:252-259`), and event-boundary behavior
(first-event-before omission, scene-window `[start, start+dur)` gating,
`src/Eval.zig:374-389`) — which come free from the shared engine.

**The load contract — a deliberate, documented divergence.** Text-path
truth (`drv_load`, `src/wasm_entry.zig:27-40, 192-228`):

| Failure | Text path (`drv_load`) |
|---|---|
| Bad args (lengths, malformed `'PACT'`) | true no-op — prior table/meta/diags stay live (`:198-205`) |
| Score diagnostics | prior score ALREADY torn down (`unload()` at `:207` runs before compile at `:212`; the diagnostics arm unloads again at `:219-221`) — nothing is loaded, `eval` returns 0 |
| OOM | same — nothing loaded |

`prt_load` is **transactional**: decode + validate + registry identity +
leaf dry-runs into fresh allocation FIRST, swap only on full success — so
EVERY refusal (bad call excepted) keeps the prior score **and its full
runtime state** (held control values, dynamic slots, a bpm nudge,
`expr_failures`). Statuses mirror the text set: 0 ok / 1 refused (reason via
`prt_loadError`, append-only u16: `bad_magic`, `unsupported_version`,
`unsupported_feature`, `truncated`, `section_out_of_bounds`,
`record_invalid`, `cap_exceeded`, `non_finite`, `payload_invalid`,
`registry_mismatch`, `dry_run_failed`) / 2 bad call (argument ranges and a
malformed `'PACT'` — a true no-op, exactly like the text path) / 3 oom (the
old score stays live on the binary path, since nothing was torn down).
`registry_mismatch` is a status-1 refusal — one spelling everywhere (review
O-2, adopted). Load-time dry-runs preserve the acceptance ⊆ runtime rule:
expr at t=0 via `evalBinary`; pattern cycle 0 in P4
(`src/PatternTrack.zig:61-70`).

**Ownership invariant (review B3):** nothing live aliases
`prt_pacbPtr`/`prt_targetsPtr` after `prt_load` returns — `DecodedScore`
owns every payload, the `'PACM'` copy, the control ids, and the canonical
registry bytes in its arena (01's decoder enforces this natively; the repo
learned the zone lesson at `src/wasm_entry.zig:115-117` and
`src/Compile.zig:317-327`). Tests: load A → overwrite the PACB zone with a
refused blob → `eval(t)` still byte-identical to A's pre-refusal frames;
controls/BPM/counters survive the refusal; the copy's memory cost is a line
item in 04's report. The heap cost is bounded by the format caps
(`pacbWorstCase`), and `prt_metaPtr` may MOVE on any successful load (fresh
arena) — the JS side must re-take views every call, which is already the
glue's discipline (`npm/pacer/src/index.js:16`).

Build: `zig build wasm-rt` — the `wasm` recipe verbatim
(`build.zig:69-98`): wasm32-freestanding, ReleaseSmall, rdynamic, entry
disabled. **Closure gate:** `tools/audit_rt_imports.zig`, SJON's auditor
shape (`SJON/tools/audit_wasm_imports.zig` — column-0 BFS, ALLOWLIST with
stale-entry failure: a listed-but-unreached module fails too, so the list
must name exactly the closure each phase has). P2's allowlist — pacer:
`rt_entry`, `PactCodec`, `Pacb`, `EvalCore`, `ExprTrack`, `PatternTrack`,
`TrackTable`, `TimeMap`, `Easing`, `Writes`; SJON: `Ast`, `Expr`, `Pattern`,
`PatternQuery`, `BinaryCursor`, `BinaryFormat`, `Schema`, `Plugin`,
`plugins/core`, `trig` (`PatternQuery` is reached through `PatternTrack`
even while its binary twin is unimplemented — the tree arm of the shared
engine). Forbidden by absence: `Compile`, pacer's `Schema.zig`, `Driver`,
`Abi`, `Eval.zig` (the facade), `PacbEncode`, `wasm_entry`, `corpus_runner`,
`parity_runner`, `cli`, `test_support`, and SJON's `Parser`/`Printer`/
`Json`/`Edit`/write-side `Binary`/`Validator`/`Host`.

**Proof by mutation:** the auditor takes a root-dir parameter; a
checked-in fixture tree carries a forbidden chain and the tool must FAIL
naming it (run in the tool's own test step) — the gate is proved against a
known-bad closure, not asserted.

**Preliminary size trend (non-binding).** At P2's end, record raw/gzip9/
brotli11 of `pacer-rt.wasm` (the `meridian.size.json` per-file method) in
the progress log, labeled: *pattern support absent, pack refuses patterns,
capability set incomplete — trend only; the binding measurement is 04's
full-capability report and the user's checkpoint.* A catastrophically bad
trend (no meaningful reduction) stops the wave here; anything else proceeds
without a verdict.

### P3 — `pacer/rt` JS glue

`npm/pacer/src/rt.js`: `PacerRt` mirroring `Pacer`
(`npm/pacer/src/index.js:100-249`) — same constructor flow (registries →
canonical `'PACT'` via the shared encoder), `load(pacbBytes)` in place of
`reload(text)`, `eval`/`setControl`/`clearControl`/`registerControl`/
`setBpm`/`exprFailures`/`meta` with identical semantics; the `'PACM'`
decoder is shared with index.js (extract the decode half into a leaf both
import — no format change); `route.js`/`lane.js` reused untouched; no
`reload(text)` exists on the class (asserted by test). Views are re-taken
from `exports.memory.buffer` on every call — never cached across loads
(memory growth invalidates them; `index.js:16` states the discipline).
Exports map gains `"./rt"`; `types.js` gains `PacerRtExports` (the
`PacerExports` precedent). Tests (`test/rt.test.js`): load a packed fixture
(packed in `pretest` via `zig build cli` + `pacer pack`); eval against the
JS corpus renderer for one case; registry-mismatch refusal (status 1 +
`prt_loadError`); reload atomicity (refused `load` keeps the old score
evaluable and its control state); pointer re-fetch after a successful load.
Gate: npm `lint && typecheck && test` + `zig build verify`.

### P4 — pattern support (gated on the prerequisite)

Unblocks `PatternTrack.queryCycleBinary` → the env-carrying binary query
(the handoff's acceptance clause), removes `pack_patterns_unsupported`, and
adds the binary pattern dry-run at load (cycle 0 through the same query —
the O6 decision, mirroring `src/PatternTrack.zig:61-70`). RED = the
`pattern-env` corpus case through the binary path (03's runner) before any
runtime code; `required_features` bit0 exercised by fixture; the closure
allowlist gains `plugins/pattern` in the same phase (a named, reviewed
delta — the stale-entry rule means it cannot be listed before the runtime
actually reaches it). **If SJON's owner declines:**
P4 does not proceed and the pattern class is *blocked* — escalate to the
user with the measured cost of the gap (which scores cannot ship binary).
"Patterns remain text-path-only permanently" is the user's decision,
recorded in the decision log then; this plan never converts the owner's
refusal into a permanent silent subset.

## Phases

| Phase | Deliverable | Gate |
|---|---|---|
| P1 | `EvalCore` leaf + `Eval` facade adapter; zero behavior change | `zig build verify` (corpus byte-identical) + `cli-golden` diff empty + CLI tests green |
| P2 | `rt_entry.zig`, `zig build wasm-rt`, `audit-rt-imports` + mutation fixture, transactional-load + ownership tests, preliminary size trend | `zig build verify`; both new verbs green; trend logged with its uncertainty label |
| P3 | `pacer/rt` + tests | npm `lint && typecheck && test`; `zig build verify` |
| P4 | patterns end-to-end (or the recorded block + escalation) | `zig build verify`; `pattern-env` green via the binary path |

## Progress log

_(created 2026-10-18; entries appended per phase)_
