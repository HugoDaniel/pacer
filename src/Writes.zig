//! Packed write-buffer format — the driver's only output.
//!
//! Wire shape (little-endian; wasm32 and every host we target are LE):
//!
//!     [magic u32]['PACW'][version u32][count u32]   12-byte header
//!     count × 20-byte Entry
//!
//! Entry layout is pinned by `comptime` asserts — drift is a build
//! break, not a runtime surprise. `flags` carries the registry index of
//! the resolved target (0 = visual, 1 = audio, …) so JS routing is one
//! switch; unused value lanes are ZERO so the same eval produces the
//! same bytes (the determinism claim is byte-equality of this buffer).
//!
//! This format is wire-stable from day one: append/version, never
//! reorder. Bump `VERSION` on any layout change.

const std = @import("std");

/// `"PACW"` read as LE u32.
pub const MAGIC: u32 = 0x57434150;
pub const VERSION: u32 = 1;
pub const HEADER_LEN: usize = 12;

/// One target write. 20 bytes, C layout.
pub const Entry = extern struct {
    /// Index into the load-time target join (string-free hot path).
    target_id: u16,
    /// Registry index of the resolved target (0 = visual, 1 = audio, …).
    flags: u8,
    /// Live component count, 1–4. Lanes ≥ ncomp are zero.
    ncomp: u8,
    value: [4]f32,
};

comptime {
    std.debug.assert(@sizeOf(Entry) == 20);
    std.debug.assert(@offsetOf(Entry, "target_id") == 0);
    std.debug.assert(@offsetOf(Entry, "flags") == 2);
    std.debug.assert(@offsetOf(Entry, "ncomp") == 3);
    std.debug.assert(@offsetOf(Entry, "value") == 4);
}

/// Explicit error set: the destination buffer was too small.
pub const Error = error{BufferTooSmall};

/// Exact encoded size for `count` entries.
pub fn encodedLen(count: usize) usize {
    return HEADER_LEN + count * @sizeOf(Entry);
}

/// Encode header + entries into `dest`. Returns the encoded slice.
/// Single pass, no allocation; asserts entry invariants (they were
/// produced by the evaluator, not user input).
pub fn encode(entries: []const Entry, dest: []u8) Error![]u8 {
    if (dest.len < encodedLen(entries.len)) return error.BufferTooSmall;
    for (entries) |e| {
        std.debug.assert(e.ncomp >= 1);
        std.debug.assert(e.ncomp <= 4);
    }
    std.mem.writeInt(u32, dest[0..4], MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], VERSION, .little);
    std.mem.writeInt(u32, dest[8..12], @intCast(entries.len), .little);
    const payload = std.mem.sliceAsBytes(entries);
    @memcpy(dest[HEADER_LEN..][0..payload.len], payload);
    const out = dest[0..encodedLen(entries.len)];
    std.debug.assert(out.len == HEADER_LEN + payload.len);
    return out;
}

/// Decode a buffer produced by `encode` (test/host-side helper; the JS
/// host reads the same layout with one DataView pass). Returns the
/// entry slice aliasing `src`.
pub fn decode(src: []const u8) ?[]const Entry {
    if (src.len < HEADER_LEN) return null;
    if (std.mem.readInt(u32, src[0..4], .little) != MAGIC) return null;
    if (std.mem.readInt(u32, src[4..8], .little) != VERSION) return null;
    const count = std.mem.readInt(u32, src[8..12], .little);
    if (src.len < encodedLen(count)) return null;
    const payload = src[HEADER_LEN..][0 .. count * @sizeOf(Entry)];
    return @alignCast(std.mem.bytesAsSlice(Entry, payload));
}

const t_ = std.testing;

test "round-trip: encode then decode preserves entries byte-exactly" {
    const entries = [_]Entry{
        .{ .target_id = 0, .flags = 0, .ncomp = 1, .value = .{ 0.5, 0, 0, 0 } },
        .{ .target_id = 7, .flags = 1, .ncomp = 3, .value = .{ 0.1, 0.2, 0.3, 0 } },
    };
    var buf: [encodedLen(2)]u8 align(4) = undefined;
    const out = try encode(&entries, &buf);
    try t_.expectEqual(encodedLen(2), out.len);
    const back = decode(out).?;
    try t_.expectEqualSlices(Entry, &entries, back);
}

test "decode rejects bad magic, version, and truncation" {
    var buf: [encodedLen(1)]u8 align(4) = undefined;
    const entries = [_]Entry{.{ .target_id = 1, .flags = 0, .ncomp = 1, .value = .{ 1, 0, 0, 0 } }};
    _ = try encode(&entries, &buf);

    var bad_magic = buf;
    bad_magic[0] ^= 0xff;
    try t_.expectEqual(@as(?[]const Entry, null), decode(&bad_magic));

    var bad_version = buf;
    bad_version[4] = 99;
    try t_.expectEqual(@as(?[]const Entry, null), decode(&bad_version));

    try t_.expectEqual(@as(?[]const Entry, null), decode(buf[0 .. buf.len - 1]));
}

test "encode fails on a short destination" {
    const entries = [_]Entry{.{ .target_id = 0, .flags = 0, .ncomp = 1, .value = .{ 0, 0, 0, 0 } }};
    var small: [HEADER_LEN]u8 = undefined;
    try t_.expectError(error.BufferTooSmall, encode(&entries, &small));
}
