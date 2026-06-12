//! `pacer.wasm` entry — static zones + the `drv_*` export surface.
//!
//! The artifact is a pure function of its linear memory: no clock, no
//! loop. One import rides in transitively (`env.sjon_host_invoke_plugin`,
//! SJON's executable-plugin dispatch) — pacer scores never declare
//! executable plugins, so hosts stub it with `() => 0`, which SJON maps
//! to a clean diagnostic rather than a trap.
//! The host writes the score text and the `'PACT'` target-registry blob
//! into the zones below, calls `drv_load`, then calls `drv_eval(seconds)`
//! per frame and reads the `'PACW'` write buffer back. Blob formats
//! live in `Abi` / `Writes` (natively tested); this file is only zone
//! plumbing and lifecycle.
//!
//! ## Memory zones
//!
//! ```
//! doc      256 KiB  ← host writes score text       (drv_docPtr/drv_docCap)
//! targets   64 KiB  ← host writes 'PACT' blob      (drv_targetsPtr/drv_targetsCap)
//! diags     64 KiB  → driver writes 'PACD' blob    (drv_diagPtr/drv_diagLen)
//! meta     192 KiB  → driver writes 'PACM' blob    (drv_metaPtr/drv_metaLen)
//! writes   ~8 KiB   → driver writes 'PACW' buffer  (drv_writesPtr)
//! heap              ← compile arena + evaluator (std.heap.wasm_allocator)
//! ```
//!
//! ## Lifecycle
//!
//! `drv_load(doc_len, targets_len)` → status:
//!   0 ok — table live, `drv_eval` armed (diag blob has 0 records);
//!   1 diagnostics — score defects, read the `'PACD'` blob; not loaded;
//!   2 bad call — lengths out of range or malformed `'PACT'` (host bug);
//!   3 out of memory.
//! Reloading is safe at any time: the previous table and evaluator are
//! torn down first — including ALL control state (held values, dynamic
//! slots); hosts re-apply held widgets after a reload. `drv_eval`/
//! `drv_evalTicks` return the encoded `'PACW'` length, or 0 when
//! nothing is loaded / the host clock is out of range (non-finite or
//! beyond the 2^53 tick ceiling).
//!
//! On a successful load the `'PACM'` metadata blob (transport, tracks
//! with key ticks + spans, controls — spans in user coordinates) is
//! encoded once; `drv_metaLen` is 0 when nothing is loaded or the blob
//! would not fit its zone (pathological scores only — meta never
//! silently truncates).
//!
//! Control state between loads: `drv_setControl(index, x, y, z, w)`
//! holds a live value (0 = ok, 1 = rejected — bad index / non-finite),
//! `drv_clearControl(index)` returns authority to the document;
//! `drv_registerControl(target_id, registry, ncomp)` adds a dynamic
//! slot for an editor lift (returns its index, `0xffffffff` when
//! rejected — the caller supplies the join, the table dropped target
//! names at load). `drv_setBpm(bpm)` rescales the seconds↔ticks
//! projection live (0 = ok, 1 = rejected).
//!
//! Append-only surface: never remove or re-type an export — bump
//! `drv_abiVersion` if the contract itself must change.

const std = @import("std");
const sjon = @import("sjon");
const Abi = @import("Abi.zig");
const Compile = @import("Compile.zig");
const Eval = @import("Eval.zig");
const TrackTable = @import("TrackTable.zig");
const Writes = @import("Writes.zig");

const gpa = std.heap.wasm_allocator;

const MAX_DOC_SIZE: usize = 256 * 1024;
const MAX_TARGETS_BLOB: usize = 64 * 1024;
const DIAGS_CAP: usize = 64 * 1024;
const META_CAP: usize = 192 * 1024;
/// Sized for a full house: every track, every document control, and
/// every dynamic slot writing on one frame.
const WRITES_CAP: usize = Writes.encodedLen(
    TrackTable.MAX_TRACKS + TrackTable.MAX_CONTROLS + Eval.MAX_DYNAMIC_CONTROLS,
);

/// `drv_registerControl` failure sentinel.
const NO_SLOT: u32 = 0xffff_ffff;

comptime {
    // The combined manifest+doc text must stay parseable by SJON.
    std.debug.assert(MAX_DOC_SIZE + Compile.manifest_src.len + 2 <= sjon.Binary.MAX_FILE_SIZE);
    // A full diag buffer still fits useful records (16-byte fixed part).
    std.debug.assert(DIAGS_CAP >= Abi.DIAGS_HEADER_LEN + 64 * (Abi.DIAG_RECORD_LEN + 256));
    // Meta at the caps fits with a generous control-id allowance.
    std.debug.assert(META_CAP >= Abi.META_HEADER_LEN +
        TrackTable.MAX_TRACKS * Abi.META_TRACK_LEN +
        TrackTable.MAX_KEYS * Abi.META_KEY_LEN +
        TrackTable.MAX_CONTROLS * (Abi.META_CONTROL_LEN + 256));
    // A registered slot index always fits the u32 return.
    std.debug.assert(TrackTable.MAX_CONTROLS + Eval.MAX_DYNAMIC_CONTROLS < NO_SLOT);
}

// ---------------------------------------------------------------------------
// Static zones
// ---------------------------------------------------------------------------

/// +1 slot for the sentinel `Compile.compile` requires.
var doc_buffer: [MAX_DOC_SIZE + 1]u8 = undefined;
var targets_buffer: [MAX_TARGETS_BLOB]u8 = undefined;
var diags_buffer: [DIAGS_CAP]u8 = undefined;
var diags_len: u32 = 0;
var meta_buffer: [META_CAP]u8 = undefined;
var meta_len: u32 = 0;
var writes_buffer: [WRITES_CAP]u8 align(4) = undefined;

/// Decoded 'PACT' scratch — names alias `targets_buffer`, consumed
/// entirely inside `drv_load`.
var targets_scratch: [Abi.MAX_TARGETS]Compile.Target = undefined;

/// Loaded state. `evaluator` borrows `result.?` whole (table + tree +
/// schema — expr tracks re-read the tree each frame), so teardown order
/// (evaluator first) and the no-reassign-while-live rule are
/// load-bearing — both are confined to `unload`/`drv_load`.
var result: ?Compile.CompileResult = null;
var evaluator: ?Eval.Evaluator = null;

const LoadStatus = enum(u32) { ok = 0, diagnostics = 1, bad_call = 2, oom = 3 };

// ---------------------------------------------------------------------------
// Exports — zone access
// ---------------------------------------------------------------------------

export fn drv_abiVersion() u32 {
    return 1;
}

export fn drv_docPtr() [*]u8 {
    return &doc_buffer;
}

export fn drv_docCap() u32 {
    return MAX_DOC_SIZE;
}

export fn drv_targetsPtr() [*]u8 {
    return &targets_buffer;
}

export fn drv_targetsCap() u32 {
    return MAX_TARGETS_BLOB;
}

export fn drv_diagPtr() [*]const u8 {
    return &diags_buffer;
}

export fn drv_diagLen() u32 {
    return diags_len;
}

export fn drv_metaPtr() [*]const u8 {
    return &meta_buffer;
}

export fn drv_metaLen() u32 {
    return meta_len;
}

export fn drv_writesPtr() [*]const u8 {
    return &writes_buffer;
}

// ---------------------------------------------------------------------------
// Exports — lifecycle + frame path
// ---------------------------------------------------------------------------

export fn drv_load(doc_len: u32, targets_len: u32) u32 {
    unload();
    diags_len = 0;
    if (doc_len > MAX_DOC_SIZE or targets_len > MAX_TARGETS_BLOB)
        return @intFromEnum(LoadStatus.bad_call);
    const targets = Abi.decodeTargets(targets_buffer[0..targets_len], &targets_scratch) orelse
        return @intFromEnum(LoadStatus.bad_call);

    doc_buffer[doc_len] = 0;
    const source: [:0]const u8 = doc_buffer[0..doc_len :0];

    var r = Compile.compile(gpa, source, targets) catch
        return @intFromEnum(LoadStatus.oom);
    // Encode diagnostics before any teardown — 'PACD' copies messages
    // into the static zone, so the host can read them after deinit.
    diags_len = @intCast(Abi.encodeDiags(&r, &diags_buffer).len);

    if (!r.ok()) {
        r.deinit();
        return @intFromEnum(LoadStatus.diagnostics);
    }
    result = r;
    evaluator = Eval.Evaluator.init(gpa, &result.?) catch {
        unload();
        return @intFromEnum(LoadStatus.oom);
    };
    // Meta never silently truncates; a blob too big for its zone
    // (pathological scores only — see the comptime bound) degrades to
    // an absent blob, not a wrong one.
    meta_len = if (Abi.encodeMeta(&result.?, &meta_buffer)) |m| @intCast(m.len) else |_| 0;
    return @intFromEnum(LoadStatus.ok);
}

export fn drv_setBpm(bpm: f64) u32 {
    const r = if (result) |*r| r else return 1;
    return if (r.setBpm(bpm)) 0 else 1;
}

export fn drv_setControl(index: u32, x: f32, y: f32, z: f32, w: f32) u32 {
    const ev = if (evaluator) |*e| e else return 1;
    return if (ev.setControl(index, .{ x, y, z, w })) 0 else 1;
}

export fn drv_clearControl(index: u32) u32 {
    const ev = if (evaluator) |*e| e else return 1;
    return if (ev.clearControl(index)) 0 else 1;
}

export fn drv_registerControl(target_id: u32, registry: u32, ncomp: u32) u32 {
    const ev = if (evaluator) |*e| e else return NO_SLOT;
    // Range-check before narrowing — host-glue input must not trap.
    if (target_id >= Eval.NO_TARGET or registry > 0xff or ncomp > 0xff) return NO_SLOT;
    const slot = ev.registerControl(@intCast(target_id), @intCast(registry), @intCast(ncomp)) orelse
        return NO_SLOT;
    return @intCast(slot);
}

export fn drv_eval(time_s: f64) u32 {
    const ev = if (evaluator) |*e| e else return 0;
    const entries = ev.evalSeconds(time_s) catch return 0;
    const out = Writes.encode(entries, &writes_buffer) catch unreachable; // WRITES_CAP covers MAX_TRACKS
    return @intCast(out.len);
}

/// Tick-domain twin (tests, corpus): total once loaded.
export fn drv_evalTicks(tick: i64) u32 {
    const ev = if (evaluator) |*e| e else return 0;
    const entries = ev.evalTicks(tick);
    const out = Writes.encode(entries, &writes_buffer) catch unreachable;
    return @intCast(out.len);
}

fn unload() void {
    meta_len = 0;
    if (evaluator) |*ev| {
        ev.deinit();
        evaluator = null;
    }
    if (result) |*r| {
        r.deinit();
        result = null;
    }
}
