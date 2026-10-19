# binary 02 — `pacer-rt.wasm`: the playback-only runtime

**Repos:** pacer
**Wire impact:** new artifact + new append-only surfaces: `prt_*` exports,
`prt_abiVersion() = 1` (a new lineage), a load-refusal reason enum (u16,
append-only). No `drv_*`/`'PAC*'` byte moves. npm gains `./rt` (append-only
exports map; triple-pin unchanged until publish).
**Gates:** `zig build verify` every phase; P2 adds the new verbs
`zig build wasm-rt` + `zig build audit-rt-imports` (proposed spellings,
created by P2; the gate step runs BOTH layers — the source auditor and,
after `wasm-rt` builds the artifact, `tools/check_rt_artifact.zig`) and
ends in a **preliminary, non-binding size trend**; P3
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
`Writes`, `Easing`, `ExprTrack`, `PatternTrack`, and the runtime's SJON
window `RtSjon` (P2 below — within the runtime closure the `sjon` module
is imported NOWHERE else). Never `Compile`.

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
    // Per-arm contract (final-review fixup): the schema is bound by the
    // arm, not one frozen set. Tree arm: the compile result's
    // `eval_schema` — core ⊕ the document's user plugins — because the
    // text path's public semantics accept user-plugin expr heads today
    // (`src/Eval.zig:230`; `src/Compile.zig:329-334`) and the facade
    // must preserve them verbatim. Binary arm: the frozen core-only
    // schema (+ `plugins/pattern` at P4) — user heads never enter a
    // binary because `pacer pack` refuses them (01, decision 8).
    schema: sjon.Schema.Schema,
};
pub fn init(gpa: std.mem.Allocator, ctx: *const Context) InitError!Evaluator;
```

The per-arm schema contract is load-bearing in both directions: the
binary arm's core-only restriction is enforced at PACK (the head walk,
01) — never by silently narrowing the schema the shared engine
evaluates the tree arm with, which would change text-path semantics;
and the tree arm carrying user plugins must never leak into a binary,
which the `LeafSource` union makes unrepresentable (a binary context
has no tree, and the pack walk is what keeps user heads out of
payloads).

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
`registry_mismatch`, `meta_incoherent`, `dry_run_failed`) / 2 bad call (argument ranges and a
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
disabled, the SJON dep resolved with `.@"plugin-exec" = false`
(`build.zig:73-77`) — which gates the NATIVE plugin runtime only: on
wasm32 it is forced false anyway (`SJON/build.zig:52-58`), so
`wasm_plugin_invoker.zig`'s `if (native_plugin_exec)
@import("PluginRuntime.zig")` branch
(`SJON/src/wasm_plugin_invoker.zig:72`) is false and the plugin-runtime
chain never links. The wasm plugin host stub is a SEPARATE option and is
not ours to unset: `wasm_plugin_host` — whether the artifact declares
the host-invoker import — is hardcoded `true` for the `sjon` module via
an `addOption` literal, not a `b.option` (`SJON/build.zig:64`), so
pacer's dependency args cannot override it — two separate flags, never
one. The extern is statically retained regardless:
`Expr.applyFunction` dispatches `wasm_export_name` funcs on a runtime
branch with no comptime gate (`SJON/src/Expr.zig:2847-2852`), and on
wasm32 `invoke` compiles to `invokeViaHostImport`
(`SJON/src/wasm_plugin_invoker.zig:159-172`), which references
`extern "env" fn sjon_host_invoke_plugin` (`:78-80`). The artifact
therefore declares exactly one import; layer 2(a) freezes that
allowance instead of pretending the section can be empty.

**Closure gate — one crossing, two layers (final-review HIGH-1).**
SJON's auditor cannot be ported as-is: pacer reaches SJON through a
*named module* (`const sjon = @import("sjon");` — `src/ExprTrack.zig:60`,
`src/TrackTable.zig:35`, and every other runtime-side file), and that
tool skips every non-`.zig` import
(`SJON/tools/audit_wasm_imports.zig:189`), so the BFS would never enter
SJON's tree — while a runtime file using `sjon.Parser`/`sjon.Host`
(member usage, no `.zig` import line at all) would evade it entirely,
which is precisely the compiler-in-the-artifact class this gate exists
to name. The opposite move is equally wrong: following the module into
`root.zig` pulls the entire write side (`root.zig` IS the kitchen-sink
aggregate — `Parser`…`Lowering`… all `pub const` exports), and
selecting namespaces does not by itself stop a source-scan traversal
there. The design fixes the module boundary at ONE audited pacer file
and proves the shipped artifact physically:

- **`src/RtSjon.zig` — the runtime's only window into SJON.** It holds
  the closure's single `@import("sjon")` plus a frozen re-export table,
  one namespace per line: `Ast`, `Expr`, `Pattern`, `PatternQuery`,
  `BinaryCursor`, `BinaryFormat`, `Schema`, `Plugin`, `trig`, and
  `plugins.core` (`plugins.pattern` joins at P4). Every other
  runtime-closure file imports `RtSjon.zig`, never the module. The
  named module is one instance, so the re-exports are the SAME types —
  the duplication caveat in `SJON/src/root.zig`'s
  `Lowering_test_hooks` note is about relative file imports, which a
  named-module re-export does not take.
- **Layer 1 — `tools/audit_rt_imports.zig`, the syntactic gate.**
  Column-0 BFS from `rt_entry.zig` (the SJON convention verbatim:
  production deps are column-0; test-only imports belong indented in
  the test body) with three module-aware rules: (a) `@import("sjon")`
  is legal ONLY inside `RtSjon.zig` — a direct module import anywhere
  else in the closure fails by name; (b) `RtSjon.zig` must match the
  strict alias grammar — exactly the allowlisted
  `pub const X = sjon.X;` lines (with `sjon.plugins.*` spelled the
  same way) and no other `sjon.`-prefixed token — closing alias and
  `@field` laundering at the one crossing; (c) `.zig` imports resolve
  against the pacer allowlist. The namespace→file map (`Expr` →
  `Expr.zig`, `plugins.core` → `plugins/core.zig`, resolved through
  `root.zig`'s `pub const` export table at `:244`) is asserted against
  that table each run, so it cannot drift. From those files the same
  BFS continues inside the dependency tree (root-dir parameter,
  `../SJON/src`) under the SJON allowlist — the TRUE transitive
  closure, with SJON's own ALLOWED as the evidence base
  (`SJON/tools/audit_wasm_imports.zig:84-108`): `Ast`, `BinaryCursor`,
  `BinaryFormat`, `Schema`, `Plugin`, `Expr`, `Pattern`, `PatternQuery`,
  `trig`, `Date`, `Time` (the column-0 reaches of the table above —
  `SJON/src/Expr.zig:37-44`, `PatternQuery.zig:35-39`,
  `BinaryCursor.zig:52-56`), plus `wasm_plugin_invoker` and
  `PluginValueCodec` (reached via `Expr`), and — under the same audited
  `comptime_excluded` mechanism SJON uses (`:72-82, 100-107`) —
  `PluginRuntime` and `runtimes/wasmtime`, textually present through
  the gated import, never linked on wasm32. SJON's own read-only
  closure additionally lists `Validator`, `MaterializedDefaults`,
  `StringFormats`, `wasm_common`, `version` — those belong to
  `wasm_binary.zig`'s entry, not to ours; their absence here is the
  expected difference. Stale-entry failure applies to both lists
  exactly as in SJON's tool. Forbidden by absence: `Compile`, pacer's
  `Schema.zig`, `Driver`, `Abi`, `Eval.zig` (the facade), `PacbEncode`,
  `wasm_entry`, `corpus_runner`, `parity_runner`, `cli`,
  `test_support`, and SJON's `Parser`/`Printer`/`Json`/`Edit`/write-side
  `Binary`/`Validator`/`Host`/`ManifestLoader`/`Lowering`/`root.zig`.
  **P2's pacer list:** `rt_entry`, `RtSjon`, `PactCodec`, `Pacb`,
  `Pacm`, `EvalCore`, `ExprTrack`, `PatternTrack`, `TrackTable`,
  `TimeMap`, `Easing`, `Writes` (`PatternQuery` is reached through
  `PatternTrack` even while its binary twin is unimplemented — the tree
  arm of the shared engine).
- **Layer 2 — `tools/check_rt_artifact.zig`, the physical gate.** The
  text scan has stated blind spots (indented imports, dynamically built
  names); the shipped bytes do not. The tool reads the BUILT
  `pacer-rt.wasm` and fails unless: (a) its **import section is EMPTY
  or holds exactly one function import** — module `env`, name
  `sjon_host_invoke_plugin`, signature `(req_ptr: u32, req_len: u32)
  callconv(.c) ?[*]u8` as declared at
  `SJON/src/wasm_plugin_invoker.zig:78-80`. That single import is
  statically unavoidable (the build paragraph above) and dynamically
  inert: the frozen core(+pattern) binary schema provides no plugin
  implementations — neither `plugins/core.zig` nor `plugins/pattern.zig`
  declares a `wasm_export_name` func — and `pacer pack` refuses
  unsupported plugin heads (decision 8), so the import has no legal
  execution route in a normal valid score; even a corrupt state that
  reached it lands in the clean `PluginFuncAllocFailed` failure path
  (`SJON/src/wasm_plugin_invoker.zig:214-220`) — a diagnostic, never
  plugin execution. The allowance is a frozen exact set: a second
  import, the right name with a wrong kind, module, or signature, or
  any lazily-referenced forbidden chain surfacing as an extra import —
  fails loudly right here; (b) its **export set equals the frozen `prt_*`
  list** — rdynamic would leak a stray `pub`; (c) a frozen MARKER list
  — distinctive compiler-only string constants (diagnostic texts,
  schema JSON keys) — appears NOWHERE in the artifact, with the control
  direction asserted the same run: every marker must be present in the
  full `pacer.wasm`, so a stale marker fails too. Section parsing and
  the marker scan are unit-tested against synthetic module bytes — the
  import rule's edges included: a synthetic module with an empty import
  section passes, one holding exactly the single inert
  `env.sjon_host_invoke_plugin` function import at the frozen signature
  passes, and a wrong kind, module, name, or signature — or any import
  beyond the one — is rejected. The signature is asserted, not just the
  name: the glue's instantiation must bind a stub matching what the
  artifact declares, so the runtime knows the signature instantiation
  will expect. Layer
  2 is what makes layer 1's blind spots acceptable instead of hidden:
  anything the scanner misses that is actually referenced gets linked —
  Zig's lazy analysis and DCE see to that — and its imports, exports,
  or strings then fail here. The residual boundary is frozen honestly:
  a deliberately marker-free compiler fragment is beyond v1's proof;
  the gate is these two layers together, not certainty.

**Proof by mutation:** the auditor takes a root-dir parameter;
checked-in fixture trees under `tools/testdata/rt-imports/` each carry
one known-bad shape and the tool must FAIL naming it (run in the tool's
own test step): a direct `@import("sjon")` outside `RtSjon.zig`; a
`sjon.Parser` re-export inside it; a relative-`.zig` import laundering
a forbidden SJON file; a forbidden chain crossing the module boundary;
stale entries in both directions. One fixture records the honest split:
an INDENTED forbidden import passes layer 1 by design — layer 2 is the
named backstop for exactly that class. The gate is proved against
known-bad closures, never asserted. None of this requires SJON-owner
work — the wave adds no second handoff.

**Preliminary size trend (non-binding).** At P2's end, record raw/gzip9/
brotli11 of `pacer-rt.wasm` (the `meridian.size.json` per-file method) in
the progress log, labeled: *pattern support absent, pack refuses patterns,
capability set incomplete — trend only; the binding measurement is 04's
full-capability report and the user's checkpoint.* The `Pacm` reader's
bytes are part of this trend and 04 reports them as their own row — the
cross-check is a wave decision (00 decision 6), so its cost stays visible,
never hidden in the total. A catastrophically bad
trend (no meaningful reduction) stops the wave here; anything else proceeds
without a verdict.

### P3 — `pacer/rt` JS glue

`npm/pacer/src/rt.js`: `PacerRt` mirroring `Pacer`
(`npm/pacer/src/index.js:100-249`) — same constructor flow (registries →
canonical `'PACT'` via the shared encoder), `load(pacbBytes)` in place of
`reload(text)`, `eval`/`setControl`/`clearControl`/`registerControl`/
`setBpm`/`exprFailures`/`meta` with identical semantics; the `'PACM'`
decoder is shared with index.js (extract the decode half into a leaf both
import — no format change; the runtime already validated the section via
01's reader before serving it, so the shared decode is not the trust
boundary); `route.js`/`lane.js` reused untouched. Instantiation binds
the one allowed import (layer 2(a)) as the same inert stub the full
driver already ships — `env.sjon_host_invoke_plugin: () => 0`
(`npm/pacer/src/index.js:84`; the `WebAssembly.instantiate` call at
`:144-148` passes it) — matching the frozen signature. A valid packed
score never reaches it (no plugin implementations in the schema,
unsupported heads refused at pack); if it is invoked anyway, the
stub's null return maps to the clean `PluginFuncAllocFailed` failure
(`SJON/src/wasm_plugin_invoker.zig:214-220`) — a diagnostic/drop,
never plugin execution. No `reload(text)` exists on the class
(asserted by test). Views are re-taken
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
actually reaches it); and the head walk's pattern arm lands with it —
builtin pattern combinators (`stack`, `seq`, `cat`, …) and `(pure …)`
leaves carrying expr forms are acceptance-tested against 01's position
rules (combinator heads never trip the expr check; the leaves' forms are
classified). **If SJON's owner declines:**
P4 does not proceed and the pattern class is *blocked* — escalate to the
user with the measured cost of the gap (which scores cannot ship binary).
"Patterns remain text-path-only permanently" is the user's decision,
recorded in the decision log then; this plan never converts the owner's
refusal into a permanent silent subset.

## Phases

| Phase | Deliverable | Gate |
|---|---|---|
| P1 | `EvalCore` leaf + `Eval` facade adapter; zero behavior change | `zig build verify` (corpus byte-identical) + `cli-golden` diff empty + CLI tests green |
| P2 | `rt_entry.zig`, `zig build wasm-rt`, closure gate (layer 1 auditor + fixtures, layer 2 artifact check), transactional-load + ownership tests, preliminary size trend | `zig build verify`; new verbs green incl. the artifact check; trend logged with its uncertainty label |
| P3 | `pacer/rt` + tests | npm `lint && typecheck && test`; `zig build verify` |
| P4 | patterns end-to-end (or the recorded block + escalation) | `zig build verify`; `pattern-env` green via the binary path |

## Progress log

_(created 2026-10-18; entries appended per phase)_

- **2026-10-19 — Phase P1 complete (T1.1 + T1.2).** One engine now exists:
  `src/EvalCore.zig` carries the whole `Evaluator` verbatim (frame path,
  control/dynamic slots, `setBpm`, `expr_failures`, `last_tick`), over a
  `LeafSource` union — `tree` (today's borrowed-tree path) | `binary`
  (parallel compact-payload slices, `ExprTrack.evalAtBinary` the leaf,
  T1.1) — with `Context` by value (C3, labeled choice). Construction:
  `initContext(gpa, ctx)` (the runtime's typed spelling) plus a generic
  `init(gpa, source: anytype)` comptime-dispatching `Context` /
  anything-`.evalContext()` / readable `@compileError` (C2 as re-targeted
  by R-B1); `CompileResult.evalContext()` vends the tree-arm bundle, so
  the exact historical `Eval.Evaluator.init(gpa, &result)` call survives
  byte-for-byte — `Driver.zig:68`, `fuzz.zig` ×4, and the 56 in-file
  facade test call sites all UNMODIFIED (zero respells, no `Eval.init`
  free fn). `src/Eval.zig` is the compiler-side facade: the SAME type by
  alias + six delegated constants + a one-line comptime identity assert;
  its test block is byte-preserved. The engine's expr arm omits-and-
  counts binary-leaf failures exactly like tree failures; the binary
  pattern arm asserts the track class absent (pre-P4, no silent
  empty-features); `Ast.NodeIndex.invalid` is the inert sentinel, guarded
  by a debug assert at the tree-arm deref (C4/R-O2). REDs: missing-module
  (`EvalCore.zig` FileNotFound via root discovery), then missing-decl
  (`initContext`), both observed. GREEN: `zig build test` 486/486
  (397 root + 89 CLI; baseline 483 + 3 EvalCore tests); `zig build
  verify` 15/15 (corpus 38/0, node 94/94, cli-golden + score-docs
  current); `git diff --exit-code <base> -- corpus src/cli/testdata`
  empty; `zig build fuzz` 5/5 361/361 (the unmodified call sites are
  R-B1's proof). Deviations recorded: C2 re-targeted (facade-by-alias +
  generic init), C3 by value — both per the plan's own §0 rulings; the
  plan's EvalCore import list naming `Easing` was approximate (the moved
  engine needs none — compiler-guided, as the plan allows).
