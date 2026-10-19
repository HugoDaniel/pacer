//! Transport math: bpm/meter ↔ ticks/beats/seconds on the shared grid.
//!
//! One bar = one cycle = `Pattern.PPC` ticks. The meter's
//! beats-per-bar (validated 1..16 by the manifest) divides PPC exactly,
//! so integer beat/bar positions are exact integer ticks.
//!
//! Float seams are pinned to ONE documented shape — `floor(value * rate)`
//! with the rate computed once at init in fixed op order — so the same
//! score converts identically on every host:
//!   * `ticks_per_second = (bpm * ticks_per_beat) / 60.0` (mul first,
//!     then divide; do not reassociate).
//!   * seconds→ticks, beats→ticks, bars→ticks are each a single f64
//!     multiply + `@floor` + exact int conversion. Integer-valued
//!     positions stay exact because both factors and the product are
//!     integers below 2^53; fractional positions are deterministic
//!     because IEEE-754 multiply/floor are.
//!
//! ## The piecewise tempo map
//!
//! `(tempo …)` segments make ONLY the seconds↔ticks projection
//! piecewise — beat/bar positions are exact integer ticks regardless.
//! The compile-built table (`withSegments`) carries per segment
//! `{start_tick, bpm, start_sec, tps}` with the cumulative `start_sec`
//! accumulated in one documented op order:
//!   * `tps_i = (bpm_i * ticks_per_beat) / 60.0` (the init op order);
//!   * `start_sec_{i+1} = start_sec_i + Δtick / tps_i` — Δtick exact
//!     i64→f64, ONE division, ONE add; do not reassociate.
//! Conversion = linear scan to the active segment (≤ MAX_TEMPO_SEGMENTS,
//! ascending, deterministic) + the same one mul + floor as the constant
//! path, against the segment origin. A map with ≤ 1 segment takes the
//! constant code path VERBATIM — the degenerate pin that keeps every
//! pre-map score bit-identical.
//!
//! Loop/hold end-behavior for MAPPED scores wraps in SECONDS first
//! (`loopSeconds`/`holdSeconds` — IEEE `@mod`/`@min`, exact), then
//! converts once; tick-wrapping would replay loop iteration 2 at the
//! final segment's tempo. Constant-tempo scores keep the historical
//! tick-domain wrap in `Eval` (bit-stable goldens).
//!
//! No allocation; pure value math (the segment slice is caller-owned,
//! compile-arena-backed). Overflow and non-finite input are errors
//! (they originate in user documents / host clocks), never panics.

const std = @import("std");
const RtSjon = @import("RtSjon.zig");
const Pattern = RtSjon.Pattern;

pub const Tick = Pattern.Tick;

/// Explicit error set. `TickOverflow` mirrors `Pattern.Error` (result
/// magnitude past the 2^53 portable ceiling); `NonFiniteTime` = the host
/// handed a NaN/inf clock value or the conversion produced one.
pub const Error = error{ TickOverflow, NonFiniteTime };

/// One derived segment of the piecewise seconds↔ticks projection.
/// `start_tick`/`bpm` are the authored truth (`TrackTable.TempoSegment`);
/// `start_sec`/`tps` are filled by `withSegments` in the documented op
/// order and never touched again.
pub const Segment = struct {
    start_tick: Tick,
    bpm: f64,
    /// Cumulative seconds at `start_tick`.
    start_sec: f64,
    /// Ticks per second inside this segment.
    tps: f64,
};

bpm: f64,
beats_per_bar: i64,
/// `PPC / beats_per_bar`, exact by the meter-component 1..16 invariant.
ticks_per_beat: i64,
/// `(bpm * ticks_per_beat) / 60.0` — fixed op order, computed once.
ticks_per_second: f64,
/// Piecewise projection table, strictly ascending by `start_tick`;
/// `[0]` is `{0, bpm}`. Empty or length 1 ⇒ the constant code path (the
/// degenerate pin). Caller-owned storage (compile arena).
segments: []const Segment = &.{},

const TimeMap = @This();

/// Build a map from validated transport values. Preconditions hold
/// because the manifest validated them (`bpm-value` 1..1000,
/// `meter-component` 1..16) — asserted, not re-diagnosed.
pub fn init(bpm: f64, beats_per_bar: i64) TimeMap {
    std.debug.assert(bpm >= 1 and bpm <= 1000);
    std.debug.assert(beats_per_bar >= 1 and beats_per_bar <= 16);
    const tpb = @divExact(Pattern.PPC, beats_per_bar);
    const tps = (bpm * @as(f64, @floatFromInt(tpb))) / 60.0;
    std.debug.assert(tpb > 0);
    std.debug.assert(std.math.isFinite(tps) and tps > 0);
    return .{
        .bpm = bpm,
        .beats_per_bar = beats_per_bar,
        .ticks_per_beat = tpb,
        .ticks_per_second = tps,
    };
}

/// Attach the piecewise tempo table. `segs` must already hold the
/// authored `{start_tick, bpm}` pairs — `[0] == {0, self.bpm}`, ticks
/// strictly ascending, bpm in the manifest's 1..1000 (compile
/// established all of it; asserted, not re-diagnosed). Fills
/// `start_sec`/`tps` in the documented op order (see the module header)
/// and returns a map carrying the table. The storage is caller-owned
/// and must outlive the map (compile arena).
pub fn withSegments(self: TimeMap, segs: []Segment) TimeMap {
    for (segs, 0..) |*s, i| {
        std.debug.assert(s.bpm >= 1 and s.bpm <= 1000);
        s.tps = (s.bpm * @as(f64, @floatFromInt(self.ticks_per_beat))) / 60.0;
        if (i == 0) {
            std.debug.assert(s.start_tick == 0);
            std.debug.assert(s.bpm == self.bpm);
            s.start_sec = 0;
        } else {
            const prev = &segs[i - 1];
            std.debug.assert(s.start_tick > prev.start_tick);
            const delta: f64 = @floatFromInt(s.start_tick - prev.start_tick);
            s.start_sec = prev.start_sec + delta / prev.tps;
        }
    }
    var out = self;
    out.segments = segs;
    return out;
}

/// THE seconds→ticks seam: one multiply, one floor. Host clock seconds
/// (audio `currentTime` or `performance.now()/1000`) in, grid tick out.
/// Under a tempo map the multiply runs against the active segment's
/// origin (same shape, scanned deterministically); the degenerate map
/// takes the constant path verbatim.
pub fn tickFromSeconds(self: *const TimeMap, seconds: f64) Error!Tick {
    if (self.segments.len <= 1)
        return mulFloor(seconds, self.ticks_per_second);
    if (!std.math.isFinite(seconds)) return error.NonFiniteTime;
    const seg = &self.segments[self.segmentIndexOfSeconds(seconds)];
    // The same one-mul-one-floor seam, against the segment origin. The
    // trailing integer add is exact (both terms ≤ 2^53 in magnitude).
    const product = (seconds - seg.start_sec) * seg.tps;
    if (!std.math.isFinite(product)) return error.TickOverflow;
    const floored = @floor(product);
    const max_f: f64 = @floatFromInt(Pattern.MAX_TICK);
    if (floored > max_f or floored < -max_f) return error.TickOverflow;
    const t = seg.start_tick + @as(Tick, @intFromFloat(floored));
    if (t > Pattern.MAX_TICK or t < -Pattern.MAX_TICK) return error.TickOverflow;
    return t;
}

/// Beats→ticks. Integer beat values are exact; fractional ones take the
/// same documented mul+floor seam.
pub fn tickFromBeats(self: *const TimeMap, beats: f64) Error!Tick {
    return mulFloor(beats, @floatFromInt(self.ticks_per_beat));
}

/// Bars→ticks (one bar = PPC ticks). Takes `self` for call-site
/// uniformity with the other projections; bars are meter-independent.
pub fn tickFromBars(self: *const TimeMap, bars: f64) Error!Tick {
    _ = self;
    return mulFloor(bars, @floatFromInt(Pattern.PPC));
}

/// Inverse projection: display for hosts/debug UIs, and under a tempo
/// map the `loop_secs = secondsFromTick(dur)` compile-time constant the
/// seconds-domain wrap runs on. Inverts exactly on segment origins.
pub fn secondsFromTick(self: *const TimeMap, t: Tick) f64 {
    if (self.segments.len <= 1)
        return @as(f64, @floatFromInt(t)) / self.ticks_per_second;
    const seg = &self.segments[self.segmentIndexOfTick(t)];
    return seg.start_sec + @as(f64, @floatFromInt(t - seg.start_tick)) / seg.tps;
}

/// The active segment's bpm at a (wrapped) tick — a step function, f64
/// exact from the score literal. The constant map reports its own bpm.
/// This is the `bpm` expr-env binding and `:emit [bpm]` lane value.
pub fn bpmAt(self: *const TimeMap, t: Tick) f64 {
    if (self.segments.len <= 1) return self.bpm;
    return self.segments[self.segmentIndexOfTick(t)].bpm;
}

/// Seconds-domain `:end loop` wrap for mapped scores: one IEEE-exact
/// `@mod` into `[0, loop_secs)` (matching the tick-domain `@mod`'s
/// treatment of negative time), applied BEFORE the one seconds→ticks
/// conversion so iteration 2 replays the early segments. A NaN/inf
/// input flows through to the conversion's `NonFiniteTime` guard —
/// host-clock input is never asserted on.
pub fn loopSeconds(seconds: f64, loop_secs: f64) f64 {
    std.debug.assert(std.math.isFinite(loop_secs));
    std.debug.assert(loop_secs > 0);
    return @mod(seconds, loop_secs);
}

/// Seconds-domain `:end hold` clamp for mapped scores (the `@min` twin
/// of the tick-domain hold). NaN flows through like `loopSeconds`.
pub fn holdSeconds(seconds: f64, loop_secs: f64) f64 {
    std.debug.assert(std.math.isFinite(loop_secs));
    std.debug.assert(loop_secs > 0);
    return @min(seconds, loop_secs);
}

/// Last segment whose `start_sec` ≤ `seconds` (segment 0 extends
/// backward for negative time). Linear scan: ≤ MAX_TEMPO_SEGMENTS
/// entries, ascending, deterministic. Asserts a table is present.
fn segmentIndexOfSeconds(self: *const TimeMap, seconds: f64) usize {
    std.debug.assert(self.segments.len >= 1);
    var i: usize = self.segments.len - 1;
    while (i > 0) : (i -= 1) {
        if (self.segments[i].start_sec <= seconds) return i;
    }
    return 0;
}

/// Last segment whose `start_tick` ≤ `t` — the tick-domain twin.
fn segmentIndexOfTick(self: *const TimeMap, t: Tick) usize {
    std.debug.assert(self.segments.len >= 1);
    var i: usize = self.segments.len - 1;
    while (i > 0) : (i -= 1) {
        if (self.segments[i].start_tick <= t) return i;
    }
    return 0;
}

/// Continuous beat position of a tick (Expr env `beat` binding).
pub fn beatOf(self: *const TimeMap, t: Tick) f64 {
    return @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(self.ticks_per_beat));
}

/// Continuous bar position of a tick (Expr env `bar` binding).
pub fn barOf(self: *const TimeMap, t: Tick) f64 {
    _ = self;
    return @as(f64, @floatFromInt(t)) / @as(f64, @floatFromInt(Pattern.PPC));
}

/// Phase within the current bar, in `[0, 1)`.
pub fn phaseOf(self: *const TimeMap, t: Tick) f64 {
    _ = self;
    const p = @as(f64, @floatFromInt(Pattern.cyclePos(t))) / @as(f64, @floatFromInt(Pattern.PPC));
    std.debug.assert(p >= 0 and p < 1);
    return p;
}

/// Shared conversion kernel: `floor(value * rate)` checked against the
/// portable tick ceiling. `rate` is an init-time constant (positive,
/// finite — asserted); `value` is host/user input (errors, not asserts).
fn mulFloor(value: f64, rate: f64) Error!Tick {
    std.debug.assert(std.math.isFinite(rate));
    std.debug.assert(rate > 0);
    if (!std.math.isFinite(value)) return error.NonFiniteTime;
    const product = value * rate;
    if (!std.math.isFinite(product)) return error.TickOverflow;
    const floored = @floor(product);
    const max_f: f64 = @floatFromInt(Pattern.MAX_TICK);
    if (floored > max_f or floored < -max_f) return error.TickOverflow;
    const t: Tick = @intFromFloat(floored);
    std.debug.assert(t <= Pattern.MAX_TICK);
    std.debug.assert(t >= -Pattern.MAX_TICK);
    return t;
}

const t_ = std.testing;

test "120bpm 4/4 reference rates" {
    const tm = TimeMap.init(120, 4);
    try t_.expectEqual(@as(i64, 180180), tm.ticks_per_beat);
    try t_.expectEqual(@as(f64, 360360), tm.ticks_per_second);
}

test "integer beat/bar positions are exact ticks" {
    const tm = TimeMap.init(120, 4);
    try t_.expectEqual(@as(Tick, 0), try tm.tickFromBeats(0));
    try t_.expectEqual(@as(Tick, 4 * 180180), try tm.tickFromBeats(4));
    try t_.expectEqual(@as(Tick, Pattern.PPC), try tm.tickFromBars(1));
    try t_.expectEqual(@as(Tick, 16 * Pattern.PPC), try tm.tickFromBars(16));
    // 4 beats = 1 bar in 4/4.
    try t_.expectEqual(try tm.tickFromBars(1), try tm.tickFromBeats(4));
}

test "dyadic fractional positions are exact" {
    const tm = TimeMap.init(120, 4);
    // 1.5 and 0.25 are exact in f64; products are integers < 2^53.
    try t_.expectEqual(@as(Tick, 270270), try tm.tickFromBeats(1.5));
    try t_.expectEqual(@as(Tick, 45045), try tm.tickFromBeats(0.25));
    try t_.expectEqual(@as(Tick, @divExact(Pattern.PPC, 2)), try tm.tickFromBars(0.5));
}

test "seconds seam: 1s at 120bpm 4/4 = 2 beats; negatives floor" {
    const tm = TimeMap.init(120, 4);
    try t_.expectEqual(@as(Tick, 360360), try tm.tickFromSeconds(1.0));
    try t_.expectEqual(@as(Tick, 2 * 360360), try tm.tickFromSeconds(2.0));
    try t_.expectEqual(@as(Tick, 90090), try tm.tickFromSeconds(0.25));
    // Floor, not trunc: -0.25s lands exactly; ticks are negative.
    try t_.expectEqual(@as(Tick, -90090), try tm.tickFromSeconds(-0.25));
}

test "round-trip projection is consistent for display purposes" {
    const tm = TimeMap.init(90, 3);
    const tick = try tm.tickFromBeats(7);
    try t_.expectEqual(@as(f64, 7), tm.beatOf(tick));
    const s = tm.secondsFromTick(tick);
    try t_.expectEqual(tick, try tm.tickFromSeconds(s));
}

test "phase stays in [0,1) including negative ticks" {
    const tm = TimeMap.init(120, 4);
    try t_.expectEqual(@as(f64, 0), tm.phaseOf(0));
    try t_.expectEqual(@as(f64, 0.5), tm.phaseOf(@divExact(Pattern.PPC, 2)));
    try t_.expectEqual(@as(f64, 0.75), tm.phaseOf(-@divExact(Pattern.PPC, 4)));
}

test "overflow and non-finite input are errors" {
    const tm = TimeMap.init(1000, 1);
    try t_.expectError(error.TickOverflow, tm.tickFromSeconds(1e30));
    try t_.expectError(error.TickOverflow, tm.tickFromBars(1e30));
    try t_.expectError(error.NonFiniteTime, tm.tickFromSeconds(std.math.nan(f64)));
    try t_.expectError(error.NonFiniteTime, tm.tickFromSeconds(std.math.inf(f64)));
}

// ---- piecewise tempo map (plan it/01 Phase 2) ----

/// 120 bpm 4/4, doubling to 240 at bar 1 (tick 720720). Boundary lands
/// at exactly 2.0 s; every hand-computed value below is dyadic-exact.
fn twoSegmentMap(buf: *[2]Segment) TimeMap {
    buf.* = .{
        .{ .start_tick = 0, .bpm = 120, .start_sec = undefined, .tps = undefined },
        .{ .start_tick = 720720, .bpm = 240, .start_sec = undefined, .tps = undefined },
    };
    return TimeMap.init(120, 4).withSegments(buf);
}

test "piecewise: the cumulative table builds in the documented op order" {
    var buf: [2]Segment = undefined;
    const tm = twoSegmentMap(&buf);
    try t_.expectEqual(@as(f64, 0), tm.segments[0].start_sec);
    try t_.expectEqual(@as(f64, 360360), tm.segments[0].tps);
    // 720720 ticks at tps 360360 = exactly 2 s.
    try t_.expectEqual(@as(f64, 2), tm.segments[1].start_sec);
    try t_.expectEqual(@as(f64, 720720), tm.segments[1].tps);
}

test "piecewise: seconds→ticks on both sides of the boundary and AT it" {
    var buf: [2]Segment = undefined;
    const tm = twoSegmentMap(&buf);
    // Inside segment 0: the old constant math.
    try t_.expectEqual(@as(Tick, 360360), try tm.tickFromSeconds(1.0));
    try t_.expectEqual(@as(Tick, 540540), try tm.tickFromSeconds(1.5));
    // AT the boundary: lands exactly on the segment-1 origin.
    try t_.expectEqual(@as(Tick, 720720), try tm.tickFromSeconds(2.0));
    // Past it: 1 s at 240 bpm = 4 beats = 720720 more ticks.
    try t_.expectEqual(@as(Tick, 1441440), try tm.tickFromSeconds(3.0));
    // Negative time extends segment 0 backward, floor not trunc.
    try t_.expectEqual(@as(Tick, -90090), try tm.tickFromSeconds(-0.25));
}

test "piecewise: a fractional-bpm third segment stays exact" {
    // Segment 2 at bar 2 (tick 1441440), 96.5 bpm → tps 289789.5;
    // start_sec = 2 + 720720/720720 = 3.
    var buf: [3]Segment = .{
        .{ .start_tick = 0, .bpm = 120, .start_sec = undefined, .tps = undefined },
        .{ .start_tick = 720720, .bpm = 240, .start_sec = undefined, .tps = undefined },
        .{ .start_tick = 1441440, .bpm = 96.5, .start_sec = undefined, .tps = undefined },
    };
    const tm = TimeMap.init(120, 4).withSegments(&buf);
    try t_.expectEqual(@as(f64, 3), tm.segments[2].start_sec);
    try t_.expectEqual(@as(f64, 289789.5), tm.segments[2].tps);
    // 2 s into segment 2: floor(2 × 289789.5) = 579579.
    try t_.expectEqual(@as(Tick, 1441440 + 579579), try tm.tickFromSeconds(5.0));
}

test "piecewise: ticks→seconds inverts on segment origins" {
    var buf: [2]Segment = undefined;
    const tm = twoSegmentMap(&buf);
    try t_.expectEqual(@as(f64, 0), tm.secondsFromTick(0));
    try t_.expectEqual(@as(f64, 2), tm.secondsFromTick(720720));
    try t_.expectEqual(@as(f64, 3), tm.secondsFromTick(1441440));
    // Round trip through the piecewise scan.
    try t_.expectEqual(@as(Tick, 900900), try tm.tickFromSeconds(tm.secondsFromTick(900900)));
}

test "degenerate 1-segment map is bit-identical to the constant implementation" {
    // The oracle IS the pre-map implementation, kept verbatim: one
    // multiply, one floor, same overflow gates.
    const oracle = struct {
        fn tickOf(m: *const TimeMap, s: f64) Error!Tick {
            if (!std.math.isFinite(s)) return error.NonFiniteTime;
            const product = s * m.ticks_per_second;
            if (!std.math.isFinite(product)) return error.TickOverflow;
            const floored = @floor(product);
            const max_f: f64 = @floatFromInt(Pattern.MAX_TICK);
            if (floored > max_f or floored < -max_f) return error.TickOverflow;
            return @intFromFloat(floored);
        }
        fn secsOf(m: *const TimeMap, tk: Tick) f64 {
            return @as(f64, @floatFromInt(tk)) / m.ticks_per_second;
        }
    };
    var buf: [1]Segment = .{
        .{ .start_tick = 0, .bpm = 97.3, .start_sec = undefined, .tps = undefined },
    };
    const tm = TimeMap.init(97.3, 5).withSegments(&buf);
    const sweep = [_]f64{ 0, 0.1, 0.25, 1.0 / 3.0, 1.5, -0.25, -7.77, 123.456, 1e6, 1e-9, 86400.5 };
    for (sweep) |s| {
        try t_.expectEqual(try oracle.tickOf(&tm, s), try tm.tickFromSeconds(s));
    }
    const tick_sweep = [_]Tick{ 0, 1, -1, 180180, 720720, 123456789, -987654321 };
    for (tick_sweep) |tk| {
        const want: u64 = @bitCast(oracle.secsOf(&tm, tk));
        const got: u64 = @bitCast(tm.secondsFromTick(tk));
        try t_.expectEqual(want, got);
    }
}

test "piecewise: loop wrap in seconds lands in the correct EARLY segment" {
    var buf: [2]Segment = undefined;
    const tm = twoSegmentMap(&buf);
    // dur = 2 bars = 1441440 ticks → loop_secs = 3.0 exactly.
    const loop_secs = tm.secondsFromTick(1441440);
    try t_.expectEqual(@as(f64, 3), loop_secs);
    // t = 3.5 s: iteration 2 must replay segment 0 — 0.5 s at 120 bpm.
    const wrapped = TimeMap.loopSeconds(3.5, loop_secs);
    try t_.expectEqual(@as(f64, 0.5), wrapped);
    try t_.expectEqual(@as(Tick, 180180), try tm.tickFromSeconds(wrapped));
    // The tick-wrap bug this ordering prevents: converting first reads
    // 1.5 s of segment-1 tempo and lands at DOUBLE the correct position.
    const tick_wrapped = @mod(try tm.tickFromSeconds(3.5), 1441440);
    try t_.expectEqual(@as(Tick, 360360), tick_wrapped);
    try t_.expect(tick_wrapped != try tm.tickFromSeconds(wrapped));
    // Negative time wraps into [0, loop_secs) like the tick-domain @mod.
    try t_.expectEqual(@as(f64, 2.5), TimeMap.loopSeconds(-0.5, loop_secs));
}

test "piecewise: hold clamps at loop_secs" {
    var buf: [2]Segment = undefined;
    const tm = twoSegmentMap(&buf);
    const loop_secs = tm.secondsFromTick(1441440);
    try t_.expectEqual(@as(f64, 3), TimeMap.holdSeconds(5.0, loop_secs));
    try t_.expectEqual(@as(Tick, 1441440), try tm.tickFromSeconds(TimeMap.holdSeconds(5.0, loop_secs)));
    // Below the edge nothing moves; negatives pass through (same as the
    // tick-domain @min).
    try t_.expectEqual(@as(f64, 2.5), TimeMap.holdSeconds(2.5, loop_secs));
    try t_.expectEqual(@as(f64, -1.5), TimeMap.holdSeconds(-1.5, loop_secs));
}

test "piecewise: overflow and non-finite input still guard" {
    var buf: [2]Segment = undefined;
    const tm = twoSegmentMap(&buf);
    try t_.expectError(error.TickOverflow, tm.tickFromSeconds(1e30));
    try t_.expectError(error.NonFiniteTime, tm.tickFromSeconds(std.math.nan(f64)));
    try t_.expectError(error.NonFiniteTime, tm.tickFromSeconds(std.math.inf(f64)));
    // NaN flows through the seconds-domain wrap to the conversion guard.
    try t_.expectError(error.NonFiniteTime, tm.tickFromSeconds(TimeMap.loopSeconds(std.math.nan(f64), 3.0)));
}

test "piecewise: bpm lookup is a step function of the tick" {
    var buf: [2]Segment = undefined;
    const tm = twoSegmentMap(&buf);
    try t_.expectEqual(@as(f64, 120), tm.bpmAt(0));
    try t_.expectEqual(@as(f64, 120), tm.bpmAt(720719));
    try t_.expectEqual(@as(f64, 240), tm.bpmAt(720720));
    try t_.expectEqual(@as(f64, 240), tm.bpmAt(10_000_000));
    // Before tick 0, segment 0 extends backward.
    try t_.expectEqual(@as(f64, 120), tm.bpmAt(-500));
    // The constant map reports its own bpm.
    const flat = TimeMap.init(90, 3);
    try t_.expectEqual(@as(f64, 90), flat.bpmAt(123456));
}
