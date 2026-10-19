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
//! `Pattern.PPC` IS pacer's per-bar tick count (`TimeMap` pins one
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
const RtSjon = @import("RtSjon.zig");
const TrackTable = @import("TrackTable.zig");

const Ast = RtSjon.Ast;
const Pattern = RtSjon.Pattern;
const PatternQuery = RtSjon.PatternQuery;

pub const Tick = TrackTable.Tick;

/// Document seed for every pattern query, pinned to 0 this slice. A
/// future `:seed` (transport- or track-level) threads through here; it
/// reaches hap value exprs as the pattern-local `seed` binding.
pub const SEED: i64 = 0;

/// Frame-path scratch budget for ONE `queryCycle` call. `Eval` fronts the
/// query with a `FixedBufferAllocator` this large (a fresh one per pattern
/// track), so the hot path never touches the gpa. It must exceed SJON's
/// own internal per-query expr scratch (`PATTERN_EXPR_SCRATCH`, 256 KiB) —
/// which `queryTree` allocates from the allocator handed in — plus the
/// compiled-`Node` + hap result arena and the transient work stacks all
/// live at once; a `FixedBufferAllocator` reclaims only LIFO, so the buffer
/// holds the call's whole high-water mark, not its peak. So 256 KiB does
/// NOT suffice (the plan's open question): the `(fast 16 (pure …))` frame
/// test measured a floor between 256 and 320 KiB. 1 MiB leaves the 256 KiB
/// SJON scratch plus room for ~a few thousand haps (~200 B each once the
/// `out` list, the result-arena dupe, and FBA fragmentation are counted) —
/// comfortably past realistic patterns (dozens–hundreds of haps/cycle),
/// allocated once per evaluator only when a pattern track is present.
///
/// It is NOT sized for a pathologically dense cycle (SJON's `MAX_HAPS` is
/// 64k, ~8 MiB of haps) — and the load-time dry-run runs under this SAME
/// budget (`Compile.dryRunPattern` fronts its query with an FBA this
/// large), so load acceptance ⊆ dry-run-cycle runtime capability: a
/// pattern whose dry-run cycle exhausts this buffer is a load diagnostic,
/// not a silent every-frame omission. The honest residual is time, not
/// resources — a pattern dense only on a cycle PAST the dry-run's can
/// still load and exhaust this buffer there. That exhaustion stays a
/// deterministic, counted omission — never a process OOM, never
/// nondeterminism — so the byte-identical claim holds; the write is
/// simply dropped.
pub const SCRATCH_BYTES: usize = 1024 * 1024;

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
/// `(pure <form>)` expr leaves. `outer_env` is pacer's evaluation scope
/// (`ExprTrack.buildEnv` at this same tick — time names + controls),
/// chained UNDER the engine's pattern-locals: inside a hap expr,
/// `cycle`/`tick`/`seed` are the pattern's own (the frozen shadow rule)
/// and every other name resolves to pacer's env. Caller-owned; must
/// outlive the call. The returned `Result` owns an arena — deinit it.
/// Collection over abort: malformed combinators surface as
/// `result.diagnostics` (the node degrades to silence), and per-hap expr
/// failures as `result.dropped` — not as errors.
pub fn queryCycle(
    gpa: std.mem.Allocator,
    tree: *const Ast.Tree,
    schema: RtSjon.Schema.Schema,
    node: Ast.NodeIndex,
    tick: Tick,
    outer_env: ?*const RtSjon.Expr.Env,
) Error!PatternQuery.Result {
    const window = try cycleWindowOf(tick);
    return PatternQuery.queryTreeWithEnv(gpa, tree, node, schema, window, SEED, outer_env);
}

/// Point-sample the queried cycle at tick `t`: the hap whose PART span
/// contains `t` (half-open `[begin, end)`, so an exact onset lands on the
/// hap STARTING there — structural, like a keyframe on its key) with the
/// LATEST onset. Overlapping haps (a `stack`) share an onset; the tie
/// breaks to the LAST in query order — a `stack` concatenates its layers
/// in child order, so the top-most declared layer wins (pinned, plan 03
/// Phase 3). No hap active at `t` → null: the write is OMITTED for the
/// frame (a gap, the expr-NaN contract). The returned value may be a
/// non-numeric `PatValue`; the caller runs it through `coerce`.
///
/// `haps` is what `queryCycle(…, t)` returned, so every hap's part sits
/// inside `t`'s enclosing cycle. Onset is the true `whole.begin` when the
/// hap carries one, else the part begin (discrete haps have `whole ==
/// part`). O(haps).
pub fn sampleAt(haps: []const PatternQuery.Hap, t: Tick) ?PatternQuery.PatValue {
    var best: ?PatternQuery.Hap = null;
    var best_onset: Tick = undefined;
    for (haps) |h| {
        const part = h.timing.part;
        // Engine Span invariant (begin ≤ end), re-asserted at the read;
        // zero-width parts are legitimate and never active at any t.
        std.debug.assert(part.begin <= part.end);
        if (t < part.begin or t >= part.end) continue; // not active at t
        const onset = if (h.timing.whole) |w| w.begin else part.begin;
        // `>=` keeps the LAST hap among equal onsets — the top stack layer.
        if (best == null or onset >= best_onset) {
            best = h;
            best_onset = onset;
        }
    }
    return if (best) |h| h.value else null;
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

const core_plugins = [_]RtSjon.Plugin.Plugin{RtSjon.plugins.core.plugin};
const core_schema: RtSjon.Schema.Schema = .{ .plugins = &core_plugins };

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
    const sjon = @import("sjon"); // write side (parse): indented test-only
    const gpa = t_.allocator;
    var tree = try sjon.parse(gpa, "(slowcat 0.1 0.2)");
    defer tree.deinit();

    var result = try queryCycle(gpa, &tree, core_schema, tree.root[0], Pattern.PPC + 1, null);
    defer result.deinit();
    try t_.expectEqual(@as(usize, 0), result.diagnostics.len);
    try t_.expectEqual(@as(usize, 1), result.haps.len);
    try t_.expect(result.haps[0].value.eql(.{ .number = 0.2 }));
}

test "sampleAt: fastcat slots land structurally, the boundary picks the later slot" {
    // `[0.1 0.2 0.3 0.4]` tiles cycle 0 into quarter-bar slots. Sampling at a
    // slot onset returns that slot (half-open), a slot boundary returns the
    // NEXT slot, and an interior tick holds its slot.
    const sjon = @import("sjon"); // write side (parse): indented test-only
    const gpa = t_.allocator;
    var tree = try sjon.parse(gpa, "[0.1 0.2 0.3 0.4]");
    defer tree.deinit();
    var result = try queryCycle(gpa, &tree, core_schema, tree.root[0], 0, null);
    defer result.deinit();

    const q = @divExact(Pattern.PPC, 4);
    try t_.expect(sampleAt(result.haps, 0).?.eql(.{ .number = 0.1 }));
    try t_.expect(sampleAt(result.haps, q - 1).?.eql(.{ .number = 0.1 })); // interior
    try t_.expect(sampleAt(result.haps, q).?.eql(.{ .number = 0.2 })); // boundary → next
    try t_.expect(sampleAt(result.haps, 2 * q).?.eql(.{ .number = 0.3 }));
    try t_.expect(sampleAt(result.haps, 3 * q).?.eql(.{ .number = 0.4 }));
    try t_.expect(sampleAt(result.haps, Pattern.PPC - 1).?.eql(.{ .number = 0.4 }));
}

test "sampleAt: a silence slot has no active hap → null" {
    const sjon = @import("sjon"); // write side (parse): indented test-only
    const gpa = t_.allocator;
    var tree = try sjon.parse(gpa, "[0.5 (silence)]");
    defer tree.deinit();
    var result = try queryCycle(gpa, &tree, core_schema, tree.root[0], 0, null);
    defer result.deinit();

    try t_.expect(sampleAt(result.haps, 0).?.eql(.{ .number = 0.5 }));
    // Second half is silent: no hap covers it.
    try t_.expectEqual(@as(?PatternQuery.PatValue, null), sampleAt(result.haps, 3 * @divExact(Pattern.PPC, 4)));
}

test "sampleAt: overlapping stack layers tie on onset → the last (top) layer wins" {
    // `(stack 0.1 0.2)` layers two full-cycle haps sharing onset 0; the tie
    // breaks to the last child in query order (the top declared layer).
    const sjon = @import("sjon"); // write side (parse): indented test-only
    const gpa = t_.allocator;
    var tree = try sjon.parse(gpa, "(stack 0.1 0.2)");
    defer tree.deinit();
    var result = try queryCycle(gpa, &tree, core_schema, tree.root[0], 0, null);
    defer result.deinit();
    try t_.expectEqual(@as(usize, 2), result.haps.len);
    try t_.expect(sampleAt(result.haps, 0).?.eql(.{ .number = 0.2 }));
    try t_.expect(sampleAt(result.haps, @divExact(Pattern.PPC, 2)).?.eql(.{ .number = 0.2 }));
}

test "sampleAt: an empty hap list is a gap → null" {
    try t_.expectEqual(@as(?PatternQuery.PatValue, null), sampleAt(&.{}, 0));
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
