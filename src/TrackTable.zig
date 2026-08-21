//! Compiled score — the compact runtime representation the evaluator
//! walks every frame.
//!
//! Built once per load by `Compile.buildTable` (walk the validated tree
//! into static arrays, convert positions to i64 ticks, flatten + dedup
//! easing programs); immutable afterwards. Keyframe tracks never touch
//! the AST again — the hot path reads these slices. Expr tracks are the
//! one designed exception: their `Source.expr` is a node index into the
//! compile result's tree, re-evaluated each frame (`ExprTrack.evalAt`),
//! so the tree must outlive the table — both live on
//! `Compile.CompileResult`, which guarantees it.
//!
//! Invariants (asserted at build, relied on by `Eval`):
//!   * every keyframe track has ≥ 1 key; keys are sorted by `at`,
//!     strictly increasing (duplicates were load diagnostics);
//!   * every `Key.value` lane ≥ its track's `ncomp` is zero;
//!   * every `ease_ref` indexes `programs`; `programs[0]` is linear
//!     (the shared default for keys without `:ease`);
//!   * every expr track dry-ran successfully at t = 0 during compile;
//!   * every trigger source is periodic (`every` > 0) or an explicit
//!     `at` slice of ≥ 1 tick, strictly ascending; scened-trigger ticks
//!     are absolute (scene start folded in), like a scened track's keys;
//!   * `transport.dur`, when present, is > 0;
//!   * control ids are unique and never shadow a reserved time-env name;
//!   * every `Track.scene` is `NO_SCENE` or a valid index into `scenes`;
//!     a scened track's key ticks are already absolute (scene start
//!     folded in at compile), and its window end `start_tick + dur_ticks`
//!     fits the grid (compile raised `tick_overflow` otherwise), so the
//!     eval-time window gate never overflows.
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
pub const MAX_CONTROLS = 64;
pub const MAX_SCENES = 64;
/// Tempo-map cap, counting segment 0 (the transport's own `:bpm`) plus
/// one per `(tempo …)` form. Generators coalesce adjacent-equal bpm.
pub const MAX_TEMPO_SEGMENTS = 512;

/// `Track.scene` sentinel: the track is top-level (un-scened). A real
/// scene index is always < `MAX_SCENES`, so this can never collide.
pub const NO_SCENE: u16 = std.math.maxInt(u16);

pub const EndBehavior = enum { loop, hold };

/// A reserved time name a `(transport :emit …)` lane broadcasts. The set
/// is a deliberate subset of `ExprTrack.reserved_names`: continuous
/// clock values worth a write lane. `tick` (unbounded integer), `cycle`
/// (a `bar` alias), and `dur` (a constant) are intentionally absent —
/// naming one in `:emit` is a `transport_invalid` diagnostic.
pub const EmitName = enum { beat, bar, phase, bpm, t };

/// One built-in clock lane: a reserved time value written every frame to
/// a host target of the same name. `name` selects the env formula
/// (reused from `ExprTrack`'s time bindings, never re-derived here);
/// `target_id`/`registry` are the load-time join and the target is
/// always scalar (`ncomp == 1`, enforced at compile).
pub const EmitLane = struct {
    name: EmitName,
    target_id: u16,
    registry: u8,
};

/// One tempo-map segment: from `start_tick` (inclusive) the transport
/// runs at `bpm`, until the next segment or the end of the score.
pub const TempoSegment = struct {
    start_tick: Tick,
    bpm: f64,
};

pub const Transport = struct {
    map: TimeMap,
    /// Score length in ticks; `null` = unbounded (end-behavior ignored).
    dur: ?Tick,
    end: EndBehavior,
    /// Built-in clock lanes (`:emit …`), in document order. Evaluated
    /// BEFORE tracks each frame, so an explicit `(track …)` on the same
    /// target overrides an emitted lane (controls still land last).
    /// Empty when the score declares no `:emit`.
    emit: []const EmitLane = &.{},
    /// Tempo-map segments, authored truth for the `'TMPO'` wire section:
    /// `segments[0]` is always `{0, transport :bpm}`, one more per
    /// `(tempo …)` form, start ticks strictly ascending (established at
    /// compile — eval never sorts). Length 1 = constant-tempo score.
    /// Defaults empty only for hand-built transports in tests; every
    /// compiled table carries ≥ 1.
    segments: []const TempoSegment = &.{},
    /// `map.secondsFromTick(dur)`, computed once at compile (and kept
    /// coherent by `setBpm`); null iff `dur` is null. The seconds-domain
    /// wrap constant for MAPPED scores — the constant-score eval path
    /// never reads it (tick wrap, bit-stable goldens).
    loop_secs: ?f64 = null,
};

/// One keyframe, position already on the tick grid.
pub const Key = struct {
    at: Tick,
    value: [4]f32,
    /// Easing program for the segment ENDING at this key. Index into
    /// `programs`; the first key of a track never reads it.
    ease_ref: u16,
};

/// A `(trigger …)` event schedule — the grid the evaluator samples for
/// its lanes. Periodic events land at `offset + k·every` (k ≥ 0, events
/// ≥ 0); explicit events are the pre-sorted `:at` positions. A scened
/// trigger's ticks are already absolute (the scene start folded in at
/// compile), exactly like a scened track's keys. Internal representation
/// — never crosses the wire — carried by `Source.trigger`.
pub const Trigger = union(enum) {
    /// Fire every `every` ticks (> 0), phased by `offset` (absolute, with
    /// the scene start folded in for a scened trigger). Unbounded — eval
    /// derives the current event by integer division, never materializing
    /// the schedule.
    periodic: struct { every: Tick, offset: Tick },
    /// Explicit hits: arena-owned, ≥ 1 element, strictly ascending in
    /// tick order (scene start folded into each for a scened trigger).
    at: []const Tick,
};

/// A track's value source — `(key …)` children XOR `:expr` XOR
/// `:pattern` (enforced at compile with `track_source_conflict`), or a
/// `(trigger …)` schedule (a trigger row kind reusing this struct; its
/// lanes are computed at eval).
pub const Source = union(enum) {
    /// Contiguous run in `keys`: `keys[start..][0..len]`, len ≥ 1,
    /// sorted by `at`, strictly increasing.
    keys: struct { start: u32, len: u32 },
    /// The `:expr` value node, evaluated against the compile result's
    /// tree each frame with the time env bound (see `ExprTrack`).
    expr: sjon.Ast.NodeIndex,
    /// A `(trigger …)` event schedule (see `Trigger`); the frame path
    /// derives its lanes from the schedule, never from `keys`/the AST.
    trigger: Trigger,
    /// The `:pattern` value node — SJON Pattern vocabulary queried on
    /// the shared tick grid, 1 cycle = 1 bar (identity: `Pattern.PPC`
    /// IS the per-bar tick count). Dry-run at load via `PatternTrack`
    /// (plan 03 Phase 2); the eval-time point-sample lands in Phase 3 —
    /// until then a pattern track emits no writes.
    pattern: sjon.Ast.NodeIndex,
};

/// One animated target. `target_id`/`registry`/`ncomp` come from the
/// load-time join against the host registries.
pub const Track = struct {
    target_id: u16,
    /// Registry index (0 = visual, 1 = audio, …) — lands in
    /// `Writes.Entry.flags` so JS routing is one switch.
    registry: u8,
    ncomp: u8,
    source: Source,
    /// Owning `(scene …)` index into `scenes`, or `NO_SCENE` for a
    /// top-level track. A scened track's key positions are already
    /// absolute (the scene's start tick was folded in at compile); the
    /// index carries the window for the eval-time gate (a scened track
    /// writes only while the playhead is inside `[start, start+dur)`) and
    /// its scene-local expr env.
    scene: u16,
};

/// One `(scene …)` window on the transport tick grid. Child tracks were
/// compiled scene-relative (their key ticks already absolute); this row
/// carries the window itself, for the eval gate and `drv_meta`.
pub const Scene = struct {
    /// Span of the `:name` symbol in score-source coordinates — the
    /// editor slices the scene's name from it (`drv_meta` writes it
    /// through verbatim); the frame path never reads it.
    name_span: sjon.Ast.Span,
    /// Window start on the transport grid.
    start_tick: Tick,
    /// Window length; child tracks play over `[start, start+dur)`.
    dur_ticks: Tick,
};

/// Editor widget hint, carried verbatim from the document into
/// `drv_meta`; the driver never interprets it.
pub const ControlType = enum(u8) { slider, xy, color };

/// A control's resolved write target (same load-time join as tracks).
pub const ControlTarget = struct { id: u16, registry: u8 };

/// One `(control …)` pin. The document `:value` is the authority while
/// the control is idle: written to `target` every frame and bound under
/// `id` in every track expression. Live overrides are runtime state on
/// `Eval.Evaluator`, never here — the table stays a pure function of
/// the document.
pub const Control = struct {
    /// Expr-env binding name; arena-owned copy. Never one of
    /// `ExprTrack.reserved_names` (load diagnostic).
    id: []const u8,
    /// Resolved write target, or null for an env-only control (a
    /// virtual knob that only feeds expressions).
    target: ?ControlTarget,
    /// Component count of `value` (joined against the target's when one
    /// is declared).
    ncomp: u8,
    kind: ControlType,
    /// Document `:value`, zero-padded like `Key.value`.
    value: [4]f32,
    /// Optional widget range — editor metadata, the driver never clamps.
    min: ?[4]f32,
    max: ?[4]f32,
    /// Span of the `:value` literal in score-source coordinates — the
    /// commit-to-text anchor for editor widgets (`drv_meta` writes it
    /// through verbatim).
    value_span: sjon.Ast.Span,
};

arena: std.heap.ArenaAllocator,
transport: Transport,
tracks: []const Track,
/// All tracks' keys, contiguous; a key-sourced track's `Source.keys`
/// run slices into it.
keys: []const Key,
/// Deduped easing programs; index 0 is always linear.
programs: []const Easing.Program,
/// `(control …)` pins in document order; the position index is the
/// control's handle in the `drv_setControl` index space.
controls: []const Control,
/// Spans of each `(track …)` / `(key …)` form in score-source
/// coordinates, parallel to `tracks` / `keys` (key spans ride the same
/// sort as their keys). Pure `drv_meta` material — the editor's
/// timeline anchors; the frame path never reads them.
track_spans: []const sjon.Ast.Span,
key_spans: []const sjon.Ast.Span,
/// `(scene …)` windows in document order; a track's `scene` field
/// indexes here. Empty when the score declares no scenes.
scenes: []const Scene = &.{},

const TrackTable = @This();

pub fn deinit(self: *TrackTable) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Keys of one keyframe track. O(1). Asserts the track is key-sourced.
pub fn trackKeys(self: *const TrackTable, track: *const Track) []const Key {
    const ks = track.source.keys;
    std.debug.assert(ks.len >= 1);
    std.debug.assert(ks.start + ks.len <= self.keys.len);
    return self.keys[ks.start..][0..ks.len];
}

test {
    // Representation-only module; behavior is exercised through
    // `Compile` (build) and `Eval` (walk). Keep the layout caps sane.
    comptime std.debug.assert(MAX_TRACKS <= std.math.maxInt(u16));
    comptime std.debug.assert(MAX_EASE_PROGRAMS <= std.math.maxInt(u16));
    comptime std.debug.assert(MAX_CONTROLS <= std.math.maxInt(u16));
    comptime std.debug.assert(MAX_SCENES <= std.math.maxInt(u16));
    // The un-scened sentinel must never alias a real scene index.
    comptime std.debug.assert(NO_SCENE >= MAX_SCENES);
}
