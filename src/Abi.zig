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
//! Both formats are wire-stable from day one: append/version, never
//! reorder. The third boundary format, `'PACW'`, lives in `Writes`.

const std = @import("std");
const sjon = @import("sjon");
const Compile = @import("Compile.zig");

const Ast = sjon.Ast;

/// `"PACT"` read as LE u32.
pub const TARGETS_MAGIC: u32 = 0x54434150;
/// `"PACD"` read as LE u32.
pub const DIAGS_MAGIC: u32 = 0x44434150;
pub const DIAGS_VERSION: u32 = 1;

pub const TARGETS_HEADER_LEN: usize = 8;
pub const DIAGS_HEADER_LEN: usize = 12;
/// Fixed bytes per diagnostic record, before its message.
pub const DIAG_RECORD_LEN: usize = 16;

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
