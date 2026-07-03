//! Per-frame evaluator — the hot path.
//!
//! `evalSeconds(t)` is one mul+floor to ticks (the `TimeMap` seam),
//! end-behavior wrap/clamp, then a bounded loop over tracks. Keyframe
//! tracks: per-track last-segment cache (the playhead is
//! near-monotonic, so the common case is O(1)), unclamped f64 lerp
//! through the easing program, truncation to f32 at emission — no
//! allocation, no AST access, no recursion. Expr tracks: the `:expr`
//! node is re-evaluated against the compile result's tree with the
//! time env bound (`ExprTrack.evalAt`), allocating only from a fixed
//! scratch zone (`ExprTrack.SCRATCH_BYTES`, reset per track) — the gpa
//! is never touched on the frame path either way.
//!
//! Boundary semantics (load-bearing for the corpus): before a track's
//! first key it holds the first value; after the last, the last
//! (transport `:end` handles loop/hold *globally* first). Exact landing
//! on key values is structural: at `t == key.at` the segment STARTING
//! there is selected, so the value is the key's own, bit-exactly —
//! easing residue (springs!) never leaks across a key.
//!
//! Expr-track runtime failure (compile dry-ran t = 0; a later tick can
//! still divide by zero, hit a budget, or yield the wrong shape): the
//! track's write is OMITTED for that frame and `expr_failures` counts
//! it. Hosts hold the last delivered value — the documented fill
//! default — and, unlike emitting a stale value from the driver,
//! omission keeps the write buffer a pure function of time: whether a
//! write exists at time t never depends on what was evaluated before.
//!
//! Controls are the one deliberate piece of API state: the buffer is a
//! pure function of (time, control state) — same table, same tick, same
//! held values ⇒ same bytes. Control writes land AFTER track writes and
//! consumers apply entries in order, so a pin outranks a track on the
//! same target. A document control always writes (its `:value` is the
//! document's authority; `setControl` replaces it until `clearControl`);
//! a dynamic slot (`registerControl`, editor lifts) writes only while
//! held. Control values also feed the expr env — a held widget steers
//! `(* knob (sin beat))` on the same frame.
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
const ExprTrack = @import("ExprTrack.zig");
const Compile = @import("Compile.zig");

pub const Tick = sjon.Pattern.Tick;

/// Time conversion failures (host clock out of range). The tick-domain
/// path is total once conversion succeeded.
pub const Error = TimeMap.Error;

/// Dynamic control slots available beyond the document's own
/// (`registerControl` — editor-lifted literals with no `(control …)`
/// in the text).
pub const MAX_DYNAMIC_CONTROLS = 64;

/// Sentinel target id of an env-only document control (writes nothing).
pub const NO_TARGET: u16 = std.math.maxInt(u16);

/// Runtime state of one control. The index space is document controls
/// first (table order), then dynamic slots in registration order.
const ControlSlot = struct {
    target_id: u16,
    registry: u8,
    ncomp: u8,
    /// Live override (`setControl`); null = idle. Document controls
    /// fall back to their `:value`; dynamic slots emit nothing.
    live: ?[4]f32,
};

/// Frame evaluator over a compiled score. The `CompileResult` is
/// borrowed whole (expr tracks need its tree + schema, not just the
/// table), must already sit in its final memory location (it is moved
/// by value; see `Compile.CompileResult`), and must outlive the
/// evaluator. Owns its arena (cache + entry buffer + expr scratch);
/// SJON deinit convention.
pub const Evaluator = struct {
    arena: std.heap.ArenaAllocator,
    table: *const TrackTable,
    tree: *const sjon.Ast.Tree,
    schema: sjon.Schema.Schema,
    /// Per-track index of the last segment hit (`keys[i] ≤ t < keys[i+1]`).
    /// Indexed by track position; expr tracks never read theirs.
    seg_cache: []u32,
    /// Reused output buffer, one entry per track.
    entries: []Writes.Entry,
    /// Fixed expr scratch (empty for keyframe-only scores) — fronts a
    /// per-track `FixedBufferAllocator` so the frame path never touches
    /// the gpa.
    scratch: []u8,
    /// Control bindings handed to every expr evaluation, one per
    /// document control (names alias the table). Values are refreshed
    /// each eval: a live override, else the document `:value`.
    ctl_bindings: []ExprTrack.ControlBinding,
    /// Control runtime state: `table.controls.len` document slots, then
    /// `MAX_DYNAMIC_CONTROLS` capacity for dynamic ones.
    slots: []ControlSlot,
    /// Live count of registered dynamic slots.
    dyn_controls: usize = 0,
    /// Lifetime count of expr-track evaluations that failed at runtime
    /// (their writes were omitted). A debugging probe, not semantics.
    expr_failures: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, result: *const Compile.CompileResult) error{OutOfMemory}!Evaluator {
        std.debug.assert(result.table != null); // compile succeeded
        const table = &result.table.?;
        std.debug.assert(table.tracks.len <= TrackTable.MAX_TRACKS);
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const seg_cache = try arena.allocator().alloc(u32, table.tracks.len);
        @memset(seg_cache, 0);
        const entries = try arena.allocator().alloc(
            Writes.Entry,
            table.tracks.len + table.controls.len + MAX_DYNAMIC_CONTROLS,
        );
        var has_expr = false;
        for (table.tracks) |tr| {
            if (tr.source == .expr) has_expr = true;
        }
        const scratch: []u8 = if (has_expr)
            try arena.allocator().alloc(u8, ExprTrack.SCRATCH_BYTES)
        else
            &.{};
        const ctl_bindings = try arena.allocator().alloc(ExprTrack.ControlBinding, table.controls.len);
        for (ctl_bindings, table.controls) |*b, ctl| {
            b.* = ExprTrack.ControlBinding.fromControl(ctl);
        }
        const slots = try arena.allocator().alloc(ControlSlot, table.controls.len + MAX_DYNAMIC_CONTROLS);
        for (slots[0..table.controls.len], table.controls) |*s, ctl| {
            s.* = .{
                .target_id = if (ctl.target) |tg| tg.id else NO_TARGET,
                .registry = if (ctl.target) |tg| tg.registry else 0,
                .ncomp = ctl.ncomp,
                .live = null,
            };
        }
        return .{
            .arena = arena,
            .table = table,
            .tree = &result.validated.result.tree,
            .schema = result.eval_schema,
            .seg_cache = seg_cache,
            .entries = entries,
            .scratch = scratch,
            .ctl_bindings = ctl_bindings,
            .slots = slots,
        };
    }

    /// Hold a live control value (a widget drag). Replaces the document
    /// authority until `clearControl`. False (no change) on a bad index
    /// or any non-finite component — control values feed expressions and
    /// the determinism claim needs canonical floats; host input, so an
    /// error result, never an assert.
    pub fn setControl(self: *Evaluator, index: usize, value: [4]f32) bool {
        if (index >= self.table.controls.len + self.dyn_controls) return false;
        for (value) |v| {
            if (!std.math.isFinite(v)) return false;
        }
        self.slots[index].live = value;
        return true;
    }

    /// Release a held control: a document control returns to its
    /// `:value`, a dynamic slot falls silent. False on a bad index.
    pub fn clearControl(self: *Evaluator, index: usize) bool {
        if (index >= self.table.controls.len + self.dyn_controls) return false;
        self.slots[index].live = null;
        return true;
    }

    /// Register a dynamic control slot for an editor-lifted literal (no
    /// `(control …)` in the text). The caller supplies the resolved
    /// join — the table dropped target names at load. Returns the slot's
    /// index in the shared control index space, or null when the slot
    /// capacity is exhausted or the join is malformed. Dynamic slots
    /// write only while held and never enter the expr env (no binding
    /// name exists for them).
    pub fn registerControl(self: *Evaluator, target_id: u16, registry: u8, ncomp: u8) ?usize {
        if (ncomp < 1 or ncomp > 4) return null;
        if (target_id == NO_TARGET) return null;
        if (self.dyn_controls == MAX_DYNAMIC_CONTROLS) return null;
        const index = self.table.controls.len + self.dyn_controls;
        self.slots[index] = .{ .target_id = target_id, .registry = registry, .ncomp = ncomp, .live = null };
        self.dyn_controls += 1;
        return index;
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

    /// Tick-domain twin (tests, corpus, `drv_evalTicks`). Total: an
    /// expr-track runtime failure omits that write (see module header),
    /// it never errors out of the frame.
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
        // Effective control values for this frame's expressions: a live
        // override wins, else the document `:value`.
        for (self.ctl_bindings, self.slots[0..self.ctl_bindings.len], table.controls) |*b, slot, ctl| {
            b.value = slot.live orelse ctl.value;
        }
        var n: usize = 0;
        for (table.tracks, 0..) |*track, i| {
            switch (track.source) {
                .keys => {
                    self.entries[n] = evalKeyTrack(table, track, t, &self.seg_cache[i]);
                    n += 1;
                },
                .expr => |node| {
                    // Reset scratch per track: each expression gets the
                    // whole fixed zone; nothing survives the call.
                    var fba = std.heap.FixedBufferAllocator.init(self.scratch);
                    const value = ExprTrack.evalAt(
                        fba.allocator(),
                        self.tree,
                        self.schema,
                        &table.transport,
                        self.ctl_bindings,
                        node,
                        t,
                        track.ncomp,
                    ) catch {
                        self.expr_failures += 1;
                        continue;
                    };
                    self.entries[n] = .{
                        .target_id = track.target_id,
                        .flags = track.registry,
                        .ncomp = track.ncomp,
                        .value = value,
                    };
                    n += 1;
                },
            }
        }
        // Control writes land AFTER track writes — consumers apply
        // entries in order, so a pin (or a held widget) outranks a
        // track on the same target. Document controls always write;
        // dynamic slots only while held.
        for (self.slots[0..table.controls.len], table.controls) |slot, ctl| {
            if (slot.target_id == NO_TARGET) continue;
            self.entries[n] = .{
                .target_id = slot.target_id,
                .flags = slot.registry,
                .ncomp = slot.ncomp,
                .value = slot.live orelse ctl.value,
            };
            n += 1;
        }
        for (self.slots[table.controls.len..][0..self.dyn_controls]) |slot| {
            const live = slot.live orelse continue;
            self.entries[n] = .{
                .target_id = slot.target_id,
                .flags = slot.registry,
                .ncomp = slot.ncomp,
                .value = live,
            };
            n += 1;
        }
        std.debug.assert(n <= self.entries.len);
        return self.entries[0..n];
    }
};

fn evalKeyTrack(table: *const TrackTable, track: *const TrackTable.Track, t: Tick, cache: *u32) Writes.Entry {
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
    try t_.expect(r.setBpm(60));
    // 1 s at 60 bpm = 1 beat → 0.25; the borrowed evaluator sees it.
    try t_.expectEqual(@as(f32, 0.25), (try ev.evalSeconds(1.0))[0].value[0]);
    // Tick-domain results are tempo-independent.
    const map = &r.table.?.transport.map;
    try t_.expectEqual(@as(f32, 0.5), ev.evalTicks(try map.tickFromBeats(2))[0].value[0]);

    try t_.expect(!r.setBpm(0));
    try t_.expect(!r.setBpm(std.math.nan(f64)));
    try t_.expectEqual(@as(f64, 60), r.table.?.transport.map.bpm);
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
