//! Never-panic fuzz harness for `Pacb.decode` — the whole-`'PACB'`
//! container decoder (plan 01, Phase 4 T4.2).
//!
//! The harness feeds the decoder ARbitrary bytes two ways and asserts
//! ONLY invariants that must hold for every input — never "it decoded",
//! never a specific refusal code, since random bytes trip every class:
//!
//!   * random bytes: a raw Smith-drawn buffer, sized to the committed
//!     fixtures + slack (this file's `MAX_INPUT`), not `fuzz.zig`'s
//!     text-snippet-sized 1024;
//!   * structured mutations of the three committed REAL-CLI fixtures
//!     (`tools/testdata/pacb/{keys-only,expr-keys,full-small}.pacb`):
//!     byte flips, truncations, cross-fixture section splices, and
//!     count-field inflation with values including just past
//!     `MAX_TICK_ENTRIES` (131073) and `u32` max. Directory exactness
//!     refuses a count that no longer matches its section bytes
//!     (`count_mismatch`); the past-cap `cap_exceeded` branches proper
//!     are unit-pinned in `Pacb.zig` (T2.4/T2.5) — the fuzzer's claim
//!     is never-panic + a WELL-FORMED refusal, whichever code fires.
//!
//! Invariants (both modes):
//!   * `decode` returns `Refused` with the out-param set to a refusal
//!     whose `offset` lies inside the buffer it describes (every
//!     refusal site writes through `Pacb`'s `fail`, never a bare
//!     error), or `OutOfMemory`, or a `DecodedScore`;
//!   * a returned score is cap-bounded (`tracks`/`keys`/`programs`/
//!     `controls`/`scenes`), satisfies the OWNERSHIP contract — every
//!     byte slice it exposes (`pacm`, `regs`, each expr/pattern
//!     payload) was copied into its arena and never aliases the input
//!     buffer — and deinits clean;
//!   * no panic anywhere, and no leak on any path (the testing
//!     allocator leak-checks both the refused and the success legs).
//!
//! A tree-trailing-comments payload refusing `payload_malformed` (the
//! KNOWN SJON `RootIter` gap, owner decision pending) is one legal
//! refusal outcome like any other — this harness asserts nothing about
//! WHICH code fires, so the known gap does not weaken it.

const std = @import("std");
const sjon = @import("sjon");
const Pacb = @import("Pacb.zig");

const Smith = std.testing.Smith;
const testing = std.testing;

/// The harness's own input budget: the largest committed fixture is
/// 6069 B and the splice mutator concatenates two of them, so 16 KiB
/// is fixture-scale plus mutation slack (the plan's sizing rule —
/// `fuzz.zig`'s `MAX_INPUT = 1024` is text-snippet-sized and does not
/// apply to whole containers). The load-time check below proves the
/// budget covers any two fixtures concatenated.
const MAX_INPUT: usize = 16 * 1024;

/// Deterministic spec reader over a Smith-drawn byte slice — the same
/// shape as `fuzz.zig`'s `SpecCursor` (reads past the end yield zeros,
/// so every input length maps onto the generator's domain). Private
/// twin: `fuzz.zig`'s is file-local by design and this file owns its
/// own stream.
const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn byte(self: *Cursor) u8 {
        if (self.pos >= self.bytes.len) return 0;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    /// A full-range u32 — raw material for positions and count fields.
    fn u32bits(self: *Cursor) u32 {
        var bits: u32 = 0;
        for (0..4) |_| bits = (bits << 8) | self.byte();
        return bits;
    }
};

/// The three committed REAL-CLI fixtures, loaded once per run.
pub const Fixtures = struct {
    keys_only: []const u8,
    expr_keys: []const u8,
    full_small: []const u8,
};

fn loadFixture(a: std.mem.Allocator, root: []const u8, name: []const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(a, "{s}/tools/testdata/pacb/{s}.pacb", .{ root, name });
    return sjon.CappedRead.readFile(testing.io, path, a, 1 << 20);
}

/// Assert that `slice` (something the score exposes) does not overlap
/// the input buffer — the ownership contract says every kept byte was
/// copied into the score's own arena. Zero-length slices own nothing
/// and trivially pass.
fn expectDisjoint(slice: []const u8, input: []const u8) !void {
    if (slice.len == 0) return;
    const s_begin = @intFromPtr(slice.ptr);
    const i_begin = @intFromPtr(input.ptr);
    try testing.expect(s_begin + slice.len <= i_begin or i_begin + input.len <= s_begin);
}

/// The success-side invariants every decoded score must satisfy,
/// whichever route produced its bytes.
fn checkSuccess(score: *const Pacb.DecodedScore, bytes: []const u8) !void {
    try testing.expect(score.tracks.len <= Pacb.MAX_TRACKS);
    try testing.expect(score.keys.len <= Pacb.MAX_KEYS);
    // `'EASE'` absent ⇒ exactly the synthesized linear default; present
    // ⇒ at least the default plus one real program, capped at 128.
    try testing.expect(score.programs.len >= 1);
    try testing.expect(score.programs.len <= Pacb.MAX_EASE_PROGRAMS);
    try testing.expect(score.controls.len <= Pacb.MAX_CONTROLS);
    try testing.expect(score.scenes.len <= Pacb.MAX_SCENES);
    try expectDisjoint(score.pacm, bytes);
    try expectDisjoint(score.regs, bytes);
    for (score.tracks) |track| switch (track.source) {
        .expr => |payload| try expectDisjoint(payload, bytes),
        .pattern => |payload| try expectDisjoint(payload, bytes),
        .keys, .trigger => {},
    };
}

/// The arbitrary-input contract of `Pacb.decode`: a well-formed refusal
/// (offset inside the buffer), resource exhaustion, or a score that
/// passes every success invariant and deinits clean. No panic is ever
/// legal — that is the harness's core claim.
fn checkDecode(bytes: []const u8) !void {
    var refusal: Pacb.Refusal = .{ .code = .bad_magic, .offset = 0 };
    var score = Pacb.decode(testing.allocator, bytes, &refusal) catch |err| switch (err) {
        error.OutOfMemory => return,
        error.Refused => {
            try testing.expect(refusal.offset <= bytes.len);
            return;
        },
    };
    defer score.deinit();
    try checkSuccess(&score, bytes);
}

/// Flip 1..8 bytes at drawn positions to drawn values — a plain
/// overwrite reaches `0x00`, the most structurally interesting value a
/// count/pad/flag byte can take.
fn flipBytes(buf: []u8, cur: *Cursor) void {
    if (buf.len == 0) return;
    const n = 1 + cur.byte() % 8;
    for (0..n) |_| {
        const pos = @as(usize, cur.u32bits()) % buf.len;
        buf[pos] = cur.byte();
    }
}

/// Keep a drawn prefix — every truncation length 0..len inclusive.
fn truncate(len: usize, cur: *Cursor) usize {
    return @as(usize, cur.u32bits()) % (len + 1);
}

/// Splice a prefix of `a` onto a suffix of `b` — cross-fixture section
/// surgery. The result is two fixtures concatenated at worst, which the
/// load-time budget check covers.
fn splice(dst: *[MAX_INPUT]u8, a: []const u8, b: []const u8, cur: *Cursor) usize {
    const cut_a = @as(usize, cur.u32bits()) % (a.len + 1);
    const cut_b = @as(usize, cur.u32bits()) % (b.len + 1);
    const total = cut_a + (b.len - cut_b);
    @memcpy(dst[0..cut_a], a[0..cut_a]);
    @memcpy(dst[cut_a..total], b[cut_b..]);
    return total;
}

/// Overwrite one count/length field — the header's `section_count`, a
/// fixed-record section's count, or a variable section's length prefix
/// — with a drawn extreme value, including just past
/// `MAX_TICK_ENTRIES`. Walks the fixture's real directory (never a
/// hardcoded offset), so whatever sections the committed producer
/// spelled are the targets.
fn inflateCountField(buf: []u8, cur: *Cursor) void {
    if (buf.len < Pacb.HEADER_LEN) return;
    const count = std.mem.readInt(u32, buf[12..16], .little);
    if (count == 0 or count > Pacb.MAX_SECTIONS) return;

    const value: u32 = switch (cur.byte() % 4) {
        0 => @intCast(Pacb.MAX_TICK_ENTRIES + 1), // 131073, just past the cap
        1 => std.math.maxInt(u32),
        2 => cur.u32bits(),
        else => @intCast(Pacb.MAX_TICK_ENTRIES), // exactly at cap
    };

    // Header's own count first, then section prefixes.
    if (cur.byte() % 4 == 0) {
        std.mem.writeInt(u32, buf[12..16], value, .little);
        return;
    }
    const i = cur.byte() % count;
    const at = Pacb.HEADER_LEN + Pacb.DIRECTORY_ENTRY_LEN * i;
    if (at + Pacb.DIRECTORY_ENTRY_LEN > buf.len) return;
    const id = std.mem.readInt(u32, buf[at..][0..4], .little);
    const off = std.mem.readInt(u32, buf[at + 4 ..][0..4], .little);
    const payload = @as(usize, off);
    if (payload + 4 > buf.len) return;
    switch (id) {
        // No count/length prefix to inflate.
        Pacb.TRAN_ID, Pacb.EASE_ID, Pacb.PACM_ID => {},
        // `[count u32]` for fixed-record kinds, the byte-length prefix
        // for `'REGS'`/`'PAYL'`, `'STRS'`' entry count — one u32 hole.
        else => std.mem.writeInt(u32, buf[payload..][0..4], value, .little),
    }
}

fn fuzzPacbDecode(ctx: *const Fixtures, smith: *Smith) anyerror!void {
    var buf: [MAX_INPUT]u8 = undefined;
    const len = smith.sliceWithHash(&buf, 0xB1C5_0A7);
    var cur = Cursor{ .bytes = buf[0..len] };

    // Raw mode: the Smith bytes themselves are the container input.
    if (cur.byte() % 2 == 0) return checkDecode(buf[0..len]);

    // Structured mode: mutate a committed fixture.
    const fixtures = [_][]const u8{ ctx.keys_only, ctx.expr_keys, ctx.full_small };
    const fixture = fixtures[cur.byte() % fixtures.len];
    var mut: [MAX_INPUT]u8 = undefined;
    var mlen = fixture.len;
    @memcpy(mut[0..mlen], fixture);

    switch (cur.byte() % 5) {
        0 => flipBytes(mut[0..mlen], &cur),
        1 => mlen = truncate(mlen, &cur),
        2 => {
            const other = fixtures[cur.byte() % fixtures.len];
            mlen = splice(&mut, fixture, other, &cur);
        },
        3 => inflateCountField(mut[0..mlen], &cur),
        4 => { // compound: flips THEN an inflated count
            flipBytes(mut[0..mlen], &cur);
            inflateCountField(mut[0..mlen], &cur);
        },
        else => unreachable,
    }
    return checkDecode(mut[0..mlen]);
}

/// Load the fixtures, prove the budget covers the splice worst case,
/// then run the corpus + Smith loop. Called from `src/fuzz.zig`'s
/// delegating test — the discovery rider (G12: the harness lives in
/// this file so its RED was a genuine missing module).
pub fn run() !void {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = @import("build_options").repo_root;

    const fixtures: Fixtures = .{
        .keys_only = try loadFixture(a, root, "keys-only"),
        .expr_keys = try loadFixture(a, root, "expr-keys"),
        .full_small = try loadFixture(a, root, "full-small"),
    };
    for ([_][]const u8{ fixtures.keys_only, fixtures.expr_keys, fixtures.full_small }) |fx| {
        try testing.expect(fx.len > 0);
        try testing.expect(2 * fx.len + 64 <= MAX_INPUT);
    }

    try testing.fuzz(&fixtures, fuzzPacbDecode, .{
        .corpus = &.{
            // Raw: empty buffer; a valid-header zero-section container;
            // dense garbage.
            "",
            "\x00PACB\x01\x00\x00\x00\x00\x00\x00\x00",
            "\x00" ++ ("\xff" ** 64),
            // Flips on keys-only: 4 sites (header/version region and
            // deep payload bytes), one zeroing a byte.
            "\x01\x00\x00\x04\x04\x00\x00\x00\xff\x10\x00\x00\x00\x00\x1f\x00\x00\x00\x7f\x40\x00\x00\x00\x01",
            // Truncate full-small to a 64-byte prefix.
            "\x01\x02\x01\x40\x00\x00\x00",
            // Splice: keys-only[0..16] ++ full-small[32..].
            "\x01\x00\x02\x10\x00\x00\x00\x02\x20\x00\x00\x00",
            // Inflate a section count to 131073 (just past
            // MAX_TICK_ENTRIES).
            "\x01\x02\x03\x00\x01\x06",
            // Inflate the header's section_count to u32 max.
            "\x01\x01\x03\x01\x00",
            // Compound: flip byte 0 to 0x0f, then inflate with a drawn
            // u32 count.
            "\x01\x02\x04\x01\x00\x00\x00\x00\x0f\x02\x01\x03",
        },
    });
}

test "fuzz Pacb.decode: committed fixtures decode clean (positive control)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = @import("build_options").repo_root;

    // The committed REAL-CLI outputs must decode SUCCESSFULLY and
    // satisfy every invariant the fuzz side asserts — the non-vacuity
    // anchor: the mutation modes start from buffers that do decode.
    for ([_][]const u8{
        try loadFixture(a, root, "keys-only"),
        try loadFixture(a, root, "expr-keys"),
        try loadFixture(a, root, "full-small"),
    }) |fx| {
        var refusal: Pacb.Refusal = undefined;
        var score = try Pacb.decode(testing.allocator, fx, &refusal);
        defer score.deinit();
        try testing.expect(score.tracks.len >= 1);
        try checkSuccess(&score, fx);
    }
}
