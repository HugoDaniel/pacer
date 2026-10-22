//! `NativeText` — std-only extern facade for the production text-loader ABI.
//!
//! This file declares the EXACT C surface `src/wasm_entry.zig` exports and
//! nothing else. It imports no Pacer or SJON source, carries no state, and
//! is safe for a public-`pacer` consumer to compile beside the separately
//! built native text object: symbols resolve at link time to the single real
//! `drv_*` definitions in that object, never to a copy, wrapper, or second
//! entry.
//!
//! Pointers are real native pointers. Lengths, capacities, statuses and
//! counters stay `u32`; `drv_eval`/`drv_setBpm` take `f64`, `drv_evalTicks`
//! takes `i64`, and control lanes stay `f32`, matching the production
//! exports. The `comptime` block below pins every FACADE declaration, so this
//! file's own call sites cannot drift. It does not compare against the
//! producer: C linkage cannot, so `src/native_text_bridge.zig` separately
//! pins the actual `wasm_entry.NativeHarness` alias types in the object that
//! owns the real `drv_*` definitions. Both sides must change together to
//! compile.
//!
//! `reset` is the one native-only cleanup symbol
//! (`pacer_native_text_reset`), defined by `src/native_text_bridge.zig`; it
//! is never part of a wasm artifact and is not reachable from public `pacer`.

const std = @import("std");

pub extern fn drv_abiVersion() callconv(.c) u32;
pub extern fn drv_docPtr() callconv(.c) [*]u8;
pub extern fn drv_docCap() callconv(.c) u32;
pub extern fn drv_targetsPtr() callconv(.c) [*]u8;
pub extern fn drv_targetsCap() callconv(.c) u32;
pub extern fn drv_load(doc_len: u32, targets_len: u32) callconv(.c) u32;
pub extern fn drv_diagPtr() callconv(.c) [*]const u8;
pub extern fn drv_diagLen() callconv(.c) u32;
pub extern fn drv_metaPtr() callconv(.c) [*]const u8;
pub extern fn drv_metaLen() callconv(.c) u32;
pub extern fn drv_writesPtr() callconv(.c) [*]const u8;
pub extern fn drv_eval(value: f64) callconv(.c) u32;
pub extern fn drv_evalTicks(tick: i64) callconv(.c) u32;
pub extern fn drv_setControl(index: u32, x: f32, y: f32, z: f32, w: f32) callconv(.c) u32;
pub extern fn drv_clearControl(index: u32) callconv(.c) u32;
pub extern fn drv_registerControl(target_id: u32, registry: u32, ncomp: u32) callconv(.c) u32;
pub extern fn drv_setBpm(value: f64) callconv(.c) u32;
pub extern fn drv_exprFailures() callconv(.c) u32;
pub extern fn pacer_native_text_reset() callconv(.c) void;
pub extern fn pacer_native_text_set_gpa(ptr: *anyopaque, vtable: *const std.mem.Allocator.VTable) callconv(.c) void;

/// Short names used by lifecycle replay code.
pub const abiVersion = drv_abiVersion;
pub const docPtr = drv_docPtr;
pub const docCap = drv_docCap;
pub const targetsPtr = drv_targetsPtr;
pub const targetsCap = drv_targetsCap;
pub const load = drv_load;
pub const diagPtr = drv_diagPtr;
pub const diagLen = drv_diagLen;
pub const metaPtr = drv_metaPtr;
pub const metaLen = drv_metaLen;
pub const writesPtr = drv_writesPtr;
pub const evalSeconds = drv_eval;
pub const evalTicks = drv_evalTicks;
pub const setControl = drv_setControl;
pub const clearControl = drv_clearControl;
pub const registerControl = drv_registerControl;
pub const setBpm = drv_setBpm;
pub const exprFailures = drv_exprFailures;
pub const reset = pacer_native_text_reset;
pub const setGpa = pacer_native_text_set_gpa;

comptime {
    if (@TypeOf(drv_abiVersion) != fn () callconv(.c) u32)
        @compileError("NativeText: drv_abiVersion ABI drift");
    if (@TypeOf(drv_docPtr) != fn () callconv(.c) [*]u8)
        @compileError("NativeText: drv_docPtr ABI drift");
    if (@TypeOf(drv_docCap) != fn () callconv(.c) u32)
        @compileError("NativeText: drv_docCap ABI drift");
    if (@TypeOf(drv_targetsPtr) != fn () callconv(.c) [*]u8)
        @compileError("NativeText: drv_targetsPtr ABI drift");
    if (@TypeOf(drv_targetsCap) != fn () callconv(.c) u32)
        @compileError("NativeText: drv_targetsCap ABI drift");
    if (@TypeOf(drv_load) != fn (u32, u32) callconv(.c) u32)
        @compileError("NativeText: drv_load ABI drift");
    if (@TypeOf(drv_diagPtr) != fn () callconv(.c) [*]const u8)
        @compileError("NativeText: drv_diagPtr ABI drift");
    if (@TypeOf(drv_diagLen) != fn () callconv(.c) u32)
        @compileError("NativeText: drv_diagLen ABI drift");
    if (@TypeOf(drv_metaPtr) != fn () callconv(.c) [*]const u8)
        @compileError("NativeText: drv_metaPtr ABI drift");
    if (@TypeOf(drv_metaLen) != fn () callconv(.c) u32)
        @compileError("NativeText: drv_metaLen ABI drift");
    if (@TypeOf(drv_writesPtr) != fn () callconv(.c) [*]const u8)
        @compileError("NativeText: drv_writesPtr ABI drift");
    if (@TypeOf(drv_eval) != fn (f64) callconv(.c) u32)
        @compileError("NativeText: drv_eval ABI drift");
    if (@TypeOf(drv_evalTicks) != fn (i64) callconv(.c) u32)
        @compileError("NativeText: drv_evalTicks ABI drift");
    if (@TypeOf(drv_setControl) != fn (u32, f32, f32, f32, f32) callconv(.c) u32)
        @compileError("NativeText: drv_setControl ABI drift");
    if (@TypeOf(drv_clearControl) != fn (u32) callconv(.c) u32)
        @compileError("NativeText: drv_clearControl ABI drift");
    if (@TypeOf(drv_registerControl) != fn (u32, u32, u32) callconv(.c) u32)
        @compileError("NativeText: drv_registerControl ABI drift");
    if (@TypeOf(drv_setBpm) != fn (f64) callconv(.c) u32)
        @compileError("NativeText: drv_setBpm ABI drift");
    if (@TypeOf(drv_exprFailures) != fn () callconv(.c) u32)
        @compileError("NativeText: drv_exprFailures ABI drift");
    if (@TypeOf(pacer_native_text_reset) != fn () callconv(.c) void)
        @compileError("NativeText: pacer_native_text_reset ABI drift");
    if (@TypeOf(pacer_native_text_set_gpa) != fn (*anyopaque, *const std.mem.Allocator.VTable) callconv(.c) void)
        @compileError("NativeText: set_gpa ABI drift");
}
