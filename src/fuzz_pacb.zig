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
//!   * (plan 05 Group 2) a structured `'SNAM'` mutator over the
//!     scene-carrying fixture: a syntactically valid `'SNAM'` frame is
//!     appended to the embedded `'PACM'`'s section-stream tail (the slot
//!     the encoder itself uses), and the container is REPAIRED around
//!     the growth — the directory's `'PACM'` len field and `'TRAN'`'s
//!     `pacm_fnv`. v1 has NO container-level checksum (the only two
//!     checksums in the format are `'TRAN'`'s, both over other
//!     sections), so there is no third repair to make — the repair
//!     list is exactly what the mutation breaks. Arbitrary inputs keep
//!     the total-invariants-only contract above; these CONSTRUCTED
//!     inputs are deterministic, so they carry behavioral assertions:
//!     the unbroken splice must DECODE with the spliced names visible
//!     through the score's own `'PACM'` copy, and each broken rule
//!     (count parallelism, `name_len` overrun, a mid-entry cut) must
//!     REFUSE — expected-refusal, never merely no-panic, with the
//!     FNV repaired precisely so the bytes are not shielded from
//!     metadata validation by an earlier error (Review Focus 2).
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
const Pacm = @import("Pacm.zig");

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

// ---------------------------------------------------------------------------
// The structured 'SNAM' mutator (plan 05 Group 2, I6): append a
// syntactically valid 'SNAM' frame to a real pack's embedded 'PACM'
// and repair the container exactly around that growth, so the bytes
// reach metadata validation instead of dying at an earlier gate.
// ---------------------------------------------------------------------------

/// How the appended 'SNAM' frame is broken (or not). Exactly ONE SNAM
/// rule breaks per flaw; everything else about the container stays
/// exact, so the refusal a decode produces is attributable.
pub const SnamFlaw = enum {
    /// Count-parallel valid frame — the splice must DECODE.
    none,
    /// The count no longer equals the 'SCEN' count (entries stay
    /// internally consistent, so only parallelism can refuse).
    count_inflated,
    /// The first entry's `name_len` field claims `overrun_len` bytes
    /// that are not there (count and accounting stay honest).
    len_overrun,
    /// The container ends one byte short of the appended frame — a
    /// record cut mid-entry, with the directory length repaired to the
    /// truncated truth so only the frame's own length check fires.
    truncated,
};

/// FNV-1a-64 over bytes — `'TRAN'`'s checksum family. Private twin:
/// the encoder owns the public spelling (`PacbEncode.fnv1a64`) and the
/// fuzz closure must not drag the compiler in; the known-answer vectors
/// are pinned on the public one.
fn fnv1a64(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h = h *% 0x100000001b3;
    }
    return h;
}

fn readU32(b: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, b[at..][0..4], .little);
}

fn readU16(b: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, b[at..][0..2], .little);
}

/// The `'SCEN'` count of an embedded `'PACM'` blob — the exact walk
/// `Pacm.decode` does (header counts, controls with inline ids, then
/// the TLV stream), stopping at the scenes section. Null when the walk
/// cannot find a count to be parallel to.
fn scenCountOf(pacm: []const u8) ?u32 {
    if (pacm.len < Pacm.META_HEADER_LEN) return null;
    if (readU32(pacm, 0) != Pacm.META_MAGIC) return null;
    var pos: usize = Pacm.META_HEADER_LEN;
    pos += @as(usize, readU32(pacm, 28)) * Pacm.META_TRACK_LEN;
    pos += @as(usize, readU32(pacm, 32)) * Pacm.META_KEY_LEN;
    const controls = readU32(pacm, 36);
    var c: u32 = 0;
    while (c < controls) : (c += 1) {
        if (pacm.len - pos < Pacm.META_CONTROL_LEN) return null;
        const id_len = readU16(pacm, pos + 6);
        pos += Pacm.META_CONTROL_LEN;
        if (pacm.len - pos < id_len) return null;
        pos += id_len;
    }
    while (pos < pacm.len) {
        if (pacm.len - pos < Pacm.META_SECTION_HEADER_LEN) return null;
        const sid = readU32(pacm, pos);
        const plen = readU32(pacm, pos + 4);
        pos += Pacm.META_SECTION_HEADER_LEN;
        if (pacm.len - pos < plen) return null;
        if (sid == Pacm.SCENES_SECTION_ID) return readU32(pacm, pos);
        pos += plen;
    }
    return null; // no 'SCEN' — nothing for names to be parallel to
}

/// Append an `'SNAM'` frame to `pacb`'s embedded `'PACM'` (the section
/// stream's tail — the slot the encoder itself uses) and repair the
/// container around the growth: the directory's `'PACM'` len field and
/// `'TRAN'`'s `pacm_fnv`, recomputed over the grown bytes. v1 has no
/// container-level checksum, so there is no third repair to make.
/// `flaw` then breaks exactly one SNAM rule (see `SnamFlaw`). Names
/// fill the entries cyclically; every name must be non-empty (the
/// truncated leg cuts entry bytes). `dest` must NOT alias `pacb` —
/// the splice copies first and writes past the copy. Returns the new
/// total length, or null when the container lacks a seam the splice
/// needs (no `.pacm`/`.tran` section, no `'SCEN'`, or `dest` too
/// small).
pub fn spliceSnam(
    dest: []u8,
    pacb: []const u8,
    names: []const []const u8,
    flaw: SnamFlaw,
    extra_count: u32,
    overrun_len: u32,
) ?usize {
    if (pacb.len < Pacb.HEADER_LEN or dest.len < pacb.len) return null;
    if (names.len == 0) return null;
    for (names) |name| if (name.len == 0) return null;

    // Directory walk: the '.pacm' entry (to grow) and '.tran' (to
    // re-hash). The real directory is exact, so the '.pacm' section —
    // the canonical last one — ends at the buffer end.
    const count = readU32(pacb, 12);
    if (count == 0 or count > Pacb.MAX_SECTIONS) return null;
    var pacm_entry: usize = 0;
    var pacm_off: usize = 0;
    var pacm_len: usize = 0;
    var tran_off: usize = 0;
    var have_tran = false;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const at = Pacb.HEADER_LEN + Pacb.DIRECTORY_ENTRY_LEN * i;
        if (at + Pacb.DIRECTORY_ENTRY_LEN > pacb.len) return null;
        const id = readU32(pacb, at);
        if (id == Pacb.PACM_ID) {
            pacm_entry = at;
            pacm_off = readU32(pacb, at + 4);
            pacm_len = readU32(pacb, at + 8);
        }
        if (id == Pacb.TRAN_ID) {
            tran_off = readU32(pacb, at + 4);
            have_tran = true;
        }
    }
    if (pacm_len == 0 or !have_tran) return null;
    if (pacm_off + pacm_len != pacb.len) return null;
    if (tran_off + 56 > pacb.len) return null; // the TRAN record is 56 bytes

    const scen = scenCountOf(pacb[pacm_off..][0..pacm_len]) orelse return null;
    const entries: u64 = switch (flaw) {
        .none, .len_overrun, .truncated => scen,
        .count_inflated => @as(u64, scen) + extra_count,
    };
    if (entries > std.math.maxInt(u32)) return null;

    // Frame budget: [id][plen][count] + entries × [len] + name bytes.
    var payload_len: usize = 4;
    for (0..@intCast(entries)) |k| payload_len += 4 + names[k % names.len].len;
    const frame_len = 8 + payload_len;
    if (dest.len < pacb.len + frame_len) return null;
    const grown = pacm_len + frame_len;
    const cut: usize = if (flaw == .truncated) 1 else 0;
    const total = pacm_off + grown - cut;

    @memcpy(dest[0..pacb.len], pacb);

    // The frame: id, payload length (the TRUE byte count — the flaws
    // lie in field VALUES, never in the frame's own accounting), then
    // count + cyclic entries.
    const frame = dest[pacm_off + pacm_len ..][0..frame_len];
    std.mem.writeInt(u32, frame[0..4], Pacm.SNAM_SECTION_ID, .little);
    std.mem.writeInt(u32, frame[4..8], @intCast(payload_len), .little);
    std.mem.writeInt(u32, frame[8..12], @intCast(entries), .little);
    var pos: usize = 12;
    for (0..@intCast(entries)) |k| {
        const name = names[k % names.len];
        const len_field: u32 = if (flaw == .len_overrun and k == 0) overrun_len else @intCast(name.len);
        std.mem.writeInt(u32, frame[pos..][0..4], len_field, .little);
        pos += 4;
        @memcpy(frame[pos..][0..name.len], name);
        pos += name.len;
    }

    // Repairs: the directory's 'PACM' len now names the grown (or
    // truncated) payload, and 'TRAN''s pacm_fnv re-hashes it.
    const new_pacm_len: u32 = @intCast(grown - cut);
    std.mem.writeInt(u32, dest[pacm_entry + 8 ..][0..4], new_pacm_len, .little);
    std.mem.writeInt(u64, dest[tran_off + 48 ..][0..8], fnv1a64(dest[pacm_off..total]), .little);
    return total;
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

    const arm = cur.byte() % 8;
    switch (arm) {
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
        // 'SNAM' structured splice over the scene-carrying fixture
        // (full-small): append a syntactically valid 'SNAM' frame to
        // the embedded 'PACM' tail and repair the container, then
        // either leave it valid (5) or break exactly one SNAM rule —
        // 6: count inflation; 7: a name_len overrun or a mid-entry
        // cut, by sub-draw.
        5, 6, 7 => {
            // A distinct output buffer: spliceSnam copies, so its dest
            // must not alias the input.
            var out: [MAX_INPUT]u8 = undefined;
            var buf_in: [MAX_INPUT]u8 = undefined;
            @memcpy(buf_in[0..ctx.full_small.len], ctx.full_small);

            // Hostile name bytes: arbitrary and drawn — the decoders
            // check bounds only, never content.
            var name_buf: [32]u8 = undefined;
            const nlen = 1 + cur.byte() % name_buf.len;
            for (name_buf[0..nlen]) |*b| b.* = cur.byte();
            const names = [_][]const u8{name_buf[0..nlen]};
            const flaw: SnamFlaw = switch (arm) {
                5 => .none,
                6 => .count_inflated,
                else => if (cur.byte() % 2 == 0) .len_overrun else .truncated,
            };
            const extra: u32 = 1 + cur.byte() % 3;
            const new_len = spliceSnam(&out, buf_in[0..ctx.full_small.len], &names, flaw, extra, 0xFFFF_FFF0) orelse
                return checkDecode(buf_in[0..ctx.full_small.len]); // no seam: fall back to the total contract

            if (flaw == .none) {
                // Positive control: the decoded score serves the
                // embedded 'PACM' with the drawn name visible.
                var refusal: Pacb.Refusal = undefined;
                var score = Pacb.decode(testing.allocator, out[0..new_len], &refusal) catch |err| switch (err) {
                    error.OutOfMemory => return,
                    error.Refused => return error.ValidSnamRefused,
                };
                defer score.deinit();
                try checkSuccess(&score, out[0..new_len]);
                const view = Pacm.decode(score.pacm) orelse return error.MetaUndecodable;
                try testing.expectEqualStrings(names[0], view.scene(0).name orelse return error.TestExpectedName);
                return;
            }
            // Expected refusal, not merely no-panic: the container was
            // repaired, so ONLY the broken SNAM rule can fire — a
            // well-formed refusal whose offset lands in the buffer.
            var refusal: Pacb.Refusal = .{ .code = .bad_magic, .offset = 0 };
            const outcome = Pacb.decode(testing.allocator, out[0..new_len], &refusal);
            if (outcome) |ok| {
                var score = ok;
                score.deinit();
                return error.MalformedSnamAccepted;
            } else |err| switch (err) {
                error.OutOfMemory => return,
                error.Refused => try testing.expect(refusal.offset <= new_len),
            }
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
            // 'SNAM' splice, valid: names "snam!" land in the decoded
            // score's own 'PACM' copy (draws: fixture full-small, arm
            // 5, name_len 5, the bytes, the extra-count draw).
            "\x01\x02\x05\x04snam!\x00",
            // 'SNAM' splice, count inflated (extra 2 → count 3 vs the
            // 'SCEN' 1): must refuse.
            "\x01\x02\x06\x02drp\x01",
            // 'SNAM' splice, name_len overrun (even sub-draw): must
            // refuse — the u32 field claims bytes that are not there.
            "\x01\x02\x07\x03drp\x00",
            // 'SNAM' splice, mid-entry cut (odd sub-draw): must
            // refuse — the container ends inside the entry.
            "\x01\x02\x07\x02xy\x01",
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

test "fuzz Pacb.decode: the 'SNAM' splice repairs exactly and breaks one rule per flaw" {
    // Deterministic twin of the fuzz arms over the real full-small
    // pack: the container around the appended 'SNAM' frame is REPAIRED
    // (directory len + TRAN pacm_fnv — v1 has no container checksum),
    // so each flaw's refusal is attributable to the SNAM rule it broke
    // and nothing else. The valid splice DECODES; every flaw REFUSES
    // with the embedded-PACM class (`meta_malformed`) and an in-bounds
    // offset. Expected-refusal, never merely no-panic.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = @import("build_options").repo_root;
    const fx = try loadFixture(a, root, "full-small");

    var dest: [MAX_INPUT]u8 = undefined;
    const names = [_][]const u8{"drop"};

    // The unbroken splice decodes clean — every success invariant holds,
    // and the spliced names are VISIBLE: the score's own served 'PACM'
    // copy decodes with the drawn name byte-for-byte (positive control —
    // the bytes reached metadata validation and survived it, not merely
    // that the container passed its gates).
    {
        const len = spliceSnam(&dest, fx, &names, .none, 0, 0) orelse return error.SpliceSeamMissing;
        var refusal: Pacb.Refusal = undefined;
        var score = try Pacb.decode(testing.allocator, dest[0..len], &refusal);
        defer score.deinit();
        try checkSuccess(&score, dest[0..len]);
        const view = Pacm.decode(score.pacm) orelse return error.MetaUndecodable;
        try testing.expectEqualStrings(names[0], view.scene(0).name orelse return error.TestExpectedName);
    }
    // One rule broken at a time: count parallelism, name_len overrun,
    // mid-entry cut.
    inline for (.{ SnamFlaw.count_inflated, SnamFlaw.len_overrun, SnamFlaw.truncated }) |flaw| {
        const len = spliceSnam(&dest, fx, &names, flaw, 2, 0xFFFF_FFF0) orelse return error.SpliceSeamMissing;
        var refusal: Pacb.Refusal = .{ .code = .bad_magic, .offset = 0 };
        const outcome = Pacb.decode(testing.allocator, dest[0..len], &refusal);
        if (outcome) |ok| {
            var score = ok;
            score.deinit();
            std.debug.print("flaw {s}: decoded, expected refusal\n", .{@tagName(flaw)});
            return error.MalformedSnamAccepted;
        } else |err| switch (err) {
            error.OutOfMemory => return,
            error.Refused => {
                try testing.expectEqual(Pacb.RefusalCode.meta_malformed, refusal.code);
                try testing.expect(refusal.offset <= len);
            },
        }
    }
}
