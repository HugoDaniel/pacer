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
/// `'PACM'` score-metadata reader: the std-only structural reading half
/// of the metadata blob (`Abi` stays the encoder and the format of
/// record) — a total decode of untrusted bytes whose views alias the
/// input, so the playback runtime's closure never drags the compiler in.
pub const Pacm = @import("Pacm.zig");
/// `'PACB'` encoder core: canonical assembly of the compiled-score
/// container from one `Compile.CompileResult` + the host target join
/// (Phase 3 T3.1). Round-trips through `Pacb.decode`.
pub const PacbEncode = @import("PacbEncode.zig");
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
/// Compiler-side facade over `EvalCore` (the SAME `Evaluator` type by
/// alias) — the public path hosts keep calling.
pub const Eval = @import("Eval.zig");
/// The frame engine, extracted: one evaluator over a tree-OR-binary
/// leaf source (`LeafSource`), constructed from an `EvalCore.Context`
/// or anything carrying `.evalContext()` (a compile result). Never
/// imports `Compile` — the runtime closure's engine leaf (02 P1).
pub const EvalCore = @import("EvalCore.zig");
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
    _ = Pacm;
    _ = PacbEncode;
    _ = Compile;
    _ = TimeMap;
    _ = Easing;
    _ = TrackTable;
    _ = Eval;
    _ = EvalCore;
    _ = Driver;
    _ = ExprTrack;
    _ = PatternTrack;
    _ = Writes;
    _ = Abi;
    // The corpus harness parser's tests have their own explicit test root
    // (`build.zig`), because it is a named std/SJON-only module. This
    // source-owning binary keeps only the frozen-copy pin below.
    // The playback runtime's entry is its own wasm root (like
    // wasm_entry, discovered here for its native export tests only).
    _ = @import("rt_entry.zig");
}

test "corpus harness: the frozen target cap equals Abi.MAX_TARGETS" {
    const CorpusHarness = @import("corpus_harness");
    try std.testing.expectEqual(@as(usize, Abi.MAX_TARGETS), CorpusHarness.MAX_TARGETS);
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

test "Pacb: frozen MAX_TREE_DEPTH copy matches the binary format's own cap" {
    // The payload walk's depth bound is a frozen copy (02 T2.1 / C1):
    // the runtime closure reaches SJON only through `RtSjon.zig`, whose
    // window carries no write-side `Binary`, so `Pacb` spells the
    // constant itself. Root imports both sides with no cycle — this is
    // the equality gate the copy depends on (the family precedent).
    try std.testing.expectEqual(
        sjon.Binary.MAX_TREE_DEPTH,
        Pacb.MAX_TREE_DEPTH,
    );
}

// ---------------------------------------------------------------------------
// Pacm — frozen-copy equality gates + the producer-oracle comparisons
// ---------------------------------------------------------------------------
//
// `Pacm` is the std-only reading half of `'PACM'`: it may never import
// `Abi` (or anything but std), so every wire constant and ordinal family
// it spells is a frozen copy, and the copies are gated HERE where both
// sides import with no cycle — the same pattern as the `Pacb` asserts
// above. The three oracle blobs under `src/testdata/pacm/` were produced
// once by the real `Abi.encodeMeta` over these fixture sources (proven
// clean in `Abi`'s own decoder tests) and are re-pinned to a fresh
// compile on every run, so `Pacm.decode` is compared against the shared
// Zig-side oracle (`Abi.decodeMeta`, plan A38) over bytes the producer
// actually emits — never over bytes a new writer generated.

const pacm_oracle_targets = [_]Compile.Target{
    .{ .name = "circle-radius", .ncomp = 1 },
    .{ .name = "tint", .ncomp = 3 },
    .{ .name = "cutoff", .ncomp = 1, .registry = 1 },
};

const pacm_oracle_keys_controls: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
    \\(track :target circle-radius
    \\  (key :at 0b :value 0.2)
    \\  (key :at 4b :value 0.8))
    \\(track :target tint :expr [1 0 0])
    \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    \\(control :id sway :value 0.12)
;

const pacm_oracle_scenes_tempo_ease: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
    \\(tempo :at 8b :bpm 160)
    \\(scene :name drop :at 2bar :dur 2bar
    \\  (track :target circle-radius
    \\    (key :at 0b :value 30)
    \\    (key :at 4b :value 140 :ease (steps :n 8))))
;

const pacm_oracle_minimal: [:0]const u8 =
    \\(transport :bpm 120)
    \\(control :id sway :value 0.12)
;

/// Field-for-field equality between the two decoders' views over the
/// SAME bytes — the shared-oracle comparison (plan A38). Enum-typed
/// fields are compared through their wire ordinals because the two
/// modules spell independent (frozen-copy) enum types.
fn pacmExpectSameView(want: *const Abi.MetaView, got: *const Pacm.MetaView) !void {
    const t_ = std.testing;
    try t_.expectEqual(want.bpm, got.bpm);
    try t_.expectEqual(want.dur, got.dur);
    try t_.expectEqual(want.end_loop, got.end_loop);
    try t_.expectEqual(want.beats_per_bar, got.beats_per_bar);
    try t_.expectEqual(@as(usize, want.track_count), got.trackCount());
    try t_.expectEqual(@as(usize, want.key_count), got.keyCount());
    try t_.expectEqual(@as(usize, want.control_count), got.controlCount());

    for (0..want.track_count) |i| {
        const w = want.track(i);
        const g = got.track(i);
        try t_.expectEqual(w.target_id, g.target_id);
        try t_.expectEqual(w.registry, g.registry);
        try t_.expectEqual(w.ncomp, g.ncomp);
        try t_.expectEqual(@intFromEnum(w.source), @intFromEnum(g.source));
        try t_.expectEqual(w.key_start, g.key_start);
        try t_.expectEqual(w.key_len, g.key_len);
        try t_.expectEqual(w.span.start, g.span.start);
        try t_.expectEqual(w.span.end, g.span.end);
    }
    for (0..want.key_count) |i| {
        const w = want.key(i);
        const g = got.key(i);
        try t_.expectEqual(w.at, g.at);
        try t_.expectEqual(w.value, g.value);
        try t_.expectEqual(w.span.start, g.span.start);
        try t_.expectEqual(w.span.end, g.span.end);
    }
    var w_ctl = want.controls();
    var g_ctl = got.controls();
    while (true) {
        const w = w_ctl.next();
        const g = g_ctl.next();
        try t_.expectEqual(w != null, g != null);
        if (w == null) break;
        try t_.expectEqual(w.?.target_id, g.?.target_id);
        try t_.expectEqual(w.?.registry, g.?.registry);
        try t_.expectEqual(w.?.ncomp, g.?.ncomp);
        try t_.expectEqual(@intFromEnum(w.?.kind), @intFromEnum(g.?.kind));
        try t_.expectEqual(w.?.value, g.?.value);
        try t_.expectEqual(w.?.min, g.?.min);
        try t_.expectEqual(w.?.max, g.?.max);
        try t_.expectEqualStrings(w.?.id, g.?.id);
        try t_.expectEqual(w.?.value_span.start, g.?.value_span.start);
        try t_.expectEqual(w.?.value_span.end, g.?.value_span.end);
    }

    try t_.expectEqual(want.sceneCount(), got.sceneCount());
    for (0..want.sceneCount()) |i| {
        const w = want.scene(i);
        const g = got.scene(i);
        try t_.expectEqual(w.start_tick, g.start_tick);
        try t_.expectEqual(w.dur_ticks, g.dur_ticks);
        try t_.expectEqual(w.name_span.start, g.name_span.start);
        try t_.expectEqual(w.name_span.end, g.name_span.end);
    }
    try t_.expectEqual(want.tempoCount(), got.tempoCount());
    for (0..want.tempoCount()) |i| {
        const w = want.tempoSeg(i);
        const g = got.tempoSeg(i);
        try t_.expectEqual(w.tick, g.tick);
        try t_.expectEqual(w.bpm, g.bpm);
    }
    try t_.expectEqual(want.easeProgramCount(), got.easeProgramCount());
    for (0..want.easeProgramCount()) |i| {
        const w = want.easeProgram(i);
        const g = got.easeProgram(i);
        try t_.expectEqual(w.len, g.len);
        for (0..Easing.MAX_STAGES) |s| {
            try t_.expectEqual(w.stages[s].t_end, g.stages[s].t_end);
            try t_.expectEqual(w.stages[s].v_base, g.stages[s].v_base);
            try t_.expectEqual(w.stages[s].v_span, g.stages[s].v_span);
            try t_.expectEqual(w.stages[s].ops_len, g.stages[s].ops_len);
            for (0..Easing.MAX_OPS) |o| {
                try t_.expectEqual(@intFromEnum(w.stages[s].ops[o].code), g.stages[s].ops[o].code);
                try t_.expectEqual(w.stages[s].ops[o].params, g.stages[s].ops[o].params);
            }
        }
    }
    try t_.expectEqual(want.easeRefCount(), got.easeRefCount());
    for (0..want.easeRefCount()) |i| try t_.expectEqual(want.easeRef(i), got.easeRef(i));
}

test "Pacm: frozen wire constants match Abi's definitions" {
    const t_ = std.testing;
    try t_.expectEqual(Abi.META_MAGIC, Pacm.META_MAGIC);
    try t_.expectEqual(Abi.META_VERSION, Pacm.META_VERSION);
    try t_.expectEqual(Abi.META_HEADER_LEN, Pacm.META_HEADER_LEN);
    try t_.expectEqual(Abi.META_TRACK_LEN, Pacm.META_TRACK_LEN);
    try t_.expectEqual(Abi.META_KEY_LEN, Pacm.META_KEY_LEN);
    try t_.expectEqual(Abi.META_CONTROL_LEN, Pacm.META_CONTROL_LEN);
    try t_.expectEqual(Abi.META_NO_TARGET, Pacm.META_NO_TARGET);
    try t_.expectEqual(Abi.META_SECTION_HEADER_LEN, Pacm.META_SECTION_HEADER_LEN);
    try t_.expectEqual(Abi.SCENES_SECTION_ID, Pacm.SCENES_SECTION_ID);
    try t_.expectEqual(Abi.SCENE_REC_LEN, Pacm.SCENE_REC_LEN);
    try t_.expectEqual(Abi.EASE_SECTION_ID, Pacm.EASE_SECTION_ID);
    try t_.expectEqual(Abi.TEMPO_SECTION_ID, Pacm.TEMPO_SECTION_ID);
    try t_.expectEqual(Abi.TEMPO_REC_LEN, Pacm.TEMPO_REC_LEN);
    try t_.expectEqual(Abi.META_EASE_OP_LEN, Pacm.META_EASE_OP_LEN);
    try t_.expectEqual(Abi.META_EASE_STAGE_LEN, Pacm.META_EASE_STAGE_LEN);
    try t_.expectEqual(Abi.META_EASE_PROGRAM_LEN, Pacm.META_EASE_PROGRAM_LEN);
}

test "Pacm: frozen ordinal families match their source enums" {
    const t_ = std.testing;
    const pairs = .{
        .{ @typeInfo(Pacm.TrackSource), @typeInfo(Abi.TrackSourceKind) },
        .{ @typeInfo(Pacm.ControlKind), @typeInfo(TrackTable.ControlType) },
    };
    inline for (pairs) |pair| {
        const p = pair[0].@"enum".fields;
        const a = pair[1].@"enum".fields;
        try t_.expectEqual(a.len, p.len);
        inline for (a, p) |src, copy| try t_.expectEqual(src.value, copy.value);
    }
    try t_.expectEqual(
        @as(u8, @intCast(@typeInfo(Easing.Op).@"enum".fields.len - 1)),
        Pacm.MAX_EASE_OP,
    );
    try t_.expectEqual(@as(usize, Easing.MAX_STAGES), Pacm.EASE_STAGE_COUNT);
    try t_.expectEqual(@as(usize, Easing.MAX_OPS), Pacm.EASE_OPS_PER_STAGE);
}

test "Pacm: the frozen oracle blobs are the real producer's bytes" {
    // Re-derives every frozen blob from a fresh compile through the real
    // `Abi.encodeMeta` — the files under `src/testdata/pacm/` can never
    // drift from the producer (or hide a hand-typo) without failing here.
    const test_support = @import("test_support.zig");
    const t_ = std.testing;
    const cases = [_]struct { source: [:0]const u8, bytes: []const u8 }{
        .{ .source = pacm_oracle_keys_controls, .bytes = @embedFile("testdata/pacm/keys-controls.pacm") },
        .{ .source = pacm_oracle_scenes_tempo_ease, .bytes = @embedFile("testdata/pacm/scenes-tempo-ease.pacm") },
        .{ .source = pacm_oracle_minimal, .bytes = @embedFile("testdata/pacm/minimal.pacm") },
    };
    for (cases) |c| {
        var r = try Compile.compile(t_.allocator, test_support.schema(), c.source, &pacm_oracle_targets);
        defer r.deinit();
        try t_.expect(r.ok());
        const blob = try t_.allocator.alloc(u8, Abi.metaEncodedLen(&r));
        defer t_.allocator.free(blob);
        _ = try Abi.encodeMeta(&r, blob);
        try t_.expectEqualSlices(u8, c.bytes, blob);
    }
}

test "Pacm: keys-controls oracle decodes field-for-field like Abi.decodeMeta" {
    const t_ = std.testing;
    const blob = @embedFile("testdata/pacm/keys-controls.pacm");
    const want = Abi.decodeMeta(blob) orelse return error.TestExpectedDecode;
    const got = Pacm.decode(blob) orelse return error.TestExpectedDecode;
    try pacmExpectSameView(&want, &got);

    // Own literals, not just the relative comparison: the transport, the
    // per-source key-range spellings, and the commit anchors.
    try t_.expectEqual(@as(f64, 120), got.bpm);
    try t_.expectEqual(@as(?i64, 2 * sjon.Pattern.PPC), got.dur);
    try t_.expectEqual(true, got.end_loop);
    try t_.expectEqual(@as(u16, 4), got.beats_per_bar);
    try t_.expectEqual(@as(usize, 2), got.trackCount());
    try t_.expectEqual(@as(usize, 2), got.keyCount());
    try t_.expectEqual(@as(usize, 2), got.controlCount());

    const tr0 = got.track(0);
    try t_.expectEqual(Pacm.TrackSource.keys, tr0.source);
    try t_.expectEqual(@as(u32, 0), tr0.key_start);
    try t_.expectEqual(@as(u32, 2), tr0.key_len);
    try t_.expectEqualStrings("(track", pacm_oracle_keys_controls[tr0.span.start..][0..6]);
    const tr1 = got.track(1);
    try t_.expectEqual(Pacm.TrackSource.expr, tr1.source);
    try t_.expectEqual(@as(u32, 0), tr1.key_start);
    try t_.expectEqual(@as(u32, 0), tr1.key_len);

    const k1 = got.key(1);
    try t_.expectEqual(@as(i64, sjon.Pattern.PPC), k1.at);
    try t_.expectEqual(@as(f32, 0.8), k1.value[0]);
    try t_.expectEqualStrings("(key :at 4b :value 0.8)", pacm_oracle_keys_controls[k1.span.start..k1.span.end]);

    var it = got.controls();
    const knob = it.next().?;
    try t_.expectEqualStrings("knob", knob.id);
    try t_.expectEqual(@as(u16, 0), knob.target_id.?);
    try t_.expectEqual(Pacm.ControlKind.slider, knob.kind);
    try t_.expectEqual(@as(f32, 0.4), knob.value[0]);
    try t_.expectEqual(@as(?[4]f32, .{ 0, 0, 0, 0 }), knob.min);
    try t_.expectEqual(@as(?[4]f32, .{ 1, 0, 0, 0 }), knob.max);
    try t_.expectEqualStrings("0.4", pacm_oracle_keys_controls[knob.value_span.start..knob.value_span.end]);
    const sway = it.next().?;
    try t_.expectEqual(@as(?u16, null), sway.target_id);
    try t_.expectEqual(@as(f32, 0.12), sway.value[0]);
    try t_.expectEqual(@as(?[4]f32, null), sway.min);

    // No scenes / no authored easing / constant tempo ⇒ no sections.
    try t_.expectEqual(@as(usize, 0), got.sceneCount());
    try t_.expectEqual(@as(usize, 0), got.tempoCount());
    try t_.expectEqual(@as(usize, 0), got.easeProgramCount());
    try t_.expectEqual(@as(usize, 0), got.easeRefCount());
}

test "Pacm: scenes-tempo-ease oracle decodes field-for-field like Abi.decodeMeta" {
    const t_ = std.testing;
    const blob = @embedFile("testdata/pacm/scenes-tempo-ease.pacm");
    const want = Abi.decodeMeta(blob) orelse return error.TestExpectedDecode;
    const got = Pacm.decode(blob) orelse return error.TestExpectedDecode;
    try pacmExpectSameView(&want, &got);

    try t_.expectEqual(@as(?i64, 8 * sjon.Pattern.PPC), got.dur);
    try t_.expectEqual(@as(usize, 1), got.sceneCount());
    const scene = got.scene(0);
    try t_.expectEqual(@as(i64, 2 * sjon.Pattern.PPC), scene.start_tick);
    try t_.expectEqual(@as(i64, 2 * sjon.Pattern.PPC), scene.dur_ticks);
    try t_.expectEqualStrings("drop", pacm_oracle_scenes_tempo_ease[scene.name_span.start..scene.name_span.end]);

    try t_.expectEqual(@as(usize, 2), got.tempoCount());
    const seg0 = got.tempoSeg(0);
    const seg1 = got.tempoSeg(1);
    try t_.expectEqual(@as(i64, 0), seg0.tick);
    try t_.expectEqual(@as(f64, 120), seg0.bpm);
    try t_.expectEqual(@as(i64, 2 * sjon.Pattern.PPC), seg1.tick);
    try t_.expectEqual(@as(f64, 160), seg1.bpm);

    // Default linear + the authored `(steps :n 8)` program.
    try t_.expectEqual(@as(usize, 2), got.easeProgramCount());
    const steps = got.easeProgram(1);
    try t_.expectEqual(@as(u8, 1), steps.len);
    try t_.expectEqual(@as(f32, 1), steps.stages[0].t_end);
    try t_.expectEqual(@as(u8, 1), steps.stages[0].ops_len);
    try t_.expectEqual(@as(f32, 8), steps.stages[0].ops[0].params[0]);
    try t_.expectEqual(@as(usize, 2), got.easeRefCount());
    try t_.expectEqual(@as(u16, 0), got.easeRef(0));
    try t_.expectEqual(@as(u16, 1), got.easeRef(1));

    const k1 = got.key(1);
    try t_.expectEqual(@as(f32, 140), k1.value[0]);
}

test "Pacm: minimal oracle decodes field-for-field like Abi.decodeMeta" {
    const t_ = std.testing;
    const blob = @embedFile("testdata/pacm/minimal.pacm");
    const want = Abi.decodeMeta(blob) orelse return error.TestExpectedDecode;
    const got = Pacm.decode(blob) orelse return error.TestExpectedDecode;
    try pacmExpectSameView(&want, &got);

    // Zero tracks, one env-only control, hold (no dur), no sections —
    // the smallest blob the producer can emit.
    try t_.expectEqual(@as(usize, 0), got.trackCount());
    try t_.expectEqual(@as(usize, 0), got.keyCount());
    try t_.expectEqual(@as(usize, 1), got.controlCount());
    try t_.expectEqual(@as(?i64, null), got.dur);
    try t_.expectEqual(false, got.end_loop);
    var it = got.controls();
    const sway = it.next().?;
    try t_.expectEqualStrings("sway", sway.id);
    try t_.expectEqual(@as(?u16, null), sway.target_id);
    try t_.expectEqual(@as(?[4]f32, null), sway.min);
    try t_.expectEqual(@as(usize, 0), got.sceneCount());
    try t_.expectEqual(@as(usize, 0), got.tempoCount());
    try t_.expectEqual(@as(usize, 0), got.easeProgramCount());
}
