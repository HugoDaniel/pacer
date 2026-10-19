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

const builtin = @import("builtin");
const Rt = @import("rt_entry.zig");

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
}

/// The one native-only C symbol: ordered teardown of the production
/// session. `prt_*` definitions themselves stay in `rt_entry.zig`.
export fn pacer_native_rt_reset() callconv(.c) void {
    Rt.NativeHarness.reset();
}
