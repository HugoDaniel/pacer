//! Native composition preflight — binary03 T1.
//!
//! This is a REAL public-module consumer, not a source-local substitute:
//! it loads `@import("pacer")`, preloads the public schema, compiles a
//! clean score through a stationary public `Driver`, runs the public pack
//! preflight, and encodes the `'PACB'`/`'PACT'` bytes the runtime consumes.
//! The actual playback object is compiled SEPARATELY from
//! `native_rt_bridge.zig` and linked here; this file never imports
//! `rt_entry.zig` (or any other pacer source). Calls reach the production
//! `prt_*` definitions only through the std-only `NativeRt` extern facade.
//!
//! Both entry points — the installable executable's `main` and the named
//! test below — run the same assertion function, so the build gate proves
//! the composition in BOTH executable and test-runner link modes. The
//! sequence is the T1 contract: real load → seconds/tick eval → complete
//! PACW/PACM copies → version-corrupt refused reload (status 1/reason 1)
//! with the live score preserved → cleanup (zero eval/meta) → a fresh
//! successful load → cleanup. `NativeRt.reset()` is deferred before the
//! first load, is idempotent, and is exercised again explicitly.
//!
//! No native pointer travels through a wasm32 `u32`; the facade's pointer
//! returns stay pointer types and every length/status stays `u32`.

const std = @import("std");
const pacer = @import("pacer");
const NativeRt = @import("NativeRt.zig");
const NativeText = @import("NativeText.zig");

const t = std.testing;

/// The real host join — two distinct registries, one document control.
const HOST_TARGETS = [_]pacer.Compile.Target{
    .{ .name = "glow", .ncomp = 1, .registry = 0 },
    .{ .name = "level", .ncomp = 1, .registry = 1 },
};

/// A clean constant-tempo score: a key track on `glow`, and a document
/// control on `level`, so eval, controls, BPM nudging and registration all
/// have real production state to touch.
const SCORE_SOURCE: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
    \\(control :id depth :target level :min 0 :max 1 :value 0.25)
    \\(track :target glow (key :at 0b :value 0.2) (key :at 4b :value 0.8))
;

/// The fixed test-harness-only diagnostic source (binary03 T5b names it).
/// It is never packed or serialized; T5a only proves the real text entry
/// produces actual `'PACD'` diagnostics and unloads the previous score.
const DIAGNOSTIC_SOURCE: []const u8 = "(transport :bpm 0)\n";

/// `prt_registerControl`'s frozen failure sentinel (rt_entry.NO_SLOT).
const NO_SLOT: u32 = 0xffff_ffff;

pub fn main(init: std.process.Init) !void {
    try runComposition(init.gpa);
}

test "native composition: public pacer consumer + actual private runtime object" {
    try runComposition(t.allocator);
}

fn runComposition(gpa: std.mem.Allocator) !void {
    // Deferred BEFORE the first load: every assertion/error exit tears BOTH
    // production sessions down. The initial calls also prove idempotence.
    defer NativeRt.reset();
    NativeRt.reset();
    defer NativeText.reset();
    NativeText.reset();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // --- The live public-module consumer -------------------------------
    // Schema load + in-place Driver are the public host path; nothing here
    // reaches into a core/runtime source tree.
    var schema = try pacer.Schema.load(a);
    defer schema.deinit();

    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, SCORE_SOURCE, &HOST_TARGETS);
    defer driver.deinit();
    try t.expect(driver.result.ok());
    try t.expect(driver.evaluator != null);

    var diags: std.ArrayList(pacer.Compile.Diagnostic) = .empty;
    defer diags.deinit(a);
    try pacer.PacbEncode.preflight(a, &driver.result, &diags);
    try t.expectEqual(@as(usize, 0), diags.items.len);
    const pacb = try pacer.PacbEncode.encode(a, &driver.result, &HOST_TARGETS);

    var pact_buf: [256]u8 = undefined;
    const pact = try pacer.PactCodec.encodeTargets(&HOST_TARGETS, &pact_buf);

    // --- Real runtime zones --------------------------------------------
    // Check caps BEFORE copying/narrowing; pointer values stay pointers.
    try t.expect(pacb.len <= @as(usize, NativeRt.pacbCap()));
    try t.expect(pact.len <= @as(usize, NativeRt.targetsCap()));
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);

    try t.expectEqual(@as(u32, 1), NativeRt.abiVersion());
    try t.expectEqual(@as(u32, 0), NativeRt.load(@intCast(pacb.len), @intCast(pact.len)));
    try t.expect(NativeRt.metaLen() > 0);

    // The runtime serves the score's own embedded PACM; the public
    // producer's fresh encodeMeta is the byte oracle.
    const meta = try a.dupe(u8, NativeRt.metaPtr()[0..NativeRt.metaLen()]);
    const want_meta = try a.alloc(u8, pacer.Abi.metaEncodedLen(&driver.result));
    _ = try pacer.Abi.encodeMeta(&driver.result, want_meta);
    try t.expectEqualSlices(u8, want_meta, meta);

    // Actual seconds/tick evaluation, compared byte-for-byte with the
    // public driver's own encoded frames.
    try expectSecondsFrame(&driver, 0.3);
    try expectTicksFrame(&driver, 7);

    // --- Controls / BPM / registration --------------------------------
    try t.expectEqual(@as(u32, 0), NativeRt.setControl(0, 0.9, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), NativeRt.setBpm(240));
    try t.expect(driver.evaluator.?.setControl(0, .{ 0.9, 0, 0, 0 }));
    try t.expect(driver.evaluator.?.setBpm(240));
    try expectSecondsFrame(&driver, 0.3);
    try expectTicksFrame(&driver, 7);

    // The registration surface's u32 sentinel, then a real dynamic slot.
    try t.expectEqual(NO_SLOT, NativeRt.registerControl(0, 256, 1)); // registry > u8
    try t.expectEqual(NO_SLOT, NativeRt.registerControl(0, 0, 0)); // ncomp < 1
    const slot = NativeRt.registerControl(3, 1, 1);
    try t.expect(slot != NO_SLOT);
    try t.expectEqual(@as(u32, 0), NativeRt.setControl(slot, 0.5, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), NativeRt.clearControl(slot));
    try t.expectEqual(@as(u32, 1), NativeRt.clearControl(999));
    try t.expectEqual(@as(u32, 0), NativeRt.exprFailures());

    // --- Complete PACW/PACM copies ------------------------------------
    const frame_seconds = try captureWrites(a, NativeRt.evalSeconds(0.3));
    const frame_ticks = try captureWrites(a, NativeRt.evalTicks(7));
    const meta_before = try a.dupe(u8, NativeRt.metaPtr()[0..NativeRt.metaLen()]);

    // --- Version-corrupt reload: status 1/reason 1, old score intact ---
    const corrupt = try a.dupe(u8, pacb);
    std.mem.writeInt(u32, corrupt[4..8], 99, .little);
    @memcpy(NativeRt.pacbPtr()[0..corrupt.len], corrupt);
    try t.expectEqual(@as(u32, 1), NativeRt.load(@intCast(corrupt.len), @intCast(pact.len)));
    try t.expectEqual(@as(u32, 1), NativeRt.loadError()); // unsupported_version
    try t.expectEqualSlices(u8, frame_seconds, try captureWrites(a, NativeRt.evalSeconds(0.3)));
    try t.expectEqualSlices(u8, frame_ticks, try captureWrites(a, NativeRt.evalTicks(7)));
    try t.expectEqualSlices(u8, meta_before, NativeRt.metaPtr()[0..NativeRt.metaLen()]);

    // --- Cleanup, zero surface, fresh load, cleanup -------------------
    NativeRt.reset();
    try t.expectEqual(@as(u32, 0), NativeRt.evalSeconds(0.3));
    try t.expectEqual(@as(u32, 0), NativeRt.evalTicks(7));
    try t.expectEqual(@as(u32, 0), NativeRt.metaLen());
    try t.expectEqual(@as(u32, 0), NativeRt.loadError());
    try t.expectEqual(NO_SLOT, NativeRt.registerControl(0, 0, 1));

    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    try t.expectEqual(@as(u32, 0), NativeRt.load(@intCast(pacb.len), @intCast(pact.len)));
    try t.expect(NativeRt.evalSeconds(0.3) > 0);
    NativeRt.reset();
    try t.expectEqual(@as(u32, 0), NativeRt.evalSeconds(0.3));
    try t.expectEqual(@as(u32, 0), NativeRt.metaLen());
    NativeRt.reset(); // repeated cleanup is safe
    try t.expectEqual(@as(u32, 0), NativeRt.metaLen());

    // --- Actual native text entry: real `drv_*` lifecycle --------------
    try runTextLifecycle(a, &driver, pact);
}

/// The T5a text-object proof. Every call below reaches the REAL `drv_*`
/// definitions in the separately compiled native text object; this
/// consumer imports only the std-only `NativeText` C facade. The public
/// `Driver` above stays the stationary metadata/frame oracle throughout.
fn runTextLifecycle(
    a: std.mem.Allocator,
    oracle: *pacer.Driver,
    pact: []const u8,
) !void {
    // The oracle's initial PACM is the byte truth for the first text load.
    const want_meta = try a.alloc(u8, pacer.Abi.metaEncodedLen(&oracle.result));
    _ = try pacer.Abi.encodeMeta(&oracle.result, want_meta);

    try t.expectEqual(@as(u32, 1), NativeText.abiVersion());
    try t.expect(@as(usize, NativeText.docCap()) >= SCORE_SOURCE.len);
    try t.expect(@as(usize, NativeText.targetsCap()) >= pact.len);

    // --- Clean load: status 0, state/control/BPM, copied blobs ---------
    @memcpy(NativeText.docPtr()[0..SCORE_SOURCE.len], SCORE_SOURCE);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(
        @as(u32, 0),
        NativeText.load(@intCast(SCORE_SOURCE.len), @intCast(pact.len)),
    );
    try t.expect(NativeText.metaLen() > 0);
    try t.expectEqualSlices(u8, want_meta, NativeText.metaPtr()[0..NativeText.metaLen()]);

    // A clean load still encodes a PACD header with zero records.
    const diag_clean = try a.dupe(u8, NativeText.diagPtr()[0..NativeText.diagLen()]);
    const clean_view = pacer.Abi.decodeDiags(diag_clean) orelse
        return error.TestUnexpectedResult;
    try t.expectEqual(@as(u32, 0), clean_view.count);

    try t.expectEqual(@as(u32, 0), NativeText.setControl(0, 0.9, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), NativeText.setBpm(240));
    try t.expect(oracle.evaluator.?.setControl(0, .{ 0.9, 0, 0, 0 }));
    try t.expect(oracle.evaluator.?.setBpm(240));
    try expectTextSecondsFrame(oracle, 0.3);
    try expectTextTicksFrame(oracle, 7);

    const frame_seconds = try captureTextWrites(a, NativeText.evalSeconds(0.3));
    const frame_ticks = try captureTextWrites(a, NativeText.evalTicks(7));
    const meta_before = try a.dupe(u8, NativeText.metaPtr()[0..NativeText.metaLen()]);
    const diag_before = try a.dupe(u8, NativeText.diagPtr()[0..NativeText.diagLen()]);

    // --- Over-cap bad call: status 2, every output preserved -----------
    // docCap() + 1 is the rejected length; nothing out of bounds is read
    // or copied. Native pointers never pass through a u32 cast.
    try t.expectEqual(
        @as(u32, 2),
        NativeText.load(NativeText.docCap() + 1, @intCast(pact.len)),
    );
    try t.expectEqualSlices(u8, frame_seconds, try captureTextWrites(a, NativeText.evalSeconds(0.3)));
    try t.expectEqualSlices(u8, frame_ticks, try captureTextWrites(a, NativeText.evalTicks(7)));
    try t.expectEqualSlices(u8, meta_before, NativeText.metaPtr()[0..NativeText.metaLen()]);
    try t.expectEqualSlices(u8, diag_before, NativeText.diagPtr()[0..NativeText.diagLen()]);

    // --- Fixed diagnostic source: status 1, real PACD, unloaded --------
    @memcpy(NativeText.docPtr()[0..DIAGNOSTIC_SOURCE.len], DIAGNOSTIC_SOURCE);
    try t.expectEqual(
        @as(u32, 1),
        NativeText.load(@intCast(DIAGNOSTIC_SOURCE.len), @intCast(pact.len)),
    );
    try t.expect(NativeText.diagLen() > pacer.Abi.DIAGS_HEADER_LEN);
    try t.expectEqual(@as(u32, 0), NativeText.evalSeconds(0.3));
    try t.expectEqual(@as(u32, 0), NativeText.evalTicks(7));
    try t.expectEqual(@as(u32, 0), NativeText.metaLen());

    const diag_blob = NativeText.diagPtr()[0..NativeText.diagLen()];
    const diag_view = pacer.Abi.decodeDiags(diag_blob) orelse
        return error.TestUnexpectedResult;
    try t.expect(diag_view.count > 0);
    var records = diag_view.records();
    var decoded: u32 = 0;
    while (records.next()) |record| {
        decoded += 1;
        try t.expect(record.message.len > 0);
    }
    try t.expectEqual(diag_view.count, decoded);

    // --- Cleanup from the diagnostic session: diagnostic state cleared -
    NativeText.reset();
    try expectTextUnloaded();

    // --- Fresh load after diagnostic teardown --------------------------
    @memcpy(NativeText.docPtr()[0..SCORE_SOURCE.len], SCORE_SOURCE);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(
        @as(u32, 0),
        NativeText.load(@intCast(SCORE_SOURCE.len), @intCast(pact.len)),
    );
    try t.expect(NativeText.metaLen() > 0);
    try t.expect(NativeText.evalSeconds(0.3) > 0);

    // --- Cleanup directly from a live clean score, then idempotence ----
    NativeText.reset();
    try expectTextUnloaded();
    NativeText.reset();
    try expectTextUnloaded();

    // --- Fresh load after clean teardown, then final cleanup -----------
    @memcpy(NativeText.docPtr()[0..SCORE_SOURCE.len], SCORE_SOURCE);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);
    try t.expectEqual(
        @as(u32, 0),
        NativeText.load(@intCast(SCORE_SOURCE.len), @intCast(pact.len)),
    );
    try t.expect(NativeText.evalSeconds(0.3) > 0);
    NativeText.reset();
    try expectTextUnloaded();

    // The public oracle was never part of the text object's session: it
    // still compiles, evaluates, and encodes the same immutable PACM.
    try t.expect(oracle.result.ok());
    const entries = try oracle.evaluator.?.evalSeconds(0.3);
    var oracle_writes: [pacer.Writes.encodedLen(pacer.EvalCore.MAX_FRAME_ENTRIES)]u8 = undefined;
    _ = try pacer.Writes.encode(entries, &oracle_writes);
    const oracle_meta = try a.alloc(u8, pacer.Abi.metaEncodedLen(&oracle.result));
    _ = try pacer.Abi.encodeMeta(&oracle.result, oracle_meta);
    try t.expectEqualSlices(u8, want_meta, oracle_meta);
}

fn expectTextSecondsFrame(oracle: *pacer.Driver, seconds: f64) !void {
    const entries = try oracle.evaluator.?.evalSeconds(seconds);
    try expectTextFrame(entries, NativeText.evalSeconds(seconds));
}

fn expectTextTicksFrame(oracle: *pacer.Driver, tick: i64) !void {
    const entries = oracle.evaluator.?.evalTicks(tick);
    try expectTextFrame(entries, NativeText.evalTicks(tick));
}

fn expectTextFrame(entries: []const pacer.Writes.Entry, got_len: u32) !void {
    try t.expect(got_len > 0);
    var want_buf: [pacer.Writes.encodedLen(pacer.EvalCore.MAX_FRAME_ENTRIES)]u8 = undefined;
    const want = try pacer.Writes.encode(entries, &want_buf);
    try t.expectEqualSlices(u8, want, NativeText.writesPtr()[0..got_len]);
}

fn captureTextWrites(a: std.mem.Allocator, len: u32) ![]u8 {
    try t.expect(len > 0);
    return a.dupe(u8, NativeText.writesPtr()[0..len]);
}

fn expectTextUnloaded() !void {
    try t.expectEqual(@as(u32, 0), NativeText.evalSeconds(0.3));
    try t.expectEqual(@as(u32, 0), NativeText.evalTicks(7));
    try t.expectEqual(@as(u32, 0), NativeText.metaLen());
    try t.expectEqual(@as(u32, 0), NativeText.diagLen());
}

/// Encode the public driver's frame and compare it with the production
/// runtime's last frame (the writes zone is reused per call, so the
/// runtime bytes are consumed immediately).
fn expectSecondsFrame(driver: *pacer.Driver, seconds: f64) !void {
    const entries = try driver.evaluator.?.evalSeconds(seconds);
    try expectSameFrame(entries, NativeRt.evalSeconds(seconds));
}

fn expectTicksFrame(driver: *pacer.Driver, tick: i64) !void {
    const entries = driver.evaluator.?.evalTicks(tick);
    try expectSameFrame(entries, NativeRt.evalTicks(tick));
}

fn expectSameFrame(entries: []const pacer.Writes.Entry, got_len: u32) !void {
    try t.expect(got_len > 0);
    var want_buf: [pacer.Writes.encodedLen(pacer.EvalCore.MAX_FRAME_ENTRIES)]u8 = undefined;
    const want = try pacer.Writes.encode(entries, &want_buf);
    try t.expectEqualSlices(u8, want, NativeRt.writesPtr()[0..got_len]);
}

fn captureWrites(a: std.mem.Allocator, len: u32) ![]u8 {
    try t.expect(len > 0);
    return a.dupe(u8, NativeRt.writesPtr()[0..len]);
}
