//! `pacer-native-rt` object root — binary03 T1.
//!
//! The playback runtime is compiled SEPARATELY from the public `pacer`
//! module: this root imports the actual `rt_entry.zig`, so its source graph
//! owns the `prt_*` definitions exactly once per final native binary. A
//! public-module consumer never imports this file or `rt_entry.zig`; it
//! calls the C surface through the std-only `NativeRt` facade.
//!
//! Reachability is explicit, not incidental: taking the address of every
//! production alias in `Rt.NativeHarness` at comptime forces the imported
//! entry and its real `export fn` bodies into the object's analysis. The
//! aliases are internal-only — no wrapper re-exports the `prt_*` names, and
//! the sole additional C symbol is the native-only cleanup entry below.
//! Neither the namespace nor the cleanup symbol is exported through the
//! public `root.zig`, and this object is never linked into a wasm artifact.
//!
//! The `NativeRt` facade pins ITS OWN extern declarations against literal
//! types; C linkage does not compare the consumer declaration with the
//! producer definition. This object therefore pins every actual
//! `Rt.NativeHarness` alias against the same exact types. A producer-side
//! signature drift now fails here, in the separately compiled object that
//! owns the real `prt_*` definitions, instead of silently linking a
//! mismatched call site.

const builtin = @import("builtin");
const Rt = @import("rt_entry.zig");

/// Pin one producer alias to the C surface `NativeRt.zig` declares. Kept
/// separate from the facade so neither declaration is its own witness.
fn expectProducer(comptime name: []const u8, comptime actual: type, comptime expected: type) void {
    if (actual != expected)
        @compileError("native_rt_bridge: " ++ name ++ " producer ABI drift");
}

comptime {
    // Native link object only: the shipped wasm artifacts keep their own
    // frozen export sets and must never include the cleanup symbol.
    if (builtin.target.cpu.arch.isWasm())
        @compileError("native_rt_bridge: native-only link object");

    // Production alias reachability. Every alias the harness surface
    // promises is referenced here, including the ABI version; a renamed or
    // removed production export fails this object's compilation.
    _ = &Rt.NativeHarness.abiVersion;
    _ = &Rt.NativeHarness.pacbPtr;
    _ = &Rt.NativeHarness.pacbCap;
    _ = &Rt.NativeHarness.targetsPtr;
    _ = &Rt.NativeHarness.targetsCap;
    _ = &Rt.NativeHarness.load;
    _ = &Rt.NativeHarness.loadError;
    _ = &Rt.NativeHarness.metaPtr;
    _ = &Rt.NativeHarness.metaLen;
    _ = &Rt.NativeHarness.writesPtr;
    _ = &Rt.NativeHarness.evalSeconds;
    _ = &Rt.NativeHarness.evalTicks;
    _ = &Rt.NativeHarness.setControl;
    _ = &Rt.NativeHarness.clearControl;
    _ = &Rt.NativeHarness.registerControl;
    _ = &Rt.NativeHarness.setBpm;
    _ = &Rt.NativeHarness.exprFailures;
    _ = &Rt.NativeHarness.reset;

    // Producer-side ABI pins. These are the same literal types the std-only
    // `NativeRt` facade declares; a change on either side of the C boundary
    // now breaks a compilation rather than becoming an unchecked call.
    expectProducer("prt_abiVersion", @TypeOf(Rt.NativeHarness.abiVersion), fn () callconv(.c) u32);
    expectProducer("prt_pacbPtr", @TypeOf(Rt.NativeHarness.pacbPtr), fn () callconv(.c) [*]u8);
    expectProducer("prt_pacbCap", @TypeOf(Rt.NativeHarness.pacbCap), fn () callconv(.c) u32);
    expectProducer("prt_targetsPtr", @TypeOf(Rt.NativeHarness.targetsPtr), fn () callconv(.c) [*]u8);
    expectProducer("prt_targetsCap", @TypeOf(Rt.NativeHarness.targetsCap), fn () callconv(.c) u32);
    expectProducer("prt_load", @TypeOf(Rt.NativeHarness.load), fn (u32, u32) callconv(.c) u32);
    expectProducer("prt_loadError", @TypeOf(Rt.NativeHarness.loadError), fn () callconv(.c) u32);
    expectProducer("prt_metaPtr", @TypeOf(Rt.NativeHarness.metaPtr), fn () callconv(.c) [*]const u8);
    expectProducer("prt_metaLen", @TypeOf(Rt.NativeHarness.metaLen), fn () callconv(.c) u32);
    expectProducer("prt_writesPtr", @TypeOf(Rt.NativeHarness.writesPtr), fn () callconv(.c) [*]const u8);
    expectProducer("prt_eval", @TypeOf(Rt.NativeHarness.evalSeconds), fn (f64) callconv(.c) u32);
    expectProducer("prt_evalTicks", @TypeOf(Rt.NativeHarness.evalTicks), fn (i64) callconv(.c) u32);
    expectProducer("prt_setControl", @TypeOf(Rt.NativeHarness.setControl), fn (u32, f32, f32, f32, f32) callconv(.c) u32);
    expectProducer("prt_clearControl", @TypeOf(Rt.NativeHarness.clearControl), fn (u32) callconv(.c) u32);
    expectProducer("prt_registerControl", @TypeOf(Rt.NativeHarness.registerControl), fn (u32, u32, u32) callconv(.c) u32);
    expectProducer("prt_setBpm", @TypeOf(Rt.NativeHarness.setBpm), fn (f64) callconv(.c) u32);
    expectProducer("prt_exprFailures", @TypeOf(Rt.NativeHarness.exprFailures), fn () callconv(.c) u32);
    // `reset` is the object-local teardown called by the cleanup export
    // below, not an extern declaration; it keeps Zig's default convention.
    expectProducer("NativeHarness.reset", @TypeOf(Rt.NativeHarness.reset), fn () void);
}

/// The one native-only C symbol: ordered teardown of the production
/// session. `prt_*` definitions themselves stay in `rt_entry.zig`.
export fn pacer_native_rt_reset() callconv(.c) void {
    Rt.NativeHarness.reset();
}
