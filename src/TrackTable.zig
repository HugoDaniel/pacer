//! Compiled score — the compact runtime representation the evaluator
//! walks every frame.
//!
//! Built once per load by `Compile.buildTable` (walk the validated tree
//! into static arrays, convert positions to i64 ticks, flatten + dedup
//! easing programs); immutable afterwards. Keyframe tracks never touch
//! the AST again — the hot path reads these slices. Expr tracks are the
//! one designed exception: their `Source.expr` is a node index into the
//! compile result's tree, re-evaluated each frame (`ExprTrack.evalAt`),
//! so the tree must outlive the table — both live on
//! `Compile.CompileResult`, which guarantees it.
//!
//! Invariants (asserted at build, relied on by `Eval`):
//!   * every keyframe track has ≥ 1 key; keys are sorted by `at`,
//!     strictly increasing (duplicates were load diagnostics);
//!   * every `Key.value` lane ≥ its track's `ncomp` is zero;
//!   * every `ease_ref` indexes `programs`; `programs[0]` is linear
//!     (the shared default for keys without `:ease`);
//!   * every expr track dry-ran successfully at t = 0 during compile;
//!   * `transport.dur`, when present, is > 0.
//!
//! Ownership: SJON convention — arena-backed `.deinit()`, the struct
//! never retains the caller's GPA.

const std = @import("std");
const sjon = @import("sjon");
const TimeMap = @import("TimeMap.zig");
const Easing = @import("Easing.zig");

pub const Tick = sjon.Pattern.Tick;

/// Caps. Exceeding any is a load diagnostic with a span, never a panic.
pub const MAX_TRACKS = 256;
pub const MAX_KEYS = 4096;
pub const MAX_EASE_PROGRAMS = 128;

pub const EndBehavior = enum { loop, hold };

pub const Transport = struct {
    map: TimeMap,
    /// Score length in ticks; `null` = unbounded (end-behavior ignored).
    dur: ?Tick,
    end: EndBehavior,
};

/// One keyframe, position already on the tick grid.
pub const Key = struct {
    at: Tick,
    value: [4]f32,
    /// Easing program for the segment ENDING at this key. Index into
    /// `programs`; the first key of a track never reads it.
    ease_ref: u16,
};

/// A track's value source — `(key …)` children XOR `:expr`, enforced at
/// compile with `track_source_conflict`.
pub const Source = union(enum) {
    /// Contiguous run in `keys`: `keys[start..][0..len]`, len ≥ 1,
    /// sorted by `at`, strictly increasing.
    keys: struct { start: u32, len: u32 },
    /// The `:expr` value node, evaluated against the compile result's
    /// tree each frame with the time env bound (see `ExprTrack`).
    expr: sjon.Ast.NodeIndex,
};

/// One animated target. `target_id`/`registry`/`ncomp` come from the
/// load-time join against the host registries.
pub const Track = struct {
    target_id: u16,
    /// Registry index (0 = visual, 1 = audio, …) — lands in
    /// `Writes.Entry.flags` so JS routing is one switch.
    registry: u8,
    ncomp: u8,
    source: Source,
};

arena: std.heap.ArenaAllocator,
transport: Transport,
tracks: []const Track,
/// All tracks' keys, contiguous; `Track.keys_start/len` slice into it.
keys: []const Key,
/// Deduped easing programs; index 0 is always linear.
programs: []const Easing.Program,

const TrackTable = @This();

pub fn deinit(self: *TrackTable) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Keys of one keyframe track. O(1). Asserts the track is key-sourced.
pub fn trackKeys(self: *const TrackTable, track: *const Track) []const Key {
    const ks = track.source.keys;
    std.debug.assert(ks.len >= 1);
    std.debug.assert(ks.start + ks.len <= self.keys.len);
    return self.keys[ks.start..][0..ks.len];
}

test {
    // Representation-only module; behavior is exercised through
    // `Compile` (build) and `Eval` (walk). Keep the layout caps sane.
    comptime std.debug.assert(MAX_TRACKS <= std.math.maxInt(u16));
    comptime std.debug.assert(MAX_EASE_PROGRAMS <= std.math.maxInt(u16));
}
