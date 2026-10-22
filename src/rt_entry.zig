//! `pacer-rt.wasm` entry — static zones + the `prt_*` export surface
//! (02 T2.2): the PLAYBACK runtime. No compiler enters this file's
//! import closure (T2.3 audits it); the score arrives as a `'PACB'`
//! blob produced offline by `pacer pack`, never as text.
//!
//! The artifact is a pure function of its linear memory: no clock, no
//! loop. The host writes the `'PACB'` blob and the `'PACT'` target
//! registry into the zones below, calls `prt_load`, then calls
//! `prt_eval(seconds)` per frame and reads the `'PACW'` write buffer
//! back. Blob formats live in `Pacb` / `PactCodec` / `Writes`; this
//! file is zone plumbing, the transactional lifecycle, and the C4/C5
//! load-time work (table materialization + expr dry-runs, joined since
//! P4/A2 by the pattern dry-run, and since the ask30/M4 adoption of
//! 2026-10-22 by the per-track prepared state the pattern seams query).
//!
//! ## Memory zones
//!
//! ```
//! pacb     PACB_CAP  ← host writes 'PACB' blob   (prt_pacbPtr/prt_pacbCap)
//! targets   64 KiB   ← host writes 'PACT' blob   (prt_targetsPtr/prt_targetsCap)
//! meta     (score)   → score's OWN 'PACM' copy   (prt_metaPtr/prt_metaLen)
//! writes   ~7.8 KiB  → driver writes 'PACW'      (prt_writesPtr)
//! heap               ← decoded score arena + evaluator (page_allocator)
//! ```
//!
//! **Zone resource policy (R-I2):** the static PACB zone IS the hard
//! input byte cap — `prt_load` with `pacb_len > PACB_CAP` is status 2
//! (bad call), the same class as oversize text under `MAX_DOC_SIZE` on
//! the drv side. This is a **whole-blob length policy, never a
//! per-string rejection** — a format-valid blob whose ids exceed the
//! 256-byte allowance but whose total length fits the zone LOADS (the
//! format is deliberately uncapped, 01:257-258; fewer targets ⇒ smaller
//! `'REGS'` ⇒ long ids fit). The **decoded heap** (the score's single
//! arena: DecodedScore + materialized table + payload arrays) is
//! separate from the static zone and bounded by the format caps.
//!
//! ## Lifecycle
//!
//! `prt_load(pacb_len, targets_len)` → status:
//!   0 ok — score live, `prt_eval` armed;
//!   1 refused — the blob failed decode or a load gate; `prt_loadError`
//!       holds the u16 reason (see `refusalReason`);
//!   2 bad call — lengths out of range or malformed `'PACT'` (host
//!       bug); the arguments are validated first, so NOTHING changed —
//!       any live score, runtime state, meta, and `prt_loadError` stay
//!       exactly as they were;
//!   3 out of memory — distinguished from a refusal; a payload/budget
//!     failure is NEVER reported as OOM (a dry-run budget exhaustion is
//!     refusal reason 11, the same doctrine as `Compile`'s dry-run).
//!
//! Reloading is TRANSACTIONAL: once the arguments validate, the fresh
//! score is decoded, gated, materialized, dry-run, and armed in new
//! memory BEFORE the old one is touched; only a fully successful build
//! swaps. Every refusal leaves the previously loaded score evaluable
//! with ALL runtime state intact (held control values, dynamic slots,
//! a bpm nudge, the `expr_failures` counter). A successful reload
//! replaces everything — hosts re-apply held widgets after one.
//!
//! `prt_loadError` is written ONLY on a status-1 refusal: a bad call is
//! a true no-op including the reason word, and success/OOM leave the
//! previous reason in place (it is meaningless until the first
//! refusal; initial value 0).
//!
//! `prt_eval`/`prt_evalTicks` return the encoded `'PACW'` length, or 0
//! when nothing is loaded / the host clock is out of range (non-finite
//! or beyond the 2^53 tick ceiling). `prt_metaPtr`/`prt_metaLen` serve
//! the score's own embedded `'PACM'` copy — the pointer MOVES across
//! loads (re-fetch after every `prt_load`); it never aliases the PACB
//! zone. Control exports mirror the `drv_*` twins' semantics
//! (`prt_registerControl` returns `0xffffffff` when rejected).
//!
//! Append-only surface: never remove or re-type an export — bump
//! `prt_abiVersion` if the contract itself must change.

const std = @import("std");
const builtin = @import("builtin");
const RtSjon = @import("RtSjon.zig");
const PactCodec = @import("PactCodec.zig");
const Pacb = @import("Pacb.zig");
const EvalCore = @import("EvalCore.zig");
const ExprTrack = @import("ExprTrack.zig");
const PatternTrack = @import("PatternTrack.zig");
const TrackTable = @import("TrackTable.zig");
const Writes = @import("Writes.zig");

/// On wasm32 `page_allocator` IS the WasmAllocator (heap.zig dispatches
/// `isWasm`); natively it is PageAllocator — one spelling, both targets.
/// Page-granule frees make a stale read after teardown fault instead of
/// silently resurrecting old bytes (the ownership tests lean on this).
/// Native-only counting seam (C4/C5): `native_rt_bridge.zig` exports a
/// setter for the allocator in use; a native perf harness can point it at
/// a counting GPA without changing one byte of the shipped wasm32 artifact
/// (the whole seam is comptime-eliminated there). The default is
/// page_allocator, so every existing native consumer is unchanged.
const gpa = if (builtin.target.cpu.arch.isWasm())
    std.heap.page_allocator
else
    NativeGpa.allocator;

var gpa_dummy: u8 = 0;

pub const NativeGpa = struct {
    pub var gpa_ptr: *anyopaque = @ptrCast(&gpa_dummy);
    pub var gpa_vtable: *const std.mem.Allocator.VTable = std.heap.page_allocator.vtable;

    const allocator: std.mem.Allocator = .{ .ptr = undefined, .vtable = &vtable };

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        return gpa_vtable.alloc(gpa_ptr, len, alignment, ret_addr);
    }
    fn resize(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return gpa_vtable.resize(gpa_ptr, memory, alignment, new_len, ret_addr);
    }
    fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return gpa_vtable.remap(gpa_ptr, memory, alignment, new_len, ret_addr);
    }
    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        gpa_vtable.free(gpa_ptr, memory, alignment, ret_addr);
    }
};

/// Per-id byte allowance for the PACB zone's worst-case sum — the
/// `wasm_entry.zig:93-97` precedent verbatim: the format allows 64 KiB
/// ids; that generosity is not worth zone bytes here.
const PACB_STR_ALLOWANCE: usize = 256;
const PACB_CAP: usize = Pacb.pacbWorstCase(PACB_STR_ALLOWANCE);
const MAX_TARGETS_BLOB: usize = 64 * 1024;
/// Sized for the true full house — every emit lane, track, document
/// control, and dynamic slot writing on one frame, derived from
/// `EvalCore.MAX_FRAME_ENTRIES` (the same constant `initContext` sizes
/// against), so the `catch unreachable` on encode holds by construction.
const WRITES_CAP: usize = Writes.encodedLen(EvalCore.MAX_FRAME_ENTRIES);

/// `prt_registerControl` failure sentinel.
const NO_SLOT: u32 = 0xffff_ffff;

comptime {
    // The cap rides a u32 export; the worst-case sum must fit it.
    std.debug.assert(PACB_CAP <= std.math.maxInt(u32));
    // The zone holds at least a header + full directory — the smallest
    // spelling of any blob the format can refuse past the magic.
    std.debug.assert(PACB_CAP >= Pacb.HEADER_LEN + Pacb.MAX_SECTIONS * Pacb.DIRECTORY_ENTRY_LEN);
    // A registered slot index always fits the u32 return.
    std.debug.assert(TrackTable.MAX_CONTROLS + EvalCore.MAX_DYNAMIC_CONTROLS < NO_SLOT);
}

// ---------------------------------------------------------------------------
// Static zones + live state
// ---------------------------------------------------------------------------

var pacb_buffer: [PACB_CAP]u8 = undefined;
var targets_buffer: [MAX_TARGETS_BLOB]u8 = undefined;
var writes_buffer: [WRITES_CAP]u8 align(4) = undefined;

/// Decoded 'PACT' scratch — names alias `targets_buffer`, validated and
/// consumed entirely inside `prt_load` (the pack-time join is baked
/// into the blob; the decoded targets themselves are not kept).
var targets_scratch: [PactCodec.MAX_TARGETS]PactCodec.Target = undefined;

/// What `prt_metaPtr` hands back when nothing is loaded (len is 0).
var meta_fallback: [1]u8 = .{0};

/// The one live score, heap-allocated so its address (and the
/// evaluator's `table` pointer into it) is stable for the score's
/// whole lifetime. Ownership: the score's arena is the ONE free —
/// `table_arena` is its child (the materialized table, control/scene
/// copies, spans, and the parallel payload slice allocate from it), and
/// the evaluator's arena is another child. Teardown is ordered:
/// evaluator first (it borrows the table), then `score.deinit()` frees
/// every chunk at once, then the shell itself.
const RtScore = struct {
    score: Pacb.DecodedScore,
    table_arena: std.heap.ArenaAllocator,
    table: TrackTable,
    /// Compact expr payloads PARALLEL to `table.tracks` (null on every
    /// non-expr track) — the binary arm's leaf (C4): the table's
    /// `.expr` node index is the inert `.invalid` sentinel, never read.
    expr_payloads: []?[]const u8,
    /// Compact pattern payloads, PARALLEL to `table.tracks` (null on
    /// every non-pattern track) — the binary pattern arm's leaf
    /// (P4/A2): the table's `.pattern` node index is the inert
    /// `.invalid` sentinel, never read.
    pattern_payloads: []?[]const u8,
    /// The prepared state, PARALLEL to `table.tracks` (null on every
    /// non-pattern track) — the ask30/M4 adoption (2026-10-22): each
    /// `.pattern` track's payload decoded ONCE at load into an owned,
    /// self-contained prepared object (`PatternTrack.materializePrepared`
    /// through the audited `RtSjon.BinaryDecoder` window). The slice and
    /// every tree are score-arena allocations: the ONE free
    /// (`score.deinit()`) reclaims all of it on every path — success,
    /// refusal, OOM — transactionally, so no explicit teardown exists
    /// and none can be missed. The evaluator borrows the pointees
    /// read-only (`LeafSource.binary.pattern_prepared`); the frame and
    /// dry-run seams query them under each call's own env.
    pattern_prepared: []?RtSjon.PatternQuery.PreparedBinary,
    evaluator: EvalCore.Evaluator,
};

var live: ?*RtScore = null;

/// The last status-1 refusal's reason (see `refusalReason`); written
/// ONLY on a refusal — bad calls are true no-ops including this word.
var load_error: u16 = 0;

const LoadStatus = enum(u32) { ok = 0, refused = 1, bad_call = 2, oom = 3 };

/// The frozen many-to-one refusal-reason map (02:127-131, R-O3) — u16,
/// append-only. Two review-flagged stretches, named for the eyeball
/// (the mapping itself is 02-frozen): the decoder's plural
/// `unsupported_features` lands on 02's singular `unsupported_feature`,
/// and `non_canonical` (the missing-`'PACM'` / ordering class) rides
/// `section_out_of_bounds`. `7 non_finite` is frozen in 02's ordered
/// list but emitted by no v1 path (append-only reserve — the decoder
/// carries finiteness in the record family); `11 dry_run_failed` arises
/// entry-side (C5), never from the decoder.
fn refusalReason(code: Pacb.RefusalCode) u16 {
    return switch (code) {
        .bad_magic => 0,
        .unsupported_version => 1,
        .unsupported_features => 2,
        .directory_malformed => 3,
        .count_mismatch, .non_canonical => 4,
        .transport_invalid, .tempo_invalid, .record_invalid, .key_invalid, .ease_invalid, .trigger_invalid, .scene_invalid, .control_invalid, .strs_invalid, .decl_invalid => 5,
        .cap_exceeded => 6,
        .payload_malformed => 8,
        .registry_mismatch => 9,
        .meta_malformed, .meta_incoherent => 10,
    };
}

/// The binary arm's per-arm schema contract: the frozen core ⊕ pattern
/// aggregate (the pattern row joined at P4/A2 per 02:345-353's named
/// delta; user heads never enter a binary because pack refuses them —
/// 01, decision 8). File-scope so the slice's pointee outlives every
/// evaluator built against it.
const core_plugins = [_]RtSjon.Plugin.Plugin{ RtSjon.plugins.core.plugin, RtSjon.plugins.pattern.plugin };
const rt_schema: RtSjon.Schema.Schema = .{ .plugins = &core_plugins };

// ---------------------------------------------------------------------------
// Exports — zone access
// ---------------------------------------------------------------------------

export fn prt_abiVersion() u32 {
    return 1;
}

export fn prt_pacbPtr() [*]u8 {
    return &pacb_buffer;
}

export fn prt_pacbCap() u32 {
    return PACB_CAP;
}

export fn prt_targetsPtr() [*]u8 {
    return &targets_buffer;
}

export fn prt_targetsCap() u32 {
    return MAX_TARGETS_BLOB;
}

export fn prt_metaPtr() [*]const u8 {
    if (live) |shell| return shell.score.pacm.ptr;
    return &meta_fallback;
}

export fn prt_metaLen() u32 {
    if (live) |shell| return @intCast(shell.score.pacm.len);
    return 0;
}

export fn prt_writesPtr() [*]const u8 {
    return &writes_buffer;
}

// ---------------------------------------------------------------------------
// Exports — lifecycle + frame path
// ---------------------------------------------------------------------------

export fn prt_load(pacb_len: u32, targets_len: u32) u32 {
    // Validate the host's arguments BEFORE anything else, so a bad call
    // is a true no-op: the live score, runtime state, meta, and
    // `load_error` all stay exactly as they were.
    if (pacb_len > PACB_CAP or targets_len > MAX_TARGETS_BLOB)
        return @intFromEnum(LoadStatus.bad_call);
    const host_blob = targets_buffer[0..targets_len];
    _ = PactCodec.decodeTargets(host_blob, &targets_scratch) orelse
        return @intFromEnum(LoadStatus.bad_call);

    // TRANSACTIONAL: the fresh score is decoded, gated, materialized,
    // dry-run, and armed in NEW memory before the old one is touched.
    // Every refusal below leaves the previously loaded score evaluable
    // with ALL runtime state intact (held controls, dynamic slots, a
    // bpm nudge, the `expr_failures` counter); only a fully successful
    // build swaps.
    var refusal: Pacb.Refusal = undefined;
    var score = Pacb.decode(gpa, pacb_buffer[0..pacb_len], &refusal) catch |err| switch (err) {
        error.Refused => {
            load_error = refusalReason(refusal.code);
            return @intFromEnum(LoadStatus.refused);
        },
        error.OutOfMemory => return @intFromEnum(LoadStatus.oom),
    };

    // Registry gate: the host join must BE the pack-time join — the
    // canonical-'PACT' byte equality is the one spelling of mismatch
    // (review O-2). Pattern-capable blobs load since P4/A2: the
    // `required_features` bit0 gate is GONE — the load-time pattern
    // dry-run (`dryRunPatterns`) is the pattern class's acceptance
    // gate now, the text path's compile dry-run doctrine.
    if (!Pacb.canonicalPactEquals(host_blob, score.regs)) {
        score.deinit();
        load_error = refusalReason(.registry_mismatch);
        return @intFromEnum(LoadStatus.refused);
    }

    const shell = gpa.create(RtScore) catch {
        score.deinit();
        return @intFromEnum(LoadStatus.oom);
    };
    // THE MOVE: from here on every failure path tears down `shell.score`
    // (its arena state is the live copy), never the dead local.
    shell.score = score;
    shell.table_arena = std.heap.ArenaAllocator.init(shell.score.arena.allocator());
    if (!materialize(shell)) {
        shell.score.deinit();
        gpa.destroy(shell);
        return @intFromEnum(LoadStatus.oom);
    }
    const dry_ok = dryRunExprs(shell) catch {
        shell.score.deinit();
        gpa.destroy(shell);
        return @intFromEnum(LoadStatus.oom);
    };
    if (!dry_ok) {
        shell.score.deinit();
        gpa.destroy(shell);
        load_error = DRY_RUN_FAILED;
        return @intFromEnum(LoadStatus.refused);
    }
    // ask30/M4 (2026-10-22; ordering wording corrected 2026-10-22 in the
    // record-fix slice — comment only, no behavior change): materialize
    // the prepared state AFTER the expr dry-run and BEFORE the pattern
    // dry-run, which queries it — state building for patterns sits
    // between the two gates, not ahead of both. This is not a blanket
    // "prepare before the dry-runs": if a payload could reach prepare
    // malformed, the earlier expr-dry refusal (11) would mask prepare's
    // payload-malformed class (8). That input class does not exist
    // through the production loader — decode's structural walk
    // (Pacb.decodePayloads) has already refused everything in prepare's
    // typed malformed set — so the ordering above is unobservable and no
    // refusal class is ever masked. A prepare failure remains the
    // payload-malformed CLASS (never a trap).
    switch (preparePatterns(shell) catch {
        shell.score.deinit();
        gpa.destroy(shell);
        return @intFromEnum(LoadStatus.oom);
    }) {
        .ok => {},
        .malformed => {
            shell.score.deinit();
            gpa.destroy(shell);
            load_error = refusalReason(.payload_malformed);
            return @intFromEnum(LoadStatus.refused);
        },
    }
    const pattern_dry_ok = dryRunPatterns(shell) catch {
        shell.score.deinit();
        gpa.destroy(shell);
        return @intFromEnum(LoadStatus.oom);
    };
    if (!pattern_dry_ok) {
        shell.score.deinit();
        gpa.destroy(shell);
        load_error = DRY_RUN_FAILED;
        return @intFromEnum(LoadStatus.refused);
    }
    shell.evaluator = EvalCore.Evaluator.initContext(shell.score.arena.allocator(), .{
        .table = &shell.table,
        .source = .{ .binary = .{
            .expr = shell.expr_payloads,
            .pattern = shell.pattern_payloads,
            .pattern_prepared = shell.pattern_prepared,
        } },
        .schema = rt_schema,
    }) catch {
        shell.score.deinit();
        gpa.destroy(shell);
        return @intFromEnum(LoadStatus.oom);
    };

    // SWAP — the first and only mutation of live state: teardown the old
    // score (evaluator before its arena) and install the armed one.
    unload();
    live = shell;
    return @intFromEnum(LoadStatus.ok);
}

export fn prt_loadError() u32 {
    return load_error;
}

/// Entry-side refusal reason (02:127-131's ordered name): a dry-tick
/// evaluation failure — the decoder has no such class because it never
/// evaluates. Arises here only: the expr dry-run (C5) and, since
/// P4/A2, the pattern dry-run.
const DRY_RUN_FAILED: u16 = 11;

/// C4 materialization: build the runtime table from the decoded rows
/// into the shell's child arena. The decoded data fits the existing
/// types verbatim, with the expr/pattern arms carrying the inert
/// `.invalid` `NodeIndex` sentinel (never dereferenced — the
/// `LeafSource` union keeps the tree unreadable on this arm) and the
/// payloads riding the parallel slice. False = allocation failure.
fn materialize(shell: *RtScore) bool {
    const a = shell.table_arena.allocator();

    const tracks = a.alloc(TrackTable.Track, shell.score.tracks.len) catch return false;
    const expr_payloads = a.alloc(?[]const u8, shell.score.tracks.len) catch return false;
    const pattern_payloads = a.alloc(?[]const u8, shell.score.tracks.len) catch return false;
    for (shell.score.tracks, tracks, expr_payloads, pattern_payloads) |dt, *track, *el, *pl| {
        el.* = null;
        pl.* = null;
        const source: TrackTable.Source = switch (dt.source) {
            .keys => |ks| .{ .keys = .{ .start = ks.start, .len = ks.len } },
            .trigger => |trig| .{ .trigger = trig },
            .expr => |payload| blk: {
                el.* = payload;
                break :blk .{ .expr = .invalid };
            },
            .pattern => |payload| blk: {
                // The pattern payload rides ITS OWN parallel slice
                // (P4/A2) — never the expr slice; the arms read
                // disjoint slots and a mixed store would hand a
                // pattern payload to the expr leaf.
                pl.* = payload;
                break :blk .{ .pattern = .invalid };
            },
        };
        track.* = .{
            .target_id = dt.target_id,
            .registry = dt.registry,
            .ncomp = dt.ncomp,
            .source = source,
            .scene = dt.scene,
        };
    }
    const controls = a.alloc(TrackTable.Control, shell.score.controls.len) catch return false;
    for (shell.score.controls, controls) |dc, *control| {
        control.* = .{
            .id = dc.id,
            .target = dc.target,
            .ncomp = dc.ncomp,
            .kind = dc.kind,
            .value = dc.value,
            .min = dc.min,
            .max = dc.max,
            // Spans never cross the wire — the editor's anchors are the
            // embedded 'PACM' copy this same score owns. Inert zeros.
            .value_span = .{ .start = 0, .end = 0 },
        };
    }
    const scenes = a.alloc(TrackTable.Scene, shell.score.scenes.len) catch return false;
    for (shell.score.scenes, scenes) |ds, *scene| {
        scene.* = .{
            .name_span = .{ .start = 0, .end = 0 },
            // The binary shell's spans are inert zeros — no source to
            // borrow. Scene NAMES likewise never materialize here (the
            // plan 05 G2 ruling): the container's scene records carry
            // window fields only, nothing in the frame path reads
            // `.name`, and names reach hosts through `prt_metaPtr`'s
            // served 'PACM' copy decoded by the host glue (plan 05
            // G3). The explicit empty is the honest inert value —
            // never a false native-exact-name claim, never a borrowed
            // garbage slice.
            .name = "",
            .start_tick = ds.start_tick,
            .dur_ticks = ds.dur_ticks,
        };
    }
    const track_spans = a.alloc(RtSjon.Ast.Span, shell.score.tracks.len) catch return false;
    @memset(track_spans, .{ .start = 0, .end = 0 });
    const key_spans = a.alloc(RtSjon.Ast.Span, shell.score.keys.len) catch return false;
    @memset(key_spans, .{ .start = 0, .end = 0 });

    shell.expr_payloads = expr_payloads;
    shell.pattern_payloads = pattern_payloads;
    shell.table = .{
        .arena = shell.table_arena,
        .transport = shell.score.transport,
        .tracks = tracks,
        .keys = shell.score.keys,
        .programs = shell.score.programs,
        .controls = controls,
        .track_spans = track_spans,
        .key_spans = key_spans,
        .scenes = scenes,
    };
    return true;
}

/// C5: dry-run every expr track at its own dry tick — the scene's start
/// tick when scened, else 0 (`Compile.zig:1189` verbatim) — through the
/// SAME `evalAtBinary` the frame path will use, control ids bound with
/// their document `:value`s, under the frame's own fixed budget: an FBA
/// over `ExprTrack.SCRATCH_BYTES`, so an evaluation's `OutOfMemory` can
/// only mean the budget — a REFUSAL (reason 11), the `Compile` dry-run
/// doctrine, never a fake OOM. A genuine allocation failure of the
/// scratch itself is the real `error.OutOfMemory` (status 3).
fn dryRunExprs(shell: *RtScore) error{OutOfMemory}!bool {
    const table = &shell.table;
    std.debug.assert(table.controls.len <= TrackTable.MAX_CONTROLS);
    var any_expr = false;
    for (table.tracks) |track| {
        if (track.source == .expr) any_expr = true;
    }
    if (!any_expr) return true;
    // Lives in the score's arena — freed by `score.deinit()`, the one
    // free; never separately.
    const scratch = try shell.score.arena.allocator().alloc(u8, ExprTrack.SCRATCH_BYTES);

    var bindings_buf: [TrackTable.MAX_CONTROLS]ExprTrack.ControlBinding = undefined;
    for (table.controls, 0..) |control, i| bindings_buf[i] = ExprTrack.ControlBinding.fromControl(control);
    const bindings = bindings_buf[0..table.controls.len];

    for (table.tracks, shell.expr_payloads) |track, pl| {
        if (track.source != .expr) continue;
        const scene: ?TrackTable.Scene = if (track.scene == TrackTable.NO_SCENE) null else table.scenes[track.scene];
        const dry_tick: TrackTable.Tick = if (scene) |s| s.start_tick else 0;
        var fba = std.heap.FixedBufferAllocator.init(scratch);
        _ = ExprTrack.evalAtBinary(
            fba.allocator(),
            pl.?, // the parallel-slice invariant: an expr track carries its payload
            rt_schema,
            &table.transport,
            bindings,
            dry_tick,
            scene,
            track.ncomp,
        ) catch return false;
    }
    return true;
}

/// ask30/M4 (2026-10-22): materialize the prepared state — ONE
/// `PatternTrack.materializePrepared` per `.pattern` track, into the
/// score's own arena, so the slice and every decoded tree die with the
/// score's one free on every path (transactional by construction: a
/// refusal's teardown is the same `score.deinit()` the other gates
/// run). No env is read and no query budget is touched: the decode is
/// O(payload) once per load, outside the 1 MiB scratch.
///
/// `.malformed` = a typed prepare refusal (`BinaryDecoder`'s wire set
/// or `MultipleRoots`) — the payload-malformed class; unreachable past
/// the decode's structural walk, typed here so it propagates rather
/// than traps. `error.OutOfMemory` is the real status-3 class.
const PrepareOutcome = enum { ok, malformed };

fn preparePatterns(shell: *RtScore) error{OutOfMemory}!PrepareOutcome {
    const a = shell.score.arena.allocator();
    const prepared = try a.alloc(?RtSjon.PatternQuery.PreparedBinary, shell.table.tracks.len);
    for (prepared) |*slot| slot.* = null;
    for (shell.table.tracks, 0..) |track, ti| {
        if (track.source != .pattern) continue;
        // Parallel-slice invariant: a pattern track carries its payload.
        // A missing slot would be an inconsistent decode — the defensive
        // mapping is the payload-malformed class, never a trap.
        const payload = shell.pattern_payloads[ti] orelse return .malformed;
        prepared[ti] = PatternTrack.materializePrepared(a, payload) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .malformed,
        };
    }
    shell.pattern_prepared = prepared;
    return .ok;
}

/// P4/A2, prepared twin since the ask30/M4 adoption (2026-10-22):
/// dry-run every pattern track at its own dry tick — the scene's
/// start tick when scened, else 0 (`Compile.dryRunPattern`'s rule) —
/// through the SAME `PatternTrack.queryCyclePrepared` the frame path
/// will use, over the prepared state materialized by `preparePatterns`,
/// pacer's env bound exactly as the text path's compile dry-run
/// binds it (`ExprTrack.buildEnv`: control ids with their document
/// `:value`s, the time names at the dry tick — the pattern-locals
/// shadow them), under the frame's own fixed budget: an FBA over
/// `PatternTrack.SCRATCH_BYTES`, so an evaluation's `OutOfMemory` can
/// only mean the budget — a REFUSAL (reason 11, the `Compile` dry-run
/// doctrine), never a fake OOM. A genuine allocation failure of the
/// scratch itself is the real `error.OutOfMemory` (status 3).
///
/// Acceptance mirrors the text dry-run's gates so the two paths cannot
/// drift: the scalar-target rule, no engine diagnostics, no dropped
/// haps, and every hap in the queried cycle satisfying the numeric
/// result contract. False = refusal (reason 11).
fn dryRunPatterns(shell: *RtScore) error{OutOfMemory}!bool {
    const table = &shell.table;
    var any_pattern = false;
    for (table.tracks) |track| {
        if (track.source == .pattern) any_pattern = true;
    }
    if (!any_pattern) return true;
    // Lives in the score's arena — freed by `score.deinit()`, the one
    // free; never separately.
    const scratch = try shell.score.arena.allocator().alloc(u8, PatternTrack.SCRATCH_BYTES);

    var bindings_buf: [TrackTable.MAX_CONTROLS]ExprTrack.ControlBinding = undefined;
    for (table.controls, 0..) |control, i| bindings_buf[i] = ExprTrack.ControlBinding.fromControl(control);
    const bindings = bindings_buf[0..table.controls.len];

    for (table.tracks, 0..) |track, ti| {
        if (track.source != .pattern) continue;
        // `PatValue` has no vector variant: a pattern can only ever
        // drive a scalar target this slice — reject the statically
        // impossible pairing regardless of the pattern's content (the
        // text dry-run's first gate).
        if (track.ncomp != 1) return false;
        // Parallel-slice invariant: a pattern track carries its
        // prepared state (preparePatterns ran for every pattern track).
        const prepared = if (shell.pattern_prepared[ti]) |*p| p else return false;
        const scene: ?TrackTable.Scene = if (track.scene == TrackTable.NO_SCENE) null else table.scenes[track.scene];
        const dry_tick: TrackTable.Tick = if (scene) |s| s.start_tick else 0;
        var env_storage: ExprTrack.EnvStorage = undefined;
        const env = ExprTrack.buildEnv(&env_storage, &table.transport, bindings, dry_tick, scene);
        var fba = std.heap.FixedBufferAllocator.init(scratch);
        var result = PatternTrack.queryCyclePrepared(
            fba.allocator(),
            rt_schema,
            prepared,
            dry_tick,
            env,
        ) catch return false;
        defer result.deinit();
        if (result.diagnostics.len > 0) return false;
        if (result.dropped > 0) return false;
        for (result.haps) |hap| {
            if (PatternTrack.coerce(hap.value) == null) return false;
        }
    }
    return true;
}

/// The armed evaluator, or null when nothing is loaded.
fn liveEvaluator() ?*EvalCore.Evaluator {
    const shell = live orelse return null;
    return &shell.evaluator;
}

export fn prt_setBpm(bpm: f64) u32 {
    const ev = liveEvaluator() orelse return 1;
    return if (ev.setBpm(bpm)) 0 else 1;
}

export fn prt_setControl(index: u32, x: f32, y: f32, z: f32, w: f32) u32 {
    const ev = liveEvaluator() orelse return 1;
    return if (ev.setControl(index, .{ x, y, z, w })) 0 else 1;
}

export fn prt_clearControl(index: u32) u32 {
    const ev = liveEvaluator() orelse return 1;
    return if (ev.clearControl(index)) 0 else 1;
}

export fn prt_registerControl(target_id: u32, registry: u32, ncomp: u32) u32 {
    const ev = liveEvaluator() orelse return NO_SLOT;
    // Range-check before narrowing — host-glue input must not trap.
    if (target_id >= EvalCore.NO_TARGET or registry > 0xff or ncomp > 0xff) return NO_SLOT;
    const slot = ev.registerControl(@intCast(target_id), @intCast(registry), @intCast(ncomp)) orelse
        return NO_SLOT;
    return @intCast(slot);
}

export fn prt_eval(time_s: f64) u32 {
    const ev = liveEvaluator() orelse return 0;
    const entries = ev.evalSeconds(time_s) catch return 0;
    const out = Writes.encode(entries, &writes_buffer) catch unreachable; // WRITES_CAP = encodedLen(EvalCore.MAX_FRAME_ENTRIES)
    return @intCast(out.len);
}

/// Tick-domain twin (tests, corpus): total once loaded and in range.
export fn prt_evalTicks(tick: i64) u32 {
    const ev = liveEvaluator() orelse return 0;
    // The header's contract: out-of-range clocks return 0, mirroring the
    // seconds path. Gating here also upholds `evalTicks`'s precondition
    // (|t| ≤ MAX_TICK keeps its trigger/window integer math in i64).
    if (tick > RtSjon.Pattern.MAX_TICK or tick < -RtSjon.Pattern.MAX_TICK) return 0;
    const entries = ev.evalTicks(tick);
    const out = Writes.encode(entries, &writes_buffer) catch unreachable; // WRITES_CAP = encodedLen(EvalCore.MAX_FRAME_ENTRIES)
    return @intCast(out.len);
}

/// Debugging probe: lifetime count of frames a track's write was
/// omitted by a runtime failure (see `EvalCore.expr_failures` — expr
/// AND pattern tracks both bump it). 0 when nothing is loaded; a fresh
/// evaluator (every load) resets it. The low 32 bits of the u64
/// counter — a probe, not a semantic counter.
export fn prt_exprFailures() u32 {
    const ev = liveEvaluator() orelse return 0;
    return @truncate(ev.expr_failures);
}

/// Internal-only native harness seam (binary03 T1).
///
/// These are aliases of the PRODUCTION exports above, not wrappers: the
/// separately compiled `native_rt_bridge.zig` takes their addresses so the
/// real entry is analyzed and linked into the private native object, and
/// `src/NativeRt.zig` declares the same C signatures for consumers. The
/// namespace is visible only to that object and to source-owning tests; it
/// is NOT exported through `root.zig`, adds no wasm export, and exposes no
/// `RtScore`, evaluator, materializer, schema, allocator or wire type.
///
/// `reset` is the object-local ordered teardown: existing `unload()` first
/// (evaluator before its arena, then the score's one free), then clear the
/// last refusal word. It is idempotent and never runs implicitly.
pub const NativeHarness = struct {
    pub const abiVersion = prt_abiVersion;
    pub const pacbPtr = prt_pacbPtr;
    pub const pacbCap = prt_pacbCap;
    pub const targetsPtr = prt_targetsPtr;
    pub const targetsCap = prt_targetsCap;
    pub const load = prt_load;
    pub const loadError = prt_loadError;
    pub const metaPtr = prt_metaPtr;
    pub const metaLen = prt_metaLen;
    pub const writesPtr = prt_writesPtr;
    pub const evalSeconds = prt_eval;
    pub const evalTicks = prt_evalTicks;
    pub const setControl = prt_setControl;
    pub const clearControl = prt_clearControl;
    pub const registerControl = prt_registerControl;
    pub const setBpm = prt_setBpm;
    pub const exprFailures = prt_exprFailures;

    pub fn reset() void {
        unload();
        load_error = 0;
    }
};

fn unload() void {
    if (live) |shell| {
        // Ordered teardown: the evaluator borrows the table, the table
        // arena is the score arena's child — the evaluator dies first,
        // `score.deinit()` is the ONE free, the shell last.
        shell.evaluator.deinit();
        shell.score.deinit();
        gpa.destroy(shell);
        live = null;
    }
}

// ---------------------------------------------------------------------------
// Tests — native, calling the exports. Compiler-side modules (`Compile`,
// `Eval`, `PacbEncode`, `test_support`, `sjon`) are indented test-block
// imports ONLY: the text path is the oracle here, never part of the
// runtime closure (the recorded plan-02 test seam).
// ---------------------------------------------------------------------------

const t = std.testing;

const FIXTURE_NAMES = [_][]const u8{ "keys-only", "expr-keys", "full-small" };

/// Read one committed fixture pair (score text + the REAL CLI's own
/// `.pacb` output) from the shared tree.
fn readFixture(a: std.mem.Allocator, name: []const u8) !struct { src: [:0]u8, pacb: []u8 } {
    const sjon = @import("sjon");
    const root = @import("build_options").repo_root;
    const src_path = try std.fmt.allocPrint(a, "{s}/tools/testdata/pacb/{s}.score.sjon", .{ root, name });
    const pacb_path = try std.fmt.allocPrint(a, "{s}/tools/testdata/pacb/{s}.pacb", .{ root, name });
    return .{
        .src = try sjon.CappedRead.readFileZ(t.io, src_path, a, 1 << 20),
        .pacb = try sjon.CappedRead.readFile(t.io, pacb_path, a, 1 << 20),
    };
}

/// The zero-count canonical 'PACT' — every committed fixture declares
/// its targets (empty host join ⇒ zero-count 'REGS').
fn emptyPactLen() u32 {
    const blob = PactCodec.encodeTargets(&.{}, &targets_buffer) catch unreachable;
    return @intCast(blob.len);
}

/// Write `pacb` into the PACB zone and load it against the zero-count
/// host join; returns the status.
fn loadPacB(pacb: []const u8) u32 {
    @memcpy(pacb_buffer[0..pacb.len], pacb);
    return prt_load(@intCast(pacb.len), emptyPactLen());
}

/// The text-path oracle for one fixture: compile + a fresh tree-arm
/// evaluator. Heap-allocated and armed IN PLACE — the evaluator's
/// `table` pointer borrows into `result`, so the pair must not move
/// after `init` (the borrow-whole rule, `Driver.zig`'s doctrine).
/// Indented compiler imports — the test seam, never closure.
const Oracle = struct {
    result: @import("Compile.zig").CompileResult,
    evaluator: EvalCore.Evaluator,

    fn deinit(self: *Oracle, a: std.mem.Allocator) void {
        self.evaluator.deinit();
        self.result.deinit();
        a.destroy(self);
    }
};

fn compileOracle(a: std.mem.Allocator, src: [:0]const u8) !*Oracle {
    return compileOracleT(a, src, &.{});
}

/// `compileOracle` over a NON-empty host join (the corpus cases' shape —
/// docs that declare no targets take them from `times.sjon`).
fn compileOracleT(a: std.mem.Allocator, src: [:0]const u8, targets: anytype) !*Oracle {
    const Compile = @import("Compile.zig");
    const Eval = @import("Eval.zig");
    const test_support = @import("test_support.zig");
    const oracle = try a.create(Oracle);
    errdefer a.destroy(oracle);
    oracle.result = try Compile.compile(a, test_support.schema(), src, targets);
    errdefer oracle.result.deinit();
    if (!oracle.result.ok()) return error.FixtureCompileFailed;
    oracle.evaluator = try Eval.Evaluator.init(a, &oracle.result);
    return oracle;
}

/// The live rt frame at `tick`, decoded out of the static writes zone.
fn rtFrame(tick: i64) []const Writes.Entry {
    const len = prt_evalTicks(tick);
    t.expect(len > 0) catch unreachable;
    const zone: []align(4) const u8 = @alignCast(writes_buffer[0..len]);
    return Writes.decode(zone) orelse unreachable;
}

test "rt_entry: zone + ABI shapes and the frozen refusal-reason map" {
    try t.expectEqual(@as(u32, 1), prt_abiVersion());
    try t.expectEqual(@as(u32, PACB_CAP), prt_pacbCap());
    try t.expectEqual(@as(u32, 64 * 1024), prt_targetsCap());
    try t.expectEqual(prt_pacbPtr(), prt_pacbPtr());
    try t.expectEqual(@as(usize, WRITES_CAP), Writes.encodedLen(EvalCore.MAX_FRAME_ENTRIES));

    // The 02:127-131 map, every decoder variant pinned (11 arises
    // entry-side; 7 `non_finite` is the frozen no-emitter reserve).
    try t.expectEqual(@as(u16, 0), refusalReason(.bad_magic));
    try t.expectEqual(@as(u16, 1), refusalReason(.unsupported_version));
    try t.expectEqual(@as(u16, 2), refusalReason(.unsupported_features));
    try t.expectEqual(@as(u16, 3), refusalReason(.directory_malformed));
    try t.expectEqual(@as(u16, 4), refusalReason(.count_mismatch));
    try t.expectEqual(@as(u16, 4), refusalReason(.non_canonical));
    try t.expectEqual(@as(u16, 5), refusalReason(.transport_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.tempo_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.record_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.key_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.ease_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.trigger_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.scene_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.control_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.strs_invalid));
    try t.expectEqual(@as(u16, 5), refusalReason(.decl_invalid));
    try t.expectEqual(@as(u16, 6), refusalReason(.cap_exceeded));
    try t.expectEqual(@as(u16, 8), refusalReason(.payload_malformed));
    try t.expectEqual(@as(u16, 9), refusalReason(.registry_mismatch));
    try t.expectEqual(@as(u16, 10), refusalReason(.meta_malformed));
    try t.expectEqual(@as(u16, 10), refusalReason(.meta_incoherent));

    // Nothing loaded: eval family is inert, meta empty, failures 0.
    try t.expectEqual(@as(u32, 0), prt_eval(0.0));
    try t.expectEqual(@as(u32, 0), prt_evalTicks(0));
    try t.expectEqual(@as(u32, 0), prt_metaLen());
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
    try t.expectEqual(@as(u32, 1), prt_setBpm(120));
    try t.expectEqual(@as(u32, 1), prt_setControl(0, 0, 0, 0, 0));
    try t.expectEqual(NO_SLOT, prt_registerControl(0, 0, 1));
}

test "rt_entry: load + eval tracer over the expr-keys committed blob" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx = try readFixture(a, "expr-keys");
    var oracle = try compileOracle(a, fx.src);
    defer oracle.deinit(a);

    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();
    try t.expect(prt_metaLen() > 0);
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    for ([_]i64{ 0, 1, 96, 191, 192, 384 }) |tick| {
        const want = oracle.evaluator.evalTicks(tick);
        try t.expect(want.len > 0);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
    }
}

test "rt_entry (g): binary-arm eval ≡ text-path eval across the three committed fixtures" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const PPC = RtSjon.Pattern.PPC;

    for (FIXTURE_NAMES) |name| {
        const fx = try readFixture(a, name);
        var oracle = try compileOracle(a, fx.src);
        defer oracle.deinit(a);

        try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
        // Byte-equal 'PACW' entry streams at a tick sweep — through keys,
        // easing segments, the wrap, scened windows, and past the end.
        // This is also the C4 proof: the sentinel is never read, or the
        // frames could not match the tree arm.
        const sweep = [_]i64{ 0, 1, 3, PPC / 16, PPC / 8 + 1, PPC / 4, PPC / 2, PPC - 1, PPC, PPC + PPC / 16, 2 * PPC - 1, 2 * PPC, 3 * PPC, 4 * PPC - 1, 4 * PPC, 6 * PPC };
        for (sweep) |tick| {
            const want = oracle.evaluator.evalTicks(tick);
            const got = rtFrame(tick);
            t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(got)) catch |err| {
                std.debug.print("parity divergence: fixture {s} tick {d}\n", .{ name, tick });
                return err;
            };
        }
        try t.expectEqual(@as(u32, 0), prt_exprFailures());
        unload();
    }
}

test "rt_entry (f): meta serves the score's own 'PACM' copy and moves across loads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx_a = try readFixture(a, "full-small");
    const fx_b = try readFixture(a, "keys-only");

    // The score's served bytes are exactly the fixture's embedded 'PACM'.
    const WantPacm = struct {
        fn of(pacb: []const u8) []const u8 {
            const dir = Pacb.parseDirectory(pacb, null) catch unreachable;
            const sec = dir.find(.pacm).?;
            return pacb[sec.off..][0..sec.len];
        }
    };

    try t.expectEqual(@as(u32, 0), loadPacB(fx_a.pacb));
    const meta_a = prt_metaPtr()[0..prt_metaLen()];
    try t.expectEqualSlices(u8, WantPacm.of(fx_a.pacb), meta_a);
    const saved_a = try a.dupe(u8, meta_a);

    try t.expectEqual(@as(u32, 0), loadPacB(fx_b.pacb));
    defer unload();
    const meta_b = prt_metaPtr()[0..prt_metaLen()];
    try t.expectEqualSlices(u8, WantPacm.of(fx_b.pacb), meta_b);
    // The new score's meta reflects the NEW score — never a stale view.
    try t.expect(!std.mem.eql(u8, saved_a, meta_b));
}

// ---------------------------------------------------------------------------
// Group 2 — transactional load, gates, dry-runs, ownership
// ---------------------------------------------------------------------------

/// In-test pack: compile + preflight + encode, exactly the
/// post-corrections contract (F3/F4). Asserts the text path ACCEPTED
/// the score (`r.ok()`, zero preflight diagnostics) — the acceptance
/// half of every parity pin.
fn packForTest(a: std.mem.Allocator, src: [:0]const u8) ![]u8 {
    const Compile = @import("Compile.zig");
    const PacbEncode = @import("PacbEncode.zig");
    const test_support = @import("test_support.zig");
    var r = try Compile.compile(a, test_support.schema(), src, &.{});
    defer r.deinit();
    if (!r.ok()) return error.FixtureCompileFailed;
    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try PacbEncode.preflight(a, &r, &diags);
    try t.expectEqual(@as(usize, 0), diags.items.len);
    return PacbEncode.encode(a, &r, &.{});
}

/// A copy of the last rt frame (the static zone is reused per call).
fn captureTicks(a: std.mem.Allocator, tick: i64) ![]u8 {
    const len = prt_evalTicks(tick);
    try t.expect(len > 0);
    return a.dupe(u8, writes_buffer[0..len]);
}

fn captureFrame(a: std.mem.Allocator, secs: f64) ![]u8 {
    const len = prt_eval(secs);
    try t.expect(len > 0);
    return a.dupe(u8, writes_buffer[0..len]);
}

/// One evaluation at `tick`, captured and DECODED: the failure counter
/// accumulates per evaluation, so a test that asserts on the counter
/// must evaluate each frame exactly once and read the capture.
fn captureFrameDecoded(a: std.mem.Allocator, tick: i64) ![]const Writes.Entry {
    const len = prt_evalTicks(tick);
    try t.expect(len > 0);
    const mem = try a.alignedAlloc(u8, .of(Writes.Entry), len);
    @memcpy(mem, writes_buffer[0..len]);
    return Writes.decode(mem) orelse unreachable;
}

test "rt_entry (a): a refusal is transactional — old score, control, bpm, counters survive" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Constant-tempo score with a document control, so a held widget AND
    // a live bpm nudge are both evaluator state worth proving.
    const src =
        \\(target :name glow :arity 1 :registry 0)
        \\(target :name level :arity 1 :registry 1)
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(control :id depth :target level :min 0 :max 1 :value 0.25)
        \\(track :target glow (key :at 0b :value 0.2) (key :at 4b :value 0.8 :ease in-out-quad))
        \\(track :target level :expr (* depth beat))
        \\
    ;
    const pacb = try packForTest(a, src);
    try t.expectEqual(@as(u32, 0), loadPacB(pacb));
    defer unload();
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.9, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), prt_setBpm(240));
    const frame_before = try captureFrame(a, 0.3);
    const ticks_before = try captureTicks(a, 7);
    const meta_ptr_before = prt_metaPtr();
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // Overwrite the zone with a refused blob: valid magic, bogus
    // version ⇒ status 1, reason 1 (nonzero — distinguishable from
    // "never written").
    std.mem.writeInt(u32, pacb_buffer[4..8], 99, .little);
    try t.expectEqual(@as(u32, 1), prt_load(@intCast(pacb.len), emptyPactLen()));
    try t.expectEqual(@as(u32, 1), prt_loadError()); // unsupported_version
    // …and a status-2 bad call right after stays a TRUE no-op, reason
    // word included.
    try t.expectEqual(@as(u32, 2), prt_load(PACB_CAP + 1, emptyPactLen()));
    try t.expectEqual(@as(u32, 1), prt_loadError());

    // The OLD score is still live: byte-identical frames (a fresh
    // evaluator would have lost the 0.9 hold and the ×2 tempo), meta
    // pointer unmoved, counter intact.
    try t.expectEqualSlices(u8, frame_before, try captureFrame(a, 0.3));
    try t.expectEqualSlices(u8, ticks_before, try captureTicks(a, 7));
    try t.expectEqual(meta_ptr_before, prt_metaPtr());
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
}

test "rt_entry (b): the PACB zone never aliases the decoded score" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx = try readFixture(a, "expr-keys");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();
    const before = try captureTicks(a, 96);
    const meta_before = try a.dupe(u8, prt_metaPtr()[0..prt_metaLen()]);
    // Clobber the whole input zone: the live score owns every byte it
    // serves (the 01 T4.3 ownership doctrine, extended to the runtime).
    @memset(&pacb_buffer, 0);
    try t.expectEqualSlices(u8, before, try captureTicks(a, 96));
    try t.expectEqualSlices(u8, meta_before, prt_metaPtr()[0..prt_metaLen()]);
}

test "rt_entry (c): status-2 classes are true no-ops" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx = try readFixture(a, "expr-keys");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();
    const before = try captureTicks(a, 96);
    const error_before = prt_loadError();
    // Oversize PACB length (the whole-blob zone policy, R-I2).
    try t.expectEqual(@as(u32, 2), prt_load(PACB_CAP + 1, emptyPactLen()));
    // Oversize targets length.
    try t.expectEqual(@as(u32, 2), prt_load(@intCast(fx.pacb.len), 64 * 1024 + 1));
    // Malformed 'PACT' (bad magic).
    @memcpy(targets_buffer[0..4], "XXXX");
    try t.expectEqual(@as(u32, 2), prt_load(@intCast(fx.pacb.len), 8));
    // Everything untouched: live score frames, meta, and the reason word
    // (bad calls never write it — whatever it held on entry survives).
    try t.expectEqualSlices(u8, before, try captureTicks(a, 96));
    try t.expect(prt_metaLen() > 0);
    try t.expectEqual(error_before, prt_loadError());
}

test "rt_entry (d): registry mismatch is status 1 with reason 9, old score live" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx = try readFixture(a, "full-small");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();
    const before = try captureTicks(a, 96);
    // A NON-empty host join against the fixture's zero-count 'REGS' —
    // one spelling of mismatch (review O-2).
    const one = [_]PactCodec.Target{.{ .name = "bogus", .ncomp = 1, .registry = 0 }};
    const blob = PactCodec.encodeTargets(&one, &targets_buffer) catch unreachable;
    try t.expectEqual(@as(u32, 1), prt_load(@intCast(fx.pacb.len), @intCast(blob.len)));
    try t.expectEqual(@as(u32, 9), prt_loadError()); // registry_mismatch
    try t.expectEqualSlices(u8, before, try captureTicks(a, 96));
}

test "rt_entry (e): an expr whose dry-tick eval fails is refused, reason 11" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx = try readFixture(a, "expr-keys");
    // Flip the one expr payload's '*' head to '/' — still structurally
    // valid, still a core head, but `(/ 0.5 beat)` at the dry tick is
    // +inf, which the result contract rejects. Decode accepts the blob;
    // only the entry-side dry-run (C5) can see it.
    const mutated = try a.dupe(u8, fx.pacb);
    const dir = Pacb.parseDirectory(mutated, null) catch unreachable;
    const payl = dir.find(.payl).?;
    const section = mutated[payl.off..][0..payl.len];
    // 'PAYL' records are [len u32][payload bytes] concatenated — flip
    // the head INSIDE a payload body, never a length prefix (0x2a as a
    // u32 length is a coincidence, not the head).
    var hits: usize = 0;
    var pos: usize = 0;
    while (pos < section.len) {
        const plen = std.mem.readInt(u32, section[pos..][0..4], .little);
        const body = section[pos + 4 ..][0..plen];
        for (body) |*byte| {
            if (byte.* == '*') {
                byte.* = '/';
                hits += 1;
            }
        }
        pos += 4 + plen;
    }
    try t.expectEqual(section.len, pos);
    try t.expectEqual(@as(usize, 1), hits);

    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb)); // a live old score
    defer unload();
    const before = try captureTicks(a, 96);
    @memcpy(pacb_buffer[0..mutated.len], mutated);
    try t.expectEqual(@as(u32, 1), prt_load(@intCast(mutated.len), emptyPactLen()));
    try t.expectEqual(@as(u32, 11), prt_loadError()); // dry_run_failed
    try t.expectEqualSlices(u8, before, try captureTicks(a, 96));
}

test "rt_entry (h): scened-expr acceptance parity (C5) — (sqrt scene-beat) loads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Sound at the scene's start tick (scene-beat = 0), unsound at flat
    // t=0 (no scene env) — the text path ACCEPTS it (packForTest asserts
    // r.ok() + zero preflight diagnostics), so the runtime must too.
    const src =
        \\(target :name glow :arity 1 :registry 0)
        \\(transport :bpm 120 :meter [4 4] :dur 4bar :end loop)
        \\(scene :name drop :at 8b :dur 8b
        \\  (track :target glow :expr (sqrt scene-beat)))
        \\
    ;
    const pacb = try packForTest(a, src);
    try t.expectEqual(@as(u32, 0), loadPacB(pacb));
    defer unload();
    // Inside the window the frame evaluates (the dry-run took the scene
    // start; a flat-0 dry-run would have refused this score at load).
    try t.expect(rtFrame(2 * RtSjon.Pattern.PPC).len > 0);
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // The inverse divergence pin: the SAME payload evaluated at flat
    // t=0 WITHOUT the scene env fails — exactly the refusal a flat-0
    // dry-run would have produced. (The text path's top-level
    // `scene-beat` ⇒ UnknownBinding stays compile-side; no rt case —
    // the pack preflight never emits such a payload.)
    var score = Pacb.decode(t.allocator, pacb, null) catch unreachable;
    defer score.deinit();
    var payload: ?[]const u8 = null;
    for (score.tracks) |track| {
        switch (track.source) {
            .expr => |pl| payload = pl,
            else => {},
        }
    }
    const scratch = try t.allocator.alloc(u8, ExprTrack.SCRATCH_BYTES);
    defer t.allocator.free(scratch);
    var fba = std.heap.FixedBufferAllocator.init(scratch);
    if (ExprTrack.evalAtBinary(fba.allocator(), payload.?, rt_schema, &score.transport, &.{}, 0, null, 1)) |_| {
        return error.TestUnexpectedResult; // flat-0 must NOT evaluate
    } else |_| {}
}

test "rt_entry: control/bpm exports mirror the drv_* contract (2^53 gate, range checks)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx = try readFixture(a, "full-small");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();

    // The 2^53 tick ceiling, both directions, mirroring the seconds path.
    try t.expectEqual(@as(u32, 0), prt_evalTicks(RtSjon.Pattern.MAX_TICK + 1));
    try t.expectEqual(@as(u32, 0), prt_evalTicks(-RtSjon.Pattern.MAX_TICK - 1));
    try t.expectEqual(@as(u32, 0), prt_evalTicks(std.math.maxInt(i64)));
    try t.expect(prt_evalTicks(RtSjon.Pattern.MAX_TICK) > 0);

    // registerControl: range checks before narrowing, then the engine's
    // own join validation; the success path returns the shared index.
    try t.expectEqual(NO_SLOT, prt_registerControl(EvalCore.NO_TARGET, 0, 1));
    try t.expectEqual(NO_SLOT, prt_registerControl(0, 256, 1));
    try t.expectEqual(NO_SLOT, prt_registerControl(0, 0, 256));
    try t.expectEqual(NO_SLOT, prt_registerControl(0, 0, 0));
    const slot = prt_registerControl(3, 1, 1);
    try t.expect(slot != NO_SLOT);
    try t.expectEqual(@as(u32, 0), prt_setControl(slot, 1, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), prt_clearControl(slot));

    // setControl/clearControl/setBpm rejection classes.
    try t.expectEqual(@as(u32, 1), prt_setControl(999, 0, 0, 0, 0));
    try t.expectEqual(@as(u32, 1), prt_setControl(0, std.math.nan(f32), 0, 0, 0));
    try t.expectEqual(@as(u32, 1), prt_clearControl(999));
    try t.expectEqual(@as(u32, 1), prt_setBpm(std.math.nan(f64)));
    try t.expectEqual(@as(u32, 1), prt_setBpm(0)); // below the 1..1000 bounds
    try t.expectEqual(@as(u32, 1), prt_setBpm(240)); // a mapped score is not nudgeable

    // A held document control lands in the frame, after track writes.
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.75, 0, 0, 0));
    const frame = rtFrame(0);
    var found = false;
    for (frame) |entry| {
        if (entry.target_id == 4 and entry.flags == 1) {
            try t.expectEqual(@as(f32, 0.75), entry.value[0]);
            found = true;
        }
    }
    try t.expect(found);
}

test "rt_entry (i): a malformed spliced 'SNAM' is refused at load, the live score untouched" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fuzz_pacb = @import("fuzz_pacb.zig");

    const fx = try readFixture(a, "full-small");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();
    const frame_before = try captureTicks(a, 96);
    const meta_before = try a.dupe(u8, prt_metaPtr()[0..prt_metaLen()]);
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // Splice a count-inflated 'SNAM' frame into the embedded 'PACM' of
    // the REAL frozen pack and repair the container around the growth
    // (directory len + TRAN pacm_fnv — v1 has no container checksum),
    // so the bytes reach metadata validation instead of dying at the
    // checksum. The reader must refuse (reason 10, meta_malformed)
    // BEFORE any state is committed — the transactional contract for
    // the new SNAM arm: prior live metadata, output, and counters all
    // survive byte-for-byte.
    var dest: [8192]u8 = undefined;
    const names = [_][]const u8{"drop"};
    const len = fuzz_pacb.spliceSnam(&dest, fx.pacb, &names, .count_inflated, 2, 0) orelse
        return error.SpliceSeamMissing;
    @memcpy(pacb_buffer[0..len], dest[0..len]);
    try t.expectEqual(@as(u32, 1), prt_load(@intCast(len), emptyPactLen()));
    try t.expectEqual(@as(u32, 10), prt_loadError()); // meta_malformed
    try t.expectEqualSlices(u8, frame_before, try captureTicks(a, 96));
    try t.expectEqualSlices(u8, meta_before, prt_metaPtr()[0..prt_metaLen()]);
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
}

test "rt_entry (j): the pre-SNAM pin decodes nameless at both unit readers; the legacy cartridge still loads" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sjon = @import("sjon");
    const Pacm = @import("Pacm.zig");
    const Abi = @import("Abi.zig");
    const root = @import("build_options").repo_root;

    // Group 0's committed pre-SNAM 'PACM' pin: a BARE 'PACM' blob, so
    // this is a UNIT-level proof at `Pacm.decode`/`Abi.decodeMeta` —
    // `prt_load` consumes 'PACB' containers only (a bare PACM is a
    // bad_magic refusal there, by design, never a test subject). The
    // old blob decodes clean and every scene name is ABSENT — the C6
    // old-blob-on-new-code pin, spelled as null (absence), which is
    // what lets a source-holding consumer fall back to the span.
    const pin_path = try std.fmt.allocPrint(a, "{s}/src/testdata/pacm/scenes-tempo-ease.pre-snam.pacm", .{root});
    const pin = try sjon.CappedRead.readFile(t.io, pin_path, a, 1 << 20);
    const pv = Pacm.decode(pin) orelse return error.TestExpectedDecode;
    try t.expectEqual(@as(usize, 1), pv.sceneCount());
    try t.expectEqual(@as(?[]const u8, null), pv.scene(0).name);
    const av = Abi.decodeMeta(pin) orelse return error.TestExpectedDecode;
    try t.expectEqual(@as(usize, 1), av.sceneCount());
    try t.expectEqual(@as(?[]const u8, null), av.scene(0).name);

    // The real-path twin: the legacy full-small cartridge (pre-SNAM
    // bytes, frozen forever) still LOADS, and the meta it serves
    // decodes nameless — the prt_load-path C6 proof.
    const fx = try readFixture(a, "full-small");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();
    const served = Pacm.decode(prt_metaPtr()[0..prt_metaLen()]) orelse return error.TestExpectedDecode;
    try t.expectEqual(@as(usize, 1), served.sceneCount());
    try t.expectEqual(@as(?[]const u8, null), served.scene(0).name);
}

/// The single payload body of a committed fixture: its absolute offset
/// and length. 'PAYL' is `[byte_size u32]` + the bodies the 'TRAK'
/// spans address region-relatively (no per-record length prefixes —
/// the per-body lengths live only in 'TRAK'); these fixtures carry
/// exactly one nonzero span (the expr track's).
const ExprSpan = struct { at: usize, len: usize };

fn soleExprSpan(blob: []const u8) !ExprSpan {
    const dir = try Pacb.parseDirectory(blob, null);
    const payl = dir.find(.payl).?;
    const byte_size = std.mem.readInt(u32, blob[payl.off..][0..4], .little);
    try t.expectEqual(payl.len, 4 + @as(usize, byte_size));
    const count = std.mem.readInt(u32, blob[12..16], .little);
    try t.expect(count > 0 and count <= Pacb.MAX_SECTIONS);
    var found: ?ExprSpan = null;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const at = Pacb.HEADER_LEN + Pacb.DIRECTORY_ENTRY_LEN * i;
        if (std.mem.readInt(u32, blob[at..][0..4], .little) != Pacb.TRAK_ID) continue;
        const trak_off = std.mem.readInt(u32, blob[at + 4 ..][0..4], .little);
        const trak_len = std.mem.readInt(u32, blob[at + 8 ..][0..4], .little);
        const tcount = std.mem.readInt(u32, blob[trak_off..][0..4], .little);
        try t.expectEqual((trak_len - 4) / Pacb.TRAK_REC_LEN, tcount);
        var k: usize = 0;
        while (k < tcount) : (k += 1) {
            const rec = trak_off + 4 + k * Pacb.TRAK_REC_LEN;
            const plen = std.mem.readInt(u32, blob[rec + 20 ..][0..4], .little);
            if (plen != 0) {
                try t.expect(found == null); // single payload fixture
                found = .{
                    .at = payl.off + 4 + std.mem.readInt(u32, blob[rec + 16 ..][0..4], .little),
                    .len = plen,
                };
            }
        }
    }
    if (found) |f| return f;
    return error.NoPayloadSpan;
}

/// Replace a committed fixture's single expr payload body with
/// `new_body`, repairing the container around the size delta: the
/// section's `[byte_size u32]`, the one nonzero 'TRAK' payload span,
/// the 'PAYL' directory length, and every section offset at/after the
/// old 'PAYL' end (they all shift by the delta). 'TRAK' sections are
/// patched IN PLACE, which is correct only while each lies BEFORE the
/// payload region (asserted below) — a 'TRAK' at/after 'PAYL' would
/// shift with the delta and be patched at its pre-shift address, and
/// its directory offset never moved. The committed fixtures all order
/// 'TRAK' before 'PAYL'. 'TRAN''s two checksums hash section CONTENTS
/// (`pact_fnv` over the 'PACT' bytes, `pacm_fnv` over the 'PACM'
/// bytes) — never offsets or lengths — so neither moves. Returns the
/// grown/shrunk blob.
fn splicePayloadRecord(a: std.mem.Allocator, blob: []const u8, new_body: []const u8) ![]u8 {
    const dir = try Pacb.parseDirectory(blob, null);
    const payl = dir.find(.payl).?;
    const span = try soleExprSpan(blob);
    try t.expectEqual(@as(usize, payl.len - 4), span.len); // one body fills the region
    try t.expectEqual(payl.off + 4, span.at); // region-relative offset 0

    const new_payl_len = 4 + new_body.len;
    const delta: isize = @as(isize, @intCast(new_payl_len)) - @as(isize, @intCast(payl.len));
    // The spliced body may SHRINK the region (an empty count-0 tail
    // body is smaller than the committed fixture's), so the signed
    // delta must reach the allocation both ways — @intCast on a
    // negative isize panics (the shrink direction was first exercised
    // by test (m); the memcpy + offset repairs below are already
    // signed-delta correct).
    const out = try a.alloc(u8, @intCast(@as(isize, @intCast(blob.len)) + delta));
    const payl_end = payl.off + payl.len;
    @memcpy(out[0..payl.off], blob[0..payl.off]);
    std.mem.writeInt(u32, out[payl.off..][0..4], @intCast(new_body.len), .little);
    @memcpy(out[payl.off + 4 ..][0..new_body.len], new_body);
    @memcpy(out[payl.off + new_payl_len ..], blob[payl_end..]);

    // Directory + span repairs over the EDITED bytes (soleExprSpan
    // already proved exactly one nonzero span exists).
    const count = std.mem.readInt(u32, out[12..16], .little);
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const at = Pacb.HEADER_LEN + Pacb.DIRECTORY_ENTRY_LEN * i;
        switch (std.mem.readInt(u32, out[at..][0..4], .little)) {
            Pacb.PAYL_ID => std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(new_payl_len), .little),
            Pacb.TRAK_ID => {
                const trak_off = std.mem.readInt(u32, out[at + 4 ..][0..4], .little);
                const trak_len = std.mem.readInt(u32, out[at + 8 ..][0..4], .little);
                const tcount = std.mem.readInt(u32, out[trak_off..][0..4], .little);
                try t.expectEqual((trak_len - 4) / Pacb.TRAK_REC_LEN, tcount);
                // Precondition (review LOW): the span patch below writes
                // at the section's OLD address, so every 'TRAK' must
                // precede the payload region — one at/after 'PAYL' would
                // have shifted with the delta.
                try t.expect(trak_off < payl.off);
                var k: usize = 0;
                while (k < tcount) : (k += 1) {
                    const rec = trak_off + 4 + k * Pacb.TRAK_REC_LEN;
                    if (std.mem.readInt(u32, out[rec + 20 ..][0..4], .little) != 0) {
                        std.mem.writeInt(u32, out[rec + 20 ..][0..4], @intCast(new_body.len), .little);
                    }
                }
            },
            else => {
                const off = std.mem.readInt(u32, out[at + 4 ..][0..4], .little);
                if (off >= payl_end) {
                    const moved = @as(isize, @intCast(off)) + delta;
                    std.mem.writeInt(u32, out[at + 4 ..][0..4], @intCast(moved), .little);
                }
            },
        }
    }
    return out;
}

test "rt_entry (k): a tree-trailing-comment expr payload loads through the production loader" {
    // The decode-level RootIter drain (Pacb A1) proven through the REAL
    // load path: the committed expr-keys blob has its payload record
    // replaced with the same-shaped tree PLUS a tree-trailing comment
    // block (the payload's own header carries the flag — real packs
    // never emit it; the compact encode is comment-free). Before the
    // drain this refused payload_malformed; the drained walk loads it.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sjon = @import("sjon");

    const fx = try readFixture(a, "expr-keys");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();

    // Same tree with and without the tail: the with-tail body is
    // strictly longer — the spliced record really carries the block
    // (never a vacuous pass).
    var tree = try sjon.parse(a, "1 ; drained");
    defer tree.deinit();
    const with_tail = try sjon.Binary.toBinary(a, tree, .{
        .with_spans = false,
        .with_head_spans = false,
        .with_kvpair_key_spans = false,
        .with_tree_trailing_comments = true,
    });
    defer with_tail.deinit();
    const plain = try sjon.Binary.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer plain.deinit();
    try t.expect(with_tail.data.len > plain.data.len);

    const grown = try splicePayloadRecord(a, fx.pacb, with_tail.data);
    const status = loadPacB(grown);
    if (status != 0) {
        std.debug.print("rt_entry (k): load refused — status={d} reason={d} (8 = payload_malformed, the pre-drain refusal)\n", .{ status, prt_loadError() });
    }
    try t.expectEqual(@as(u32, 0), status);
    // The new score is live: a nonempty frame at tick 7.
    try t.expect(prt_evalTicks(7) > 0);
}

test "rt_entry (l): residual junk after the payload walk refuses reason 8, prior score live" {
    // The drain must not over-accept: junk INSIDE the payload record —
    // a short valid tree padded to the record's exact body length —
    // leaves the walk short of the payload end. Status 1, exact reason
    // 8 (payload_malformed), and the transactional contract: the old
    // score, its held control, bpm nudge, meta and counters stay live.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sjon = @import("sjon");

    // A document control, so a held widget AND a live bpm nudge are
    // both evaluator state worth proving (test (a)'s shape).
    const src =
        \\(target :name glow :arity 1 :registry 0)
        \\(target :name level :arity 1 :registry 1)
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(control :id depth :target level :min 0 :max 1 :value 0.25)
        \\(track :target glow (key :at 0b :value 0.2) (key :at 4b :value 0.8 :ease in-out-quad))
        \\(track :target level :expr (* depth beat))
        \\
    ;
    const pacb = try packForTest(a, src);
    try t.expectEqual(@as(u32, 0), loadPacB(pacb));
    defer unload();
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.9, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), prt_setBpm(240));
    const frame_before = try captureFrame(a, 0.3);
    const ticks_before = try captureTicks(a, 7);
    const meta_ptr_before = prt_metaPtr();
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // The in-place rewrite: constant `1` compact binary, junk fill to
    // the body's exact length (no container repair needed).
    var tree = try sjon.parse(a, "1");
    defer tree.deinit();
    const plain = try sjon.Binary.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer plain.deinit();
    const span = try soleExprSpan(pacb);
    try t.expect(plain.data.len < span.len); // the junk fill is nonempty

    const junked = try a.dupe(u8, pacb);
    @memcpy(junked[span.at..][0..plain.data.len], plain.data);
    @memset(junked[span.at + plain.data.len ..][0 .. span.len - plain.data.len], 0xAA);

    try t.expectEqual(@as(u32, 1), loadPacB(junked));
    try t.expectEqual(@as(u32, 8), prt_loadError()); // payload_malformed
    // The OLD score is still live: byte-identical frames (held 0.9 and
    // the ×2 tempo inside them), meta pointer unmoved, counter intact.
    try t.expectEqualSlices(u8, frame_before, try captureFrame(a, 0.3));
    try t.expectEqualSlices(u8, ticks_before, try captureTicks(a, 7));
    try t.expectEqual(meta_ptr_before, prt_metaPtr());
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
}

test "rt_entry (m): a flag-on EMPTY count-0 tail loads through the production loader" {
    // Review-HIGH mirror of (k) through the REAL load path, third
    // shape: the writer emits the tree-trailing COUNT varint even when
    // the tree has no tree-level trailing comment, so a flag-on encode
    // of a comment-free tree ends in exactly `[0x00]` after the roots.
    // Before the drain this refused payload_malformed at the roots'
    // end; the drained walk reads the one varint byte and loads.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sjon = @import("sjon");

    const fx = try readFixture(a, "expr-keys");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();

    var tree = try sjon.parse(a, "1");
    defer tree.deinit();
    const with_empty0 = try sjon.Binary.toBinary(a, tree, .{
        .with_spans = false,
        .with_head_spans = false,
        .with_kvpair_key_spans = false,
        .with_tree_trailing_comments = true,
    });
    defer with_empty0.deinit();
    const plain = try sjon.Binary.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer plain.deinit();
    // Non-vacuity: the spliced body really carries the flag and the
    // empty block — flags byte 0x20, the last byte is the count-0
    // varint, and the length difference against the same tree's
    // compact encode is exactly the flag's three bytes: +2 for the
    // empty comment pool (anyCommentsFlag gates the pool, so the flag
    // alone writes `[0 entries][0 bytes]` where compact writes none)
    // and +1 for the `[count 0]` tail varint.
    try t.expectEqual(@as(u8, 0x20), with_empty0.data[5]);
    try t.expectEqual(plain.data.len + 3, with_empty0.data.len);
    try t.expectEqual(@as(u8, 0x00), with_empty0.data[with_empty0.data.len - 1]);

    const grown = try splicePayloadRecord(a, fx.pacb, with_empty0.data);
    const status = loadPacB(grown);
    if (status != 0) {
        std.debug.print("rt_entry (m): load refused — status={d} reason={d} (8 = payload_malformed, the pre-drain refusal)\n", .{ status, prt_loadError() });
    }
    try t.expectEqual(@as(u32, 0), status);
    // The new score is live: a nonempty frame at tick 7.
    try t.expect(prt_evalTicks(7) > 0);
}

// ---------------------------------------------------------------------------
// Group 3 — A2: the binary pattern runtime path (real loader fixtures;
// the A2-era producer bypass became the real preflight+encode producer
// when A3+A4 lifted the pack refusal, 2026-10-22)
// ---------------------------------------------------------------------------

/// A3+A4 test-side producer (2026-10-22): the REAL production route —
/// `Compile` + `PacbEncode.preflight` (must report NOTHING for a clean
/// fixture) + `PacbEncode.encode`, the same route the `pacer pack` verb
/// takes. The interim `:pattern` refusal is lifted (plan 06 A3+A4), so
/// `:pattern` fixtures ride the ordinary producer — there is no bypass
/// any more. A fixture that trips preflight is a fixture bug and fails
/// here, loudly.
fn packPatternForTest(a: std.mem.Allocator, src: [:0]const u8, targets: anytype) ![]u8 {
    const Compile = @import("Compile.zig");
    const PacbEncode = @import("PacbEncode.zig");
    const test_support = @import("test_support.zig");
    var r = try Compile.compile(a, test_support.schema(), src, targets);
    defer r.deinit();
    if (!r.ok()) return error.FixtureCompileFailed;
    var refused: std.ArrayList(Compile.Diagnostic) = .empty;
    try PacbEncode.preflight(a, &r, &refused);
    if (refused.items.len != 0) return error.FixturePreflightRefused;
    return PacbEncode.encode(a, &r, targets);
}

/// `loadPacB` over a NON-empty host join (test (d)'s shape): the blob's
/// canonical 'REGS' must equal the canonical encoding of `targets`.
fn loadPacBT(pacb: []const u8, targets: []const PactCodec.Target) u32 {
    @memcpy(pacb_buffer[0..pacb.len], pacb);
    const blob = PactCodec.encodeTargets(targets, &targets_buffer) catch unreachable;
    return prt_load(@intCast(pacb.len), @intCast(blob.len));
}

test "rt_entry (n): a pattern score loads and evaluates through the production loader" {
    // The named acceptance fixture (handoff :149-153): the
    // `corpus/pattern-env` document — beat-tracking across the bar wrap
    // (`(pure (* beat 2))`), the `tick` shadow (the frame-time OUTER
    // binding must lose to the pattern-local), and a document control
    // read through the env's parent scope. The successful LOAD itself is
    // a dry-run proof: the load-time pattern dry-run binds pacer's env
    // exactly as the text path does — had `beat`/`tick`/`sway` been
    // unbound there, the static leaf check would refuse (reason 11) and
    // this load could not succeed.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sjon = @import("sjon");
    const root = @import("build_options").repo_root;
    const Compile = @import("Compile.zig");

    const src = try sjon.CappedRead.readFileZ(t.io, try std.fmt.allocPrint(a, "{s}/corpus/pattern-env/doc.sjon", .{root}), a, 1 << 20);
    // The corpus case's own host join (times.sjon): clock/onset/swayx2 on
    // registry 0 — the doc declares no targets, the corpus supplies them.
    // A drift between this list and times.sjon fails loudly at compile.
    const tg = [_]Compile.Target{
        .{ .name = "clock", .ncomp = 1, .registry = 0 },
        .{ .name = "onset", .ncomp = 1, .registry = 0 },
        .{ .name = "swayx2", .ncomp = 1, .registry = 0 },
    };
    var oracle = try compileOracleT(a, src, &tg);
    defer oracle.deinit(a);
    const pacb = try packPatternForTest(a, src, &tg);

    // The A2 gate: pre-lift this load is status 1, reason 2
    // (unsupported_features). Post-lift the whole path must arm.
    try t.expectEqual(@as(u32, 0), loadPacBT(pacb, &tg));
    defer unload();

    // Explicit non-vacuous values (never oracle-only): document order is
    // clock, onset, swayx2 — three whole-cycle haps, one write each.
    const PPC = RtSjon.Pattern.PPC;
    {
        const frame = rtFrame(0);
        try t.expectEqual(@as(usize, 3), frame.len);
        try t.expectEqual(@as(f32, 0), frame[0].value[0]); // (* beat 2) @ beat 0
        try t.expectEqual(@as(f32, 0), frame[1].value[0]); // tick shadow: cycle-0 onset, NOT frame tick
        try t.expectEqual(@as(f32, 0.5), frame[2].value[0]); // sway 0.25 × 2 through the parent scope
    }
    // The shadow decoy at the boundary: frame tick PPC/2 carries an
    // OUTER `tick` of PPC/2, but the pattern-local wins — the onset hap
    // still writes 0.0. And `beat` follows the clock (PPC/2 = two beats
    // at [4 4], ×2 = 4.0).
    {
        const frame = rtFrame(PPC / 2);
        try t.expectEqual(@as(usize, 3), frame.len);
        try t.expectEqual(@as(f32, 4), frame[0].value[0]);
        try t.expectEqual(@as(f32, 0), frame[1].value[0]);
    }
    // Byte-parity with the tree arm across the wrap and on
    // nonmonotonic revisits — the oracle re-derives every frame.
    const sweep = [_]i64{ 0, 1, PPC / 2, PPC - 1, PPC, PPC + PPC / 4, 2 * PPC, 3 * PPC + PPC / 2, 5 };
    for (sweep) |tick| {
        const want = oracle.evaluator.evalTicks(tick);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
    }
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // Live controls change BETWEEN frames on both arms identically:
    // hold sway at 0.75, the hap value follows on the next frame.
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.75, 0, 0, 0));
    try t.expect(oracle.evaluator.setControl(0, .{ 0.75, 0, 0, 0 }));
    for ([_]i64{ 0, PPC + PPC / 2 }) |tick| {
        const want = oracle.evaluator.evalTicks(tick);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
    }
    try t.expectEqual(@as(f32, 1.5), rtFrame(0)[2].value[0]); // 0.75 × 2 — the held value reached the hap
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // Retained-caller-bytes safety: clobber the whole input zone. The
    // live score owns every byte it evaluates (payload slices point
    // into the decoded score's arena, never the zone), so frames are
    // unchanged.
    @memset(&pacb_buffer, 0);
    try t.expectEqual(@as(f32, 1.5), rtFrame(0)[2].value[0]);
}

test "rt_entry (o): an empty (silence) pattern loads light; the keys track is unaffected" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\(target :name glow :arity 1 :registry 0)
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(track :target glow (key :at 0b :value 0.2) (key :at 4b :value 0.8 :ease in-out-quad))
        \\(track :target glow :pattern (silence))
        \\
    ;
    const pacb = try packPatternForTest(a, src, &.{});
    try t.expectEqual(@as(u32, 0), loadPacB(pacb));
    defer unload();

    // The silence slot is a GAP, not a failure: only the keys track
    // writes, byte-equal to the tree arm, and the drop counter stays 0 —
    // a plain silence never counts as a failure (same tree semantics).
    var oracle = try compileOracle(a, src);
    defer oracle.deinit(a);
    for ([_]i64{ 0, 96, 191, 192, 384, 900 }) |tick| {
        const want = oracle.evaluator.evalTicks(tick);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
        try t.expectEqual(@as(usize, 1), rtFrame(tick).len); // the key write only
    }
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
}

test "rt_entry (p): a pattern whose dry-run cycle exceeds the frame budget refuses reason 11, old score live" {
    // The `corpus/pattern-budget` shape (the text path's
    // `pattern_eval_failed` load diagnostic): a dry-run cycle that
    // out-allocates `PatternTrack.SCRATCH_BYTES` must refuse at LOAD —
    // status 1, the reason-11 reserve, deterministically distinct from
    // real OOM (status 3) and from decode refusal (reason 8) — and the
    // refusal is transactional. The same document text is a COMPILE
    // refusal (asserted below — same budget, same tree: the text
    // dry-run fronts the identical 1 MiB), so the blob is produced by
    // hand-encoding the `(fast 8000 (pure 1))` payload and splicing it
    // over a decode-valid single-payload blob — the producer class that
    // bypasses the compile gate the runtime dry-run must mirror.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sjon = @import("sjon");

    const budget_src =
        \\(target :name radius :arity 1 :registry 0)
        \\(transport :bpm 120)
        \\(track :target radius :pattern (fast 8000 (pure 1)))
        \\
    ;
    {
        const Compile = @import("Compile.zig");
        const test_support = @import("test_support.zig");
        var r = try Compile.compile(a, test_support.schema(), budget_src, &.{});
        defer r.deinit();
        try t.expect(!r.ok()); // the text path refuses the same score
    }

    // Hand-encode the budget pattern (parse-only — no compile gate) and
    // splice it over a packed silence-pattern blob (single payload, so
    // the surgeons apply).
    var tree = try sjon.parse(a, "(fast 8000 (pure 1))");
    defer tree.deinit();
    const body = try sjon.Binary.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer body.deinit();

    const base_src =
        \\(target :name radius :arity 1 :registry 0)
        \\(transport :bpm 120)
        \\(track :target radius :pattern (silence))
        \\
    ;
    const pacb = try packPatternForTest(a, base_src, &.{});
    const budget_blob = try splicePayloadRecord(a, pacb, body.data);

    // A live old score with held state, as in (a)/(l).
    const live_src =
        \\(target :name glow :arity 1 :registry 0)
        \\(target :name level :arity 1 :registry 1)
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(control :id depth :target level :min 0 :max 1 :value 0.25)
        \\(track :target glow (key :at 0b :value 0.2) (key :at 4b :value 0.8 :ease in-out-quad))
        \\(track :target level :expr (* depth beat))
        \\
    ;
    const live_blob = try packForTest(a, live_src);
    try t.expectEqual(@as(u32, 0), loadPacB(live_blob));
    defer unload();
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.9, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), prt_setBpm(240));
    const frame_before = try captureFrame(a, 0.3);
    const ticks_before = try captureTicks(a, 7);
    const meta_ptr_before = prt_metaPtr();
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    try t.expectEqual(@as(u32, 1), loadPacB(budget_blob));
    try t.expectEqual(@as(u32, 11), prt_loadError()); // dry_run_failed — the reserve, exact current behavior
    // The OLD score is still live: byte-identical frames (held 0.9 and
    // the ×2 tempo inside them), meta pointer unmoved, counter intact.
    try t.expectEqualSlices(u8, frame_before, try captureFrame(a, 0.3));
    try t.expectEqualSlices(u8, ticks_before, try captureTicks(a, 7));
    try t.expectEqual(meta_ptr_before, prt_metaPtr());
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
}

test "rt_entry (q): a pattern leaf that fails its cycle-0 dry-run refuses reason 11, not reason 8" {
    // The (e) doctrine, pattern twin: decode is structural — a payload
    // whose `(pure …)` leaf carries an UNBOUND name is decode-valid
    // (reason 8 cannot see it) and must be caught by the entry-side
    // dry-run instead. The text path refuses the same score at compile
    // (`pattern_eval_failed`), so the bypass producer cannot emit it:
    // the body is spliced by hand over a packed silence-pattern blob
    // (the single-payload surgeons are source-agnostic).
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sjon = @import("sjon");
    const Compile = @import("Compile.zig");
    const test_support = @import("test_support.zig");

    const base_src =
        \\(target :name glow :arity 1 :registry 0)
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target glow :pattern (silence))
        \\
    ;
    const pacb = try packPatternForTest(a, base_src, &.{});

    // Compile PROVES the unbound-name score is a compile refusal (the
    // text path's acceptance boundary this dry-run mirrors).
    {
        var r = try Compile.compile(a, test_support.schema(),
            \\(target :name glow :arity 1 :registry 0)
            \\(transport :bpm 120 :meter [4 4])
            \\(track :target glow :pattern (pure nosuchname))
            \\
        , &.{});
        defer r.deinit();
        try t.expect(!r.ok());
    }

    var tree = try sjon.parse(a, "(pure nosuchname)");
    defer tree.deinit();
    const body = try sjon.Binary.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer body.deinit();
    const mutated = try splicePayloadRecord(a, pacb, body.data);

    // A live old score, then the refusal: exact reason 11 (not the
    // decode class 8), transactional.
    const fx = try readFixture(a, "expr-keys");
    try t.expectEqual(@as(u32, 0), loadPacB(fx.pacb));
    defer unload();
    const before = try captureTicks(a, 96);
    try t.expectEqual(@as(u32, 1), loadPacB(mutated));
    try t.expectEqual(@as(u32, 11), prt_loadError()); // dry_run_failed
    try t.expectEqualSlices(u8, before, try captureTicks(a, 96));
}

// ---------------------------------------------------------------------------
// Group 4 — ask30/M4 prepared-runtime adoption (2026-10-22): the loader
// tests over the REAL production path. (r) is the named acceptance gate:
// Repro A — the compile-accepted 98,501 B pattern the A2 one-shot
// dry-run refused (status 1 reason 11, prod-four-a2-boundary-report.md
// "Repro A") — loads once the frame/dry-run seams query the prepared
// state; (s) pins the acceptance frontier's dense edge; (t) pins
// per-frame env freshness through a live control.
// ---------------------------------------------------------------------------

/// The Repro A source (prod-four-a2-boundary-report.md "Repro A",
/// probeB4SrcNondense): `(cat (pure 0.5) s₀ … s₂₃ (pure (+ 1 2)))` where
/// each sᵢ is a DISTINCT 4-KiB string (8-digit zero-padded index +
/// 'a'×4088) — 96 KiB of non-dedupable ballast; cycle 0 is exactly one
/// numeric hap 0.5, and the expr leaf only plays in cycle 25. The text
/// path ACCEPTS it (floor 753,664 B ≤ the shared 1 MiB); the A2 one-shot
/// binary dry-run REFUSED it (floor 1,253,376 B — the expr-leaf
/// retention machinery, ≈5× payload).
fn reproASource(a: std.mem.Allocator) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(a,
        \\(target :name glow :arity 1 :registry 0)
        \\(transport :bpm 120 :meter [4 4] :dur 64bar :end loop)
        \\(track :target glow :pattern (cat (pure 0.5)
        \\
    );
    for (0..24) |i| {
        try buf.append(a, '"');
        const idx = try std.fmt.allocPrint(a, "{d:0>8}", .{i});
        defer a.free(idx);
        try buf.appendSlice(a, idx);
        try buf.appendNTimes(a, 'a', 4088);
        try buf.appendSlice(a, "\"\n");
    }
    try buf.appendSlice(a, "(pure (+ 1 2))))\n");
    return a.dupeZ(u8, buf.items);
}

test "rt_entry (r): Repro A — a real-compile-accepted 98,501 B pattern loads (the window closes)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The text authority: the REAL compile accepts the score (its own
    // load dry-run queries cycle 0 under the identical 1 MiB) — the
    // independent oracle the runtime must not refuse.
    const src = try reproASource(a);
    var oracle = try compileOracle(a, src);
    defer oracle.deinit(a);

    // Pack through the T3.1 uniform path (compile + encode, no preflight
    // — pack's interim :pattern refusal is A3+A4 scope, pinned in
    // ParityTests) and pin the NAMED payload anchor: 98,501 B.
    const pacb = try packPatternForTest(a, src, &.{});
    const span = try soleExprSpan(pacb);
    try t.expectEqual(@as(usize, 98501), span.len);
    try t.expect(pacb.len < PACB_CAP);

    // THE WINDOW: through the A2 one-shot this load was status 1 reason
    // 11 (the retention cost rode every query); through the prepared
    // runtime it LOADS — the decode happens once at load, outside the
    // scratch, and the per-query cost is the tree path's.
    const status = loadPacB(pacb);
    if (status != 0) {
        std.debug.print("rt_entry (r): load refused — status={d} reason={d}\n", .{ status, prt_loadError() });
        return error.LoadRefused; // named in the failure output: 1=refused 3=oom
    }
    try t.expectEqual(@as(u32, 0), status);
    defer unload();

    // Explicit nonempty values (never oracle-only): cycle 0 writes
    // exactly one entry — glow 0.5 — and cycle 25 writes the expr
    // leaf's 3.0.
    const PPC = RtSjon.Pattern.PPC;
    {
        const frame = rtFrame(0);
        try t.expectEqual(@as(usize, 1), frame.len);
        try t.expectEqual(@as(f32, 0.5), frame[0].value[0]);
    }
    {
        const frame = rtFrame(25 * PPC);
        try t.expectEqual(@as(usize, 1), frame.len);
        try t.expectEqual(@as(f32, 3), frame[0].value[0]); // (+ 1 2) evaluated per cycle
    }
    // Byte-parity with the tree arm across cycles and a revisit — the
    // prepared object answers every query under the frame's own env.
    // The sweep stays on the window's numeric cycles (0 and 25): the
    // ballast cycles 1–24 carry STRING haps — a documented counted
    // omission on BOTH arms (the coerce channel) — and cycles past the
    // cat are the arms' shared exhausted-cat behavior, neither part of
    // this window proof; the counter must stay 0 here.
    const sweep = [_]i64{ 0, 25 * PPC, 0 };
    for (sweep) |tick| {
        const want = oracle.evaluator.evalTicks(tick);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
    }
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // The prepared state OWNS its decoded tree: clobbering the whole
    // input zone cannot move a frame (the 98.5 KiB of strings live in
    // the score-owned prepared tree, never aliased into the zone).
    @memset(&pacb_buffer, 0);
    for (sweep) |tick| {
        const want = oracle.evaluator.evalTicks(tick);
        try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
    }
}

test "rt_entry (s): the dense acceptance frontier does not shrink — fast 64 loads, literal and expr leaf" {
    // The A2 boundary probe's dense anchors (floors 274,432 B ≪ 1 MiB,
    // text = binary): the adoption must not narrow what the one-shot
    // accepted. `fast 64` with a literal hap and with an expr-leaf hap
    // both load status 0 and evaluate.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sources = [_][:0]const u8{
        \\(target :name glow :arity 1 :registry 0)
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(track :target glow :pattern (fast 64 (pure 1)))
        \\
        ,
        \\(target :name glow :arity 1 :registry 0)
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(track :target glow :pattern (fast 64 (pure (+ 1 2))))
        \\
        ,
    };
    for (sources) |src| {
        var oracle = try compileOracle(a, src);
        defer oracle.deinit(a);
        const pacb = try packPatternForTest(a, src, &.{});
        try t.expectEqual(@as(u32, 0), loadPacB(pacb));
        defer unload();
        for ([_]i64{ 0, RtSjon.Pattern.PPC / 2 }) |tick| {
            const want = oracle.evaluator.evalTicks(tick);
            try t.expect(want.len > 0);
            try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
        }
        try t.expectEqual(@as(u32, 0), prt_exprFailures());
    }
}

test "rt_entry (t): live control valid→invalid→valid through the loaded pattern — per-frame env freshness" {
    // The prepared object must classify under EACH query's live env,
    // never a classification cached at prepare/dry-run. Two top-level
    // pattern tracks, both omission channels:
    //   - the sway track `(pure (/ 2 sway))`: sway 0.25 writes 8.0;
    //     sway 0 fails the PER-QUERY leaf capture (diagnostics channel:
    //     the leaf degrades to silence, a plain silence gap —
    //     uncounted); sway 0.5 writes 4.0 again, same prepared object.
    //   - the hole track `(pure (/ 1 (- 1 cycle)))`: ÷0 exactly in
    //     cycle 1 — the hap DROPS, the write omits, the failure counter
    //     counts (the EvalCore hole semantics, loader-side); finite
    //     (1.0, then -1.0) everywhere else.
    // Every frame AND the failure counter are parity-checked against
    // the tree arm driven through the identical control sequence.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\(target :name glow :arity 1 :registry 0)
        \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
        \\(control :id sway :value 0.25)
        \\(track :target glow :pattern (pure (/ 2 sway)))
        \\(track :target glow :pattern (pure (/ 1 (- 1 cycle))))
        \\
    ;
    var oracle = try compileOracle(a, src);
    defer oracle.deinit(a);
    const pacb = try packPatternForTest(a, src, &.{});

    // The LOAD itself is a dry-run proof under the document value.
    try t.expectEqual(@as(u32, 0), loadPacB(pacb));
    defer unload();
    const PPC = RtSjon.Pattern.PPC;

    // One CAPTURE per tick: the failure counter accumulates per
    // evaluation, so every frame is captured exactly once and all
    // asserts read the capture.
    const c0 = try captureFrameDecoded(a, 7);
    try t.expectEqualSlices(Writes.Entry, oracle.evaluator.evalTicks(7), c0);
    try t.expectEqual(@as(usize, 2), c0.len);
    try t.expectEqual(@as(f32, 8), c0[0].value[0]);
    try t.expectEqual(@as(f32, 1), c0[1].value[0]);

    const c1 = try captureFrameDecoded(a, PPC + 7); // the drop, counted once
    try t.expectEqualSlices(Writes.Entry, oracle.evaluator.evalTicks(PPC + 7), c1);
    try t.expectEqual(@as(usize, 1), c1.len); // the dropped hap's hole
    try t.expectEqual(@as(u32, 1), prt_exprFailures());
    try t.expectEqual(@as(u64, 1), oracle.evaluator.expr_failures); // arms agree

    const c2 = try captureFrameDecoded(a, 2 * PPC + 7); // finite again, no new count
    try t.expectEqualSlices(Writes.Entry, oracle.evaluator.evalTicks(2 * PPC + 7), c2);
    try t.expectEqual(@as(f32, -1), c2[1].value[0]);
    try t.expectEqual(@as(u32, 1), prt_exprFailures());

    // INVALID: sway 0 → the sway leaf's per-query capture fails → that
    // leaf degrades to silence (uncounted) — the same prepared object
    // classifies afresh under the changed live env.
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0, 0, 0, 0));
    try t.expect(oracle.evaluator.setControl(0, .{ 0, 0, 0, 0 }));
    const c3 = try captureFrameDecoded(a, 7);
    try t.expectEqualSlices(Writes.Entry, oracle.evaluator.evalTicks(7), c3);
    try t.expectEqual(@as(usize, 1), c3.len); // only the hole track writes
    try t.expectEqual(@as(u32, 1), prt_exprFailures()); // uncounted on both arms
    try t.expectEqual(@as(u64, 1), oracle.evaluator.expr_failures);

    // VALID again: 2 / 0.5 = 4.0, the counter untouched.
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.5, 0, 0, 0));
    try t.expect(oracle.evaluator.setControl(0, .{ 0.5, 0, 0, 0 }));
    const c4 = try captureFrameDecoded(a, 7);
    try t.expectEqualSlices(Writes.Entry, oracle.evaluator.evalTicks(7), c4);
    try t.expectEqual(@as(usize, 2), c4.len);
    try t.expectEqual(@as(f32, 4), c4[0].value[0]);
    try t.expectEqual(@as(u32, 1), prt_exprFailures());
    try t.expectEqual(@as(u64, 1), oracle.evaluator.expr_failures);
}

// ---------------------------------------------------------------------------
// Group 5 — A3+A4 review carry (2026-10-22): the reload-carry gap. The
// (p)/(q) anchors prove a REFUSED pattern load keeps an old NON-pattern
// score alive; neither one exercises the seam the review named: a live
// PATTERN score being swapped successfully (new state, no leaks) or
// preserved under refusal (frames/controls/meta byte-identical). Both
// tests here drive the REAL production entries end to end, from the REAL
// producer (preflight + encode — pack accepts patterns since A3+A4).
// ---------------------------------------------------------------------------

/// The pattern-carrying live score: a real env pattern (a document
/// control read through the env's parent scope), an expr `bpm` probe
/// (the live tempo observable per frame) and a per-frame counting hole
/// (past beat 1, `(* beat 1e308)` overflows to a non-finite value — the
/// write omits and `expr_failures` increments; the compile-time dry-run
/// stays clean because the guarded branch is finite at its dry tick),
/// so a state or counter leak across a reload seam is visible in the
/// frames themselves.
const CARRY_PATTERN_SRC: [:0]const u8 =
    \\(target :name bpmout :arity 1 :registry 0)
    \\(target :name hole :arity 1 :registry 0)
    \\(transport :bpm 120 :meter [4 4])
    \\(control :id sway :value 0.5)
    \\(track :target radius :pattern (pure (* sway 2)))
    \\(track :target bpmout :expr bpm)
    \\(track :target hole :expr (if (< beat 2) 0 (* beat 1e308)))
;

/// The bpm probe score the successful swap lands on: no pattern, no
/// control — its single frame names the LIVE bpm, so the old score's
/// bpm nudge, pattern frames and held control must all be gone.
const CARRY_PROBE_SRC: [:0]const u8 =
    \\(target :name radius :arity 1 :registry 0)
    \\(transport :bpm 120 :meter [4 4])
    \\(track :target radius :expr bpm)
;

/// The pattern score's host join (radius only; bpmout is declared-only
/// and appends at compile).
const CARRY_TARGETS = [_]PactCodec.Target{
    .{ .name = "radius", .ncomp = 1, .registry = 0 },
};

test "rt_entry (u): successful reload FROM a live pattern score — the new score is live, nothing of the old leaks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pacb_p = try packPatternForTest(a, CARRY_PATTERN_SRC, &CARRY_TARGETS);
    const pacb_s = try packPatternForTest(a, CARRY_PROBE_SRC, &.{});

    // 1. Load the pattern score through the real loader; establish live
    //    state: held control, bpm nudge, frames, a nonzero counter.
    try t.expectEqual(@as(u32, 0), loadPacBT(pacb_p, &CARRY_TARGETS));
    defer unload();

    {
        const f = rtFrame(0);
        try t.expectEqual(@as(usize, 3), f.len); // hole is finite at beat 0
        try t.expectEqual(@as(f32, 1.0), f[0].value[0]); // sway 0.5 × 2
        try t.expectEqual(@as(f32, 120.0), f[1].value[0]); // the bpm probe
        try t.expectEqual(@as(f32, 0.0), f[2].value[0]); // the guarded hole
    }
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
    // Past beat 1 the hole overflows: the write omits, the counter counts.
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.75, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), prt_setBpm(90.0));
    {
        const f = rtFrame(0);
        try t.expectEqual(@as(f32, 1.5), f[0].value[0]); // 0.75 × 2, held
        try t.expectEqual(@as(f32, 90.0), f[1].value[0]); // nudged tempo
    }
    _ = rtFrame(540541); // beat 3: the hole overflows f64, omitted, counted
    const counter_before = prt_exprFailures();
    try t.expect(counter_before >= 1);
    const meta_p = try a.dupe(u8, prt_metaPtr()[0..prt_metaLen()]);
    const n_p = prt_evalTicks(0);
    const frame_p = try a.dupe(u8, writes_buffer[0..n_p]);

    // 2. THE SWAP: a successful reload of a different, clean score
    //    while the pattern score is live. The prepared pattern state,
    //    the held control and the bpm nudge all belong to the old
    //    evaluator — none may survive into the new one.
    try t.expectEqual(@as(u32, 0), loadPacB(pacb_s));

    // Meta is the NEW score's own 'PACM', not the pattern score's.
    const dir = Pacb.parseDirectory(pacb_s, null) catch unreachable;
    const sec = dir.find(.pacm).?;
    try t.expectEqualSlices(u8, pacb_s[sec.off..][0..sec.len], prt_metaPtr()[0..prt_metaLen()]);
    // The two scores' metas are different blobs; serving the old one
    // here would be a stale-meta leak.
    try t.expect(!std.mem.eql(u8, meta_p, prt_metaPtr()[0..prt_metaLen()]));

    // The frame is the NEW score's: one write, the FRESH transport bpm
    // (120 — the nudge to 90 died with the old evaluator; a leaked
    // pattern frame would carry radius/sway writes instead).
    const n_s = prt_evalTicks(0);
    try t.expect(n_s > 0);
    const zone_s: []align(4) const u8 = @alignCast(writes_buffer[0..n_s]);
    const f = Writes.decode(zone_s) orelse unreachable;
    try t.expectEqual(@as(usize, 1), f.len);
    try t.expectEqual(@as(f32, 120.0), f[0].value[0]);
    try t.expect(n_s != n_p or !std.mem.eql(u8, frame_p, writes_buffer[0..n_s]));

    // The counter is the NEW evaluator's: zero (a leak of the old
    // per-frame hole count is visible here).
    try t.expectEqual(@as(u32, 0), prt_exprFailures());

    // The held control did not survive: the new score has no control,
    // so index 0 must be REJECTED, not silently bound to the old slot.
    try t.expectEqual(@as(u32, 1), prt_setControl(0, 1, 0, 0, 0));

    // 3. And the seam carries INTO the pattern score again: a fresh
    //    load rebuilds it from its document state (sway 0.5, bpm 120),
    //    never from the mutated values an earlier session held.
    try t.expectEqual(@as(u32, 0), loadPacBT(pacb_p, &CARRY_TARGETS));
    const f2 = rtFrame(0);
    try t.expectEqual(@as(usize, 3), f2.len);
    try t.expectEqual(@as(f32, 1.0), f2[0].value[0]); // doc 0.5 × 2
    try t.expectEqual(@as(f32, 120.0), f2[1].value[0]); // doc bpm
    try t.expectEqual(@as(f32, 0.0), f2[2].value[0]); // guarded hole
    _ = rtFrame(540541); // beat 3: the fresh hole counts exactly once
    try t.expectEqual(@as(u32, 1), prt_exprFailures()); // fresh counter
}

test "rt_entry (v): refused and malformed reloads while a pattern score is live preserve its frames, controls and meta" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const pacb_p = try packPatternForTest(a, CARRY_PATTERN_SRC, &CARRY_TARGETS);

    try t.expectEqual(@as(u32, 0), loadPacBT(pacb_p, &CARRY_TARGETS));
    defer unload();

    // Live, non-default state: held control, bpm nudge, frames, counter.
    try t.expectEqual(@as(u32, 0), prt_setControl(0, 0.75, 0, 0, 0));
    try t.expectEqual(@as(u32, 0), prt_setBpm(90.0));
    _ = rtFrame(540541); // beat 3: the hole's omission, counted
    const counter = prt_exprFailures();
    try t.expect(counter >= 1);
    const meta_p = try a.dupe(u8, prt_metaPtr()[0..prt_metaLen()]);
    const n_p = prt_evalTicks(0);
    const frame_p = try a.dupe(u8, writes_buffer[0..n_p]);

    // (1) MALFORMED reload (status 1, reason 1): the corrupt bytes take
    //     over the ZONE — the live score owns its bytes, so the pattern
    //     still evaluates its own frame afterwards.
    const corrupt = try a.dupe(u8, pacb_p);
    std.mem.writeInt(u32, corrupt[4..8], 99, .little);
    try t.expectEqual(@as(u32, 1), loadPacB(corrupt));
    try t.expectEqual(@as(u32, 1), prt_loadError()); // unsupported_version
    try t.expectEqualSlices(u8, meta_p, prt_metaPtr()[0..prt_metaLen()]);
    const n1 = prt_evalTicks(0);
    try t.expectEqual(n_p, n1);
    try t.expectEqualSlices(u8, frame_p, writes_buffer[0..n1]);
    try t.expectEqual(@as(f32, 1.5), rtFrame(0)[0].value[0]); // held control
    try t.expectEqual(@as(f32, 90.0), rtFrame(0)[1].value[0]); // nudged bpm
    try t.expectEqual(counter, prt_exprFailures());

    // (2) REFUSED reload (status 1, reason 9): a valid blob against a
    //     mismatching host join — the transactional refusal keeps the
    //     pattern score and every piece of runtime state.
    const mutated = [_]PactCodec.Target{.{ .name = "radius", .ncomp = 2, .registry = 0 }};
    try t.expectEqual(@as(u32, 1), loadPacBT(pacb_p, &mutated));
    try t.expectEqual(@as(u32, 9), prt_loadError()); // registry_mismatch
    try t.expectEqualSlices(u8, meta_p, prt_metaPtr()[0..prt_metaLen()]);
    const n2 = prt_evalTicks(0);
    try t.expectEqual(n_p, n2);
    try t.expectEqualSlices(u8, frame_p, writes_buffer[0..n2]);
    try t.expectEqual(counter, prt_exprFailures());

    // (3) BAD CALL (status 2): validated before anything is touched — a
    //     true no-op, including the reason word.
    const reason_before = prt_loadError();
    try t.expectEqual(@as(u32, 2), prt_load(prt_pacbCap() + 1, 0));
    try t.expectEqual(reason_before, prt_loadError());
    try t.expectEqualSlices(u8, meta_p, prt_metaPtr()[0..prt_metaLen()]);
    const n3 = prt_evalTicks(0);
    try t.expectEqual(n_p, n3);
    try t.expectEqualSlices(u8, frame_p, writes_buffer[0..n3]);
    try t.expectEqual(counter, prt_exprFailures());
}

test "rt_entry: ownership — repeated reloads, eval-after-reload, no stale pointers" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fx_a = try readFixture(a, "keys-only");
    const fx_b = try readFixture(a, "full-small");
    const oracle_a = try compileOracle(a, fx_a.src);
    defer oracle_a.deinit(a);
    const oracle_b = try compileOracle(a, fx_b.src);
    defer oracle_b.deinit(a);

    // page_allocator munmaps the freed score's pages, so any stale read
    // after a swap faults instead of resurrecting bytes (ulimit -c 0).
    // Alternating successful loads is the struct-move/stale-pointer probe:
    // each new score was decoded, moved into its shell, and armed while
    // the predecessor's memory was still live, then the predecessor died.
    for (0..4) |round| {
        const use_a = round % 2 == 0;
        try t.expectEqual(@as(u32, 0), loadPacB(if (use_a) fx_a.pacb else fx_b.pacb));
        const oracle = if (use_a) oracle_a else oracle_b;
        for ([_]i64{ 0, 1, 96, 191, 192 }) |tick| {
            const want = oracle.evaluator.evalTicks(tick);
            try t.expectEqualSlices(u8, std.mem.sliceAsBytes(want), std.mem.sliceAsBytes(rtFrame(tick)));
        }
        // Meta is the CURRENT score's own copy.
        const pacb = if (use_a) fx_a.pacb else fx_b.pacb;
        const dir = Pacb.parseDirectory(pacb, null) catch unreachable;
        const sec = dir.find(.pacm).?;
        try t.expectEqualSlices(u8, pacb[sec.off..][0..sec.len], prt_metaPtr()[0..prt_metaLen()]);
    }
    unload();
    // After teardown the exports are inert again.
    try t.expectEqual(@as(u32, 0), prt_evalTicks(0));
    try t.expectEqual(@as(u32, 0), prt_eval(0.5));
    try t.expectEqual(@as(u32, 0), prt_metaLen());
    try t.expectEqual(@as(u32, 0), prt_exprFailures());
}
