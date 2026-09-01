//! WASM boundary blobs — the packed little-endian formats that cross
//! the `pacer.wasm` linear-memory boundary, kept out of `wasm_entry.zig`
//! so both directions are natively testable (the SJON `wasm_common`
//! discipline). The JS glue in `npm/pacer` mirrors both with one
//! `DataView` pass each.
//!
//! Inbound (host → driver), `'PACT'` — the target-registry join list:
//!
//!     [magic u32]['PACT'][count u32]
//!     count × { ncomp u8, registry u8, name_len u16, name bytes }
//!
//! Decoded `Target.name`s alias the blob — they must only live for the
//! duration of one `Compile.compile` call (the table stores ids, never
//! names).
//!
//! Outbound (driver → host), `'PACD'` — load diagnostics, spans in SCORE
//! coordinates (the schema is preloaded beside the document, never
//! prepended to it, so no mapping happens anywhere):
//!
//!     [magic u32]['PACD'][version u32][count u32]
//!     count × { source u8, severity u8, code u16, start u32, end u32,
//!               msg_len u32, msg bytes }
//!
//!     source: 0 = SJON validation (code is `Ast.Diagnostic.Code`),
//!             1 = pacer load    (code is `Compile.Code`).
//!     severity: 0 = error, 1 = warning.
//!
//! Outbound (driver → host), `'PACM'` — score metadata for the editor
//! (timeline lanes, widget rails, commit-to-text anchors), encoded once
//! per successful load. All spans are USER source coordinates:
//!
//!     [magic u32]['PACM'][version u32]
//!     [bpm f64][dur i64][beats_per_bar u16][flags u8][pad u8]
//!         flags: bit0 = dur present, bit1 = end is loop.
//!     [track_count u32][key_count u32][control_count u32]
//!     track_count × 24 { target_id u16, registry u8, ncomp u8,
//!                        source u8 (0 keys / 1 expr / 2 trigger / 3 pattern), pad u8×3,
//!                        key_start u32, key_len u32 (0,0 for expr/trigger),
//!                        span_start u32, span_end u32 }
//!     key_count × 32 { at i64, value f32×4, span_start u32, span_end u32 }
//!     control_count × (64 + id) {
//!         target_id u16 (0xffff = env-only), registry u8, ncomp u8,
//!         type u8 (ControlType), flags u8 (bit0 min, bit1 max),
//!         id_len u16, value f32×4, min f32×4, max f32×4,
//!         value_span_start u32, value_span_end u32, id bytes }
//!
//! After the last control comes a SECTION STREAM — zero or more
//! length-prefixed TLV sections, walked to end-of-buffer, each:
//!
//!     [section_id u32][payload_len u32][payload : payload_len bytes]
//!
//! `section_id` is a 4-CC read LE (house magic style); `payload_len`
//! counts the payload only. A decoder loops to end-of-buffer, dispatching
//! known ids and skipping unknown ones by length (`off += 8 + payload_len`),
//! so a decoder predating a section ignores it and adding a section never
//! bumps `META_VERSION`. Each id appears at most once, encoder-emitted in a
//! fixed order; a section is OMITTED when its count is 0 (an empty and an
//! absent section are equivalent to a decoder), keeping a no-section blob
//! byte-stable. Payload shape is the section's own business — the house
//! pattern is `[count u32][fixed extern-struct record × count]`. A new
//! section adds its `metaWorstCase` term in the same commit that defines
//! its records — the worst-case sum lives beside the constants below and
//! must keep restating this spec. Defined:
//!
//!     'SCEN' scenes — [count u32] then count × 24 {
//!         start_tick i64, dur_ticks i64,
//!         name_span_start u32, name_span_end u32 }
//!       (the scene's name rides as a span like a track's — the editor
//!       slices it from source; scenes aren't a setControl lookup key.)
//!
//!     'EASE' easing programs — the deduped program table (`programs[0]`
//!       is the default linear) so an editor renders authored curves
//!       without re-parsing ease specs. Emitted AFTER 'SCEN', and OMITTED
//!       when the only program is linear (a linear-only blob stays
//!       byte-stable). Payload:
//!         [program_count u32]
//!         program_count × 772 {                 // MetaEaseProgramRec
//!           len u8, pad×3,
//!           8 × 96 {                            // MetaEaseStageRec (unused zeroed)
//!             t_end f32, v_base f32, v_span f32, ops_len u8, pad×3,
//!             4 × 20 { code u8, pad×3, params f32×4 } } }  // MetaEaseOpRec
//!         [key_ref_count u32]                    // == the key stream length
//!         key_ref_count × { ease_ref u16 }       // program index per key, in key order
//!       (a key's `ease_ref` names the program for the segment ENDING at
//!       it; index 0 = linear. The array parallels the `key_count` key
//!       records, so a decoder zips it with them.)
//!
//!     'TMPO' tempo map — the transport's piecewise segments (it/01), so
//!       a timeline consumer draws the true beat grid without re-parsing
//!       `(tempo …)` forms. Emitted AFTER 'EASE' (the fixed order is
//!       'SCEN', 'EASE', 'TMPO'), OMITTED when the score is constant-
//!       tempo (count would be 1 — segment 0 alone; a mapless blob stays
//!       byte-stable). Self-contained: segment 0 (tick 0, the
//!       transport's own `:bpm`) is INCLUDED, so no transport join is
//!       needed. Payload:
//!         [count u32]
//!         count × 16 { tick i64, bpm f64 }   // ascending, [0].tick == 0
//!
//! Both formats are wire-stable from day one: append/version, never
//! reorder. The third boundary format, `'PACW'`, lives in `Writes`.
//!
//! Release policy (all wire surfaces, `Writes` and `wasm_entry`
//! included): appending — a new TLV section, trailing field, enum
//! variant, or `drv_*` export — rides a MINOR release; bumping any blob
//! `VERSION` / `drv_abiVersion`, or reusing a section 4-CC, is a
//! BREAKING release — a major once 1.0 tags, a 0.x minor until then.

const std = @import("std");
const sjon = @import("sjon");
const Compile = @import("Compile.zig");
const TrackTable = @import("TrackTable.zig");
const Easing = @import("Easing.zig");
const test_support = @import("test_support.zig");

const Ast = sjon.Ast;

/// `"PACT"` read as LE u32.
pub const TARGETS_MAGIC: u32 = 0x54434150;
/// `"PACD"` read as LE u32.
pub const DIAGS_MAGIC: u32 = 0x44434150;
pub const DIAGS_VERSION: u32 = 1;
/// `"PACM"` read as LE u32.
pub const META_MAGIC: u32 = 0x4d434150;
pub const META_VERSION: u32 = 1;

pub const TARGETS_HEADER_LEN: usize = 8;
pub const DIAGS_HEADER_LEN: usize = 12;
/// Fixed bytes per diagnostic record, before its message.
pub const DIAG_RECORD_LEN: usize = 16;
/// magic+version (8) + transport block (20) + counts (12).
pub const META_HEADER_LEN: usize = 40;
pub const META_TRACK_LEN: usize = 24;
pub const META_KEY_LEN: usize = 32;
/// Fixed bytes per control record, before its id.
pub const META_CONTROL_LEN: usize = 64;
/// `target_id` of an env-only control in a meta record.
pub const META_NO_TARGET: u16 = 0xffff;
/// Frame header of a post-controls TLV section: `section_id`+`payload_len`.
pub const META_SECTION_HEADER_LEN: usize = 8;
/// `"SCEN"` read LE — the scenes section id in the meta section stream.
pub const SCENES_SECTION_ID: u32 = 0x4e454353;
/// Bytes per scene record inside the `'SCEN'` payload.
pub const SCENE_REC_LEN: usize = 24;
/// `"EASE"` read LE — the easing-program section id in the meta stream.
pub const EASE_SECTION_ID: u32 = 0x45534145;
/// `"TMPO"` read LE — the tempo-map section id in the meta stream.
pub const TEMPO_SECTION_ID: u32 = 0x4f504d54;
/// Bytes per tempo-segment record inside the `'TMPO'` payload.
pub const TEMPO_REC_LEN: usize = 16;
/// Bytes per compiled-op record inside an `'EASE'` program.
pub const META_EASE_OP_LEN: usize = 20;
/// Bytes per stage record inside an `'EASE'` program.
pub const META_EASE_STAGE_LEN: usize = 96;
/// Bytes per program record inside the `'EASE'` payload.
pub const META_EASE_PROGRAM_LEN: usize = 772;

/// Worst-case `'PACM'` blob size at every cap — term by term in wire
/// order, ending with the section stream. `id_allowance` is caller
/// policy: the format itself lets a control id run to 64 KiB; a zone
/// sizer picks its own per-control budget. CONVENTION: a new TLV section
/// adds its term HERE, in the same commit that defines its records —
/// this sum is the header's wire spec restated as arithmetic, and the
/// zone assert in `wasm_entry` calls it rather than re-spelling it.
pub fn metaWorstCase(comptime id_allowance: usize) usize {
    return META_HEADER_LEN +
        TrackTable.MAX_TRACKS * META_TRACK_LEN +
        TrackTable.MAX_KEYS * META_KEY_LEN +
        TrackTable.MAX_CONTROLS * (META_CONTROL_LEN + id_allowance) +
        META_SECTION_HEADER_LEN + 4 + TrackTable.MAX_SCENES * SCENE_REC_LEN + // 'SCEN'
        META_SECTION_HEADER_LEN + 4 + TrackTable.MAX_EASE_PROGRAMS * META_EASE_PROGRAM_LEN +
        4 + TrackTable.MAX_KEYS * 2 + // 'EASE' (programs + per-key ease_refs)
        META_SECTION_HEADER_LEN + 4 + TrackTable.MAX_TEMPO_SEGMENTS * TEMPO_REC_LEN; // 'TMPO'
}

/// Most registries any host may join at load. Generous: pngine uniform
/// tables run tens of fields, not hundreds.
pub const MAX_TARGETS = 1024;

/// Explicit error set: the destination buffer was too small.
pub const Error = error{BufferTooSmall};

// ---------------------------------------------------------------------------
// 'PACT' — targets in
// ---------------------------------------------------------------------------

/// Exact encoded size of a target list.
pub fn targetsEncodedLen(targets: []const Compile.Target) usize {
    var len: usize = TARGETS_HEADER_LEN;
    for (targets) |tg| len += 4 + tg.name.len;
    return len;
}

/// Encode a target list into `dest`. Used by tests and native hosts;
/// the JS glue produces the same bytes directly.
pub fn encodeTargets(targets: []const Compile.Target, dest: []u8) Error![]u8 {
    std.debug.assert(targets.len <= MAX_TARGETS);
    if (dest.len < targetsEncodedLen(targets)) return error.BufferTooSmall;
    std.mem.writeInt(u32, dest[0..4], TARGETS_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], @intCast(targets.len), .little);
    var pos: usize = TARGETS_HEADER_LEN;
    for (targets) |tg| {
        std.debug.assert(tg.ncomp >= 1);
        std.debug.assert(tg.ncomp <= 4);
        std.debug.assert(tg.name.len >= 1);
        std.debug.assert(tg.name.len <= std.math.maxInt(u16));
        dest[pos] = tg.ncomp;
        dest[pos + 1] = tg.registry;
        std.mem.writeInt(u16, dest[pos + 2 ..][0..2], @intCast(tg.name.len), .little);
        pos += 4;
        @memcpy(dest[pos..][0..tg.name.len], tg.name);
        pos += tg.name.len;
    }
    std.debug.assert(pos == targetsEncodedLen(targets));
    return dest[0..pos];
}

/// Decode a `'PACT'` blob into `out`. Returns the filled prefix, or
/// null on any defect (bad magic, truncation, ncomp ∉ 1..4, empty name,
/// trailing bytes, count > out.len) — the blob is host-glue output, so
/// a defect is a host bug, but it still must not trap the module.
/// Names alias `blob`.
pub fn decodeTargets(blob: []const u8, out: []Compile.Target) ?[]const Compile.Target {
    if (blob.len < TARGETS_HEADER_LEN) return null;
    if (std.mem.readInt(u32, blob[0..4], .little) != TARGETS_MAGIC) return null;
    const count = std.mem.readInt(u32, blob[4..8], .little);
    if (count > out.len) return null;
    var pos: usize = TARGETS_HEADER_LEN;
    for (0..count) |i| {
        if (blob.len - pos < 4) return null;
        const ncomp = blob[pos];
        const registry = blob[pos + 1];
        const name_len = std.mem.readInt(u16, blob[pos + 2 ..][0..2], .little);
        pos += 4;
        if (ncomp < 1 or ncomp > 4) return null;
        if (name_len == 0) return null;
        if (blob.len - pos < name_len) return null;
        out[i] = .{ .name = blob[pos..][0..name_len], .ncomp = ncomp, .registry = registry };
        pos += name_len;
    }
    if (pos != blob.len) return null;
    return out[0..count];
}

// ---------------------------------------------------------------------------
// 'PACD' — diagnostics out
// ---------------------------------------------------------------------------

/// Encode every diagnostic on a compile result — SJON validation first,
/// then pacer load codes. Total: records that don't fit in `dest` are
/// dropped and `count` reflects what was written (size `dest` so this
/// never bites; `wasm_entry` uses 64 KiB against typical sub-KiB loads).
pub fn encodeDiags(result: *const Compile.CompileResult, dest: []u8) []u8 {
    std.debug.assert(dest.len >= DIAGS_HEADER_LEN);
    const v = &result.validated;
    var pos: usize = DIAGS_HEADER_LEN;
    var count: u32 = 0;

    for (v.result.diagnostics) |d| {
        const severity: u8 = switch (d.severity) {
            .err => 0,
            .warning => 1,
        };
        if (!appendRecord(dest, &pos, 0, severity, @intCast(@intFromEnum(d.code)), d.span, d.message)) break;
        count += 1;
    }
    for (result.diagnostics) |d| {
        // Pacer load diagnostics are always errors (they void the table).
        if (!appendRecord(dest, &pos, 1, 0, @intFromEnum(d.code), d.span, d.message)) break;
        count += 1;
    }

    std.mem.writeInt(u32, dest[0..4], DIAGS_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], DIAGS_VERSION, .little);
    std.mem.writeInt(u32, dest[8..12], count, .little);
    return dest[0..pos];
}

/// Exact encoded size of every diagnostic on a result. `encodeDiags`
/// into a buffer at least this large never drops a record — the corpus
/// runner sizes with this; `wasm_entry` accepts truncation instead.
pub fn diagsEncodedLen(result: *const Compile.CompileResult) usize {
    var len: usize = DIAGS_HEADER_LEN;
    for (result.validated.result.diagnostics) |d| len += DIAG_RECORD_LEN + d.message.len;
    for (result.diagnostics) |d| len += DIAG_RECORD_LEN + d.message.len;
    return len;
}

fn appendRecord(dest: []u8, pos: *usize, source: u8, severity: u8, code: u16, span: Ast.Span, message: []const u8) bool {
    if (dest.len - pos.* < DIAG_RECORD_LEN + message.len) return false;
    dest[pos.*] = source;
    dest[pos.* + 1] = severity;
    std.mem.writeInt(u16, dest[pos.* + 2 ..][0..2], code, .little);
    std.mem.writeInt(u32, dest[pos.* + 4 ..][0..4], span.start, .little);
    std.mem.writeInt(u32, dest[pos.* + 8 ..][0..4], span.end, .little);
    std.mem.writeInt(u32, dest[pos.* + 12 ..][0..4], @intCast(message.len), .little);
    pos.* += DIAG_RECORD_LEN;
    @memcpy(dest[pos.*..][0..message.len], message);
    pos.* += message.len;
    return true;
}

// ---------------------------------------------------------------------------
// 'PACM' — score metadata out
// ---------------------------------------------------------------------------

/// 'PACM' track record — 24 bytes, mirrors META_TRACK_LEN. LE hosts only
/// (the module's standing assumption); encoded by value-copy like Writes.Entry.
const MetaTrackRec = extern struct {
    target_id: u16,
    registry: u8,
    ncomp: u8,
    source: u8, // 0 keys / 1 expr / 2 trigger / 3 pattern
    _pad: [3]u8 = .{ 0, 0, 0 },
    key_start: u32,
    key_len: u32,
    span_start: u32,
    span_end: u32,
};
const MetaKeyRec = extern struct {
    at: i64,
    value: [4]f32,
    span_start: u32,
    span_end: u32,
};
const MetaControlRec = extern struct {
    target_id: u16, // 0xffff = env-only
    registry: u8,
    ncomp: u8,
    kind: u8,
    flags: u8, // bit0 min, bit1 max
    id_len: u16,
    value: [4]f32,
    min: [4]f32,
    max: [4]f32,
    value_span_start: u32,
    value_span_end: u32,
};
/// One `'SCEN'` payload record — 24 bytes, mirrors SCENE_REC_LEN. The
/// scene's name rides as a span (like a track's), not inline bytes: the
/// editor slices it from source, and scenes are not a setControl key.
const MetaSceneRec = extern struct {
    start_tick: i64,
    dur_ticks: i64,
    name_span_start: u32,
    name_span_end: u32,
};
/// One `'TMPO'` payload record — 16 bytes, mirrors TEMPO_REC_LEN. The
/// authored `{tick, bpm}` pair verbatim (`TrackTable.TempoSegment`).
const MetaTempoRec = extern struct {
    tick: i64,
    bpm: f64,
};
/// One compiled easing op inside an `'EASE'` program record — mirrors
/// `Easing.OpRec` for the wire, with explicit padding so `asBytes`
/// carries no undefined bytes.
const MetaEaseOpRec = extern struct {
    code: u8, // Easing.Op
    _pad: [3]u8 = .{ 0, 0, 0 },
    params: [4]f32,
};
/// One stage inside an `'EASE'` program record — mirrors `Easing.Stage`.
/// Unused op slots are ZEROED (matching the compiled program's zero-fill),
/// so two equal programs serialize to equal bytes.
const MetaEaseStageRec = extern struct {
    t_end: f32,
    v_base: f32,
    v_span: f32,
    ops_len: u8,
    _pad: [3]u8 = .{ 0, 0, 0 },
    ops: [Easing.MAX_OPS]MetaEaseOpRec,
};
/// One compiled easing program — mirrors `Easing.Program`. Fixed size
/// (all stage/op slots present, unused ones zeroed) so the `'EASE'`
/// payload is `[count u32][rec × count]` exactly like `'SCEN'`.
const MetaEaseProgramRec = extern struct {
    len: u8, // live stage count
    _pad: [3]u8 = .{ 0, 0, 0 },
    stages: [Easing.MAX_STAGES]MetaEaseStageRec,
};

comptime {
    std.debug.assert(@sizeOf(MetaTrackRec) == META_TRACK_LEN);
    std.debug.assert(@sizeOf(MetaKeyRec) == META_KEY_LEN);
    std.debug.assert(@sizeOf(MetaControlRec) == META_CONTROL_LEN);
    std.debug.assert(@sizeOf(MetaSceneRec) == SCENE_REC_LEN);
    std.debug.assert(@sizeOf(MetaTempoRec) == TEMPO_REC_LEN);
    std.debug.assert(@offsetOf(MetaTempoRec, "bpm") == 8);
    std.debug.assert(@sizeOf(MetaEaseOpRec) == META_EASE_OP_LEN);
    std.debug.assert(@sizeOf(MetaEaseStageRec) == META_EASE_STAGE_LEN);
    std.debug.assert(@sizeOf(MetaEaseProgramRec) == META_EASE_PROGRAM_LEN);
    // spot-check a couple of offsets so a field reorder is a build break
    std.debug.assert(@offsetOf(MetaTrackRec, "key_start") == 8);
    std.debug.assert(@offsetOf(MetaControlRec, "value") == 8);
    std.debug.assert(@offsetOf(MetaControlRec, "value_span_start") == 56);
    std.debug.assert(@offsetOf(MetaSceneRec, "name_span_start") == 16);
    std.debug.assert(@offsetOf(MetaEaseStageRec, "ops") == 16);
    std.debug.assert(@offsetOf(MetaEaseProgramRec, "stages") == 4);
}

/// Widen one compiled `Easing.Program` into its wire record — all stage
/// and op slots copied (unused ones already zeroed on the program), so
/// the bytes are a pure function of the program.
fn easeProgramRec(prog: *const Easing.Program) MetaEaseProgramRec {
    var rec: MetaEaseProgramRec = .{ .len = prog.len, .stages = undefined };
    for (0..Easing.MAX_STAGES) |i| {
        const s = prog.stages[i];
        var srec: MetaEaseStageRec = .{
            .t_end = s.t_end,
            .v_base = s.v_base,
            .v_span = s.v_span,
            .ops_len = s.ops_len,
            .ops = undefined,
        };
        for (0..Easing.MAX_OPS) |j|
            srec.ops[j] = .{ .code = @intFromEnum(s.ops[j].code), .params = s.ops[j].params };
        rec.stages[i] = srec;
    }
    return rec;
}

/// Exact encoded size of the meta blob. Asserts a live table.
pub fn metaEncodedLen(result: *const Compile.CompileResult) usize {
    const table = &result.table.?;
    var len: usize = META_HEADER_LEN +
        table.tracks.len * META_TRACK_LEN +
        table.keys.len * META_KEY_LEN;
    for (table.controls) |c| len += META_CONTROL_LEN + c.id.len;
    // 'SCEN' section (omitted when there are no scenes, so a no-scenes
    // blob stays byte-identical to a pre-scenes one).
    if (table.scenes.len > 0)
        len += META_SECTION_HEADER_LEN + 4 + table.scenes.len * SCENE_REC_LEN;
    // 'EASE' section (omitted when the only program is the default linear
    // — `programs[0]` — so a linear-only blob stays byte-stable).
    if (table.programs.len > 1)
        len += META_SECTION_HEADER_LEN + 4 + table.programs.len * META_EASE_PROGRAM_LEN +
            4 + table.keys.len * 2;
    // 'TMPO' section (omitted for a constant-tempo score — segment 0
    // alone — so a mapless blob stays byte-stable).
    if (table.transport.segments.len > 1)
        len += META_SECTION_HEADER_LEN + 4 + table.transport.segments.len * TEMPO_REC_LEN;
    return len;
}

/// Encode the `'PACM'` blob for a successfully compiled score (asserts
/// `result.ok()`). Spans are score coordinates, written through
/// verbatim. Unlike diagnostics, metadata must never silently
/// truncate (the editor would desync), so a short `dest` is an error.
pub fn encodeMeta(result: *const Compile.CompileResult, dest: []u8) Error![]u8 {
    std.debug.assert(result.ok());
    const table = &result.table.?;
    const total = metaEncodedLen(result);
    if (dest.len < total) return error.BufferTooSmall;
    const map = &table.transport.map;

    std.mem.writeInt(u32, dest[0..4], META_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], META_VERSION, .little);
    std.mem.writeInt(u64, dest[8..16], @bitCast(map.bpm), .little);
    std.mem.writeInt(i64, dest[16..24], table.transport.dur orelse 0, .little);
    std.mem.writeInt(u16, dest[24..26], @intCast(map.beats_per_bar), .little);
    var tflags: u8 = 0;
    if (table.transport.dur != null) tflags |= 1;
    if (table.transport.end == .loop) tflags |= 2;
    dest[26] = tflags;
    dest[27] = 0;
    std.mem.writeInt(u32, dest[28..32], @intCast(table.tracks.len), .little);
    std.mem.writeInt(u32, dest[32..36], @intCast(table.keys.len), .little);
    std.mem.writeInt(u32, dest[36..40], @intCast(table.controls.len), .little);

    var pos: usize = META_HEADER_LEN;
    for (table.tracks, table.track_spans) |track, span| {
        const range: struct { start: u32, len: u32 } = switch (track.source) {
            .keys => |ks| .{ .start = ks.start, .len = ks.len },
            .expr, .trigger, .pattern => .{ .start = 0, .len = 0 },
        };
        const rec: MetaTrackRec = .{
            .target_id = track.target_id,
            .registry = track.registry,
            .ncomp = track.ncomp,
            // Append-only wire values — the npm glue's TRACK_SOURCES
            // mirrors this mapping by index.
            .source = switch (track.source) {
                .keys => 0,
                .expr => 1,
                .trigger => 2,
                .pattern => 3,
            },
            .key_start = range.start,
            .key_len = range.len,
            .span_start = span.start,
            .span_end = span.end,
        };
        @memcpy(dest[pos..][0..META_TRACK_LEN], std.mem.asBytes(&rec));
        pos += META_TRACK_LEN;
    }
    for (table.keys, table.key_spans) |key, span| {
        const rec: MetaKeyRec = .{
            .at = key.at,
            .value = key.value,
            .span_start = span.start,
            .span_end = span.end,
        };
        @memcpy(dest[pos..][0..META_KEY_LEN], std.mem.asBytes(&rec));
        pos += META_KEY_LEN;
    }
    for (table.controls) |ctl| {
        var cflags: u8 = 0;
        if (ctl.min != null) cflags |= 1;
        if (ctl.max != null) cflags |= 2;
        const rec: MetaControlRec = .{
            .target_id = if (ctl.target) |tg| tg.id else META_NO_TARGET,
            .registry = if (ctl.target) |tg| tg.registry else 0,
            .ncomp = ctl.ncomp,
            .kind = @intFromEnum(ctl.kind),
            .flags = cflags,
            .id_len = @intCast(ctl.id.len),
            .value = ctl.value,
            .min = ctl.min orelse .{ 0, 0, 0, 0 },
            .max = ctl.max orelse .{ 0, 0, 0, 0 },
            .value_span_start = ctl.value_span.start,
            .value_span_end = ctl.value_span.end,
        };
        @memcpy(dest[pos..][0..META_CONTROL_LEN], std.mem.asBytes(&rec));
        pos += META_CONTROL_LEN;
        @memcpy(dest[pos..][0..ctl.id.len], ctl.id);
        pos += ctl.id.len;
    }

    // The section stream: a 'SCEN' TLV frame when the score has scenes.
    if (table.scenes.len > 0) {
        std.mem.writeInt(u32, dest[pos..][0..4], SCENES_SECTION_ID, .little);
        std.mem.writeInt(u32, dest[pos + 4 ..][0..4], @intCast(4 + table.scenes.len * SCENE_REC_LEN), .little);
        pos += META_SECTION_HEADER_LEN;
        std.mem.writeInt(u32, dest[pos..][0..4], @intCast(table.scenes.len), .little);
        pos += 4;
        for (table.scenes) |scene| {
            const rec: MetaSceneRec = .{
                .start_tick = scene.start_tick,
                .dur_ticks = scene.dur_ticks,
                .name_span_start = scene.name_span.start,
                .name_span_end = scene.name_span.end,
            };
            @memcpy(dest[pos..][0..SCENE_REC_LEN], std.mem.asBytes(&rec));
            pos += SCENE_REC_LEN;
        }
    }

    // The 'EASE' section (after 'SCEN', fixed order): the deduped easing
    // program table plus a per-key program-index array parallel to the key
    // stream. An external editor renders authored curves from this without
    // re-parsing ease specs. Present only when a non-linear program exists.
    if (table.programs.len > 1) {
        const payload_len = 4 + table.programs.len * META_EASE_PROGRAM_LEN + 4 + table.keys.len * 2;
        std.mem.writeInt(u32, dest[pos..][0..4], EASE_SECTION_ID, .little);
        std.mem.writeInt(u32, dest[pos + 4 ..][0..4], @intCast(payload_len), .little);
        pos += META_SECTION_HEADER_LEN;
        std.mem.writeInt(u32, dest[pos..][0..4], @intCast(table.programs.len), .little);
        pos += 4;
        for (table.programs) |*prog| {
            const rec = easeProgramRec(prog);
            @memcpy(dest[pos..][0..META_EASE_PROGRAM_LEN], std.mem.asBytes(&rec));
            pos += META_EASE_PROGRAM_LEN;
        }
        std.mem.writeInt(u32, dest[pos..][0..4], @intCast(table.keys.len), .little);
        pos += 4;
        for (table.keys) |key| {
            std.mem.writeInt(u16, dest[pos..][0..2], key.ease_ref, .little);
            pos += 2;
        }
    }

    // The 'TMPO' section (after 'EASE', fixed order): the authored tempo
    // segments including segment 0, so a timeline consumer draws the true
    // beat grid with no transport join. Present only under a tempo map.
    if (table.transport.segments.len > 1) {
        const payload_len = 4 + table.transport.segments.len * TEMPO_REC_LEN;
        std.mem.writeInt(u32, dest[pos..][0..4], TEMPO_SECTION_ID, .little);
        std.mem.writeInt(u32, dest[pos + 4 ..][0..4], @intCast(payload_len), .little);
        pos += META_SECTION_HEADER_LEN;
        std.mem.writeInt(u32, dest[pos..][0..4], @intCast(table.transport.segments.len), .little);
        pos += 4;
        for (table.transport.segments) |seg| {
            const rec: MetaTempoRec = .{ .tick = seg.start_tick, .bpm = seg.bpm };
            @memcpy(dest[pos..][0..TEMPO_REC_LEN], std.mem.asBytes(&rec));
            pos += TEMPO_REC_LEN;
        }
    }

    std.debug.assert(pos == total);
    return dest[0..pos];
}

// ---------------------------------------------------------------------------
// 'PACD' / 'PACM' — decoding
// ---------------------------------------------------------------------------
//
// The reading halves of the two encode-only blobs, symmetric with
// `encodeTargets`/`decodeTargets` and `Writes.encode`/`decode`. Three
// consumers want them: `corpus_runner` (which used to walk the bytes
// inline), the native CLI, and any host that reads a blob back.
//
// Both decoders are TOTAL — every defect returns null rather than
// trapping, exactly as `decodeTargets` does, because a blob is host
// glue's output. Validation happens ONCE, at decode: lengths, magics,
// versions, enum bytes, and the section stream's exact accounting. The
// accessors are therefore assert-based rather than fallible, and every
// returned slice (a message, a control id) ALIASES `blob`.

/// Which encoder produced a `'PACD'` record — the `source` byte.
pub const DiagSource = enum(u8) { sjon = 0, pacer = 1 };
/// A `'PACD'` record's `severity` byte. Pacer records are always `err`.
pub const DiagSeverity = enum(u8) { err = 0, warning = 1 };

/// One decoded `'PACD'` record. `message` aliases the blob.
pub const DiagRecord = struct {
    source: DiagSource,
    severity: DiagSeverity,
    /// `Ast.Diagnostic.Code` when `source == .sjon`, `Compile.Code` when
    /// `.pacer` — the two code spaces are disjoint only by `source`.
    code: u16,
    span: Ast.Span,
    message: []const u8,
};

/// A validated `'PACD'` blob. Records come SJON-first, then pacer's —
/// the order `encodeDiags` writes and the golden pins.
pub const DiagView = struct {
    blob: []const u8,
    count: u32,

    pub const Iter = struct {
        blob: []const u8,
        left: u32,
        pos: usize,

        pub fn next(self: *Iter) ?DiagRecord {
            if (self.left == 0) return null;
            self.left -= 1;
            const b = self.blob;
            const p = self.pos;
            const msg_len = std.mem.readInt(u32, b[p + 12 ..][0..4], .little);
            self.pos = p + DIAG_RECORD_LEN + msg_len;
            return .{
                .source = @enumFromInt(b[p]),
                .severity = @enumFromInt(b[p + 1]),
                .code = std.mem.readInt(u16, b[p + 2 ..][0..2], .little),
                .span = .{
                    .start = std.mem.readInt(u32, b[p + 4 ..][0..4], .little),
                    .end = std.mem.readInt(u32, b[p + 8 ..][0..4], .little),
                },
                .message = b[p + DIAG_RECORD_LEN ..][0..msg_len],
            };
        }
    };

    pub fn records(self: *const DiagView) Iter {
        return .{ .blob = self.blob, .left = self.count, .pos = DIAGS_HEADER_LEN };
    }
};

/// Decode a `'PACD'` blob. Null on any defect: bad magic, a version this
/// build does not know, a truncated record or message, an out-of-range
/// `source`/`severity` byte, or trailing bytes past the last record.
pub fn decodeDiags(blob: []const u8) ?DiagView {
    if (blob.len < DIAGS_HEADER_LEN) return null;
    if (std.mem.readInt(u32, blob[0..4], .little) != DIAGS_MAGIC) return null;
    if (std.mem.readInt(u32, blob[4..8], .little) != DIAGS_VERSION) return null;
    const count = std.mem.readInt(u32, blob[8..12], .little);

    var pos: usize = DIAGS_HEADER_LEN;
    for (0..count) |_| {
        if (blob.len - pos < DIAG_RECORD_LEN) return null;
        if (std.enums.fromInt(DiagSource, blob[pos]) == null) return null;
        if (std.enums.fromInt(DiagSeverity, blob[pos + 1]) == null) return null;
        const msg_len = std.mem.readInt(u32, blob[pos + 12 ..][0..4], .little);
        pos += DIAG_RECORD_LEN;
        if (blob.len - pos < msg_len) return null;
        pos += msg_len;
    }
    if (pos != blob.len) return null;
    return .{ .blob = blob, .count = count };
}

/// A track's value source, as the `'PACM'` `source` byte spells it.
/// Append-only, mirroring the encoder's mapping and the npm glue's
/// `TRACK_SOURCES` table.
pub const TrackSourceKind = enum(u8) { keys = 0, expr = 1, trigger = 2, pattern = 3 };

/// One decoded `'PACM'` track record.
pub const MetaTrack = struct {
    target_id: u16,
    registry: u8,
    ncomp: u8,
    source: TrackSourceKind,
    /// Index of this track's first key in the flat key stream; `(0, 0)`
    /// for every non-key source.
    key_start: u32,
    key_len: u32,
    span: Ast.Span,
};

/// One decoded `'PACM'` key record. Lanes at or past the track's `ncomp`
/// are zero, as encoded.
pub const MetaKey = struct {
    at: i64,
    value: [4]f32,
    span: Ast.Span,
};

/// One decoded `'PACM'` control record. `id` aliases the blob;
/// `target_id` is null for an env-only control (the wire sentinel).
pub const MetaControl = struct {
    target_id: ?u16,
    registry: u8,
    ncomp: u8,
    kind: TrackTable.ControlType,
    value: [4]f32,
    min: ?[4]f32,
    max: ?[4]f32,
    id: []const u8,
    value_span: Ast.Span,
};

/// One decoded `'SCEN'` record. The name rides as a span — slice it from
/// the score source, as the encoder's header explains.
pub const MetaScene = struct {
    start_tick: i64,
    dur_ticks: i64,
    name_span: Ast.Span,
};

/// One decoded `'TMPO'` record — an authored `(tempo …)` segment.
pub const MetaTempoSeg = struct {
    tick: i64,
    bpm: f64,
};

/// A validated `'PACM'` blob: the fixed header plus cursors into the
/// three arrays and whichever TLV sections were present. An absent
/// section reads as an empty one (`sceneCount() == 0`), which is the
/// encoder's own equivalence — it omits a section whose count is zero.
pub const MetaView = struct {
    blob: []const u8,
    bpm: f64,
    /// null when the transport declared no `:dur` (the flags bit).
    dur: ?i64,
    end_loop: bool,
    beats_per_bar: u16,
    track_count: u32,
    key_count: u32,
    control_count: u32,
    /// Offset of the first control record — where the key array ends.
    controls_off: usize,
    scen: ?[]const u8 = null,
    ease: ?[]const u8 = null,
    tmpo: ?[]const u8 = null,

    fn keysOff(self: *const MetaView) usize {
        return META_HEADER_LEN + @as(usize, self.track_count) * META_TRACK_LEN;
    }

    pub fn track(self: *const MetaView, i: usize) MetaTrack {
        std.debug.assert(i < self.track_count);
        const r = self.blob[META_HEADER_LEN + i * META_TRACK_LEN ..][0..META_TRACK_LEN];
        return .{
            .target_id = std.mem.readInt(u16, r[0..2], .little),
            .registry = r[2],
            .ncomp = r[3],
            .source = @enumFromInt(r[4]),
            .key_start = std.mem.readInt(u32, r[8..12], .little),
            .key_len = std.mem.readInt(u32, r[12..16], .little),
            .span = .{
                .start = std.mem.readInt(u32, r[16..20], .little),
                .end = std.mem.readInt(u32, r[20..24], .little),
            },
        };
    }

    pub fn key(self: *const MetaView, i: usize) MetaKey {
        std.debug.assert(i < self.key_count);
        const r = self.blob[self.keysOff() + i * META_KEY_LEN ..][0..META_KEY_LEN];
        return .{
            .at = std.mem.readInt(i64, r[0..8], .little),
            .value = readLanes(r[8..24]),
            .span = .{
                .start = std.mem.readInt(u32, r[24..28], .little),
                .end = std.mem.readInt(u32, r[28..32], .little),
            },
        };
    }

    pub const ControlIter = struct {
        blob: []const u8,
        left: u32,
        pos: usize,

        pub fn next(self: *ControlIter) ?MetaControl {
            if (self.left == 0) return null;
            self.left -= 1;
            const r = self.blob[self.pos..][0..META_CONTROL_LEN];
            const target_id = std.mem.readInt(u16, r[0..2], .little);
            const flags = r[5];
            const id_len = std.mem.readInt(u16, r[6..8], .little);
            const id = self.blob[self.pos + META_CONTROL_LEN ..][0..id_len];
            self.pos += META_CONTROL_LEN + id_len;
            return .{
                .target_id = if (target_id == META_NO_TARGET) null else target_id,
                .registry = r[2],
                .ncomp = r[3],
                .kind = @enumFromInt(r[4]),
                .value = readLanes(r[8..24]),
                .min = if (flags & 1 != 0) readLanes(r[24..40]) else null,
                .max = if (flags & 2 != 0) readLanes(r[40..56]) else null,
                .id = id,
                .value_span = .{
                    .start = std.mem.readInt(u32, r[56..60], .little),
                    .end = std.mem.readInt(u32, r[60..64], .little),
                },
            };
        }
    };

    /// Controls in document order — which IS the `drv_setControl` index
    /// space, so the iteration index is the slot.
    pub fn controls(self: *const MetaView) ControlIter {
        return .{ .blob = self.blob, .left = self.control_count, .pos = self.controls_off };
    }

    pub fn sceneCount(self: *const MetaView) usize {
        const p = self.scen orelse return 0;
        return std.mem.readInt(u32, p[0..4], .little);
    }

    pub fn scene(self: *const MetaView, i: usize) MetaScene {
        std.debug.assert(i < self.sceneCount());
        const r = self.scen.?[4 + i * SCENE_REC_LEN ..][0..SCENE_REC_LEN];
        return .{
            .start_tick = std.mem.readInt(i64, r[0..8], .little),
            .dur_ticks = std.mem.readInt(i64, r[8..16], .little),
            .name_span = .{
                .start = std.mem.readInt(u32, r[16..20], .little),
                .end = std.mem.readInt(u32, r[20..24], .little),
            },
        };
    }

    pub fn tempoCount(self: *const MetaView) usize {
        const p = self.tmpo orelse return 0;
        return std.mem.readInt(u32, p[0..4], .little);
    }

    pub fn tempoSeg(self: *const MetaView, i: usize) MetaTempoSeg {
        std.debug.assert(i < self.tempoCount());
        const r = self.tmpo.?[4 + i * TEMPO_REC_LEN ..][0..TEMPO_REC_LEN];
        return .{
            .tick = std.mem.readInt(i64, r[0..8], .little),
            .bpm = @bitCast(std.mem.readInt(u64, r[8..16], .little)),
        };
    }

    pub fn easeProgramCount(self: *const MetaView) usize {
        const p = self.ease orelse return 0;
        return std.mem.readInt(u32, p[0..4], .little);
    }

    /// Rebuild one compiled program from its wire record. Every stage and
    /// op slot is carried (unused ones zeroed by the encoder), so this is
    /// bit-equal to the `TrackTable.programs` entry it came from.
    pub fn easeProgram(self: *const MetaView, i: usize) Easing.Program {
        std.debug.assert(i < self.easeProgramCount());
        const r = self.ease.?[4 + i * META_EASE_PROGRAM_LEN ..][0..META_EASE_PROGRAM_LEN];
        var prog: Easing.Program = .{ .len = r[0], .stages = undefined };
        for (0..Easing.MAX_STAGES) |s| {
            const sr = r[4 + s * META_EASE_STAGE_LEN ..][0..META_EASE_STAGE_LEN];
            var stage: Easing.Stage = .{
                .t_end = readF32(sr[0..4]),
                .v_base = readF32(sr[4..8]),
                .v_span = readF32(sr[8..12]),
                .ops_len = sr[12],
                .ops = undefined,
            };
            for (0..Easing.MAX_OPS) |o| {
                const orr = sr[16 + o * META_EASE_OP_LEN ..][0..META_EASE_OP_LEN];
                stage.ops[o] = .{
                    .code = @enumFromInt(orr[0]),
                    .params = readLanes(orr[4..20]),
                };
            }
            prog.stages[s] = stage;
        }
        return prog;
    }

    /// Offset of the per-key `ease_ref` array inside the `'EASE'` payload.
    fn easeRefsOff(self: *const MetaView) usize {
        return 4 + self.easeProgramCount() * META_EASE_PROGRAM_LEN;
    }

    pub fn easeRefCount(self: *const MetaView) usize {
        const p = self.ease orelse return 0;
        return std.mem.readInt(u32, p[self.easeRefsOff()..][0..4], .little);
    }

    /// The program index for the segment ENDING at key `i` — parallel to
    /// the key stream, so a consumer zips it with `key(i)`.
    pub fn easeRef(self: *const MetaView, i: usize) u16 {
        std.debug.assert(i < self.easeRefCount());
        const p = self.ease.?;
        return std.mem.readInt(u16, p[self.easeRefsOff() + 4 + i * 2 ..][0..2], .little);
    }
};

fn readF32(b: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, b, .little));
}

fn readLanes(b: *const [16]u8) [4]f32 {
    var out: [4]f32 = undefined;
    for (0..4) |i| out[i] = readF32(b[i * 4 ..][0..4]);
    return out;
}

/// Decode a `'PACM'` blob. Null on any defect: bad magic, a version this
/// build does not know, a truncated array or control id, an enum byte
/// outside `TrackSourceKind` / `ControlType` / `Easing.Op`, a key range
/// running past the key stream, a section frame whose payload does not
/// account exactly for its records, a repeated section id, or bytes left
/// over after the last frame.
///
/// An UNKNOWN section id is skipped by its length — that tolerance is the
/// whole point of the TLV stream, so a decoder predating a section still
/// reads everything before it.
pub fn decodeMeta(blob: []const u8) ?MetaView {
    if (blob.len < META_HEADER_LEN) return null;
    if (std.mem.readInt(u32, blob[0..4], .little) != META_MAGIC) return null;
    if (std.mem.readInt(u32, blob[4..8], .little) != META_VERSION) return null;

    const flags = blob[26];
    const track_count = std.mem.readInt(u32, blob[28..32], .little);
    const key_count = std.mem.readInt(u32, blob[32..36], .little);
    const control_count = std.mem.readInt(u32, blob[36..40], .little);

    var pos: usize = META_HEADER_LEN;
    if ((blob.len - pos) / META_TRACK_LEN < track_count) return null;
    for (0..track_count) |i| {
        const r = blob[pos + i * META_TRACK_LEN ..][0..META_TRACK_LEN];
        if (std.enums.fromInt(TrackSourceKind, r[4]) == null) return null;
        const ks = std.mem.readInt(u32, r[8..12], .little);
        const kl = std.mem.readInt(u32, r[12..16], .little);
        if (@as(u64, ks) + kl > key_count) return null;
    }
    pos += @as(usize, track_count) * META_TRACK_LEN;

    if ((blob.len - pos) / META_KEY_LEN < key_count) return null;
    pos += @as(usize, key_count) * META_KEY_LEN;

    const controls_off = pos;
    for (0..control_count) |_| {
        if (blob.len - pos < META_CONTROL_LEN) return null;
        if (std.enums.fromInt(TrackTable.ControlType, blob[pos + 4]) == null) return null;
        const id_len = std.mem.readInt(u16, blob[pos + 6 ..][0..2], .little);
        pos += META_CONTROL_LEN;
        if (blob.len - pos < id_len) return null;
        pos += id_len;
    }

    var view: MetaView = .{
        .blob = blob,
        .bpm = @bitCast(std.mem.readInt(u64, blob[8..16], .little)),
        .dur = if (flags & 1 != 0) std.mem.readInt(i64, blob[16..24], .little) else null,
        .end_loop = flags & 2 != 0,
        .beats_per_bar = std.mem.readInt(u16, blob[24..26], .little),
        .track_count = track_count,
        .key_count = key_count,
        .control_count = control_count,
        .controls_off = controls_off,
    };

    // The TLV section stream, walked to end-of-buffer.
    while (pos < blob.len) {
        if (blob.len - pos < META_SECTION_HEADER_LEN) return null;
        const sid = std.mem.readInt(u32, blob[pos..][0..4], .little);
        const plen = std.mem.readInt(u32, blob[pos + 4 ..][0..4], .little);
        pos += META_SECTION_HEADER_LEN;
        if (blob.len - pos < plen) return null;
        const payload = blob[pos..][0..plen];
        pos += plen;

        switch (sid) {
            SCENES_SECTION_ID => {
                if (view.scen != null) return null;
                if (plen < 4) return null;
                const n = std.mem.readInt(u32, payload[0..4], .little);
                if (4 + @as(u64, n) * SCENE_REC_LEN != plen) return null;
                view.scen = payload;
            },
            EASE_SECTION_ID => {
                if (view.ease != null) return null;
                if (plen < 4) return null;
                const progs = std.mem.readInt(u32, payload[0..4], .little);
                const refs_off = 4 + @as(u64, progs) * META_EASE_PROGRAM_LEN;
                if (refs_off + 4 > plen) return null;
                const refs = std.mem.readInt(u32, payload[@intCast(refs_off)..][0..4], .little);
                if (refs_off + 4 + @as(u64, refs) * 2 != plen) return null;
                // Every op byte must name a real primitive: `easeProgram`
                // returns `Easing.Op` values, so an unknown code would be
                // an invalid enum rather than a diagnosable defect.
                for (0..progs) |p| {
                    const r = payload[4 + p * META_EASE_PROGRAM_LEN ..][0..META_EASE_PROGRAM_LEN];
                    for (0..Easing.MAX_STAGES) |s| {
                        const sr = r[4 + s * META_EASE_STAGE_LEN ..][0..META_EASE_STAGE_LEN];
                        for (0..Easing.MAX_OPS) |o|
                            if (std.enums.fromInt(Easing.Op, sr[16 + o * META_EASE_OP_LEN]) == null) return null;
                    }
                }
                view.ease = payload;
            },
            TEMPO_SECTION_ID => {
                if (view.tmpo != null) return null;
                if (plen < 4) return null;
                const n = std.mem.readInt(u32, payload[0..4], .little);
                if (4 + @as(u64, n) * TEMPO_REC_LEN != plen) return null;
                view.tmpo = payload;
            },
            else => {}, // unknown id — skipped by length, the TLV contract
        }
    }
    std.debug.assert(pos == blob.len);
    return view;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

const sample_targets = [_]Compile.Target{
    .{ .name = "circle-radius", .ncomp = 1 },
    .{ .name = "tint", .ncomp = 3 },
    .{ .name = "cutoff", .ncomp = 1, .registry = 1 },
};

test "targets round-trip: encode then decode preserves every field" {
    var blob: [256]u8 = undefined;
    const encoded = try encodeTargets(&sample_targets, &blob);
    var out: [8]Compile.Target = undefined;
    const back = decodeTargets(encoded, &out).?;
    try t.expectEqual(sample_targets.len, back.len);
    for (sample_targets, back) |want, got| {
        try t.expectEqualStrings(want.name, got.name);
        try t.expectEqual(want.ncomp, got.ncomp);
        try t.expectEqual(want.registry, got.registry);
    }
}

test "decodeTargets rejects every malformed shape" {
    var blob: [256]u8 = undefined;
    const encoded = try encodeTargets(&sample_targets, &blob);
    var out: [8]Compile.Target = undefined;

    var bad_magic: [256]u8 = undefined;
    @memcpy(bad_magic[0..encoded.len], encoded);
    bad_magic[0] ^= 0xff;
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(bad_magic[0..encoded.len], &out));

    // Truncated: mid-header, mid-record, mid-name.
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(encoded[0..4], &out));
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(encoded[0..10], &out));
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(encoded[0 .. encoded.len - 1], &out));

    // Trailing garbage — `encoded` aliases `blob`, so just widen the view.
    blob[encoded.len] = 0;
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(blob[0 .. encoded.len + 1], &out));

    // ncomp out of 1..4 (first record's ncomp byte sits right after the header).
    var bad_ncomp: [256]u8 = undefined;
    @memcpy(bad_ncomp[0..encoded.len], encoded);
    bad_ncomp[TARGETS_HEADER_LEN] = 0;
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(bad_ncomp[0..encoded.len], &out));
    bad_ncomp[TARGETS_HEADER_LEN] = 5;
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(bad_ncomp[0..encoded.len], &out));

    // More targets than the caller's capacity.
    var tiny: [2]Compile.Target = undefined;
    try t.expectEqual(@as(?[]const Compile.Target, null), decodeTargets(encoded, &tiny));
}

test "encodeTargets fails on a short destination" {
    var small: [4]u8 = undefined;
    try t.expectError(error.BufferTooSmall, encodeTargets(&sample_targets, &small));
}

test "encodeDiags: pacer diagnostic carries its score-coordinate span" {
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target nonexistent (key :at 0b :value 1))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    try t.expect(!r.ok());

    var buf: [4096]u8 = undefined;
    const encoded = encodeDiags(&r, &buf);

    try t.expectEqual(DIAGS_MAGIC, std.mem.readInt(u32, encoded[0..4], .little));
    try t.expectEqual(DIAGS_VERSION, std.mem.readInt(u32, encoded[4..8], .little));
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, encoded[8..12], .little));

    const rec = encoded[DIAGS_HEADER_LEN..];
    try t.expectEqual(@as(u8, 1), rec[0]); // source: pacer
    try t.expectEqual(@as(u8, 0), rec[1]); // severity: error
    try t.expectEqual(@intFromEnum(Compile.Code.unknown_target), std.mem.readInt(u16, rec[2..4], .little));
    // The span covers `nonexistent` in USER coordinates.
    const start = std.mem.readInt(u32, rec[4..8], .little);
    const end = std.mem.readInt(u32, rec[8..12], .little);
    try t.expectEqualStrings("nonexistent", source[start..end]);
    const msg_len = std.mem.readInt(u32, rec[12..16], .little);
    try t.expectEqual(encoded.len, DIAGS_HEADER_LEN + DIAG_RECORD_LEN + msg_len);
}

test "encodeDiags: SJON validation diagnostic rides as source 0" {
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target tint (key :at 4 :value [1 1 1]))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    try t.expect(!r.ok());

    var buf: [4096]u8 = undefined;
    const encoded = encodeDiags(&r, &buf);
    try t.expect(std.mem.readInt(u32, encoded[8..12], .little) >= 1);

    const rec = encoded[DIAGS_HEADER_LEN..];
    try t.expectEqual(@as(u8, 0), rec[0]); // source: SJON
    try t.expectEqual(
        @as(u16, @intCast(@intFromEnum(Ast.Diagnostic.Code.unit_required))),
        std.mem.readInt(u16, rec[2..4], .little),
    );
    // The span lands on the bare `4` in score coordinates.
    const start = std.mem.readInt(u32, rec[4..8], .little);
    try t.expectEqualStrings("4", source[start .. start + 1]);
}

test "encodeDiags: clean compile yields an empty record set" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target tint (key :at 0b :value [1 0 0]))
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());

    var buf: [64]u8 = undefined;
    const encoded = encodeDiags(&r, &buf);
    try t.expectEqual(DIAGS_HEADER_LEN, encoded.len);
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, encoded[8..12], .little));
}

test "encodeMeta: transport, tracks, keys, controls — spans in score coordinates" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8))
        \\(track :target tint :expr [1 0 0])
        \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());

    var buf: [4096]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    try t.expectEqual(metaEncodedLen(&r), m.len);

    try t.expectEqual(META_MAGIC, std.mem.readInt(u32, m[0..4], .little));
    try t.expectEqual(META_VERSION, std.mem.readInt(u32, m[4..8], .little));
    try t.expectEqual(@as(f64, 120), @as(f64, @bitCast(std.mem.readInt(u64, m[8..16], .little))));
    try t.expectEqual(2 * sjon.Pattern.PPC, std.mem.readInt(i64, m[16..24], .little));
    try t.expectEqual(@as(u16, 4), std.mem.readInt(u16, m[24..26], .little));
    try t.expectEqual(@as(u8, 3), m[26]); // dur present + loop
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, m[28..32], .little));
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, m[32..36], .little));
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, m[36..40], .little));

    // Track 0: keyframed, keys [0..2), span starts at its form.
    const t0 = m[META_HEADER_LEN..][0..META_TRACK_LEN];
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, t0[0..2], .little));
    try t.expectEqual(@as(u8, 1), t0[3]); // ncomp
    try t.expectEqual(@as(u8, 0), t0[4]); // source: keys
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, t0[8..12], .little));
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, t0[12..16], .little));
    const t0_start = std.mem.readInt(u32, t0[16..20], .little);
    try t.expectEqualStrings("(track", source[t0_start..][0..6]);

    // Track 1: expr-sourced, empty key range.
    const t1 = m[META_HEADER_LEN + META_TRACK_LEN ..][0..META_TRACK_LEN];
    try t.expectEqual(@as(u8, 1), t1[4]); // source: expr
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, t1[12..16], .little));

    // Key 1: tick exact, value bit-exact, span covers the (key …) form.
    const keys_off = META_HEADER_LEN + 2 * META_TRACK_LEN;
    const k1 = m[keys_off + META_KEY_LEN ..][0..META_KEY_LEN];
    try t.expectEqual(@as(i64, 4 * 180180), std.mem.readInt(i64, k1[0..8], .little));
    try t.expectEqual(@as(f32, 0.8), @as(f32, @bitCast(std.mem.readInt(u32, k1[8..12], .little))));
    const k1_span_start = std.mem.readInt(u32, k1[24..28], .little);
    const k1_span_end = std.mem.readInt(u32, k1[28..32], .little);
    try t.expectEqualStrings("(key :at 4b :value 0.8)", source[k1_span_start..k1_span_end]);

    // Control: join, flags, range, id, and the :value commit anchor.
    const c0 = m[keys_off + 2 * META_KEY_LEN ..][0..META_CONTROL_LEN];
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, c0[0..2], .little));
    try t.expectEqual(@as(u8, 1), c0[3]); // ncomp
    try t.expectEqual(@as(u8, 0), c0[4]); // type: slider
    try t.expectEqual(@as(u8, 3), c0[5]); // min + max present
    try t.expectEqual(@as(u16, 4), std.mem.readInt(u16, c0[6..8], .little));
    try t.expectEqual(@as(f32, 0.4), @as(f32, @bitCast(std.mem.readInt(u32, c0[8..12], .little))));
    try t.expectEqual(@as(f32, 1), @as(f32, @bitCast(std.mem.readInt(u32, c0[40..44], .little))));
    const vs_start = std.mem.readInt(u32, c0[56..60], .little);
    const vs_end = std.mem.readInt(u32, c0[60..64], .little);
    try t.expectEqualStrings("0.4", source[vs_start..vs_end]);
    const id_off = keys_off + 2 * META_KEY_LEN + META_CONTROL_LEN;
    try t.expectEqualStrings("knob", m[id_off..][0..4]);
    try t.expectEqual(id_off + 4, m.len);
}

test "encodeMeta: env-only control carries the no-target sentinel" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id sway :value 0.12)
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    var buf: [512]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    const c0 = m[META_HEADER_LEN..][0..META_CONTROL_LEN];
    try t.expectEqual(META_NO_TARGET, std.mem.readInt(u16, c0[0..2], .little));
    try t.expectEqual(@as(u8, 0), c0[5]); // no min/max
    try t.expectEqual(@as(u8, 0), m[26]); // no dur, hold
}

test "encodeMeta refuses a short destination (no silent truncation)" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target tint (key :at 0b :value [1 0 0]))
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    var small: [META_HEADER_LEN + META_TRACK_LEN]u8 = undefined;
    try t.expectError(error.BufferTooSmall, encodeMeta(&r, &small));
}

test "encodeDiags truncates whole records when the buffer is tight" {
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target nope-a (key :at 0b :value 1))
        \\(track :target nope-b (key :at 0b :value 1))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    try t.expectEqual(@as(usize, 2), r.diagnostics.len);

    // Room for the header and one record (+message), not two.
    const one_record = DIAGS_HEADER_LEN + DIAG_RECORD_LEN + r.diagnostics[0].message.len;
    var buf: [4096]u8 = undefined;
    const encoded = encodeDiags(&r, buf[0 .. one_record + 8]);
    try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, encoded[8..12], .little));
    try t.expectEqual(one_record, encoded.len);
}

test "encodeMeta: a scenes section rides after the controls as a 'SCEN' TLV frame" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name intro :at 0b :dur 4b
        \\  (track :target circle-radius (key :at 0b :value 0.1)))
        \\(scene :name drop :at 8b :dur 4b
        \\  (track :target circle-radius (key :at 0b :value 0.9)))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());

    var buf: [4096]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    try t.expectEqual(metaEncodedLen(&r), m.len);

    // 2 scened tracks, 2 keys, 0 controls → the section follows directly.
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, m[28..32], .little)); // tracks
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, m[32..36], .little)); // keys
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, m[36..40], .little)); // controls
    const sec = META_HEADER_LEN + 2 * META_TRACK_LEN + 2 * META_KEY_LEN;

    // Frame header: id 'SCEN', payload_len = 4 (count) + 2 × 24 (records).
    try t.expectEqual(SCENES_SECTION_ID, std.mem.readInt(u32, m[sec..][0..4], .little));
    const plen = std.mem.readInt(u32, m[sec + 4 ..][0..4], .little);
    try t.expectEqual(@as(u32, 4 + 2 * SCENE_REC_LEN), plen);
    // The frame accounts for exactly the rest of the blob (self-delimiting).
    try t.expectEqual(m.len, sec + META_SECTION_HEADER_LEN + plen);

    const body = sec + META_SECTION_HEADER_LEN;
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, m[body..][0..4], .little)); // count
    const ppb: i64 = 180180;

    const rec0 = body + 4;
    try t.expectEqual(@as(i64, 0), std.mem.readInt(i64, m[rec0..][0..8], .little));
    try t.expectEqual(@as(i64, 4 * ppb), std.mem.readInt(i64, m[rec0 + 8 ..][0..8], .little));
    const n0s = std.mem.readInt(u32, m[rec0 + 16 ..][0..4], .little);
    const n0e = std.mem.readInt(u32, m[rec0 + 20 ..][0..4], .little);
    try t.expectEqualStrings("intro", source[n0s..n0e]);

    const rec1 = rec0 + SCENE_REC_LEN;
    try t.expectEqual(@as(i64, 8 * ppb), std.mem.readInt(i64, m[rec1..][0..8], .little));
    try t.expectEqual(@as(i64, 4 * ppb), std.mem.readInt(i64, m[rec1 + 8 ..][0..8], .little));
    const n1s = std.mem.readInt(u32, m[rec1 + 16 ..][0..4], .little);
    const n1e = std.mem.readInt(u32, m[rec1 + 20 ..][0..4], .little);
    try t.expectEqualStrings("drop", source[n1s..n1e]);
}

test "encodeMeta: a score with no scenes emits no 'SCEN' frame" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius (key :at 0b :value 0.1))
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    var buf: [512]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    // 1 track, 1 key, 0 controls, 0 scenes → the blob ends at the last
    // record with no trailing section (byte-identical to a pre-scenes blob).
    try t.expectEqual(META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN, m.len);
}

test "PACM section walk: an unknown-id section is skipped, scenes still decode" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name intro :at 0b :dur 4b
        \\  (track :target circle-radius (key :at 0b :value 0.1)))
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    var buf: [4096]u8 = undefined;
    const m = try encodeMeta(&r, &buf);

    // The real 'SCEN' frame sits after 1 track, 1 key, 0 controls.
    const sec = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN;
    const scen = m[sec..];

    // Synthetic stream: an unknown 'ZZZZ' frame, then the real 'SCEN' frame.
    var stream: [512]u8 = undefined;
    const unknown_payload = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    std.mem.writeInt(u32, stream[0..4], 0x5a5a5a5a, .little); // 'ZZZZ'
    std.mem.writeInt(u32, stream[4..8], @intCast(unknown_payload.len), .little);
    @memcpy(stream[8..][0..unknown_payload.len], &unknown_payload);
    const after_unknown = META_SECTION_HEADER_LEN + unknown_payload.len;
    @memcpy(stream[after_unknown..][0..scen.len], scen);
    const stream_len = after_unknown + scen.len;

    // Walk the TLV stream: dispatch only 'SCEN', always skip by length.
    var off: usize = 0;
    var scenes_seen: usize = 0;
    while (off < stream_len) {
        const id = std.mem.readInt(u32, stream[off..][0..4], .little);
        const plen = std.mem.readInt(u32, stream[off + 4 ..][0..4], .little);
        if (id == SCENES_SECTION_ID)
            scenes_seen = std.mem.readInt(u32, stream[off + META_SECTION_HEADER_LEN ..][0..4], .little);
        off += META_SECTION_HEADER_LEN + plen;
    }
    try t.expectEqual(stream_len, off); // landed exactly at end-of-stream
    try t.expectEqual(@as(usize, 1), scenes_seen); // the unknown frame didn't disturb it
}

test "encodeMeta: an easing program table rides as an 'EASE' section" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 4b :value 1 :ease out-cubic))
        \\(track :target cutoff
        \\  (key :at 0b :value 0)
        \\  (key :at 4b :value 1 :ease smoothstep))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());

    var buf: [8192]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    try t.expectEqual(metaEncodedLen(&r), m.len);

    // 2 tracks, 4 keys, 0 controls, 0 scenes → the section stream is 'EASE'.
    try t.expectEqual(@as(u32, 2), std.mem.readInt(u32, m[28..32], .little));
    try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, m[32..36], .little));
    try t.expectEqual(@as(u32, 0), std.mem.readInt(u32, m[36..40], .little));

    const sec = META_HEADER_LEN + 2 * META_TRACK_LEN + 4 * META_KEY_LEN;
    try t.expectEqual(EASE_SECTION_ID, std.mem.readInt(u32, m[sec..][0..4], .little));
    const plen = std.mem.readInt(u32, m[sec + 4 ..][0..4], .little);
    try t.expectEqual(m.len, sec + META_SECTION_HEADER_LEN + plen); // self-delimiting

    var off: usize = sec + META_SECTION_HEADER_LEN;
    // programs[0] linear (default) + out-cubic + smoothstep = 3 distinct.
    try t.expectEqual(@as(u32, 3), std.mem.readInt(u32, m[off..][0..4], .little));
    off += 4;

    // Program 0 = the default linear: one stage [0,1]→[0,1], one linear op.
    {
        const p = m[off..][0..META_EASE_PROGRAM_LEN];
        try t.expectEqual(@as(u8, 1), p[0]); // len (stage count)
        const st = p[4..][0..META_EASE_STAGE_LEN];
        try t.expectEqual(@as(f32, 1), @as(f32, @bitCast(std.mem.readInt(u32, st[0..4], .little)))); // t_end
        try t.expectEqual(@as(f32, 0), @as(f32, @bitCast(std.mem.readInt(u32, st[4..8], .little)))); // v_base
        try t.expectEqual(@as(f32, 1), @as(f32, @bitCast(std.mem.readInt(u32, st[8..12], .little)))); // v_span
        try t.expectEqual(@as(u8, 1), st[12]); // ops_len
        try t.expectEqual(@intFromEnum(Easing.Op.linear), st[16]); // op0.code
    }
    // Program 1 = out-cubic (interned first), program 2 = smoothstep.
    try t.expectEqual(
        @intFromEnum(Easing.Op.out_cubic),
        m[off + META_EASE_PROGRAM_LEN + 4 + 16],
    );
    try t.expectEqual(
        @intFromEnum(Easing.Op.smoothstep),
        m[off + 2 * META_EASE_PROGRAM_LEN + 4 + 16],
    );
    off += 3 * META_EASE_PROGRAM_LEN;

    // Per-key ease refs, parallel to the key stream: circle-radius
    // [linear, out-cubic] then cutoff [linear, smoothstep].
    try t.expectEqual(@as(u32, 4), std.mem.readInt(u32, m[off..][0..4], .little));
    off += 4;
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, m[off..][0..2], .little));
    try t.expectEqual(@as(u16, 1), std.mem.readInt(u16, m[off + 2 ..][0..2], .little));
    try t.expectEqual(@as(u16, 0), std.mem.readInt(u16, m[off + 4 ..][0..2], .little));
    try t.expectEqual(@as(u16, 2), std.mem.readInt(u16, m[off + 6 ..][0..2], .little));
}

test "encodeMeta: a linear-only score emits no 'EASE' section" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 4b :value 1))
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    var buf: [1024]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    // 1 track, 2 keys, 0 controls, no scenes, only the default linear
    // program → the blob ends at the last key (byte-stable vs pre-ease).
    try t.expectEqual(META_HEADER_LEN + META_TRACK_LEN + 2 * META_KEY_LEN, m.len);
}

test "encodeMeta: a tempo map rides as a 'TMPO' section" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(tempo :at 4b :bpm 240)
        \\(tempo :at 8b :bpm 96.5)
        \\(track :target circle-radius (key :at 0b :value 0.1))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());

    var buf: [4096]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    try t.expectEqual(metaEncodedLen(&r), m.len);

    // 1 track, 1 key, 0 controls, no scenes, linear-only → the section
    // stream is exactly the 'TMPO' frame.
    const sec = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN;
    try t.expectEqual(TEMPO_SECTION_ID, std.mem.readInt(u32, m[sec..][0..4], .little));
    const plen = std.mem.readInt(u32, m[sec + 4 ..][0..4], .little);
    try t.expectEqual(@as(u32, 4 + 3 * TEMPO_REC_LEN), plen);
    try t.expectEqual(m.len, sec + META_SECTION_HEADER_LEN + plen); // self-delimiting

    // Payload: count INCLUDING segment 0 (self-contained — no transport
    // join needed), then {tick i64, bpm f64} ascending.
    const body = sec + META_SECTION_HEADER_LEN;
    try t.expectEqual(@as(u32, 3), std.mem.readInt(u32, m[body..][0..4], .little));
    const ppb: i64 = 180180;
    const rec0 = body + 4;
    try t.expectEqual(@as(i64, 0), std.mem.readInt(i64, m[rec0..][0..8], .little));
    try t.expectEqual(@as(f64, 120), @as(f64, @bitCast(std.mem.readInt(u64, m[rec0 + 8 ..][0..8], .little))));
    const rec1 = rec0 + TEMPO_REC_LEN;
    try t.expectEqual(@as(i64, 4 * ppb), std.mem.readInt(i64, m[rec1..][0..8], .little));
    try t.expectEqual(@as(f64, 240), @as(f64, @bitCast(std.mem.readInt(u64, m[rec1 + 8 ..][0..8], .little))));
    const rec2 = rec1 + TEMPO_REC_LEN;
    try t.expectEqual(@as(i64, 8 * ppb), std.mem.readInt(i64, m[rec2..][0..8], .little));
    try t.expectEqual(@as(f64, 96.5), @as(f64, @bitCast(std.mem.readInt(u64, m[rec2 + 8 ..][0..8], .little))));
}

test "encodeMeta: a constant-tempo score emits no 'TMPO' frame" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target circle-radius (key :at 0b :value 0.1))
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    var buf: [512]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    // Segment count 1 → omitted: byte-identical to a pre-tempo blob.
    try t.expectEqual(META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN, m.len);
}

test "encodeMeta: 'TMPO' rides after 'EASE' in the fixed section order" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(tempo :at 4b :bpm 240)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0)
        \\  (key :at 4b :value 1 :ease out-cubic))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());

    var buf: [8192]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    try t.expectEqual(metaEncodedLen(&r), m.len);

    var off: usize = META_HEADER_LEN + META_TRACK_LEN + 2 * META_KEY_LEN;
    try t.expectEqual(EASE_SECTION_ID, std.mem.readInt(u32, m[off..][0..4], .little));
    off += META_SECTION_HEADER_LEN + std.mem.readInt(u32, m[off + 4 ..][0..4], .little);
    try t.expectEqual(TEMPO_SECTION_ID, std.mem.readInt(u32, m[off..][0..4], .little));
    off += META_SECTION_HEADER_LEN + std.mem.readInt(u32, m[off + 4 ..][0..4], .little);
    try t.expectEqual(m.len, off);
}

test "encodeMeta: 'EASE' rides after 'SCEN' when both are present" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(scene :name intro :at 0b :dur 4b
        \\  (track :target circle-radius
        \\    (key :at 0b :value 0)
        \\    (key :at 4b :value 1 :ease out-cubic)))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    for (r.diagnostics) |d| std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    try t.expect(r.ok());

    var buf: [4096]u8 = undefined;
    const m = try encodeMeta(&r, &buf);
    try t.expectEqual(metaEncodedLen(&r), m.len);

    // Section stream after 1 track, 2 keys, 0 controls: 'SCEN' then 'EASE'.
    var off: usize = META_HEADER_LEN + META_TRACK_LEN + 2 * META_KEY_LEN;
    try t.expectEqual(SCENES_SECTION_ID, std.mem.readInt(u32, m[off..][0..4], .little));
    off += META_SECTION_HEADER_LEN + std.mem.readInt(u32, m[off + 4 ..][0..4], .little);
    try t.expectEqual(EASE_SECTION_ID, std.mem.readInt(u32, m[off..][0..4], .little));
    off += META_SECTION_HEADER_LEN + std.mem.readInt(u32, m[off + 4 ..][0..4], .little);
    try t.expectEqual(m.len, off); // the two frames account for the whole stream
}

// ---------------------------------------------------------------------------
// Decoder tests (Phase 1 reds)
// ---------------------------------------------------------------------------

test "decodeMeta: every header, track, key and control field round-trips" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8))
        \\(track :target tint :expr [1 0 0])
        \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
        \\(control :id sway :value 0.12)
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    const table = &r.table.?;

    const blob = try t.allocator.alloc(u8, metaEncodedLen(&r));
    defer t.allocator.free(blob);
    _ = try encodeMeta(&r, blob);

    const v = decodeMeta(blob) orelse return error.TestExpectedDecode;

    try t.expectEqual(table.transport.map.bpm, v.bpm);
    try t.expectEqual(table.transport.dur, v.dur);
    try t.expectEqual(true, v.end_loop);
    try t.expectEqual(@as(u16, 4), v.beats_per_bar);
    try t.expectEqual(table.tracks.len, v.track_count);
    try t.expectEqual(table.keys.len, v.key_count);
    try t.expectEqual(table.controls.len, v.control_count);

    for (table.tracks, table.track_spans, 0..) |want, span, i| {
        const got = v.track(i);
        try t.expectEqual(want.target_id, got.target_id);
        try t.expectEqual(want.registry, got.registry);
        try t.expectEqual(want.ncomp, got.ncomp);
        try t.expectEqual(span.start, got.span.start);
        try t.expectEqual(span.end, got.span.end);
        switch (want.source) {
            .keys => |ks| {
                try t.expectEqual(TrackSourceKind.keys, got.source);
                try t.expectEqual(ks.start, got.key_start);
                try t.expectEqual(ks.len, got.key_len);
            },
            .expr => try t.expectEqual(TrackSourceKind.expr, got.source),
            .trigger => try t.expectEqual(TrackSourceKind.trigger, got.source),
            .pattern => try t.expectEqual(TrackSourceKind.pattern, got.source),
        }
    }

    for (table.keys, table.key_spans, 0..) |want, span, i| {
        const got = v.key(i);
        try t.expectEqual(want.at, got.at);
        try t.expectEqual(want.value, got.value);
        try t.expectEqual(span.start, got.span.start);
        try t.expectEqual(span.end, got.span.end);
    }

    var it = v.controls();
    for (table.controls) |want| {
        const got = it.next() orelse return error.TestExpectedControl;
        try t.expectEqualStrings(want.id, got.id);
        try t.expectEqual(want.ncomp, got.ncomp);
        try t.expectEqual(want.kind, got.kind);
        try t.expectEqual(want.value, got.value);
        try t.expectEqual(want.min, got.min);
        try t.expectEqual(want.max, got.max);
        try t.expectEqual(want.value_span.start, got.value_span.start);
        if (want.target) |tg| {
            try t.expectEqual(tg.id, got.target_id.?);
            try t.expectEqual(tg.registry, got.registry);
        } else {
            try t.expectEqual(@as(?u16, null), got.target_id);
        }
    }
    try t.expectEqual(@as(?MetaControl, null), it.next());

    // A score with no scenes / no tempo map / linear-only easing emits
    // none of the three sections — absent and empty are equivalent.
    try t.expectEqual(@as(usize, 0), v.sceneCount());
    try t.expectEqual(@as(usize, 0), v.tempoCount());
    try t.expectEqual(@as(usize, 0), v.easeProgramCount());
}

test "decodeMeta: 'SCEN', 'EASE' and 'TMPO' sections decode against the table" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
        \\(tempo :at 8b :bpm 160)
        \\(scene :name drop :at 2bar :dur 2bar
        \\  (track :target circle-radius
        \\    (key :at 0b :value 30)
        \\    (key :at 4b :value 140 :ease (steps :n 8))))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), source, &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    const table = &r.table.?;

    const blob = try t.allocator.alloc(u8, metaEncodedLen(&r));
    defer t.allocator.free(blob);
    _ = try encodeMeta(&r, blob);
    const v = decodeMeta(blob) orelse return error.TestExpectedDecode;

    try t.expectEqual(table.scenes.len, v.sceneCount());
    for (table.scenes, 0..) |want, i| {
        const got = v.scene(i);
        try t.expectEqual(want.start_tick, got.start_tick);
        try t.expectEqual(want.dur_ticks, got.dur_ticks);
        try t.expectEqualStrings("drop", source[got.name_span.start..got.name_span.end]);
    }

    try t.expectEqual(table.transport.segments.len, v.tempoCount());
    for (table.transport.segments, 0..) |want, i| {
        const got = v.tempoSeg(i);
        try t.expectEqual(want.start_tick, got.tick);
        try t.expectEqual(want.bpm, got.bpm);
    }

    try t.expectEqual(table.programs.len, v.easeProgramCount());
    for (table.programs, 0..) |want, i| {
        const got = v.easeProgram(i);
        try t.expectEqual(want.len, got.len);
        for (0..Easing.MAX_STAGES) |s| {
            try t.expectEqual(want.stages[s].t_end, got.stages[s].t_end);
            try t.expectEqual(want.stages[s].ops_len, got.stages[s].ops_len);
            for (0..Easing.MAX_OPS) |o| {
                try t.expectEqual(want.stages[s].ops[o].code, got.stages[s].ops[o].code);
                try t.expectEqual(want.stages[s].ops[o].params, got.stages[s].ops[o].params);
            }
        }
    }
    try t.expectEqual(table.keys.len, v.easeRefCount());
    for (table.keys, 0..) |want, i| try t.expectEqual(want.ease_ref, v.easeRef(i));
}

test "decodeMeta: an unknown section id is skipped by length" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id sway :value 0.12)
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());

    const base = metaEncodedLen(&r);
    const blob = try t.allocator.alloc(u8, base + META_SECTION_HEADER_LEN + 6);
    defer t.allocator.free(blob);
    _ = try encodeMeta(&r, blob[0..base]);
    std.mem.writeInt(u32, blob[base..][0..4], 0x5a5a5a5a, .little);
    std.mem.writeInt(u32, blob[base + 4 ..][0..4], 6, .little);
    @memset(blob[base + META_SECTION_HEADER_LEN ..], 0xab);

    const v = decodeMeta(blob) orelse return error.TestExpectedDecode;
    try t.expectEqual(@as(u32, 1), v.control_count);
    try t.expectEqual(@as(usize, 0), v.sceneCount());
}

test "decodeMeta rejects every malformed shape" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id sway :value 0.12)
    , &sample_targets);
    defer r.deinit();
    try t.expect(r.ok());
    const good = try t.allocator.alloc(u8, metaEncodedLen(&r));
    defer t.allocator.free(good);
    _ = try encodeMeta(&r, good);

    try t.expectEqual(@as(?MetaView, null), decodeMeta(good[0 .. META_HEADER_LEN - 1])); // truncated header
    try t.expectEqual(@as(?MetaView, null), decodeMeta(good[0 .. good.len - 1])); // truncated id bytes

    const bad = try t.allocator.dupe(u8, good);
    defer t.allocator.free(bad);
    std.mem.writeInt(u32, bad[0..4], 0xdeadbeef, .little);
    try t.expectEqual(@as(?MetaView, null), decodeMeta(bad)); // bad magic

    @memcpy(bad, good);
    std.mem.writeInt(u32, bad[4..8], META_VERSION + 1, .little);
    try t.expectEqual(@as(?MetaView, null), decodeMeta(bad)); // future version

    @memcpy(bad, good);
    bad[META_HEADER_LEN + 4] = 9; // a control kind outside ControlType
    try t.expectEqual(@as(?MetaView, null), decodeMeta(bad));
}

test "decodeDiags: source, severity, code, span and message round-trip" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(control :id beat :value 1)
        \\(track :target nonexistent :expr 1)
    , &sample_targets);
    defer r.deinit();
    try t.expect(!r.ok());

    const blob = try t.allocator.alloc(u8, diagsEncodedLen(&r));
    defer t.allocator.free(blob);
    const written = encodeDiags(&r, blob);
    try t.expectEqual(blob.len, written.len);

    const v = decodeDiags(written) orelse return error.TestExpectedDecode;
    try t.expectEqual(r.validated.result.diagnostics.len + r.diagnostics.len, v.count);

    var it = v.records();
    for (r.validated.result.diagnostics) |want| {
        const got = it.next() orelse return error.TestExpectedRecord;
        try t.expectEqual(DiagSource.sjon, got.source);
        try t.expectEqual(@as(u16, @intCast(@intFromEnum(want.code))), got.code);
        try t.expectEqual(want.span.start, got.span.start);
        try t.expectEqualStrings(want.message, got.message);
    }
    for (r.diagnostics) |want| {
        const got = it.next() orelse return error.TestExpectedRecord;
        try t.expectEqual(DiagSource.pacer, got.source);
        try t.expectEqual(DiagSeverity.err, got.severity);
        try t.expectEqual(@intFromEnum(want.code), got.code);
        try t.expectEqual(want.span.start, got.span.start);
        try t.expectEqual(want.span.end, got.span.end);
        try t.expectEqualStrings(want.message, got.message);
    }
    try t.expectEqual(@as(?DiagRecord, null), it.next());
}

test "decodeDiags rejects every malformed shape" {
    var r = try Compile.compile(t.allocator, test_support.schema(),
        \\(transport :bpm 120)
        \\(track :target nonexistent :expr 1)
    , &sample_targets);
    defer r.deinit();
    const good_buf = try t.allocator.alloc(u8, diagsEncodedLen(&r));
    defer t.allocator.free(good_buf);
    const good = encodeDiags(&r, good_buf);

    try t.expectEqual(@as(?DiagView, null), decodeDiags(good[0..DIAGS_HEADER_LEN - 1]));
    try t.expectEqual(@as(?DiagView, null), decodeDiags(good[0 .. good.len - 1])); // truncated message

    const bad = try t.allocator.dupe(u8, good);
    defer t.allocator.free(bad);
    std.mem.writeInt(u32, bad[0..4], 0xdeadbeef, .little);
    try t.expectEqual(@as(?DiagView, null), decodeDiags(bad));

    @memcpy(bad, good);
    std.mem.writeInt(u32, bad[4..8], DIAGS_VERSION + 1, .little);
    try t.expectEqual(@as(?DiagView, null), decodeDiags(bad));

    @memcpy(bad, good);
    bad[DIAGS_HEADER_LEN] = 2; // a source byte outside DiagSource
    try t.expectEqual(@as(?DiagView, null), decodeDiags(bad));
}
