//! `'PACB'` — the compiled-score container (data at rest).
//!
//! A `'PACB'` file carries one compiled score: the transport truth, the
//! target-registry identity, the track/key/trigger/control/scene rows, the
//! expression/pattern payloads, and the `'PACM'` metadata blob — all in one
//! versioned, validated, little-endian container. It is NOT a wasm-boundary
//! blob: it is written offline by `pacer pack` and read by the playback
//! runtime. Every field is packed with explicit read/write calls; there is
//! no implicit struct padding or alignment in the wire format, and every
//! reserved/pad field is zero.
//!
//! Layout:
//!
//!     [magic u32 'PACB'][version u32 = 1][required_features u32]
//!     [section_count u32]
//!     section_count × { id u32, off u32, len u32 }   ; off from buffer start
//!
//! `required_features` bit0 = pattern tracks are present. All other bits
//! are reserved and MUST be zero; a decoder refuses unknown set bits.
//!
//! The directory is EXACT, not merely well-formed: it begins immediately
//! after the 16-byte header (`off[0] == 16 + 12 × section_count`), sections
//! are contiguous and gap-free (`off[i+1] == off[i] + len[i]`), ids are
//! unique, present sections appear in the fixed canonical order below, and
//! the buffer ends exactly at the last section's end — no gaps, no
//! inter-section slack, no trailing bytes. A present fixed-width section's
//! payload is exactly `[count u32] + count × record width`; `'TRAN'` is one
//! 56-byte record with no count. Variable-width sections validate their own
//! lengths in their owning Phase-2 stage.
//!
//! Canonical order and record widths:
//!
//!     'TRAN' 0x4e415254  56 B singleton (no count)
//!     'REGS' 0x53474552  variable: [byte_len u32] + canonical 'PACT' bytes
//!     'DECL' 0x4c434544  4 B records, count-prefixed
//!     'EMIT' 0x54494d45  8 B records, count-prefixed
//!     'TMPO' 0x4f504d54  16 B records, count-prefixed
//!     'TRAK' 0x4b415254  40 B records, count-prefixed
//!     'KEYS' 0x5359454b  28 B records, count-prefixed
//!     'TICK' 0x4b434954  8 B records, count-prefixed
//!     'EASE' 0x45534145  variable: PACM 'EASE' payload verbatim
//!     'CTRL' 0x4c525443  60 B records, count-prefixed
//!     'SCEN' 0x4e454353  16 B records, count-prefixed
//!     'STRS' 0x53525453  variable: [count u32][byte_size u32] + entries
//!     'PAYL' 0x4c594150  variable: [byte_size u32] + SJON binary payloads
//!     'PACM' 0x4d434150  variable: the metadata blob verbatim
//!
//! The section-kind enum is wire-stable and append-only: its tags ARE the
//! 4-CCs. Never reorder, remove, or retag a kind; a new kind appends and a
//! breaking change to an existing payload mints a fresh id. The canonical
//! order array is likewise frozen.
//!
//! Caps (v1 binary-format resource policy, frozen):
//!
//!   * `MAX_PAYLOAD_BYTES` = 256 KiB per expression/pattern payload.
//!   * `MAX_PAYL_BYTES` = 4 MiB total `'PAYL'` bytes.
//!   * `MAX_TICK_ENTRIES` = 131072 explicit-trigger entries, globally.
//!     DERIVATION: the wasm artifact's static doc zone is 256 KiB
//!     (`MAX_DOC_SIZE`, `src/wasm_entry.zig:72`); explicit `:at` entries
//!     are a direct literal vector with no sharing/repetition construct,
//!     and each costs at least 2 source bytes (shortest atom plus
//!     separator/delimiter, amortized). A wasm-compilable score therefore
//!     carries at most 256×1024/2 = 131072 explicit ticks across all
//!     tracks. This is a conservative producer bound, not a claim that the
//!     encoding is tight; native CLI/direct-API compiles can exceed it and
//!     the packer refuses loudly with the measured count. The text path
//!     itself stays uncapped.
//!
//! INTERIM T2.1 BOUNDARY — no production use. This file currently owns the
//! container header, the directory validator, the frozen caps, and
//! `pacbWorstCase`. `parseDirectory` is a directory-only view: it validates
//! structure, never section semantics, and is NOT a decoded score. The
//! whole-blob `decode(...) DecodedScore` entry point is deliberately absent
//! until the section stages land (T2.2–T2.8): returning a successful score
//! before transport/registry/records/payloads/PACM are validated would be a
//! lying API. Section payload decoding, `DecodedScore`, and its ownership
//! contract arrive with those stages.
//!
//! Imports: std only (T2.1 needs nothing else). The end-state decoder may
//! add `PactCodec`, `TrackTable`, `TimeMap`, `Easing`, `Pacm`, and sjon;
//! it must NEVER import `Compile`, `Abi`, `Schema`, or `Driver`.

const std = @import("std");

/// `"PACB"` read as a little-endian u32.
pub const MAGIC: u32 = 0x42434150;
/// Container version. A breaking layout change bumps this.
pub const VERSION: u32 = 1;

/// Required-feature bit 0: at least one `:pattern` track is present.
pub const FEATURE_PATTERN_TRACKS: u32 = 1 << 0;
/// Every feature bit this decoder understands. Unknown set bits refuse.
pub const KNOWN_FEATURES: u32 = FEATURE_PATTERN_TRACKS;

/// Fixed file header: magic, version, required_features, section_count.
pub const HEADER_LEN: usize = 16;
/// One directory entry: id, off, len.
pub const DIRECTORY_ENTRY_LEN: usize = 12;
/// The canonical table has exactly 14 section kinds.
pub const MAX_SECTIONS: usize = 14;

/// Per-expression/pattern payload cap (v1 resource policy).
pub const MAX_PAYLOAD_BYTES: usize = 256 * 1024;
/// Total `'PAYL'` payload cap (v1 resource policy).
pub const MAX_PAYL_BYTES: usize = 4 * 1024 * 1024;
/// Global explicit-trigger entry cap (v1 resource policy; derivation in
/// the module header).
pub const MAX_TICK_ENTRIES: usize = 131072;

// Frozen copies of the compile-side caps. `Pacb` never imports the
// compiler; `src/root.zig` asserts each copy against its source definition.
pub const MAX_TARGETS: usize = 1024;
pub const MAX_TRACKS: usize = 256;
pub const MAX_KEYS: usize = 4096;
pub const MAX_EASE_PROGRAMS: usize = 128;
pub const MAX_CONTROLS: usize = 64;
pub const MAX_SCENES: usize = 64;
pub const MAX_TEMPO_SEGMENTS: usize = 512;
/// The `EmitName` ordinal count (`beat/bar/phase/bpm/t`).
pub const EMIT_LANE_CAP: usize = 5;
/// Canonical `'PACT'` header size, copied from `PactCodec`.
pub const PACT_HEADER_LEN: usize = 8;
/// Frozen `'PACM'` `'EASE'` program record width, copied from `Abi`.
const PACM_EASE_PROGRAM_LEN: usize = 772;

/// `'TRAN'` is one 56-byte record, not count-prefixed.
pub const TRAN_REC_LEN: usize = 56;
/// `'DECL'` record: registry u8, ncomp u8, pad u16.
pub const DECL_REC_LEN: usize = 4;
/// `'EMIT'` record: name u8, registry u8, target_id u16, reserved u32.
pub const EMIT_REC_LEN: usize = 8;
/// `'TMPO'` record: tick i64, bpm f64.
pub const TMPO_REC_LEN: usize = 16;
/// `'TRAK'` record width.
pub const TRAK_REC_LEN: usize = 40;
/// `'KEYS'` record: at i64, value f32×4, ease_ref u16, pad u16.
pub const KEYS_REC_LEN: usize = 28;
/// `'TICK'` record: one i64 tick.
pub const TICK_REC_LEN: usize = 8;
/// `'CTRL'` record width.
pub const CTRL_REC_LEN: usize = 60;
/// `'SCEN'` record: start_tick i64, dur_ticks i64.
pub const SCEN_REC_LEN: usize = 16;

/// `"TRAN"` read as LE u32.
pub const TRAN_ID: u32 = 0x4e415254;
/// `"REGS"` read as LE u32.
pub const REGS_ID: u32 = 0x53474552;
/// `"DECL"` read as LE u32.
pub const DECL_ID: u32 = 0x4c434544;
/// `"EMIT"` read as LE u32.
pub const EMIT_ID: u32 = 0x54494d45;
/// `"TMPO"` read as LE u32.
pub const TMPO_ID: u32 = 0x4f504d54;
/// `"TRAK"` read as LE u32.
pub const TRAK_ID: u32 = 0x4b415254;
/// `"KEYS"` read as LE u32.
pub const KEYS_ID: u32 = 0x5359454b;
/// `"TICK"` read as LE u32.
pub const TICK_ID: u32 = 0x4b434954;
/// `"EASE"` read as LE u32.
pub const EASE_ID: u32 = 0x45534145;
/// `"CTRL"` read as LE u32.
pub const CTRL_ID: u32 = 0x4c525443;
/// `"SCEN"` read as LE u32.
pub const SCEN_ID: u32 = 0x4e454353;
/// `"STRS"` read as LE u32.
pub const STRS_ID: u32 = 0x53525453;
/// `"PAYL"` read as LE u32.
pub const PAYL_ID: u32 = 0x4c594150;
/// `"PACM"` read as LE u32.
pub const PACM_ID: u32 = 0x4d434150;

/// Section kinds. The tags ARE the 4-CC ids and are wire-stable from
/// birth: append-only, never reorder/remove/retag. Declaration order is
/// the canonical emission order.
pub const SectionKind = enum(u32) {
    tran = TRAN_ID,
    regs = REGS_ID,
    decl = DECL_ID,
    emit = EMIT_ID,
    tmpo = TMPO_ID,
    trak = TRAK_ID,
    keys = KEYS_ID,
    tick = TICK_ID,
    ease = EASE_ID,
    ctrl = CTRL_ID,
    scen = SCEN_ID,
    strs = STRS_ID,
    payl = PAYL_ID,
    pacm = PACM_ID,
};

/// Canonical directory/emission order, frozen with v1.
pub const canonical_section_order = [_]SectionKind{
    .tran,
    .regs,
    .decl,
    .emit,
    .tmpo,
    .trak,
    .keys,
    .tick,
    .ease,
    .ctrl,
    .scen,
    .strs,
    .payl,
    .pacm,
};

comptime {
    std.debug.assert(canonical_section_order.len == MAX_SECTIONS);
    std.debug.assert(std.enums.values(SectionKind).len == MAX_SECTIONS);
    for (canonical_section_order, 0..) |kind, i| {
        for (canonical_section_order[0..i]) |earlier| {
            std.debug.assert(kind != earlier);
        }
    }
}

/// One parsed directory row.
pub const Section = struct {
    kind: SectionKind,
    /// Byte offset from the start of the file.
    off: u32,
    /// Payload length in bytes.
    len: u32,
    /// Record count for a count-prefixed fixed-width section. `null` for
    /// `'TRAN'` (one record, no count) and every variable-width kind.
    count: ?u32 = null,
};

/// The interim directory-only view of a `'PACB'` buffer. It never aliases
/// the input bytes and carries no section content: this is NOT a decoded
/// score (see the module header's T2.1 boundary).
pub const Directory = struct {
    required_features: u32,
    len: u8,
    sections: [MAX_SECTIONS]Section = @splat(.{
        .kind = .tran,
        .off = 0,
        .len = 0,
        .count = null,
    }),

    /// The `len` valid rows.
    pub fn slice(self: *const Directory) []const Section {
        return self.sections[0..self.len];
    }

    /// The row for `kind`, or null when the section is absent.
    pub fn find(self: *const Directory, kind: SectionKind) ?*const Section {
        for (self.slice()) |*section| {
            if (section.kind == kind) return section;
        }
        return null;
    }
};

/// Why a `'PACB'` buffer was refused. Append-only from birth: the enum is
/// u16 so the reason stream can grow without renumbering; never reorder or
/// remove a variant.
pub const RefusalCode = enum(u16) {
    bad_magic,
    unsupported_version,
    unsupported_features,
    directory_malformed,
    count_mismatch,
    transport_invalid,
    tempo_invalid,
    record_invalid,
    key_invalid,
    ease_invalid,
    trigger_invalid,
    scene_invalid,
    control_invalid,
    strs_invalid,
    payload_malformed,
    cap_exceeded,
    registry_mismatch,
    decl_invalid,
    non_canonical,
    meta_malformed,
    meta_incoherent,
};

/// A refusal reason plus the offset (from the file start) where the defect
/// was detected. `offset` is diagnostic only; it never aliases the input.
pub const Refusal = struct {
    code: RefusalCode,
    offset: usize,
};

/// Decoder error set. `OutOfMemory` is reserved for the arena-backed
/// `DecodedScore` stages; the directory-only view never allocates.
pub const DecodeError = error{ Refused, OutOfMemory };

fn fail(refusal: ?*Refusal, code: RefusalCode, offset: usize) DecodeError {
    if (refusal) |out| out.* = .{ .code = code, .offset = offset };
    return error.Refused;
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

/// The count-prefixed fixed record width of `kind`, or null when the kind
/// is not a count-prefixed fixed-record section.
fn fixedRecordLen(kind: SectionKind) ?usize {
    return switch (kind) {
        .decl => DECL_REC_LEN,
        .emit => EMIT_REC_LEN,
        .tmpo => TMPO_REC_LEN,
        .trak => TRAK_REC_LEN,
        .keys => KEYS_REC_LEN,
        .tick => TICK_REC_LEN,
        .ctrl => CTRL_REC_LEN,
        .scen => SCEN_REC_LEN,
        .tran, .regs, .ease, .strs, .payl, .pacm => null,
    };
}

/// Canonical index of `kind`; every enum value is in the frozen array.
fn canonicalIndex(kind: SectionKind) usize {
    for (canonical_section_order, 0..) |candidate, i| {
        if (candidate == kind) return i;
    }
    unreachable;
}

/// Validate one section's directory-level shape: `'TRAN'` is exactly one
/// 56-byte record; every count-prefixed fixed-width kind is exactly
/// `4 + count × width`; `'TICK'` additionally enforces its cap. The
/// variable-width kinds validate their own internal lengths in their
/// owning Phase-2 stage.
fn checkSectionShape(
    section: *Section,
    payload: []const u8,
    refusal: ?*Refusal,
) DecodeError!void {
    if (section.kind == .tran) {
        if (payload.len != TRAN_REC_LEN) {
            return fail(refusal, .directory_malformed, section.off);
        }
        return;
    }

    const rec_len = fixedRecordLen(section.kind) orelse return;
    if (payload.len < 4) return fail(refusal, .directory_malformed, section.off);

    const count = readU32(payload, 0);
    const expected_len = 4 + @as(u64, count) * @as(u64, rec_len);
    if (expected_len != @as(u64, payload.len)) {
        return fail(refusal, .directory_malformed, section.off);
    }
    section.count = count;

    if (section.kind == .tick and count > MAX_TICK_ENTRIES) {
        return fail(refusal, .cap_exceeded, section.off);
    }
}

/// Validate the container header and directory and return the interim
/// directory view. Structural rules only: magic/version/features, the
/// directory's exact placement/contiguity/order/uniqueness, each section's
/// bounds, and the fixed-width record/count arithmetic. Section payload
/// semantics belong to T2.2–T2.8.
pub fn parseDirectory(bytes: []const u8, refusal: ?*Refusal) DecodeError!Directory {
    if (bytes.len < 4) return fail(refusal, .bad_magic, 0);
    if (readU32(bytes, 0) != MAGIC) return fail(refusal, .bad_magic, 0);
    if (bytes.len < HEADER_LEN) return fail(refusal, .directory_malformed, bytes.len);
    if (readU32(bytes, 4) != VERSION) return fail(refusal, .unsupported_version, 4);

    const required_features = readU32(bytes, 8);
    if (required_features & ~KNOWN_FEATURES != 0) {
        return fail(refusal, .unsupported_features, 8);
    }

    const section_count = readU32(bytes, 12);
    if (section_count > MAX_SECTIONS) {
        return fail(refusal, .directory_malformed, 12);
    }
    const count: usize = @intCast(section_count);
    const directory_end = HEADER_LEN + count * DIRECTORY_ENTRY_LEN;
    if (bytes.len < directory_end) {
        return fail(refusal, .directory_malformed, bytes.len);
    }

    var directory: Directory = .{
        .required_features = required_features,
        .len = @intCast(count),
    };
    var seen: u16 = 0;
    var last_index: ?usize = null;
    var expected_off: usize = directory_end;

    for (0..count) |i| {
        const at = HEADER_LEN + i * DIRECTORY_ENTRY_LEN;
        const id = readU32(bytes, at);
        const kind = std.enums.fromInt(SectionKind, id) orelse
            return fail(refusal, .directory_malformed, at);

        const index = canonicalIndex(kind);
        const bit: u16 = @as(u16, 1) << @as(u4, @intCast(index));
        if (seen & bit != 0) return fail(refusal, .directory_malformed, at);
        seen |= bit;
        if (last_index) |previous| {
            if (index <= previous) return fail(refusal, .directory_malformed, at);
        }
        last_index = index;

        const off = readU32(bytes, at + 4);
        const len = readU32(bytes, at + 8);

        // Exact placement: off[0] == directory_end, then every following
        // section starts exactly where the previous one ended. This one
        // check rejects gaps, overlap, and a wrong first offset.
        const off_usize: usize = off;
        const len_usize: usize = len;
        if (off_usize != expected_off) {
            return fail(refusal, .directory_malformed, at + 4);
        }

        // Safe bounds (subtraction form: no integer overflow). The
        // contiguity invariant keeps `off_usize <= bytes.len`, but the
        // explicit check keeps the invariant local and total.
        if (off_usize > bytes.len or len_usize > bytes.len - off_usize) {
            return fail(refusal, .directory_malformed, at + 8);
        }

        var section: Section = .{ .kind = kind, .off = off, .len = len };
        try checkSectionShape(&section, bytes[off_usize..][0..len_usize], refusal);
        directory.sections[i] = section;
        expected_off = off_usize + len_usize;
    }

    // The buffer ends exactly at the last section's end: no trailing slack.
    if (expected_off != bytes.len) {
        return fail(refusal, .directory_malformed, expected_off);
    }
    return directory;
}

/// Frozen copy of `Abi.metaWorstCase`'s arithmetic: the largest `'PACM'`
/// blob at every cap, given a per-control-id `str_allowance`. `Pacb` never
/// imports `Abi`; `src/root.zig` equality-asserts this function against
/// `Abi.metaWorstCase` for several allowances.
pub fn pacmWorstCase(comptime str_allowance: usize) usize {
    const meta_header_len = 40;
    const meta_track_len = 24;
    const meta_key_len = 32;
    const meta_control_len = 64;
    const meta_section_header_len = 8;
    const scene_rec_len = 24;
    const tempo_rec_len = 16;

    return meta_header_len +
        MAX_TRACKS * meta_track_len +
        MAX_KEYS * meta_key_len +
        MAX_CONTROLS * (meta_control_len + str_allowance) +
        meta_section_header_len + 4 + MAX_SCENES * scene_rec_len +
        meta_section_header_len + 4 + MAX_EASE_PROGRAMS * PACM_EASE_PROGRAM_LEN +
        4 + MAX_KEYS * 2 +
        meta_section_header_len + 4 + MAX_TEMPO_SEGMENTS * tempo_rec_len;
}

/// The largest `'PACB'` file at every v1 cap, term by term in wire order.
/// `str_allowance` is caller policy for the three string-bearing sums
/// (target names in `'REGS'`, control ids in `'STRS'`, control ids in the
/// embedded `'PACM'`), matching `Abi.metaWorstCase`'s convention. This is
/// arithmetic, not a tuned measurement: every term is a frozen width/cap
/// or a length prefix, and the `'PACM'` tail is the frozen copy above.
pub fn pacbWorstCase(comptime str_allowance: usize) usize {
    return HEADER_LEN +
        MAX_SECTIONS * DIRECTORY_ENTRY_LEN +
        TRAN_REC_LEN +
        (4 + PACT_HEADER_LEN + MAX_TARGETS * (4 + str_allowance)) + // 'REGS'
        (4 + MAX_TARGETS * DECL_REC_LEN) + // 'DECL'
        (4 + EMIT_LANE_CAP * EMIT_REC_LEN) + // 'EMIT'
        (4 + MAX_TEMPO_SEGMENTS * TMPO_REC_LEN) + // 'TMPO'
        (4 + MAX_TRACKS * TRAK_REC_LEN) + // 'TRAK'
        (4 + MAX_KEYS * KEYS_REC_LEN) + // 'KEYS'
        (4 + MAX_TICK_ENTRIES * TICK_REC_LEN) + // 'TICK'
        (4 + MAX_EASE_PROGRAMS * PACM_EASE_PROGRAM_LEN + 4 + MAX_KEYS * 2) + // 'EASE'
        (4 + MAX_CONTROLS * CTRL_REC_LEN) + // 'CTRL'
        (4 + MAX_SCENES * SCEN_REC_LEN) + // 'SCEN'
        (8 + MAX_CONTROLS * (2 + str_allowance)) + // 'STRS'
        (4 + MAX_PAYL_BYTES) + // 'PAYL'
        pacmWorstCase(str_allowance); // 'PACM'
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

fn putU32(buf: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, buf[at..][0..4], value, .little);
}

fn writeHeader(buf: []u8, section_count: usize, required_features: u32) void {
    putU32(buf, 0, MAGIC);
    putU32(buf, 4, VERSION);
    putU32(buf, 8, required_features);
    putU32(buf, 12, @intCast(section_count));
}

fn writeDirEntry(
    buf: []u8,
    index: usize,
    kind: SectionKind,
    off: usize,
    len: usize,
) void {
    const at = HEADER_LEN + index * DIRECTORY_ENTRY_LEN;
    putU32(buf, at, @intFromEnum(kind));
    putU32(buf, at + 4, @intCast(off));
    putU32(buf, at + 8, @intCast(len));
}

fn expectRefusal(bytes: []const u8, code: RefusalCode) !void {
    var refusal: Refusal = undefined;
    try t.expectError(error.Refused, parseDirectory(bytes, &refusal));
    try t.expectEqual(code, refusal.code);
}

const minimal_dir_end = HEADER_LEN + 2 * DIRECTORY_ENTRY_LEN;
const minimal_len = minimal_dir_end + TRAN_REC_LEN + 40;

/// The plan's minimal valid fixture: `'TRAN'` + `'PACM'` only, with the
/// payload bytes zeroed (this task validates the directory, not content).
/// Offsets are written literally, not derived from a writer.
fn minimalFixture() [minimal_len]u8 {
    var buf: [minimal_len]u8 = @splat(0);
    writeHeader(&buf, 2, 0);
    writeDirEntry(&buf, 0, .tran, 40, TRAN_REC_LEN);
    writeDirEntry(&buf, 1, .pacm, 96, 40);
    return buf;
}

test "Pacb: minimal TRAN+PACM fixture decodes its directory" {
    const fixture = minimalFixture();
    var refusal: Refusal = undefined;
    const directory = try parseDirectory(&fixture, &refusal);

    try t.expectEqual(@as(u8, 2), directory.len);
    try t.expectEqual(@as(u32, 0), directory.required_features);
    const sections = directory.slice();
    try t.expectEqual(@as(usize, 2), sections.len);

    try t.expectEqual(SectionKind.tran, sections[0].kind);
    try t.expectEqual(@as(u32, 40), sections[0].off);
    try t.expectEqual(@as(u32, 56), sections[0].len);
    try t.expect(sections[0].count == null);

    try t.expectEqual(SectionKind.pacm, sections[1].kind);
    try t.expectEqual(@as(u32, 96), sections[1].off);
    try t.expectEqual(@as(u32, 40), sections[1].len);
    try t.expect(sections[1].count == null);

    try t.expect(directory.find(.tran) != null);
    try t.expect(directory.find(.regs) == null);

    // The refusal out-parameter is optional.
    _ = try parseDirectory(&fixture, null);
}

test "Pacb: every prefix of the minimal fixture refuses without trapping" {
    const fixture = minimalFixture();
    var i: usize = 0;
    while (i < fixture.len) : (i += 1) {
        var refusal: Refusal = undefined;
        try t.expectError(error.Refused, parseDirectory(fixture[0..i], &refusal));
        const expected: RefusalCode = if (i < 4) .bad_magic else .directory_malformed;
        try t.expectEqual(expected, refusal.code);
    }
}

test "Pacb: header defects refuse with the named reason" {
    var buf = minimalFixture();

    putU32(&buf, 0, 0xdeadbeef);
    try expectRefusal(&buf, .bad_magic);

    buf = minimalFixture();
    putU32(&buf, 4, VERSION + 1);
    try expectRefusal(&buf, .unsupported_version);

    buf = minimalFixture();
    putU32(&buf, 8, FEATURE_PATTERN_TRACKS | (@as(u32, 1) << 31));
    try expectRefusal(&buf, .unsupported_features);

    buf = minimalFixture();
    putU32(&buf, 12, MAX_SECTIONS + 1);
    try expectRefusal(&buf, .directory_malformed);

    // Integer-extreme count: rejected before any multiplication/read.
    buf = minimalFixture();
    putU32(&buf, 12, std.math.maxInt(u32));
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: off[0] starts immediately after the directory" {
    var buf = minimalFixture();
    putU32(&buf, 20, 41);
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: overlapping sections refuse" {
    var buf = minimalFixture();
    putU32(&buf, 32, 95);
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: a gap between sections refuses" {
    var buf = minimalFixture();
    putU32(&buf, 32, 97);
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: a section overrun refuses" {
    var buf = minimalFixture();
    putU32(&buf, 36, 41);
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: reordered sections refuse" {
    var buf = minimalFixture();
    putU32(&buf, 16, @intFromEnum(SectionKind.pacm));
    putU32(&buf, 28, @intFromEnum(SectionKind.tran));
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: duplicate section ids refuse" {
    var buf = minimalFixture();
    putU32(&buf, 28, @intFromEnum(SectionKind.tran));
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: unknown section ids refuse" {
    var buf = minimalFixture();
    putU32(&buf, 28, 0x58585858);
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: trailing slack refuses" {
    const fixture = minimalFixture();
    var slack: [minimal_len + 1]u8 = @splat(0);
    @memcpy(slack[0..minimal_len], &fixture);
    try expectRefusal(&slack, .directory_malformed);
}

test "Pacb: TRAN width must be exactly 56 bytes" {
    var buf = minimalFixture();
    putU32(&buf, 24, 55);
    putU32(&buf, 32, 95);
    putU32(&buf, 36, 41);
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: integer-extreme directory offsets refuse" {
    var buf = minimalFixture();
    putU32(&buf, 20, std.math.maxInt(u32));
    try expectRefusal(&buf, .directory_malformed);

    buf = minimalFixture();
    putU32(&buf, 36, std.math.maxInt(u32));
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: count × record width must consume the section exactly" {
    var buf = allKindsFixture();
    // 'TRAK' has one 40-byte record at len 44; claiming two records
    // without growing the section must refuse.
    putU32(&buf, 308, 2);
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: a u32-maximum count is compared in u64, not wrapped" {
    var buf = allKindsFixture();
    putU32(&buf, 308, std.math.maxInt(u32));
    try expectRefusal(&buf, .directory_malformed);
}

test "Pacb: TICK count over MAX_TICK_ENTRIES refuses cap_exceeded" {
    const tick_count = MAX_TICK_ENTRIES + 1;
    const tick_len = 4 + tick_count * TICK_REC_LEN;
    const dir_end = HEADER_LEN + 3 * DIRECTORY_ENTRY_LEN;
    const tran_off = dir_end;
    const tick_off = tran_off + TRAN_REC_LEN;
    const pacm_off = tick_off + tick_len;
    const total = pacm_off + 40;

    const buf = try t.allocator.alloc(u8, total);
    defer t.allocator.free(buf);
    @memset(buf, 0);

    writeHeader(buf, 3, 0);
    writeDirEntry(buf, 0, .tran, tran_off, TRAN_REC_LEN);
    writeDirEntry(buf, 1, .tick, tick_off, tick_len);
    writeDirEntry(buf, 2, .pacm, pacm_off, 40);
    putU32(buf, tick_off, @intCast(tick_count));

    try expectRefusal(buf, .cap_exceeded);
}

const all_kinds_order = [_]SectionKind{
    .tran,
    .regs,
    .decl,
    .emit,
    .tmpo,
    .trak,
    .keys,
    .tick,
    .ease,
    .ctrl,
    .scen,
    .strs,
    .payl,
    .pacm,
};

const all_kinds_lens = [_]usize{
    56, // TRAN
    12, // REGS: byte_len 8 + zero-count PACT header 8
    8, // DECL: count 1 + one 4-byte record
    12, // EMIT: count 1 + one 8-byte record
    36, // TMPO: count 2 + two 16-byte records
    44, // TRAK: count 1 + one 40-byte record
    32, // KEYS: count 1 + one 28-byte record
    12, // TICK: count 1 + one 8-byte record
    8, // EASE: two u32 counts, no programs/refs
    64, // CTRL: count 1 + one 60-byte record
    20, // SCEN: count 1 + one 16-byte record
    8, // STRS: count 0, byte_size 0
    4, // PAYL: byte_size 0
    40, // PACM: a structurally readable header
};

// Manually derived from the canonical table: 16 + 14×12 = 184, then each
// payload length above. These literals are the independent expectation;
// the builder below derives placement by summation.
const all_kinds_offsets = [_]u32{
    184, 240, 252, 260, 272, 308, 352, 384, 396, 404, 468, 488, 496, 500,
};

const all_kinds_len = 540;

fn allKindsFixture() [all_kinds_len]u8 {
    var buf: [all_kinds_len]u8 = @splat(0);
    writeHeader(&buf, all_kinds_order.len, FEATURE_PATTERN_TRACKS);

    var pos: usize = HEADER_LEN + all_kinds_order.len * DIRECTORY_ENTRY_LEN;
    for (all_kinds_order, all_kinds_lens, 0..) |kind, len, i| {
        writeDirEntry(&buf, i, kind, pos, len);
        pos += len;
    }
    std.debug.assert(pos == all_kinds_len);

    // Count prefixes / length prefixes of the fixed and variable kinds.
    putU32(&buf, 240, 8); // REGS byte_len (zero-count PACT header)
    putU32(&buf, 252, 1); // DECL count
    putU32(&buf, 260, 1); // EMIT count
    putU32(&buf, 272, 2); // TMPO count
    putU32(&buf, 308, 1); // TRAK count
    putU32(&buf, 352, 1); // KEYS count
    putU32(&buf, 384, 1); // TICK count
    putU32(&buf, 404, 1); // CTRL count
    putU32(&buf, 468, 1); // SCEN count
    putU32(&buf, 488, 0); // STRS count
    putU32(&buf, 492, 0); // STRS byte_size
    putU32(&buf, 496, 0); // PAYL byte_size

    return buf;
}

test "Pacb: all 14 kinds keep the frozen ids, order and widths" {
    try t.expectEqual(@as(u32, 0x4e415254), @intFromEnum(SectionKind.tran));
    try t.expectEqual(@as(u32, 0x53474552), @intFromEnum(SectionKind.regs));
    try t.expectEqual(@as(u32, 0x4c434544), @intFromEnum(SectionKind.decl));
    try t.expectEqual(@as(u32, 0x54494d45), @intFromEnum(SectionKind.emit));
    try t.expectEqual(@as(u32, 0x4f504d54), @intFromEnum(SectionKind.tmpo));
    try t.expectEqual(@as(u32, 0x4b415254), @intFromEnum(SectionKind.trak));
    try t.expectEqual(@as(u32, 0x5359454b), @intFromEnum(SectionKind.keys));
    try t.expectEqual(@as(u32, 0x4b434954), @intFromEnum(SectionKind.tick));
    try t.expectEqual(@as(u32, 0x45534145), @intFromEnum(SectionKind.ease));
    try t.expectEqual(@as(u32, 0x4c525443), @intFromEnum(SectionKind.ctrl));
    try t.expectEqual(@as(u32, 0x4e454353), @intFromEnum(SectionKind.scen));
    try t.expectEqual(@as(u32, 0x53525453), @intFromEnum(SectionKind.strs));
    try t.expectEqual(@as(u32, 0x4c594150), @intFromEnum(SectionKind.payl));
    try t.expectEqual(@as(u32, 0x4d434150), @intFromEnum(SectionKind.pacm));

    try t.expectEqual(@as(usize, 14), canonical_section_order.len);
    try t.expectEqualSlices(
        SectionKind,
        &all_kinds_order,
        &canonical_section_order,
    );

    try t.expectEqual(@as(usize, 56), TRAN_REC_LEN);
    try t.expectEqual(@as(usize, 4), DECL_REC_LEN);
    try t.expectEqual(@as(usize, 8), EMIT_REC_LEN);
    try t.expectEqual(@as(usize, 16), TMPO_REC_LEN);
    try t.expectEqual(@as(usize, 40), TRAK_REC_LEN);
    try t.expectEqual(@as(usize, 28), KEYS_REC_LEN);
    try t.expectEqual(@as(usize, 8), TICK_REC_LEN);
    try t.expectEqual(@as(usize, 60), CTRL_REC_LEN);
    try t.expectEqual(@as(usize, 16), SCEN_REC_LEN);
}

test "Pacb: the all-kinds fixture exposes a complete directory view" {
    const fixture = allKindsFixture();
    const directory = try parseDirectory(&fixture, null);

    try t.expectEqual(@as(u8, 14), directory.len);
    try t.expectEqual(FEATURE_PATTERN_TRACKS, directory.required_features);

    for (
        directory.slice(),
        all_kinds_order,
        all_kinds_offsets,
        all_kinds_lens,
    ) |section, kind, off, len| {
        try t.expectEqual(kind, section.kind);
        try t.expectEqual(off, section.off);
        try t.expectEqual(len, section.len);
    }

    try t.expect(directory.find(.tran).?.count == null);
    try t.expect(directory.find(.regs).?.count == null);
    try t.expectEqual(@as(?u32, 1), directory.find(.decl).?.count);
    try t.expectEqual(@as(?u32, 1), directory.find(.emit).?.count);
    try t.expectEqual(@as(?u32, 2), directory.find(.tmpo).?.count);
    try t.expectEqual(@as(?u32, 1), directory.find(.trak).?.count);
    try t.expectEqual(@as(?u32, 1), directory.find(.keys).?.count);
    try t.expectEqual(@as(?u32, 1), directory.find(.tick).?.count);
    try t.expect(directory.find(.ease).?.count == null);
    try t.expectEqual(@as(?u32, 1), directory.find(.ctrl).?.count);
    try t.expectEqual(@as(?u32, 1), directory.find(.scen).?.count);
    try t.expect(directory.find(.strs).?.count == null);
    try t.expect(directory.find(.payl).?.count == null);
    try t.expect(directory.find(.pacm).?.count == null);
}

test "Pacb: refusal codes are u16 and append-only from birth" {
    const expected = [_][]const u8{
        "bad_magic",
        "unsupported_version",
        "unsupported_features",
        "directory_malformed",
        "count_mismatch",
        "transport_invalid",
        "tempo_invalid",
        "record_invalid",
        "key_invalid",
        "ease_invalid",
        "trigger_invalid",
        "scene_invalid",
        "control_invalid",
        "strs_invalid",
        "payload_malformed",
        "cap_exceeded",
        "registry_mismatch",
        "decl_invalid",
        "non_canonical",
        "meta_malformed",
        "meta_incoherent",
    };
    const fields = @typeInfo(RefusalCode).@"enum".fields;
    try t.expectEqual(expected.len, fields.len);
    inline for (expected, 0..) |name, i| {
        try t.expectEqualStrings(name, fields[i].name);
        try t.expectEqual(@as(u16, @intCast(i)), fields[i].value);
    }
}

test "Pacb: v1 caps are frozen and pacbWorstCase is the spec sum" {
    try t.expectEqual(@as(usize, 256 * 1024), MAX_PAYLOAD_BYTES);
    try t.expectEqual(@as(usize, 4 * 1024 * 1024), MAX_PAYL_BYTES);
    try t.expectEqual(@as(usize, 131072), MAX_TICK_ENTRIES);

    // Each extra allowance byte buys one name byte in 'REGS' and one id
    // byte in each of 'STRS' and the embedded PACM controls.
    const per_allowance_byte = MAX_TARGETS + 2 * MAX_CONTROLS;
    try t.expectEqual(
        pacbWorstCase(0) + per_allowance_byte,
        pacbWorstCase(1),
    );
    try t.expectEqual(
        pacbWorstCase(0) + 64 * per_allowance_byte,
        pacbWorstCase(64),
    );

    // Independent tool arithmetic (Python) over the frozen terms: the
    // exact totals pin every term, so a typo in a width/cap cannot hide
    // behind the growth property above.
    try t.expectEqual(@as(usize, 5_754_664), pacbWorstCase(0));
    try t.expectEqual(@as(usize, 5_828_392), pacbWorstCase(64));

    // The 'PAYL' term alone is the frozen 4 MiB cap plus its length prefix.
    try t.expect(pacbWorstCase(0) > MAX_PAYL_BYTES);
}
