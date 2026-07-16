//! Pattern-track evaluation — the single definition of "query a track's
//! `:pattern` node on the tick grid", shared by `Compile` (the load-time
//! dry-run over the enclosing cycle) and `Eval` (the frame-path
//! point-sample, plan 03 Phase 3). One code path means the two cannot
//! drift: the cycle window the dry-run queried and the value contract it
//! accepted are exactly what the frame path queries and coerces.
//!
//! ## Cycle mapping (frozen, plan 03 Phase 1)
//!
//! 1 pattern cycle = 1 bar, as identity on the shared grid:
//! `sjon.Pattern.PPC` IS pacer's per-bar tick count (`TimeMap` pins one
//! bar = PPC ticks for every meter — the meter divides beats *within*
//! the bar), so no conversion exists and the window math is exact
//! integer arithmetic, transport-independent.
//!
//! ## Result contract
//!
//! A hap payload must be a finite number (`PatValue.number` or an exact
//! integer variant) — the write is its single f64→f32 truncation in lane
//! 0. Symbols, strings, keywords, booleans, and nil are legal pattern
//! vocabulary but violate the contract; `PatValue` has no vector
//! variant, so `:pattern` drives SCALAR targets only this slice (a
//! multi-component target is rejected at load, `pattern_result_invalid`).
//!
//! Determinism: `PatternQuery` is a pure function of (tree, window,
//! seed) — seeded SplitMix64, integer tick math, and the same pinned
//! `Expr` kernels as `:expr` tracks — so same document + same tick ⇒
//! identical haps, native and wasm32.

const std = @import("std");
const sjon = @import("sjon");
const TrackTable = @import("TrackTable.zig");

const Ast = sjon.Ast;
const Pattern = sjon.Pattern;
const PatternQuery = sjon.PatternQuery;

pub const Tick = TrackTable.Tick;

/// Document seed for every pattern query, pinned to 0 this slice. A
/// future `:seed` (transport- or track-level) threads through here; it
/// reaches hap value exprs as the pattern-local `seed` binding.
pub const SEED: i64 = 0;

/// The engine's deterministic outcome set (depth / hap / byte ceilings,
/// tick overflow) plus `OutOfMemory` — same shape as `ExprTrack.Error`'s
/// pass-through: callers map everything but OOM to a diagnostic.
pub const Error = PatternQuery.Error;

/// The enclosing cycle window of `tick`: `[c·PPC, (c+1)·PPC)` for
/// `c = floor(tick / PPC)`. Exact integer math; an edge-of-grid window
/// bound that cannot be represented is `error.TickOverflow` (the
/// engine's own overflow outcome, never a wrap).
pub fn cycleWindowOf(tick: Tick) Error!Pattern.Span {
    // PPC is a positive constant, so divFloor cannot fail.
    const cycle = std.math.divFloor(Tick, tick, Pattern.PPC) catch unreachable;
    const begin = std.math.mul(Tick, cycle, Pattern.PPC) catch return error.TickOverflow;
    const end = std.math.add(Tick, begin, Pattern.PPC) catch return error.TickOverflow;
    return Pattern.Span.init(begin, end);
}

/// Query the enclosing cycle of `tick`. `tree` must be the tree `node`
/// belongs to and `schema` the core-carrying aggregate it validated
/// under (both live on the `Compile.CompileResult`) — the schema backs
/// `(pure <form>)` expr leaves. The returned `Result` owns an arena —
/// deinit it. Collection over abort: malformed combinators surface as
/// `result.diagnostics` (the node degrades to silence), and per-hap expr
/// failures as `result.dropped` — not as errors.
pub fn queryCycle(
    gpa: std.mem.Allocator,
    tree: *const Ast.Tree,
    schema: sjon.Schema.Schema,
    node: Ast.NodeIndex,
    tick: Tick,
) Error!PatternQuery.Result {
    const window = try cycleWindowOf(tick);
    return PatternQuery.queryTree(gpa, tree, node, schema, window, SEED);
}

/// Apply the result contract to one hap payload: a finite number, with
/// the single f64→f32 truncation into lane 0 (lanes 1–3 zero — the
/// `TrackTable.Key.value` invariant). Anything else is null; `Compile`
/// turns that into `pattern_result_invalid` at load, `Eval` (Phase 3)
/// into a per-frame omission.
pub fn coerce(value: PatternQuery.PatValue) ?[4]f32 {
    const x: f64 = switch (value) {
        .number => |n| n,
        // Exact promotion for grid-friendly integer literals like
        // `(pure 1)` — i64/u64 → f64 may round at extreme magnitudes,
        // but the finiteness gate below still holds.
        .integer_i64 => |i| @floatFromInt(i),
        .integer_u64 => |u| @floatFromInt(u),
        .symbol, .string, .keyword, .boolean, .nil => return null,
    };
    if (!std.math.isFinite(x)) return null;
    return .{ @floatCast(x), 0, 0, 0 };
}

// ---------------------------------------------------------------------------
// Tests. Trees come from `sjon.parse` over a bare pattern form — the
// dry-run/eval callers hand in `Compile`'s validated tree, but the
// engine only needs the node and (for expr leaves) a core-carrying
// schema. Score-level coverage lives in `Compile` tests.
// ---------------------------------------------------------------------------

const t_ = std.testing;

const core_plugins = [_]sjon.Plugin.Plugin{sjon.plugins.core.plugin};
const core_schema: sjon.Schema.Schema = .{ .plugins = &core_plugins };

test "cycleWindowOf: identity windows on the PPC grid, negatives included" {
    const PPC = Pattern.PPC;
    try t_.expectEqual(Pattern.Span.init(0, PPC), try cycleWindowOf(0));
    try t_.expectEqual(Pattern.Span.init(0, PPC), try cycleWindowOf(PPC - 1));
    try t_.expectEqual(Pattern.Span.init(PPC, 2 * PPC), try cycleWindowOf(PPC));
    // floor semantics: a negative tick belongs to the cycle below zero.
    try t_.expectEqual(Pattern.Span.init(-PPC, 0), try cycleWindowOf(-1));
}

test "queryCycle: the window is the tick's enclosing cycle (slowcat alternation)" {
    // `(slowcat 0.1 0.2)` plays child i at cycle i — querying at a tick
    // inside cycle 1 must return the SECOND child, pinning the window
    // derivation through the real engine.
    const gpa = t_.allocator;
    var tree = try sjon.parse(gpa, "(slowcat 0.1 0.2)");
    defer tree.deinit();

    var result = try queryCycle(gpa, &tree, core_schema, tree.root[0], Pattern.PPC + 1);
    defer result.deinit();
    try t_.expectEqual(@as(usize, 0), result.diagnostics.len);
    try t_.expectEqual(@as(usize, 1), result.haps.len);
    try t_.expect(result.haps[0].value.eql(.{ .number = 0.2 }));
}

test "coerce: finite numbers pass, everything else is null" {
    try t_.expectEqual([4]f32{ 0.5, 0, 0, 0 }, coerce(.{ .number = 0.5 }).?);
    try t_.expectEqual([4]f32{ 3, 0, 0, 0 }, coerce(.{ .integer_i64 = 3 }).?);
    try t_.expectEqual([4]f32{ 7, 0, 0, 0 }, coerce(.{ .integer_u64 = 7 }).?);
    try t_.expectEqual(@as(?[4]f32, null), coerce(.{ .number = std.math.inf(f64) }));
    try t_.expectEqual(@as(?[4]f32, null), coerce(.{ .number = std.math.nan(f64) }));
    try t_.expectEqual(@as(?[4]f32, null), coerce(.{ .symbol = "bd" }));
    try t_.expectEqual(@as(?[4]f32, null), coerce(.{ .string = "x" }));
    try t_.expectEqual(@as(?[4]f32, null), coerce(.{ .keyword = "k" }));
    try t_.expectEqual(@as(?[4]f32, null), coerce(.{ .boolean = true }));
    try t_.expectEqual(@as(?[4]f32, null), coerce(.nil));
}
