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
const sjon = @import("sjon");
const runner = @import("parity_runner.zig");
const negatives = @import("parity_negatives.zig");
const CorpusHarness = @import("corpus_harness");
const NativeRt = @import("NativeRt.zig");
const NativeText = @import("NativeText.zig");
const build_options = @import("build_options");

const t = std.testing;

test {
    // Explicit discovery block: this root is registered separately in
    // build.zig, never through `src/root.zig`.
    _ = @import("parity_runner.zig");
    _ = @import("NativeRt.zig");
    _ = @import("parity_negatives.zig");
}

/// Read the four committed fixture blobs the production-loader negative
/// suite mutates (three T6a blobs plus the B2a `host-join` registry
/// fixture). Bounded reads; no fixture is ever written.
fn negativeFixtures(a: std.mem.Allocator) !negatives.Fixtures {
    const load = struct {
        fn one(alloc: std.mem.Allocator, name: []const u8) ![]u8 {
            const path = try std.fmt.allocPrint(
                alloc,
                "{s}/tools/testdata/pacb/{s}.pacb",
                .{ build_options.repo_root, name },
            );
            return sjon.CappedRead.readFile(t.io, path, alloc, 1 << 20);
        }
    };
    return .{
        .keys_only = try load.one(a, "keys-only"),
        .expr_keys = try load.one(a, "expr-keys"),
        .full_small = try load.one(a, "full-small"),
        .host_join = try load.one(a, "host-join"),
    };
}

/// Number of non-overlapping `needle` occurrences in `haystack`.
fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| {
        n += 1;
        i = at + needle.len;
    }
    return n;
}

/// The last `\n`-delimited line of `haystack` containing `needle`, if any.
fn lastLineContaining(haystack: []const u8, needle: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, haystack, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) found = line;
    }
    return found;
}

test "negatives: production prt_load exact refusals and transactional state" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();
    try negatives.run(a, &sink.writer, try negativeFixtures(a));
    const out = sink.written();

    // The LITERAL expected category inventory of the T6a suite, independent
    // of the suite's own execution counters — the report gate must never
    // derive its expectation from the counters it checks. Names must match
    // `parity_negatives.zig` exactly; the counts are the reviewed inventory:
    // 35 named mutations, 3 bad-call cases, the 1 "prefixes" family label
    // (a label, never an attempt), and one prefix attempt per byte of the
    // committed keys-only blob (3700 proper prefixes).
    const expected_named = [_][]const u8{
        "forged-magic",            "forged-version",       "forged-features",
        "directory-overlap",       "directory-overrun",    "directory-reorder",
        "directory-gap",           "directory-duplicate-id", "directory-unknown-id",
        "directory-trailing-slack", "trak-count-inflated", "tick-count-cap",
        "tran-bpm-nan",            "tran-bpm-pos-inf",     "tran-bpm-neg-inf",
        "tmpo-bpm-nan",            "tmpo-bpm-pos-inf",     "tmpo-bpm-neg-inf",
        "keys-value-pad-nan",      "keys-value-pad-pos-inf", "keys-value-pad-neg-inf",
        "ctrl-min-nan",            "ctrl-min-pos-inf",     "ctrl-min-neg-inf",
        "ease-stage-nan",          "ease-stage-pos-inf",   "ease-stage-neg-inf",
        "ease-op-param-nan",
        "ease-ref-range",          "ease-ref-disagrees",   "ease-stage-domain",
        "ease-op-padding",
        "ease-program-cap",        "ease-degenerate-present", "ease-refs-count-mismatch",
        // B2a compact-payload family (2026-10-22): the compact-IR
        // structural classes over a genuine packed payload's copy, each
        // reaching the payload walk / presence / cap gate exactly — the
        // directory and byte_size are always repaired so reason 3/4 can
        // never mask the claimed stage.
        "payload-zero-root",       "payload-multi-root",   "payload-corrupt-node",
        "payload-inspan-slack",
        "payload-region-degenerate", "payload-section-absent", "payload-presence-without-track",
        "payload-span-cap",        "payload-total-cap",
    };
    const expected_bad_calls = [_][]const u8{
        "bad-call-pacb-overcap", "bad-call-targets-overcap", "bad-call-pact-malformed",
    };
    // B2a status-0 characterization attempts (named v1 tolerances and
    // honest-rewrite controls). Each must appear EXACTLY once as an
    // acceptance line; a refusal here is a failed gate.
    const expected_positive = [_][]const u8{
        "payload-region-slack-tolerated", "payload-reassembly-identity",
    };
    const expected_family_labels = [_][]const u8{ "prefixes", "compact-payload" };
    const expected_prefix_cases: usize = 3700;

    // Every named mutation and bad call executed EXACTLY once: a removed or
    // double-counted run call fails here, per name.
    for (expected_named) |name| {
        const needle = try std.fmt.allocPrint(a, "negatives: {s}: status 1 reason", .{name});
        try t.expectEqual(@as(usize, 1), countOccurrences(out, needle));
    }
    for (expected_bad_calls) |name| {
        const needle = try std.fmt.allocPrint(a, "negatives: {s}: status 2", .{name});
        try t.expectEqual(@as(usize, 1), countOccurrences(out, needle));
    }
    for (expected_positive) |name| {
        const needle = try std.fmt.allocPrint(a, "negatives: {s}: status 0 (accepted; ", .{name});
        try t.expectEqual(@as(usize, 1), countOccurrences(out, needle));
    }
    try t.expectEqual(
        @as(usize, 1),
        countOccurrences(out, "negatives: prefixes 0.."),
    );

    // The printed partition equals the literal inventory, arithmetic exact.
    // B2a (2026-10-22): the partition gained a `positive` term — status-0
    // characterization attempts are counted, never laundered as refusals —
    // and the T6a-only qualifier was NARROWED to its true remainder (B2b
    // numeric/dry-run), not removed: the hold stays until B2b lands.
    const expected_partition = try std.fmt.allocPrint(
        a,
        "negatives: partition {d} named + {d} bad-call + {d} prefix + {d} positive = {d} attempted; {d} names = {d} mutation name(s) + {d} bad-call name(s) + {d} positive name(s) + {d} family label(s) (B2b numeric/dry-run remains excluded)\n",
        .{
            expected_named.len,
            expected_bad_calls.len,
            expected_prefix_cases,
            expected_positive.len,
            expected_named.len + expected_bad_calls.len + expected_prefix_cases + expected_positive.len,
            expected_named.len + expected_bad_calls.len + expected_positive.len + expected_family_labels.len,
            expected_named.len,
            expected_bad_calls.len,
            expected_positive.len,
            expected_family_labels.len,
        },
    );
    if (std.mem.indexOf(u8, out, expected_partition) == null) {
        // RED context: show the summary line the suite actually printed.
        if (lastLineContaining(out, "attempted")) |line| {
            std.debug.print("negatives partition gate, actually printed summary: {s}\n", .{line});
        }
    }
    try t.expect(std.mem.indexOf(u8, out, expected_partition) != null);

    // The superseded T6a-only totals are preserved as a DATED baseline
    // line (history, not a live claim): the reviewed B1 inventory at
    // d2644eb, printed verbatim.
    try t.expectEqual(
        @as(usize, 1),
        countOccurrences(out, "negatives: T6a baseline at d2644eb (2026-10-22): 35 named + 3 bad-call + 3700 prefix = 3738 attempted; 39 names = 35 mutation name(s) + 3 bad-call name(s) + 1 family label(s)"),
    );

    // The old all-of-T6b exclusion qualifier must be GONE — narrowed to
    // the B2b remainder, never silently kept as if nothing had landed.
    try t.expectEqual(
        @as(usize, 0),
        countOccurrences(out, "(T6b payload/meta/registry/dry-run work is excluded from T6a)"),
    );
    // The closing PASS line keeps the remaining-open holds spelled out.
    try t.expectEqual(
        @as(usize, 1),
        countOccurrences(out, "negatives: exact status/reason and transactional preservation PASS; B2b numeric/dry-run and T6/P3 remain open"),
    );
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

test "classifier: later reload records are never the initial classification" {
    const golden = runner.GENERATED_HEADER ++
        "\n(load :ok true)\n(meta :bpm \"0000000000000000\")\n(reload :kind current :status 0)\n(load :ok false)\n";
    // The initial record is true; the later `(load :ok false)` is a reload
    // and must not overwrite it.
    try t.expectEqual(true, (try runner.parseInitialLoad(golden)).initial_ok);
}

test "classifier: lifecycle records are known but never a classification" {
    const golden = runner.GENERATED_HEADER ++
        "\n(load :ok true)\n" ++
        "(reload :kind bad-version :skipped binary-only)\n" ++
        "(registry-mismatch :mode structural :skipped binary-only)\n" ++
        "(load :ok false)\n";
    try t.expectEqual(true, (try runner.parseInitialLoad(golden)).initial_ok);
    // Unknown heads are still refused; lifecycle heads are not a silent
    // wildcard for arbitrary records.
    try t.expectError(
        error.UnknownTopLevelForm,
        runner.parseInitialLoad(runner.GENERATED_HEADER ++ "\n(load :ok true)\n(reloadx :kind current)\n"),
    );
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

test "pack guard: a clean pattern packs and replays through the real loader" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, PATTERN_SOURCE, &HOST_TARGETS);
    defer driver.deinit();
    try t.expect(driver.result.ok());

    // A3+A4: the clean pattern case packs through the SAME orchestration a
    // non-pattern case uses — preflight accepts (nothing to refuse), encode
    // emits — and the bytes replay through the real production loader.
    const packed_case = try runner.packCase(a, &driver.result, &HOST_TARGETS);
    const pacb = switch (packed_case) {
        .encoded => |bytes| bytes,
        .preflight_refused => return error.TestUnexpectedResult, // preflight must accept
        .compile_refused => return error.TestUnexpectedResult,
    };
    try t.expect(pacb.len > 0);

    defer NativeRt.reset();
    NativeRt.reset();

    const pact_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&HOST_TARGETS));
    const pact = try pacer.PactCodec.encodeTargets(&HOST_TARGETS, pact_buf);
    try t.expect(pact.len <= NativeRt.targetsCap());
    try t.expect(pacb.len <= NativeRt.pacbCap());
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(@as(u32, 0), NativeRt.load(@intCast(pacb.len), @intCast(pact.len)));

    // The loaded score IS the pattern score: the binary frame at tick 0 is
    // byte-identical to the text arm's (slot 0 of cycle 0 writes 0.1).
    const evaluator = &driver.evaluator.?;
    const want_entries = try evaluator.evalSeconds(0);
    var want_buf: [pacer.Writes.encodedLen(pacer.EvalCore.MAX_FRAME_ENTRIES)]u8 = undefined;
    const want = try pacer.Writes.encode(want_entries, &want_buf);
    const got_len = NativeRt.evalSeconds(0);
    try t.expectEqual(want.len, got_len);
    try t.expectEqualSlices(u8, want, NativeRt.writesPtr()[0..got_len]);

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

// ---------------------------------------------------------------------------
// Lifecycle per-path table — actual drv_load vs actual prt_load
// ---------------------------------------------------------------------------

const LIFECYCLE_TARGETS = [_]pacer.Compile.Target{
    .{ .name = "alpha", .ncomp = 1, .registry = 0 },
    .{ .name = "bravo", .ncomp = 1, .registry = 0 },
    .{ .name = "lift", .ncomp = 1, .registry = 0 },
};

const LIFECYCLE_SOURCE: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4])
    \\(control :id depth :target alpha :value 0.25)
    \\(track :target alpha (key :at 0b :value 0.2) (key :at 4b :value 0.8))
    \\(track :target bravo :expr (/ 1 (- beat 1)))
;

const LIFECYCLE_DIAGNOSTIC: []const u8 = "(transport :bpm 0)\n";
const REASON_VERSION: u32 = 1;
const REASON_REGISTRY_MISMATCH: u32 = 9;
const NO_SLOT: u32 = 0xffff_ffff;

fn lifecyclePact(a: std.mem.Allocator) ![]const u8 {
    const buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&LIFECYCLE_TARGETS));
    return pacer.PactCodec.encodeTargets(&LIFECYCLE_TARGETS, buf);
}

fn lifecyclePack(a: std.mem.Allocator, result: *const pacer.Compile.CompileResult) ![]const u8 {
    var diags: std.ArrayList(pacer.Compile.Diagnostic) = .empty;
    try pacer.PacbEncode.preflight(a, result, &diags);
    try t.expectEqual(@as(usize, 0), diags.items.len);
    return pacer.PacbEncode.encode(a, result, &LIFECYCLE_TARGETS);
}

fn loadBoth(doc: []const u8, pacb: []const u8, pact: []const u8) !void {
    try t.expect(pacb.len <= @as(usize, NativeRt.pacbCap()));
    try t.expect(pact.len <= @as(usize, NativeRt.targetsCap()));
    try t.expect(doc.len <= @as(usize, NativeText.docCap()));
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(@as(u32, 0), NativeRt.load(@intCast(pacb.len), @intCast(pact.len)));
    @memcpy(NativeText.docPtr()[0..doc.len], doc);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(@as(u32, 0), NativeText.load(@intCast(doc.len), @intCast(pact.len)));
}

fn captureTextFrame(a: std.mem.Allocator, seconds: f64) ![]const u8 {
    const len = NativeText.evalSeconds(seconds);
    try t.expect(len > 0);
    return a.dupe(u8, NativeText.writesPtr()[0..len]);
}

fn captureRtFrame(a: std.mem.Allocator, seconds: f64) ![]const u8 {
    const len = NativeRt.evalSeconds(seconds);
    try t.expect(len > 0);
    return a.dupe(u8, NativeRt.writesPtr()[0..len]);
}

fn captureTextMeta(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8, NativeText.metaPtr()[0..NativeText.metaLen()]);
}

fn captureRtMeta(a: std.mem.Allocator) ![]const u8 {
    return a.dupe(u8, NativeRt.metaPtr()[0..NativeRt.metaLen()]);
}

fn expectSameSlice(want: []const u8, got: []const u8) !void {
    try t.expectEqualSlices(u8, want, got);
}

test "lifecycle: text bad-call preserves, diagnostics unloads, current resets" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, LIFECYCLE_SOURCE, &LIFECYCLE_TARGETS);
    defer driver.deinit();
    try t.expect(driver.result.ok());

    const pacb = try lifecyclePack(a, &driver.result);
    const pact = try lifecyclePact(a);

    defer NativeRt.reset();
    defer NativeText.reset();
    NativeRt.reset();
    NativeText.reset();
    try loadBoth(LIFECYCLE_SOURCE, pacb, pact);

    const text_frame = try captureTextFrame(a, 0.3);
    const rt_frame = try captureRtFrame(a, 0.3);
    try expectSameSlice(text_frame, rt_frame);
    const text_meta = try captureTextMeta(a);
    const rt_meta = try captureRtMeta(a);
    try expectSameSlice(text_meta, rt_meta);

    // bad-call: both status 2; everything preserved, including the
    // binary reason word.
    const reason_before = NativeRt.loadError();
    try t.expectEqual(@as(u32, 2), NativeText.load(NativeText.docCap() + 1, 0));
    try t.expectEqual(@as(u32, 2), NativeRt.load(NativeRt.pacbCap() + 1, 0));
    try t.expectEqual(reason_before, NativeRt.loadError());
    try expectSameSlice(text_frame, try captureTextFrame(a, 0.3));
    try expectSameSlice(rt_frame, try captureRtFrame(a, 0.3));
    try expectSameSlice(text_meta, try captureTextMeta(a));
    try expectSameSlice(rt_meta, try captureRtMeta(a));
    try t.expectEqual(@as(u32, 0), NativeText.exprFailures());
    try t.expectEqual(@as(u32, 0), NativeRt.exprFailures());
    try t.expect(NativeText.metaLen() > 0);

    // diagnostics: text status 1, unloaded (meta 0, eval 0), real PACD.
    // The binary arm is not packed or loaded here; its live score remains.
    @memcpy(NativeText.docPtr()[0..LIFECYCLE_DIAGNOSTIC.len], LIFECYCLE_DIAGNOSTIC);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(
        @as(u32, 1),
        NativeText.load(@intCast(LIFECYCLE_DIAGNOSTIC.len), @intCast(pact.len)),
    );
    try t.expectEqual(@as(u32, 0), NativeText.metaLen());
    try t.expectEqual(@as(u32, 0), NativeText.evalSeconds(0.3));
    try t.expect(NativeText.diagLen() > pacer.Abi.DIAGS_HEADER_LEN);
    const diag = pacer.Abi.decodeDiags(NativeText.diagPtr()[0..NativeText.diagLen()]) orelse
        return error.TestUnexpectedResult;
    try t.expect(diag.count > 0);
    try expectSameSlice(rt_frame, try captureRtFrame(a, 0.3));
    try expectSameSlice(rt_meta, try captureRtMeta(a));

    // current: both reload valid A; state/counters reset.
    @memcpy(NativeText.docPtr()[0..LIFECYCLE_SOURCE.len], LIFECYCLE_SOURCE);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(
        @as(u32, 0),
        NativeText.load(@intCast(LIFECYCLE_SOURCE.len), @intCast(pact.len)),
    );
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(@as(u32, 0), NativeRt.load(@intCast(pacb.len), @intCast(pact.len)));
    try t.expectEqual(@as(u32, 0), NativeText.exprFailures());
    try t.expectEqual(@as(u32, 0), NativeRt.exprFailures());
    try expectSameSlice(text_frame, try captureTextFrame(a, 0.3));
    try expectSameSlice(rt_frame, try captureRtFrame(a, 0.3));
    try expectSameSlice(text_meta, try captureTextMeta(a));
    try expectSameSlice(rt_meta, try captureRtMeta(a));
}

test "lifecycle: refusals preserve held state/counters; registry mismatches are valid PACT" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, LIFECYCLE_SOURCE, &LIFECYCLE_TARGETS);
    defer driver.deinit();
    try t.expect(driver.result.ok());

    const pacb = try lifecyclePack(a, &driver.result);
    const pact = try lifecyclePact(a);

    defer NativeRt.reset();
    defer NativeText.reset();
    NativeRt.reset();
    NativeText.reset();
    try loadBoth(LIFECYCLE_SOURCE, pacb, pact);

    const initial_text_meta = try captureTextMeta(a);
    const initial_rt_meta = try captureRtMeta(a);
    // 0.6 s at 120 bpm is beat 1.2: no omission, counter stays 0.
    const reset_text_frame = try captureTextFrame(a, 0.6);
    const reset_rt_frame = try captureRtFrame(a, 0.6);
    // 0.5 s is beat 1: the expr omits bravo and increments the counter.
    const fail_text_frame = try captureTextFrame(a, 0.5);
    const fail_rt_frame = try captureRtFrame(a, 0.5);
    try expectSameSlice(fail_text_frame, fail_rt_frame);
    try t.expectEqual(@as(u32, 1), NativeText.exprFailures());
    try t.expectEqual(@as(u32, 1), NativeRt.exprFailures());

    // Held document control + dynamic slot + BPM nudge.
    const text_slot = NativeText.registerControl(2, 0, 1);
    const rt_slot = NativeRt.registerControl(2, 0, 1);
    try t.expect(text_slot != NO_SLOT);
    try t.expectEqual(text_slot, rt_slot);
    try t.expectEqual(@as(u32, 0), NativeText.setControl(text_slot, 1, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), NativeRt.setControl(rt_slot, 1, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), NativeText.setBpm(100));
    try t.expectEqual(@as(u32, 0), NativeRt.setBpm(100));

    // 0.6 s at 100 bpm is exactly beat 1: omit + counter increment. This
    // witness shows held control, dynamic slot and the BPM effect.
    const witness_text = try captureTextFrame(a, 0.6);
    const witness_rt = try captureRtFrame(a, 0.6);
    try expectSameSlice(witness_text, witness_rt);
    try t.expectEqual(@as(u32, 2), NativeText.exprFailures());
    try t.expectEqual(@as(u32, 2), NativeRt.exprFailures());
    const held_rt_meta = try captureRtMeta(a);

    // bad-version: binary status 1/reason 1, A live, state preserved;
    // text is an explicit binary-only skip.
    const corrupt = try a.dupe(u8, pacb);
    std.mem.writeInt(u32, corrupt[4..8], 99, .little);
    @memcpy(NativeRt.pacbPtr()[0..corrupt.len], corrupt);
    try t.expectEqual(@as(u32, 1), NativeRt.load(@intCast(corrupt.len), @intCast(pact.len)));
    try t.expectEqual(REASON_VERSION, NativeRt.loadError());
    try t.expectEqual(@as(u32, 2), NativeRt.exprFailures());
    try t.expectEqual(@as(u32, 2), NativeText.exprFailures());
    try expectSameSlice(witness_rt, try captureRtFrame(a, 0.6));
    try t.expectEqual(@as(u32, 3), NativeRt.exprFailures());
    try expectSameSlice(held_rt_meta, try captureRtMeta(a));
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    try expectSameSlice(witness_text, try captureTextFrame(a, 0.6));
    try t.expectEqual(@as(u32, 3), NativeText.exprFailures());

    // Structural mismatch: a valid ncomp change, status 1/reason 9.
    var structural = try a.dupe(pacer.Compile.Target, &LIFECYCLE_TARGETS);
    structural[0].ncomp = 2;
    const structural_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(structural));
    const structural_pact = try pacer.PactCodec.encodeTargets(structural, structural_buf);
    @memcpy(NativeRt.targetsPtr()[0..structural_pact.len], structural_pact);
    const count_before_structural = NativeRt.exprFailures();
    try t.expectEqual(
        @as(u32, 1),
        NativeRt.load(@intCast(pacb.len), @intCast(structural_pact.len)),
    );
    try t.expectEqual(REASON_REGISTRY_MISMATCH, NativeRt.loadError());
    try t.expectEqual(count_before_structural, NativeRt.exprFailures());
    try expectSameSlice(witness_rt, try captureRtFrame(a, 0.6));
    try expectSameSlice(held_rt_meta, try captureRtMeta(a));
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);

    // Name swap: only ordered names change; same lengths, shapes,
    // registries and count — still a VALID canonical PACT, reason 9.
    var swapped = try a.dupe(pacer.Compile.Target, &LIFECYCLE_TARGETS);
    try t.expect(!std.mem.eql(u8, swapped[0].name, swapped[1].name));
    try t.expectEqual(swapped[0].name.len, swapped[1].name.len);
    try t.expectEqual(swapped[0].ncomp, swapped[1].ncomp);
    try t.expectEqual(swapped[0].registry, swapped[1].registry);
    std.mem.swap([]const u8, &swapped[0].name, &swapped[1].name);
    const swapped_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(swapped));
    const swapped_pact = try pacer.PactCodec.encodeTargets(swapped, swapped_buf);
    try t.expectEqual(structural_pact.len, swapped_pact.len);
    @memcpy(NativeRt.targetsPtr()[0..swapped_pact.len], swapped_pact);
    const count_before_swap = NativeRt.exprFailures();
    try t.expectEqual(
        @as(u32, 1),
        NativeRt.load(@intCast(pacb.len), @intCast(swapped_pact.len)),
    );
    try t.expectEqual(REASON_REGISTRY_MISMATCH, NativeRt.loadError());
    try t.expectEqual(count_before_swap, NativeRt.exprFailures());
    try expectSameSlice(witness_rt, try captureRtFrame(a, 0.6));
    try expectSameSlice(held_rt_meta, try captureRtMeta(a));
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    try expectSameSlice(witness_text, try captureTextFrame(a, 0.6));

    // current: both reset; the original document reproduces its initial
    // frame/meta and counters are zero again.
    @memcpy(NativeText.docPtr()[0..LIFECYCLE_SOURCE.len], LIFECYCLE_SOURCE);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(
        @as(u32, 0),
        NativeText.load(@intCast(LIFECYCLE_SOURCE.len), @intCast(pact.len)),
    );
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(@as(u32, 0), NativeRt.load(@intCast(pacb.len), @intCast(pact.len)));
    try t.expectEqual(@as(u32, 0), NativeText.exprFailures());
    try t.expectEqual(@as(u32, 0), NativeRt.exprFailures());
    try expectSameSlice(reset_text_frame, try captureTextFrame(a, 0.6));
    try expectSameSlice(reset_rt_frame, try captureRtFrame(a, 0.6));
    try expectSameSlice(initial_text_meta, try captureTextMeta(a));
    try expectSameSlice(initial_rt_meta, try captureRtMeta(a));
}

// ---------------------------------------------------------------------------
// Generic lifecycle replay contracts — binary03 P2 correction.
//
// These drive `replayLifecycleCase` itself (the generic adapter), not a
// case-specific copy. The counters must follow the ACTUAL equivalent
// evaluation sequence: a key-only frame increments zero, two failing
// expressions increment two, and the focused one-omission anchor above
// keeps its exact 2 -> 3 expectation.
// ---------------------------------------------------------------------------

const ZERO_OMISSION_TARGETS = [_]pacer.Compile.Target{
    .{ .name = "radius", .ncomp = 1, .registry = 0 },
};

const MULTI_OMISSION_SOURCE: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4])
    \\(track :target alpha :expr (/ 1 (- beat 1)))
    \\(track :target bravo :expr (/ 1 (- beat 1)))
;

const MULTI_OMISSION_TARGETS = [_]pacer.Compile.Target{
    .{ .name = "alpha", .ncomp = 1, .registry = 0 },
    .{ .name = "bravo", .ncomp = 1, .registry = 0 },
};

const ZERO_BITS: u64 = 0x0000000000000000;
const HALF_BITS: u64 = 0x3FE0000000000000;

/// Compile and pack one clean score, then run a lifecycle script through the
/// generic replay exactly as the corpus walk does.
fn replayLifecycleScript(
    a: std.mem.Allocator,
    doc: [:0]const u8,
    host_targets: []const pacer.Compile.Target,
    steps: []const CorpusHarness.Step,
) !void {
    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, doc, host_targets);
    defer driver.deinit();
    try t.expect(driver.result.ok());

    const packed_case = try runner.packCase(a, &driver.result, host_targets);
    const pacb = switch (packed_case) {
        .encoded => |bytes| bytes,
        else => return error.TestUnexpectedResult,
    };
    const harness: CorpusHarness.Harness = .{ .targets = &.{}, .steps = steps };
    var sink: std.Io.Writer.Allocating = .init(a);
    defer sink.deinit();

    defer NativeRt.reset();
    defer NativeText.reset();
    try runner.replayLifecycleCase(
        a,
        &sink.writer,
        "generic-lifecycle-replay",
        &driver,
        harness,
        host_targets,
        doc,
        pacb,
    );
}

test "lifecycle replay: zero-omission post-refusal eval keeps both counters" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A key-only score has no failing expression: the post-refusal eval is
    // valid and both counters remain unchanged. The generic adapter must not
    // claim a literal +1 that belongs only to the authored anchor.
    try replayLifecycleScript(a, CLEAN_SOURCE, &ZERO_OMISSION_TARGETS, &.{
        .{ .eval = ZERO_BITS },
        .{ .reload = .bad_version },
        .{ .eval = HALF_BITS },
    });
}

test "lifecycle replay: multiple omissions move both counters by the same actual count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Two expr tracks omit on the same frame: the equivalent sequence adds
    // two to each counter, not the anchor's literal one.
    try replayLifecycleScript(a, MULTI_OMISSION_SOURCE, &MULTI_OMISSION_TARGETS, &.{
        .{ .reload = .bad_version },
        .{ .eval = HALF_BITS },
    });
}

test "lifecycle replay: terminal diagnostics is a valid script end" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The specified outcome is text unloaded / binary still live; the
    // contract never required a final `current`.
    try replayLifecycleScript(a, LIFECYCLE_SOURCE, &LIFECYCLE_TARGETS, &.{
        .{ .reload = .diagnostics },
    });
}

test "lifecycle replay: terminal bad-version is valid without a following eval" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A refused load may end the script; the counter probe is not a required
    // postcondition. The refusal itself still preserves both paths' state.
    try replayLifecycleScript(a, LIFECYCLE_SOURCE, &LIFECYCLE_TARGETS, &.{
        .{ .eval = HALF_BITS },
        .{ .reload = .bad_version },
    });
}

test "lifecycle replay: diagnostics then bad-call keeps the unloaded text state" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A bad call preserves whatever state precedes it; after diagnostics
    // that state is unloaded text / live binary. The following eval must be
    // zero on the text path and still live on the binary path.
    try replayLifecycleScript(a, LIFECYCLE_SOURCE, &LIFECYCLE_TARGETS, &.{
        .{ .reload = .diagnostics },
        .{ .reload = .bad_call },
        .{ .eval = HALF_BITS },
    });
}

test "lifecycle replay: diagnostics then bad-version needs no live text session" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `bad-version` is an explicit binary-only skip. During the intentional
    // text-unloaded divergence the binary refusal is still valid and the
    // script may finish without restoring the text score.
    try replayLifecycleScript(a, LIFECYCLE_SOURCE, &LIFECYCLE_TARGETS, &.{
        .{ .reload = .diagnostics },
        .{ .reload = .bad_version },
    });
}

test "lifecycle replay: diagnostics then registry probe uses the live binary state" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The registry probe is binary-only too; an unloaded text session must
    // not prevent the live binary from reaching reason 9, and the final
    // assertions remain per path.
    try replayLifecycleScript(a, LIFECYCLE_SOURCE, &LIFECYCLE_TARGETS, &.{
        .{ .reload = .diagnostics },
        .{ .registry_mismatch = .structural },
        .{ .eval = HALF_BITS },
    });
}
