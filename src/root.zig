//! pacer — deterministic animation driver conducted by an SJON score.
//!
//! The driver is a pure function of time: a host samples its master clock
//! (audio when playing, `performance.now()` otherwise), passes one f64
//! seconds value in, and receives a packed `(target, value)` write buffer
//! out. It never reads a clock, never owns a loop, never touches the GPU
//! or the audio graph — visual targets are routed by name through
//! pngine's uniform reflection table, audio targets through the audio
//! engine's param registry, both joined once at load.
//!
//! Memory model follows SJON's (see SJON `src/root.zig`): every public
//! entry point takes `gpa: std.mem.Allocator` and returns an owned struct
//! with arena-backed `.deinit()`; the struct never retains the caller's
//! GPA. Time follows SJON's `Pattern` tick core: `i64` ticks on the
//! `PPC = 720720` grid, overflow as diagnostics, floor-division cycle
//! math. Determinism claim: same document + same f64 time → byte-identical
//! write buffer, native and wasm32.

const std = @import("std");
const sjon = @import("sjon");

/// Package version. Mirrors `build.zig.zon`.
pub const version = "0.1.0";

/// Score compiler: manifest prepend → `sjon.validateDocument` → the
/// compiled `TrackTable` (targets joined, ticks converted, programs
/// deduped), with pacer's own wire-stable diagnostic codes.
pub const Compile = @import("Compile.zig");
/// Transport math: bpm/meter ↔ ticks/beats/seconds; the one documented
/// mul+floor f64 seam.
pub const TimeMap = @import("TimeMap.zig");
/// Easing programs: flat compiled stage tables (seq/chain/primitives),
/// deterministic by construction (`sjon.trig` kernels + fixed-count
/// bezier bisection).
pub const Easing = @import("Easing.zig");
/// Compiled score representation the frame path walks (tracks, keys in
/// ticks, deduped easing programs).
pub const TrackTable = @import("TrackTable.zig");
/// Per-frame evaluator: seconds → ticks → packed write entries.
pub const Eval = @import("Eval.zig");
/// Packed write-buffer wire format (`'PACW'` header + 20-byte entries).
pub const Writes = @import("Writes.zig");

test {
    _ = Compile;
    _ = TimeMap;
    _ = Easing;
    _ = TrackTable;
    _ = Eval;
    _ = Writes;
}

test "sjon dependency wiring: tick grid + trig kernels reachable" {
    // The two SJON surfaces pacer is built on: the Pattern tick core and
    // the deterministic math kernels. Reaching both through the module
    // proves the path dep + re-exports are wired.
    try std.testing.expectEqual(@as(i64, 0), @rem(sjon.Pattern.PPC, 16));
    try std.testing.expectEqual(@as(f64, 1.0), sjon.trig.exp64(0.0));
}
