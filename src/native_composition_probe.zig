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

/// `prt_registerControl`'s frozen failure sentinel (rt_entry.NO_SLOT).
const NO_SLOT: u32 = 0xffff_ffff;

pub fn main(init: std.process.Init) !void {
    try runComposition(init.gpa);
}

test "native composition: public pacer consumer + actual private runtime object" {
    try runComposition(t.allocator);
}

fn runComposition(gpa: std.mem.Allocator) !void {
    // Deferred BEFORE the first load: every assertion/error exit tears the
    // production session down. The initial call also proves idempotence.
    defer NativeRt.reset();
    NativeRt.reset();

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
