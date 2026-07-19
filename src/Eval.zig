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
//! is never touched on the frame path either way. Trigger tracks:
//! `evalTrigger` finds the last event ≤ t (periodic: one integer
//! `divFloor`; explicit: the same near-monotonic cursor cache as
//! keyframes) and writes the (phase, count, gate, beats-since) lanes,
//! each an i64 tick delta through one f64 division, truncated to the
//! target's ncomp — before the first event the write is omitted.
//! Pattern tracks: `PatternTrack.queryCycle` samples the `:pattern` node
//! over this tick's enclosing cycle (1 cycle = 1 bar, identity), fronted by
//! the same fixed scratch as exprs, and `PatternTrack.sampleAt` selects the
//! active hap (latest onset, top `stack` layer on a tie); no active hap
//! omits the write (a gap). Hap value exprs bind the pattern-locals
//! cycle/tick/seed only this slice.
//!
//! Boundary semantics (load-bearing for the corpus): before a track's
//! first key it holds the first value; after the last, the last
//! (transport `:end` handles loop/hold *globally* first). Exact landing
//! on key values is structural: at `t == key.at` the segment STARTING
//! there is selected, so the value is the key's own, bit-exactly —
//! easing residue (springs!) never leaks across a key.
//!
//! Expr / pattern runtime failure (compile dry-ran cycle 0 / t = 0; a
//! later tick can still divide by zero, hit a budget, drop a hap, or
//! yield the wrong shape): the track's write is OMITTED for that frame
//! and `expr_failures` counts it (the one shared probe — a pattern
//! `:pattern` track that omits at a later cycle bumps the same counter).
//! Hosts hold the last delivered value — the documented fill default —
//! and, unlike emitting a stale value from the driver, omission keeps the
//! write buffer a pure function of time: whether a write exists at time t
//! never depends on what was evaluated before.
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
const PatternTrack = @import("PatternTrack.zig");
const Compile = @import("Compile.zig");

/// The shared grid position type (`i64`), re-exported for call sites.
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
    /// Per-track resume cursor, indexed by track position: the last
    /// segment hit for a keyframe track (`keys[i] ≤ t < keys[i+1]`), the
    /// last event index for a trigger `:at` track (see `evalTrigger`).
    /// Expr, pattern, and periodic-trigger tracks never read theirs.
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
    /// Lifetime count of frames a track's write was OMITTED by a runtime
    /// failure: an expr that raised or yielded the wrong shape, or a
    /// pattern whose query refused, whose selected hap was uncoercible, or
    /// whose sample fell in a cycle the engine dropped a hap in. Counts
    /// omitted writes only — a frame that still produced a write never
    /// bumps it (for patterns the drop signal is cycle-coarse; see the
    /// `.pattern` arm). A debugging probe, not semantics — the determinism
    /// claim never reads it.
    expr_failures: u64 = 0,

    /// Build the evaluator over a SUCCESSFUL compile. Borrows `result`
    /// whole (table + tree + schema) — `result` must already sit in its
    /// final memory location, never be reassigned while the evaluator
    /// lives, and outlive it (see the struct doc). All allocation
    /// happens here; the frame path never touches the gpa.
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
            table.transport.emit.len + table.tracks.len + table.controls.len + MAX_DYNAMIC_CONTROLS,
        );
        // Frame scratch fronts every expr / pattern eval so the hot path
        // never touches the gpa; size it to the largest consumer present.
        // A pattern query needs materially more than an expr — SJON's own
        // per-query expr scratch alone is 256 KiB (see
        // `PatternTrack.SCRATCH_BYTES`) — so a pattern track dominates.
        var scratch_need: usize = 0;
        for (table.tracks) |tr| {
            switch (tr.source) {
                .expr => scratch_need = @max(scratch_need, ExprTrack.SCRATCH_BYTES),
                .pattern => scratch_need = @max(scratch_need, PatternTrack.SCRATCH_BYTES),
                else => {},
            }
        }
        const scratch: []u8 = if (scratch_need > 0)
            try arena.allocator().alloc(u8, scratch_need)
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

    /// Tear down BEFORE the borrowed `CompileResult` (borrow-whole rule).
    pub fn deinit(self: *Evaluator) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The host-facing entry point: master-clock seconds in, write
    /// entries out. The returned slice aliases the evaluator's buffer —
    /// consume (or encode) before the next eval.
    ///
    /// Tempo-mapped scores wrap in SECONDS before the one conversion
    /// (the it/01 seam): tick-wrapping a raw conversion would read loop
    /// iteration 2 at the final segment's tempo. The wrapped value lands
    /// in [0, dur] by construction, so `evalTicks`'s tick-domain wrap
    /// below is at most an exact boundary fold (dur ≡ 0 under loop).
    /// Constant scores keep the historical convert-then-tick-wrap path
    /// bit-for-bit (the degenerate pin).
    pub fn evalSeconds(self: *Evaluator, seconds: f64) Error![]const Writes.Entry {
        const transport = &self.table.transport;
        const map = &transport.map;
        if (map.segments.len > 1 and transport.dur != null) {
            const loop_secs = transport.loop_secs.?; // compile computed it with dur
            const wrapped = switch (transport.end) {
                .loop => TimeMap.loopSeconds(seconds, loop_secs),
                .hold => TimeMap.holdSeconds(seconds, loop_secs),
            };
            return self.evalTicks(try map.tickFromSeconds(wrapped));
        }
        const t = try map.tickFromSeconds(seconds);
        return self.evalTicks(t);
    }

    /// Tick-domain twin (tests, corpus, `drv_evalTicks`). Total: an
    /// expr-track runtime failure omits that write (see module header),
    /// it never errors out of the frame. Precondition: |t_raw| ≤
    /// `Pattern.MAX_TICK` — `tickFromSeconds` guarantees it and
    /// `drv_evalTicks` gates it; the trigger/window integer math relies
    /// on the headroom.
    pub fn evalTicks(self: *Evaluator, t_raw: Tick) []const Writes.Entry {
        std.debug.assert(t_raw <= sjon.Pattern.MAX_TICK);
        std.debug.assert(t_raw >= -sjon.Pattern.MAX_TICK);
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
        // Built-in clock lanes (`:emit …`) land FIRST — a track or control
        // on the same target, written later, overrides an emitted lane for
        // in-order consumers. Each lane is its reserved name's env value at
        // the wrapped tick, truncated to f32 exactly as a scalar `:expr`
        // track (`ExprTrack.coerce`), so the two are bit-identical.
        for (table.transport.emit) |lane| {
            const v: f32 = @floatCast(ExprTrack.emitValue(&table.transport, t, lane.name));
            self.entries[n] = .{
                .target_id = lane.target_id,
                .flags = lane.registry,
                .ncomp = 1,
                .value = .{ v, 0, 0, 0 },
            };
            n += 1;
        }
        for (table.tracks, 0..) |*track, i| {
            // Scene window gate: a scened track writes only while the
            // wrapped playhead sits inside its window [start, start+dur).
            // Outside, the write is OMITTED (like an expr-NaN) so an
            // overlapping later scene hands the target off by write order;
            // wrapping `t` first lets loop end-behavior re-enter scenes.
            // `start + dur` cannot overflow — compile raised `tick_overflow`
            // otherwise, so no such table reaches here. The scene also
            // supplies the `scene-beat`/`scene-phase` expr env.
            const scene: ?TrackTable.Scene = if (track.scene != TrackTable.NO_SCENE)
                table.scenes[track.scene]
            else
                null;
            if (scene) |s| {
                if (t < s.start_tick or t >= s.start_tick + s.dur_ticks) continue;
            }
            switch (track.source) {
                .keys => {
                    self.entries[n] = evalKeyTrack(table, track, t, &self.seg_cache[i]);
                    n += 1;
                },
                .expr => |node| {
                    if (self.evalExprTrack(track, node, t, scene)) |entry| {
                        self.entries[n] = entry;
                        n += 1;
                    }
                },
                .trigger => |*sched| {
                    // Resolve the lanes for the current event; before the
                    // first event the write is OMITTED (like an expr-NaN /
                    // an out-of-window scene), keeping the buffer a pure
                    // function of time.
                    if (evalTrigger(&table.transport.map, track, sched, t, &self.seg_cache[i])) |entry| {
                        self.entries[n] = entry;
                        n += 1;
                    }
                },
                .pattern => |node| {
                    if (self.evalPatternTrack(track, node, t, scene)) |entry| {
                        self.entries[n] = entry;
                        n += 1;
                    }
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

    /// One `.expr` track at wrapped tick `t`, or null when the write is
    /// OMITTED by a runtime failure (counted in `expr_failures`).
    fn evalExprTrack(
        self: *Evaluator,
        track: *const TrackTable.Track,
        node: sjon.Ast.NodeIndex,
        t: Tick,
        scene: ?TrackTable.Scene,
    ) ?Writes.Entry {
        std.debug.assert(track.ncomp >= 1);
        std.debug.assert(track.ncomp <= 4);
        // Reset scratch per track: each expression gets the
        // whole fixed zone; nothing survives the call.
        var fba = std.heap.FixedBufferAllocator.init(self.scratch);
        const value = ExprTrack.evalAt(
            fba.allocator(),
            self.tree,
            self.schema,
            &self.table.transport,
            self.ctl_bindings,
            node,
            t,
            scene,
            track.ncomp,
        ) catch {
            self.expr_failures += 1;
            return null;
        };
        return .{
            .target_id = track.target_id,
            .flags = track.registry,
            .ncomp = track.ncomp,
            .value = value,
        };
    }

    /// One `.pattern` track at wrapped tick `t`, or null when there is no
    /// write this frame — silence, or a failure-induced hole (counted).
    ///
    /// Query this tick's enclosing cycle through the shared
    /// module — fronted by the fixed scratch, so the frame path
    /// never touches the gpa — then point-sample the active hap
    /// (`PatternTrack.sampleAt`). Hap value exprs see pacer's env
    /// at THIS tick (time names + live control values, scene-locals
    /// when scened — `ExprTrack.buildEnv`, the same scope `:expr`
    /// tracks read) under the engine's pattern-local shadows, so a
    /// `(pure (* beat 2))` hap tracks the clock within its span.
    /// `expr_failures` counts only
    /// frames whose write is actually OMITTED by a failure: a
    /// query refusal, an uncoercible selected value, or an empty
    /// sample in a cycle the engine dropped a hap in (the active
    /// hap was likely the one that failed). A plain silence gap
    /// is uncounted; when a sibling hap still lands, the write is
    /// produced and nothing is counted even if another hap
    /// dropped. `result.dropped` is a cycle-level count, so the
    /// probe is coarse — a real gap in a cycle that also dropped
    /// elsewhere is counted too — but it never miscounts a frame
    /// that wrote.
    fn evalPatternTrack(
        self: *Evaluator,
        track: *const TrackTable.Track,
        node: sjon.Ast.NodeIndex,
        t: Tick,
        scene: ?TrackTable.Scene,
    ) ?Writes.Entry {
        std.debug.assert(track.ncomp >= 1);
        std.debug.assert(track.ncomp <= 4);
        var fba = std.heap.FixedBufferAllocator.init(self.scratch);
        var env_storage: ExprTrack.EnvStorage = undefined;
        const env = ExprTrack.buildEnv(&env_storage, &self.table.transport, self.ctl_bindings, t, scene);
        var result = PatternTrack.queryCycle(fba.allocator(), self.tree, self.schema, node, t, env) catch {
            self.expr_failures += 1;
            return null;
        };
        defer result.deinit();
        if (PatternTrack.sampleAt(result.haps, t)) |pv| {
            const value = PatternTrack.coerce(pv) orelse {
                self.expr_failures += 1; // selected hap violates the numeric contract
                return null;
            };
            return .{
                .target_id = track.target_id,
                .flags = track.registry,
                .ncomp = track.ncomp,
                .value = value,
            };
        }
        if (result.dropped > 0) {
            // No active hap AND the engine dropped one this cycle:
            // the sample is a failure-induced hole, not silence.
            self.expr_failures += 1;
        }
        return null;
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

/// Sample a `(trigger …)` schedule at wrapped tick `t` into a write entry,
/// or `null` before the first event (the write is omitted). The schedule's
/// ticks are absolute (scene start already folded in), so the scene-window
/// gate in the caller is the only scene handling needed. `cache` holds the
/// last `:at` cursor (indexed by track position); periodic schedules divide
/// and never touch it.
///
/// Lanes, in the frozen order, truncated to the target's `ncomp`:
///   [0] phase       — `(t − event)/span` ∈ [0,1); a periodic schedule
///       always has a next event (span = `every`), the last explicit `:at`
///       event holds 1.0;
///   [1] count       — 0-based event index as f32 (exact to 2^24, then
///       f32-rounded — deterministically);
///   [2] gate        — 1.0 exactly on the event tick, else 0.0 (structural);
///   [3] beats-since — `(t − event)/ppb` (= `map.beatOf`).
/// Each derives from an i64 tick delta through ONE f64 division (the eval
/// seam) and is narrowed to f32 only here at emission.
fn evalTrigger(
    map: *const TimeMap,
    track: *const TrackTable.Track,
    sched: *const TrackTable.Trigger,
    t: Tick,
    cache: *u32,
) ?Writes.Entry {
    var event_tick: Tick = undefined;
    var count: Tick = undefined;
    // Span to the next event; 0 = no next (last `:at` event) → phase holds 1.
    var span: Tick = 0;
    switch (sched.*) {
        .periodic => |p| {
            std.debug.assert(p.every > 0);
            const k = @divFloor(t - p.offset, p.every);
            if (k < 0) return null; // before the first event
            event_tick = p.offset + k * p.every;
            count = k;
            span = p.every; // unbounded schedule — always a next event
        },
        .at => |ticks| {
            std.debug.assert(ticks.len >= 1);
            if (t < ticks[0]) return null; // before the first event
            // Resume from the cached cursor (playhead near-monotonic),
            // restart on a backwards seek, advance forwards — as evalKeyTrack.
            var i: usize = cache.*;
            if (i >= ticks.len or ticks[i] > t) i = 0;
            while (i + 1 < ticks.len and ticks[i + 1] <= t) : (i += 1) {}
            cache.* = @intCast(i);
            // Cursor postcondition — relies on compile's strictly
            // ascending `:at` invariant, re-asserted at the read.
            std.debug.assert(ticks[i] <= t);
            if (i + 1 < ticks.len) std.debug.assert(t < ticks[i + 1]);
            event_tick = ticks[i];
            count = @intCast(i);
            span = if (i + 1 < ticks.len) ticks[i + 1] - event_tick else 0;
        },
    }

    const since = t - event_tick; // ticks since the event (≥ 0)
    std.debug.assert(since >= 0);
    const phase: f64 = if (span == 0)
        1.0
    else
        @as(f64, @floatFromInt(since)) / @as(f64, @floatFromInt(span));
    const gate: f64 = if (since == 0) 1.0 else 0.0;
    const lanes = [4]f64{ phase, @floatFromInt(count), gate, map.beatOf(since) };

    var entry: Writes.Entry = .{
        .target_id = track.target_id,
        .flags = track.registry,
        .ncomp = track.ncomp,
        .value = .{ 0, 0, 0, 0 },
    };
    for (0..track.ncomp) |c| entry.value[c] = @floatCast(lanes[c]);
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

// Trigger lanes want a full-width and a scalar target: `pulse` (ncomp 4)
// reads all four lanes (phase, count, gate, beats-since); `hit` (ncomp 1)
// keeps only `phase` and proves the higher lanes are zeroed by truncation.
const trigger_targets = [_]Compile.Target{
    .{ .name = "pulse", .ncomp = 4 },
    .{ .name = "hit", .ncomp = 1 },
};

fn compileScoreWith(source: [:0]const u8, tgts: []const Compile.Target) !Compile.CompileResult {
    var r = try Compile.compile(t_.allocator, source, tgts);
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
