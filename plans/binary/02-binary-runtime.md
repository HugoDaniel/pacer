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
**Created 2026-10-18; P1–P3 complete 2026-10-19 (P3 QUALIFIED);
P4 is blocked on the SJON-owner prerequisite; 03/04 remain pending.**

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
- **2026-10-19 — P2 in progress: T2.1 landed the `RtSjon` window (the
  phase gate stays T2.5's — interim carry-forward, not a phase close).**
  `src/RtSjon.zig` is the runtime closure's single SJON window (C1): the
  one column-0 `@import("sjon")` inside the closure, behind a frozen
  nine-row re-export table — `Ast`, `Expr`, `Pattern`, `PatternQuery`,
  `BinaryCursor`, `Schema`, `Plugin`, `trig`, `plugins.core` — every row
  actually reached by the seven closure files (`EvalCore`, `ExprTrack`,
  `PatternTrack`, `TrackTable`, `TimeMap`, `Easing`, `Pacb` now import
  `RtSjon.zig` at column 0 and spell their production SJON tokens through
  it). `BinaryFormat` is absent because SJON exports no such root name;
  the write side stays out of the window entirely, and its one
  closure-needed constant — the payload walk's depth cap — is a frozen
  `Pacb.MAX_TREE_DEPTH = 1024` copy (u32, matching the source's own
  spelling), equality-pinned against the module constant in
  `src/root.zig`'s frozen-copy test family. Write-side test uses (parse,
  `Binary.toBinary`, `validateDocument`, `Host`) ride INDENTED test-block
  imports in the closure files — `TestDoc`'s field carries the one
  inline indented spelling, lazily analyzed so no non-test build ever
  resolves it — and the T1.x transitional `sjon_w` locals are renamed
  back to plain `sjon` (write-side test oracles preserved verbatim).
  Pure indirection, zero behavior change: RED = missing-module
  (TrackTable respelled before the file existed —
  `unable to load 'RtSjon.zig': FileNotFound`, both roots failing
  through it); GREEN `zig build test` 487/487 (398 root + 89 CLI;
  baseline 486 + the one equality-gate test), `zig build verify` 15/15
  (corpus 38/0, node parity 94/94, cli-golden + score-docs current),
  `zig build fuzz` 5/5 361/361, cli-golden regeneration byte-neutral,
  `git diff --exit-code 1138707 -- corpus src/cli/testdata` empty.
  `zig fmt --check` clean on every touched file. NOT in this task (P2
  stays open): `rt_entry.zig`, the `wasm-rt` verb, the layer-1/2
  closure auditor, the transactional load — T2.2–T2.5 next.
- **2026-10-19 — P2 in progress: T2.2 landed `rt_entry.zig` + the
  `wasm-rt` verb + the transactional load (the phase gate stays T2.5's —
  interim carry-forward, not a phase close).** `src/rt_entry.zig` is the
  playback runtime's entry: the static zones (PACB in at the measured
  **`PACB_CAP` = 6,049,576 bytes** — toolchain-computed
  `Pacb.pacbWorstCase(256)`, the R-I2 256-byte allowance; labeled:
  *static zone = hard input byte cap, a whole-blob length policy, never
  a per-string rejection; decoded heap (the score's single arena)
  separate* — this row is T2.5's zone figure), `'PACT'` in 64 KiB,
  writes out at `Writes.encodedLen(EvalCore.MAX_FRAME_ENTRIES)`), the 17
  frozen `prt_*` exports (drv-twins' shapes incl. the 2^53 tick gate and
  registerControl range checks), `prt_load` statuses 0/1/2/3 with the
  02:127-131 frozen u16 reason map (R-O3; the two review-flagged
  stretches doc-commented at the table; `7 non_finite`
  reserved-no-emitter; `11 dry_run_failed` entry-side), meta served from
  the score's OWN embedded-`'PACM'` copy (pointer moves across loads).
  The load is TRANSACTIONAL: args ⇒ 2 (true no-op, reason word
  included) → `Pacb.decode` ⇒ 1+reason (OOM ⇒ 3, never faked) → pattern
  gate (`required_features` bit0 ⇒ `unsupported_feature`, pre-P4) →
  `canonicalPactEquals` ⇒ `registry_mismatch` → C4 materialization (inert
  `.invalid` sentinels, parallel payload slice, zeroed wire-absent
  spans) → C5 expr dry-runs at each track's own dry tick
  (`scene.start_tick` else 0, FBA over `ExprTrack.SCRATCH_BYTES`,
  `evalAtBinary` — budget exhaustion is a refusal, never OOM) →
  `EvalCore.initContext` → swap, then teardown (evaluator before the one
  arena free). REDs all observed: missing-module (root discovery,
  FileNotFound), unknown-step `wasm-rt`, then group-2: (a) refusal
  killing the old score under unload-first, (d) missing registry gate,
  (e) missing dry-run — each failed against the v1 shape before the
  transactional implement landed. Tests (native, calling the exports,
  text-path oracles on indented imports only): zones/ABI + the whole
  reason map, load/eval tracer, (a)–(h) incl. the (g) three-fixture
  byte-equal parity sweep (the C4 sentinel proof) and the (h) named
  scened-expr `(sqrt scene-beat)` acceptance-parity pin with its flat-0
  divergence inverse, control/bpm twins, and the ownership suite
  (zone-no-alias `@memset`, repeated alternating reloads under
  page-munmap, meta = current score's own bytes). Gates: `zig build
  test` 499/499; `zig build wasm-rt` builds the REAL
  `zig-out/bin/pacer-rt.wasm` (172,255 bytes, first actual artifact —
  BUILT, closure UNVERIFIED: T2.3/T2.4's gate is still ahead, no
  closure claim made); `zig build verify` 15/15; `zig build fuzz` 5/5
  361/361; fmt clean. Node smoke (one-off control script, Linux node
  v26.10.0, inert env stub, actual output in `binary02-t22-report.md`):
  `prt_load(full-small.pacb)` ⇒ 0, metaLen 2879, `prt_eval(0.5)` 152
  bytes, a corrupted reload ⇒ 1 with the old frame byte-identical and a
  held control intact, `keys-only` reload ⇒ 0 (metaLen 1784). Two test
  premises corrected during RED (not weakened): (c)'s reason-word pin
  made order-independent (before/after, not assumed-initial), (e)'s
  payload mutation made structural (`'PAYL'` `[len][bytes]` walk —
  0x2a-as-length is a coincidence). NOT in this task (P2 stays open):
  the layer-1/2 closure auditor + mutation fixtures (T2.3/T2.4), the
  size trend (T2.5).
- **2026-10-19 — P2 in progress: T2.3 + T2.4 landed the two-layer
  closure gate and the formal artifact smoke (the phase gate stays
  T2.5's — interim carry-forward, not a phase close).** T2.3
  (`f15ac7c`): `tools/audit_rt_imports.zig` — the layer-1 source
  auditor, column-0 BFS from `src/rt_entry.zig` under the three
  module-aware rules (02:202-212): `@import("sjon")` legal ONLY in
  `RtSjon.zig`; `RtSjon.zig` held to the strict nine-row alias grammar
  (`plugins.core` nested — Zig has no dotted decl names; comments
  stripped before the token scan so code, not prose, is governed);
  `.zig` imports resolve against the frozen twelve-file pacer
  allowlist, relative-`..` escapes forbidden by absence. The
  namespace→file map is asserted against SJON `root.zig`'s export
  table every run (`has_side_effects`; root.zig read, never
  traversed); the SJON leg BFSes under the re-derived 16-entry
  allowlist — 02's 15 PLUS `plugins/core.zig`, which 02:215-224's
  enumeration missed (reached both as the `plugins.core` row's own
  file AND from `Schema.zig:2407` column-0 in a test region);
  `Binary.zig` absent by design (C1). Stale entries fail both lists in
  both directions. Proof by mutation (02:280-290): six checked-in
  fixture trees under `tools/testdata/rt-imports/`, each run through
  the REAL tool and asserted to FAIL naming the shape (direct sjon
  import, `sjon.Parser` row, relative-`.zig` laundering,
  module-boundary crossing, stale both directions) — plus the
  honest-split fixture: an INDENTED forbidden import PASSES layer 1 by
  design (the named blind spot; layer 2 is the backstop). One genuine
  column-0 finding on the real tree: `src/Pacb.zig:6506`'s test-region
  helper SIGNATURE named `@import("Compile.zig").CompileResult` at
  column 0 (the T2.2 report's "test/helper bodies only" claim was
  inaccurate for that one line) — localized via an indented alias in
  the test-only `ScoreAndPacm` struct; test-only, zero production
  impact. RED observed: `no step named 'audit-rt-imports'`. T2.4 (this
  commit): `tools/check_rt_artifact.zig` — the layer-2 physical gate,
  chained into the same verb (`audit-rt-imports`: layer 1 → `wasm-rt`
  + `wasm` artifacts BUILT as dependencies, never stale → the artifact
  check on the INSTALLED `zig-out/bin` paths). The gate fails unless
  the built `pacer-rt.wasm` has (a) an EMPTY import section or exactly
  the one frozen function import `env.sjon_host_invoke_plugin` with
  `(i32,i32)->i32` asserted through the type section — not just the
  name (02:242's frozen empty-or-one allowance); (b) an export set
  exactly equal to the frozen 17 `prt_*` + `memory`, both directions;
  (c) the frozen 3-marker compiler-only list absent from the artifact
  AND present in the full `pacer.wasm` control the same run (a stale
  marker fails loudly) — `target_arity_mismatch` (Compile.Code
  vocabulary riding 'PACD'), `repr-shape` (schema/pacer.sjon, wired to
  wasm_entry only), `use-plugin` (SJON's text-parser directive). The
  section parser is bounds-checked throughout (over-long LEB, section
  size vs remaining bytes); synthetic-bytes unit tests cover the
  02:263-268 edge matrix (empty imports pass; the single inert import
  passes; wrong kind/module/name/signature, any second import, missing
  /extra/wrong-kind exports, malformed inputs — 12 tests riding
  `zig build test`). Real-artifact negatives observed exit 1:
  full-as-rt (35 named findings — every drv_* export, all 17 missing
  prt_*, all 3 markers present), a marker-tampered rt artifact, and a
  truncated artifact (malformed: section size past EOF). `tools/
  smoke_rt.mjs` is the formal smoke (superseding the T2.2 one-off):
  real-artifact instantiate with the inert `env.sjon_host_invoke_plugin`
  stub, `prt_abiVersion()=1`, `prt_load(full-small.pacb)` ⇒ 0 with a
  zero-count 'PACT' (R-O1 — the fixture declares its targets),
  metaLen 2879, `prt_eval(0.5)` 152 bytes, a CORRUPTED reload ⇒ 1
  reason 0 with the old score live (frame byte-identical, held control
  intact — JS-visible transactional proof), `keys-only` reload ⇒ 0
  (metaLen 1784). RED observed: missing-tool FileNotFound from the
  wired test module before the tool existed. Gates (obs, serial;
  combined report `binary02-t23-t24-report.md`): `zig build test`
  11/11 steps **521/521** (410 root + 89 CLI + 10 layer-1 + 12
  layer-2 tool tests); `zig build audit-rt-imports` 10/10 steps —
  layer 1 OK (12 pacer + 16 SJON, map matches root.zig) AND layer 2
  OK (172,255-byte artifact, 1 import, frozen export set exact, 3
  markers absent-here/present-in the 666,873-byte control); `zig build
  verify` 15/15, 410/410, corpus 38/0, node 94/94, cli-golden +
  score-docs current; `zig build fuzz` 5/5 361/361; node v26.10.0
  smoke PASS (exit 0); fmt clean on all touched zig. Truth limits,
  stated: the marker check is a physical string presence/absence gate
  on frozen picked markers with a same-run control direction — not a
  universal compiler-exclusion proof; layer 1 is a column-0 source
  scan with a named indented/dynamic blind spot, so synthetics and the
  source BFS are jointly bounded — the shipped-bytes rules (a)+(b)
  plus lazy-linkage/DCE carry the closure claim. NOT in this task (P2
  stays open): the preliminary size trend (T2.5) closes P2; P3
  (T3.1/T3.2) untouched.
- **2026-10-19 — Phase P2 complete (T2.5, the preliminary size trend;
  P2 closes QUALIFIED — the closure rests on the ACTUAL two-layer
  audit, built and run against the real artifact and passing, not on
  a plan assertion; the layer-1 blind spot and marker-gate truth
  limits stated in the T2.3/T2.4 entry stand).** Measured on the
  ACTUAL CURRENT artifacts at base `af74e0e` (both rebuilt/confirmed
  by the `audit-rt-imports` verb this task; no earlier figure
  reused), per-file `meridian.size.json` method (per-file encoded
  sums, not an archive or wire measurement; node v26.10.0 `zlib`,
  gzip level 9, brotli quality 11 — the SAME method on both files):

  | file | raw | gzip9 | brotli11 |
  |---|---|---|---|
  | `pacer-rt.wasm` (playback runtime) | 172,255 | 67,767 | 57,827 |
  | `pacer.wasm` (full driver, control) | 666,873 | 241,879 | 195,623 |

  Plain ratios on those measurements: the rt artifact is 25.8% of the
  full driver's raw bytes (28.0% under gzip9, 29.6% under brotli11).
  **Label (mandated, 02:294-296):** *pattern support absent, pack
  refuses patterns, capability set incomplete — trend only; the
  binding measurement is 04's full-capability report and the user's
  checkpoint.* **Static PACB zone (own row, R-I2):**
  **`PACB_CAP` = 6,049,576 bytes** — `Pacb.pacbWorstCase(256)`
  toolchain-printed in T2.2 and runtime-confirmed
  (`prt_pacbCap=6049576`, T2.2 smoke) — labeled: *static zone = hard
  input byte cap, a whole-blob length policy, never a per-string
  rejection; the decoded heap (the score's single arena) is separate
  and bounded by the format caps.* The zone is a static reservation
  in the rt artifact's memory layout, NOT artifact byte bloat — it
  does not appear in the file column above. **`Pacm` reader byte
  cost (own row, 00 decision 6 — visible, never hidden in the
  total):** measured by a CONTROLLED same-build-variant ablation, not
  estimated — an ignored scratch copy of the decode path
  (git-`info/exclude`'d `src/ablate_*`, deleted after measurement)
  stubbed ONLY the PACM structural decode + routing cross-check
  (`Pacm.decode` + `verifyRouting`; the `'TRAN'` fnv fast-reject
  retained), built with the identical ReleaseSmall wasm32-freestanding
  recipe and the same resolved SJON module; production
  `src/Pacb.zig`/`src/rt_entry.zig`/`build.zig` untouched. Ablated
  artifact: 168,130 raw / 65,708 gzip9 / 56,297 brotli11 ⇒ reader
  cost **Δ = 4,125 raw / 2,059 gzip9 / 1,530 brotli11 bytes** (~2.4%
  of the rt artifact raw). What this proves, exactly: the marginal
  LINKED cost of the `Pacm` reader (decode + routing cross-check +
  its call glue, DCE cascade included) inside THIS toolchain/build
  variant — not a standalone module size, and not a figure guaranteed
  to reproduce identically under future closures or toolchains.
  **Catastrophe rule restated (02:299-301):** a catastrophically bad
  trend (no meaningful reduction) stops the wave here; anything else
  proceeds WITHOUT a verdict — no verdict is taken here. Gates this
  task (obs, serial): `zig build verify` 15/15 (zig 410/410, corpus
  38/0, node 94/94, cli-golden + score-docs current), `zig build
  wasm-rt` green, `zig build audit-rt-imports` 10/10 (layer 1 OK —
  12 pacer + 16 SJON; layer 2 OK — 172,255-byte artifact, frozen
  export set exact, 3 markers absent-here/present-in the 666,873-byte
  control). RED: none constructible (measurement/docs task — the 01
  T4.3 doctrine); the recorded numbers + green verbs ARE the
  evidence. P3 (T3.1 shared leaves, then T3.2 `PacerRt`) is next.
- **2026-10-19 — Phase P3 IN PROGRESS (T3.1 shared leaves landed;
  P3 does NOT close here).** `src/pact.js` (the canonical `'PACT'`
  `encodeTargets` + its `'PACT'`/`MAX_TARGETS` constants),
  `src/meta.js` (the `'PACM'` decode half as `decodeMeta(buffer,
  ptr, len, docBytes, targetName)`), and `test/harness.js`
  (`parseHarness` + the canonical `renderCase`, now taking the
  already-loaded driver so the SAME renderer can serve T3.2's
  playback runtime) are extracted leaves. `index.js` imports
  `encodeTargets`/`decodeMeta` and `corpus.test.js` imports the
  harness; the moved bodies are behavior-identical — views are still
  re-taken per call, JSDoc return shapes unchanged, and all 38 corpus
  goldens stay byte-identical. No `PacerRt` class exists yet and the
  exports map is untouched (that is T3.2). Test-count note (precise,
  not a semantic drift): Node's default discovery also runs the new
  helper `test/harness.js` as a file-level module case, so the suite
  reports 95 = the SAME 94 named semantic tests as the pre-extraction
  verify plus 1 helper module case; the 94 names compare equal set-
  for-set, and every case passes. Linux gates: biome 14 files clean,
  `tsc --noEmit` exit 0. Obs gates: `zig build verify` 15/15 (zig
  410/410, corpus 38/0, node 95/95 — 94 semantic + helper),
  `node tools/smoke_rt.mjs` PASS. RED observed: duplicate-declaration
  first (pointing at the leaves before the old bodies were removed),
  then `ERR_MODULE_NOT_FOUND` (leaves referenced before creation).
  T3.2 (`PacerRt` + `test/rt.test.js` + append-only package wiring)
  is next.
- **2026-10-19 — Phase P3 COMPLETE (T3.2 landed); P1–P3 COMPLETE /
  QUALIFIED, pending P4 review and 03/04. The wave is NOT complete.**
  `src/rt.js` adds `PacerRt`, the playback-runtime glue over the real
  `pacer-rt.wasm` `prt_*` surface: the same registries → canonical
  `'PACT'` flow through `pact.js`; `load(pacbBytes)` as the only load
  verb (`PacerRt.prototype.reload` is undefined — asserted); the same
  `eval` / `evalTicks` / `evalBytes` / `setControl` / `clearControl` /
  `registerControl` / `setBpm` / `exprFailures` / `meta` call surface;
  views re-taken from `exports.memory.buffer` on every call; the one
  inert `env.sjon_host_invoke_plugin: () => 0` import. `load` is
  transactional: a status-1 refusal leaves the old score armed (driver
  `ok` stays true once a score is live) while the returned `ok` is the
  load's own outcome; `status` / `reason` carry the refusal class.
  `diagnostics` stays `[]` — a PACB has no 'PACD', so no compiler message
  is invented.
  **Metadata contract (source-forced, recorded not invented):** PACM
  spans are preserved in original source byte coordinates, but the
  binary carries no source text. The shared `decodeMeta` is called with
  empty `docBytes`, so scene `name` is `''` while `nameSpan` remains
  authoritative; declared-only target names are `null` because `'DECL'`
  carries registry/ncomp only and names never cross the wire (the same
  null `Pacer` reports for an unhosted declared target). The parity test
  therefore asserts the eval/control/BPM render is byte-equal and that
  the ONLY rendered difference is the source-sliced scene name; the span
  is asserted equal. No format change, no text fallback, no fabricated
  names.
  **Package surface (append-only):** `exports["./rt"]`, `exports["./
  pacer-rt.wasm"]`, `files += "pacer-rt.wasm"`, and the
  `build:wasm-rt` / `build:wasm-rt-copy` / `build:rt-fixture` scripts;
  `pretest` rebuilds wasm, wasm-rt, copies it, then packs
  `full-small.score.sjon`; `build` carries both artifact legs and
  `build:types` (emits `types/rt.d.ts`); `clean` removes both artifacts
  and the generated fixture. The generated fixture and `pacer-rt.wasm`
  are gitignored, never committed. `build.zig`'s verify node leg now
  depends on `wasm-rt` + the fresh CLI fixture so a clean checkout is
  self-contained.
  **Tests:** `test/rt.test.js` (8 production-artifact tests) covers load
  + exact immutable metadata (including byte-coordinate span slicing),
  text↔binary harness parity (writes/control/BPM; one documented scene
  name difference), registry mismatch (status 1, reason 9), transactional
  refused reload with control/BPM/`exprFailures` held, second-load meta
  view replacement, absent `reload`, evalTicks/control surface, and
  robust typed-byte/zone-overflow/bad-call honesty. `exports.test.js`
  pins the append-only package map. REDs observed: missing `rt.js`
  (`ERR_MODULE_NOT_FOUND`), then a named FAIL for each grown behavior
  (`setControl`, `exprFailures`, `evalTicks`).
  **Gates (this task):** Linux node 104/104; biome 2.5.0 clean (16
  files); `tsc --noEmit` exit 0; `npm run build:types` emitted
  `types/rt.d.ts`; obs `npm test` 104/104 with the pretest build/copy/
  pack; clean-checkout obs `zig build verify` 18/18 (410/410 Zig, corpus
  38/0, node 104/104, cli-golden + score-docs current); `zig build test`
  521/521; `zig build fuzz` 361/361; `zig build audit-rt-imports` 10/10
  (both layers, 172,255-byte artifact); `npm pack --dry-run` exit 0
  (35 entries, ships `pacer-rt.wasm` + `types/rt.d.ts`, no tests or
  generated fixture). P4 stays blocked on the SJON owner prerequisite;
  03/04 remain pending.
