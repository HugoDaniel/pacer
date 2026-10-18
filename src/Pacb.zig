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
//! `pacbWorstCase`, and the T2.2 transport stage (`decodeTransport`:
//! `'TRAN'`/`'TMPO'` domains, then the `TimeMap` rebuild in compile's own
//! op order). Stages expose owned, validated, typed results —
//! `parseDirectory` is still a structure-only view and `decodeTransport`
//! still leaves `emit` empty (`'EMIT'` lands in T2.4). The whole-blob
//! `decode(...) DecodedScore` entry point is deliberately absent until
//! every section stage validates (T2.8): returning a successful score
//! before registry/records/payloads/PACM are validated would be a lying
//! API.
//!
//! Imports: std, sjon (`Pattern.MAX_TICK`), `TimeMap`, `TrackTable` (the
//! T2.2 subset of the frozen end-state list). Later stages add
//! `PactCodec`, `Easing`, and `Pacm` as their GREEN needs them; this file
//! must NEVER import `Compile`, `Abi`, `Schema`, or `Driver` — the one
//! test that compares decoded transport against the compiler
//! (`decoded transport equals the compiled transport field-for-field`)
//! imports `Compile`/`test_support` INSIDE its test body only, so a
//! normal (non-test) build never analyses them through this file; that
//! textual cohabitation is the recorded plan-02 import seam, not strict
//! closure.

const std = @import("std");
const sjon = @import("sjon");
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
