//! Never-panic fuzz harnesses for pacer's byte-eating and
//! arbitrary-input entrypoints.
//!
//! Each harness generates an input (via `std.testing.fuzz` + `Smith`, or
//! the baked-in corpus on a plain `zig build fuzz`), feeds it to the
//! target, and asserts ONLY invariants that must hold for ARBITRARY
//! input — never "it compiled" or "no diagnostics", since random bytes
//! trip every diagnostic. Leaks are caught by `testing.allocator`.
//!
//! Shipped as a SEPARATE target (`zig build fuzz`) so the default
//! `zig build test` / `verify` stay fast — the SJON precedent. Each
//! harness is also a normal `test {}`, so the corpus runs on every
//! invocation even without the instrumented fuzzer.
//!
//! Invariants enforced:
//!   * `Compile.compile` over arbitrary source + a fixed registry either
//!     returns a `CompileResult` or `error.OutOfMemory`; `deinit`
//!     succeeds; when `ok()`, an `Evaluator` inits and `evalTicks` /
//!     `evalSeconds` run without panicking.
//!   * `Abi.decodeTargets` returns null or a slice whose every target has
//!     `ncomp ∈ 1..4`, a non-empty name, and a name slice inside the blob.
//!   * `Writes.decode` returns null or a slice whose `encodedLen(count)`
//!     fits the source buffer (fed 4-aligned, decode's alias contract).
//!   * `Easing.seqOf` / `chainOf` return an `Easing.Error` or a `Program`;
//!     `Program.eval` on a built program never panics. (Finiteness is NOT
//!     asserted: eval is total on ℝ but composing overshooting ops with
//!     extreme parameters can reach ±inf by design — a documented
//!     totality, not a panic or a contract breach.)
//!   * An `Eval.Evaluator` over a fixed all-sources score is a pure
//!     function of time: the same clock yields byte-identical entries
//!     regardless of evaluation order or history (the resume cursors are
//!     caches, not state), and arbitrary f64 seconds yield entries or a
//!     `TimeMap` error — the same one, deterministically.
//!   * `Compile.compile` over fuzzed host registries × compose-mode
//!     `(target …)` declarations preserves the host prefix of the merged
//!     join verbatim, appends only declared symbols, and every write of
//!     an ok score lands inside the join.

const std = @import("std");
const sjon = @import("sjon");
const Abi = @import("Abi.zig");
const Compile = @import("Compile.zig");
const test_support = @import("test_support.zig");
const Eval = @import("Eval.zig");
const Easing = @import("Easing.zig");
const Writes = @import("Writes.zig");
const fuzz_pacb = @import("fuzz_pacb.zig");

const Smith = std.testing.Smith;
const testing = std.testing;

/// Maximum input any harness eats. Keeps fuzzing cheap and stays well
/// under the compile-side document cap (which has its own tests).
const MAX_INPUT: usize = 1024;

/// Copy `bytes` into a sentinel-terminated, allocator-owned slice.
fn toSentinel(gpa: std.mem.Allocator, bytes: []const u8) ![:0]u8 {
    const buf = try gpa.allocSentinel(u8, bytes.len, 0);
    @memcpy(buf, bytes);
    return buf;
}

/// Deterministic spec reader over a Smith-drawn byte slice, shared by the
/// structured harnesses (4–6). Reads past the end yield zeros, so every
/// input length decodes to SOME spec — no rejected draws, the whole input
/// space maps onto the generator's domain.
const SpecCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *SpecCursor) u8 {
        if (self.pos >= self.bytes.len) return 0;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    /// A full-range u64 from 8 bytes — raw material for tick folds.
    fn u64bits(self: *SpecCursor) u64 {
        var bits: u64 = 0;
        for (0..8) |_| bits = (bits << 8) | self.byte();
        return bits;
    }

    /// A full-range f64 from 8 bytes — reaches NaN, ±inf, denormals.
    fn f64bits(self: *SpecCursor) f64 {
        return @bitCast(self.u64bits());
    }

    /// A bounded float in [lo, hi] from two bytes — for stage weights,
    /// where an arbitrary magnitude only tests f64 overflow, not the
    /// normalization logic.
    fn floatIn(self: *SpecCursor, lo: f64, hi: f64) f64 {
        const raw = (@as(u16, self.byte()) << 8) | self.byte();
        return lo + (@as(f64, @floatFromInt(raw)) / 65535.0) * (hi - lo);
    }
};

// ---------------------------------------------------------------------------
// 1. Compile.compile — arbitrary source + a fixed registry; then eval.
// ---------------------------------------------------------------------------

/// A fixed 3-target join spanning both registries and a vector target —
/// enough for a random score to resolve `(track :target …)` and pin the
/// arity/registry paths.
const fuzz_targets = [_]Compile.Target{
    .{ .name = "a", .ncomp = 1 },
    .{ .name = "b", .ncomp = 3 },
    .{ .name = "c", .ncomp = 1, .registry = 1 },
};

fn fuzzCompile(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xC0FF_11);

    const src = try toSentinel(testing.allocator, buf[0..len]);
    defer testing.allocator.free(src);

    var result = Compile.compile(testing.allocator, test_support.schema(), src, &fuzz_targets) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer result.deinit();

    // A defective score is a diagnostic-carrying result, never a panic.
    if (!result.ok()) return;

    var ev = Eval.Evaluator.init(testing.allocator, &result) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer ev.deinit();

    // The frame path over a spread of ticks (0, ±half a bar, a small
    // non-landing tick) plus one seconds eval — walking every entry so a
    // corrupt slice header would crash here rather than slip past.
    for ([_]i64{ 0, 360360, -360360, 2 }) |tick| {
        for (ev.evalTicks(tick)) |e| _ = e.ncomp;
    }
    _ = ev.evalSeconds(1.0) catch {};
}

test "fuzz Compile.compile: arbitrary source → CompileResult or OOM; eval never panics" {
    try testing.fuzz({}, fuzzCompile, .{
        .corpus = &.{
            "",
            "(transport :bpm 120)",
            "(transport :bpm 120)\n(track :target a (key :at 0b :value 0.5))",
            "(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)\n(track :target b (key :at 0b :value [1 0 0]) (key :at 4b :value [0 1 0] :ease in-out-quad))",
            "(transport :bpm 97)\n(track :target a :expr (+ 0.5 (* 0.5 (sin (* (tau) beat)))))",
            "(transport :bpm 120)\n(control :id k :target a :min 0 :max 1 :value 0.4)\n(track :target a :expr (* k 2))",
            "(transport :bpm 120)\n(track :target a (key :at 0b :value 0.1) (key :at 3b :value 0.9 :ease (spring :damping 0.4 :periods 3)))",
            "(track :target nope (key :at 0b :value 1))",
            "(transport :bpm 120)\n(track :target a (key :at 4 :value 1))",
            "(broken",
            "(transport :bpm 0)",
            "\xff\xfe\x00\x01",
        },
    });
}

// ---------------------------------------------------------------------------
// 2. Abi.decodeTargets — null, or every target well-formed and in-blob.
// ---------------------------------------------------------------------------

fn fuzzDecodeTargets(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x7A6_6E7);
    const blob = buf[0..len];

    var out: [64]Compile.Target = undefined;
    const targets = Abi.decodeTargets(blob, &out) orelse return;

    const base = @intFromPtr(blob.ptr);
    for (targets) |tg| {
        try testing.expect(tg.ncomp >= 1 and tg.ncomp <= 4);
        try testing.expect(tg.name.len >= 1);
        const name_at = @intFromPtr(tg.name.ptr);
        try testing.expect(name_at >= base);
        try testing.expect(name_at + tg.name.len <= base + blob.len);
    }
}

test "fuzz Abi.decodeTargets: null or in-blob, well-formed targets" {
    try testing.fuzz({}, fuzzDecodeTargets, .{
        .corpus = &.{
            "",
            // 'PACT' magic, count 0.
            "PACT\x00\x00\x00\x00",
            // 'PACT', count 1, ncomp 1, registry 0, name_len 1, "r".
            "PACT\x01\x00\x00\x00\x01\x00\x01\x00r",
            // count 2 with a vec3 second target.
            "PACT\x02\x00\x00\x00\x01\x00\x01\x00a\x03\x01\x04\x00tint",
            // ncomp 0 (rejected).
            "PACT\x01\x00\x00\x00\x00\x00\x01\x00r",
            // name_len 0 (rejected).
            "PACT\x01\x00\x00\x00\x01\x00\x00\x00",
            // trailing garbage (rejected).
            "PACT\x01\x00\x00\x00\x01\x00\x01\x00r\x00",
            "\x00\x00\x00\x00\x00\x00\x00\x00",
        },
    });
}

// ---------------------------------------------------------------------------
// 3. Writes.decode — null, or encodedLen(count) fits the buffer.
//
// decode's source must be 4-aligned — a signature fact
// (`[]align(4) const u8`), so the aligned buffer here is checked by the
// compiler, not by discipline. The BYTES stay arbitrary.
// ---------------------------------------------------------------------------

fn fuzzWritesDecode(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 align(4) = undefined;
    const len = smith.sliceWithHash(&buf, 0x5A1_235);
    const src = buf[0..len];

    const entries = Writes.decode(src) orelse return;
    try testing.expect(Writes.encodedLen(entries.len) <= src.len);
    for (entries) |e| _ = e.value;
}

test "fuzz Writes.decode: null or count fits the buffer" {
    try testing.fuzz({}, fuzzWritesDecode, .{
        .corpus = &.{
            "",
            // 'PACW' v1 count 0.
            "PACW\x01\x00\x00\x00\x00\x00\x00\x00",
            // count 1 + one 20-byte entry.
            "PACW\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
            // count claims 1000 but no payload (rejected).
            "PACW\x01\x00\x00\x00\xe8\x03\x00\x00",
            // bad magic.
            "XXXX\x01\x00\x00\x00\x00\x00\x00\x00",
            "\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00",
        },
    });
}

// ---------------------------------------------------------------------------
// 4. Easing.seqOf / chainOf — an Error or a Program; eval never panics.
//
// The specs are derived deterministically from the input bytes: stage and
// op counts sometimes exceed the caps (to exercise the reject paths), op
// codes stay in the valid enum range (an out-of-range tag would be UB,
// not a meaningful fuzz input), and params/weights are arbitrary f64 bit
// patterns (NaN/±inf drive compactOp's domain rejections).
// ---------------------------------------------------------------------------

fn fuzzEasing(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xEA51_47);
    var cur = SpecCursor{ .bytes = buf[0..len] };

    // 0..MAX_STAGES+1 stages / ops-per-stage — the +2 reaches the
    // over-cap and empty (zero) reject paths.
    const n_stages = cur.byte() % (Easing.MAX_STAGES + 2);
    var stages: [Easing.MAX_STAGES + 1]Easing.StageSpec = undefined;
    var ops: [(Easing.MAX_STAGES + 1) * (Easing.MAX_OPS + 1)]Easing.OpSpec = undefined;
    var op_i: usize = 0;
    const op_count = @typeInfo(Easing.Op).@"enum".fields.len;
    for (0..n_stages) |s| {
        const n_ops = cur.byte() % (Easing.MAX_OPS + 2);
        const start = op_i;
        for (0..n_ops) |_| {
            // Fold the byte into a valid tag (0..op_count-1) — the enum has
            // no invalid bit patterns to read safely.
            const code: Easing.Op = @enumFromInt(cur.byte() % op_count);
            ops[op_i] = .{ .code = code, .params = .{
                cur.f64bits(), cur.f64bits(), cur.f64bits(), cur.f64bits(),
            } };
            op_i += 1;
        }
        stages[s] = .{
            .t = cur.floatIn(-2, 130), // sometimes ≤ 0 → EaseWeightsInvalid
            .v = cur.floatIn(-130, 130),
            .ops = ops[start..op_i],
        };
    }

    const prog = Easing.seqOf(stages[0..n_stages]) catch |err| return expectEaseError(err);
    for ([_]f64{ 0, 0.25, 0.5, 0.75, 1.0 }) |u| _ = prog.eval(u);

    // chainOf twin over the first stage's ops, when in range.
    if (n_stages > 0 and stages[0].ops.len >= 1 and stages[0].ops.len <= Easing.MAX_OPS) {
        const chain = Easing.chainOf(stages[0].ops) catch |err| return expectEaseError(err);
        for ([_]f64{ 0, 0.5, 1.0 }) |u| _ = chain.eval(u);
    }
}

fn expectEaseError(err: Easing.Error) !void {
    switch (err) {
        error.EaseStagesExceeded,
        error.EaseOpsExceeded,
        error.EaseWeightsInvalid,
        error.EaseParamsInvalid,
        => {},
    }
}

test "fuzz Easing.seqOf / chainOf: Error or Program; eval never panics" {
    try testing.fuzz({}, fuzzEasing, .{
        .corpus = &.{
            "",
            "\x00",
            "\x01\x01\x00" ++ ("\x00" ** 8) ++ "\x80\x00\x80\x00", // 1 stage, 1 linear op
            "\x02\x02\x03\x0a\x14\x1e" ++ ("\x11" ** 40),
            "\xff" ** 64,
            "\x03\x04\x14\x14\x14\x14" ++ ("\x3f" ** 80),
            "\x08\x02\x00\x01" ++ ("\x40" ** 60),
        },
    });
}

// ---------------------------------------------------------------------------
// 5. Evaluator over arbitrary clocks — purity as order-independence.
//
// One fixed score covering every track source and both resume cursors
// (keyframe segment, trigger `:at` event) plus loop wrap, a scene window,
// and emit lanes. Two evaluators over the SAME result receive the SAME
// drawn clocks in OPPOSITE orders; the determinism claim says history
// never matters, so every (evaluator, clock) pair must produce
// byte-identical entries. This is the strongest fuzzable form of "pure
// function of time", and it pins the cursors as caches, not state.
// ---------------------------------------------------------------------------

const eval_score: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 4bar :end loop :emit [beat phase])
    \\(track :target a
    \\  (key :at 0b :value 0.0)
    \\  (key :at 4b :value 1.0 :ease in-out-quad)
    \\  (key :at 9b :value 0.25))
    \\(track :target b :expr (+ 0.5 (* 0.5 (sin (* (tau) beat)))))
    \\(track :target c :pattern [0.1 0.2 (silence) 0.4])
    \\(trigger :target d :every 1b :offset 1b)
    \\(trigger :target e :at [2b 5b 7b])
    \\(scene :name intro :at 0b :dur 6b
    \\  (track :target f (key :at 0b :value 0.1) (key :at 6b :value 0.7))
    \\  (track :target g :expr scene-phase))
;

/// The fixed score's join. `beat`/`phase` back the emit lanes (an emitted
/// lane needs a scalar host target of its own name); `d` is ncomp-4 so
/// the periodic trigger writes all four lanes.
const eval_targets = [_]Compile.Target{
    .{ .name = "a", .ncomp = 1 },
    .{ .name = "b", .ncomp = 1 },
    .{ .name = "c", .ncomp = 1 },
    .{ .name = "d", .ncomp = 4, .registry = 1 },
    .{ .name = "e", .ncomp = 1, .registry = 1 },
    .{ .name = "f", .ncomp = 1 },
    .{ .name = "g", .ncomp = 1 },
    .{ .name = "beat", .ncomp = 1 },
    .{ .name = "phase", .ncomp = 1 },
};

/// Clocks drawn per iteration; frames are snapshotted for the reverse
/// replay, so the count stays small and stack-bounded.
const N_CLOCKS = 6;

/// Frame snapshot capacity: 2 emit lanes + 7 tracks = 9 for the fixed
/// score; headroom asserted at snapshot time, not trusted.
const MAX_FRAME_ENTRIES = 16;

const Frame = struct { n: usize, entries: [MAX_FRAME_ENTRIES]Writes.Entry };

/// Fold arbitrary u64 bits into the evaluator's contractual clock domain
/// [-MAX_TICK, MAX_TICK] — the precondition `drv_evalTicks` gates and
/// `tickFromSeconds` guarantees. The span 2^54+1 fits u64 and the folded
/// magnitude ≤ 2^53 fits i64 exactly.
fn foldTick(bits: u64) i64 {
    const max: u64 = sjon.Pattern.MAX_TICK;
    const span = 2 * max + 1;
    return @as(i64, @intCast(bits % span)) - @as(i64, @intCast(max));
}

/// Snapshot a frame, asserting the wire invariants every produced entry
/// must satisfy: a live arity, an id inside the join, flags equal to the
/// target's registry (today's whole flags contract).
fn snapshotFrame(entries: []const Writes.Entry) !Frame {
    try testing.expect(entries.len <= MAX_FRAME_ENTRIES);
    var fr = Frame{ .n = entries.len, .entries = undefined };
    for (entries, fr.entries[0..entries.len]) |e, *dst| {
        try testing.expect(e.ncomp >= 1 and e.ncomp <= 4);
        try testing.expect(e.target_id < eval_targets.len);
        try testing.expectEqual(eval_targets[e.target_id].registry, e.flags);
        dst.* = e;
    }
    return fr;
}

/// Byte-equality of a snapshot against a live frame — the determinism
/// claim IS byte-equality, so NaN lanes (none expected) would still have
/// to match bit-for-bit. `Entry` is padding-free (comptime-pinned 20
/// bytes), so the byte view is sound.
fn expectSameFrame(want: *const Frame, got: []const Writes.Entry) !void {
    try testing.expectEqual(want.n, got.len);
    try testing.expectEqualSlices(
        u8,
        std.mem.sliceAsBytes(want.entries[0..want.n]),
        std.mem.sliceAsBytes(got),
    );
}

const EvalPair = struct {
    fwd: *Eval.Evaluator,
    rev: *Eval.Evaluator,
};

fn fuzzEvalClocks(ctx: EvalPair, smith: *Smith) anyerror!void {
    var buf: [256]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xE7A1_09);
    var cur = SpecCursor{ .bytes = buf[0..len] };

    // Clock lattice: mostly full-range folds, seeded with the exact
    // boundaries a fold would almost never land on — the tick ceiling
    // and the loop edge (`:dur 4bar`).
    const edge = 4 * sjon.Pattern.PPC;
    const specials = [_]i64{
        0,                      1,
        -1,                     sjon.Pattern.MAX_TICK,
        -sjon.Pattern.MAX_TICK, sjon.Pattern.MAX_TICK - 1,
        edge,                   edge - 1,
    };
    var clocks: [N_CLOCKS]i64 = undefined;
    for (&clocks) |*t| {
        const sel = cur.byte();
        t.* = if (sel < 64) specials[sel % specials.len] else foldTick(cur.u64bits());
    }

    // Forward walk, snapshotting each frame; an immediate re-eval at the
    // same clock must reproduce it (cursor idempotence).
    var frames: [N_CLOCKS]Frame = undefined;
    for (clocks, &frames) |t, *fr| {
        fr.* = try snapshotFrame(ctx.fwd.evalTicks(t));
        try expectSameFrame(fr, ctx.fwd.evalTicks(t));
    }
    // Reverse replay on the second evaluator: same clock, different
    // history, identical bytes.
    var i: usize = clocks.len;
    while (i > 0) {
        i -= 1;
        try expectSameFrame(&frames[i], ctx.rev.evalTicks(clocks[i]));
    }

    // The seconds seam: raw f64 bit patterns (NaN, ±inf, beyond-ceiling
    // magnitudes) yield entries or a TimeMap error — and the SAME one
    // from both evaluators. One bounded draw keeps the in-range path warm.
    const secs = [_]f64{ cur.f64bits(), cur.floatIn(-64, 64) };
    for (secs) |s| {
        if (ctx.fwd.evalSeconds(s)) |entries| {
            const fr = try snapshotFrame(entries);
            try expectSameFrame(&fr, try ctx.rev.evalSeconds(s));
        } else |err| {
            switch (err) {
                error.TickOverflow, error.NonFiniteTime => {},
            }
            try testing.expectError(err, ctx.rev.evalSeconds(s));
        }
    }
}

test "fuzz Evaluator clocks: same time → same frame, in any order" {
    var result = Compile.compile(testing.allocator, test_support.schema(), eval_score, &eval_targets) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer result.deinit();
    for (result.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try testing.expect(result.ok());

    // Borrow-whole teardown order: both evaluators deinit (LIFO) before
    // the result they borrow.
    var fwd = try Eval.Evaluator.init(testing.allocator, &result);
    defer fwd.deinit();
    var rev = try Eval.Evaluator.init(testing.allocator, &result);
    defer rev.deinit();

    // Non-vacuity guard: at beat 1 the score writes emit lanes, keys,
    // expr, pattern, the periodic trigger, and the scene tracks — if this
    // frame were empty the purity comparisons below would compare nothing.
    try testing.expect(fwd.evalTicks(@divExact(sjon.Pattern.PPC, 4)).len >= 6);

    try testing.fuzz(EvalPair{ .fwd = &fwd, .rev = &rev }, fuzzEvalClocks, .{
        .corpus = &.{
            "",
            // The specials: ±ceiling, ceiling-1, loop edge ±0/1, then 0.
            "\x03\x04\x05\x06\x07\x00",
            // Full-range folds + extreme f64 seconds bits.
            "\xff" ** 62,
            "\x40" ** 62,
            // Zero clocks, then seconds = +inf (NonFiniteTime twice).
            ("\x00" ** 6) ++ "\x7f\xf0\x00\x00\x00\x00\x00\x00\x00\x00",
            // Zero clocks, then seconds = 8.9e307 (TickOverflow).
            ("\x00" ** 6) ++ "\x7f\xe0\x00\x00\x00\x00\x00\x00\x00\x00",
        },
    });
}

// ---------------------------------------------------------------------------
// 6. Compile target joins — fuzzed host registries × compose-mode decls.
//
// Hosts and declarations draw names from one tiny symbol space so every
// collision class is reached: host∩declared (host-authoritative, arity
// agreement), declared-only (appended), duplicate declarations, junk
// host names no symbol can match. Arities sometimes leave 1..4 to walk
// the schema-reject path; track targets are drawn independently so
// unknown-target and arity-mismatch diagnostics fire too.
// ---------------------------------------------------------------------------

const join_symbols = [_][]const u8{ "a", "b", "c", "d", "ab", "cd" };

fn fuzzTargetJoin(_: void, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0x70_1A17);
    var cur = SpecCursor{ .bytes = buf[0..len] };

    // Host registry: 0..6 entries — a shared symbol (collides with the
    // decls below) or 1..3 junk bytes (never a valid symbol; must simply
    // never match). Arity 1..4 and any u8 registry, mirroring what a
    // decoded 'PACT' can carry. Duplicate host names are legal input
    // (first match wins downstream).
    var junk: [6][3]u8 = undefined;
    var host: [6]Compile.Target = undefined;
    const n_host = cur.byte() % (host.len + 1);
    for (0..n_host) |i| {
        const pick = cur.byte();
        const name: []const u8 = if (pick % 8 < join_symbols.len)
            join_symbols[pick % 8]
        else blk: {
            const n = 1 + cur.byte() % 3;
            for (junk[i][0..n]) |*ch| ch.* = cur.byte();
            break :blk junk[i][0..n];
        };
        host[i] = .{ .name = name, .ncomp = 1 + cur.byte() % 4, .registry = cur.byte() };
    }

    // Score text: 0..5 declarations, a transport, 0..2 tracks. The
    // buffer is sized for the worst case (5×41 + 21 + 2×42 < 512), so
    // bufPrint cannot fail.
    var text: [512]u8 = undefined;
    var pos: usize = 0;
    var decls: [5]Compile.Target = undefined;
    const n_decl = cur.byte() % (decls.len + 1);
    for (decls[0..n_decl]) |*d| {
        const name = join_symbols[cur.byte() % join_symbols.len];
        const arity_pick = cur.byte();
        // Mostly in range; 0 and 9 walk the schema-reject path.
        const arity: u8 = switch (arity_pick % 8) {
            7 => 9,
            6 => 0,
            else => 1 + arity_pick % 4,
        };
        const registry = cur.byte();
        d.* = .{ .name = name, .ncomp = arity, .registry = registry };
        pos += (std.fmt.bufPrint(
            text[pos..],
            "(target :name {s} :arity {d} :registry {d})\n",
            .{ name, arity, registry },
        ) catch unreachable).len;
    }
    pos += (std.fmt.bufPrint(text[pos..], "(transport :bpm 120)\n", .{}) catch unreachable).len;
    const n_tracks = cur.byte() % 3;
    for (0..n_tracks) |_| {
        pos += (std.fmt.bufPrint(
            text[pos..],
            "(track :target {s} (key :at 0b :value 1))\n",
            .{join_symbols[cur.byte() % join_symbols.len]},
        ) catch unreachable).len;
    }

    const src = try toSentinel(testing.allocator, text[0..pos]);
    defer testing.allocator.free(src);

    var result = Compile.compile(testing.allocator, test_support.schema(), src, host[0..n_host]) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer result.deinit();

    // Diagnostics or not, the merged view exists and must preserve the
    // host prefix VERBATIM — host join indices are the wire contract.
    try testing.expect(result.targets.len >= n_host);
    for (host[0..n_host], result.targets[0..n_host]) |h, m| {
        try testing.expectEqualStrings(h.name, m.name);
        try testing.expectEqual(h.ncomp, m.ncomp);
        try testing.expectEqual(h.registry, m.registry);
    }
    // Anything appended is exactly one of the declarations (name, arity,
    // registry) — the merge invents nothing.
    for (result.targets[n_host..]) |m| {
        try testing.expect(m.ncomp >= 1 and m.ncomp <= 4);
        var declared = false;
        for (decls[0..n_decl]) |d| {
            declared = declared or (std.mem.eql(u8, d.name, m.name) and
                d.ncomp == m.ncomp and d.registry == m.registry);
        }
        try testing.expect(declared);
    }

    if (!result.ok()) return;
    var ev = Eval.Evaluator.init(testing.allocator, &result) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        return;
    };
    defer ev.deinit();
    // One frame: every write must land inside the merged join.
    for (ev.evalTicks(0)) |e| {
        try testing.expect(e.target_id < result.targets.len);
        try testing.expectEqual(result.targets[e.target_id].registry, e.flags);
    }
}

test "fuzz Compile target joins: host prefix verbatim, appends only declared" {
    try testing.fuzz({}, fuzzTargetJoin, .{
        .corpus = &.{
            "",
            // 2 hosts ("a" scalar reg 0, "b" vec reg 1), no decls, 1 track on "a".
            "\x02\x00\x00\x00\x01\x02\x01\x00\x01\x00",
            // No hosts, 2 decls (one duplicate pair), no tracks.
            "\x00\x02\x00\x00\x00\x00\x00\x00\x00",
            // Junk host name + colliding decl + a track.
            "\x01\x07\x02\xfe\xff\x00\x00\x01\x00\x00\x00\x01\x00",
            "\xff" ** 48,
            "\x40" ** 32,
        },
    });
}

// ---------------------------------------------------------------------------
// 7. Pacb.decode — whole-'PACB' container bytes, random or fixture-derived.
//
//    The harness body lives in its own file, `fuzz_pacb.zig`, so the RED
//    that introduced it was a genuine missing module rather than a
//    fabricated missing-export seam on this root (G12); this delegating
//    wrapper is what discovery rides (this root imports siblings
//    directly, so the module must exist for the target to compile).
// ---------------------------------------------------------------------------

test "fuzz Pacb.decode: never-panic over random bytes and fixture mutations" {
    try fuzz_pacb.run();
}
