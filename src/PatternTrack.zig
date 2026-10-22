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

/// The binary query entry's error set: `PatternQuery.BinaryError` — the
/// engine's own error set plus the cursor's wire classes and
/// `MultipleRoots`. A decode-validated single-root payload cannot reach
/// the latter two through the production loader (01's structural walk is
/// the preceding proof), but on any input they propagate rather than
/// trap — `ExprTrack.evalAtBinary`'s totality doctrine, pattern side.
pub const BinaryError = PatternQuery.BinaryError;

/// Query the enclosing cycle of `tick` over a compact single-root
/// pattern payload — the binary parallel of `queryCycle` (02:345, P4).
/// The SAME `cycleWindowOf` window, the SAME `SEED`, the SAME
/// result contract (`sampleAt`/`coerce` stay shared — no second pattern
/// interpreter), routed through SJON's delivered env-carrying binary
/// entry `queryBinaryWithEnv`: the ENTRY selects eval semantics, so a
/// `(pure <form>)` leaf is captured, dry-run at cycle 0, and evaluated
/// per cycle under the pattern-locals (`cycle`/`tick`/`seed` shadow the
/// outer env's same-named bindings). `outer_env` is pacer's evaluation
/// scope (`ExprTrack.buildEnv` at this tick — time names + live control
/// values), chained UNDER the pattern-locals exactly as the tree arm
/// does; the legacy frozen `queryBinary`/`queryBinaryWithBudget` (a
/// `(pure …)` leaf is silence there) are never adopted.
///
/// Dated note (2026-10-22, ask30/M4 adoption): the runtime's frame and
/// dry-run seams no longer call this per query — they query the
/// prepared state (`materializePrepared` + `queryCyclePrepared`), so a
/// payload decodes once per loaded track instead of once per frame.
/// This entry remains the delivered SJON one-shot semantics, unchanged
/// and pinned by the tests below (the prepared twin's oracle).
///
/// `schema` must carry the core vocabulary the payload's expr leaves
/// evaluate under — the runtime's frozen core ⊕ pattern aggregate.
///
/// Ownership is the delivered SJON retention semantics, unchanged: the
/// returned `Result` owns its arena — deinit it. When the pattern
/// carries expr leaves, the engine retains a layout-identical copy of
/// `payload` INSIDE the result (one cursor over the copy), so the result
/// is self-contained — the caller's bytes and env may be freed after the
/// call; no retained cursor escapes into pacer. Collection over abort:
/// static leaf defects surface as `result.diagnostics` (the leaf
/// degrades to silence), later-cycle eval failures as `result.dropped`
/// — the tree path's three disjoint channels, binary side.
pub fn queryCycleBinary(
    gpa: std.mem.Allocator,
    schema: RtSjon.Schema.Schema,
    payload: []const u8,
    tick: Tick,
    outer_env: ?*const RtSjon.Expr.Env,
) BinaryError!PatternQuery.Result {
    const window = try cycleWindowOf(tick);
    return PatternQuery.queryBinaryWithEnv(gpa, payload, schema, window, SEED, outer_env);
}

/// Materialize one compact single-root pattern payload into an owned,
/// self-contained prepared state — the ask30/M4 named delta (SJON ask
/// 30 §H, adopted 2026-10-22): ONE read-only tree decode per loaded
/// pattern track, at load, through the audited `RtSjon.BinaryDecoder`
/// window (`BinaryDecoder.fromBinary`, data construction via
/// `Ast.TreeBuilder` — never a compiler), then the shipped binary
/// compile's root discipline (`PreparedBinary.fromTree`).
///
/// Allocation: the decoded tree is O(payload) ONCE per load, OUTSIDE
/// the semantic 1 MiB scratch — never charged to any query budget —
/// and the caller backs it with an allocator that owns it for the
/// score's whole lifetime (the runtime hands the score's own arena, so
/// the state dies with the score's one free; a prepare error frees the
/// decode's partial state internally on the `fromTree` error path).
/// The caller's bytes may be freed once this returns: the tree owns
/// its strings.
///
/// Errors: `BinaryDecoder`'s typed wire set plus `error.MultipleRoots`.
/// Through the production loader every variant is unreachable — 01's
/// structural walk is the preceding proof (same 1024 depth cap, pool
/// capped at `Cursor.init`, single root, exact-end consumption) — but
/// on any input they propagate rather than trap (the totality
/// doctrine), and the loader maps the whole set to the
/// `payload_malformed` refusal class.
pub fn materializePrepared(
    gpa: std.mem.Allocator,
    payload: []const u8,
) (RtSjon.BinaryDecoder.Error || error{MultipleRoots})!PatternQuery.PreparedBinary {
    const tree = try RtSjon.BinaryDecoder.fromBinary(gpa, payload, .{});
    // Consumes `tree` on success AND on error — the dead local binding
    // is never touched again.
    return PatternQuery.PreparedBinary.fromTree(tree);
}

/// The prepared twin of `queryCycleBinary`: query the enclosing cycle
/// of `tick` over an already-materialized prepared state — the SAME
/// `cycleWindowOf` window, the SAME `SEED`, the SAME shared
/// `sampleAt`/`coerce` contract, forwarded to SJON's delivered
/// `queryPreparedBinaryWithEnv` (the one `queryTreeFull` body every
/// tree entry uses — the per-query metered sequence IS the tree path's,
/// over a logically equal tree; ask 30 §A.2/A.9). The prepared state is
/// read-only at query and shared across frames; every query classifies
/// under the call's OWN env (`outer_env` forwarded live, never
/// inspected or cached by prepare) — control-dependent classification
/// is recomputed per query, the tree arm's exact freshness contract.
///
/// Error set: `PatternQuery.Error` — the decode leg already happened at
/// prepare, so the wire classes and `MultipleRoots` cannot arise here.
/// The returned `Result` owns its arena — deinit it (the owning
/// contract, unchanged).
pub fn queryCyclePrepared(
    gpa: std.mem.Allocator,
    schema: RtSjon.Schema.Schema,
    prepared: *const PatternQuery.PreparedBinary,
    tick: Tick,
    outer_env: ?*const RtSjon.Expr.Env,
) Error!PatternQuery.Result {
    const window = try cycleWindowOf(tick);
    return PatternQuery.queryPreparedBinaryWithEnv(gpa, prepared, schema, window, SEED, outer_env);
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

// ---------------------------------------------------------------------------
// P4 — `queryCycleBinary`: the binary arm of the same query. Payloads
// come from `sjon.parse` + `Binary.toBinary` (write side, indented
// test-only imports — never closure); the schema is the runtime's frozen
// core ⊕ pattern aggregate.
// ---------------------------------------------------------------------------

const t_bin = std.testing;

const rt_plugins = [_]RtSjon.Plugin.Plugin{ RtSjon.plugins.core.plugin, RtSjon.plugins.pattern.plugin };
const rt_schema: RtSjon.Schema.Schema = .{ .plugins = &rt_plugins };

/// Parse `src` and compact-encode it to a single-root payload (the test
/// twin of what a pack payload carries).
fn binaryPayload(gpa: std.mem.Allocator, src: [:0]const u8) ![]u8 {
    const sjon = @import("sjon"); // write side (parse + encode): indented test-only
    var tree = try sjon.parse(gpa, src);
    defer tree.deinit();
    try t_bin.expectEqual(@as(usize, 1), tree.root.len);
    const bin = try sjon.Binary.toBinary(gpa, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    return gpa.dupe(u8, bin.data);
}

test "queryCycleBinary: the window is the tick's enclosing cycle (slowcat alternation), tree ≡ binary" {
    const gpa = t_bin.allocator;
    const payload = try binaryPayload(gpa, "(slowcat 0.1 0.2)");
    defer gpa.free(payload);

    // Cycle 1 returns the SECOND child — the same window derivation as
    // the tree arm's test, through the binary entry.
    var result = try queryCycleBinary(gpa, rt_schema, payload, Pattern.PPC + 1, null);
    defer result.deinit();
    try t_bin.expectEqual(@as(usize, 0), result.diagnostics.len);
    try t_bin.expectEqual(@as(usize, 1), result.haps.len);
    try t_bin.expect(result.haps[0].value.eql(.{ .number = 0.2 }));

    // Tree ≡ binary over the SAME pattern source: identical hap count
    // and values (the delivered equivalence, pinned through pacer's
    // entries).
    const sjon = @import("sjon"); // write side (parse): indented test-only
    var tree = try sjon.parse(gpa, "(slowcat 0.1 0.2)");
    defer tree.deinit();
    var tree_result = try queryCycle(gpa, &tree, rt_schema, tree.root[0], Pattern.PPC + 1, null);
    defer tree_result.deinit();
    try t_bin.expectEqual(tree_result.haps.len, result.haps.len);
    for (tree_result.haps, result.haps) |th, bh| try t_bin.expect(th.value.eql(bh.value));
}

test "queryCycleBinary: pacer env threads under the pattern-locals — shadow rule preserved" {
    // `(stack (pure (* base 2)) (pure (+ tick 0)))` with an outer env
    // carrying `base = 3` AND a decoy `tick = 999`: the hap values are
    // {6, 0} — the outer `base` resolves through the parent scope while
    // the pattern-local `tick` (the cycle onset, 0 in cycle 0) SHADOWS
    // the outer decoy — the frozen rule, binary side.
    const gpa = t_bin.allocator;
    const payload = try binaryPayload(gpa, "(stack (pure (* base 2)) (pure (+ tick 0)))");
    defer gpa.free(payload);

    const bindings = [_]RtSjon.Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 3 } },
        .{ .name = "tick", .value = .{ .number = 999 } },
    };
    const outer: RtSjon.Expr.Env = .{ .bindings = &bindings };

    var result = try queryCycleBinary(gpa, rt_schema, payload, 0, &outer);
    defer result.deinit();
    try t_bin.expectEqual(@as(usize, 0), result.diagnostics.len);
    try t_bin.expectEqual(@as(usize, 0), result.dropped);
    try t_bin.expectEqual(@as(usize, 2), result.haps.len);
    var saw_six = false;
    var saw_zero = false;
    for (result.haps) |h| {
        if (h.value.eql(.{ .number = 6 })) saw_six = true; // base × 2 through the parent scope
        if (h.value.eql(.{ .number = 0 })) saw_zero = true; // the SHADOW won, not 999
    }
    try t_bin.expect(saw_six);
    try t_bin.expect(saw_zero);
}

// ---------------------------------------------------------------------------
// ask30/M4 (2026-10-22) — the prepared twin: materializePrepared +
// queryCyclePrepared. Unit pins for the adoption's new seams; the
// loader-level acceptance lives in rt_entry (r)/(s)/(t).
// ---------------------------------------------------------------------------

test "queryCyclePrepared: the prepared twin answers like the one-shot — window, shadow, env freshness" {
    const gpa = t_bin.allocator;

    // Window: cycle 1 returns the SECOND slowcat child through the
    // prepared state.
    {
        const payload = try binaryPayload(gpa, "(slowcat 0.1 0.2)");
        defer gpa.free(payload);
        var prepared = try materializePrepared(gpa, payload);
        defer prepared.deinit();
        var result = try queryCyclePrepared(gpa, rt_schema, &prepared, Pattern.PPC + 1, null);
        defer result.deinit();
        try t_bin.expectEqual(@as(usize, 0), result.diagnostics.len);
        try t_bin.expectEqual(@as(usize, 1), result.haps.len);
        try t_bin.expect(result.haps[0].value.eql(.{ .number = 0.2 }));
    }

    // Shadow + env FRESHNESS: the SAME prepared object under three
    // different live envs answers each differently — classification is
    // per query, never cached at prepare.
    const payload = try binaryPayload(gpa, "(stack (pure (* base 2)) (pure (+ tick 0)))");
    defer gpa.free(payload);
    var prepared = try materializePrepared(gpa, payload);
    defer prepared.deinit();
    const base3 = [_]RtSjon.Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 3 } },
        .{ .name = "tick", .value = .{ .number = 999 } },
    };
    const base5 = [_]RtSjon.Expr.Env.Binding{
        .{ .name = "base", .value = .{ .number = 5 } },
        .{ .name = "tick", .value = .{ .number = 999 } },
    };
    const env3: RtSjon.Expr.Env = .{ .bindings = &base3 };
    const env5: RtSjon.Expr.Env = .{ .bindings = &base5 };

    var r3 = try queryCyclePrepared(gpa, rt_schema, &prepared, 0, &env3);
    defer r3.deinit();
    try t_bin.expectEqual(@as(usize, 2), r3.haps.len);
    var saw_six = false;
    var saw_zero = false;
    for (r3.haps) |h| {
        if (h.value.eql(.{ .number = 6 })) saw_six = true;
        if (h.value.eql(.{ .number = 0 })) saw_zero = true; // the shadow won, not 999
    }
    try t_bin.expect(saw_six and saw_zero);

    // One-shot equivalence over the SAME payload and env.
    var r_one = try queryCycleBinary(gpa, rt_schema, payload, 0, &env3);
    defer r_one.deinit();
    try t_bin.expectEqual(r_one.haps.len, r3.haps.len);
    for (r_one.haps, r3.haps) |oh, ph| try t_bin.expect(oh.value.eql(ph.value));

    // Fresh env: base 5 → {10, 0} from the SAME prepared object.
    var r5 = try queryCyclePrepared(gpa, rt_schema, &prepared, 0, &env5);
    defer r5.deinit();
    var saw_ten = false;
    for (r5.haps) |h| {
        if (h.value.eql(.{ .number = 10 })) saw_ten = true;
    }
    try t_bin.expect(saw_ten);

    // Null env: `base` is unbound — that leaf's capture fails into the
    // diagnostics channel (degrade to silence), while the tick-local
    // leaf still plays: one hap (the shadow's 0), at least one
    // diagnostic, never an error.
    var r_null = try queryCyclePrepared(gpa, rt_schema, &prepared, 0, null);
    defer r_null.deinit();
    try t_bin.expect(r_null.diagnostics.len > 0);
    try t_bin.expectEqual(@as(usize, 1), r_null.haps.len);
    try t_bin.expect(r_null.haps[0].value.eql(.{ .number = 0 }));
}

test "materializePrepared: a malformed payload refuses with the typed wire error" {
    const gpa = t_bin.allocator;
    const payload = try binaryPayload(gpa, "(slowcat 0.1 0.2)");
    defer gpa.free(payload);
    const corrupted = try gpa.dupe(u8, payload);
    defer gpa.free(corrupted);
    corrupted[0] ^= 0xFF; // bad magic
    try t_bin.expectError(error.InvalidMagic, materializePrepared(gpa, corrupted));
}

test "materializePrepared: a multi-root payload refuses MultipleRoots (typed; unreachable through the loader)" {
    const sjon = @import("sjon"); // write side (parse + encode): indented test-only
    const gpa = t_bin.allocator;
    var tree = try sjon.parse(gpa, "1 2");
    defer tree.deinit();
    const bin = try sjon.Binary.toBinary(gpa, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    try t_bin.expectError(error.MultipleRoots, materializePrepared(gpa, bin.data));
}

test "materializePrepared: a zero-root payload prepares silent (the prepared entry's own specified behavior)" {
    const gpa = t_bin.allocator;
    // Hand-wired wire: header, empty pool at 16, roots at 16, count 0.
    var wire: [19]u8 = undefined;
    @memset(&wire, 0);
    @memcpy(wire[0..4], &RtSjon.BinaryDecoder.wire_magic);
    wire[4] = RtSjon.BinaryDecoder.wire_version;
    std.mem.writeInt(u32, wire[8..12], 16, .little); // pool section at 16
    std.mem.writeInt(u32, wire[12..16], 18, .little); // roots at 18
    wire[16] = 0; // pool: 0 entries
    wire[17] = 0; // pool: 0 bytes
    wire[18] = 0; // roots: count 0
    var prepared = try materializePrepared(gpa, &wire);
    defer prepared.deinit();
    try t_bin.expectEqual(@as(usize, 0), prepared.tree.root.len);
    try t_bin.expect(prepared.root == null);
    // Every query answers the silence result — no hap, no diagnostic,
    // no drop, no error.
    var result = try queryCyclePrepared(gpa, rt_schema, &prepared, 0, null);
    defer result.deinit();
    try t_bin.expectEqual(@as(usize, 0), result.haps.len);
    try t_bin.expectEqual(@as(usize, 0), result.diagnostics.len);
    try t_bin.expectEqual(@as(usize, 0), result.dropped);
}
