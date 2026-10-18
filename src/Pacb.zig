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
//! INTERIM PHASE-2 BOUNDARY — no production use. This file currently owns
//! the container header, the directory validator, the frozen caps,
//! `pacbWorstCase`, the T2.2 transport stage (`decodeTransport`:
//! `'TRAN'`/`'TMPO'` domains, then the `TimeMap` rebuild in compile's own
//! op order), the T2.3 registry-identity stage (`decodeRegistry`:
//! `'REGS'`/`'DECL'` + the `pact_fnv` fast-reject, with
//! `canonicalPactEquals` as the load-time identity check 02's `prt_load`
//! calls), and the T2.4 record-sections stage (`decodeRecords`:
//! `'TRAK'`/`'KEYS'`/`'TICK'`/`'EMIT'`/`'SCEN'` — tracks, keys, scenes,
//! emit lanes; the id-bound consumers of the registry join for
//! `'TRAK'`/`'EMIT'` land here, `'CTRL'`'s with T2.5). Stages expose
//! owned, validated, typed results — `parseDirectory` is still a
//! structure-only view, `TransportStage.transport.emit` stays empty
//! (`RecordsStage.emit` holds the lanes until T2.8's assembly), and
//! `DecodedSource.expr`/`pattern` stay empty (payloads are T2.6's; the
//! wire spans ride `RecordsStage.payload_spans`). The whole-blob
//! `decode(...) DecodedScore` entry point is deliberately absent until
//! every section stage validates (T2.8): returning a successful score
//! before ease/controls/payloads/PACM are validated would be a lying API.
//!
//! Imports: std, sjon (`Pattern.MAX_TICK`), `PactCodec`, `TimeMap`,
//! `TrackTable` (the T2.2+T2.3+T2.4 subset of the frozen end-state list).
//! Later stages add `Easing` and `Pacm` as their GREEN needs them; this
//! file must NEVER import `Compile`, `Abi`, `Schema`, or `Driver` — the
//! one test that compares decoded transport against the compiler
//! (`decoded transport equals the compiled transport field-for-field`)
//! imports `Compile`/`test_support` INSIDE its test body only, so a
//! normal (non-test) build never analyses them through this file; that
//! textual cohabitation is the recorded plan-02 import seam, not strict
//! closure.

const std = @import("std");
const sjon = @import("sjon");
const PactCodec = @import("PactCodec.zig");
const TimeMap = @import("TimeMap.zig");
const TrackTable = @import("TrackTable.zig");

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

// ---------------------------------------------------------------------------
// T2.2 — transport stage ('TRAN' + 'TMPO')
// ---------------------------------------------------------------------------

/// `'TRAN'` flags byte: bit 0 = `dur` present, bit 1 = `:end` is loop.
pub const TRAN_FLAG_DUR: u8 = 1 << 0;
pub const TRAN_FLAG_LOOP: u8 = 1 << 1;

/// Owned transport-stage result. The `TrackTable.Transport` re-derives
/// every projection through the same calls compile uses (`TimeMap.init`,
/// `withSegments` over an arena copy of the authored table when it holds
/// more than one segment, `loop_secs = map.secondsFromTick(dur)`), so
/// nothing derived is stored on the wire. The `emit` lanes stay empty
/// here — `'EMIT'` records land in T2.4 and T2.8's `DecodedScore`
/// assembles the final transport. The raw registry fields ride `'TRAN'`
/// and are carried for the stage that owns them (T2.3); this stage does
/// not validate them.
pub const TransportStage = struct {
    arena: std.heap.ArenaAllocator,
    transport: TrackTable.Transport,
    host_targets: u32,
    declared_targets: u32,
    pact_fnv: u64,
    pacm_fnv: u64,

    pub fn deinit(self: *TransportStage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn readU64(bytes: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, bytes[at..][0..8], .little);
}

fn readI64(bytes: []const u8, at: usize) i64 {
    return std.mem.readInt(i64, bytes[at..][0..8], .little);
}

fn readF64(bytes: []const u8, at: usize) f64 {
    return @bitCast(readU64(bytes, at));
}

/// Where the payload region begins for this directory (the first
/// section's expected offset) — the diagnostic stand-in location for a
/// missing required section.
fn payloadStart(directory: *const Directory) usize {
    return HEADER_LEN + @as(usize, directory.len) * DIRECTORY_ENTRY_LEN;
}

/// Decode and validate the transport stage: `'TRAN'` domains first —
/// every `TimeMap` precondition is an assert there, so the decoder
/// checks BEFORE calling — then `'TMPO'` as the authored segment truth,
/// then the map rebuild in the documented op order. `directory` is the
/// T2.1 view of the same `bytes`; the stage never aliases `bytes`.
pub fn decodeTransport(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    directory: *const Directory,
    refusal: ?*Refusal,
) DecodeError!TransportStage {
    const tran = directory.find(.tran) orelse
        return fail(refusal, .non_canonical, payloadStart(directory));
    const tr = bytes[tran.off..][0..TRAN_REC_LEN];

    // 'TRAN' domains — before any TimeMap call (asserts, not errors).
    const flags = tr[24];
    if (flags & ~(TRAN_FLAG_DUR | TRAN_FLAG_LOOP) != 0) {
        return fail(refusal, .transport_invalid, tran.off + 24);
    }
    if (!std.mem.allEqual(u8, tr[25..32], 0)) {
        return fail(refusal, .transport_invalid, tran.off + 25);
    }
    const bpm = readF64(tr, 0);
    if (!(std.math.isFinite(bpm) and bpm >= 1 and bpm <= 1000)) {
        return fail(refusal, .transport_invalid, tran.off);
    }
    const beats_per_bar = readI64(tr, 8);
    if (!(beats_per_bar >= 1 and beats_per_bar <= 16)) {
        return fail(refusal, .transport_invalid, tran.off + 8);
    }

    const dur_present = flags & TRAN_FLAG_DUR != 0;
    const dur_field = readI64(tr, 16);
    var dur: ?TrackTable.Tick = null;
    if (dur_present) {
        if (dur_field <= 0 or dur_field > sjon.Pattern.MAX_TICK) {
            return fail(refusal, .transport_invalid, tran.off + 16);
        }
        dur = dur_field;
    } else if (dur_field != 0) {
        // The absent case is spelled 0 ("dur i64 (0 when absent)").
        return fail(refusal, .transport_invalid, tran.off + 16);
    }
    const end: TrackTable.EndBehavior = if (flags & TRAN_FLAG_LOOP != 0) .loop else .hold;
    if (end == .loop and !dur_present) {
        // Mirrors compile's loop_requires_dur — producer-impossible input.
        return fail(refusal, .transport_invalid, tran.off + 24);
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // 'TMPO': the authored segment table, validated BEFORE the rebuild —
    // withSegments' contract is asserts (ascending, [0] == {0, bpm},
    // per-segment domains), so every precondition is a checked refusal
    // here, never a trap on host bytes.
    var seg_count: usize = 0;
    if (directory.find(.tmpo)) |sec| {
        seg_count = sec.count.?; // count×width exactness is T2.1's
        if (seg_count > MAX_TEMPO_SEGMENTS) {
            return fail(refusal, .cap_exceeded, sec.off);
        }
        if (seg_count < 2) {
            // Segment 0 alone is the omitted (constant-tempo) case —
            // PACM's constant-tempo omission, spelled canonically.
            return fail(refusal, .non_canonical, sec.off);
        }
        var prev_tick: i64 = 0;
        for (0..seg_count) |i| {
            const at = sec.off + 4 + i * TMPO_REC_LEN;
            const tick = readI64(bytes, at);
            const seg_bpm = readF64(bytes, at + 8);
            if (tick > sjon.Pattern.MAX_TICK or tick < -sjon.Pattern.MAX_TICK) {
                return fail(refusal, .tempo_invalid, at);
            }
            if (i == 0) {
                if (tick != 0) return fail(refusal, .tempo_invalid, at);
                if (@as(u64, @bitCast(seg_bpm)) != @as(u64, @bitCast(bpm))) {
                    return fail(refusal, .tempo_invalid, at);
                }
            } else if (tick <= prev_tick) {
                return fail(refusal, .tempo_invalid, at);
            }
            if (!(std.math.isFinite(seg_bpm) and seg_bpm >= 1 and seg_bpm <= 1000)) {
                return fail(refusal, .tempo_invalid, at);
            }
            prev_tick = tick;
        }
    }

    const authored = a.alloc(TrackTable.TempoSegment, if (seg_count == 0) 1 else seg_count) catch
        return error.OutOfMemory;
    if (directory.find(.tmpo)) |sec| {
        for (authored, 0..) |*seg, i| {
            const at = sec.off + 4 + i * TMPO_REC_LEN;
            seg.* = .{ .start_tick = readI64(bytes, at), .bpm = readF64(bytes, at + 8) };
        }
    } else {
        authored[0] = .{ .start_tick = 0, .bpm = bpm };
    }

    // The rebuild, in compile's own op order: `TimeMap.init`, then
    // `withSegments` ONLY when the authored table holds more than one
    // segment — a ≤ 1 segment map takes the constant code path
    // verbatim, so an absent 'TMPO' and a compiled constant-tempo
    // score decode identically (the degenerate pin).
    var map = TimeMap.init(bpm, beats_per_bar);
    if (authored.len > 1) {
        const derived = a.alloc(TimeMap.Segment, authored.len) catch
            return error.OutOfMemory;
        for (derived, authored) |*d, s| {
            d.* = .{ .start_tick = s.start_tick, .bpm = s.bpm, .start_sec = undefined, .tps = undefined };
        }
        map = map.withSegments(derived);
    }

    // The seconds-domain wrap constant, computed once through the
    // rebuilt table — the same call compile makes.
    var loop_secs: ?f64 = null;
    if (dur) |d| loop_secs = map.secondsFromTick(d);

    return .{
        .arena = arena,
        .transport = .{
            .map = map,
            .dur = dur,
            .end = end,
            .emit = &.{},
            .segments = authored,
            .loop_secs = loop_secs,
        },
        .host_targets = readU32(tr, 32),
        .declared_targets = readU32(tr, 36),
        .pact_fnv = readU64(tr, 40),
        .pacm_fnv = readU64(tr, 48),
    };
}

// ---------------------------------------------------------------------------
// T2.3 — registry identity stage ('REGS' + 'DECL' + fnv fast-reject)
// ---------------------------------------------------------------------------

/// The 4-byte `'DECL'` record's semantic fields (the wire pad is zero and
/// checked, never carried). Pinned here so T2.3 decode and the T3.1
/// encoder agree on the record's shape (critique G13).
pub const Decl = struct { registry: u8, ncomp: u8 };

/// Owned registry-identity stage result. `regs` is a DEEP, arena-owned
/// copy of the canonical registry identity bytes and `declared` the
/// `'DECL'` records — the borrow-vs-own contract until T2.8's final
/// `DecodedScore` arena carries them; the stage never aliases the input
/// buffer. When `'REGS'` is absent the identity IS the zero-count
/// `'PACT'` spelling (the canonical-presence rule), so `regs` carries
/// those 8 bytes — `canonicalPactEquals(host_blob, stage.regs)` is then
/// the uniform load-time check for every score, absent section or not.
pub const RegistryStage = struct {
    arena: std.heap.ArenaAllocator,
    regs: []const u8,
    declared: []const Decl,
    host_targets: u32,
    declared_targets: u32,
    pact_fnv: u64,

    pub fn deinit(self: *RegistryStage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// FNV-1a-64 over bytes — the `'TRAN'` checksum family. Private: the
/// encoder (T3.1) owns the public `fnv1a64` spelling; this is the
/// decoder-side use of the same std hash.
fn fnv1a64(bytes: []const u8) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(bytes);
    return h.final();
}

/// Canonical registry identity — the function 02's `prt_load` calls
/// against the runtime host blob: would the canonical re-encoding of
/// `host_blob` byte-equal `regs`? Spelled as a lockstep structural walk
/// of both blobs, which is exactly the decode→re-encode→compare
/// predicate with no allocation and no scratch: a `'PACT'` record has
/// exactly one byte spelling, so the canonical bytes of `host_blob`'s
/// decoded content equal `regs` iff the walk matches end to end (the
/// same magic, the same count, every record byte-for-byte, both ending
/// exactly at their ends). Validates `host_blob`'s decodability along
/// the way (magic, per-record domains, exact end) — a corrupt host blob
/// is never equal to anything. Pure identity: caps and checksums are
/// decode-side policy and never consulted here.
pub fn canonicalPactEquals(host_blob: []const u8, regs: []const u8) bool {
    if (host_blob.len < PactCodec.TARGETS_HEADER_LEN) return false;
    if (regs.len < PactCodec.TARGETS_HEADER_LEN) return false;
    if (std.mem.readInt(u32, host_blob[0..4], .little) != PactCodec.TARGETS_MAGIC) return false;
    // The canonical re-encoding's header (magic + count) must agree.
    if (!std.mem.eql(u8, host_blob[0..PactCodec.TARGETS_HEADER_LEN], regs[0..PactCodec.TARGETS_HEADER_LEN])) return false;

    const count = std.mem.readInt(u32, host_blob[4..8], .little);
    var hp: usize = PactCodec.TARGETS_HEADER_LEN;
    var rp: usize = PactCodec.TARGETS_HEADER_LEN;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        // `PactCodec.decodeTargets`' own per-record rules.
        if (host_blob.len - hp < 4) return false;
        const ncomp = host_blob[hp];
        if (ncomp < 1 or ncomp > 4) return false;
        const name_len: usize = std.mem.readInt(u16, host_blob[hp + 2 ..][0..2], .little);
        if (name_len == 0) return false;

        // The canonical record head and name bytes, compared in place.
        if (regs.len - rp < 4) return false;
        if (!std.mem.eql(u8, host_blob[hp..][0..4], regs[rp..][0..4])) return false;
        hp += 4;
        rp += 4;
        if (host_blob.len - hp < name_len) return false;
        if (regs.len - rp < name_len) return false;
        if (!std.mem.eql(u8, host_blob[hp..][0..name_len], regs[rp..][0..name_len])) return false;
        hp += name_len;
        rp += name_len;
    }
    return hp == host_blob.len and rp == regs.len;
}

/// Decode and validate the registry identity stage: `'REGS'` (byte
/// equality of the canonical `'PACT'` encoding IS the identity; the
/// `'TRAN'` `pact_fnv` is a fast-reject + diagnostic checksum only, and
/// must agree with the bytes), the zero-count spelling when `'REGS'` is
/// absent, and the `'DECL'` record table against `'TRAN'`'s
/// `declared_targets`. The `'TRAK'`/`'CTRL'`/`'EMIT'` consumers of the
/// id bound land with their sections (T2.4/T2.5).
pub fn decodeRegistry(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    directory: *const Directory,
    refusal: ?*Refusal,
) DecodeError!RegistryStage {
    const tran = directory.find(.tran) orelse
        return fail(refusal, .non_canonical, payloadStart(directory));
    const tr = bytes[tran.off..][0..TRAN_REC_LEN];
    const host_targets = readU32(tr, 32);
    const declared_targets = readU32(tr, 36);
    const pact_fnv = readU64(tr, 40);

    // The join bound: host + declared targets can never exceed the
    // codec leaf's cap (THE definition, `PactCodec.MAX_TARGETS`).
    if (@as(u64, host_targets) + @as(u64, declared_targets) > MAX_TARGETS) {
        return fail(refusal, .cap_exceeded, tran.off + 36);
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var regs: []const u8 = &.{};
    if (directory.find(.regs)) |sec| {
        const payload = bytes[sec.off..][0..sec.len];
        if (payload.len < 4) {
            return fail(refusal, .registry_mismatch, sec.off);
        }
        const byte_len = readU32(payload, 0);
        if (@as(usize, byte_len) != payload.len - 4) {
            return fail(refusal, .registry_mismatch, sec.off);
        }
        const pact = payload[4..];
        // The section must be the canonical encoding of its own decoded
        // content: a 'PACT' record has exactly one byte spelling, so
        // this self-compare IS decode → re-encode → byte-compare (it
        // also proves the magic, per-record domains, and exact end).
        if (!canonicalPactEquals(pact, pact)) {
            return fail(refusal, .registry_mismatch, sec.off);
        }
        const count = std.mem.readInt(u32, pact[4..8], .little);
        if (count < 1) {
            // The zero-count join is the omitted case — an empty host
            // join must not spell a present section.
            return fail(refusal, .non_canonical, sec.off);
        }
        if (count != host_targets) {
            return fail(refusal, .count_mismatch, sec.off);
        }
        // Fast-reject + diagnostic checksum: byte equality above is the
        // identity; the checksum must merely agree with the bytes.
        if (fnv1a64(pact) != pact_fnv) {
            return fail(refusal, .registry_mismatch, sec.off);
        }
        regs = a.dupe(u8, pact) catch return error.OutOfMemory;
    } else {
        if (host_targets != 0) {
            return fail(refusal, .non_canonical, tran.off + 32);
        }
        // The fast-reject stays well-defined over the 8-B zero-count
        // 'PACT' — the identity an empty host join must spell.
        var zero_pact: [PactCodec.TARGETS_HEADER_LEN]u8 = undefined;
        std.mem.writeInt(u32, zero_pact[0..4], PactCodec.TARGETS_MAGIC, .little);
        std.mem.writeInt(u32, zero_pact[4..8], 0, .little);
        if (fnv1a64(&zero_pact) != pact_fnv) {
            return fail(refusal, .registry_mismatch, tran.off + 40);
        }
        regs = a.dupe(u8, &zero_pact) catch return error.OutOfMemory;
    }

    var declared: []const Decl = &.{};
    if (directory.find(.decl)) |sec| {
        const count: usize = sec.count.?; // count×width exactness is T2.1's
        if (count != declared_targets) {
            return fail(refusal, .count_mismatch, sec.off);
        }
        const records = a.alloc(Decl, count) catch return error.OutOfMemory;
        for (records, 0..) |*rec, i| {
            const at = sec.off + 4 + i * DECL_REC_LEN;
            rec.* = .{ .registry = bytes[at], .ncomp = bytes[at + 1] };
            const pad = std.mem.readInt(u16, bytes[at + 2 ..][0..2], .little);
            if (pad != 0) {
                return fail(refusal, .decl_invalid, at + 2);
            }
            if (rec.ncomp < 1 or rec.ncomp > 4) {
                return fail(refusal, .decl_invalid, at + 1);
            }
        }
        declared = records;
    } else if (declared_targets != 0) {
        // An absent 'DECL' is the zero-declared spelling.
        return fail(refusal, .count_mismatch, tran.off + 36);
    }

    return .{
        .arena = arena,
        .regs = regs,
        .declared = declared,
        .host_targets = host_targets,
        .declared_targets = declared_targets,
        .pact_fnv = pact_fnv,
    };
}

// ---------------------------------------------------------------------------
// T2.4 — record sections stage ('TRAK' + 'KEYS' + 'TICK' + 'EMIT' + 'SCEN')
// ---------------------------------------------------------------------------

/// Frozen `source` ordinals — copied constants, not a live reference to
/// `'PACM'`'s `MetaTrackRec` values (`src/Abi.zig:36-39`);
/// `src/root.zig` equality-asserts the copy against `Abi.TrackSourceKind`.
pub const SOURCE_KEYS: u8 = 0;
pub const SOURCE_EXPR: u8 = 1;
pub const SOURCE_TRIGGER: u8 = 2;
pub const SOURCE_PATTERN: u8 = 3;

/// Frozen `trig_kind` ordinals (0 periodic, 1 explicit), wire-stable with
/// `TrackTable.Trigger`'s tag order; also asserted in `src/root.zig`.
pub const TRIG_PERIODIC: u8 = 0;
pub const TRIG_EXPLICIT: u8 = 1;

/// One `(scene …)` window, decoder-side: the span-carrying field of
/// `TrackTable.Scene` never crosses the wire (§A O-a), so this is the
/// whole 16-byte `'SCEN'` record.
pub const DecodedScene = struct { start_tick: i64, dur_ticks: i64 };

/// A track's value source, decoder-side (frozen for the wave, §A O-a —
/// do NOT "upgrade" to `TrackTable.Source`, whose expr/pattern arms hold
/// AST indexes into a tree this side never has). The `keys` arm's run
/// indexes `RecordsStage.keys`; the `trigger` arm mirrors
/// `TrackTable.Trigger` verbatim, its `.at` schedule an arena copy of
/// the track's `'TICK'` slice. The `expr`/`pattern` arms carry the
/// track's `'PAYL'` bytes — EMPTY at this stage: payload validation and
/// copies are T2.6's; until then `RecordsStage.payload_spans` carries
/// the wire slice for that consumer.
pub const DecodedSource = union(enum) {
    keys: struct { start: u32, len: u32 },
    expr: []const u8,
    trigger: TrackTable.Trigger,
    pattern: []const u8,
};

/// One `'TRAK'` row (frozen representation, T2.1).
pub const DecodedTrack = struct {
    target_id: u16,
    registry: u8,
    ncomp: u8,
    scene: u16,
    source: DecodedSource,
};

/// A payload slice exactly as the `'TRAK'` record spells it — the T2.4
/// carry for the T2.6 `'PAYL'` consumer, which owns its bounds check and
/// its arena copy.
pub const PayloadSpan = struct { off: u32, len: u32 };

/// Owned record-sections stage result. Everything it returns lives in
/// its arena — never a pointer into the input buffer, never a dangling
/// local — until T2.8's final `DecodedScore` arena carries it all.
pub const RecordsStage = struct {
    arena: std.heap.ArenaAllocator,
    tracks: []const DecodedTrack,
    keys: []const TrackTable.Key,
    scenes: []const DecodedScene,
    /// `'EMIT'` lanes in document (section) order — what T2.8 folds into
    /// the decoded transport (`TransportStage.transport.emit` stays
    /// empty; this stage owns the lanes).
    emit: []const TrackTable.EmitLane,
    /// Parallel to `tracks`; meaningful only for expr/pattern sources.
    payload_spans: []const PayloadSpan,

    pub fn deinit(self: *RecordsStage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readF32(bytes: []const u8, at: usize) f32 {
    return @bitCast(readU32(bytes, at));
}

/// Bounds-defended section payload view. Every stage documents that
/// `directory` is `parseDirectory`'s view of the SAME `bytes`; this
/// guard keeps a mismatched caller buffer a refusal instead of a panic —
/// decode never traps, even on API misuse.
fn sectionPayload(bytes: []const u8, section: *const Section, refusal: ?*Refusal) DecodeError![]const u8 {
    if (section.off > bytes.len or section.len > bytes.len - section.off) {
        return fail(refusal, .directory_malformed, section.off);
    }
    return bytes[section.off..][0..section.len];
}

const JoinEntry = struct { registry: u8, ncomp: u8 };

/// The `(registry, ncomp)` of join entry `id` — host entries walked out
/// of the registry stage's owned canonical `'PACT'` bytes (the names live
/// there; identity is T2.3's byte compare, this is the triple lookup),
/// declared entries from its `'DECL'` records. The caller has proven
/// `id < host + declared`; the walk bounds-guards itself anyway, so even
/// a mismatched stage argument is a null, never a trap.
fn joinEntry(registry: *const RegistryStage, id: u16) ?JoinEntry {
    if (id < registry.host_targets) {
        var p: usize = PactCodec.TARGETS_HEADER_LEN;
        var i: u32 = 0;
        while (i < id) : (i += 1) {
            if (registry.regs.len - p < 4) return null;
            const name_len: usize = std.mem.readInt(u16, registry.regs[p + 2 ..][0..2], .little);
            if (registry.regs.len - p < 4 + name_len) return null;
            p += 4 + name_len;
        }
        if (registry.regs.len - p < 4) return null;
        return .{ .ncomp = registry.regs[p], .registry = registry.regs[p + 1] };
    }
    const decl_id = @as(usize, id) - registry.host_targets;
    if (decl_id >= registry.declared.len) return null;
    const rec = registry.declared[decl_id];
    return .{ .ncomp = rec.ncomp, .registry = rec.registry };
}

/// Decode and validate the record sections. PRECONDITIONS: `directory`
/// is `parseDirectory(bytes, …)`'s result and `registry` is
/// `decodeRegistry(…, bytes, &directory, …)`'s result for those same
/// `bytes` (the stage reads `'TRAK'` join bindings through it); the
/// section-payload guard above turns a mismatched pair into a refusal,
/// never a trap. Validation, in order: counts over caps; canonical
/// presence (a present section here is never degenerate); the
/// `'KEYS'`/`'TICK'` iff-consumers cross-check; per-record domains —
/// source/trig_kind/ncomp ordinals, the registry join bound + the exact
/// `(registry, ncomp)` triple of the joined entry (host join from
/// `'REGS'` bytes, declared from `'DECL'` records), `scene` `NO_SCENE`
/// or `< 'SCEN'` count (G10), per-source unused-field zero slack —
/// key runs (≥ 1 key, strictly ascending, lanes ≥ ncomp zero,
/// slice-bounded) and trigger schedules (periodic `every > 0`;
/// explicit non-empty, strictly ascending, `|tick| ≤ MAX_TICK`,
/// slice-bounded, and non-overlapping — the section is the
/// concatenation of every schedule); scene window ends checked-added;
/// `'EMIT'` lane ordinals ≤ 4, unique (G10), reserved zero, joined.
/// `'KEYS'` `ease_ref` is checked against the synthesized linear default
/// when `'EASE'` is absent (T2.5 owns the real-table bound); `'EASE'`,
/// `'CTRL'`, `'STRS'` and `'PAYL'` are later stages' sections.
pub fn decodeRecords(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    directory: *const Directory,
    registry: *const RegistryStage,
    refusal: ?*Refusal,
) DecodeError!RecordsStage {
    const trak_sec = directory.find(.trak);
    const keys_sec = directory.find(.keys);
    const tick_sec = directory.find(.tick);
    const emit_sec = directory.find(.emit);
    const scen_sec = directory.find(.scen);
    const ease_present = directory.find(.ease) != null;

    // Counts over caps ('TICK''s cap is the T2.1 directory check —
    // count×width exactness first, then ≤ MAX_TICK_ENTRIES).
    if (trak_sec) |s| {
        if (s.count.? > MAX_TRACKS) return fail(refusal, .cap_exceeded, s.off);
    }
    if (keys_sec) |s| {
        if (s.count.? > MAX_KEYS) return fail(refusal, .cap_exceeded, s.off);
    }
    if (scen_sec) |s| {
        if (s.count.? > MAX_SCENES) return fail(refusal, .cap_exceeded, s.off);
    }
    if (emit_sec) |s| {
        // The EmitName field-count ceiling `Eval` asserts (G10).
        if (s.count.? > EMIT_LANE_CAP) return fail(refusal, .cap_exceeded, s.off);
    }

    // Canonical presence: a present record section is never degenerate
    // (the zero case is the omitted section).
    inline for (.{ trak_sec, keys_sec, tick_sec, emit_sec, scen_sec }) |maybe| {
        if (maybe) |s| {
            if (s.count.? == 0) return fail(refusal, .non_canonical, s.off);
        }
    }

    // Cross-section presence is CHECKED, not implied: 'KEYS' iff a keys
    // track exists, 'TICK' iff an explicit-trigger track does. The
    // pre-scan reads only the source/trig_kind bytes — validating those
    // two ordinals first (shape before cross-section coherence) so a
    // corrupt ordinal never misreports as a presence contradiction.
    const trak_count: usize = if (trak_sec) |s| s.count.? else 0;
    var has_keys_track = false;
    var has_explicit = false;
    if (trak_sec) |s| {
        _ = try sectionPayload(bytes, s, refusal);
        for (0..trak_count) |i| {
            const at = s.off + 4 + i * TRAK_REC_LEN;
            const src = bytes[at + 4];
            const kind = bytes[at + 5];
            if (src > SOURCE_PATTERN) {
                return fail(refusal, .record_invalid, at + 4);
            }
            if (kind > TRIG_EXPLICIT) {
                return fail(refusal, .record_invalid, at + 5);
            }
            if (src == SOURCE_KEYS) {
                has_keys_track = true;
            } else if (src == SOURCE_TRIGGER and kind == TRIG_EXPLICIT) {
                has_explicit = true;
            }
        }
    }
    if ((keys_sec != null) != has_keys_track) {
        return fail(refusal, .non_canonical, if (keys_sec) |s| s.off else payloadStart(directory));
    }
    if ((tick_sec != null) != has_explicit) {
        return fail(refusal, .non_canonical, if (tick_sec) |s| s.off else payloadStart(directory));
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const scen_count: usize = if (scen_sec) |s| s.count.? else 0;
    var scenes: []const DecodedScene = &.{};
    if (scen_sec) |s| {
        _ = try sectionPayload(bytes, s, refusal);
        const recs = a.alloc(DecodedScene, scen_count) catch return error.OutOfMemory;
        for (recs, 0..) |*rec, i| {
            const at = s.off + 4 + i * SCEN_REC_LEN;
            const start = readI64(bytes, at);
            const dur = readI64(bytes, at + 8);
            // The window end is the one check compile makes of the pair
            // (`tick_overflow`); decode refuses the same class. Grid
            // bounds on the individual fields are producer consequences
            // (`posToTick*`), not compile asserts — not re-derived here.
            _ = std.math.add(i64, start, dur) catch
                return fail(refusal, .scene_invalid, at);
            rec.* = .{ .start_tick = start, .dur_ticks = dur };
        }
        scenes = recs;
    }

    const keys_count: usize = if (keys_sec) |s| s.count.? else 0;
    var keys: []const TrackTable.Key = &.{};
    if (keys_sec) |s| {
        _ = try sectionPayload(bytes, s, refusal);
        const recs = a.alloc(TrackTable.Key, keys_count) catch return error.OutOfMemory;
        for (recs, 0..) |*rec, i| {
            const at = s.off + 4 + i * KEYS_REC_LEN;
            if (readU16(bytes, at + 26) != 0) {
                return fail(refusal, .record_invalid, at + 26);
            }
            const ease_ref = readU16(bytes, at + 24);
            if (!ease_present and ease_ref != 0) {
                // 'EASE' absent ⇒ the program table is the synthesized
                // linear default alone; any other index dangles. (T2.5
                // owns the bound against the real table.)
                return fail(refusal, .ease_invalid, at + 24);
            }
            rec.* = .{
                .at = readI64(bytes, at),
                .value = .{
                    readF32(bytes, at + 8),
                    readF32(bytes, at + 12),
                    readF32(bytes, at + 16),
                    readF32(bytes, at + 20),
                },
                .ease_ref = ease_ref,
            };
        }
        keys = recs;
    }

    const tick_count: usize = if (tick_sec) |s| s.count.? else 0;
    if (tick_sec) |s| _ = try sectionPayload(bytes, s, refusal);

    const tracks = a.alloc(DecodedTrack, trak_count) catch return error.OutOfMemory;
    const spans = a.alloc(PayloadSpan, trak_count) catch return error.OutOfMemory;
    // The join bound every target_id is held against; `joinEntry` turns
    // an id inside it into the exact (registry, ncomp) triple.
    const join_size: u64 = @as(u64, registry.host_targets) + registry.declared_targets;
    // 'TICK' is the concatenation of every explicit schedule: slices in
    // track order never overlap (each new slice starts at or after the
    // previous one's end).
    var prev_tick_end: ?u64 = null;
    if (trak_sec) |s| {
        for (0..trak_count) |i| {
            const at = s.off + 4 + i * TRAK_REC_LEN;
            const target_id = readU16(bytes, at);
            const trak_registry = bytes[at + 2];
            const ncomp = bytes[at + 3];
            const source = bytes[at + 4];
            const trig_kind = bytes[at + 5];
            const scene = readU16(bytes, at + 6);
            const key_start = readU32(bytes, at + 8);
            const key_len = readU32(bytes, at + 12);
            const payload_off = readU32(bytes, at + 16);
            const payload_len = readU32(bytes, at + 20);
            const trig_every = readI64(bytes, at + 24);
            const trig_offset = readI64(bytes, at + 32);

            // source/trig_kind ordinals were validated by the pre-scan
            // (shape before cross-section coherence); ncomp rides here.
            if (ncomp < 1 or ncomp > 4) {
                return fail(refusal, .record_invalid, at + 3);
            }

            // Registry binding: the id is inside the join, and the
            // record's (registry, ncomp) is the joined entry's exact
            // triple — host join ('REGS' names) or 'DECL' record.
            if (@as(u64, target_id) >= join_size) {
                return fail(refusal, .registry_mismatch, at);
            }
            const entry = joinEntry(registry, target_id) orelse
                return fail(refusal, .registry_mismatch, at);
            if (entry.registry != trak_registry or entry.ncomp != ncomp) {
                return fail(refusal, .registry_mismatch, at + 2);
            }

            // `scene`: NO_SCENE or a valid index into THIS 'SCEN' table
            // (the table invariant; the count is cap-checked above, so
            // this subsumes MAX_SCENES — G10).
            if (scene != TrackTable.NO_SCENE and @as(usize, scene) >= scen_count) {
                return fail(refusal, .scene_invalid, at + 6);
            }

            var track: DecodedTrack = .{
                .target_id = target_id,
                .registry = trak_registry,
                .ncomp = ncomp,
                .scene = scene,
                .source = undefined,
            };
            spans[i] = .{ .off = 0, .len = 0 };

            switch (source) {
                SOURCE_KEYS => {
                    // Unused-by-source fields must be zero.
                    if (trig_every != 0) return fail(refusal, .record_invalid, at + 24);
                    if (trig_offset != 0) return fail(refusal, .record_invalid, at + 32);
                    if (payload_off != 0) return fail(refusal, .record_invalid, at + 16);
                    if (payload_len != 0) return fail(refusal, .record_invalid, at + 20);
                    if (key_len < 1) {
                        return fail(refusal, .key_invalid, at + 12);
                    }
                    const run_end = @as(u64, key_start) + key_len;
                    if (run_end > keys_count) {
                        return fail(refusal, .key_invalid, at + 8);
                    }
                    const run = keys[@intCast(key_start)..][0..@intCast(key_len)];
                    for (run, 0..) |key, k| {
                        const key_at = keys_sec.?.off + 4 + (@as(usize, key_start) + k) * KEYS_REC_LEN;
                        if (k > 0 and key.at <= run[k - 1].at) {
                            return fail(refusal, .key_invalid, key_at);
                        }
                        var lane: usize = ncomp;
                        while (lane < 4) : (lane += 1) {
                            if (key.value[lane] != 0) {
                                return fail(refusal, .key_invalid, key_at + 8 + lane * 4);
                            }
                        }
                    }
                    track.source = .{ .keys = .{ .start = key_start, .len = key_len } };
                },
                SOURCE_EXPR, SOURCE_PATTERN => {
                    if (trig_every != 0) return fail(refusal, .record_invalid, at + 24);
                    if (trig_offset != 0) return fail(refusal, .record_invalid, at + 32);
                    if (key_start != 0) return fail(refusal, .record_invalid, at + 8);
                    if (key_len != 0) return fail(refusal, .record_invalid, at + 12);
                    spans[i] = .{ .off = payload_off, .len = payload_len };
                    track.source = if (source == SOURCE_EXPR) .{ .expr = &.{} } else .{ .pattern = &.{} };
                },
                SOURCE_TRIGGER => {
                    if (payload_off != 0) return fail(refusal, .record_invalid, at + 16);
                    if (payload_len != 0) return fail(refusal, .record_invalid, at + 20);
                    if (trig_kind == TRIG_PERIODIC) {
                        if (key_start != 0) return fail(refusal, .record_invalid, at + 8);
                        if (key_len != 0) return fail(refusal, .record_invalid, at + 12);
                        // The compile rule: a positive interval.
                        if (trig_every <= 0) {
                            return fail(refusal, .trigger_invalid, at + 24);
                        }
                        track.source = .{ .trigger = .{ .periodic = .{
                            .every = trig_every,
                            .offset = trig_offset,
                        } } };
                    } else {
                        if (trig_every != 0) return fail(refusal, .record_invalid, at + 24);
                        if (trig_offset != 0) return fail(refusal, .record_invalid, at + 32);
                        if (key_len < 1) {
                            return fail(refusal, .trigger_invalid, at + 12);
                        }
                        const run_end = @as(u64, key_start) + key_len;
                        if (run_end > tick_count) {
                            return fail(refusal, .trigger_invalid, at + 8);
                        }
                        if (prev_tick_end) |end| {
                            if (key_start < end) {
                                return fail(refusal, .trigger_invalid, at + 8);
                            }
                        }
                        prev_tick_end = run_end;
                        const sched = a.alloc(TrackTable.Tick, @intCast(key_len)) catch
                            return error.OutOfMemory;
                        for (sched, 0..) |*slot, k| {
                            const tick_at = tick_sec.?.off + 4 + (@as(usize, key_start) + k) * TICK_REC_LEN;
                            const tick = readI64(bytes, tick_at);
                            if (k > 0 and tick <= sched[k - 1]) {
                                return fail(refusal, .trigger_invalid, tick_at);
                            }
                            if (tick > sjon.Pattern.MAX_TICK or tick < -sjon.Pattern.MAX_TICK) {
                                return fail(refusal, .trigger_invalid, tick_at);
                            }
                            slot.* = tick;
                        }
                        track.source = .{ .trigger = .{ .at = sched } };
                    }
                },
                else => unreachable, // source ≤ SOURCE_PATTERN checked above
            }
            tracks[i] = track;
        }
    }

    var emit: []const TrackTable.EmitLane = &.{};
    if (emit_sec) |s| {
        _ = try sectionPayload(bytes, s, refusal);
        const lanes = a.alloc(TrackTable.EmitLane, s.count.?) catch return error.OutOfMemory;
        var seen: u8 = 0; // one bit per EmitName ordinal (count ≤ 5 here)
        for (lanes, 0..) |*lane, i| {
            const at = s.off + 4 + i * EMIT_REC_LEN;
            if (readU32(bytes, at + 4) != 0) {
                return fail(refusal, .record_invalid, at + 4);
            }
            const name = std.enums.fromInt(TrackTable.EmitName, bytes[at]) orelse
                return fail(refusal, .record_invalid, at);
            // Lane uniqueness is compile-enforced and `Eval` leans on it
            // (src/Eval.zig:184-186) — decode proves it (G10).
            const bit = @as(u8, 1) << @as(u3, @intCast(bytes[at]));
            if (seen & bit != 0) {
                return fail(refusal, .record_invalid, at);
            }
            seen |= bit;
            const target_id = readU16(bytes, at + 2);
            if (@as(u64, target_id) >= join_size) {
                return fail(refusal, .registry_mismatch, at + 2);
            }
            const entry = joinEntry(registry, target_id) orelse
                return fail(refusal, .registry_mismatch, at + 2);
            if (entry.registry != bytes[at + 1]) {
                return fail(refusal, .registry_mismatch, at + 1);
            }
            lane.* = .{
                .name = name,
                .target_id = target_id,
                .registry = bytes[at + 1],
            };
        }
        emit = lanes;
    }

    return .{
        .arena = arena,
        .tracks = tracks,
        .keys = keys,
        .scenes = scenes,
        .emit = emit,
        .payload_spans = spans,
    };
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

// ---------------------------------------------------------------------------
// T2.2 — transport stage tests ('TRAN' + 'TMPO')
// ---------------------------------------------------------------------------

fn putU8(buf: []u8, at: usize, value: u8) void {
    buf[at] = value;
}

fn putI64(buf: []u8, at: usize, value: i64) void {
    std.mem.writeInt(i64, buf[at..][0..8], value, .little);
}

fn putF64(buf: []u8, at: usize, value: f64) void {
    std.mem.writeInt(u64, buf[at..][0..8], @bitCast(value), .little);
}

fn putU64(buf: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, buf[at..][0..8], value, .little);
}

/// One authored `'TMPO'` record as the section spells it.
const TmpoRec = struct { tick: i64, bpm: f64 };

/// The `'TRAN'` record's semantic content (56-B layout in the module
/// header: bpm f64, beats_per_bar i64, dur i64, flags u8 + pad×7,
/// host_targets u32, declared_targets u32, pact_fnv u64, pacm_fnv u64).
const TransportSpec = struct {
    bpm: f64 = 120,
    beats_per_bar: i64 = 4,
    dur: ?i64 = null,
    end_loop: bool = false,
    host_targets: u32 = 0,
    declared_targets: u32 = 0,
    pact_fnv: u64 = 0,
    pacm_fnv: u64 = 0,
};

fn writeTranRecord(buf: []u8, at: usize, spec: TransportSpec) void {
    putF64(buf, at, spec.bpm);
    putI64(buf, at + 8, spec.beats_per_bar);
    putI64(buf, at + 16, spec.dur orelse 0);
    var flags: u8 = 0;
    if (spec.dur != null) flags |= 1 << 0;
    if (spec.end_loop) flags |= 1 << 1;
    putU8(buf, at + 24, flags); // pads at +25..+32 stay zero
    putU32(buf, at + 32, spec.host_targets);
    putU32(buf, at + 36, spec.declared_targets);
    putU64(buf, at + 40, spec.pact_fnv);
    putU64(buf, at + 48, spec.pacm_fnv);
}

/// The plan's shared per-subgroup fixture builder, grown for T2.2: a
/// minimal valid `'PACB'` carrying `'TRAN'`, an optional `'TMPO'`, and
/// a 40-byte zeroed `'PACM'` tail (its content is unchecked until
/// T2.7/T2.8). Offsets are derived by summation; one mutation is
/// applied per test after building.
fn buildTransportFixture(
    alloc: std.mem.Allocator,
    spec: TransportSpec,
    tmpo: []const TmpoRec,
) ![]u8 {
    const has_tmpo = tmpo.len > 0;
    const n: usize = 2 + @as(usize, @intFromBool(has_tmpo));
    const dir_end = HEADER_LEN + n * DIRECTORY_ENTRY_LEN;
    const tran_off = dir_end;
    const tmpo_off = tran_off + TRAN_REC_LEN;
    const tmpo_len: usize = if (has_tmpo) 4 + tmpo.len * TMPO_REC_LEN else 0;
    const pacm_off = tmpo_off + tmpo_len;
    const pacm_len: usize = 40;

    const buf = try alloc.alloc(u8, pacm_off + pacm_len);
    @memset(buf, 0);
    writeHeader(buf, n, 0);
    writeDirEntry(buf, 0, .tran, tran_off, TRAN_REC_LEN);
    if (has_tmpo) {
        writeDirEntry(buf, 1, .tmpo, tmpo_off, tmpo_len);
        putU32(buf, tmpo_off, @intCast(tmpo.len));
        for (tmpo, 0..) |rec, i| {
            const at = tmpo_off + 4 + i * TMPO_REC_LEN;
            putI64(buf, at, rec.tick);
            putF64(buf, at + 8, rec.bpm);
        }
    }
    writeDirEntry(buf, n - 1, .pacm, pacm_off, pacm_len);
    writeTranRecord(buf, tran_off, spec);
    return buf;
}

/// 120 bpm doubling to 240 at tick 720720 — the two-segment reference.
const default_tmpo = [_]TmpoRec{
    .{ .tick = 0, .bpm = 120 },
    .{ .tick = 720720, .bpm = 240 },
};

/// Offset of `'TRAN'`'s payload in a TRAN+TMPO+PACM fixture.
const fixture_tran_at = HEADER_LEN + 3 * DIRECTORY_ENTRY_LEN;
/// Offset of `'TMPO'`'s payload in a TRAN+TMPO+PACM fixture.
const fixture_tmpo_at = fixture_tran_at + TRAN_REC_LEN;

fn expectTransportRefusal(bytes: []const u8, code: RefusalCode) !void {
    var refusal: Refusal = undefined;
    const directory = try parseDirectory(bytes, null);
    const decoded = decodeTransport(t.allocator, bytes, &directory, &refusal);
    if (decoded) |payload| {
        var stage = payload;
        stage.deinit();
        return error.WronglyAccepted;
    } else |err| {
        try t.expectEqual(error.Refused, err);
        try t.expectEqual(code, refusal.code);
    }
}

test "Pacb: TRAN bpm outside the finite 1..1000 domain refuses transport_invalid" {
    const bad = [_]f64{
        std.math.nan(f64),
        std.math.inf(f64),
        -std.math.inf(f64),
        0,
        0.5,
        1001,
    };
    for (bad) |bpm| {
        const buf = try buildTransportFixture(t.allocator, .{ .bpm = bpm }, &.{});
        defer t.allocator.free(buf);
        try expectTransportRefusal(buf, .transport_invalid);
    }
}

test "Pacb: TRAN beats_per_bar outside 1..16 refuses transport_invalid" {
    for ([_]i64{ 0, -1, 17 }) |bpb| {
        const buf = try buildTransportFixture(
            t.allocator,
            .{ .beats_per_bar = bpb },
            &.{},
        );
        defer t.allocator.free(buf);
        try expectTransportRefusal(buf, .transport_invalid);
    }
}

test "Pacb: a set dur flag with a non-positive dur refuses transport_invalid" {
    for ([_]i64{ 0, -720720 }) |dur| {
        const buf = try buildTransportFixture(t.allocator, .{ .dur = dur }, &.{});
        defer t.allocator.free(buf);
        try expectTransportRefusal(buf, .transport_invalid);
    }
}

test "Pacb: unknown TRAN flag bits and non-zero pads refuse transport_invalid" {
    {
        const buf = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
        defer t.allocator.free(buf);
        putU8(buf, fixture_tran_at + 24, 0b100); // reserved bit 2
        try expectTransportRefusal(buf, .transport_invalid);
    }
    {
        const buf = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
        defer t.allocator.free(buf);
        putU8(buf, fixture_tran_at + 31, 1); // a pad byte
        try expectTransportRefusal(buf, .transport_invalid);
    }
}

test "Pacb: a clear dur flag requires a zero dur field" {
    // The absent case is spelled 0 ("dur i64 (0 when absent)"); a
    // non-zero field behind a clear flag is a lie no producer writes.
    const buf = try buildTransportFixture(t.allocator, .{}, &.{});
    defer t.allocator.free(buf);
    putI64(buf, fixture_tran_at - 12 + 16, 42);
    try expectTransportRefusal(buf, .transport_invalid);
}

test "Pacb: end loop without dur refuses transport_invalid" {
    // Mirrors compile's loop_requires_dur: :end loop requires :dur. A
    // PACB spelling loop-without-dur is producer-impossible input.
    const buf = try buildTransportFixture(t.allocator, .{ .end_loop = true }, &.{});
    defer t.allocator.free(buf);
    try expectTransportRefusal(buf, .transport_invalid);
}

test "Pacb: TMPO with fewer than two segments refuses non_canonical" {
    const one = [_]TmpoRec{.{ .tick = 0, .bpm = 120 }};
    const buf = try buildTransportFixture(t.allocator, .{}, &one);
    defer t.allocator.free(buf);
    try expectTransportRefusal(buf, .non_canonical);
}

test "Pacb: TMPO segment 0 must be tick 0 at the TRAN bpm" {
    {
        const buf = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
        defer t.allocator.free(buf);
        putI64(buf, fixture_tmpo_at + 4, 720720); // [0].tick != 0
        try expectTransportRefusal(buf, .tempo_invalid);
    }
    {
        const buf = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
        defer t.allocator.free(buf);
        putF64(buf, fixture_tmpo_at + 12, 121); // [0].bpm != 'TRAN'.bpm
        try expectTransportRefusal(buf, .tempo_invalid);
    }
}

test "Pacb: TMPO ticks must be strictly ascending" {
    const buf = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
    defer t.allocator.free(buf);
    putI64(buf, fixture_tmpo_at + 4 + TMPO_REC_LEN, 0); // [1].tick == [0].tick
    try expectTransportRefusal(buf, .tempo_invalid);
}

test "Pacb: TMPO segment bpm outside the finite 1..1000 domain refuses tempo_invalid" {
    const bad = [_]f64{ std.math.nan(f64), std.math.inf(f64), 0, 1001 };
    for (bad) |bpm| {
        const buf = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
        defer t.allocator.free(buf);
        putF64(buf, fixture_tmpo_at + 4 + TMPO_REC_LEN + 8, bpm); // [1].bpm
        try expectTransportRefusal(buf, .tempo_invalid);
    }
}

test "Pacb: TMPO count over MAX_TEMPO_SEGMENTS refuses cap_exceeded" {
    const n = MAX_TEMPO_SEGMENTS + 1;
    const recs = try t.allocator.alloc(TmpoRec, n);
    defer t.allocator.free(recs);
    for (recs, 0..) |*rec, i| {
        rec.* = .{ .tick = @as(i64, @intCast(i)) * 720720, .bpm = 120 };
    }
    const buf = try buildTransportFixture(t.allocator, .{}, recs);
    defer t.allocator.free(buf);
    try expectTransportRefusal(buf, .cap_exceeded);
}

test "Pacb: a TMPO tick magnitude beyond MAX_TICK refuses tempo_invalid" {
    const buf = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
    defer t.allocator.free(buf);
    putI64(buf, fixture_tmpo_at + 4 + TMPO_REC_LEN, (1 << 53) + 1);
    try expectTransportRefusal(buf, .tempo_invalid);
}

test "Pacb: an absent TRAN refuses non_canonical" {
    // A PACM-only container: directory-valid, but 'TRAN' is required.
    var buf: [16 + DIRECTORY_ENTRY_LEN + 40]u8 = @splat(0);
    writeHeader(&buf, 1, 0);
    writeDirEntry(&buf, 0, .pacm, 16 + DIRECTORY_ENTRY_LEN, 40);
    try expectTransportRefusal(&buf, .non_canonical);
}

test "Pacb: an absent TMPO synthesizes the single-segment constant map" {
    const dur: i64 = 3 * 720720; // 3 bars
    const buf = try buildTransportFixture(
        t.allocator,
        .{ .bpm = 97.25, .beats_per_bar = 5, .dur = dur, .end_loop = true },
        &.{},
    );
    defer t.allocator.free(buf);

    const directory = try parseDirectory(buf, null);
    var stage = try decodeTransport(t.allocator, buf, &directory, null);
    defer stage.deinit();
    const transport = &stage.transport;

    // The authored table is the synthesized degenerate map [{0, bpm}].
    try t.expectEqual(@as(usize, 1), transport.segments.len);
    try t.expectEqual(@as(i64, 0), transport.segments[0].start_tick);
    try t.expectEqual(@as(u64, @bitCast(@as(f64, 97.25))), @as(u64, @bitCast(transport.segments[0].bpm)));

    // The map itself takes the constant path: no derived table, exactly
    // like a compiled constant-tempo score (segments.len <= 1).
    try t.expectEqual(@as(usize, 0), transport.map.segments.len);
    const want_map = TimeMap.init(97.25, 5);
    try t.expectEqual(@as(i64, 720720 / 5), transport.map.ticks_per_beat);
    try t.expectEqual(
        @as(u64, @bitCast(want_map.ticks_per_second)),
        @as(u64, @bitCast(transport.map.ticks_per_second)),
    );
    try t.expectEqual(dur, transport.dur.?);
    try t.expectEqual(TrackTable.EndBehavior.loop, transport.end);
    try t.expectEqual(
        @as(u64, @bitCast(want_map.secondsFromTick(dur))),
        @as(u64, @bitCast(transport.loop_secs.?)),
    );

    // The authored table is arena-owned, not an alias of the input.
    @memset(buf, 0xAA);
    try t.expectEqual(@as(u64, @bitCast(@as(f64, 97.25))), @as(u64, @bitCast(transport.segments[0].bpm)));
}

test "Pacb: decoded transport equals the compiled transport field-for-field" {
    // The compiler-oracle seam: Compile and test_support are referenced
    // ONLY inside this test body, so a normal (non-test) build never
    // analyses them through Pacb (the plan-02 import-closure seam —
    // recorded, not claimed as strict closure).
    const Compile = @import("Compile.zig");
    const test_support = @import("test_support.zig");

    const targets = [_]Compile.Target{.{ .name = "circle-radius", .ncomp = 1 }};

    // Leg 1: a tempo-mapped score with a loop.
    const mapped: [:0]const u8 =
        \\(transport :bpm 125 :meter [4 4] :dur 400b :end loop)
        \\(tempo :at 160b :bpm 150)
        \\(tempo :at 200b :bpm 96.5)
        \\(track :target circle-radius
        \\  (key :at 0b :value 0.2)
        \\  (key :at 300b :value 0.8))
    ;
    var r = try Compile.compile(t.allocator, test_support.schema(), mapped, &targets);
    defer r.deinit();
    try t.expect(r.ok());
    {
        const want = &r.table.?.transport;

        const tmpo = try t.allocator.alloc(TmpoRec, want.segments.len);
        defer t.allocator.free(tmpo);
        for (want.segments, 0..) |seg, i| {
            tmpo[i] = .{ .tick = seg.start_tick, .bpm = seg.bpm };
        }
        const buf = try buildTransportFixture(
            t.allocator,
            .{
                .bpm = want.map.bpm,
                .beats_per_bar = want.map.beats_per_bar,
                .dur = want.dur,
                .end_loop = want.end == .loop,
            },
            tmpo,
        );
        defer t.allocator.free(buf);

        const directory = try parseDirectory(buf, null);
        var stage = try decodeTransport(t.allocator, buf, &directory, null);
        defer stage.deinit();
        const got = &stage.transport;

        try t.expectEqual(@as(u64, @bitCast(want.map.bpm)), @as(u64, @bitCast(got.map.bpm)));
        try t.expectEqual(want.map.beats_per_bar, got.map.beats_per_bar);
        try t.expectEqual(want.map.ticks_per_beat, got.map.ticks_per_beat);
        try t.expectEqual(
            @as(u64, @bitCast(want.map.ticks_per_second)),
            @as(u64, @bitCast(got.map.ticks_per_second)),
        );
        try t.expectEqual(want.dur, got.dur);
        try t.expectEqual(want.end, got.end);
        try t.expectEqual(want.emit.len, got.emit.len);

        // Authored truth: the exact 'TMPO' table.
        try t.expectEqual(want.segments.len, got.segments.len);
        for (want.segments, got.segments) |w, g| {
            try t.expectEqual(w.start_tick, g.start_tick);
            try t.expectEqual(@as(u64, @bitCast(w.bpm)), @as(u64, @bitCast(g.bpm)));
        }

        // Derived table: same op order, bit-equal cumulative fields.
        try t.expectEqual(want.map.segments.len, got.map.segments.len);
        for (want.map.segments, got.map.segments) |w, g| {
            try t.expectEqual(w.start_tick, g.start_tick);
            try t.expectEqual(@as(u64, @bitCast(w.bpm)), @as(u64, @bitCast(g.bpm)));
            try t.expectEqual(@as(u64, @bitCast(w.start_sec)), @as(u64, @bitCast(g.start_sec)));
            try t.expectEqual(@as(u64, @bitCast(w.tps)), @as(u64, @bitCast(g.tps)));
        }

        try t.expect(want.loop_secs != null and got.loop_secs != null);
        try t.expectEqual(
            @as(u64, @bitCast(want.loop_secs.?)),
            @as(u64, @bitCast(got.loop_secs.?)),
        );
    }

    // Leg 2: a constant-tempo score (no 'TMPO', no dur).
    const flat: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target circle-radius (key :at 0b :value 0.5))
    ;
    var r2 = try Compile.compile(t.allocator, test_support.schema(), flat, &targets);
    defer r2.deinit();
    try t.expect(r2.ok());
    {
        const want = &r2.table.?.transport;
        const buf = try buildTransportFixture(
            t.allocator,
            .{ .bpm = want.map.bpm, .beats_per_bar = want.map.beats_per_bar },
            &.{},
        );
        defer t.allocator.free(buf);

        const directory = try parseDirectory(buf, null);
        var stage = try decodeTransport(t.allocator, buf, &directory, null);
        defer stage.deinit();
        const got = &stage.transport;

        try t.expectEqual(want.segments.len, got.segments.len); // 1, synthesized
        try t.expectEqual(@as(i64, 0), got.segments[0].start_tick);
        try t.expectEqual(
            @as(u64, @bitCast(want.segments[0].bpm)),
            @as(u64, @bitCast(got.segments[0].bpm)),
        );
        try t.expectEqual(@as(usize, 0), got.map.segments.len);
        try t.expectEqual(want.dur, got.dur);
        try t.expectEqual(want.end, got.end);
        try t.expect(want.loop_secs == null and got.loop_secs == null);
        try t.expectEqual(
            @as(u64, @bitCast(want.map.ticks_per_second)),
            @as(u64, @bitCast(got.map.ticks_per_second)),
        );
    }
}

// ---------------------------------------------------------------------------
// T2.3 — registry identity stage tests ('REGS' + 'DECL' + fnv)
// ---------------------------------------------------------------------------

fn putU16(buf: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, buf[at..][0..2], value, .little);
}

/// One `'DECL'` record as the section spells it (registry, ncomp, pad 0).
const DeclRec = struct { registry: u8 = 0, ncomp: u8 = 1 };

/// Test-side FNV-1a-64 (mirrors `std.hash.Fnv1a_64`, which the decoder
/// uses; spelled here so tests compute expected checksums independently
/// of the production helper).
fn fnv(bytes: []const u8) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(bytes);
    return h.final();
}

fn encodePact(alloc: std.mem.Allocator, targets: []const PactCodec.Target) ![]u8 {
    const buf = try alloc.alloc(u8, PactCodec.targetsEncodedLen(targets));
    _ = try PactCodec.encodeTargets(targets, buf);
    return buf;
}

/// The shared fixture builder, grown for T2.3: `'TRAN'`, an optional
/// `'REGS'`, optional `'DECL'` records, an optional `'TMPO'`, and the
/// zeroed `'PACM'` tail — canonical order throughout.
fn buildPacbFixture(
    alloc: std.mem.Allocator,
    spec: TransportSpec,
    tmpo: []const TmpoRec,
    regs: ?[]const u8,
    decl: []const DeclRec,
) ![]u8 {
    const has_tmpo = tmpo.len > 0;
    const n: usize = 2 + @as(usize, @intFromBool(has_tmpo)) +
        @as(usize, @intFromBool(regs != null)) + @as(usize, @intFromBool(decl.len > 0));
    const dir_end = HEADER_LEN + n * DIRECTORY_ENTRY_LEN;
    const tran_off = dir_end;
    const regs_off = tran_off + TRAN_REC_LEN;
    const regs_len: usize = if (regs) |r| 4 + r.len else 0;
    const decl_off = regs_off + regs_len;
    const decl_len: usize = if (decl.len > 0) 4 + decl.len * DECL_REC_LEN else 0;
    const tmpo_off = decl_off + decl_len;
    const tmpo_len: usize = if (has_tmpo) 4 + tmpo.len * TMPO_REC_LEN else 0;
    const pacm_off = tmpo_off + tmpo_len;
    const pacm_len: usize = 40;

    const buf = try alloc.alloc(u8, pacm_off + pacm_len);
    @memset(buf, 0);
    writeHeader(buf, n, 0);
    var index: usize = 0;
    writeDirEntry(buf, index, .tran, tran_off, TRAN_REC_LEN);
    index += 1;
    if (regs) |r| {
        writeDirEntry(buf, index, .regs, regs_off, regs_len);
        putU32(buf, regs_off, @intCast(r.len));
        @memcpy(buf[regs_off + 4 ..][0..r.len], r);
        index += 1;
    }
    if (decl.len > 0) {
        writeDirEntry(buf, index, .decl, decl_off, decl_len);
        putU32(buf, decl_off, @intCast(decl.len));
        for (decl, 0..) |rec, i| {
            const at = decl_off + 4 + i * DECL_REC_LEN;
            buf[at] = rec.registry;
            buf[at + 1] = rec.ncomp;
            putU16(buf, at + 2, 0); // pad
        }
        index += 1;
    }
    if (has_tmpo) {
        writeDirEntry(buf, index, .tmpo, tmpo_off, tmpo_len);
        putU32(buf, tmpo_off, @intCast(tmpo.len));
        for (tmpo, 0..) |rec, i| {
            const at = tmpo_off + 4 + i * TMPO_REC_LEN;
            putI64(buf, at, rec.tick);
            putF64(buf, at + 8, rec.bpm);
        }
        index += 1;
    }
    writeDirEntry(buf, n - 1, .pacm, pacm_off, pacm_len);
    writeTranRecord(buf, tran_off, spec);
    return buf;
}

/// The two-target host join the T2.3 tests swap, reorder and reshape.
const host_two = [_]PactCodec.Target{
    .{ .name = "t-one", .ncomp = 3, .registry = 0 },
    .{ .name = "t-two", .ncomp = 1, .registry = 1 },
};

fn expectRegistryRefusal(bytes: []const u8, code: RefusalCode) !void {
    var refusal: Refusal = undefined;
    const directory = try parseDirectory(bytes, null);
    const decoded = decodeRegistry(t.allocator, bytes, &directory, &refusal);
    if (decoded) |payload| {
        var stage = payload;
        stage.deinit();
        return error.WronglyAccepted;
    } else |err| {
        try t.expectEqual(error.Refused, err);
        try t.expectEqual(code, refusal.code);
    }
}

test "Pacb: a clean registry fixture decodes its identity" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const decl = [_]DeclRec{.{ .registry = 1, .ncomp = 2 }};

    const buf = try buildPacbFixture(
        t.allocator,
        .{ .host_targets = 2, .declared_targets = 1, .pact_fnv = fnv(regs) },
        &.{},
        regs,
        &decl,
    );
    defer t.allocator.free(buf);

    const directory = try parseDirectory(buf, null);
    var stage = try decodeRegistry(t.allocator, buf, &directory, null);
    defer stage.deinit();

    try t.expectEqual(@as(u32, 2), stage.host_targets);
    try t.expectEqual(@as(u32, 1), stage.declared_targets);
    try t.expectEqual(fnv(regs), stage.pact_fnv);
    try t.expectEqualSlices(u8, regs, stage.regs);
    try t.expectEqual(@as(usize, 1), stage.declared.len);
    try t.expectEqual(@as(u8, 1), stage.declared[0].registry);
    try t.expectEqual(@as(u8, 2), stage.declared[0].ncomp);

    // The stage deep-copies: clobbering the input leaves it intact (the
    // borrow-vs-own contract until T2.8's final arena owns everything).
    @memset(buf, 0xAA);
    try t.expectEqualSlices(u8, regs, stage.regs);
    try t.expectEqual(@as(u8, 1), stage.declared[0].registry);
    try t.expectEqual(@as(u8, 2), stage.declared[0].ncomp);
}

test "Pacb: REGS absent with a nonzero host_targets refuses non_canonical" {
    const buf = try buildPacbFixture(t.allocator, .{ .host_targets = 3 }, &.{}, null, &.{});
    defer t.allocator.free(buf);
    try expectRegistryRefusal(buf, .non_canonical);
}

test "Pacb: REGS absent with a wrong zero-count fnv refuses registry_mismatch" {
    const zero_pact = try encodePact(t.allocator, &.{});
    defer t.allocator.free(zero_pact);

    // The well-defined spelling: FNV-1a-64 over the 8-B zero-count 'PACT'.
    {
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .pact_fnv = fnv(zero_pact) },
            &.{},
            null,
            &.{},
        );
        defer t.allocator.free(buf);
        var refusal: Refusal = undefined;
        const directory = try parseDirectory(buf, null);
        var stage = try decodeRegistry(t.allocator, buf, &directory, &refusal);
        stage.deinit(); // accepted — the positive control
    }
    {
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .pact_fnv = fnv(zero_pact) ^ 1 },
            &.{},
            null,
            &.{},
        );
        defer t.allocator.free(buf);
        try expectRegistryRefusal(buf, .registry_mismatch);
    }
}

test "Pacb: REGS present with a zero-count PACT refuses non_canonical" {
    const zero_pact = try encodePact(t.allocator, &.{});
    defer t.allocator.free(zero_pact);
    const buf = try buildPacbFixture(
        t.allocator,
        .{ .pact_fnv = fnv(zero_pact) },
        &.{},
        zero_pact,
        &.{},
    );
    defer t.allocator.free(buf);
    try expectRegistryRefusal(buf, .non_canonical);
}

test "Pacb: a wrong pact_fnv fast-rejects registry_mismatch" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const buf = try buildPacbFixture(
        t.allocator,
        .{ .host_targets = 2, .pact_fnv = fnv(regs) ^ 1 },
        &.{},
        regs,
        &.{},
    );
    defer t.allocator.free(buf);
    try expectRegistryRefusal(buf, .registry_mismatch);
}

test "Pacb: REGS record count must equal TRAN host_targets" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const buf = try buildPacbFixture(
        t.allocator,
        .{ .host_targets = 1, .pact_fnv = fnv(regs) }, // blob says 2
        &.{},
        regs,
        &.{},
    );
    defer t.allocator.free(buf);
    try expectRegistryRefusal(buf, .count_mismatch);
}

test "Pacb: DECL count must equal TRAN declared_targets" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    {
        const decl = [_]DeclRec{ .{}, .{ .registry = 1, .ncomp = 4 } };
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .declared_targets = 1, .pact_fnv = fnv(regs) },
            &.{},
            regs,
            &decl,
        );
        defer t.allocator.free(buf);
        try expectRegistryRefusal(buf, .count_mismatch);
    }
    {
        // Absent 'DECL' is the zero-declared spelling.
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .declared_targets = 2, .pact_fnv = fnv(regs) },
            &.{},
            regs,
            &.{},
        );
        defer t.allocator.free(buf);
        try expectRegistryRefusal(buf, .count_mismatch);
    }
}

test "Pacb: host plus declared targets over MAX_TARGETS refuses cap_exceeded" {
    const zero_pact = try encodePact(t.allocator, &.{});
    defer t.allocator.free(zero_pact);
    const decl = try t.allocator.alloc(DeclRec, MAX_TARGETS + 1);
    defer t.allocator.free(decl);
    for (decl) |*rec| rec.* = .{ .registry = 0, .ncomp = 1 };

    const buf = try buildPacbFixture(
        t.allocator,
        .{
            .declared_targets = MAX_TARGETS + 1,
            .pact_fnv = fnv(zero_pact),
        },
        &.{},
        null,
        decl,
    );
    defer t.allocator.free(buf);
    try expectRegistryRefusal(buf, .cap_exceeded);
}

test "Pacb: DECL record defects refuse decl_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const decl = [_]DeclRec{.{ .registry = 0, .ncomp = 2 }};
    // n = 4 sections (TRAN+REGS+DECL+PACM): TRAN at 64, REGS at 120,
    // DECL at 120 + (4 + regs.len).
    const decl_rec_at = HEADER_LEN + 4 * DIRECTORY_ENTRY_LEN + TRAN_REC_LEN + 4 + regs.len + 4;

    {
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .declared_targets = 1, .pact_fnv = fnv(regs) },
            &.{},
            regs,
            &decl,
        );
        defer t.allocator.free(buf);
        putU8(buf, decl_rec_at + 1, 0); // ncomp 0
        try expectRegistryRefusal(buf, .decl_invalid);
    }
    {
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .declared_targets = 1, .pact_fnv = fnv(regs) },
            &.{},
            regs,
            &decl,
        );
        defer t.allocator.free(buf);
        putU8(buf, decl_rec_at + 1, 5); // ncomp 5
        try expectRegistryRefusal(buf, .decl_invalid);
    }
    {
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .declared_targets = 1, .pact_fnv = fnv(regs) },
            &.{},
            regs,
            &decl,
        );
        defer t.allocator.free(buf);
        putU16(buf, decl_rec_at + 2, 1); // non-zero pad
        try expectRegistryRefusal(buf, .decl_invalid);
    }
}

test "Pacb: REGS structural defects refuse registry_mismatch" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const regs_at = HEADER_LEN + 3 * DIRECTORY_ENTRY_LEN + TRAN_REC_LEN; // TRAN+REGS+PACM

    {
        // byte_len disagrees with the section length
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .pact_fnv = fnv(regs) },
            &.{},
            regs,
            &.{},
        );
        defer t.allocator.free(buf);
        putU32(buf, regs_at, @intCast(regs.len - 1));
        try expectRegistryRefusal(buf, .registry_mismatch);
    }
    {
        // truncated PACT: count says 2, the second name does not fit
        const chopped = regs[0 .. regs.len - 3];
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .pact_fnv = fnv(chopped) },
            &.{},
            chopped,
            &.{},
        );
        defer t.allocator.free(buf);
        try expectRegistryRefusal(buf, .registry_mismatch);
    }
    {
        // bad magic (byte_len stays consistent; the walk checks magic)
        const buf = try buildPacbFixture(
            t.allocator,
            .{ .host_targets = 2, .pact_fnv = fnv(regs) },
            &.{},
            regs,
            &.{},
        );
        defer t.allocator.free(buf);
        putU32(buf, regs_at + 4, 0xdeadbeef);
        try expectRegistryRefusal(buf, .registry_mismatch);
    }
}

// ---------------------------------------------------------------------------
// T2.4 — record-section stage tests ('TRAK' + 'KEYS' + 'TICK' + 'EMIT' +
// 'SCEN')
// ---------------------------------------------------------------------------

fn putF32(buf: []u8, at: usize, value: f32) void {
    std.mem.writeInt(u32, buf[at..][0..4], @bitCast(value), .little);
}

/// One `'TRAK'` record as the section spells it (40 B: target_id u16,
/// registry u8, ncomp u8, source u8, trig_kind u8, scene u16, key_start
/// u32, key_len u32, payload_off u32, payload_len u32, trig_every i64,
/// trig_offset i64).
const TrakRec = struct {
    target_id: u16 = 0,
    registry: u8 = 0,
    ncomp: u8 = 1,
    source: u8 = SOURCE_KEYS,
    trig_kind: u8 = TRIG_PERIODIC,
    scene: u16 = TrackTable.NO_SCENE,
    key_start: u32 = 0,
    key_len: u32 = 0,
    payload_off: u32 = 0,
    payload_len: u32 = 0,
    trig_every: i64 = 0,
    trig_offset: i64 = 0,
};

/// One `'KEYS'` record (28 B: at i64, value f32×4, ease_ref u16, pad u16).
const KeyRec = struct {
    at: i64 = 0,
    value: [4]f32 = .{ 0, 0, 0, 0 },
    ease_ref: u16 = 0,
};

/// One `'EMIT'` record (8 B: name u8, registry u8, target_id u16,
/// reserved u32).
const EmitRec = struct {
    name: u8 = 0,
    registry: u8 = 0,
    target_id: u16 = 0,
    reserved: u32 = 0,
};

/// One `'SCEN'` record (16 B: start_tick i64, dur_ticks i64).
const ScenRec = struct { start_tick: i64 = 0, dur_ticks: i64 = 0 };

/// Optional means absent; a NON-NULL EMPTY slice spells a present
/// zero-count section (the canonical-presence mutation under test).
const RecordsSpec = struct {
    transport: TransportSpec = .{},
    tmpo: []const TmpoRec = &.{},
    regs: ?[]const u8 = null,
    decl: []const DeclRec = &.{},
    emit: ?[]const EmitRec = null,
    trak: ?[]const TrakRec = null,
    keys: ?[]const KeyRec = null,
    tick: ?[]const i64 = null,
    scen: ?[]const ScenRec = null,
};

/// Absolute payload offsets of the record sections (0 = absent; every
/// present payload starts at least at the 184-byte all-kinds boundary).
const RecordsLayout = struct {
    emit: u32 = 0,
    trak: u32 = 0,
    keys: u32 = 0,
    tick: u32 = 0,
    scen: u32 = 0,
};

const BuiltFixture = struct { buf: []u8, layout: RecordsLayout };

/// The T2.4 fixture builder: canonical order throughout, offsets derived
/// by summation, one mutation applied per test afterwards (via the spec
/// records or a byte patch through `layout`).
fn buildRecordsFixture(
    alloc: std.mem.Allocator,
    spec: RecordsSpec,
) !BuiltFixture {
    const has_tmpo = spec.tmpo.len > 0;
    const has_decl = spec.decl.len > 0;
    var n: usize = 2; // TRAN + PACM
    if (spec.regs != null) n += 1;
    if (has_decl) n += 1;
    if (spec.emit != null) n += 1;
    if (has_tmpo) n += 1;
    if (spec.trak != null) n += 1;
    if (spec.keys != null) n += 1;
    if (spec.tick != null) n += 1;
    if (spec.scen != null) n += 1;

    var pos: usize = HEADER_LEN + n * DIRECTORY_ENTRY_LEN;
    const tran_off = pos;
    pos += TRAN_REC_LEN;
    const regs_off = pos;
    const regs_len: usize = if (spec.regs) |r| 4 + r.len else 0;
    pos += regs_len;
    const decl_off = pos;
    const decl_len: usize = if (has_decl) 4 + spec.decl.len * DECL_REC_LEN else 0;
    pos += decl_len;
    const emit_off = pos;
    const emit_len: usize = if (spec.emit) |e| 4 + e.len * EMIT_REC_LEN else 0;
    pos += emit_len;
    const tmpo_off = pos;
    const tmpo_len: usize = if (has_tmpo) 4 + spec.tmpo.len * TMPO_REC_LEN else 0;
    pos += tmpo_len;
    const trak_off = pos;
    const trak_len: usize = if (spec.trak) |tr| 4 + tr.len * TRAK_REC_LEN else 0;
    pos += trak_len;
    const keys_off = pos;
    const keys_len: usize = if (spec.keys) |ks| 4 + ks.len * KEYS_REC_LEN else 0;
    pos += keys_len;
    const tick_off = pos;
    const tick_len: usize = if (spec.tick) |tk| 4 + tk.len * TICK_REC_LEN else 0;
    pos += tick_len;
    const scen_off = pos;
    const scen_len: usize = if (spec.scen) |sc| 4 + sc.len * SCEN_REC_LEN else 0;
    pos += scen_len;
    const pacm_off = pos;
    const pacm_len: usize = 40;

    const buf = try alloc.alloc(u8, pacm_off + pacm_len);
    @memset(buf, 0);
    writeHeader(buf, n, 0);

    var index: usize = 0;
    writeDirEntry(buf, index, .tran, tran_off, TRAN_REC_LEN);
    index += 1;
    if (spec.regs) |r| {
        writeDirEntry(buf, index, .regs, regs_off, regs_len);
        putU32(buf, regs_off, @intCast(r.len));
        @memcpy(buf[regs_off + 4 ..][0..r.len], r);
        index += 1;
    }
    if (has_decl) {
        writeDirEntry(buf, index, .decl, decl_off, decl_len);
        putU32(buf, decl_off, @intCast(spec.decl.len));
        for (spec.decl, 0..) |rec, i| {
            const at = decl_off + 4 + i * DECL_REC_LEN;
            buf[at] = rec.registry;
            buf[at + 1] = rec.ncomp;
            putU16(buf, at + 2, 0); // pad
        }
        index += 1;
    }
    if (spec.emit) |lanes| {
        writeDirEntry(buf, index, .emit, emit_off, emit_len);
        putU32(buf, emit_off, @intCast(lanes.len));
        for (lanes, 0..) |rec, i| {
            const at = emit_off + 4 + i * EMIT_REC_LEN;
            putU8(buf, at, rec.name);
            putU8(buf, at + 1, rec.registry);
            putU16(buf, at + 2, rec.target_id);
            putU32(buf, at + 4, rec.reserved);
        }
        index += 1;
    }
    if (has_tmpo) {
        writeDirEntry(buf, index, .tmpo, tmpo_off, tmpo_len);
        putU32(buf, tmpo_off, @intCast(spec.tmpo.len));
        for (spec.tmpo, 0..) |rec, i| {
            const at = tmpo_off + 4 + i * TMPO_REC_LEN;
            putI64(buf, at, rec.tick);
            putF64(buf, at + 8, rec.bpm);
        }
        index += 1;
    }
    if (spec.trak) |traks| {
        writeDirEntry(buf, index, .trak, trak_off, trak_len);
        putU32(buf, trak_off, @intCast(traks.len));
        for (traks, 0..) |rec, i| {
            const at = trak_off + 4 + i * TRAK_REC_LEN;
            putU16(buf, at, rec.target_id);
            putU8(buf, at + 2, rec.registry);
            putU8(buf, at + 3, rec.ncomp);
            putU8(buf, at + 4, rec.source);
            putU8(buf, at + 5, rec.trig_kind);
            putU16(buf, at + 6, rec.scene);
            putU32(buf, at + 8, rec.key_start);
            putU32(buf, at + 12, rec.key_len);
            putU32(buf, at + 16, rec.payload_off);
            putU32(buf, at + 20, rec.payload_len);
            putI64(buf, at + 24, rec.trig_every);
            putI64(buf, at + 32, rec.trig_offset);
        }
        index += 1;
    }
    if (spec.keys) |ks| {
        writeDirEntry(buf, index, .keys, keys_off, keys_len);
        putU32(buf, keys_off, @intCast(ks.len));
        for (ks, 0..) |rec, i| {
            const at = keys_off + 4 + i * KEYS_REC_LEN;
            putI64(buf, at, rec.at);
            putF32(buf, at + 8, rec.value[0]);
            putF32(buf, at + 12, rec.value[1]);
            putF32(buf, at + 16, rec.value[2]);
            putF32(buf, at + 20, rec.value[3]);
            putU16(buf, at + 24, rec.ease_ref);
            putU16(buf, at + 26, 0); // pad
        }
        index += 1;
    }
    if (spec.tick) |ticks| {
        writeDirEntry(buf, index, .tick, tick_off, tick_len);
        putU32(buf, tick_off, @intCast(ticks.len));
        for (ticks, 0..) |tick, i| {
            putI64(buf, tick_off + 4 + i * TICK_REC_LEN, tick);
        }
        index += 1;
    }
    if (spec.scen) |scs| {
        writeDirEntry(buf, index, .scen, scen_off, scen_len);
        putU32(buf, scen_off, @intCast(scs.len));
        for (scs, 0..) |rec, i| {
            const at = scen_off + 4 + i * SCEN_REC_LEN;
            putI64(buf, at, rec.start_tick);
            putI64(buf, at + 8, rec.dur_ticks);
        }
        index += 1;
    }
    writeDirEntry(buf, n - 1, .pacm, pacm_off, pacm_len);
    writeTranRecord(buf, tran_off, spec.transport);

    return .{ .buf = buf, .layout = .{
        .emit = if (spec.emit != null) @intCast(emit_off) else 0,
        .trak = if (spec.trak != null) @intCast(trak_off) else 0,
        .keys = if (spec.keys != null) @intCast(keys_off) else 0,
        .tick = if (spec.tick != null) @intCast(tick_off) else 0,
        .scen = if (spec.scen != null) @intCast(scen_off) else 0,
    } };
}

/// The shared base fixture: the `host_two` join plus one declared target
/// `(registry 1, ncomp 2)` (join size 3), one track of every source kind
/// (keys on id 0 in scene 0, expr on id 1, periodic trigger on declared
/// id 2, explicit trigger on id 0), two scenes, two emit lanes, three
/// keys, three explicit ticks.
const RecordsBase = struct {
    trak: [4]TrakRec,
    keys: [3]KeyRec,
    tick: [3]i64,
    emit: [2]EmitRec,
    scen: [2]ScenRec,
};

fn baseRecords() RecordsBase {
    return .{
        .trak = .{
            .{ .target_id = 0, .registry = 0, .ncomp = 3, .source = SOURCE_KEYS, .scene = 0, .key_start = 0, .key_len = 3 },
            .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_EXPR, .payload_off = 0, .payload_len = 12 },
            .{ .target_id = 2, .registry = 1, .ncomp = 2, .source = SOURCE_TRIGGER, .trig_kind = TRIG_PERIODIC, .trig_every = 480, .trig_offset = 120 },
            .{ .target_id = 0, .registry = 0, .ncomp = 3, .source = SOURCE_TRIGGER, .trig_kind = TRIG_EXPLICIT, .key_start = 0, .key_len = 3 },
        },
        .keys = .{
            .{ .at = 0, .value = .{ 0.1, 0.2, 0.3, 0 } },
            .{ .at = 360360, .value = .{ 0.25, 0.5, 0.75, 0 } },
            .{ .at = 720720, .value = .{ 1, 0, -1, 0 } },
        },
        .tick = .{ 5, 500, 5000 },
        .emit = .{
            .{ .name = 0, .registry = 0, .target_id = 0 }, // beat
            .{ .name = 4, .registry = 1, .target_id = 1 }, // t
        },
        .scen = .{
            .{ .start_tick = 0, .dur_ticks = 720720 },
            .{ .start_tick = 1441440, .dur_ticks = 360360 },
        },
    };
}

const base_decl = [_]DeclRec{.{ .registry = 1, .ncomp = 2 }};

/// `'TRAN'` fields matching the base join (host 2 + declared 1), with the
/// identity checksum over the actual `'REGS'` bytes.
fn hostJoinSpec(regs: []const u8) TransportSpec {
    return .{ .host_targets = 2, .declared_targets = 1, .pact_fnv = fnv(regs) };
}

/// Base fixture from a (possibly mutated) base record set.
fn buildBaseFixture(
    alloc: std.mem.Allocator,
    base: *const RecordsBase,
    regs: []const u8,
) !BuiltFixture {
    return buildRecordsFixture(alloc, .{
        .transport = hostJoinSpec(regs),
        .regs = regs,
        .decl = &base_decl,
        .emit = &base.emit,
        .trak = &base.trak,
        .keys = &base.keys,
        .tick = &base.tick,
        .scen = &base.scen,
    });
}

fn expectRecordsRefusal(bytes: []const u8, code: RefusalCode) !void {
    var refusal: Refusal = undefined;
    const directory = try parseDirectory(bytes, null);
    var registry = try decodeRegistry(t.allocator, bytes, &directory, &refusal);
    defer registry.deinit();
    const decoded = decodeRecords(t.allocator, bytes, &directory, &registry, &refusal);
    if (decoded) |payload| {
        var stage = payload;
        stage.deinit();
        return error.WronglyAccepted;
    } else |err| {
        try t.expectEqual(error.Refused, err);
        try t.expectEqual(code, refusal.code);
    }
}

test "Pacb: a clean records fixture decodes owned tracks, keys, scenes and emit" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();
    const built = try buildBaseFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);

    const directory = try parseDirectory(built.buf, null);
    var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
    defer registry.deinit();
    var stage = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
    defer stage.deinit();

    // Expected values are fixed literals, independent of the builder's
    // arithmetic (the builder only places bytes; these pin the decode).
    try t.expectEqual(@as(usize, 4), stage.tracks.len);
    try t.expectEqual(@as(u16, 0), stage.tracks[0].target_id);
    try t.expectEqual(@as(u8, 0), stage.tracks[0].registry);
    try t.expectEqual(@as(u8, 3), stage.tracks[0].ncomp);
    try t.expectEqual(@as(u16, 0), stage.tracks[0].scene);
    try t.expect(stage.tracks[0].source == .keys);
    try t.expectEqual(@as(u32, 0), stage.tracks[0].source.keys.start);
    try t.expectEqual(@as(u32, 3), stage.tracks[0].source.keys.len);

    try t.expect(stage.tracks[1].source == .expr);
    try t.expectEqual(@as(usize, 0), stage.tracks[1].source.expr.len); // T2.6 fills
    try t.expectEqual(@as(u32, 0), stage.payload_spans[1].off);
    try t.expectEqual(@as(u32, 12), stage.payload_spans[1].len);

    try t.expect(stage.tracks[2].source == .trigger);
    switch (stage.tracks[2].source.trigger) {
        .periodic => |p| {
            try t.expectEqual(@as(i64, 480), p.every);
            try t.expectEqual(@as(i64, 120), p.offset);
        },
        else => return error.UnexpectedArm,
    }

    try t.expect(stage.tracks[3].source == .trigger);
    switch (stage.tracks[3].source.trigger) {
        .at => |at| {
            try t.expectEqual(@as(usize, 3), at.len);
            try t.expectEqualSlices(i64, &.{ 5, 500, 5000 }, at);
        },
        else => return error.UnexpectedArm,
    }

    try t.expectEqual(@as(usize, 3), stage.keys.len);
    try t.expectEqual(@as(i64, 0), stage.keys[0].at);
    try t.expectEqual(@as(f32, 0.1), stage.keys[0].value[0]);
    try t.expectEqual(@as(f32, 0.2), stage.keys[0].value[1]);
    try t.expectEqual(@as(f32, 0.3), stage.keys[0].value[2]);
    try t.expectEqual(@as(f32, 0), stage.keys[0].value[3]);
    try t.expectEqual(@as(i64, 360360), stage.keys[1].at);
    try t.expectEqual(@as(f32, 0.5), stage.keys[1].value[1]);
    try t.expectEqual(@as(i64, 720720), stage.keys[2].at);
    try t.expectEqual(@as(f32, -1), stage.keys[2].value[2]);
    try t.expectEqual(@as(u16, 0), stage.keys[2].ease_ref);

    try t.expectEqual(@as(usize, 2), stage.scenes.len);
    try t.expectEqual(DecodedScene{ .start_tick = 0, .dur_ticks = 720720 }, stage.scenes[0]);
    try t.expectEqual(DecodedScene{ .start_tick = 1441440, .dur_ticks = 360360 }, stage.scenes[1]);

    try t.expectEqual(@as(usize, 2), stage.emit.len);
    try t.expectEqual(
        TrackTable.EmitLane{ .name = .beat, .target_id = 0, .registry = 0 },
        stage.emit[0],
    );
    try t.expectEqual(
        TrackTable.EmitLane{ .name = .t, .target_id = 1, .registry = 1 },
        stage.emit[1],
    );

    // The stage owns everything it returns (the borrow-vs-own contract
    // until T2.8's final arena): clobber the input, values survive.
    @memset(built.buf, 0xAA);
    try t.expectEqual(@as(usize, 4), stage.tracks.len);
    try t.expectEqual(@as(u32, 3), stage.tracks[0].source.keys.len);
    try t.expectEqualSlices(i64, &.{ 5, 500, 5000 }, stage.tracks[3].source.trigger.at);
    try t.expectEqual(@as(i64, 360360), stage.keys[1].at);
    try t.expectEqual(@as(f32, 0.75), stage.keys[1].value[2]);
    try t.expectEqual(@as(i64, 1441440), stage.scenes[1].start_tick);
    try t.expectEqual(TrackTable.EmitName.t, stage.emit[1].name);
    try t.expectEqual(@as(u32, 12), stage.payload_spans[1].len);
}

test "Pacb: record-section counts over their caps refuse cap_exceeded" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // 'TRAK' over MAX_TRACKS (257 expr rows — compact, no keys needed).
    {
        const many = try t.allocator.alloc(TrakRec, MAX_TRACKS + 1);
        defer t.allocator.free(many);
        for (many) |*rec| rec.* = baseRecords().trak[1];
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = many,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .cap_exceeded);
    }
    // 'KEYS' over MAX_KEYS.
    {
        var base = baseRecords();
        base.trak[0].key_len = MAX_KEYS + 1;
        const many = try t.allocator.alloc(KeyRec, MAX_KEYS + 1);
        defer t.allocator.free(many);
        for (many, 0..) |*rec, i| rec.* = .{ .at = @intCast(i) };
        const spec: RecordsSpec = .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &base.trak,
            .emit = &base.emit,
            .scen = &base.scen,
            .keys = many,
        };
        const built = try buildRecordsFixture(t.allocator, spec);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .cap_exceeded);
    }
    // 'SCEN' over MAX_SCENES.
    {
        const many = try t.allocator.alloc(ScenRec, MAX_SCENES + 1);
        defer t.allocator.free(many);
        for (many) |*rec| rec.* = .{ .start_tick = 0, .dur_ticks = 4 };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &.{EmitRec{}},
            .scen = many,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .cap_exceeded);
    }
    // 'EMIT' over the five-lane ceiling (G10).
    {
        const lanes = [_]EmitRec{
            .{ .name = 0 }, .{ .name = 1 }, .{ .name = 2 },
            .{ .name = 3 }, .{ .name = 4 }, .{ .name = 0 },
        };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &lanes,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .cap_exceeded);
    }
}

test "Pacb: present zero-count record sections refuse non_canonical" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const sections = [_]struct { name: []const u8, spec: RecordsSpec }{
        .{ .name = "TRAK", .spec = .{ .transport = hostJoinSpec(regs), .regs = regs, .decl = &base_decl, .trak = &.{} } },
        .{ .name = "KEYS", .spec = .{ .transport = hostJoinSpec(regs), .regs = regs, .decl = &base_decl, .emit = &.{EmitRec{}}, .trak = &.{baseRecords().trak[1]}, .keys = &.{} } },
        .{ .name = "SCEN", .spec = .{ .transport = hostJoinSpec(regs), .regs = regs, .decl = &base_decl, .emit = &.{EmitRec{}}, .scen = &.{} } },
    };
    for (sections) |case| {
        const built = try buildRecordsFixture(t.allocator, case.spec);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .non_canonical);
    }
}

test "Pacb: source and trig_kind ordinals out of range refuse record_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    {
        var base = baseRecords();
        base.trak[0].source = 4;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .record_invalid);
    }
    {
        var base = baseRecords();
        base.trak[2].trig_kind = 2;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .record_invalid);
    }
}

test "Pacb: TRAK ncomp outside 1..4 refuses record_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    for ([_]u8{ 0, 5 }) |ncomp| {
        var base = baseRecords();
        base.trak[0].ncomp = ncomp;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .record_invalid);
    }
}

test "Pacb: per-source non-zero slack refuses record_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const mutations = [_]struct { index: usize, field: []const u8, value: u64 }{
        .{ .index = 0, .field = "trig_every", .value = 1 }, // keys track
        .{ .index = 0, .field = "payload_off", .value = 4 }, // keys track
        .{ .index = 1, .field = "key_len", .value = 1 }, // expr track
        .{ .index = 2, .field = "payload_len", .value = 8 }, // periodic trigger
        .{ .index = 3, .field = "trig_offset", .value = 7 }, // explicit trigger
        .{ .index = 1, .field = "pattern_trig_every", .value = 2 }, // pattern track
    };
    for (mutations) |m| {
        var base = baseRecords();
        if (std.mem.eql(u8, m.field, "pattern_trig_every")) {
            base.trak[m.index].source = SOURCE_PATTERN;
            base.trak[m.index].trig_every = @intCast(m.value);
        } else if (std.mem.eql(u8, m.field, "trig_every")) {
            base.trak[m.index].trig_every = @intCast(m.value);
        } else if (std.mem.eql(u8, m.field, "trig_offset")) {
            base.trak[m.index].trig_offset = @intCast(m.value);
        } else if (std.mem.eql(u8, m.field, "payload_off")) {
            base.trak[m.index].payload_off = @intCast(m.value);
        } else if (std.mem.eql(u8, m.field, "payload_len")) {
            base.trak[m.index].payload_len = @intCast(m.value);
        } else if (std.mem.eql(u8, m.field, "key_len")) {
            base.trak[m.index].key_len = @intCast(m.value);
        }
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .record_invalid);
    }
}

test "Pacb: a track outside the join or with a wrong triple refuses registry_mismatch" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    {
        var base = baseRecords();
        base.trak[0].target_id = 3; // join size is host 2 + declared 1
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .registry_mismatch);
    }
    {
        var base = baseRecords();
        base.trak[0].registry = 1; // host entry 0 is (registry 0, ncomp 3)
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .registry_mismatch);
    }
    {
        var base = baseRecords();
        base.trak[0].ncomp = 2; // host entry 0 is (registry 0, ncomp 3)
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .registry_mismatch);
    }
}

test "Pacb: scene must be NO_SCENE or index the SCEN table" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    {
        // Shaped-valid against MAX_SCENES but out of range for THIS
        // table (2 rows) — the G10 correction.
        var base = baseRecords();
        base.trak[0].scene = 63;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .scene_invalid);
    }
    {
        // No 'SCEN' section at all: only NO_SCENE passes.
        var base = baseRecords();
        base.trak[0].scene = 1;
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &base.emit,
            .trak = &base.trak,
            .keys = &base.keys,
            .tick = &base.tick,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .scene_invalid);
    }
}

test "Pacb: a keys run needs at least one key and must not overrun KEYS" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    {
        var base = baseRecords();
        base.trak[0].key_len = 0;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .key_invalid);
    }
    {
        var base = baseRecords();
        base.trak[0].key_start = 2; // 2 + 3 > 3 keys
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .key_invalid);
    }
}

test "Pacb: keys must ascend strictly with lanes at or above ncomp zero" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    {
        var base = baseRecords();
        base.keys[1].at = 0; // ties keys[0]
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .key_invalid);
    }
    {
        var base = baseRecords();
        base.keys[1].at = -720720; // descending
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .key_invalid);
    }
    {
        // A scalar target (host entry 1: ncomp 1) whose value writes
        // lane 1 — the fixed unused lanes rule.
        var base = baseRecords();
        base.trak[0] = .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_KEYS, .scene = 0, .key_start = 0, .key_len = 3 };
        base.keys[1].value = .{ 0.5, 0.25, 0, 0 };
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .key_invalid);
    }
}

test "Pacb: a periodic trigger needs a positive every" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    for ([_]i64{ 0, -480 }) |every| {
        var base = baseRecords();
        base.trak[2].trig_every = every;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
}

test "Pacb: an explicit schedule is non-empty, ascending, tick-bounded, slice-bounded" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    {
        var base = baseRecords();
        base.trak[3].key_len = 0; // empty schedule
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
    {
        var base = baseRecords();
        base.tick[1] = 5; // ties tick[0]
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
    {
        var base = baseRecords();
        base.tick[1] = (1 << 53) + 1; // beyond the tick ceiling
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
    {
        var base = baseRecords();
        base.trak[3].key_start = 1; // 1 + 3 > 3 ticks
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
}

test "Pacb: overlapping explicit schedules refuse trigger_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();
    // Track 3 slices ticks[0..2); this second explicit track slices
    // ticks[1..3) — individually valid, overlapping as schedules.
    base.trak[1] = .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_TRIGGER, .trig_kind = TRIG_EXPLICIT, .key_start = 1, .key_len = 2 };
    const built = try buildBaseFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);
    try expectRecordsRefusal(built.buf, .trigger_invalid);
}

test "Pacb: a non-zero ease_ref with EASE absent refuses ease_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();
    base.keys[1].ease_ref = 3; // the synthesized table is linear alone
    const built = try buildBaseFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);
    try expectRecordsRefusal(built.buf, .ease_invalid);
}

test "Pacb: a non-zero KEYS pad refuses record_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();
    const built = try buildBaseFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);
    putU16(built.buf, built.layout.keys + 4 + KEYS_REC_LEN + 26, 1); // key 1 pad
    try expectRecordsRefusal(built.buf, .record_invalid);
}

test "Pacb: a scene window end overflow refuses scene_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();
    base.scen[1] = .{ .start_tick = 1 << 53, .dur_ticks = std.math.maxInt(i64) };
    const built = try buildBaseFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);
    try expectRecordsRefusal(built.buf, .scene_invalid);
}

test "Pacb: EMIT lanes enforce ordinal, uniqueness, reserved zero and the join" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const cases = [_]struct { code: RefusalCode, lanes: []const EmitRec }{
        .{ .code = .record_invalid, .lanes = &.{ .{ .name = 5 }, .{ .name = 1 } } }, // ordinal > 4
        .{ .code = .record_invalid, .lanes = &.{ .{ .name = 0 }, .{ .name = 0 } } }, // duplicate beat
        .{ .code = .record_invalid, .lanes = &.{.{ .name = 0, .reserved = 1 }} }, // reserved pad
        .{ .code = .registry_mismatch, .lanes = &.{.{ .name = 0, .target_id = 3 }} }, // out of join
        .{ .code = .registry_mismatch, .lanes = &.{.{ .name = 0, .target_id = 0, .registry = 1 }} }, // wrong registry
    };
    for (cases) |case| {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = case.lanes,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, case.code);
    }
}

test "Pacb: KEYS and TICK presence must match their track consumers" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();

    // 'KEYS' present with no keys track (expr + periodic only).
    {
        const trak = base.trak[1..3];
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &base.emit,
            .trak = trak,
            .keys = &base.keys,
            .scen = &base.scen,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .non_canonical);
    }
    // A keys track with 'KEYS' absent.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &base.emit,
            .trak = &base.trak,
            .tick = &base.tick,
            .scen = &base.scen,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .non_canonical);
    }
    // 'TICK' present with no explicit trigger.
    {
        const trak = base.trak[0..3];
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &base.emit,
            .trak = trak,
            .keys = &base.keys,
            .tick = &base.tick,
            .scen = &base.scen,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .non_canonical);
    }
    // An explicit trigger with 'TICK' absent.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &base.emit,
            .trak = &base.trak,
            .keys = &base.keys,
            .scen = &base.scen,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .non_canonical);
    }
}

test "Pacb: canonicalPactEquals catches same-shaped registry swaps" {
    const base = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(base);

    // Identity: a canonical blob equals itself and its re-encoding.
    try t.expect(canonicalPactEquals(base, base));
    {
        const re_encoded = try encodePact(t.allocator, &host_two);
        defer t.allocator.free(re_encoded);
        try t.expect(canonicalPactEquals(re_encoded, base));
    }

    // Same-shaped ordered NAME swap: identical (ncomp, registry)
    // signature per slot, different names — the exact confusion the
    // identity rule exists to prevent.
    {
        const swapped = try encodePact(t.allocator, &.{
            .{ .name = "t-two", .ncomp = 3, .registry = 0 },
            .{ .name = "t-one", .ncomp = 1, .registry = 1 },
        });
        defer t.allocator.free(swapped);
        try t.expect(!canonicalPactEquals(swapped, base));
    }

    // Reorder: same records, different order.
    {
        const reordered = try encodePact(t.allocator, &.{ host_two[1], host_two[0] });
        defer t.allocator.free(reordered);
        try t.expect(!canonicalPactEquals(reordered, base));
    }

    // Arity change on one target.
    {
        const arity = try encodePact(t.allocator, &.{
            .{ .name = "t-one", .ncomp = 4, .registry = 0 },
            host_two[1],
        });
        defer t.allocator.free(arity);
        try t.expect(!canonicalPactEquals(arity, base));
    }

    // Registry change on one target.
    {
        const reg = try encodePact(t.allocator, &.{
            .{ .name = "t-one", .ncomp = 3, .registry = 1 },
            host_two[1],
        });
        defer t.allocator.free(reg);
        try t.expect(!canonicalPactEquals(reg, base));
    }

    // Count change: a strict prefix is not the same registry.
    {
        const fewer = try encodePact(t.allocator, host_two[0..1]);
        defer t.allocator.free(fewer);
        try t.expect(!canonicalPactEquals(fewer, base));
        try t.expect(!canonicalPactEquals(base, fewer));
    }

    // A non-decodable host blob never equals anything, and the
    // zero-count encoding equals only itself.
    try t.expect(!canonicalPactEquals(base[0 .. base.len - 1], base));
    try t.expect(!canonicalPactEquals(base[4..], base));
    {
        const zero = try encodePact(t.allocator, &.{});
        defer t.allocator.free(zero);
        try t.expect(canonicalPactEquals(zero, zero));
        try t.expect(!canonicalPactEquals(zero, base));
    }
}
