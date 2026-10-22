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
//! `result.ok()` is a PRECONDITION (`Abi.encodeMeta` asserts the same).
//! The v1 resource gates live in `preflight` below — `encode` produces
//! whatever the table spells. DIRECT-API callers who skip `preflight`
//! accept its documented preconditions: the caps (per-payload, total
//! `'PAYL'`, global explicit ticks, and the compact-IR payload writer's
//! structural caps — node count, distinct string pool, string length,
//! depth, all MEASURED by `preflight` against the frozen `sjon.Binary`
//! constants) hold, so every section fits its u32 directory fields and
//! the payload writer's cap arms cannot fire; a pathological ≤ 256 MiB
//! source that grows one past 4 GiB is preflight territory, never a
//! silent wrap (T3.1's flag, recorded here — final-review L1 extended
//! the precondition from the three byte/count caps to the writer's
//! structural caps, which a legal native-band source CAN exceed).
//!
//! Imports `Compile`, `Abi`, `Pacb`, `Pacm`, `PactCodec`, `TrackTable`
//! (the plan-frozen set plus the two T3.1-recorded std/shared leaves —
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
/// canonical `'PACB'` buffer. PRECONDITIONS: `result.ok()`, and (for a
/// v1-legal pack) `preflight` reported no refusals — `encode` emits the
/// caps-unchecked spelling of whatever the table holds, so a direct-API
/// caller who skips `preflight` owns the preconditions the module
/// header spells (byte caps, tick cap, and the compact-IR payload
/// writer's measured structural caps); `host_targets` is the same host
/// registry list the score was compiled against (the merged join's
/// prefix, `CompileResult.targets`).
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
    // table's own AST. A `PayloadWriterCap` here is `unreachable` under
    // `encode`'s documented precondition (the module header's
    // direct-API note): v1-legal packs ran `preflight`, which MEASURES
    // these caps and refuses the score first; the CLI always does.
    const payload_bytes = try a.alloc([]const u8, table.tracks.len);
    for (payload_bytes) |*slot| slot.* = &.{};
    var has_payload_track = false;
    var payload_total: usize = 0;
    for (table.tracks, 0..) |track, i| switch (track.source) {
        .expr => |node| {
            const bytes = encodePayload(a, &result.validated.result.tree, node) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PayloadWriterCap => unreachable,
            };
            payload_bytes[i] = bytes;
            payload_spans[i] = .{ .off = payload_total, .len = bytes.len };
            payload_total += bytes.len;
            has_payload_track = true;
        },
        .pattern => |node| {
            const bytes = encodePayload(a, &result.validated.result.tree, node) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.PayloadWriterCap => unreachable,
            };
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

/// What `sjon.Binary.toBinary` itself caps on the encode side, measured
/// over the payload subtree the writer will actually walk. `nodes` is
/// the cloned one-root tree's node count (dominating every per-container
/// child cap), `pool_entries` its DISTINCT interned strings (the writer's
/// `PoolBuilder` dedupes the same way the clone re-interns, so the tree's
/// pool IS the writer's), `max_string` the longest pool entry, `depth`
/// the nesting the writer's depth-bounded walkers descend.
const PayloadProfile = struct {
    nodes: usize,
    pool_entries: usize,
    max_string: usize,
    depth: u32,
};

/// The payload writer's structural-cap rejections surfaced for callers
/// that measure before they commit (`preflight`; the CLI's self-check
/// re-encode). NOT part of `Error` — the frozen public failure surface
/// stays `error{OutOfMemory}`; a v1-legal pack has already refused these
/// inputs at preflight with measured `pack_cap_exceeded` diagnostics.
pub const PayloadWriterCapError = error{PayloadWriterCap};

/// Measure one payload subtree's profile — the same clone the writer
/// encodes, read off its finalized tree (node count, pool size, longest
/// string, depth) without invoking the writer.
fn payloadProfile(
    a: std.mem.Allocator,
    tree: *const sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
) Error!PayloadProfile {
    // Same arena contract as `encodePayload`: the builder allocates
    // from the arena finalize snapshots, so `one_root.deinit` frees it.
    var tree_arena = std.heap.ArenaAllocator.init(a);
    defer tree_arena.deinit(); // no-op after finalize clears the slot
    var builder = sjon.Ast.TreeBuilder{ .a = tree_arena.allocator() };
    const root = try builder.cloneNode(tree, node);
    var one_root = try builder.finalize(&tree_arena, "", &.{root});
    defer one_root.deinit();

    var max_string: usize = 0;
    const n_strings = one_root.string_index.len - 1;
    for (0..n_strings) |i| {
        const len = one_root.string_index[i + 1] - one_root.string_index[i];
        if (len > max_string) max_string = len;
    }
    return .{
        .nodes = one_root.nodes.len,
        .pool_entries = n_strings,
        .max_string = max_string,
        .depth = try one_root.maxDepth(a),
    };
}

/// One measured structural refusal for a payload the writer rejected:
/// name the FIRST frozen cap the profile exceeds; if none does (a
/// writer arm the profile does not model — today only the output-size
/// cap, dominated by node/string counts for any ≤ 256 MiB source), say
/// so with the full measured profile rather than a wrong number.
fn addPayloadStructuralDiag(
    gpa: std.mem.Allocator,
    diags: *std.ArrayList(Compile.Diagnostic),
    span: sjon.Ast.Span,
    prof: PayloadProfile,
) Error!void {
    if (prof.nodes > sjon.Binary.MAX_NODES) {
        return addDiag(gpa, diags, .pack_cap_exceeded, span, "pack: payload holds {d} nodes, over the {d}-node v1 compact-IR cap", .{ prof.nodes, sjon.Binary.MAX_NODES });
    } else if (prof.pool_entries > sjon.Binary.MAX_STRING_POOL_ENTRIES) {
        return addDiag(gpa, diags, .pack_cap_exceeded, span, "pack: payload holds {d} distinct strings, over the {d}-entry v1 compact-IR pool cap", .{ prof.pool_entries, sjon.Binary.MAX_STRING_POOL_ENTRIES });
    } else if (prof.max_string > sjon.Binary.MAX_STRING_LENGTH) {
        return addDiag(gpa, diags, .pack_cap_exceeded, span, "pack: payload's longest string is {d} bytes, over the {d}-byte v1 compact-IR cap", .{ prof.max_string, sjon.Binary.MAX_STRING_LENGTH });
    } else if (prof.depth > sjon.Binary.MAX_TREE_DEPTH) {
        return addDiag(gpa, diags, .pack_cap_exceeded, span, "pack: payload nests {d} deep, over the {d}-level v1 compact-IR cap", .{ prof.depth, sjon.Binary.MAX_TREE_DEPTH });
    } else {
        return addDiag(gpa, diags, .pack_cap_exceeded, span, "pack: payload exceeds a v1 compact-IR writer cap (measured: {d} nodes, {d} distinct strings, longest {d} bytes, depth {d})", .{ prof.nodes, prof.pool_entries, prof.max_string, prof.depth });
    }
}

/// Serialize one expr/pattern value subtree: `cloneNode` into a fresh
/// one-root tree, then the frozen compact binary encoding (A29 — no
/// spans, no comments; the smallest deterministic spelling). The source
/// string is unused (strings re-intern into the clone; compact drops
/// spans), so the one-root tree finalizes against "".
///
/// BOUNDED: `toBinary`'s non-OOM rejections (node count, distinct pool
/// entries, string length, depth — `MAX_*` in `sjon.Binary`) surface as
/// `error.PayloadWriterCap` for `preflight` to measure and refuse, and
/// for the self-check to treat as an internal invariant break. A legal
/// native-band source CAN build a payload over the 65536-entry pool
/// (one quoted string per ~7 source bytes), so this is reachable data
/// about the score, not a producer-impossible arm.
pub fn encodePayload(
    a: std.mem.Allocator,
    tree: *const sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
) (Error || PayloadWriterCapError)![]const u8 {
    // The builder MUST allocate from the arena `finalize` snapshots
    // into the tree: `Tree.deinit` frees that arena alone, so a builder
    // on the raw `a` would strand its nodes/strings (a leak the
    // self-check's payload re-encode exposed under the test GPA).
    var tree_arena = std.heap.ArenaAllocator.init(a);
    defer tree_arena.deinit(); // no-op after finalize clears the slot
    var builder = sjon.Ast.TreeBuilder{ .a = tree_arena.allocator() };
    const root = try builder.cloneNode(tree, node);
    var one_root = try builder.finalize(&tree_arena, "", &.{root});
    defer one_root.deinit();
    const bin = sjon.Binary.toBinary(
        a,
        one_root,
        sjon.Binary.ToBinaryOptions.forMode(.compact),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PayloadWriterCap,
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
// Pack preflight (T3.2) — head-walk position classifier + caps
// ---------------------------------------------------------------------------

/// The frozen core-only schema every decoded `'PACB'` evaluates
/// against: exactly the `core` plugin (A35 — the same comptime
/// precedent as `ExprTrack`'s core schema; `init` runs the form-key cap
/// asserts once at load).
const binary_core_plugins = [_]sjon.Plugin.Plugin{sjon.plugins.core.plugin};
const binary_core_schema: sjon.Schema.Schema =
    sjon.Schema.Schema.init(&binary_core_plugins);

comptime {
    // A33 membership pin: the classifier's special-form catalog IS
    // `isCoreSpecialForm`'s ten. If SJON's catalog moves, this pin
    // breaks the build here (the classifier's name dispatch below must
    // be re-reviewed) instead of silently diverging — risk E1's guard.
    const ten = [_][]const u8{ "let", "if", "cond", "and", "or", "map", "filter", "any", "all", "fold" };
    for (ten) |h| std.debug.assert(sjon.Expr.isCoreSpecialForm(h, null));
    // Qualified heads are never special forms (the scheduler's own
    // rule — a namespace disqualifies), and the binary schema resolves
    // core's impl-null special-form markers exactly like the text path.
    std.debug.assert(!sjon.Expr.isCoreSpecialForm("let", "core"));
}

/// One eval-position call head: the classifier's output. `head` /
/// `namespace` borrow the tree's string pool; `span` is the head
/// symbol's own span in score coordinates (the diagnostic anchor).
pub const HeadRef = struct {
    head: []const u8,
    namespace: ?[]const u8,
    span: sjon.Ast.Span,
};

/// Collect every CALL head in `node`'s eval positions: each form the
/// SJON evaluator would visit — root, vector elements, special-form
/// value positions, call arguments, kvpair VALUES (never keys) —
/// contributes its head, in source order. Name positions (let binding
/// names, binder vectors, kvpair keys) are never collected, and a
/// special form whose shape the scheduler would reject at schedule
/// time contributes nothing at all (the scheduler aborts before any
/// child is scheduled — the subtree is dead on both paths). Mirrors
/// `scheduleForm`/`scheduleFormBinary` shapes A31/A32; iterative, so
/// walk depth is heap-bound like the evaluator's own frame machine.
pub fn collectCallHeads(
    gpa: std.mem.Allocator,
    tree: *const sjon.Ast.Tree,
    node: sjon.Ast.NodeIndex,
) Error![]HeadRef {
    var heads: std.ArrayList(HeadRef) = .empty;
    errdefer heads.deinit(gpa);
    var work: std.ArrayList(sjon.Ast.NodeIndex) = .empty;
    defer work.deinit(gpa);
    try work.append(gpa, node);
    while (work.pop()) |idx| {
        switch (tree.tagOf(idx)) {
            .form => try walkForm(gpa, tree, idx, &heads, &work),
            .vector => {
                const elems = tree.vectorElements(idx);
                var i = elems.len;
                while (i > 0) {
                    i -= 1;
                    try work.append(gpa, elems[i]);
                }
            },
            // Every other tag is a leaf. A `.kvpair` never reaches the
            // stack as a value: each push site skips kvpair slots
            // (eval of a kvpair raises before anything inside it runs
            // — a dead slot, mirrored from the scheduler).
            else => {},
        }
    }
    return heads.toOwnedSlice(gpa);
}

fn walkForm(
    gpa: std.mem.Allocator,
    tree: *const sjon.Ast.Tree,
    idx: sjon.Ast.NodeIndex,
    heads: *std.ArrayList(HeadRef),
    work: *std.ArrayList(sjon.Ast.NodeIndex),
) Error!void {
    const hdr = tree.formHeader(idx);
    if (hdr.namespace == null and sjon.Expr.isCoreSpecialForm(hdr.head, null)) {
        try pushSpecialFormPositions(gpa, tree, hdr, work);
        return;
    }
    // Call (or form-as-data) position: the head IS the classified
    // thing. Head-shape pin: on a validated tree every form head is
    // symbolic text — number/string/keyword heads are parse
    // diagnostics and `true`/`false`/`nil` literal heads survive as
    // text that resolves not_found in both schemas (form-as-data,
    // packs clean). The classifier never re-checks head kinds (G13).
    try heads.append(gpa, .{
        .head = hdr.head,
        .namespace = hdr.namespace,
        .span = hdr.head_span,
    });
    // Argument positions: positional children and kvpair VALUES, in
    // source order — exactly what `scheduleForm`'s child walks (the
    // resolved-arg path and `scheduleFormCollect`'s form-as-data path
    // share) would evaluate.
    var i = hdr.children.len;
    while (i > 0) {
        i -= 1;
        const child = hdr.children[i];
        if (tree.tagOf(child) == .kvpair) {
            try work.append(gpa, tree.kvpairHeader(child).value);
        } else {
            try work.append(gpa, child);
        }
    }
}

/// Push the eval-position children of one special form (source order —
/// the LIFO work stack pops what was pushed last, so children are
/// pushed reversed). Returns having pushed NOTHING when the form's
/// shape is one the scheduler rejects at schedule time: those checks
/// precede all child scheduling, so the subtree is dead on both paths
/// and contributes neither heads nor positions.
fn pushSpecialFormPositions(
    gpa: std.mem.Allocator,
    tree: *const sjon.Ast.Tree,
    hdr: sjon.Ast.FormHeader,
    work: *std.ArrayList(sjon.Ast.NodeIndex),
) Error!void {
    const kids = hdr.children;
    if (std.mem.eql(u8, hdr.head, "let")) {
        if (kids.len != 2) return; // ArityMismatch
        if (tree.tagOf(kids[0]) != .vector) return; // InvalidLetBinding
        const binds = tree.vectorElements(kids[0]);
        if (binds.len % 2 != 0) return; // InvalidLetBinding
        if (tree.tagOf(kids[1]) == .kvpair) return; // InvalidLetBinding
        // Name slots are symbols — checked for EVERY pair at schedule
        // time, before any value evaluates (the schedule loop runs to
        // completion or aborts the whole form).
        for (0..binds.len / 2) |p| {
            if (tree.tagOf(binds[2 * p]) != .symbol) return;
        }
        // Binding values: all walked, then the body. No kvpair cut is
        // needed here — kvpairs exist only as FORM children, never
        // inside a vector (the parser's rule), so a binding value can
        // never be one; a keyword value (`:k`) evaluates to itself.
        try work.append(gpa, kids[1]); // body pops last
        var p = binds.len / 2;
        while (p > 0) {
            p -= 1;
            try work.append(gpa, binds[2 * p + 1]);
        }
        return;
    }
    if (std.mem.eql(u8, hdr.head, "if")) {
        if (kids.len < 2 or kids.len > 3) return; // ArityMismatch
        for (kids) |child| {
            if (tree.tagOf(child) == .kvpair) return; // KeywordInExpressionArgs
        }
        var i = kids.len;
        while (i > 0) {
            i -= 1;
            try work.append(gpa, kids[i]);
        }
        return;
    }
    if (std.mem.eql(u8, hdr.head, "cond")) {
        if (kids.len % 2 != 0) return; // InvalidCondClause
        if (kids.len == 0) return; // literal nil — nothing scheduled
        // The scheduler checks the FIRST clause's two slots up front.
        if (tree.tagOf(kids[0]) == .kvpair) return;
        if (tree.tagOf(kids[1]) == .kvpair) return;
        // Later clauses are validated lazily as `cond_select` reaches
        // them, BOTH slots at once: a kvpair in either slot errors
        // before the clause's test evaluates, killing every later
        // clause too. Walk clauses until the first such cut.
        var live = kids.len;
        var c: usize = 1;
        while (c < kids.len / 2) : (c += 1) {
            if (tree.tagOf(kids[2 * c]) == .kvpair or
                tree.tagOf(kids[2 * c + 1]) == .kvpair)
            {
                live = 2 * c;
                break;
            }
        }
        var i = live;
        while (i > 0) {
            i -= 1;
            try work.append(gpa, kids[i]);
        }
        return;
    }
    if (std.mem.eql(u8, hdr.head, "and") or std.mem.eql(u8, hdr.head, "or")) {
        if (kids.len == 0) return; // literal true/false — nothing scheduled
        if (tree.tagOf(kids[0]) == .kvpair) return; // checked at schedule
        // The tail is validated lazily one element at a time: the first
        // kvpair reached errors before it evaluates, killing every
        // element after it. Walk until that cut.
        var live = kids.len;
        for (1..kids.len) |i| {
            if (tree.tagOf(kids[i]) == .kvpair) {
                live = i;
                break;
            }
        }
        var i = live;
        while (i > 0) {
            i -= 1;
            try work.append(gpa, kids[i]);
        }
        return;
    }
    if (std.mem.eql(u8, hdr.head, "map") or std.mem.eql(u8, hdr.head, "filter") or
        std.mem.eql(u8, hdr.head, "any") or std.mem.eql(u8, hdr.head, "all"))
    {
        if (kids.len != 3) return; // ArityMismatch
        // Binder vector: a syntactic, never-evaluated one-symbol vector.
        if (tree.tagOf(kids[0]) != .vector) return; // InvalidBinderShape
        const binder = tree.vectorElements(kids[0]);
        if (binder.len != 1) return;
        if (tree.tagOf(binder[0]) != .symbol) return;
        if (tree.tagOf(kids[1]) == .kvpair) return; // xs slot
        if (tree.tagOf(kids[2]) == .kvpair) return; // body slot
        try work.append(gpa, kids[2]); // body pops last
        try work.append(gpa, kids[1]);
        return;
    }
    if (std.mem.eql(u8, hdr.head, "fold")) {
        if (kids.len != 4) return; // ArityMismatch
        if (tree.tagOf(kids[0]) != .vector) return; // InvalidBinderShape
        const binder = tree.vectorElements(kids[0]);
        if (binder.len != 2) return;
        if (tree.tagOf(binder[0]) != .symbol) return;
        if (tree.tagOf(binder[1]) != .symbol) return;
        if (std.mem.eql(u8, tree.stringSlice(@enumFromInt(tree.dataOf(binder[0]).single)), tree.stringSlice(@enumFromInt(tree.dataOf(binder[1]).single)))) return; // [acc acc]
        for (kids[1..]) |child| {
            if (tree.tagOf(child) == .kvpair) return;
        }
        try work.append(gpa, kids[3]); // body
        try work.append(gpa, kids[2]); // xs
        try work.append(gpa, kids[1]); // init pops first
        return;
    }
    // An `isCoreSpecialForm` member outside the ten-name dispatch: the
    // catalog grew upstream (the comptime pin above held when this was
    // written). Its head is not a call; its positions are unknown —
    // walk every child as a value (kvpair values, never keys), the
    // conservative over-walk: over-collecting can only refuse louder,
    // never emit a payload the binary path evaluates differently.
    var i = kids.len;
    while (i > 0) {
        i -= 1;
        const child = kids[i];
        if (tree.tagOf(child) == .kvpair) {
            try work.append(gpa, tree.kvpairHeader(child).value);
        } else {
            try work.append(gpa, child);
        }
    }
}

/// One pack-refusal reason for a collected head — the full-outcome
/// compare between the eval schema and the core-only binary schema
/// (I1/G11: pack-clean iff BOTH schemas resolve the head to the SAME
/// (plugin, func) identity; anything else refuses).
const HeadVerdict = union(enum) {
    /// Identical resolution (or form-as-data: not-found in both).
    clean,
    /// `.found` through `eval_schema` in a plugin the binary schema
    /// does not carry (or under a different identity) — carries the
    /// eval-side plugin name for the message.
    user_plugin: []const u8,
    /// `.ambiguous` through `eval_schema` — a user plugin redeclaring
    /// a core name makes the bare head error on BOTH text paths, so
    /// binary-found does not make the outcomes identical.
    ambiguous,
    /// Resolves on the binary path but NOT on the eval path — the two
    /// schemas disagree in the other direction (structurally
    /// unreachable today: the binary schema's single core plugin is
    /// `eval_schema`'s head; kept so the compare stays full-outcome).
    binary_only,
};

/// Resolve one collected head through both schemas and compare the
/// FULL outcomes. Plugin identity is (name, func-pointer): the core
/// plugin rides both schemas as copies of the same declaration, so its
/// `expr_funcs` entries share one static array — equal pointers ARE
/// the same function.
fn classifyHead(eval_schema: sjon.Schema.Schema, h: HeadRef) HeadVerdict {
    const ev = eval_schema.lookupExprFunc(h.head, h.namespace);
    const bin = binary_core_schema.lookupExprFunc(h.head, h.namespace);
    switch (ev) {
        .not_found => switch (bin) {
            .not_found => return .clean, // form-as-data literal (A37)
            else => return .binary_only,
        },
        .ambiguous => return .ambiguous,
        .found => |eh| switch (bin) {
            // The binary schema holds exactly one plugin, so its bare
            // lookup cannot collide; the arm exists for exhaustiveness
            // and refuses conservatively if that ever changes.
            .ambiguous => return .{ .user_plugin = eh.plugin.name },
            .not_found => return .{ .user_plugin = eh.plugin.name },
            .found => |bh| {
                if (bh.func == eh.func and
                    std.mem.eql(u8, bh.plugin.name, eh.plugin.name))
                {
                    return .clean;
                }
                return .{ .user_plugin = eh.plugin.name };
            },
        },
    }
}

/// Append one diagnostic to `diags` with a `gpa`-owned message — the
/// caller owns the list and every message in it (arena-friendly).
fn addDiag(
    gpa: std.mem.Allocator,
    diags: *std.ArrayList(Compile.Diagnostic),
    code: Compile.Code,
    span: sjon.Ast.Span,
    comptime fmt: []const u8,
    args: anytype,
) Error!void {
    const message = std.fmt.allocPrint(gpa, fmt, args) catch return error.OutOfMemory;
    diags.append(gpa, .{ .code = code, .span = span, .message = message }) catch
        return error.OutOfMemory;
}

/// Pack preflight — the v1 gate between a clean compile and `encode`.
/// Classifies every expr track's call heads (the position classifier
/// never prunes: untaken branches, short-circuit tails and never-run
/// binder bodies are all compared), and refuses any head the core-only
/// binary schema cannot resolve identically. Diagnostics are ordinary
/// `Compile.Diagnostic`s in score coordinates, appended to `diags`
/// (collection over abort); an empty list means the score packs.
/// PRECONDITION `result.ok()` — `encode`'s twin; a dirty compile is
/// reported through its own diagnostics and never reaches pack.
/// Allocations: diagnostics + messages from `gpa` (caller-owned);
/// everything transient from an internal scratch arena.
pub fn preflight(
    gpa: std.mem.Allocator,
    result: *const Compile.CompileResult,
    diags: *std.ArrayList(Compile.Diagnostic),
) Error!void {
    std.debug.assert(result.ok());
    const table = &result.table.?;
    const tree = &result.validated.result.tree;

    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const a = scratch.allocator();

    // One refusal per distinct (namespace, head), at its FIRST
    // occurrence's span — later duplicates add no information.
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);

    for (table.tracks) |track| switch (track.source) {
        .expr => |node| {
            const heads = try collectCallHeads(a, tree, node);            for (heads) |h| {
                const key = std.fmt.allocPrint(a, "{s}\x00{s}", .{
                    h.namespace orelse "", h.head,
                }) catch return error.OutOfMemory;
                if (seen.contains(key)) continue;
                seen.put(a, key, {}) catch return error.OutOfMemory;
                switch (classifyHead(result.eval_schema, h)) {
                    .clean => {},
                    .user_plugin => |plugin| try addDiag(
                        gpa,
                        diags,
                        .pack_user_expr_unsupported,
                        h.span,
                        "pack: expr head '{s}' is provided by plugin '{s}' — v1 packs resolve the core plugin only",
                        .{ spelled(a, h), plugin },
                    ),
                    .ambiguous => try addDiag(
                        gpa,
                        diags,
                        .pack_user_expr_unsupported,
                        h.span,
                        "pack: expr head '{s}' is ambiguous in this score (a user plugin redeclares a core name) — the binary schema resolves core only",
                        .{spelled(a, h)},
                    ),
                    .binary_only => try addDiag(
                        gpa,
                        diags,
                        .pack_user_expr_unsupported,
                        h.span,
                        "pack: expr head '{s}' resolves on the binary path but not on the eval path — schemas disagree",
                        .{spelled(a, h)},
                    ),
                }
            }
        },
        // Only expr heads carry the core-only-schema risk; keys, trigger
        // schedules and (since A3+A4) pattern tracks carry no head to
        // classify. The pattern refusal that stood here is lifted —
        // see the measure loop below.
        .keys, .trigger, .pattern => {},
    };
    // (The interim `.pattern` refusal that stood here was lifted
    // 2026-10-22, plan 06 A3+A4: the SJON pattern query env is delivered
    // and adopted, so a clean `:pattern` track is packable like any
    // other. `pack_patterns_unsupported` stays as the frozen, unemitted
    // wire reserve — Compile.zig's ordinal pin and reserve test.)

    // Payload caps, MEASURED on the very bytes `encode` would emit —
    // a subtree's compact IR can exceed its source text (risk E2), so
    // nothing is assumed. Per-payload first (track order), then the
    // `'PAYL'` total: the decoder refuses exactly these shapes
    // (`span.len > MAX_PAYLOAD_BYTES`, region `> MAX_PAYL_BYTES`), so
    // a preflight-clean pack can never emit what decode would refuse.
    // Loud measured refusals only — never a truncated subset.
    //
    // Both VALUE payload kinds are measured: an `:expr` track's compact
    // IR and a `:pattern` track's compact IR obey the SAME per-payload
    // and 'PAYL' caps the decoder enforces (A3+A4, 2026-10-22 — the
    // measure loop no longer skips patterns; the refusal that justified
    // skipping is gone).
    //
    // The writer's structural rejections (node/pool/string/depth —
    // final-review L1) surface through the bounded `encodePayload` and
    // are re-measured here as ordinary `pack_cap_exceeded` diagnostics:
    // a legal native-band source CAN exceed the 65536-entry string pool
    // (~7 source bytes per distinct string), so the refusal carries the
    // profile's measured numbers, never a bare "a cap tripped".
    var payload_total: usize = 0;
    var total_over_span: ?sjon.Ast.Span = null;
    for (table.tracks) |track| switch (track.source) {
        .expr, .pattern => |node| {
            const bytes = encodePayload(a, tree, node) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    // Measured refusal: profile the subtree the writer
                    // rejected and continue collecting (over abort).
                    const prof = try payloadProfile(a, tree, node);
                    try addPayloadStructuralDiag(gpa, diags, tree.spanOf(node), prof);
                    continue;
                },
            };
            if (bytes.len > Pacb.MAX_PAYLOAD_BYTES) {
                try addDiag(
                    gpa,
                    diags,
                    .pack_cap_exceeded,
                    tree.spanOf(node),
                    "pack: payload is {d} bytes, over the {d}-byte v1 per-payload cap",
                    .{ bytes.len, Pacb.MAX_PAYLOAD_BYTES },
                );
            }
            payload_total += bytes.len;
            if (total_over_span == null and payload_total > Pacb.MAX_PAYL_BYTES) {
                total_over_span = tree.spanOf(node);
            }
        },
        .keys, .trigger => {},
    };
    if (payload_total > Pacb.MAX_PAYL_BYTES) {
        try addDiag(
            gpa,
            diags,
            .pack_cap_exceeded,
            total_over_span.?,
            "pack: total payload bytes {d} exceed the {d}-byte v1 'PAYL' cap",
            .{ payload_total, Pacb.MAX_PAYL_BYTES },
        );
    }

    // The global explicit-tick cap (I2/G6): the measured sum of `:at`
    // entries across ALL tracks against `MAX_TICK_ENTRIES`. The text
    // path is deliberately uncapped — a native-band source (> 256 KiB)
    // or a direct-API compile can legally compile past the cap, and
    // pack refuses loudly with the measured count, never a truncated
    // schedule. One refusal, at the track whose entries complete the
    // overage (the decoder's own `count > MAX_TICK_ENTRIES` is the
    // same comparison over the same total).
    var tick_total: usize = 0;
    var tick_over_span: ?sjon.Ast.Span = null;
    for (table.tracks, 0..) |track, track_index| switch (track.source) {
        .trigger => |trig| switch (trig) {
            .at => |ats| {
                tick_total += ats.len;
                if (tick_over_span == null and tick_total > Pacb.MAX_TICK_ENTRIES) {
                    tick_over_span = table.track_spans[track_index];
                }
            },
            .periodic => {},
        },
        .keys, .expr, .pattern => {},
    };
    if (tick_total > Pacb.MAX_TICK_ENTRIES) {
        try addDiag(
            gpa,
            diags,
            .pack_cap_exceeded,
            tick_over_span.?,
            "pack: {d} explicit trigger entries exceed the global v1 cap of {d} (measured across all tracks)",
            .{ tick_total, Pacb.MAX_TICK_ENTRIES },
        );
    }

    // Control ids ride three u16 length fields — 'STRS' `id_len`, the
    // 'CTRL' id range, and PACM's control `id_len` — none of which the
    // compiler caps (`control-id` is a bare symbol with no length
    // bound). A native-band source compiles clean past the field and
    // would trap the encoder's `@intCast`; refuse here, measured, with
    // the id symbol's own span. This is the one producer-bound gap the
    // decoder's own checks cannot backstop: every count cap
    // (tracks/keys/scenes/controls/tempo/targets/ease programs) is
    // compile-side, and host/declared NAMES are bounded at the CLI's
    // two inputs before this — but ids enter as score text.
    for (result.validated.result.data_forest) |form| {
        if (tree.tagOf(form) != .form) continue;
        const hdr = tree.formHeader(form);
        if (!std.mem.eql(u8, hdr.head, "control")) continue;
        for (hdr.children) |child| {
            if (tree.tagOf(child) != .kvpair) continue;
            const kv = tree.kvpairHeader(child);
            if (!std.mem.eql(u8, kv.key, "id")) continue;
            const id = tree.symbolText(kv.value);
            if (id.len > std.math.maxInt(u16)) {
                try addDiag(
                    gpa,
                    diags,
                    .pack_cap_exceeded,
                    tree.spanOf(kv.value),
                    "pack: control id is {d} bytes, over the {d}-byte v1 'STRS'/'CTRL'/PACM id field",
                    .{ id.len, std.math.maxInt(u16) },
                );
            }
            break;
        }
    }
}

/// The message spelling of one head — `ns/head` when qualified.
/// Composed in the caller's scratch arena (message-time only).
fn spelled(a: std.mem.Allocator, h: HeadRef) []const u8 {
    const ns = h.namespace orelse return h.head;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ ns, h.head }) catch h.head;
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

/// One expected classifier outcome: a head text plus its namespace
/// (null = bare). Order is the walk's source order.
const ExpectedHead = struct { head: []const u8, ns: ?[]const u8 = null };

/// Parse `src`, run `collectCallHeads` over its single root, and assert
/// the exact head/namespace sequence — the classifier's position
/// contract pinned left to right.
fn expectHeads(src: [:0]const u8, expected: []const ExpectedHead) !void {
    var tree = try sjon.Parser.parse(t.allocator, src);
    defer tree.deinit();
    const heads = try collectCallHeads(t.allocator, &tree, tree.root[0]);
    defer t.allocator.free(heads);
    if (heads.len != expected.len) {
        std.debug.print("src: {s}\nheads: {d} collected, {d} expected\n", .{ src, heads.len, expected.len });
        for (heads) |h| std.debug.print("  {s}/{s}\n", .{ h.namespace orelse "", h.head });
        return error.HeadCountMismatch;
    }
    for (heads, expected) |got, want| {
        try t.expectEqualStrings(want.head, got.head);
        if (want.ns) |ns| {
            try t.expect(got.namespace != null);
            try t.expectEqualStrings(ns, got.namespace.?);
        } else {
            try t.expect(got.namespace == null);
        }
    }
}

test "PacbEncode: collectCallHeads classifies eval positions in source order" {
    // `if` walks test + both branches; a vector in eval position walks
    // its elements. Heads arrive in source order, spans attached.
    try expectHeads("(if (> t 1) (u 1) [(w 2) 3])", &.{
        .{ .head = ">" },
        .{ .head = "u" },
        .{ .head = "w" },
    });
    // `and`/`or`/`cond` never prune: every branch position is walked.
    try expectHeads("(or 1 (u 2) (v 3))", &.{ .{ .head = "u" }, .{ .head = "v" } });
    try expectHeads("(and (a 1) (b 2) (c 3))", &.{
        .{ .head = "a" }, .{ .head = "b" }, .{ .head = "c" },
    });
    try expectHeads("(cond false (u 1) true (v 2))", &.{ .{ .head = "u" }, .{ .head = "v" } });
    // Zero-arg `and`/`or`/`cond` are literals — nothing to walk.
    try expectHeads("(and)", &.{});
    try expectHeads("(or)", &.{});
    try expectHeads("(cond)", &.{});
    // `let` walks binding values + body, never the binding names.
    try expectHeads("(let [u 5 sin 2] (+ u (sin u)))", &.{ .{ .head = "+" }, .{ .head = "sin" } });
    // Binders walk xs/init/body, never the binder vector's name slots.
    try expectHeads("(map [u] (f xs) (g u))", &.{ .{ .head = "f" }, .{ .head = "g" } });
    try expectHeads("(fold [u acc] (i 0) (xs 1) (h u acc))", &.{
        .{ .head = "i" }, .{ .head = "xs" }, .{ .head = "h" },
    });
    // Ordinary calls walk positional children AND kvpair values, never
    // kvpair keys; the head itself is collected with its namespace.
    try expectHeads("(nothing 1 (h 2) :u (k 3))", &.{
        .{ .head = "nothing" }, .{ .head = "h" }, .{ .head = "k" },
    });
    try expectHeads("(core/let [x (a 1)] (b 2))", &.{
        .{ .head = "let", .ns = "core" }, .{ .head = "a" }, .{ .head = "b" },
    });
}

test "PacbEncode: special-form shape violations kill the subtree (scheduler abort order)" {
    // The scheduler checks each special form's shape BEFORE scheduling
    // any child — an arity/binder/kvpair violation raises at schedule
    // time, so nothing inside is ever evaluated. The classifier mirrors
    // that exactly: a malformed special form contributes no heads and
    // is not descended into.
    try expectHeads("(if (u 1))", &.{}); // arity 1
    try expectHeads("(if (u 1) (v 2) (w 3) (z 4))", &.{}); // arity 4
    try expectHeads("(if :k (u 1) 2)", &.{}); // kvpair test slot
    try expectHeads("(if false :k 2)", &.{}); // kvpair then slot
    try expectHeads("(let [x] (u 1))", &.{}); // odd binding vector
    try expectHeads("(let [x 1] :k)", &.{}); // kvpair body
    try expectHeads("(let [(u 1) 2] 3)", &.{}); // non-symbol binding name
    try expectHeads("(map [x] (u xs))", &.{}); // arity 2
    try expectHeads("(map [x 1] xs (u x))", &.{}); // non-symbol binder
    try expectHeads("(map [(u 1)] xs body)", &.{}); // 2-slot binder vector
    try expectHeads("(fold [acc x] (u 0) xs)", &.{}); // arity 3
    try expectHeads("(fold [acc acc] (u 0) xs body)", &.{}); // duplicate binder names
    try expectHeads("(cond (u 1))", &.{}); // odd clause count
    try expectHeads("(and :k (u 1))", &.{}); // kvpair in first slot
    // Later cond/and/or slots holding a kvpair are a CUT: the error
    // raises when the walk reaches them, so that slot and everything
    // after it is dead (mirroring `cond_select`/`and_check`/`or_check`).
    // (`:k 3` parses as ONE kvpair child — prefix-colon syntax — so the
    // clause counts below are the real child counts.)
    try expectHeads("(cond (a 1) (u 1) 2 :k 3)", &.{ .{ .head = "a" }, .{ .head = "u" } });
    try expectHeads("(or (u 1) :k 2)", &.{.{ .head = "u" }});
    try expectHeads("(or 1 :k 2 (v 3))", &.{});
}

test "PacbEncode: collectCallHeads spans are head spans in score coordinates" {
    var tree = try sjon.Parser.parse(t.allocator, "(if (> t 1) (myuser 2) 3)");
    defer tree.deinit();
    const heads = try collectCallHeads(t.allocator, &tree, tree.root[0]);
    defer t.allocator.free(heads);
    try t.expectEqual(@as(usize, 2), heads.len);
    // `myuser` starts at offset 13 (the lparen of its form is at 12).
    try t.expectEqual(@as(u32, 13), heads[1].span.start);
    try t.expect(heads[1].span.end > heads[1].span.start);
}

// ---- pack preflight (T3.2) -------------------------------------------------

const up_plugin = "(plugin :name up (expr-func :name u :params [number] :result number))\n";
const up_sin_plugin = "(plugin :name up (expr-func :name sin :params [number] :result number))\n";
const transport_line = "(transport :bpm 120 :meter [4 4])\n";

/// Compile a one-`:expr`-track score against target `x` and preflight
/// it into an arena; returns the diagnostics (empty when pack-clean).
fn preflightExpr(
    arena: std.mem.Allocator,
    extra_head: []const u8,
    expr_src: []const u8,
) ![]Compile.Diagnostic {
    const src = try std.fmt.allocPrintSentinel(arena, "{s}{s}(track :target x :expr {s})", .{
        transport_line, extra_head, expr_src,
    }, 0);
    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    var r = try compileForTest(arena, src, &tg);
    defer r.deinit();
    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(arena, &r, &diags);
    return diags.items;
}

/// Assert `src`'s `:expr` refuses packing with `code` and a message
/// containing `needle`, and return the first matching diagnostic (for
/// span assertions).
fn expectRefused(
    arena: std.mem.Allocator,
    plugin_head: []const u8,
    expr_src: []const u8,
    code: Compile.Code,
    needle: []const u8,
) !Compile.Diagnostic {
    const diags = try preflightExpr(arena, plugin_head, expr_src);
    for (diags) |d| {
        if (d.code == code and std.mem.indexOf(u8, d.message, needle) != null) return d;
    }
    std.debug.print("want {s} mentioning '{s}', got {d} diag(s):\n", .{ @tagName(code), needle, diags.len });
    for (diags) |d| std.debug.print("  {s}: {s}\n", .{ @tagName(d.code), d.message });
    return error.ExpectedRefusalMissing;
}

fn expectPacksClean(arena: std.mem.Allocator, plugin_head: []const u8, expr_src: []const u8) !void {
    const diags = try preflightExpr(arena, plugin_head, expr_src);
    if (diags.len != 0) {
        std.debug.print("expected pack-clean, got:\n", .{});
        for (diags) |d| std.debug.print("  {s}: {s}\n", .{ @tagName(d.code), d.message });
        return error.ExpectedCleanPack;
    }
}

test "PacbEncode: preflight refuses user-plugin heads the dry-run cannot see" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A user head in a RESULT branch guarded by a time test: the t=0
    // dry-run takes the else arm and never calls it; any t > 1s would.
    _ = try expectRefused(a, up_plugin, "(if (> t 1) (u 1) 2)", .pack_user_expr_unsupported, "'u'");
    // Short-circuit tail — one `or_check` step from evaluation.
    _ = try expectRefused(a, up_plugin, "(or 1 (u 2))", .pack_user_expr_unsupported, "'u'");
    // Hidden in an untaken `if` branch: only the never-pruning walk
    // catches it (the dry-run evaluates neither branch).
    const d = try expectRefused(a, up_plugin, "(if false (u 1) 2)", .pack_user_expr_unsupported, "'u'");
    // The span is the HEAD's span in score coordinates.
    const src_probe = transport_line ++ up_plugin ++ "(track :target x :expr (if false (u 1) 2))";
    const at = std.mem.indexOf(u8, src_probe, "(u 1)").?;
    try t.expectEqual(@as(u32, @intCast(at + 1)), d.span.start);
    // The same hiding works through every eval-position grammar shape.
    _ = try expectRefused(a, up_plugin, "(if false [(u 1)] 2)", .pack_user_expr_unsupported, "'u'");
    _ = try expectRefused(a, up_plugin, "(cond false (u 1) true 2)", .pack_user_expr_unsupported, "'u'");
    _ = try expectRefused(a, up_plugin, "(fold [a b] 0 [] (u a))", .pack_user_expr_unsupported, "'u'");
    _ = try expectRefused(a, up_plugin, "(let [a (if false (u 1) 2)] (+ a 1))", .pack_user_expr_unsupported, "'u'");
    // Namespace-qualified user head: found through the eval schema's
    // user plugin, absent from the core-only binary schema.
    _ = try expectRefused(a, up_plugin, "(if false (up/u 1) 2)", .pack_user_expr_unsupported, "'up/u'");
}

test "PacbEncode: preflight refuses ambiguous core redeclaration even when binary-found (I1/G11)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A user plugin redeclaring `sin`, called ONLY in an untaken
    // branch: `eval_schema` (core ⊕ user) is .ambiguous on the bare
    // head — error.AmbiguousFunction on BOTH schedule paths — while
    // the core-only binary schema finds core's sin. Found-in-binary
    // does NOT make the outcomes identical: refused.
    const d = try expectRefused(a, up_sin_plugin, "(if false (sin 1) 2)", .pack_user_expr_unsupported, "'sin'");
    try t.expect(std.mem.indexOf(u8, d.message, "ambiguous") != null);
}

test "PacbEncode: preflight dedupes one refusal per distinct head at its first span" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // `u` twice (first span wins), `w` once — both declared by the
    // plugin, so exactly two refusals.
    const two_head_plugin = "(plugin :name up" ++
        " (expr-func :name u :params [number] :result number)" ++
        " (expr-func :name w :params [number] :result number))\n";
    const src = try std.fmt.allocPrintSentinel(a, "{s}{s}(track :target x :expr (if false [(u 1) (u 2) (w 3)] 2))", .{
        transport_line, two_head_plugin,
    }, 0);
    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    var r = try compileForTest(a, src, &tg);
    defer r.deinit();
    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    try t.expectEqual(@as(usize, 2), diags.items.len);
    try t.expect(diags.items[0].code == .pack_user_expr_unsupported);
    try t.expect(diags.items[1].code == .pack_user_expr_unsupported);
    const u_at = std.mem.indexOf(u8, src, "(u 1)").?;
    try t.expectEqual(@as(u32, @intCast(u_at + 1)), diags.items[0].span.start);
}

test "PacbEncode: preflight accepts a :pattern track (refusal lifted, spanned pin retired)" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    var r = try compileForTest(
        a,
        transport_line ++ "(track :target x :pattern (fast 2 [0.2 (pure (+ 0.1 0.2))]))",
        &tg,
    );
    defer r.deinit();

    // A3+A4 (2026-10-22): the interim v1 refusal is GONE. A clean pattern
    // track is packable — preflight reports NOTHING, exactly like the
    // expr/keys/trigger arms, and `encode` emits the payload for the
    // decoder to accept (T3.1's uniform path, FEATURE_PATTERN_TRACKS).
    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    for (diags.items) |d| {
        std.debug.print("unexpected preflight diagnostic: {s}: {s}\n", .{ @tagName(d.code), d.message });
    }
    try t.expectEqual(@as(usize, 0), diags.items.len);

    const bytes = try encode(a, &r, &.{});
    defer a.free(bytes);
    var decoded = try Pacb.decode(a, bytes, null);
    defer decoded.deinit();
    try t.expect(decoded.required_features & Pacb.FEATURE_PATTERN_TRACKS != 0);
}

test "PacbEncode: preflight refuses an oversized payload with the measured size" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One expr track whose payload (the compact IR of the whole
    // `:expr` subtree) exceeds the per-payload cap: a large literal
    // vector hidden in an untaken branch compiles clean (the dry-run
    // never evaluates it) yet packs to > 256 KiB.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, transport_line);
    try buf.appendSlice(a, "(track :target x :expr (if false [");
    for (0..32768) |_| try buf.appendSlice(a, "1 ");
    try buf.appendSlice(a, "] 2))");
    const src = try buf.toOwnedSliceSentinel(a, 0);

    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    var r = try compileForTest(a, src, &tg);
    defer r.deinit();

    // The oracle: the very bytes `encode` would emit.
    const node = r.table.?.tracks[0].source.expr;
    const payload = try encodePayload(a, &r.validated.result.tree, node);
    try t.expect(payload.len > Pacb.MAX_PAYLOAD_BYTES); // fixture honest

    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    try t.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try t.expect(d.code == .pack_cap_exceeded);
    const measured = try std.fmt.allocPrint(a, "{d}", .{payload.len});
    try t.expect(std.mem.indexOf(u8, d.message, measured) != null);
    // The span is the payload subtree's own span (score coordinates).
    const want_span = r.validated.result.tree.spanOf(node);
    try t.expectEqual(want_span.start, d.span.start);
}

test "PacbEncode: preflight refuses total 'PAYL' overage across tracks, never per-payload" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Seventeen expr tracks, each payload just UNDER the per-payload
    // cap (so no per-payload refusal fires) but summing past the
    // 4 MiB total: exactly one measured-total refusal.
    var targets: std.ArrayList(Compile.Target) = .empty;
    defer targets.deinit(a);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, transport_line);
    var expected_total: usize = 0;
    for (0..17) |i| {
        const name = try std.fmt.allocPrint(a, "tgt{d}", .{i});
        try targets.append(a, .{ .name = name, .ncomp = 1 });
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "(track :target {s} :expr (if false [", .{name}));
        for (0..28000) |_| try buf.appendSlice(a, "1 ");
        try buf.appendSlice(a, "] 2))\n");
    }
    const src = try buf.toOwnedSliceSentinel(a, 0);

    var r = try compileForTest(a, src, targets.items);
    defer r.deinit();
    for (r.table.?.tracks) |track| {
        const bytes = try encodePayload(a, &r.validated.result.tree, track.source.expr);
        try t.expect(bytes.len <= Pacb.MAX_PAYLOAD_BYTES); // per-payload honest
        expected_total += bytes.len;
    }
    try t.expect(expected_total > Pacb.MAX_PAYL_BYTES); // fixture honest

    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    try t.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try t.expect(d.code == .pack_cap_exceeded);
    const measured = try std.fmt.allocPrint(a, "{d}", .{expected_total});
    try t.expect(std.mem.indexOf(u8, d.message, measured) != null);
    try t.expect(std.mem.indexOf(u8, d.message, "total") != null);
}

/// One expr payload whose distinct-string pool exceeds the compact-IR
/// writer's `MAX_STRING_POOL_ENTRIES` (65536): ~65.6k distinct quoted
/// strings inside an UNTAKEN `if` branch — the dry-run never builds
/// the vector (the same trick the 'PAYL' fixture uses), the walk still
/// sees every string, and ~525 KB of source sits inside the native
/// 1 MiB band.
fn bigPoolSource(a: std.mem.Allocator, n: usize) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, transport_line);
    try buf.appendSlice(a, "(track :target x :expr (if false [");
    for (0..n) |i| {
        var num: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&num, "\"s{d}\" ", .{i}) catch unreachable;
        try buf.appendSlice(a, s);
    }
    try buf.appendSlice(a, "] 1))");
    return buf.toOwnedSliceSentinel(a, 0);
}

// Final-review L1 (binary01-fc): the payload writer's structural caps
// (node count, distinct string pool, string length, depth) are now
// MEASURED at preflight and refused as ordinary `pack_cap_exceeded`
// diagnostics — the writer's own rejections surface as data, never as
// the old `unreachable`. A >64k-distinct-string payload is the one
// construct a legal native-band source can build that trips one.
test "PacbEncode: preflight refuses a payload over the string-pool cap with the measured count" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    const src = try bigPoolSource(a, sjon.Binary.MAX_STRING_POOL_ENTRIES + 64);
    var r = try compileForTest(a, src, &tg);
    defer r.deinit();

    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    try t.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try t.expect(d.code == .pack_cap_exceeded);
    // Measured distinct-string count over the frozen cap, and the cap
    // itself, both ride the message.
    try t.expect(std.mem.indexOf(u8, d.message, "65536") != null);
    // The span is the :expr node's own span (score coordinates).
    const expr_span = r.validated.result.tree.spanOf(r.table.?.tracks[0].source.expr);
    try t.expectEqual(expr_span.start, d.span.start);
}

// A3+A4 (2026-10-22): the interim refusal is lifted — a :pattern payload
// is an ordinary payload. The SAME measured caps apply: a payload the
// compact-IR writer rejects (here the 65536-entry string pool) surfaces
// as the ordinary measured `pack_cap_exceeded` diagnostic, never a
// pattern-specific refusal and never a crash.
test "PacbEncode: preflight measures an over-cap :pattern payload under the same caps" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};
    var pat: std.ArrayList(u8) = .empty;
    defer pat.deinit(a);
    try pat.appendSlice(a, transport_line);
    try pat.appendSlice(a, "(track :target x :pattern (fast 2 [0.2 (pure (if false [");
    for (0..sjon.Binary.MAX_STRING_POOL_ENTRIES + 64) |i| {
        var num: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&num, "\"s{d}\" ", .{i}) catch unreachable;
        try pat.appendSlice(a, s);
    }
    try pat.appendSlice(a, "] 0.2))]))");
    const src = try pat.toOwnedSliceSentinel(a, 0);

    var r = try compileForTest(a, src, &tg);
    defer r.deinit();

    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    // Exactly the writer-cap refusal the same-shaped expr payload gets:
    // one measured structural diagnostic, no pattern-specific class.
    try t.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try t.expect(d.code == .pack_cap_exceeded);
    // The measured count and the frozen cap both ride the message.
    try t.expect(std.mem.indexOf(u8, d.message, "65536") != null);
    // The span is the :pattern subtree's own span (score coordinates) —
    // the same coordinate contract the expr arm pins.
    const pat_span = r.validated.result.tree.spanOf(r.table.?.tracks[0].source.pattern);
    try t.expectEqual(pat_span.start, d.span.start);
}

// A3+A4 (2026-10-22): :pattern payload bytes COUNT toward the 'PAYL'
// total — the decoder's 4 MiB region cap does not distinguish payload
// kinds, so the preflight measure must not either. Fixture calibration
// (observed, 2026-10-22): SJON's pattern query bounds a legal flat
// literal vector near its 1024 live-frame ceiling (`DepthExceeded`
// past ~1024 haps), so one legal pattern payload stays small; the
// region cap is reached through MULTIPLICITY over many legal pattern
// tracks, with expr bulk holding the total just under the cap so only
// the pattern bytes can cross it.
test "PacbEncode: preflight refuses total 'PAYL' overage reached through :pattern payloads" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 36 expr tracks (each an untaken-branch vector packing to ~108 KB —
    // the compact IR spends ~9 bytes per literal, so 12000 literals land
    // there — under the per-payload cap) sum just UNDER the 4 MiB region
    // cap; 80 legal pattern tracks (~900 literals each, ~7 KB each)
    // push the measured total past it. Only the pattern bytes can
    // cross — exactly one measured-total refusal.
    var targets: std.ArrayList(Compile.Target) = .empty;
    defer targets.deinit(a);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, transport_line);
    var expr_total: usize = 0;
    var pattern_total: usize = 0;
    for (0..36) |i| {
        const name = try std.fmt.allocPrint(a, "exg{d}", .{i});
        try targets.append(a, .{ .name = name, .ncomp = 1 });
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "(track :target {s} :expr (if false [", .{name}));
        for (0..12000) |_| try buf.appendSlice(a, "1 ");
        try buf.appendSlice(a, "] 2))\n");
    }
    for (0..80) |i| {
        const name = try std.fmt.allocPrint(a, "ptg{d}", .{i});
        try targets.append(a, .{ .name = name, .ncomp = 1 });
        try buf.appendSlice(a, try std.fmt.allocPrint(a, "(track :target {s} :pattern [", .{name}));
        for (0..900) |_| try buf.appendSlice(a, "1 ");
        try buf.appendSlice(a, "])\n");
    }
    const src = try buf.toOwnedSliceSentinel(a, 0);

    var r = try compileForTest(a, src, targets.items);
    defer r.deinit();
    for (r.table.?.tracks) |track| switch (track.source) {
        .expr => |node| expr_total += (try encodePayload(a, &r.validated.result.tree, node)).len,
        .pattern => |node| pattern_total += (try encodePayload(a, &r.validated.result.tree, node)).len,
        else => {},
    };
    // Fixture honesty: the expr bulk alone stays under the region cap;
    // only the pattern bytes cross it.
    try t.expect(expr_total < Pacb.MAX_PAYL_BYTES);
    try t.expect(expr_total + pattern_total > Pacb.MAX_PAYL_BYTES);

    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    // One measured-total refusal — the same shape the expr arm pins —
    // never a per-track pattern refusal, never a truncated subset.
    try t.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try t.expect(d.code == .pack_cap_exceeded);
    const measured = try std.fmt.allocPrint(a, "{d}", .{expr_total + pattern_total});
    try t.expect(std.mem.indexOf(u8, d.message, measured) != null);
    try t.expect(std.mem.indexOf(u8, d.message, "total") != null);
}

/// Build a one-trigger score with `n` explicit `:at` positions
/// (`1b 2b … nb` — the grammar's honest ascending integer spelling;
/// bare integers are not valid time-pos values).
fn bigTickSource(a: std.mem.Allocator, n: usize) ![:0]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, transport_line);
    try buf.appendSlice(a, "(trigger :target x :at [");
    for (1..n + 1) |i| {
        var num: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&num, "{d}b ", .{i}) catch unreachable;
        try buf.appendSlice(a, s);
    }
    try buf.appendSlice(a, "])");
    return buf.toOwnedSliceSentinel(a, 0);
}

test "PacbEncode: preflight refuses the tick-count overage with the measured count" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tg = [_]Compile.Target{.{ .name = "x", .ncomp = 1 }};

    // 131073 explicit entries (~0.9 MB of source, within the native
    // 1 MiB band): the TEXT path is uncapped by design — the compile
    // is clean — and pack refuses loudly with the measured count.
    const src = try bigTickSource(a, 131073);
    var r = try compileForTest(a, src, &tg);
    defer r.deinit();
    try t.expectEqual(@as(usize, 131073), r.table.?.tracks[0].source.trigger.at.len);

    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    try t.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try t.expect(d.code == .pack_cap_exceeded);
    try t.expect(std.mem.indexOf(u8, d.message, "131073") != null);
    // The span is the overage-completing track's own span.
    const want_span = r.table.?.track_spans[0];
    try t.expectEqual(want_span.start, d.span.start);

    // The boundary packs: exactly MAX_TICK_ENTRIES entries preflight
    // clean AND round-trip through decode (the decoder's own cap is
    // the same `>`, never `>=`) — the ~1 MiB 'TICK' section is legal.
    const src_ok = try bigTickSource(a, Pacb.MAX_TICK_ENTRIES);
    var r2 = try compileForTest(a, src_ok, &tg);
    defer r2.deinit();
    var diags2: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r2, &diags2);
    try t.expectEqual(@as(usize, 0), diags2.items.len);
    const bytes = try encode(a, &r2, &.{});
    defer a.free(bytes);
    var decoded = try Pacb.decode(a, bytes, null);
    defer decoded.deinit();
    try t.expectEqual(Pacb.MAX_TICK_ENTRIES, decoded.tracks[0].source.trigger.at.len);
}

// Final-review I3, the one REAL producer gap (binary01-fc): a control
// id rides three u16 length fields — 'STRS' id_len, the 'CTRL' id
// range, and PACM's control id_len — none of which the compiler caps
// (`control-id` is a bare symbol). A native-band source compiles clean
// past 65535 and would trap the encoder's `@intCast`; preflight
// refuses it measured, with the id's own span.
test "PacbEncode: preflight refuses a control id over the u16 id field, measured" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cap = std.math.maxInt(u16);

    // Over-cap: compile clean, then refuse at preflight with the
    // measured length at the id symbol's span.
    const over_src = try std.fmt.allocPrintSentinel(
        a,
        "{s}(control :id {s} :value 0)",
        .{ transport_line, "k" ** (cap + 1) },
        0,
    );
    var r = try compileForTest(a, over_src, &.{});
    defer r.deinit();
    try t.expectEqual(@as(usize, 1), r.table.?.controls.len);
    try t.expectEqual(cap + 1, r.table.?.controls[0].id.len);

    var diags: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r, &diags);
    try t.expectEqual(@as(usize, 1), diags.items.len);
    const d = diags.items[0];
    try t.expect(d.code == .pack_cap_exceeded);
    try t.expect(std.mem.indexOf(u8, d.message, "65536") != null);
    // The span is the id symbol's own span, so the diagnostic points at
    // the exact spelling in score coordinates.
    const tree = &r.validated.result.tree;
    var want_span: sjon.Ast.Span = .{ .start = 0, .end = 0 };
    for (r.validated.result.data_forest) |form| {
        if (tree.tagOf(form) != .form) continue;
        const hdr = tree.formHeader(form);
        if (!std.mem.eql(u8, hdr.head, "control")) continue;
        for (hdr.children) |c| {
            if (tree.tagOf(c) != .kvpair) continue;
            const kv = tree.kvpairHeader(c);
            if (std.mem.eql(u8, kv.key, "id")) {
                want_span = tree.spanOf(kv.value);
                break;
            }
        }
    }
    try t.expectEqual(want_span.start, d.span.start);
    try t.expectEqual(want_span.end, d.span.end);

    // At-cap: packs and round-trips — the boundary is exact, `>` not
    // `>=`, on the same field all three writers spell.
    const ok_src = try std.fmt.allocPrintSentinel(
        a,
        "{s}(control :id {s} :value 0)",
        .{ transport_line, "k" ** cap },
        0,
    );
    var r2 = try compileForTest(a, ok_src, &.{});
    defer r2.deinit();
    var diags2: std.ArrayList(Compile.Diagnostic) = .empty;
    try preflight(a, &r2, &diags2);
    try t.expectEqual(@as(usize, 0), diags2.items.len);
    const blob = try encode(a, &r2, &.{});
    defer a.free(blob);
    var decoded = try Pacb.decode(a, blob, null);
    defer decoded.deinit();
    try t.expectEqual(cap, decoded.controls[0].id.len);
}

test "PacbEncode: preflight acceptance set — grammar name slots and form-as-data pack clean" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Plain core-only score: clean.
    try expectPacksClean(a, "", "(+ t 1)");
    // Vector elements in eval position, core heads: clean.
    try expectPacksClean(a, "", "(if false [(sin 1) (+ 2 3)] 2)");
    // `let` binding NAMES never classify — even when they collide with
    // a core head (`sin`) or a user func name (`u`).
    try expectPacksClean(a, up_plugin, "(let [u 5 sin 2] (+ u (sin u)))");
    // Binder vectors are name slots (`[u]`, `[u acc]`); bodies/args walk.
    // (The map body's vector result must match the target's ncomp 1.)
    try expectPacksClean(a, up_plugin, "(map [u] [1] (+ u 1))");
    try expectPacksClean(a, up_plugin, "(fold [u acc] 0 [1 2] (+ u acc))");
    // kvpair KEYS never classify (the VALUE is walked — a literal).
    try expectPacksClean(a, up_plugin, "(if false (nothing :u 1) 2)");
    // A head resolving in NEITHER schema is a form-as-data literal.
    try expectPacksClean(a, "", "(if false (nope-not-anywhere 1 2) 3)");
    // Qualified core heads resolve through core on BOTH paths (the
    // core plugin's impl-null special-form markers are found-both,
    // identical) — pack-clean; it would fail to CALL on both equally.
    try expectPacksClean(a, "", "(if false (core/let [a 1] (+ a a)) 2)");
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

test "PacbEncode: the three committed CLI fixtures re-encode byte-identical" {
    // `tools/testdata/pacb/*.pacb` are the REAL CLI's own output —
    // generated by `zig build run -- pack <src> --out <dst>`, the
    // canonical producer. Re-packing the same sources here and
    // byte-comparing anchors cross-run determinism in the repo: same
    // source, same bytes, whatever the process.
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = @import("build_options").repo_root;

    // Sceneless sources: still byte-identical to the frozen CLI output —
    // the metadata wave's 'SNAM' section is OMITTED at scene count 0, so
    // these pins are untouched by it.
    for ([_][]const u8{ "keys-only", "expr-keys" }) |name| {
        const src_path = try std.fmt.allocPrint(a, "{s}/tools/testdata/pacb/{s}.score.sjon", .{ root, name });
        const pacb_path = try std.fmt.allocPrint(a, "{s}/tools/testdata/pacb/{s}.pacb", .{ root, name });
        const src = try sjon.CappedRead.readFileZ(std.testing.io, src_path, a, 1 << 20);
        const want = try sjon.CappedRead.readFile(std.testing.io, pacb_path, a, 1 << 20);

        var r = try compileForTest(a, src, &.{});
        defer r.deinit();
        var diags: std.ArrayList(Compile.Diagnostic) = .empty;
        try preflight(a, &r, &diags);
        try t.expectEqual(@as(usize, 0), diags.items.len);

        const bytes = try encode(a, &r, &.{});
        try t.expectEqualSlices(u8, want, bytes);
    }

    // full-small carries one scene, so the metadata wave changes the
    // producer's output: the fresh pack is the FROZEN bytes (the
    // fixtures stay frozen forever) PLUS exactly the known appended
    // 'SNAM' tail frame — the legitimate known-producer-append form of
    // this exact assert. Every frozen byte still matches one-to-one and
    // the append itself is pinned byte-for-byte; parity is strengthened,
    // not weakened.
    const snam_tail = [_]u8{
        'S', 'N', 'A', 'M', // section id "SNAM", LE 4-CC
        12,  0,   0,   0, // payload_len: count(4) + name_len(4) + name(4)
        1,   0,   0,   0, // count — equals the 'SCEN' count
        4,   0,   0,   0, // name_len u32
        'd', 'r', 'o', 'p', // the verbatim :name symbol bytes
    };
    {
        const src_path = try std.fmt.allocPrint(a, "{s}/tools/testdata/pacb/full-small.score.sjon", .{root});
        const pacb_path = try std.fmt.allocPrint(a, "{s}/tools/testdata/pacb/full-small.pacb", .{root});
        const src = try sjon.CappedRead.readFileZ(std.testing.io, src_path, a, 1 << 20);
        const want = try sjon.CappedRead.readFile(std.testing.io, pacb_path, a, 1 << 20);

        var r = try compileForTest(a, src, &.{});
        defer r.deinit();
        var diags: std.ArrayList(Compile.Diagnostic) = .empty;
        try preflight(a, &r, &diags);
        try t.expectEqual(@as(usize, 0), diags.items.len);

        const bytes = try encode(a, &r, &.{});
        // The embedded 'PACM' is the container's LAST section, so the
        // appended 'SNAM' frame shows up as exactly four changes against
        // the frozen file: the directory's 'PACM' length field (frozen
        // directory entry: kind@148, off@152, len@156) grows by the
        // tail's 20 bytes; the TRAN record's pacm_fnv (@208 — TRAN@160:
        // bpm, meter, dur, flags, target counts, pact_fnv, pacm_fnv)
        // re-hashes over the grown PACM; and the tail itself closes the
        // file. Every other byte is identical.
        const pacm_dir_len_off = 156;
        const pacm_fnv_off = 208;
        const old_pacm_len = std.mem.readInt(u32, want[pacm_dir_len_off..][0..4], .little);
        try t.expectEqual(want.len + snam_tail.len, bytes.len);
        try t.expectEqualSlices(u8, want[0..pacm_dir_len_off], bytes[0..pacm_dir_len_off]);
        try t.expectEqual(old_pacm_len + snam_tail.len, std.mem.readInt(u32, bytes[pacm_dir_len_off..][0..4], .little));
        try t.expectEqualSlices(u8, want[pacm_dir_len_off + 4 .. pacm_fnv_off], bytes[pacm_dir_len_off + 4 .. pacm_fnv_off]);
        // pacm_fnv: FNV-1a-64 over the grown embedded PACM (its offset
        // is unchanged — nothing before the last section moved).
        const fresh_pacm = bytes[want.len - old_pacm_len ..];
        try t.expectEqual(fnv1a64(fresh_pacm), std.mem.readInt(u64, bytes[pacm_fnv_off..][0..8], .little));
        try t.expectEqualSlices(u8, want[pacm_fnv_off + 8 ..], bytes[pacm_fnv_off + 8 .. want.len]);
        try t.expectEqualSlices(u8, &snam_tail, bytes[want.len..]);
    }
}

test "PacbEncode: long scene names ride the pack's embedded 'PACM' verbatim" {
    // The CLI-pack producer path: this module embeds the real
    // `Abi.encodeMeta` blob as 'PACM', so the pack must carry long scene
    // names exactly. A 300-byte name (past the dead 255-ish per-name
    // policy) and a 66,000-byte name (past any 16-bit field — the wire
    // length is u32) each survive pack → container decode → metadata
    // section walk, read back out of the PRODUCED bytes, never a
    // constructed record.
    inline for ([_]usize{ 300, 66000 }) |name_len| {
        const name = "a" ** 66000;
        const src = try std.fmt.allocPrintSentinel(
            t.allocator,
            "(transport :bpm 120)\n(scene :name {s} :at 0b :dur 4b\n  (track :target circle-radius (key :at 0b :value 0.5)))\n",
            .{name[0..name_len]},
            0,
        );
        defer t.allocator.free(src);
        var r = try compileForTest(t.allocator, src, fixture_host[0..1]);
        defer r.deinit();
        var diags: std.ArrayList(Compile.Diagnostic) = .empty;
        try preflight(t.allocator, &r, &diags);
        try t.expectEqual(@as(usize, 0), diags.items.len);
        const bytes = try encode(t.allocator, &r, &.{});
        defer t.allocator.free(bytes);

        var score = try Pacb.decode(t.allocator, bytes, null);
        defer score.deinit();

        // Walk the embedded PACM's section stream to the 'SNAM' tail:
        // 1 track, 1 key, 0 controls before the stream, then 'SCEN'.
        const pacm = score.pacm;
        var off: usize = Abi.META_HEADER_LEN + Abi.META_TRACK_LEN + Abi.META_KEY_LEN;
        try t.expect(pacm.len >= off + Abi.META_SECTION_HEADER_LEN);
        try t.expectEqual(Abi.SCENES_SECTION_ID, std.mem.readInt(u32, pacm[off..][0..4], .little));
        off += Abi.META_SECTION_HEADER_LEN + std.mem.readInt(u32, pacm[off + 4 ..][0..4], .little);
        // The 'SNAM' tail frame must EXIST: this expect fails (never an
        // out-of-bounds read) while the producer does not append it yet.
        try t.expect(pacm.len >= off + Abi.META_SECTION_HEADER_LEN + 8 + name_len);
        try t.expectEqual(Abi.SNAM_SECTION_ID, std.mem.readInt(u32, pacm[off..][0..4], .little));
        const plen = std.mem.readInt(u32, pacm[off + 4 ..][0..4], .little);
        try t.expectEqual(@as(u32, @intCast(4 + 4 + name_len)), plen);
        const body = off + Abi.META_SECTION_HEADER_LEN;
        try t.expectEqual(@as(u32, 1), std.mem.readInt(u32, pacm[body..][0..4], .little));
        const got_len = std.mem.readInt(u32, pacm[body + 4 ..][0..4], .little);
        try t.expectEqual(@as(u32, @intCast(name_len)), got_len);
        try t.expectEqualSlices(u8, name[0..name_len], pacm[body + 8 ..][0..got_len]);
        try t.expectEqual(pacm.len, off + Abi.META_SECTION_HEADER_LEN + plen); // tail
    }
}
