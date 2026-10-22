//! `pacer-native-text` object root — binary03 T5a.
//!
//! The text driver is compiled SEPARATELY from the public `pacer` module:
//! this root imports the actual `wasm_entry.zig`, so its source graph owns
//! the `drv_*` definitions exactly once per final native binary. A
//! public-module consumer never imports this file or `wasm_entry.zig`; it
//! calls the C surface through the std-only `NativeText` facade.
//!
//! Reachability is explicit, not incidental: taking the address of every
//! production alias in `Text.NativeHarness` at comptime forces the imported
//! entry and its real `export fn` bodies into the object's analysis. The
//! aliases are internal-only — no wrapper re-exports the `drv_*` names, and
//! the sole additional C symbol is the native-only cleanup entry below.
//! Neither the namespace nor the cleanup symbol is exported through the
//! public `root.zig`, and this object is never linked into a wasm artifact.
//!
//! The `NativeText` facade pins ITS OWN extern declarations against literal
//! types; C linkage does not compare the consumer declaration with the
//! producer definition. This object therefore pins every actual
//! `Text.NativeHarness` alias against the same exact types. A producer-side
//! signature drift now fails here, in the separately compiled object that
//! owns the real `drv_*` definitions, instead of silently linking a
//! mismatched call site.
//!
//! The text object allocates through `wasm_entry`'s portable
//! `std.heap.page_allocator`: on wasm32 that IS the WasmAllocator, while
//! natively it makes actual schema/Driver allocation possible. No load
//! algorithm, export set, or allocator hook changes with it.

const builtin = @import("builtin");
const std = @import("std");
const Text = @import("wasm_entry.zig");

/// Pin one producer alias to the C surface `NativeText.zig` declares. Kept
/// separate from the facade so neither declaration is its own witness.
fn expectProducer(comptime name: []const u8, comptime actual: type, comptime expected: type) void {
    if (actual != expected)
        @compileError("native_text_bridge: " ++ name ++ " producer ABI drift");
}

comptime {
    // Native link object only: the shipped wasm artifacts keep their own
    // frozen export sets and must never include the cleanup symbol.
    if (builtin.target.cpu.arch.isWasm())
        @compileError("native_text_bridge: native-only link object");

    // Production alias reachability. Every alias the harness surface
    // promises is referenced here, including the ABI version; a renamed or
    // removed production export fails this object's compilation.
    _ = &Text.NativeHarness.abiVersion;
    _ = &Text.NativeHarness.docPtr;
    _ = &Text.NativeHarness.docCap;
    _ = &Text.NativeHarness.targetsPtr;
    _ = &Text.NativeHarness.targetsCap;
    _ = &Text.NativeHarness.load;
    _ = &Text.NativeHarness.diagPtr;
    _ = &Text.NativeHarness.diagLen;
    _ = &Text.NativeHarness.metaPtr;
    _ = &Text.NativeHarness.metaLen;
    _ = &Text.NativeHarness.writesPtr;
    _ = &Text.NativeHarness.evalSeconds;
    _ = &Text.NativeHarness.evalTicks;
    _ = &Text.NativeHarness.setControl;
    _ = &Text.NativeHarness.clearControl;
    _ = &Text.NativeHarness.registerControl;
    _ = &Text.NativeHarness.setBpm;
    _ = &Text.NativeHarness.exprFailures;
    _ = &Text.NativeHarness.reset;

    // Producer-side ABI pins. These are the same literal types the std-only
    // `NativeText` facade declares; a change on either side of the C
    // boundary now breaks a compilation rather than becoming an unchecked
    // call.
    expectProducer("drv_abiVersion", @TypeOf(Text.NativeHarness.abiVersion), fn () callconv(.c) u32);
    expectProducer("drv_docPtr", @TypeOf(Text.NativeHarness.docPtr), fn () callconv(.c) [*]u8);
    expectProducer("drv_docCap", @TypeOf(Text.NativeHarness.docCap), fn () callconv(.c) u32);
    expectProducer("drv_targetsPtr", @TypeOf(Text.NativeHarness.targetsPtr), fn () callconv(.c) [*]u8);
    expectProducer("drv_targetsCap", @TypeOf(Text.NativeHarness.targetsCap), fn () callconv(.c) u32);
    expectProducer("drv_load", @TypeOf(Text.NativeHarness.load), fn (u32, u32) callconv(.c) u32);
    expectProducer("drv_diagPtr", @TypeOf(Text.NativeHarness.diagPtr), fn () callconv(.c) [*]const u8);
    expectProducer("drv_diagLen", @TypeOf(Text.NativeHarness.diagLen), fn () callconv(.c) u32);
    expectProducer("drv_metaPtr", @TypeOf(Text.NativeHarness.metaPtr), fn () callconv(.c) [*]const u8);
    expectProducer("drv_metaLen", @TypeOf(Text.NativeHarness.metaLen), fn () callconv(.c) u32);
    expectProducer("drv_writesPtr", @TypeOf(Text.NativeHarness.writesPtr), fn () callconv(.c) [*]const u8);
    expectProducer("drv_eval", @TypeOf(Text.NativeHarness.evalSeconds), fn (f64) callconv(.c) u32);
    expectProducer("drv_evalTicks", @TypeOf(Text.NativeHarness.evalTicks), fn (i64) callconv(.c) u32);
    expectProducer("drv_setControl", @TypeOf(Text.NativeHarness.setControl), fn (u32, f32, f32, f32, f32) callconv(.c) u32);
    expectProducer("drv_clearControl", @TypeOf(Text.NativeHarness.clearControl), fn (u32) callconv(.c) u32);
    expectProducer("drv_registerControl", @TypeOf(Text.NativeHarness.registerControl), fn (u32, u32, u32) callconv(.c) u32);
    expectProducer("drv_setBpm", @TypeOf(Text.NativeHarness.setBpm), fn (f64) callconv(.c) u32);
    expectProducer("drv_exprFailures", @TypeOf(Text.NativeHarness.exprFailures), fn () callconv(.c) u32);
    // `reset` is the object-local teardown called by the cleanup export
    // below, not an extern declaration; it keeps Zig's default convention.
    expectProducer("NativeHarness.reset", @TypeOf(Text.NativeHarness.reset), fn () void);
}

/// Native-only injection point for the counting-GPA harness (C4/C5). The
/// entry's `NativeGpa` defaults to the page allocator; this setter replaces
/// both words. Never part of the wasm artifact.
export fn pacer_native_text_set_gpa(ptr: *anyopaque, vtable: *const std.mem.Allocator.VTable) callconv(.c) void {
    Text.NativeGpa.gpa_ptr = ptr;
    Text.NativeGpa.gpa_vtable = vtable;
}

/// The one native-only C symbol: ordered teardown of the production text
/// session. `drv_*` definitions themselves stay in `wasm_entry.zig`.
export fn pacer_native_text_reset() callconv(.c) void {
    Text.NativeHarness.reset();
}
