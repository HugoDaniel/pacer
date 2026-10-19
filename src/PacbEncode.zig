//! `'PACB'` encoder core — the producer half of the compiled-score
//! container (plan 01, Phase 3 T3.1).
//!
//! `encode` mirrors one `Compile.CompileResult` + the host target join
//! into the canonical container `Pacb.decode` accepts: the same frozen
//! section order, the same presence/omit rules, the same zero-pad
//! discipline. It EMITS the compiled table; it never re-derives it —
//! no shadow evaluation, no second compilation pass, no schema walk.
//! Every record field is read straight off `result.table` (or sliced
//! verbatim out of the single embedded `'PACM'` pass), so the wire can
//! only ever spell what the compiler already computed.
//!
//! Canonical rules implemented here (all decoder-checked — `Pacb.zig`
//! is the format of record):
//!
//!   * Required sections: `'TRAN'` and `'PACM'` always present.
//!   * Degenerate omission: `'REGS'` iff the host join is non-empty,
//!     `'DECL'` iff declared targets exist, `'EMIT'`/`'TRAK'`/`'KEYS'`/
//!     `'TICK'`/`'CTRL'`/`'SCEN'`/`'STRS'`/`'PAYL'` iff they carry ≥ 1
//!     record, `'TMPO'` iff the tempo map has > 1 segment, `'EASE'` iff
//!     the program table is more than the shared linear default.
//!   * `'DECL'` is `result.targets[host_targets.len..]` — the merged
//!     join's declared tail (A22); the host prefix is the ACTUAL
//!     `host_targets` slice, encoded canonically into `'REGS'`.
//!   * `'EASE'`/`'TMPO'` payloads are sliced verbatim out of the one
//!     `Abi.encodeMeta` pass whose blob is embedded whole as `'PACM'`
//!     — one producer pass, three spellings, no re-encoding.
//!   * Directory: canonical order, contiguous, gap-free, first payload
//!     at `16 + 12 × count`, buffer ends exactly at the last section.
//!   * Every pad/reserved/unused byte is zero (the output buffer is
//!     zero-allocated; writers touch only real fields).
//!   * `required_features` bit0 iff a `:pattern` track exists.
//!
//! Error set is `error{OutOfMemory}` alone (the frozen interface):
//! `result.ok()` is a PRECONDITION (`Abi.encodeMeta` asserts the same),
//! and the v1 resource caps (per-payload, total `'PAYL'`, global
//! explicit ticks) are T3.2's pack preflight — loud refusals with
//! diagnostics belong there, not here.
//!
//! Imports `Compile`, `Abi`, `Pacb`, `PactCodec` (the plan-frozen set —
//! the compiler side is legal here; the DECODER side stays compiler-
//! free). Test bodies additionally import `test_support`/`ExprTrack`,
//! exactly as `Pacb.zig`'s compiler-oracle tests do.

const std = @import("std");
const sjon = @import("sjon");
const Compile = @import("Compile.zig");
const Abi = @import("Abi.zig");
const Pacb = @import("Pacb.zig");
const Pacm = @import("Pacm.zig");
const PactCodec = @import("PactCodec.zig");
const TrackTable = @import("TrackTable.zig");

/// The encoder's whole failure surface: allocation. Every other defect
/// is either a `result.ok()` precondition (asserted) or T3.2 pack
/// preflight territory (refusal diagnostics, not encoder errors).
pub const Error = error{OutOfMemory};

/// FNV-1a-64 over bytes — `'TRAN'`'s checksum family, the public
/// spelling (the decoder-side use is `Pacb`'s private twin).
pub fn fnv1a64(bytes: []const u8) u64 {
    var h = std.hash.Fnv1a_64.init();
    h.update(bytes);
    return h.final();
}

/// The canonical `'PACT'` bytes of the ACTUAL host join — the registry
/// identity `'REGS'` carries and `pact_fnv` checksums. An empty host
/// join is the 8-byte zero-count spelling (the omitted-section case),
/// so the checksum is well-defined for every score.
fn canonicalRegs(
    a: std.mem.Allocator,
    host_targets: []const Compile.Target,
) Error![]const u8 {
    if (host_targets.len == 0) {
        const zero = a.alloc(u8, PactCodec.TARGETS_HEADER_LEN) catch
            return error.OutOfMemory;
        std.mem.writeInt(u32, zero[0..4], PactCodec.TARGETS_MAGIC, .little);
        std.mem.writeInt(u32, zero[4..8], 0, .little);
        return zero;
    }
    const buf = a.alloc(u8, PactCodec.targetsEncodedLen(host_targets)) catch
        return error.OutOfMemory;
    return PactCodec.encodeTargets(host_targets, buf) catch
        return error.OutOfMemory;
}

/// One `'TRAK'` payload span / explicit-tick run position, in the
/// concatenated stream (the same shape the decoder carries).
const PayloadSpan = struct { off: usize, len: usize };

/// Encode one successfully compiled score + its host target join into a
/// canonical `'PACB'` buffer. PRECONDITION `result.ok()`; `host_targets`
/// is the same host registry list the score was compiled against (the
/// merged join's prefix, `CompileResult.targets`).
pub fn encode(
    gpa: std.mem.Allocator,
    result: *const Compile.CompileResult,
    host_targets: []const Compile.Target,
) Error![]u8 {
    std.debug.assert(result.ok());
    const table = &result.table.?;
    const transport = &table.transport;

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    // The single 'PACM' pass: the blob embedded verbatim below.
    const pacm_buf = a.alloc(u8, Abi.metaEncodedLen(result)) catch
        return error.OutOfMemory;
    const pacm = Abi.encodeMeta(result, pacm_buf) catch return error.OutOfMemory;

    // Registry identity bytes: canonical 'PACT' of the actual host join.
    const regs = try canonicalRegs(a, host_targets);
    const declared_count = result.targets.len - host_targets.len;

    // --- section content, one arena buffer per present section ---
    var bufs: [Pacb.MAX_SECTIONS]SectionBuf = undefined;
    var n: usize = 0;

    {
        const dest = try a.alloc(u8, Pacb.TRAN_REC_LEN);
        @memset(dest, 0);
        writeTran(dest, transport, host_targets.len, declared_count, regs, pacm);
        bufs[n] = .{ .kind = .tran, .bytes = dest };
        n += 1;
    }
    if (host_targets.len > 0) {
        const dest = try a.alloc(u8, 4 + regs.len);
        @memset(dest, 0);
        std.mem.writeInt(u32, dest[0..4], @intCast(regs.len), .little);
        @memcpy(dest[4..], regs);
        bufs[n] = .{ .kind = .regs, .bytes = dest };
        n += 1;
    }

    // 'DECL': the merged join's declared tail — `result.targets` past the
    // host prefix (A22). The host prefix itself never rides this
    // section; it is the actual `host_targets` list's 'REGS' bytes.
    if (declared_count > 0) {
        const tail = result.targets[host_targets.len..];
        const dest = try a.alloc(u8, 4 + tail.len * Pacb.DECL_REC_LEN);
        @memset(dest, 0);
        std.mem.writeInt(u32, dest[0..4], @intCast(tail.len), .little);
        for (tail, 0..) |target, i| {
            const at = 4 + i * Pacb.DECL_REC_LEN;
            dest[at] = target.registry;
            dest[at + 1] = target.ncomp;
            // pad u16 @ +2 stays zero
        }
        bufs[n] = .{ .kind = .decl, .bytes = dest };
        n += 1;
    }

    // 'EMIT': the transport's clock lanes, document order.
    if (transport.emit.len > 0) {
        const dest = try a.alloc(u8, 4 + transport.emit.len * Pacb.EMIT_REC_LEN);
        @memset(dest, 0);
        std.mem.writeInt(u32, dest[0..4], @intCast(transport.emit.len), .little);
        for (transport.emit, 0..) |lane, i| {
            const at = 4 + i * Pacb.EMIT_REC_LEN;
            dest[at] = @intFromEnum(lane.name);
            dest[at + 1] = lane.registry;
            std.mem.writeInt(u16, dest[at + 2 ..][0..2], lane.target_id, .little);
            // reserved u32 @ +4 stays zero
        }
        bufs[n] = .{ .kind = .emit, .bytes = dest };
        n += 1;
    }

    // 'STRS' + 'CTRL': the control-id table (sorted canonically, the
    // decoder's own comparator) and the pin records addressed into it.
    if (table.controls.len > 0) {
        const ids = try a.alloc([]const u8, table.controls.len);
        for (ids, table.controls) |*slot, ctl| slot.* = ctl.id;
        const byStrsOrder = struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return Pacb.strsEntryLess(x, y);
            }
        }.less;
        std.mem.sort([]const u8, ids, {}, byStrsOrder);

        var byte_size: usize = 0;
        for (ids) |id| byte_size += 2 + id.len;
        const strs = try a.alloc(u8, 8 + byte_size);
        @memset(strs, 0);
        std.mem.writeInt(u32, strs[0..4], @intCast(ids.len), .little);
        std.mem.writeInt(u32, strs[4..8], @intCast(byte_size), .little);
        var cursor: usize = 8;
        for (ids) |id| {
            std.mem.writeInt(u16, strs[cursor..][0..2], @intCast(id.len), .little);
            @memcpy(strs[cursor + 2 ..][0..id.len], id);
            cursor += 2 + id.len;
        }

        const ctrl = try a.alloc(u8, 4 + table.controls.len * Pacb.CTRL_REC_LEN);
        @memset(ctrl, 0);
        std.mem.writeInt(u32, ctrl[0..4], @intCast(table.controls.len), .little);
        for (table.controls, 0..) |ctl, i| {
            const at = 4 + i * Pacb.CTRL_REC_LEN;
            if (ctl.target) |tg| {
                std.mem.writeInt(u16, ctrl[at..][0..2], tg.id, .little);
                ctrl[at + 2] = tg.registry;
            } else {
                std.mem.writeInt(u16, ctrl[at..][0..2], TrackTable.NO_TARGET, .little);
            }
            ctrl[at + 3] = ctl.ncomp;
            ctrl[at + 4] = @intFromEnum(ctl.kind);
            var flags: u8 = 0;
            if (ctl.min != null) flags |= 1;
            if (ctl.max != null) flags |= 2;
            ctrl[at + 5] = flags;
            // The id's byte range inside 'STRS' (region-relative, exactly
            // one entry's spelling — decode matches entry-for-entry).
            var id_off: usize = 0;
            var scan: usize = 0;
            for (ids) |id| {
                if (std.mem.eql(u8, id, ctl.id)) {
                    id_off = scan + 2;
                    break;
                }
                scan += 2 + id.len;
            }
            std.mem.writeInt(u32, ctrl[at + 6 ..][0..4], @intCast(id_off), .little);
            std.mem.writeInt(u16, ctrl[at + 10 ..][0..2], @intCast(ctl.id.len), .little);
            for (0..4) |lane| {
                std.mem.writeInt(u32, ctrl[at + 12 + lane * 4 ..][0..4], @bitCast(ctl.value[lane]), .little);
            }
            if (ctl.min) |min| for (0..4) |lane| {
                std.mem.writeInt(u32, ctrl[at + 28 + lane * 4 ..][0..4], @bitCast(min[lane]), .little);
            };
            if (ctl.max) |max| for (0..4) |lane| {
                std.mem.writeInt(u32, ctrl[at + 44 + lane * 4 ..][0..4], @bitCast(max[lane]), .little);
            };
        }

        bufs[n] = .{ .kind = .ctrl, .bytes = ctrl };
        n += 1;
        bufs[n] = .{ .kind = .strs, .bytes = strs };
        n += 1;
    }

    // 'SCEN': the windows (the name span stays text-side, §A O-a).
    if (table.scenes.len > 0) {
        const dest = try a.alloc(u8, 4 + table.scenes.len * Pacb.SCEN_REC_LEN);
        @memset(dest, 0);
        std.mem.writeInt(u32, dest[0..4], @intCast(table.scenes.len), .little);
        for (table.scenes, 0..) |scene, i| {
            const at = 4 + i * Pacb.SCEN_REC_LEN;
            std.mem.writeInt(i64, dest[at..][0..8], scene.start_tick, .little);
            std.mem.writeInt(i64, dest[at + 8 ..][0..8], scene.dur_ticks, .little);
        }
        bufs[n] = .{ .kind = .scen, .bytes = dest };
        n += 1;
    }

    // 'EASE'/'TMPO': the same 'PACM' pass's own TLV payloads, sliced
    // verbatim — the decoder re-checks these bytes against the table,
    // and the embedded blob's writer is the format of record, so the
    // sections can never diverge from it. The view borrows `pacm`
    // (scratch-arena memory, alive through assembly); a decode failure
    // here would be the encoder's own emission lying about itself —
    // producer-impossible.
    if (table.programs.len > 1 or table.transport.segments.len > 1) {
        const view = Pacm.decode(pacm) orelse unreachable;
        if (table.programs.len > 1) {
            bufs[n] = .{ .kind = .ease, .bytes = view.ease.? };
            n += 1;
        }
        if (table.transport.segments.len > 1) {
            bufs[n] = .{ .kind = .tmpo, .bytes = view.tmpo.? };
            n += 1;
        }
    }

    // Per-track payload/tick spans, cursored as the record writer walks
    // the tracks in order (the decoder's non-overlap discipline).
    const payload_spans = try a.alloc(PayloadSpan, table.tracks.len);
    for (payload_spans) |*span| span.* = .{ .off = 0, .len = 0 };
    const tick_spans = try a.alloc(PayloadSpan, table.tracks.len);
    for (tick_spans) |*span| span.* = .{ .off = 0, .len = 0 };
    var tick_total: usize = 0;
    var has_keys_track = false;
    for (table.tracks) |track| switch (track.source) {
        .trigger => |trig| switch (trig) {
            .at => |ats| tick_total += ats.len,
            .periodic => {},
        },
        .keys => has_keys_track = true,
        .expr, .pattern => {},
    };

    // 'PAYL': per expr/pattern track, the value subtree cloned into a
    // one-root tree and compact-encoded (the frozen A29 choice) — never
    // a re-parse, never a shadow evaluation; the bytes are the compiled
    // table's own AST.
    const payload_bytes = try a.alloc([]const u8, table.tracks.len);
    for (payload_bytes) |*slot| slot.* = &.{};
    var has_payload_track = false;
    var payload_total: usize = 0;
    for (table.tracks, 0..) |track, i| switch (track.source) {
        .expr => |node| {
            const bytes = try encodePayload(a, &result.validated.result.tree, node);
            payload_bytes[i] = bytes;
            payload_spans[i] = .{ .off = payload_total, .len = bytes.len };
            payload_total += bytes.len;
            has_payload_track = true;
        },
        .pattern => |node| {
            const bytes = try encodePayload(a, &result.validated.result.tree, node);
            payload_bytes[i] = bytes;
            payload_spans[i] = .{ .off = payload_total, .len = bytes.len };
            payload_total += bytes.len;
            has_payload_track = true;
        },
        .keys, .trigger => {},
    };

    // 'TRAK' + 'TICK' + 'KEYS': the record sections over the table.
    if (table.tracks.len > 0 or has_keys_track or tick_total > 0) {
        const trak = try a.alloc(u8, 4 + table.tracks.len * Pacb.TRAK_REC_LEN);
        @memset(trak, 0);
        std.mem.writeInt(u32, trak[0..4], @intCast(table.tracks.len), .little);

        var tick_section: []u8 = &.{};
        if (tick_total > 0) {
            tick_section = try a.alloc(u8, 4 + tick_total * Pacb.TICK_REC_LEN);
            @memset(tick_section, 0);
            std.mem.writeInt(u32, tick_section[0..4], @intCast(tick_total), .little);
        }
        var tick_cursor: usize = 0;

        for (table.tracks, 0..) |track, i| {
            const at = 4 + i * Pacb.TRAK_REC_LEN;
            std.mem.writeInt(u16, trak[at..][0..2], track.target_id, .little);
            trak[at + 2] = track.registry;
            trak[at + 3] = track.ncomp;
            std.mem.writeInt(u16, trak[at + 6 ..][0..2], track.scene, .little);
            switch (track.source) {
                .keys => |ks| {
                    trak[at + 4] = Pacb.SOURCE_KEYS;
                    std.mem.writeInt(u32, trak[at + 8 ..][0..4], ks.start, .little);
                    std.mem.writeInt(u32, trak[at + 12 ..][0..4], ks.len, .little);
                },
                .trigger => |trig| switch (trig) {
                    .periodic => |p| {
                        trak[at + 4] = Pacb.SOURCE_TRIGGER;
                        trak[at + 5] = Pacb.TRIG_PERIODIC;
                        std.mem.writeInt(i64, trak[at + 24 ..][0..8], p.every, .little);
                        std.mem.writeInt(i64, trak[at + 32 ..][0..8], p.offset, .little);
                    },
                    .at => |ats| {
                        trak[at + 4] = Pacb.SOURCE_TRIGGER;
                        trak[at + 5] = Pacb.TRIG_EXPLICIT;
                        std.mem.writeInt(u32, trak[at + 8 ..][0..4], @intCast(tick_cursor), .little);
                        std.mem.writeInt(u32, trak[at + 12 ..][0..4], @intCast(ats.len), .little);
                        for (ats) |tick| {
                            std.mem.writeInt(i64, tick_section[4 + tick_cursor * Pacb.TICK_REC_LEN ..][0..8], tick, .little);
                            tick_cursor += 1;
                        }
                    },
                },
                .expr, .pattern => {
                    trak[at + 4] = if (track.source == .expr)
                        Pacb.SOURCE_EXPR
                    else
                        Pacb.SOURCE_PATTERN;
                    std.mem.writeInt(u32, trak[at + 16 ..][0..4], @intCast(payload_spans[i].off), .little);
                    std.mem.writeInt(u32, trak[at + 20 ..][0..4], @intCast(payload_spans[i].len), .little);
                },
            }
        }

        if (table.tracks.len > 0) {
            bufs[n] = .{ .kind = .trak, .bytes = trak };
            n += 1;
        }
        if (has_keys_track) {
            const keys = try a.alloc(u8, 4 + table.keys.len * Pacb.KEYS_REC_LEN);
            @memset(keys, 0);
            std.mem.writeInt(u32, keys[0..4], @intCast(table.keys.len), .little);
            for (table.keys, 0..) |key, i| {
                const at = 4 + i * Pacb.KEYS_REC_LEN;
                std.mem.writeInt(i64, keys[at..][0..8], key.at, .little);
                for (0..4) |lane| {
                    std.mem.writeInt(u32, keys[at + 8 + lane * 4 ..][0..4], @bitCast(key.value[lane]), .little);
                }
                std.mem.writeInt(u16, keys[at + 24 ..][0..2], key.ease_ref, .little);
            }
            bufs[n] = .{ .kind = .keys, .bytes = keys };
            n += 1;
        }
        if (tick_total > 0) {
            bufs[n] = .{ .kind = .tick, .bytes = tick_section };
            n += 1;
        }
    }

    // 'PAYL': the concatenated per-track payloads in track order.
    if (has_payload_track) {
        const dest = try a.alloc(u8, 4 + payload_total);
        @memset(dest, 0);
        std.mem.writeInt(u32, dest[0..4], @intCast(payload_total), .little);
        var cursor: usize = 4;
        for (payload_bytes) |bytes| {
            @memcpy(dest[cursor..][0..bytes.len], bytes);
            cursor += bytes.len;
        }
        bufs[n] = .{ .kind = .payl, .bytes = dest };
        n += 1;
    }

    {
        const dest = try a.alloc(u8, pacm.len);
        @memcpy(dest, pacm);
        bufs[n] = .{ .kind = .pacm, .bytes = dest };
        n += 1;
    }

    return assemble(gpa, &bufs, n, table);
}

/// One assembled section: its kind and its complete payload bytes
/// (count prefixes included), in canonical emission order.
const SectionBuf = struct { kind: Pacb.SectionKind, bytes: []const u8 };

/// Serialize one expr/pattern value subtree: `cloneNode` into a fresh
/// one-root tree, then the frozen compact binary encoding (A29 — no
/// spans, no comments; the smallest deterministic spelling). The source
/// string is unused (strings re-intern into the clone; compact drops
/// spans), so the one-root tree finalizes against "".
fn encodePayload(
    a: std.mem.Allocator,
    tree: *const sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
) Error![]const u8 {
    var builder = sjon.Ast.TreeBuilder{ .a = a };
    const root = try builder.cloneNode(tree, node);
    var tree_arena = std.heap.ArenaAllocator.init(a);
    defer tree_arena.deinit();
    var one_root = try builder.finalize(&tree_arena, "", &.{root});
    defer one_root.deinit();
    // The writer's non-OOM outcomes are structural-cap rejections
    // (node count, depth, string length) that a cloned subtree of a
    // validated document cannot trip: the parser's own caps sit at or
    // below the writer's (comptime-checked for depth), and compact mode
    // emits no comments. Producer-impossible, like the linear default.
    const bin = sjon.Binary.toBinary(
        a,
        one_root,
        sjon.Binary.ToBinaryOptions.forMode(.compact),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable,
    };
    defer bin.deinit();
    return a.dupe(u8, bin.data);
}

/// Canonical-rank of a section kind — its index in the frozen
/// `canonical_section_order` table (the enum's INTEGER values are the
/// 4-CC ids, which do NOT sort canonically: 'PACM' < 'TRAN' bytewise).
fn canonicalRank(kind: Pacb.SectionKind) usize {
    for (Pacb.canonical_section_order, 0..) |candidate, i| {
        if (candidate == kind) return i;
    }
    unreachable;
}

/// Assemble header + directory + section bodies in canonical order
/// (ranked by `canonical_section_order`; the buffers are sorted into
/// it). Contiguity and exact end follow from the arithmetic, and the
/// zero-filled output keeps every pad/reserved byte zero.
/// `required_features` bit0 is set iff the table carries a `:pattern`
/// track — the one header word with content.
fn assemble(
    gpa: std.mem.Allocator,
    bufs: []SectionBuf,
    n: usize,
    table: *const TrackTable,
) Error![]u8 {
    const byCanonical = struct {
        fn less(_: void, x: SectionBuf, y: SectionBuf) bool {
            return canonicalRank(x.kind) < canonicalRank(y.kind);
        }
    }.less;
    std.mem.sort(SectionBuf, bufs[0..n], {}, byCanonical);

    var total: usize = Pacb.HEADER_LEN + n * Pacb.DIRECTORY_ENTRY_LEN;
    for (bufs[0..n]) |b| total += b.bytes.len;
    const out = gpa.alloc(u8, total) catch return error.OutOfMemory;
    @memset(out, 0);

    var features: u32 = 0;
    for (table.tracks) |track| {
        if (track.source == .pattern) features |= Pacb.FEATURE_PATTERN_TRACKS;
    }
    std.mem.writeInt(u32, out[0..4], Pacb.MAGIC, .little);
    std.mem.writeInt(u32, out[4..8], Pacb.VERSION, .little);
    std.mem.writeInt(u32, out[8..12], features, .little);
    std.mem.writeInt(u32, out[12..16], @intCast(n), .little);

    var off: usize = Pacb.HEADER_LEN + n * Pacb.DIRECTORY_ENTRY_LEN;
    for (bufs[0..n], 0..) |b, i| {
        const at = Pacb.HEADER_LEN + i * Pacb.DIRECTORY_ENTRY_LEN;
        std.mem.writeInt(u32, out[at..][0..4], @intFromEnum(b.kind), .little);
        std.mem.writeInt(u32, out[at + 4 ..][0..4], @intCast(off), .little);
        std.mem.writeInt(u32, out[at + 8 ..][0..4], @intCast(b.bytes.len), .little);
        @memcpy(out[off..][0..b.bytes.len], b.bytes);
        off += b.bytes.len;
    }
    std.debug.assert(off == total);
    return out;
}

/// `'TRAN'` — one 56-byte record, every field from the compiled
/// transport plus the two join counts and the two checksums.
fn writeTran(
    dest: []u8,
    transport: *const TrackTable.Transport,
    host_len: usize,
    declared_len: usize,
    regs: []const u8,
    pacm: []const u8,
) void {
    const map = &transport.map;
    std.mem.writeInt(u64, dest[0..8], @bitCast(map.bpm), .little);
    std.mem.writeInt(i64, dest[8..16], map.beats_per_bar, .little);
    std.mem.writeInt(i64, dest[16..24], transport.dur orelse 0, .little);
    var flags: u8 = 0;
    if (transport.dur != null) flags |= Pacb.TRAN_FLAG_DUR;
    if (transport.end == .loop) flags |= Pacb.TRAN_FLAG_LOOP;
    dest[24] = flags;
    // dest[25..32] reserved zero (buffer pre-zeroed)
    std.mem.writeInt(u32, dest[32..36], @intCast(host_len), .little);
    std.mem.writeInt(u32, dest[36..40], @intCast(declared_len), .little);
    std.mem.writeInt(u64, dest[40..48], fnv1a64(regs), .little);
    std.mem.writeInt(u64, dest[48..56], fnv1a64(pacm), .little);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const t = std.testing;

/// Compile a fixture score against the test schema — the same
/// compiler-oracle seam `Pacb.zig`'s tests use.
fn compileForTest(
    alloc: std.mem.Allocator,
    source: [:0]const u8,
    host: []const Compile.Target,
) !Compile.CompileResult {
    const test_support = @import("test_support.zig");
    var r = try Compile.compile(alloc, test_support.schema(), source, host);
    if (!r.ok()) {
        r.deinit();
        return error.FixtureCompileFailed;
    }
    return r;
}

test "PacbEncode: a transport-only score round-trips through Pacb.decode" {
    const source: [:0]const u8 = "(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)";
    var r = try compileForTest(t.allocator, source, &.{});
    defer r.deinit();
    const want = &r.table.?.transport;

    const bytes = try encode(t.allocator, &r, &.{});
    defer t.allocator.free(bytes);

    // Canonical degenerate score: exactly 'TRAN' + 'PACM', contiguous,
    // exact end (parseDirectory is the structural judge).
    const dir = try Pacb.parseDirectory(bytes, null);
    try t.expectEqual(@as(u8, 2), dir.len);
    try t.expectEqual(Pacb.SectionKind.tran, dir.slice()[0].kind);
    try t.expectEqual(Pacb.SectionKind.pacm, dir.slice()[1].kind);

    // Pack twice: byte-equality (canonical assembly is deterministic).
    const again = try encode(t.allocator, &r, &.{});
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);

    var refusal: Pacb.Refusal = undefined;
    var score = try Pacb.decode(t.allocator, bytes, &refusal);
    defer score.deinit();

    // Transport parity, field-for-field (bit-equal floats).
    try t.expectEqual(@as(u32, 0), score.required_features);
    try t.expectEqual(
        @as(u64, @bitCast(want.map.bpm)),
        @as(u64, @bitCast(score.transport.map.bpm)),
    );
    try t.expectEqual(want.map.beats_per_bar, score.transport.map.beats_per_bar);
    try t.expectEqual(want.map.ticks_per_beat, score.transport.map.ticks_per_beat);
    try t.expectEqual(
        @as(u64, @bitCast(want.map.ticks_per_second)),
        @as(u64, @bitCast(score.transport.map.ticks_per_second)),
    );
    try t.expectEqual(want.dur, score.transport.dur);
    try t.expectEqual(want.end, score.transport.end);
    try t.expectEqual(
        @as(u64, @bitCast(want.loop_secs.?)),
        @as(u64, @bitCast(score.transport.loop_secs.?)),
    );

    // Registry identity: the empty host join's zero-count 'PACT'
    // spelling, checksummed by the public fnv1a64.
    try t.expectEqual(@as(usize, 0), score.declared.len);
    try t.expectEqual(fnv1a64(score.regs), score.pact_fnv);
    try t.expectEqual(@as(usize, PactCodec.TARGETS_HEADER_LEN), score.regs.len);

    // The embedded metadata is the real producer's own emission.
    const fresh = try t.allocator.alloc(u8, Abi.metaEncodedLen(&r));
    defer t.allocator.free(fresh);
    const fresh_pacm = try Abi.encodeMeta(&r, fresh);
    try t.expectEqualSlices(u8, fresh_pacm, score.pacm);
    try t.expectEqual(fnv1a64(fresh_pacm), score.pacm_fnv);
}

test "PacbEncode: a keys-only score round-trips with exact table parity" {
    const source: [:0]const u8 =
        \\(transport :bpm 132 :meter [3 4] :dur 4bar :end hold)
        \\(track :target circle-radius
        \\  (key :at 0b :value 10)
        \\  (key :at 2b :value 90))
    ;
    var r = try compileForTest(t.allocator, source, &fixture_host);
    defer r.deinit();
    const table = &r.table.?;

    const bytes = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(bytes);

    // Canonical section set for a keys-only score against a host join:
    // TRAN + REGS + TRAK + KEYS + PACM (linear-only easing ⇒ 'EASE'
    // omitted; no tempo map ⇒ 'TMPO' omitted; nothing else applies).
    const dir = try Pacb.parseDirectory(bytes, null);
    try t.expectEqual(@as(u8, 5), dir.len);
    const want_kinds = [_]Pacb.SectionKind{ .tran, .regs, .trak, .keys, .pacm };
    for (dir.slice(), want_kinds) |section, kind| {
        try t.expectEqual(kind, section.kind);
    }

    // Pack twice: byte-equality.
    const again = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);

    var score = try Pacb.decode(t.allocator, bytes, null);
    defer score.deinit();

    // Registry: the canonical 'PACT' of the ACTUAL host join.
    const regs = try t.allocator.alloc(u8, PactCodec.targetsEncodedLen(&fixture_host));
    defer t.allocator.free(regs);
    const canonical = try PactCodec.encodeTargets(&fixture_host, regs);
    try t.expectEqualSlices(u8, canonical, score.regs);
    try t.expectEqual(fnv1a64(canonical), score.pact_fnv);
    try t.expectEqual(@as(usize, 0), score.declared.len);

    // Table parity: tracks/keys/programs field-for-field.
    try t.expectEqual(table.tracks.len, score.tracks.len);
    for (table.tracks, score.tracks) |w, g| {
        try t.expectEqual(w.target_id, g.target_id);
        try t.expectEqual(w.registry, g.registry);
        try t.expectEqual(w.ncomp, g.ncomp);
        try t.expectEqual(w.scene, g.scene);
        const wks = w.source.keys;
        try t.expectEqual(wks.start, g.source.keys.start);
        try t.expectEqual(wks.len, g.source.keys.len);
    }
    try t.expectEqual(table.keys.len, score.keys.len);
    for (table.keys, score.keys) |w, g| {
        try t.expectEqual(w.at, g.at);
        try t.expectEqual(w.value, g.value);
        try t.expectEqual(w.ease_ref, g.ease_ref);
    }
    // Linear-only ⇒ the synthesized default program table.
    try t.expectEqual(@as(usize, 1), score.programs.len);
    try t.expect(std.meta.eql(table.programs[0], score.programs[0]));
    try t.expectEqual(@as(usize, 0), score.controls.len);
    try t.expectEqual(@as(usize, 0), score.scenes.len);
    try t.expectEqual(@as(usize, 0), score.transport.emit.len);
}

test "PacbEncode: an expr track's payload round-trips and evaluates identically" {
    const ExprTrack = @import("ExprTrack.zig");

    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
        \\(track :target circle-radius
        \\  (key :at 0b :value 10)
        \\  (key :at 2b :value 90))
        \\(track :target tint :expr [(+ 0.25 (* t 2)) 0 0])
    ;
    var r = try compileForTest(t.allocator, source, &fixture_host);
    defer r.deinit();
    const table = &r.table.?;

    const bytes = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(bytes);

    const dir = try Pacb.parseDirectory(bytes, null);
    try t.expectEqual(@as(u8, 6), dir.len);
    const want_kinds = [_]Pacb.SectionKind{ .tran, .regs, .trak, .keys, .payl, .pacm };
    for (dir.slice(), want_kinds) |section, kind| {
        try t.expectEqual(kind, section.kind);
    }

    const again = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);

    var score = try Pacb.decode(t.allocator, bytes, null);
    defer score.deinit();

    try t.expectEqual(table.tracks.len, score.tracks.len);
    var expr_idx: usize = 0;
    for (table.tracks, score.tracks, 0..) |w, g, i| {
        try t.expectEqual(w.target_id, g.target_id);
        try t.expectEqual(w.registry, g.registry);
        try t.expectEqual(w.ncomp, g.ncomp);
        if (w.source == .expr) {
            expr_idx = i;
            try t.expect(g.source == .expr);
        }
    }

    // The payload is the frozen compact encoding of the expr subtree —
    // byte-equal to the standalone-parse oracle (A29: cloneNode into a
    // one-root tree + toBinary(.compact)).
    var oracle_tree = try sjon.parse(t.allocator, "[(+ 0.25 (* t 2)) 0 0]");
    defer oracle_tree.deinit();
    const oracle = try sjon.Binary.toBinary(
        t.allocator,
        oracle_tree,
        sjon.Binary.ToBinaryOptions.forMode(.compact),
    );
    defer oracle.deinit();
    try t.expectEqualSlices(u8, oracle.data, score.tracks[expr_idx].source.expr);

    // Payload evaluation == text-path evaluation at tick 0, same env
    // (no controls in this score; the decoded transport builds it).
    const want_vec = try ExprTrack.evalAt(
        t.allocator,
        &r.validated.result.tree,
        r.eval_schema,
        &table.transport,
        &.{},
        table.tracks[expr_idx].source.expr,
        0,
        null,
        table.tracks[expr_idx].ncomp,
    );
    try t.expectEqual([4]f32{ 0.25, 0, 0, 0 }, want_vec);
    var storage: ExprTrack.EnvStorage = undefined;
    const env = ExprTrack.buildEnv(&storage, &score.transport, &.{}, 0, null);
    var bres = try sjon.Expr.evalBinary(
        t.allocator,
        score.tracks[expr_idx].source.expr,
        env,
        r.eval_schema,
    );
    defer bres.deinit();
    try t.expect(bres.value == .vector);
    try t.expectEqual(@as(usize, 3), bres.value.vector.len);
    var got_vec: [4]f32 = .{ 0, 0, 0, 0 };
    // Same widening as the text path's `coerce` (`toF64` + f32 cast):
    // integer-tagged literals ride `.integer_i64`, not `.number`.
    for (bres.value.vector, 0..) |v, i| {
        got_vec[i] = @as(f32, @floatCast(v.toF64() orelse return error.UnexpectedValue));
    }
    try t.expectEqual(want_vec, got_vec);
}

test "PacbEncode: trigger/scene/control/emit sections round-trip exactly" {
    const source: [:0]const u8 =
        \\(transport :bpm 96 :meter [4 4] :emit [beat phase])
        \\(scene :name drop :at 1bar :dur 2bar
        \\  (track :target circle-radius
        \\    (key :at 0b :value 5)
        \\    (key :at 1b :value 6)))
        \\(trigger :target boom :at [1b 2b 4b])
        \\(trigger :target click :every 1b)
        \\(control :id knob :target circle-radius :min 0 :max 1 :value 0.4)
        \\(control :id sway :value 0.12)
    ;
    var r = try compileForTest(t.allocator, source, &fixture_host);
    defer r.deinit();
    const table = &r.table.?;

    const bytes = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(bytes);

    const dir = try Pacb.parseDirectory(bytes, null);
    try t.expectEqual(@as(u8, 10), dir.len);
    const want_kinds = [_]Pacb.SectionKind{
        .tran, .regs, .emit, .trak, .keys, .tick, .ctrl, .scen, .strs, .pacm,
    };
    for (dir.slice(), want_kinds) |section, kind| {
        try t.expectEqual(kind, section.kind);
    }

    const again = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);

    var score = try Pacb.decode(t.allocator, bytes, null);
    defer score.deinit();

    // Emit lanes: document order, joined ids.
    try t.expectEqual(table.transport.emit.len, score.transport.emit.len);
    for (table.transport.emit, score.transport.emit) |w, g| {
        try t.expectEqual(w.name, g.name);
        try t.expectEqual(w.target_id, g.target_id);
        try t.expectEqual(w.registry, g.registry);
    }

    // Tracks: the scene's keys child (absolute positions), the explicit
    // trigger, the periodic trigger — in compile's record order.
    try t.expectEqual(table.tracks.len, score.tracks.len);
    for (table.tracks, score.tracks) |w, g| {
        try t.expectEqual(w.target_id, g.target_id);
        try t.expectEqual(w.registry, g.registry);
        try t.expectEqual(w.ncomp, g.ncomp);
        try t.expectEqual(w.scene, g.scene);
        switch (w.source) {
            .keys => |wks| {
                try t.expectEqual(wks.start, g.source.keys.start);
                try t.expectEqual(wks.len, g.source.keys.len);
            },
            .trigger => |wtrig| switch (wtrig) {
                .periodic => |wp| {
                    try t.expectEqual(wp.every, g.source.trigger.periodic.every);
                    try t.expectEqual(wp.offset, g.source.trigger.periodic.offset);
                },
                .at => |wats| try t.expectEqualSlices(i64, wats, g.source.trigger.at),
            },
            .expr, .pattern => return error.UnexpectedSource,
        }
    }

    // Scenes: the window fields (the name span stays text-side).
    try t.expectEqual(table.scenes.len, score.scenes.len);
    for (table.scenes, score.scenes) |w, g| {
        try t.expectEqual(w.start_tick, g.start_tick);
        try t.expectEqual(w.dur_ticks, g.dur_ticks);
    }

    // Controls: identity, target join, widget kind, value/range lanes.
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
}

test "PacbEncode: tempo map and ease table slice verbatim out of the PACM pass" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
        \\(tempo :at 4b :bpm 160)
        \\(track :target circle-radius
        \\  (key :at 0b :value 30)
        \\  (key :at 2b :value 140 :ease (steps :n 8)))
        \\(track :target tint :expr [1 0 0])
    ;
    var r = try compileForTest(t.allocator, source, &fixture_host);
    defer r.deinit();
    const table = &r.table.?;

    const bytes = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(bytes);

    const dir = try Pacb.parseDirectory(bytes, null);
    try t.expectEqual(@as(u8, 8), dir.len);
    const want_kinds = [_]Pacb.SectionKind{
        .tran, .regs, .tmpo, .trak, .keys, .ease, .payl, .pacm,
    };
    for (dir.slice(), want_kinds) |section, kind| {
        try t.expectEqual(kind, section.kind);
    }

    const again = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);

    var score = try Pacb.decode(t.allocator, bytes, null);
    defer score.deinit();

    // Segments: the authored tempo table, segment 0 included.
    try t.expectEqual(table.transport.segments.len, score.transport.segments.len);
    for (table.transport.segments, score.transport.segments) |w, g| {
        try t.expectEqual(w.start_tick, g.start_tick);
        try t.expectEqual(@as(u64, @bitCast(w.bpm)), @as(u64, @bitCast(g.bpm)));
    }
    try t.expectEqual(@as(usize, 2), score.transport.segments.len);

    // Programs: the deduped table (linear default + the steps program).
    try t.expectEqual(table.programs.len, score.programs.len);
    try t.expectEqual(@as(usize, 2), score.programs.len);
    for (table.programs, score.programs) |*w, *g| {
        try t.expect(std.meta.eql(w.*, g.*));
    }

    // The frozen rule, pinned on the wire: the 'EASE'/'TMPO' sections
    // ARE the embedded PACM's own TLV payloads — one producer pass,
    // sliced verbatim (no re-encoding).
    const view = Pacm.decode(score.pacm) orelse return error.MetaUndecodable;
    const ease_sec = dir.find(.ease).?;
    try t.expectEqualSlices(
        u8,
        view.ease.?,
        bytes[ease_sec.off..][0..ease_sec.len],
    );
    const tmpo_sec = dir.find(.tmpo).?;
    try t.expectEqualSlices(
        u8,
        view.tmpo.?,
        bytes[tmpo_sec.off..][0..tmpo_sec.len],
    );

    // Keys still carry their ease refs into the program table.
    for (table.keys, score.keys) |w, g| {
        try t.expectEqual(w.at, g.at);
        try t.expectEqual(w.value, g.value);
        try t.expectEqual(w.ease_ref, g.ease_ref);
    }
    try t.expectEqual(@as(u16, 1), score.keys[1].ease_ref);
}

test "PacbEncode: a pattern track sets the feature bit and serializes its payload" {
    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop)
        \\(track :target circle-radius :pattern (euclid 3 8 0.9))
    ;
    var r = try compileForTest(t.allocator, source, &fixture_host);
    defer r.deinit();
    const table = &r.table.?;

    const bytes = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(bytes);

    const dir = try Pacb.parseDirectory(bytes, null);
    try t.expectEqual(@as(u8, 5), dir.len);
    const want_kinds = [_]Pacb.SectionKind{ .tran, .regs, .trak, .payl, .pacm };
    for (dir.slice(), want_kinds) |section, kind| {
        try t.expectEqual(kind, section.kind);
    }

    // The header's own feature word, before any decode.
    try t.expectEqual(Pacb.FEATURE_PATTERN_TRACKS, std.mem.readInt(u32, bytes[8..12], .little));

    const again = try encode(t.allocator, &r, &fixture_host);
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);

    // Structural round-trip ONLY: the payload is the frozen compact
    // encoding of the pattern subtree and decode consumes it. No
    // pattern EVALUATION parity is claimed here — pattern evaluation is
    // not yet a capability of this producer (T3.2 preflight refuses the
    // score loudly; the SJON-side env lands with the runtime wave).
    var oracle_tree = try sjon.parse(t.allocator, "(euclid 3 8 0.9)");
    defer oracle_tree.deinit();
    const oracle = try sjon.Binary.toBinary(
        t.allocator,
        oracle_tree,
        sjon.Binary.ToBinaryOptions.forMode(.compact),
    );
    defer oracle.deinit();

    var score = try Pacb.decode(t.allocator, bytes, null);
    defer score.deinit();
    try t.expectEqual(Pacb.FEATURE_PATTERN_TRACKS, score.required_features);
    try t.expectEqual(table.tracks.len, score.tracks.len);
    try t.expect(score.tracks[0].source == .pattern);
    try t.expectEqualSlices(u8, oracle.data, score.tracks[0].source.pattern);
}

test "PacbEncode: declared targets form the 'DECL' tail of an empty host join" {
    const source: [:0]const u8 =
        \\(transport :bpm 108 :meter [4 4] :dur 4bar :end loop)
        \\(target :name circle-radius :arity 1)
        \\(target :name boom :arity 1 :registry 2)
        \\(track :target circle-radius
        \\  (key :at 0b :value 1)
        \\  (key :at 2b :value 2))
        \\(trigger :target boom :at [1b])
    ;
    var r = try compileForTest(t.allocator, source, &.{});
    defer r.deinit();
    const table = &r.table.?;

    const bytes = try encode(t.allocator, &r, &.{});
    defer t.allocator.free(bytes);

    const dir = try Pacb.parseDirectory(bytes, null);
    try t.expectEqual(@as(u8, 6), dir.len);
    // No 'REGS': the host join is empty — the identity is the zero-count
    // 'PACT' spelling, checksummed in 'TRAN'.
    const want_kinds = [_]Pacb.SectionKind{ .tran, .decl, .trak, .keys, .tick, .pacm };
    for (dir.slice(), want_kinds) |section, kind| {
        try t.expectEqual(kind, section.kind);
    }

    const again = try encode(t.allocator, &r, &.{});
    defer t.allocator.free(again);
    try t.expectEqualSlices(u8, bytes, again);

    var score = try Pacb.decode(t.allocator, bytes, null);
    defer score.deinit();

    // The merged join's declared tail, in declaration order.
    try t.expectEqual(@as(usize, 2), score.declared.len);
    try t.expectEqual(Pacb.Decl{ .registry = 0, .ncomp = 1 }, score.declared[0]);
    try t.expectEqual(Pacb.Decl{ .registry = 2, .ncomp = 1 }, score.declared[1]);
    try t.expectEqual(@as(usize, PactCodec.TARGETS_HEADER_LEN), score.regs.len);

    // Target ids address the merged join: host prefix (empty) + declared.
    try t.expectEqual(table.tracks.len, score.tracks.len);
    for (table.tracks, score.tracks) |w, g| {
        try t.expectEqual(w.target_id, g.target_id);
        try t.expectEqual(w.registry, g.registry);
        try t.expectEqual(w.ncomp, g.ncomp);
    }
    try t.expectEqual(@as(u16, 0), score.tracks[0].target_id);
    try t.expectEqual(@as(u16, 1), score.tracks[1].target_id);
    try t.expectEqual(@as(u8, 2), score.tracks[1].registry);

    // Host-declared MIX: the host prefix is preserved verbatim and the
    // declared tail appends after it (A22).
    {
        const mixed = [_]Compile.Target{.{ .name = "circle-radius", .ncomp = 1 }};
        const bytes2 = try encode(t.allocator, &r, &mixed);
        defer t.allocator.free(bytes2);
        var score2 = try Pacb.decode(t.allocator, bytes2, null);
        defer score2.deinit();
        try t.expectEqual(@as(usize, 1), score2.declared.len);
        // circle-radius is host-provided (arity agreed) — NOT re-declared;
        // only boom appends.
        try t.expectEqual(Pacb.Decl{ .registry = 2, .ncomp = 1 }, score2.declared[0]);
        const regs2 = try t.allocator.alloc(u8, PactCodec.targetsEncodedLen(&mixed));
        defer t.allocator.free(regs2);
        const canonical2 = try PactCodec.encodeTargets(&mixed, regs2);
        try t.expectEqualSlices(u8, canonical2, score2.regs);
        // The ids still address the same names: circle-radius stays 0
        // (host-provided, join slot 0), boom stays 1 (declared slot).
        try t.expectEqual(@as(u16, 0), score2.tracks[0].target_id);
        try t.expectEqual(@as(u16, 1), score2.tracks[1].target_id);
    }
}

test "PacbEncode: wire pins — header literals and the zero-pad discipline" {
    const source: [:0]const u8 =
        \\(transport :bpm 100 :meter [4 4] :dur 4bar :emit [beat])
        \\(target :name solo :arity 2)
        \\(target :name beat :arity 1)
        \\(track :target solo
        \\  (key :at 0b :value [1 2])
        \\  (key :at 1b :value [3 4]))
        \\(trigger :target solo :at [2b])
        \\(control :id level :value 0.5)
    ;
    var r = try compileForTest(t.allocator, source, &.{});
    defer r.deinit();

    const bytes = try encode(t.allocator, &r, &.{});
    defer t.allocator.free(bytes);

    const dir = try Pacb.parseDirectory(bytes, null);

    // Header literals: magic 'PACB', VERSION 1, no feature bits, and the
    // count this score must spell (8 present sections).
    try t.expectEqualSlices(u8, &.{ 0x50, 0x41, 0x43, 0x42 }, bytes[0..4]);
    try t.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, bytes[4..8]);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, bytes[8..12]);
    try t.expectEqual(@as(u8, 9), dir.len);
    try t.expectEqual(@as(u32, 16 + 9 * 12), dir.slice()[0].off);

    // 'TRAN' reserved bytes are zero.
    const tran = dir.find(.tran).?;
    try t.expect(allZero(bytes[tran.off + 25 ..][0..7]));

    // 'DECL': two records in declaration order (solo, beat), pads zero.
    const decl = dir.find(.decl).?;
    try t.expectEqual(@as(u32, 12), decl.len);
    try t.expectEqual(@as(u8, 0), bytes[decl.off + 4]); // solo registry
    try t.expectEqual(@as(u8, 2), bytes[decl.off + 5]); // solo ncomp
    try t.expect(allZero(bytes[decl.off + 6 ..][0..2]));
    try t.expectEqual(@as(u8, 1), bytes[decl.off + 9]); // beat ncomp
    try t.expect(allZero(bytes[decl.off + 10 ..][0..2]));

    // 'EMIT': one lane, reserved u32 zero.
    const emit = dir.find(.emit).?;
    try t.expectEqual(@as(u8, 0), bytes[emit.off + 4]); // beat ordinal
    try t.expect(allZero(bytes[emit.off + 8 ..][0..4]));

    // 'TRAK': the keys track's unused-by-source fields are all zero
    // (trig_every/offset + payload span), record 0 at +4.
    const trak = dir.find(.trak).?;
    try t.expectEqual(@as(u8, Pacb.SOURCE_KEYS), bytes[trak.off + 4]);
    try t.expect(allZero(bytes[trak.off + 4 + 16 ..][0..24]));
    // The explicit trigger (record 1): payload span and both trigger
    // timing fields unused ⇒ zero.
    const trig_at = trak.off + 4 + Pacb.TRAK_REC_LEN;
    try t.expectEqual(@as(u8, Pacb.SOURCE_TRIGGER), bytes[trig_at + 4]);
    try t.expect(allZero(bytes[trig_at + 16 ..][0..24]));

    // 'KEYS': pad u16 zero on every record.
    const keys = dir.find(.keys).?;
    const key_count = std.mem.readInt(u32, bytes[keys.off..][0..4], .little);
    try t.expectEqual(@as(u32, 2), key_count);
    var i: usize = 0;
    while (i < key_count) : (i += 1) {
        const at = keys.off + 4 + i * Pacb.KEYS_REC_LEN;
        try t.expect(allZero(bytes[at + 26 ..][0..2]));
    }

    // 'CTRL': env-only control — target sentinel, registry zero, and the
    // un-flagged min/max lanes byte-zero.
    const ctrl = dir.find(.ctrl).?;
    try t.expectEqual(@as(u16, TrackTable.NO_TARGET), std.mem.readInt(u16, bytes[ctrl.off + 4 ..][0..2], .little));
    try t.expectEqual(@as(u8, 0), bytes[ctrl.off + 4 + 2]);
    try t.expectEqual(@as(u8, 0), bytes[ctrl.off + 4 + 5]); // flags: no min/max
    try t.expect(allZero(bytes[ctrl.off + 4 + 28 ..][0..32]));
}

fn allZero(slice: []const u8) bool {
    return std.mem.allEqual(u8, slice, 0);
}

test "PacbEncode: fnv1a64 known answers (FNV-1a-64 test vectors)" {
    // The published FNV-1a-64 vectors: empty string = offset basis,
    // "a", "foobar". Pinning them keeps 'TRAN''s checksum family
    // anchored to the standard hash the decoder shares.
    try t.expectEqual(@as(u64, 0xcbf29ce484222325), fnv1a64(""));
    try t.expectEqual(@as(u64, 0xaf63dc4c8601ec8c), fnv1a64("a"));
    try t.expectEqual(@as(u64, 0x85944171f73967e8), fnv1a64("foobar"));
}

/// Host join used by the table fixtures.
const fixture_host = [_]Compile.Target{
    .{ .name = "circle-radius", .ncomp = 1 },
    .{ .name = "tint", .ncomp = 3 },
    .{ .name = "boom", .ncomp = 1 },
    .{ .name = "click", .ncomp = 1 },
    .{ .name = "beat", .ncomp = 1 },
    .{ .name = "phase", .ncomp = 1 },
};
