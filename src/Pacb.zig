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
//! PHASE 2 COMPLETE (decoder wave) — the section stages plus the T2.8
//! whole-blob assembly. This file owns the container header, the
//! directory validator, the frozen caps,
//! `pacbWorstCase`, the T2.2 transport stage (`decodeTransport`:
//! `'TRAN'`/`'TMPO'` domains, then the `TimeMap` rebuild in compile's own
//! op order), the T2.3 registry-identity stage (`decodeRegistry`:
//! `'REGS'`/`'DECL'` + the `pact_fnv` fast-reject, with
//! `canonicalPactEquals` as the load-time identity check 02's `prt_load`
//! calls), the T2.4 record-sections stage (`decodeRecords`:
//! `'TRAK'`/`'KEYS'`/`'TICK'`/`'EMIT'`/`'SCEN'` — tracks, keys, scenes,
//! emit lanes; the id-bound consumers of the registry join for
//! `'TRAK'`/`'EMIT'` land there, `'CTRL'`'s with T2.5), the T2.5
//! ease/control stage (`decodeEaseControls`: `'EASE'` program
//! invariants + the synthesized linear default, `'STRS'`' sorted unique
//! non-reserved id table, `'CTRL'` join/env-only coherence), the T2.6
//! payload stage (`decodePayloads`: `'PAYL'` arithmetic/caps/
//! span discipline + the per-payload single-root structural walk over
//! `RtSjon.BinaryCursor`, schema-free, producing the per-track arena
//! copies), and the T2.8 whole-blob assembly (`decode` →
//! `DecodedScore` + `verifyRouting`, the PACM coherence cross-check).
//! The stages remain individually public — each owns its section's
//! validation — and `decode` is the only entry point that can return a
//! score: it never returns one the embedded PACM has not cross-checked
//! (`pacm_fnv` fast reject → `Pacm.decode` → `verifyRouting`).
//!
//! OWNERSHIP (`decode`): the score's arena is created FIRST and its
//! allocator is handed to every stage as that stage's `gpa` — a clean
//! ownership transfer, not a copy chain: each stage's sub-arena
//! allocates inside memory the returned score already owns, so the
//! stage structs die at return with their memory retained, no stage
//! arena can outlive `score.deinit()` (the one free), and a failed
//! stage's errdefer plus the outer errdefer leak nothing. Everything
//! the score exposes — registry bytes, control ids, payload copies,
//! trigger schedules, transport segments, the metadata blob — lives in
//! that one arena; nothing aliases the input buffer. The stages' own
//! standalone contracts (borrow-vs-own, `deinit`) are unchanged: a
//! caller that passes an ordinary allocator still gets a
//! self-contained stage.
//!
//! Imports: std, `RtSjon.zig` — the runtime closure's single SJON window
//! (02 T2.1: `Pattern.MAX_TICK`, `BinaryCursor`) — `PactCodec`,
//! `TimeMap`, `TrackTable`, `Easing`, `Pacm` (the frozen
//! end-state set). This file must NEVER import `Compile`, `Abi`,
//! `Schema`, or `Driver` — the compiler-oracle tests (`decoded
//! transport equals the compiled transport`, the T2.8 ownership and
//! coherence suite) import `Compile`/`test_support`/`Abi`/`ExprTrack`
//! INSIDE test bodies only, so a normal (non-test) build never
//! analyses them through this file; that textual cohabitation is the
//! recorded plan-02 import seam, not strict closure. The frozen
//! `ExprTrack.reserved_names` copy lives here for the same reason
//! (asserted against its source in `src/root.zig`).

const std = @import("std");
const RtSjon = @import("RtSjon.zig");
const PactCodec = @import("PactCodec.zig");
const TimeMap = @import("TimeMap.zig");
const TrackTable = @import("TrackTable.zig");
const Easing = @import("Easing.zig");
const Pacm = @import("Pacm.zig");

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
/// The binary payload walk's depth cap — a FROZEN COPY (02 T2.1 / C1):
/// the source constant lives on SJON's write side (`Binary.MAX_TREE_DEPTH`,
/// itself `BinaryFormat.MAX_TREE_DEPTH: u32 = 1024`), which the runtime
/// closure's `RtSjon` window deliberately does not carry, so it is
/// spelled here instead. Equality-pinned against the source in
/// `src/root.zig`'s frozen-copy test family, like every other copy.
pub const MAX_TREE_DEPTH: u32 = 1024;
/// The folded-tick envelope: the widest tick-domain value any decoded
/// field may carry. Scened fields (keys `at`, periodic `trig_offset`,
/// explicit `'TICK'` entries) are ONE checked i64 add of the scene start
/// (|v| ≤ `RtSjon.Pattern.MAX_TICK`) and a local position (|v| ≤
/// `RtSjon.Pattern.MAX_TICK`), so their producer envelope is exactly
/// ±2·MAX_TICK inclusive — 2·MAX_TICK itself is compile-reachable
/// (scene start MAX_TICK + local MAX_TICK) and accepted; everything past
/// it is producer-impossible and refused. Unfolded tick fields keep the
/// plain grid bound: `trig_every` ∈ 1..MAX_TICK (it converts at the map
/// origin and is never scene-folded), `'TMPO'`/`'TRAN'` `dur` stay
/// ≤ MAX_TICK (no fold exists there). The bound keeps every eval-side
/// subtraction (`t - at`, `t - offset`, widest intermediate `b.at -
/// a.at` ≤ 2⁵⁵) comfortably inside i64 for every probe |t| ≤ MAX_TICK.
pub const MAX_FOLDED_TICK: i64 = 2 * RtSjon.Pattern.MAX_TICK;

comptime {
    // Headroom for the eval-side arithmetic at the envelope: the widest
    // intermediate the runtime forms from folded values is bounded by a
    // small multiple of MAX_TICK (2·MAX_TICK + MAX_TICK ≤ 4·MAX_TICK),
    // which must never approach the i64 ceiling. Checked-inequality
    // form everywhere — no `@abs` on an i64 min can occur under this
    // bound (|v| ≤ 2·MAX_TICK ≪ |i64 min|).
    std.debug.assert(4 * RtSjon.Pattern.MAX_TICK < std.math.maxInt(i64));
}

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
    // Bounds-defended read: the documented precondition is that
    // `directory` is `parseDirectory`'s view of these same `bytes`; the
    // `sectionPayload` guard turns a mismatched pair into a refusal,
    // never a trap (the T2.4+ stage discipline, applied to the early
    // T2.2 reads too).
    const tr = try sectionPayload(bytes, tran, refusal);
    if (tr.len != TRAN_REC_LEN) {
        return fail(refusal, .directory_malformed, tran.off);
    }

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
        if (dur_field <= 0 or dur_field > RtSjon.Pattern.MAX_TICK) {
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
        // Mismatched-pair defense: the section slice must be in bounds
        // and exactly `4 + count × width` inside THIS buffer.
        const tmpo_payload = try sectionPayload(bytes, sec, refusal);
        if (tmpo_payload.len != 4 + @as(u64, seg_count) * TMPO_REC_LEN) {
            return fail(refusal, .directory_malformed, sec.off);
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
            if (tick > RtSjon.Pattern.MAX_TICK or tick < -RtSjon.Pattern.MAX_TICK) {
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
    // Bounds-defended read (the same `sectionPayload` discipline the
    // T2.4+ stages carry — a mismatched directory/buffer pair is a
    // refusal, never a trap).
    const tr = try sectionPayload(bytes, tran, refusal);
    if (tr.len != TRAN_REC_LEN) {
        return fail(refusal, .directory_malformed, tran.off);
    }
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
        const payload = try sectionPayload(bytes, sec, refusal);
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
        if (count == 0) {
            // The zero-declared join is the ABSENT section — an empty
            // 'DECL' is the same degenerate presence every other
            // section refuses ('REGS', 'TMPO', the record sections).
            return fail(refusal, .non_canonical, sec.off);
        }
        // Mismatched-pair defense: in bounds and exactly
        // `4 + count × width` inside THIS buffer.
        const decl_payload = try sectionPayload(bytes, sec, refusal);
        if (@as(u64, decl_payload.len) != 4 + @as(u64, count) * DECL_REC_LEN) {
            return fail(refusal, .directory_malformed, sec.off);
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
/// key runs (≥ 1 key, strictly ascending, `|at| ≤ MAX_FOLDED_TICK`,
/// lanes ≥ ncomp zero, slice-bounded) and trigger schedules (periodic
/// `every ∈ 1..MAX_TICK`, `|offset| ≤ MAX_FOLDED_TICK`; explicit
/// non-empty, strictly ascending, `|tick| ≤ MAX_FOLDED_TICK`
/// (the scened fold envelope), slice-bounded, and non-overlapping — the
/// section is the concatenation of every schedule); scene window ends checked-added;
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
    var has_pattern = false;
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
            } else if (src == SOURCE_PATTERN) {
                has_pattern = true;
            }
        }
    }
    if ((keys_sec != null) != has_keys_track) {
        return fail(refusal, .non_canonical, if (keys_sec) |s| s.off else payloadStart(directory));
    }
    if ((tick_sec != null) != has_explicit) {
        return fail(refusal, .non_canonical, if (tick_sec) |s| s.off else payloadStart(directory));
    }
    // The header's own bit definition: `required_features` bit0 is set
    // iff a pattern track exists. The producer sets it from the track
    // table, so a disagreement is producer-impossible — the two
    // spellings must agree (unknown bits were already refused by
    // `parseDirectory`; only bit0 can be set here).
    if ((directory.required_features & FEATURE_PATTERN_TRACKS != 0) != has_pattern) {
        return fail(refusal, .non_canonical, if (has_pattern and trak_sec != null)
            trak_sec.?.off
        else
            8);
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
    // previous one's end). 'KEYS' carries the same discipline — compile
    // appends each track's run disjointly (`keys_start = keys.len`
    // before the track's keys, `src/Compile.zig`).
    var prev_tick_end: ?u64 = null;
    var prev_key_end: ?u64 = null;
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
                    // Non-overlap in track order, like 'TICK' slices.
                    if (prev_key_end) |end| {
                        if (key_start < end) {
                            return fail(refusal, .key_invalid, at + 8);
                        }
                    }
                    prev_key_end = run_end;
                    const run = keys[@intCast(key_start)..][0..@intCast(key_len)];
                    for (run, 0..) |key, k| {
                        const key_at = keys_sec.?.off + 4 + (@as(usize, key_start) + k) * KEYS_REC_LEN;
                        if (k > 0 and key.at <= run[k - 1].at) {
                            return fail(refusal, .key_invalid, key_at);
                        }
                        // The folded-tick envelope: a scened key is one
                        // fold of two MAX_TICK-bounded values, so
                        // |at| ≤ 2·MAX_TICK inclusive and nothing past
                        // it is producible.
                        if (key.at > MAX_FOLDED_TICK or key.at < -MAX_FOLDED_TICK) {
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
                        // The compile rules: a positive interval that
                        // converts at the map origin (never folded, so
                        // the grid bound itself), and an offset within
                        // the folded envelope (the scene start folds in
                        // once — `t - offset` stays inside i64 for every
                        // probe tick).
                        if (trig_every <= 0 or trig_every > RtSjon.Pattern.MAX_TICK) {
                            return fail(refusal, .trigger_invalid, at + 24);
                        }
                        if (trig_offset > MAX_FOLDED_TICK or trig_offset < -MAX_FOLDED_TICK) {
                            return fail(refusal, .trigger_invalid, at + 32);
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
                            // The folded envelope (scened explicit ticks
                            // are absolute: one fold of scene start +
                            // local, both MAX_TICK-bounded — the parity
                            // bound `TrackTable` documents).
                            if (tick > MAX_FOLDED_TICK or tick < -MAX_FOLDED_TICK) {
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
            // A lane writes ONE scalar (`Eval` writes per lane name);
            // compile refuses non-scalar emit targets
            // (`target_arity_mismatch`), so the joined entry is ncomp 1.
            if (entry.ncomp != 1) {
                return fail(refusal, .registry_mismatch, at + 2);
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

// ---------------------------------------------------------------------------
// T2.5 — ease/control stage ('EASE' + 'STRS' + 'CTRL')
// ---------------------------------------------------------------------------

/// Wire stage-record width inside an `'EASE'` program (frozen copy of
/// `Abi.META_EASE_STAGE_LEN`; the comptime pin below ties it into
/// `PACM_EASE_PROGRAM_LEN`).
const PACM_EASE_STAGE_LEN: usize = 96;
/// Wire op-record width inside an `'EASE'` stage (frozen copy of
/// `Abi.META_EASE_OP_LEN`).
const PACM_EASE_OP_LEN: usize = 20;

comptime {
    std.debug.assert(PACM_EASE_PROGRAM_LEN == 4 + Easing.MAX_STAGES * PACM_EASE_STAGE_LEN);
    std.debug.assert(PACM_EASE_STAGE_LEN == 16 + Easing.MAX_OPS * PACM_EASE_OP_LEN);
}

/// Frozen copy of `ExprTrack.reserved_names` — the time-env binding
/// names a `'STRS'` control id must never shadow. `Pacb` does not
/// import `ExprTrack` (the decoder stays out of the eval closure);
/// `src/root.zig` equality-asserts the copy against its source.
pub const reserved_control_names = [_][]const u8{
    "t", "tick", "beat", "bar", "cycle", "phase", "bpm", "dur", "scene-beat", "scene-phase",
};

fn isReservedControlName(name: []const u8) bool {
    for (reserved_control_names) |reserved| {
        if (std.mem.eql(u8, reserved, name)) return true;
    }
    return false;
}

/// `'STRS'` sort order: by length first, then bytes — the canonical
/// spelling the packer emits and decode requires. Public: the T3.1
/// encoder sorts its `'STRS'` entries with THIS comparator, so producer
/// and decoder share one definition of the order (no second spelling).
pub fn strsEntryLess(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return a.len < b.len;
    return std.mem.order(u8, a, b) == .lt;
}

/// One decoded `(control …)` pin (frozen T2.1 representation, §A O-a:
/// the span-carrying `value_span` of `TrackTable.Control` never crosses
/// the wire). `id` is an arena-owned copy out of the `'STRS'` entries.
pub const DecodedControl = struct {
    id: []const u8,
    /// Resolved write target (same load-time join as tracks), or null
    /// for an env-only control (`target_id == NO_TARGET` on the wire).
    target: ?TrackTable.ControlTarget,
    ncomp: u8,
    kind: TrackTable.ControlType,
    /// Document `:value`, zero-padded like `TrackTable.Key.value`.
    value: [4]f32,
    /// Optional widget range — the record's flag bit decides presence.
    min: ?[4]f32,
    max: ?[4]f32,
};

/// Owned ease/control stage result. `programs` is the verbatim `'EASE'`
/// program table — or the synthesized shared linear default alone when
/// `'EASE'` is absent (the canonical-presence rule) — and `controls`
/// the decoded pins with ids copied out of `'STRS'`. Everything lives
/// in the stage's arena, never aliasing the input buffer, until T2.8's
/// final `DecodedScore` arena carries it all.
pub const EaseControlStage = struct {
    arena: std.heap.ArenaAllocator,
    programs: []const Easing.Program,
    controls: []const DecodedControl,

    pub fn deinit(self: *EaseControlStage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// The shared linear default, spelled exactly as compile spells it
/// (`Easing.primitive(.{ .code = .linear })`, `src/Compile.zig:491-493`):
/// a parameterless primitive cannot fail to build, so this is a
/// constant construction, never a user-input assert.
fn linearDefaultProgram() Easing.Program {
    return Easing.primitive(.{ .code = .linear }) catch unreachable;
}

/// Decode and validate the ease/control stage: the `'EASE'` program
/// table (`Program.eval` asserts its own invariants, so every
/// precondition is a checked refusal here first — `src/Easing.zig:162-170`),
/// the `'STRS'` control-id table, and the `'CTRL'` records joined
/// against the registry identity. Validation order: caps, canonical
/// presence (`'EASE'` present ⇒ ≥ 2 programs with program 0 linear —
/// the linear-only table is the omitted case; `'STRS'` iff a control
/// exists), section length arithmetic, per-record shape, then the join.
/// PRECONDITIONS: `directory` is `parseDirectory(bytes, …)`'s result,
/// `registry` and `records` the same-buffer stages
/// (`decodeRegistry`/`decodeRecords`) — the section-payload guard
/// turns a mismatched pair into a refusal, never a trap. `'PAYL'` and
/// the `'PACM'` cross-check are later stages' sections (T2.6/T2.8).
pub fn decodeEaseControls(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    directory: *const Directory,
    records: *const RecordsStage,
    registry: *const RegistryStage,
    refusal: ?*Refusal,
) DecodeError!EaseControlStage {
    const strs_sec = directory.find(.strs);
    const ctrl_sec = directory.find(.ctrl);
    const ease_sec = directory.find(.ease);

    // Caps before any allocation keyed by a lying count ('CTRL' is
    // fixed-width, so T2.1 already proved count×60; 'STRS' owns its
    // own u32 count below; 'EASE' owns program_count).
    if (ctrl_sec) |sec| {
        if (sec.count.? > MAX_CONTROLS) {
            return fail(refusal, .cap_exceeded, sec.off);
        }
    }

    // Canonical presence + the iff-consumer rule: 'STRS' iff a control
    // exists ('CTRL' present ⇔ ≥ 1 control; a present count-0 section
    // is the degenerate, omitted case).
    if (strs_sec != null and ctrl_sec == null) {
        return fail(refusal, .non_canonical, if (strs_sec) |s| s.off else payloadStart(directory));
    }
    if (ctrl_sec) |sec| {
        if (sec.count.? == 0) return fail(refusal, .non_canonical, sec.off);
        if (strs_sec == null) {
            return fail(refusal, .non_canonical, payloadStart(directory));
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    // --- 'STRS': parse + validate the sorted unique id table ---
    const StrEntry = struct { byte_start: u32, len: u16 };
    var entries: []const StrEntry = &.{};
    var strs_region: []const u8 = &.{};
    if (strs_sec) |sec| {
        const payload = try sectionPayload(bytes, sec, refusal);
        if (payload.len < 8) return fail(refusal, .strs_invalid, sec.off);
        const count = readU32(payload, 0);
        if (count > MAX_CONTROLS) return fail(refusal, .cap_exceeded, sec.off);
        if (count == 0) return fail(refusal, .non_canonical, sec.off);
        const byte_size = readU32(payload, 4);
        if (@as(u64, byte_size) != payload.len - 8) {
            return fail(refusal, .strs_invalid, sec.off + 4);
        }
        if (byte_size == 0) return fail(refusal, .non_canonical, sec.off + 4);

        const list = a.alloc(StrEntry, count) catch return error.OutOfMemory;
        var prev: []const u8 = &.{};
        var pos: usize = 8;
        for (0..count) |i| {
            if (pos + 2 > payload.len) return fail(refusal, .strs_invalid, pos);
            const elen = readU16(payload, pos);
            if (elen == 0) return fail(refusal, .strs_invalid, pos);
            if (pos + 2 + elen > payload.len) return fail(refusal, .strs_invalid, pos);
            const slice = payload[pos + 2 ..][0..elen];
            if (i > 0) {
                // Sorted by (len, bytes) and unique — one rule: the
                // sequence is strictly increasing under the sort order.
                if (!strsEntryLess(prev, slice)) {
                    return fail(refusal, .strs_invalid, pos);
                }
            }
            if (isReservedControlName(slice)) {
                return fail(refusal, .strs_invalid, pos + 2);
            }
            list[i] = .{ .byte_start = @intCast(pos + 2 - 8), .len = elen };
            prev = slice;
            // `2 + elen` alone would compute in u16 and overflow at the
            // 65535-byte boundary id — widen before the add (the same
            // discipline as the `pos + 2 + elen` bound check above).
            pos += 2 + @as(usize, elen);
        }
        // The entries consume byte_size exactly — no tail slack.
        if (pos != payload.len) return fail(refusal, .strs_invalid, pos);
        entries = list;
        strs_region = payload[8..];
    }

    // --- 'EASE': parse + validate the program table ---
    var programs: []const Easing.Program = &.{};
    if (ease_sec) |sec| {
        const payload = try sectionPayload(bytes, sec, refusal);
        if (payload.len < 4) return fail(refusal, .ease_invalid, sec.off);
        const n = readU32(payload, 0);
        if (n > MAX_EASE_PROGRAMS) return fail(refusal, .cap_exceeded, sec.off);
        if (n < 2) {
            // The linear-only table is the omitted case.
            return fail(refusal, .non_canonical, sec.off);
        }
        const table_end = 4 + @as(u64, n) * PACM_EASE_PROGRAM_LEN + 4;
        if (table_end > payload.len) return fail(refusal, .ease_invalid, sec.off);
        const key_ref_count = readU32(payload, 4 + @as(usize, n) * PACM_EASE_PROGRAM_LEN);
        const expected_len = table_end + @as(u64, key_ref_count) * 2;
        if (expected_len != payload.len) {
            return fail(refusal, .ease_invalid, sec.off);
        }

        const table = a.alloc(Easing.Program, n) catch return error.OutOfMemory;
        for (0..n) |i| {
            try validateEaseProgramWire(payload, 4 + i * PACM_EASE_PROGRAM_LEN, refusal);
            table[i] = readEaseProgram(payload, 4 + i * PACM_EASE_PROGRAM_LEN);
        }
        // Program 0 is the shared linear default — the anchor every
        // ease_ref 0 names and Eval's fallback leans on.
        if (!std.meta.eql(table[0], linearDefaultProgram())) {
            return fail(refusal, .ease_invalid, sec.off + 4);
        }
        // The refs array parallels the key stream in key order.
        if (key_ref_count != records.keys.len) {
            return fail(refusal, .count_mismatch, 4 + @as(usize, n) * PACM_EASE_PROGRAM_LEN);
        }
        for (0..key_ref_count) |i| {
            const at = 4 + @as(usize, n) * PACM_EASE_PROGRAM_LEN + 4 + i * 2;
            if (readU16(payload, at) >= n) {
                return fail(refusal, .ease_invalid, at);
            }
            // The refs array is a redundant spelling of the key stream's
            // `ease_ref` field — the producer writes both from one pass
            // (`Abi.encodeMeta` walks `table.keys` for the refs exactly
            // as the records do). Two spellings of one truth may never
            // disagree: elementwise coherence, the same identity
            // discipline `'REGS'` carries.
            if (readU16(payload, at) != records.keys[i].ease_ref) {
                return fail(refusal, .ease_invalid, at);
            }
        }
        programs = table;
    } else {
        const table = a.alloc(Easing.Program, 1) catch return error.OutOfMemory;
        table[0] = linearDefaultProgram();
        programs = table;
    }

    // The final ease_ref bound over the real (or synthesized) table —
    // subsumes decodeRecords' absent-section check and catches any
    // index that dangles past the programs the score carries.
    for (records.keys) |key| {
        if (key.ease_ref >= programs.len) {
            return fail(refusal, .ease_invalid, 0);
        }
    }

    // --- 'CTRL': parse + validate the control records ---
    const join_size: u64 = @as(u64, registry.host_targets) + registry.declared_targets;
    var used_entries = a.alloc(bool, entries.len) catch return error.OutOfMemory;
    @memset(used_entries, false);

    var controls: []const DecodedControl = &.{};
    if (ctrl_sec) |sec| {
        _ = try sectionPayload(bytes, sec, refusal); // bounds guard, then absolute reads
        const count: usize = sec.count.?; // count×width exactness is T2.1's
        const recs = a.alloc(DecodedControl, count) catch return error.OutOfMemory;
        for (recs, 0..) |*rec, i| {
            const at = sec.off + 4 + i * CTRL_REC_LEN;
            const flags = bytes[at + 5];
            if (flags & ~@as(u8, 0b11) != 0) {
                return fail(refusal, .control_invalid, at + 5);
            }
            const kind = std.enums.fromInt(TrackTable.ControlType, bytes[at + 4]) orelse
                return fail(refusal, .control_invalid, at + 4);

            // The id must be exactly one 'STRS' entry (byte_start +
            // length), never used before — ids are unique because the
            // entries are.
            const id_off = readU32(bytes, at + 6);
            const id_len = readU16(bytes, at + 10);
            var id: []const u8 = &.{};
            var matched: ?usize = null;
            if (@as(u64, id_off) + id_len <= strs_region.len) {
                for (entries, 0..) |entry, e| {
                    if (entry.byte_start == id_off and entry.len == id_len) {
                        matched = e;
                        break;
                    }
                }
            }
            const entry_index = matched orelse
                return fail(refusal, .control_invalid, at + 6);
            if (used_entries[entry_index]) {
                return fail(refusal, .control_invalid, at + 6);
            }
            used_entries[entry_index] = true;
            id = strs_region[@intCast(id_off)..][0..id_len];

            const target_id = readU16(bytes, at);
            const ctl_registry = bytes[at + 2];
            const ncomp = bytes[at + 3];
            var target: ?TrackTable.ControlTarget = null;
            if (target_id == TrackTable.NO_TARGET) {
                // Env-only: no join entry exists to check against, so
                // ncomp carries its own 1..4 domain and the registry
                // byte (unused-by-target) spells zero.
                if (ctl_registry != 0) {
                    return fail(refusal, .control_invalid, at + 2);
                }
                if (ncomp < 1 or ncomp > 4) {
                    return fail(refusal, .control_invalid, at + 3);
                }
            } else {
                if (@as(u64, target_id) >= join_size) {
                    return fail(refusal, .registry_mismatch, at);
                }
                const entry = joinEntry(registry, target_id) orelse
                    return fail(refusal, .registry_mismatch, at);
                if (entry.registry != ctl_registry or entry.ncomp != ncomp) {
                    return fail(refusal, .registry_mismatch, at + 2);
                }
                target = .{ .id = target_id, .registry = ctl_registry };
            }

            var value: [4]f32 = undefined;
            for (0..4) |lane| value[lane] = readF32(bytes, at + 12 + lane * 4);
            var lane = @as(usize, ncomp);
            while (lane < 4) : (lane += 1) {
                if (value[lane] != 0) {
                    return fail(refusal, .control_invalid, at + 12 + lane * 4);
                }
            }

            var min: ?[4]f32 = null;
            if (flags & 1 != 0) {
                var lanes: [4]f32 = undefined;
                for (0..4) |l| lanes[l] = readF32(bytes, at + 28 + l * 4);
                for (lanes) |v| {
                    if (!std.math.isFinite(v)) return fail(refusal, .control_invalid, at + 28);
                }
                min = lanes;
            } else {
                for (0..4) |l| {
                    if (readF32(bytes, at + 28 + l * 4) != 0) {
                        return fail(refusal, .control_invalid, at + 28 + l * 4);
                    }
                }
            }
            var max: ?[4]f32 = null;
            if (flags & 2 != 0) {
                var lanes: [4]f32 = undefined;
                for (0..4) |l| lanes[l] = readF32(bytes, at + 44 + l * 4);
                for (lanes) |v| {
                    if (!std.math.isFinite(v)) return fail(refusal, .control_invalid, at + 44);
                }
                max = lanes;
            } else {
                for (0..4) |l| {
                    if (readF32(bytes, at + 44 + l * 4) != 0) {
                        return fail(refusal, .control_invalid, at + 44 + l * 4);
                    }
                }
            }

            rec.* = .{
                .id = a.dupe(u8, id) catch return error.OutOfMemory,
                .target = target,
                .ncomp = ncomp,
                .kind = kind,
                .value = value,
                .min = min,
                .max = max,
            };
        }
        controls = recs;
    }

    return .{ .arena = arena, .programs = programs, .controls = controls };
}

/// Highest legal `Easing.Op` wire ordinal (the enum is exhaustive and
/// append-only; 21 = `spring` today).
const EASE_OP_MAX_ORDINAL: u8 = @intCast(@typeInfo(Easing.Op).@"enum".fields.len - 1);

/// Validate one 772-byte `'EASE'` program record in place — every
/// precondition `Program.eval` asserts (`len` 1..8, `denom > 0` via
/// strictly increasing `t_end` from a virtual 0), plus the format's own
/// canonical rules: pads zero, finite floats, op ordinals in range, and
/// every unused stage/op slot byte-zero (the normalized-on-copy
/// convention — one spelling per program).
fn validateEaseProgramWire(
    payload: []const u8,
    at: usize,
    refusal: ?*Refusal,
) DecodeError!void {
    const len = payload[at];
    if (len < 1 or len > Easing.MAX_STAGES) {
        return fail(refusal, .ease_invalid, at);
    }
    if (!std.mem.allEqual(u8, payload[at + 1 .. at + 4], 0)) {
        return fail(refusal, .ease_invalid, at + 1);
    }
    var prev_end: f32 = 0;
    for (0..Easing.MAX_STAGES) |i| {
        const sat = at + 4 + i * PACM_EASE_STAGE_LEN;
        if (i >= len) {
            // Unused stage slot: byte-zero.
            if (!std.mem.allEqual(u8, payload[sat .. sat + PACM_EASE_STAGE_LEN], 0)) {
                return fail(refusal, .ease_invalid, sat);
            }
            continue;
        }
        const t_end = readF32(payload, sat);
        const v_base = readF32(payload, sat + 4);
        const v_span = readF32(payload, sat + 8);
        if (!std.math.isFinite(t_end) or !std.math.isFinite(v_base) or !std.math.isFinite(v_span)) {
            return fail(refusal, .ease_invalid, sat);
        }
        // Strictly increasing from the virtual 0 boundary: this is the
        // `denom > 0` eval assert, pre-checked.
        if (!(t_end > prev_end)) {
            return fail(refusal, .ease_invalid, sat);
        }
        prev_end = t_end;
        const ops_len = payload[sat + 12];
        if (ops_len > Easing.MAX_OPS) {
            return fail(refusal, .ease_invalid, sat + 12);
        }
        if (!std.mem.allEqual(u8, payload[sat + 13 .. sat + 16], 0)) {
            return fail(refusal, .ease_invalid, sat + 13);
        }
        for (0..Easing.MAX_OPS) |j| {
            const oat = sat + 16 + j * PACM_EASE_OP_LEN;
            if (j >= ops_len) {
                // Unused op slot: byte-zero.
                if (!std.mem.allEqual(u8, payload[oat .. oat + PACM_EASE_OP_LEN], 0)) {
                    return fail(refusal, .ease_invalid, oat);
                }
                continue;
            }
            if (payload[oat] > EASE_OP_MAX_ORDINAL) {
                return fail(refusal, .ease_invalid, oat);
            }
            if (!std.mem.allEqual(u8, payload[oat + 1 .. oat + 4], 0)) {
                return fail(refusal, .ease_invalid, oat + 1);
            }
            for (0..4) |p| {
                if (!std.math.isFinite(readF32(payload, oat + 4 + p * 4))) {
                    return fail(refusal, .ease_invalid, oat + 4 + p * 4);
                }
            }
        }
    }
}

/// Read one 772-byte `'EASE'` program record into an `Easing.Program`.
/// All stage/op slots are copied — the wire's zeroed unused slots ARE
/// the canonical zero-fill (`Program.zero_stage` spells code 0 with
/// zero params), so a faithful copy reproduces the canonical struct.
fn readEaseProgram(payload: []const u8, at: usize) Easing.Program {
    var prog: Easing.Program = .{
        .len = payload[at],
        .stages = @splat(Easing.Program.zero_stage),
    };
    for (0..Easing.MAX_STAGES) |i| {
        const sat = at + 4 + i * PACM_EASE_STAGE_LEN;
        var stage: Easing.Stage = .{
            .t_end = readF32(payload, sat),
            .v_base = readF32(payload, sat + 4),
            .v_span = readF32(payload, sat + 8),
            .ops_len = payload[sat + 12],
            .ops = @splat(.{ .code = .linear, .params = .{ 0, 0, 0, 0 } }),
        };
        for (0..Easing.MAX_OPS) |j| {
            const oat = sat + 16 + j * PACM_EASE_OP_LEN;
            stage.ops[j] = .{
                // Out-of-range bytes degrade to linear here so the
                // carry never trips the exhaustive-enum check; the
                // validated stage refuses them before this read.
                .code = std.enums.fromInt(Easing.Op, payload[oat]) orelse .linear,
                .params = .{
                    readF32(payload, oat + 4),
                    readF32(payload, oat + 8),
                    readF32(payload, oat + 12),
                    readF32(payload, oat + 16),
                },
            };
        }
        prog.stages[i] = stage;
    }
    return prog;
}

/// Owned payload stage result: per-track payload COPIES, parallel to
/// `RecordsStage.tracks` (empty slices for non-payload sources) — the
/// seam T2.8's `DecodedScore` assembly zips into the still-empty
/// `DecodedSource.expr`/`pattern` arms. Each expr/pattern entry is the
/// arena-owned, structurally validated SJON binary-IR buffer the
/// track's `(payload_off, payload_len)` addresses.
pub const PayloadStage = struct {
    arena: std.heap.ArenaAllocator,
    payloads: []const []const u8,

    pub fn deinit(self: *PayloadStage) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Decode and validate the payload stage: the `'PAYL'` section's
/// length arithmetic and caps, the iff-consumer rule (`'PAYL'` iff an
/// expr/pattern track exists), every track span's bounds and
/// non-overlap, and each payload's STRUCTURAL consumption — a
/// `BinaryCursor` over the copy: header/pool/roots-offset equality,
/// exactly one root, a full depth-first walk over every node kind at
/// its exact wire width, ending exactly at `payload_len` (trailing
/// slack inside a payload refuses). No evaluation, no schema, no
/// compiler — pattern-payload acceptance stays schema-free until 02 P4
/// (the `'PAYL'`-walk is the 01-local seam 02 reroutes through
/// `RtSjon`). PRECONDITIONS: `directory` is `parseDirectory(bytes, …)`'s
/// result and `records` the same-buffer `decodeRecords` stage — the
/// section-payload guard turns a mismatched pair into a refusal, never
/// a trap. Validation order: presence/canonical shape, section
/// arithmetic, total cap, span caps/bounds/overlap, then the walk.
pub fn decodePayloads(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    directory: *const Directory,
    records: *const RecordsStage,
    refusal: ?*Refusal,
) DecodeError!PayloadStage {
    const payl_sec = directory.find(.payl);

    // Cross-section presence is CHECKED, not implied: 'PAYL' iff an
    // expr/pattern track exists (the track sources are T2.4-validated
    // by the time this stage runs).
    var has_payload_track = false;
    for (records.tracks) |track| {
        switch (track.source) {
            .expr, .pattern => has_payload_track = true,
            .keys, .trigger => {},
        }
    }
    if (payl_sec != null and !has_payload_track) {
        return fail(refusal, .non_canonical, payl_sec.?.off);
    }
    if (payl_sec == null and has_payload_track) {
        return fail(refusal, .non_canonical, payloadStart(directory));
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const payloads = a.alloc([]const u8, records.tracks.len) catch return error.OutOfMemory;
    for (payloads) |*slot| slot.* = &.{};

    if (payl_sec) |sec| {
        const payload = try sectionPayload(bytes, sec, refusal);
        if (payload.len < 4) return fail(refusal, .payload_malformed, sec.off);
        const byte_size = readU32(payload, 0);
        if (@as(u64, byte_size) != payload.len - 4) {
            return fail(refusal, .payload_malformed, sec.off);
        }
        if (byte_size == 0) {
            // The degenerate region is the omitted section.
            return fail(refusal, .non_canonical, sec.off);
        }
        if (byte_size > MAX_PAYL_BYTES) {
            return fail(refusal, .cap_exceeded, sec.off);
        }
        const region = payload[4..];

        // Spans: per-payload cap, region bounds (checked u64 adds), and
        // non-overlap in track order — the 'TICK' discipline.
        var prev_end: ?u64 = null;
        for (records.tracks, records.payload_spans) |track, span| {
            switch (track.source) {
                .expr, .pattern => {
                    if (span.len > MAX_PAYLOAD_BYTES) {
                        return fail(refusal, .cap_exceeded, sec.off + 4 + span.off);
                    }
                    const end = @as(u64, span.off) + span.len;
                    if (end > byte_size) {
                        return fail(refusal, .payload_malformed, sec.off + 4 + span.off);
                    }
                    if (prev_end) |pe| {
                        if (span.off < pe) {
                            return fail(refusal, .payload_malformed, sec.off + 4 + span.off);
                        }
                    }
                    prev_end = end;
                },
                .keys, .trigger => {},
            }
        }

        // Copy first, then walk the copy — the validated bytes and the
        // returned payload are the same arena memory.
        for (records.tracks, records.payload_spans, payloads) |track, span, *out| {
            switch (track.source) {
                .expr, .pattern => {
                    const copy = a.dupe(u8, region[span.off..][0..span.len]) catch
                        return error.OutOfMemory;
                    try walkPayloadStructurally(a, copy, refusal, sec.off + 4 + span.off);
                    out.* = copy;
                },
                .keys, .trigger => {},
            }
        }
    }

    return .{ .arena = arena, .payloads = payloads };
}

/// The payload structural-consumption walk (the plan's rule): run the
/// SJON binary cursor over one copied payload — `Cursor.init` proves
/// the header, both pools, and the roots-offset equality (it already
/// rejects pool↔roots slack); exactly one root is required (the
/// `MultipleRoots` rule — zero is the same defect class here); and a
/// full depth-first walk through the cursor's own child/vector
/// iterators consumes EVERY node kind at its exact wire width, covering
/// branches an evaluation would never visit. The walk must end exactly
/// at `payload.len`. Iterative, like `PatternQuery.compileBinary`'s
/// frame machine — the cursor is single-pass and monotonic, so a frame
/// pushed mid-iteration runs to completion and the parent resumes at
/// the next child. Depth is capped at the wire format's own
/// `MAX_TREE_DEPTH` (the encoder never nests deeper); a deeper payload
/// is malformed, never a native-stack gamble. Every `BinaryCursor`
/// error maps to `payload_malformed` — deterministic, host-identical.
fn walkPayloadStructurally(
    a: std.mem.Allocator,
    payload: []const u8,
    refusal: ?*Refusal,
    payload_at: usize,
) DecodeError!void {
    const BC = RtSjon.BinaryCursor;

    var cursor = BC.Cursor.init(payload) catch {
        return fail(refusal, .payload_malformed, payload_at);
    };
    // O(1) pool lookups: the walk resolves a pool entry per
    // string/keyword/symbol/head/unit node, and the entries are only
    // forward-walkable without an index (O(M×N) worst case). The index
    // lives on the stage arena, exactly as `compileBinary` places it.
    const pool_index = a.alloc(u32, cursor.poolIndexLen()) catch return error.OutOfMemory;
    cursor.indexPools(pool_index);

    var roots = cursor.rootIter() catch {
        return fail(refusal, .payload_malformed, payload_at);
    };
    if (roots.remaining != 1) {
        // Zero roots or multiple roots: a payload is one subtree.
        return fail(refusal, .payload_malformed, payload_at);
    }
    const root = (roots.next() catch {
        return fail(refusal, .payload_malformed, payload_at);
    }).?;

    const WalkFrame = union(enum) {
        vec: BC.VectorIter,
        children: BC.ChildIter,
    };
    var stack: [MAX_TREE_DEPTH]WalkFrame = undefined;
    var depth: usize = 0;

    var current = root;
    while (true) {
        // Consume the node's variant payload at its exact width.
        switch (current.kind) {
            .vector => {
                if (depth >= stack.len) {
                    return fail(refusal, .payload_malformed, payload_at);
                }
                const iter = BC.readVector(&cursor, current) catch
                    return fail(refusal, .payload_malformed, payload_at);
                stack[depth] = .{ .vec = iter };
                depth += 1;
            },
            .form => {
                if (depth >= stack.len) {
                    return fail(refusal, .payload_malformed, payload_at);
                }
                const form = BC.readForm(&cursor, current) catch
                    return fail(refusal, .payload_malformed, payload_at);
                stack[depth] = .{ .children = form.children };
                depth += 1;
            },
            .nil => BC.readNil(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .boolean => _ = BC.readBoolean(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .number => _ = BC.readNumber(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .number_with_unit => _ = BC.readNumberWithUnit(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .date => _ = BC.readDate(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .time => _ = BC.readTime(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .string => _ = BC.readString(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .keyword => _ = BC.readKeyword(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
            .symbol => _ = BC.readSymbol(&cursor, current) catch
                return fail(refusal, .payload_malformed, payload_at),
        }

        // Descend: pull the next node view off the top of the stack,
        // popping exhausted iterators (their trailing-comment fields
        // are consumed by the final null return, keeping the cursor's
        // own accounting exact).
        var next: ?BC.NodeView = null;
        while (depth > 0) {
            const top = &stack[depth - 1];
            switch (top.*) {
                .vec => |*iter| {
                    if (iter.next() catch
                        return fail(refusal, .payload_malformed, payload_at)) |view|
                    {
                        next = view;
                        break;
                    }
                },
                .children => |*iter| {
                    if (iter.next() catch
                        return fail(refusal, .payload_malformed, payload_at)) |entry|
                    {
                        next = entry.value;
                        break;
                    }
                },
            }
            depth -= 1;
        }
        if (next) |view| {
            current = view;
            continue;
        }
        break;
    }

    // The walk consumed every node it could reach: the payload must
    // end exactly here — trailing slack inside a payload refuses.
    if (@as(usize, cursor.pos) != payload.len) {
        return fail(refusal, .payload_malformed, payload_at + cursor.pos);
    }
}

// ---------------------------------------------------------------------------
// T2.8 — whole-blob decode: DecodedScore assembly + PACM coherence
// ---------------------------------------------------------------------------

/// The whole decoded score: every stage's owned result assembled into
/// ONE arena-backed value (the T2.1 §A O-a repr, plus the header's
/// `required_features` word and the embedded `'PACM'` blob — carried
/// owned for the future stages that route on them: 02's runtime, the
/// T3.1 encoder's self-check). No AST anywhere: the `expr`/`pattern`
/// arms are payload byte slices, `trigger` an arena-owned schedule,
/// `keys` the flat stream — the decoded score is data at rest,
/// evaluable but never a compiled tree.
pub const DecodedScore = struct {
    arena: std.heap.ArenaAllocator,
    /// The header's feature word (bit0 = pattern tracks), already
    /// cross-checked against the track table by `decodeRecords`.
    required_features: u32,
    /// The final transport: the T2.2 rebuild with `'EMIT'` folded in
    /// (the lanes were `RecordsStage.emit`, arena-owned like everything
    /// else).
    transport: TrackTable.Transport,
    tracks: []const DecodedTrack,
    keys: []const TrackTable.Key,
    programs: []const Easing.Program,
    controls: []const DecodedControl,
    scenes: []const DecodedScene,
    regs: []const u8,
    declared: []const Decl,
    /// Deep, arena-owned copy of the embedded `'PACM'` blob — the one
    /// byte range the section stages never copied (they validate the
    /// sections; the metadata is copied once, here).
    pacm: []const u8,
    pact_fnv: u64,
    pacm_fnv: u64,

    pub fn deinit(self: *DecodedScore) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Bit-for-bit `[4]f32` lane equality. Both wires spell one producer
/// pass, so equal BITS are the coherence predicate — `==` would misread
/// a NaN lane present on both sides as a lie.
fn lanesEq(a: [4]f32, b: [4]f32) bool {
    for (a, b) |x, y| {
        if (@as(u32, @bitCast(x)) != @as(u32, @bitCast(y))) return false;
    }
    return true;
}

/// The PACM↔section coherence cross-check (T2.8; placement per the
/// focused ruling — here, not in std-only `Pacm`). Compares every
/// ROUTING field the two spellings of one compile must agree on —
/// transport scalars, counts, per-track identity + the per-source
/// key-range rule (B1/G9: a keys track's PACM range IS the `'TRAK'`
/// fields; every other source's meta range is the constant `(0,0)`,
/// never compared against a real `'TICK'` slice), key content, control
/// identity/values, the shared scene fields, and `'EASE'`/`'TMPO'`
/// presence + content. Documented spans and source strings (name spans,
/// value spans, track spans) are TRUSTED, never cross-checked: the
/// decoder has no source text, and those fields are anchors for a
/// consumer that does. Returns the refusal code (always
/// `meta_incoherent` today) or null when the metadata tells the truth.
pub fn verifyRouting(view: *const Pacm.MetaView, score: *const DecodedScore) ?RefusalCode {
    // Transport scalars: the PACM header restates 'TRAN''s truth.
    if (@as(u64, @bitCast(view.bpm)) != @as(u64, @bitCast(score.transport.map.bpm))) {
        return .meta_incoherent;
    }
    if (view.beats_per_bar != score.transport.map.beats_per_bar) {
        return .meta_incoherent;
    }
    if (view.dur != score.transport.dur) return .meta_incoherent;
    if (view.end_loop != (score.transport.end == .loop)) return .meta_incoherent;

    // Counts: three more spellings of one table.
    if (view.trackCount() != score.tracks.len) return .meta_incoherent;
    if (view.keyCount() != score.keys.len) return .meta_incoherent;
    if (view.controlCount() != score.controls.len) return .meta_incoherent;

    // Per-track identity + the per-source key-range rule (B1/G9).
    for (score.tracks, 0..) |track, i| {
        const meta = view.track(i);
        if (meta.target_id != track.target_id) return .meta_incoherent;
        if (meta.registry != track.registry) return .meta_incoherent;
        if (meta.ncomp != track.ncomp) return .meta_incoherent;
        switch (track.source) {
            // A keys track's PACM range IS the 'TRAK' fields.
            .keys => |ks| {
                if (meta.source != .keys) return .meta_incoherent;
                if (meta.key_start != ks.start) return .meta_incoherent;
                if (meta.key_len != ks.len) return .meta_incoherent;
            },
            // Every other source's meta range is the constant (0,0) —
            // `Abi.encodeMeta`'s own spelling (`src/Abi.zig:437-440`);
            // it is never compared against a real 'TICK' slice, which
            // 'TRAK' carries for an explicit trigger.
            .expr, .trigger, .pattern => {
                const want: u8 = switch (track.source) {
                    .expr => SOURCE_EXPR,
                    .trigger => SOURCE_TRIGGER,
                    .pattern => SOURCE_PATTERN,
                    .keys => unreachable,
                };
                if (@intFromEnum(meta.source) != want) return .meta_incoherent;
                if (meta.key_start != 0 or meta.key_len != 0) return .meta_incoherent;
            },
        }
    }

    // Key content: the flat stream, at + value lanes (bit-equal — both
    // spellings come from one producer pass; a NaN lane on both sides
    // is agreement, not a lie).
    for (score.keys, 0..) |key, i| {
        const meta = view.key(i);
        if (meta.at != key.at) return .meta_incoherent;
        if (!lanesEq(meta.value, key.value)) return .meta_incoherent;
    }

    // Controls: identity (id, target presence + triple, ncomp, kind)
    // and value lanes; min/max compare presence AND lanes (the absent
    // side is zero-spelled on both wires, but a flag lie refuses even
    // when the lanes happen to be zero).
    var it = view.controls();
    for (score.controls) |ctl| {
        const meta = it.next() orelse return .meta_incoherent;
        if (!std.mem.eql(u8, meta.id, ctl.id)) return .meta_incoherent;
        if (ctl.target) |tg| {
            if (meta.target_id == null or meta.target_id.? != tg.id) {
                return .meta_incoherent;
            }
            if (meta.registry != tg.registry) return .meta_incoherent;
        } else {
            if (meta.target_id != null) return .meta_incoherent;
            if (meta.registry != 0) return .meta_incoherent;
        }
        if (meta.ncomp != ctl.ncomp) return .meta_incoherent;
        if (@intFromEnum(meta.kind) != @intFromEnum(ctl.kind)) return .meta_incoherent;
        if (!lanesEq(meta.value, ctl.value)) return .meta_incoherent;
        if ((meta.min == null) != (ctl.min == null)) return .meta_incoherent;
        if (meta.min != null and !lanesEq(meta.min.?, ctl.min.?)) return .meta_incoherent;
        if ((meta.max == null) != (ctl.max == null)) return .meta_incoherent;
        if (meta.max != null and !lanesEq(meta.max.?, ctl.max.?)) return .meta_incoherent;
    }

    // Scenes: the shared window fields; the name span is a documented
    // source string — trusted, never cross-checked.
    if (view.sceneCount() != score.scenes.len) return .meta_incoherent;
    for (score.scenes, 0..) |scene, i| {
        const meta = view.scene(i);
        if (meta.start_tick != scene.start_tick) return .meta_incoherent;
        if (meta.dur_ticks != scene.dur_ticks) return .meta_incoherent;
    }

    // 'EASE': presence parity first — a present 'EASE' section is the
    // only way programs.len > 1 (the synthesized linear default alone is
    // the omitted case) — then content: every program field, and the
    // refs array as a second spelling of the key stream's ease_ref
    // fields (elementwise, like the PACB-side stage rule).
    const ease_present = score.programs.len > 1;
    if ((view.ease != null) != ease_present) return .meta_incoherent;
    if (ease_present) {
        if (view.easeProgramCount() != score.programs.len) return .meta_incoherent;
        for (score.programs, 0..) |*prog, i| {
            const meta = view.easeProgram(i);
            if (meta.len != prog.len) return .meta_incoherent;
            for (meta.stages, prog.stages) |ms, ps| {
                if (@as(u32, @bitCast(ms.t_end)) != @as(u32, @bitCast(ps.t_end))) return .meta_incoherent;
                if (@as(u32, @bitCast(ms.v_base)) != @as(u32, @bitCast(ps.v_base))) return .meta_incoherent;
                if (@as(u32, @bitCast(ms.v_span)) != @as(u32, @bitCast(ps.v_span))) return .meta_incoherent;
                if (ms.ops_len != ps.ops_len) return .meta_incoherent;
                for (ms.ops, ps.ops) |mo, po| {
                    if (mo.code != @intFromEnum(po.code)) return .meta_incoherent;
                    if (!lanesEq(mo.params, po.params)) return .meta_incoherent;
                }
            }
        }
        if (view.easeRefCount() != score.keys.len) return .meta_incoherent;
        for (score.keys, 0..) |key, i| {
            if (view.easeRef(i) != key.ease_ref) return .meta_incoherent;
        }
    }

    // 'TMPO': presence parity, then the authored segment table.
    const tmpo_present = score.transport.segments.len > 1;
    if ((view.tmpo != null) != tmpo_present) return .meta_incoherent;
    if (tmpo_present) {
        if (view.tempoCount() != score.transport.segments.len) return .meta_incoherent;
        for (score.transport.segments, 0..) |seg, i| {
            const meta = view.tempoSeg(i);
            if (meta.tick != seg.start_tick) return .meta_incoherent;
            if (@as(u64, @bitCast(meta.bpm)) != @as(u64, @bitCast(seg.bpm))) {
                return .meta_incoherent;
            }
        }
    }

    return null;
}

/// Decode one whole `'PACB'` buffer into an owned score. Validation is
/// the full staged chain — directory, transport, registry identity,
/// records, ease/control, payloads — closed by the PACM coherence
/// cross-check (`pacm_fnv` fast reject, `Pacm.decode` structural,
/// `verifyRouting` semantic). Refusal classes: structural garbage in
/// the embedded PACM ⇒ `meta_malformed`; every PACM↔section
/// disagreement (including the checksum alone) ⇒ `meta_incoherent`; a
/// missing required `'PACM'` ⇒ `non_canonical`; earlier classes per
/// their owning stage. The returned score owns every byte it exposes
/// (see OWNERSHIP in the module header); `bytes` may be freed or
/// clobbered the moment `decode` returns.
pub fn decode(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    refusal: ?*Refusal,
) DecodeError!DecodedScore {
    var directory = try parseDirectory(bytes, refusal);
    const pacm_sec = directory.find(.pacm) orelse
        return fail(refusal, .non_canonical, payloadStart(&directory));

    // OWNERSHIP TRANSFER, not a copy chain: the score's arena is created
    // first and every stage receives ITS allocator as the stage's `gpa`,
    // so each stage's sub-arena allocates inside memory the returned
    // score already owns. The stage structs die at return with their
    // memory retained — `score.deinit()` is the one free — and on any
    // failure path the errdefer below (the local copy of the same arena
    // state; the partially built score is never returned) releases
    // everything the stages allocated. No stage arena can dangle.
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const transport = try decodeTransport(a, bytes, &directory, refusal);
    const registry = try decodeRegistry(a, bytes, &directory, refusal);
    const records = try decodeRecords(a, bytes, &directory, &registry, refusal);
    const ease = try decodeEaseControls(a, bytes, &directory, &records, &registry, refusal);
    const payloads = try decodePayloads(a, bytes, &directory, &records, refusal);

    // Assembly: zip the validated payload copies into the still-empty
    // expr/pattern arms and fold `'EMIT'` into the transport.
    const tracks = a.alloc(DecodedTrack, records.tracks.len) catch return error.OutOfMemory;
    for (records.tracks, payloads.payloads, tracks) |rec, payload, *out| {
        out.* = rec;
        switch (out.source) {
            .expr => out.source = .{ .expr = payload },
            .pattern => out.source = .{ .pattern = payload },
            .keys, .trigger => {},
        }
    }
    var final_transport = transport.transport;
    final_transport.emit = records.emit;

    // The metadata blob is the one thing the stages never copied: own it.
    const pacm_payload = try sectionPayload(bytes, pacm_sec, refusal);
    const pacm_copy = a.dupe(u8, pacm_payload) catch return error.OutOfMemory;

    const score: DecodedScore = .{
        .arena = arena,
        .required_features = directory.required_features,
        .transport = final_transport,
        .tracks = tracks,
        .keys = records.keys,
        .programs = ease.programs,
        .controls = ease.controls,
        .scenes = records.scenes,
        .regs = registry.regs,
        .declared = registry.declared,
        .pacm = pacm_copy,
        .pact_fnv = registry.pact_fnv,
        .pacm_fnv = transport.pacm_fnv,
    };

    // The PACM coherence close, cheap-to-dear: the 'TRAN' fast-reject
    // checksum first (it must agree with the full walk — and catch the
    // case only it can see, a lying checksum over an honest blob), then
    // the structural decode, then the field-for-field cross-check. The
    // view borrows the INPUT bytes (`Pacm`'s contract) and is read only
    // here, before `decode` returns.
    const tran_sec = directory.find(.tran).?; // decodeTransport proved presence
    if (score.pacm_fnv != fnv1a64(pacm_payload)) {
        return fail(refusal, .meta_incoherent, tran_sec.off + 48);
    }
    const view = Pacm.decode(pacm_payload) orelse
        return fail(refusal, .meta_malformed, pacm_sec.off);
    if (verifyRouting(&view, &score)) |code| {
        return fail(refusal, code, pacm_sec.off);
    }
    return score;
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
    const snam_len_field = 4;
    // Abi.MAX_DOC_SIZE, frozen copy — the source-document bound the
    // aggregate name bytes can never exceed.
    const max_doc_size = 256 * 1024;

    return meta_header_len +
        MAX_TRACKS * meta_track_len +
        MAX_KEYS * meta_key_len +
        MAX_CONTROLS * (meta_control_len + str_allowance) +
        meta_section_header_len + 4 + MAX_SCENES * scene_rec_len +
        meta_section_header_len + 4 + MAX_EASE_PROGRAMS * PACM_EASE_PROGRAM_LEN +
        4 + MAX_KEYS * 2 +
        meta_section_header_len + 4 + MAX_TEMPO_SEGMENTS * tempo_rec_len +
        meta_section_header_len + 4 + MAX_SCENES * snam_len_field + max_doc_size; // 'SNAM'
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
    // behind the growth property above. (The metadata wave's 'SNAM'
    // section added 262,412 bytes — 8 + 4 + 64×4 + the 256 KiB source
    // bound — to both totals; measured by the compiler itself in the
    // first post-change run: pacbWorstCase(0) printed as the `found`
    // value of the old pin's failure.)
    try t.expectEqual(@as(usize, 6_017_076), pacbWorstCase(0));
    try t.expectEqual(@as(usize, 6_090_804), pacbWorstCase(64));

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

test "Pacb: decodeTransport refuses (never traps) on a mismatched directory" {
    // The documented stage precondition is `parseDirectory(bytes)`'s own
    // view; a mismatched pair must be a REFUSAL, never a trap or a
    // garbage-dependent panic. T2.4+ stages carry the `sectionPayload`
    // guard — this pins the same defense for the T2.2 reads.
    const with_tmpo = try buildTransportFixture(t.allocator, .{}, &default_tmpo);
    defer t.allocator.free(with_tmpo);
    const flat = try buildTransportFixture(t.allocator, .{}, &.{});
    defer t.allocator.free(flat);

    // Prefix cuts under a full-buffer directory: 'TRAN' still lands on
    // its valid bytes, 'TMPO' extends past the end — the section-slice
    // guard refuses (before the fix these were raw out-of-bounds reads).
    {
        const directory = try parseDirectory(with_tmpo, null);
        var refusal: Refusal = undefined;
        const decoded = decodeTransport(t.allocator, with_tmpo[0..110], &directory, &refusal);
        if (decoded) |_| {
            return error.WronglyAccepted;
        } else |err| {
            try t.expectEqual(error.Refused, err);
            try t.expectEqual(RefusalCode.directory_malformed, refusal.code);
        }
    }
    {
        // A cut mid-section (past two whole TMPO records).
        const directory = try parseDirectory(with_tmpo, null);
        var refusal: Refusal = undefined;
        const decoded = decodeTransport(t.allocator, with_tmpo[0..130], &directory, &refusal);
        if (decoded) |_| {
            return error.WronglyAccepted;
        } else |err| {
            try t.expectEqual(error.Refused, err);
            try t.expectEqual(RefusalCode.directory_malformed, refusal.code);
        }
    }
    // A wholly different buffer: 'TRAN' lands on foreign bytes and the
    // domain checks own the refusal — the property pinned here is
    // refused-not-trapped, not the specific code.
    {
        const directory = try parseDirectory(with_tmpo, null);
        var refusal: Refusal = undefined;
        const decoded = decodeTransport(t.allocator, flat, &directory, &refusal);
        if (decoded) |_| {
            return error.WronglyAccepted;
        } else |err| {
            try t.expectEqual(error.Refused, err);
        }
    }
}

test "Pacb: decodeRegistry refuses (never traps) on a mismatched directory" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // A REGS-carrying directory over a shorter buffer: the section
    // slice extends past the end — today an out-of-bounds trap, with
    // the guard a plain refusal.
    const with_regs = try buildPacbFixture(
        t.allocator,
        .{ .host_targets = 2, .pact_fnv = fnv(regs) },
        &.{},
        regs,
        &.{},
    );
    defer t.allocator.free(with_regs);
    const flat = try buildTransportFixture(t.allocator, .{}, &.{});
    defer t.allocator.free(flat);

    const directory = try parseDirectory(with_regs, null);
    var refusal: Refusal = undefined;
    const decoded = decodeRegistry(t.allocator, flat, &directory, &refusal);
    if (decoded) |_| {
        return error.WronglyAccepted;
    } else |err| {
        try t.expectEqual(error.Refused, err);
        try t.expectEqual(RefusalCode.directory_malformed, refusal.code);
    }
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

test "Pacb: a present zero-count DECL refuses non_canonical" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // The zero-declared join is the ABSENT 'DECL' (the canonical
    // spelling every other degenerate section already follows: 'REGS',
    // 'TMPO', the record sections, 'EASE', 'STRS', 'PAYL'). A present
    // count-0 section is a degenerate spelling that never decodes.
    const built = try buildRecordsFixture(t.allocator, .{
        .transport = .{ .host_targets = 2, .declared_targets = 0, .pact_fnv = fnv(regs) },
        .regs = regs,
        .decl_zero = true,
    });
    defer t.allocator.free(built.buf);
    try expectRegistryRefusal(built.buf, .non_canonical);
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
/// reserved u32). Defaults join the scalar host entry ("t-two",
/// ncomp 1) — a lane target must be scalar.
const EmitRec = struct {
    name: u8 = 0,
    registry: u8 = 1,
    target_id: u16 = 1,
    reserved: u32 = 0,
};

/// One `'SCEN'` record (16 B: start_tick i64, dur_ticks i64).
const ScenRec = struct { start_tick: i64 = 0, dur_ticks: i64 = 0 };

/// One `'CTRL'` record (60 B: target_id u16 (0xffff env-only), registry
/// u8, ncomp u8, type u8, flags u8 (bit0 min, bit1 max), id_off u32,
/// id_len u16, value f32×4, min f32×4, max f32×4). `id` auto-resolves
/// `(id_off, id_len)` into the spec's `'STRS'` entries by content when
/// `id_off` is null; an explicit `id_off` spells a raw pointer (mutation
/// tests) and takes `id.len` as its length.
const CtrlRec = struct {
    id: []const u8 = "",
    target_id: u16 = TrackTable.NO_TARGET,
    registry: u8 = 0,
    ncomp: u8 = 1,
    type: u8 = 0, // slider
    flags: u8 = 0,
    id_off: ?u32 = null,
    id_len: ?u16 = null,
    value: [4]f32 = .{ 0, 0, 0, 0 },
    min: [4]f32 = .{ 0, 0, 0, 0 },
    max: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Wire stage/op record widths inside an `'EASE'` program — independent
/// test literals (the production decoder spells its own frozen copies):
/// 772 = 4 + 8×96 and 96 = 16 + 4×20, pinned against
/// `PACM_EASE_PROGRAM_LEN` in the T2.5 tests.
const ease_stage_len = 96;
const ease_op_len = 20;

/// Serialize one `Easing.Program` into its 772-byte wire record — the
/// test-side mirror of `Abi.easeProgramRec`: every stage/op slot written
/// from the struct (a compiled program's unused slots are zero/linear-0,
/// which IS the byte-zero wire spelling), so struct-level mutations
/// serialize directly.
fn writeEaseProgram(buf: []u8, at: usize, prog: *const Easing.Program) void {
    buf[at] = prog.len;
    // len pad ×3 stays zero (fixture buffers are pre-zeroed).
    for (0..Easing.MAX_STAGES) |i| {
        const st = &prog.stages[i];
        const sat = at + 4 + i * ease_stage_len;
        putF32(buf, sat, st.t_end);
        putF32(buf, sat + 4, st.v_base);
        putF32(buf, sat + 8, st.v_span);
        buf[sat + 12] = st.ops_len;
        for (0..Easing.MAX_OPS) |j| {
            const oat = sat + 16 + j * ease_op_len;
            buf[oat] = @intFromEnum(st.ops[j].code);
            for (0..4) |p| {
                putF32(buf, oat + 4 + p * 4, st.ops[j].params[p]);
            }
        }
    }
}

/// Resolve a CtrlRec's `(id_off, id_len)` against the spec's `'STRS'`
/// entry list. `id_off` is region-relative and points AT THE STRING
/// BYTES (the `payload_off` convention: into the entries region, past
/// each entry's own `[len u16]` prefix).
fn resolveStrsEntry(strs: ?[]const []const u8, rec: CtrlRec) struct { off: u32, len: u16 } {
    if (rec.id_off) |off| {
        return .{ .off = off, .len = rec.id_len orelse @intCast(rec.id.len) };
    }
    if (strs) |ids| {
        var off: u32 = 2; // past the entry's own length prefix
        for (ids) |id| {
            if (std.mem.eql(u8, id, rec.id)) {
                return .{ .off = off, .len = @intCast(id.len) };
            }
            off += @intCast(2 + id.len);
        }
    }
    return .{ .off = 0, .len = @intCast(rec.id.len) };
}

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
    /// `'EASE'` programs (T2.5). The per-key ref array is derived from
    /// `keys` unless `ease_refs` overrides it (its length IS
    /// `key_ref_count`, so a consistent lie about the count is
    /// spellable).
    ease: ?[]const Easing.Program = null,
    ease_refs: ?[]const u16 = null,
    /// `'STRS'` control-id table (T2.5), written verbatim in the given
    /// order so ordering/duplication mutations spell directly.
    strs: ?[]const []const u8 = null,
    /// `'CTRL'` records (T2.5); `id_off`/`id_len` auto-resolve into
    /// `strs` by content when null.
    ctrl: ?[]const CtrlRec = null,
    /// `'PAYL'` payload region bytes (T2.6), written verbatim.
    payl: ?[]const u8 = null,
    /// `'PACM'` bytes (T2.8): null keeps the historical 40-byte zero
    /// stub (unchecked placeholder), a slice writes the real blob.
    pacm: ?[]const u8 = null,
    /// Omit the `'PACM'` section entirely — the T2.8 required-presence
    /// mutation. (A non-null `pacm` overrides it.)
    pacm_absent: bool = false,
    /// The header `required_features` word (producer truth: bit0 iff a
    /// pattern track rides `trak`). Zero by default — fixtures without
    /// pattern tracks.
    features: u32 = 0,
    /// Spell a PRESENT zero-count `'DECL'` (the canonical-presence
    /// mutation under test); `decl` stays empty.
    decl_zero: bool = false,
};

/// Absolute payload offsets of the record sections (0 = absent; every
/// present payload starts at least at the 184-byte all-kinds boundary).
/// `tran`/`pacm` are always present in a built fixture unless
/// `pacm_absent` spelled the omission (then `pacm` is 0).
const RecordsLayout = struct {
    tran: u32 = 0,
    emit: u32 = 0,
    trak: u32 = 0,
    keys: u32 = 0,
    tick: u32 = 0,
    ease: u32 = 0,
    ctrl: u32 = 0,
    scen: u32 = 0,
    strs: u32 = 0,
    payl: u32 = 0,
    pacm: u32 = 0,
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
    const has_decl = spec.decl.len > 0 or spec.decl_zero;
    var n: usize = 2; // TRAN + PACM
    if (spec.regs != null) n += 1;
    if (has_decl) n += 1;
    if (spec.emit != null) n += 1;
    if (has_tmpo) n += 1;
    if (spec.trak != null) n += 1;
    if (spec.keys != null) n += 1;
    if (spec.tick != null) n += 1;
    if (spec.ease != null) n += 1;
    if (spec.ctrl != null) n += 1;
    if (spec.scen != null) n += 1;
    if (spec.strs != null) n += 1;
    if (spec.payl != null) n += 1;
    if (spec.pacm_absent) n -= 1; // TRAN + PACM is the floor of 2

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
    const ease_off = pos;
    const refs_len: usize = if (spec.ease != null)
        (if (spec.ease_refs) |r| r.len else if (spec.keys) |ks| ks.len else 0)
    else
        0;
    const ease_len: usize = if (spec.ease) |ps| 4 + ps.len * PACM_EASE_PROGRAM_LEN + 4 + refs_len * 2 else 0;
    pos += ease_len;
    const ctrl_off = pos;
    const ctrl_len: usize = if (spec.ctrl) |cs| 4 + cs.len * CTRL_REC_LEN else 0;
    pos += ctrl_len;
    const scen_off = pos;
    const scen_len: usize = if (spec.scen) |sc| 4 + sc.len * SCEN_REC_LEN else 0;
    pos += scen_len;
    const strs_off = pos;
    const strs_len: usize = if (spec.strs) |ids| blk: {
        var sum: usize = 8;
        for (ids) |id| sum += 2 + id.len;
        break :blk sum;
    } else 0;
    pos += strs_len;
    const payl_off = pos;
    const payl_len: usize = if (spec.payl) |p| 4 + p.len else 0;
    pos += payl_len;
    const pacm_off = pos;
    const pacm_len: usize = if (spec.pacm_absent) 0 else if (spec.pacm) |p| p.len else 40;

    const buf = try alloc.alloc(u8, pacm_off + pacm_len);
    @memset(buf, 0);
    writeHeader(buf, n, spec.features);

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
    if (spec.ease) |progs| {
        writeDirEntry(buf, index, .ease, ease_off, ease_len);
        putU32(buf, ease_off, @intCast(progs.len));
        for (progs, 0..) |*prog, i| {
            writeEaseProgram(buf, ease_off + 4 + i * PACM_EASE_PROGRAM_LEN, prog);
        }
        putU32(buf, ease_off + 4 + progs.len * PACM_EASE_PROGRAM_LEN, @intCast(refs_len));
        for (0..refs_len) |i| {
            const ref: u16 = if (spec.ease_refs) |r| r[i] else if (spec.keys) |ks| ks[i].ease_ref else 0;
            putU16(buf, ease_off + 4 + progs.len * PACM_EASE_PROGRAM_LEN + 4 + i * 2, ref);
        }
        index += 1;
    }
    if (spec.ctrl) |cs| {
        writeDirEntry(buf, index, .ctrl, ctrl_off, ctrl_len);
        putU32(buf, ctrl_off, @intCast(cs.len));
        for (cs, 0..) |rec, i| {
            const at = ctrl_off + 4 + i * CTRL_REC_LEN;
            putU16(buf, at, rec.target_id);
            putU8(buf, at + 2, rec.registry);
            putU8(buf, at + 3, rec.ncomp);
            putU8(buf, at + 4, rec.type);
            putU8(buf, at + 5, rec.flags);
            const resolved = resolveStrsEntry(spec.strs, rec);
            putU32(buf, at + 6, resolved.off);
            putU16(buf, at + 10, resolved.len);
            for (0..4) |lane| {
                putF32(buf, at + 12 + lane * 4, rec.value[lane]);
                putF32(buf, at + 28 + lane * 4, rec.min[lane]);
                putF32(buf, at + 44 + lane * 4, rec.max[lane]);
            }
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
    if (spec.strs) |ids| {
        writeDirEntry(buf, index, .strs, strs_off, strs_len);
        putU32(buf, strs_off, @intCast(ids.len));
        putU32(buf, strs_off + 4, @intCast(strs_len - 8));
        var at = strs_off + 8;
        for (ids) |id| {
            putU16(buf, at, @intCast(id.len));
            @memcpy(buf[at + 2 ..][0..id.len], id);
            at += 2 + id.len;
        }
        index += 1;
    }
    if (spec.payl) |payload_region| {
        writeDirEntry(buf, index, .payl, payl_off, payl_len);
        putU32(buf, payl_off, @intCast(payload_region.len));
        @memcpy(buf[payl_off + 4 ..][0..payload_region.len], payload_region);
        index += 1;
    }
    if (!spec.pacm_absent) {
        writeDirEntry(buf, n - 1, .pacm, pacm_off, pacm_len);
        if (spec.pacm) |p| @memcpy(buf[pacm_off..][0..p.len], p);
        // null (the historical placeholder) leaves the 40 stub bytes
        // zeroed, exactly as before T2.8.
    }
    writeTranRecord(buf, tran_off, spec.transport);

    return .{ .buf = buf, .layout = .{
        .tran = @intCast(tran_off),
        .emit = if (spec.emit != null) @intCast(emit_off) else 0,
        .trak = if (spec.trak != null) @intCast(trak_off) else 0,
        .keys = if (spec.keys != null) @intCast(keys_off) else 0,
        .tick = if (spec.tick != null) @intCast(tick_off) else 0,
        .ease = if (spec.ease != null) @intCast(ease_off) else 0,
        .ctrl = if (spec.ctrl != null) @intCast(ctrl_off) else 0,
        .scen = if (spec.scen != null) @intCast(scen_off) else 0,
        .strs = if (spec.strs != null) @intCast(strs_off) else 0,
        .payl = if (spec.payl != null) @intCast(payl_off) else 0,
        .pacm = if (spec.pacm_absent) 0 else @intCast(pacm_off),
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
            .{ .name = 0, .registry = 1, .target_id = 1 }, // beat → scalar t-two
            .{ .name = 4, .registry = 1, .target_id = 1 }, // t → scalar t-two
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
        TrackTable.EmitLane{ .name = .beat, .target_id = 1, .registry = 1 },
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
        if (std.mem.eql(u8, m.field, "pattern_trig_every")) {
            // Producer truth for the converted track: a pattern track
            // sets the feature bit.
            putU32(built.buf, 8, FEATURE_PATTERN_TRACKS);
        }
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
        base.tick[1] = 2 * RtSjon.Pattern.MAX_TICK + 1; // beyond the fold envelope
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

test "Pacb: keys at carries the folded 2*MAX_TICK envelope" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const folded_max: i64 = 2 * RtSjon.Pattern.MAX_TICK;

    // Boundary acceptance: a scened key is ONE checked fold of the scene
    // start (|v| <= MAX_TICK) and a local position (|v| <= MAX_TICK), so
    // start MAX_TICK + local MAX_TICK lands exactly on 2*MAX_TICK —
    // compile-legal, table-carried, and accepted here (the T3.1
    // round-trip class the interim review named).
    {
        var base = baseRecords();
        base.scen[0] = .{ .start_tick = RtSjon.Pattern.MAX_TICK, .dur_ticks = 1 };
        base.keys[2].at = folded_max;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        const directory = try parseDirectory(built.buf, null);
        var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
        defer registry.deinit();
        var stage = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
        defer stage.deinit();
        try t.expectEqual(folded_max, stage.keys[2].at);
    }
    // The negative boundary is equally legal (negative positions are
    // producer-legal; the envelope is symmetric).
    {
        var base = baseRecords();
        base.keys[0].at = -folded_max;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        const directory = try parseDirectory(built.buf, null);
        var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
        defer registry.deinit();
        var stage = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
        defer stage.deinit();
        try t.expectEqual(-folded_max, stage.keys[0].at);
    }
    // One past the envelope refuses key_invalid: a single fold of two
    // MAX_TICK-bounded values can never produce it (producer-impossible).
    {
        var base = baseRecords();
        base.keys[2].at = folded_max + 1;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .key_invalid);
    }
    {
        var base = baseRecords();
        base.keys[0].at = -folded_max - 1;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .key_invalid);
    }
}

test "Pacb: periodic every and offset carry their tick envelopes" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const folded_max: i64 = 2 * RtSjon.Pattern.MAX_TICK;

    // `every` is never scene-folded (it converts at the map origin), so
    // its envelope is the grid bound itself: 1..MAX_TICK inclusive.
    // `offset` folds the scene start once: |offset| <= 2*MAX_TICK.
    {
        var base = baseRecords();
        base.scen[0] = .{ .start_tick = RtSjon.Pattern.MAX_TICK, .dur_ticks = 1 };
        base.trak[2].scene = 0;
        base.trak[2].trig_every = RtSjon.Pattern.MAX_TICK;
        base.trak[2].trig_offset = folded_max;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        const directory = try parseDirectory(built.buf, null);
        var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
        defer registry.deinit();
        var stage = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
        defer stage.deinit();
        try t.expect(stage.tracks[2].source == .trigger);
        switch (stage.tracks[2].source.trigger) {
            .periodic => |p| {
                try t.expectEqual(RtSjon.Pattern.MAX_TICK, p.every);
                try t.expectEqual(folded_max, p.offset);
            },
            else => return error.UnexpectedArm,
        }
    }
    // The negative offset boundary.
    {
        var base = baseRecords();
        base.trak[2].trig_offset = -folded_max;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        const directory = try parseDirectory(built.buf, null);
        var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
        defer registry.deinit();
        var stage = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
        defer stage.deinit();
        switch (stage.tracks[2].source.trigger) {
            .periodic => |p| try t.expectEqual(-folded_max, p.offset),
            else => return error.UnexpectedArm,
        }
    }
    // `every` past MAX_TICK refuses (producer-impossible at the origin).
    {
        var base = baseRecords();
        base.trak[2].trig_every = RtSjon.Pattern.MAX_TICK + 1;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
    // `offset` past the fold envelope refuses (the eval subtraction
    // t - offset must stay inside i64 for every probe |t| <= MAX_TICK).
    {
        var base = baseRecords();
        base.trak[2].trig_offset = folded_max + 1;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
    {
        var base = baseRecords();
        base.trak[2].trig_offset = -folded_max - 1;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .trigger_invalid);
    }
}

test "Pacb: explicit schedule ticks carry the folded 2*MAX_TICK envelope" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const folded_max: i64 = 2 * RtSjon.Pattern.MAX_TICK;

    // The scened-fold parity case: scene start MAX_TICK + local position
    // MAX_TICK folds to exactly 2*MAX_TICK — compile emits it with one
    // checked add (`Compile.buildAtList`), the table documents carrying
    // it, and refusing it would break T3.1 round-trip parity.
    {
        var base = baseRecords();
        base.scen[0] = .{ .start_tick = RtSjon.Pattern.MAX_TICK, .dur_ticks = 1 };
        base.trak[3].scene = 0;
        base.tick[2] = folded_max;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        const directory = try parseDirectory(built.buf, null);
        var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
        defer registry.deinit();
        var stage = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
        defer stage.deinit();
        try t.expect(stage.tracks[3].source == .trigger);
        switch (stage.tracks[3].source.trigger) {
            .at => |at| try t.expectEqual(folded_max, at[2]),
            else => return error.UnexpectedArm,
        }
    }
    // The negative boundary.
    {
        var base = baseRecords();
        base.tick[0] = -folded_max;
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        const directory = try parseDirectory(built.buf, null);
        var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
        defer registry.deinit();
        var stage = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
        defer stage.deinit();
        switch (stage.tracks[3].source.trigger) {
            .at => |at| try t.expectEqual(-folded_max, at[0]),
            else => return error.UnexpectedArm,
        }
    }
    // One past the envelope refuses — the repointed ceiling.
    {
        var base = baseRecords();
        base.tick[2] = folded_max + 1;
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

test "Pacb: overlapping keys runs refuse key_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();
    // Track 0 slices keys[0..3); this second keys track slices
    // keys[1..3) — individually valid, overlapping as runs. 'KEYS' is
    // the concatenation of every track's run in track order (compile
    // appends disjoint runs), so slices never overlap — the 'TICK'
    // discipline.
    base.trak[1] = .{ .target_id = 0, .registry = 0, .ncomp = 3, .source = SOURCE_KEYS, .key_start = 1, .key_len = 2 };
    const built = try buildBaseFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);
    try expectRecordsRefusal(built.buf, .key_invalid);
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

test "Pacb: an EMIT lane needs a scalar (ncomp 1) join target" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Compile refuses non-scalar emit targets (`target_arity_mismatch`)
    // and `Eval` writes one scalar per lane — a lane joined to the
    // 3-component host entry is producer-impossible.
    const lanes = [_]EmitRec{.{ .name = 0, .target_id = 0, .registry = 0 }};
    const built = try buildRecordsFixture(t.allocator, .{
        .transport = hostJoinSpec(regs),
        .regs = regs,
        .decl = &base_decl,
        .emit = &lanes,
    });
    defer t.allocator.free(built.buf);
    try expectRecordsRefusal(built.buf, .registry_mismatch);
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

test "Pacb: the pattern-features bit must match pattern-track presence" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Producer truth: bit0 of required_features is set iff a :pattern
    // track exists (the header's own definition). The decoder reads the
    // source ordinals in 'TRAK', so the two spellings must agree —
    // a mismatch is producer-impossible and non-canonical.
    {
        // A pattern track with the feature bit clear.
        const trak = [_]TrakRec{
            .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_PATTERN, .payload_off = 0, .payload_len = 12 },
        };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &trak,
        });
        defer t.allocator.free(built.buf);
        try expectRecordsRefusal(built.buf, .non_canonical);
    }
    {
        // The bit set with no pattern track.
        var base = baseRecords();
        const built = try buildBaseFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putU32(built.buf, 8, FEATURE_PATTERN_TRACKS);
        try expectRecordsRefusal(built.buf, .non_canonical);
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

// ---------------------------------------------------------------------------
// T2.5 — ease/control stage tests ('EASE' + 'STRS' + 'CTRL')
// ---------------------------------------------------------------------------

fn expectEaseControlRefusal(bytes: []const u8, code: RefusalCode) !void {
    var refusal: Refusal = undefined;
    const directory = try parseDirectory(bytes, null);
    var registry = try decodeRegistry(t.allocator, bytes, &directory, &refusal);
    defer registry.deinit();
    var records = try decodeRecords(t.allocator, bytes, &directory, &registry, &refusal);
    defer records.deinit();
    const decoded = decodeEaseControls(t.allocator, bytes, &directory, &records, &registry, &refusal);
    if (decoded) |payload| {
        var stage = payload;
        stage.deinit();
        return error.WronglyAccepted;
    } else |err| {
        try t.expectEqual(error.Refused, err);
        try t.expectEqual(code, refusal.code);
    }
}

/// The shared T2.5 base: the host_two join, one declared target, the
/// four base tracks (keys referencing program 1), an `'EASE'` table of
/// [linear, two-stage seq], a sorted two-entry `'STRS'` table, and two
/// controls (one host-targeted slider with min/max, one env-only).
const EaseControlBase = struct {
    trak: [4]TrakRec,
    programs: [2]Easing.Program,
    strs: [2][]const u8,
    ctrl: [2]CtrlRec,
    keys: [3]KeyRec,
};

fn baseEaseControl() EaseControlBase {
    var base = baseRecords();
    base.keys[1].ease_ref = 1;
    return .{
        .trak = base.trak,
        .keys = base.keys,
        .programs = .{
            Easing.primitive(.{ .code = .linear }) catch unreachable,
            Easing.seqOf(&.{
                .{ .t = 1, .v = 1, .ops = &.{.{ .code = .out_cubic }} },
                .{ .t = 1, .v = 1, .ops = &.{.{ .code = .in_out_quad }} },
            }) catch unreachable,
        },
        .strs = .{ "amp", "level" },
        .ctrl = .{
            .{
                .id = "amp",
                .target_id = 0,
                .registry = 0,
                .ncomp = 3,
                .type = 0,
                .flags = 0b11,
                .value = .{ 0.25, 0.5, 0.75, 0 },
                .min = .{ 0, 0.5, 1, 0 },
                .max = .{ 1, 2, 3, 0 },
            },
            .{
                .id = "level",
                .target_id = TrackTable.NO_TARGET,
                .ncomp = 1,
                .type = 0,
                .value = .{ 0.5, 0, 0, 0 },
            },
        },
    };
}

fn buildEaseControlFixture(
    alloc: std.mem.Allocator,
    base: *const EaseControlBase,
    regs: []const u8,
) !BuiltFixture {
    const b = baseRecords();
    return buildRecordsFixture(alloc, .{
        .transport = hostJoinSpec(regs),
        .regs = regs,
        .decl = &base_decl,
        .emit = &b.emit,
        .trak = &base.trak,
        .keys = &base.keys,
        .tick = &b.tick,
        .scen = &b.scen,
        .ease = &base.programs,
        .strs = &base.strs,
        .ctrl = &base.ctrl,
    });
}

/// Wire offsets inside the `'EASE'` payload of a built fixture.
const EaseAt = struct { count: usize, layout: RecordsLayout };

fn easeProgramAt(layout: RecordsLayout, program: usize) usize {
    return layout.ease + 4 + program * PACM_EASE_PROGRAM_LEN;
}

fn easeStageAt(layout: RecordsLayout, program: usize, stage: usize) usize {
    return easeProgramAt(layout, program) + 4 + stage * ease_stage_len;
}

fn easeOpAt(layout: RecordsLayout, program: usize, stage: usize, op: usize) usize {
    return easeStageAt(layout, program, stage) + 16 + op * ease_op_len;
}

test "Pacb: a clean ease/control fixture decodes owned programs and controls" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseEaseControl();
    const built = try buildEaseControlFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);

    // The wire arithmetic the record widths must satisfy: 772 = 4+8×96
    // and 96 = 16+4×20 (independent expectation, not the decoder's).
    try t.expectEqual(@as(usize, 772), PACM_EASE_PROGRAM_LEN);
    try t.expectEqual(@as(usize, 4 + 8 * ease_stage_len), PACM_EASE_PROGRAM_LEN);
    try t.expectEqual(@as(usize, 16 + 4 * ease_op_len), ease_stage_len);

    const directory = try parseDirectory(built.buf, null);
    var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
    defer registry.deinit();
    var records = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
    defer records.deinit();
    var stage = try decodeEaseControls(t.allocator, built.buf, &directory, &records, &registry, null);
    defer stage.deinit();

    try t.expectEqual(@as(usize, 2), stage.programs.len);
    const want_linear = Easing.primitive(.{ .code = .linear }) catch unreachable;
    try t.expect(std.meta.eql(stage.programs[0], want_linear));

    const want_seq = base.programs[1];
    try t.expect(std.meta.eql(stage.programs[1], want_seq));
    // Independent literal pins (not the builder's echo): the seq's
    // normalized boundaries and the eval math at a spot point.
    try t.expectEqual(@as(u8, 2), stage.programs[1].len);
    try t.expectEqual(@as(f32, 0.5), stage.programs[1].stages[0].t_end);
    try t.expectEqual(@as(f32, 1.0), stage.programs[1].stages[1].t_end);
    try t.expectEqual(@as(f32, 0.5), stage.programs[1].stages[1].v_base);
    try t.expectEqual(
        @as(u64, @bitCast(want_seq.eval(0.25))),
        @as(u64, @bitCast(stage.programs[1].eval(0.25))),
    );

    try t.expectEqual(@as(usize, 2), stage.controls.len);
    const c0 = stage.controls[0];
    try t.expectEqualStrings("amp", c0.id);
    try t.expect(c0.target != null);
    try t.expectEqual(@as(u16, 0), c0.target.?.id);
    try t.expectEqual(@as(u8, 0), c0.target.?.registry);
    try t.expectEqual(@as(u8, 3), c0.ncomp);
    try t.expectEqual(TrackTable.ControlType.slider, c0.kind);
    try t.expectEqual(@as(f32, 0.25), c0.value[0]);
    try t.expectEqual(@as(f32, 0.75), c0.value[2]);
    try t.expect(c0.min != null and c0.min.?[1] == 0.5);
    try t.expect(c0.max != null and c0.max.?[2] == 3);

    const c1 = stage.controls[1];
    try t.expectEqualStrings("level", c1.id);
    try t.expect(c1.target == null);
    try t.expectEqual(@as(u8, 1), c1.ncomp);
    try t.expectEqual(@as(f32, 0.5), c1.value[0]);
    try t.expect(c1.min == null and c1.max == null);

    // The stage owns everything it returns: clobber the input, the
    // programs and control ids survive (the borrow-vs-own contract
    // until T2.8's final DecodedScore arena).
    @memset(built.buf, 0xAA);
    try t.expect(std.meta.eql(stage.programs[1], want_seq));
    try t.expectEqualStrings("amp", stage.controls[0].id);
    try t.expectEqualStrings("level", stage.controls[1].id);
    try t.expectEqual(@as(u8, 3), stage.controls[0].ncomp);
}

test "Pacb: EASE absent synthesizes the shared linear default" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseRecords();
    const built = try buildBaseFixture(t.allocator, &base, regs);
    defer t.allocator.free(built.buf);

    const directory = try parseDirectory(built.buf, null);
    var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
    defer registry.deinit();
    var records = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
    defer records.deinit();
    var stage = try decodeEaseControls(t.allocator, built.buf, &directory, &records, &registry, null);
    defer stage.deinit();

    try t.expectEqual(@as(usize, 1), stage.programs.len);
    const want = Easing.primitive(.{ .code = .linear }) catch unreachable;
    try t.expect(std.meta.eql(stage.programs[0], want));
    try t.expectEqual(@as(f64, 0.25), stage.programs[0].eval(0.25));
    try t.expectEqual(@as(usize, 0), stage.controls.len);
}

test "Pacb: EASE program shape defects refuse ease_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // len 0 / len 9 on a live program.
    {
        var base = baseEaseControl();
        base.programs[1].len = 0;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    {
        var base = baseEaseControl();
        base.programs[1].len = Easing.MAX_STAGES + 1;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // ops_len over MAX_OPS.
    {
        var base = baseEaseControl();
        base.programs[1].stages[0].ops_len = Easing.MAX_OPS + 1;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // t_end: ties, a zero first boundary (eval's denom>0 assert), and a
    // non-finite stage float.
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putF32(built.buf, easeStageAt(built.layout, 1, 0), 1.0); // ties stage 1
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putF32(built.buf, easeStageAt(built.layout, 1, 0), 0.0); // zero first
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putF32(built.buf, easeStageAt(built.layout, 1, 0), std.math.nan(f32));
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // Non-finite op param (stage 0, op 0, param 0 of program 1).
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putF32(built.buf, easeOpAt(built.layout, 1, 0, 0) + 4, std.math.inf(f32));
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // Op code outside the frozen Easing.Op set (0..21).
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putU8(built.buf, easeOpAt(built.layout, 1, 0, 0), 22);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // Program 0 must be the shared linear default.
    {
        var base = baseEaseControl();
        const swap = base.programs[0];
        base.programs[0] = base.programs[1];
        base.programs[1] = swap;
        base.keys[1].ease_ref = 1;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
}

test "Pacb: EASE unused slots and pads must be byte-zero" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Unused stage slot (program 1 is a 2-stage seq; stage 2 is unused).
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putF32(built.buf, easeStageAt(built.layout, 1, 2), 0.25);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // Unused op slot inside a live stage (each stage has one op).
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putF32(built.buf, easeOpAt(built.layout, 1, 0, 1) + 4, 1);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // The len pad, the ops_len pad and the op-code pad are reserved zero.
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putU8(built.buf, easeProgramAt(built.layout, 1) + 1, 1);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putU8(built.buf, easeStageAt(built.layout, 1, 0) + 13, 1);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    {
        var base = baseEaseControl();
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putU8(built.buf, easeOpAt(built.layout, 1, 0, 0) + 1, 1);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
}

test "Pacb: EASE canonical presence, caps and section arithmetic" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseEaseControl();

    // Present with a single program: the linear-only table is the
    // omitted case.
    {
        const one = [_]Easing.Program{base.programs[0]};
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &baseRecords().emit,
            .trak = &base.trak,
            .keys = &base.keys,
            .tick = &baseRecords().tick,
            .scen = &baseRecords().scen,
            .ease = &one,
            .strs = &base.strs,
            .ctrl = &base.ctrl,
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .non_canonical);
    }
    // program_count over MAX_EASE_PROGRAMS (129 one-stage programs; the
    // section is ~99 KiB, count×width exact at the directory level).
    {
        const many = try t.allocator.alloc(Easing.Program, MAX_EASE_PROGRAMS + 1);
        defer t.allocator.free(many);
        for (many) |*prog| prog.* = base.programs[0];
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &baseRecords().emit,
            .trak = &base.trak,
            .keys = &base.keys,
            .tick = &baseRecords().tick,
            .scen = &baseRecords().scen,
            .ease = many,
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .cap_exceeded);
    }
    // The length arithmetic must consume the section exactly: claim one
    // fewer ref than the bytes carry.
    {
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        putU32(
            built.buf,
            built.layout.ease + 4 + 2 * PACM_EASE_PROGRAM_LEN,
            2, // 3 ref slots physically follow
        );
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // key_ref_count must equal the 'KEYS' count (a consistent 4-ref
    // section against 3 keys).
    {
        const refs = [_]u16{ 0, 1, 0, 0 };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &baseRecords().emit,
            .trak = &base.trak,
            .keys = &base.keys,
            .tick = &baseRecords().tick,
            .scen = &baseRecords().scen,
            .ease = &base.programs,
            .ease_refs = &refs,
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .count_mismatch);
    }
}

test "Pacb: ease refs are bounded by the program table" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // A KEYS ease_ref past the table.
    {
        var base = baseEaseControl();
        base.keys[2].ease_ref = 2; // table holds 0..1
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
    // A refs-array entry past the table (keys themselves clean).
    {
        var base = baseEaseControl();
        const refs = [_]u16{ 0, 0, 7 };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &baseRecords().emit,
            .trak = &base.trak,
            .keys = &.{ base.keys[0], .{ .at = 360360, .value = .{ 0.25, 0.5, 0.75, 0 } }, base.keys[2] },
            .tick = &baseRecords().tick,
            .scen = &baseRecords().scen,
            .ease = &base.programs,
            .ease_refs = &refs,
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
}

test "Pacb: ease refs must agree with the key stream's ease_refs" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // The refs array and the KEYS ease_ref fields are two spellings of
    // one truth (the producer writes both from the same key stream,
    // `Abi.encodeMeta`'s 'EASE' section). Both in bounds, disagreeing:
    // refs say 0 for key 1, the KEYS record says 1 — the same
    // canonical-identity discipline 'REGS' already carries.
    {
        var base = baseEaseControl();
        const refs = [_]u16{ 0, 0, 0 };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .emit = &baseRecords().emit,
            .trak = &base.trak,
            .keys = &base.keys,
            .tick = &baseRecords().tick,
            .scen = &baseRecords().scen,
            .ease = &base.programs,
            .ease_refs = &refs,
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .ease_invalid);
    }
}

test "Pacb: STRS ordering, uniqueness, emptiness and reservation refuse strs_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseEaseControl();

    // Unsorted: equal lengths out of byte order.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "zed", "amp" },
            .ctrl = &.{.{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .strs_invalid);
    }
    // Unsorted: longer entry before a shorter one.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "level", "amp" },
            .ctrl = &.{.{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .strs_invalid);
    }
    // Duplicate entry (also the not-strictly-increasing case).
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "amp" },
            .ctrl = &.{.{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .strs_invalid);
    }
    // Empty entry.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "", "amp" },
            .ctrl = &.{.{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .strs_invalid);
    }
    // Reserved time-env names ("beat" and "t").
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "beat" },
            .ctrl = &.{.{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .strs_invalid);
    }
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "t" },
            .ctrl = &.{.{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .strs_invalid);
    }
    // byte_size disagrees with the entries it carries.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "level" },
            .ctrl = &base.ctrl,
        });
        defer t.allocator.free(built.buf);
        putU32(built.buf, built.layout.strs + 4, 5); // entries need 11
        try expectEaseControlRefusal(built.buf, .strs_invalid);
    }
}

test "Pacb: STRS/CTRL canonical presence, caps and iff-consumption" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    var base = baseEaseControl();

    // A present zero-count STRS is the omitted case.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .non_canonical);
    }
    // A present zero-count CTRL likewise.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{"amp"},
            .ctrl = &.{},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .non_canonical);
    }
    // STRS over the 64-entry cap.
    {
        const many = try t.allocator.alloc([]const u8, MAX_CONTROLS + 1);
        defer t.allocator.free(many);
        for (many, 0..) |*id, i| id.* = try std.fmt.allocPrint(t.allocator, "c{d:0>8}", .{i});
        defer for (many) |id| t.allocator.free(id);
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = many,
            .ctrl = &.{.{ .id = many[0], .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .cap_exceeded);
    }
    // CTRL over MAX_CONTROLS (pointing at one shared entry).
    {
        const ctrls = try t.allocator.alloc(CtrlRec, MAX_CONTROLS + 1);
        defer t.allocator.free(ctrls);
        for (ctrls) |*rec| rec.* = .{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{"amp"},
            .ctrl = ctrls,
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .cap_exceeded);
    }
    // 'STRS' iff a control exists, both directions.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "level" },
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .non_canonical);
    }
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .ctrl = &base.ctrl,
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .non_canonical);
    }
}

test "Pacb: control ids must resolve to unique STRS entries" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Beyond the entries region ("amp" is at 0..3, the region is 11 B).
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "level" },
            .ctrl = &.{.{ .id = "amp", .id_off = 100, .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // Mid-entry start (inside "amp"'s bytes, not a string-bytes start).
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "level" },
            .ctrl = &.{.{ .id = "mp!", .id_off = 3, .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // The right start but the wrong length (a strict prefix of "amp").
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "level" },
            .ctrl = &.{.{ .id = "am", .id_off = 2, .id_len = 2, .target_id = 0, .registry = 0, .ncomp = 3 }},
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // Two controls naming the same entry.
    {
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .strs = &.{ "amp", "level" },
            .ctrl = &.{
                .{ .id = "amp", .target_id = 0, .registry = 0, .ncomp = 3 },
                .{ .id = "amp", .target_id = TrackTable.NO_TARGET },
            },
        });
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
}

test "Pacb: control type ordinal and env-only rules refuse control_invalid" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // A type byte outside ControlType's 0..2.
    {
        var base = baseEaseControl();
        base.ctrl[0].type = 7;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // Env-only ncomp bounds (no join entry exists to check against).
    for ([_]u8{ 0, 5 }) |ncomp| {
        var base = baseEaseControl();
        base.ctrl[1].ncomp = ncomp;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // An env-only control's registry byte is unused-by-target: zero.
    {
        var base = baseEaseControl();
        base.ctrl[1].registry = 1;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // Reserved flag bits refuse.
    {
        var base = baseEaseControl();
        base.ctrl[0].flags |= 0b100;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
}

test "Pacb: control join coherence refuses registry_mismatch" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // A targeted id outside the join that is not the NO_TARGET spelling.
    {
        var base = baseEaseControl();
        base.ctrl[0].target_id = 42; // join size is 3
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .registry_mismatch);
    }
    // A wrong registry for host entry 0 (registry 0, ncomp 3).
    {
        var base = baseEaseControl();
        base.ctrl[0].registry = 1;
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .registry_mismatch);
    }
    // A wrong ncomp for host entry 0.
    {
        var base = baseEaseControl();
        base.ctrl[0].ncomp = 2;
        base.ctrl[0].value = .{ 0.25, 0.5, 0, 0 };
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .registry_mismatch);
    }
}

test "Pacb: control flags are coherent with finite lanes and zero spellings" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // A set min flag with a non-finite lane.
    {
        var base = baseEaseControl();
        base.ctrl[0].min[2] = std.math.nan(f32);
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // A set max flag with an infinite lane.
    {
        var base = baseEaseControl();
        base.ctrl[0].max[0] = std.math.inf(f32);
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // A clear flag must spell zero lanes (the absent-case spelling).
    {
        var base = baseEaseControl();
        base.ctrl[1].max = .{ 1, 0, 0, 0 };
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
    // Value lanes at or above ncomp are zero-padded like Key.value.
    {
        var base = baseEaseControl();
        base.ctrl[1].value = .{ 0.5, 0.25, 0, 0 };
        const built = try buildEaseControlFixture(t.allocator, &base, regs);
        defer t.allocator.free(built.buf);
        try expectEaseControlRefusal(built.buf, .control_invalid);
    }
}

// ---------------------------------------------------------------------------
// T2.6 — payload stage tests ('PAYL': structural consumption)
// ---------------------------------------------------------------------------

fn expectPayloadRefusal(bytes: []const u8, code: RefusalCode) !void {
    var refusal: Refusal = undefined;
    const directory = try parseDirectory(bytes, null);
    var registry = try decodeRegistry(t.allocator, bytes, &directory, &refusal);
    defer registry.deinit();
    var records = try decodeRecords(t.allocator, bytes, &directory, &registry, &refusal);
    defer records.deinit();
    const decoded = decodePayloads(t.allocator, bytes, &directory, &records, &refusal);
    if (decoded) |payload| {
        var stage = payload;
        stage.deinit();
        return error.WronglyAccepted;
    } else |err| {
        try t.expectEqual(error.Refused, err);
        try t.expectEqual(code, refusal.code);
    }
}

/// Compact single-root SJON binary IR for a source snippet (the frozen
/// encoder choice, A29 — test-side oracle; the decoder only ever reads).
fn toBinaryCompact(alloc: std.mem.Allocator, src: [:0]const u8) ![]u8 {
    const sjon = @import("sjon"); // write side: indented test-only
    var tree = try sjon.parse(alloc, src);
    defer tree.deinit();
    const bin = try sjon.Binary.toBinary(
        alloc,
        tree,
        sjon.Binary.ToBinaryOptions.forMode(.compact),
    );
    defer bin.deinit();
    return alloc.dupe(u8, bin.data);
}

/// A one-expr-track fixture over an arbitrary payload region (mutations
/// included) — TRAN+REGS+DECL+TRAK+PAYL+PACM in canonical order.
fn buildPayloadFixture(
    alloc: std.mem.Allocator,
    payload_region: []const u8,
    regs: []const u8,
) !BuiltFixture {
    const trak = [_]TrakRec{
        .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_EXPR, .payload_off = 0, .payload_len = @intCast(payload_region.len) },
    };
    return buildRecordsFixture(alloc, .{
        .transport = hostJoinSpec(regs),
        .regs = regs,
        .decl = &base_decl,
        .trak = &trak,
        .payl = payload_region,
    });
}

/// The roots-block offset of a binary-IR buffer (header field @12).
fn irRootsOffset(payload: []const u8) usize {
    return readU32(payload, 12);
}

test "Pacb: payload spans validate structurally and copy into the arena" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // An expr payload (form/number/symbol kinds) and a pattern payload
    // (vector/symbol/unit/string/nil/boolean/form-with-keyword kinds) —
    // the pattern side is accepted SCHEMA-FREE, structure only.
    const expr_bin = try toBinaryCompact(t.allocator, "(+ 1 (* 2 t))");
    defer t.allocator.free(expr_bin);
    const pat_bin = try toBinaryCompact(t.allocator, "[bd (pure :x 1) 90deg \"s\" nil true]");
    defer t.allocator.free(pat_bin);

    const region = try t.allocator.alloc(u8, expr_bin.len + pat_bin.len);
    defer t.allocator.free(region);
    @memcpy(region[0..expr_bin.len], expr_bin);
    @memcpy(region[expr_bin.len..], pat_bin);

    var base = baseRecords();
    const trak = [_]TrakRec{
        base.trak[0], // keys track: payload stays empty
        .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_EXPR, .payload_off = 0, .payload_len = @intCast(expr_bin.len) },
        .{ .target_id = 2, .registry = 1, .ncomp = 2, .source = SOURCE_PATTERN, .payload_off = @intCast(expr_bin.len), .payload_len = @intCast(pat_bin.len) },
    };
    const built = try buildRecordsFixture(t.allocator, .{
        .transport = hostJoinSpec(regs),
        .regs = regs,
        .decl = &base_decl,
        .emit = &base.emit,
        .trak = &trak,
        .keys = &base.keys,
        .scen = &base.scen,
        .payl = region,
    });
    defer t.allocator.free(built.buf);
    // Producer truth: a pattern track sets the feature bit.
    putU32(built.buf, 8, FEATURE_PATTERN_TRACKS);

    const directory = try parseDirectory(built.buf, null);
    var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
    defer registry.deinit();
    var records = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
    defer records.deinit();
    var stage = try decodePayloads(t.allocator, built.buf, &directory, &records, null);
    defer stage.deinit();

    try t.expectEqual(@as(usize, 3), stage.payloads.len);
    try t.expectEqual(@as(usize, 0), stage.payloads[0].len); // keys track
    try t.expectEqualSlices(u8, expr_bin, stage.payloads[1]);
    try t.expectEqualSlices(u8, pat_bin, stage.payloads[2]);

    // The stage owns its copies: clobber the input, the payloads read
    // back byte-identical (the ownership contract until T2.8's final
    // arena; 02 P2 re-proves it at the wasm boundary).
    @memset(built.buf, 0xAA);
    try t.expectEqualSlices(u8, expr_bin, stage.payloads[1]);
    try t.expectEqualSlices(u8, pat_bin, stage.payloads[2]);
}

test "Pacb: zero- and multi-root payloads refuse payload_malformed" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Zero roots: patch the root count varint to 0.
    {
        const payload = try toBinaryCompact(t.allocator, "(+ 1 (* 2 t))");
        defer t.allocator.free(payload);
        payload[irRootsOffset(payload)] = 0;
        const built = try buildPayloadFixture(t.allocator, payload, regs);
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .payload_malformed);
    }
    // Multi-root: a two-root document.
    {
        const payload = try toBinaryCompact(t.allocator, "(+ 1 (* 2 t)) 42");
        defer t.allocator.free(payload);
        const built = try buildPayloadFixture(t.allocator, payload, regs);
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .payload_malformed);
    }
}

test "Pacb: trailing slack inside a payload refuses payload_malformed" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // One extra byte after the single root — never consumed by the
    // walk, so the payload does not end exactly at its length.
    const clean = try toBinaryCompact(t.allocator, "(+ 1 (* 2 t))");
    defer t.allocator.free(clean);
    const slackful = try t.allocator.alloc(u8, clean.len + 1);
    defer t.allocator.free(slackful);
    @memcpy(slackful[0..clean.len], clean);
    slackful[clean.len] = 0x00;

    const built = try buildPayloadFixture(t.allocator, slackful, regs);
    defer t.allocator.free(built.buf);
    try expectPayloadRefusal(built.buf, .payload_malformed);
}

test "Pacb: corrupt node bytes mid-payload refuse payload_malformed" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Flip the root node's tag byte (just past the root-count varint)
    // to an unknown wire tag.
    const payload = try toBinaryCompact(t.allocator, "(+ 1 (* 2 t))");
    defer t.allocator.free(payload);
    payload[irRootsOffset(payload) + 1] = 0xFF;

    const built = try buildPayloadFixture(t.allocator, payload, regs);
    defer t.allocator.free(built.buf);
    try expectPayloadRefusal(built.buf, .payload_malformed);
}

test "Pacb: an oversized string pool refuses payload_malformed" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Hand-crafted 23-byte frame: a valid header, then a pool count
    // varint of 65537 (one past MAX_STRING_POOL_ENTRIES) — Cursor.init
    // refuses before anything else, and the stage maps it.
    const payload = [_]u8{
        'S', 'J', '1', '\n', // magic
        0x05, // wire version
        0x00, // flags (compact)
        0x00, 0x00, // reserved
        16, 0, 0, 0, // pool_offset = HEADER_SIZE
        20, 0, 0, 0, // roots_offset
        0x81, 0x80, 0x04, // pool_count = 65537 (LEB128)
        0x00, // pool byte_size = 0
        0x01, // root count = 1
        0x06, 0x00, // symbol node, pool idx 0
    };
    const built = try buildPayloadFixture(t.allocator, &payload, regs);
    defer t.allocator.free(built.buf);
    try expectPayloadRefusal(built.buf, .payload_malformed);
}

test "Pacb: per-payload and total payload caps refuse cap_exceeded" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // One payload past MAX_PAYLOAD_BYTES (content irrelevant — the cap
    // fires before any structural parse).
    {
        const big = try t.allocator.alloc(u8, MAX_PAYLOAD_BYTES + 1);
        defer t.allocator.free(big);
        @memset(big, 0);
        const built = try buildPayloadFixture(t.allocator, big, regs);
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .cap_exceeded);
    }
    // The 'PAYL' region past MAX_PAYL_BYTES.
    {
        const big = try t.allocator.alloc(u8, MAX_PAYL_BYTES + 1);
        defer t.allocator.free(big);
        @memset(big, 0);
        const trak = [_]TrakRec{
            .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_EXPR, .payload_off = 0, .payload_len = @intCast(big.len / 2) },
            .{ .target_id = 2, .registry = 1, .ncomp = 2, .source = SOURCE_EXPR, .payload_off = @intCast(big.len / 2), .payload_len = @intCast(big.len / 2 + 1) },
        };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &trak,
            .payl = big,
        });
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .cap_exceeded);
    }
}

test "Pacb: PAYL presence must match expr/pattern tracks (non_canonical)" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    const payload = try toBinaryCompact(t.allocator, "(+ 1 (* 2 t))");
    defer t.allocator.free(payload);

    // 'PAYL' present with no expr/pattern track (keys only).
    {
        const base = baseRecords();
        const trak = [_]TrakRec{base.trak[0]};
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &trak,
            .keys = &base.keys,
            .scen = &base.scen,
            .payl = payload,
        });
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .non_canonical);
    }
    // An expr track with 'PAYL' absent.
    {
        const base = baseRecords();
        const trak = [_]TrakRec{base.trak[1]};
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &trak,
        });
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .non_canonical);
    }
}

test "Pacb: payload spans must be bounded, in-region and non-overlapping" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    const payload = try toBinaryCompact(t.allocator, "(+ 1 (* 2 t))");
    defer t.allocator.free(payload);
    const region = try t.allocator.alloc(u8, payload.len * 2);
    defer t.allocator.free(region);
    @memcpy(region[0..payload.len], payload);
    @memcpy(region[payload.len..], payload);

    // A span past the region's end.
    {
        const trak = [_]TrakRec{
            .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_EXPR, .payload_off = @intCast(payload.len + 2), .payload_len = @intCast(payload.len) },
        };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &trak,
            .payl = region,
        });
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .payload_malformed);
    }
    // Two tracks slicing the same bytes (overlap in track order).
    {
        const trak = [_]TrakRec{
            .{ .target_id = 1, .registry = 1, .ncomp = 1, .source = SOURCE_EXPR, .payload_off = 0, .payload_len = @intCast(payload.len) },
            .{ .target_id = 2, .registry = 1, .ncomp = 2, .source = SOURCE_PATTERN, .payload_off = 0, .payload_len = @intCast(payload.len) },
        };
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &trak,
            .payl = region,
            .features = FEATURE_PATTERN_TRACKS,
        });
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .payload_malformed);
    }
    // byte_size must consume the section exactly.
    {
        const built = try buildPayloadFixture(t.allocator, region[0..payload.len], regs);
        defer t.allocator.free(built.buf);
        putU32(built.buf, built.layout.payl, @intCast(payload.len - 1));
        try expectPayloadRefusal(built.buf, .payload_malformed);
    }
    // A present zero-size 'PAYL' is the omitted case.
    {
        const base = baseRecords();
        const trak = [_]TrakRec{base.trak[1]};
        const built = try buildRecordsFixture(t.allocator, .{
            .transport = hostJoinSpec(regs),
            .regs = regs,
            .decl = &base_decl,
            .trak = &trak,
            .payl = &.{},
        });
        defer t.allocator.free(built.buf);
        try expectPayloadRefusal(built.buf, .non_canonical);
    }
}

test "Pacb: date and time payload literals walk and copy (positive fixture)" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // The walk's .date/.time arms were the only switch arms without a
    // positive fixture. Built by the real encoder — the frozen
    // `sjon.parse` + `toBinary(compact)` oracle — with one date and
    // both time spellings (with and without fractional seconds).
    const bin = try toBinaryCompact(t.allocator, "[2026-10-18 12:34:56 23:45:12.75]");
    defer t.allocator.free(bin);
    const built = try buildPayloadFixture(t.allocator, bin, regs);
    defer t.allocator.free(built.buf);

    const directory = try parseDirectory(built.buf, null);
    var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
    defer registry.deinit();
    var records = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
    defer records.deinit();
    var stage = try decodePayloads(t.allocator, built.buf, &directory, &records, null);
    defer stage.deinit();

    try t.expectEqual(@as(usize, 1), stage.payloads.len);
    try t.expectEqualSlices(u8, bin, stage.payloads[0]);
}

test "Pacb: node comments and spans payloads walk (positive fixture)" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // Spans on (the encoder default) plus node comments: a root leading
    // comment, an element leading comment, and a vector trailing
    // comment — the comment sites the cursor's own iterators consume
    // (leading inside `nextNodeView`, trailing on iterator exhaustion).
    // NOT covered: the tree-trailing block (the known gap below).
    const sjon = @import("sjon"); // write side: indented test-only
    var tree = try sjon.parse(t.allocator, "; lead\n[; inner\n1 2 ; vtail]");
    defer tree.deinit();
    const bin = try sjon.Binary.toBinary(t.allocator, tree, .{ .with_node_comments = true });
    defer bin.deinit();
    const payload = try t.allocator.dupe(u8, bin.data);
    defer t.allocator.free(payload);
    try t.expect(payload.len > 0);

    const built = try buildPayloadFixture(t.allocator, payload, regs);
    defer t.allocator.free(built.buf);

    const directory = try parseDirectory(built.buf, null);
    var registry = try decodeRegistry(t.allocator, built.buf, &directory, null);
    defer registry.deinit();
    var records = try decodeRecords(t.allocator, built.buf, &directory, &registry, null);
    defer records.deinit();
    var stage = try decodePayloads(t.allocator, built.buf, &directory, &records, null);
    defer stage.deinit();

    try t.expectEqual(@as(usize, 1), stage.payloads.len);
    try t.expectEqualSlices(u8, payload, stage.payloads[0]);
}

test "Pacb: KNOWN GAP — tree-trailing comments payloads currently refuse" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);

    // DEFERRED, explicitly (interim review finding 3 / focused ruling
    // 3): SJON's RootIter has no exhaustion-consume for the
    // [tree trailing comments] block the encoder writes after the
    // roots when with_tree_trailing_comments is set, so the exact-end
    // check refuses every such payload as payload_malformed. This test
    // pins the CURRENT refusal so the gap is visible and deliberate —
    // it is NOT an accepted contract. When the owner-approved SJON-side
    // cursor capability lands, the expectation flips to acceptance;
    // refusing the flag combination as non_canonical was ruled out as a
    // unilateral narrowing.
    const sjon = @import("sjon"); // write side: indented test-only
    var tree = try sjon.parse(t.allocator, "(+ 1 t) ; tail");
    defer tree.deinit();
    const bin = try sjon.Binary.toBinary(t.allocator, tree, .{
        .with_spans = false,
        .with_head_spans = false,
        .with_kvpair_key_spans = false,
        .with_tree_trailing_comments = true,
    });
    defer bin.deinit();
    const payload = try t.allocator.dupe(u8, bin.data);
    defer t.allocator.free(payload);
    try t.expect(payload.len > 0);

    const built = try buildPayloadFixture(t.allocator, payload, regs);
    defer t.allocator.free(built.buf);
    try expectPayloadRefusal(built.buf, .payload_malformed);
}

// ---------------------------------------------------------------------------
// T2.8 — whole-blob decode tests: assembly, ownership, PACM coherence
// ---------------------------------------------------------------------------
//
// Every fixture here is REAL: the embedded PACM is `Abi.encodeMeta`'s
// output over a score compiled in-test through `test_support.schema()`
// (the Compile/test_support/Abi/ExprTrack imports stay function-local —
// the recorded plan-02 import seam, so a non-test build never analyses
// them through this file), and the PACB sections are the test-side
// mirror of what the T3.1 encoder will emit for the same result.
// Coherence mutations patch the embedded PACM bytes IN PLACE and then
// RECOMPUTE `'TRAN'`'s pacm_fnv, so every refusal observed is the
// semantic predicate's own — never the checksum's. The fnv-only case
// is spelled separately (blob untouched, checksum lied about).

/// The host join every full-fixture score compiles against: one scalar
/// visual target, one 3-lane visual target, one scalar audio target.
const full_host = [_]PactCodec.Target{
    .{ .name = "circle-radius", .ncomp = 1 },
    .{ .name = "tint", .ncomp = 3 },
    .{ .name = "boom", .ncomp = 1, .registry = 1 },
};

/// The everything score: keys (scened, eased) + expr + explicit trigger
/// + a targeted control + an env-only control + a tempo map + a scene.
const full_source: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
    \\(tempo :at 8b :bpm 160)
    \\(scene :name drop :at 2bar :dur 2bar
    \\  (track :target circle-radius
    \\    (key :at 0b :value 30)
    \\    (key :at 4b :value 140 :ease (steps :n 8))))
    \\(track :target tint :expr [1 0 0])
    \\(trigger :target boom :at [1b 2b 4b])
    \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    \\(control :id sway :value 0.12)
;

/// Same score, linear easing only — the PACM omits `'EASE'` (the
/// programs table is the default alone).
const linear_source: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
    \\(tempo :at 8b :bpm 160)
    \\(scene :name drop :at 2bar :dur 2bar
    \\  (track :target circle-radius
    \\    (key :at 0b :value 30)
    \\    (key :at 4b :value 140)))
    \\(track :target tint :expr [1 0 0])
    \\(trigger :target boom :at [1b 2b 4b])
    \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    \\(control :id sway :value 0.12)
;

/// Same score, constant tempo — the PACM omits `'TMPO'`.
const flat_source: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
    \\(scene :name drop :at 2bar :dur 2bar
    \\  (track :target circle-radius
    \\    (key :at 0b :value 30)
    \\    (key :at 4b :value 140 :ease (steps :n 8))))
    \\(track :target tint :expr [1 0 0])
    \\(trigger :target boom :at [1b 2b 4b])
    \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    \\(control :id sway :value 0.12)
;

/// One more control — `control_count` 3 against the full score's 2.
const extra_control_source: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
    \\(tempo :at 8b :bpm 160)
    \\(scene :name drop :at 2bar :dur 2bar
    \\  (track :target circle-radius
    \\    (key :at 0b :value 30)
    \\    (key :at 4b :value 140 :ease (steps :n 8))))
    \\(track :target tint :expr [1 0 0])
    \\(trigger :target boom :at [1b 2b 4b])
    \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    \\(control :id sway :value 0.12)
    \\(control :id extra :value 0.5)
;

/// One more key — `key_count` 3 against the full score's 2.
const extra_key_source: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
    \\(tempo :at 8b :bpm 160)
    \\(scene :name drop :at 2bar :dur 2bar
    \\  (track :target circle-radius
    \\    (key :at 0b :value 30)
    \\    (key :at 4b :value 140 :ease (steps :n 8))
    \\    (key :at 6b :value 90)))
    \\(track :target tint :expr [1 0 0])
    \\(trigger :target boom :at [1b 2b 4b])
    \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    \\(control :id sway :value 0.12)
;

/// One more track — `track_count` 4 against the full score's 3.
const extra_track_source: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
    \\(tempo :at 8b :bpm 160)
    \\(scene :name drop :at 2bar :dur 2bar
    \\  (track :target circle-radius
    \\    (key :at 0b :value 30)
    \\    (key :at 4b :value 140 :ease (steps :n 8))))
    \\(track :target tint :expr [1 0 0])
    \\(track :target circle-radius :expr 0.5)
    \\(trigger :target boom :at [1b 2b 4b])
    \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
    \\(control :id sway :value 0.12)
;

/// A compile result plus its real `'PACM'` bytes, moved into place
/// together (the result is borrowed by pointer afterwards, never moved
/// again — the compile-result borrow rule).
const ScoreAndPacm = struct {
    /// The compile half's type, aliased inside this test-only struct so
    /// helper SIGNATURES can name it without a column-0
    /// `@import("Compile.zig")` line — the layer-1 closure gate
    /// (`tools/audit_rt_imports.zig`) scans column-0 lines, and the whole
    /// struct lives in the test region.
    const R = @import("Compile.zig").CompileResult;
    r: R,
    pacm: []u8,
};

fn compileOk(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    host: []const PactCodec.Target,
) !ScoreAndPacm.R {
    const Compile = @import("Compile.zig");
    const test_support = @import("test_support.zig");
    var r = try Compile.compile(alloc, test_support.schema(), source, host);
    if (!r.ok()) return error.FixtureCompileFailed;
    return r;
}

fn compileWithPacm(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    host: []const PactCodec.Target,
) !ScoreAndPacm {
    var r = try compileOk(alloc, source, host);
    errdefer r.deinit();
    const pacm = try encodePacm(alloc, &r);
    return .{ .r = r, .pacm = pacm };
}

/// The real producer's `'PACM'` bytes for one compiled fixture score.
fn encodePacm(alloc: std.mem.Allocator, r: anytype) ![]u8 {
    const Abi = @import("Abi.zig");
    const buf = try alloc.alloc(u8, Abi.metaEncodedLen(r));
    _ = try Abi.encodeMeta(r, buf);
    return buf;
}

/// `'STRS'` canonical sort order as a `std.mem.sort` comparator.
fn strsLess(_: void, a: []const u8, b: []const u8) bool {
    return strsEntryLess(a, b);
}

/// Build a whole `'PACB'` whose every section mirrors one compile
/// result — the test-side twin of the T3.1 encoder's mirror: `'TRAN'`
/// from the transport (+ both checksums over the real bytes), `'REGS'`
/// the canonical host `'PACT'`, `'DECL'` the merged join's tail, the
/// record sections from the table, `'EASE'`/`'SCEN'` per the canonical
/// presence rules, `'STRS'` the sorted control ids, `'PAYL'` the given
/// payload bytes (one per expr/pattern track, in track order), and the
/// given PACM blob verbatim (the coherent case passes the same result's
/// own emission; the coherence tests pass another score's).
fn buildScoreFixture(
    alloc: std.mem.Allocator,
    r: anytype,
    host: []const PactCodec.Target,
    payloads: []const []const u8,
    pacm: []const u8,
) !BuiltFixture {
    const table = &r.table.?;
    const want = &table.transport;

    const regs = try encodePact(alloc, host);
    defer alloc.free(regs);
    const decl_recs = try alloc.alloc(DeclRec, r.targets.len - host.len);
    defer alloc.free(decl_recs);
    for (decl_recs, r.targets[host.len..]) |*rec, tgt| {
        rec.* = .{ .registry = tgt.registry, .ncomp = tgt.ncomp };
    }
    const tmpo_recs = try alloc.alloc(TmpoRec, want.segments.len);
    defer alloc.free(tmpo_recs);
    for (tmpo_recs, want.segments) |*rec, seg| {
        rec.* = .{ .tick = seg.start_tick, .bpm = seg.bpm };
    }
    const emit_recs = try alloc.alloc(EmitRec, want.emit.len);
    defer alloc.free(emit_recs);
    for (emit_recs, want.emit) |*rec, lane| {
        rec.* = .{
            .name = @intFromEnum(lane.name),
            .registry = lane.registry,
            .target_id = lane.target_id,
        };
    }
    const trak_recs = try alloc.alloc(TrakRec, table.tracks.len);
    defer alloc.free(trak_recs);
    const key_recs = try alloc.alloc(KeyRec, table.keys.len);
    defer alloc.free(key_recs);
    for (key_recs, table.keys) |*rec, key| {
        rec.* = .{ .at = key.at, .value = key.value, .ease_ref = key.ease_ref };
    }
    var tick_total: usize = 0;
    for (table.tracks) |track| switch (track.source) {
        .trigger => |trig| switch (trig) {
            .at => |ats| tick_total += ats.len,
            .periodic => {},
        },
        else => {},
    };
    const tick_recs = try alloc.alloc(i64, tick_total);
    defer alloc.free(tick_recs);
    const scen_recs = try alloc.alloc(ScenRec, table.scenes.len);
    defer alloc.free(scen_recs);
    for (scen_recs, table.scenes) |*rec, scene| {
        rec.* = .{ .start_tick = scene.start_tick, .dur_ticks = scene.dur_ticks };
    }
    const ctrl_recs = try alloc.alloc(CtrlRec, table.controls.len);
    defer alloc.free(ctrl_recs);
    const strs_ids = try alloc.alloc([]const u8, table.controls.len);
    defer alloc.free(strs_ids);
    for (strs_ids, table.controls) |*slot, ctl| slot.* = ctl.id;
    std.mem.sort([]const u8, strs_ids, {}, strsLess);
    for (ctrl_recs, table.controls) |*rec, ctl| {
        var flags: u8 = 0;
        if (ctl.min != null) flags |= 1;
        if (ctl.max != null) flags |= 2;
        rec.* = .{
            .id = ctl.id,
            .target_id = if (ctl.target) |tg| tg.id else TrackTable.NO_TARGET,
            .registry = if (ctl.target) |tg| tg.registry else 0,
            .ncomp = ctl.ncomp,
            .type = @intFromEnum(ctl.kind),
            .flags = flags,
            .value = ctl.value,
            .min = ctl.min orelse .{ 0, 0, 0, 0 },
            .max = ctl.max orelse .{ 0, 0, 0, 0 },
        };
    }

    // 'TRAK' rows + the concatenated 'TICK'/'PAYL' regions, cursoring
    // through the payload/tick streams exactly as the encoder will.
    var payl_cursor: u32 = 0;
    var tick_cursor: u32 = 0;
    var payl_i: usize = 0;
    var tick_i: usize = 0;
    for (trak_recs, table.tracks) |*rec, track| {
        rec.* = .{
            .target_id = track.target_id,
            .registry = track.registry,
            .ncomp = track.ncomp,
            .scene = track.scene,
        };
        switch (track.source) {
            .keys => |ks| {
                rec.source = SOURCE_KEYS;
                rec.key_start = ks.start;
                rec.key_len = ks.len;
            },
            .expr, .pattern => {
                const bytes = payloads[payl_i];
                payl_i += 1;
                rec.source = if (track.source == .expr) SOURCE_EXPR else SOURCE_PATTERN;
                rec.payload_off = payl_cursor;
                rec.payload_len = @intCast(bytes.len);
                payl_cursor += @intCast(bytes.len);
            },
            .trigger => |trig| switch (trig) {
                .periodic => |p| {
                    rec.source = SOURCE_TRIGGER;
                    rec.trig_kind = TRIG_PERIODIC;
                    rec.trig_every = p.every;
                    rec.trig_offset = p.offset;
                },
                .at => |ats| {
                    rec.source = SOURCE_TRIGGER;
                    rec.trig_kind = TRIG_EXPLICIT;
                    rec.key_start = tick_cursor;
                    rec.key_len = @intCast(ats.len);
                    tick_cursor += @intCast(ats.len);
                    for (ats) |at| {
                        tick_recs[tick_i] = at;
                        tick_i += 1;
                    }
                },
            },
        }
    }

    var payl_region_len: usize = 0;
    for (payloads) |p| payl_region_len += p.len;
    const payl_region = try alloc.alloc(u8, payl_region_len);
    defer alloc.free(payl_region);
    {
        var off: usize = 0;
        for (payloads) |p| {
            @memcpy(payl_region[off..][0..p.len], p);
            off += p.len;
        }
    }

    var features: u32 = 0;
    for (table.tracks) |track| {
        if (track.source == .pattern) features = FEATURE_PATTERN_TRACKS;
    }

    return buildRecordsFixture(alloc, .{
        .transport = .{
            .bpm = want.map.bpm,
            .beats_per_bar = want.map.beats_per_bar,
            .dur = want.dur,
            .end_loop = want.end == .loop,
            .host_targets = @intCast(host.len),
            .declared_targets = @intCast(r.targets.len - host.len),
            .pact_fnv = fnv(regs),
            .pacm_fnv = fnv(pacm),
        },
        .tmpo = if (want.segments.len > 1) tmpo_recs else &.{},
        .regs = regs,
        .decl = decl_recs,
        .emit = if (emit_recs.len > 0) emit_recs else null,
        .trak = trak_recs,
        .keys = if (key_recs.len > 0) key_recs else null,
        .tick = if (tick_recs.len > 0) tick_recs else null,
        .scen = if (scen_recs.len > 0) scen_recs else null,
        .ease = if (table.programs.len > 1) table.programs else null,
        .strs = if (strs_ids.len > 0) strs_ids else null,
        .ctrl = if (ctrl_recs.len > 0) ctrl_recs else null,
        .payl = if (payl_region.len > 0) payl_region else null,
        .features = features,
        .pacm = pacm,
    });
}

fn expectDecodeRefusal(bytes: []const u8, code: RefusalCode) !void {
    var refusal: Refusal = undefined;
    const decoded = decode(t.allocator, bytes, &refusal);
    if (decoded) |payload| {
        var score = payload;
        score.deinit();
        return error.WronglyAccepted;
    } else |err| {
        try t.expectEqual(error.Refused, err);
        try t.expectEqual(code, refusal.code);
    }
}

/// Recompute `'TRAN'`'s pacm_fnv over the CURRENT embedded PACM bytes —
/// the step every semantic coherence mutation takes so the checksum
/// never masks the predicate under test.
fn repointPacmFnv(buf: []u8, layout: RecordsLayout) void {
    putU64(buf, layout.tran + 48, fnv(buf[layout.pacm..]));
}

/// Offset of a TLV section FRAME (`[id][len]` header included) inside
/// a PACM blob, walked exactly as `Pacm.decode` walks it.
fn pacmSectionOff(pacm: []const u8, id: u32) usize {
    const track_count = readU32(pacm, 28);
    const key_count = readU32(pacm, 32);
    const control_count = readU32(pacm, 36);
    var pos: usize = 40 + @as(usize, track_count) * 24 + @as(usize, key_count) * 32;
    for (0..control_count) |_| {
        const id_len: usize = readU16(pacm, pos + 6);
        pos += 64 + id_len;
    }
    while (pos < pacm.len) {
        const sid = readU32(pacm, pos);
        if (sid == id) return pos;
        pos += 8 + readU32(pacm, pos + 4);
    }
    unreachable; // the fixture's PACM carries the section
}

/// The three-line Eval key-segment math (`evalKeyTrack`'s interior
/// case), spelled inline so the test IS the text-path oracle — never a
/// re-use of decoder code.
fn interpKeys(
    keys: []const TrackTable.Key,
    programs: []const Easing.Program,
    ncomp: u8,
    at: i64,
) [4]f32 {
    var i: usize = 0;
    while (i + 1 < keys.len - 1 and keys[i + 1].at <= at) : (i += 1) {}
    const a = &keys[i];
    const b = &keys[i + 1];
    const u = @as(f64, @floatFromInt(at - a.at)) / @as(f64, @floatFromInt(b.at - a.at));
    const e = programs[b.ease_ref].eval(u);
    var out: [4]f32 = .{ 0, 0, 0, 0 };
    for (0..ncomp) |c| {
        const av: f64 = a.value[c];
        const bv: f64 = b.value[c];
        out[c] = @floatCast(av + (bv - av) * e);
    }
    return out;
}

test "Pacb: decode assembles a full compiled score and owns it after the input is clobbered" {
    const ExprTrack = @import("ExprTrack.zig");
    const PPC = RtSjon.Pattern.PPC;

    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const table = &a.r.table.?;
    const want = &table.transport;

    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);

    var score = try decode(t.allocator, built.buf, null);
    defer score.deinit();

    // OWNERSHIP: every read below happens after the input is gone.
    @memset(built.buf, 0xAA);

    // --- header + transport, field-for-field against the compile ---
    try t.expectEqual(@as(u32, 0), score.required_features);
    try t.expectEqual(@as(u64, @bitCast(want.map.bpm)), @as(u64, @bitCast(score.transport.map.bpm)));
    try t.expectEqual(want.map.beats_per_bar, score.transport.map.beats_per_bar);
    try t.expectEqual(want.map.ticks_per_beat, score.transport.map.ticks_per_beat);
    try t.expectEqual(
        @as(u64, @bitCast(want.map.ticks_per_second)),
        @as(u64, @bitCast(score.transport.map.ticks_per_second)),
    );
    try t.expectEqual(want.dur, score.transport.dur);
    try t.expectEqual(want.end, score.transport.end);
    try t.expectEqual(want.emit.len, score.transport.emit.len);
    try t.expectEqual(want.segments.len, score.transport.segments.len);
    for (want.segments, score.transport.segments) |w, g| {
        try t.expectEqual(w.start_tick, g.start_tick);
        try t.expectEqual(@as(u64, @bitCast(w.bpm)), @as(u64, @bitCast(g.bpm)));
    }
    try t.expectEqual(want.map.segments.len, score.transport.map.segments.len);
    for (want.map.segments, score.transport.map.segments) |w, g| {
        try t.expectEqual(w.start_tick, g.start_tick);
        try t.expectEqual(@as(u64, @bitCast(w.bpm)), @as(u64, @bitCast(g.bpm)));
        try t.expectEqual(@as(u64, @bitCast(w.start_sec)), @as(u64, @bitCast(g.start_sec)));
        try t.expectEqual(@as(u64, @bitCast(w.tps)), @as(u64, @bitCast(g.tps)));
    }
    try t.expectEqual(
        @as(u64, @bitCast(want.loop_secs.?)),
        @as(u64, @bitCast(score.transport.loop_secs.?)),
    );

    // --- registry identity ---
    const regs = try encodePact(t.allocator, &full_host);
    defer t.allocator.free(regs);
    try t.expectEqualSlices(u8, regs, score.regs);
    try t.expectEqual(@as(usize, 0), score.declared.len);
    try t.expectEqual(fnv(regs), score.pact_fnv);
    try t.expectEqual(fnv(a.pacm), score.pacm_fnv);
    try t.expectEqualSlices(u8, a.pacm, score.pacm);

    // --- tracks, keys, programs, controls, scenes ---
    try t.expectEqual(table.tracks.len, score.tracks.len);
    var expr_idx: usize = 0;
    var keys_idx: usize = 0;
    var trig_idx: usize = 0;
    for (table.tracks, score.tracks, 0..) |w, g, i| {
        try t.expectEqual(w.target_id, g.target_id);
        try t.expectEqual(w.registry, g.registry);
        try t.expectEqual(w.ncomp, g.ncomp);
        try t.expectEqual(w.scene, g.scene);
        switch (w.source) {
            .keys => |wks| {
                keys_idx = i;
                try t.expectEqual(wks.start, g.source.keys.start);
                try t.expectEqual(wks.len, g.source.keys.len);
            },
            .expr => {
                expr_idx = i;
                try t.expectEqualSlices(u8, expr_bin, g.source.expr);
            },
            .trigger => |wtrig| {
                trig_idx = i;
                switch (wtrig) {
                    .periodic => |wp| {
                        const gp = g.source.trigger.periodic;
                        try t.expectEqual(wp.every, gp.every);
                        try t.expectEqual(wp.offset, gp.offset);
                    },
                    .at => |wats| try t.expectEqualSlices(i64, wats, g.source.trigger.at),
                }
            },
            .pattern => return error.UnexpectedPatternTrack,
        }
    }
    try t.expectEqual(@as(usize, 3), score.tracks.len);

    try t.expectEqual(table.keys.len, score.keys.len);
    for (table.keys, score.keys) |w, g| {
        try t.expectEqual(w.at, g.at);
        try t.expectEqual(w.value, g.value);
        try t.expectEqual(w.ease_ref, g.ease_ref);
    }
    // Literal pins, independent of the builder's arithmetic: the scened
    // keys are absolute (scene start 2bar folded in), 30 → 140 eased by
    // the steps program (index 1).
    try t.expectEqual(@as(usize, 2), score.keys.len);
    try t.expectEqual(@as(i64, 2 * PPC), score.keys[0].at);
    try t.expectEqual(@as(i64, 3 * PPC), score.keys[1].at);
    try t.expectEqual(@as(f32, 30), score.keys[0].value[0]);
    try t.expectEqual(@as(f32, 140), score.keys[1].value[0]);
    try t.expectEqual(@as(u16, 1), score.keys[1].ease_ref);

    try t.expectEqual(table.programs.len, score.programs.len);
    for (table.programs, score.programs) |w, g| try t.expect(std.meta.eql(w, g));

    try t.expectEqual(table.controls.len, score.controls.len);
    for (table.controls, score.controls) |w, g| {
        try t.expectEqualStrings(w.id, g.id);
        try t.expectEqual(w.target == null, g.target == null);
        if (w.target) |wt| {
            try t.expectEqual(wt.id, g.target.?.id);
            try t.expectEqual(wt.registry, g.target.?.registry);
        }
        try t.expectEqual(w.ncomp, g.ncomp);
        try t.expectEqual(w.kind, g.kind);
        try t.expectEqual(w.value, g.value);
        try t.expectEqual(w.min == null, g.min == null);
        if (w.min) |wm| try t.expectEqual(wm, g.min.?);
        try t.expectEqual(w.max == null, g.max == null);
        if (w.max) |wm| try t.expectEqual(wm, g.max.?);
    }
    try t.expectEqualStrings("knob", score.controls[0].id);
    try t.expectEqualStrings("sway", score.controls[1].id);

    try t.expectEqual(table.scenes.len, score.scenes.len);
    for (table.scenes, score.scenes) |w, g| {
        try t.expectEqual(w.start_tick, g.start_tick);
        try t.expectEqual(w.dur_ticks, g.dur_ticks);
    }
    try t.expectEqual(@as(i64, 2 * PPC), score.scenes[0].start_tick);
    try t.expectEqual(@as(i64, 2 * PPC), score.scenes[0].dur_ticks); // :dur 2bar

    // The explicit trigger schedule: 1b/2b/4b on the 4/4 grid.
    try t.expectEqualSlices(i64, &.{ PPC / 4, PPC / 2, PPC }, score.tracks[trig_idx].source.trigger.at);

    // --- eval: the decoded expr payload vs the text path, tick 0 ---
    var want_bindings: [TrackTable.MAX_CONTROLS]ExprTrack.ControlBinding = undefined;
    for (table.controls, 0..) |ctl, i| {
        want_bindings[i] = ExprTrack.ControlBinding.fromControl(ctl);
    }
    const want_vec = try ExprTrack.evalAt(
        t.allocator,
        &a.r.validated.result.tree,
        a.r.eval_schema,
        want,
        want_bindings[0..table.controls.len],
        table.tracks[expr_idx].source.expr,
        0,
        null,
        table.tracks[expr_idx].ncomp,
    );

    var got_bindings: [TrackTable.MAX_CONTROLS]ExprTrack.ControlBinding = undefined;
    for (score.controls, 0..) |ctl, i| {
        got_bindings[i] = .{ .name = ctl.id, .value = ctl.value, .ncomp = ctl.ncomp };
    }
    var storage: ExprTrack.EnvStorage = undefined;
    const env = ExprTrack.buildEnv(&storage, &score.transport, got_bindings[0..score.controls.len], 0, null);
    var bres = try RtSjon.Expr.evalBinary(t.allocator, score.tracks[expr_idx].source.expr, env, a.r.eval_schema);
    defer bres.deinit();
    try t.expect(bres.value == .vector);
    try t.expectEqual(@as(usize, 3), bres.value.vector.len);
    var got_vec: [4]f32 = .{ 0, 0, 0, 0 };
    // Same widening as the text path's `coerce` (`toF64` + f32 cast):
    // integer-tagged literals ride `.integer_i64`, not `.number`.
    for (bres.value.vector, 0..) |v, i| {
        got_vec[i] = @floatCast(v.toF64() orelse return error.UnexpectedValue);
    }
    try t.expectEqual(want_vec, got_vec);
    try t.expectEqual([4]f32{ 1, 0, 0, 0 }, got_vec);

    // --- keys interpolation at two interior ticks, text-path oracle ---
    const dec_run = score.keys[score.tracks[keys_idx].source.keys.start..][0..score.tracks[keys_idx].source.keys.len];
    const text_run = table.trackKeys(&table.tracks[keys_idx]);
    const t1 = text_run[0].at + @divTrunc(text_run[1].at - text_run[0].at, 2);
    const t2 = text_run[0].at + @divTrunc(text_run[1].at - text_run[0].at, 4);
    try t.expectEqual(
        interpKeys(text_run, table.programs, table.tracks[keys_idx].ncomp, t1),
        interpKeys(dec_run, score.programs, score.tracks[keys_idx].ncomp, t1),
    );
    try t.expectEqual(
        interpKeys(text_run, table.programs, table.tracks[keys_idx].ncomp, t2),
        interpKeys(dec_run, score.programs, score.tracks[keys_idx].ncomp, t2),
    );
    // Structural landing: at a key tick the key's own value, bit-exact.
    try t.expectEqual(text_run[0].value, dec_run[0].value);
}

test "Pacb: decode refuses a missing required PACM section (non_canonical)" {
    const regs = try encodePact(t.allocator, &host_two);
    defer t.allocator.free(regs);
    const built = try buildRecordsFixture(t.allocator, .{
        .transport = hostJoinSpec(regs),
        .regs = regs,
        .pacm_absent = true,
    });
    defer t.allocator.free(built.buf);
    try expectDecodeRefusal(built.buf, .non_canonical);
}

test "Pacb: decode refuses structurally malformed embedded PACM (meta_malformed)" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);

    // T2.7's garbage classes, embedded: a broken magic, and a track key
    // range overrunning the key stream. Both with the checksum
    // repointed, so the structural decoder is what refuses.
    built.buf[built.layout.pacm] ^= 0xff;
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_malformed);
    built.buf[built.layout.pacm] ^= 0xff;

    putU32(built.buf, built.layout.pacm + 40 + 12, 99); // track 0 key_len
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_malformed);
}

test "Pacb: a wrong pacm_fnv alone refuses meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);

    // The blob is untouched and fully coherent; ONLY 'TRAN''s checksum
    // lies — the fast reject's own case (it must agree with the full
    // check, and catch what only it can see).
    putU64(built.buf, built.layout.tran + 48, fnv(a.pacm) ^ 1);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
}

test "Pacb: PACM transport lies refuse meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];

    // bpm f64 @8 (one lane byte), beats_per_bar u16 @24, dur i64 @16,
    // end-loop flag bit @26 — each alone, checksum repointed each time.
    pacm[9] ^= 0x01;
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    pacm[9] ^= 0x01;

    putU16(pacm, 24, 5);
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putU16(pacm, 24, 4);

    putI64(pacm, 16, 8 * RtSjon.Pattern.PPC + 1);
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putI64(pacm, 16, 8 * RtSjon.Pattern.PPC);

    pacm[26] ^= 0b10;
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    pacm[26] ^= 0b10;
}

test "Pacb: PACM count lies refuse meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);

    // A sibling score's PACM is structurally valid but disagrees on one
    // count: an extra track / key / control against the same sections.
    inline for (.{ extra_track_source, extra_key_source, extra_control_source }) |source| {
        var v = try compileWithPacm(t.allocator, source, &full_host);
        defer v.r.deinit();
        defer t.allocator.free(v.pacm);
        const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, v.pacm);
        defer t.allocator.free(built.buf);
        try expectDecodeRefusal(built.buf, .meta_incoherent);
    }
}

test "Pacb: per-track PACM lies refuse meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];
    // Offsets are RELATIVE to the PACM blob. Compile emits top-level
    // tracks, then scene children, then top-level triggers — index the
    // records by KIND, never by position.
    var keys_i: usize = 0;
    for (a.r.table.?.tracks, 0..) |track, i| {
        if (track.source == .keys) keys_i = i;
    }
    const tr0: usize = 40 + keys_i * 24; // the keys track's PACM record

    putU16(pacm, tr0 + 0, 1); // target_id 0 → 1 (tint's id)
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putU16(pacm, tr0 + 0, 0);

    pacm[tr0 + 2] = 1; // registry 0 → 1
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    pacm[tr0 + 2] = 0;

    pacm[tr0 + 3] = 2; // ncomp 1 → 2
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    pacm[tr0 + 3] = 1;

    pacm[tr0 + 4] = SOURCE_EXPR; // source keys → expr
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    pacm[tr0 + 4] = SOURCE_KEYS;
}

test "Pacb: the per-source key-range rule refuses meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];
    // Track records indexed by kind (compile order is top-level tracks,
    // then scene children, then triggers — never positional).
    var keys_i: usize = 0;
    var expr_i: usize = 0;
    var trig_i: usize = 0;
    for (a.r.table.?.tracks, 0..) |track, i| {
        switch (track.source) {
            .keys => keys_i = i,
            .expr => expr_i = i,
            .trigger => trig_i = i,
            .pattern => {},
        }
    }
    const trk: usize = 40; // track array base, relative to the blob

    // keys source: the PACM range must EQUAL the 'TRAK' fields — a len
    // lie (still structurally inside the stream) refuses.
    putU32(pacm, trk + keys_i * 24 + 12, 1); // key_len 2 → 1
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putU32(pacm, trk + keys_i * 24 + 12, 2);

    // expr source: the meta range must be (0,0) — the B1 zero-rule.
    // (Never compared against a real 'TICK' slice: 'TRAK' carries that
    // one.)
    putU32(pacm, trk + expr_i * 24 + 8, 1); // key_start 0 → 1
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putU32(pacm, trk + expr_i * 24 + 8, 0);

    // trigger source: same zero-rule.
    putU32(pacm, trk + trig_i * 24 + 8, 1); // key_start 0 → 1
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putU32(pacm, trk + trig_i * 24 + 8, 0);
}

test "Pacb: PACM key-content lies refuse meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];
    // Key array base (past the 3 track records), relative to the blob.
    const keys: usize = 40 + 3 * 24;

    putI64(pacm, keys + 32, 3 * RtSjon.Pattern.PPC + 1); // key 1 at
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putI64(pacm, keys + 32, 3 * RtSjon.Pattern.PPC);

    putF32(pacm, keys + 32 + 8, 141); // key 1 value[0]
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putF32(pacm, keys + 32 + 8, 140);
}

test "Pacb: PACM control lies refuse meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];
    // Control 0 ("knob", 64 B + 4 id bytes) right after the key stream,
    // relative to the blob.
    const ctl: usize = 40 + 3 * 24 + 2 * 32;

    putF32(pacm, ctl + 8, 0.41); // value[0] 0.4 → 0.41
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putF32(pacm, ctl + 8, 0.4);

    putU16(pacm, ctl, TrackTable.NO_TARGET); // env-only lie
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putU16(pacm, ctl, 0);

    pacm[ctl + 64 + 3] = 'c'; // id "knob" → "knoc" (not a 'STRS' entry)
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    pacm[ctl + 64 + 3] = 'b';
}

test "Pacb: PACM scene payload divergence refuses meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];

    // 'SCEN' shared fields (start_tick/dur_ticks); the name span is a
    // documented source string — trusted, never cross-checked.
    const scen = pacmSectionOff(pacm, 0x4e454353); // "SCEN"
    putI64(pacm, scen + 8 + 4, 2 * RtSjon.Pattern.PPC + 1); // scene 0 start
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
}

test "Pacb: PACM EASE divergence refuses meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];

    // Program bytes: program 1's stage 0, op 0, param 0 (the steps
    // count, 8.0). The refs array: ref[1] (1 → 0).
    const ease = pacmSectionOff(pacm, 0x45534145); // "EASE"
    const prog1_stage0_op0_param0 = ease + 8 + 4 + 772 + 4 + 16 + 4;
    putF32(pacm, prog1_stage0_op0_param0, 8.5);
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
    putF32(pacm, prog1_stage0_op0_param0, 8);

    const refs = ease + 8 + 4 + 2 * 772 + 4; // 2 programs in this fixture
    putU16(pacm, refs + 2, 0); // ref[1] 1 → 0
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
}

test "Pacb: PACM TMPO divergence refuses meta_incoherent" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);
    const pacm = built.buf[built.layout.pacm..];

    // Segment 1's bpm (160 → 161, still in domain and ascending).
    const tmpo = pacmSectionOff(pacm, 0x4f504d54); // "TMPO"
    putF64(pacm, tmpo + 8 + 16 + 8, 161);
    repointPacmFnv(built.buf, built.layout);
    try expectDecodeRefusal(built.buf, .meta_incoherent);
}

test "Pacb: EASE and TMPO presence contradictions refuse meta_incoherent" {
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);

    // Sections from the linear-only score (legitimately no 'EASE'
    // section) + the full score's PACM (carries 'EASE'): the
    // absent-one-side contradiction, spelled without touching either
    // blob's structure.
    {
        var lin = try compileWithPacm(t.allocator, linear_source, &full_host);
        defer lin.r.deinit();
        defer t.allocator.free(lin.pacm);
        var a = try compileWithPacm(t.allocator, full_source, &full_host);
        defer a.r.deinit();
        defer t.allocator.free(a.pacm);
        const built = try buildScoreFixture(t.allocator, &lin.r, &full_host, &.{expr_bin}, a.pacm);
        defer t.allocator.free(built.buf);
        try expectDecodeRefusal(built.buf, .meta_incoherent);
    }

    // Sections from the mapless score (no 'TMPO' section) + the full
    // score's PACM (carries 'TMPO').
    {
        var flat = try compileWithPacm(t.allocator, flat_source, &full_host);
        defer flat.r.deinit();
        defer t.allocator.free(flat.pacm);
        var a = try compileWithPacm(t.allocator, full_source, &full_host);
        defer a.r.deinit();
        defer t.allocator.free(a.pacm);
        const built = try buildScoreFixture(t.allocator, &flat.r, &full_host, &.{expr_bin}, a.pacm);
        defer t.allocator.free(built.buf);
        try expectDecodeRefusal(built.buf, .meta_incoherent);
    }
}

test "Pacb: every prefix of the full fixture refuses without trapping" {
    var a = try compileWithPacm(t.allocator, full_source, &full_host);
    defer a.r.deinit();
    defer t.allocator.free(a.pacm);
    const expr_bin = try toBinaryCompact(t.allocator, "[1 0 0]");
    defer t.allocator.free(expr_bin);
    const built = try buildScoreFixture(t.allocator, &a.r, &full_host, &.{expr_bin}, a.pacm);
    defer t.allocator.free(built.buf);

    for (0..built.buf.len) |n| {
        var refusal: Refusal = undefined;
        const decoded = decode(t.allocator, built.buf[0..n], &refusal);
        if (decoded) |payload| {
            var score = payload;
            score.deinit();
            return error.WronglyAccepted;
        } else |err| {
            try t.expectEqual(error.Refused, err);
        }
    }
}
