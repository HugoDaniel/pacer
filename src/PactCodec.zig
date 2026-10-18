//! `'PACT'` — the target-registry codec leaf.
//!
//! Inbound (host → driver), the target-registry join list:
//!
//!     [magic u32]['PACT'][count u32]
//!     count × { ncomp u8, registry u8, name_len u16, name bytes }
//!
//! Decoded `Target.name`s alias the blob — they must only live for the
//! duration of one `Compile.compile` call (the table stores ids, never
//! names).
//!
//! Std-only by construction: this is the leaf `Abi` and `Compile` delegate
//! to, so a binary runtime can decode the host blob without dragging the
//! compiler in. Imports must stay column-0 (`@import(...)`) and std-only —
//! never `Compile`, `Abi`, or `Schema`.

const std = @import("std");

/// `"PACT"` read as LE u32.
pub const TARGETS_MAGIC: u32 = 0x54434150;
pub const TARGETS_HEADER_LEN: usize = 8;

/// One resolvable target, as joined from a host registry at load time.
/// `registry` is the ordered-registry index (0 = visual, 1 = audio, …)
/// and rides into `Writes.Entry.flags` for JS-side routing.
pub const Target = struct {
    /// Borrowed from the caller for the duration of `compile` ONLY (the
    /// wasm path aliases the 'PACT' blob): the result copies every name
    /// it keeps into its arena, and the table stores ids, not names.
    name: []const u8,
    ncomp: u8,
    registry: u8 = 0,
};

/// Most targets any host may join at load — THE definition. `Compile` and
/// `Abi` alias it so the codec leaf never imports either module. Generous:
/// pngine uniform tables run tens of fields, not hundreds.
pub const MAX_TARGETS = 1024;

/// Explicit error set: the destination buffer was too small.
pub const Error = error{BufferTooSmall};

/// Exact encoded size of a target list.
pub fn targetsEncodedLen(targets: []const Target) usize {
    var len: usize = TARGETS_HEADER_LEN;
    for (targets) |tg| len += 4 + tg.name.len;
    return len;
}

/// Encode a target list into `dest`. Used by tests and native hosts;
/// the JS glue produces the same bytes directly.
pub fn encodeTargets(targets: []const Target, dest: []u8) Error![]u8 {
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
pub fn decodeTargets(blob: []const u8, out: []Target) ?[]const Target {
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
