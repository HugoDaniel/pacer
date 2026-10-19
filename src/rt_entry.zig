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
//! load-time work (table materialization + expr dry-runs).
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
const RtSjon = @import("RtSjon.zig");
const PactCodec = @import("PactCodec.zig");
const Pacb = @import("Pacb.zig");
const EvalCore = @import("EvalCore.zig");
const ExprTrack = @import("ExprTrack.zig");
const TrackTable = @import("TrackTable.zig");
const Writes = @import("Writes.zig");

/// On wasm32 `page_allocator` IS the WasmAllocator (heap.zig dispatches
/// `isWasm`); natively it is PageAllocator — one spelling, both targets.
/// Page-granule frees make a stale read after teardown fault instead of
/// silently resurrecting old bytes (the ownership tests lean on this).
const gpa = std.heap.page_allocator;

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

/// The binary arm's per-arm schema contract: the frozen core-only
/// schema — user heads never enter a binary because pack refuses them
/// (01, decision 8). File-scope so the slice's pointee outlives every
/// evaluator built against it.
const core_plugins = [_]RtSjon.Plugin.Plugin{RtSjon.plugins.core.plugin};
const core_only_schema: RtSjon.Schema.Schema = .{ .plugins = &core_plugins };

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

    // Pattern gate (P4 owner-pending): a blob requiring pattern tracks
    // is refused before any evaluator exists — the binary arm's pattern
    // payload slice stays empty by construction.
    if (score.required_features & Pacb.FEATURE_PATTERN_TRACKS != 0) {
        score.deinit();
        load_error = refusalReason(.unsupported_features);
        return @intFromEnum(LoadStatus.refused);
    }
    // Registry gate: the host join must BE the pack-time join — the
    // canonical-'PACT' byte equality is the one spelling of mismatch
    // (review O-2).
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
    shell.evaluator = EvalCore.Evaluator.initContext(shell.score.arena.allocator(), .{
        .table = &shell.table,
        .source = .{ .binary = .{ .expr = shell.expr_payloads } },
        .schema = core_only_schema,
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
/// evaluates. Arises here only.
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
    for (shell.score.tracks, tracks, expr_payloads) |dt, *track, *pl| {
        pl.* = null;
        const source: TrackTable.Source = switch (dt.source) {
            .keys => |ks| .{ .keys = .{ .start = ks.start, .len = ks.len } },
            .trigger => |trig| .{ .trigger = trig },
            .expr => |payload| blk: {
                pl.* = payload;
                break :blk .{ .expr = .invalid };
            },
            .pattern => |payload| blk: {
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
            .start_tick = ds.start_tick,
            .dur_ticks = ds.dur_ticks,
        };
    }
    const track_spans = a.alloc(RtSjon.Ast.Span, shell.score.tracks.len) catch return false;
    @memset(track_spans, .{ .start = 0, .end = 0 });
    const key_spans = a.alloc(RtSjon.Ast.Span, shell.score.keys.len) catch return false;
    @memset(key_spans, .{ .start = 0, .end = 0 });

    shell.expr_payloads = expr_payloads;
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
            core_only_schema,
            &table.transport,
            bindings,
            dry_tick,
            scene,
            track.ncomp,
        ) catch return false;
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
    const Compile = @import("Compile.zig");
    const Eval = @import("Eval.zig");
    const test_support = @import("test_support.zig");
    const oracle = try a.create(Oracle);
    errdefer a.destroy(oracle);
    oracle.result = try Compile.compile(a, test_support.schema(), src, &.{});
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
    if (ExprTrack.evalAtBinary(fba.allocator(), payload.?, core_only_schema, &score.transport, &.{}, 0, null, 1)) |_| {
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
