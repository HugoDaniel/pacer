//! pacer — deterministic animation driver conducted by an SJON score.
//!
//! The driver is a pure function of time: a host samples its master clock
//! (audio when playing, `performance.now()` otherwise), passes one f64
//! seconds value in, and receives a packed `(target, value)` write buffer
//! out. It never reads a clock, never owns a loop, never touches the GPU
//! or the audio graph — visual targets are routed by name through
//! pngine's uniform reflection table, audio targets through the audio
//! engine's param registry, both joined once at load.
//!
//! Memory model follows SJON's (see SJON `src/root.zig`): every public
//! entry point takes `gpa: std.mem.Allocator` and returns an owned struct
//! with arena-backed `.deinit()`; the struct never retains the caller's
//! GPA. Time follows SJON's `Pattern` tick core: `i64` ticks on the
//! `PPC = 720720` grid, overflow as diagnostics, floor-division cycle
//! math. Determinism claim: same document + same f64 time → byte-identical
//! write buffer, native and wasm32.

const std = @import("std");
const sjon = @import("sjon");

/// Package version. Mirrors `build.zig.zon`.
pub const version = "0.2.0";

/// The pacer score schema, preloaded once per host and borrowed by every
/// compile — the outermost ring of the lifetime nesting.
pub const Schema = @import("Schema.zig");
/// `'PACT'` target-registry codec leaf: std-only encode/decode of the
/// host→driver target join, shared by `Abi` and (later) the binary runtime.
pub const PactCodec = @import("PactCodec.zig");
/// `'PACB'` compiled-score container: data-at-rest format constants,
/// header/directory validation, caps and the worst-case sizer (Phase 2
/// subgroup T2.1). Section payload decoding is not exposed yet — see the
/// module header for the interim boundary.
pub const Pacb = @import("Pacb.zig");
/// Score compiler: preloaded schema → `sjon.validateDocument` → the
/// compiled `TrackTable` (targets joined, ticks converted, programs
/// deduped), with pacer's own wire-stable diagnostic codes.
pub const Compile = @import("Compile.zig");
/// Transport math: bpm/meter ↔ ticks/beats/seconds; the one documented
/// mul+floor f64 seam.
pub const TimeMap = @import("TimeMap.zig");
/// Easing programs: flat compiled stage tables (seq/chain/primitives),
/// deterministic by construction (`sjon.trig` kernels + fixed-count
/// bezier bisection).
pub const Easing = @import("Easing.zig");
/// Compiled score representation the frame path walks (tracks, keys in
/// ticks, deduped easing programs).
pub const TrackTable = @import("TrackTable.zig");
/// Per-frame evaluator: seconds → ticks → packed write entries.
pub const Eval = @import("Eval.zig");
/// The compile-result + evaluator pair with the borrow-whole lifetime
/// encoded as structure (in-place init, ordered teardown).
pub const Driver = @import("Driver.zig");
/// Expr-track evaluation shared by `Compile` (t=0 dry-run) and `Eval`
/// (frame path): the time env contract + result coercion.
pub const ExprTrack = @import("ExprTrack.zig");
/// Pattern-track evaluation shared by `Compile` (cycle dry-run) and
/// `Eval` (frame path): the cycle↔bar window + payload coercion.
pub const PatternTrack = @import("PatternTrack.zig");
/// Packed write-buffer wire format (`'PACW'` header + 20-byte entries).
pub const Writes = @import("Writes.zig");
/// WASM boundary blobs: `'PACT'` target-registry list in, `'PACD'`
/// diagnostics out in score coordinates (`'PACW'` writes live in `Writes`).
pub const Abi = @import("Abi.zig");

test {
    _ = Schema;
    _ = PactCodec;
    _ = Pacb;
    _ = Compile;
    _ = TimeMap;
    _ = Easing;
    _ = TrackTable;
    _ = Eval;
    _ = Driver;
    _ = ExprTrack;
    _ = PatternTrack;
    _ = Writes;
    _ = Abi;
    // Not part of the `pacer` module — the corpus runner is its own
    // executable root — but its harness vocabulary earns the same
    // discovery as everything else.
    _ = @import("corpus_runner.zig");
}

test "sjon dependency wiring: tick grid + trig kernels reachable" {
    // The two SJON surfaces pacer is built on: the Pattern tick core and
    // the deterministic math kernels. Reaching both through the module
    // proves the path dep + re-exports are wired.
    try std.testing.expectEqual(@as(i64, 0), @rem(sjon.Pattern.PPC, 16));
    try std.testing.expectEqual(@as(f64, 1.0), sjon.trig.exp64(0.0));
}

test "sjon PatternQuery reachable: a fastcat literal subdivides one cycle" {
    // 03 Phase 0 feasibility spike — pacer will drive `:pattern` tracks by
    // consuming SJON's deterministic pattern engine (`query(window) ->
    // [Hap]`). Prove that surface links and runs through the path dep (built
    // `plugin-exec = false`): parse a pattern, query one cycle, read the
    // haps. `[bd hh sn cp]` is a fastcat — four bare-symbol `pure`s tiling
    // one cycle left to right. One pattern cycle maps to one bar because
    // `Pattern.PPC` IS pacer's per-bar tick count, so the four haps land on
    // exact quarter-bar boundaries via integer tick math (no f64) — the
    // determinism `:pattern` inherits for free.
    const gpa = std.testing.allocator;
    const PQ = sjon.PatternQuery;
    const PPC = sjon.Pattern.PPC;

    var tree = try sjon.parse(gpa, "[bd hh sn cp]");
    defer tree.deinit();

    // Empty schema: a pure-literal pattern has no `(pure <form>)` expression
    // leaf, so the per-hap `Expr` dry-run never consults it.
    var result = try PQ.queryTree(
        gpa,
        &tree,
        tree.root[0],
        sjon.Schema.Schema.init(&.{}),
        PQ.Span.init(0, PPC),
        0,
    );
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 4), result.haps.len);

    // Structural landing: hap i covers [i·PPC/4, (i+1)·PPC/4] and carries the
    // i-th symbol — the query is a pure function of the tick grid.
    const names = [_][]const u8{ "bd", "hh", "sn", "cp" };
    const step = @divExact(PPC, 4);
    for (result.haps, 0..) |h, i| {
        try std.testing.expect(h.value.eql(.{ .symbol = names[i] }));
        try std.testing.expectEqual(@as(i64, @intCast(i)) * step, h.timing.part.begin);
        try std.testing.expectEqual(@as(i64, @intCast(i + 1)) * step, h.timing.part.end);
    }
}

test "Pacb: the frozen PACM worst-case term restates Abi.metaWorstCase" {
    // `Pacb` must never import `Abi` (the decoder side cannot drag the
    // compiler in), so its PACM term is a frozen copy. Root can import both
    // without a cycle: this is the equality gate the copy depends on.
    inline for ([_]usize{ 0, 1, 16, 64, 256 }) |str_allowance| {
        try std.testing.expectEqual(
            Abi.metaWorstCase(str_allowance),
            Pacb.pacmWorstCase(str_allowance),
        );
    }
}

test "Pacb: frozen cap and header copies match their source definitions" {
    try std.testing.expectEqual(
        @as(usize, PactCodec.MAX_TARGETS),
        Pacb.MAX_TARGETS,
    );
    try std.testing.expectEqual(
        PactCodec.TARGETS_HEADER_LEN,
        Pacb.PACT_HEADER_LEN,
    );
    try std.testing.expectEqual(
        @as(usize, TrackTable.MAX_TRACKS),
        Pacb.MAX_TRACKS,
    );
    try std.testing.expectEqual(
        @as(usize, TrackTable.MAX_KEYS),
        Pacb.MAX_KEYS,
    );
    try std.testing.expectEqual(
        @as(usize, TrackTable.MAX_EASE_PROGRAMS),
        Pacb.MAX_EASE_PROGRAMS,
    );
    try std.testing.expectEqual(
        @as(usize, TrackTable.MAX_CONTROLS),
        Pacb.MAX_CONTROLS,
    );
    try std.testing.expectEqual(
        @as(usize, TrackTable.MAX_SCENES),
        Pacb.MAX_SCENES,
    );
    try std.testing.expectEqual(
        @as(usize, TrackTable.MAX_TEMPO_SEGMENTS),
        Pacb.MAX_TEMPO_SEGMENTS,
    );
    try std.testing.expectEqual(
        @as(usize, @typeInfo(TrackTable.EmitName).@"enum".fields.len),
        Pacb.EMIT_LANE_CAP,
    );
}

test "Pacb: frozen record ordinals match their source definitions" {
    // The wire `source` ordinals are frozen copies of 'PACM''s
    // MetaTrackRec values (`Abi.TrackSourceKind`), and `trig_kind`
    // mirrors `TrackTable.Trigger`'s tag order — copies because `Pacb`
    // must never import `Abi`. Root imports both sides with no cycle:
    // this is the equality gate the copies depend on.
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(Abi.TrackSourceKind.keys)),
        Pacb.SOURCE_KEYS,
    );
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(Abi.TrackSourceKind.expr)),
        Pacb.SOURCE_EXPR,
    );
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(Abi.TrackSourceKind.trigger)),
        Pacb.SOURCE_TRIGGER,
    );
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(Abi.TrackSourceKind.pattern)),
        Pacb.SOURCE_PATTERN,
    );
    const TrigTag = @typeInfo(TrackTable.Trigger).@"union".tag_type.?;
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(TrigTag.periodic)),
        Pacb.TRIG_PERIODIC,
    );
    try std.testing.expectEqual(
        @as(u8, @intFromEnum(TrigTag.at)),
        Pacb.TRIG_EXPLICIT,
    );
    // 'EMIT' name ordinals decode straight into `TrackTable.EmitName`
    // (no copy); the wire order is the enum's own: beat=0 … t=4.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TrackTable.EmitName.beat));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(TrackTable.EmitName.t));
}

test "Pacb: frozen reserved-name copy matches ExprTrack.reserved_names" {
    // `Pacb` refuses 'STRS' entries that shadow a time-env binding name
    // but must not import `ExprTrack` (the decoder's closure), so the
    // reserved set is a frozen copy. Root imports both sides with no
    // cycle: this is the equality gate the copy depends on.
    try std.testing.expectEqual(
        @as(usize, ExprTrack.reserved_names.len),
        Pacb.reserved_control_names.len,
    );
    for (ExprTrack.reserved_names, Pacb.reserved_control_names) |src, copy| {
        try std.testing.expectEqualStrings(src, copy);
    }
}
