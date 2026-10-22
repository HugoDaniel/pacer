//! Production `prt_load` negative suite — binary03 T6a.
//!
//! This is the FIRST bounded slice of T6: the negative-suite MECHANISM plus
//! the container-envelope and record-domain refusals. It deliberately does
//! NOT cover the T6b workload (compact payloads, PACM structural/coherence
//! mutation families, the registry-identity matrix, checksum-only lies, the
//! expr dry-run, or cross-section PACM divergence). Those stay unclaimed.
//!
//! Every case calls the ACTUAL production loader through the std-only
//! `NativeRt` C facade. There is no decoder, evaluator, materializer, or
//! refusal mapper in this file: mutations are byte edits over the committed
//! `tools/testdata/pacb/{keys-only,expr-keys,full-small}.pacb` fixtures, and
//! expected status/reason pairs are the production contract. `pacer` is
//! imported only for its public format constants and directory view.
//!
//! ## Transactional contract
//!
//! Each family starts with a real successful load of the unmodified fixture,
//! then applies live state where the fixture allows it (a held dynamic slot,
//! a document control, a BPM nudge). Before every refusal the suite copies
//! the live `'PACM'` and complete `'PACW'` surfaces and snapshots the
//! expression-failure counter. A refusal must return exactly status 1 with
//! exactly the named reason, and leave metadata, both frame probes, and the
//! counter unchanged. A status-2 bad call must additionally leave the prior
//! load-error word untouched. The clean fixture bytes are restored to the
//! input zone after every assertion; each mutation starts from a fresh copy
//! of the committed base, never from a previous mutation.
//!
//! ## Prefixes
//!
//! The prefix family is derived from the actual length of the committed
//! `keys-only` blob: every proper prefix `0..len` is attempted. Prefixes
//! shorter than the 4-byte magic are `bad_magic` (reason 0); every longer
//! prefix is a directory/truncation refusal (reason 3). The full blob is
//! loaded successfully first.
//!
//! ## Source corrections (recorded, not papered over)
//!
//! `Pacb.decodeRecords` enforces the KEYS lane-domain rule (lanes at or
//! above a track's `ncomp` must be zero) but does not apply a finiteness
//! check to an active key value. The three `keys-value-*` cases therefore
//! place the non-finite value in a zero-required lane, where the production
//! `key_invalid` gate is reached (reason 5). An active-lane non-finite value
//! is not a reason-5 case in v1: it would decode and only fail the later
//! PACM cross-check (reason 10, a T6b surface). The same source reading
//! applies to CTRL `value`: v1 checks finiteness for the optional min/max
//! lanes, so the `ctrl-*-*` cases mutate those lanes. No production code is
//! changed to manufacture either expectation.

const std = @import("std");
const pacer = @import("pacer");
const NativeRt = @import("NativeRt.zig");

const Pb = pacer.Pacb;
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The committed fixture blobs, read once by the caller. They are
/// immutable inputs: this suite only ever mutates copies. `host_join`
/// is the B2a registry fixture: a real CLI pack whose pack-time host
/// join is NON-empty (`'REGS'` carries `glow:1:0, flow:1:0`), so the
/// registry-identity family can load it against canonical-but-mismatched
/// joins — the three older blobs all pack against the empty join.
pub const Fixtures = struct {
    keys_only: []const u8,
    expr_keys: []const u8,
    full_small: []const u8,
    host_join: []const u8,
};

/// The pack-time host join of the `host-join` fixture, spelled by the
/// fixture source's regen command (`--target glow:1:0 --target
/// flow:1:0`) and carried in its `'REGS'` section. The suite encodes
/// the same triples through the actual `PactCodec` producer.
const HOST_JOIN_TARGETS = [_]pacer.Compile.Target{
    .{ .name = "glow", .ncomp = 1, .registry = 0 },
    .{ .name = "flow", .ncomp = 1, .registry = 0 },
};

/// Frozen format-derived sizes. `Abi.META_EASE_*` are the public wire
/// constants; the directory/EASE arithmetic below uses these, never an
/// unexplained absolute fixture offset.
const EASE_PROGRAM_LEN: usize = pacer.Abi.META_EASE_PROGRAM_LEN;
const EASE_STAGE_LEN: usize = pacer.Abi.META_EASE_STAGE_LEN;
const EASE_OP_LEN: usize = pacer.Abi.META_EASE_OP_LEN;
const MAGIC_LEN: usize = @sizeOf(@TypeOf(Pb.MAGIC));
const NO_SLOT: u32 = 0xffff_ffff;

// Frozen field positions inside v1 records. Every one is named here once so
// the mutation table reads as format fields, not unexplained byte offsets.
const HEADER_MAGIC_OFF: usize = 0;
const HEADER_VERSION_OFF: usize = 4;
const HEADER_FEATURES_OFF: usize = 8;
const HEADER_COUNT_OFF: usize = 12;
const DIR_ID_OFF: usize = 0;
const DIR_OFF_OFF: usize = 4;
const DIR_LEN_OFF: usize = 8;
const COUNT_OFF: usize = 0;
const TRAN_BPM_OFF: usize = 0;
const TMPO_REC_BPM_OFF: usize = 8;
const KEY_REC_VALUE_OFF: usize = 8;
const CTRL_REC_MIN_OFF: usize = 28;
const EASE_STAGE_TEND_OFF: usize = 0;
const EASE_OP_CODE_OFF: usize = 0;
const EASE_OP_PARAM_OFF: usize = 4;

/// The two frame probes used to prove a refusal preserved the live score.
const FRAME_SECONDS: f64 = 0.3;
const FRAME_TICKS: i64 = 7;

pub const Error = error{
    CounterMismatch,
    DuplicateMutationName,
    FixtureInvalid,
    FixtureMissingSection,
    NegativeMismatch,
    StateSetupFailed,
    StateMismatch,
};

const SectionSpec = struct {
    kind: Pb.SectionKind,
    payload: []const u8,
};

const Snapshot = struct {
    meta: []const u8,
    frame_seconds: []const u8,
    frame_ticks: []const u8,
    counter: u32,
};

/// One independent family of mutations sharing a live baseline. The live
/// score is ONLY ever the clean fixture; every attempted mutation is
/// expected to refuse, so the baseline stays valid for the whole family.
const Family = struct {
    a: Allocator,
    out: *Io.Writer,
    base: []const u8,
    pact: []const u8,
    snap: Snapshot,

    fn begin(
        a: Allocator,
        out: *Io.Writer,
        base: []const u8,
        pact: []const u8,
    ) !Family {
        NativeRt.reset();

        if (base.len > NativeRt.pacbCap()) return error.FixtureInvalid;
        if (pact.len > NativeRt.targetsCap()) return error.FixtureInvalid;
        @memcpy(NativeRt.pacbPtr()[0..base.len], base);
        @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);

        const status = NativeRt.load(@intCast(base.len), @intCast(pact.len));
        if (status != 0) {
            try out.print(
                "negatives: baseline load failed: status {d} reason {d}\n",
                .{ status, NativeRt.loadError() },
            );
            return error.FixtureInvalid;
        }

        // Apply live state the fixture allows. The dynamic slot is always
        // valid for these fixtures (declared target 0 is a scalar); the
        // document control exists in full-small and is absent in keys-only;
        // the BPM nudge is accepted only by a constant-tempo fixture.
        const slot = NativeRt.registerControl(0, 0, 1);
        if (slot == NO_SLOT) return error.StateSetupFailed;
        if (NativeRt.setControl(slot, 0.75, 0.0, 0.0, 0.0) != 0)
            return error.StateSetupFailed;
        _ = NativeRt.setControl(0, 0.9, 0.0, 0.0, 0.0);
        _ = NativeRt.setBpm(90);

        const seconds_len = NativeRt.evalSeconds(FRAME_SECONDS);
        if (seconds_len == 0) return error.StateSetupFailed;
        const frame_seconds = try a.dupe(u8, NativeRt.writesPtr()[0..seconds_len]);

        const ticks_len = NativeRt.evalTicks(FRAME_TICKS);
        if (ticks_len == 0) return error.StateSetupFailed;
        const frame_ticks = try a.dupe(u8, NativeRt.writesPtr()[0..ticks_len]);

        const meta_len = NativeRt.metaLen();
        if (meta_len == 0) return error.StateSetupFailed;
        const meta = try a.dupe(u8, NativeRt.metaPtr()[0..meta_len]);

        return .{
            .a = a,
            .out = out,
            .base = base,
            .pact = pact,
            .snap = .{
                .meta = meta,
                .frame_seconds = frame_seconds,
                .frame_ticks = frame_ticks,
                .counter = NativeRt.exprFailures(),
            },
        };
    }

    fn end(_: *Family) void {
        NativeRt.reset();
    }

    /// Assert every preserved surface. The counter is read BEFORE the frame
    /// probes, because those probes are allowed to increment it again.
    fn assertState(self: *Family, name: []const u8) !void {
        if (NativeRt.exprFailures() != self.snap.counter) {
            try self.out.print(
                "negatives: {s}: expr-failure counter moved {d}->{d} across a refusal\n",
                .{ name, self.snap.counter, NativeRt.exprFailures() },
            );
            return error.StateMismatch;
        }
        if (NativeRt.metaLen() != self.snap.meta.len) {
            try self.out.print(
                "negatives: {s}: meta length changed {d}->{d} across a refusal\n",
                .{ name, self.snap.meta.len, NativeRt.metaLen() },
            );
            return error.StateMismatch;
        }
        if (!std.mem.eql(u8, self.snap.meta, NativeRt.metaPtr()[0..NativeRt.metaLen()])) {
            try self.out.print("negatives: {s}: meta bytes changed across a refusal\n", .{name});
            return error.StateMismatch;
        }

        const seconds_len = NativeRt.evalSeconds(FRAME_SECONDS);
        if (seconds_len != self.snap.frame_seconds.len or
            !std.mem.eql(u8, self.snap.frame_seconds, NativeRt.writesPtr()[0..seconds_len]))
        {
            try self.out.print(
                "negatives: {s}: seconds frame changed across a refusal (expected {d} bytes, got {d})\n",
                .{ name, self.snap.frame_seconds.len, seconds_len },
            );
            return error.StateMismatch;
        }

        const ticks_len = NativeRt.evalTicks(FRAME_TICKS);
        if (ticks_len != self.snap.frame_ticks.len or
            !std.mem.eql(u8, self.snap.frame_ticks, NativeRt.writesPtr()[0..ticks_len]))
        {
            try self.out.print(
                "negatives: {s}: tick frame changed across a refusal (expected {d} bytes, got {d})\n",
                .{ name, self.snap.frame_ticks.len, ticks_len },
            );
            return error.StateMismatch;
        }

        // The probes above are the same deterministic sequence for every
        // case, so any counter movement they cause is the new baseline.
        // The refusal itself was already checked against the old value
        // BEFORE these evaluations ran.
        self.snap.counter = NativeRt.exprFailures();
    }

    /// Overwrite the input zone, require status 1 + the exact reason, prove
    /// the old score is intact, then restore the clean fixture bytes.
    fn expectRefusal(
        self: *Family,
        name: []const u8,
        bytes: []const u8,
        reason: u32,
    ) !void {
        if (bytes.len > NativeRt.pacbCap()) {
            try self.out.print(
                "negatives: {s}: mutation is {d} bytes, over the production PACB cap {d}\n",
                .{ name, bytes.len, NativeRt.pacbCap() },
            );
            return error.NegativeMismatch;
        }

        @memcpy(NativeRt.pacbPtr()[0..bytes.len], bytes);
        const status = NativeRt.load(@intCast(bytes.len), @intCast(self.pact.len));
        const got_reason = NativeRt.loadError();
        if (status != 1 or got_reason != reason) {
            try self.out.print(
                "negatives: {s}: expected status 1 reason {d}, got status {d} reason {d} ({d} bytes)\n",
                .{ name, reason, status, got_reason, bytes.len },
            );
            return error.NegativeMismatch;
        }

        try self.assertState(name);
        @memcpy(NativeRt.pacbPtr()[0..self.base.len], self.base);
    }

    /// Require a status-2 bad call: the prior load-error word and every live
    /// surface survive. The caller owns any input-zone corruption.
    fn expectBadCall(
        self: *Family,
        name: []const u8,
        pacb_len: u32,
        targets_len: u32,
    ) !void {
        const reason_before = NativeRt.loadError();
        const status = NativeRt.load(pacb_len, targets_len);
        if (status != 2) {
            try self.out.print(
                "negatives: {s}: expected status 2, got status {d} reason {d}\n",
                .{ name, status, NativeRt.loadError() },
            );
            return error.NegativeMismatch;
        }
        if (NativeRt.loadError() != reason_before) {
            try self.out.print(
                "negatives: {s}: bad call changed the load-error word {d}->{d}\n",
                .{ name, reason_before, NativeRt.loadError() },
            );
            return error.NegativeMismatch;
        }
        try self.assertState(name);
        try self.out.print(
            "negatives: {s}: status 2, prior reason {d} preserved\n",
            .{ name, reason_before },
        );
    }
};

/// Summary partition counters, one increment per operation AT the place the
/// operation actually executes. Every summary term must be one of these —
/// never derived from a fixture length or from the names list (B1).
const Counters = struct {
    /// Every expected-under-test production call: named mutations, bad
    /// calls, prefix attempts. The setup/probe loads stay uncounted, and
    /// the enumeration is exact: the three step-1 fixture loads, the
    /// three Family.begin baseline loads (one per family), and the
    /// bad-call family's prior-reason re-eval — seven uncounted loads in
    /// all, none of them attempts.
    attempted: usize = 0,
    named: usize = 0,
    bad_calls: usize = 0,
    prefix: usize = 0,
    /// B2a: characterization attempts that the production loader must
    /// ACCEPT (status 0) — named v1 tolerances and honest-rewrite
    /// controls. Never counted as refusals; every one still rides the
    /// real loader and a unique name.
    positive: usize = 0,
    /// Family labels ride the names list for uniqueness but are never
    /// attempts.
    family_labels: usize = 0,
};

fn addName(a: Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return error.DuplicateMutationName;
    }
    try names.append(a, name);
}

fn runNamed(
    fam: *Family,
    names: *std.ArrayList([]const u8),
    counters: *Counters,
    name: []const u8,
    bytes: []const u8,
    reason: u32,
) !void {
    try addName(fam.a, names, name);
    counters.named += 1;
    counters.attempted += 1;
    try fam.expectRefusal(name, bytes, reason);
    try fam.out.print("negatives: {s}: status 1 reason {d}\n", .{ name, reason });
}

/// Count and require one status-2 bad call; name uniqueness rides `names`.
fn runBadCall(
    fam: *Family,
    names: *std.ArrayList([]const u8),
    counters: *Counters,
    name: []const u8,
    pacb_len: u32,
    targets_len: u32,
) !void {
    try addName(fam.a, names, name);
    counters.bad_calls += 1;
    counters.attempted += 1;
    try fam.expectBadCall(name, pacb_len, targets_len);
}

// ---------------------------------------------------------------------------
// Container/directory helpers — structure only, never a second decoder
// ---------------------------------------------------------------------------

fn findSection(base: []const u8, kind: Pb.SectionKind) Pb.Section {
    const dir = Pb.parseDirectory(base, null) catch unreachable;
    return dir.find(kind).?.*;
}

fn sectionPayload(base: []const u8, kind: Pb.SectionKind) []const u8 {
    const section = findSection(base, kind);
    return base[section.off..][0..section.len];
}

fn collectSections(a: Allocator, base: []const u8) ![]SectionSpec {
    const dir = try Pb.parseDirectory(base, null);
    const specs = try a.alloc(SectionSpec, dir.slice().len);
    for (dir.slice(), 0..) |section, i| {
        specs[i] = .{
            .kind = section.kind,
            .payload = base[section.off..][0..section.len],
        };
    }
    return specs;
}

/// Canonical v1 container assembly from parts. Every outer offset/length is
/// recomputed here, so a mutation that changes a section's size reaches its
/// claimed gate instead of failing directory arithmetic first.
fn rebuild(a: Allocator, specs: []const SectionSpec, features: u32) ![]u8 {
    var total: u64 = Pb.HEADER_LEN + specs.len * Pb.DIRECTORY_ENTRY_LEN;
    for (specs) |spec| total += spec.payload.len;
    if (total > std.math.maxInt(u32)) return error.FixtureInvalid;

    const buf = try a.alloc(u8, @intCast(total));
    putU32(buf, HEADER_MAGIC_OFF, Pb.MAGIC);
    putU32(buf, HEADER_VERSION_OFF, Pb.VERSION);
    putU32(buf, HEADER_FEATURES_OFF, features);
    putU32(buf, HEADER_COUNT_OFF, @intCast(specs.len));

    var pos: usize = Pb.HEADER_LEN + specs.len * Pb.DIRECTORY_ENTRY_LEN;
    for (specs, 0..) |spec, i| {
        const at = Pb.HEADER_LEN + i * Pb.DIRECTORY_ENTRY_LEN;
        putU32(buf, at + DIR_ID_OFF, @intFromEnum(spec.kind));
        putU32(buf, at + DIR_OFF_OFF, @intCast(pos));
        putU32(buf, at + DIR_LEN_OFF, @intCast(spec.payload.len));
        @memcpy(buf[pos..][0..spec.payload.len], spec.payload);
        pos += spec.payload.len;
    }
    return buf;
}

fn replaceSection(
    a: Allocator,
    base: []const u8,
    kind: Pb.SectionKind,
    payload: []const u8,
) ![]u8 {
    const specs = try collectSections(a, base);
    var found = false;
    for (specs) |*spec| {
        if (spec.kind == kind) {
            spec.payload = payload;
            found = true;
        }
    }
    if (!found) return error.FixtureMissingSection;
    return rebuild(a, specs, 0);
}

fn duplicate(base: []const u8, a: Allocator) ![]u8 {
    return a.dupe(u8, base);
}

fn putU8(bytes: []u8, at: usize, value: u8) void {
    bytes[at] = value;
}

fn putU16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn putU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn putI64(bytes: []u8, at: usize, value: i64) void {
    std.mem.writeInt(i64, bytes[at..][0..8], value, .little);
}

fn putF32(bytes: []u8, at: usize, value: f32) void {
    putU32(bytes, at, @bitCast(value));
}

fn putF64(bytes: []u8, at: usize, value: f64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], @bitCast(value), .little);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

// ---------------------------------------------------------------------------
// Envelope mutations
// ---------------------------------------------------------------------------

fn forgedMagic(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    putU32(out, HEADER_MAGIC_OFF, 0x5858_5858); // "XXXX"
    return out;
}

fn forgedVersion(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    putU32(out, HEADER_VERSION_OFF, 99);
    return out;
}

fn forgedFeatures(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    putU32(out, HEADER_FEATURES_OFF, 0x8000_0000);
    return out;
}

fn directoryOverlap(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const dir = Pb.parseDirectory(base, null) catch unreachable;
    if (dir.slice().len < 2) return error.FixtureInvalid;
    // Point entry 1 at entry 0's payload: contiguity/exact placement fails.
    putU32(out, Pb.HEADER_LEN + 1 * Pb.DIRECTORY_ENTRY_LEN + DIR_OFF_OFF, dir.sections[0].off);
    return out;
}

fn directoryOverrun(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const dir = Pb.parseDirectory(base, null) catch unreachable;
    const last = dir.slice().len - 1;
    putU32(out, Pb.HEADER_LEN + last * Pb.DIRECTORY_ENTRY_LEN + DIR_LEN_OFF, std.math.maxInt(u32));
    return out;
}

fn directoryReorder(a: Allocator, base: []const u8) ![]u8 {
    const specs = try collectSections(a, base);
    if (specs.len < 2) return error.FixtureInvalid;
    std.mem.swap(SectionSpec, &specs[0], &specs[1]);
    return rebuild(a, specs, 0);
}

fn directoryGap(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const dir = Pb.parseDirectory(base, null) catch unreachable;
    // The first payload must begin immediately after the directory.
    putU32(out, Pb.HEADER_LEN + DIR_OFF_OFF, dir.sections[0].off + 1);
    return out;
}

fn directoryDuplicateId(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const dir = Pb.parseDirectory(base, null) catch unreachable;
    if (dir.slice().len < 2) return error.FixtureInvalid;
    putU32(out, Pb.HEADER_LEN + 1 * Pb.DIRECTORY_ENTRY_LEN + DIR_ID_OFF, @intFromEnum(dir.sections[0].kind));
    return out;
}

fn directoryUnknownId(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    putU32(out, Pb.HEADER_LEN + 1 * Pb.DIRECTORY_ENTRY_LEN + DIR_ID_OFF, 0xdead_beef);
    return out;
}

fn directoryTrailingSlack(a: Allocator, base: []const u8) ![]u8 {
    const out = try a.alloc(u8, base.len + 1);
    @memcpy(out[0..base.len], base);
    out[base.len] = 0;
    return out;
}

fn trakCountInflated(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .trak);
    putU32(out, section.off + COUNT_OFF, readU32(base, section.off + COUNT_OFF) + 1);
    return out;
}

/// A properly sized TICK section carrying `MAX_TICK_ENTRIES + 1` records,
/// built from the public cap and record width. The outer directory is a
/// valid canonical 3-section container; the directory-level cap gate is the
/// first production check to see it. Input length stays inside the runtime
/// PACB zone.
fn tickCapFixture(a: Allocator, base: []const u8) ![]u8 {
    const tran = try a.dupe(u8, sectionPayload(base, .tran));
    const pacm = try a.dupe(u8, sectionPayload(base, .pacm));
    const count: usize = Pb.MAX_TICK_ENTRIES + 1;
    const payload = try a.alloc(u8, 4 + count * Pb.TICK_REC_LEN);
    @memset(payload, 0);
    putU32(payload, COUNT_OFF, @intCast(count));

    const specs = [_]SectionSpec{
        .{ .kind = .tran, .payload = tran },
        .{ .kind = .tick, .payload = payload },
        .{ .kind = .pacm, .payload = pacm },
    };
    return rebuild(a, &specs, 0);
}

// ---------------------------------------------------------------------------
// Transport / tempo numeric domains
// ---------------------------------------------------------------------------

fn tranBpm(a: Allocator, base: []const u8, value: f64) ![]u8 {
    const out = try duplicate(base, a);
    putF64(out, findSection(base, .tran).off + TRAN_BPM_OFF, value);
    return out;
}

fn tmpoBpm(a: Allocator, base: []const u8, value: f64) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .tmpo);
    if (readU32(base, section.off) < 2) return error.FixtureInvalid;
    // Segment 1's bpm; segment 0 stays the TRAN mirror.
    putF64(out, section.off + 4 + 1 * Pb.TMPO_REC_LEN + TMPO_REC_BPM_OFF, value);
    return out;
}

// ---------------------------------------------------------------------------
// Keys / controls numeric fields
// ---------------------------------------------------------------------------

fn keyPadLane(a: Allocator, base: []const u8, value: f32) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .keys);
    // Key record 0 belongs to a one-component track; lane 1 is the
    // zero-required domain lane, so a non-finite value is a key_invalid.
    putF32(out, section.off + 4 + 0 * Pb.KEYS_REC_LEN + KEY_REC_VALUE_OFF + 1 * 4, value);
    return out;
}

fn controlMinLane(a: Allocator, base: []const u8, value: f32) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .ctrl);
    // Record 0 has both min/max flags set; lane 0 is a checked finite lane.
    putF32(out, section.off + 4 + 0 * Pb.CTRL_REC_LEN + CTRL_REC_MIN_OFF, value);
    return out;
}

// ---------------------------------------------------------------------------
// EASE
// ---------------------------------------------------------------------------

fn easeProgramAt(program: usize) usize {
    return 4 + program * EASE_PROGRAM_LEN;
}

fn easeStageAt(program: usize, stage: usize) usize {
    return easeProgramAt(program) + 4 + stage * EASE_STAGE_LEN;
}

fn easeOpAt(program: usize, stage: usize, op: usize) usize {
    return easeStageAt(program, stage) + 16 + op * EASE_OP_LEN;
}

fn easeRefsCountAt(base: []const u8) usize {
    const payload = sectionPayload(base, .ease);
    const n = readU32(payload, COUNT_OFF);
    return 4 + @as(usize, n) * EASE_PROGRAM_LEN;
}

fn easeRefAt(base: []const u8, index: usize) usize {
    return easeRefsCountAt(base) + 4 + index * 2;
}

fn easeStageTEnd(a: Allocator, base: []const u8, value: f32) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .ease);
    putF32(out, section.off + easeStageAt(1, 0) + EASE_STAGE_TEND_OFF, value);
    return out;
}

fn easeOpParam(a: Allocator, base: []const u8, value: f32) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .ease);
    putF32(out, section.off + easeOpAt(1, 0, 0) + EASE_OP_PARAM_OFF, value);
    return out;
}

fn easeRefRange(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .ease);
    const n = readU32(sectionPayload(base, .ease), 0);
    putU16(out, section.off + easeRefAt(base, 0), @intCast(n));
    return out;
}

fn easeRefDisagrees(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .ease);
    // The KEYS stream says key 1 uses program 1; the redundant refs-array
    // spelling is required to agree elementwise.
    putU16(out, section.off + easeRefAt(base, 1), 0);
    return out;
}

fn easeStageDomain(a: Allocator, base: []const u8) ![]u8 {
    return easeStageTEnd(a, base, 0.0);
}

fn easeOpPadding(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .ease);
    putU8(out, section.off + easeOpAt(1, 0, 0) + EASE_OP_CODE_OFF + 1, 1);
    return out;
}

fn easeProgramCap(a: Allocator, base: []const u8) ![]u8 {
    const count: usize = Pb.MAX_EASE_PROGRAMS + 1;
    const payload = try a.alloc(u8, 4 + count * EASE_PROGRAM_LEN);
    @memset(payload, 0);
    putU32(payload, COUNT_OFF, @intCast(count));
    return replaceSection(a, base, .ease, payload);
}

fn easeDegeneratePresent(a: Allocator, base: []const u8) ![]u8 {
    const src = sectionPayload(base, .ease);
    if (readU32(src, COUNT_OFF) < 1) return error.FixtureInvalid;
    const payload = try a.alloc(u8, 4 + EASE_PROGRAM_LEN + 4);
    @memset(payload, 0);
    putU32(payload, COUNT_OFF, 1);
    @memcpy(payload[4..][0..EASE_PROGRAM_LEN], src[4..][0..EASE_PROGRAM_LEN]);
    putU32(payload, 4 + EASE_PROGRAM_LEN, 0);
    return replaceSection(a, base, .ease, payload);
}

fn easeRefsCountMismatch(a: Allocator, base: []const u8) ![]u8 {
    const src = sectionPayload(base, .ease);
    const programs = readU32(src, COUNT_OFF);
    const table_end = 4 + @as(usize, programs) * EASE_PROGRAM_LEN;
    const refs = readU32(src, table_end);
    if (refs == 0) return error.FixtureInvalid;

    const new_refs = refs - 1;
    const new_len = table_end + 4 + @as(usize, new_refs) * 2;
    const payload = try a.alloc(u8, new_len);
    @memcpy(payload[0..table_end], src[0..table_end]);
    putU32(payload, table_end, new_refs);
    @memcpy(
        payload[table_end + 4 ..][0 .. @as(usize, new_refs) * 2],
        src[table_end + 4 ..][0 .. @as(usize, new_refs) * 2],
    );
    return replaceSection(a, base, .ease, payload);
}

// ---------------------------------------------------------------------------
// Suite
// ---------------------------------------------------------------------------

/// Run T6a. The caller supplies the three committed fixture blobs; every
/// runtime call below is the real `prt_load` through `NativeRt`.
pub fn run(gpa: Allocator, out: *Io.Writer, fixtures: Fixtures) !void {
    // Every mutation copy lives in one suite-local arena: the executable
    // callers pass a general-purpose allocator and still get an exact,
    // leak-free run (the test callers may pass an arena of their own).
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    defer NativeRt.reset();
    NativeRt.reset();

    // The committed empty host join — every fixture declares its targets.
    const none = [_]pacer.Compile.Target{};
    const pact_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&none));
    const pact = try pacer.PactCodec.encodeTargets(&none, pact_buf);

    // The host-join fixture's own pack-time join (its 'REGS' payload).
    const join_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&HOST_JOIN_TARGETS));
    const join_pact = try pacer.PactCodec.encodeTargets(&HOST_JOIN_TARGETS, join_buf);

    var names: std.ArrayList([]const u8) = .empty;
    var counters = Counters{};

    // 1. Every full fixture must load successfully before any mutation,
    //    each against its own pack-time join (the three declared-only
    //    blobs pack against the empty join; host-join packs against the
    //    non-empty 'REGS' join it carries).
    const fixture_list = [_]struct { name: []const u8, bytes: []const u8, pact: []const u8 }{
        .{ .name = "keys-only", .bytes = fixtures.keys_only, .pact = pact },
        .{ .name = "expr-keys", .bytes = fixtures.expr_keys, .pact = pact },
        .{ .name = "full-small", .bytes = fixtures.full_small, .pact = pact },
        .{ .name = "host-join", .bytes = fixtures.host_join, .pact = join_pact },
    };
    for (fixture_list) |fx| {
        NativeRt.reset();
        if (fx.bytes.len > NativeRt.pacbCap()) return error.FixtureInvalid;
        if (fx.pact.len > NativeRt.targetsCap()) return error.FixtureInvalid;
        @memcpy(NativeRt.pacbPtr()[0..fx.bytes.len], fx.bytes);
        @memcpy(NativeRt.targetsPtr()[0..fx.pact.len], fx.pact);
        const status = NativeRt.load(@intCast(fx.bytes.len), @intCast(fx.pact.len));
        if (status != 0) {
            try out.print(
                "negatives: fixture {s}: full untruncated load expected status 0, got {d} reason {d}\n",
                .{ fx.name, status, NativeRt.loadError() },
            );
            return error.NegativeMismatch;
        }
        if (NativeRt.metaLen() == 0 or NativeRt.evalSeconds(FRAME_SECONDS) == 0) {
            try out.print("negatives: fixture {s}: valid load produced no live surface\n", .{fx.name});
            return error.NegativeMismatch;
        }
    }
    try out.print(
        "negatives: full fixtures 4/4 status 0 (keys-only {d} B, expr-keys {d} B, full-small {d} B, host-join {d} B)\n",
        .{ fixtures.keys_only.len, fixtures.expr_keys.len, fixtures.full_small.len, fixtures.host_join.len },
    );

    // 2. Every proper prefix of the actual small fixture.
    {
        try addName(a, &names, "prefixes");
        counters.family_labels += 1; // a family label, never an attempt
        var fam = try Family.begin(a, out, fixtures.keys_only, pact);
        defer fam.end();

        var n: usize = 0;
        while (n < fixtures.keys_only.len) : (n += 1) {
            const want_reason: u32 = if (n < MAGIC_LEN) 0 else 3;
            counters.prefix += 1;
            counters.attempted += 1;
            try fam.expectRefusal("prefix", fixtures.keys_only[0..n], want_reason);
        }
        // The summary prints THIS counter — the loop's own increment —
        // never the fixture-length shorthand.
        if (n != counters.prefix) {
            try out.print(
                "negatives: prefix loop counter {d} != loop increments {d}\n",
                .{ n, counters.prefix },
            );
            return error.CounterMismatch;
        }
        try out.print(
            "negatives: prefixes 0..{d} (actual blob length): {d} proper prefixes, magic-short reason 0, all longer reason 3\n",
            .{ fixtures.keys_only.len, n },
        );
    }

    // 3. Envelope/record/ease mutations on full-small's one-of-every-section
    //    shape. Each starts from the committed base through `runNamed`.
    {
        var fam = try Family.begin(a, out, fixtures.full_small, pact);
        defer fam.end();

        try runNamed(&fam, &names, &counters, "forged-magic", try forgedMagic(a, fixtures.full_small), 0);
        try runNamed(&fam, &names, &counters, "forged-version", try forgedVersion(a, fixtures.full_small), 1);
        try runNamed(&fam, &names, &counters, "forged-features", try forgedFeatures(a, fixtures.full_small), 2);

        try runNamed(&fam, &names, &counters, "directory-overlap", try directoryOverlap(a, fixtures.full_small), 3);
        try runNamed(&fam, &names, &counters, "directory-overrun", try directoryOverrun(a, fixtures.full_small), 3);
        try runNamed(&fam, &names, &counters, "directory-reorder", try directoryReorder(a, fixtures.full_small), 3);
        try runNamed(&fam, &names, &counters, "directory-gap", try directoryGap(a, fixtures.full_small), 3);
        try runNamed(&fam, &names, &counters, "directory-duplicate-id", try directoryDuplicateId(a, fixtures.full_small), 3);
        try runNamed(&fam, &names, &counters, "directory-unknown-id", try directoryUnknownId(a, fixtures.full_small), 3);
        try runNamed(&fam, &names, &counters, "directory-trailing-slack", try directoryTrailingSlack(a, fixtures.full_small), 3);

        try runNamed(&fam, &names, &counters, "trak-count-inflated", try trakCountInflated(a, fixtures.full_small), 3);
        try runNamed(&fam, &names, &counters, "tick-count-cap", try tickCapFixture(a, fixtures.full_small), 6);

        try runNamed(&fam, &names, &counters, "tran-bpm-nan", try tranBpm(a, fixtures.full_small, std.math.nan(f64)), 5);
        try runNamed(&fam, &names, &counters, "tran-bpm-pos-inf", try tranBpm(a, fixtures.full_small, std.math.inf(f64)), 5);
        try runNamed(&fam, &names, &counters, "tran-bpm-neg-inf", try tranBpm(a, fixtures.full_small, -std.math.inf(f64)), 5);

        try runNamed(&fam, &names, &counters, "tmpo-bpm-nan", try tmpoBpm(a, fixtures.full_small, std.math.nan(f64)), 5);
        try runNamed(&fam, &names, &counters, "tmpo-bpm-pos-inf", try tmpoBpm(a, fixtures.full_small, std.math.inf(f64)), 5);
        try runNamed(&fam, &names, &counters, "tmpo-bpm-neg-inf", try tmpoBpm(a, fixtures.full_small, -std.math.inf(f64)), 5);

        try runNamed(&fam, &names, &counters, "keys-value-pad-nan", try keyPadLane(a, fixtures.full_small, std.math.nan(f32)), 5);
        try runNamed(&fam, &names, &counters, "keys-value-pad-pos-inf", try keyPadLane(a, fixtures.full_small, std.math.inf(f32)), 5);
        try runNamed(&fam, &names, &counters, "keys-value-pad-neg-inf", try keyPadLane(a, fixtures.full_small, -std.math.inf(f32)), 5);

        try runNamed(&fam, &names, &counters, "ctrl-min-nan", try controlMinLane(a, fixtures.full_small, std.math.nan(f32)), 5);
        try runNamed(&fam, &names, &counters, "ctrl-min-pos-inf", try controlMinLane(a, fixtures.full_small, std.math.inf(f32)), 5);
        try runNamed(&fam, &names, &counters, "ctrl-min-neg-inf", try controlMinLane(a, fixtures.full_small, -std.math.inf(f32)), 5);

        try runNamed(&fam, &names, &counters, "ease-stage-nan", try easeStageTEnd(a, fixtures.full_small, std.math.nan(f32)), 5);
        try runNamed(&fam, &names, &counters, "ease-stage-pos-inf", try easeStageTEnd(a, fixtures.full_small, std.math.inf(f32)), 5);
        try runNamed(&fam, &names, &counters, "ease-stage-neg-inf", try easeStageTEnd(a, fixtures.full_small, -std.math.inf(f32)), 5);
        try runNamed(&fam, &names, &counters, "ease-op-param-nan", try easeOpParam(a, fixtures.full_small, std.math.nan(f32)), 5);

        try runNamed(&fam, &names, &counters, "ease-ref-range", try easeRefRange(a, fixtures.full_small), 5);
        try runNamed(&fam, &names, &counters, "ease-ref-disagrees", try easeRefDisagrees(a, fixtures.full_small), 5);
        try runNamed(&fam, &names, &counters, "ease-stage-domain", try easeStageDomain(a, fixtures.full_small), 5);
        try runNamed(&fam, &names, &counters, "ease-op-padding", try easeOpPadding(a, fixtures.full_small), 5);

        try runNamed(&fam, &names, &counters, "ease-program-cap", try easeProgramCap(a, fixtures.full_small), 6);
        try runNamed(&fam, &names, &counters, "ease-degenerate-present", try easeDegeneratePresent(a, fixtures.full_small), 4);
        try runNamed(&fam, &names, &counters, "ease-refs-count-mismatch", try easeRefsCountMismatch(a, fixtures.full_small), 4);
    }

    // 4. Status-2 bad calls: a prior status-1 reason must survive.
    {
        var fam = try Family.begin(a, out, fixtures.full_small, pact);
        defer fam.end();

        // Establish a nonzero prior reason through the ACTUAL loader. This
        // is the bad-call family's setup re-eval, not a new attempt: the
        // mutation is already counted once in the envelope family, and the
        // success path prints nothing here.
        try fam.expectRefusal("forged-version", try forgedVersion(a, fixtures.full_small), 1);
        if (NativeRt.loadError() != 1) return error.NegativeMismatch;

        try runBadCall(
            &fam,
            &names,
            &counters,
            "bad-call-pacb-overcap",
            NativeRt.pacbCap() + 1,
            @intCast(pact.len),
        );

        try runBadCall(
            &fam,
            &names,
            &counters,
            "bad-call-targets-overcap",
            @intCast(fixtures.full_small.len),
            NativeRt.targetsCap() + 1,
        );

        // Malformed PACT (bad magic) is validated before the blob, so the
        // live score and the prior reason word survive.
        @memset(NativeRt.targetsPtr()[0..8], 0);
        @memcpy(NativeRt.targetsPtr()[0..4], "XXXX");
        try runBadCall(
            &fam,
            &names,
            &counters,
            "bad-call-pact-malformed",
            @intCast(fixtures.full_small.len),
            8,
        );
        @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    }

    // Internal consistency: the partition must reconstruct `attempted` and
    // the names list exactly, from the execution counters alone.
    if (counters.attempted != counters.named + counters.bad_calls + counters.prefix + counters.positive) {
        try out.print(
            "negatives: counter partition mismatch: attempted {d} != {d} named + {d} bad-call + {d} prefix + {d} positive\n",
            .{ counters.attempted, counters.named, counters.bad_calls, counters.prefix, counters.positive },
        );
        return error.CounterMismatch;
    }
    if (names.items.len != counters.named + counters.bad_calls + counters.positive + counters.family_labels) {
        try out.print(
            "negatives: name partition mismatch: {d} names != {d} mutations + {d} bad-calls + {d} positives + {d} family label(s)\n",
            .{ names.items.len, counters.named, counters.bad_calls, counters.positive, counters.family_labels },
        );
        return error.CounterMismatch;
    }

    try out.print(
        "negatives: partition {d} named + {d} bad-call + {d} prefix + {d} positive = {d} attempted; {d} names = {d} mutation name(s) + {d} bad-call name(s) + {d} positive name(s) + {d} family label(s) (B2b numeric/dry-run remains excluded)\n",
        .{
            counters.named,
            counters.bad_calls,
            counters.prefix,
            counters.positive,
            counters.attempted,
            names.items.len,
            counters.named,
            counters.bad_calls,
            counters.positive,
            counters.family_labels,
        },
    );
    // The superseded T6a-only summary, kept as a DATED baseline: the
    // totals below are the reviewed B1 inventory at d2644eb, printed as
    // history — the live partition above is the one that must be true.
    try out.print(
        "negatives: T6a baseline at d2644eb (2026-10-22): 35 named + 3 bad-call + 3700 prefix = 3738 attempted; 39 names = 35 mutation name(s) + 3 bad-call name(s) + 1 family label(s)\n",
        .{},
    );
    try out.print(
        "negatives: exact status/reason and transactional preservation PASS; B2b numeric/dry-run and T6/P3 remain open\n",
        .{},
    );
}
