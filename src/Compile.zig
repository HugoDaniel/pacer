//! Score compiler: preloaded schema → `sjon.validateDocument` →
//! compiled `TrackTable`.
//!
//! Stage 1 (`validate`): the score is validated against the preloaded
//! pacer schema (`Schema.zig`, built once per host) handed to SJON
//! through `HostOptions.preloaded` — no filesystem, works on
//! wasm32-freestanding. The document is parsed on its own, so every
//! diagnostic span is a DOCUMENT coordinate: nothing to rebase, no
//! manifest region to filter out.
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
//! shape defects fail at load with spans. Pattern tracks (`:pattern`)
//! follow the same discipline through `PatternTrack.queryCycle`: the
//! dry-run queries their first cycle and every hap must satisfy the
//! result contract. Time-dependent failures (e.g. a division that only
//! zeroes at beat 2, a symbol payload in a later slowcat cycle) are by
//! nature beyond the dry-run; the frame path omits that track's write
//! for the frame.
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
const PactCodec = @import("PactCodec.zig");
const TimeMap = @import("TimeMap.zig");
const Easing = @import("Easing.zig");
const TrackTable = @import("TrackTable.zig");
const ExprTrack = @import("ExprTrack.zig");
const PatternTrack = @import("PatternTrack.zig");
const Schema = @import("Schema.zig");
const test_support = @import("test_support.zig");

const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;

/// Explicit error set. Validation/compile FAILURES are not errors —
/// they are diagnostics on a successfully returned result (collection
/// over abort, the SJON discipline). Only resource exhaustion is one.
pub const Error = error{OutOfMemory};

/// Maximum `(chain …)` nesting depth before flattening gives up.
pub const MAX_CHAIN_DEPTH = 4;

/// Ceiling on the merged target join (host registries + compose-mode
/// `(target …)` declarations). THE definition lives in `PactCodec` — the
/// std-only `'PACT'` leaf this module imports — so the codec never imports
/// the compiler; `Compile.MAX_TARGETS` keeps its public spelling. A
/// declaration past it is `target_decl_invalid`; the cap also keeps every
/// join index inside a `u16` `target_id` and clear of the
/// `TrackTable.NO_TARGET` sentinel.
pub const MAX_TARGETS = PactCodec.MAX_TARGETS;
comptime {
    std.debug.assert(MAX_TARGETS <= TrackTable.NO_TARGET);
}

// ---------------------------------------------------------------------------
// Stage 1 — validate
// ---------------------------------------------------------------------------

/// Owned result of `validate`: the SJON `HostResult` (tree, schema, data
/// forest, diagnostics) over the score source alone. Spans index the
/// SCORE — the schema rides beside the document rather than in front of
/// it, so there is no coordinate translation anywhere in pacer.
///
/// A thin wrapper rather than a bare `HostResult` because `deinit`'s
/// ordering obligation (this goes down before the `Schema` it borrows)
/// belongs to a named type.
pub const Validated = struct {
    result: sjon.Host.HostResult,

    /// Release the SJON result. The `Schema` it borrowed must outlive
    /// this call — see `Schema.zig`'s header.
    pub fn deinit(self: *Validated) void {
        self.result.deinit();
        self.* = undefined;
    }

    /// True when any diagnostic is an error.
    pub fn hasErrors(self: *const Validated) bool {
        return self.result.hasErrors();
    }

    /// First SJON diagnostic with the given code, or null. Test/debug
    /// helper, the twin of `CompileResult.findDiag` for the other code
    /// space; production consumers iterate `result.diagnostics`.
    pub fn findDiag(self: *const Validated, code: Ast.Diagnostic.Code) ?sjon.Host.HostDiagnostic {
        for (self.result.diagnostics) |d| {
            if (d.code == code) return d;
        }
        return null;
    }
};

/// Validate a pacer score against the preloaded schema. Always returns a
/// `Validated` on success of the machinery itself — check `.hasErrors()`
/// / `.result.diagnostics` for the score's actual verdict. O(source): the
/// manifest was parsed once, when `schema` was built.
///
/// `schema` is BORROWED — it must outlive the returned `Validated` (and
/// anything derived from it). Host contract (asserted, not diagnosed):
/// `source` must fit `sjon.Binary.MAX_FILE_SIZE` — the wasm host gates
/// this via `drv_docCap`; a native host sizes its own input.
pub fn validate(gpa: Allocator, schema: *const Schema, source: [:0]const u8) Error!Validated {
    std.debug.assert(source.len <= sjon.Binary.MAX_FILE_SIZE);
    const result = sjon.validateDocument(gpa, source, .{ .preloaded = &schema.preloaded }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .result = result };
}

// ---------------------------------------------------------------------------
// Stage 2 — compile
// ---------------------------------------------------------------------------

/// One resolvable target, as joined from a host registry at load time.
/// The record itself lives in `PactCodec` (the `'PACT'` leaf); this alias
/// keeps `Compile.Target` — the spelling every host and caller uses.
pub const Target = PactCodec.Target;

/// Pacer load-diagnostic codes. Wire-stable from day one: append-only,
/// never reorder, never rename (they cross the WASM boundary in 'PACD'
/// and the golden corpus pins them as `@intFromEnum` ordinals).
pub const Code = enum(u16) {
    /// `:target` names no target in the merged host+declared join.
    unknown_target,
    /// A value's component count disagrees with its target's arity.
    target_arity_mismatch,
    /// Two keys of one track land on the same grid tick.
    duplicate_key_at,
    /// More than `TrackTable.MAX_TRACKS` tracks.
    track_cap_exceeded,
    /// More than `TrackTable.MAX_KEYS` keys across all tracks.
    key_cap_exceeded,
    /// More than `TrackTable.MAX_EASE_PROGRAMS` distinct programs.
    ease_cap_exceeded,
    /// A `(seq …)` with more than `Easing.MAX_STAGES` stages.
    ease_stages_exceeded,
    /// A flattened `(chain …)` with more than `Easing.MAX_OPS` ops.
    ease_ops_exceeded,
    /// Non-positive `:t`, a cancelled `Σ:v`, or a collapsed boundary.
    ease_weights_invalid,
    /// A primitive parameter outside its domain (bezier x, spring z, …).
    ease_params_invalid,
    /// An ease form nested beyond the flat seq/chain model.
    ease_nesting_unsupported,
    /// A position overflows the portable tick grid (2^53 ceiling).
    tick_overflow,
    /// The score has no `(transport …)` form.
    transport_missing,
    /// More than one `(transport …)` form.
    transport_duplicate,
    /// A malformed transport field (bad `:emit` name, non-positive `:dur`, …).
    transport_invalid,
    /// `:end loop` without a `:dur` to wrap on.
    loop_requires_dur,
    /// A track with no value source at all (no keys, `:expr`, `:pattern`).
    track_empty,
    /// A track with more than one source (keys / `:expr` / `:pattern`).
    track_source_conflict,
    /// The `:expr` t=0 dry-run raised (unknown binding, div by zero, …).
    expr_eval_failed,
    /// The `:expr` dry-run value violates the shape/finiteness contract.
    expr_result_invalid,
    /// Two `(control …)` pins share an `:id`.
    control_duplicate_id,
    /// More than `TrackTable.MAX_CONTROLS` controls.
    control_cap_exceeded,
    /// A malformed control (reserved `:id`, `:min`/`:max` arity, …).
    control_invalid,
    /// A malformed `(scene …)` (missing `:name`/`:at`/`:dur`, …).
    scene_invalid,
    /// Two scenes share a `:name`.
    scene_duplicate_name,
    /// More than `TrackTable.MAX_SCENES` scenes.
    scene_cap_exceeded,
    /// A malformed `(trigger …)` schedule (no events, unsorted `:at`, …).
    trigger_invalid,
    /// The `:pattern` cycle dry-run query raised.
    pattern_eval_failed,
    /// A pattern payload violates the numeric result contract.
    pattern_result_invalid,
    /// A malformed compose-mode `(target …)` declaration (missing
    /// name/arity, duplicate name, arity conflict with the host, cap).
    target_decl_invalid,
    /// A malformed `(tempo …)` form (missing `:at`/`:bpm`, non-positive
    /// / seconds-unit / non-ascending `:at`, segment cap).
    tempo_map_invalid,
    /// Pack preflight: an expr head resolves through the document's
    /// user plugins — or ambiguously against a core name — so the
    /// core-only binary schema cannot evaluate it identically (plan 01
    /// T3.2; the head and its span ride the diagnostic).
    pack_user_expr_unsupported,
    /// Pack preflight: a `:pattern` track cannot be packed in v1 —
    /// the pattern query env is pending the SJON owner's decision
    /// (interim refusal, lifted by plan 02 P4; never silently packed).
    pack_patterns_unsupported,
    /// Pack preflight: a v1 binary resource cap exceeded — per-payload
    /// bytes, total `'PAYL'` bytes, or the global explicit-trigger
    /// entry count. The measured amount rides the message; packing
    /// refuses loudly, never emits a truncated subset.
    pack_cap_exceeded,
};

comptime {
    // The corpus prints codes as ordinals; pin both ends so an
    // accidental insertion breaks the build, not the goldens.
    std.debug.assert(@intFromEnum(Code.unknown_target) == 0);
    std.debug.assert(@intFromEnum(Code.tempo_map_invalid) == 30);
    // The three pack codes are appended AFTER the frozen 0..30 span
    // (T3.2) — the tail pin holds the count at exactly 34 variants.
    std.debug.assert(@intFromEnum(Code.pack_user_expr_unsupported) == 31);
    std.debug.assert(@intFromEnum(Code.pack_patterns_unsupported) == 32);
    std.debug.assert(@intFromEnum(Code.pack_cap_exceeded) == 33);
}

/// One pacer load diagnostic. `span` indexes the score source — the same
/// coordinate space as SJON's own diagnostics, ready for editor display
/// with no translation.
pub const Diagnostic = struct {
    code: Code,
    span: Ast.Span,
    /// Compile-arena-backed; lives exactly as long as the result.
    message: []const u8,
};

/// Owned result of `compile`. `table` is non-null iff the score is
/// clean: no SJON validation errors and no pacer diagnostics.
///
/// The validated tree (and its schema aggregate) ride along because
/// expr tracks evaluate by node index against them every frame — the
/// table alone is self-contained only for keyframe-only scores.
/// `Eval.Evaluator` therefore borrows the WHOLE result. Hold the pair
/// through `Driver` (which encodes placement, no-reassign, and teardown
/// order as structure) unless you can uphold those three rules yourself:
/// the result must sit in its final memory location before the borrow
/// (the struct is moved by value; interior pointers taken before the
/// move would dangle), never be reassigned while borrowed, and outlive
/// the evaluator.
///
/// Immutable once returned: every live nudge (`setBpm`, held controls) is
/// `Eval.Evaluator` state, so the table — and the `'PACM'` blob encoded
/// from it — is the document's truth for the result's whole life.
pub const CompileResult = struct {
    validated: Validated,
    arena: std.heap.ArenaAllocator,
    diagnostics: []const Diagnostic,
    table: ?TrackTable,
    /// The merged target join this score compiled against: the caller's
    /// host registries (indices preserved) followed by any compose-mode
    /// `(target …)` declaration the host did not already provide (appended
    /// in document order). Names are arena-backed. NOT a wire surface —
    /// the `'PACT'`/`'PACM'` blobs never carry declared names (a consumer
    /// reads them from source, like scene names); this is a native-side
    /// view so the corpus runner and tests can name declared-only targets.
    /// Equals the host list verbatim when the score has no declarations.
    /// Every name — host-provided or declared — is arena-owned, so this
    /// slice never aliases the caller's target memory (the SJON memory
    /// model: the result retains nothing of its inputs).
    targets: []const Target,
    /// Schema for expr-track evaluation: the CORE plugin prepended to
    /// this document's user plugins — the preloaded pacer schema, plus
    /// anything the score declared inline (`HostResult.schema` is
    /// user-only by design: core funcs like `sin`/`tau` would not resolve
    /// through it, and an unresolved head quietly evaluates to a form
    /// literal). Mirrors `Host.zig`'s eval-pass schema. The outer slice
    /// is arena-backed, so it survives the by-value move of this struct;
    /// the preloaded entries' interiors live in the `Schema` bundle,
    /// which must outlive this result.
    eval_schema: sjon.Schema.Schema,

    /// Tear down everything the compile owns (table, arena, validated
    /// tree). Any `Eval.Evaluator` borrowing this result goes first; the
    /// `Schema` this result borrows goes last.
    pub fn deinit(self: *CompileResult) void {
        if (self.table) |*tb| tb.deinit();
        self.arena.deinit();
        self.validated.deinit();
        self.* = undefined;
    }

    /// True when the score compiled clean — `table` is live and the
    /// diagnostics (both sources) are empty.
    pub fn ok(self: *const CompileResult) bool {
        return self.table != null;
    }

    /// First pacer diagnostic with the given code, or null. Test/debug
    /// helper; `validated.findDiag` is the SJON-side twin.
    pub fn findDiag(self: *const CompileResult, code: Code) ?Diagnostic {
        for (self.diagnostics) |d| {
            if (d.code == code) return d;
        }
        return null;
    }
};

/// Compile a score against the host registries. The frame path needs
/// nothing beyond the returned result — but the result is borrowed
/// WHOLE: expr/pattern tracks re-read its tree + schema every frame, so
/// only keyframe-only scores could live off `table` alone (see
/// `CompileResult`). `schema` is borrowed too, one ring further out (see
/// `Schema.zig`): it must outlive the result. Host contract, asserted not
/// diagnosed: `source.len` within `sjon.Binary.MAX_FILE_SIZE` (the wasm
/// host gates via `drv_docCap`), and `targets.len` within `MAX_TARGETS`
/// (the 'PACT' decoder gates).
pub fn compile(gpa: Allocator, schema: *const Schema, source: [:0]const u8, targets: []const Target) Error!CompileResult {
    std.debug.assert(targets.len <= MAX_TARGETS);
    var v = try validate(gpa, schema, source);
    errdefer v.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();

    // The result owns its target join outright: copy the host names in
    // now, so `CompileResult.targets` never aliases the caller's memory
    // (under wasm that is `targets_buffer`, overwritten by the next load).
    const host_targets = try arena.allocator().alloc(Target, targets.len);
    for (host_targets, targets) |*owned, tg| {
        owned.* = .{
            .name = try arena.allocator().dupe(u8, tg.name),
            .ncomp = tg.ncomp,
            .registry = tg.registry,
        };
    }

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
        .view = .init(&v.result.tree, &v.result.materialized_defaults),
        .targets = host_targets,
        .merged_targets = host_targets,
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
        .targets = builder.merged_targets,
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
    /// Author-value-first view over the tree and SJON's materialized
    /// `:default` overlay. Every default the score-language declares is
    /// spelled ONCE, in `schema/pacer.sjon`, and read back through here —
    /// `effNumber` / `effSymbol` / `effVecNumber` below. The one exception
    /// is `(key :ease)`, whose default is structural (see `build`'s
    /// `programs[0]` seed); the overlay is keyed by a GLOBAL form lookup,
    /// so slot-local forms like `key` never receive entries.
    view: sjon.EffectiveView.EffectiveView,
    /// Active join for `resolveTarget`: the host list until `buildTargetJoin`
    /// merges the compose-mode `(target …)` declarations, then the merged
    /// list (host indices preserved, declared-only names appended).
    targets: []const Target,
    /// The merged join, surfaced on `CompileResult.targets`. Defaults to
    /// the host list so it is sound even when `build()` never runs (SJON
    /// validation errors) or fails before the join.
    merged_targets: []const Target,
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

    /// Table-under-construction state, table-arena backed. `ta` is set
    /// once at the top of `build()` (undefined before it runs — nothing
    /// touches these outside the build walk). Rows and keys land ONLY
    /// through `appendRow`/`appendKey`, so the row/span (and key/span)
    /// pairings hold by construction, not by call-site discipline.
    ta: Allocator = undefined,
    tracks: std.ArrayList(TrackTable.Track) = .empty,
    keys: std.ArrayList(TrackTable.Key) = .empty,
    track_spans: std.ArrayList(Ast.Span) = .empty,
    key_spans: std.ArrayList(Ast.Span) = .empty,
    scenes: std.ArrayList(TrackTable.Scene) = .empty,

    /// Dry-run scratch: the dry-runs evaluate under exactly the resources
    /// the frame path will have (`ExprTrack.SCRATCH_BYTES` /
    /// `PatternTrack.SCRATCH_BYTES`), fronted by a `FixedBufferAllocator`
    /// over this buffer — one code path, one resource model. Lazily
    /// gpa-allocated on first dry-run (grown if a pattern follows an
    /// expr) and freed at the end of `build()` — NOT table-arena backed:
    /// the table arena lives as long as the result, and a build-scoped
    /// megabyte must not pin itself to every loaded pattern score.
    dry_scratch: []u8 = &.{},

    /// The lazily-grown `dry_scratch`, at least `need` bytes. Allocation
    /// failure here is a REAL compile-aborting OOM (the host's memory,
    /// not the frame budget).
    fn dryScratch(self: *Builder, need: usize) Error![]u8 {
        if (self.dry_scratch.len < need) {
            self.gpa.free(self.dry_scratch);
            self.dry_scratch = &.{};
            self.dry_scratch = self.gpa.alloc(u8, need) catch return error.OutOfMemory;
        }
        return self.dry_scratch;
    }

    /// `buildTrackForm`'s walk verdict.
    const Walk = enum {
        /// This form was handled (built, or skipped with its diagnostic
        /// emitted) — the walk continues.
        keep_walking,
        /// The table-global key cap forced the WHOLE walk to stop.
        stop_walk,
    };

    /// The only place a table row (track or trigger) is ever appended:
    /// row and span in lockstep, so `track_spans.len == tracks.len` is
    /// structural (the end-of-walk asserts document this guarantee).
    fn appendRow(self: *Builder, row: TrackTable.Track, span: Ast.Span) Error!void {
        self.tracks.append(self.ta, row) catch return error.OutOfMemory;
        self.track_spans.append(self.ta, span) catch return error.OutOfMemory;
    }

    /// The only place a key is ever appended — `key_spans.len ==
    /// keys.len` by construction, like `appendRow`.
    fn appendKey(self: *Builder, key: TrackTable.Key, span: Ast.Span) Error!void {
        self.keys.append(self.ta, key) catch return error.OutOfMemory;
        self.key_spans.append(self.ta, span) catch return error.OutOfMemory;
    }

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
        self.ta = ta;
        // The dry-run scratch is build-scoped by nature (see its doc).
        defer {
            self.gpa.free(self.dry_scratch);
            self.dry_scratch = &.{};
        }

        const before_diags = self.diags.items.len;
        // Linear has no params to validate — this cannot fail.
        // Slot 0 IS `(key :ease)`'s schema default made structural: an
        // omitted `:ease` refs it instead of interning a program. The
        // overlay could not supply it anyway — it is keyed by a GLOBAL form
        // lookup and `key` is slot-local to `(track …)`. The
        // "omitted-key table matches what the manifest declares" test pins
        // this slot against the manifest's `:default linear`.
        self.programs[0] = Easing.primitive(.{ .code = .linear }) catch unreachable;
        self.programs_len = 1;

        // Merge compose-mode (target …) declarations into the join FIRST,
        // so every downstream resolveTarget (emit lanes, controls, tracks,
        // triggers) sees them. A declaration defect emits here and nulls
        // the table via the diag gate below.
        try self.buildTargetJoin();

        const transport = try self.buildTransport(ta) orelse {
            table_arena.deinit();
            return null;
        };

        // Controls first: the track dry-run needs their ids bound.
        var controls: std.ArrayList(TrackTable.Control) = .empty;
        try self.buildControls(ta, &controls);

        try self.buildTracks(&transport);

        // Scenes: validate each `(scene …)` (presence, uniqueness, cap)
        // and walk its child tracks scene-relative into the SAME arrays,
        // scene start folded into every key tick. Any defect nulls the
        // table via the diag-count gate below.
        try self.buildScenes(&transport);

        // Triggers: build each top-level (trigger …) into the table as
        // trigger rows. Scened triggers were already walked by
        // buildScenes (scene start folded into their schedule). A defect
        // emits and nulls the table via the diag gate below.
        try self.buildTriggers(&transport);

        std.debug.assert(self.track_spans.items.len == self.tracks.items.len);
        std.debug.assert(self.key_spans.items.len == self.keys.items.len);

        if (self.diags.items.len != before_diags) {
            table_arena.deinit();
            return null;
        }

        const programs = ta.dupe(Easing.Program, self.programs[0..self.programs_len]) catch
            return error.OutOfMemory;
        return .{
            .arena = table_arena,
            .transport = transport,
            .tracks = self.tracks.items,
            .keys = self.keys.items,
            .programs = programs,
            .controls = controls.items,
            .track_spans = self.track_spans.items,
            .key_spans = self.key_spans.items,
            .scenes = self.scenes.items,
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

        // Member-set-validated symbol; the names match the enum.
        const kind = std.meta.stringToEnum(TrackTable.ControlType, self.effSymbol(idx, "type").?).?;

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

        const beats_per_bar: i64 = @intFromFloat(self.effVecNumber(idx, "meter", 0).?);
        var map = TimeMap.init(bpm, beats_per_bar);

        // `(tempo …)` segments attach BEFORE any position conversion, so
        // an s-unit `:dur` here — and every downstream s position —
        // resolves through the finished piecewise map. The authored pairs
        // ride the table (`Transport.segments`, the 'TMPO' truth); the
        // derived cumulative table lives on the map.
        const segments = try self.buildTempoSegments(ta, &map, bpm);
        if (segments.len > 1) {
            const derived = ta.alloc(TimeMap.Segment, segments.len) catch return error.OutOfMemory;
            for (derived, segments) |*d, s|
                d.* = .{ .start_tick = s.start_tick, .bpm = s.bpm, .start_sec = undefined, .tps = undefined };
            map = map.withSegments(derived);
        }

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

        // Member-set-validated symbol; the names match the enum.
        const end = std.meta.stringToEnum(TrackTable.EndBehavior, self.effSymbol(idx, "end").?).?;
        if (end == .loop and dur == null) {
            try self.emit(.loop_requires_dur, tree.spanOf(idx), ":end loop requires :dur", .{});
        }

        var emit_lanes: []const TrackTable.EmitLane = &.{};
        if (kvNode(tree, children, "emit")) |emit_node| {
            emit_lanes = try self.buildEmit(ta, emit_node);
        }

        // The seconds-domain wrap constant for mapped scores, computed
        // once here (exact f64 from the table).
        var loop_secs: ?f64 = null;
        if (dur) |d| loop_secs = map.secondsFromTick(d);

        return .{ .map = map, .dur = dur, .end = end, .emit = emit_lanes, .segments = segments, .loop_secs = loop_secs };
    }

    /// Collect the `(tempo …)` forms into the transport's segment table.
    /// Segment 0 is the transport's own `:bpm` at tick 0; each form must
    /// carry `:at` (> 0, b/bar units only — an `s` position is circular,
    /// it would need the map being defined) and `:bpm`, strictly
    /// ascending in DOCUMENT order — reject, don't sort (the trigger
    /// `:at` discipline). Every defect is `tempo_map_invalid` at the
    /// offending span; the walk keeps collecting (the table nulls via
    /// the diag gate), except the cap, which stops it at the first
    /// overflowing form.
    fn buildTempoSegments(self: *Builder, ta: Allocator, map: *const TimeMap, bpm0: f64) Error![]const TrackTable.TempoSegment {
        const tree = self.tree;
        var segs: std.ArrayList(TrackTable.TempoSegment) = .empty;
        segs.append(ta, .{ .start_tick = 0, .bpm = bpm0 }) catch return error.OutOfMemory;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "tempo")) continue;
            const children = tree.formHeader(idx).children;
            const at_node = kvNode(tree, children, "at");
            const bpm_node = kvNode(tree, children, "bpm");
            if (at_node == null or bpm_node == null) {
                try self.emit(.tempo_map_invalid, tree.spanOf(idx), "(tempo …) requires :at and :bpm", .{});
                continue;
            }
            const nu = tree.numberWithUnitOf(at_node.?);
            if (std.mem.eql(u8, nu.unit, "s")) {
                try self.emit(.tempo_map_invalid, tree.spanOf(at_node.?), ":at cannot be in seconds — the tempo map defines the seconds axis; use b or bar", .{});
                continue;
            }
            const converted = if (std.mem.eql(u8, nu.unit, "b"))
                map.tickFromBeats(nu.value)
            else
                map.tickFromBars(nu.value);
            const tick = converted catch {
                try self.emit(.tick_overflow, tree.spanOf(at_node.?), "position overflows the tick grid", .{});
                continue;
            };
            if (tick <= 0) {
                try self.emit(.tempo_map_invalid, tree.spanOf(at_node.?), ":at must be after tick 0 (segment 0 is the transport's own :bpm)", .{});
                continue;
            }
            if (tick <= segs.items[segs.items.len - 1].start_tick) {
                try self.emit(.tempo_map_invalid, tree.spanOf(at_node.?), ":at positions must be strictly ascending in document order", .{});
                continue;
            }
            if (segs.items.len == TrackTable.MAX_TEMPO_SEGMENTS) {
                try self.emit(.tempo_map_invalid, tree.spanOf(idx), "more than {d} tempo segments", .{TrackTable.MAX_TEMPO_SEGMENTS});
                break;
            }
            segs.append(ta, .{ .start_tick = tick, .bpm = readNumber(tree, bpm_node.?).? }) catch
                return error.OutOfMemory;
        }
        return segs.items;
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

    fn buildTracks(self: *Builder, transport: *const TrackTable.Transport) Error!void {
        const tree = self.tree;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "track")) continue;
            if (self.tracks.items.len == TrackTable.MAX_TRACKS) {
                try self.emit(.track_cap_exceeded, tree.spanOf(idx), "more than {d} tracks", .{TrackTable.MAX_TRACKS});
                return;
            }
            // Top-level tracks: no owning scene (no offset, no window env).
            if (try self.buildTrackForm(transport, idx, null, TrackTable.NO_SCENE) == .stop_walk) return;
        }
    }

    /// Build one `(track …)` form into the table. `scene_win` is the owning
    /// scene (null for a top-level track): its start tick is added to every
    /// key tick with a checked add, and it supplies the scene-local expr env
    /// (`scene-beat`/`scene-phase`) for the dry-run. `scene_index` is the
    /// owning scene's index or `NO_SCENE`, recorded on the `Track`. Every
    /// per-track defect emits at its span and keeps walking (skip this
    /// track, keep collecting) — only `Walk.stop_walk` ends the walk (see
    /// the variant). The caller checks the track cap first — it depends
    /// on the running table count.
    fn buildTrackForm(
        self: *Builder,
        transport: *const TrackTable.Transport,
        idx: NodeIndex,
        scene_win: ?TrackTable.Scene,
        scene_index: u16,
    ) Error!Walk {
        const tree = self.tree;
        const map = &transport.map;
        const hdr = tree.formHeader(idx);
        const offset: TrackTable.Tick = if (scene_win) |w| w.start_tick else 0;

        const target_node = kvNode(tree, hdr.children, "target").?;
        const target_name = tree.symbolText(target_node);
        const target = self.resolveTarget(target_name) orelse {
            try self.emit(.unknown_target, tree.spanOf(target_node), "unknown target `{s}` — not in any host registry", .{target_name});
            return .keep_walking;
        };

        // Three explicit value sources — keys XOR :expr XOR :pattern.
        // The `:expr` / `:pattern` pairing is a count over two declared
        // keys, so the manifest's `(exclusive-group :cardinality
        // at-most-one …)` owns it and voids the table before this walk
        // runs (asserted below). A group counts no `(key …)` CHILDREN,
        // though, so the two pairings involving them stay here: one
        // `track_source_conflict` at the later-listed source's span
        // (collection over abort — one diagnostic names the pair, the
        // track is skipped, the walk continues).
        const expr_node = kvNode(tree, hdr.children, "expr");
        const pattern_node = kvNode(tree, hdr.children, "pattern");
        std.debug.assert(expr_node == null or pattern_node == null);
        if (expr_node) |node| {
            if (firstKeyChild(tree, hdr.children) != null) {
                try self.emit(.track_source_conflict, tree.spanOf(node), "track `{s}` has both (key …) children and :expr — exactly one value source", .{target_name});
                return .keep_walking;
            }
            if (try self.dryRunExpr(transport, node, target.ncomp, scene_win)) {
                try self.appendRow(.{
                    .target_id = target.id,
                    .registry = target.registry,
                    .ncomp = target.ncomp,
                    .source = .{ .expr = node },
                    .scene = scene_index,
                }, tree.spanOf(idx));
            }
            return .keep_walking;
        }
        if (pattern_node) |node| {
            if (firstKeyChild(tree, hdr.children) != null) {
                try self.emit(.track_source_conflict, tree.spanOf(node), "track `{s}` has both (key …) children and :pattern — exactly one value source", .{target_name});
                return .keep_walking;
            }
            if (try self.dryRunPattern(transport, node, target.ncomp, scene_win)) {
                try self.appendRow(.{
                    .target_id = target.id,
                    .registry = target.registry,
                    .ncomp = target.ncomp,
                    .source = .{ .pattern = node },
                    .scene = scene_index,
                }, tree.spanOf(idx));
            }
            return .keep_walking;
        }

        const keys_start: u32 = @intCast(self.keys.items.len);
        for (hdr.children) |child| {
            if (tree.tagOf(child) != .form) continue;
            std.debug.assert(std.mem.eql(u8, tree.formHeader(child).head, "key"));
            if (self.keys.items.len == TrackTable.MAX_KEYS) {
                try self.emit(.key_cap_exceeded, tree.spanOf(child), "more than {d} keys", .{TrackTable.MAX_KEYS});
                return .stop_walk;
            }
            if (try self.buildKey(map, child, target.ncomp, offset)) |k| {
                try self.appendKey(k, tree.spanOf(child));
            }
        }
        const track_keys = self.keys.items[keys_start..];
        const track_key_spans = self.key_spans.items[keys_start..];
        if (track_keys.len == 0) {
            try self.emit(.track_empty, tree.spanOf(idx), "track `{s}` has no value source — give it (key …) children, :expr, or :pattern", .{target_name});
            return .keep_walking;
        }

        // Author order is free; the table is sorted. Equal ticks are
        // a defect (which value wins would be source-order luck).
        sortKeysWithSpans(track_keys, track_key_spans);
        for (track_keys[1..], 0..) |k, i| {
            if (k.at == track_keys[i].at) {
                try self.emit(.duplicate_key_at, track_key_spans[i + 1], "duplicate key at the same tick ({d})", .{k.at});
            }
        }

        try self.appendRow(.{
            .target_id = target.id,
            .registry = target.registry,
            .ncomp = target.ncomp,
            .source = .{ .keys = .{ .start = keys_start, .len = @intCast(track_keys.len) } },
            .scene = scene_index,
        }, tree.spanOf(idx));
        return .keep_walking;
    }

    /// Validate every top-level `(scene …)` and compile its children into
    /// the table. Shape checks: presence of the schema-optional
    /// `:name`/`:at`/`:dur` (missing any → `scene_invalid`), name
    /// uniqueness (`scene_duplicate_name`), and the `MAX_SCENES` cap. A
    /// sound scene records its window in `scenes`; its child `(track …)`
    /// forms are walked scene-relative — each key tick offset by the
    /// scene start (overflow → `tick_overflow`) — carrying the scene
    /// index. Any diagnostic nulls the table via the caller's diag gate.
    fn buildScenes(self: *Builder, transport: *const TrackTable.Transport) Error!void {
        const tree = self.tree;
        const map = &transport.map;
        var seen: std.ArrayList([]const u8) = .empty;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "scene")) continue;
            if (self.scenes.items.len == TrackTable.MAX_SCENES) {
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
            // scene (tick_overflow was emitted; the table is doomed). An
            // s-unit :dur is wall-clock from the scene START (anchored) —
            // under a tempo map "1s long" depends on where the scene sits.
            const start_tick = try self.posToTick(map, at_node.?) orelse continue;
            const dur_ticks = try self.posToTickLocal(map, dur_node.?, start_tick) orelse continue;
            // The eval-time window gate compares against `start + dur`;
            // guarantee that end fits the grid now, so the frame path never
            // overflows (a non-positive dur is a harmless never-active
            // window, resolved at eval). Overflow dooms the table, exactly
            // like buildKey's scene-relative fold.
            _ = std.math.add(TrackTable.Tick, start_tick, dur_ticks) catch {
                try self.emit(.tick_overflow, tree.spanOf(dur_node.?), "scene window end overflows the tick grid", .{});
                continue;
            };

            const scene_index: u16 = @intCast(self.scenes.items.len);
            const scene: TrackTable.Scene = .{
                .name_span = tree.spanOf(name_node.?),
                .start_tick = start_tick,
                .dur_ticks = dur_ticks,
            };
            self.scenes.append(self.ta, scene) catch return error.OutOfMemory;

            // Child tracks and triggers resolve scene-relative (offset =
            // scene start): a track carries the window into its expr env, a
            // trigger folds it into its schedule. Both count as table rows.
            for (children) |child| {
                const is_track = isForm(tree, child, "track");
                if (!is_track and !isForm(tree, child, "trigger")) continue;
                if (self.tracks.items.len == TrackTable.MAX_TRACKS) {
                    try self.emit(.track_cap_exceeded, tree.spanOf(child), "more than {d} tracks", .{TrackTable.MAX_TRACKS});
                    return;
                }
                if (is_track) {
                    if (try self.buildTrackForm(transport, child, scene, scene_index) == .stop_walk) return;
                } else {
                    try self.buildTriggerForm(transport, child, scene, scene_index);
                }
            }
        }
    }

    /// Build every top-level `(trigger …)` into the table. A trigger fires
    /// on an event schedule that is EITHER periodic (`:every`, phased by
    /// optional `:offset`) XOR an explicit ascending `:at` list; exactly
    /// one source is required. It joins its target like a track and lands
    /// as a trigger `Track` row (a `Source.trigger`, no keys), counted
    /// against `MAX_TRACKS`. Scened triggers are walked by `buildScenes`
    /// (scene start folded in); this pass handles the top-level forest.
    fn buildTriggers(self: *Builder, transport: *const TrackTable.Transport) Error!void {
        const tree = self.tree;
        for (self.forest) |idx| {
            if (!isForm(tree, idx, "trigger")) continue;
            if (self.tracks.items.len == TrackTable.MAX_TRACKS) {
                try self.emit(.track_cap_exceeded, tree.spanOf(idx), "more than {d} tracks", .{TrackTable.MAX_TRACKS});
                return;
            }
            // Top-level triggers: no owning scene (offset 0, no window env).
            try self.buildTriggerForm(transport, idx, null, TrackTable.NO_SCENE);
        }
    }

    /// Build one `(trigger …)` form into the table. `scene_win` is the
    /// owning scene (null for a top-level trigger): its start tick folds
    /// into the schedule — added to each `:at` position and to the periodic
    /// `:offset` with a checked add (overflow → `tick_overflow`) — so a
    /// scened trigger's ticks are absolute, exactly like a scened track's
    /// keys. `scene_index` is recorded on the row. Every per-trigger defect
    /// emits at its span and returns (skip this trigger; the diag gate
    /// nulls the table). The caller checks the track cap first — it depends
    /// on the running row count.
    fn buildTriggerForm(
        self: *Builder,
        transport: *const TrackTable.Transport,
        idx: NodeIndex,
        scene_win: ?TrackTable.Scene,
        scene_index: u16,
    ) Error!void {
        const tree = self.tree;
        const map = &transport.map;
        const children = tree.formHeader(idx).children;
        const offset: TrackTable.Tick = if (scene_win) |w| w.start_tick else 0;

        const every_node = kvNode(tree, children, "every");
        const at_node = kvNode(tree, children, "at");
        // Exactly one source, counted by the manifest's `(exclusive-group
        // :cardinality exactly-one …)`: neither is required_one_of_missing,
        // both is mutually_exclusive_keys_present, and either voids the
        // table before this walk runs. `(a == null) == (b == null)` is true
        // iff both are present or both absent — so this asserts the group.
        std.debug.assert((every_node == null) != (at_node == null));

        const target_node = kvNode(tree, children, "target").?;
        const target_name = tree.symbolText(target_node);
        const target = self.resolveTarget(target_name) orelse {
            try self.emit(.unknown_target, tree.spanOf(target_node), "unknown target `{s}` — not in any host registry", .{target_name});
            return;
        };

        const schedule: TrackTable.Trigger = if (every_node) |en| blk: {
            // Periodic interval must be a positive tick count (overflow
            // already emitted tick_overflow and returned null). An
            // s-unit :every converts at the map ORIGIN — a wall-clock
            // period has no fixed tick width on a varying grid; mapped
            // scores should author :every in b/bar.
            const every_ticks = try self.posToTick(map, en) orelse return;
            if (every_ticks <= 0) {
                try self.emit(.trigger_invalid, tree.spanOf(en), ":every must be a positive interval", .{});
                return;
            }
            // :offset's zero is the ONE default the manifest cannot carry
            // (every other one is `:default` there, read through
            // `effNumber`/`effSymbol`): `Plugin.KeySpec.Default` has a
            // `number: f64` variant and no unit variant, so a `:default 0b`
            // on a `time-pos` key would silently drop its unit. Zero ticks
            // is unit-free and exact, so it lives here instead.
            //
            // The scene start folds in. A top-level offset never overflows
            // (offset is 0 and the local tick is a valid grid position),
            // exactly like buildKey's scene fold — so the overflow below is
            // reachable only with :offset present, and the span points at
            // that value.
            var offset_local: TrackTable.Tick = 0;
            var offset_span = tree.spanOf(idx);
            if (kvNode(tree, children, "offset")) |on| {
                offset_local = try self.posToTickLocal(map, on, offset) orelse return;
                offset_span = tree.spanOf(on);
            }
            const offset_abs = std.math.add(TrackTable.Tick, offset, offset_local) catch {
                try self.emit(.tick_overflow, offset_span, "scene-relative trigger offset overflows the tick grid", .{});
                return;
            };
            break :blk .{ .periodic = .{ .every = every_ticks, .offset = offset_abs } };
        } else blk: {
            const at = try self.buildAtList(self.ta, map, at_node.?, offset) orelse return;
            break :blk .{ .at = at };
        };

        try self.appendRow(.{
            .target_id = target.id,
            .registry = target.registry,
            .ncomp = target.ncomp,
            .source = .{ .trigger = schedule },
            .scene = scene_index,
        }, tree.spanOf(idx));
    }

    /// Resolve an explicit `:at` event list into an arena-owned tick slice:
    /// non-empty, strictly ascending in TICK order, with `offset` (the
    /// scene start, 0 at the top level) folded into each position. Empty,
    /// descending, or tied positions are a `trigger_invalid` (which event a
    /// tie selects would be source-order luck); a position overflowing the
    /// grid — or the scene-relative fold overflowing — is a `tick_overflow`.
    /// The uniform `offset` add preserves order, so ascending-in-local ⇔
    /// ascending-in-absolute. Returns null after emitting on any defect.
    fn buildAtList(self: *Builder, ta: Allocator, map: *const TimeMap, at_node: NodeIndex, offset: TrackTable.Tick) Error!?[]const TrackTable.Tick {
        const tree = self.tree;
        const elems = tree.vectorElements(at_node);
        if (elems.len == 0) {
            try self.emit(.trigger_invalid, tree.spanOf(at_node), ":at needs at least one event position", .{});
            return null;
        }
        var ticks: std.ArrayList(TrackTable.Tick) = .empty;
        var prev: ?TrackTable.Tick = null;
        for (elems) |elem| {
            const local = try self.posToTickLocal(map, elem, offset) orelse return null;
            const tick = std.math.add(TrackTable.Tick, local, offset) catch {
                try self.emit(.tick_overflow, tree.spanOf(elem), "scene-relative trigger position overflows the tick grid", .{});
                return null;
            };
            if (prev) |p| {
                if (tick <= p) {
                    try self.emit(.trigger_invalid, tree.spanOf(at_node), ":at positions must be strictly ascending in time", .{});
                    return null;
                }
            }
            prev = tick;
            ticks.append(ta, tick) catch return error.OutOfMemory;
        }
        return ticks.items;
    }

    /// Dry-run an expr track through the SAME code path the frame uses
    /// (`ExprTrack.evalAt`), so load-time acceptance and frame semantics
    /// cannot drift. Control ids are bound with their document `:value`s.
    /// A top-level track dry-runs at t = 0; a scened track dry-runs at its
    /// scene start (the window's first tick, `scene-beat`/`scene-phase` at
    /// 0) with the scene env bound — so a `(/ 1 beat)` sound over the
    /// window is not spuriously rejected for beat 0 it never sees, and a
    /// top-level `scene-beat` reference is caught as `UnknownBinding`. True
    /// = the track is sound; false = a diagnostic was emitted at its span.
    fn dryRunExpr(self: *Builder, transport: *const TrackTable.Transport, expr_node: NodeIndex, ncomp: u8, scene: ?TrackTable.Scene) Error!bool {
        const controls = self.ctl_bindings[0..self.ctl_count];
        const dry_tick: TrackTable.Tick = if (scene) |s| s.start_tick else 0;
        // The frame path's own fixed budget fronts the eval (see
        // `dryRunPattern` — same doctrine: a dry-run evaluates under
        // exactly the resources the frame will have), so `OutOfMemory`
        // can ONLY mean the budget. Reachable: Expr's own byte ceiling
        // (`MAX_EVAL_BYTES`, 64 MiB) sits far above this scratch, so an
        // allocation-heavy expr lands here first — the wide-sum
        // diagnostic test pins it.
        var fba = std.heap.FixedBufferAllocator.init(try self.dryScratch(ExprTrack.SCRATCH_BYTES));
        _ = ExprTrack.evalAt(fba.allocator(), self.tree, self.schema, transport, controls, expr_node, dry_tick, scene, ncomp) catch |err| switch (err) {
            error.OutOfMemory => {
                try self.emit(.expr_eval_failed, self.tree.spanOf(expr_node), "expression exceeds the {d}-KiB frame evaluation budget at the dry-run tick", .{ExprTrack.SCRATCH_BYTES / 1024});
                return false;
            },
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

    /// Dry-run a pattern track through the SAME query the frame will use
    /// (`PatternTrack.queryCycle`), so load-time acceptance and frame
    /// semantics cannot drift. A top-level track dry-runs cycle 0; a
    /// scened track the cycle containing its scene start (the first
    /// window the frame path will ever query for it — a `(slowcat …)`
    /// arm the scene never opens on is not spuriously rejected). Pacer's
    /// env rides under the pattern-locals exactly as at frame time —
    /// control ids bound with their document `:value`s, the time names
    /// at the dry-run tick — so a hap expr reading `beat` or a control
    /// passes the engine's static leaf check. The sweep is stricter than
    /// the expr dry-run's single point: EVERY hap in the queried cycle
    /// must satisfy the result contract, so a symbol payload half a bar
    /// in fails at load, not silently at eval. Content of LATER cycles
    /// is by nature beyond the dry-run (the expr-at-t=0 limitation); the
    /// frame path omits those writes.
    /// True = the track is sound; false = a diagnostic was emitted.
    fn dryRunPattern(self: *Builder, transport: *const TrackTable.Transport, pattern_node: NodeIndex, ncomp: u8, scene: ?TrackTable.Scene) Error!bool {
        // `PatValue` has no vector variant: a pattern can only ever
        // drive a scalar target this slice — reject the statically
        // impossible pairing regardless of the pattern's content.
        if (ncomp != 1) {
            try self.emit(.pattern_result_invalid, self.tree.spanOf(pattern_node), "pattern values are scalar; target expects {d} components", .{ncomp});
            return false;
        }
        const dry_tick: TrackTable.Tick = if (scene) |s| s.start_tick else 0;
        var env_storage: ExprTrack.EnvStorage = undefined;
        const env = ExprTrack.buildEnv(&env_storage, transport, self.ctl_bindings[0..self.ctl_count], dry_tick, scene);
        // Front the query with the frame path's own fixed budget
        // (`Eval.evalPatternTrack`'s exact shape): the query allocates
        // solely from the handed-in allocator, so `OutOfMemory` here can
        // ONLY mean the budget — a diagnostic, not a compile abort.
        var fba = std.heap.FixedBufferAllocator.init(try self.dryScratch(PatternTrack.SCRATCH_BYTES));
        var result = PatternTrack.queryCycle(fba.allocator(), self.tree, self.schema, pattern_node, dry_tick, env) catch |err| switch (err) {
            error.OutOfMemory => {
                try self.emit(.pattern_eval_failed, self.tree.spanOf(pattern_node), "pattern exceeds the {d}-KiB frame evaluation budget in the dry-run cycle", .{PatternTrack.SCRATCH_BYTES / 1024});
                return false;
            },
            // The engine's deterministic ceilings (depth / hap / byte
            // budgets, tick overflow) — same outcome on every host.
            else => {
                try self.emit(.pattern_eval_failed, self.tree.spanOf(pattern_node), "pattern failed to evaluate: {s}", .{@errorName(err)});
                return false;
            },
        };
        defer result.deinit();
        if (result.diagnostics.len > 0) {
            // Forward the engine's own diagnostics (malformed
            // combinators, broken expr leaves) — their spans index the
            // same tree, so they land on the offending head.
            for (result.diagnostics) |d| {
                try self.emit(.pattern_eval_failed, d.span, "pattern: {s}", .{d.message});
            }
            return false;
        }
        if (result.dropped > 0) {
            // Belt-and-braces: a hap whose expr leaf failed at query
            // time after passing the engine's static check.
            try self.emit(.pattern_eval_failed, self.tree.spanOf(pattern_node), "pattern expression failed to evaluate in the dry-run cycle ({d} hap(s) dropped)", .{result.dropped});
            return false;
        }
        for (result.haps) |hap| {
            if (PatternTrack.coerce(hap.value) == null) {
                try self.emit(.pattern_result_invalid, self.tree.spanOf(pattern_node), "pattern values must be finite numbers — symbols, strings, keywords, booleans, and nil cannot drive a target", .{});
                return false;
            }
        }
        return true;
    }

    fn buildKey(self: *Builder, map: *const TimeMap, key_form: NodeIndex, want_ncomp: u8, offset: TrackTable.Tick) Error!?TrackTable.Key {
        const tree = self.tree;
        const children = tree.formHeader(key_form).children;

        const at_node = kvNode(tree, children, "at").?;
        // Scene-relative: the offset anchors an s-unit position under a
        // tempo map (wall-clock from the scene start).
        const local = try self.posToTickLocal(map, at_node, offset) orelse return null;
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

        var ease_ref: u16 = 0; // programs[0] — the manifest's `:default linear`
        if (kvNode(tree, children, "ease")) |ease_node| {
            ease_ref = try self.buildEase(ease_node);
        }
        return .{ .at = at, .value = val.value, .ease_ref = ease_ref };
    }

    /// `:at` / `:dur` → ticks at the transport origin. Unit set is
    /// manifest-validated [b bar s]. Sugar for `posToTickLocal` with a
    /// zero anchor — the two are the same math there.
    fn posToTick(self: *Builder, map: *const TimeMap, node: NodeIndex) Error!?TrackTable.Tick {
        return self.posToTickLocal(map, node, 0);
    }

    /// `:at` / `:dur` → a LOCAL tick offset from `anchor` (the caller
    /// folds the anchor back in, as it always did for scene-relative
    /// positions). b/bar are pure tick offsets — exact, map-free. An
    /// `s`-unit value under a tempo map is wall-clock FROM THE ANCHOR:
    /// `tickFromSeconds(secondsFromTick(anchor) + v) - anchor` — one
    /// conversion each way, both through `TimeMap` (the only converter).
    /// The degenerate (constant) map keeps the historical single
    /// conversion verbatim — anchoring would perturb the float path and
    /// break the bit-stability pin; the two agree in exact math.
    /// Returns null after emitting on overflow (non-finite literals
    /// cannot reach here — the lexer owns number syntax).
    fn posToTickLocal(self: *Builder, map: *const TimeMap, node: NodeIndex, anchor: TrackTable.Tick) Error!?TrackTable.Tick {
        const nu = self.tree.numberWithUnitOf(node);
        const converted = if (std.mem.eql(u8, nu.unit, "b"))
            map.tickFromBeats(nu.value)
        else if (std.mem.eql(u8, nu.unit, "bar"))
            map.tickFromBars(nu.value)
        else blk: {
            std.debug.assert(std.mem.eql(u8, nu.unit, "s"));
            if (map.segments.len <= 1 or anchor == 0)
                break :blk map.tickFromSeconds(nu.value);
            break :blk if (map.tickFromSeconds(map.secondsFromTick(anchor) + nu.value)) |abs|
                abs - anchor
            else |err|
                err;
        };
        return converted catch {
            try self.emit(.tick_overflow, self.tree.spanOf(node), "position overflows the tick grid", .{});
            return null;
        };
    }

    // ---- effective values (author kvpair, else the schema's :default) ----

    /// The effective `:key` on `form` as a number. The author's literal
    /// when written, else the manifest's `:default` — never a constant
    /// restated here. Null only when the key is absent from both, which
    /// for a defaulted key the validator has already ruled out.
    fn effNumber(self: *const Builder, form: NodeIndex, key: []const u8) ?f64 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |node| readNumber(self.tree, node),
            .default => |entry| switch (entry.value) {
                .number => |x| x,
                else => null,
            },
        };
    }

    /// The effective `:key` on `form` as a symbol name. Member-set typed
    /// in every current use, so callers map the text to their enum.
    /// (The overlay normalizes a `:default` symbol to `Expr.Value.keyword`
    /// — `MaterializedDefaults.literalToValue`'s documented rule.)
    fn effSymbol(self: *const Builder, form: NodeIndex, key: []const u8) ?[]const u8 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |node| self.tree.symbolText(node),
            .default => |entry| switch (entry.value) {
                .keyword => |k| k,
                .string => |str| str,
                else => null,
            },
        };
    }

    /// Component `i` of the effective vector-valued `:key` on `form`.
    /// Element count is manifest-guaranteed on both arms (`vector-shape`
    /// on the author's, the loader's literal type-check on the default's).
    fn effVecNumber(self: *const Builder, form: NodeIndex, key: []const u8, i: usize) ?f64 {
        const ev = self.view.getEffectiveValue(form, key) orelse return null;
        return switch (ev) {
            .author => |node| readNumber(self.tree, self.tree.vectorElements(node)[i]),
            .default => |entry| switch (entry.value) {
                .vector => |elems| switch (elems[i]) {
                    .number => |x| x,
                    else => null,
                },
                else => null,
            },
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
            const code: Easing.Op = if (std.mem.eql(u8, self.effSymbol(node, "jump").?, "start"))
                .steps_start
            else
                .steps_end;
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
        const periods = self.effNumber(node, "periods").?;
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

    /// Dedup-append into the program table. The returned ref always
    /// indexes a live program (cap overflow degrades to 0 = linear).
    fn intern(self: *Builder, prog: Easing.Program, node: NodeIndex) Error!u16 {
        std.debug.assert(self.programs_len >= 1); // programs[0] = linear, seeded
        std.debug.assert(self.programs_len <= TrackTable.MAX_EASE_PROGRAMS);
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

    /// Merge the compose-mode `(target …)` declarations into the join,
    /// replacing `self.targets`. The host registries keep their indices
    /// (`0..host.len`); a declared name the host does NOT provide is
    /// appended in document order under its `:arity`/`:registry`, so a
    /// score compiles, corpus-tests, and lints with no host at all. Rules
    /// (host-authoritative on a name match, per the plan):
    ///   - a duplicate declared `:name` (twice in the score) →
    ///     `target_decl_invalid` (independent of the host);
    ///   - a name the host also provides: its arity must equal the host's,
    ///     else `target_arity_mismatch`; the declared `:registry` is ignored
    ///     (host wins) and the declaration is otherwise a no-op;
    ///   - a declared-only name: appended, its join index becoming its id.
    /// Missing `:name`/`:arity`, or overrunning `MAX_TARGETS`, is
    /// `target_decl_invalid`. Any diagnostic nulls the table via the diag
    /// gate. The merged slice is compile-arena-backed and surfaced on
    /// `CompileResult.targets`.
    fn buildTargetJoin(self: *Builder) Error!void {
        const tree = self.tree;
        const host_len = self.targets.len;
        var merged: std.ArrayList(Target) = .empty;
        try merged.appendSlice(self.arena, self.targets);
        // Declared names seen so far — catches a duplicate declaration
        // whether or not the host also provides the name.
        var declared: std.ArrayList([]const u8) = .empty;

        for (self.forest) |idx| {
            if (!isForm(tree, idx, "target")) continue;
            const children = tree.formHeader(idx).children;
            const name_node = kvNode(tree, children, "name");
            const arity_node = kvNode(tree, children, "arity");
            if (name_node == null or arity_node == null) {
                try self.emit(.target_decl_invalid, tree.spanOf(idx), "target declaration requires :name and :arity", .{});
                continue;
            }
            const name = tree.symbolText(name_node.?);
            // :arity / :registry are manifest-bounded integers (1..4 / 0..255).
            const arity: u8 = @intFromFloat(readNumber(tree, arity_node.?).?);
            const registry: u8 = @intFromFloat(self.effNumber(idx, "registry").?);

            // A name declared twice in the score is a defect regardless of
            // whether the host also provides it.
            if (containsName(declared.items, name)) {
                try self.emit(.target_decl_invalid, tree.spanOf(name_node.?), "duplicate target declaration `{s}`", .{name});
                continue;
            }
            declared.append(self.arena, name) catch return error.OutOfMemory;

            if (indexOfTarget(merged.items[0..host_len], name)) |i| {
                // Host provides it: host-authoritative; only arity must agree.
                if (merged.items[i].ncomp != arity) {
                    try self.emit(.target_arity_mismatch, tree.spanOf(arity_node.?), "declared arity {d} for `{s}` disagrees with the host's {d}", .{ arity, name, merged.items[i].ncomp });
                }
                continue;
            }
            if (merged.items.len >= MAX_TARGETS) {
                try self.emit(.target_decl_invalid, tree.spanOf(idx), "more than {d} targets after declarations", .{MAX_TARGETS});
                break;
            }
            merged.append(self.arena, .{
                .name = self.arena.dupe(u8, name) catch return error.OutOfMemory,
                .ncomp = arity,
                .registry = registry,
            }) catch return error.OutOfMemory;
        }

        self.targets = merged.items;
        self.merged_targets = merged.items;
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

/// Index of the first target named `name`, or null. Linear like
/// `resolveTarget`; join sizes are small (host tens, cap 1024).
fn indexOfTarget(targets: []const Target, name: []const u8) ?usize {
    for (targets, 0..) |tg, i| {
        if (std.mem.eql(u8, tg.name, name)) return i;
    }
    return null;
}

/// True when `names` already holds `name` — the duplicate-declaration test.
fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
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
    var v = try validate(t.allocator, test_support.schema(), minimal_score);
    defer v.deinit();
    for (v.result.diagnostics) |d| {
        std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    }
    try t.expect(!v.hasErrors());
}

test "composed easing program validates clean" {
    var v = try validate(t.allocator, test_support.schema(),
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
    var v = try validate(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target x (key :at 4 :value 0.5))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
    try t.expect(v.findDiag(.unit_required) != null);
}

test "wrong unit on a position slot is rejected" {
    var v = try validate(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target x (key :at 4ms :value 0.5))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "unknown easing name is rejected" {
    var v = try validate(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target x
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1 :ease bouncy-magic))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "unknown form head is rejected" {
    var v = try validate(t.allocator, test_support.schema(), "(timeline :bpm 120)");
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "(key …) is local to (track …) — a stray one at the top level is unknown" {
    // `key` is declared inside `(form :name track …)`, reachable only through
    // the `key-section` head-set on track's positional slot. At the top level
    // it resolves against nothing.
    var v = try validate(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(key :at 0b :value 1)
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "(stage …) is local to (seq …) — a stray one at the top level is unknown" {
    var v = try validate(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(stage :ease linear :t 1 :v 1)
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "the locals stay reachable where they belong — keys in a track, stages in a seq" {
    var v = try validate(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target x
        \\  (key :at 0b :value 0)
        \\  (key :at 2b :value 1 :ease (seq
        \\    (stage :ease out-quad :t 1 :v 1.2)
        \\    (stage :ease in-quad :t 1 :v -0.2))))
    );
    defer v.deinit();
    try t.expect(!v.hasErrors());
}

test "diagnostic spans map back into user source" {
    const bad_source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target x (key :at 4 :value 0.5))
    ;
    var v = try validate(t.allocator, test_support.schema(), bad_source);
    defer v.deinit();
    const d = v.findDiag(.unit_required).?;
    const user_start = d.span.start;
    // The offending literal `4` sits inside the user text.
    try t.expectEqualStrings("4", bad_source[user_start .. user_start + 1]);
}

test "empty source validates clean (no data forms, no diagnostics)" {
    var v = try validate(t.allocator, test_support.schema(), "");
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
    var r = try compile(t.allocator, test_support.schema(), minimal_score, &test_targets);
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
    var r = try compile(t.allocator, test_support.schema(),
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
    var r = try compile(t.allocator, test_support.schema(),
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
    var r = try compile(t.allocator, test_support.schema(),
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

// ---- compose-mode (target …) declarations ----

test "compose-mode: a standalone score compiles against an empty host registry" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(target :name glow :arity 1 :registry 0)
        \\(target :name tint :arity 3 :registry 0)
        \\(transport :bpm 120)
        \\(track :target glow
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8))
        \\(track :target tint
        \\  (key :at 0b :value [1 0 0])
        \\  (key :at 4b :value [0 0 1]))
    , &.{});
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    // The declarations ARE the join now: glow=id0 arity1, tint=id1 arity3.
    try t.expectEqual(@as(usize, 2), r.targets.len);
    try t.expectEqualStrings("glow", r.targets[0].name);
    try t.expectEqual(@as(u8, 1), r.targets[0].ncomp);
    try t.expectEqualStrings("tint", r.targets[1].name);
    try t.expectEqual(@as(u8, 3), r.targets[1].ncomp);
    const table = r.table.?;
    try t.expectEqual(@as(u16, 0), table.tracks[0].target_id);
    try t.expectEqual(@as(u16, 1), table.tracks[1].target_id);
    try t.expectEqual(@as(u8, 3), table.tracks[1].ncomp);
}

test "compose-mode: declared targets merge with the host registry (host authoritative on a name match)" {
    // Host: circle-radius(1,reg0), tint(3,reg0), cutoff(1,reg1). The score
    // restates circle-radius (consistent), tries to move tint to reg 5
    // (host wins — ignored), and declares a decl-only glow at reg 2.
    var r = try compile(t.allocator, test_support.schema(),
        \\(target :name circle-radius :arity 1 :registry 0)
        \\(target :name tint :arity 3 :registry 5)
        \\(target :name glow :arity 1 :registry 2)
        \\(transport :bpm 120)
        \\(track :target glow (key :at 0b :value 0.5))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    // Host ids 0..2 preserved; glow appends at id 3 with its declared registry.
    try t.expectEqual(@as(usize, 4), r.targets.len);
    try t.expectEqualStrings("tint", r.targets[1].name);
    try t.expectEqual(@as(u8, 0), r.targets[1].registry); // host wins; :registry 5 ignored
    try t.expectEqualStrings("glow", r.targets[3].name);
    try t.expectEqual(@as(u8, 2), r.targets[3].registry);
    try t.expectEqual(@as(u16, 3), r.table.?.tracks[0].target_id);
}

test "compose-mode: a declared arity disagreeing with the host is target_arity_mismatch" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(target :name circle-radius :arity 3)
        \\(transport :bpm 120)
        \\(track :target circle-radius (key :at 0b :value [1 1 1]))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.target_arity_mismatch) != null);
}

test "compose-mode: a duplicate target declaration is target_decl_invalid" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(target :name glow :arity 1)
        \\(target :name glow :arity 1)
        \\(transport :bpm 120)
        \\(track :target glow (key :at 0b :value 1))
    , &.{});
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.target_decl_invalid) != null);
}

test "compose-mode: a target declaration missing :name or :arity is target_decl_invalid" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(target :registry 0)
        \\(transport :bpm 120)
    , &.{});
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.target_decl_invalid) != null);
}

test "compile diagnostics: transport missing / seq nesting / weights" {
    var missing = try compile(t.allocator, test_support.schema(), "(track :target tint (key :at 0b :value [1 1 1]))", &test_targets);
    defer missing.deinit();
    try t.expect(!missing.ok());
    try t.expect(missing.findDiag(.transport_missing) != null);

    var nested = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1
        \\    :ease (seq (stage :ease (seq (stage :ease linear :t 1 :v 1)) :t 1 :v 1))))
    , &test_targets);
    defer nested.deinit();
    try t.expect(!nested.ok());
    try t.expect(nested.findDiag(.ease_nesting_unsupported) != null);

    var weights = try compile(t.allocator, test_support.schema(),
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
    var r = try compile(t.allocator, test_support.schema(),
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

test "hex literals reach the score language — 0xFF is 255, everywhere a number is" {
    // SJON 1.2.0 opened `0x` as an integer literal, and pacer inherits the
    // MEANING for free: `(* 0xFF x)` used to evaluate to 0 (an unknown
    // symbol), silently. Nothing in pacer decides this — `readNumber`
    // already accepted the integer tags — so the point of the test is that
    // the inheritance cannot regress unnoticed.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id mask :value 0xFF)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0x10)
        \\  (key :at 1b :value 1 :ease (steps :n 0x8)))
        \\(track :target cutoff :expr (* 0xFF 2))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;
    try t.expectEqual(@as(f32, 255), table.controls[0].value[0]);
    try t.expectEqual(@as(f32, 16), table.keys[0].value[0]);
    // (steps :n 0x8) — the stair count rides the program's first param.
    const stairs = table.programs[table.keys[1].ease_ref];
    try t.expectEqual(@as(f32, 8), stairs.stages[0].ops[0].params[0]);
}

test "values that narrow to f32 must FIT — 1e39 is refused, not encoded as +inf" {
    // The determinism seam is "a single f64→f32 truncation at emission",
    // and nothing checked that the f64 *fits*: `:value 1e39` used to
    // compile clean and reach the write buffer as +inf. `(repr-shape :type
    // f32)` on `plain-number` / `stage-weight` refuses it at compile, with
    // a span. Range-only by design — precision loss (16777217 losing its
    // low bit) stays the emitter's accepted step.
    //
    // EVERY slot reports the same code, and that is SJON's rule, not a
    // pacer choice: a union whose alternatives are disjoint by node shape
    // reports the arm the value could only have meant
    // (portable-manifest §4.9, SJON ask 15). A number in a `key-value`
    // slot can only have meant `plain-number`, a vector only `vec-value`,
    // so the union spelling says what the bare kind says. It used to
    // collapse to `union_no_branch_matched` naming two kinds and no
    // cause — the rule landed, its message did not, and the corpus case
    // `diag-repr-f32` was written around the swallow.
    const cases = [_][:0]const u8{
        // …a scalar key value (union slot, scalar arm)…
        "(transport :bpm 120)\n(track :target circle-radius (key :at 0b :value 1e39))",
        // …a vector component (union slot, vector arm)…
        "(transport :bpm 120)\n(track :target tint (key :at 0b :value [0 -1e39 0]))",
        // …a control's document value (union slot)…
        "(transport :bpm 120)\n(control :id knob :value 1e39)",
        // …a seq stage's time weight and value span (bare kinds)…
        "(transport :bpm 120)\n(track :target circle-radius\n  (key :at 0b :value 0)\n  (key :at 1b :value 1 :ease (seq (stage :ease linear :t 1e39 :v 1))))",
        "(transport :bpm 120)\n(track :target circle-radius\n  (key :at 0b :value 0)\n  (key :at 1b :value 1 :ease (seq (stage :ease linear :t 1 :v 1e39))))",
        // …and a bezier control point (vector element, bare kind).
        "(transport :bpm 120)\n(track :target circle-radius\n  (key :at 0b :value 0)\n  (key :at 1b :value 1 :ease (cubic-bezier :p [0.4 1e39 0.2 1])))",
    };
    for (cases) |src| {
        var r = try compile(t.allocator, test_support.schema(), src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        const d = r.validated.findDiag(.repr_out_of_range) orelse {
            std.debug.print("expected repr_out_of_range; got:\n", .{});
            for (r.validated.result.diagnostics) |got| std.debug.print("  {s}: {s}\n", .{ @tagName(got.code), got.message });
            return error.TestUnexpectedResult;
        };
        // The span lands on the offending literal, in score coordinates.
        try t.expect(std.mem.indexOf(u8, src[d.span.start..d.span.end], "1e39") != null);
    }

    // The boundary of the rule above, and the reason the arm can be
    // trusted: an arm is determined PER VALUE. A string reaches neither
    // alternative of `key-value`, nothing else could have been meant is
    // false, and the union's own report is what stands.
    var no_arm = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius (key :at 0b :value "nope"))
    , &test_targets);
    defer no_arm.deinit();
    try t.expect(!no_arm.ok());
    try t.expect(no_arm.validated.findDiag(.union_no_branch_matched) != null);

    // The largest f32 still compiles — the bound is the type's, not a
    // hand-picked ceiling.
    var edge = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius (key :at 0b :value 3.4028234663852886e38))
    , &test_targets);
    defer edge.deinit();
    try t.expect(edge.ok());
}

test "compile diagnostics: keys XOR expr — both is a conflict" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  :expr (+ beat 0)
        \\  (key :at 0b :value 0.2))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.track_source_conflict) != null);
}

test "compile accepts pattern tracks: node recorded, walk-opaque interior" {
    // The pattern interior (`fast`, `pure`, …) is SJON Pattern
    // vocabulary, not pacer schema — `:walk-opaque` keeps the validator
    // out, exactly like `:expr`. The fixture exercises a combinator, a
    // fastcat vector, literal numbers, AND an expr leaf — everything the
    // Phase 2 dry-run must accept for a sound pattern.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target circle-radius :pattern (fast 2 [0.2 (pure (+ 0.1 0.2))]))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;
    try t.expectEqual(@as(usize, 1), table.tracks.len);
    try t.expectEqual(@as(usize, 0), table.keys.len);
    try t.expect(table.tracks[0].source == .pattern);
}

test "compile diagnostics: pattern XOR keys XOR expr — any pairing is a conflict" {
    var with_keys = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  :pattern [0 1]
        \\  (key :at 0b :value 0.2))
    , &test_targets);
    defer with_keys.deinit();
    try t.expect(!with_keys.ok());
    try t.expect(with_keys.findDiag(.track_source_conflict) != null);

    // :expr vs :pattern is a COUNT over two declared keys, so the
    // manifest's `(exclusive-group :cardinality at-most-one …)` owns it —
    // the group cannot see `(key …)` children, which is why the two
    // pairings above stay pacer's.
    var with_expr = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  :expr (+ beat 0)
        \\  :pattern [0 1])
    , &test_targets);
    defer with_expr.deinit();
    try t.expect(!with_expr.ok());
    try t.expect(with_expr.validated.findDiag(.mutually_exclusive_keys_present) != null);
}

test "compile diagnostics: pattern dry-run — a malformed combinator fails at load with spans" {
    // `(fast 2)` is missing its pattern argument. The engine collects an
    // arity diagnostic (degrading the node to silence) and the dry-run
    // forwards it as `pattern_eval_failed` — same tree, so the span
    // lands on the offending head in score coordinates.
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target circle-radius :pattern (fast 2))
    ;
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    const diag = r.findDiag(.pattern_eval_failed).?;
    const start = diag.span.start;
    try t.expectEqualStrings("fast", source[start..diag.span.end]);
}

test "compile diagnostics: pattern dry-run runs under the frame budget — over-budget cycle 0 fails at load" {
    // The dry-run queries cycle 0 under the SAME fixed scratch the frame
    // path evaluates with (`PatternTrack.SCRATCH_BYTES`), so "compiles
    // clean" implies "plays at cycle 0" — no silent every-frame omission
    // for a load-accepted pattern. FBA exhaustion is deterministic (same
    // allocation sequence on every host), so acceptance stays a pure
    // function of the document.
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target circle-radius :pattern (fast 8000 (pure 1)))
    ;
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    const diag = r.findDiag(.pattern_eval_failed).?;
    try t.expect(std.mem.indexOf(u8, diag.message, "budget") != null);
    // The span lands on the `:pattern` value node.
    const start = diag.span.start;
    try t.expect(std.mem.indexOf(u8, source[start..diag.span.end], "fast 8000") != null);

    // Guard against over-tightening: a comfortably-dense-but-fitting
    // pattern must still load.
    var dense = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius :pattern (fast 64 (pure 1)))
    , &test_targets);
    defer dense.deinit();
    for (dense.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(dense.ok());
}

test "compile diagnostics: expr dry-run runs under the frame budget — over-budget expr fails at load" {
    // PROBE (plan elegance/04 Phase 2): whether an expr can out-allocate
    // `ExprTrack.SCRATCH_BYTES` below SJON Expr's own ceilings
    // (`MAX_EVAL_BYTES` is 64 MiB, so the byte ceiling does not trip
    // first). A wide sum allocates one arena `Value` per literal.
    const wide = "(+ " ++ ("1.5 " ** 20000) ++ ")";
    const source: [:0]const u8 =
        "(transport :bpm 120)\n(track :target circle-radius :expr " ++ wide ++ ")";
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    const diag = r.findDiag(.expr_eval_failed).?;
    try t.expect(std.mem.indexOf(u8, diag.message, "budget") != null);
}

test "compile diagnostics: pattern payloads must be finite numbers — pattern_result_invalid" {
    // Symbol atoms (`bd`) are legal pattern vocabulary but violate the
    // write contract (a track's value is a finite number). The dry-run
    // checks EVERY hap in the dry-run cycle, so the defect fails at
    // load even though tick 0's hap (0.5) is fine.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius :pattern [0.5 bd])
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.pattern_result_invalid) != null);
}

test "compile diagnostics: a pattern on a multi-component target is pattern_result_invalid" {
    // `PatValue` has no vector variant — a pattern can only ever drive a
    // scalar target this slice, so the impossible pairing is rejected at
    // load regardless of the pattern's content.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target tint :pattern [0.2 0.7])
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.pattern_result_invalid) != null);
}

test "compile patterns: a scened pattern dry-runs at its scene start" {
    // `(slowcat 0.5 bd)` plays child i at cycle i: cycle 0 is the sound
    // number 0.5, cycle 1 the invalid symbol `bd`. Top-level the dry-run
    // queries cycle 0 and accepts (the bd at cycle 1 is a frame-path
    // omission, the expr-at-t=0 limitation); a scene opening at bar 1
    // dry-runs the cycle containing its start — and catches bd at load.
    var top = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius :pattern (slowcat 0.5 bd))
    , &test_targets);
    defer top.deinit();
    for (top.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(top.ok());

    var scened = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(scene :name drop :at 1bar :dur 1bar
        \\  (track :target circle-radius :pattern (slowcat 0.5 bd)))
    , &test_targets);
    defer scened.deinit();
    try t.expect(!scened.ok());
    try t.expect(scened.findDiag(.pattern_result_invalid) != null);
}

test "compile patterns: hap exprs read pacer's time env under the pattern-local shadows" {
    // `beat` is a pacer time binding, not a pattern-local: before the env
    // threading (SJON `queryTreeWithEnv`) this failed the engine's static
    // leaf check at load (UnknownBinding → pattern_eval_failed). The dry-run
    // now chains pacer's env under the `cycle`/`tick`/`seed` shadows — the
    // frozen env-merge design — so the document is sound.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target circle-radius :pattern (pure (* beat 2)))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
}

test "compile patterns: hap exprs read document control values" {
    // Controls bind in the env's parent scope exactly as for `:expr`
    // tracks — the dry-run binds the document `:value`.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id sway :value 0.5)
        \\(track :target circle-radius :pattern (pure (* sway 2)))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
}

test "compile patterns: an unbound name in a hap expr still fails at load" {
    // The env is additive, not a blanket resolver — a genuinely unknown
    // name keeps its honest load failure.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius :pattern (pure (* nope 2)))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.pattern_eval_failed) != null);
}

test "pattern diagnostic codes are wire-stable appendices" {
    // Pinned wire values — Code is append-only and crosses in 'PACD'.
    // Both codes ride the load-time dry-run (tests above); the frame
    // path surfaces the same failures as counted omissions.
    try t.expectEqual(@as(u16, 27), @intFromEnum(Code.pattern_eval_failed));
    try t.expectEqual(@as(u16, 28), @intFromEnum(Code.pattern_result_invalid));
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
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    const unknown = r.findDiag(.expr_eval_failed).?;
    // The span points at the whole expression in score coordinates.
    const start = unknown.span.start;
    try t.expectEqualStrings("(* radius-knob 2)", source[start..unknown.span.end]);
}

test "compile diagnostics: expr result shape — arity, boolean, typo'd func" {
    // The fourth track locks Expr's form-construction semantics: a head
    // that is no expr-func (`sine`) evaluates to a form LITERAL, not
    // `UnknownFunction` — it must still fail the dry-run, as a shape
    // defect.
    var r = try compile(t.allocator, test_support.schema(),
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
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
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
    // The :value span is the commit-to-text anchor, in score coordinates.
    const vs_start = knob.value_span.start;
    const vs_end = knob.value_span.end;
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
    var r = try compile(t.allocator, test_support.schema(),
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

test "control: :min/:max exist for slider and xy, not for color" {
    // `:min`/`:max` are editor RANGE metadata — meaningful for a slider
    // and an xy pad, meaningless for a colour picker. `:discriminant type`
    // plus one `(variant :when [slider xy] …)` says so in the manifest, so
    // a range on a colour control is `unknown_key` instead of validating
    // clean and riding into 'PACM' as noise.
    var color = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id tint-pick :type color :target tint :min [0 0 0] :value [1 0 0])
    , &test_targets);
    defer color.deinit();
    try t.expect(!color.ok());
    try t.expect(color.validated.findDiag(.unknown_key) != null);

    // Both selected values keep their ranges…
    var ranged = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id knob :type slider :min 0 :max 1 :value 0.25)
        \\(control :id pad :type xy :min [-1 -1] :max [1 1] :value [0 0])
    , &test_targets);
    defer ranged.deinit();
    for (ranged.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(ranged.ok());

    // …and so does a control with no :type at all: the discriminant
    // resolves from the manifest's `:default slider` (effective axis D),
    // which is why B3's default and this variant have to land together.
    var defaulted = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id knob :min 0 :max 1 :value 0.25)
    , &test_targets);
    defer defaulted.deinit();
    for (defaulted.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(defaulted.ok());
    try t.expectEqual(TrackTable.ControlType.slider, defaulted.table.?.controls[0].kind);
}

test "control: a variant key written BEFORE the discriminant is unknown" {
    // SJON resolves the variant from the discriminant kvpair as the walk
    // reaches it, so `:min` ahead of an explicit `:type` is `unknown_key`
    // — the same text with the keys swapped validates. Characterization:
    // the rule is SJON's (portable-manifest §5.3), and the manifest's
    // `:description` tells authors to put `:type` first. Omitting `:type`
    // entirely is unaffected — the default applies to the whole form.
    var before = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id knob :min 0 :type slider :value 0.25)
    , &test_targets);
    defer before.deinit();
    try t.expect(!before.ok());
    try t.expect(before.validated.findDiag(.unknown_key) != null);

    var after = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id knob :type slider :min 0 :value 0.25)
    , &test_targets);
    defer after.deinit();
    try t.expect(after.ok());
}

test "compile diagnostics: control defects" {
    var r = try compile(t.allocator, test_support.schema(),
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
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius :expr (* late-knob 0.5))
        \\(control :id late-knob :value 0.8)
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
}

test "compile leaves table null when SJON validation already failed" {
    var r = try compile(t.allocator, test_support.schema(), "(transport :bpm 120)(track :target x (key :at 4 :value 1))", &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expectEqual(@as(usize, 0), r.diagnostics.len); // SJON's own diagnostic carries it
    try t.expect(r.validated.findDiag(.unit_required) != null);
}

/// Compile `source` and assert exactly that `code` was raised (the score
/// is defective, so the table is null).
fn expectDiag(source: [:0]const u8, code: Code) !void {
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
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
    var r = try compile(t.allocator, test_support.schema(), "(transport :bpm 120 :emit [beat bar phase])", &targets);
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
        var r = try compile(t.allocator, test_support.schema(), "(transport :bpm 120 :emit [beat beat])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.transport_invalid) != null);
    }
    // A symbol that is not an emittable time name.
    {
        var r = try compile(t.allocator, test_support.schema(), "(transport :bpm 120 :emit [wobble])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.transport_invalid) != null);
    }
    // A reserved time name that is NOT emittable (tick/cycle/dur) is
    // rejected too — the emit set is a subset of the env bindings.
    {
        var r = try compile(t.allocator, test_support.schema(), "(transport :bpm 120 :emit [tick])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.transport_invalid) != null);
    }
    // An emittable name absent from every host registry.
    {
        var r = try compile(t.allocator, test_support.schema(), "(transport :bpm 120 :emit [phase])", &scalar);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.unknown_target) != null);
    }
    // An emittable name resolving to a non-scalar target.
    {
        const vec = [_]Target{.{ .name = "beat", .ncomp = 2 }};
        var r = try compile(t.allocator, test_support.schema(), "(transport :bpm 120 :emit [beat])", &vec);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.target_arity_mismatch) != null);
    }
}

test "compile transport :emit diagnostics carry the offending entry's span" {
    const scalar = [_]Target{.{ .name = "beat", .ncomp = 1 }};
    const source: [:0]const u8 = "(transport :bpm 120 :emit [beat wobble])";
    var r = try compile(t.allocator, test_support.schema(), source, &scalar);
    defer r.deinit();
    const d = r.findDiag(.transport_invalid).?;
    const start = d.span.start;
    const end = d.span.end;
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
        var r = try compile(t.allocator, test_support.schema(), try zterm(a, &src), &test_targets);
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
        var r = try compile(t.allocator, test_support.schema(), try zterm(a, &src), &test_targets);
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
        var r = try compile(t.allocator, test_support.schema(), try zterm(a, &src), &test_targets);
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
        var r = try compile(t.allocator, test_support.schema(), try zterm(a, &src), &test_targets);
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
        var r = try compile(t.allocator, test_support.schema(), src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.scene_invalid) != null);
    }
}

test "compile diagnostics: two scenes named drop → scene_duplicate_name" {
    var r = try compile(t.allocator, test_support.schema(),
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
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(r.findDiag(.scene_cap_exceeded) != null);
}

test "compile accepts a valid scene: no diagnostics" {
    // A well-formed scene compiles clean; its nested (track …) rows are
    // pinned by the table-shape tests below.
    var r = try compile(t.allocator, test_support.schema(),
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
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;

    // The scene records its window on the tick grid (1b = 180180 ticks).
    const ppb: i64 = 180180;
    try t.expectEqual(@as(usize, 1), table.scenes.len);
    try t.expectEqual(@as(i64, 160 * ppb), table.scenes[0].start_tick);
    try t.expectEqual(@as(i64, 60 * ppb), table.scenes[0].dur_ticks);
    // The name span slices `drop` straight out of the score source.
    const ns = table.scenes[0].name_span;
    try t.expectEqualStrings("drop", source[ns.start..ns.end]);

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
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(scene :name edge :at 30000000000000b :dur 4b
        \\  (track :target circle-radius (key :at 30000000000000b :value 0)))
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.tick_overflow) != null);
}

// --- scenes (plan 01 Phase 3: eval semantics) ------------------------

test "compile diagnostics: scene-beat/scene-phase are unbound at the top level" {
    // The scene-local env exists ONLY inside a (scene …); a top-level
    // :expr referencing it fails the dry-run (UnknownBinding → the
    // expr_eval_failed code) — the guard that these names are never bound
    // globally. Inside a scene they resolve (see the Eval tests).
    for ([_][:0]const u8{
        "(transport :bpm 120)\n(track :target circle-radius :expr scene-beat)",
        "(transport :bpm 120)\n(track :target circle-radius :expr scene-phase)",
    }) |src| {
        var r = try compile(t.allocator, test_support.schema(), src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.expr_eval_failed) != null);
    }
}

// --- triggers (plan 02 Phase 1: schema + validation) -----------------

test "compile diagnostics: trigger source COUNT is the schema's, its VALUES are pacer's" {
    // Exactly one of :every (periodic) / :at (explicit hits) — a count, so
    // an `(exclusive-group :cardinality exactly-one …)` in the manifest
    // owns it: neither is `required_one_of_missing`, both is
    // `mutually_exclusive_keys_present`, each with a span.
    var none = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(trigger :target circle-radius)
    , &test_targets);
    defer none.deinit();
    try t.expect(!none.ok());
    try t.expect(none.validated.findDiag(.required_one_of_missing) != null);

    var both = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(trigger :target circle-radius :every 2b :at [4b 8b])
    , &test_targets);
    defer both.deinit();
    try t.expect(!both.ok());
    try t.expect(both.validated.findDiag(.mutually_exclusive_keys_present) != null);

    // What a group cannot count — the interval's VALUE — stays pacer's.
    var zero = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(trigger :target circle-radius :every 0b)
    , &test_targets);
    defer zero.deinit();
    try t.expect(!zero.ok());
    try t.expect(zero.findDiag(.trigger_invalid) != null);
}

test "compile diagnostics: trigger empty or unsorted :at → trigger_invalid" {
    // The explicit list must be non-empty and strictly ascending in TICK
    // order (so [1bar 2b] — descending once converted — is rejected too),
    // since which event a tie resolves to would be source-order luck.
    const cases = [_][:0]const u8{
        "(transport :bpm 120)\n(trigger :target circle-radius :at [])",
        "(transport :bpm 120)\n(trigger :target circle-radius :at [8b 4b])",
        "(transport :bpm 120)\n(trigger :target circle-radius :at [4b 4b])",
        "(transport :bpm 120)\n(trigger :target circle-radius :at [1bar 2b])",
    };
    for (cases) |src| {
        var r = try compile(t.allocator, test_support.schema(), src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.trigger_invalid) != null);
    }
}

test "trigger: :offset without :every is dependent_key_missing, not a silent no-op" {
    // `:offset` phases a PERIODIC schedule; with an explicit `:at` list, or
    // with no source at all, it means nothing. It used to be documented as
    // "ignored without :every" and quietly dropped — the one silent no-op
    // in the score language. `:requires [every]` in the manifest makes it a
    // diagnostic with a span (and an LSP quick-fix), from SJON's side.
    const cases = [_][:0]const u8{
        "(transport :bpm 120)\n(trigger :target circle-radius :offset 1b)",
        "(transport :bpm 120)\n(trigger :target circle-radius :at [4b 8b] :offset 1b)",
    };
    for (cases) |src| {
        var r = try compile(t.allocator, test_support.schema(), src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.validated.findDiag(.dependent_key_missing) != null);
    }

    // …and the pairing that means something still compiles.
    var ok = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(trigger :target circle-radius :every 2b :offset 1b)
    , &test_targets);
    defer ok.deinit();
    try t.expect(ok.ok());
}

test "compile diagnostics: trigger unknown target → unknown_target" {
    // A trigger joins its target like a track — an unresolved name reuses
    // the existing unknown_target code (no trigger-specific target code).
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(trigger :target nonexistent :every 2b)
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.unknown_target) != null);
}

test "compile trigger diagnostics carry a user span" {
    const source: [:0]const u8 = "(transport :bpm 120)\n(trigger :target circle-radius :every 0b)";
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    const d = r.findDiag(.trigger_invalid).?;
    // The :every value is the offending node; its span maps into the user
    // text and slices `0b`.
    const start = d.span.start;
    const end = d.span.end;
    try t.expectEqualStrings("0b", source[start..end]);
}

test "compile accepts valid triggers: periodic + explicit list" {
    // A well-formed trigger emits no diagnostic; its table row and
    // lanes are pinned by the trigger-shape and Eval tests.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(trigger :target circle-radius :every 2b :offset 1b)
        \\(trigger :target cutoff :at [160b 220b 256b])
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    try t.expectEqual(@as(usize, 0), r.diagnostics.len);
}

// --- triggers (plan 02 Phase 2: compile into the table) --------------

test "compile triggers: periodic schedule builds a table row" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(trigger :target circle-radius :every 2b :offset 1b)
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;
    // A trigger is a table row of its own kind, joined against the
    // registry like a track, but with no keys (its lanes are eval-derived).
    try t.expectEqual(@as(usize, 1), table.tracks.len);
    try t.expectEqual(@as(usize, 0), table.keys.len);
    const tr = table.tracks[0];
    try t.expectEqual(@as(u16, 0), tr.target_id);
    try t.expectEqual(@as(u8, 0), tr.registry);
    try t.expectEqual(@as(u8, 1), tr.ncomp);
    try t.expectEqual(TrackTable.NO_SCENE, tr.scene);
    try t.expect(tr.source == .trigger);
    const sched = tr.source.trigger;
    try t.expect(sched == .periodic);
    const ppb: i64 = 180180;
    try t.expectEqual(@as(i64, 2 * ppb), sched.periodic.every);
    try t.expectEqual(@as(i64, 1 * ppb), sched.periodic.offset);
}

test "compile triggers: periodic :offset defaults to 0" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(trigger :target circle-radius :every 4b)
    , &test_targets);
    defer r.deinit();
    try t.expect(r.ok());
    const sched = r.table.?.tracks[0].source.trigger;
    try t.expectEqual(@as(i64, 4 * 180180), sched.periodic.every);
    try t.expectEqual(@as(i64, 0), sched.periodic.offset);
}

test "compile triggers: explicit :at builds an owned ascending tick slice" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(trigger :target cutoff :at [160b 220b 256b])
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const tr = r.table.?.tracks[0];
    try t.expectEqual(@as(u8, 1), tr.registry); // cutoff is a registry-1 target
    try t.expectEqual(@as(u8, 1), tr.ncomp);
    try t.expect(tr.source == .trigger);
    const sched = tr.source.trigger;
    try t.expect(sched == .at);
    const ppb: i64 = 180180;
    try t.expectEqual(@as(usize, 3), sched.at.len);
    try t.expectEqual(@as(i64, 160 * ppb), sched.at[0]);
    try t.expectEqual(@as(i64, 220 * ppb), sched.at[1]);
    try t.expectEqual(@as(i64, 256 * ppb), sched.at[2]);
}

test "compile triggers: a scened trigger walks scene-relative and carries the scene index" {
    // Both schedule kinds fold the scene start in — the :at ticks and the
    // periodic :offset become absolute, exactly like a scened track's keys.
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name drop :at 160b :dur 60b
        \\  (trigger :target circle-radius :at [0b 4b])
        \\  (trigger :target cutoff :every 2b :offset 1b))
    ;
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;
    const ppb: i64 = 180180;
    try t.expectEqual(@as(usize, 1), table.scenes.len);
    try t.expectEqual(@as(usize, 2), table.tracks.len);

    const at_tr = table.tracks[0];
    try t.expectEqual(@as(u16, 0), at_tr.scene);
    try t.expectEqual(@as(i64, 160 * ppb), at_tr.source.trigger.at[0]);
    try t.expectEqual(@as(i64, 164 * ppb), at_tr.source.trigger.at[1]);

    const per_tr = table.tracks[1];
    try t.expectEqual(@as(u16, 0), per_tr.scene);
    try t.expectEqual(@as(i64, 2 * ppb), per_tr.source.trigger.periodic.every);
    try t.expectEqual(@as(i64, 161 * ppb), per_tr.source.trigger.periodic.offset);
}

test "compile triggers: scene-relative schedule overflow → tick_overflow" {
    // The scene start and the event position each convert inside the grid,
    // but their sum overflows i64 — the fold seam raises tick_overflow, for
    // both an explicit :at position and a periodic :offset.
    const cases = [_][:0]const u8{
        \\(transport :bpm 120)
        \\(scene :name edge :at 30000000000000b :dur 4b
        \\  (trigger :target circle-radius :at [30000000000000b]))
        ,
        \\(transport :bpm 120)
        \\(scene :name edge :at 30000000000000b :dur 4b
        \\  (trigger :target circle-radius :every 2b :offset 30000000000000b))
    };
    for (cases) |src| {
        var r = try compile(t.allocator, test_support.schema(), src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.tick_overflow) != null);
    }
}

test "compile triggers: a trigger past MAX_TRACKS → track_cap_exceeded" {
    // A trigger counts as a table row: fill the table with plain tracks,
    // then the trailing trigger is the row that trips the cap.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "(transport :bpm 120)\n");
    for (0..TrackTable.MAX_TRACKS) |_|
        try src.appendSlice(a, "(track :target circle-radius (key :at 0b :value 0))\n");
    try src.appendSlice(a, "(trigger :target circle-radius :every 2b)\n");
    try src.append(a, 0);
    const source = src.items[0 .. src.items.len - 1 :0];
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(r.findDiag(.track_cap_exceeded) != null);
}

test "compile never panics on stray top-level atoms (fuzz regression)" {
    // A parseable document whose data forest holds a NON-form node (a
    // bare atom or vector) must degrade to a diagnostic, never trap:
    // buildTransport / buildTracks / buildControls once called formHeader
    // on every forest node without a tagOf guard. drv_load reaches this
    // path, so this is a real crash surface, not a test-only one.
    for ([_][:0]const u8{ "5", "[1 2 3]", "nil" }) |src| {
        var r = try compile(t.allocator, test_support.schema(), src, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok()); // no transport → not loadable, but no panic
    }
}

// ---- (tempo …) tempo-map segments (plan it/01) ----

test "tempo-map: a clean multi-segment score compiles with 0 diags" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 125 :meter [4 4] :dur 400b :end loop)
        \\(tempo :at 160b :bpm 150)
        \\(tempo :at 200b :bpm 96.5)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0.2)
        \\  (key :at 300b :value 0.8))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const ppb: i64 = 180180;
    const segs = r.table.?.transport.segments;
    try t.expectEqual(@as(usize, 3), segs.len);
    try t.expectEqual(@as(i64, 0), segs[0].start_tick);
    try t.expectEqual(@as(f64, 125), segs[0].bpm);
    try t.expectEqual(@as(i64, 160 * ppb), segs[1].start_tick);
    try t.expectEqual(@as(f64, 150), segs[1].bpm);
    try t.expectEqual(@as(i64, 200 * ppb), segs[2].start_tick);
    try t.expectEqual(@as(f64, 96.5), segs[2].bpm);
}

test "tempo-map: a mapless score still carries segment 0 (the transport's own :bpm)" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius (key :at 0b :value 0.5))
    , &test_targets);
    defer r.deinit();
    try t.expect(r.ok());
    const segs = r.table.?.transport.segments;
    try t.expectEqual(@as(usize, 1), segs.len);
    try t.expectEqual(@as(i64, 0), segs[0].start_tick);
    try t.expectEqual(@as(f64, 120), segs[0].bpm);
}

test "tempo-map: a missing :at or :bpm is tempo_map_invalid with the form's span" {
    const cases = [_][:0]const u8{
        \\(transport :bpm 120)
        \\(tempo :bpm 150)
        ,
        \\(transport :bpm 120)
        \\(tempo :at 160b)
    };
    for (cases) |source| {
        var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        const d = r.findDiag(.tempo_map_invalid).?;
        const start = d.span.start;
        try t.expectEqualStrings("(tempo", source[start..][0..6]);
    }
}

test "tempo-map: :at 0b, negative, seconds-unit, descending, duplicate → tempo_map_invalid" {
    const cases = [_][:0]const u8{
        \\(transport :bpm 120)
        \\(tempo :at 0b :bpm 150)
        ,
        \\(transport :bpm 120)
        \\(tempo :at -4b :bpm 150)
        ,
        \\(transport :bpm 120)
        \\(tempo :at 30s :bpm 150)
        ,
        \\(transport :bpm 120)
        \\(tempo :at 200b :bpm 150)
        \\(tempo :at 160b :bpm 96.5)
        ,
        \\(transport :bpm 120)
        \\(tempo :at 160b :bpm 150)
        \\(tempo :at 160b :bpm 96.5)
    };
    for (cases) |source| {
        var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
        defer r.deinit();
        try t.expect(!r.ok());
        try t.expect(r.findDiag(.tempo_map_invalid) != null);
    }
}

test "tempo-map: the seconds-unit rejection spans the offending :at literal" {
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(tempo :at 30s :bpm 150)
    ;
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    const d = r.findDiag(.tempo_map_invalid).?;
    const start = d.span.start;
    const end = d.span.end;
    try t.expectEqualStrings("30s", source[start..end]);
}

test "tempo-map: more than MAX_TEMPO_SEGMENTS segments is tempo_map_invalid" {
    // 513 generated forms: segment 0 + 511 forms fill the cap; the 512th
    // form is the first overflowing one (the walk stops there).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "(transport :bpm 120)\n");
    for (0..513) |i| {
        const line = try std.fmt.allocPrint(a, "(tempo :at {d}b :bpm 130)\n", .{(i + 1) * 4});
        try src.appendSlice(a, line);
    }
    try src.append(a, 0);
    const source = src.items[0 .. src.items.len - 1 :0];
    var r = try compile(t.allocator, test_support.schema(), source, &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    const d = r.findDiag(.tempo_map_invalid).?;
    try t.expect(std.mem.indexOf(u8, d.message, "512") != null);
}

test "tempo-map: s-unit key positions resolve through the piecewise map" {
    // 120 bpm 4/4 doubling to 240 at beat 4 (tick 720720, wall-clock
    // 2 s). A key at 3 s is 1 s past the boundary — 4 beats at 240 —
    // landing on beat 8 (tick 1441440), NOT the constant-bpm beat 6.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(tempo :at 4b :bpm 240)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 3s :value 1))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const keys = r.table.?.trackKeys(&r.table.?.tracks[0]);
    try t.expectEqual(@as(i64, 1441440), keys[1].at);
}

test "tempo-map: scene :at / :dur and trigger :at in s are map-correct" {
    // scene :at 3s → tick 1441440; :dur 1s is wall-clock FROM THE SCENE
    // START (3 s → 4 s = 4 beats at 240) → 720720 ticks, not the
    // origin-tempo 360360. The trigger hit at 3s matches the scene start.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(tempo :at 4b :bpm 240)
        \\(scene :name drop :at 3s :dur 1s
        \\  (track :target circle-radius (key :at 0b :value 1)))
        \\(trigger :target cutoff :at [3s])
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;
    try t.expectEqual(@as(i64, 1441440), table.scenes[0].start_tick);
    try t.expectEqual(@as(i64, 720720), table.scenes[0].dur_ticks);
    try t.expectEqual(@as(i64, 1441440), table.tracks[1].source.trigger.at[0]);
}

test "tempo-map: a scened key in s anchors at the scene start" {
    // Scene starts at beat 4 = the tempo boundary (wall-clock 2 s). A
    // key 1 s into the scene runs at 240 bpm → local 720720 ticks,
    // absolute 1441440 — the constant math would land at 1081080.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(tempo :at 4b :bpm 240)
        \\(scene :name drop :at 4b :dur 8b
        \\  (track :target circle-radius
        \\    (key :at 0b :value 0)
        \\    (key :at 1s :value 1)))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const keys = r.table.?.trackKeys(&r.table.?.tracks[0]);
    try t.expectEqual(@as(i64, 1441440), keys[1].at);
}

test "tempo-map: transport :dur in s converts from the origin; loop_secs is exact" {
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4] :dur 3s :end loop)
        \\(tempo :at 4b :bpm 240)
        \\(track :target circle-radius (key :at 0b :value 0))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    // 3 s = 2 s of 120 bpm (720720) + 1 s of 240 (720720) = 1441440.
    try t.expectEqual(@as(?i64, 1441440), r.table.?.transport.dur);
    try t.expectEqual(@as(?f64, 3.0), r.table.?.transport.loop_secs);
}

test "tempo-map: a (tempo …) with no (transport …) is still transport_missing, never a crash" {
    // Segment 0 IS the transport's :bpm — without a transport there is no
    // map to join, so the existing transport_missing verdict stands and
    // the orphaned (tempo …) forms are simply never walked.
    var r = try compile(t.allocator, test_support.schema(),
        \\(tempo :at 160b :bpm 150)
    , &test_targets);
    defer r.deinit();
    try t.expect(!r.ok());
    try t.expect(r.findDiag(.transport_missing) != null);
}

// ---------------------------------------------------------------------------
// Tests — the schema's `:default` is the source, the compiler is the mirror
// ---------------------------------------------------------------------------

/// The `KeySpec` the manifest declares for `<form>`'s `:<key>`, searching
/// slot-local forms too (`key` lives inside `track`, `stage` inside `seq`).
fn schemaKey(form_name: []const u8, key_name: []const u8) ?sjon.Plugin.KeySpec {
    return findSchemaKey(test_support.schema().preloaded.plugins[0].forms, form_name, key_name);
}

fn findSchemaKey(forms: []const sjon.Plugin.FormSpec, form_name: []const u8, key_name: []const u8) ?sjon.Plugin.KeySpec {
    for (forms) |f| {
        if (std.mem.eql(u8, f.name, form_name)) {
            for (f.keys) |k| {
                if (std.mem.eql(u8, k.name, key_name)) return k;
            }
        }
        if (findSchemaKey(f.local_forms, form_name, key_name)) |k| return k;
    }
    return null;
}

/// Every default this schema declares, so a new one cannot be added
/// without deciding where the compiler reads it.
const declared_defaults = [_]struct { form: []const u8, key: []const u8 }{
    .{ .form = "transport", .key = "meter" },
    .{ .form = "transport", .key = "end" },
    .{ .form = "control", .key = "type" },
    .{ .form = "target", .key = "registry" },
    .{ .form = "steps", .key = "jump" },
    .{ .form = "spring", .key = "periods" },
    .{ .form = "key", .key = "ease" },
};

test "defaults: every one is declared in the manifest, not only in prose" {
    for (declared_defaults) |d| {
        const k = schemaKey(d.form, d.key) orelse {
            std.debug.print("no such schema key: ({s} :{s})\n", .{ d.form, d.key });
            return error.TestUnexpectedResult;
        };
        if (k.default == null) {
            std.debug.print("({s} :{s}) declares no :default\n", .{ d.form, d.key });
            return error.TestUnexpectedResult;
        }
    }
}

test "defaults: the omitted-key table matches what the manifest declares" {
    // The drift gate the two-source arrangement never had: compile a score
    // that omits every defaulted key, then compare the resulting table
    // against the schema's OWN declared default — not against a literal
    // repeated here.
    var r = try compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(target :name glow :arity 1)
        \\(control :id knob :value 0.5)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1))
        \\(track :target tint
        \\  (key :at 0b :value [0 0 0])
        \\  (key :at 1b :value [1 1 1] :ease (chain (steps :n 4) (spring :damping 1))))
    , &test_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());
    const table = r.table.?;

    // (transport :meter [4 4]) — the bar length.
    const meter = schemaKey("transport", "meter").?.default.?;
    try t.expectEqual(meter.vector[0].number, @as(f64, @floatFromInt(table.transport.map.beats_per_bar)));

    // (transport :end hold)
    const end = schemaKey("transport", "end").?.default.?;
    try t.expectEqualStrings(end.symbol, @tagName(table.transport.end));

    // (control :type slider)
    const ctype = schemaKey("control", "type").?.default.?;
    try t.expectEqualStrings(ctype.symbol, @tagName(table.controls[0].kind));

    // (target :registry 0) — `glow` is declared-only, so its registry is
    // the declaration's, appended past the three host entries.
    const reg = schemaKey("target", "registry").?.default.?;
    try t.expectEqualStrings("glow", r.targets[3].name);
    try t.expectEqual(reg.number, @as(f64, @floatFromInt(r.targets[3].registry)));

    // (steps :jump end) and (spring :periods 3) — read back off the
    // compiled program of the last key's chain.
    const run = table.tracks[1].source.keys;
    const chain = table.programs[table.keys[run.start + 1].ease_ref];
    const jump = schemaKey("steps", "jump").?.default.?;
    var jump_buf: [32]u8 = undefined;
    try t.expectEqualStrings(
        try std.fmt.bufPrint(&jump_buf, "steps_{s}", .{jump.symbol}),
        @tagName(chain.stages[0].ops[0].code),
    );
    // A spring's compiled params are (lambda, omega); omega = 2π × periods.
    const periods = schemaKey("spring", "periods").?.default.?;
    try t.expectEqual(Easing.Op.spring, chain.stages[0].ops[1].code);
    try t.expectEqual(
        @as(f32, @floatCast(2.0 * std.math.pi * periods.number)),
        chain.stages[0].ops[1].params[1],
    );

    // (key :ease linear) — `programs[0]` IS the schema's default made
    // structural, and an omitted `:ease` refs it.
    const ease = schemaKey("key", "ease").?.default.?;
    try t.expectEqual(@as(u16, 0), table.keys[0].ease_ref);
    try t.expectEqual(Easing.op_names.get(ease.symbol).?, table.programs[0].stages[0].ops[0].code);
}
