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
//! Outbound (driver → host), `'PACD'` — load diagnostics, spans already
//! mapped to USER source coordinates (spans inside the prepended
//! manifest have no user coordinate and clamp to 0..0):
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
//!                        source u8 (0 keys / 1 expr / 2 trigger), pad u8×3,
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
//! pattern is `[count u32][fixed extern-struct record × count]`. Defined:
//!
//!     'SCEN' scenes — [count u32] then count × 24 {
//!         start_tick i64, dur_ticks i64,
//!         name_span_start u32, name_span_end u32 }
//!       (the scene's name rides as a span like a track's — the editor
//!       slices it from source; scenes aren't a setControl lookup key.)
//!
//! Both formats are wire-stable from day one: append/version, never
//! reorder. The third boundary format, `'PACW'`, lives in `Writes`.

const std = @import("std");
const sjon = @import("sjon");
const Compile = @import("Compile.zig");
const TrackTable = @import("TrackTable.zig");

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
        if (!appendRecord(dest, &pos, 0, severity, @intCast(@intFromEnum(d.code)), userSpan(v, d.span), d.message)) break;
        count += 1;
    }
    for (result.diagnostics) |d| {
        // Pacer load diagnostics are always errors (they void the table).
        if (!appendRecord(dest, &pos, 1, 0, @intFromEnum(d.code), userSpan(v, d.span), d.message)) break;
        count += 1;
    }

    std.mem.writeInt(u32, dest[0..4], DIAGS_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], DIAGS_VERSION, .little);
    std.mem.writeInt(u32, dest[8..12], count, .little);
    return dest[0..pos];
}

/// Map a combined-text span to user coordinates; manifest-region spans
/// clamp to 0..0 (no user coordinate exists for them).
fn userSpan(v: *const Compile.Validated, span: Ast.Span) Ast.Span {
    if (span.start < v.prefix_len) return .{ .start = 0, .end = 0 };
    std.debug.assert(span.end >= span.start);
    return .{
        .start = @intCast(v.userOffset(span.start)),
        .end = @intCast(v.userOffset(span.end)),
    };
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
    source: u8, // 0 keys / 1 expr / 2 trigger
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

comptime {
    std.debug.assert(@sizeOf(MetaTrackRec) == META_TRACK_LEN);
    std.debug.assert(@sizeOf(MetaKeyRec) == META_KEY_LEN);
    std.debug.assert(@sizeOf(MetaControlRec) == META_CONTROL_LEN);
    std.debug.assert(@sizeOf(MetaSceneRec) == SCENE_REC_LEN);
    // spot-check a couple of offsets so a field reorder is a build break
    std.debug.assert(@offsetOf(MetaTrackRec, "key_start") == 8);
    std.debug.assert(@offsetOf(MetaControlRec, "value") == 8);
    std.debug.assert(@offsetOf(MetaControlRec, "value_span_start") == 56);
    std.debug.assert(@offsetOf(MetaSceneRec, "name_span_start") == 16);
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
    return len;
}

/// Encode the `'PACM'` blob for a successfully compiled score (asserts
/// `result.ok()`). Spans are mapped to USER coordinates — manifest-
/// region spans cannot occur here (every record comes from the user's
/// data forms). Unlike diagnostics, metadata must never silently
/// truncate (the editor would desync), so a short `dest` is an error.
pub fn encodeMeta(result: *const Compile.CompileResult, dest: []u8) Error![]u8 {
    std.debug.assert(result.ok());
    const table = &result.table.?;
    const total = metaEncodedLen(result);
    if (dest.len < total) return error.BufferTooSmall;
    const v = &result.validated;
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
        const us = userSpan(v, span);
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
            .span_start = us.start,
            .span_end = us.end,
        };
        @memcpy(dest[pos..][0..META_TRACK_LEN], std.mem.asBytes(&rec));
        pos += META_TRACK_LEN;
    }
    for (table.keys, table.key_spans) |key, span| {
        const us = userSpan(v, span);
        const rec: MetaKeyRec = .{
            .at = key.at,
            .value = key.value,
            .span_start = us.start,
            .span_end = us.end,
        };
        @memcpy(dest[pos..][0..META_KEY_LEN], std.mem.asBytes(&rec));
        pos += META_KEY_LEN;
    }
    for (table.controls) |ctl| {
        var cflags: u8 = 0;
        if (ctl.min != null) cflags |= 1;
        if (ctl.max != null) cflags |= 2;
        const us = userSpan(v, ctl.value_span);
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
            .value_span_start = us.start,
            .value_span_end = us.end,
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
            const us = userSpan(v, scene.name_span);
            const rec: MetaSceneRec = .{
                .start_tick = scene.start_tick,
                .dur_ticks = scene.dur_ticks,
                .name_span_start = us.start,
                .name_span_end = us.end,
            };
            @memcpy(dest[pos..][0..SCENE_REC_LEN], std.mem.asBytes(&rec));
            pos += SCENE_REC_LEN;
        }
    }

    std.debug.assert(pos == total);
    return dest[0..pos];
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

test "encodeDiags: pacer diagnostic with a user-coordinate span" {
    const source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target nonexistent (key :at 0b :value 1))
    ;
    var r = try Compile.compile(t.allocator, source, &sample_targets);
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
    var r = try Compile.compile(t.allocator, source, &sample_targets);
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
    // The span lands on the bare `4` in user coordinates.
    const start = std.mem.readInt(u32, rec[4..8], .little);
    try t.expectEqualStrings("4", source[start .. start + 1]);
}

test "encodeDiags: clean compile yields an empty record set" {
    var r = try Compile.compile(t.allocator,
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

test "encodeMeta: transport, tracks, keys, controls — spans in user coordinates" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8))
        \\(track :target tint :expr [1 0 0])
        \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    ;
    var r = try Compile.compile(t.allocator, source, &sample_targets);
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
    var r = try Compile.compile(t.allocator,
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
    var r = try Compile.compile(t.allocator,
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
    var r = try Compile.compile(t.allocator, source, &sample_targets);
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
    var r = try Compile.compile(t.allocator, source, &sample_targets);
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
    var r = try Compile.compile(t.allocator,
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
    var r = try Compile.compile(t.allocator,
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
