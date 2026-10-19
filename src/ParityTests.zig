//! Separate test root for the native parity runner — binary03 T3.
//!
//! This root imports the actual public `pacer` module and the named
//! `corpus_harness` leaf, and links the same separately compiled
//! `native_rt_object` as the parity executable. It never imports a pacer
//! core/runtime source file, and `src/root.zig` never imports this root.
//!
//! The tests cover the classifier's ONE initial load record, later reload
//! records, duplicates/malformed/unknown records, the clean/dirty pattern
//! classification, the pack guard that keeps diagnostic fixtures away from
//! the asserted pack APIs, and a byte-comparison toothproof over a REAL
//! production frame (mutated on a copy, asserted by name, then restored).

const std = @import("std");
const pacer = @import("pacer");
const runner = @import("parity_runner.zig");
const NativeRt = @import("NativeRt.zig");

const t = std.testing;

test {
    // Explicit discovery block: this root is registered separately in
    // build.zig, never through `src/root.zig`.
    _ = @import("parity_runner.zig");
    _ = @import("NativeRt.zig");
}

const HOST_TARGETS = [_]pacer.Compile.Target{
    .{ .name = "radius", .ncomp = 1, .registry = 0 },
};

const CLEAN_SOURCE: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4])
    \\(track :target radius
    \\  (key :at 0b :value 0.2)
    \\  (key :at 4b :value 0.8))
;

const DIAGNOSTIC_SOURCE: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4])
    \\(track :target missing (key :at 0b :value 0.5))
;

const PATTERN_SOURCE: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4])
    \\(track :target radius :pattern [0.1 0.2])
;

// ---------------------------------------------------------------------------
// Initial golden record — total classification input
// ---------------------------------------------------------------------------

test "classifier: initial load true and false are read at the initial position" {
    try t.expectEqual(
        true,
        (try runner.parseInitialLoad(runner.GENERATED_HEADER ++ "\n(load :ok true)\n")).initial_ok,
    );
    try t.expectEqual(
        false,
        (try runner.parseInitialLoad(runner.GENERATED_HEADER ++ "\n(load :ok false)\n(diag :source sjon)\n")).initial_ok,
    );
}

test "classifier: a later reload record is never the initial classification" {
    const golden = runner.GENERATED_HEADER ++
        "\n(load :ok true)\n(meta :bpm \"0000000000000000\")\n(reload :kind current :status 0)\n(load :ok false)\n";
    // The initial record is true; the later `(load :ok false)` is a reload
    // and must not overwrite it.
    try t.expectEqual(true, (try runner.parseInitialLoad(golden)).initial_ok);
}

test "classifier: duplicate initial records are refused" {
    const golden = runner.GENERATED_HEADER ++ "\n(load :ok true)\n(load :ok false)\n";
    try t.expectError(error.DuplicateInitialLoad, runner.parseInitialLoad(golden));
}

test "classifier: malformed, missing, and unknown golden records are refused" {
    try t.expectError(
        error.MalformedHeader,
        runner.parseInitialLoad("(load :ok true)\n"),
    );
    try t.expectError(
        error.MissingInitialLoad,
        runner.parseInitialLoad(runner.GENERATED_HEADER ++ "\n(meta :bpm \"0000000000000000\")\n"),
    );
    try t.expectError(
        error.MalformedLoadRecord,
        runner.parseInitialLoad(runner.GENERATED_HEADER ++ "\n(load :ok maybe)\n"),
    );
    try t.expectError(
        error.UnknownTopLevelForm,
        runner.parseInitialLoad(runner.GENERATED_HEADER ++ "\n(load :ok true)\n(rewind :to 0)\n"),
    );
}

test "classifier: clean non-pattern, clean pattern, dirty pattern, disagreement" {
    try t.expectEqual(
        runner.Class.clean_non_pattern,
        try runner.classify(true, true, false),
    );
    try t.expectEqual(
        runner.Class.clean_pattern,
        try runner.classify(true, true, true),
    );
    // A dirty pattern source (the pattern-budget shape): compile refuses even
    // though a pattern exists in the source; it is a load-failing fixture.
    try t.expectEqual(
        runner.Class.load_failing,
        try runner.classify(false, false, true),
    );
    try t.expectEqual(
        runner.Class.load_failing,
        try runner.classify(false, false, false),
    );
    try t.expectError(
        error.CompileGoldenDisagreement,
        runner.classify(true, false, false),
    );
    try t.expectError(
        error.CompileGoldenDisagreement,
        runner.classify(false, true, false),
    );
}

// ---------------------------------------------------------------------------
// Pack orchestration guards
// ---------------------------------------------------------------------------

test "pack guard: a diagnostic score is compile_refused without any pack API" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, DIAGNOSTIC_SOURCE, &HOST_TARGETS);
    defer driver.deinit();

    try t.expect(!driver.result.ok());
    try t.expect(driver.result.findDiag(.unknown_target) != null);

    // If this reached `PacbEncode.preflight`/`encode`, their `result.ok()`
    // assertions would abort the test. The only correct arm is no output.
    const packed_case = try runner.packCase(a, &driver.result, &HOST_TARGETS);
    switch (packed_case) {
        .compile_refused => {},
        else => return error.TestUnexpectedResult,
    }
}

test "pack guard: a clean pattern reaches preflight and is never encoded" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, PATTERN_SOURCE, &HOST_TARGETS);
    defer driver.deinit();
    try t.expect(driver.result.ok());

    const packed_case = try runner.packCase(a, &driver.result, &HOST_TARGETS);
    switch (packed_case) {
        .preflight_refused => |diags| {
            try t.expect(diags.len > 0);
            var refused = false;
            for (diags) |d| {
                if (d.code == .pack_patterns_unsupported) refused = true;
            }
            try t.expect(refused);
        },
        .encoded => return error.TestUnexpectedResult, // encode must never run
        .compile_refused => return error.TestUnexpectedResult,
    }
    try t.expectEqual(
        runner.Class.clean_pattern,
        try runner.classify(true, true, true),
    );
}

// ---------------------------------------------------------------------------
// Byte comparison toothproof over real production bytes
// ---------------------------------------------------------------------------

test "byte comparison: a mutated production frame names its first byte; restore passes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, CLEAN_SOURCE, &HOST_TARGETS);
    defer driver.deinit();

    const packed_case = try runner.packCase(a, &driver.result, &HOST_TARGETS);
    const pacb = switch (packed_case) {
        .encoded => |bytes| bytes,
        else => return error.TestUnexpectedResult,
    };

    // Runtime lifecycle: reset before the first load and on every exit.
    defer NativeRt.reset();
    NativeRt.reset();

    try t.expect(pacb.len <= @as(usize, NativeRt.pacbCap()));
    const pact_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&HOST_TARGETS));
    const pact = try pacer.PactCodec.encodeTargets(&HOST_TARGETS, pact_buf);
    try t.expect(pact.len <= @as(usize, NativeRt.targetsCap()));

    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(@as(u32, 0), NativeRt.load(@intCast(pacb.len), @intCast(pact.len)));

    // The text path's complete 'PACW' blob and the real production frame.
    const entries = try driver.evaluator.?.evalSeconds(0.5);
    var text_buf: [pacer.Writes.encodedLen(pacer.EvalCore.MAX_FRAME_ENTRIES)]u8 = undefined;
    const want = try pacer.Writes.encode(entries, &text_buf);

    const got_len: usize = NativeRt.evalSeconds(0.5);
    try t.expectEqual(want.len, got_len);
    try t.expect(got_len > pacer.Writes.HEADER_LEN);
    const got = try a.dupe(u8, NativeRt.writesPtr()[0..got_len]);

    var sink: std.Io.Writer.Allocating = .init(a);
    try runner.expectSameBytes(&sink.writer, "mutation-check", 0, "writes", want, got);
    try t.expectEqual(@as(usize, 0), sink.written().len);

    // Deliberate mutation on the COPY (never source, never the corpus): the
    // first payload byte is at the 12-byte 'PACW' header boundary.
    got[pacer.Writes.HEADER_LEN] ^= 0x01;
    try t.expectError(
        error.ParityMismatch,
        runner.expectSameBytes(&sink.writer, "mutation-check", 0, "writes", want, got),
    );
    const report = sink.written();
    try t.expect(std.mem.indexOf(u8, report, "mutation-check") != null);
    try t.expect(std.mem.indexOf(u8, report, "step 0") != null);
    try t.expect(std.mem.indexOf(u8, report, "writes MISMATCH") != null);
    try t.expect(std.mem.indexOf(u8, report, "first difference at offset 12") != null);
    try t.expect(std.mem.indexOf(u8, report, "expected 0x") != null);
    try t.expect(std.mem.indexOf(u8, report, "actual 0x") != null);

    // Restore the copy: the same comparator is green again.
    got[pacer.Writes.HEADER_LEN] ^= 0x01;
    try runner.expectSameBytes(&sink.writer, "mutation-check", 0, "writes", want, got);
}
