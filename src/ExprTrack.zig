//! Expr-track evaluation — the single definition of "evaluate a track's
//! `:expr` node at a tick", shared by `Compile` (the load-time dry-run
//! at t = 0) and `Eval` (the frame path). One code path means the two
//! cannot drift: whatever the dry-run accepted, the frame evaluates
//! identically. `evalAtBinary` is the binary twin of `evalAt`: the same
//! env, the same result contract, `Expr.evalBinary` over a
//! decode-validated compact single-root payload in place of the tree
//! walk — the runtime's leaf (02), bit-equal to the tree arm by test pin.
//!
//! ## Time environment
//!
//! Every evaluation binds the same environment, derived ONLY from the
//! post-wrap tick and the transport — never from the raw host clock —
//! so loop/hold end-behavior applies to expressions exactly as it does
//! to keyframes:
//!
//! | name    | value                                                |
//! |---------|------------------------------------------------------|
//! | `t`     | seconds, `secondsFromTick(tick)` (one f64 division)  |
//! | `tick`  | the i64 grid tick itself (exact integer)             |
//! | `beat`  | continuous beat position                             |
//! | `bar`   | continuous bar position                              |
//! | `cycle` | alias of `bar` (the `Pattern` vocabulary)            |
//! | `phase` | position within the current bar, `[0, 1)`            |
//! | `bpm`   | active tempo segment's bpm at the tick (a step       |
//! |         | function; constant scores: the transport's `:bpm`)   |
//! | `dur`   | score length in BEATS — bound only when the          |
//! |         | transport declares `:dur` (referencing it in an      |
//! |         | unbounded score is an `UnknownBinding` dry-run catch) |
//!
//! Inside a `(scene …)` track two more names bind, derived from the owning
//! scene passed to `evalAt` — `scene-beat` (beats since the window opened)
//! and `scene-phase` (0..1 through it). They are absent for a top-level
//! track, so referencing one there is an `UnknownBinding` dry-run catch,
//! exactly like `dur` in an unbounded score. `Eval`'s window gate only ever
//! evaluates a scened track for a tick in `[start, start+dur)`, so
//! scene-beat ≥ 0 and scene-phase ∈ [0,1); the compile dry-run evaluates at
//! the scene start (both 0). A non-positive window is degenerate — never
//! active — and reports phase 0 rather than dividing.
//!
//! Every `(control …)` id is bound too, in a parent scope below the
//! time names (compile rejects collisions with `reserved_names`; the
//! scope order makes time win even if one slipped through). The caller
//! supplies the values: document `:value`s at the compile dry-run,
//! live-overridden effective values on the frame path — so
//! `(* radius-knob (sin beat))` follows a held widget.
//!
//! ## Result contract
//!
//! The expression must yield a number (`ncomp == 1`) or a numeric
//! vector of exactly `ncomp` elements, all finite — anything else is
//! `error.ResultShape`. Non-finite f64 components are rejected because
//! NaN payload bits are not portable across native/wasm and the
//! determinism claim is byte-level; the f64→f32 truncation itself is
//! IEEE-pinned and stays.
//!
//! Determinism: `Expr`'s closed vocabulary is parity-tested in SJON
//! (vendored trig/exp/pow kernels, SplitMix64 rand) and the env above
//! is a pure function of (transport, tick) — same table + same tick →
//! identical result, native and wasm32.

const std = @import("std");
const sjon = @import("sjon");
const TrackTable = @import("TrackTable.zig");
const TimeMap = @import("TimeMap.zig");

const Ast = sjon.Ast;
const Expr = sjon.Expr;

pub const Tick = TrackTable.Tick;

/// Frame-path scratch budget for ONE evaluation. `Eval` fronts every
/// frame-path call with a `FixedBufferAllocator` this large (reset per
/// track), so the hot path never touches the gpa; `Compile`'s dry-run
/// uses the plain gpa. Exhaustion is a deterministic outcome — the same
/// expression at the same tick exhausts on every host — never a
/// process-level OOM.
pub const SCRATCH_BYTES: usize = 256 * 1024;

/// `ResultShape` = the expression evaluated but its value violates the
/// result contract above; everything else is `Expr`'s own deterministic
/// outcome set (`UnknownBinding`, `DivisionByZero`, `DepthExceeded`,
/// `MemoryBudgetExceeded`, …) plus `OutOfMemory` from the allocator.
pub const Error = Expr.Error || error{ResultShape};

/// t, tick, beat, bar, cycle, phase, bpm, dur, scene-beat, scene-phase —
/// the last two bound only inside a scene, dur only when `:dur` is set.
const MAX_BINDINGS = 10;

/// Base time names always in reach (7 of them: everything but `dur`,
/// which is conditional).
const BASE_BINDINGS = 7;

/// The names `bindTime` owns. `Compile` rejects control ids that
/// collide with these (`control_invalid`), keeping every expression's
/// meaning independent of scope-resolution order.
pub const reserved_names = [_][]const u8{ "t", "tick", "beat", "bar", "cycle", "phase", "bpm", "dur", "scene-beat", "scene-phase" };

comptime {
    // The three encodings of `bindTime`'s output are hand-synchronized;
    // tie them so adding a binding without growing the caps is a build
    // break, not a Debug-only bounds trip inside `bindTime`.
    std.debug.assert(reserved_names.len == MAX_BINDINGS);
    std.debug.assert(BASE_BINDINGS < MAX_BINDINGS);
    // Every `EmitName` is a reserved time name — appending a future
    // variant without reserving its name is a build break, not a prose
    // promise (`emitValue`'s totality rests on this).
    for (@typeInfo(TrackTable.EmitName).@"enum".fields) |f| {
        var found = false;
        for (reserved_names) |rn| found = found or std.mem.eql(u8, rn, f.name);
        std.debug.assert(found);
    }
}

/// One control's binding for an evaluation: the document `:value` at
/// the compile dry-run, the live-overridden effective value on the
/// frame path. Values are f32 (the boundary quantum — `drv_setControl`
/// takes f32) promoted exactly to f64 at binding time.
pub const ControlBinding = struct {
    name: []const u8,
    value: [4]f32,
    ncomp: u8,

    /// Project a table control into its evaluation binding (name + value +
    /// arity). The single home for this map — `Compile`'s dry-run and
    /// `Eval`'s per-frame refresh both build bindings from controls.
    pub fn fromControl(ctl: TrackTable.Control) ControlBinding {
        return .{ .name = ctl.id, .value = ctl.value, .ncomp = ctl.ncomp };
    }
};

/// Backing storage for one evaluation env. The built `Expr.Env` holds
/// slices and a parent pointer into these arrays, so the caller owns the
/// storage and must keep it in place (not moved, not reused) for as long
/// as the env is read — a stack local spanning the evaluation call.
pub const EnvStorage = struct {
    ctl_vals: [TrackTable.MAX_CONTROLS][4]Expr.Value,
    ctl_buf: [TrackTable.MAX_CONTROLS]Expr.Env.Binding,
    time_buf: [MAX_BINDINGS]Expr.Env.Binding,
    ctl_env: Expr.Env,
    env: Expr.Env,
};

/// Build the evaluation env for `tick` in `storage` and return it. The
/// single definition of pacer's expression scope — `:expr` tracks and
/// `:pattern` hap value exprs (via SJON's `queryTreeWithEnv`, where the
/// pattern-locals `cycle`/`tick`/`seed` shadow it) read the same names.
/// Controls bind in a parent scope; the time env is the child, so time
/// names win structurally (and compile rejects collisions).
pub fn buildEnv(
    storage: *EnvStorage,
    transport: *const TrackTable.Transport,
    controls: []const ControlBinding,
    tick: Tick,
    scene: ?TrackTable.Scene,
) *const Expr.Env {
    std.debug.assert(controls.len <= TrackTable.MAX_CONTROLS);
    for (controls, 0..) |c, i| {
        storage.ctl_buf[i] = .{ .name = c.name, .value = bindControl(c, &storage.ctl_vals[i]) };
    }
    storage.ctl_env = .{ .bindings = storage.ctl_buf[0..controls.len] };
    storage.env = .{ .parent = &storage.ctl_env, .bindings = bindTime(transport, tick, scene, &storage.time_buf) };
    return &storage.env;
}

/// Evaluate an expr node at a tick. `tree` must be the tree `node`
/// belongs to and `schema` the aggregate it validated under — both live
/// on the `Compile.CompileResult`, which outlives every caller. Cost:
/// O(expression), bounded by `Expr`'s frame/step ceilings and by `gpa`
/// itself (the frame path passes a fixed-buffer allocator).
pub fn evalAt(
    gpa: std.mem.Allocator,
    tree: *const Ast.Tree,
    schema: sjon.Schema.Schema,
    transport: *const TrackTable.Transport,
    controls: []const ControlBinding,
    node: Ast.NodeIndex,
    tick: Tick,
    scene: ?TrackTable.Scene,
    ncomp: u8,
) Error![4]f32 {
    std.debug.assert(ncomp >= 1 and ncomp <= 4);
    var storage: EnvStorage = undefined;
    const env = buildEnv(&storage, transport, controls, tick, scene);
    var result = try Expr.eval(gpa, tree, node, env, schema);
    defer result.deinit();
    return coerce(result.value, ncomp) orelse error.ResultShape;
}

/// Evaluate a compact single-root binary-IR payload at a tick — the
/// binary twin of `evalAt` (02:71-74): the SAME `buildEnv` environment,
/// `Expr.evalBinary` over `payload` in place of the tree walk, then the
/// SAME `coerce`, so the two arms cannot drift. The payload is a
/// decode-validated single-root compact subtree (01's structural walk is
/// the preceding proof; the pack head walk keeps it core-only), and
/// `schema` is the same aggregate the tree arm validates under. The
/// callee stays total over everything downstream of that validation:
/// `Expr.BinaryError`'s cursor classes and `MultipleRoots` cannot reach
/// it through a decode-validated payload, but on any input they
/// propagate rather than trap. `Expr.evalBinary` deep-copies its result
/// into its own arena, so `payload` need not outlive the call; the
/// per-frame re-decode is deterministic and budgeted by the caller's
/// allocator (the frame path fronts it exactly as it fronts `evalAt`).
pub fn evalAtBinary(
    gpa: std.mem.Allocator,
    payload: []const u8,
    schema: sjon.Schema.Schema,
    transport: *const TrackTable.Transport,
    controls: []const ControlBinding,
    tick: Tick,
    scene: ?TrackTable.Scene,
    ncomp: u8,
) (Expr.BinaryError || error{ResultShape})![4]f32 {
    std.debug.assert(ncomp >= 1 and ncomp <= 4);
    var storage: EnvStorage = undefined;
    const env = buildEnv(&storage, transport, controls, tick, scene);
    var result = try Expr.evalBinary(gpa, payload, env, schema);
    defer result.deinit();
    return coerce(result.value, ncomp) orelse error.ResultShape;
}

/// A control value as an Expr value: scalar for ncomp 1, else a vector
/// of `ncomp` numbers backed by `vals` (caller-owned, must outlive the
/// evaluation). f32→f64 promotion is exact.
fn bindControl(c: ControlBinding, vals: *[4]Expr.Value) Expr.Value {
    std.debug.assert(c.ncomp >= 1 and c.ncomp <= 4);
    if (c.ncomp == 1) return .{ .number = c.value[0] };
    for (0..c.ncomp) |i| vals[i] = .{ .number = c.value[i] };
    return .{ .vector = vals[0..c.ncomp] };
}

/// Fill `buf` with the time environment (see the module header table).
/// Pure function of (transport, tick, scene); fixed binding order. `scene`
/// adds the two scene-local names when present — see `evalAt`.
fn bindTime(transport: *const TrackTable.Transport, tick: Tick, scene: ?TrackTable.Scene, buf: *[MAX_BINDINGS]Expr.Env.Binding) []const Expr.Env.Binding {
    const map = &transport.map;
    const bar = map.barOf(tick);
    var n: usize = 0;
    buf[n] = .{ .name = "t", .value = .{ .number = map.secondsFromTick(tick) } };
    n += 1;
    buf[n] = .{ .name = "tick", .value = .{ .integer_i64 = tick } };
    n += 1;
    buf[n] = .{ .name = "beat", .value = .{ .number = map.beatOf(tick) } };
    n += 1;
    buf[n] = .{ .name = "bar", .value = .{ .number = bar } };
    n += 1;
    buf[n] = .{ .name = "cycle", .value = .{ .number = bar } };
    n += 1;
    buf[n] = .{ .name = "phase", .value = .{ .number = map.phaseOf(tick) } };
    n += 1;
    buf[n] = .{ .name = "bpm", .value = .{ .number = map.bpmAt(tick) } };
    n += 1;
    if (transport.dur) |dur| {
        buf[n] = .{ .name = "dur", .value = .{ .number = map.beatOf(dur) } };
        n += 1;
    }
    if (scene) |s| {
        // Scene-local clock. `Eval`'s gate guarantees tick ∈ [start,
        // start+dur) here (the compile dry-run uses tick == start), so
        // `local` is a non-negative offset well inside the grid — plain
        // subtraction cannot overflow. A non-positive window is degenerate
        // (never active): report phase 0 instead of dividing.
        const local = tick - s.start_tick;
        buf[n] = .{ .name = "scene-beat", .value = .{ .number = map.beatOf(local) } };
        n += 1;
        const phase: f64 = if (s.dur_ticks > 0)
            @as(f64, @floatFromInt(local)) / @as(f64, @floatFromInt(s.dur_ticks))
        else
            0;
        buf[n] = .{ .name = "scene-phase", .value = .{ .number = phase } };
        n += 1;
    }
    std.debug.assert(n >= BASE_BINDINGS);
    std.debug.assert(n <= MAX_BINDINGS);
    return buf[0..n];
}

/// The f64 value of one emittable clock name at `tick` — the same
/// `TimeMap` calls `bindTime` binds, same argument, same op order, so a
/// `(transport :emit …)` lane and an equivalent `:expr` track land
/// bit-identically (`Eval` truncates this to f32 exactly as `coerce`
/// does for a scalar expr; the Eval-level twin sweep pins the equality).
/// Total by construction: the switch is exhaustive, and the comptime
/// block above pins every `EmitName` as a reserved time name — drift now
/// requires `bindTime` to abandon these methods, which that sweep catches.
pub fn emitValue(transport: *const TrackTable.Transport, tick: Tick, name: TrackTable.EmitName) f64 {
    const map = &transport.map;
    return switch (name) {
        .beat => map.beatOf(tick),
        .bar => map.barOf(tick),
        .phase => map.phaseOf(tick),
        .bpm => map.bpmAt(tick),
        .t => map.secondsFromTick(tick),
    };
}

/// Apply the result contract: number / ncomp-vector, all components
/// finite f64 before the IEEE-pinned f64→f32 truncation. Lanes ≥ ncomp
/// are zero (the `TrackTable.Key.value` invariant, kept here too).
fn coerce(value: Expr.Value, ncomp: u8) ?[4]f32 {
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    switch (value) {
        .vector => |elems| {
            if (elems.len != ncomp) return null;
            for (elems, 0..) |e, i| {
                out[i] = finite32(e.toF64() orelse return null) orelse return null;
            }
        },
        else => {
            if (ncomp != 1) return null;
            out[0] = finite32(value.toF64() orelse return null) orelse return null;
        },
    }
    return out;
}

fn finite32(x: f64) ?f32 {
    if (!std.math.isFinite(x)) return null;
    return @floatCast(x);
}

// ---------------------------------------------------------------------------
// Tests. Trees come from `sjon.validateDocument` over top-level expr
// forms — the host may fail to evaluate them itself (unknown bindings
// at the top level are not our concern); only the tree and the node
// indices are used. The schema is core-only, mirroring what `Compile`
// prepends (`CompileResult.eval_schema`) — `HostResult.schema` is
// user-only and would NOT resolve `sin`/`pow`/`+`. Score-level
// coverage lives in `Compile`/`Eval` tests.
// ---------------------------------------------------------------------------

const t_ = std.testing;

const core_plugins = [_]sjon.Plugin.Plugin{sjon.plugins.core.plugin};
const core_schema: sjon.Schema.Schema = .{ .plugins = &core_plugins };

const TestDoc = struct {
    result: sjon.Host.HostResult,

    fn init(source: [:0]const u8) !TestDoc {
        return .{ .result = try sjon.validateDocument(t_.allocator, source, .{}) };
    }
    fn deinit(self: *TestDoc) void {
        self.result.deinit();
    }
    fn node(self: *const TestDoc, i: usize) Ast.NodeIndex {
        return self.result.data_forest[i];
    }
};

const test_transport: TrackTable.Transport = .{
    .map = TimeMap.init(120, 4),
    .dur = null,
    .end = .hold,
};

test "evalAt: constant scalar golden" {
    var doc = try TestDoc.init("(+ 1 2)");
    defer doc.deinit();
    const v = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), 0, null, 1);
    try t_.expectEqual([4]f32{ 3, 0, 0, 0 }, v);
}

test "evalAt: time bindings golden at 6.5 beats (all dyadic-exact)" {
    var doc = try TestDoc.init(
        \\(+ beat 0) (+ bar 0) (+ cycle 0) (+ phase 0) (+ t 0) (+ bpm 0) (+ tick 0)
    );
    defer doc.deinit();
    const tree = &doc.result.tree;
    const schema = core_schema;
    // 6.5 beats at 120 bpm 4/4: 1171170 ticks; every projection is dyadic.
    const tick: Tick = 6 * 180180 + 90090;
    const expect = [_]f32{ 6.5, 1.625, 1.625, 0.625, 3.25, 120, 1171170 };
    for (expect, 0..) |want, i| {
        const v = try evalAt(t_.allocator, tree, schema, &test_transport, &.{}, doc.node(i), tick, null, 1);
        try t_.expectEqual(want, v[0]);
    }
}

test "evalAt: phase stays in [0,1) at negative ticks" {
    var doc = try TestDoc.init("(+ phase 0)");
    defer doc.deinit();
    const tick: Tick = -@divExact(sjon.Pattern.PPC, 4);
    const v = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), tick, null, 1);
    try t_.expectEqual(@as(f32, 0.75), v[0]);
}

test "evalAt: dur is bound only when the transport declares :dur" {
    var doc = try TestDoc.init("(+ dur 0)");
    defer doc.deinit();
    try t_.expectError(
        error.UnknownBinding,
        evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), 0, null, 1),
    );
    var bounded = test_transport;
    bounded.dur = 4 * sjon.Pattern.PPC; // 4 bars = 16 beats
    const v = try evalAt(t_.allocator, &doc.result.tree, core_schema, &bounded, &.{}, doc.node(0), 0, null, 1);
    try t_.expectEqual(@as(f32, 16), v[0]);
}

test "evalAt: scene-beat / scene-phase bind only when a scene is supplied" {
    var doc = try TestDoc.init("(+ scene-beat 0) (+ scene-phase 0)");
    defer doc.deinit();
    const tree = &doc.result.tree;
    // Absent scene → both names are unbound (the top-level rejection).
    try t_.expectError(
        error.UnknownBinding,
        evalAt(t_.allocator, tree, core_schema, &test_transport, &.{}, doc.node(0), 0, null, 1),
    );
    // Window [4b, 12b): dur 8 beats. Evaluate at absolute 6b → local 2b.
    const scene: TrackTable.Scene = .{ .name_span = .{ .start = 0, .end = 0 }, .start_tick = 4 * 180180, .dur_ticks = 8 * 180180 };
    const tick: Tick = 6 * 180180;
    const beat = try evalAt(t_.allocator, tree, core_schema, &test_transport, &.{}, doc.node(0), tick, scene, 1);
    try t_.expectEqual(@as(f32, 2), beat[0]); // 2 beats since the window opened
    const phase = try evalAt(t_.allocator, tree, core_schema, &test_transport, &.{}, doc.node(1), tick, scene, 1);
    try t_.expectEqual(@as(f32, 0.25), phase[0]); // 2/8 through the window
}

test "evalAt: a degenerate (non-positive dur) scene reports phase 0, never divides" {
    var doc = try TestDoc.init("(+ scene-phase 0)");
    defer doc.deinit();
    const scene: TrackTable.Scene = .{ .name_span = .{ .start = 0, .end = 0 }, .start_tick = 0, .dur_ticks = 0 };
    const v = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), 0, scene, 1);
    try t_.expectEqual(@as(f32, 0), v[0]);
}

test "evalAt: result-shape rejections — boolean, arity, non-finite" {
    var doc = try TestDoc.init("(> 1 0) (+ 1 2) (pow 10 400)");
    defer doc.deinit();
    const tree = &doc.result.tree;
    const schema = core_schema;
    // Boolean result.
    try t_.expectError(error.ResultShape, evalAt(t_.allocator, tree, schema, &test_transport, &.{}, doc.node(0), 0, null, 1));
    // Scalar where a vec3 target expects 3 components.
    try t_.expectError(error.ResultShape, evalAt(t_.allocator, tree, schema, &test_transport, &.{}, doc.node(1), 0, null, 3));
    // Overflow to +inf: evaluates fine, rejected by the finiteness gate.
    try t_.expectError(error.ResultShape, evalAt(t_.allocator, tree, schema, &test_transport, &.{}, doc.node(2), 0, null, 1));
}

test "evalAt: expr failures pass through (division by zero at beat 0)" {
    var doc = try TestDoc.init("(/ 1 beat)");
    defer doc.deinit();
    try t_.expectError(
        error.DivisionByZero,
        evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), 0, null, 1),
    );
}

test "evalAt: control bindings — scalar, vector, mixed with time" {
    // `pick` alone: a bare symbol expression resolves to the vector
    // binding (arithmetic stays scalar; vectors pass through whole).
    var doc = try TestDoc.init("(* knob 2) pick (* knob beat)");
    defer doc.deinit();
    const tree = &doc.result.tree;
    const controls = [_]ControlBinding{
        .{ .name = "knob", .value = .{ 0.25, 0, 0, 0 }, .ncomp = 1 },
        .{ .name = "pick", .value = .{ 1, 0.5, 0, 0 }, .ncomp = 3 },
    };

    const scalar = try evalAt(t_.allocator, tree, core_schema, &test_transport, &controls, doc.node(0), 0, null, 1);
    try t_.expectEqual(@as(f32, 0.5), scalar[0]);

    const vec = try evalAt(t_.allocator, tree, core_schema, &test_transport, &controls, doc.node(1), 0, null, 3);
    try t_.expectEqual([4]f32{ 1, 0.5, 0, 0 }, vec);

    // Controls and time names coexist: knob · beat at 2 beats.
    const tick: Tick = 2 * 180180;
    const mixed = try evalAt(t_.allocator, tree, core_schema, &test_transport, &controls, doc.node(2), tick, null, 1);
    try t_.expectEqual(@as(f32, 0.5), mixed[0]);
}

test "evalAt: bpm binds the active segment's tempo under a tempo map" {
    var doc = try TestDoc.init("(+ bpm 0)");
    defer doc.deinit();
    var buf: [2]TimeMap.Segment = .{
        .{ .start_tick = 0, .bpm = 120, .start_sec = undefined, .tps = undefined },
        .{ .start_tick = 720720, .bpm = 240, .start_sec = undefined, .tps = undefined },
    };
    var mapped = test_transport;
    mapped.map = TimeMap.init(120, 4).withSegments(&buf);
    // A step function of the (wrapped) tick: still 120 one tick before
    // the boundary, 240 exactly at it.
    const before = try evalAt(t_.allocator, &doc.result.tree, core_schema, &mapped, &.{}, doc.node(0), 720719, null, 1);
    try t_.expectEqual(@as(f32, 120), before[0]);
    const after = try evalAt(t_.allocator, &doc.result.tree, core_schema, &mapped, &.{}, doc.node(0), 720720, null, 1);
    try t_.expectEqual(@as(f32, 240), after[0]);
}

test "evalAt: an unbound control name is still UnknownBinding" {
    var doc = try TestDoc.init("(* missing-knob 2)");
    defer doc.deinit();
    try t_.expectError(
        error.UnknownBinding,
        evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), 0, null, 1),
    );
}

// ---------------------------------------------------------------------------
// Binary-leaf tests (02 T1.1). Every payload comes from the frozen
// producer's exact spell — `TreeBuilder.cloneNode` into a fresh one-root
// tree, then `Binary.toBinary(.forMode(.compact))` (what
// `PacbEncode.encodePayload` encodes, A29) — never hand-mocked bytes. The
// write-side SJON this needs is test-only, so it keeps an INDENTED import
// per the closure split (02:200-202). It is spelled `sjon_w`, not `sjon`,
// only because the file-scope production `sjon` still exists here and Zig
// forbids a local shadowing it — T2.1's RtSjon reroute renames the
// production import and this alias becomes plain `sjon`. The tree arm's
// `evalAt` on the SAME env is the equivalence oracle throughout.
// ---------------------------------------------------------------------------

/// Compact single-root payload for one validated expr node of `doc`,
/// built exactly as the pack path builds it: clone the subtree, finalize
/// the one-root tree against "" (compact drops spans; strings re-intern),
/// encode compact. Caller owns the returned bytes.
fn compactPayload(a: std.mem.Allocator, doc: *const TestDoc, node: usize) ![]u8 {
    const sjon_w = @import("sjon");
    var tree_arena = std.heap.ArenaAllocator.init(a);
    defer tree_arena.deinit(); // no-op once finalize snapshots the arena
    var builder = sjon_w.Ast.TreeBuilder{ .a = tree_arena.allocator() };
    const root = try builder.cloneNode(&doc.result.tree, doc.node(node));
    var one_root = try builder.finalize(&tree_arena, "", &.{root});
    defer one_root.deinit();
    const bin = try sjon_w.Binary.toBinary(a, one_root, sjon_w.Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    return a.dupe(u8, bin.data);
}

test "evalAtBinary: constant scalar equivalence — bit-equal [4]f32 vs the tree arm" {
    var doc = try TestDoc.init("(+ 1 2)");
    defer doc.deinit();
    const payload = try compactPayload(t_.allocator, &doc, 0);
    defer t_.allocator.free(payload);
    const want = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), 0, null, 1);
    const got = try evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &.{}, 0, null, 1);
    try t_.expectEqual(want, got);
    try t_.expectEqual([4]f32{ 3, 0, 0, 0 }, got);
}

test "evalAtBinary: time bindings at 6.5 beats — bit-equal to the tree arm" {
    var doc = try TestDoc.init(
        \\(+ beat 0) (+ bar 0) (+ cycle 0) (+ phase 0) (+ t 0) (+ bpm 0) (+ tick 0)
    );
    defer doc.deinit();
    // 6.5 beats at 120 bpm 4/4: 1171170 ticks; every projection dyadic.
    const tick: Tick = 6 * 180180 + 90090;
    const golden = [_]f32{ 6.5, 1.625, 1.625, 0.625, 3.25, 120, 1171170 };
    for (golden, 0..) |want, i| {
        const payload = try compactPayload(t_.allocator, &doc, i);
        defer t_.allocator.free(payload);
        const tree_v = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(i), tick, null, 1);
        const bin_v = try evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &.{}, tick, null, 1);
        try t_.expectEqual(tree_v, bin_v);
        try t_.expectEqual(want, bin_v[0]);
    }
}

test "evalAtBinary: phase stays in [0,1) at negative ticks — bit-equal both arms" {
    var doc = try TestDoc.init("(+ phase 0)");
    defer doc.deinit();
    const payload = try compactPayload(t_.allocator, &doc, 0);
    defer t_.allocator.free(payload);
    const tick: Tick = -@divExact(sjon.Pattern.PPC, 4);
    const want = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), tick, null, 1);
    const got = try evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &.{}, tick, null, 1);
    try t_.expectEqual(want, got);
    try t_.expectEqual(@as(f32, 0.75), got[0]);
}

test "evalAtBinary: control bindings — scalar, vector, mixed with time, bit-equal both arms" {
    // Mirrors the evalAt control test: `pick` alone resolves to the
    // vector binding; arithmetic stays scalar; controls mix with time.
    var doc = try TestDoc.init("(* knob 2) pick (* knob beat)");
    defer doc.deinit();
    const controls = [_]ControlBinding{
        .{ .name = "knob", .value = .{ 0.25, 0, 0, 0 }, .ncomp = 1 },
        .{ .name = "pick", .value = .{ 1, 0.5, 0, 0 }, .ncomp = 3 },
    };
    const tick: Tick = 2 * 180180;

    // Scalar control arithmetic (ncomp 1, tick 0).
    {
        const payload = try compactPayload(t_.allocator, &doc, 0);
        defer t_.allocator.free(payload);
        const want = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &controls, doc.node(0), 0, null, 1);
        const got = try evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &controls, 0, null, 1);
        try t_.expectEqual(want, got);
        try t_.expectEqual(@as(f32, 0.5), got[0]);
    }
    // Vector control passes through whole (ncomp 3).
    {
        const payload = try compactPayload(t_.allocator, &doc, 1);
        defer t_.allocator.free(payload);
        const want = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &controls, doc.node(1), 0, null, 3);
        const got = try evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &controls, 0, null, 3);
        try t_.expectEqual(want, got);
        try t_.expectEqual([4]f32{ 1, 0.5, 0, 0 }, got);
    }
    // Control · time at 2 beats.
    {
        const payload = try compactPayload(t_.allocator, &doc, 2);
        defer t_.allocator.free(payload);
        const want = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &controls, doc.node(2), tick, null, 1);
        const got = try evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &controls, tick, null, 1);
        try t_.expectEqual(want, got);
        try t_.expectEqual(@as(f32, 0.5), got[0]);
    }
}

test "evalAtBinary: scene env — start tick (the C5 dry env) and interior, bit-equal both arms" {
    var doc = try TestDoc.init("(+ scene-beat 0) (+ scene-phase 0)");
    defer doc.deinit();
    // Window [4b, 12b): dur 8 beats — same window as the evalAt scene test.
    const scene: TrackTable.Scene = .{ .name_span = .{ .start = 0, .end = 0 }, .start_tick = 4 * 180180, .dur_ticks = 8 * 180180 };
    // C5: the load dry-run's env — tick == scene.start_tick, so both
    // scene names read 0 (a scened `(sqrt scene-beat)` is sound here and
    // non-finite at flat 0 — the divergence that forced the correction).
    {
        const payload = try compactPayload(t_.allocator, &doc, 0);
        defer t_.allocator.free(payload);
        const want = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), scene.start_tick, scene, 1);
        const got = try evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &.{}, scene.start_tick, scene, 1);
        try t_.expectEqual(want, got);
        try t_.expectEqual(@as(f32, 0), got[0]);
    }
    // Interior, absolute 6b → local 2b: the scene env is NOT assumed
    // flat-0 — scene-beat 2, scene-phase 0.25 through the real binding.
    {
        const tick: Tick = 6 * 180180;
        const beat_payload = try compactPayload(t_.allocator, &doc, 0);
        defer t_.allocator.free(beat_payload);
        const want_beat = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), tick, scene, 1);
        const got_beat = try evalAtBinary(t_.allocator, beat_payload, core_schema, &test_transport, &.{}, tick, scene, 1);
        try t_.expectEqual(want_beat, got_beat);
        try t_.expectEqual(@as(f32, 2), got_beat[0]);

        const phase_payload = try compactPayload(t_.allocator, &doc, 1);
        defer t_.allocator.free(phase_payload);
        const want_phase = try evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(1), tick, scene, 1);
        const got_phase = try evalAtBinary(t_.allocator, phase_payload, core_schema, &test_transport, &.{}, tick, scene, 1);
        try t_.expectEqual(want_phase, got_phase);
        try t_.expectEqual(@as(f32, 0.25), got_phase[0]);
    }
}

test "evalAtBinary: bpm under a tempo map — bit-equal both arms at the segment boundary" {
    var doc = try TestDoc.init("(+ bpm 0)");
    defer doc.deinit();
    var buf: [2]TimeMap.Segment = .{
        .{ .start_tick = 0, .bpm = 120, .start_sec = undefined, .tps = undefined },
        .{ .start_tick = 720720, .bpm = 240, .start_sec = undefined, .tps = undefined },
    };
    var mapped = test_transport;
    mapped.map = TimeMap.init(120, 4).withSegments(&buf);
    const payload = try compactPayload(t_.allocator, &doc, 0);
    defer t_.allocator.free(payload);
    // The step function of the wrapped tick: 120 one tick before the
    // boundary, 240 exactly at it — identical on both arms.
    for ([_]struct { tick: Tick, bpm: f32 }{
        .{ .tick = 720719, .bpm = 120 },
        .{ .tick = 720720, .bpm = 240 },
    }) |case| {
        const want = try evalAt(t_.allocator, &doc.result.tree, core_schema, &mapped, &.{}, doc.node(0), case.tick, null, 1);
        const got = try evalAtBinary(t_.allocator, payload, core_schema, &mapped, &.{}, case.tick, null, 1);
        try t_.expectEqual(want, got);
        try t_.expectEqual(case.bpm, got[0]);
    }
}

test "evalAtBinary: expr failures pass through — division by zero at beat 0, both arms" {
    var doc = try TestDoc.init("(/ 1 beat)");
    defer doc.deinit();
    const payload = try compactPayload(t_.allocator, &doc, 0);
    defer t_.allocator.free(payload);
    try t_.expectError(
        error.DivisionByZero,
        evalAt(t_.allocator, &doc.result.tree, core_schema, &test_transport, &.{}, doc.node(0), 0, null, 1),
    );
    try t_.expectError(
        error.DivisionByZero,
        evalAtBinary(t_.allocator, payload, core_schema, &test_transport, &.{}, 0, null, 1),
    );
}

test "evalAtBinary: result-shape rejections match the tree arm — boolean, arity, non-finite" {
    var doc = try TestDoc.init("(> 1 0) (+ 1 2) (pow 10 400)");
    defer doc.deinit();
    const tree = &doc.result.tree;
    const schema = core_schema;
    const cases = [_]struct { node: usize, ncomp: u8 }{
        .{ .node = 0, .ncomp = 1 }, // Boolean result.
        .{ .node = 1, .ncomp = 3 }, // Scalar where a vec3 target expects 3.
        .{ .node = 2, .ncomp = 1 }, // Overflow to +inf: finiteness gate.
    };
    for (cases) |case| {
        const payload = try compactPayload(t_.allocator, &doc, case.node);
        defer t_.allocator.free(payload);
        try t_.expectError(error.ResultShape, evalAt(t_.allocator, tree, schema, &test_transport, &.{}, doc.node(case.node), 0, null, case.ncomp));
        try t_.expectError(error.ResultShape, evalAtBinary(t_.allocator, payload, schema, &test_transport, &.{}, 0, null, case.ncomp));
    }
}

test "evalAtBinary: malformed and non-single-root payloads are errors, never traps" {
    const sjon_w = @import("sjon");
    // A valid compact encoding of a zero-root document: not single-root.
    var tree = try sjon_w.parse(t_.allocator, "");
    defer tree.deinit();
    const bin = try sjon_w.Binary.toBinary(t_.allocator, tree, sjon_w.Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    try t_.expectError(
        error.MultipleRoots,
        evalAtBinary(t_.allocator, bin.data, core_schema, &test_transport, &.{}, 0, null, 1),
    );
    // Not a binary IR at all: refused at the magic check, before any read.
    const junk = [_]u8{0} ** 16;
    try t_.expectError(
        error.InvalidMagic,
        evalAtBinary(t_.allocator, &junk, core_schema, &test_transport, &.{}, 0, null, 1),
    );
}
