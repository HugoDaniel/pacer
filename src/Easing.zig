//! Easing programs — a list of easings acting as one.
//!
//! An easing is a unit map `e: [0,1] → ℝ` with `e(0) = 0`, `e(1) = 1`;
//! output may leave `[0,1]` (overshoot) and the keyframe lerp is
//! UNCLAMPED, which is what makes springs and bounces work. The `:ease`
//! slot compiles to a flat `Program`:
//!
//!   * a named primitive or `(chain …)` → one `Stage` whose op list is
//!     the flattened chain (`ops[1..]` applied to the previous op's
//!     output, i.e. `(chain E1 E2)` = `E2(E1(u))`);
//!   * `(seq (stage …) …)` → one `Stage` per stage, `:t`/`:v` weights
//!     normalized once at build (one division each, fixed op order) so
//!     the composed program spans exactly `[0,1] → [0,1]`.
//!
//! Evaluation is a linear stage scan + op switch — no recursion, no
//! allocation, no host-stack descent (the walker discipline does not
//! apply; programs are flat by construction).
//!
//! Determinism: primitives use only polynomials, `sjon.trig` kernels
//! (`sin64`/`cos64`/`exp64`/`pow64` — bit-identical native vs wasm32),
//! and fixed-count bisection for cubic-bezier (32 iterations, no epsilon
//! early-exit). Exact landing on key values is STRUCTURAL — segment
//! selection switches at key ticks, so `e(1)`'s last-ulp wobble (e.g. a
//! spring's residual oscillation) never leaks into the next segment.
//!
//! Caps (`MAX_STAGES`, `MAX_OPS`) are build errors, surfaced by the
//! compiler as `pacer_ease_cap_exceeded`-class diagnostics with spans.

const std = @import("std");
const sjon = @import("sjon");
const trig = sjon.trig;

/// Stage cap per program. A bounce-and-settle needs 3; 8 is headroom.
pub const MAX_STAGES = 8;
/// Op cap per stage (a stage's op list is its flattened chain).
pub const MAX_OPS = 4;

/// Explicit error set. All variants are user-document defects the
/// compiler maps to diagnostics with spans; none allocate.
pub const Error = error{
    /// More than `MAX_STAGES` stages in a `(seq …)`.
    EaseStagesExceeded,
    /// More than `MAX_OPS` primitives in a flattened `(chain …)`.
    EaseOpsExceeded,
    /// Non-positive `:t` weight, zero/near-zero `Σ:v`, or weights so
    /// skewed the normalized f32 stage boundaries collapse.
    EaseWeightsInvalid,
    /// Primitive parameter outside its domain (bezier x outside [0,1],
    /// spring damping 0, …).
    EaseParamsInvalid,
};

/// Primitive op codes. Wire-stable: they serialize into `'PACM'`'s
/// `'EASE'` section (`Abi.encodeMeta`) — append-only, never reorder.
pub const Op = enum(u8) {
    linear,
    hold,
    smoothstep,
    in_quad,
    out_quad,
    in_out_quad,
    in_cubic,
    out_cubic,
    in_out_cubic,
    in_quart,
    out_quart,
    in_out_quart,
    in_sine,
    out_sine,
    in_out_sine,
    in_expo,
    out_expo,
    in_out_expo,
    /// `params[0]` = step count n. Tread jumps at each tread's end.
    steps_end,
    /// `params[0]` = step count n. Tread jumps at each tread's start.
    steps_start,
    /// `params` = [x1, y1, x2, y2]. CSS semantics; input clamped to
    /// [0,1] before the solve (the curve is only defined there).
    cubic_bezier,
    /// `params` = [λ, ω] (decay rate, angular frequency), precomputed by
    /// the builder from (:damping z, :periods n): ω = 2πn, λ = zω.
    spring,
};

/// Named-easing entries, comptime-iterable (tests sweep the whole set).
/// Must stay in sync with the manifest's `ease-name` member set.
pub const named_entries = [_]struct { []const u8, Op }{
    .{ "linear", .linear },
    .{ "hold", .hold },
    .{ "smoothstep", .smoothstep },
    .{ "in-quad", .in_quad },
    .{ "out-quad", .out_quad },
    .{ "in-out-quad", .in_out_quad },
    .{ "in-cubic", .in_cubic },
    .{ "out-cubic", .out_cubic },
    .{ "in-out-cubic", .in_out_cubic },
    .{ "in-quart", .in_quart },
    .{ "out-quart", .out_quart },
    .{ "in-out-quart", .in_out_quart },
    .{ "in-sine", .in_sine },
    .{ "out-sine", .out_sine },
    .{ "in-out-sine", .in_out_sine },
    .{ "in-expo", .in_expo },
    .{ "out-expo", .out_expo },
    .{ "in-out-expo", .in_out_expo },
};

/// Named-easing lookup for the bare-symbol `:ease` sugar — `Compile`
/// resolves symbols here (`Lexer.zig`'s StaticStringMap discipline).
pub const op_names = std.StaticStringMap(Op).initComptime(named_entries);

/// One primitive invocation as authored (pre-compaction). Builder input.
pub const OpSpec = struct {
    code: Op,
    params: [4]f64 = .{ 0, 0, 0, 0 },
};

/// One `(stage :ease E :t w :v w)` as authored. Builder input.
pub const StageSpec = struct {
    t: f64,
    v: f64,
    ops: []const OpSpec,
};

/// Compiled primitive record. Params are f32 (compact, wire-carried in
/// `'PACM'`'s `'EASE'` section); evaluation widens to f64 (exact).
pub const OpRec = struct {
    code: Op,
    params: [4]f32 = .{ 0, 0, 0, 0 },
};

/// One compiled stage: cumulative normalized end time, value base/span
/// (normalized so the whole program spans [0,1]), flattened op chain.
pub const Stage = struct {
    t_end: f32,
    v_base: f32,
    v_span: f32,
    ops_len: u8,
    ops: [MAX_OPS]OpRec,
};

/// A compiled easing program. Fixed-size value type — no allocation,
/// trivially copyable into the track table. Unused stage/op slots are
/// ZEROED (not undefined) so two equal programs compare equal with
/// `std.meta.eql` — the dedup pass in the compiler relies on this.
pub const Program = struct {
    len: u8,
    stages: [MAX_STAGES]Stage,

    pub const zero_stage: Stage = .{
        .t_end = 0,
        .v_base = 0,
        .v_span = 0,
        .ops_len = 0,
        .ops = @splat(.{ .code = .linear, .params = .{ 0, 0, 0, 0 } }),
    };

    /// `e(u)`. `u` arrives in `[0, 1)` by construction (segment
    /// selection is by time); values ≥ the last boundary use the last
    /// stage, so the function is total on ℝ for safety.
    pub fn eval(self: *const Program, u: f64) f64 {
        std.debug.assert(self.len >= 1);
        std.debug.assert(self.len <= MAX_STAGES);
        var i: usize = 0;
        while (i + 1 < self.len and u >= @as(f64, self.stages[i].t_end)) : (i += 1) {}
        const st = &self.stages[i];
        const t_begin: f64 = if (i == 0) 0 else @as(f64, self.stages[i - 1].t_end);
        const denom = @as(f64, st.t_end) - t_begin;
        std.debug.assert(denom > 0); // build rejects collapsed boundaries
        var v = (u - t_begin) / denom;
        for (st.ops[0..st.ops_len]) |op| v = evalOp(op, v);
        return @as(f64, st.v_base) + @as(f64, st.v_span) * v;
    }
};

/// Compile a single named primitive (the bare-symbol `:ease` sugar).
pub fn primitive(spec: OpSpec) Error!Program {
    return chainOf(&.{spec});
}

/// Compile a `(chain E1 E2 …)`: one stage spanning [0,1] whose op list
/// is the chain in application order.
pub fn chainOf(ops: []const OpSpec) Error!Program {
    return seqOf(&.{.{ .t = 1, .v = 1, .ops = ops }});
}

/// Compile a `(seq (stage …) …)`. Normalization (fixed op order, one
/// division per weight): `t_end_i = (Σ_{j≤i} t_j) / Σt` — the last
/// boundary is `Σt/Σt = 1.0` exactly; `v_base_i = (Σ_{j<i} v_j) / Σv`,
/// `v_span_i = v_i / Σv`. `:v` may be negative (bounce pull-back); `Σv`
/// must be meaningfully non-zero or the program cannot land on the key.
pub fn seqOf(stages: []const StageSpec) Error!Program {
    if (stages.len == 0 or stages.len > MAX_STAGES) return error.EaseStagesExceeded;

    var total_t: f64 = 0;
    var total_v: f64 = 0;
    for (stages) |s| {
        if (!std.math.isFinite(s.t) or s.t <= 0) return error.EaseWeightsInvalid;
        if (!std.math.isFinite(s.v)) return error.EaseWeightsInvalid;
        total_t += s.t;
        total_v += s.v;
    }
    // Near-zero Σv: the documented deterministic cutoff. A program whose
    // value spans cancel to ~0 cannot be normalized to land on the key.
    if (@abs(total_v) < 1e-9) return error.EaseWeightsInvalid;

    var prog: Program = .{ .len = @intCast(stages.len), .stages = @splat(Program.zero_stage) };
    var cum_t: f64 = 0;
    var cum_v: f64 = 0;
    for (stages, 0..) |s, i| {
        if (s.ops.len == 0 or s.ops.len > MAX_OPS) return error.EaseOpsExceeded;
        cum_t += s.t;
        var st: Stage = .{
            .t_end = @floatCast(cum_t / total_t),
            .v_base = @floatCast(cum_v / total_v),
            .v_span = @floatCast(s.v / total_v),
            .ops_len = @intCast(s.ops.len),
            .ops = @splat(.{ .code = .linear, .params = .{ 0, 0, 0, 0 } }),
        };
        cum_v += s.v;
        for (s.ops, 0..) |op, j| st.ops[j] = try compactOp(op);
        prog.stages[i] = st;

        // f32 rounding must not collapse a stage to zero width — that
        // would divide by zero at eval. Extreme weight ratios trip here.
        const prev: f32 = if (i == 0) 0 else prog.stages[i - 1].t_end;
        if (!(st.t_end > prev)) return error.EaseWeightsInvalid;
    }
    std.debug.assert(prog.stages[prog.len - 1].t_end == 1.0);
    std.debug.assert(prog.len >= 1);
    return prog;
}

/// Validate + compact one authored op. Parameter domains beyond what the
/// manifest can express are enforced here (with the compiler attaching
/// spans): bezier x-coordinates in [0,1], spring damping strictly > 0.
fn compactOp(spec: OpSpec) Error!OpRec {
    switch (spec.code) {
        .steps_end, .steps_start => {
            const n = spec.params[0];
            if (!(n >= 1 and n <= 64) or @floor(n) != n) return error.EaseParamsInvalid;
            return .{ .code = spec.code, .params = .{ @floatCast(n), 0, 0, 0 } };
        },
        .cubic_bezier => {
            const x1 = spec.params[0];
            const y1 = spec.params[1];
            const x2 = spec.params[2];
            const y2 = spec.params[3];
            if (!(x1 >= 0 and x1 <= 1) or !(x2 >= 0 and x2 <= 1)) return error.EaseParamsInvalid;
            if (!std.math.isFinite(y1) or !std.math.isFinite(y2)) return error.EaseParamsInvalid;
            return .{ .code = spec.code, .params = .{
                @floatCast(x1), @floatCast(y1), @floatCast(x2), @floatCast(y2),
            } };
        },
        .spring => {
            const z = spec.params[0]; // damping ratio
            const n = spec.params[1]; // periods
            if (!(z > 0 and z <= 1)) return error.EaseParamsInvalid;
            if (!(n >= 0.5 and n <= 16)) return error.EaseParamsInvalid;
            const omega = 2.0 * std.math.pi * n;
            const lambda = z * omega;
            return .{ .code = spec.code, .params = .{
                @floatCast(lambda), @floatCast(omega), 0, 0,
            } };
        },
        else => return .{ .code = spec.code },
    }
}

/// One primitive applied to one value. Total on ℝ — chained ops feed it
/// overshoot values outside [0,1] and it must never NaN on them (the
/// bezier clamps; everything else is polynomial/trig-total).
fn evalOp(op: OpRec, x: f64) f64 {
    const p1 = 1.0 - x;
    return switch (op.code) {
        .linear => x,
        .hold => if (x >= 1) 1 else 0,
        .smoothstep => x * x * (3.0 - 2.0 * x),
        .in_quad => x * x,
        .out_quad => 1.0 - p1 * p1,
        .in_out_quad => if (x < 0.5)
            2.0 * x * x
        else
            1.0 - (2.0 * p1) * (2.0 * p1) / 2.0,
        .in_cubic => x * x * x,
        .out_cubic => 1.0 - p1 * p1 * p1,
        .in_out_cubic => if (x < 0.5)
            4.0 * x * x * x
        else
            1.0 - (2.0 * p1) * (2.0 * p1) * (2.0 * p1) / 2.0,
        .in_quart => x * x * x * x,
        .out_quart => 1.0 - p1 * p1 * p1 * p1,
        .in_out_quart => if (x < 0.5)
            8.0 * x * x * x * x
        else
            1.0 - (2.0 * p1) * (2.0 * p1) * (2.0 * p1) * (2.0 * p1) / 2.0,
        .in_sine => 1.0 - trig.cos64(x * (std.math.pi / 2.0)),
        .out_sine => trig.sin64(x * (std.math.pi / 2.0)),
        .in_out_sine => -(trig.cos64(std.math.pi * x) - 1.0) / 2.0,
        .in_expo => if (x == 0) 0 else trig.pow64(2.0, 10.0 * x - 10.0),
        .out_expo => if (x == 1) 1 else 1.0 - trig.pow64(2.0, -10.0 * x),
        .in_out_expo => if (x == 0)
            0
        else if (x == 1)
            1
        else if (x < 0.5)
            trig.pow64(2.0, 20.0 * x - 10.0) / 2.0
        else
            (2.0 - trig.pow64(2.0, -20.0 * x + 10.0)) / 2.0,
        .steps_end => blk: {
            const n = @as(f64, op.params[0]);
            break :blk @floor(x * n) / n;
        },
        .steps_start => blk: {
            const n = @as(f64, op.params[0]);
            break :blk @ceil(x * n) / n;
        },
        .cubic_bezier => blk: {
            const u = std.math.clamp(x, 0.0, 1.0);
            const t = solveBezierT(u, op.params[0], op.params[2]);
            break :blk bezierAxis(t, op.params[1], op.params[3]);
        },
        .spring => blk: {
            // 1 - e^(-λx)·cos(ωx): e(0) = 1 - 1·1 = 0 exactly; at x = 1
            // the residual e^(-λ)·cos(ω) is sub-percent for in-range
            // (z, n) and never leaks past the segment (structural
            // landing — see module header).
            const lambda = @as(f64, op.params[0]);
            const omega = @as(f64, op.params[1]);
            break :blk 1.0 - trig.exp64(-lambda * x) * trig.cos64(omega * x);
        },
    };
}

/// Bernstein/Horner evaluation of one bezier axis with implicit
/// endpoints 0 and 1 (the WebKit UnitBezier formulation; fixed op order).
fn bezierAxis(t: f64, c1: f32, c2: f32) f64 {
    const p1 = @as(f64, c1);
    const p2 = @as(f64, c2);
    const c = 3.0 * p1;
    const b = 3.0 * (p2 - p1) - c;
    const a = 1.0 - c - b;
    return ((a * t + b) * t + c) * t;
}

/// Solve `x(t) = u` for `t` by fixed-count bisection — 32 iterations, no
/// epsilon early-exit, so every host runs the identical instruction
/// sequence and lands on identical bits. `x(t)` is monotone on [0,1]
/// because x1, x2 ∈ [0,1] (validated at build).
fn solveBezierT(u: f64, x1: f32, x2: f32) f64 {
    std.debug.assert(u >= 0 and u <= 1);
    var lo: f64 = 0;
    var hi: f64 = 1;
    var i: u8 = 0;
    while (i < 32) : (i += 1) {
        const mid = (lo + hi) * 0.5;
        if (bezierAxis(mid, x1, x2) < u) lo = mid else hi = mid;
    }
    const t = (lo + hi) * 0.5;
    std.debug.assert(t >= 0 and t <= 1);
    return t;
}

const t_ = std.testing;

fn evalNamed(name: []const u8, u: f64) !f64 {
    const prog = try primitive(.{ .code = op_names.get(name).? });
    return prog.eval(u);
}

test "every named primitive satisfies e(0)=0" {
    for (named_entries) |entry| {
        try t_.expectEqual(@as(f64, 0), try evalNamed(entry[0], 0));
    }
}

test "named primitives reach 1 at the segment end" {
    // e(1) is never evaluated on the hot path (segment switching), but
    // the limit must still be 1 for every primitive.
    for (named_entries) |entry| {
        try t_.expectApproxEqAbs(@as(f64, 1), try evalNamed(entry[0], 1), 1e-12);
    }
}

test "primitive spot values" {
    try t_.expectEqual(@as(f64, 0.5), try evalNamed("linear", 0.5));
    try t_.expectEqual(@as(f64, 0.5), try evalNamed("smoothstep", 0.5));
    try t_.expectEqual(@as(f64, 0.25), try evalNamed("in-quad", 0.5));
    try t_.expectEqual(@as(f64, 0.875), try evalNamed("out-cubic", 0.5));
    try t_.expectEqual(@as(f64, 0), try evalNamed("hold", 0.999));
    try t_.expectEqual(@as(f64, 1), try evalNamed("hold", 1));
}

test "steps quantize with end/start jump semantics" {
    const end4 = try primitive(.{ .code = .steps_end, .params = .{ 4, 0, 0, 0 } });
    try t_.expectEqual(@as(f64, 0), end4.eval(0.1));
    try t_.expectEqual(@as(f64, 0.25), end4.eval(0.3));
    try t_.expectEqual(@as(f64, 0.75), end4.eval(0.9));

    const start4 = try primitive(.{ .code = .steps_start, .params = .{ 4, 0, 0, 0 } });
    try t_.expectEqual(@as(f64, 0), start4.eval(0));
    try t_.expectEqual(@as(f64, 0.25), start4.eval(0.1));
    try t_.expectEqual(@as(f64, 1), start4.eval(0.9));
}

test "cubic-bezier with symmetric control points approximates identity" {
    const prog = try primitive(.{ .code = .cubic_bezier, .params = .{ 0.25, 0.25, 0.75, 0.75 } });
    try t_.expectApproxEqAbs(@as(f64, 0.5), prog.eval(0.5), 1e-9);
    try t_.expectApproxEqAbs(@as(f64, 0.25), prog.eval(0.25), 1e-9);
    // Determinism: the same input gives the same bits, twice.
    try t_.expectEqual(prog.eval(0.37), prog.eval(0.37));
}

test "spring starts at exactly 0, overshoots, and settles near 1" {
    const prog = try primitive(.{ .code = .spring, .params = .{ 0.5, 3, 0, 0 } });
    try t_.expectEqual(@as(f64, 0), prog.eval(0));
    // First crest overshoots past 1 (that's the point of springs).
    var overshot = false;
    var u: f64 = 0;
    while (u < 1) : (u += 0.01) {
        if (prog.eval(u) > 1.0) overshot = true;
    }
    try t_.expect(overshot);
    try t_.expectApproxEqAbs(@as(f64, 1), prog.eval(0.999), 0.01);
}

test "seq normalizes weights and lands stage boundaries exactly" {
    // Overshoot-and-settle: out past 1.15, pull back, settle on 1.
    const prog = try seqOf(&.{
        .{ .t = 0.4, .v = 1.15, .ops = &.{.{ .code = .out_cubic }} },
        .{ .t = 0.35, .v = -0.18, .ops = &.{.{ .code = .in_out_quad }} },
        .{ .t = 0.25, .v = 0.03, .ops = &.{.{ .code = .out_quad }} },
    });
    try t_.expectEqual(@as(u8, 3), prog.len);
    try t_.expectEqual(@as(f32, 1.0), prog.stages[2].t_end);
    // Stage 0 ends at value 1.15 (cumulative v_base of stage 1).
    try t_.expectApproxEqAbs(@as(f64, 1.15), @as(f64, prog.stages[1].v_base), 1e-6);
    // Midway through stage 0: 0 + 1.15·out_cubic(0.5).
    try t_.expectApproxEqAbs(@as(f64, 1.15 * 0.875), prog.eval(0.2), 1e-6);
    // The whole program overshoots within stage 0's tail.
    try t_.expect(prog.eval(0.39) > 1.0);
}

test "two equal linear stages compose to the identity" {
    const prog = try seqOf(&.{
        .{ .t = 1, .v = 1, .ops = &.{.{ .code = .linear }} },
        .{ .t = 1, .v = 1, .ops = &.{.{ .code = .linear }} },
    });
    try t_.expectApproxEqAbs(@as(f64, 0.25), prog.eval(0.25), 1e-7);
    try t_.expectApproxEqAbs(@as(f64, 0.75), prog.eval(0.75), 1e-7);
}

test "chain composes left to right" {
    // (chain linear steps_end(2)): quantize the ramp into halves.
    const prog = try chainOf(&.{
        .{ .code = .linear },
        .{ .code = .steps_end, .params = .{ 2, 0, 0, 0 } },
    });
    try t_.expectEqual(@as(f64, 0), prog.eval(0.4));
    try t_.expectEqual(@as(f64, 0.5), prog.eval(0.6));
}

test "caps and weight defects are build errors" {
    const lin: OpSpec = .{ .code = .linear };
    // 9 stages.
    var many: [9]StageSpec = undefined;
    for (&many) |*s| s.* = .{ .t = 1, .v = 1, .ops = &.{lin} };
    try t_.expectError(error.EaseStagesExceeded, seqOf(&many));
    // 5 chained ops.
    try t_.expectError(error.EaseOpsExceeded, chainOf(&.{ lin, lin, lin, lin, lin }));
    // Zero time weight.
    try t_.expectError(error.EaseWeightsInvalid, seqOf(&.{.{ .t = 0, .v = 1, .ops = &.{lin} }}));
    // Value spans cancelling to zero.
    try t_.expectError(error.EaseWeightsInvalid, seqOf(&.{
        .{ .t = 1, .v = 1, .ops = &.{lin} },
        .{ .t = 1, .v = -1, .ops = &.{lin} },
    }));
    // Collapsed f32 boundary from extreme weight skew.
    try t_.expectError(error.EaseWeightsInvalid, seqOf(&.{
        .{ .t = 1e30, .v = 1, .ops = &.{lin} },
        .{ .t = 1e-30, .v = 1, .ops = &.{lin} },
    }));
}

test "param domains are build errors" {
    try t_.expectError(error.EaseParamsInvalid, primitive(.{ .code = .cubic_bezier, .params = .{ -0.1, 0, 0.5, 1 } }));
    try t_.expectError(error.EaseParamsInvalid, primitive(.{ .code = .spring, .params = .{ 0, 3, 0, 0 } }));
    try t_.expectError(error.EaseParamsInvalid, primitive(.{ .code = .steps_end, .params = .{ 0.5, 0, 0, 0 } }));
}

test "op_names covers exactly the manifest's named set" {
    // 18 named primitives; parameterized ops are forms, not names.
    try t_.expectEqual(@as(usize, 18), named_entries.len);
    try t_.expect(op_names.get("out-cubic") != null);
    try t_.expect(op_names.get("cubic-bezier") == null);
}
