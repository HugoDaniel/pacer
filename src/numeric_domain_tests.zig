//! B2b numeric/finite acceptance matrix — executable characterization of
//! the v1 playback loader's ACTUAL numeric domain, through the production
//! `prt_load` / `prt_evalTicks` exports (`NativeRt`).
//!
//! Every cell is an independently named assertion. The fixture is the
//! committed `numeric-matrix.pacb`: four declared targets so each lane is
//! addressable (a 4-lane key track + a 4-lane control, and scalar
//! key/control pairs whose lanes 1..3 are the pad domain), one control
//! whose min/max flags are SET and one whose flags are CLEAR. Mutations are
//! byte edits over a copy of the REAL CLI's pack; the PACM side is patched
//! in lockstep (with `'TRAN'+48` FNV-1a-64 recomputed) whenever a cell is
//! meant to reach the coherence cross-check, so a checksum fast-reject can
//! never mask the claimed stage.
//!
//! The matrix pins the two BL-1 expectations as disjoint, both-real facts:
//!   (i) a non-finite active lane only on the PACB side is a bit-equality
//!       `lanesEq` failure -> status 1 reason 10 `meta_incoherent`; and
//!   (ii) the SAME non-finite bits on both wires load clean (status 0), and
//!       the frame writes exactly those bits (no sanitizer, no rejection).
//!
//! Pad lanes are the zero-required domain (`key_invalid` /
//! `control_invalid`, reason 5). CTRL min/max are checked finite only when
//! their flags are set; with flags clear the lanes are zero-required (so
//! `-0.0` is accepted — it compares equal to zero — while a nonzero
//! finite or non-finite lane refuses reason 5). `Pacm.decode` itself has no
//! active-lane finiteness gate: structurally valid non-finite payloads
//! return a non-null view.

const std = @import("std");
const pacer = @import("pacer");
const sjon = @import("sjon");
const NativeRt = @import("NativeRt.zig");
const build_options = @import("build_options");

const Pb = pacer.Pacb;
const Pacm = pacer.Pacm;
const Writes = pacer.Writes;
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Report = struct {
    names: []const []const u8,
};

pub const Error = error{
    CounterMismatch,
    DuplicateCellName,
    FixtureInvalid,
    MatrixMismatch,
};

/// Read the committed numeric fixture once.
pub fn fixture(a: Allocator) ![]u8 {
    const path = try std.fmt.allocPrint(
        a,
        "{s}/tools/testdata/pacb/numeric-matrix.pacb",
        .{build_options.repo_root},
    );
    return sjon.CappedRead.readFile(std.testing.io, path, a, 1 << 20);
}

fn findSection(base: []const u8, kind: Pb.SectionKind) Pb.Section {
    const dir = Pb.parseDirectory(base, null) catch unreachable;
    return dir.find(kind).?.*;
}

fn sectionPayload(base: []const u8, kind: Pb.SectionKind) []const u8 {
    const section = findSection(base, kind);
    return base[section.off..][0..section.len];
}

fn duplicate(a: Allocator, base: []const u8) ![]u8 {
    return a.dupe(u8, base);
}

fn putU16(bytes: []u8, at: usize, value: u16) void {
    std.mem.writeInt(u16, bytes[at..][0..2], value, .little);
}

fn putU32(bytes: []u8, at: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
}

fn putU64(bytes: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, bytes[at..][0..8], value, .little);
}

fn putF32Bits(bytes: []u8, at: usize, bits: u32) void {
    putU32(bytes, at, bits);
}

fn readU16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn readU32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}

fn readF32Bits(bytes: []const u8, at: usize) u32 {
    return readU32(bytes, at);
}

const TRAN_PACM_FNV_OFF: usize = 48;
const PACM_TRACK_COUNT_OFF: usize = 28;
const PACM_KEY_COUNT_OFF: usize = 32;
const PACM_CONTROL_COUNT_OFF: usize = 36;
const PACM_TRACK_LEN: usize = Pacm.META_TRACK_LEN;
const PACM_KEY_LEN: usize = Pacm.META_KEY_LEN;
const PACM_CONTROL_LEN: usize = Pacm.META_CONTROL_LEN;
const PACM_KEY_VALUE_OFF: usize = 8;
const PACM_CONTROL_VALUE_OFF: usize = 8;
const PACM_CONTROL_MIN_OFF: usize = 24;
const PACM_CONTROL_MAX_OFF: usize = 40;
const CTRL_VALUE_OFF: usize = 12;
const CTRL_MIN_OFF: usize = 28;
const CTRL_MAX_OFF: usize = 44;

fn recomputePacmFnv(bytes: []u8) void {
    const tran = findSection(bytes, .tran);
    var h = std.hash.Fnv1a_64.init();
    h.update(sectionPayload(bytes, .pacm));
    putU64(bytes, tran.off + TRAN_PACM_FNV_OFF, h.final());
}

fn keysRecAt(base: []const u8, key_index: usize, lane: usize) usize {
    const keys = findSection(base, .keys);
    return @as(usize, keys.off) + 4 + key_index * Pb.KEYS_REC_LEN + PACM_KEY_VALUE_OFF + lane * 4;
}

fn ctrlRecAt(base: []const u8, control_index: usize) usize {
    // PACB 'CTRL' is a count-prefixed FIXED-stride section: the id lives in
    // 'STRS' (referenced by id_off/id_len at +6/+10), so record i starts at
    // off + 4 + i*CTRL_REC_LEN. (PACM is the variable-length spelling.)
    const ctrl = findSection(base, .ctrl);
    return @as(usize, ctrl.off) + 4 + control_index * Pb.CTRL_REC_LEN;
}

fn pacmControlsOff(p: []const u8) usize {
    const tc = readU32(p, PACM_TRACK_COUNT_OFF);
    const kc = readU32(p, PACM_KEY_COUNT_OFF);
    return Pacm.META_HEADER_LEN + @as(usize, tc) * PACM_TRACK_LEN + @as(usize, kc) * PACM_KEY_LEN;
}

fn pacmKeyOff(p: []const u8, key_index: usize, lane: usize) usize {
    const base = Pacm.META_HEADER_LEN +
        @as(usize, readU32(p, PACM_TRACK_COUNT_OFF)) * PACM_TRACK_LEN;
    return base + key_index * PACM_KEY_LEN + PACM_KEY_VALUE_OFF + lane * 4;
}

fn pacmCtrlAt(p: []const u8, control_index: usize) usize {
    var off = pacmControlsOff(p);
    var i: usize = 0;
    while (i < control_index) : (i += 1) {
        off += PACM_CONTROL_LEN + readU16(p, off + 6);
    }
    return off;
}

/// Patch one PACB key lane and the PACM spelling of the same key in
/// lockstep, then close with the honest FNV.
fn keyLaneBoth(a: Allocator, base: []const u8, key_index: usize, lane: usize, bits: u32) ![]u8 {
    const out = try duplicate(a, base);
    putF32Bits(out, keysRecAt(out, key_index, lane), bits);
    const pacm = findSection(out, .pacm);
    const p = out[pacm.off..][0..pacm.len];
    putF32Bits(p, pacmKeyOff(p, key_index, lane), bits);
    recomputePacmFnv(out);
    return out;
}

/// Patch one PACB key lane only (the one-sided / pad-lane shapes).
fn keyLanePacb(a: Allocator, base: []const u8, key_index: usize, lane: usize, bits: u32) ![]u8 {
    const out = try duplicate(a, base);
    putF32Bits(out, keysRecAt(out, key_index, lane), bits);
    return out;
}

const CtrlField = enum { value, min, max };

fn ctrlFieldOff(field: CtrlField) usize {
    return switch (field) {
        .value => CTRL_VALUE_OFF,
        .min => CTRL_MIN_OFF,
        .max => CTRL_MAX_OFF,
    };
}

fn pacmCtrlFieldOff(field: CtrlField) usize {
    return switch (field) {
        .value => PACM_CONTROL_VALUE_OFF,
        .min => PACM_CONTROL_MIN_OFF,
        .max => PACM_CONTROL_MAX_OFF,
    };
}

fn ctrlLaneBoth(a: Allocator, base: []const u8, control_index: usize, field: CtrlField, lane: usize, bits: u32) ![]u8 {
    const out = try duplicate(a, base);
    putF32Bits(out, ctrlRecAt(out, control_index) + ctrlFieldOff(field) + lane * 4, bits);
    const pacm = findSection(out, .pacm);
    const p = out[pacm.off..][0..pacm.len];
    putF32Bits(p, pacmCtrlAt(p, control_index) + pacmCtrlFieldOff(field) + lane * 4, bits);
    recomputePacmFnv(out);
    return out;
}

fn ctrlLanePacb(a: Allocator, base: []const u8, control_index: usize, field: CtrlField, lane: usize, bits: u32) ![]u8 {
    const out = try duplicate(a, base);
    putF32Bits(out, ctrlRecAt(out, control_index) + ctrlFieldOff(field) + lane * 4, bits);
    return out;
}

/// A PACM payload copy with one lane edited — the reader-oracle cells.
fn pacmOnlyLane(a: Allocator, base: []const u8, target: enum { key, ctrl }, index: usize, field: CtrlField, lane: usize, bits: u32) ![]u8 {
    const p = try a.dupe(u8, sectionPayload(base, .pacm));
    switch (target) {
        .key => putF32Bits(p, pacmKeyOff(p, index, lane), bits),
        .ctrl => putF32Bits(p, pacmCtrlAt(p, index) + pacmCtrlFieldOff(field) + lane * 4, bits),
    }
    return p;
}

const Loaded = struct {
    status: u32,
    reason: u32,
};

fn loadBlob(a: Allocator, pacb: []const u8, pact: []const u8) !Loaded {
    _ = a;
    if (pacb.len > NativeRt.pacbCap() or pact.len > NativeRt.targetsCap()) return error.FixtureInvalid;
    NativeRt.reset();
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);
    const status = NativeRt.load(@intCast(pacb.len), @intCast(pact.len));
    return .{ .status = status, .reason = NativeRt.loadError() };
}

fn frameEntry(a: Allocator, target_id: u16) !Writes.Entry {
    const len = NativeRt.evalTicks(0);
    if (len == 0) return error.MatrixMismatch;
    const mem = try a.alignedAlloc(u8, .of(Writes.Entry), len);
    @memcpy(mem, NativeRt.writesPtr()[0..len]);
    const entries = Writes.decode(mem) orelse return error.MatrixMismatch;
    for (entries) |entry| {
        if (entry.target_id == target_id) return entry;
    }
    return error.MatrixMismatch;
}

fn addName(a: Allocator, names: *std.ArrayList([]const u8), name: []const u8) !void {
    for (names.items) |existing| {
        if (std.mem.eql(u8, existing, name)) return error.DuplicateCellName;
    }
    try names.append(a, name);
}

fn cellName(
    a: Allocator,
    names: *std.ArrayList([]const u8),
    comptime fmt: []const u8,
    args: anytype,
) !void {
    try addName(a, names, try std.fmt.allocPrint(a, fmt, args));
}

fn expectRefused(
    a: Allocator,
    out: *Io.Writer,
    pacb: []const u8,
    pact: []const u8,
    reason: u32,
    name: []const u8,
) !void {
    const got = try loadBlob(a, pacb, pact);
    if (got.status != 1 or got.reason != reason) {
        try out.print(
            "numeric: {s}: expected status 1 reason {d}, got status {d} reason {d}\n",
            .{ name, reason, got.status, got.reason },
        );
        return error.MatrixMismatch;
    }
}

fn expectAccepted(
    a: Allocator,
    out: *Io.Writer,
    pacb: []const u8,
    pact: []const u8,
    name: []const u8,
) !void {
    const got = try loadBlob(a, pacb, pact);
    if (got.status != 0) {
        try out.print(
            "numeric: {s}: expected status 0 (accepted), got status {d} reason {d}\n",
            .{ name, got.status, got.reason },
        );
        return error.MatrixMismatch;
    }
}

/// Accepted key cell: the frame at tick 0 must write the PACB key
/// record's own four lanes BIT-EXACTLY (no sanitizer, no invented
/// rejection). The key is the first key of the 4-lane `quad` track.
fn expectKeyWrite(
    a: Allocator,
    out: *Io.Writer,
    pacb: []const u8,
    pact: []const u8,
    name: []const u8,
) !void {
    try expectAccepted(a, out, pacb, pact, name);
    const entry = frameEntry(a, 0) catch |err| {
        try out.print("numeric: {s}: no frame write for quad\n", .{name});
        return err;
    };
    for (0..4) |lane| {
        const want = readF32Bits(pacb, keysRecAt(pacb, 0, lane));
        const got: u32 = @bitCast(entry.value[lane]);
        if (want != got) {
            try out.print(
                "numeric: {s}: quad lane {d} expected bits 0x{x:0>8}, frame wrote 0x{x:0>8}\n",
                .{ name, lane, want, got },
            );
            return error.MatrixMismatch;
        }
    }
}

/// Accepted control cell: the frame at tick 0 must write the PACB control
/// record's own four value lanes BIT-EXACTLY.
fn expectControlWrite(
    a: Allocator,
    out: *Io.Writer,
    pacb: []const u8,
    pact: []const u8,
    name: []const u8,
) !void {
    try expectAccepted(a, out, pacb, pact, name);
    const entry = frameEntry(a, 1) catch |err| {
        try out.print("numeric: {s}: no frame write for quadctl\n", .{name});
        return err;
    };
    for (0..4) |lane| {
        const want = readF32Bits(pacb, ctrlRecAt(pacb, 0) + CTRL_VALUE_OFF + lane * 4);
        const got: u32 = @bitCast(entry.value[lane]);
        if (want != got) {
            try out.print(
                "numeric: {s}: quadctl lane {d} expected bits 0x{x:0>8}, frame wrote 0x{x:0>8}\n",
                .{ name, lane, want, got },
            );
            return error.MatrixMismatch;
        }
    }
}

/// Accepted pad cell: lanes >= ncomp stay zero in the emitted entry.
fn expectZeroPadWrite(
    a: Allocator,
    out: *Io.Writer,
    pacb: []const u8,
    pact: []const u8,
    target_id: u16,
    lane: usize,
    name: []const u8,
) !void {
    try expectAccepted(a, out, pacb, pact, name);
    const entry = frameEntry(a, target_id) catch |err| {
        try out.print("numeric: {s}: no frame write for target {d}\n", .{ name, target_id });
        return err;
    };
    const got: u32 = @bitCast(entry.value[lane]);
    if (got != 0) {
        try out.print(
            "numeric: {s}: target {d} pad lane {d} expected 0, frame wrote 0x{x:0>8}\n",
            .{ name, target_id, lane, got },
        );
        return error.MatrixMismatch;
    }
}

pub fn run(a: Allocator, out: *Io.Writer, pacb: []const u8) !Report {
    var names: std.ArrayList([]const u8) = .empty;

    const none = [_]pacer.Compile.Target{};
    const pact_buf = try a.alloc(u8, pacer.PactCodec.targetsEncodedLen(&none));
    const pact = try pacer.PactCodec.encodeTargets(&none, pact_buf);

    // Baseline: the unmutated packed score loads.
    try expectAccepted(a, out, pacb, pact, "numeric-baseline");

    const values = [_]struct { label: []const u8, bits: u32 }{
        .{ .label = "finite", .bits = @bitCast(@as(f32, 0.125)) },
        .{ .label = "nan", .bits = @bitCast(std.math.nan(f32)) },
        .{ .label = "pos-inf", .bits = @bitCast(std.math.inf(f32)) },
        .{ .label = "neg-inf", .bits = @bitCast(-std.math.inf(f32)) },
        .{ .label = "neg-zero", .bits = @bitCast(@as(f32, -0.0)) },
    };

    // ---- KEYS active lanes: quad key 0, lanes 0..3 independently.
    for (0..4) |lane| {
        for (values) |v| {
            const name = try std.fmt.allocPrint(a, "numeric-keys-active-l{d}-{s}", .{ lane, v.label });
            try addName(a, &names, name);
            const blob = try keyLaneBoth(a, pacb, 0, lane, v.bits);
            try expectKeyWrite(a, out, blob, pact, name);

            // The PACM reader preserves the same active-lane bits.
            const p = try pacmOnlyLane(a, pacb, .key, 0, .value, lane, v.bits);
            const view = Pacm.decode(p) orelse {
                try out.print("numeric: {s}: Pacm.decode returned null for an active-lane edit\n", .{name});
                return error.MatrixMismatch;
            };
            if (@as(u32, @bitCast(view.key(0).value[lane])) != v.bits) {
                try out.print("numeric: {s}: Pacm.decode did not preserve the active-lane bits\n", .{name});
                return error.MatrixMismatch;
            }
        }
    }

    // ---- KEYS pad lanes: scalar key 2, lanes 1..3.
    for (1..4) |lane| {
        {
            const name = try std.fmt.allocPrint(a, "numeric-keys-pad-l{d}-nonzero", .{lane});
            try addName(a, &names, name);
            const blob = try keyLanePacb(a, pacb, 2, lane, @bitCast(@as(f32, 0.5)));
            try expectRefused(a, out, blob, pact, 5, name);
        }
        {
            const name = try std.fmt.allocPrint(a, "numeric-keys-pad-l{d}-zero", .{lane});
            try addName(a, &names, name);
            const blob = try keyLaneBoth(a, pacb, 2, lane, 0);
            const entry = blk: {
                try expectAccepted(a, out, blob, pact, name);
                break :blk frameEntry(a, 2) catch |err| {
                    try out.print("numeric: {s}: no frame write for scalar\n", .{name});
                    return err;
                };
            };
            if (@as(u32, @bitCast(entry.value[lane])) != 0) {
                try out.print("numeric: {s}: scalar pad lane did not stay zero\n", .{name});
                return error.MatrixMismatch;
            }
        }
    }

    // ---- CTRL value lanes: control 0 (tint, ncomp 4), lanes 0..3.
    for (0..4) |lane| {
        for (values) |v| {
            const name = try std.fmt.allocPrint(a, "numeric-ctrl-value-l{d}-{s}", .{ lane, v.label });
            try addName(a, &names, name);
            const blob = try ctrlLaneBoth(a, pacb, 0, .value, lane, v.bits);
            try expectControlWrite(a, out, blob, pact, name);

            const p = try pacmOnlyLane(a, pacb, .ctrl, 0, .value, lane, v.bits);
            const view = Pacm.decode(p) orelse {
                try out.print("numeric: {s}: Pacm.decode returned null for a control value edit\n", .{name});
                return error.MatrixMismatch;
            };
            var it = view.controls();
            const ctl = it.next().?;
            if (@as(u32, @bitCast(ctl.value[lane])) != v.bits) {
                try out.print("numeric: {s}: Pacm.decode did not preserve the control value bits\n", .{name});
                return error.MatrixMismatch;
            }
        }
    }

    // ---- CTRL value pad lanes: control 1 (plain, ncomp 1), lanes 1..3.
    for (1..4) |lane| {
        {
            const name = try std.fmt.allocPrint(a, "numeric-ctrl-value-pad-l{d}-nonzero", .{lane});
            try addName(a, &names, name);
            const blob = try ctrlLanePacb(a, pacb, 1, .value, lane, @bitCast(@as(f32, 0.5)));
            try expectRefused(a, out, blob, pact, 5, name);
        }
        {
            const name = try std.fmt.allocPrint(a, "numeric-ctrl-value-pad-l{d}-zero", .{lane});
            try addName(a, &names, name);
            const blob = try ctrlLaneBoth(a, pacb, 1, .value, lane, 0);
            try expectZeroPadWrite(a, out, blob, pact, 3, lane, name);
        }
    }

    // ---- CTRL min/max: flags SET (control 0) and flags CLEAR (control 1).
    {
        const name = "numeric-ctrl-min-set-finite";
        try addName(a, &names, name);
        const blob = try ctrlLaneBoth(a, pacb, 0, .min, 0, @bitCast(@as(f32, 0.5)));
        try expectAccepted(a, out, blob, pact, name);
        const view = Pacm.decode(sectionPayload(blob, .pacm)).?;
        var it = view.controls();
        const ctl = it.next().?;
        if (@as(u32, @bitCast(ctl.min.?[0])) != @as(u32, @bitCast(@as(f32, 0.5)))) return error.MatrixMismatch;
    }
    {
        const name = "numeric-ctrl-max-set-finite";
        try addName(a, &names, name);
        const blob = try ctrlLaneBoth(a, pacb, 0, .max, 0, @bitCast(@as(f32, 0.5)));
        try expectAccepted(a, out, blob, pact, name);
        const view = Pacm.decode(sectionPayload(blob, .pacm)).?;
        var it = view.controls();
        const ctl = it.next().?;
        if (@as(u32, @bitCast(ctl.max.?[0])) != @as(u32, @bitCast(@as(f32, 0.5)))) return error.MatrixMismatch;
    }
    // The only values that trip the flag-set finiteness gate are the three
    // non-finite lanes; -0.0 is finite and is covered by the value-lane
    // cells above.
    for (values[1..4]) |v| {
        inline for (.{ .{ "min", CtrlField.min }, .{ "max", CtrlField.max } }) |pair| {
            const name = try std.fmt.allocPrint(a, "numeric-ctrl-{s}-set-{s}", .{ pair[0], v.label });
            try addName(a, &names, name);
            const blob = try ctrlLanePacb(a, pacb, 0, pair[1], 0, v.bits);
            try expectRefused(a, out, blob, pact, 5, name);
        }
    }
    {
        const name = "numeric-ctrl-min-clear-zero";
        try addName(a, &names, name);
        const blob = try ctrlLaneBoth(a, pacb, 1, .min, 0, 0);
        try expectAccepted(a, out, blob, pact, name);
    }
    {
        const name = "numeric-ctrl-max-clear-zero";
        try addName(a, &names, name);
        const blob = try ctrlLaneBoth(a, pacb, 1, .max, 0, 0);
        try expectAccepted(a, out, blob, pact, name);
    }
    {
        const name = "numeric-ctrl-min-clear-neg-zero";
        try addName(a, &names, name);
        const neg_zero: u32 = @bitCast(@as(f32, -0.0));
        const blob = try ctrlLaneBoth(a, pacb, 1, .min, 0, neg_zero);
        try expectAccepted(a, out, blob, pact, name);
    }
    {
        const name = "numeric-ctrl-max-clear-neg-zero";
        try addName(a, &names, name);
        const neg_zero: u32 = @bitCast(@as(f32, -0.0));
        const blob = try ctrlLaneBoth(a, pacb, 1, .max, 0, neg_zero);
        try expectAccepted(a, out, blob, pact, name);
    }
    inline for (.{ .{ "min", CtrlField.min }, .{ "max", CtrlField.max } }) |pair| {
        {
            const name = try std.fmt.allocPrint(a, "numeric-ctrl-{s}-clear-finite-nonzero", .{pair[0]});
            try addName(a, &names, name);
            const blob = try ctrlLanePacb(a, pacb, 1, pair[1], 0, @bitCast(@as(f32, 0.5)));
            try expectRefused(a, out, blob, pact, 5, name);
        }
        {
            const name = try std.fmt.allocPrint(a, "numeric-ctrl-{s}-clear-nan", .{pair[0]});
            try addName(a, &names, name);
            const blob = try ctrlLanePacb(a, pacb, 1, pair[1], 0, @bitCast(std.math.nan(f32)));
            try expectRefused(a, out, blob, pact, 5, name);
        }
    }

    // ---- PACM reader has no active-lane finiteness gate (reader oracle).
    {
        const name = "numeric-pacm-key-nan-reader";
        try addName(a, &names, name);
        const p = try pacmOnlyLane(a, pacb, .key, 0, .value, 0, @bitCast(std.math.nan(f32)));
        const view = Pacm.decode(p) orelse {
            try out.print("numeric: {s}: Pacm.decode refused a non-finite active key lane\n", .{name});
            return error.MatrixMismatch;
        };
        if (!std.math.isNan(view.key(0).value[0])) return error.MatrixMismatch;
    }
    {
        const name = "numeric-pacm-ctrl-value-pos-inf-reader";
        try addName(a, &names, name);
        const p = try pacmOnlyLane(a, pacb, .ctrl, 0, .value, 0, @bitCast(std.math.inf(f32)));
        const view = Pacm.decode(p) orelse {
            try out.print("numeric: {s}: Pacm.decode refused a non-finite control value lane\n", .{name});
            return error.MatrixMismatch;
        };
        var it = view.controls();
        if (!std.math.isInf(it.next().?.value[0])) return error.MatrixMismatch;
    }
    {
        const name = "numeric-pacm-ctrl-min-neg-inf-reader";
        try addName(a, &names, name);
        const p = try pacmOnlyLane(a, pacb, .ctrl, 0, .min, 0, @bitCast(-std.math.inf(f32)));
        const view = Pacm.decode(p) orelse {
            try out.print("numeric: {s}: Pacm.decode refused a non-finite min lane\n", .{name});
            return error.MatrixMismatch;
        };
        var it = view.controls();
        if (!std.math.isInf(it.next().?.min.?[0])) return error.MatrixMismatch;
    }
    {
        const name = "numeric-pacm-ctrl-max-nan-reader";
        try addName(a, &names, name);
        const p = try pacmOnlyLane(a, pacb, .ctrl, 0, .max, 0, @bitCast(std.math.nan(f32)));
        const view = Pacm.decode(p) orelse {
            try out.print("numeric: {s}: Pacm.decode refused a non-finite max lane\n", .{name});
            return error.MatrixMismatch;
        };
        var it = view.controls();
        if (!std.math.isNan(it.next().?.max.?[0])) return error.MatrixMismatch;
    }

    // ---- BL-1 (i): one-sided non-finite bits are incoherent.
    {
        const name = "numeric-coherence-key-one-sided-nan";
        try addName(a, &names, name);
        const blob = try keyLanePacb(a, pacb, 0, 0, @bitCast(std.math.nan(f32)));
        try expectRefused(a, out, blob, pact, 10, name);
    }
    {
        const name = "numeric-coherence-ctrl-value-one-sided-pos-inf";
        try addName(a, &names, name);
        const blob = try ctrlLanePacb(a, pacb, 0, .value, 0, @bitCast(std.math.inf(f32)));
        try expectRefused(a, out, blob, pact, 10, name);
    }

    try out.print("numeric: {d} named cells executed (BL-1 key/control cross-check + self-consistent non-finite writes)\n", .{names.items.len});
    return .{ .names = names.items };
}

test "numeric: PACB CTRL records use the fixed 60-byte stride" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pacb = try fixture(a);

    const ctrl = findSection(pacb, .ctrl);
    const ctrl0 = ctrlRecAt(pacb, 0);
    const ctrl1 = ctrlRecAt(pacb, 1);

    // 'CTRL' is a count-prefixed FIXED-stride section: the control id
    // lives in 'STRS' (id_off/id_len at +6/+10), unlike PACM's
    // variable-length control records. Every record is exactly
    // CTRL_REC_LEN (60) bytes, so record i starts at off + 4 + i*60.
    try std.testing.expectEqual(@as(usize, ctrl.off) + 4, ctrl0);
    try std.testing.expectEqual(@as(usize, ctrl.off) + 4 + Pb.CTRL_REC_LEN, ctrl1);
    try std.testing.expectEqual(
        @as(usize, ctrl.off) + @as(usize, ctrl.len),
        ctrl1 + Pb.CTRL_REC_LEN,
    );

    // The two controls the matrix mutates: 0 is the 4-lane flags-SET
    // `tint`; 1 is the scalar flags-CLEAR `plain`. The ncomp (+3) and
    // flags (+5) bytes make the claimed field/lane offsets legible.
    try std.testing.expectEqual(@as(u8, 4), pacb[ctrl0 + 3]);
    try std.testing.expectEqual(@as(u8, 3), pacb[ctrl0 + 5]);
    try std.testing.expectEqual(@as(u8, 1), pacb[ctrl1 + 3]);
    try std.testing.expectEqual(@as(u8, 0), pacb[ctrl1 + 5]);

    // The six value-pad cells target rec1 + 16/20/24; the eight CLEAR
    // cells target rec1 + 28 (min lane 0) and rec1 + 44 (max lane 0).
    // Each claimed offset is inside its declared field and every field
    // stays inside the 60-byte record.
    try std.testing.expectEqual(@as(usize, 16), CTRL_VALUE_OFF + 1 * 4);
    try std.testing.expectEqual(@as(usize, 24), CTRL_VALUE_OFF + 3 * 4);
    try std.testing.expectEqual(@as(usize, 28), CTRL_MIN_OFF);
    try std.testing.expectEqual(@as(usize, 44), CTRL_MAX_OFF);
    try std.testing.expect(ctrl1 + CTRL_MIN_OFF + 3 * 4 < ctrl1 + CTRL_MAX_OFF);
    try std.testing.expect(ctrl1 + CTRL_MAX_OFF + 3 * 4 < ctrl1 + Pb.CTRL_REC_LEN);
}
