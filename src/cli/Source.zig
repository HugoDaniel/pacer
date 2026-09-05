//! Score input and source coordinates — the CLI's only io-touching,
//! non-dispatch code, separated so every renderer stays a pure function
//! of `(source, CompileResult, *Writer)`.
//!
//! Every span in pacer is a RAW BYTE OFFSET into the score
//! (`sjon.Ast.Span`): the schema is preloaded beside the document rather
//! than prepended to it, so spans are score coordinates by construction
//! and the library translates them nowhere. The CLI is the first consumer
//! that has to show a person WHERE, so the conversion lives here and only
//! here.

const std = @import("std");
const sjon = @import("sjon");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Input cap. Well under `sjon.Binary.MAX_FILE_SIZE`, which
/// `Compile.validate` ASSERTS its source fits — a host contract, so the
/// CLI must refuse an over-cap file with a message before that can fire.
pub const MAX_SOURCE_BYTES: usize = 1 << 20;

comptime {
    std.debug.assert(MAX_SOURCE_BYTES <= sjon.Binary.MAX_FILE_SIZE);
}

pub const LoadError = error{ ReadFailed, TooLarge, OutOfMemory };

/// Read a score. `-` is stdin, sniffed nowhere — pacer has exactly one
/// input format, so the path is a name, not a type tag. The result is
/// NUL-terminated because `Driver.init` takes `[:0]const u8`.
pub fn load(a: Allocator, io: Io, path: []const u8) LoadError![:0]u8 {
    if (isStdin(path)) {
        var file = Io.File.stdin();
        var buf: [4096]u8 = undefined;
        var reader = file.reader(io, &buf);
        return reader.interface.allocRemainingAlignedSentinel(
            a,
            .limited(MAX_SOURCE_BYTES),
            .of(u8),
            0,
        ) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => error.TooLarge,
            else => error.ReadFailed,
        };
    }
    return sjon.CappedRead.readFileZ(io, path, a, MAX_SOURCE_BYTES) catch |e| switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        else => error.ReadFailed,
    };
}

pub fn isStdin(path: []const u8) bool {
    return path.len == 1 and path[0] == '-';
}

/// What a diagnostic line calls this input.
pub fn label(path: []const u8) []const u8 {
    return if (isStdin(path)) "<stdin>" else path;
}

pub const Pos = struct { line: u32, col: u32 };

/// Byte offset → 1-based (line, column) over one loaded score.
///
/// `line` counts `'\n'` only, so a lone `'\r'` is an ordinary column and a
/// CRLF file's `'\r'` sits at the end of the previous line — what every
/// editor shows, and what SJON's own renderer does.
///
/// `col` counts UNICODE CODEPOINTS, not bytes and not UTF-16 units,
/// because that is what a person means by "column 7". The byte offsets
/// ride untouched beside it in every span object, so a consumer needing
/// another coordinate space converts from those on the side that holds
/// the text — the CLI does not invent a third space it has no consumer
/// for. An offset landing INSIDE a sequence rounds DOWN to that
/// codepoint's first byte, so a span clipped mid-character still points
/// at the character.
///
/// Built once per source (one pass for the line starts, binary search per
/// lookup): an `ir` dump over a large score asks thousands of times.
pub const LineIndex = struct {
    source: []const u8,
    /// Byte offset of each line's first byte. `[0] == 0`, ascending.
    line_starts: []const u32,

    pub fn build(a: Allocator, source: []const u8) Allocator.Error!LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(a);
        try starts.append(a, 0);
        for (source, 0..) |b, i| {
            if (b == '\n') try starts.append(a, @intCast(i + 1));
        }
        return .{ .source = source, .line_starts = try starts.toOwnedSlice(a) };
    }

    pub fn deinit(self: *LineIndex, a: Allocator) void {
        a.free(self.line_starts);
        self.* = undefined;
    }

    pub fn at(self: *const LineIndex, offset: u32) Pos {
        // Past-EOF clamps rather than panicking: a span is host data here,
        // and an EOF span (start == source.len) is ordinary.
        var off: usize = @min(offset, self.source.len);
        // Round down out of the middle of a sequence.
        while (off > 0 and off < self.source.len and isContinuation(self.source[off])) off -= 1;

        const line = upperBound(self.line_starts, off);
        const start = self.line_starts[line];

        var col: u32 = 1;
        var i: usize = start;
        while (i < off) {
            const len = std.unicode.utf8ByteSequenceLength(self.source[i]) catch 1;
            // A truncated tail still advances, so this cannot spin.
            i += @min(@as(usize, len), off - i);
            col += 1;
        }
        return .{ .line = @intCast(line + 1), .col = col };
    }
};

fn isContinuation(b: u8) bool {
    return b & 0xc0 == 0x80;
}

/// Index of the last entry `<= off`. `starts[0] == 0 <= off` always, so
/// this is total.
fn upperBound(starts: []const u32, off: usize) usize {
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (lo + 1 < hi) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= off) lo = mid else hi = mid;
    }
    return lo;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn idx(source: []const u8) !LineIndex {
    return LineIndex.build(t.allocator, source);
}

test "LineIndex: ASCII offsets map to 1-based line and column" {
    var li = try idx("abc\ndef\n");
    defer li.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 1 }, li.at(0));
    try t.expectEqual(Pos{ .line = 1, .col = 3 }, li.at(2));
    try t.expectEqual(Pos{ .line = 2, .col = 1 }, li.at(4));
    try t.expectEqual(Pos{ .line = 2, .col = 3 }, li.at(6));
}

test "LineIndex: columns count codepoints, not bytes" {
    // "é" is 2 bytes, "€" 3, "🎛" 4 — the 'x' after them is column 5.
    const src = "é€🎛x";
    var li = try idx(src);
    defer li.deinit(t.allocator);
    try t.expectEqual(@as(u32, 4), li.at(@intCast(src.len - 1)).col);
}

test "LineIndex: an offset inside a sequence rounds down to its character" {
    const src = "a€b"; // '€' occupies bytes 1..4
    var li = try idx(src);
    defer li.deinit(t.allocator);
    try t.expectEqual(@as(u32, 2), li.at(1).col); // the lead byte
    try t.expectEqual(@as(u32, 2), li.at(2).col); // mid-sequence, same column
    try t.expectEqual(@as(u32, 2), li.at(3).col);
    try t.expectEqual(@as(u32, 3), li.at(4).col); // 'b'
}

test "LineIndex: a CR is an ordinary column; only LF advances the line" {
    var li = try idx("ab\r\ncd");
    defer li.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 3 }, li.at(2)); // the '\r'
    try t.expectEqual(Pos{ .line = 2, .col = 1 }, li.at(4)); // 'c'
}

test "LineIndex: EOF and past-EOF clamp instead of panicking" {
    const src = "abc";
    var li = try idx(src);
    defer li.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 4 }, li.at(3));
    try t.expectEqual(Pos{ .line = 1, .col = 4 }, li.at(999));
}

test "LineIndex: empty source, and a last line with no trailing newline" {
    var empty = try idx("");
    defer empty.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 1, .col = 1 }, empty.at(0));

    var tail = try idx("a\nbc");
    defer tail.deinit(t.allocator);
    try t.expectEqual(Pos{ .line = 2, .col = 3 }, tail.at(4));
}

test "LineIndex: an invalid lead byte advances one column, never hangs" {
    const src = "a\x80\x80b";
    var li = try idx(src);
    defer li.deinit(t.allocator);
    try t.expectEqual(@as(u32, 4), li.at(3).col);
}

test "label: `-` reads as <stdin>, a path reads as itself" {
    try t.expectEqualStrings("<stdin>", label("-"));
    try t.expectEqualStrings("score.sjon", label("score.sjon"));
}
