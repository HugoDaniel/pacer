//! Production `prt_load` negative suite — binary03 T6a, extended by B2a
//! (compact payloads, `'PACM'` structural/coherence, registry identity)
//! and B2b's pattern dry-run budget family.
//!
//! This is the bounded T6 negative-suite MECHANISM plus the container-
//! envelope and record-domain refusals (T6a), the compact-payload family,
//! the B2a metadata/registry families, and the B2b load-time pattern
//! dry-run budget family (status 1 reason 11, transactional). The B2b
//! numeric/finite matrix is the parity test root's separate
//! `numeric_domain_tests.zig` module — it characterizes KEYS/CTRL/pad/
//! cross-check and evaluation-write cells through the same exports.
//! T6b is complete: P3 was accepted and Group B exited on 2026-10-22;
//! C/D/E remain unclaimed.
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
const sjon = @import("sjon");
const NativeRt = @import("NativeRt.zig");

const Pb = pacer.Pacb;
const Pacm = pacer.Pacm;
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
    /// B2b dry-run splice base: a REAL CLI pack with one pattern track
    /// carrying `(silence)` and a single payload record, so the budget
    /// family can splice a hand-encoded body over it (test (p)'s class).
    pattern_silence: []const u8,
    /// B2b dry-run LIVE baseline: a pattern track plus the singular expr
    /// that trips a nonzero failure counter at beat 1, against the empty
    /// host join. Never spliced; the refusal must preserve this score.
    pattern_live: []const u8,
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
// Frozen 'TRAK' field positions (40-byte record) used by the payload
// families: the per-track compact-IR span address.
const TRAK_REC_SOURCE_OFF: usize = 4;
const TRAK_REC_PAYLOAD_OFF_OFF: usize = 16;
const TRAK_REC_PAYLOAD_LEN_OFF: usize = 20;
/// Frozen track-source ordinal (docs/binary-score.md; test-asserted
/// against the source enum in src/root.zig).
const SOURCE_EXPR: u8 = 1;
const SOURCE_PATTERN: u8 = 3;
/// Frozen compact-IR header field: the roots block's offset (u32) —
/// the wire layout is `[magic "SJ1\n"][wire_version][flags][reserved]
/// [pool_offset u32][roots_offset u32]` (SJON Binary.zig).
const BINARY_ROOTS_OFFSET_OFF: usize = 12;
/// Frozen 'TRAN' field: the embedded-'PACM' FNV-1a-64 fast-reject
/// checksum (`Pacb.decode` reads it at `tran.off + 48`; the record is
/// 56 bytes, `Pacb.TRAN_REC_LEN`).
const TRAN_PACM_FNV_OFF: usize = 48;
// Frozen 'PACM' header field positions (40-byte header; src/Pacm.zig).
const PACM_VERSION_OFF: usize = 4;
const PACM_BPM_OFF: usize = 8;
const PACM_TRACK_COUNT_OFF: usize = 28;
const PACM_KEY_COUNT_OFF: usize = 32;
const PACM_CONTROL_COUNT_OFF: usize = 36;
// Frozen 'PACM' record fields.
const PACM_TRACK_TARGET_OFF: usize = 0;
const PACM_TRACK_REGISTRY_OFF: usize = 2;
const PACM_TRACK_SOURCE_OFF: usize = 4;
const PACM_KEY_VALUE_OFF: usize = 8;
const PACM_CONTROL_REGISTRY_OFF: usize = 2;
const PACM_CONTROL_VALUE_OFF: usize = 8;
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
    meta_ptr: [*]const u8,
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
                .meta_ptr = NativeRt.metaPtr(),
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
        if (NativeRt.metaPtr() != self.snap.meta_ptr) {
            try self.out.print("negatives: {s}: meta pointer moved across a refusal\n", .{name});
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
        // Restore BOTH input zones: the mutation owned the PACB zone, and
        // the targets zone must still hold this family's canonical PACT.
        @memcpy(NativeRt.pacbPtr()[0..self.base.len], self.base);
        @memcpy(NativeRt.targetsPtr()[0..self.pact.len], self.pact);
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

    /// Require a status-0 acceptance of a mutated copy (B2a positive
    /// category): a named v1 tolerance or an honest-rewrite control.
    /// The acceptance SWAPS the live score, so held dynamic state is
    /// reset by the documented swap semantics — the pins here are score
    /// identity (the complete 'PACM' must be byte-unchanged: a positive
    /// mutation may never touch metadata) and a still-nonempty frame.
    /// Positive cases run LAST in their family; nothing after them may
    /// assume the pre-swap held state.
    fn expectAccepted(
        self: *Family,
        name: []const u8,
        bytes: []const u8,
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
        if (status != 0) {
            try self.out.print(
                "negatives: {s}: expected status 0 (accepted), got status {d} reason {d} ({d} bytes)\n",
                .{ name, status, NativeRt.loadError(), bytes.len },
            );
            return error.NegativeMismatch;
        }
        if (NativeRt.metaLen() != self.snap.meta.len or
            !std.mem.eql(u8, self.snap.meta, NativeRt.metaPtr()[0..NativeRt.metaLen()]))
        {
            try self.out.print("negatives: {s}: accepted mutation changed the 'PACM' surface\n", .{name});
            return error.StateMismatch;
        }
        if (NativeRt.evalSeconds(FRAME_SECONDS) == 0) {
            try self.out.print("negatives: {s}: accepted score produced no frame\n", .{name});
            return error.StateMismatch;
        }

        // Restore the clean fixture bytes for whatever follows.
        @memcpy(NativeRt.pacbPtr()[0..self.base.len], self.base);
    }

    /// Require a status-0 acceptance whose metadata is a KNOWN rewrite of
    /// the committed `'PACM'`: the loader must serve exactly the mutated
    /// blob's embedded payload (proving the honest FNV rewrite reached
    /// the served surface, not a stale or re-encoded copy). The acceptance
    /// swaps the live score, so this runs LAST in its family.
    fn expectAcceptedPacm(
        self: *Family,
        name: []const u8,
        bytes: []const u8,
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
        if (status != 0) {
            try self.out.print(
                "negatives: {s}: expected status 0 (accepted), got status {d} reason {d} ({d} bytes)\n",
                .{ name, status, NativeRt.loadError(), bytes.len },
            );
            return error.NegativeMismatch;
        }
        const expected = sectionPayload(bytes, .pacm);
        if (NativeRt.metaLen() != expected.len or
            !std.mem.eql(u8, expected, NativeRt.metaPtr()[0..NativeRt.metaLen()]))
        {
            try self.out.print(
                "negatives: {s}: served 'PACM' is not the honest-rewritten payload ({d} vs {d} bytes)\n",
                .{ name, NativeRt.metaLen(), expected.len },
            );
            return error.StateMismatch;
        }
        if (NativeRt.evalSeconds(FRAME_SECONDS) == 0) {
            try self.out.print("negatives: {s}: accepted score produced no frame\n", .{name});
            return error.StateMismatch;
        }

        @memcpy(NativeRt.pacbPtr()[0..self.base.len], self.base);
    }

    /// Require a status-0 acceptance that also PLAYS: the boundary
    /// control for the dry-run budget family must load and produce a
    /// frame whose target write carries the pattern's authored value.
    /// The acceptance swaps the live score; this runs LAST in its family.
    fn expectAcceptedPlays(
        self: *Family,
        name: []const u8,
        bytes: []const u8,
        want_target: u16,
        want_value: f32,
    ) !void {
        if (bytes.len > NativeRt.pacbCap()) {
            try self.out.print("negatives: {s}: mutation exceeds the production PACB cap\n", .{name});
            return error.NegativeMismatch;
        }

        @memcpy(NativeRt.pacbPtr()[0..bytes.len], bytes);
        const status = NativeRt.load(@intCast(bytes.len), @intCast(self.pact.len));
        if (status != 0) {
            try self.out.print(
                "negatives: {s}: expected status 0 (accepted), got status {d} reason {d}\n",
                .{ name, status, NativeRt.loadError() },
            );
            return error.NegativeMismatch;
        }
        if (NativeRt.metaLen() != self.snap.meta.len or
            !std.mem.eql(u8, self.snap.meta, NativeRt.metaPtr()[0..NativeRt.metaLen()]))
        {
            try self.out.print("negatives: {s}: accepted mutation changed the 'PACM' surface\n", .{name});
            return error.StateMismatch;
        }
        const len = NativeRt.evalTicks(0);
        if (len == 0) {
            try self.out.print("negatives: {s}: accepted score produced no frame\n", .{name});
            return error.StateMismatch;
        }
        const mem = try self.a.alignedAlloc(u8, .of(pacer.Writes.Entry), len);
        @memcpy(mem, NativeRt.writesPtr()[0..len]);
        const entries = pacer.Writes.decode(mem) orelse {
            try self.out.print("negatives: {s}: accepted frame did not decode\n", .{name});
            return error.StateMismatch;
        };
        var found = false;
        for (entries) |entry| {
            if (entry.target_id != want_target) continue;
            found = true;
            if (@as(u32, @bitCast(entry.value[0])) != @as(u32, @bitCast(want_value))) {
                try self.out.print(
                    "negatives: {s}: frame target {d} wrote 0x{x:0>8}, expected 0x{x:0>8}\n",
                    .{ name, want_target, @as(u32, @bitCast(entry.value[0])), @as(u32, @bitCast(want_value)) },
                );
                return error.StateMismatch;
            }
            break;
        }
        if (!found) {
            try self.out.print("negatives: {s}: frame carried no write for target {d}\n", .{ name, want_target });
            return error.StateMismatch;
        }

        @memcpy(NativeRt.pacbPtr()[0..self.base.len], self.base);
    }

    /// Establish a NONZERO expression-failure counter on the live score
    /// without changing the documented semantics (one eval at beat 1 of
    /// the singular flow expr carried by `host-join` and `pattern-live`),
    /// then make it the snapshot value every later refusal must preserve.
    /// The frame snapshots are untouched: later probes are deterministic
    /// re-evaluations.
    fn primeExprFailure(self: *Family) !void {
        // Re-assert the family's bpm nudge, then probe ONE BEAT at that
        // tempo (60/90 s): host-join's flow expr `(/ 1 (- beat 1))` hits
        // its division by zero exactly there, so the counter is nonzero
        // without changing any documented semantics.
        if (NativeRt.setBpm(90) != 0) return error.StateSetupFailed;
        _ = NativeRt.evalSeconds(60.0 / 90.0);
        if (NativeRt.exprFailures() == 0) {
            try self.out.print("negatives: registry counter probe did not trip an expr failure\n", .{});
            return error.StateSetupFailed;
        }
        self.snap.counter = NativeRt.exprFailures();
    }

    /// Overwrite BOTH input zones (a host join mismatch is a targets-zone
    /// edit, not a PACB edit), require status 1 + reason 9, prove the old
    /// live score is intact, then restore BOTH zones from the committed
    /// bytes. `bytes` and `pact_bytes` are caller-owned copies, never
    /// borrowed views of the live zones.
    fn expectRegistryRefusal(
        self: *Family,
        name: []const u8,
        bytes: []const u8,
        pact_bytes: []const u8,
    ) !void {
        if (bytes.len > NativeRt.pacbCap() or pact_bytes.len > NativeRt.targetsCap()) {
            try self.out.print("negatives: {s}: mutation exceeds the production zone cap\n", .{name});
            return error.NegativeMismatch;
        }

        @memcpy(NativeRt.pacbPtr()[0..bytes.len], bytes);
        @memcpy(NativeRt.targetsPtr()[0..pact_bytes.len], pact_bytes);
        const status = NativeRt.load(@intCast(bytes.len), @intCast(pact_bytes.len));
        const got_reason = NativeRt.loadError();
        if (status != 1 or got_reason != 9) {
            try self.out.print(
                "negatives: {s}: expected status 1 reason 9, got status {d} reason {d} ({d} bytes, {d} targets)\n",
                .{ name, status, got_reason, bytes.len, pact_bytes.len },
            );
            return error.NegativeMismatch;
        }

        try self.assertState(name);
        // Restore BOTH zones: the refusal path never edits them itself.
        @memcpy(NativeRt.pacbPtr()[0..self.base.len], self.base);
        @memcpy(NativeRt.targetsPtr()[0..self.pact.len], self.pact);
    }
};

/// Summary partition counters, one increment per operation AT the place the
/// operation actually executes. Every summary term must be one of these —
/// never derived from a fixture length or from the names list (B1).
const Counters = struct {
    /// Every expected-under-test production call: named mutations, bad
    /// calls, prefix attempts. The setup/probe loads stay uncounted, and
    /// the enumeration is exact: six step-1 fixture loads, nine
    /// `Family.begin` baseline loads (prefix, envelope, compact, PACM
    /// structural, coherence, registry, dry-run refusal, dry-run
    /// boundary, bad-call), and the bad-call family's prior-reason
    /// re-eval — sixteen uncounted loads in all, none of them attempts.
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

/// Count and require one status-0 characterization (B2a positive
/// category). The printed line carries the tolerance/control's meaning
/// so the literal inventory can pin it verbatim.
fn runPositive(
    fam: *Family,
    names: *std.ArrayList([]const u8),
    counters: *Counters,
    name: []const u8,
    bytes: []const u8,
    detail: []const u8,
) !void {
    try addName(fam.a, names, name);
    counters.positive += 1;
    counters.attempted += 1;
    try fam.expectAccepted(name, bytes);
    try fam.out.print("negatives: {s}: status 0 (accepted; {s})\n", .{ name, detail });
}

/// Count and require one status-0 acceptance that also plays the authored
/// pattern value (B2b's within-budget boundary control).
fn runPositivePlays(
    fam: *Family,
    names: *std.ArrayList([]const u8),
    counters: *Counters,
    name: []const u8,
    bytes: []const u8,
    detail: []const u8,
    want_target: u16,
    want_value: f32,
) !void {
    try addName(fam.a, names, name);
    counters.positive += 1;
    counters.attempted += 1;
    try fam.expectAcceptedPlays(name, bytes, want_target, want_value);
    try fam.out.print("negatives: {s}: status 0 (accepted; {s})\n", .{ name, detail });
}

/// Count and require one status-0 acceptance whose served `'PACM'` is the
/// honest-rewritten payload (checksum repair discipline: the fast reject
/// must pass, the structural reader must accept it, and coherence must
/// still hold).
fn runPositivePacm(
    fam: *Family,
    names: *std.ArrayList([]const u8),
    counters: *Counters,
    name: []const u8,
    bytes: []const u8,
    detail: []const u8,
) !void {
    try addName(fam.a, names, name);
    counters.positive += 1;
    counters.attempted += 1;
    try fam.expectAcceptedPacm(name, bytes);
    try fam.out.print("negatives: {s}: status 0 (accepted; {s})\n", .{ name, detail });
}

/// Count and require one status-1 `'PACM'`-family refusal, and assert the
/// INDEPENDENT reader oracle on the mutated blob's embedded payload: the
/// same status/reason (10) covers checksum, structural, and coherence
/// classes, so the line records which gate the independent `Pacm.decode`
/// sees. `want_reader_null` pins structural garbage (null) vs an honest
/// PACM whose loader refusal is checksum/coherence (non-null).
fn runPacmNamed(
    fam: *Family,
    names: *std.ArrayList([]const u8),
    counters: *Counters,
    name: []const u8,
    bytes: []const u8,
    reason: u32,
    want_reader_null: bool,
) !void {
    try addName(fam.a, names, name);
    const reader_null = Pacm.decode(sectionPayload(bytes, .pacm)) == null;
    if (reader_null != want_reader_null) {
        try fam.out.print(
            "negatives: {s}: reader oracle expected {s}, got {s}\n",
            .{ name, if (want_reader_null) "null" else "nonnull", if (reader_null) "null" else "nonnull" },
        );
        return error.NegativeMismatch;
    }
    counters.named += 1;
    counters.attempted += 1;
    try fam.expectRefusal(name, bytes, reason);
    try fam.out.print(
        "negatives: {s}: status 1 reason {d}; reader {s}\n",
        .{ name, reason, if (reader_null) "null" else "nonnull" },
    );
}

/// Count and require one registry-identity refusal (status 1 reason 9)
/// under a canonical-but-mismatched host join, restoring BOTH input zones.
fn runRegistryNamed(
    fam: *Family,
    names: *std.ArrayList([]const u8),
    counters: *Counters,
    name: []const u8,
    bytes: []const u8,
    pact_bytes: []const u8,
) !void {
    try addName(fam.a, names, name);
    counters.named += 1;
    counters.attempted += 1;
    try fam.expectRegistryRefusal(name, bytes, pact_bytes);
    try fam.out.print(
        "negatives: {s}: status 1 reason 9; live score preserved (expr counter {d}, frames, held control, bpm, meta)\n",
        .{ name, fam.snap.counter },
    );
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
    // Preserve the producer's required-features word: B2b's pattern base
    // carries bit0, and a rebuild must not silently clear a section kind
    // the loader gates on.
    return rebuild(a, specs, readU32(base, HEADER_FEATURES_OFF));
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

fn putU64(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
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

fn readF32(bytes: []const u8, at: usize) f32 {
    return @bitCast(readU32(bytes, at));
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
// Compact payloads (B2a) — structural edits over a GENUINE packed
// payload's copy. The packer is never weakened and no second decoder
// exists: every mutator either patches bytes in place (size-preserving
// header/node lies) or reassembles the canonical container so the
// directory arithmetic can never mask the claimed stage.
// ---------------------------------------------------------------------------

/// The 'TRAK' record of the fixture's (single) expr track: the span
/// address of its genuine compact-IR payload inside the 'PAYL' region.
const PayloadSpan = struct { rec: usize, off: u32, len: u32 };

fn trakPayloadSpanBySource(base: []const u8, source: u8) !PayloadSpan {
    const section = findSection(base, .trak);
    const n = readU32(base, section.off);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = section.off + 4 + i * Pb.TRAK_REC_LEN;
        if (base[rec + TRAK_REC_SOURCE_OFF] == source) {
            return .{
                .rec = rec,
                .off = readU32(base, rec + TRAK_REC_PAYLOAD_OFF_OFF),
                .len = readU32(base, rec + TRAK_REC_PAYLOAD_LEN_OFF),
            };
        }
    }
    return error.FixtureMissingSection;
}

fn trakPayloadSpan(base: []const u8) !PayloadSpan {
    return trakPayloadSpanBySource(base, SOURCE_EXPR);
}

/// Canonical container reassembly with several sections replaced at
/// once (the `replaceSection` generalization the resized-payload
/// mutations need: 'PAYL' growth moves 'PACM', a span growth moves
/// both).
fn reassemble(a: Allocator, base: []const u8, patches: []const SectionSpec) ![]u8 {
    const specs = try collectSections(a, base);
    for (specs) |*spec| {
        for (patches) |patch| {
            if (spec.kind == patch.kind) spec.payload = patch.payload;
        }
    }
    // A canonical rebuild keeps the producer's required-features word
    // (B2b's pattern base carries bit0; existing T6a/B2a fixtures carry 0).
    return rebuild(a, specs, readU32(base, HEADER_FEATURES_OFF));
}

fn removeSection(a: Allocator, base: []const u8, kind: Pb.SectionKind) ![]u8 {
    const specs = try collectSections(a, base);
    var kept: std.ArrayList(SectionSpec) = .empty;
    var removed = false;
    for (specs) |spec| {
        if (spec.kind == kind) {
            removed = true;
        } else {
            try kept.append(a, spec);
        }
    }
    if (!removed) return error.FixtureMissingSection;
    return rebuild(a, kept.items, 0);
}

/// Hand-encode one pattern body as compact SJON binary (parse-only — no
/// compile dry-run, the test (p) producer class). The suite never uses a
/// decoder: this is the producer side only.
fn patternBody(a: Allocator, text: [:0]const u8) ![]u8 {
    var tree = try sjon.parse(a, text);
    defer tree.deinit();
    const body = try sjon.Binary.toBinary(a, tree, sjon.Binary.ToBinaryOptions.forMode(.compact));
    defer body.deinit();
    return a.dupe(u8, body.data);
}

/// Replace the single pattern payload in a REAL CLI pack (`pattern-silence`)
/// with a hand-encoded body, repairing `'PAYL'`'s byte_size, the one
/// pattern `'TRAK'` span, and the canonical directory. This is test (p)'s
/// `splicePayloadRecord` class, reduced to the one-payload base the B2b
/// fixture carries; no production packer is weakened.
fn splicePatternBody(a: Allocator, base: []const u8, new_body: []const u8) ![]u8 {
    const payl = findSection(base, .payl);
    const span = try trakPayloadSpanBySource(base, SOURCE_PATTERN);
    if (span.off != 0 or span.len != readU32(base, payl.off)) {
        return error.FixtureInvalid;
    }

    const trak = findSection(base, .trak);
    const trak_out = try a.dupe(u8, sectionPayload(base, .trak));
    putU32(
        trak_out,
        span.rec - @as(usize, trak.off) + TRAK_REC_PAYLOAD_LEN_OFF,
        @intCast(new_body.len),
    );

    const payl_out = try a.alloc(u8, 4 + new_body.len);
    putU32(payl_out, 0, @intCast(new_body.len));
    @memcpy(payl_out[4..], new_body);

    return reassemble(a, base, &.{
        .{ .kind = .payl, .payload = payl_out },
        .{ .kind = .trak, .payload = trak_out },
    });
}

/// The payload's own header lie: the roots block's varint count. A
/// payload is ONE subtree — zero roots and multiple roots are the same
/// defect class (the walk's `remaining != 1` rule). Size-preserving.
fn payloadRoots(a: Allocator, base: []const u8, count: u8) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .payl);
    const span = try trakPayloadSpan(base);
    const payload_at = section.off + 4 + span.off;
    const roots_off = readU32(out, payload_at + BINARY_ROOTS_OFFSET_OFF);
    putU8(out, payload_at + roots_off, count);
    return out;
}

/// A node-tag byte inside the roots block flipped to an ordinal no
/// variant owns: the root iterator or the width-exact walk refuses.
/// Size-preserving.
fn payloadCorruptNode(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const section = findSection(base, .payl);
    const span = try trakPayloadSpan(base);
    const payload_at = section.off + 4 + span.off;
    const roots_off = readU32(out, payload_at + BINARY_ROOTS_OFFSET_OFF);
    putU8(out, payload_at + roots_off + 1, 0xFF);
    return out;
}

/// The probe-G shape: the span itself grows +4 junk bytes AFTER the
/// drained comment tail. The walk must drain the legal tail, then hit
/// the exact-end rule on the residual — never a directory lie, so
/// byte_size, the span fields and the directory are all repaired here.
fn payloadInSpanSlack(a: Allocator, base: []const u8) ![]u8 {
    const section = findSection(base, .payl);
    const span = try trakPayloadSpan(base);
    const byte_size = readU32(base, section.off);
    const old_region = base[section.off + 4 ..][0..byte_size];

    const new_size = byte_size + 4;
    const payl = try a.alloc(u8, 4 + new_size);
    putU32(payl, 0, @intCast(new_size));
    @memcpy(payl[4..][0..old_region.len], old_region);
    @memset(payl[4 + old_region.len ..], 0xAA);

    const trak = findSection(base, .trak);
    const trak_out = try a.dupe(u8, sectionPayload(base, .trak));
    putU32(
        trak_out,
        span.rec - trak.off + TRAK_REC_PAYLOAD_LEN_OFF,
        span.len + 4,
    );

    return reassemble(a, base, &.{
        .{ .kind = .payl, .payload = payl },
        .{ .kind = .trak, .payload = trak_out },
    });
}

/// The probe-F tolerance: +4 junk bytes beyond the last span, byte_size
/// grown to match, spans untouched. decodePayloads checks per-span
/// cap/bounds/overlap but never region coverage — the loader must
/// ACCEPT this (a named v1 tolerance, senior probe F, measured
/// status 0), and the positive category records it as such.
fn payloadRegionSlack(a: Allocator, base: []const u8) ![]u8 {
    const section = findSection(base, .payl);
    const byte_size = readU32(base, section.off);
    const old_region = base[section.off + 4 ..][0..byte_size];

    const new_size = byte_size + 4;
    const payl = try a.alloc(u8, 4 + new_size);
    putU32(payl, 0, @intCast(new_size));
    @memcpy(payl[4..][0..old_region.len], old_region);
    @memset(payl[4 + old_region.len ..], 0x55);

    return reassemble(a, base, &.{.{ .kind = .payl, .payload = payl }});
}

/// The degenerate region: byte_size 0. The reader treats a zero region
/// as the OMITTED section (non_canonical, reason 4) — the presence
/// discipline, not a payload-walk defect.
fn payloadRegionDegenerate(a: Allocator, base: []const u8) ![]u8 {
    const payload = try a.alloc(u8, 4);
    @memset(payload, 0);
    return replaceSection(a, base, .payl, payload);
}

/// 'PAYL' absent while an expr track remains: the cross-section
/// presence pair is CHECKED both directions (non_canonical, reason 4).
fn payloadSectionAbsent(a: Allocator, base: []const u8) ![]u8 {
    return removeSection(a, base, .payl);
}

/// The reverse presence lie: the expr track's complete 'TRAK' record is
/// removed (count repaired, directory rebuilt) while 'PAYL' stays —
/// PAYL-present with no payload track refuses (non_canonical, reason 4)
/// at the payload stage, before the PACM close can speak.
fn payloadPresenceWithoutTrack(a: Allocator, base: []const u8) ![]u8 {
    const trak = findSection(base, .trak);
    const span = try trakPayloadSpan(base);
    const n = readU32(base, trak.off);

    const out = try a.alloc(u8, trak.len - Pb.TRAK_REC_LEN);
    putU32(out, 0, n - 1);
    var src: usize = 4;
    var dst: usize = 4;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec_at = trak.off + src;
        if (rec_at != span.rec) {
            @memcpy(out[dst..][0..Pb.TRAK_REC_LEN], base[rec_at..][0..Pb.TRAK_REC_LEN]);
            dst += Pb.TRAK_REC_LEN;
        }
        src += Pb.TRAK_REC_LEN;
    }

    return reassemble(a, base, &.{.{ .kind = .trak, .payload = out }});
}

/// The per-payload cap: the span's own length field past
/// `MAX_PAYLOAD_BYTES`. The cap gate fires at the span scan — before
/// bounds and before any walk — so the region stays untouched; the
/// reason is cap_exceeded (6), never a directory or walk refusal.
fn payloadSpanCap(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const span = try trakPayloadSpan(base);
    putU32(out, span.rec + TRAK_REC_PAYLOAD_LEN_OFF, @intCast(Pb.MAX_PAYLOAD_BYTES + 1));
    return out;
}

/// The 'PAYL' region cap: a REAL byte_size past `MAX_PAYL_BYTES` (the
/// size arithmetic is checked first, so the region must actually carry
/// the bytes), refusing at the cap gate (6) before any span is read.
fn payloadTotalCap(a: Allocator, base: []const u8) ![]u8 {
    const new_size: usize = Pb.MAX_PAYL_BYTES + 1;

    const payl = try a.alloc(u8, 4 + new_size);
    putU32(payl, 0, @intCast(new_size));
    @memset(payl[4..], 0);

    return reassemble(a, base, &.{.{ .kind = .payl, .payload = payl }});
}

/// The harness-validity positive: canonical reassembly of the
/// committed blob must be byte-IDENTICAL (the real CLI's output is
/// canonical), so every reassembled mutation above differs from the
/// base by exactly its claimed edit — nothing else.
fn reassemblyIdentity(a: Allocator, base: []const u8) ![]u8 {
    const specs = try collectSections(a, base);
    const rebuilt = try rebuild(a, specs, 0);
    if (!std.mem.eql(u8, rebuilt, base)) return error.FixtureInvalid;
    return rebuilt;
}

// ---------------------------------------------------------------------------
// 'PACM' structural family (B2a) — every edit is made to the GENUINE
// embedded metadata payload and then closed with the honest
// `'TRAN'+48` FNV-1a-64 over that payload, so the checksum fast-reject
// cannot mask the structural gate. The independent `Pacm.decode`
// reader oracle is asserted separately for each case (the loader's
// reason 10 is one word for three distinct stages).
// ---------------------------------------------------------------------------

const PacmTlv = struct { hdr: usize, payload: usize, len: usize, id: u32 };

/// Byte offset just past the `'PACM'` control stream (the first TLV
/// frame, or end-of-buffer when there is no section stream). Mirrors
/// `Pacm.decode`'s own walk of the header's counts and inline id
/// lengths; never a second decoder, just stream arithmetic.
fn pacmControlsEnd(p: []const u8) usize {
    const tc = readU32(p, PACM_TRACK_COUNT_OFF);
    const kc = readU32(p, PACM_KEY_COUNT_OFF);
    const cc = readU32(p, PACM_CONTROL_COUNT_OFF);
    var pos: usize = Pacm.META_HEADER_LEN +
        @as(usize, tc) * Pacm.META_TRACK_LEN +
        @as(usize, kc) * Pacm.META_KEY_LEN;
    var i: usize = 0;
    while (i < cc) : (i += 1) {
        const id_len = std.mem.readInt(u16, p[pos + 6 ..][0..2], .little);
        pos += Pacm.META_CONTROL_LEN + id_len;
    }
    return pos;
}

/// One TLV frame by section id: header offset, payload offset, length.
fn pacmFindTlv(p: []const u8, want: u32) ?PacmTlv {
    var pos = pacmControlsEnd(p);
    while (pos + Pacm.META_SECTION_HEADER_LEN <= p.len) {
        const id = readU32(p, pos);
        const len = readU32(p, pos + 4);
        const payload = pos + Pacm.META_SECTION_HEADER_LEN;
        if (payload + @as(usize, len) > p.len) return null;
        if (id == want) return .{ .hdr = pos, .payload = payload, .len = @intCast(len), .id = id };
        pos = payload + @as(usize, len);
    }
    return null;
}

fn pacmCopy(a: Allocator, base: []const u8) ![]u8 {
    return a.dupe(u8, sectionPayload(base, .pacm));
}

/// Recompute the `'TRAN'` fast-reject checksum over the (possibly
/// replaced) `'PACM'` section payload. The edit itself is never a
/// checksum shortcut: an honest rewrite must reach the structural and
/// coherence gates with a valid FNV.
fn recomputePacmFnv(bytes: []u8) void {
    const tran = findSection(bytes, .tran);
    var h = std.hash.Fnv1a_64.init();
    h.update(sectionPayload(bytes, .pacm));
    putU64(bytes, tran.off + TRAN_PACM_FNV_OFF, h.final());
}

/// Replace the `'PACM'` payload in the canonical container. A same-size
/// edit patches in place (directory untouched); a resize reassembles so
/// the directory arithmetic cannot mask the claimed gate. Either way the
/// honest checksum is recomputed.
fn pacmAssemble(a: Allocator, base: []const u8, payload: []const u8) ![]u8 {
    const old = sectionPayload(base, .pacm);
    const out = if (payload.len == old.len) blk: {
        const d = try duplicate(base, a);
        const sec = findSection(base, .pacm);
        @memcpy(d[sec.off..][0..payload.len], payload);
        break :blk d;
    } else try reassemble(a, base, &.{.{ .kind = .pacm, .payload = payload }});
    recomputePacmFnv(out);
    return out;
}

/// A pure checksum lie over an HONEST PACM: flip one FNV bit and touch
/// nothing else. The reader oracle stays non-null, proving reason 10
/// here is the fast-reject, not structure or coherence.
fn pacmChecksumLie(a: Allocator, base: []const u8) ![]u8 {
    const out = try duplicate(base, a);
    const tran = findSection(base, .tran);
    out[tran.off + TRAN_PACM_FNV_OFF] ^= 1;
    return out;
}

/// The reader's version domain: a version byte it does not understand
/// (structural null), with the honest checksum.
fn pacmVersionInvalid(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    putU32(p, PACM_VERSION_OFF, Pacm.META_VERSION + 1);
    return pacmAssemble(a, base, p);
}

/// The reader's enum domain: a track `source` byte outside the frozen
/// ordinal family (keys/expr/trigger/pattern).
fn pacmEnumInvalid(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    putU8(p, Pacm.META_HEADER_LEN + PACM_TRACK_SOURCE_OFF, 0xFF);
    return pacmAssemble(a, base, p);
}

/// The reader's transport domain: bpm 0 is outside finite 1..1000.
fn pacmBpmZero(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    putF64(p, PACM_BPM_OFF, 0.0);
    return pacmAssemble(a, base, p);
}

/// A count lie past the reader's divide-first bound: a hostile
/// track_count cannot wrap, so the length arithmetic refuses it.
fn pacmTrackCountInflated(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    putU32(p, PACM_TRACK_COUNT_OFF, std.math.maxInt(u32));
    return pacmAssemble(a, base, p);
}

/// Truncation inside the section stream: the final TLV frame header no
/// longer has its payload (the reader walks to exact end-of-buffer).
fn pacmTruncated(a: Allocator, base: []const u8) ![]u8 {
    const old = sectionPayload(base, .pacm);
    if (old.len < 8) return error.FixtureInvalid;
    const p = try a.dupe(u8, old[0 .. old.len - 8]);
    return pacmAssemble(a, base, p);
}

/// Trailing slack after the last TLV frame: a partial frame header is a
/// defect (the reader's stream must end EXACTLY at the buffer end).
fn pacmTlvTrailingSlack(a: Allocator, base: []const u8) ![]u8 {
    const old = sectionPayload(base, .pacm);
    const p = try a.alloc(u8, old.len + 4);
    @memcpy(p[0..old.len], old);
    @memset(p[old.len..], 0xAA);
    return pacmAssemble(a, base, p);
}

/// Section accounting: 'SCEN' claims one more record than its payload
/// carries (`4 + n×24 != payload_len`).
fn pacmSectionAccounting(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const tlv = pacmFindTlv(p, Pacm.SCENES_SECTION_ID) orelse
        return error.FixtureMissingSection;
    putU32(p, tlv.payload, readU32(p, tlv.payload) + 1);
    return pacmAssemble(a, base, p);
}

/// A repeated section id: the fixed encoder emits each id at most once,
/// and the reader refuses a repeat whose payload is otherwise valid.
fn pacmDuplicateTlv(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const tlv = pacmFindTlv(p, Pacm.SCENES_SECTION_ID) orelse
        return error.FixtureMissingSection;
    const out = try a.alloc(u8, p.len + Pacm.META_SECTION_HEADER_LEN + tlv.len);
    @memcpy(out[0..p.len], p);
    putU32(out, p.len, tlv.id);
    putU32(out, p.len + 4, @intCast(tlv.len));
    @memcpy(out[p.len + Pacm.META_SECTION_HEADER_LEN ..][0..tlv.len], p[tlv.payload..][0..tlv.len]);
    return pacmAssemble(a, base, out);
}

/// A well-formed 'SNAM' payload parallel to `count` scenes: `count`
/// entries of the given names. Bounds are the reader's only rule.
fn snamPayload(a: Allocator, names: []const []const u8) ![]u8 {
    var total: usize = 4;
    for (names) |n| total += 4 + n.len;
    const p = try a.alloc(u8, total);
    putU32(p, 0, @intCast(names.len));
    var pos: usize = 4;
    for (names) |n| {
        putU32(p, pos, @intCast(n.len));
        @memcpy(p[pos + 4 ..][0..n.len], n);
        pos += 4 + n.len;
    }
    return p;
}

fn insertTlv(a: Allocator, p: []const u8, at: usize, id: u32, payload: []const u8) ![]u8 {
    const out = try a.alloc(u8, p.len + Pacm.META_SECTION_HEADER_LEN + payload.len);
    @memcpy(out[0..at], p[0..at]);
    putU32(out, at, id);
    putU32(out, at + 4, @intCast(payload.len));
    @memcpy(out[at + Pacm.META_SECTION_HEADER_LEN ..][0..payload.len], payload);
    @memcpy(
        out[at + Pacm.META_SECTION_HEADER_LEN + payload.len ..][0 .. p.len - at],
        p[at..],
    );
    return out;
}

fn appendTlv(a: Allocator, p: []const u8, id: u32, payload: []const u8) ![]u8 {
    return insertTlv(a, p, p.len, id, payload);
}

/// Replace one TLV frame in place: same id, same position; the payload
/// length may change. A stream that does not carry the id yet grows one
/// canonical tail frame (the fixed encoder emits `'SNAM'` last), so the
/// same case addresses the frozen pre-`'SNAM'` fixture and a names-carrying
/// one alike.
fn replaceTlv(a: Allocator, p: []const u8, id: u32, payload: []const u8) ![]u8 {
    const tlv = pacmFindTlv(p, id) orelse
        return insertTlv(a, p, p.len, id, payload);
    const frame_len = Pacm.META_SECTION_HEADER_LEN + tlv.len;
    const out = try a.alloc(u8, p.len - frame_len + Pacm.META_SECTION_HEADER_LEN + payload.len);
    @memcpy(out[0..tlv.hdr], p[0..tlv.hdr]);
    putU32(out, tlv.hdr, id);
    putU32(out, tlv.hdr + 4, @intCast(payload.len));
    @memcpy(out[tlv.hdr + Pacm.META_SECTION_HEADER_LEN ..][0..payload.len], payload);
    @memcpy(
        out[tlv.hdr + Pacm.META_SECTION_HEADER_LEN + payload.len ..][0 .. p.len - (tlv.hdr + frame_len)],
        p[tlv.hdr + frame_len ..],
    );
    return out;
}

/// 'SNAM' before the 'SCEN' it parallelizes: the reader requires the
/// fixed encoder order, so a names frame first has nothing to parallel.
fn pacmSnamBeforeScen(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const scen = pacmFindTlv(p, Pacm.SCENES_SECTION_ID) orelse
        return error.FixtureMissingSection;
    const names = [_][]const u8{"drop"};
    const snam = try snamPayload(a, &names);
    return pacmAssemble(a, base, try insertTlv(a, p, scen.hdr, Pacm.SNAM_SECTION_ID, snam));
}

/// 'SNAM' count not parallel to 'SCEN': replace the committed names frame
/// in place with a well-formed count-2 frame whose entries account
/// exactly. The frozen full-small fixture predates `'SNAM'`, so the
/// helper inserts the canonical tail frame; either way there is exactly
/// ONE names frame, `'SCEN'` precedes it and the payload is otherwise
/// valid. ONLY the parallelism rule (`n != view.sceneCount()` at
/// `Pacm.decode`) can refuse this blob — never repeat, order, bounds or
/// trailing slack.
fn pacmSnamCountBreak(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const names = [_][]const u8{ "drop", "x" };
    const snam = try snamPayload(a, &names);
    return pacmAssemble(a, base, try replaceTlv(a, p, Pacm.SNAM_SECTION_ID, snam));
}

/// 'SNAM' with no 'SCEN' at all: a names frame must follow the scenes it
/// parallelizes (expr-keys has no scene section).
fn pacmSnamWithoutScen(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const empty = [_][]const u8{};
    const snam = try snamPayload(a, &empty);
    return pacmAssemble(a, base, try appendTlv(a, p, Pacm.SNAM_SECTION_ID, snam));
}

/// The honest-rewrite positive: a trusted PACM field (a documented track
/// span, never cross-checked by `verifyRouting`) changes, and the FNV is
/// recomputed over the new payload. The loader must accept AND serve
/// exactly that payload — the checksum repair discipline.
fn pacmHonestRewrite(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const span_end_at = Pacm.META_HEADER_LEN + 20;
    putU32(p, span_end_at, readU32(p, span_end_at) + 1);
    return pacmAssemble(a, base, p);
}

// ---------------------------------------------------------------------------
// 'PACM' ↔ PACB coherence family (B2a) — the PACM side stays
// structurally valid with an honest checksum (the reader oracle is
// asserted non-null on every case), so the refusal is the semantic
// cross-check, never checksum or structure. Count lies remove a WHOLE
// PACB unit and repair the directory rather than inflating a header into
// truncation. Finite lanes only: the non-finite matrix is B2b.
// ---------------------------------------------------------------------------

fn pacmFirstKeyOff(p: []const u8) usize {
    return Pacm.META_HEADER_LEN +
        @as(usize, readU32(p, PACM_TRACK_COUNT_OFF)) * Pacm.META_TRACK_LEN;
}

fn pacmFirstControlOff(p: []const u8) usize {
    return pacmFirstKeyOff(p) +
        @as(usize, readU32(p, PACM_KEY_COUNT_OFF)) * Pacm.META_KEY_LEN;
}

/// PACM track 0's `target_id` disagrees with the PACB track's join id.
fn pacmCoherenceTrackTarget(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const at = Pacm.META_HEADER_LEN + PACM_TRACK_TARGET_OFF;
    putU16(p, at, std.mem.readInt(u16, p[at..][0..2], .little) + 1);
    return pacmAssemble(a, base, p);
}

/// PACM track 0's registry byte disagrees with the PACB row's.
fn pacmCoherenceTrackRegistry(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const at = Pacm.META_HEADER_LEN + PACM_TRACK_REGISTRY_OFF;
    putU8(p, at, p[at] +% 1);
    return pacmAssemble(a, base, p);
}

/// PACM control 0's registry byte disagrees with the PACB control row's.
fn pacmCoherenceControlRegistry(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const at = pacmFirstControlOff(p) + PACM_CONTROL_REGISTRY_OFF;
    putU8(p, at, p[at] +% 1);
    return pacmAssemble(a, base, p);
}

/// A count lie that stays decodable: remove ONE complete 'TRAK' unit
/// from the PACB side and rebuild the canonical directory. The PACM is
/// untouched (valid structure, honest checksum); `verifyRouting`'s count
/// comparison is what refuses. No header is inflated into truncation.
fn pacbTrackUnitRemoved(a: Allocator, base: []const u8) ![]u8 {
    const src = sectionPayload(base, .trak);
    const n = readU32(src, COUNT_OFF);
    if (n < 2) return error.FixtureInvalid;
    const kept: usize = n - 1;
    const payload = try a.alloc(u8, 4 + kept * Pb.TRAK_REC_LEN);
    putU32(payload, COUNT_OFF, @intCast(kept));
    @memcpy(payload[4..], src[4..][0 .. kept * Pb.TRAK_REC_LEN]);
    return reassemble(a, base, &.{.{ .kind = .trak, .payload = payload }});
}

/// PACM key 0's finite value lane disagrees with the PACB key stream
/// (one-sided finite lane lie; the PACM reader stays non-null).
fn pacmCoherenceKeyValue(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const at = pacmFirstKeyOff(p) + PACM_KEY_VALUE_OFF;
    putF32(p, at, readF32(p, at) + 0.5);
    return pacmAssemble(a, base, p);
}

/// PACM control 0's finite value lane disagrees with the PACB control.
fn pacmCoherenceControlValue(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const at = pacmFirstControlOff(p) + PACM_CONTROL_VALUE_OFF;
    putF32(p, at, readF32(p, at) + 0.5);
    return pacmAssemble(a, base, p);
}

/// PACM 'EASE' program 0 / stage 0 / op 0 param differs from the PACB
/// program (finite; the op code stays in its domain).
fn pacmCoherenceEaseParam(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const tlv = pacmFindTlv(p, Pacm.EASE_SECTION_ID) orelse
        return error.FixtureMissingSection;
    // payload: [count u32][program: len u8+pad3, 8×stage 96]
    // stage: [t_end,v_base,v_span 12][ops_len u8+pad3][4×op 20]
    // op: [code u8+pad3][params 4×f32] — param 0 at +4.
    const at = tlv.payload + 4 + 4 + 16 + 4;
    putF32(p, at, readF32(p, at) + 0.5);
    return pacmAssemble(a, base, p);
}

/// PACM 'TMPO' segment 1 bpm differs from the PACB segment table
/// (finite; the PACM reader validates only count accounting here).
fn pacmCoherenceTmpoBpm(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const tlv = pacmFindTlv(p, Pacm.TEMPO_SECTION_ID) orelse
        return error.FixtureMissingSection;
    if (readU32(p, tlv.payload) < 2) return error.FixtureInvalid;
    putF64(p, tlv.payload + 4 + Pacm.TEMPO_REC_LEN + 8, 100.0);
    return pacmAssemble(a, base, p);
}

/// PACM 'SCEN' scene 0's start tick differs from the PACB scene window
/// (the name spans stay ordered, so the reader accepts).
fn pacmCoherenceSceneWindow(a: Allocator, base: []const u8) ![]u8 {
    const p = try pacmCopy(a, base);
    const tlv = pacmFindTlv(p, Pacm.SCENES_SECTION_ID) orelse
        return error.FixtureMissingSection;
    const at = tlv.payload + 4;
    putI64(p, at, std.mem.readInt(i64, p[at..][0..8], .little) + 1);
    return pacmAssemble(a, base, p);
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
        .{ .name = "pattern-silence", .bytes = fixtures.pattern_silence, .pact = pact },
        .{ .name = "pattern-live", .bytes = fixtures.pattern_live, .pact = pact },
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
        "negatives: full fixtures 6/6 status 0 (keys-only {d} B, expr-keys {d} B, full-small {d} B, host-join {d} B, pattern-silence {d} B, pattern-live {d} B)\n",
        .{
            fixtures.keys_only.len,
            fixtures.expr_keys.len,
            fixtures.full_small.len,
            fixtures.host_join.len,
            fixtures.pattern_silence.len,
            fixtures.pattern_live.len,
        },
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

    // 4. Compact-payload family (B2a) over expr-keys' genuine packed
    //    payload: the structural walk classes (8), the presence
    //    discipline (4), the caps (6) — then the status-0 positive
    //    characterizations LAST (an accepted load swaps the live score).
    {
        try addName(a, &names, "compact-payload");
        counters.family_labels += 1; // a family label, never an attempt
        var fam = try Family.begin(a, out, fixtures.expr_keys, pact);
        defer fam.end();

        try runNamed(&fam, &names, &counters, "payload-zero-root", try payloadRoots(a, fixtures.expr_keys, 0), 8);
        try runNamed(&fam, &names, &counters, "payload-multi-root", try payloadRoots(a, fixtures.expr_keys, 2), 8);
        try runNamed(&fam, &names, &counters, "payload-corrupt-node", try payloadCorruptNode(a, fixtures.expr_keys), 8);
        try runNamed(&fam, &names, &counters, "payload-inspan-slack", try payloadInSpanSlack(a, fixtures.expr_keys), 8);

        try runNamed(&fam, &names, &counters, "payload-region-degenerate", try payloadRegionDegenerate(a, fixtures.expr_keys), 4);
        try runNamed(&fam, &names, &counters, "payload-section-absent", try payloadSectionAbsent(a, fixtures.expr_keys), 4);
        try runNamed(&fam, &names, &counters, "payload-presence-without-track", try payloadPresenceWithoutTrack(a, fixtures.expr_keys), 4);

        try runNamed(&fam, &names, &counters, "payload-span-cap", try payloadSpanCap(a, fixtures.expr_keys), 6);
        try runNamed(&fam, &names, &counters, "payload-total-cap", try payloadTotalCap(a, fixtures.expr_keys), 6);

        try runPositive(
            &fam,
            &names,
            &counters,
            "payload-region-slack-tolerated",
            try payloadRegionSlack(a, fixtures.expr_keys),
            "region bytes beyond every span are a named v1 tolerance",
        );
        try runPositive(
            &fam,
            &names,
            &counters,
            "payload-reassembly-identity",
            try reassemblyIdentity(a, fixtures.expr_keys),
            "canonical reassembly is byte-identical to the producer output",
        );
    }

    // 5. PACM structural family (B2a) over full-small's genuine embedded
    //    metadata: every PACM-side edit recomputes 'TRAN'+48 FNV-1a-64 so
    //    the checksum fast-reject cannot mask the structural gate. The
    //    independent reader oracle is pinned per case; the honest-rewrite
    //    positive runs LAST (an accepted load swaps the live score).
    {
        try addName(a, &names, "pacm-structural");
        counters.family_labels += 1; // a family label, never an attempt
        var fam = try Family.begin(a, out, fixtures.full_small, pact);
        defer fam.end();

        try runPacmNamed(&fam, &names, &counters, "pacm-checksum-lie", try pacmChecksumLie(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-version-invalid", try pacmVersionInvalid(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-enum-invalid", try pacmEnumInvalid(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-bpm-zero", try pacmBpmZero(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-track-count-inflated", try pacmTrackCountInflated(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-truncated", try pacmTruncated(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-tlv-trailing-slack", try pacmTlvTrailingSlack(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-section-accounting", try pacmSectionAccounting(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-duplicate-tlv", try pacmDuplicateTlv(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-snam-before-scen", try pacmSnamBeforeScen(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-snam-count-break", try pacmSnamCountBreak(a, fixtures.full_small), 10, true);
        try runPacmNamed(&fam, &names, &counters, "pacm-snam-without-scen", try pacmSnamWithoutScen(a, fixtures.expr_keys), 10, true);

        try runPositivePacm(
            &fam,
            &names,
            &counters,
            "pacm-fnv-honest-rewrite",
            try pacmHonestRewrite(a, fixtures.full_small),
            "trusted span rewritten with the honest FNV; the loader serves that exact payload",
        );
    }

    // 6. PACM↔PACB coherence family (B2a): the PACM side is structurally
    //    valid and checksum-honest (reader oracle non-null), so every
    //    refusal is the semantic cross-check. The count case removes a
    //    complete 'TRAK' unit and repairs the directory — never a header
    //    inflated into truncation.
    {
        try addName(a, &names, "pacm-coherence");
        counters.family_labels += 1; // a family label, never an attempt
        var fam = try Family.begin(a, out, fixtures.full_small, pact);
        defer fam.end();

        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-track-target", try pacmCoherenceTrackTarget(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-track-registry", try pacmCoherenceTrackRegistry(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-control-registry", try pacmCoherenceControlRegistry(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-track-count", try pacbTrackUnitRemoved(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-key-value", try pacmCoherenceKeyValue(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-control-value", try pacmCoherenceControlValue(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-ease-param", try pacmCoherenceEaseParam(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-tmpo-bpm", try pacmCoherenceTmpoBpm(a, fixtures.full_small), 10, false);
        try runPacmNamed(&fam, &names, &counters, "pacm-coherence-scene-window", try pacmCoherenceSceneWindow(a, fixtures.full_small), 10, false);
    }

    // 7. Registry-identity family (B2a) over the committed host-join
    //    fixture: the host join must BE the pack-time join (canonical
    //    'PACT' byte equality). Both cases write a PactCodec-produced
    //    join into the targets zone and assert the ORIGINAL live score
    //    survives on the same instance (frames, held control, bpm, meta,
    //    counter), restoring BOTH input zones afterwards.
    {
        try addName(a, &names, "registry-identity");
        counters.family_labels += 1; // a family label, never an attempt
        var fam = try Family.begin(a, out, fixtures.host_join, join_pact);
        defer fam.end();
        try fam.primeExprFailure();

        // A canonical join with one EXTRA target: same spelling rules,
        // different registry content.
        const extra_targets = [_]pacer.Compile.Target{
            HOST_JOIN_TARGETS[0],
            HOST_JOIN_TARGETS[1],
            .{ .name = "pulse", .ncomp = 1, .registry = 0 },
        };
        const extra_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&extra_targets));
        const extra_pact = try pacer.PactCodec.encodeTargets(&extra_targets, extra_buf);

        // The same-shaped swap: "glow" and "flow" are both four bytes,
        // and each slot keeps a byte-identical (ncomp, registry) head.
        const swapped_targets = [_]pacer.Compile.Target{
            .{ .name = "flow", .ncomp = 1, .registry = 0 },
            .{ .name = "glow", .ncomp = 1, .registry = 0 },
        };
        const swapped_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&swapped_targets));
        const swapped_pact = try pacer.PactCodec.encodeTargets(&swapped_targets, swapped_buf);

        try runRegistryNamed(
            &fam,
            &names,
            &counters,
            "registry-extra-target",
            try duplicate(fixtures.host_join, a),
            extra_pact,
        );
        try runRegistryNamed(
            &fam,
            &names,
            &counters,
            "registry-name-swap",
            try duplicate(fixtures.host_join, a),
            swapped_pact,
        );
    }

    // 8. Pattern dry-run budget family (B2b) — test (p)'s producer class
    //    lifted into the counted suite. The over-budget body
    //    `(fast 8000 (pure 1))` is hand-encoded and spliced over the
    //    committed `pattern-silence` pack (compile refuses the same text,
    //    so the packer cannot produce it). The live baseline is
    //    `pattern-live` (the host-join singular expr shape) so the
    //    transactional pin includes a NONZERO expr-failure counter. The
    //    within-budget boundary `(fast 10 (pure 1))` must load AND play:
    //    the trip is the 1 MiB dry-run budget, not pattern complexity.
    {
        try addName(a, &names, "pattern-dry-run");
        counters.family_labels += 1; // a family label, never an attempt

        const budget_blob = try splicePatternBody(
            a,
            fixtures.pattern_silence,
            try patternBody(a, "(fast 8000 (pure 1))"),
        );
        var fam = try Family.begin(a, out, fixtures.pattern_live, pact);
        defer fam.end();
        try fam.primeExprFailure();
        try runNamed(
            &fam,
            &names,
            &counters,
            "pattern-dry-run-budget",
            budget_blob,
            11,
        );
    }
    {
        const boundary_blob = try splicePatternBody(
            a,
            fixtures.pattern_silence,
            try patternBody(a, "(fast 10 (pure 1))"),
        );
        var fam = try Family.begin(a, out, fixtures.pattern_silence, pact);
        defer fam.end();
        try runPositivePlays(
            &fam,
            &names,
            &counters,
            "pattern-dry-run-boundary",
            boundary_blob,
            "within the 1 MiB dry-run budget; loads and plays (fast 10)",
            0,
            1.0,
        );
    }

    // 9. Status-2 bad calls: a prior status-1 reason must survive.
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
        "negatives: partition {d} named + {d} bad-call + {d} prefix + {d} positive = {d} attempted; {d} names = {d} mutation name(s) + {d} bad-call name(s) + {d} positive name(s) + {d} family label(s) (T6b complete 2026-10-22; P3 accepted, Group B exited at bb0ba56; C/D/E open)\n",
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
        "negatives: exact status/reason and transactional preservation PASS; T6b complete; P3 accepted and Group B exited (2026-10-22); C/D/E open\n",
        .{},
    );
}
