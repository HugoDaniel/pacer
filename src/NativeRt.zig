//! `NativeRt` — std-only extern facade for the production playback ABI.
//!
//! This file declares the EXACT C surface `src/rt_entry.zig` exports and
//! nothing else. It imports no Pacer or SJON source, carries no runtime
//! state, and is safe for a public-`pacer` consumer to compile beside the
//! separately built native playback object: symbols resolve at link time
//! to the single real `prt_*` definitions in that object, never to a
//! copy, wrapper, or second runtime.
//!
//! Pointers are real native pointers. Lengths, statuses, the widened
//! `prt_loadError` word and every scalar stay `u32`; the evaluator's
//! `f64`/`i64`/`f32` arguments keep their production widths. The
//! `comptime` block below pins every FACADE declaration, so this file's
//! own call sites cannot drift. It does not compare against the producer:
//! C linkage cannot, so `src/native_rt_bridge.zig` separately pins the
//! actual `Rt.NativeHarness` alias types in the object that owns the real
//! `prt_*` definitions. Both sides must change together to compile.
//!
//! `reset` is the one native-only cleanup symbol (`pacer_native_rt_reset`),
//! defined by `src/native_rt_bridge.zig`; it is never part of a wasm
//! artifact and is not reachable from public `pacer`.

pub extern fn prt_abiVersion() callconv(.c) u32;
pub extern fn prt_pacbPtr() callconv(.c) [*]u8;
pub extern fn prt_pacbCap() callconv(.c) u32;
pub extern fn prt_targetsPtr() callconv(.c) [*]u8;
pub extern fn prt_targetsCap() callconv(.c) u32;
pub extern fn prt_load(pacb_len: u32, targets_len: u32) callconv(.c) u32;
pub extern fn prt_loadError() callconv(.c) u32;
pub extern fn prt_metaPtr() callconv(.c) [*]const u8;
pub extern fn prt_metaLen() callconv(.c) u32;
pub extern fn prt_writesPtr() callconv(.c) [*]const u8;
pub extern fn prt_eval(value: f64) callconv(.c) u32;
pub extern fn prt_evalTicks(tick: i64) callconv(.c) u32;
pub extern fn prt_setControl(index: u32, x: f32, y: f32, z: f32, w: f32) callconv(.c) u32;
pub extern fn prt_clearControl(index: u32) callconv(.c) u32;
pub extern fn prt_registerControl(target_id: u32, registry: u32, ncomp: u32) callconv(.c) u32;
pub extern fn prt_setBpm(value: f64) callconv(.c) u32;
pub extern fn prt_exprFailures() callconv(.c) u32;
pub extern fn pacer_native_rt_reset() callconv(.c) void;

/// Short names used by replay code.
pub const abiVersion = prt_abiVersion;
pub const pacbPtr = prt_pacbPtr;
pub const pacbCap = prt_pacbCap;
pub const targetsPtr = prt_targetsPtr;
pub const targetsCap = prt_targetsCap;
pub const load = prt_load;
pub const loadError = prt_loadError;
pub const metaPtr = prt_metaPtr;
pub const metaLen = prt_metaLen;
pub const writesPtr = prt_writesPtr;
pub const evalSeconds = prt_eval;
pub const evalTicks = prt_evalTicks;
pub const setControl = prt_setControl;
pub const clearControl = prt_clearControl;
pub const registerControl = prt_registerControl;
pub const setBpm = prt_setBpm;
pub const exprFailures = prt_exprFailures;
pub const reset = pacer_native_rt_reset;

comptime {
    if (@TypeOf(prt_abiVersion) != fn () callconv(.c) u32)
        @compileError("NativeRt: prt_abiVersion ABI drift");
    if (@TypeOf(prt_pacbPtr) != fn () callconv(.c) [*]u8)
        @compileError("NativeRt: prt_pacbPtr ABI drift");
    if (@TypeOf(prt_pacbCap) != fn () callconv(.c) u32)
        @compileError("NativeRt: prt_pacbCap ABI drift");
    if (@TypeOf(prt_targetsPtr) != fn () callconv(.c) [*]u8)
        @compileError("NativeRt: prt_targetsPtr ABI drift");
    if (@TypeOf(prt_targetsCap) != fn () callconv(.c) u32)
        @compileError("NativeRt: prt_targetsCap ABI drift");
    if (@TypeOf(prt_load) != fn (u32, u32) callconv(.c) u32)
        @compileError("NativeRt: prt_load ABI drift");
    if (@TypeOf(prt_loadError) != fn () callconv(.c) u32)
        @compileError("NativeRt: prt_loadError ABI drift");
    if (@TypeOf(prt_metaPtr) != fn () callconv(.c) [*]const u8)
        @compileError("NativeRt: prt_metaPtr ABI drift");
    if (@TypeOf(prt_metaLen) != fn () callconv(.c) u32)
        @compileError("NativeRt: prt_metaLen ABI drift");
    if (@TypeOf(prt_writesPtr) != fn () callconv(.c) [*]const u8)
        @compileError("NativeRt: prt_writesPtr ABI drift");
    if (@TypeOf(prt_eval) != fn (f64) callconv(.c) u32)
        @compileError("NativeRt: prt_eval ABI drift");
    if (@TypeOf(prt_evalTicks) != fn (i64) callconv(.c) u32)
        @compileError("NativeRt: prt_evalTicks ABI drift");
    if (@TypeOf(prt_setControl) != fn (u32, f32, f32, f32, f32) callconv(.c) u32)
        @compileError("NativeRt: prt_setControl ABI drift");
    if (@TypeOf(prt_clearControl) != fn (u32) callconv(.c) u32)
        @compileError("NativeRt: prt_clearControl ABI drift");
    if (@TypeOf(prt_registerControl) != fn (u32, u32, u32) callconv(.c) u32)
        @compileError("NativeRt: prt_registerControl ABI drift");
    if (@TypeOf(prt_setBpm) != fn (f64) callconv(.c) u32)
        @compileError("NativeRt: prt_setBpm ABI drift");
    if (@TypeOf(prt_exprFailures) != fn () callconv(.c) u32)
        @compileError("NativeRt: prt_exprFailures ABI drift");
    if (@TypeOf(pacer_native_rt_reset) != fn () callconv(.c) void)
        @compileError("NativeRt: pacer_native_rt_reset ABI drift");
}
