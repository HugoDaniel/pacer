# 03 — The borrow-whole rule becomes structure (`Driver`)

**Repo:** pacer
**Wire impact:** none (`drv_*` exports unchanged; this is native-side lifetime shape)
**Gates:** `zig build verify`, npm gate
**Size:** medium — a new small module + two call-site migrations; no semantics move.

## Why

`Eval.Evaluator` borrows a `Compile.CompileResult` WHOLE, which imposes three
uncheckable obligations on every holder of the pair: the result must sit in its final
memory location before `Evaluator.init`, must never be reassigned while borrowed, and
must be torn down AFTER the evaluator. The contract is documented in four places
(`Compile.zig:246-249`, `Eval.zig:98-103`, `wasm_entry.zig:119-122`, CLAUDE.md) and
confined to two call sites — but enforced by nothing. It is the one contract in the
codebase a new call site can get wrong with no assert, type, or build break catching
it: discipline where everything else is structure.

The rule exists because the compiled artifact is deliberately not closed (expr and
pattern tracks re-read the tree + schema every frame — the anti-drift trade). That
trade stays. Only its footgun goes.

## Design

Two options; **Option B is recommended**.

**Option A — pointer-returning compile.** `compile` allocates the `CompileResult`
inside its own arena and returns `*CompileResult` (the arena-carrier pattern; deinit
copies the arena out before destroying). Pointer stability by construction — but it
diverges from the SJON house memory model ("returns an owned struct with arena-backed
`.deinit()`"), churns every test and the corpus runner, and still leaves teardown
ORDER to the caller. Rejected unless B proves insufficient.

**Option B — a `Driver` that owns the pair and the ordering.** New `src/Driver.zig`
(re-exported from root):

```zig
pub const Driver = struct {
    result: Compile.CompileResult,
    /// Non-null iff `result.ok()` — armed by `init`.
    evaluator: ?Eval.Evaluator,

    /// In-place init: the POINTER receiver is the contract — `self` is
    /// the final memory location, visibly, in the signature itself.
    pub fn init(self: *Driver, gpa: Allocator, source: [:0]const u8, targets: []const Compile.Target) Error!void
    pub fn deinit(self: *Driver) void  // evaluator first, then result — encoded once
};
```

`init` compiles into `self.result` (the by-value move lands BEFORE any borrow is
taken), then arms `self.evaluator` from `&self.result` when the compile is clean.
`deinit` owns the teardown order. The three obligations collapse to one, stated by
the signature: place the `Driver`, then init it, don't move it. `result` and
`evaluator` stay `pub` (wasm_entry reaches `setBpm`/`setControl`/meta encoding
through them; no forwarding shims — the Driver owns lifetime, not API).

Migrations: `wasm_entry.zig` replaces the `result`/`evaluator` optional pair with
one `var driver: Driver = undefined; var loaded: bool = false;` (its
validate-before-teardown ordering in `drv_load` is preserved verbatim — the
argument gate still runs before `driver.deinit()`); `corpus_runner.zig` replaces its
pair likewise. `Eval.zig`'s own tests may keep constructing raw pairs (stack locals
that never move — they exercise the Evaluator, not the lifetime rule); the
borrow-whole prose in `Compile`/`Eval` shrinks to "use `Driver` unless you can
uphold these three rules yourself", and CLAUDE.md's borrow-whole section points at
the type.

## Phases

### Phase 1 — Driver + native migration (RED first)
Load: `src/Compile.zig` (CompileResult docs), `src/Eval.zig` (Evaluator.init/deinit
docs), `src/corpus_runner.zig` (the load/teardown sites only).
Reds: new `src/Driver.zig` tests — clean score arms the evaluator and evals; failing
score leaves `evaluator == null` with diagnostics readable; `deinit` after both
outcomes is leak-free (`std.testing.allocator` catches order bugs); reload-in-place
(deinit + re-init on the same storage) works.
Green: implement `Driver`, re-export from `root.zig`, migrate `corpus_runner.zig`.
Gate: `zig build test`, `zig build corpus` (byte-identical goldens).

### Phase 2 — wasm entry migration + docs
Load: `src/wasm_entry.zig`, `CLAUDE.md` (borrow-whole section), the doc paragraphs
flagged in Phase 1.
Work: migrate `drv_load`/`unload` to the single `Driver`; keep the
validate-first/no-op-on-bad-call behavior byte-for-byte (the corpus pins the
acceptance echoes); shrink the four prose statements of the rule to point at the
type.
Gate: `zig build verify`, npm gate (wasm rebuild + parity walk + driver.test.js's
reload/control-state cases — these exercise exactly the lifecycle that moved).

## Progress log

(empty)
