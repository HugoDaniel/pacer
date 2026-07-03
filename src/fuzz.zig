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

const std = @import("std");
const Abi = @import("Abi.zig");
const Compile = @import("Compile.zig");
const Eval = @import("Eval.zig");
const Easing = @import("Easing.zig");
const Writes = @import("Writes.zig");

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

    var result = Compile.compile(testing.allocator, src, &fuzz_targets) catch |err| {
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
// decode `@alignCast`s the payload to `Entry` (align 4), so the source
// must be 4-aligned — feed a 4-aligned buffer, decode's documented
// caller contract.
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

const SpecCursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *SpecCursor) u8 {
        if (self.pos >= self.bytes.len) return 0;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    /// A full-range f64 from 8 bytes — reaches NaN, ±inf, denormals.
    fn f64bits(self: *SpecCursor) f64 {
        var bits: u64 = 0;
        for (0..8) |_| bits = (bits << 8) | self.byte();
        return @bitCast(bits);
    }

    /// A bounded float in [lo, hi] from two bytes — for stage weights,
    /// where an arbitrary magnitude only tests f64 overflow, not the
    /// normalization logic.
    fn floatIn(self: *SpecCursor, lo: f64, hi: f64) f64 {
        const raw = (@as(u16, self.byte()) << 8) | self.byte();
        return lo + (@as(f64, @floatFromInt(raw)) / 65535.0) * (hi - lo);
    }
};

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
