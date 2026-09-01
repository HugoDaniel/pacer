//! JSON scalar emitters — the two ways this CLI could emit INVALID JSON,
//! refused in one place instead of at every call site.
//!
//! 1. **A non-finite float.** `{d}` on an f64 writes the bare words `nan`
//!    / `inf` / `-inf` (`std/fmt/float.zig`), which no JSON parser
//!    accepts. Every float goes through `number` / `lanes`, which emit
//!    `null` instead. Nothing pacer produces SHOULD be non-finite — an
//!    out-of-f32-range literal is a compile diagnostic, NaN is rejected at
//!    the expr boundary, `setControl` refuses non-finite lanes — so a
//!    `null` in the output means an invariant broke, which is worth seeing
//!    rather than hiding.
//! 2. **Invalid UTF-8.** A score is not required to be valid UTF-8; a JSON
//!    string is. `string` substitutes U+FFFD. (The corpus golden instead
//!    REFUSES a control byte outright, because its format has no escape —
//!    JSON has one, so the CLI can be strictly more permissive.)
//!
//! Structure — objects, arrays, commas — is written literally by the
//! renderers. This module owns scalars only.

const std = @import("std");
const t = std.testing;
const Writer = std.Io.Writer;

/// One JSON string, quotes included.
pub fn string(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b < 0x80) {
            switch (b) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                else => if (b < 0x20)
                    try w.print("\\u{x:0>4}", .{b})
                else
                    try w.writeByte(b),
            }
            i += 1;
            continue;
        }
        // A multi-byte sequence: emit it verbatim when it decodes, and
        // one U+FFFD when it does not. A sequence TRUNCATED by the end of
        // input is one replacement for the whole tail, not one per
        // leftover byte.
        const len = std.unicode.utf8ByteSequenceLength(b) catch {
            try w.writeAll(replacement);
            i += 1;
            continue;
        };
        if (i + len > s.len) {
            try w.writeAll(replacement);
            break;
        }
        _ = std.unicode.utf8Decode(s[i..][0..len]) catch {
            try w.writeAll(replacement);
            i += 1;
            continue;
        };
        try w.writeAll(s[i..][0..len]);
        i += len;
    }
    try w.writeByte('"');
}

const replacement = "\u{FFFD}";

/// One JSON number from an f64 — `null` when non-finite. Zig's `{d}`
/// is shortest-round-trip, so the decimal is lossless.
pub fn number(w: *Writer, x: f64) Writer.Error!void {
    if (!std.math.isFinite(x)) return w.writeAll("null");
    try w.print("{d}", .{x});
}

/// One JSON number from an f32. Deliberately NOT widened to f64 first:
/// `{d}` renders the shortest decimal that round-trips through the type
/// it is given, and an f32 0.1 widened to f64 prints as
/// `0.10000000149011612`. The value is f32 on the wire, so it is f32 here.
pub fn number32(w: *Writer, x: f32) Writer.Error!void {
    if (!std.math.isFinite(x)) return w.writeAll("null");
    try w.print("{d}", .{x});
}

/// A write/key/control value as a JSON array, TRUNCATED to `ncomp`.
///
/// The wire carries four lanes with everything past `ncomp` zeroed
/// (`Writes.Entry`), and `ncomp` rides beside this array in every object
/// that contains one — so nothing is hidden by the truncation, and
/// `--set pan=0.25,0.5` and `"value":[0.25,0.5]` become the same spelling
/// in both directions.
pub fn lanes(w: *Writer, v: [4]f32, ncomp: u8) Writer.Error!void {
    std.debug.assert(ncomp >= 1 and ncomp <= 4);
    try w.writeByte('[');
    for (v[0..ncomp], 0..) |lane, i| {
        if (i != 0) try w.writeByte(',');
        try number32(w, lane);
    }
    try w.writeByte(']');
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn render(comptime f: anytype, args: anytype) ![]const u8 {
    var aw: Writer.Allocating = .init(t.allocator);
    errdefer aw.deinit();
    try @call(.auto, f, .{&aw.writer} ++ args);
    return aw.toOwnedSlice();
}

test "string: quotes and backslashes escape" {
    const got = try render(string, .{"a\"b\\c"});
    defer t.allocator.free(got);
    try t.expectEqualStrings("\"a\\\"b\\\\c\"", got);
}

test "string: control bytes ride as \\u00XX, and the named escapes win" {
    const got = try render(string, .{"a\nb\tc\x01d"});
    defer t.allocator.free(got);
    try t.expectEqualStrings("\"a\\nb\\tc\\u0001d\"", got);
}

test "string: valid multi-byte UTF-8 passes through verbatim" {
    const got = try render(string, .{"héllo € 🎛"});
    defer t.allocator.free(got);
    try t.expectEqualStrings("\"héllo € 🎛\"", got);
}

test "string: invalid UTF-8 becomes U+FFFD rather than invalid JSON" {
    // A lone continuation byte and a truncated 3-byte lead. A score is
    // not required to be valid UTF-8; a JSON string is.
    const got = try render(string, .{"a\x80b\xe2\x82"});
    defer t.allocator.free(got);
    try t.expectEqualStrings("\"a\u{FFFD}b\u{FFFD}\"", got);
}

test "number: non-finite becomes null, never the bare words JSON rejects" {
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64) }) |x| {
        const got = try render(number, .{x});
        defer t.allocator.free(got);
        try t.expectEqualStrings("null", got);
    }
}

test "number: a finite value round-trips through a JSON parser" {
    const got = try render(number, .{@as(f64, 0.1)});
    defer t.allocator.free(got);
    try t.expectEqual(@as(f64, 0.1), try std.fmt.parseFloat(f64, got));
}

test "lanes: truncated to ncomp, so --set and the output share a spelling" {
    const v: [4]f32 = .{ 0.25, 0.5, 0, 0 };
    const one = try render(lanes, .{ v, @as(u8, 1) });
    defer t.allocator.free(one);
    try t.expectEqualStrings("[0.25]", one);
    const two = try render(lanes, .{ v, @as(u8, 2) });
    defer t.allocator.free(two);
    try t.expectEqualStrings("[0.25,0.5]", two);
}
