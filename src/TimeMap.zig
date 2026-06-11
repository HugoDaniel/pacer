//! Transport math: bpm/meter ↔ ticks/beats/seconds on the shared grid.
//!
//! One bar = one cycle = `sjon.Pattern.PPC` ticks. The meter's
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
//! No allocation; pure value math. Overflow and non-finite input are
//! errors (they originate in user documents / host clocks), never panics.

const std = @import("std");
const sjon = @import("sjon");
const Pattern = sjon.Pattern;

pub const Tick = Pattern.Tick;

/// Explicit error set. `TickOverflow` mirrors `Pattern.Error` (result
/// magnitude past the 2^53 portable ceiling); `NonFiniteTime` = the host
/// handed a NaN/inf clock value or the conversion produced one.
pub const Error = error{ TickOverflow, NonFiniteTime };

bpm: f64,
beats_per_bar: i64,
/// `PPC / beats_per_bar`, exact by the meter-component 1..16 invariant.
ticks_per_beat: i64,
/// `(bpm * ticks_per_beat) / 60.0` — fixed op order, computed once.
ticks_per_second: f64,

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

/// THE seconds→ticks seam: one multiply, one floor. Host clock seconds
/// (audio `currentTime` or `performance.now()/1000`) in, grid tick out.
pub fn tickFromSeconds(self: *const TimeMap, seconds: f64) Error!Tick {
    return mulFloor(seconds, self.ticks_per_second);
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

/// Inverse projection for hosts/debug UIs (NOT part of the deterministic
/// eval path, which never round-trips through seconds).
pub fn secondsFromTick(self: *const TimeMap, t: Tick) f64 {
    return @as(f64, @floatFromInt(t)) / self.ticks_per_second;
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
