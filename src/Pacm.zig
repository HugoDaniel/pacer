//! `'PACM'` score-metadata reader — the std-only reading half of the
//! metadata blob (`Abi.encodeMeta` stays the encoder and the format of
//! record; this module restates its wire spec as reading arithmetic so
//! the playback runtime's closure never drags the compiler in).
//!
//! Layout (wire spec of record: `src/Abi.zig`'s header — restated here
//! because a reader with two implementations must not drift from its
//! writer):
//!
//!     [magic u32 'PACM'][version u32 = 1]
//!     [bpm f64][dur i64][beats_per_bar u16][flags u8][pad u8]
//!         flags: bit0 = dur present, bit1 = end is loop.
//!     [track_count u32][key_count u32][control_count u32]
//!     track_count × 24 { target_id u16, registry u8, ncomp u8,
//!                        source u8 (0 keys / 1 expr / 2 trigger / 3 pattern), pad u8×3,
//!                        key_start u32, key_len u32 (0,0 for expr/trigger/pattern),
//!                        span_start u32, span_end u32 }
//!     key_count × 32 { at i64, value f32×4, span_start u32, span_end u32 }
//!     control_count × (64 + id) {
//!         target_id u16 (0xffff = env-only), registry u8, ncomp u8,
//!         type u8 (0 slider / 1 xy / 2 color), flags u8 (bit0 min, bit1 max),
//!         id_len u16, value f32×4, min f32×4, max f32×4,
//!         value_span_start u32, value_span_end u32, id bytes }
//!
//! After the last control comes a SECTION STREAM — zero or more
//! length-prefixed TLV sections, walked to end-of-buffer, each:
//!
//!     [section_id u32][payload_len u32][payload : payload_len bytes]
//!
//! A decoder loops to end-of-buffer, dispatching known ids and skipping
//! unknown ones by length, so a decoder predating a section ignores it.
//! Each id appears at most once (a repeat is a defect); the encoder
//! emits 'SCEN' then 'EASE' then 'TMPO' and omits a section whose count
//! is zero. Payload shapes:
//!
//!     'SCEN' [count u32] count × 24 { start_tick i64, dur_ticks i64,
//!                                     name_span_start u32, name_span_end u32 }
//!     'EASE' [program_count u32]
//!            program_count × 772 { len u8, pad×3, 8 × 96 {
//!              t_end f32, v_base f32, v_span f32, ops_len u8, pad×3,
//!              4 × 20 { code u8, pad×3, params f32×4 } } }
//!            [key_ref_count u32] key_ref_count × { ease_ref u16 }
//!     'TMPO' [count u32] count × 16 { tick i64, bpm f64 }
//!
//! Role and invariants:
//!
//! * Imports std ONLY. Never `Abi` (the encoder), never `Pacb` (the
//!   container that embeds a 'PACM' and copies what it keeps) — this
//!   file is shared closure with the binary runtime (plan 02), which is
//!   why every constant and ordinal family below is a frozen copy,
//!   asserted against its source definition in `src/root.zig`.
//! * TOTAL: `decode` returns null on every defect and never traps on
//!   any byte sequence — lengths are compared before they are
//!   multiplied (divide-first, u64 arithmetic), so a hostile count
//!   cannot wrap or overrun on native or wasm32.
//! * ALIASING: every slice the view returns (a section payload, a
//!   control id) aliases the caller's blob. The view borrows, never
//!   owns; `Pacb` copies whatever it keeps past the borrow.
//! * `verifyRouting` lives in `Pacb.zig` (the resolved placement, per
//!   the focused ruling): its typed signature takes a
//!   `*const Pacb.DecodedScore`, which would make this file import
//!   `Pacb` — a std-only violation and an inverted dependency direction.
//!   The wiring landed with T2.8; this reader stays std-only.

const std = @import("std");

/// `"PACM"` read as a little-endian u32 (frozen copy of `Abi.META_MAGIC`).
pub const META_MAGIC: u32 = 0x4d434150;
/// Blob version this reader understands (frozen copy of `Abi.META_VERSION`).
pub const META_VERSION: u32 = 1;
/// magic+version (8) + transport block (20) + counts (12).
pub const META_HEADER_LEN: usize = 40;
/// Bytes per track record.
pub const META_TRACK_LEN: usize = 24;
/// Bytes per key record.
pub const META_KEY_LEN: usize = 32;
/// Fixed bytes per control record, before its id.
pub const META_CONTROL_LEN: usize = 64;
/// `target_id` of an env-only control, spelled on the wire (0xffff).
pub const META_NO_TARGET: u16 = 0xffff;
/// Frame header of a post-controls TLV section: id + payload_len.
pub const META_SECTION_HEADER_LEN: usize = 8;
/// `"SCEN"` read LE — the scenes section id.
pub const SCENES_SECTION_ID: u32 = 0x4e454353;
/// Bytes per scene record inside the `'SCEN'` payload.
pub const SCENE_REC_LEN: usize = 24;
/// `"EASE"` read LE — the easing-program section id.
pub const EASE_SECTION_ID: u32 = 0x45534145;
/// `"TMPO"` read LE — the tempo-map section id.
pub const TEMPO_SECTION_ID: u32 = 0x4f504d54;
/// Bytes per tempo-segment record inside the `'TMPO'` payload.
pub const TEMPO_REC_LEN: usize = 16;
/// Bytes per compiled-op record inside an `'EASE'` program.
pub const META_EASE_OP_LEN: usize = 20;
/// Bytes per stage record inside an `'EASE'` program.
pub const META_EASE_STAGE_LEN: usize = 96;
/// Bytes per program record inside the `'EASE'` payload.
pub const META_EASE_PROGRAM_LEN: usize = 772;

/// A track's value source, as the `'PACM'` `source` byte spells it
/// (frozen copy of `Abi.TrackSourceKind`'s wire ordinals).
pub const TrackSource = enum(u8) { keys = 0, expr = 1, trigger = 2, pattern = 3 };

/// A control's widget kind, as the `'PACM'` `type` byte spells it
/// (frozen copy of `TrackTable.ControlType`'s wire ordinals).
pub const ControlKind = enum(u8) { slider = 0, xy = 1, color = 2 };

/// Highest legal `'EASE'` op ordinal — `Easing.Op`'s 22 variants, 0..21
/// (frozen copy; a byte above this is not an op the runtime can name).
pub const MAX_EASE_OP: u8 = 21;
/// Stage slots per `'EASE'` program record (frozen copy of
/// `Easing.MAX_STAGES`).
pub const EASE_STAGE_COUNT: usize = 8;
/// Op slots per `'EASE'` stage record (frozen copy of `Easing.MAX_OPS`).
pub const EASE_OPS_PER_STAGE: usize = 4;

/// Transport domains the compiler guarantees (`TimeMap.init` asserts
/// them; a reader of untrusted at-rest bytes checks them instead).
pub const BPM_MIN: f64 = 1.0;
pub const BPM_MAX: f64 = 1000.0;
pub const BEATS_PER_BAR_MIN: u16 = 1;
pub const BEATS_PER_BAR_MAX: u16 = 16;

/// A source-coordinate span pair, as every span-carrying record spells
/// it (std-only spelling of the encoder's `Ast.Span` pair).
pub const Span = struct {
    start: u32,
    end: u32,
};

/// One decoded track record. `key_start`/`key_len` index the flat key
/// stream and are `(0, 0)` for every non-keys source.
pub const MetaTrack = struct {
    target_id: u16,
    registry: u8,
    ncomp: u8,
    source: TrackSource,
    key_start: u32,
    key_len: u32,
    span: Span,
};

/// One decoded key record. Lanes at or past the track's `ncomp` are
/// zero, as encoded.
pub const MetaKey = struct {
    at: i64,
    value: [4]f32,
    span: Span,
};

/// One decoded control record. `id` aliases the blob; `target_id` is
/// null for an env-only control (the wire sentinel).
pub const MetaControl = struct {
    target_id: ?u16,
    registry: u8,
    ncomp: u8,
    kind: ControlKind,
    value: [4]f32,
    min: ?[4]f32,
    max: ?[4]f32,
    id: []const u8,
    value_span: Span,
};

/// One decoded `'SCEN'` record. The name rides as a span — slice it
/// from the score source, as the encoder's header explains.
pub const MetaScene = struct {
    start_tick: i64,
    dur_ticks: i64,
    name_span: Span,
};

/// One decoded `'TMPO'` record — an authored tempo segment.
pub const MetaTempoSeg = struct {
    tick: i64,
    bpm: f64,
};

/// One op slot inside an `'EASE'` stage — the op ordinal plus its
/// parameters, mirroring `Easing.OpRec`'s wire shape with std types.
pub const MetaEaseOp = struct {
    code: u8,
    params: [4]f32,
};

/// One stage slot inside an `'EASE'` program record.
pub const MetaEaseStage = struct {
    t_end: f32,
    v_base: f32,
    v_span: f32,
    ops_len: u8,
    ops: [EASE_OPS_PER_STAGE]MetaEaseOp,
};

/// One `'EASE'` program record — every stage and op slot carried
/// (unused ones zeroed by the encoder), mirroring the compiled
/// `Easing.Program`'s wire shape with std types.
pub const MetaEaseProgram = struct {
    len: u8,
    stages: [EASE_STAGE_COUNT]MetaEaseStage,
};

/// A validated `'PACM'` blob: the transport scalars plus byte-slice
/// sections and typed accessors mirroring `Abi.MetaView`'s read shapes.
/// Every slice ALIASES the input blob — the view borrows, never owns.
/// An absent section reads as an empty one (`sceneCount() == 0`), which
/// is the encoder's own equivalence.
pub const MetaView = struct {
    bpm: f64,
    /// null when the transport declared no `:dur` (the flags bit).
    dur: ?i64,
    end_loop: bool,
    beats_per_bar: u16,
    /// The track array — `trackCount() × META_TRACK_LEN` aliasing bytes.
    tracks: []const u8,
    /// The key array — `keyCount() × META_KEY_LEN` aliasing bytes.
    keys: []const u8,
    /// The control stream (records + inline ids), aliasing bytes. The
    /// accessor is `controls()` (mirroring `Abi.MetaView`'s read
    /// shape), so the field carries the stream name.
    control_stream: []const u8,
    control_count: u32,
    scen: ?[]const u8 = null,
    ease: ?[]const u8 = null,
    tmpo: ?[]const u8 = null,

    pub fn trackCount(self: *const MetaView) usize {
        return self.tracks.len / META_TRACK_LEN;
    }

    pub fn keyCount(self: *const MetaView) usize {
        return self.keys.len / META_KEY_LEN;
    }

    pub fn controlCount(self: *const MetaView) usize {
        return self.control_count;
    }

    pub fn track(self: *const MetaView, i: usize) MetaTrack {
        std.debug.assert(i < self.trackCount());
        const r = self.tracks[i * META_TRACK_LEN ..][0..META_TRACK_LEN];
        return .{
            .target_id = std.mem.readInt(u16, r[0..2], .little),
            .registry = r[2],
            .ncomp = r[3],
            .source = @enumFromInt(r[4]),
            .key_start = std.mem.readInt(u32, r[8..12], .little),
            .key_len = std.mem.readInt(u32, r[12..16], .little),
            .span = .{
                .start = std.mem.readInt(u32, r[16..20], .little),
                .end = std.mem.readInt(u32, r[20..24], .little),
            },
        };
    }

    pub fn key(self: *const MetaView, i: usize) MetaKey {
        std.debug.assert(i < self.keyCount());
        const r = self.keys[i * META_KEY_LEN ..][0..META_KEY_LEN];
        return .{
            .at = std.mem.readInt(i64, r[0..8], .little),
            .value = readLanes(r[8..24]),
            .span = .{
                .start = std.mem.readInt(u32, r[24..28], .little),
                .end = std.mem.readInt(u32, r[28..32], .little),
            },
        };
    }

    pub const ControlIter = struct {
        stream: []const u8,
        left: u32,
        pos: usize,

        pub fn next(self: *ControlIter) ?MetaControl {
            if (self.left == 0) return null;
            self.left -= 1;
            const r = self.stream[self.pos..][0..META_CONTROL_LEN];
            const target_id = std.mem.readInt(u16, r[0..2], .little);
            const flags = r[5];
            const id_len = std.mem.readInt(u16, r[6..8], .little);
            const id = self.stream[self.pos + META_CONTROL_LEN ..][0..id_len];
            // Widen before the add: `META_CONTROL_LEN + id_len` alone
            // computes in u16 and overflows at the 65535-byte boundary.
            self.pos += META_CONTROL_LEN + @as(usize, id_len);
            return .{
                .target_id = if (target_id == META_NO_TARGET) null else target_id,
                .registry = r[2],
                .ncomp = r[3],
                .kind = @enumFromInt(r[4]),
                .value = readLanes(r[8..24]),
                .min = if (flags & 1 != 0) readLanes(r[24..40]) else null,
                .max = if (flags & 2 != 0) readLanes(r[40..56]) else null,
                .id = id,
                .value_span = .{
                    .start = std.mem.readInt(u32, r[56..60], .little),
                    .end = std.mem.readInt(u32, r[60..64], .little),
                },
            };
        }
    };

    /// Controls in document order — which IS the `drv_setControl` index
    /// space, so the iteration index is the slot.
    pub fn controls(self: *const MetaView) ControlIter {
        return .{ .stream = self.control_stream, .left = self.control_count, .pos = 0 };
    }

    pub fn sceneCount(self: *const MetaView) usize {
        const p = self.scen orelse return 0;
        return std.mem.readInt(u32, p[0..4], .little);
    }

    pub fn scene(self: *const MetaView, i: usize) MetaScene {
        std.debug.assert(i < self.sceneCount());
        const r = self.scen.?[4 + i * SCENE_REC_LEN ..][0..SCENE_REC_LEN];
        return .{
            .start_tick = std.mem.readInt(i64, r[0..8], .little),
            .dur_ticks = std.mem.readInt(i64, r[8..16], .little),
            .name_span = .{
                .start = std.mem.readInt(u32, r[16..20], .little),
                .end = std.mem.readInt(u32, r[20..24], .little),
            },
        };
    }

    pub fn tempoCount(self: *const MetaView) usize {
        const p = self.tmpo orelse return 0;
        return std.mem.readInt(u32, p[0..4], .little);
    }

    pub fn tempoSeg(self: *const MetaView, i: usize) MetaTempoSeg {
        std.debug.assert(i < self.tempoCount());
        const r = self.tmpo.?[4 + i * TEMPO_REC_LEN ..][0..TEMPO_REC_LEN];
        return .{
            .tick = std.mem.readInt(i64, r[0..8], .little),
            .bpm = @bitCast(std.mem.readInt(u64, r[8..16], .little)),
        };
    }

    pub fn easeProgramCount(self: *const MetaView) usize {
        const p = self.ease orelse return 0;
        return std.mem.readInt(u32, p[0..4], .little);
    }

    /// One program's full wire record — every stage and op slot carried,
    /// so this mirrors the compiled program it came from.
    pub fn easeProgram(self: *const MetaView, i: usize) MetaEaseProgram {
        std.debug.assert(i < self.easeProgramCount());
        const r = self.ease.?[4 + i * META_EASE_PROGRAM_LEN ..][0..META_EASE_PROGRAM_LEN];
        var prog: MetaEaseProgram = .{ .len = r[0], .stages = undefined };
        for (0..EASE_STAGE_COUNT) |s| {
            const sr = r[4 + s * META_EASE_STAGE_LEN ..][0..META_EASE_STAGE_LEN];
            var stage: MetaEaseStage = .{
                .t_end = readF32(sr[0..4]),
                .v_base = readF32(sr[4..8]),
                .v_span = readF32(sr[8..12]),
                .ops_len = sr[12],
                .ops = undefined,
            };
            for (0..EASE_OPS_PER_STAGE) |o| {
                const orr = sr[16 + o * META_EASE_OP_LEN ..][0..META_EASE_OP_LEN];
                stage.ops[o] = .{
                    .code = orr[0],
                    .params = readLanes(orr[4..20]),
                };
            }
            prog.stages[s] = stage;
        }
        return prog;
    }

    /// Offset of the per-key `ease_ref` array inside the `'EASE'` payload.
    fn easeRefsOff(self: *const MetaView) usize {
        return 4 + self.easeProgramCount() * META_EASE_PROGRAM_LEN;
    }

    pub fn easeRefCount(self: *const MetaView) usize {
        const p = self.ease orelse return 0;
        return std.mem.readInt(u32, p[self.easeRefsOff()..][0..4], .little);
    }

    /// The program index for the segment ENDING at key `i` — parallel to
    /// the key stream, so a consumer zips it with `key(i)`.
    pub fn easeRef(self: *const MetaView, i: usize) u16 {
        std.debug.assert(i < self.easeRefCount());
        const p = self.ease.?;
        return std.mem.readInt(u16, p[self.easeRefsOff() + 4 + i * 2 ..][0..2], .little);
    }
};

fn readF32(b: *const [4]u8) f32 {
    return @bitCast(std.mem.readInt(u32, b, .little));
}

fn readLanes(b: *const [16]u8) [4]f32 {
    var out: [4]f32 = undefined;
    for (0..4) |i| out[i] = readF32(b[i * 4 ..][0..4]);
    return out;
}

/// Decode a `'PACM'` blob. Null on any defect: bad magic, a version
/// this build does not know, transport outside the compiler's domains
/// (bpm not finite in 1..1000, beats_per_bar outside 1..16), a
/// truncated header/array/record/id, a record-width lie, an enum byte
/// outside the frozen ordinal families, a key range past the key
/// stream, an unordered span pair, a truncated or unterminated TLV
/// stream, trailing bytes, a repeated section id, or a section payload
/// that does not account exactly for its records. An UNKNOWN section id
/// is skipped by its length — that tolerance is the whole point of the
/// TLV stream, so a reader predating a section still reads everything
/// before it.
pub fn decode(blob: []const u8) ?MetaView {
    if (blob.len < META_HEADER_LEN) return null;
    if (std.mem.readInt(u32, blob[0..4], .little) != META_MAGIC) return null;
    if (std.mem.readInt(u32, blob[4..8], .little) != META_VERSION) return null;

    // Transport domains: the compiler guarantees these (`TimeMap.init`
    // asserts them on its own inputs); a reader of untrusted at-rest
    // bytes checks them instead. Checked before any length arithmetic.
    const bpm: f64 = @bitCast(std.mem.readInt(u64, blob[8..16], .little));
    if (!std.math.isFinite(bpm) or bpm < BPM_MIN or bpm > BPM_MAX) return null;
    const beats_per_bar = std.mem.readInt(u16, blob[24..26], .little);
    if (beats_per_bar < BEATS_PER_BAR_MIN or beats_per_bar > BEATS_PER_BAR_MAX) return null;

    const flags = blob[26];
    const track_count = std.mem.readInt(u32, blob[28..32], .little);
    const key_count = std.mem.readInt(u32, blob[32..36], .little);
    const control_count = std.mem.readInt(u32, blob[36..40], .little);

    var pos: usize = META_HEADER_LEN;
    // Divide before multiplying: a hostile count is bounded by the bytes
    // that actually exist, so the length arithmetic below cannot wrap.
    if ((blob.len - pos) / META_TRACK_LEN < track_count) return null;
    for (0..track_count) |i| {
        const r = blob[pos + i * META_TRACK_LEN ..][0..META_TRACK_LEN];
        if (std.enums.fromInt(TrackSource, r[4]) == null) return null;
        const ks = std.mem.readInt(u32, r[8..12], .little);
        const kl = std.mem.readInt(u32, r[12..16], .little);
        // u64 compare — a u32-max range never wraps.
        if (@as(u64, ks) + kl > key_count) return null;
        const span_start = std.mem.readInt(u32, r[16..20], .little);
        const span_end = std.mem.readInt(u32, r[20..24], .little);
        if (span_start > span_end) return null;
    }
    const tracks = blob[pos..][0 .. @as(usize, track_count) * META_TRACK_LEN];
    pos += tracks.len;

    if ((blob.len - pos) / META_KEY_LEN < key_count) return null;
    for (0..key_count) |i| {
        const r = blob[pos + i * META_KEY_LEN ..][0..META_KEY_LEN];
        if (std.mem.readInt(u32, r[24..28], .little) > std.mem.readInt(u32, r[28..32], .little)) return null;
    }
    const keys = blob[pos..][0 .. @as(usize, key_count) * META_KEY_LEN];
    pos += keys.len;

    const controls_off = pos;
    for (0..control_count) |_| {
        if (blob.len - pos < META_CONTROL_LEN) return null;
        if (std.enums.fromInt(ControlKind, blob[pos + 4]) == null) return null;
        if (std.mem.readInt(u32, blob[pos + 56 ..][0..4], .little) >
            std.mem.readInt(u32, blob[pos + 60 ..][0..4], .little)) return null;
        const id_len = std.mem.readInt(u16, blob[pos + 6 ..][0..2], .little);
        pos += META_CONTROL_LEN;
        if (blob.len - pos < id_len) return null;
        pos += id_len;
    }
    const controls = blob[controls_off..pos];

    var view: MetaView = .{
        .bpm = bpm,
        .dur = if (flags & 1 != 0) std.mem.readInt(i64, blob[16..24], .little) else null,
        .end_loop = flags & 2 != 0,
        .beats_per_bar = beats_per_bar,
        .tracks = tracks,
        .keys = keys,
        .control_stream = controls,
        .control_count = control_count,
    };

    // The TLV section stream, walked to EXACT end-of-buffer: a partial
    // frame header or trailing slack after the last frame is a defect.
    while (pos < blob.len) {
        if (blob.len - pos < META_SECTION_HEADER_LEN) return null;
        const sid = std.mem.readInt(u32, blob[pos..][0..4], .little);
        const plen = std.mem.readInt(u32, blob[pos + 4 ..][0..4], .little);
        pos += META_SECTION_HEADER_LEN;
        if (blob.len - pos < plen) return null;
        const payload = blob[pos..][0..plen];
        pos += plen;

        switch (sid) {
            SCENES_SECTION_ID => {
                if (view.scen != null) return null; // a repeat is a defect
                if (plen < 4) return null;
                const n = std.mem.readInt(u32, payload[0..4], .little);
                if (4 + @as(u64, n) * SCENE_REC_LEN != plen) return null;
                for (0..n) |i| {
                    const r = payload[4 + i * SCENE_REC_LEN ..][0..SCENE_REC_LEN];
                    if (std.mem.readInt(u32, r[16..20], .little) >
                        std.mem.readInt(u32, r[20..24], .little)) return null;
                }
                view.scen = payload;
            },
            EASE_SECTION_ID => {
                if (view.ease != null) return null; // a repeat is a defect
                if (plen < 4) return null;
                const progs = std.mem.readInt(u32, payload[0..4], .little);
                const refs_off = 4 + @as(u64, progs) * META_EASE_PROGRAM_LEN;
                if (refs_off + 4 > plen) return null;
                const refs = std.mem.readInt(u32, payload[@intCast(refs_off)..][0..4], .little);
                if (refs_off + 4 + @as(u64, refs) * 2 != plen) return null;
                // Every op byte must name a real primitive: the accessor
                // hands back op ordinals, so an unknown code is an
                // invalid value rather than a diagnosable defect.
                for (0..progs) |p| {
                    const r = payload[4 + p * META_EASE_PROGRAM_LEN ..][0..META_EASE_PROGRAM_LEN];
                    for (0..EASE_STAGE_COUNT) |s| {
                        const sr = r[4 + s * META_EASE_STAGE_LEN ..][0..META_EASE_STAGE_LEN];
                        for (0..EASE_OPS_PER_STAGE) |o|
                            if (sr[16 + o * META_EASE_OP_LEN] > MAX_EASE_OP) return null;
                    }
                }
                view.ease = payload;
            },
            TEMPO_SECTION_ID => {
                if (view.tmpo != null) return null; // a repeat is a defect
                if (plen < 4) return null;
                const n = std.mem.readInt(u32, payload[0..4], .little);
                if (4 + @as(u64, n) * TEMPO_REC_LEN != plen) return null;
                view.tmpo = payload;
            },
            else => {}, // unknown id — skipped by length, the TLV contract
        }
    }
    return view;
}

// ---------------------------------------------------------------------------
// Tests — std-only, so they live beside the reader instead of in root
// (the frozen-copy/oracle comparisons against `Abi` are in `src/root.zig`).
// ---------------------------------------------------------------------------

const t = std.testing;

/// Hand-built minimal valid blob (the std-only twin of the producer's
/// smallest useful emission): 1 keys track, 1 key, 1 env-only xy control
/// with a max but no min, no sections. Byte offsets are the wire spec.
const MINIMAL_LEN: usize = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN + META_CONTROL_LEN + 2;

fn minimalBlob(dest: []u8) usize {
    @memset(dest[0..MINIMAL_LEN], 0);
    std.mem.writeInt(u32, dest[0..4], META_MAGIC, .little);
    std.mem.writeInt(u32, dest[4..8], META_VERSION, .little);
    std.mem.writeInt(u64, dest[8..16], @bitCast(@as(f64, 120)), .little);
    std.mem.writeInt(u16, dest[24..26], 4, .little);
    std.mem.writeInt(u32, dest[28..32], 1, .little); // track_count
    std.mem.writeInt(u32, dest[32..36], 1, .little); // key_count
    std.mem.writeInt(u32, dest[36..40], 1, .little); // control_count

    // Track 0: keys source, key range [0,1), span [5,9).
    std.mem.writeInt(u16, dest[40..42], 7, .little);
    dest[42] = 1; // registry
    dest[43] = 2; // ncomp
    dest[44] = 0; // source: keys
    std.mem.writeInt(u32, dest[48..52], 0, .little); // key_start
    std.mem.writeInt(u32, dest[52..56], 1, .little); // key_len
    std.mem.writeInt(u32, dest[56..60], 5, .little); // span_start
    std.mem.writeInt(u32, dest[60..64], 9, .little); // span_end

    // Key 0: at 42, value {0.25, 0.5, 0, 0}, span [11,15).
    std.mem.writeInt(i64, dest[64..72], 42, .little);
    std.mem.writeInt(u32, dest[72..76], @bitCast(@as(f32, 0.25)), .little);
    std.mem.writeInt(u32, dest[76..80], @bitCast(@as(f32, 0.5)), .little);
    std.mem.writeInt(u32, dest[88..92], 11, .little);
    std.mem.writeInt(u32, dest[92..96], 15, .little);

    // Control 0: env-only xy with a max, id "ab", value_span [21,23).
    const c = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN;
    std.mem.writeInt(u16, dest[c..][0..2], META_NO_TARGET, .little);
    dest[c + 3] = 1; // ncomp
    dest[c + 4] = 1; // kind: xy
    dest[c + 5] = 0b10; // flags: max only
    std.mem.writeInt(u16, dest[c + 6 ..][0..2], 2, .little); // id_len
    std.mem.writeInt(u32, dest[c + 8 ..][0..4], @bitCast(@as(f32, 9)), .little); // value[0]
    std.mem.writeInt(u32, dest[c + 40 ..][0..4], @bitCast(@as(f32, 7)), .little); // max[0]
    std.mem.writeInt(u32, dest[c + 56 ..][0..4], 21, .little);
    std.mem.writeInt(u32, dest[c + 60 ..][0..4], 23, .little);
    dest[c + META_CONTROL_LEN] = 'a';
    dest[c + META_CONTROL_LEN + 1] = 'b';
    return MINIMAL_LEN;
}

/// Append one TLV frame (`[id][len][payload]`) and return the new end.
fn appendSection(dest: []u8, pos: usize, id: u32, payload: []const u8) usize {
    std.mem.writeInt(u32, dest[pos..][0..4], id, .little);
    std.mem.writeInt(u32, dest[pos + 4 ..][0..4], @intCast(payload.len), .little);
    @memcpy(dest[pos + META_SECTION_HEADER_LEN ..][0..payload.len], payload);
    return pos + META_SECTION_HEADER_LEN + payload.len;
}

/// One well-formed 'SCEN' payload: a single scene {0 ticks, 0 ticks,
/// name span [3,8)}.
fn scenPayload(dest: []u8) []const u8 {
    @memset(dest[0..28], 0);
    std.mem.writeInt(u32, dest[0..4], 1, .little);
    std.mem.writeInt(u32, dest[20..24], 3, .little);
    std.mem.writeInt(u32, dest[24..28], 8, .little);
    return dest[0..28];
}

/// One well-formed 'TMPO' payload: segments {0,120} and {720720,160}.
fn tmpoPayload(dest: []u8) []const u8 {
    std.mem.writeInt(u32, dest[0..4], 2, .little);
    std.mem.writeInt(u64, dest[8..16], @bitCast(@as(f64, 120)), .little);
    std.mem.writeInt(i64, dest[16..24], 720720, .little);
    std.mem.writeInt(u64, dest[24..32], @bitCast(@as(f64, 160)), .little);
    return dest[0..36];
}

/// One well-formed 'EASE' payload: 1 program (772 B, all-zero — op code
/// 0 names `linear`), then a 1-entry per-key ref array.
fn easePayload(dest: []u8) []const u8 {
    @memset(dest[0 .. 4 + META_EASE_PROGRAM_LEN + 4 + 2], 0);
    std.mem.writeInt(u32, dest[0..4], 1, .little); // program_count
    std.mem.writeInt(u32, dest[4 + META_EASE_PROGRAM_LEN ..][0..4], 1, .little); // key_ref_count
    return dest[0 .. 4 + META_EASE_PROGRAM_LEN + 4 + 2];
}

test "Pacm: a hand-built minimal blob decodes with every field" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);
    const blob = buf[0..len];

    const v = decode(blob) orelse return error.TestExpectedDecode;
    try t.expectEqual(@as(f64, 120), v.bpm);
    try t.expectEqual(@as(?i64, null), v.dur);
    try t.expectEqual(false, v.end_loop);
    try t.expectEqual(@as(u16, 4), v.beats_per_bar);
    try t.expectEqual(@as(usize, 1), v.trackCount());
    try t.expectEqual(@as(usize, 1), v.keyCount());
    try t.expectEqual(@as(usize, 1), v.controlCount());

    const tr = v.track(0);
    try t.expectEqual(@as(u16, 7), tr.target_id);
    try t.expectEqual(@as(u8, 1), tr.registry);
    try t.expectEqual(@as(u8, 2), tr.ncomp);
    try t.expectEqual(TrackSource.keys, tr.source);
    try t.expectEqual(@as(u32, 0), tr.key_start);
    try t.expectEqual(@as(u32, 1), tr.key_len);
    try t.expectEqual(@as(u32, 5), tr.span.start);
    try t.expectEqual(@as(u32, 9), tr.span.end);

    const k = v.key(0);
    try t.expectEqual(@as(i64, 42), k.at);
    try t.expectEqual(@as(f32, 0.25), k.value[0]);
    try t.expectEqual(@as(f32, 0.5), k.value[1]);
    try t.expectEqual(@as(u32, 11), k.span.start);
    try t.expectEqual(@as(u32, 15), k.span.end);

    var it = v.controls();
    const ctl = it.next().?;
    try t.expectEqual(@as(?u16, null), ctl.target_id);
    try t.expectEqual(ControlKind.xy, ctl.kind);
    try t.expectEqual(@as(f32, 9), ctl.value[0]);
    try t.expectEqual(@as(?[4]f32, null), ctl.min);
    try t.expectEqual(@as(?[4]f32, .{ 7, 0, 0, 0 }), ctl.max);
    try t.expectEqualStrings("ab", ctl.id);
    try t.expectEqual(@as(u32, 21), ctl.value_span.start);
    try t.expectEqual(@as(u32, 23), ctl.value_span.end);
    try t.expectEqual(@as(?MetaControl, null), it.next());

    try t.expectEqual(@as(usize, 0), v.sceneCount());
    try t.expectEqual(@as(usize, 0), v.tempoCount());
    try t.expectEqual(@as(usize, 0), v.easeProgramCount());
}

test "Pacm: the view aliases the caller's blob, never copies it" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);
    const v = decode(buf[0..len]) orelse return error.TestExpectedDecode;

    // The track array aliases the blob's bytes: patching the target id
    // in the INPUT is visible through the already-decoded view.
    try t.expectEqual(@intFromPtr(buf[40..].ptr), @intFromPtr(v.tracks.ptr));
    std.mem.writeInt(u16, buf[40..42], 99, .little);
    try t.expectEqual(@as(u16, 99), v.track(0).target_id);
}

test "Pacm: every truncated prefix is refused except section boundaries" {
    var buf: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const base = minimalBlob(&buf);
    const with_scen = appendSection(&buf, base, SCENES_SECTION_ID, scenPayload(&scratch));
    const len = appendSection(&buf, with_scen, TEMPO_SECTION_ID, tmpoPayload(&scratch));

    // A prefix that lands exactly on a section boundary is a VALID
    // shorter blob (the format is self-delimiting): {base, with_scen}.
    // Every other prefix cuts a record, an id, a frame header or a
    // payload mid-flight and must refuse.
    var n: usize = 0;
    while (n < len) : (n += 1) {
        const got = decode(buf[0..n]);
        if (n == base or n == with_scen) {
            try t.expect(got != null);
        } else {
            if (got != null) return error.WronglyAccepted;
        }
    }
}

test "Pacm: bad magic and future versions are refused" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);

    std.mem.writeInt(u32, buf[0..4], 0xdeadbeef, .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    _ = minimalBlob(&buf);
    std.mem.writeInt(u32, buf[4..8], META_VERSION + 1, .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
}

test "Pacm: count lies that break width accounting are refused" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);

    _ = minimalBlob(&buf); // 2 tracks claimed, 1 track + 1 key + 1 control exist
    std.mem.writeInt(u32, buf[28..32], 3, .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    _ = minimalBlob(&buf);
    std.mem.writeInt(u32, buf[32..36], 3, .little); // 3 keys claimed, 1 exists
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    _ = minimalBlob(&buf);
    std.mem.writeInt(u32, buf[36..40], 1, .little); // a control with no bytes left
    const cut = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN;
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..cut]));

    _ = minimalBlob(&buf);
    const c = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN;
    std.mem.writeInt(u16, buf[c + 6 ..][0..2], 60000, .little); // id runs past the end
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
}

test "Pacm: trailing bytes after the last record are refused" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);

    // A stray byte after the exact end — not a frame, just slack.
    try t.expectEqual(@as(?MetaView, null), decode(buf[0 .. len + 1]));

    // A whole unknown frame IS legal (the TLV contract), but bytes
    // after a complete frame that do not form one are not.
    var scratch: [64]u8 = undefined;
    var buf2: [1024]u8 = undefined;
    const l2 = appendSection(&buf2, minimalBlob(&buf2), SCENES_SECTION_ID, scenPayload(&scratch));
    try t.expectEqual(@as(?MetaView, null), decode(buf2[0 .. l2 + 3]));
}

test "Pacm: unknown section ids are skipped by length" {
    var buf: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const base = minimalBlob(&buf);
    const after_unknown = appendSection(&buf, base, 0x5a5a5a5a, &[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    const len = appendSection(&buf, after_unknown, SCENES_SECTION_ID, scenPayload(&scratch));

    const v = decode(buf[0..len]) orelse return error.TestExpectedDecode;
    try t.expectEqual(@as(usize, 1), v.sceneCount());
    try t.expectEqual(@as(i64, 0), v.scene(0).start_tick);
}

test "Pacm: duplicate section ids are refused" {
    var buf: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const with_scen = appendSection(&buf, minimalBlob(&buf), SCENES_SECTION_ID, scenPayload(&scratch));
    const len = appendSection(&buf, with_scen, SCENES_SECTION_ID, scenPayload(&scratch));
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    var buf2: [1024]u8 = undefined;
    const l2 = appendSection(&buf2, appendSection(&buf2, minimalBlob(&buf2), TEMPO_SECTION_ID, tmpoPayload(&scratch)), TEMPO_SECTION_ID, tmpoPayload(&scratch));
    try t.expectEqual(@as(?MetaView, null), decode(buf2[0..l2]));

    var buf3: [2048]u8 = undefined;
    const l3 = appendSection(&buf3, appendSection(&buf3, minimalBlob(&buf3), EASE_SECTION_ID, easePayload(&scratch)), EASE_SECTION_ID, easePayload(&scratch));
    try t.expectEqual(@as(?MetaView, null), decode(buf3[0..l3]));
}

test "Pacm: section payloads must account exactly for their records" {
    var buf: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;

    // 'SCEN': the frame length says one record, the count says two.
    {
        const payload = scenPayload(&scratch);
        std.mem.writeInt(u32, scratch[0..4], 2, .little);
        const len = appendSection(&buf, minimalBlob(&buf), SCENES_SECTION_ID, payload);
        try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
    }
    // 'TMPO': same lie.
    {
        const payload = tmpoPayload(&scratch);
        std.mem.writeInt(u32, scratch[0..4], 3, .little);
        const len = appendSection(&buf, minimalBlob(&buf), TEMPO_SECTION_ID, payload);
        try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
    }
    // 'EASE': the refs count does not match the bytes the frame carries.
    {
        const payload = easePayload(&scratch);
        std.mem.writeInt(u32, scratch[4 + META_EASE_PROGRAM_LEN ..][0..4], 2, .little);
        const len = appendSection(&buf, minimalBlob(&buf), EASE_SECTION_ID, payload);
        try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
    }
    // 'EASE': the program count overruns into the refs region.
    {
        const payload = easePayload(&scratch);
        std.mem.writeInt(u32, scratch[0..4], 2, .little);
        const len = appendSection(&buf, minimalBlob(&buf), EASE_SECTION_ID, payload);
        try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
    }
    // A payload too short to even carry its count.
    {
        const len = appendSection(&buf, minimalBlob(&buf), SCENES_SECTION_ID, &[_]u8{ 0, 0, 0 });
        try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
    }
}

test "Pacm: a well-formed EASE frame decodes its program and refs" {
    var buf: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const len = appendSection(&buf, minimalBlob(&buf), EASE_SECTION_ID, easePayload(&scratch));
    const v = decode(buf[0..len]) orelse return error.TestExpectedDecode;
    try t.expectEqual(@as(usize, 1), v.easeProgramCount());
    try t.expectEqual(@as(usize, 1), v.easeRefCount());
    try t.expectEqual(@as(u16, 0), v.easeRef(0));
    const prog = v.easeProgram(0);
    try t.expectEqual(@as(u8, 0), prog.len);
    try t.expectEqual(@as(u8, 0), prog.stages[0].ops[0].code); // linear
}

test "Pacm: enum bytes outside the frozen ordinal families are refused" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);

    buf[META_HEADER_LEN + 4] = 4; // source: past pattern
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    _ = minimalBlob(&buf);
    const c = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN;
    buf[c + 4] = 3; // control kind: past color
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    var buf2: [2048]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const payload = easePayload(&scratch);
    scratch[4 + 4 + 16] = MAX_EASE_OP + 1; // program 0 stage 0 op 0 code: past the 22 ops
    const len2 = appendSection(&buf2, minimalBlob(&buf2), EASE_SECTION_ID, payload);
    try t.expectEqual(@as(?MetaView, null), decode(buf2[0..len2]));
}

test "Pacm: unordered span pairs are refused" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);

    // Track span reversed (5 > 9 becomes 9 > 5).
    std.mem.writeInt(u32, buf[56..60], 9, .little);
    std.mem.writeInt(u32, buf[60..64], 5, .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    _ = minimalBlob(&buf);
    std.mem.writeInt(u32, buf[88..92], 15, .little); // key span reversed
    std.mem.writeInt(u32, buf[92..96], 11, .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    _ = minimalBlob(&buf);
    const c = META_HEADER_LEN + META_TRACK_LEN + META_KEY_LEN;
    std.mem.writeInt(u32, buf[c + 56 ..][0..4], 23, .little); // value span reversed
    std.mem.writeInt(u32, buf[c + 60 ..][0..4], 21, .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    var buf2: [1024]u8 = undefined;
    var scratch: [1024]u8 = undefined;
    const payload = scenPayload(&scratch);
    std.mem.writeInt(u32, scratch[20..24], 8, .little); // scene name span reversed
    std.mem.writeInt(u32, scratch[24..28], 3, .little);
    const len2 = appendSection(&buf2, minimalBlob(&buf2), SCENES_SECTION_ID, payload);
    try t.expectEqual(@as(?MetaView, null), decode(buf2[0..len2]));
}

test "Pacm: transport outside the compiler domains is refused" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);

    const bad_bpms = [_]f64{ 0, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 0.5, 1000.5 };
    for (bad_bpms) |bpm| {
        _ = minimalBlob(&buf);
        std.mem.writeInt(u64, buf[8..16], @bitCast(bpm), .little);
        if (decode(buf[0..len]) != null) return error.WronglyAccepted;
    }
    const bad_bars = [_]u16{ 0, 17, std.math.maxInt(u16) };
    for (bad_bars) |bars| {
        _ = minimalBlob(&buf);
        std.mem.writeInt(u16, buf[24..26], bars, .little);
        if (decode(buf[0..len]) != null) return error.WronglyAccepted;
    }

    // The closed boundaries themselves are in-domain and accepted.
    _ = minimalBlob(&buf);
    std.mem.writeInt(u64, buf[8..16], @bitCast(@as(f64, 1)), .little);
    try t.expect(decode(buf[0..len]) != null);
    _ = minimalBlob(&buf);
    std.mem.writeInt(u64, buf[8..16], @bitCast(@as(f64, 1000)), .little);
    try t.expect(decode(buf[0..len]) != null);
    _ = minimalBlob(&buf);
    std.mem.writeInt(u16, buf[24..26], 1, .little);
    try t.expect(decode(buf[0..len]) != null);
    _ = minimalBlob(&buf);
    std.mem.writeInt(u16, buf[24..26], 16, .little);
    try t.expect(decode(buf[0..len]) != null);
}

test "Pacm: key ranges past the key stream are refused" {
    var buf: [1024]u8 = undefined;
    const len = minimalBlob(&buf);

    // One key exists; a range of [1,1) runs one past it.
    std.mem.writeInt(u32, buf[48..52], 1, .little);
    std.mem.writeInt(u32, buf[52..56], 1, .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));

    // A u32-max range is compared in u64, never wrapped.
    _ = minimalBlob(&buf);
    std.mem.writeInt(u32, buf[48..52], std.math.maxInt(u32), .little);
    std.mem.writeInt(u32, buf[52..56], std.math.maxInt(u32), .little);
    try t.expectEqual(@as(?MetaView, null), decode(buf[0..len]));
}
