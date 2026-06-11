//! Compiled score — the compact runtime representation the evaluator
//! walks every frame.
//!
//! Built once per load by `Compile.buildTable` (walk the validated tree
//! into static arrays, convert positions to i64 ticks, flatten + dedup
//! easing programs); immutable afterwards. The hot path never touches
//! the AST, never parses, never allocates — it reads these slices.
//!
//! Invariants (asserted at build, relied on by `Eval`):
//!   * every track has ≥ 1 key; keys are sorted by `at`, strictly
//!     increasing (duplicates were load diagnostics);
//!   * every `Key.value` lane ≥ its track's `ncomp` is zero;
//!   * every `ease_ref` indexes `programs`; `programs[0]` is linear
//!     (the shared default for keys without `:ease`);
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

/// One animated target. `target_id`/`registry`/`ncomp` come from the
/// load-time join against the host registries.
pub const Track = struct {
    target_id: u16,
    /// Registry index (0 = visual, 1 = audio, …) — lands in
    /// `Writes.Entry.flags` so JS routing is one switch.
    registry: u8,
    ncomp: u8,
    keys_start: u32,
    keys_len: u32,
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

/// Keys of one track. O(1).
pub fn trackKeys(self: *const TrackTable, track: *const Track) []const Key {
    std.debug.assert(track.keys_len >= 1);
    std.debug.assert(track.keys_start + track.keys_len <= self.keys.len);
    return self.keys[track.keys_start..][0..track.keys_len];
}

test {
    // Representation-only module; behavior is exercised through
    // `Compile` (build) and `Eval` (walk). Keep the layout caps sane.
    comptime std.debug.assert(MAX_TRACKS <= std.math.maxInt(u16));
    comptime std.debug.assert(MAX_EASE_PROGRAMS <= std.math.maxInt(u16));
}
