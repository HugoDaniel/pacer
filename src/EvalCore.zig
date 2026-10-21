//! The frame engine, extracted (02 P1) — ONE evaluator over a tree-OR-
//! binary leaf source. Everything `Eval.Evaluator` was yesterday lives
//! here unchanged; `src/Eval.zig` is now a compiler-side facade that
//! re-exports this type under the historical name, so the exact call
//! `Eval.Evaluator.init(gpa, &result)` keeps compiling unmodified. This
//! leaf never names or imports the compiler — construction is either a
//! `Context` bundle (the runtime's spelling, `initContext`) or anything
//! carrying `.evalContext()` (duck-typed by the generic `init`; the
//! compile-result type qualifies through its own `evalContext()`).
//!
//! Leaf sources (the `LeafSource` union — mutually exclusive BY
//! CONSTRUCTION, a mixed context is unrepresentable):
//!   * tree — today's path verbatim: `.expr`/`.pattern` nodes evaluate
//!     against the borrowed validated tree with the document's
//!     user-plugin aggregate schema;
//!   * binary — the runtime's path (02): parallel compact-payload
//!     slices carry each `.expr`/`.pattern` track's decode-validated
//!     single-root IR, evaluated by `ExprTrack.evalAtBinary` (the T1.1
//!     twin: same env, same coerce, bit-equal by test pin) and — since
//!     P4/A2 (2026-10-21) — `PatternTrack.queryCycleBinary` (the
//!     delivered env-carrying binary query: same window, same env, same
//!     sample/coerce). The table's `.expr`/`.pattern` node indices are
//!     INERT sentinels on this arm — never read (C4).
//!
//! Per-arm schema contract: the tree arm's schema is bound by the
//! context venter (the compile result's core ⊕ user-plugins aggregate
//! on the text path); the binary arm's is the frozen core-only schema.
//! The union keeps either from leaking across arms.
//!
//! ---
//!
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
//! never depends on what was evaluated before. The binary arm's leaf
//! failures ride the SAME omit-and-count path — any `evalAtBinary`
//! error is counted and omitted, never a trap (02 T1.2).
//!
//! Controls and the tempo nudge are the deliberate pieces of API state,
//! and both live HERE — the compiled table is never written after
//! compile. The buffer is a pure function of (time, control state, bpm
//! nudge): same table, same tick, same held values, same bpm ⇒ same
//! bytes. `setBpm` rebuilds this evaluator's own `transport` copy (the
//! seconds projection only; ticks are musical positions and stand still),
//! so the table — and the `'PACM'` blob encoded from it — stays the
//! document's truth. Control writes land AFTER track writes and
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
const RtSjon = @import("RtSjon.zig");
const TrackTable = @import("TrackTable.zig");
const TimeMap = @import("TimeMap.zig");
const Writes = @import("Writes.zig");
const ExprTrack = @import("ExprTrack.zig");
const PatternTrack = @import("PatternTrack.zig");

/// Mutually exclusive BY CONSTRUCTION — a mixed context is
/// unrepresentable. The tree arm is today's path verbatim; the binary
/// arm carries the runtime's parallel compact-payload slices (the
/// table's `.expr` node indices are inert sentinels there — never
/// dereferenced, C4).
pub const LeafSource = union(enum) {
    tree: *const RtSjon.Ast.Tree,
    binary: struct {
        /// Compact single-root expr payloads, PARALLEL to
        /// `table.tracks`: the `.expr` track's payload at its track
        /// position, null on every other track.
        expr: []const ?[]const u8,
        /// Compact single-root pattern payloads, PARALLEL to
        /// `table.tracks` (the expr slice's P4 twin): the `.pattern`
        /// track's payload at its track position, null on every other
        /// track. Same length as `expr` — one slot per track either way.
        pattern: []const ?[]const u8 = &.{},
    },
};

/// What an evaluator is built over: the compiled table (borrowed), the
/// leaf source (borrowed pointees), and the per-arm schema. Copied BY
/// VALUE into the evaluator at init (C3, a labeled choice: a pure
/// pointer-bundle, so no caller stack frame is ever borrowed); the
/// pointees keep the borrow-whole contract — the score owns them,
/// ordered teardown, evaluator first.
pub const Context = struct {
    table: *const TrackTable,
    source: LeafSource,
    /// Per-arm contract: tree arm — the aggregate the document
    /// validated under (core ⊕ its user plugins; user heads are public
    /// text-path semantics and must keep resolving). Binary arm —
    /// the frozen core ⊕ pattern aggregate (the pattern row joined at
    /// P4/A2); user heads never enter a binary because pack refuses
    /// them (01, decision 8).
    schema: RtSjon.Schema.Schema,
};

/// The shared grid position type (`i64`), re-exported for call sites.
pub const Tick = RtSjon.Pattern.Tick;

/// Time conversion failures (host clock out of range). The tick-domain
/// path is total once conversion succeeded.
pub const Error = TimeMap.Error;

/// Dynamic control slots available beyond the document's own
/// (`registerControl` — editor-lifted literals with no `(control …)`
/// in the text).
pub const MAX_DYNAMIC_CONTROLS = 64;

/// Sentinel target id of an env-only document control (writes nothing) —
/// `TrackTable.NO_TARGET`, re-exported for the wasm entry's range guard.
pub const NO_TARGET: u16 = TrackTable.NO_TARGET;

/// `Evaluator.init`'s error set: all allocation happens there, so the
/// build phase can only exhaust memory. `Error` is the frame path's.
pub const InitError = error{OutOfMemory};

/// The most entries one frame can produce: every emit lane, every track,
/// every document control, and every dynamic slot writing at once. The
/// lane ceiling is `EmitName`'s field count (compile rejects duplicate
/// lanes), so appending a variant grows this automatically. `Evaluator.init`
/// sizes (and asserts) against it; the wasm writes zone is
/// `Writes.encodedLen(MAX_FRAME_ENTRIES)` — one derivation, no mirrored sum.
pub const MAX_FRAME_ENTRIES = @typeInfo(TrackTable.EmitName).@"enum".fields.len +
    TrackTable.MAX_TRACKS + TrackTable.MAX_CONTROLS + MAX_DYNAMIC_CONTROLS;

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

/// Frame evaluator over a compiled score's table + leaf source. The
/// `Context` is copied at init; its pointees are borrowed whole (expr
/// tracks need the tree + schema on the tree arm, not just the table)
/// — hold the owning pair through `Driver` (lifetime as structure)
/// unless you can uphold the placement / no-reassign / teardown-order
/// rules yourself (see the compile-result struct's own doc). Owns its
/// arena (cache + entry buffer + expr scratch); SJON deinit convention.
pub const Evaluator = struct {
    arena: std.heap.ArenaAllocator,
    table: *const TrackTable,
    /// The transport every frame projects through: a value copy of
    /// `table.transport` taken at init, so `setBpm` can rebuild its map
    /// without writing to the borrowed table. Its slices (`emit`,
    /// `segments`, `map.segments`) still alias the table's arena.
    transport: TrackTable.Transport,
    /// The leaf the expr/pattern arms evaluate against — the borrowed
    /// validated tree (text path) or the parallel binary payloads
    /// (runtime). Mutually exclusive by construction (`LeafSource`).
    source: LeafSource,
    schema: RtSjon.Schema.Schema,
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
    /// The tick the LAST frame was computed at, after every wrap. A
    /// read-only debugging probe like `expr_failures` — the determinism
    /// claim never reads it, and nothing in evaluation branches on it.
    ///
    /// It exists because that tick is not recoverable from outside:
    /// `evalSeconds` wraps SECONDS for a mapped score and then converts,
    /// while `evalTicks` wraps in the tick domain, so calling
    /// `tickFromSeconds` a second time answers a different question on any
    /// looping score. A consumer that wants to report a frame's musical
    /// position reads this rather than re-spelling a pinned seam.
    last_tick: Tick = 0,

    /// Build the evaluator from a context bundle — the runtime's typed
    /// spelling. `ctx` is copied by value (C3); the pointees keep the
    /// borrow-whole contract. All allocation happens here; the frame
    /// path never touches the gpa.
    pub fn initContext(gpa: std.mem.Allocator, ctx: Context) InitError!Evaluator {
        const table = ctx.table;
        std.debug.assert(table.tracks.len <= TrackTable.MAX_TRACKS);
        // Lane uniqueness is enforced upstream, so the enum's field
        // count is the lane ceiling — the invariant MAX_FRAME_ENTRIES
        // rests on.
        std.debug.assert(table.transport.emit.len <= @typeInfo(TrackTable.EmitName).@"enum".fields.len);
        // The binary arm's expr AND pattern payloads are indexed by
        // track position (C4) — the parallel-slice invariant both arms
        // rest on.
        switch (ctx.source) {
            .binary => |bin| {
                std.debug.assert(bin.expr.len == table.tracks.len);
                std.debug.assert(bin.pattern.len == table.tracks.len);
            },
            .tree => {},
        }
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const seg_cache = try arena.allocator().alloc(u32, table.tracks.len);
        @memset(seg_cache, 0);
        const entry_count =
            table.transport.emit.len + table.tracks.len + table.controls.len + MAX_DYNAMIC_CONTROLS;
        std.debug.assert(entry_count <= MAX_FRAME_ENTRIES);
        const entries = try arena.allocator().alloc(Writes.Entry, entry_count);
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
            .transport = table.transport,
            .source = ctx.source,
            .schema = ctx.schema,
            .seg_cache = seg_cache,
            .entries = entries,
            .scratch = scratch,
            .ctl_bindings = ctl_bindings,
            .slots = slots,
        };
    }

    /// Build the evaluator over a SUCCESSFUL compile — the historical
    /// public spelling `Evaluator.init(gpa, &result)`, preserved
    /// byte-for-byte (02:76-91, R-B1): every existing caller compiles
    /// unmodified through the facade alias. Comptime dispatch:
    ///   * an `EvalCore.Context` → the runtime arm directly;
    ///   * anything carrying `.evalContext()` (a compile-result pointer,
    ///     `*const` or mutable) → the tree arm through that method;
    ///   * anything else → this readable error, not a duck-type maze.
    /// The dispatch is structural — this leaf never names the compiler.
    pub fn init(gpa: std.mem.Allocator, source: anytype) InitError!Evaluator {
        const S = @TypeOf(source);
        if (comptime S == Context) return initContext(gpa, source);
        if (comptime hasEvalContext(S)) return initContext(gpa, source.evalContext());
        @compileError("Evaluator.init: want EvalCore.Context or a compile result carrying .evalContext(), got " ++ @typeName(S));
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

    /// Live tempo nudge (`drv_setBpm`): rebuild THIS evaluator's
    /// seconds↔ticks projection at the new tempo. Runtime state like a held
    /// control — the compiled table keeps the document's tempo (so does the
    /// `'PACM'` blob), a fresh evaluator starts from it, and a reload resets
    /// it. Musical positions are ticks and stay put — including positions
    /// authored in `s`, which were converted at load with the load-time
    /// tempo (the standard tempo-nudge semantic). False (no change) when
    /// bpm is outside the manifest's 1..1000 bounds or the score carries a
    /// tempo map — a mapped score's tempo truth is score text (segment bpms
    /// are not one nudgeable scalar); edit the `(tempo …)` forms and reload
    /// instead. Host input, so a result, never an assert.
    pub fn setBpm(self: *Evaluator, bpm: f64) bool {
        if (!std.math.isFinite(bpm) or bpm < 1 or bpm > 1000) return false;
        const transport = &self.transport;
        if (transport.map.segments.len > 1) return false;
        transport.map = TimeMap.init(bpm, transport.map.beats_per_bar);
        // Keep loop_secs coherent (the constant-score path never reads it,
        // but a stale value is a trap for the next reader).
        if (transport.dur) |d| transport.loop_secs = transport.map.secondsFromTick(d);
        return true;
    }

    /// Tear down BEFORE the borrowed context pointees (borrow-whole rule).
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
        const transport = &self.transport;
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
        std.debug.assert(t_raw <= RtSjon.Pattern.MAX_TICK);
        std.debug.assert(t_raw >= -RtSjon.Pattern.MAX_TICK);
        const table = self.table;
        const transport = &self.transport;
        var t = t_raw;
        if (transport.dur) |dur| {
            std.debug.assert(dur > 0);
            switch (transport.end) {
                .loop => t = @mod(t, dur),
                .hold => t = @min(t, dur),
            }
        }
        // The probe, set AFTER the wrap: `t`, not `t_raw`, is the position
        // every write below is computed from.
        self.last_tick = t;
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
        for (transport.emit) |lane| {
            const v: f32 = @floatCast(ExprTrack.emitValue(transport, t, lane.name));
            self.push(&n, .{
                .target_id = lane.target_id,
                .flags = lane.registry,
                .ncomp = 1,
                .value = .{ v, 0, 0, 0 },
            });
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
                .keys => self.push(&n, evalKeyTrack(table, track, t, &self.seg_cache[i])),
                .expr => {
                    if (self.evalExprTrack(track, i, t, scene)) |entry|
                        self.push(&n, entry);
                },
                .trigger => |*sched| {
                    // Resolve the lanes for the current event; before the
                    // first event the write is OMITTED (like an expr-NaN /
                    // an out-of-window scene), keeping the buffer a pure
                    // function of time.
                    if (evalTrigger(&transport.map, track, sched, t, &self.seg_cache[i])) |entry|
                        self.push(&n, entry);
                },
                .pattern => |node| {
                    if (self.evalPatternTrack(track, node, i, t, scene)) |entry|
                        self.push(&n, entry);
                },
            }
        }
        // Control writes land AFTER track writes — consumers apply
        // entries in order, so a pin (or a held widget) outranks a
        // track on the same target. Document controls always write;
        // dynamic slots only while held.
        for (self.slots[0..table.controls.len], table.controls) |slot, ctl| {
            if (slot.target_id == NO_TARGET) continue;
            self.push(&n, .{
                .target_id = slot.target_id,
                .flags = slot.registry,
                .ncomp = slot.ncomp,
                .value = slot.live orelse ctl.value,
            });
        }
        for (self.slots[table.controls.len..][0..self.dyn_controls]) |slot| {
            const live = slot.live orelse continue;
            self.push(&n, .{
                .target_id = slot.target_id,
                .flags = slot.registry,
                .ncomp = slot.ncomp,
                .value = live,
            });
        }
        std.debug.assert(n <= self.entries.len);
        return self.entries[0..n];
    }

    /// Append one entry to this frame's buffer — the only way `evalTicks`
    /// writes `entries`. Write ORDER is the callers' contract (emit →
    /// tracks → controls; in-order consumers depend on it) — this helper
    /// only owns the append-and-advance.
    fn push(self: *Evaluator, n: *usize, entry: Writes.Entry) void {
        self.entries[n.*] = entry;
        n.* += 1;
    }

    /// One `.expr` track at wrapped tick `t`, or null when the write is
    /// OMITTED by a runtime failure (counted in `expr_failures`). The
    /// leaf switch: the tree arm re-reads the node against the borrowed
    /// tree; the binary arm decodes the track's compact payload —
    /// same env, same coerce, so the arms cannot drift (T1.1's pin).
    /// Either arm's failure rides the same omit-and-count path.
    fn evalExprTrack(
        self: *Evaluator,
        track: *const TrackTable.Track,
        track_index: usize,
        t: Tick,
        scene: ?TrackTable.Scene,
    ) ?Writes.Entry {
        std.debug.assert(track.ncomp >= 1);
        std.debug.assert(track.ncomp <= 4);
        // Reset scratch per track: each expression gets the
        // whole fixed zone; nothing survives the call.
        var fba = std.heap.FixedBufferAllocator.init(self.scratch);
        const value: [4]f32 = switch (self.source) {
            .tree => |tree| blk: {
                // C4 guard (R-O2): the tree arm dereferences the track's
                // source node — a real index, never the inert sentinel a
                // binary-materialized table would carry.
                const node = track.source.expr;
                std.debug.assert(node != .invalid);
                break :blk ExprTrack.evalAt(
                    fba.allocator(),
                    tree,
                    self.schema,
                    &self.transport,
                    self.ctl_bindings,
                    node,
                    t,
                    scene,
                    track.ncomp,
                ) catch {
                    self.expr_failures += 1;
                    return null;
                };
            },
            .binary => |bin| blk: {
                // The node index is inert on this arm — never read (C4);
                // the payload slice is the leaf.
                const payload = bin.expr[track_index] orelse {
                    // Parallel-slice invariant: an `.expr` track carries
                    // its payload. A missing one is a context-construction
                    // bug — the same omit-and-count as any leaf failure,
                    // never a silent empty write.
                    self.expr_failures += 1;
                    return null;
                };
                break :blk ExprTrack.evalAtBinary(
                    fba.allocator(),
                    payload,
                    self.schema,
                    &self.transport,
                    self.ctl_bindings,
                    t,
                    scene,
                    track.ncomp,
                ) catch {
                    self.expr_failures += 1;
                    return null;
                };
            },
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
        node: RtSjon.Ast.NodeIndex,
        track_index: usize,
        t: Tick,
        scene: ?TrackTable.Scene,
    ) ?Writes.Entry {
        std.debug.assert(track.ncomp >= 1);
        std.debug.assert(track.ncomp <= 4);
        var fba = std.heap.FixedBufferAllocator.init(self.scratch);
        var env_storage: ExprTrack.EnvStorage = undefined;
        const env = ExprTrack.buildEnv(&env_storage, &self.transport, self.ctl_bindings, t, scene);
        var result = switch (self.source) {
            .tree => |tree| blk: {
                // C4 guard (R-O2): the tree arm dereferences the track's
                // source node — a real index, never the inert sentinel a
                // binary-materialized table would carry.
                std.debug.assert(node != .invalid);
                break :blk PatternTrack.queryCycle(fba.allocator(), tree, self.schema, node, t, env) catch {
                    self.expr_failures += 1;
                    return null;
                };
            },
            .binary => |bin| blk: {
                // P4/A2: the parallel payload slice is the leaf — the
                // binary parallel of the tree arm's node, through the
                // SAME shared window/sample/coerce helpers (no second
                // interpreter). The env is built identically (transport
                // clock + live control values, scene-locals when
                // scened), so the shadow rule and the hap semantics
                // cannot drift from the text path.
                const payload = bin.pattern[track_index] orelse {
                    // Parallel-slice invariant: a `.pattern` track
                    // carries its payload. A missing one is a
                    // context-construction bug — the same
                    // omit-and-count as any leaf failure, never a
                    // silent empty write.
                    self.expr_failures += 1;
                    return null;
                };
                break :blk PatternTrack.queryCycleBinary(fba.allocator(), self.schema, payload, t, env) catch {
                    self.expr_failures += 1;
                    return null;
                };
            },
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

/// Comptime duck-type: does `S` carry an `evalContext()` member — a
/// compile-result struct, or a single-item pointer to one (`*const` and
/// mutable both qualify)? Structural only; this leaf never names the
/// compiler-side type (02:35).
fn hasEvalContext(comptime S: type) bool {
    const pointee: ?type = switch (@typeInfo(S)) {
        .pointer => |ptr| if (ptr.size == .one) ptr.child else null,
        else => S,
    };
    const target = pointee orelse return false;
    return switch (@typeInfo(target)) {
        .@"struct", .@"enum", .@"union", .@"opaque" => @hasDecl(target, "evalContext"),
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Tests. The engine's historical suite stays with the facade
// (`src/Eval.zig`) — it compiles real scores through the public path.
// Here: the construction surface and the binary arm, pinned against the
// tree arm on the SAME table. The compiler-side imports these tests
// need sit INDENTED inside each test (the closure split, 02:200-202):
// this file's column-0 imports are its production surface only, and the
// write-side payload builder below keeps its own indented module import.
// ---------------------------------------------------------------------------

const t_ = std.testing;

/// Compact single-root payload for one expr node of a validated tree —
/// the frozen producer's exact spell (`TreeBuilder.cloneNode` into a
/// fresh one-root tree, `Binary.toBinary(.forMode(.compact))`, what the
/// pack path encodes). Test-only; caller owns the returned bytes.
fn compactPayloadFor(a: std.mem.Allocator, tree: *const RtSjon.Ast.Tree, node: RtSjon.Ast.NodeIndex) ![]u8 {
    const sjon = @import("sjon");
    var tree_arena = std.heap.ArenaAllocator.init(a);
    defer tree_arena.deinit(); // no-op once finalize snapshots the arena
    var builder = sjon.Ast.TreeBuilder{ .a = tree_arena.allocator() };
    const root = try builder.cloneNode(tree, node);
    var one_root = try builder.finalize(&tree_arena, "", &.{root});
    defer one_root.deinit();
    const bin = try sjon.Binary.toBinary(a, one_root, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer bin.deinit();
    return a.dupe(u8, bin.data);
}

/// The binary arm's frozen aggregate — core ⊕ pattern (the pattern row
/// joined at P4/A2).
const core_plugins = [_]RtSjon.Plugin.Plugin{ RtSjon.plugins.core.plugin, RtSjon.plugins.pattern.plugin };
const binary_schema: RtSjon.Schema.Schema = .{ .plugins = &core_plugins };

test "EvalCore: initContext evaluates a binary-arm context bit-equal to the facade path" {
    const Compile = @import("Compile.zig");
    const Eval = @import("Eval.zig");
    const test_support = @import("test_support.zig");
    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    var r = try Compile.compile(t_.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target x :expr (+ 0.25 (* 0.25 beat)))
    , &tg);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t_.expect(r.ok());

    const table = &r.table.?;
    const payload = try compactPayloadFor(t_.allocator, &r.validated.result.tree, table.tracks[0].source.expr);
    defer t_.allocator.free(payload);
    const payloads = [_]?[]const u8{payload};
    const pattern_nulls = [_]?[]const u8{null};

    // The tree arm through the PRESERVED public spelling (the facade
    // alias — pins it against this file's typed spelling).
    var tree_ev = try Eval.Evaluator.init(t_.allocator, &r);
    defer tree_ev.deinit();
    // The binary arm through the runtime's typed spelling.
    var bin_ev = try Evaluator.initContext(t_.allocator, .{
        .table = table,
        .source = .{ .binary = .{ .expr = &payloads, .pattern = &pattern_nulls } },
        .schema = binary_schema,
    });
    defer bin_ev.deinit();

    const a = tree_ev.evalTicks(2 * 180180);
    const b = bin_ev.evalTicks(2 * 180180);
    try t_.expectEqual(a.len, b.len);
    try t_.expectEqualSlices(Writes.Entry, a, b);
    try t_.expectEqual(@as(f32, 0.75), b[0].value[0]); // 0.25 + 0.25·2
    try t_.expectEqual(@as(u64, 0), bin_ev.expr_failures);
}

test "EvalCore: binary arm ≡ tree arm over one table — tick sweep, held control, dynamic slot, both spellings" {
    const Compile = @import("Compile.zig");
    const Eval = @import("Eval.zig");
    const test_support = @import("test_support.zig");
    const tg = [_]Compile.Target{
        .{ .name = "radius", .ncomp = 1 },
        .{ .name = "tint", .ncomp = 3 },
        .{ .name = "pulse", .ncomp = 4 },
    };
    var r = try Compile.compile(t_.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(control :id knob :value 0.25)
        \\(track :target radius
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8 :ease out-cubic))
        \\(track :target tint :expr [(* knob 4) (+ beat 0) (* phase 2)])
        \\(trigger :target pulse :every 2b :offset 1b)
        \\(scene :name drop :at 4b :dur 8b
        \\  (track :target radius :expr (+ scene-beat (sqrt scene-phase))))
    , &tg);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t_.expect(r.ok());

    const table = &r.table.?;
    const tree = &r.validated.result.tree;
    const map = &table.transport.map;

    // Binary payloads, parallel to table.tracks (C4): the `.expr`
    // track's compact clone at its position, null elsewhere.
    var payloads = try t_.allocator.alloc(?[]const u8, table.tracks.len);
    defer {
        for (payloads) |maybe| if (maybe) |p| t_.allocator.free(@constCast(p));
        t_.allocator.free(payloads);
    }
    for (table.tracks, 0..) |tr, i| {
        payloads[i] = switch (tr.source) {
            .expr => |node| try compactPayloadFor(t_.allocator, tree, node),
            else => null,
        };
    }
    const pattern_nulls = try t_.allocator.alloc(?[]const u8, table.tracks.len);
    defer t_.allocator.free(pattern_nulls);
    @memset(pattern_nulls, null);
    const ctx: Context = .{
        .table = table,
        .source = .{ .binary = .{ .expr = payloads, .pattern = pattern_nulls } },
        .schema = binary_schema,
    };

    // Tree arm — the PRESERVED public spelling, through the facade
    // alias (the generic init's duck-typed arm via evalContext()).
    var tree_ev = try Eval.Evaluator.init(t_.allocator, &r);
    defer tree_ev.deinit();
    // Binary arm — the runtime's typed spelling.
    var bin_ev = try Evaluator.initContext(t_.allocator, ctx);
    defer bin_ev.deinit();
    // And the generic init's Context arm (by value) — same engine, the
    // third construction spelling.
    var ctx_ev = try Evaluator.init(t_.allocator, ctx);
    defer ctx_ev.deinit();

    const sweep = [_]Tick{
        try map.tickFromBeats(-1), // before every event/window
        0,
        try map.tickFromBeats(1), // trigger event tick (gate lane)
        try map.tickFromBeats(2) + 90090, // mid-beat, mid-interval
        try map.tickFromBeats(4), // scene start (C5's dry env)
        try map.tickFromBeats(6), // scene interior
        (try map.tickFromBeats(12)) - 1, // last tick inside the window
        try map.tickFromBeats(13), // past the last key
    };
    // One sweep with the three evaluators in their current control
    // state — document values, nothing held.
    for (sweep) |tick| {
        const a = tree_ev.evalTicks(tick);
        const b = bin_ev.evalTicks(tick);
        try t_.expectEqual(a.len, b.len);
        try t_.expectEqualSlices(Writes.Entry, a, b);
        const c = ctx_ev.evalTicks(tick);
        try t_.expectEqualSlices(Writes.Entry, b, c);
    }

    // Held document control (env-only `knob`): the tint expr reads the
    // live value on BOTH arms — the ctl_bindings refresh is shared.
    try t_.expect(tree_ev.setControl(0, .{ 0.75, 0, 0, 0 }));
    try t_.expect(bin_ev.setControl(0, .{ 0.75, 0, 0, 0 }));
    for (sweep) |tick| {
        const a = tree_ev.evalTicks(tick);
        const b = bin_ev.evalTicks(tick);
        try t_.expectEqual(a.len, b.len);
        try t_.expectEqualSlices(Writes.Entry, a, b);
    }
    // The held value actually changed the expr (not a vacuous pass):
    // the tint expr (target id 1) at beat 0 with knob 0.75 → lane 0 is
    // 3.0. Entry order is document order — the radius keyframe track
    // writes first — so address the expr entry by its target id.
    {
        const at_zero = tree_ev.evalTicks(0);
        var tint: ?Writes.Entry = null;
        for (at_zero) |e| {
            if (e.target_id == 1) tint = e;
        }
        try t_.expect(tint != null);
        try t_.expectEqual(@as(u8, 3), tint.?.ncomp);
        try t_.expectEqual(@as(f32, 3), tint.?.value[0]);
    }

    // Dynamic slot: register on both (same index space), silent until
    // held, then a write on every frame of the sweep.
    const tree_slot = tree_ev.registerControl(2, 0, 4).?;
    const bin_slot = bin_ev.registerControl(2, 0, 4).?;
    try t_.expectEqual(tree_slot, bin_slot);
    for (sweep) |tick| {
        const a = tree_ev.evalTicks(tick);
        const b = bin_ev.evalTicks(tick);
        try t_.expectEqual(a.len, b.len);
        try t_.expectEqualSlices(Writes.Entry, a, b);
    }
    try t_.expect(tree_ev.setControl(tree_slot, .{ 9, 8, 7, 0 }));
    try t_.expect(bin_ev.setControl(bin_slot, .{ 9, 8, 7, 0 }));
    for (sweep) |tick| {
        const a = tree_ev.evalTicks(tick);
        const b = bin_ev.evalTicks(tick);
        try t_.expectEqual(a.len, b.len);
        try t_.expectEqualSlices(Writes.Entry, a, b);
        // The held slot lands as the LAST entry (dynamic writes after
        // tracks and document controls) on the pulse target.
        try t_.expectEqual(@as(u16, 2), b[b.len - 1].target_id);
        try t_.expectEqual([4]f32{ 9, 8, 7, 0 }, b[b.len - 1].value);
    }

    // The probes agree too — and nothing was ever omitted.
    try t_.expectEqual(tree_ev.expr_failures, bin_ev.expr_failures);
    try t_.expectEqual(tree_ev.last_tick, bin_ev.last_tick);
    try t_.expectEqual(@as(u64, 0), tree_ev.expr_failures);
}

test "EvalCore: per-arm schema — the tree arm carries the document's user plugins, the binary arm the frozen core⊕pattern aggregate" {
    const Compile = @import("Compile.zig");
    const Eval = @import("Eval.zig");
    const test_support = @import("test_support.zig");
    // A user plugin REDECLARING a core name (`sin`): through the
    // compile result's eval_schema (core ⊕ user) the bare head is
    // AMBIGUOUS, so the tree arm's taken branch fails — omit + count —
    // while the binary arm's frozen core⊕pattern aggregate would
    // resolve core's sin and WRITE. The
    // dry-run at t=0 takes the else branch, so this score compiles
    // clean (the pack-preflight I1/G11 vocabulary, minus the pack).
    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    var r = try Compile.compile(t_.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(plugin :name up (expr-func :name sin :params [number] :result number))
        \\(track :target x :expr (if (> t 1) (sin 1) 2))
    , &tg);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t_.expect(r.ok());

    const table = &r.table.?;
    const map = &table.transport.map;
    const t_taken = try map.tickFromSeconds(2); // t = 2 s > 1 s: taken branch

    // Tree arm, through the preserved alias spelling: the guarded head
    // resolves AMBIGUOUS through the carried user-plugin aggregate —
    // the text path's public semantics, preserved verbatim.
    var tree_ev = try Eval.Evaluator.init(t_.allocator, &r);
    defer tree_ev.deinit();
    try t_.expectEqual(@as(f32, 2), tree_ev.evalTicks(0)[0].value[0]);
    try t_.expectEqual(@as(u64, 0), tree_ev.expr_failures);
    try t_.expectEqual(@as(usize, 0), tree_ev.evalTicks(t_taken).len);
    try t_.expectEqual(@as(u64, 1), tree_ev.expr_failures);

    // Binary arm over the SAME table, the frozen aggregate: core's sin
    // resolves — the write lands (the per-arm contract is the point,
    // not the value; the kernel is SJON's own).
    const payload = try compactPayloadFor(t_.allocator, &r.validated.result.tree, table.tracks[0].source.expr);
    defer t_.allocator.free(payload);
    const payloads = [_]?[]const u8{payload};
    const pattern_nulls = [_]?[]const u8{null};
    var bin_ev = try Evaluator.initContext(t_.allocator, .{
        .table = table,
        .source = .{ .binary = .{ .expr = &payloads, .pattern = &pattern_nulls } },
        .schema = binary_schema,
    });
    defer bin_ev.deinit();
    const at_zero = bin_ev.evalTicks(0);
    try t_.expectEqual(@as(usize, 1), at_zero.len);
    try t_.expectEqual(@as(f32, 2), at_zero[0].value[0]); // same else branch
    const at_taken = bin_ev.evalTicks(t_taken);
    try t_.expectEqual(@as(usize, 1), at_taken.len);
    try t_.expectApproxEqAbs(@as(f32, 0.8414710), at_taken[0].value[0], 1e-5); // sin(1)
    try t_.expectEqual(@as(u64, 0), bin_ev.expr_failures);
}

test "EvalCore: binary pattern arm ≡ tree pattern arm — env, shadow, dropped counting" {
    // P4/A2: the `.pattern` arm over a binary LeafSource evaluates
    // through `queryCycleBinary` with the SAME buildEnv scope as the
    // tree arm — byte-equal frames over a control-reading, shadow-using
    // pattern score, and the same omit-and-count on a dropped hap.
    const Compile = @import("Compile.zig");
    const Eval = @import("Eval.zig");
    const test_support = @import("test_support.zig");
    const tg = [_]Compile.Target{
        .{ .name = "clock", .ncomp = 1 },
        .{ .name = "onset", .ncomp = 1 },
        .{ .name = "swayx2", .ncomp = 1 },
        .{ .name = "hole", .ncomp = 1 },
    };
    var r = try Compile.compile(t_.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(control :id sway :value 0.25)
        \\(track :target clock :pattern (pure (* beat 2)))
        \\(track :target onset :pattern (pure (+ tick 0)))
        \\(track :target swayx2 :pattern (pure (* sway 2)))
        \\(track :target hole :pattern (pure (/ 1 (- 1 cycle))))
        \\
    , &tg);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t_.expect(r.ok());

    const table = &r.table.?;
    const tree = &r.validated.result.tree;
    // Binary payloads, parallel to table.tracks (C4): each `.pattern`
    // track's compact clone at its position, null elsewhere.
    const expr_nulls = try t_.allocator.alloc(?[]const u8, table.tracks.len);
    defer t_.allocator.free(expr_nulls);
    @memset(expr_nulls, null);
    var pattern_payloads = try t_.allocator.alloc(?[]const u8, table.tracks.len);
    defer {
        for (pattern_payloads) |maybe| if (maybe) |p| t_.allocator.free(@constCast(p));
        t_.allocator.free(pattern_payloads);
    }
    for (table.tracks, 0..) |tr, i| {
        pattern_payloads[i] = switch (tr.source) {
            .pattern => |node| try compactPayloadFor(t_.allocator, tree, node),
            else => null,
        };
    }
    var bin_ev = try Evaluator.initContext(t_.allocator, .{
        .table = table,
        .source = .{ .binary = .{ .expr = expr_nulls, .pattern = pattern_payloads } },
        .schema = binary_schema,
    });
    defer bin_ev.deinit();
    var tree_ev = try Eval.Evaluator.init(t_.allocator, &r);
    defer tree_ev.deinit();

    // Byte-equal frames across the wrap; the `hole` track drops its hap
    // in cycle 1 (÷0) on BOTH arms — the write omits and the counter
    // counts identically, then recovers in cycle 2.
    const PPC = RtSjon.Pattern.PPC;
    const sweep = [_]Tick{ 0, PPC / 2, PPC - 1, PPC, PPC + PPC / 2, 2 * PPC - 1, 2 * PPC, 3 * PPC };
    for (sweep) |tick| {
        const a = tree_ev.evalTicks(tick);
        const b = bin_ev.evalTicks(tick);
        try t_.expectEqualSlices(Writes.Entry, a, b);
    }
    // The drop was seen identically (cycle-1 frames, both arms), and
    // both evaluators recovered to 0-new-failures by cycle 2's frames.
    try t_.expect(tree_ev.expr_failures > 0);
    try t_.expectEqual(tree_ev.expr_failures, bin_ev.expr_failures);
    // A held control changes the sway hap identically on both arms.
    try t_.expect(tree_ev.setControl(0, .{ 0.75, 0, 0, 0 }));
    try t_.expect(bin_ev.setControl(0, .{ 0.75, 0, 0, 0 }));
    for (sweep) |tick| {
        const a = tree_ev.evalTicks(tick);
        const b = bin_ev.evalTicks(tick);
        try t_.expectEqualSlices(Writes.Entry, a, b);
    }
}
