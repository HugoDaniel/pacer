//! Score compiler: manifest prepend → `sjon.validateDocument` →
//! compiled `TrackTable`.
//!
//! Stage 1 (`validate`): the pacer schema manifest (`schema/pacer.sjon`,
//! `@embedFile`'d via the `pacer_schema` build import) is prepended to
//! the user source and the combined text validated in one call — no
//! filesystem, works on wasm32-freestanding (the pngine `Compiler.zig`
//! pattern). Spans in diagnostics index the COMBINED text; user
//! coordinates are recovered via `Validated.userOffset`.
//!
//! Stage 2 (`compile`): walk the validated tree once into the static
//! `TrackTable` — positions converted to i64 ticks here (beats/bars
//! exact integer products, seconds through the one documented mul+floor
//! seam), easing forms flattened + deduped into the program table,
//! targets joined by name against the caller's ordered registries.
//! After this walk keyframe tracks never touch the AST. Expr tracks
//! (`:expr`, exclusive with `(key …)` children) keep their node index
//! and are dry-run here at t = 0 via `ExprTrack.evalAt` — the same code
//! path the frame uses — so unknown bindings, type errors, and result-
//! shape defects fail at load with spans. Time-dependent failures
//! (e.g. a division that only zeroes at beat 2) are by nature beyond
//! the dry-run; the frame path omits that track's write for the frame.
//!
//! `(control …)` pins build BEFORE tracks: their ids must already be
//! bound (with document `:value`s) when the dry-run evaluates each
//! expression, so `(* radius-knob 2)` loads cleanly regardless of where
//! the control sits in the document.
//!
//! Diagnostics: pacer-level load defects (unknown target, duplicate
//! key, cap overflow, …) are `Diagnostic`s with wire-stable codes and
//! spans — collection over abort, mirroring SJON. Any error (SJON or
//! pacer) ⇒ `CompileResult.table == null`; the diagnostics are the
//! product then.

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;
const TimeMap = @import("TimeMap.zig");
const Easing = @import("Easing.zig");
const TrackTable = @import("TrackTable.zig");
const ExprTrack = @import("ExprTrack.zig");

const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;

/// The pacer score schema, embedded as a portable SJON manifest.
/// Provided as the `pacer_schema` anonymous import by build.zig.
pub const manifest_src: [:0]const u8 = @embedFile("pacer_schema");

/// Explicit error set. Validation/compile FAILURES are not errors —
/// they are diagnostics on a successfully returned result (collection
/// over abort, the SJON discipline). Only resource exhaustion is one.
pub const Error = error{OutOfMemory};

/// Maximum `(chain …)` nesting depth before flattening gives up.
pub const MAX_CHAIN_DEPTH = 4;

// ---------------------------------------------------------------------------
// Stage 1 — validate
// ---------------------------------------------------------------------------

/// Owned result of `validate`. Holds the SJON `HostResult` (tree,
/// schema, data forest, diagnostics) plus the combined manifest+source
/// text the result's spans index into.
pub const Validated = struct {
    result: sjon.Host.HostResult,
    /// Manifest + "\n\n" + user source. Diagnostic/AST spans index here.
    combined: [:0]const u8,
    /// Byte offset where user source begins inside `combined`.
    prefix_len: usize,
    gpa: Allocator,

    pub fn deinit(self: *Validated) void {
        self.result.deinit();
        self.gpa.free(self.combined);
        self.* = undefined;
    }

    /// True when any diagnostic is an error (manifest or validation).
    pub fn hasErrors(self: *const Validated) bool {
        return self.result.hasErrors();
    }

    /// Map a combined-text byte offset into user-source coordinates.
    /// Asserts the offset lies in the user region — manifest spans have
    /// no user coordinate and must be filtered first.
    pub fn userOffset(self: *const Validated, combined_offset: usize) usize {
        std.debug.assert(combined_offset >= self.prefix_len);
        std.debug.assert(combined_offset <= self.combined.len);
        return combined_offset - self.prefix_len;
    }
};

/// Validate a pacer score. Always returns a `Validated` on success of
/// the machinery itself — check `.hasErrors()` / `.result.diagnostics`
/// for the score's actual verdict. O(manifest + source).
pub fn validate(gpa: Allocator, source: [:0]const u8) Error!Validated {
    std.debug.assert(source.len + manifest_src.len + 2 <= sjon.Binary.MAX_FILE_SIZE);
    const combined = std.fmt.allocPrintSentinel(gpa, "{s}\n\n{s}", .{ manifest_src, source }, 0) catch
        return error.OutOfMemory;
    errdefer gpa.free(combined);
    const prefix_len = manifest_src.len + 2;

    const result = sjon.validateDocument(gpa, combined, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    std.debug.assert(combined.len == prefix_len + source.len);
    return .{ .result = result, .combined = combined, .prefix_len = prefix_len, .gpa = gpa };
}

/// First SJON diagnostic with the given code, or null. Test/debug
/// helper; production consumers iterate `result.diagnostics`.
pub fn findCode(v: *const Validated, code: Ast.Diagnostic.Code) ?sjon.Host.HostDiagnostic {
    for (v.result.diagnostics) |d| {
        if (d.code == code) return d;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Stage 2 — compile
// ---------------------------------------------------------------------------

/// One resolvable target, as joined from a host registry at load time.
/// `registry` is the ordered-registry index (0 = visual, 1 = audio, …)
/// and rides into `Writes.Entry.flags` for JS-side routing.
pub const Target = struct {
    name: []const u8,
    ncomp: u8,
    registry: u8 = 0,
};

/// Pacer load-diagnostic codes. Wire-stable from day one: append-only,
/// never reorder, never rename (they will cross the WASM boundary and
/// land in the driver corpus).
pub const Code = enum(u16) {
    unknown_target,
    target_arity_mismatch,
    duplicate_key_at,
    track_cap_exceeded,
    key_cap_exceeded,
    ease_cap_exceeded,
    ease_stages_exceeded,
    ease_ops_exceeded,
    ease_weights_invalid,
    ease_params_invalid,
    ease_nesting_unsupported,
    tick_overflow,
    transport_missing,
    transport_duplicate,
    transport_invalid,
    loop_requires_dur,
    track_empty,
    track_source_conflict,
    expr_eval_failed,
    expr_result_invalid,
    control_duplicate_id,
    control_cap_exceeded,
    control_invalid,
    scene_invalid,
    scene_duplicate_name,
    scene_cap_exceeded,
};

/// One pacer load diagnostic. `span` indexes the combined text (same
/// coordinate space as SJON's own diagnostics — map through
/// `Validated.userOffset` for editor display).
pub const Diagnostic = struct {
    code: Code,
    span: Ast.Span,
    message: []const u8,
};

/// Owned result of `compile`. `table` is non-null iff the score is
/// clean: no SJON validation errors and no pacer diagnostics.
///
/// The validated tree (and its schema aggregate) ride along because
/// expr tracks evaluate by node index against them every frame — the
/// table alone is self-contained only for keyframe-only scores.
/// `Eval.Evaluator` therefore borrows the WHOLE result, which must sit
/// in its final memory location first (the struct is moved by value;
/// interior pointers taken before the move would dangle).
pub const CompileResult = struct {
    validated: Validated,
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,
    table: ?TrackTable,
    /// Schema for expr-track evaluation: the CORE plugin prepended to
    /// the document's user plugins (`HostResult.schema` is user-only by
    /// design — core funcs like `sin`/`tau` would not resolve through
    /// it, and an unresolved head quietly evaluates to a form literal).
    /// Mirrors `Host.zig`'s eval-pass schema. Arena-backed slice, so it
    /// survives the by-value move of this struct.
    eval_schema: sjon.Schema.Schema,

    pub fn deinit(self: *CompileResult) void {
        if (self.table) |*tb| tb.deinit();
        self.arena.deinit();
        self.validated.deinit();
        self.* = undefined;
    }

    pub fn ok(self: *const CompileResult) bool {
        return self.table != null;
    }

    /// First pacer diagnostic with the given code, or null. Test helper.
    pub fn findDiag(self: *const CompileResult, code: Code) ?Diagnostic {
        for (self.diagnostics) |d| {
            if (d.code == code) return d;
        }
        return null;
    }

    /// Live tempo nudge (`drv_setBpm`): rebuild the seconds↔ticks
    /// projection at the new tempo. A live `Eval.Evaluator` borrowing
    /// this result picks the change up on its next eval. Musical
    /// positions are ticks and stay put — including positions authored
    /// in `s`, which were converted at load with the load-time tempo
    /// (the standard tempo-nudge semantic). False (no change) when no
    /// table is loaded or bpm is outside the manifest's 1..1000 bounds.
    pub fn setBpm(self: *CompileResult, bpm: f64) bool {
        if (!std.math.isFinite(bpm) or bpm < 1 or bpm > 1000) return false;
        const tb = if (self.table) |*tb| tb else return false;
        tb.transport.map = TimeMap.init(bpm, tb.transport.map.beats_per_bar);
        return true;
    }
};

/// Compile a score against the host registries. The frame path needs
/// nothing else afterwards — `CompileResult.table` is self-contained.
pub fn compile(gpa: Allocator, source: [:0]const u8, targets: []const Target) Error!CompileResult {
    var v = try validate(gpa, source);
    errdefer v.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    const user_plugins = v.result.schema.plugins;
    const eval_plugins = arena.allocator().alloc(sjon.Plugin.Plugin, user_plugins.len + 1) catch
        return error.OutOfMemory;
    eval_plugins[0] = sjon.plugins.core.plugin;
    @memcpy(eval_plugins[1..], user_plugins);
    const eval_schema: sjon.Schema.Schema = .{ .plugins = eval_plugins };

    var builder: Builder = .{
        .gpa = gpa,
        .arena = arena.allocator(),
        .tree = &v.result.tree,
        .forest = v.result.data_forest,
        .schema = eval_schema,
        .targets = targets,
        .diags = .empty,
    };

    var table: ?TrackTable = null;
    if (!v.hasErrors()) {
        table = try builder.build();
    }

    return .{
        .validated = v,
        .arena = arena,
        .diagnostics = builder.diags.items,
        .table = table,
        .eval_schema = eval_schema,
    };
}

/// Tree→table walk state. Lives only inside `compile`.
const Builder = struct {
    gpa: Allocator,
    arena: Allocator,
    tree: *const Ast.Tree,
    /// Top-level validated data forms (`HostResult.data_forest`).
    forest: []const NodeIndex,
    /// Core-prepended eval schema (`CompileResult.eval_schema`) —
    /// resolves the expr-func vocabulary for the expr-track dry-run.
    schema: sjon.Schema.Schema,
    targets: []const Target,
    diags: std.ArrayList(Diagnostic),

    /// Program table under construction. `[0]` is the shared linear
    /// default; `intern` dedups against the live prefix.
    programs: [TrackTable.MAX_EASE_PROGRAMS]Easing.Program = undefined,
    programs_len: usize = 0,

    /// Control bindings for the expr dry-run (document `:value`s),
    /// filled by `buildControls` before any track builds. Names alias
    /// the table arena.
    ctl_bindings: [TrackTable.MAX_CONTROLS]ExprTrack.ControlBinding = undefined,
    ctl_count: usize = 0,

    /// Short-circuit signal for easing subtrees: the diagnostic was
    /// already emitted at the offending node; callers fall back to the
    /// linear program and keep collecting.
    const EaseFail = error{ EaseInvalid, OutOfMemory };

    fn emit(self: *Builder, code: Code, span: Ast.Span, comptime fmt: []const u8, args: anytype) Error!void {
        const message = std.fmt.allocPrint(self.arena, fmt, args) catch return error.OutOfMemory;
        self.diags.append(self.arena, .{ .code = code, .span = span, .message = message }) catch
            return error.OutOfMemory;
    }

    /// Build the table, or null when defects were found (diagnostics
    /// carry the details). Allocation failure is the only error.
    fn build(self: *Builder) Error!?TrackTable {
        var table_arena = std.heap.ArenaAllocator.init(self.gpa);
        errdefer table_arena.deinit();
        const ta = table_arena.allocator();

        const before_diags = self.diags.items.len;
        self.programs[0] = Easing.primitive(.{ .code = .linear }) catch unreachable;
        self.programs_len = 1;

        const transport = try self.buildTransport(ta) orelse {
            table_arena.deinit();
            return null;
        };

        // Controls first: the track dry-run needs their ids bound.
        var controls: std.ArrayList(TrackTable.Control) = .empty;
        try self.buildControls(ta, &controls);

        var tracks: std.ArrayList(TrackTable.Track) = .empty;
        var keys: std.ArrayList(TrackTable.Key) = .empty;
        var track_spans: std.ArrayList(Ast.Span) = .empty;
        var key_spans: std.ArrayList(Ast.Span) = .empty;
        try self.buildTracks(ta, &transport, &tracks, &keys, &track_spans, &key_spans);

        // Scenes: validate each `(scene …)` (presence, uniqueness, cap)
        // and walk its child tracks scene-relative into the SAME arrays,
        // scene start folded into every key tick. Any defect nulls the
        // table via the diag-count gate below.
        var scenes: std.ArrayList(TrackTable.Scene) = .empty;
        try self.buildScenes(ta, &transport, &scenes, &tracks, &keys, &track_spans, &key_spans);

        std.debug.assert(track_spans.items.len == tracks.items.len);
        std.debug.assert(key_spans.items.len == keys.items.len);

        if (self.diags.items.len != before_diags) {
            table_arena.deinit();
            return null;
        }

        const programs = ta.dupe(Easing.Program, self.programs[0..self.programs_len]) catch
            return error.OutOfMemory;
        return .{
            .arena = table_arena,
            .transport = transport,
            .tracks = tracks.items,
            .keys = keys.items,
            .programs = programs,
            .controls = controls.items,
            .track_spans = track_spans.items,
            .key_spans = key_spans.items,
            .scenes = scenes.items,
        };
    }

    fn buildControls(self: *Builder, ta: Allocator, controls: *std.ArrayList(TrackTable.Control)) Error!void {
        const tree = self.tree;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "control")) continue;
            if (controls.items.len == TrackTable.MAX_CONTROLS) {
                try self.emit(.control_cap_exceeded, tree.spanOf(idx), "more than {d} controls", .{TrackTable.MAX_CONTROLS});
                return;
            }
            if (try self.buildControl(ta, idx, controls.items)) |ctl| {
                self.ctl_bindings[controls.items.len] = ExprTrack.ControlBinding.fromControl(ctl);
                controls.append(ta, ctl) catch return error.OutOfMemory;
                self.ctl_count = controls.items.len;
            }
        }
    }

    /// Build one `(control …)` pin, or null after emitting a diagnostic.
    fn buildControl(self: *Builder, ta: Allocator, idx: NodeIndex, existing: []const TrackTable.Control) Error!?TrackTable.Control {
        const tree = self.tree;
        const children = tree.formHeader(idx).children;

        const id_node = kvNode(tree, children, "id").?;
        const id = tree.symbolText(id_node);
        for (ExprTrack.reserved_names) |reserved| {
            if (std.mem.eql(u8, id, reserved)) {
                try self.emit(.control_invalid, tree.spanOf(id_node), "control id `{s}` shadows a reserved time binding", .{id});
                return null;
            }
        }
        for (existing) |c| {
            if (std.mem.eql(u8, c.id, id)) {
                try self.emit(.control_duplicate_id, tree.spanOf(id_node), "duplicate control id `{s}`", .{id});
                return null;
            }
        }

        const value_node = kvNode(tree, children, "value").?;
        const val = readValueVec(tree, value_node);

        var target: ?TrackTable.ControlTarget = null;
        if (kvNode(tree, children, "target")) |target_node| {
            const name = tree.symbolText(target_node);
            const tg = self.resolveTarget(name) orelse {
                try self.emit(.unknown_target, tree.spanOf(target_node), "unknown target `{s}` — not in any host registry", .{name});
                return null;
            };
            if (val.ncomp != tg.ncomp) {
                try self.emit(.target_arity_mismatch, tree.spanOf(value_node), "value has {d} component(s); target expects {d}", .{ val.ncomp, tg.ncomp });
                return null;
            }
            target = .{ .id = tg.id, .registry = tg.registry };
        }

        var kind: TrackTable.ControlType = .slider;
        if (kvNode(tree, children, "type")) |type_node| {
            // Member-set-validated symbol; the names match the enum.
            kind = std.meta.stringToEnum(TrackTable.ControlType, tree.symbolText(type_node)).?;
        }

        var bounds_ok = true;
        const min = try self.readBound(children, "min", val.ncomp, &bounds_ok);
        const max = try self.readBound(children, "max", val.ncomp, &bounds_ok);
        if (!bounds_ok) return null;

        return .{
            .id = ta.dupe(u8, id) catch return error.OutOfMemory,
            .target = target,
            .ncomp = val.ncomp,
            .kind = kind,
            .value = val.value,
            .min = min,
            .max = max,
            .value_span = tree.spanOf(value_node),
        };
    }

    /// Read an optional `:min`/`:max` widget bound; its arity must match
    /// `:value`'s (emits `control_invalid` and flips `ok` otherwise).
    fn readBound(self: *Builder, children: []const NodeIndex, key: []const u8, want_ncomp: u8, ok: *bool) Error!?[4]f32 {
        const node = kvNode(self.tree, children, key) orelse return null;
        const b = readValueVec(self.tree, node);
        if (b.ncomp != want_ncomp) {
            try self.emit(.control_invalid, self.tree.spanOf(node), ":{s} has {d} component(s); :value has {d}", .{ key, b.ncomp, want_ncomp });
            ok.* = false;
            return null;
        }
        return b.value;
    }

    fn buildTransport(self: *Builder, ta: Allocator) Error!?TrackTable.Transport {
        const tree = self.tree;
        var found: ?NodeIndex = null;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "transport")) continue;
            if (found != null) {
                try self.emit(.transport_duplicate, tree.spanOf(idx), "more than one (transport …) form", .{});
                continue;
            }
            found = idx;
        }
        const idx = found orelse {
            try self.emit(.transport_missing, .{ .start = 0, .end = 0 }, "score has no (transport …) form", .{});
            return null;
        };
        const children = tree.formHeader(idx).children;

        // :bpm is required and typed by the manifest; the hasErrors gate
        // guarantees presence + shape here.
        const bpm = readNumber(tree, kvNode(tree, children, "bpm").?).?;

        var beats_per_bar: i64 = 4;
        if (kvNode(tree, children, "meter")) |meter_node| {
            const elems = tree.vectorElements(meter_node);
            std.debug.assert(elems.len == 2); // vector-shape :len 2
            beats_per_bar = @intFromFloat(readNumber(tree, elems[0]).?);
        }
        const map = TimeMap.init(bpm, beats_per_bar);

        var dur: ?TrackTable.Tick = null;
        if (kvNode(tree, children, "dur")) |dur_node| {
            if (try self.posToTick(&map, dur_node)) |ticks| {
                if (ticks <= 0) {
                    try self.emit(.transport_invalid, tree.spanOf(dur_node), ":dur must be positive", .{});
                } else {
                    dur = ticks;
                }
            }
        }

        var end: TrackTable.EndBehavior = .hold;
        if (kvNode(tree, children, "end")) |end_node| {
            const text = tree.symbolText(end_node);
            end = if (std.mem.eql(u8, text, "loop")) .loop else .hold;
        }
        if (end == .loop and dur == null) {
            try self.emit(.loop_requires_dur, tree.spanOf(idx), ":end loop requires :dur", .{});
        }

        var emit_lanes: []const TrackTable.EmitLane = &.{};
        if (kvNode(tree, children, "emit")) |emit_node| {
            emit_lanes = try self.buildEmit(ta, emit_node);
        }

        return .{ .map = map, .dur = dur, .end = end, .emit = emit_lanes };
    }

    /// Resolve a `(transport :emit …)` list into clock lanes. Each entry
    /// must name an emittable time value (`TrackTable.EmitName`), be
    /// unique in the list, and join to a scalar host target of the same
    /// name — every failure emits at the offending entry's span and the
    /// lane is dropped (the table is discarded whole once any diagnostic
    /// exists). Returns the lanes that were sound.
    fn buildEmit(self: *Builder, ta: Allocator, emit_node: NodeIndex) Error![]const TrackTable.EmitLane {
        const tree = self.tree;
        const elems = tree.vectorElements(emit_node);
        var lanes: std.ArrayList(TrackTable.EmitLane) = .empty;
        for (elems, 0..) |elem, i| {
            const name = tree.symbolText(elem);
            const which = std.meta.stringToEnum(TrackTable.EmitName, name) orelse {
                try self.emit(.transport_invalid, tree.spanOf(elem), ":emit `{s}` is not an emittable time name (beat, bar, phase, bpm, t)", .{name});
                continue;
            };
            if (duplicateBefore(tree, elems[0..i], name)) {
                try self.emit(.transport_invalid, tree.spanOf(elem), "duplicate :emit lane `{s}`", .{name});
                continue;
            }
            const tg = self.resolveTarget(name) orelse {
                try self.emit(.unknown_target, tree.spanOf(elem), "unknown target `{s}` — not in any host registry", .{name});
                continue;
            };
            if (tg.ncomp != 1) {
                try self.emit(.target_arity_mismatch, tree.spanOf(elem), "emitted lane `{s}` needs a scalar target; `{s}` has {d} component(s)", .{ name, name, tg.ncomp });
                continue;
            }
            lanes.append(ta, .{ .name = which, .target_id = tg.id, .registry = tg.registry }) catch
                return error.OutOfMemory;
        }
        return lanes.items;
    }

    fn buildTracks(
        self: *Builder,
        ta: Allocator,
        transport: *const TrackTable.Transport,
        tracks: *std.ArrayList(TrackTable.Track),
        keys: *std.ArrayList(TrackTable.Key),
        track_spans: *std.ArrayList(Ast.Span),
        key_spans: *std.ArrayList(Ast.Span),
    ) Error!void {
        const tree = self.tree;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "track")) continue;
            if (tracks.items.len == TrackTable.MAX_TRACKS) {
                try self.emit(.track_cap_exceeded, tree.spanOf(idx), "more than {d} tracks", .{TrackTable.MAX_TRACKS});
                return;
            }
            // Top-level tracks: no scene offset, no owning scene.
            if (!try self.buildTrackForm(ta, transport, idx, 0, TrackTable.NO_SCENE, tracks, keys, track_spans, key_spans)) return;
        }
    }

    /// Build one `(track …)` form into the table. `offset` is added to
    /// every key tick (0 for a top-level track, the owning scene's start
    /// tick otherwise) with a checked add; `scene` is the owning scene's
    /// index or `NO_SCENE`. Returns false only when a key-cap forced the
    /// whole walk to stop; every per-track defect emits at its span and
    /// returns true (skip this track, keep collecting). The caller checks
    /// the track cap first — it depends on the running table count.
    fn buildTrackForm(
        self: *Builder,
        ta: Allocator,
        transport: *const TrackTable.Transport,
        idx: NodeIndex,
        offset: TrackTable.Tick,
        scene: u16,
        tracks: *std.ArrayList(TrackTable.Track),
        keys: *std.ArrayList(TrackTable.Key),
        track_spans: *std.ArrayList(Ast.Span),
        key_spans: *std.ArrayList(Ast.Span),
    ) Error!bool {
        const tree = self.tree;
        const map = &transport.map;
        const hdr = tree.formHeader(idx);

        const target_node = kvNode(tree, hdr.children, "target").?;
        const target_name = tree.symbolText(target_node);
        const target = self.resolveTarget(target_name) orelse {
            try self.emit(.unknown_target, tree.spanOf(target_node), "unknown target `{s}` — not in any host registry", .{target_name});
            return true;
        };

        if (kvNode(tree, hdr.children, "expr")) |expr_node| {
            if (firstKeyChild(tree, hdr.children) != null) {
                try self.emit(.track_source_conflict, tree.spanOf(expr_node), "track `{s}` has both (key …) children and :expr — exactly one value source", .{target_name});
                return true;
            }
            if (try self.dryRunExpr(transport, expr_node, target.ncomp)) {
                tracks.append(ta, .{
                    .target_id = target.id,
                    .registry = target.registry,
                    .ncomp = target.ncomp,
                    .source = .{ .expr = expr_node },
                    .scene = scene,
                }) catch return error.OutOfMemory;
                track_spans.append(ta, tree.spanOf(idx)) catch return error.OutOfMemory;
            }
            return true;
        }

        const keys_start: u32 = @intCast(keys.items.len);
        for (hdr.children) |child| {
            if (tree.tagOf(child) != .form) continue;
            std.debug.assert(std.mem.eql(u8, tree.formHeader(child).head, "key"));
            if (keys.items.len == TrackTable.MAX_KEYS) {
                try self.emit(.key_cap_exceeded, tree.spanOf(child), "more than {d} keys", .{TrackTable.MAX_KEYS});
                return false;
            }
            if (try self.buildKey(map, child, target.ncomp, offset)) |k| {
                keys.append(ta, k) catch return error.OutOfMemory;
                key_spans.append(ta, tree.spanOf(child)) catch return error.OutOfMemory;
            }
        }
        const track_keys = keys.items[keys_start..];
        const track_key_spans = key_spans.items[keys_start..];
        if (track_keys.len == 0) {
            try self.emit(.track_empty, tree.spanOf(idx), "track `{s}` has no value source — give it (key …) children or :expr", .{target_name});
            return true;
        }

        // Author order is free; the table is sorted. Equal ticks are
        // a defect (which value wins would be source-order luck).
        sortKeysWithSpans(track_keys, track_key_spans);
        for (track_keys[1..], 0..) |k, i| {
            if (k.at == track_keys[i].at) {
                try self.emit(.duplicate_key_at, track_key_spans[i + 1], "duplicate key at the same tick ({d})", .{k.at});
            }
        }

        tracks.append(ta, .{
            .target_id = target.id,
            .registry = target.registry,
            .ncomp = target.ncomp,
            .source = .{ .keys = .{ .start = keys_start, .len = @intCast(track_keys.len) } },
            .scene = scene,
        }) catch return error.OutOfMemory;
        track_spans.append(ta, tree.spanOf(idx)) catch return error.OutOfMemory;
        return true;
    }

    /// Validate every top-level `(scene …)` and compile its children into
    /// the table. Shape checks: presence of the schema-optional
    /// `:name`/`:at`/`:dur` (missing any → `scene_invalid`), name
    /// uniqueness (`scene_duplicate_name`), and the `MAX_SCENES` cap. A
    /// sound scene records its window in `scenes`; its child `(track …)`
    /// forms are walked scene-relative — each key tick offset by the
    /// scene start (overflow → `tick_overflow`) — carrying the scene
    /// index. Any diagnostic nulls the table via the caller's diag gate.
    fn buildScenes(
        self: *Builder,
        ta: Allocator,
        transport: *const TrackTable.Transport,
        scenes: *std.ArrayList(TrackTable.Scene),
        tracks: *std.ArrayList(TrackTable.Track),
        keys: *std.ArrayList(TrackTable.Key),
        track_spans: *std.ArrayList(Ast.Span),
        key_spans: *std.ArrayList(Ast.Span),
    ) Error!void {
        const tree = self.tree;
        const map = &transport.map;
        var seen: std.ArrayList([]const u8) = .empty;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "scene")) continue;
            if (scenes.items.len == TrackTable.MAX_SCENES) {
                try self.emit(.scene_cap_exceeded, tree.spanOf(idx), "more than {d} scenes", .{TrackTable.MAX_SCENES});
                return;
            }

            const children = tree.formHeader(idx).children;
            const name_node = kvNode(tree, children, "name");
            const at_node = kvNode(tree, children, "at");
            const dur_node = kvNode(tree, children, "dur");
            if (name_node == null or at_node == null or dur_node == null) {
                try self.emit(.scene_invalid, tree.spanOf(idx), "scene requires :name, :at, and :dur", .{});
                continue;
            }

            const name = tree.symbolText(name_node.?);
            for (seen.items) |prev| {
                if (std.mem.eql(u8, prev, name)) {
                    try self.emit(.scene_duplicate_name, tree.spanOf(name_node.?), "duplicate scene name `{s}`", .{name});
                    break;
                }
            } else {
                seen.append(self.arena, name) catch return error.OutOfMemory;
            }

            // Window on the tick grid; overflow of either bound skips the
            // scene (tick_overflow was emitted; the table is doomed).
            const start_tick = try self.posToTick(map, at_node.?) orelse continue;
            const dur_ticks = try self.posToTick(map, dur_node.?) orelse continue;

            const scene_index: u16 = @intCast(scenes.items.len);
            scenes.append(ta, .{
                .name_span = tree.spanOf(name_node.?),
                .start_tick = start_tick,
                .dur_ticks = dur_ticks,
            }) catch return error.OutOfMemory;

            // Child tracks resolve scene-relative (offset = scene start).
            for (children) |child| {
                if (!isForm(tree, child, "track")) continue;
                if (tracks.items.len == TrackTable.MAX_TRACKS) {
                    try self.emit(.track_cap_exceeded, tree.spanOf(child), "more than {d} tracks", .{TrackTable.MAX_TRACKS});
                    return;
                }
                if (!try self.buildTrackForm(ta, transport, child, start_tick, scene_index, tracks, keys, track_spans, key_spans)) return;
            }
        }
    }

    /// Dry-run an expr track at t = 0 through the SAME code path the
    /// frame uses (`ExprTrack.evalAt`), so load-time acceptance and
    /// frame semantics cannot drift. Control ids are bound with their
    /// document `:value`s. True = the track is sound at t = 0; false = a
    /// diagnostic was emitted at the expression's span.
    fn dryRunExpr(self: *Builder, transport: *const TrackTable.Transport, expr_node: NodeIndex, ncomp: u8) Error!bool {
        const controls = self.ctl_bindings[0..self.ctl_count];
        _ = ExprTrack.evalAt(self.gpa, self.tree, self.schema, transport, controls, expr_node, 0, ncomp) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResultShape => {
                // A misspelled function name lands here too: a head
                // that resolves to no expr-func evaluates to a form
                // LITERAL (Expr's form-construction semantics), which
                // then fails the shape contract — hence the hint.
                try self.emit(.expr_result_invalid, self.tree.spanOf(expr_node), "expression must yield a finite number or a finite {d}-component numeric vector (a form result usually means a misspelled function name)", .{ncomp});
                return false;
            },
            else => {
                try self.emit(.expr_eval_failed, self.tree.spanOf(expr_node), "expression failed to evaluate at t=0: {s}", .{@errorName(err)});
                return false;
            },
        };
        return true;
    }

    fn buildKey(self: *Builder, map: *const TimeMap, key_form: NodeIndex, want_ncomp: u8, offset: TrackTable.Tick) Error!?TrackTable.Key {
        const tree = self.tree;
        const children = tree.formHeader(key_form).children;

        const at_node = kvNode(tree, children, "at").?;
        const local = try self.posToTick(map, at_node) orelse return null;
        // Scene start folds in here (offset 0 for a top-level track can
        // never overflow — `local` is already a valid grid position).
        const at = std.math.add(TrackTable.Tick, local, offset) catch {
            try self.emit(.tick_overflow, tree.spanOf(at_node), "scene-relative position overflows the tick grid", .{});
            return null;
        };

        const value_node = kvNode(tree, children, "value").?;
        const val = readValueVec(tree, value_node);
        if (val.ncomp != want_ncomp) {
            try self.emit(.target_arity_mismatch, tree.spanOf(value_node), "value has {d} component(s); target expects {d}", .{ val.ncomp, want_ncomp });
            return null;
        }

        var ease_ref: u16 = 0; // linear default
        if (kvNode(tree, children, "ease")) |ease_node| {
            ease_ref = try self.buildEase(ease_node);
        }
        return .{ .at = at, .value = val.value, .ease_ref = ease_ref };
    }

    /// `:at` / `:dur` → ticks. Unit set is manifest-validated [b bar s].
    /// Returns null after emitting on overflow (non-finite literals
    /// cannot reach here — the lexer owns number syntax).
    fn posToTick(self: *Builder, map: *const TimeMap, node: NodeIndex) Error!?TrackTable.Tick {
        const nu = self.tree.numberWithUnitOf(node);
        const converted = if (std.mem.eql(u8, nu.unit, "b"))
            map.tickFromBeats(nu.value)
        else if (std.mem.eql(u8, nu.unit, "bar"))
            map.tickFromBars(nu.value)
        else blk: {
            std.debug.assert(std.mem.eql(u8, nu.unit, "s"));
            break :blk map.tickFromSeconds(nu.value);
        };
        return converted catch {
            try self.emit(.tick_overflow, self.tree.spanOf(node), "position overflows the tick grid", .{});
            return null;
        };
    }

    // ---- easing subtrees ----

    /// Compile one `:ease` value to a program-table ref. Defects emit a
    /// diagnostic at the offending node and fall back to linear so the
    /// walk keeps collecting (the table is discarded at the end anyway).
    fn buildEase(self: *Builder, node: NodeIndex) Error!u16 {
        const prog = self.compileEaseNode(node) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.EaseInvalid => return 0,
        };
        return self.intern(prog, node);
    }

    fn compileEaseNode(self: *Builder, node: NodeIndex) EaseFail!Easing.Program {
        const tree = self.tree;
        if (tree.tagOf(node) == .symbol) {
            var ops: [Easing.MAX_OPS]Easing.OpSpec = undefined;
            const n = try self.resolveOps(node, &ops, 0, 0);
            return self.runEasing(Easing.chainOf(ops[0..n]), node);
        }
        const hdr = tree.formHeader(node);
        if (std.mem.eql(u8, hdr.head, "seq")) {
            var stages: [Easing.MAX_STAGES]Easing.StageSpec = undefined;
            var ops_bufs: [Easing.MAX_STAGES][Easing.MAX_OPS]Easing.OpSpec = undefined;
            var len: usize = 0;
            for (hdr.children) |child| {
                if (tree.tagOf(child) != .form) continue;
                std.debug.assert(std.mem.eql(u8, tree.formHeader(child).head, "stage"));
                if (len == Easing.MAX_STAGES) {
                    try self.emit(.ease_stages_exceeded, tree.spanOf(node), "more than {d} stages", .{Easing.MAX_STAGES});
                    return error.EaseInvalid;
                }
                const stage_children = tree.formHeader(child).children;
                const ease_node = kvNode(tree, stage_children, "ease").?;
                const ops_n = try self.resolveOps(ease_node, &ops_bufs[len], 0, 0);
                stages[len] = .{
                    .t = readNumber(tree, kvNode(tree, stage_children, "t").?).?,
                    .v = readNumber(tree, kvNode(tree, stage_children, "v").?).?,
                    .ops = ops_bufs[len][0..ops_n],
                };
                len += 1;
            }
            return self.runEasing(Easing.seqOf(stages[0..len]), node);
        }
        // chain / steps / cubic-bezier / spring: one stage, flattened ops.
        var ops: [Easing.MAX_OPS]Easing.OpSpec = undefined;
        const n = try self.resolveOps(node, &ops, 0, 0);
        return self.runEasing(Easing.chainOf(ops[0..n]), node);
    }

    /// Flatten one ease-spec node (symbol or form) into `buf[len..]`.
    /// Returns the new length. `(chain …)` recurses (depth-capped);
    /// `(seq …)` is rejected here — piecewise programs cannot nest
    /// inside op chains (the representation is deliberately flat).
    fn resolveOps(self: *Builder, node: NodeIndex, buf: *[Easing.MAX_OPS]Easing.OpSpec, len: usize, depth: usize) EaseFail!usize {
        const tree = self.tree;
        const span = tree.spanOf(node);
        if (tree.tagOf(node) == .symbol) {
            const code = Easing.op_names.get(tree.symbolText(node)) orelse {
                try self.emit(.ease_params_invalid, span, "unknown easing `{s}`", .{tree.symbolText(node)});
                return error.EaseInvalid;
            };
            return self.pushOp(buf, len, .{ .code = code }, span);
        }
        const hdr = tree.formHeader(node);
        const head = hdr.head;
        if (std.mem.eql(u8, head, "chain")) {
            if (depth == MAX_CHAIN_DEPTH) {
                try self.emit(.ease_nesting_unsupported, span, "(chain …) nested deeper than {d}", .{MAX_CHAIN_DEPTH});
                return error.EaseInvalid;
            }
            var n = len;
            for (hdr.children) |child| {
                if (tree.tagOf(child) == .kvpair) continue;
                n = try self.resolveOps(child, buf, n, depth + 1);
            }
            return n;
        }
        if (std.mem.eql(u8, head, "seq")) {
            try self.emit(.ease_nesting_unsupported, span, "(seq …) cannot nest inside another easing", .{});
            return error.EaseInvalid;
        }
        if (std.mem.eql(u8, head, "steps")) {
            const n_val = readNumber(tree, kvNode(tree, hdr.children, "n").?).?;
            var code: Easing.Op = .steps_end;
            if (kvNode(tree, hdr.children, "jump")) |jn| {
                if (std.mem.eql(u8, tree.symbolText(jn), "start")) code = .steps_start;
            }
            return self.pushOp(buf, len, .{ .code = code, .params = .{ n_val, 0, 0, 0 } }, span);
        }
        if (std.mem.eql(u8, head, "cubic-bezier")) {
            const elems = tree.vectorElements(kvNode(tree, hdr.children, "p").?);
            std.debug.assert(elems.len == 4); // vector-shape :len 4
            return self.pushOp(buf, len, .{ .code = .cubic_bezier, .params = .{
                readNumber(tree, elems[0]).?,
                readNumber(tree, elems[1]).?,
                readNumber(tree, elems[2]).?,
                readNumber(tree, elems[3]).?,
            } }, span);
        }
        std.debug.assert(std.mem.eql(u8, head, "spring")); // head-set closed
        const damping = readNumber(tree, kvNode(tree, hdr.children, "damping").?).?;
        const periods = if (kvNode(tree, hdr.children, "periods")) |pn| readNumber(tree, pn).? else 3;
        return self.pushOp(buf, len, .{ .code = .spring, .params = .{ damping, periods, 0, 0 } }, span);
    }

    fn pushOp(self: *Builder, buf: *[Easing.MAX_OPS]Easing.OpSpec, len: usize, spec: Easing.OpSpec, span: Ast.Span) EaseFail!usize {
        if (len == Easing.MAX_OPS) {
            try self.emit(.ease_ops_exceeded, span, "more than {d} chained easing ops", .{Easing.MAX_OPS});
            return error.EaseInvalid;
        }
        buf[len] = spec;
        return len + 1;
    }

    /// Map an `Easing` builder result to diagnostics at `node`.
    fn runEasing(self: *Builder, result: Easing.Error!Easing.Program, node: NodeIndex) EaseFail!Easing.Program {
        const span = self.tree.spanOf(node);
        return result catch |err| {
            switch (err) {
                error.EaseStagesExceeded => try self.emit(.ease_stages_exceeded, span, "easing stage cap exceeded", .{}),
                error.EaseOpsExceeded => try self.emit(.ease_ops_exceeded, span, "easing op cap exceeded", .{}),
                error.EaseWeightsInvalid => try self.emit(.ease_weights_invalid, span, "stage weights cannot be normalized (zero :t, zero Σ:v, or extreme skew)", .{}),
                error.EaseParamsInvalid => try self.emit(.ease_params_invalid, span, "easing parameter outside its domain", .{}),
            }
            return error.EaseInvalid;
        };
    }

    /// Dedup-append into the program table.
    fn intern(self: *Builder, prog: Easing.Program, node: NodeIndex) Error!u16 {
        for (self.programs[0..self.programs_len], 0..) |p, i| {
            if (std.meta.eql(p, prog)) return @intCast(i);
        }
        if (self.programs_len == TrackTable.MAX_EASE_PROGRAMS) {
            try self.emit(.ease_cap_exceeded, self.tree.spanOf(node), "more than {d} distinct easing programs", .{TrackTable.MAX_EASE_PROGRAMS});
            return 0;
        }
        self.programs[self.programs_len] = prog;
        self.programs_len += 1;
        return @intCast(self.programs_len - 1);
    }

    fn resolveTarget(self: *Builder, name: []const u8) ?struct { id: u16, ncomp: u8, registry: u8 } {
        for (self.targets, 0..) |tg, i| {
            if (std.mem.eql(u8, tg.name, name)) {
                return .{ .id = @intCast(i), .ncomp = tg.ncomp, .registry = tg.registry };
            }
        }
        return null;
    }

};

/// Sort a track's keys (and their parallel source spans) by tick.
/// Insertion sort: key counts are small and mostly pre-sorted.
fn sortKeysWithSpans(keys: []TrackTable.Key, spans: []Ast.Span) void {
    std.debug.assert(keys.len == spans.len);
    var i: usize = 1;
    while (i < keys.len) : (i += 1) {
        const k = keys[i];
        const s = spans[i];
        var j = i;
        while (j > 0 and keys[j - 1].at > k.at) : (j -= 1) {
            keys[j] = keys[j - 1];
            spans[j] = spans[j - 1];
        }
        keys[j] = k;
        spans[j] = s;
    }
}

/// True when `idx` is a form whose head text-matches `head`. The data
/// forest may hold stray top-level atoms (a fuzz surface) — those are
/// not forms, so the tag guard comes first.
fn isForm(tree: *const Ast.Tree, idx: NodeIndex, head: []const u8) bool {
    return tree.tagOf(idx) == .form and std.mem.eql(u8, tree.formHeader(idx).head, head);
}

/// True when some earlier `:emit` entry carries the same symbol text —
/// the duplicate-lane test. All entries are schema-guaranteed symbols.
fn duplicateBefore(tree: *const Ast.Tree, before: []const NodeIndex, name: []const u8) bool {
    for (before) |prev| {
        if (std.mem.eql(u8, tree.symbolText(prev), name)) return true;
    }
    return false;
}

/// First `(key …)` positional child of a track, or null. The manifest's
/// `:positional key-section` guarantees form children ARE key forms.
fn firstKeyChild(tree: *const Ast.Tree, children: []const NodeIndex) ?NodeIndex {
    for (children) |c| {
        if (tree.tagOf(c) == .form) return c;
    }
    return null;
}

/// Find a kvpair child by key name. O(children).
fn kvNode(tree: *const Ast.Tree, children: []const NodeIndex, key: []const u8) ?NodeIndex {
    for (children) |c| {
        if (tree.tagOf(c) != .kvpair) continue;
        const kv = tree.kvpairHeader(c);
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// Read a `key-value` slot (scalar or 1-4 component vector) into a
/// zero-padded `[4]f32` + live component count. Shape is manifest-
/// guaranteed (`key-value` union), hence the asserts.
fn readValueVec(tree: *const Ast.Tree, node: NodeIndex) struct { value: [4]f32, ncomp: u8 } {
    var value: [4]f32 = .{ 0, 0, 0, 0 };
    var ncomp: u8 = 1;
    if (tree.tagOf(node) == .vector) {
        const elems = tree.vectorElements(node);
        std.debug.assert(elems.len >= 1 and elems.len <= 4); // vector-shape
        ncomp = @intCast(elems.len);
        for (elems, 0..) |e, i| value[i] = @floatCast(readNumber(tree, e).?);
    } else {
        value[0] = @floatCast(readNumber(tree, node).?);
    }
    return .{ .value = value, .ncomp = ncomp };
}

/// Read any plain numeric literal as f64. Returns null for non-number
/// tags (callers gated by the validator treat that as unreachable).
fn readNumber(tree: *const Ast.Tree, idx: NodeIndex) ?f64 {
    return switch (tree.tagOf(idx)) {
        .number => tree.numberOf(idx),
        .number_i64 => @floatFromInt(tree.numberI64Of(idx)),
        .number_u64 => @floatFromInt(tree.numberU64Of(idx)),
        else => null,
    };
}

// ---------------------------------------------------------------------------
// Tests — stage 1
// ---------------------------------------------------------------------------

const t = std.testing;

const minimal_score: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 16bar :end loop)
    \\(track :target circle-radius
    \\  (key :at 0b :value 0.2)
    \\  (key :at 4b :value 0.8 :ease out-cubic)
    \\  (key :at 8b :value 0.2 :ease smoothstep))
;

test "minimal score validates clean" {
    var v = try validate(t.allocator, minimal_score);
    defer v.deinit();
    for (v.result.diagnostics) |d| {
        std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    }
    try t.expect(!v.hasErrors());
}

test "composed easing program validates clean" {
    var v = try validate(t.allocator,
        \\(transport :bpm 90)
        \\(track :target logo-y
        \\  (key :at 0b :value 0.0)
        \\  (key :at 2b :value 1.0
        \\    :ease (seq (stage :ease out-cubic   :t 0.4  :v 1.15)
        \\               (stage :ease in-out-quad :t 0.35 :v -0.18)
        \\               (stage :ease (spring :damping 0.5 :periods 2) :t 0.25 :v 0.03))))
        \\(track :target tint
        \\  (key :at 0b :value [1 0 0])
        \\  (key :at 1bar :value [0 0 1] :ease (chain (cubic-bezier :p [0.4 0 0.2 1]) (steps :n 4 :jump end))))
    );
    defer v.deinit();
    try t.expect(!v.hasErrors());
}

test "bare number in a position slot is rejected (unit required)" {
    var v = try validate(t.allocator,
        \\(transport :bpm 120)
        \\(track :target x (key :at 4 :value 0.5))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
    try t.expect(findCode(&v, .unit_required) != null);
}

test "wrong unit on a position slot is rejected" {
    var v = try validate(t.allocator,
        \\(transport :bpm 120)
        \\(track :target x (key :at 4ms :value 0.5))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "unknown easing name is rejected" {
    var v = try validate(t.allocator,
        \\(transport :bpm 120)
        \\(track :target x
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1 :ease bouncy-magic))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "unknown form head is rejected" {
    var v = try validate(t.allocator, "(timeline :bpm 120)");
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "diagnostic spans map back into user source" {
    const bad_source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target x (key :at 4 :value 0.5))
    ;
    var v = try validate(t.allocator, bad_source);
    defer v.deinit();
    const d = findCode(&v, .unit_required).?;
    const user_start = v.userOffset(d.span.start);
    // The offending literal `4` sits inside the user text.
    try t.expectEqualStrings("4", bad_source[user_start .. user_start + 1]);
}

test "empty source validates clean (no data forms, no diagnostics)" {
    var v = try validate(t.allocator, "");
    defer v.deinit();
    try t.expect(!v.hasErrors());
}

// ---------------------------------------------------------------------------
// Tests — stage 2
// ---------------------------------------------------------------------------

const test_targets = [_]Target{
    .{ .name = "circle-radius", .ncomp = 1 },
    .{ .name = "tint", .ncomp = 3 },
    .{ .name = "cutoff", .ncomp = 1, .registry = 1 },
};

test "compile builds the table: ticks exact, programs deduped" {
    var r = try compile(t.allocator, minimal_score, &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;

    try t.expectEqual(@as(usize, 1), table.tracks.len);
    try t.expectEqual(@as(i64, 180180), table.transport.map.ticks_per_beat);
    try t.expectEqual(@as(?i64, 16 * sjon.Pattern.PPC), table.transport.dur);
    try t.expectEqual(TrackTable.EndBehavior.loop, table.transport.end);

    const track = table.tracks[0];
    try t.expectEqual(@as(u16, 0), track.target_id);
    try t.expectEqual(@as(u8, 1), track.ncomp);
    const keys = table.trackKeys(&track);
    try t.expectEqual(@as(usize, 3), keys.len);
    try t.expectEqual(@as(i64, 0), keys[0].at);
    try t.expectEqual(@as(i64, 4 * 180180), keys[1].at);
    try t.expectEqual(@as(i64, 8 * 180180), keys[2].at);
    // linear (default) + out-cubic + smoothstep = 3 distinct programs.
    try t.expectEqual(@as(usize, 3), table.programs.len);
    try t.expectEqual(@as(u16, 0), keys[0].ease_ref);
}

test "compile resolves multi-registry targets and vec arity" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(track :target tint
        \\  (key :at 0b :value [1 0 0])
        \\  (key :at 2b :value [0 0 1]))
        \\(track :target cutoff
        \\  (key :at 0b :value 200)
        \\  (key :at 4b :value 8000 :ease in-out-sine))
    , &test_targets);
    defer r.deinit();
    try t.expect(r.ok());
    const table = r.table.?;
    try t.expectEqual(@as(usize, 2), table.tracks.len);
    try t.expectEqual(@as(u8, 3), table.tracks[0].ncomp);
    try t.expectEqual(@as(u8, 0), table.tracks[0].registry);
    try t.expectEqual(@as(u8, 1), table.tracks[1].registry);
    const tint_keys = table.trackKeys(&table.tracks[0]);
    try t.expectEqual(@as(f32, 1), tint_keys[0].value[0]);
    try t.expectEqual(@as(f32, 0), tint_keys[0].value[3]); // zero lane
}

test "compile sorts out-of-order keys by tick" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 4b :value 0.8)
        \\  (key :at 0b :value 0.2)
        \\  (key :at 2b :value 0.5))
    , &test_targets);
    defer r.deinit();
    try t.expect(r.ok());
    const keys = r.table.?.trackKeys(&r.table.?.tracks[0]);
    try t.expectEqual(@as(f32, 0.2), keys[0].value[0]);
    try t.expectEqual(@as(f32, 0.5), keys[1].value[0]);
    try t.expectEqual(@as(f32, 0.8), keys[2].value[0]);
}

test "compile diagnostics: unknown target, arity, duplicates, loop, empty" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120 :end loop)
        \\(track :target nonexistent (key :at 0b :value 1))
        \\(track :target circle-radius
        \\  (key :at 0b :value [1 2 3])
        \\  (key :at 1b :value 0.5)
        \\  (key :at 1b :value 0.7))
        \\(track :target tint)
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.loop_requires_dur) != null);
    try t.expect(r.findDiag(.unknown_target) != null);
    try t.expect(r.findDiag(.target_arity_mismatch) != null);
    try t.expect(r.findDiag(.duplicate_key_at) != null);
    try t.expect(r.findDiag(.track_empty) != null);
}

test "compile diagnostics: transport missing / seq nesting / weights" {
    var missing = try compile(t.allocator, "(track :target tint (key :at 0b :value [1 1 1]))", &test_targets);
    defer missing.deinit();
    try t.expect(!missing.ok());
    try t.expect(missing.findDiag(.transport_missing) != null);

    var nested = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1
        \\    :ease (seq (stage :ease (seq (stage :ease linear :t 1 :v 1)) :t 1 :v 1))))
    , &test_targets);
    defer nested.deinit();
    try t.expect(!nested.ok());
    try t.expect(nested.findDiag(.ease_nesting_unsupported) != null);

    var weights = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1
        \\    :ease (seq (stage :ease linear :t 1 :v 1) (stage :ease linear :t 1 :v -1))))
    , &test_targets);
    defer weights.deinit();
    try t.expect(!weights.ok());
    try t.expect(weights.findDiag(.ease_weights_invalid) != null);
}

test "compile accepts expr tracks: node recorded, keys table untouched" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target circle-radius
        \\  :expr (+ 0.5 (* 0.5 (sin (* (tau) beat)))))
        \\(track :target tint :expr [phase phase phase])
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;
    try t.expectEqual(@as(usize, 2), table.tracks.len);
    try t.expectEqual(@as(usize, 0), table.keys.len);
    try t.expect(table.tracks[0].source == .expr);
    try t.expectEqual(@as(u8, 3), table.tracks[1].ncomp);
}

test "compile diagnostics: keys XOR expr — both is a conflict" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  :expr (+ beat 0)
        \\  (key :at 0b :value 0.2))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.track_source_conflict) != null);
}

test "compile diagnostics: expr dry-run failures carry user spans" {
    // Unknown binding (no (control …) declares radius-knob here), and a
    // division that is zero exactly at t=0 — both must fail at LOAD,
    // not on the frame path.
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target circle-radius :expr (* radius-knob 2))
        \\(track :target tint :expr (/ 1 beat))
    ;
    var r = try compile(t.allocator, source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    const unknown = r.findDiag(.expr_eval_failed).?;
    // The span points at the whole expression in user coordinates.
    const start = r.validated.userOffset(unknown.span.start);
    try t.expectEqualStrings("(* radius-knob 2)", source[start..r.validated.userOffset(unknown.span.end)]);
}

test "compile diagnostics: expr result shape — arity, boolean, typo'd func" {
    // The fourth track locks Expr's form-construction semantics: a head
    // that is no expr-func (`sine`) evaluates to a form LITERAL, not
    // `UnknownFunction` — it must still fail the dry-run, as a shape
    // defect.
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(track :target circle-radius :expr [1 2])
        \\(track :target tint :expr (+ 1 2))
        \\(track :target cutoff :expr (> beat 1))
        \\(track :target circle-radius :expr (sine beat))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    var shape_count: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .expr_result_invalid) shape_count += 1;
    }
    try t.expectEqual(@as(usize, 4), shape_count);
}

test "compile builds controls: target join, defaults, spans, env binding" {
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(control :id radius-knob :type slider :target circle-radius :min 0 :max 1 :value 0.4)
        \\(control :id sway :value 0.12)
        \\(track :target circle-radius :expr (* radius-knob 2))
        \\(track :target tint :expr [sway sway sway])
    ;
    var r = try compile(t.allocator, source, &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;

    try t.expectEqual(@as(usize, 2), table.controls.len);
    const knob = table.controls[0];
    try t.expectEqualStrings("radius-knob", knob.id);
    try t.expectEqual(@as(u16, 0), knob.target.?.id);
    try t.expectEqual(TrackTable.ControlType.slider, knob.kind);
    try t.expectEqual(@as(u8, 1), knob.ncomp);
    try t.expectEqual(@as(f32, 0.4), knob.value[0]);
    try t.expectEqual(@as(f32, 0), knob.min.?[0]);
    try t.expectEqual(@as(f32, 1), knob.max.?[0]);
    // The :value span is the commit-to-text anchor, in user coordinates.
    const vs_start = r.validated.userOffset(knob.value_span.start);
    const vs_end = r.validated.userOffset(knob.value_span.end);
    try t.expectEqualStrings("0.4", source[vs_start..vs_end]);

    // Env-only control: no target, defaults applied.
    const sway = table.controls[1];
    try t.expectEqual(@as(?TrackTable.ControlTarget, null), sway.target);
    try t.expectEqual(TrackTable.ControlType.slider, sway.kind);
    try t.expectEqual(@as(?[4]f32, null), sway.min);

    // Both expr tracks dry-ran against the control bindings.
    try t.expectEqual(@as(usize, 2), table.tracks.len);
}

test "compile builds vector controls and joins their arity" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(control :id tint-pick :type color :target tint :value [1 0 0])
        \\(track :target tint :expr tint-pick)
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const ctl = r.table.?.controls[0];
    try t.expectEqual(@as(u8, 3), ctl.ncomp);
    try t.expectEqual(TrackTable.ControlType.color, ctl.kind);
    try t.expectEqual(@as(f32, 1), ctl.value[0]);
    try t.expectEqual(@as(f32, 0), ctl.value[3]); // zero lane
}

test "compile diagnostics: control defects" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(control :id knob :value 1)
        \\(control :id knob :value 2)
        \\(control :id beat :value 3)
        \\(control :id a :target nonexistent :value 4)
        \\(control :id b :target tint :value 5)
        \\(control :id c :min [0 0] :value 6)
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.control_duplicate_id) != null);
    try t.expect(r.findDiag(.unknown_target) != null);
    try t.expect(r.findDiag(.target_arity_mismatch) != null);
    // Reserved id and min-arity mismatch both land on control_invalid.
    var invalid_count: usize = 0;
    for (r.diagnostics) |d| {
        if (d.code == .control_invalid) invalid_count += 1;
    }
    try t.expectEqual(@as(usize, 2), invalid_count);
}

test "compile binds controls for the dry-run regardless of document order" {
    // The track sits ABOVE the control: a single-pass walk would miss
    // the binding; the two-pass build must not.
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(track :target circle-radius :expr (* late-knob 0.5))
        \\(control :id late-knob :value 0.8)
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
}

test "compile leaves table null when SJON validation already failed" {
    var r = try compile(t.allocator, "(transport :bpm 120)(track :target x (key :at 4 :value 1))", &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expectEqual(@as(usize, 0), r.diagnostics.len); // SJON's own diagnostic carries it
    try t.expect(findCode(&r.validated, .unit_required) != null);
}

/// Compile `source` and assert exactly that `code` was raised (the score
/// is defective, so the table is null).
fn expectDiag(source: [:0]const u8, code: Code) !void {
    var r = try compile(t.allocator, source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    if (r.findDiag(code) == null) {
        for (r.diagnostics) |d| std.debug.print("  got: {s} — {s}\n", .{ @tagName(d.code), d.message });
        std.debug.print("expected diagnostic .{s} was not raised\n", .{@tagName(code)});
        return error.DiagnosticNotRaised;
    }
}

test "compile diagnostics: transport + easing defects fire by name" {
    // Two transports, a non-positive :dur, and a position past the grid.
    try expectDiag(
        \\(transport :bpm 120)
        \\(transport :bpm 100)
        \\(track :target circle-radius (key :at 0b :value 0))
    , .transport_duplicate);
    try expectDiag(
        \\(transport :bpm 120 :dur 0b)
        \\(track :target circle-radius (key :at 0b :value 0))
    , .transport_invalid);
    try expectDiag(
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 99999999999999999bar :value 1))
    , .tick_overflow);

    // Easing: an out-of-domain bezier x (schema lets the control points
    // through; the [0,1] x-bound is a compile-stage check), an over-long
    // chain, and too many stages.
    try expectDiag(
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1 :ease (cubic-bezier :p [2 0 0.5 1])))
    , .ease_params_invalid);
    try expectDiag(
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1 :ease (chain linear linear linear linear linear)))
    , .ease_ops_exceeded);
    try expectDiag(
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1 :ease (seq
        \\    (stage :ease linear :t 1 :v 1) (stage :ease linear :t 1 :v 1)
        \\    (stage :ease linear :t 1 :v 1) (stage :ease linear :t 1 :v 1)
        \\    (stage :ease linear :t 1 :v 1) (stage :ease linear :t 1 :v 1)
        \\    (stage :ease linear :t 1 :v 1) (stage :ease linear :t 1 :v 1)
        \\    (stage :ease linear :t 1 :v 1))))
    , .ease_stages_exceeded);
}

test "compile transport :emit resolves clock lanes to same-named targets" {
    const targets = [_]Target{
        .{ .name = "beat", .ncomp = 1 },
        .{ .name = "bar", .ncomp = 1 },
        .{ .name = "phase", .ncomp = 1, .registry = 1 },
    };
    var r = try compile(t.allocator, "(transport :bpm 120 :emit [beat bar phase])", &targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const emit = r.table.?.transport.emit;
    try t.expectEqual(@as(usize, 3), emit.len);
    // Lanes preserve document order; each joins to its same-named target.
    try t.expectEqual(TrackTable.EmitName.beat, emit[0].name);
    try t.expectEqual(@as(u16, 0), emit[0].target_id);
    try t.expectEqual(@as(u8, 0), emit[0].registry);
    try t.expectEqual(TrackTable.EmitName.bar, emit[1].name);
    try t.expectEqual(@as(u16, 1), emit[1].target_id);
    try t.expectEqual(TrackTable.EmitName.phase, emit[2].name);
    try t.expectEqual(@as(u16, 2), emit[2].target_id);
    try t.expectEqual(@as(u8, 1), emit[2].registry);
}

test "compile transport :emit defects fire by name" {
    const scalar = [_]Target{
        .{ .name = "beat", .ncomp = 1 },
        .{ .name = "bar", .ncomp = 1 },
    };
    // Duplicate lane in the list.
    {
        var r = try compile(t.allocator, "(transport :bpm 120 :emit [beat beat])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.transport_invalid) != null);
    }
    // A symbol that is not an emittable time name.
    {
        var r = try compile(t.allocator, "(transport :bpm 120 :emit [wobble])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.transport_invalid) != null);
    }
    // A reserved time name that is NOT emittable (tick/cycle/dur) is
    // rejected too — the emit set is a subset of the env bindings.
    {
        var r = try compile(t.allocator, "(transport :bpm 120 :emit [tick])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.transport_invalid) != null);
    }
    // An emittable name absent from every host registry.
    {
        var r = try compile(t.allocator, "(transport :bpm 120 :emit [phase])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.unknown_target) != null);
    }
    // An emittable name resolving to a non-scalar target.
    {
        const vec = [_]Target{.{ .name = "beat", .ncomp = 2 }};
        var r = try compile(t.allocator, "(transport :bpm 120 :emit [beat])", &vec);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.target_arity_mismatch) != null);
    }
}

test "compile transport :emit diagnostics carry the offending entry's span" {
    const scalar = [_]Target{.{ .name = "beat", .ncomp = 1 }};
    const source: [:0]const u8 = "(transport :bpm 120 :emit [beat wobble])";
    var r = try compile(t.allocator, source, &scalar);
    defer r.deinit();
    const d = r.findDiag(.transport_invalid).?;
    const start = r.validated.userOffset(d.span.start);
    const end = r.validated.userOffset(d.span.end);
    try t.expectEqualStrings("wobble", source[start..end]);
}

test "compile diagnostics: table + program caps fire by name" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const zterm = struct {
        fn f(al: Allocator, src: *std.ArrayList(u8)) ![:0]const u8 {
            try src.append(al, 0);
            return src.items[0 .. src.items.len - 1 :0];
        }
    }.f;

    // track_cap_exceeded: MAX_TRACKS + 1 tracks. The cap is structural
    // (checked before target resolution), so one shared target is fine.
    {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "(transport :bpm 120)\n");
        for (0..TrackTable.MAX_TRACKS + 1) |_|
            try src.appendSlice(a, "(track :target circle-radius (key :at 0b :value 0))\n");
        var r = try compile(t.allocator, try zterm(a, &src), &test_targets);
        defer r.deinit();
        try t.expect(r.findDiag(.track_cap_exceeded) != null);
    }

    // key_cap_exceeded: one track, MAX_KEYS + 1 keys on a rising grid.
    {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "(transport :bpm 120)\n(track :target circle-radius\n");
        for (0..TrackTable.MAX_KEYS + 1) |i|
            try src.appendSlice(a, try std.fmt.allocPrint(a, "  (key :at {d}b :value 0)\n", .{i}));
        try src.appendSlice(a, ")\n");
        var r = try compile(t.allocator, try zterm(a, &src), &test_targets);
        defer r.deinit();
        try t.expect(r.findDiag(.key_cap_exceeded) != null);
    }

    // control_cap_exceeded: MAX_CONTROLS + 1 uniquely-ided controls.
    {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "(transport :bpm 120)\n");
        for (0..TrackTable.MAX_CONTROLS + 1) |i|
            try src.appendSlice(a, try std.fmt.allocPrint(a, "(control :id c{d} :value 0)\n", .{i}));
        try src.appendSlice(a, "(track :target circle-radius (key :at 0b :value 0))\n");
        var r = try compile(t.allocator, try zterm(a, &src), &test_targets);
        defer r.deinit();
        try t.expect(r.findDiag(.control_cap_exceeded) != null);
    }

    // ease_cap_exceeded: MAX_EASE_PROGRAMS + 2 keys, each a DISTINCT
    // program (steps-end n, steps-start n, then two named), so dedup
    // cannot collapse them below the cap.
    {
        var src: std.ArrayList(u8) = .empty;
        try src.appendSlice(a, "(transport :bpm 120)\n(track :target circle-radius\n");
        for (0..TrackTable.MAX_EASE_PROGRAMS + 2) |i| {
            const ease = if (i < 64)
                try std.fmt.allocPrint(a, "(steps :n {d})", .{i + 1})
            else if (i < 128)
                try std.fmt.allocPrint(a, "(steps :n {d} :jump start)", .{i - 63})
            else if (i == 128)
                try a.dupe(u8, "linear")
            else
                try a.dupe(u8, "smoothstep");
            try src.appendSlice(a, try std.fmt.allocPrint(a, "  (key :at {d}b :value 0 :ease {s})\n", .{ i, ease }));
        }
        try src.appendSlice(a, ")\n");
        var r = try compile(t.allocator, try zterm(a, &src), &test_targets);
        defer r.deinit();
        try t.expect(r.findDiag(.ease_cap_exceeded) != null);
    }
}

// --- scenes (plan 01 Phase 1: schema + validation) -------------------

test "compile diagnostics: scene missing :name/:at/:dur → scene_invalid" {
    // :name/:at/:dur are schema-OPTIONAL so their absence surfaces as a
    // pacer scene_invalid (with a span), not a generic SJON missing-key
    // error — one wire-stable code for every scene-shape defect.
    const cases = [_][:0]const u8{
        "(transport :bpm 120)\n(scene :at 0b :dur 8b (track :target circle-radius (key :at 0b :value 0)))",
        "(transport :bpm 120)\n(scene :name intro :dur 8b (track :target circle-radius (key :at 0b :value 0)))",
        "(transport :bpm 120)\n(scene :name intro :at 0b (track :target circle-radius (key :at 0b :value 0)))",
    };
    for (cases) |src| {
        var r = try compile(t.allocator, src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.scene_invalid) != null);
    }
}

test "compile diagnostics: two scenes named drop → scene_duplicate_name" {
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(scene :name drop :at 0b :dur 8b
        \\  (track :target circle-radius (key :at 0b :value 0)))
        \\(scene :name drop :at 8b :dur 8b
        \\  (track :target tint (key :at 0b :value [0 0 0])))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.scene_duplicate_name) != null);
}

test "compile diagnostics: 65 scenes → scene_cap_exceeded" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "(transport :bpm 120)\n");
    for (0..TrackTable.MAX_SCENES + 1) |i|
        try src.appendSlice(a, try std.fmt.allocPrint(a, "(scene :name s{d} :at {d}b :dur 4b (track :target circle-radius (key :at 0b :value 0)))\n", .{ i, i }));
    try src.append(a, 0);
    const source = src.items[0 .. src.items.len - 1 :0];
    var r = try compile(t.allocator, source, &test_targets);
    defer r.deinit();
    try t.expect(r.findDiag(.scene_cap_exceeded) != null);
}

test "compile accepts a valid scene: no diagnostics" {
    // Phase 1 is validation-only: the scene's nested (track …) is not yet
    // walked into the table, so a well-formed scene simply compiles clean.
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(scene :name drop :at 160b :dur 60b
        \\  (track :target circle-radius
        \\    (key :at 0b :value 0)
        \\    (key :at 4b :value 1 :ease out-cubic)))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    try t.expectEqual(@as(usize, 0), r.diagnostics.len);
}

// --- scenes (plan 01 Phase 2: compile into the table) ----------------

test "compile scenes: child keys land at absolute ticks, tracks carry the scene index" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target circle-radius (key :at 0b :value 0.1))
        \\(scene :name drop :at 160b :dur 60b
        \\  (track :target tint
        \\    (key :at 0b :value [1 0 0])
        \\    (key :at 4b :value [0 0 1] :ease out-cubic)))
    ;
    var r = try compile(t.allocator, source, &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;

    // The scene records its window on the tick grid (1b = 180180 ticks).
    const ppb: i64 = 180180;
    try t.expectEqual(@as(usize, 1), table.scenes.len);
    try t.expectEqual(@as(i64, 160 * ppb), table.scenes[0].start_tick);
    try t.expectEqual(@as(i64, 60 * ppb), table.scenes[0].dur_ticks);
    // The name span slices `drop` out of the user source (combined→user).
    const ns = table.scenes[0].name_span;
    try t.expectEqualStrings("drop", source[r.validated.userOffset(ns.start)..r.validated.userOffset(ns.end)]);

    // Two tracks: the top-level one is un-scened, the scened one indexes 0.
    try t.expectEqual(@as(usize, 2), table.tracks.len);
    try t.expectEqual(TrackTable.NO_SCENE, table.tracks[0].scene);
    try t.expectEqual(@as(u16, 0), table.tracks[1].scene);

    // The scened track's keys are offset by the scene start (160b).
    const scened = table.trackKeys(&table.tracks[1]);
    try t.expectEqual(@as(i64, 160 * ppb), scened[0].at);
    try t.expectEqual(@as(i64, 164 * ppb), scened[1].at);
}

test "compile scenes: scene-relative position overflow → tick_overflow" {
    // Scene start and child key each convert inside the grid (≈5.4e18
    // ticks) but their sum overflows i64 — the addition seam, not the
    // per-position conversion, must raise tick_overflow.
    var r = try compile(t.allocator,
        \\(transport :bpm 120)
        \\(scene :name edge :at 30000000000000b :dur 4b
        \\  (track :target circle-radius (key :at 30000000000000b :value 0)))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.tick_overflow) != null);
}

test "compile never panics on stray top-level atoms (fuzz regression)" {
    // A parseable document whose data forest holds a NON-form node (a
    // bare atom or vector) must degrade to a diagnostic, never trap:
    // buildTransport / buildTracks / buildControls once called formHeader
    // on every forest node without a tagOf guard. drv_load reaches this
    // path, so this is a real crash surface, not a test-only one.
    for ([_][:0]const u8{ "5", "[1 2 3]", "nil" }) |src| {
        var r = try compile(t.allocator, src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok()); // no transport → not loadable, but no panic
    }
}
