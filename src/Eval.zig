//! `Eval` — the compiler-side facade over `EvalCore` (02 P1).
//!
//! `Eval.Evaluator` IS `EvalCore.Evaluator`: the same type by alias, so
//! every method, every field, and every constant below is the engine's
//! own, preserved by construction — silent drift is unrepresentable,
//! and the one-line comptime identity assert pins it. The exact
//! historical call `Eval.Evaluator.init(gpa, &result)` keeps compiling
//! UNMODIFIED: the engine's generic `init` accepts anything carrying
//! `.evalContext()` (the compile result vends its tree-arm
//! `EvalCore.Context`), or a `Context` directly — the runtime's
//! binary-arm spelling. There is no `Eval.init` free function and no
//! respelled caller (`Driver`, the fuzz harnesses, the CLI, and the
//! tests below all keep their frozen spellings).
//!
//! This file sits OUTSIDE the runtime closure on purpose: it may name
//! `Compile` (its tests compile real scores); the engine leaf may not.
//! The engine's semantics documentation moved with the engine — see
//! `EvalCore.zig`'s module header (boundary rules, control/bpm state,
//! the fixed-order float seams, the determinism claim).

const std = @import("std");
const sjon = @import("sjon");
const TrackTable = @import("TrackTable.zig");
const Writes = @import("Writes.zig");
const Compile = @import("Compile.zig");
const test_support = @import("test_support.zig");
const EvalCore = @import("EvalCore.zig");

/// The frame evaluator — `EvalCore`'s engine, aliased whole. Same type:
/// `init` (both comptime arms), every method, every field.
pub const Evaluator = EvalCore.Evaluator;

/// The shared grid position type (`i64`), re-exported for call sites.
pub const Tick = EvalCore.Tick;

/// Time conversion failures (host clock out of range).
pub const Error = EvalCore.Error;

/// Dynamic control slots available beyond the document's own.
pub const MAX_DYNAMIC_CONTROLS = EvalCore.MAX_DYNAMIC_CONTROLS;

/// Sentinel target id of an env-only document control (writes nothing).
pub const NO_TARGET = EvalCore.NO_TARGET;

/// `Evaluator.init`'s error set.
pub const InitError = EvalCore.InitError;

/// The most entries one frame can produce (see `EvalCore`).
pub const MAX_FRAME_ENTRIES = EvalCore.MAX_FRAME_ENTRIES;

comptime {
    // Identity — the facade cannot drift from the engine it aliases.
    std.debug.assert(Evaluator == EvalCore.Evaluator);
}

// ---------------------------------------------------------------------------
// Tests (compile a real score; golden values hand-computed)
// ---------------------------------------------------------------------------

const t_ = std.testing;

const targets = [_]Compile.Target{
    .{ .name = "radius", .ncomp = 1 },
    .{ .name = "tint", .ncomp = 3 },
};

// Trigger lanes want a full-width and a scalar target: `pulse` (ncomp 4)
// reads all four lanes (phase, count, gate, beats-since); `hit` (ncomp 1)
// keeps only `phase` and proves the higher lanes are zeroed by truncation.
const trigger_targets = [_]Compile.Target{
    .{ .name = "pulse", .ncomp = 4 },
    .{ .name = "hit", .ncomp = 1 },
};

fn compileScoreWith(source: [:0]const u8, tgts: []const Compile.Target) !Compile.CompileResult {
    var r = try Compile.compile(t_.allocator, test_support.schema(), source, tgts);
    errdefer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t_.expect(r.ok());
    return r;
}

fn compileScore(source: [:0]const u8) !Compile.CompileResult {
    return compileScoreWith(source, &targets);
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
    var ev = try Evaluator.init(t_.allocator, &r);
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
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // 9 beats ≡ 1 beat into the 8-beat loop → linear 1/8.
    const wrapped = ev.evalTicks(try map.tickFromBeats(9))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 0.125), wrapped, 1e-6);
    // Negative time wraps forward: -1b ≡ 7b → 7/8.
    const negative = ev.evalTicks(try map.tickFromBeats(-1))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 0.875), negative, 1e-6);
}

test "tempo-map: evalSeconds wraps in seconds — loop replays the early segment" {
    // 120 bpm doubling to 240 at beat 4; dur 8b (tick 1441440) is
    // wall-clock 3 s. t = 3.5 s must replay 0.5 s of SEGMENT 0 (beat 1);
    // the tick-domain wrap would read 1.5 s of segment-1 tempo and land
    // on beat 2 — double the correct position.
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4] :dur 8b :end loop)
        \\(tempo :at 4b :bpm 240)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 8b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    const wrapped = (try ev.evalSeconds(3.5))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 0.125), wrapped, 1e-6);
    // Bit-identical to evaluating the wrapped time directly.
    try t_.expectEqual((try ev.evalSeconds(0.5))[0].value[0], wrapped);
    // The bug the seconds-wrap prevents: tick-wrapping the raw conversion.
    const buggy = ev.evalTicks(@mod(try map.tickFromSeconds(3.5), 1441440))[0].value[0];
    try t_.expectApproxEqAbs(@as(f32, 0.25), buggy, 1e-6);
    try t_.expect(buggy != wrapped);
}

test "last_tick reports the tick a frame was ACTUALLY computed at" {
    // The probe exists because that tick is not recoverable from outside.
    // `evalSeconds` wraps SECONDS for a mapped score and then converts;
    // `evalTicks` wraps again in ticks. So a consumer wanting to report a
    // frame's musical position cannot call `tickFromSeconds` a second time
    // — on any looping score the two answers differ — and must not
    // re-spell the wrap, which is a pinned determinism seam.
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4] :dur 8b :end loop)
        \\(tempo :at 4b :bpm 240)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 8b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    _ = try ev.evalSeconds(3.5);
    // 3.5 s wraps to 0.5 s of wall clock, which is beat 1 = tick 180180.
    try t_.expectEqual(@as(Tick, 180180), ev.last_tick);
    // Evaluating the wrapped time directly agrees, as the values already do.
    _ = try ev.evalSeconds(0.5);
    try t_.expectEqual(@as(Tick, 180180), ev.last_tick);
    // And the naive recomputation does NOT — this is the whole point.
    try t_.expect((try map.tickFromSeconds(3.5)) != ev.last_tick);

    // A constant score wraps in the tick domain instead; the probe reports
    // the post-wrap value there too.
    var c = try compileScore(
        \\(transport :bpm 120 :meter [4 4] :dur 4b :end loop)
        \\(track :target radius (key :at 0b :value 0.0) (key :at 4b :value 1.0))
    );
    defer c.deinit();
    var cev = try Evaluator.init(t_.allocator, &c);
    defer cev.deinit();
    _ = try cev.evalSeconds(2.5); // dur 4b = 2 s, so this is 0.5 s in
    try t_.expectEqual(@as(Tick, 180180), cev.last_tick);

    // `evalTicks` is the same seam, so it sets the probe too.
    _ = cev.evalTicks(720720 + 180180);
    try t_.expectEqual(@as(Tick, 180180), cev.last_tick);
}

test "tempo-map: evalSeconds hold clamps at loop_secs" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4] :dur 8b :end hold)
        \\(tempo :at 4b :bpm 240)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 8b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    try t_.expectEqual(@as(f32, 1.0), (try ev.evalSeconds(5.0))[0].value[0]);
    try t_.expectEqual((try ev.evalSeconds(3.0))[0].value[0], (try ev.evalSeconds(5.0))[0].value[0]);
    // Below the edge the map is live: 2.5 s = 2 beats into segment 1 →
    // beat 6 → 0.75.
    try t_.expectApproxEqAbs(@as(f32, 0.75), (try ev.evalSeconds(2.5))[0].value[0], 1e-6);
}

test "tempo-map: :emit [bpm] steps at the boundary and matches (track :expr bpm) bit-exactly" {
    const bpm_targets = [_]Compile.Target{
        .{ .name = "bpm", .ncomp = 1 },
        .{ .name = "radius", .ncomp = 1 },
    };
    var r = try compileScoreWith(
        \\(transport :bpm 120 :meter [4 4] :emit [bpm])
        \\(tempo :at 4b :bpm 240)
        \\(track :target radius :expr bpm)
    , &bpm_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    // One tick before the boundary: both lanes read segment 0.
    const before = ev.evalTicks(720719);
    try t_.expectEqual(@as(usize, 2), before.len);
    try t_.expectEqual(@as(f32, 120), before[0].value[0]); // emit lane
    try t_.expectEqual(before[0].value[0], before[1].value[0]); // expr twin
    // At the boundary: the step lands, still bit-identical.
    const after = ev.evalTicks(720720);
    try t_.expectEqual(@as(f32, 240), after[0].value[0]);
    try t_.expectEqual(after[0].value[0], after[1].value[0]);
}

test "emit lanes: every EmitName matches its :expr twin bit-exactly (incl. map boundary, negative tick)" {
    const twin_targets = [_]Compile.Target{
        .{ .name = "beat", .ncomp = 1 },
        .{ .name = "bar", .ncomp = 1 },
        .{ .name = "phase", .ncomp = 1 },
        .{ .name = "bpm", .ncomp = 1 },
        .{ .name = "t", .ncomp = 1 },
        .{ .name = "x-beat", .ncomp = 1 },
        .{ .name = "x-bar", .ncomp = 1 },
        .{ .name = "x-phase", .ncomp = 1 },
        .{ .name = "x-bpm", .ncomp = 1 },
        .{ .name = "x-t", .ncomp = 1 },
    };
    var r = try compileScoreWith(
        \\(transport :bpm 120 :meter [4 4] :emit [beat bar phase bpm t])
        \\(tempo :at 4b :bpm 240)
        \\(track :target x-beat :expr beat)
        \\(track :target x-bar :expr bar)
        \\(track :target x-phase :expr phase)
        \\(track :target x-bpm :expr bpm)
        \\(track :target x-t :expr t)
    , &twin_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    // Frame order: the five emit lanes (declaration order) then the five
    // expr twins (document order) — twin i of lane i. Sweep the origin,
    // both sides of the 4b tempo boundary, an off-grid late tick, and a
    // negative tick; every lane must equal its twin BIT-exactly (the
    // shared-formula claim `emitValue` makes).
    const ticks = [_]Tick{ 0, 4 * 720720 - 1, 4 * 720720, 7 * 720720 + 123, -720720 };
    for (ticks) |tk| {
        const entries = ev.evalTicks(tk);
        try t_.expectEqual(@as(usize, 10), entries.len);
        for (0..5) |i| {
            try t_.expectEqual(entries[i].value[0], entries[i + 5].value[0]);
        }
    }
}

test "tempo-map: a trigger's beats-since lane is tick-derived, map-unaffected" {
    var r = try compileScoreWith(
        \\(transport :bpm 120 :meter [4 4])
        \\(tempo :at 4b :bpm 240)
        \\(trigger :target pulse :every 2b)
    , &trigger_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    // Beat 5: last event at beat 4, one beat ago — phase 0.5 through the
    // 2-beat period, beats-since exactly 1, regardless of the map.
    const e = ev.evalTicks(5 * 180180)[0];
    try t_.expectEqual(@as(f32, 0.5), e.value[0]);
    try t_.expectEqual(@as(f32, 1.0), e.value[3]);
}

test "vector tracks interpolate per component, zero lanes stay zero" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(track :target tint
        \\  (key :at 0b :value [1 0 0.5])
        \\  (key :at 2b :value [0 1 0.5]))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
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
    var ev = try Evaluator.init(t_.allocator, &r);
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
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    var buf_a: [Writes.encodedLen(2)]u8 align(4) = undefined;
    var buf_b: [Writes.encodedLen(2)]u8 align(4) = undefined;
    const times = [_]f64{ 0.0, 0.123456789, 1.5, 7.25, -2.5, 1e-9 };
    for (times) |s| {
        const a = try Writes.encode(try ev.evalSeconds(s), &buf_a);
        // A fresh evaluator (cold cache) must agree byte-for-byte —
        // the cache is a pure optimization, never semantics.
        var ev2 = try Evaluator.init(t_.allocator, &r);
        defer ev2.deinit();
        const b = try Writes.encode(try ev2.evalSeconds(s), &buf_b);
        try t_.expectEqualSlices(u8, a, b);
    }
}

test "expr tracks: golden values, vector exprs, mixed with keyframes" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :expr (+ 0.25 (* 0.25 beat)))
        \\(track :target tint :expr [phase phase phase])
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // beat 0: 0.25; beat 2: 0.75 — pure affine, dyadic-exact.
    try t_.expectEqual(@as(f32, 0.25), ev.evalTicks(0)[0].value[0]);
    const at2 = ev.evalTicks(try map.tickFromBeats(2));
    try t_.expectEqual(@as(usize, 2), at2.len);
    try t_.expectEqual(@as(f32, 0.75), at2[0].value[0]);
    // 2 beats into a 4/4 bar = phase 0.5, all three lanes; lane 3 zero.
    try t_.expectEqual(@as(u8, 3), at2[1].ncomp);
    try t_.expectEqual(@as(f32, 0.5), at2[1].value[0]);
    try t_.expectEqual(@as(f32, 0.5), at2[1].value[2]);
    try t_.expectEqual(@as(f32, 0), at2[1].value[3]);
    try t_.expectEqual(@as(u64, 0), ev.expr_failures);
}

test "expr tracks: loop wrap applies to the env (pure function of wrapped tick)" {
    var r = try compileScore(
        \\(transport :bpm 120 :dur 1bar :end loop)
        \\(track :target radius :expr (+ beat 0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;
    // 5 beats wraps to 1 beat inside the 4-beat loop.
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(try map.tickFromBeats(5))[0].value[0]);
}

test "expr runtime failure omits the write and counts it" {
    // Dry-run at beat 0 passes (1/2); beat 2 divides by zero. The
    // failing frame drops the radius write, keeps the tint write, and
    // the next frame recovers — pure function of time throughout.
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(track :target radius :expr (/ 1 (- 2 beat)))
        \\(track :target tint :expr [phase phase phase])
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    try t_.expectEqual(@as(usize, 2), ev.evalTicks(0).len);
    const failing = ev.evalTicks(try map.tickFromBeats(2));
    try t_.expectEqual(@as(usize, 1), failing.len);
    try t_.expectEqual(@as(u8, 3), failing[0].ncomp); // the tint entry
    try t_.expectEqual(@as(u64, 1), ev.expr_failures);
    try t_.expectEqual(@as(usize, 2), ev.evalTicks(try map.tickFromBeats(3)).len);
}

test "expr tracks: same time twice → byte-identical encoded writes" {
    var r = try compileScore(
        \\(transport :bpm 97 :meter [7 8] :dur 4bar :end loop)
        \\(track :target radius :expr (+ 0.5 (* 0.5 (sin (* (tau) phase)))))
        \\(track :target tint :expr [(sin beat) (sin bar) (sin t)])
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    var buf_a: [Writes.encodedLen(2)]u8 align(4) = undefined;
    var buf_b: [Writes.encodedLen(2)]u8 align(4) = undefined;
    const times = [_]f64{ 0.0, 0.123456789, 1.5, 7.25, -2.5, 1e-9, 60.0 };
    for (times) |s| {
        const a = try Writes.encode(try ev.evalSeconds(s), &buf_a);
        var ev2 = try Evaluator.init(t_.allocator, &r);
        defer ev2.deinit();
        const b = try Writes.encode(try ev2.evalSeconds(s), &buf_b);
        try t_.expectEqualSlices(u8, a, b);
    }
}

test "expr tracks read document control values" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(control :id sway :value 0.5)
        \\(track :target radius :expr (* sway 2))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(0)[0].value[0]);
}

test "document control writes after the track; live override wins; clear restores" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(control :id knob :target radius :value 0.4)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 4b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;
    const at2 = try map.tickFromBeats(2);

    // Track write first (mid-segment 0.5), control write last — the pin
    // outranks the score for in-order consumers.
    const idle = ev.evalTicks(at2);
    try t_.expectEqual(@as(usize, 2), idle.len);
    try t_.expectEqual(@as(f32, 0.5), idle[0].value[0]);
    try t_.expectEqual(@as(f32, 0.4), idle[1].value[0]);
    try t_.expectEqual(@as(u16, 0), idle[1].target_id);

    try t_.expect(ev.setControl(0, .{ 0.9, 0, 0, 0 }));
    try t_.expectEqual(@as(f32, 0.9), ev.evalTicks(at2)[1].value[0]);

    try t_.expect(ev.clearControl(0));
    try t_.expectEqual(@as(f32, 0.4), ev.evalTicks(at2)[1].value[0]);
}

test "env-only controls feed expressions live and write nothing" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(control :id sway :value 0.5)
        \\(track :target radius :expr (* sway 2))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    const idle = ev.evalTicks(0);
    try t_.expectEqual(@as(usize, 1), idle.len); // no control write entry
    try t_.expectEqual(@as(f32, 1), idle[0].value[0]);

    try t_.expect(ev.setControl(0, .{ 0.25, 0, 0, 0 }));
    try t_.expectEqual(@as(f32, 0.5), ev.evalTicks(0)[0].value[0]);
    try t_.expect(ev.clearControl(0));
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(0)[0].value[0]);
}

test "dynamic control slots write only while held" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 4b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    // Lift the tint uniform (target id 1, vec3) without any text pin.
    const idx = ev.registerControl(1, 0, 3).?;
    try t_.expectEqual(@as(usize, 1), ev.evalTicks(0).len); // idle: silent

    try t_.expect(ev.setControl(idx, .{ 1, 2, 3, 0 }));
    const held = ev.evalTicks(0);
    try t_.expectEqual(@as(usize, 2), held.len);
    try t_.expectEqual(@as(u16, 1), held[1].target_id);
    try t_.expectEqual(@as(u8, 3), held[1].ncomp);
    try t_.expectEqual(@as(f32, 2), held[1].value[1]);

    try t_.expect(ev.clearControl(idx));
    try t_.expectEqual(@as(usize, 1), ev.evalTicks(0).len);
}

test "full-house frame: every source saturated lands exactly MAX_FRAME_ENTRIES" {
    // The cap is EXACT, not merely safe: all emit lanes + MAX_TRACKS
    // single-key tracks + MAX_CONTROLS targeted pins + every dynamic slot
    // held live produce one write each, and the tight wasm writes zone
    // (`Writes.encodedLen(MAX_FRAME_ENTRIES)`) fits the frame with zero
    // slack — one byte less is BufferTooSmall.
    var arena_state = std.heap.ArenaAllocator.init(t_.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const emit_fields = @typeInfo(TrackTable.EmitName).@"enum".fields;
    var tgts: std.ArrayList(Compile.Target) = .empty;
    var src: std.ArrayList(u8) = .empty;

    try src.appendSlice(arena, "(transport :bpm 120 :meter [4 4] :emit [");
    inline for (emit_fields) |f| {
        try tgts.append(arena, .{ .name = f.name, .ncomp = 1 });
        try src.appendSlice(arena, f.name);
        try src.append(arena, ' ');
    }
    try src.appendSlice(arena, "])\n");
    for (0..TrackTable.MAX_TRACKS) |i| {
        const name = try std.fmt.allocPrint(arena, "k{d:0>3}", .{i});
        try tgts.append(arena, .{ .name = name, .ncomp = 1 });
        try src.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "(track :target {s} (key :at 0b :value 0.5))\n",
            .{name},
        ));
    }
    for (0..TrackTable.MAX_CONTROLS) |i| {
        const name = try std.fmt.allocPrint(arena, "c{d:0>2}", .{i});
        try tgts.append(arena, .{ .name = name, .ncomp = 1 });
        try src.appendSlice(arena, try std.fmt.allocPrint(
            arena,
            "(control :id v{d:0>2} :target {s} :value 0.25)\n",
            .{ i, name },
        ));
    }
    const dyn_base: u16 = @intCast(tgts.items.len);
    for (0..MAX_DYNAMIC_CONTROLS) |i| {
        const name = try std.fmt.allocPrint(arena, "d{d:0>2}", .{i});
        try tgts.append(arena, .{ .name = name, .ncomp = 1 });
    }

    var r = try compileScoreWith(try arena.dupeZ(u8, src.items), tgts.items);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    // Idle dynamic slots are silent: emit + tracks + document controls.
    const static_count = emit_fields.len + TrackTable.MAX_TRACKS + TrackTable.MAX_CONTROLS;
    try t_.expectEqual(static_count, ev.evalTicks(0).len);

    // Register and hold every dynamic slot; the 65th registration is refused.
    for (0..MAX_DYNAMIC_CONTROLS) |i| {
        const slot = ev.registerControl(dyn_base + @as(u16, @intCast(i)), 0, 1).?;
        try t_.expect(ev.setControl(slot, .{ 0.75, 0, 0, 0 }));
    }
    try t_.expectEqual(@as(?usize, null), ev.registerControl(dyn_base, 0, 1));

    const full = ev.evalTicks(0);
    try t_.expectEqual(@as(usize, MAX_FRAME_ENTRIES), full.len);

    var buf: [Writes.encodedLen(MAX_FRAME_ENTRIES)]u8 = undefined;
    const encoded = try Writes.encode(full, &buf);
    try t_.expectEqual(buf.len, encoded.len);
    try t_.expectError(error.BufferTooSmall, Writes.encode(full, buf[0 .. buf.len - 1]));
}

test "setControl rejects bad indices and non-finite values" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(control :id knob :target radius :value 0.4)
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    try t_.expect(!ev.setControl(1, .{ 0, 0, 0, 0 })); // no dynamic slot registered
    try t_.expect(!ev.setControl(0, .{ std.math.nan(f32), 0, 0, 0 }));
    try t_.expect(!ev.setControl(0, .{ 0, std.math.inf(f32), 0, 0 }));
    try t_.expect(!ev.clearControl(7));
    // The rejected calls changed nothing: the document value still writes.
    try t_.expectEqual(@as(f32, 0.4), ev.evalTicks(0)[0].value[0]);
}

test "setBpm rescales the seconds projection; the tick grid stands still" {
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(track :target radius
        \\  (key :at 0b :value 0.0)
        \\  (key :at 4b :value 1.0))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    // 1 s at 120 bpm = 2 beats → 0.5.
    try t_.expectEqual(@as(f32, 0.5), (try ev.evalSeconds(1.0))[0].value[0]);
    try t_.expect(ev.setBpm(60));
    // 1 s at 60 bpm = 1 beat → 0.25.
    try t_.expectEqual(@as(f32, 0.25), (try ev.evalSeconds(1.0))[0].value[0]);
    // Tick-domain results are tempo-independent.
    const map = &r.table.?.transport.map;
    try t_.expectEqual(@as(f32, 0.5), ev.evalTicks(try map.tickFromBeats(2))[0].value[0]);

    try t_.expect(!ev.setBpm(0));
    try t_.expect(!ev.setBpm(std.math.nan(f64)));
    try t_.expectEqual(@as(f64, 60), ev.transport.map.bpm);

    // The nudge is evaluator state: the compiled table keeps the document's
    // tempo, and a fresh evaluator over the same result starts from it.
    try t_.expectEqual(@as(f64, 120), r.table.?.transport.map.bpm);
    var fresh = try Evaluator.init(t_.allocator, &r);
    defer fresh.deinit();
    try t_.expectEqual(@as(f32, 0.5), (try fresh.evalSeconds(1.0))[0].value[0]);
}

test "setBpm refuses a mapped score (tempo truth is score text); a constant one keeps loop_secs coherent" {
    var mapped = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(tempo :at 4b :bpm 240)
        \\(track :target radius (key :at 0b :value 0))
    );
    defer mapped.deinit();
    var mev = try Evaluator.init(t_.allocator, &mapped);
    defer mev.deinit();
    try t_.expect(!mev.setBpm(90));
    try t_.expectEqual(@as(f64, 120), mev.transport.map.bpm);

    var flat = try compileScore(
        \\(transport :bpm 120 :dur 2bar :end loop)
        \\(track :target radius (key :at 0b :value 0))
    );
    defer flat.deinit();
    var fev = try Evaluator.init(t_.allocator, &flat);
    defer fev.deinit();
    try t_.expect(fev.setBpm(240));
    try t_.expectEqual(@as(f64, 240), fev.transport.map.bpm);
    // 2 bars = 1441440 ticks at 720720 tps = 2 s.
    try t_.expectEqual(@as(?f64, 2.0), fev.transport.loop_secs);
    // The table is untouched — 2 bars at the document's 120 bpm is 4 s.
    try t_.expectEqual(@as(f64, 120), flat.table.?.transport.map.bpm);
    try t_.expectEqual(@as(?f64, 4.0), flat.table.?.transport.loop_secs);
}

test "determinism holds under identical control state" {
    var r = try compileScore(
        \\(transport :bpm 97 :meter [7 8])
        \\(control :id knob :target radius :value 0.4)
        \\(control :id sway :value 0.3)
        \\(track :target tint :expr [sway (sin (* sway beat)) phase])
    );
    defer r.deinit();

    var buf_a: [Writes.encodedLen(3)]u8 align(4) = undefined;
    var buf_b: [Writes.encodedLen(3)]u8 align(4) = undefined;
    for ([_]f64{ 0.0, 1.5, 7.25 }) |s| {
        var a = try Evaluator.init(t_.allocator, &r);
        defer a.deinit();
        var b = try Evaluator.init(t_.allocator, &r);
        defer b.deinit();
        try t_.expect(a.setControl(0, .{ 0.7, 0, 0, 0 }));
        try t_.expect(b.setControl(0, .{ 0.7, 0, 0, 0 }));
        try t_.expect(a.setControl(1, .{ 0.6, 0, 0, 0 }));
        try t_.expect(b.setControl(1, .{ 0.6, 0, 0, 0 }));
        const wa = try Writes.encode(try a.evalSeconds(s), &buf_a);
        const wb = try Writes.encode(try b.evalSeconds(s), &buf_b);
        try t_.expectEqualSlices(u8, wa, wb);
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
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // Forward sweep, then jump back — values must match a cold eval.
    const probe = [_]f64{ 0.5, 1.5, 2.5, 3.5, 1.25, 0.75, 3.9, 0.1 };
    for (probe) |beats| {
        const warm = ev.evalTicks(try map.tickFromBeats(beats))[0].value[0];
        var cold = try Evaluator.init(t_.allocator, &r);
        defer cold.deinit();
        const expect = cold.evalTicks(try map.tickFromBeats(beats))[0].value[0];
        try t_.expectEqual(expect, warm);
    }
}

// ---------------------------------------------------------------------------
// (transport :emit …) clock lanes — evaluated before tracks, bit-exact
// with an equivalent :expr track (same ExprTrack env), wrapped like the
// clock. Emit targets are named after the reserved time names.
// ---------------------------------------------------------------------------

// Emit targets first, then a `_ref` target per lane carrying the same
// value via an :expr track — the two must land byte-identically.
const emit_ref_targets = [_]Compile.Target{
    .{ .name = "beat", .ncomp = 1 },
    .{ .name = "bar", .ncomp = 1 },
    .{ .name = "phase", .ncomp = 1 },
    .{ .name = "t", .ncomp = 1 },
    .{ .name = "beat_ref", .ncomp = 1 },
    .{ .name = "bar_ref", .ncomp = 1 },
    .{ .name = "phase_ref", .ncomp = 1 },
    .{ .name = "t_ref", .ncomp = 1 },
};

test "emit lanes: bit-exact with an equivalent :expr track" {
    var r = try compileScoreWith(
        \\(transport :bpm 125 :meter [4 4] :emit [beat bar phase t])
        \\(track :target beat_ref :expr beat)
        \\(track :target bar_ref :expr bar)
        \\(track :target phase_ref :expr phase)
        \\(track :target t_ref :expr t)
    , &emit_ref_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // At every probe the four emit lanes lead (document order), then the
    // four ref tracks — each emit value equals its ref, bit-for-bit.
    for ([_]f64{ 0, 1.5, 2.333, 7.1, -3.25 }) |beats| {
        const w = ev.evalTicks(try map.tickFromBeats(beats));
        try t_.expectEqual(@as(usize, 8), w.len);
        try t_.expectEqual(w[4].value[0], w[0].value[0]); // beat  vs beat_ref
        try t_.expectEqual(w[5].value[0], w[1].value[0]); // bar   vs bar_ref
        try t_.expectEqual(w[6].value[0], w[2].value[0]); // phase vs phase_ref
        try t_.expectEqual(w[7].value[0], w[3].value[0]); // t     vs t_ref
        // Scalar lanes, higher components cleared.
        try t_.expectEqual(@as(u8, 1), w[0].ncomp);
        try t_.expectEqual(@as(f32, 0), w[0].value[1]);
    }

    // Emit lanes carry their resolved target ids in :emit order.
    const w0 = ev.evalTicks(0);
    try t_.expectEqual(@as(u16, 0), w0[0].target_id); // beat  = targets[0]
    try t_.expectEqual(@as(u16, 1), w0[1].target_id); // bar
    try t_.expectEqual(@as(u16, 2), w0[2].target_id); // phase
    try t_.expectEqual(@as(u16, 3), w0[3].target_id); // t
}

test "emit lanes: write order emit → track → control on the same target" {
    // All three write `beat`; consumers apply in order, so the emitted
    // lane lands first and is overridden by the track, then the control.
    var r = try compileScoreWith(
        \\(transport :bpm 120 :emit [beat])
        \\(control :id knob :target beat :value 7.0)
        \\(track :target beat
        \\  (key :at 0b :value 5.0)
        \\  (key :at 4b :value 9.0))
    , &emit_ref_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    const w = ev.evalTicks(0);
    try t_.expectEqual(@as(usize, 3), w.len);
    try t_.expectEqual(@as(u16, 0), w[0].target_id); // emit beat
    try t_.expectEqual(@as(f32, 0), w[0].value[0]); //   = 0 at beat 0
    try t_.expectEqual(@as(u16, 0), w[1].target_id); // track beat
    try t_.expectEqual(@as(f32, 5), w[1].value[0]); //    holds first key
    try t_.expectEqual(@as(u16, 0), w[2].target_id); // control beat
    try t_.expectEqual(@as(f32, 7), w[2].value[0]); //    pin wins last
}

test "emit lanes: end-behavior clamps/wraps the clock like tracks" {
    // hold: past :dur the beat lane freezes at the score length.
    {
        var r = try compileScoreWith(
            \\(transport :bpm 120 :meter [4 4] :dur 1bar :end hold :emit [beat])
        , &emit_ref_targets);
        defer r.deinit();
        var ev = try Evaluator.init(t_.allocator, &r);
        defer ev.deinit();
        const map = &r.table.?.transport.map;
        // 1 bar = 4 beats; beat 6 clamps to beat 4.
        try t_.expectEqual(@as(f32, 4), ev.evalTicks(try map.tickFromBeats(6))[0].value[0]);
    }
    // loop: the beat lane wraps with the playhead.
    {
        var r = try compileScoreWith(
            \\(transport :bpm 120 :meter [4 4] :dur 1bar :end loop :emit [beat])
        , &emit_ref_targets);
        defer r.deinit();
        var ev = try Evaluator.init(t_.allocator, &r);
        defer ev.deinit();
        const map = &r.table.?.transport.map;
        // beat 5 wraps to beat 1 inside the 4-beat loop.
        try t_.expectEqual(@as(f32, 1), ev.evalTicks(try map.tickFromBeats(5))[0].value[0]);
    }
}

// ---------------------------------------------------------------------------
// (scene …) windows — plan 01 Phase 3: eval semantics. A scened track
// writes ONLY while the playhead sits inside its window [start, start+dur);
// outside, its write is OMITTED (like an expr-NaN), so an overlapping later
// scene hands the target off by write order. Scened expr tracks get two
// scene-local env bindings: scene-beat (beats since the window opened) and
// scene-phase (0..1 through it).
// ---------------------------------------------------------------------------

test "scene window gate: a scened track writes only inside [start, start+dur)" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name drop :at 4b :dur 8b
        \\  (track :target radius
        \\    (key :at 0b :value 0.2)
        \\    (key :at 8b :value 0.8)))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;
    const start = try map.tickFromBeats(4); // window [4b, 12b)
    const end = try map.tickFromBeats(12);

    // One tick before the window: nothing written.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(start - 1).len);
    // Scene start (inclusive): writes, structural landing on the first key.
    const at_start = ev.evalTicks(start);
    try t_.expectEqual(@as(usize, 1), at_start.len);
    try t_.expectEqual(@as(f32, 0.2), at_start[0].value[0]);
    // Mid-window: interpolates (absolute 8b = scene-relative 4b, halfway).
    try t_.expectApproxEqAbs(@as(f32, 0.5), ev.evalTicks(try map.tickFromBeats(8))[0].value[0], 1e-6);
    // Last tick of the window: still writing.
    try t_.expectEqual(@as(usize, 1), ev.evalTicks(end - 1).len);
    // Window end (exclusive): nothing written.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(end).len);
}

test "scene expr env: scene-beat and scene-phase bind scene-relative" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name drop :at 4b :dur 8b
        \\  (track :target radius :expr scene-beat)
        \\  (track :target tint :expr [scene-phase scene-phase scene-phase]))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // Scene start: scene-beat 0, scene-phase 0.
    const at_start = ev.evalTicks(try map.tickFromBeats(4));
    try t_.expectEqual(@as(usize, 2), at_start.len);
    try t_.expectEqual(@as(f32, 0), at_start[0].value[0]); // scene-beat
    try t_.expectEqual(@as(f32, 0), at_start[1].value[0]); // scene-phase

    // Halfway (absolute 8b = scene-relative 4b of 8): beat 4, phase 0.5.
    const mid = ev.evalTicks(try map.tickFromBeats(8));
    try t_.expectEqual(@as(f32, 4), mid[0].value[0]);
    try t_.expectEqual(@as(f32, 0.5), mid[1].value[0]);
    try t_.expectEqual(@as(f32, 0.5), mid[1].value[2]);
}

test "scene window gate: loop wrap re-enters the scene" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4] :dur 4bar :end loop)
        \\(scene :name drop :at 4b :dur 8b
        \\  (track :target radius
        \\    (key :at 0b :value 0.2)
        \\    (key :at 8b :value 0.8)))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // 16-beat loop; 20 beats wraps to 4 (scene start) → first key writes.
    const wrapped = ev.evalTicks(try map.tickFromBeats(20));
    try t_.expectEqual(@as(usize, 1), wrapped.len);
    try t_.expectEqual(@as(f32, 0.2), wrapped[0].value[0]);
    // 16 beats wraps to 0 (before the window) → nothing written.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(try map.tickFromBeats(16)).len);
}

// ---------------------------------------------------------------------------
// (trigger …) event lanes — plan 02 Phase 3. At wrapped tick T the trigger
// finds the last event ≤ T (none yet → write OMITTED) and writes, truncated
// to the target's ncomp: [0] phase = (T − event)/span, [1] count = event
// index, [2] gate = 1.0 on the exact event tick else 0.0, [3] beats-since =
// (T − event)/ppb. Each lane is an i64 tick delta through ONE f64 division
// (the eval seam), narrowed to f32 only at emission. A periodic schedule
// always has a next event (span = every); the last explicit :at event holds
// phase 1.0.
// ---------------------------------------------------------------------------

test "trigger periodic: exact tick gate=1 phase=0 count=k; mid phase=(T-event)/every, beats-since=(T-event)/ppb" {
    var r = try compileScoreWith(
        \\(transport :bpm 120 :meter [4 4])
        \\(trigger :target pulse :every 2b :offset 1b)
    , &trigger_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // Before the first event (offset 1b): the write is omitted.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(0).len);
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(try map.tickFromBeats(1) - 1).len);

    // First event (k=0) at 1b: gate 1, phase 0, count 0, beats-since 0.
    const e0 = ev.evalTicks(try map.tickFromBeats(1));
    try t_.expectEqual(@as(usize, 1), e0.len);
    try t_.expectEqual(@as(u8, 4), e0[0].ncomp);
    try t_.expectEqual(@as(f32, 0), e0[0].value[0]); // phase
    try t_.expectEqual(@as(f32, 0), e0[0].value[1]); // count
    try t_.expectEqual(@as(f32, 1), e0[0].value[2]); // gate
    try t_.expectEqual(@as(f32, 0), e0[0].value[3]); // beats-since

    // Third event (k=2) at 5b (= 1b + 2·2b): count 2, gate 1.
    const e2 = ev.evalTicks(try map.tickFromBeats(5));
    try t_.expectEqual(@as(f32, 2), e2[0].value[1]); // count
    try t_.expectEqual(@as(f32, 1), e2[0].value[2]); // gate

    // Mid-interval at 2b (event 1b, next 3b): phase 0.5, count 0, gate 0,
    // beats-since 1.0 (one beat elapsed).
    const em = ev.evalTicks(try map.tickFromBeats(2));
    try t_.expectEqual(@as(f32, 0.5), em[0].value[0]); // phase
    try t_.expectEqual(@as(f32, 0), em[0].value[1]); // count
    try t_.expectEqual(@as(f32, 0), em[0].value[2]); // gate
    try t_.expectEqual(@as(f32, 1), em[0].value[3]); // beats-since
}

test "trigger :at explicit: last event holds phase 1.0; ncomp-1 keeps phase, zeroes count/gate/beats-since" {
    var r = try compileScoreWith(
        \\(transport :bpm 120 :meter [4 4])
        \\(trigger :target hit :at [2b 4b 8b])
    , &trigger_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // Before the first hit: omitted.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(try map.tickFromBeats(1)).len);

    // First hit at 2b (k=0, next 4b): phase 0. ncomp-1 → only value[0].
    const h0 = ev.evalTicks(try map.tickFromBeats(2));
    try t_.expectEqual(@as(usize, 1), h0.len);
    try t_.expectEqual(@as(u8, 1), h0[0].ncomp);
    try t_.expectEqual(@as(f32, 0), h0[0].value[0]); // phase
    // Truncation: the count/gate/beats-since lanes stay zeroed above ncomp.
    try t_.expectEqual(@as(f32, 0), h0[0].value[1]);
    try t_.expectEqual(@as(f32, 0), h0[0].value[2]);
    try t_.expectEqual(@as(f32, 0), h0[0].value[3]);

    // Mid at 3b (event 2b, span 2b): phase 0.5.
    try t_.expectEqual(@as(f32, 0.5), ev.evalTicks(try map.tickFromBeats(3))[0].value[0]);

    // Second hit exact 4b (k=1): gate would be lane 2 = 1.0, but ncomp-1
    // truncates it away → value[2] stays 0; phase 0 in lane 0.
    const h1 = ev.evalTicks(try map.tickFromBeats(4));
    try t_.expectEqual(@as(f32, 0), h1[0].value[0]); // phase
    try t_.expectEqual(@as(f32, 0), h1[0].value[2]); // gate truncated

    // Last hit exact 8b (k=2, no next): phase holds 1.0.
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(try map.tickFromBeats(8))[0].value[0]);
    // After the last hit (10b): phase still held at 1.0.
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(try map.tickFromBeats(10))[0].value[0]);
}

test "trigger periodic under loop: wrap resets count on the local timeline" {
    var r = try compileScoreWith(
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(trigger :target pulse :every 2b :offset 1b)
    , &trigger_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // 2-bar loop = 8 beats; events at 1b,3b,5b,7b. 9b wraps to 1b → the
    // count resets to 0 (not the unwrapped k=4) and the exact event gates.
    const w = ev.evalTicks(try map.tickFromBeats(9));
    try t_.expectEqual(@as(usize, 1), w.len);
    try t_.expectEqual(@as(f32, 0), w[0].value[1]); // count reset by wrap
    try t_.expectEqual(@as(f32, 1), w[0].value[2]); // gate: exact event after wrap
}

test "scened trigger: events fold the scene start; the window gate brackets the write" {
    var r = try compileScoreWith(
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name drop :at 4b :dur 8b
        \\  (trigger :target pulse :every 2b :offset 1b))
    , &trigger_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // Window [4b, 12b). First event = scene start 4b + offset 1b = 5b.
    // Before the window (3b): gated out.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(try map.tickFromBeats(3)).len);
    // Window open (4b): inside the gate, but the first event (5b) hasn't
    // fired yet → still omitted.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(try map.tickFromBeats(4)).len);
    // Exact first event 5b: gate 1, count 0.
    const e0 = ev.evalTicks(try map.tickFromBeats(5));
    try t_.expectEqual(@as(usize, 1), e0.len);
    try t_.expectEqual(@as(f32, 1), e0[0].value[2]); // gate
    try t_.expectEqual(@as(f32, 0), e0[0].value[1]); // count
    // Window end (12b, exclusive): gated out even though the periodic
    // schedule would otherwise fire.
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(try map.tickFromBeats(12)).len);
}

test "triggers: same time twice → byte-identical encoded writes (cold cursor vs warm)" {
    var r = try compileScoreWith(
        \\(transport :bpm 97 :meter [7 8] :dur 4bar :end loop)
        \\(trigger :target pulse :every 3b :offset 1b)
        \\(trigger :target hit :at [2b 5b 11b])
    , &trigger_targets);
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    var buf_a: [Writes.encodedLen(2)]u8 align(4) = undefined;
    var buf_b: [Writes.encodedLen(2)]u8 align(4) = undefined;
    const times = [_]f64{ 0.0, 0.123456789, 1.5, 7.25, -2.5, 1e-9, 30.0 };
    for (times) |s| {
        const a = try Writes.encode(try ev.evalSeconds(s), &buf_a);
        // A fresh (cold-cursor) evaluator must agree byte-for-byte — the
        // :at cursor cache is a pure optimization, never semantics.
        var ev2 = try Evaluator.init(t_.allocator, &r);
        defer ev2.deinit();
        const b = try Writes.encode(try ev2.evalSeconds(s), &buf_b);
        try t_.expectEqualSlices(u8, a, b);
    }
}

// ---------------------------------------------------------------------------
// (track … :pattern …) frame eval — plan 03 Phase 3. At wrapped tick T the
// pattern track queries its enclosing cycle window ([c·PPC, (c+1)·PPC), 1
// cycle = 1 bar as identity) once through the shared `PatternTrack`, then
// point-samples: the hap whose part span contains T with the latest onset
// (ties → last in query order — the top `stack` layer). No active hap → the
// write is OMITTED (a gap), like an expr-NaN. A per-hap expr drop at a later
// cycle (SJON `result.dropped`) or an uncoercible selected value counts in
// `expr_failures` and omits the write. Hap value exprs bind only the
// pattern-locals cycle/tick/seed this slice (pacer's time env in hap exprs is
// a separate follow-up — see the plan); literals + those locals are plenty.
// ---------------------------------------------------------------------------

test "pattern frame: structural landing on each fastcat slot, mid-slot holds" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern [0.1 0.2 0.3 0.4])
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // One 4/4 bar = one cycle = PPC ticks; the four slots start on beats
    // 0/1/2/3. At an exact slot onset the slot STARTING there lands (half-open
    // [begin, end), like a keyframe on its key) — structural, bit-exact.
    try t_.expectEqual(@as(f32, 0.1), ev.evalTicks(0)[0].value[0]);
    try t_.expectEqual(@as(f32, 0.2), ev.evalTicks(try map.tickFromBeats(1))[0].value[0]);
    try t_.expectEqual(@as(f32, 0.3), ev.evalTicks(try map.tickFromBeats(2))[0].value[0]);
    try t_.expectEqual(@as(f32, 0.4), ev.evalTicks(try map.tickFromBeats(3))[0].value[0]);
    // Mid-slot (half a beat into slot 0) still holds slot 0's value.
    const mid = ev.evalTicks(try map.tickFromBeats(1) - @divExact(try map.tickFromBeats(1), 2));
    try t_.expectEqual(@as(f32, 0.1), mid[0].value[0]);
    // Scalar target: exactly one write, higher lanes zero.
    const at0 = ev.evalTicks(0);
    try t_.expectEqual(@as(usize, 1), at0.len);
    try t_.expectEqual(@as(u8, 1), at0[0].ncomp);
    try t_.expectEqual(@as(f32, 0), at0[0].value[1]);
    try t_.expectEqual(@as(u64, 0), ev.expr_failures);
}

test "pattern frame: a silence slot is a gap — the write is omitted" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern [0.5 (silence)])
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    // First half of the cycle carries 0.5; the silent second half yields no
    // hap → no active hap at T → the write is omitted (len 0).
    try t_.expectEqual(@as(usize, 1), ev.evalTicks(0).len);
    try t_.expectEqual(@as(f32, 0.5), ev.evalTicks(0)[0].value[0]);
    try t_.expectEqual(@as(usize, 0), ev.evalTicks(try map.tickFromBeats(3)).len);
    try t_.expectEqual(@as(u64, 0), ev.expr_failures); // a gap is not a failure
}

test "pattern frame: a seeded expr leaf differs across cycles, identical across evaluators" {
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern (pure (rand01 seed cycle)))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const PPC = sjon.Pattern.PPC;

    // A bare `pure_expr` is one hap per cycle valued rand01(seed=0, cycle):
    // cycle 1 and cycle 2 bind cycle = 1 / 2, so the samples differ, yet each
    // is bit-identical from a cold second evaluator (pure function of tick).
    const c1 = ev.evalTicks(PPC)[0].value[0];
    const c2 = ev.evalTicks(2 * PPC)[0].value[0];
    try t_.expect(c1 != c2);
    try t_.expect(std.math.isFinite(c1) and std.math.isFinite(c2));

    var buf_a: [Writes.encodedLen(1)]u8 align(4) = undefined;
    var buf_b: [Writes.encodedLen(1)]u8 align(4) = undefined;
    for ([_]Tick{ 0, PPC, 2 * PPC, 5 * PPC }) |t| {
        const a = try Writes.encode(ev.evalTicks(t), &buf_a);
        var ev2 = try Evaluator.init(t_.allocator, &r);
        defer ev2.deinit();
        const b = try Writes.encode(ev2.evalTicks(t), &buf_b);
        try t_.expectEqualSlices(u8, a, b);
    }
}

test "pattern frame: a later-cycle expr drop counts in expr_failures and omits the write" {
    // Dry-run at cycle 0 passes (1/(1-0) = 1); cycle 1 divides by zero and
    // the hap drops; cycle 2 recovers (1/(1-2) = -1). The sibling expr track
    // always writes, so the pattern omission is isolated to its own entry.
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern (pure (/ 1 (- 1 cycle))))
        \\(track :target tint :expr [phase phase phase])
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const PPC = sjon.Pattern.PPC;

    // Cycle 0: pattern writes 1, tint writes → two entries.
    const c0 = ev.evalTicks(0);
    try t_.expectEqual(@as(usize, 2), c0.len);
    try t_.expectEqual(@as(f32, 1), c0[0].value[0]);
    try t_.expectEqual(@as(u64, 0), ev.expr_failures);

    // Cycle 1: the pattern hap drops (÷0) → only tint survives, and the drop
    // is counted.
    const c1 = ev.evalTicks(PPC);
    try t_.expectEqual(@as(usize, 1), c1.len);
    try t_.expectEqual(@as(u8, 3), c1[0].ncomp); // the tint entry
    try t_.expectEqual(@as(u64, 1), ev.expr_failures);

    // Cycle 2: 1/(1-2) = -1 is finite → the pattern recovers; the counter
    // does not decrease.
    const c2 = ev.evalTicks(2 * PPC);
    try t_.expectEqual(@as(usize, 2), c2.len);
    try t_.expectEqual(@as(f32, -1), c2[0].value[0]);
    try t_.expectEqual(@as(u64, 1), ev.expr_failures);
}

test "pattern frame: a dropped layer under a surviving one writes and is NOT counted" {
    // `(stack 0.5 (pure (/ 1 (- 1 cycle))))` layers a constant over an expr
    // that divides by zero at cycle 1. The expr hap drops there, but the 0.5
    // layer always lands — the write is produced, so the failure probe must
    // NOT tick (it counts omitted writes, not dropped haps).
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern (stack 0.5 (pure (/ 1 (- 1 cycle)))))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const PPC = sjon.Pattern.PPC;

    // Cycle 0: both layers land; the top (last) layer 1/(1-0)=1 wins the tie.
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(0)[0].value[0]);
    // Cycle 1: the expr layer drops, 0.5 survives → the write is produced and
    // nothing is counted, even sampling several ticks inside the cycle.
    for ([_]Tick{ PPC, PPC + @divExact(PPC, 3), 2 * PPC - 1 }) |t| {
        const w = ev.evalTicks(t);
        try t_.expectEqual(@as(usize, 1), w.len);
        try t_.expectEqual(@as(f32, 0.5), w[0].value[0]);
    }
    try t_.expectEqual(@as(u64, 0), ev.expr_failures);
}

test "pattern frame: a hap-dense expr pattern fits the fixed frame scratch (no gpa)" {
    // `evalTicks` takes no allocator — the frame path can only draw on the
    // evaluator's fixed pattern scratch. A cycle of 16 `pure_expr` haps drives
    // 16 SJON leaf evals (each through SJON's own 256 KiB internal scratch) on
    // top of the compile + hap arenas; if the buffer were too small the query
    // would OOM into a counted drop. A clean write with zero failures proves
    // the fixed buffer alone suffices.
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern (fast 16 (pure (rand01 seed cycle))))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const PPC = sjon.Pattern.PPC;

    for ([_]Tick{ 0, @divExact(PPC, 3), PPC, 7 * PPC + 12345 }) |t| {
        const w = ev.evalTicks(t);
        try t_.expectEqual(@as(usize, 1), w.len);
        try t_.expect(std.math.isFinite(w[0].value[0]));
    }
    try t_.expectEqual(@as(u64, 0), ev.expr_failures);
}

test "pattern frame: hap exprs read pacer's time env — beat tracks the clock" {
    // `(pure (* beat 2))` re-evaluates each frame with pacer's env chained
    // under the pattern-locals, so the hap's value follows the transport
    // clock inside its own span — including across the bar wrap, where the
    // pattern cycle advances AND `beat` keeps counting absolutely.
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern (pure (* beat 2)))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    try t_.expectEqual(@as(f32, 0), ev.evalTicks(0)[0].value[0]);
    try t_.expectEqual(@as(f32, 2), ev.evalTicks(try map.tickFromBeats(1))[0].value[0]);
    try t_.expectEqual(@as(f32, 5), ev.evalTicks(try map.tickFromBeats(2.5))[0].value[0]);
    // Beat 5 sits in bar/cycle 1: the env crosses the wrap with the clock.
    try t_.expectEqual(@as(f32, 10), ev.evalTicks(try map.tickFromBeats(5))[0].value[0]);
    try t_.expectEqual(@as(u64, 0), ev.expr_failures);
}

test "pattern frame: the pattern-local tick shadows pacer's frame tick" {
    // Both envs bind `tick`; inside a hap the PATTERN's is authoritative
    // (the frozen shadow rule): the leaf sees the hap's cycle-onset tick,
    // not the frame tick. Mid-cycle the frame tick is nonzero yet the value
    // stays the onset — 0 in cycle 0, PPC in cycle 1 (exact in f32).
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target radius :pattern (pure (+ tick 0)))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const PPC = sjon.Pattern.PPC;

    try t_.expectEqual(@as(f32, 0), ev.evalTicks(@divExact(PPC, 2))[0].value[0]);
    try t_.expectEqual(@as(f32, PPC), ev.evalTicks(PPC + @divExact(PPC, 2))[0].value[0]);
}

test "pattern frame: hap exprs read live control overrides" {
    // Same contract as `:expr` tracks: the env binds the EFFECTIVE control
    // value — document `:value` idle, the live override while set.
    var r = try compileScore(
        \\(transport :bpm 120)
        \\(control :id sway :value 0.5)
        \\(track :target radius :pattern (pure (* sway 2)))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();

    try t_.expectEqual(@as(f32, 1), ev.evalTicks(0)[0].value[0]);
    try t_.expect(ev.setControl(0, .{ 0.25, 0, 0, 0 }));
    try t_.expectEqual(@as(f32, 0.5), ev.evalTicks(0)[0].value[0]);
    try t_.expect(ev.clearControl(0));
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(0)[0].value[0]);
}

test "pattern frame: a scened pattern's hap exprs bind scene-beat" {
    // The scene-local names ride the same env as `:expr` tracks — bound
    // only inside the window, scene-relative.
    var r = try compileScore(
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name drop :at 1bar :dur 1bar
        \\  (track :target radius :pattern (pure (+ scene-beat 0))))
    );
    defer r.deinit();
    var ev = try Evaluator.init(t_.allocator, &r);
    defer ev.deinit();
    const map = &r.table.?.transport.map;

    try t_.expectEqual(@as(f32, 0), ev.evalTicks(try map.tickFromBeats(4))[0].value[0]);
    try t_.expectEqual(@as(f32, 1), ev.evalTicks(try map.tickFromBeats(5))[0].value[0]);
}
