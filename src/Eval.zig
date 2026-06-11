//! Per-frame evaluator — the hot path.
//!
//! `evalSeconds(t)` is one mul+floor to ticks (the `TimeMap` seam),
//! end-behavior wrap/clamp, then a bounded loop over tracks: per-track
//! last-segment cache (the playhead is near-monotonic, so the common
//! case is O(1)), unclamped f64 lerp through the easing program,
//! truncation to f32 at emission. No allocation, no AST access, no
//! recursion — everything was compiled into the `TrackTable`.
//!
//! Boundary semantics (load-bearing for the corpus): before a track's
//! first key it holds the first value; after the last, the last
//! (transport `:end` handles loop/hold *globally* first). Exact landing
//! on key values is structural: at `t == key.at` the segment STARTING
//! there is selected, so the value is the key's own, bit-exactly —
//! easing residue (springs!) never leaks across a key.
//!
//! Fixed-order float seams, in order of application:
//!   1. `u = (t - a.at) / (b.at - a.at)` — exact i64→f64 (ticks < 2^53),
//!      one division;
//!   2. `e = program.eval(u)` — pinned ops only (see `Easing`);
//!   3. `value = a + (b - a) * e` per component, f64, then ONE
//!      truncation to f32. UNCLAMPED — overshoot extrapolates past the
//!      key values; that is what makes springs/bounces work.
//!
//! Determinism claim: same table + same f64 time → byte-identical
//! entries (and `Writes.encode` bytes), native and wasm32.

const std = @import("std");
const sjon = @import("sjon");
const TrackTable = @import("TrackTable.zig");
const TimeMap = @import("TimeMap.zig");
const Writes = @import("Writes.zig");

pub const Tick = sjon.Pattern.Tick;

/// Time conversion failures (host clock out of range). The tick-domain
/// path is total once conversion succeeded.
pub const Error = TimeMap.Error;

/// Frame evaluator over a compiled table. The table is borrowed and
/// must outlive the evaluator. Owns its arena (cache + entry buffer);
/// SJON deinit convention.
pub const Evaluator = struct {
    arena: std.heap.ArenaAllocator,
    table: *const TrackTable,
    /// Per-track index of the last segment hit (`keys[i] ≤ t < keys[i+1]`).
    seg_cache: []u32,
    /// Reused output buffer, one entry per track.
    entries: []Writes.Entry,

    pub fn init(gpa: std.mem.Allocator, table: *const TrackTable) error{OutOfMemory}!Evaluator {
        std.debug.assert(table.tracks.len <= TrackTable.MAX_TRACKS);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const seg_cache = try arena.allocator().alloc(u32, table.tracks.len);
        @memset(seg_cache, 0);
        const entries = try arena.allocator().alloc(Writes.Entry, table.tracks.len);
        return .{ .arena = arena, .table = table, .seg_cache = seg_cache, .entries = entries };
    }

    pub fn deinit(self: *Evaluator) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The host-facing entry point: master-clock seconds in, write
    /// entries out. The returned slice aliases the evaluator's buffer —
    /// consume (or encode) before the next eval.
    pub fn evalSeconds(self: *Evaluator, seconds: f64) Error![]const Writes.Entry {
        const t = try self.table.transport.map.tickFromSeconds(seconds);
        return self.evalTicks(t);
    }

    /// Tick-domain twin (tests, corpus, future `drv_evalTicks`). Total.
    pub fn evalTicks(self: *Evaluator, t_raw: Tick) []const Writes.Entry {
        const table = self.table;
        var t = t_raw;
        if (table.transport.dur) |dur| {
            std.debug.assert(dur > 0);
            switch (table.transport.end) {
                .loop => t = @mod(t, dur),
                .hold => t = @min(t, dur),
            }
        }
        for (table.tracks, 0..) |*track, i| {
            self.entries[i] = evalTrack(table, track, t, &self.seg_cache[i]);
        }
        return self.entries;
    }
};

fn evalTrack(table: *const TrackTable, track: *const TrackTable.Track, t: Tick, cache: *u32) Writes.Entry {
    const keys = table.trackKeys(track);
    std.debug.assert(keys.len >= 1);

    var entry: Writes.Entry = .{
        .target_id = track.target_id,
        .flags = track.registry,
        .ncomp = track.ncomp,
        .value = .{ 0, 0, 0, 0 },
    };

    if (t <= keys[0].at) {
        entry.value = keys[0].value;
        return entry;
    }
    if (t >= keys[keys.len - 1].at) {
        entry.value = keys[keys.len - 1].value;
        return entry;
    }
    std.debug.assert(keys.len >= 2);

    // Segment search: resume from the cached segment (playhead is
    // near-monotonic), restart on a backwards seek, advance forwards.
    var i: usize = cache.*;
    if (i >= keys.len - 1 or keys[i].at > t) i = 0;
    while (i + 1 < keys.len - 1 and keys[i + 1].at <= t) : (i += 1) {}
    cache.* = @intCast(i);
    const a = &keys[i];
    const b = &keys[i + 1];
    std.debug.assert(a.at <= t);
    std.debug.assert(t < b.at);

    const u = @as(f64, @floatFromInt(t - a.at)) / @as(f64, @floatFromInt(b.at - a.at));
    const e = table.programs[b.ease_ref].eval(u);
    for (0..track.ncomp) |c| {
        const av: f64 = a.value[c];
        const bv: f64 = b.value[c];
        entry.value[c] = @floatCast(av + (bv - av) * e);
    }
    return entry;
}

// ---------------------------------------------------------------------------
// Tests (compile a real score; golden values hand-computed)
// ---------------------------------------------------------------------------

const t_ = std.testing;
const Compile = @import("Compile.zig");

const targets = [_]Compile.Target{
    .{ .name = "radius", .ncomp = 1 },
    .{ .name = "tint", .ncomp = 3 },
};

fn compileScore(source: [:0]const u8) !Compile.CompileResult {
    var r = try Compile.compile(t_.allocator, source, &targets);
    errdefer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t_.expect(r.ok());
    return r;
}

test "keyframe interpolation: golden values at beat positions" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8 :ease out-cubic)
        \\  (key :at 8b :value 0.2 :ease smoothstep))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r.table.?);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // At key ticks: the key's own value, bit-exactly (structural landing).
    try t_.expectEqual(@as(f32, 0.2), ev.evalTicks(try map.tickFromBeats(0))[0].value[0]);
    try t_.expectEqual(@as(f32, 0.8), ev.evalTicks(try map.tickFromBeats(4))[0].value[0]);
    try t_.expectEqual(@as(f32, 0.2), ev.evalTicks(try map.tickFromBeats(8))[0].value[0]);

    // Mid-segment: 0.2 + 0.6·out_cubic(0.5) = 0.2 + 0.6·0.875 = 0.725.
    const mid = ev.evalTicks(try map.tickFromBeats(2))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 0.725), mid, 1e-6);

    // Hold-first / hold-last.
    try t_.expectEqual(@as(f32, 0.2), ev.evalTicks(try map.tickFromBeats(-3))[0].value[0]);
    try t_.expectEqual(@as(f32, 0.2), ev.evalTicks(try map.tickFromBeats(100))[0].value[0]);
}

test "loop end-behavior wraps the playhead" {
    var r = try compileScore(
        \\(transport :bpm 120 :dur 2bar :end loop)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 8b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r.table.?);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // 9 beats ≡ 1 beat into the 8-beat loop → linear 1/8.
    const wrapped = ev.evalTicks(try map.tickFromBeats(9))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 0.125), wrapped, 1e-6);
    // Negative time wraps forward: -1b ≡ 7b → 7/8.
    const negative = ev.evalTicks(try map.tickFromBeats(-1))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 0.875), negative, 1e-6);
}

test "vector tracks interpolate per component, zero lanes stay zero" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(track :target tint
        \\  (key :at 0b :value [1 0 0.5])
        \\  (key :at 2b :value [0 1 0.5]))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r.table.?);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    const e = ev.evalTicks(try map.tickFromBeats(1))[0];
    try t_.expectEqual(@as(u8, 3), e.ncomp);
    try t_.expectApproxEqAbs(@as(f32, 0.5), e.value[0], 1e-6);
    try t_.expectApproxEqAbs(@as(f32, 0.5), e.value[1], 1e-6);
    try t_.expectEqual(@as(f32, 0.5), e.value[2]);
    try t_.expectEqual(@as(f32, 0), e.value[3]);
}

test "overshoot extrapolates past key values (unclamped lerp)" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 4b :value 1.0
        \\    :ease (seq (stage :ease out-cubic :t 0.5 :v 1.2)
        \\               (stage :ease in-out-quad :t 0.5 :v -0.2))))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r.table.?);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // End of stage 0 sits at value 1.2 — past the key value 1.0.
    const crest = ev.evalTicks(try map.tickFromBeats(2))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 1.2), crest, 1e-5);
    try t_.expectEqual(@as(f32, 1.0), ev.evalTicks(try map.tickFromBeats(4))[0].value[0]);
}

test "same time twice → byte-identical encoded writes" {
    var r = try compileScore(
        \\(transport :bpm 97 :meter [7 8])
        \\(track :target radius
        \\  (key :at 0b :value 0.1)
        \\  (key :at 3b :value 0.9 :ease (spring :damping 0.4 :periods 3)))
        \\(track :target tint
        \\  (key :at 0b :value [0 0 0])
        \\  (key :at 2bar :value [1 1 1] :ease in-out-expo))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r.table.?);
    defer ev.deinit();

    var buf_a: [Writes.encodedLen(2)]u8 align(4) = undefined;
    var buf_b: [Writes.encodedLen(2)]u8 align(4) = undefined;
    const times = [_]f64{ 0.0, 0.123456789, 1.5, 7.25, -2.5, 1e-9 };
    for (times) |s| {
        const a = try Writes.encode(try ev.evalSeconds(s), &buf_a);
        // A fresh evaluator (cold cache) must agree byte-for-byte —
        // the cache is a pure optimization, never semantics.
        var ev2 = try Evaluator.init(t_.allocator, &r.table.?);
        defer ev2.deinit();
        const b = try Writes.encode(try ev2.evalSeconds(s), &buf_b);
        try t_.expectEqualSlices(u8, a, b);
    }
}

test "segment cache survives scrubbing backwards" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 1b :value 0.25)
        \\  (key :at 2b :value 0.5)
        \\  (key :at 3b :value 0.75)
        \\  (key :at 4b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r.table.?);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // Forward sweep, then jump back — values must match a cold eval.
    const probe = [_]f64{ 0.5, 1.5, 2.5, 3.5, 1.25, 0.75, 3.9, 0.1 };
    for (probe) |beats| {
        const warm = ev.evalTicks(try map.tickFromBeats(beats))[0].value[0];
        var cold = try Evaluator.init(t_.allocator, &r.table.?);
        defer cold.deinit();
        const expect = cold.evalTicks(try map.tickFromBeats(beats))[0].value[0];
        try t_.expectEqual(expect, warm);
    }
}
