//! `pacer pack` — compile a score to the `'PACB'` container file.
//!
//! ## Channels
//!
//! `pack` is a DATA verb with TWO outputs that must never meet: the
//! deterministic JSON report rides stdout alone, and the binary blob
//! goes only to `--out`. A blob byte on stdout would corrupt every
//! `| jq` pipeline the other verbs promise, so the write is checked,
//! atomic (temp file + rename), and COMPLETED before the first byte of
//! the report — the report never claims a pack that did not land.
//!
//! ## The `--targets-json` adapter
//!
//! The file is exactly the JSON serialization of a pngine `getUniforms`
//! answer — one object mapping name → `{ "type": string, "elemCount":
//! number }`, insertion order preserved (order IS the target_id space).
//! The adapter replicates the hello player's `buildJoin`
//! (`animader/examples/hello/player/join.js`) verbatim:
//!
//!   * LANES `f32/i32/u32` → 1, `vec2{f,i,u}` → 2, `vec3{f,i,u}` → 3,
//!     `vec4{f,i,u}` → 4 — the only WGSL spellings a 1..4-lane score
//!     target can be.
//!   * `elemCount` non-zero (an array field) is skipped, not guessed.
//!   * An unknown `type` (matrices, textures, newer spellings) is
//!     skipped, not guessed.
//!   * Registry 0: the reflection IS registry 0's answer.
//!
//! The parse itself is `std.json` — the native JSON parser the SJON
//! bridge (`sjon.Json`) also sits ON TOP of; `sjon.Json.fromJson` maps
//! SJON-tagged objects (`{"$form": …}`) and REJECTS plain ones, so it
//! cannot read a reflection dump. What the plan called "parse via
//! sjon.Json" is this: the same `std.json.Value` surface, consumed
//! natively (recorded in the task report).
//!
//! The JSON names a HOST registry and nothing else: the adapter never
//! mines score text for target names, never invents one, and never
//! second-guesses the compile join's own unknown-target diagnostics.

const std = @import("std");
const pacer = @import("pacer");
const sjon = @import("sjon");
const Args = @import("Args.zig");
const Envelope = @import("Envelope.zig");
const Json = @import("Json.zig");
const Source = @import("Source.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;
const t = std.testing;

/// Everything the verb propagates to `main` — `Cli.Error`'s shape,
/// spelled here so the verb module never imports its dispatcher.
pub const Error = Allocator.Error || Writer.Error;

/// The adapter's whole failure surface. `Malformed` covers everything
/// that is not the specified file shape (unparseable JSON, a non-object
/// root, a non-object entry, a non-numeric `elemCount`); the caller
/// renders it as a usage error naming the file.
pub const JoinError = error{
    OutOfMemory,
    ReadFailed,
    TooLarge,
    Malformed,
    TooManyTargets,
};

/// One reflected WGSL type's lane count — `buildJoin`'s LANES table,
/// verbatim and complete: the twelve bare spellings a 1..4-lane score
/// target can be. Null = unknown type = skip the entry (a matrix is
/// nine lanes; pacer's target arity is 1..4 — `join.js` skips rather
/// than guesses, and so does the adapter: no templated `vec2<f32>`
/// aliasing, no future spellings).
pub fn lanesOf(wgsl_type: []const u8) ?u8 {
    const table = [_]struct { name: []const u8, lanes: u8 }{
        .{ .name = "f32", .lanes = 1 },
        .{ .name = "i32", .lanes = 1 },
        .{ .name = "u32", .lanes = 1 },
        .{ .name = "vec2f", .lanes = 2 },
        .{ .name = "vec2i", .lanes = 2 },
        .{ .name = "vec2u", .lanes = 2 },
        .{ .name = "vec3f", .lanes = 3 },
        .{ .name = "vec3i", .lanes = 3 },
        .{ .name = "vec3u", .lanes = 3 },
        .{ .name = "vec4f", .lanes = 4 },
        .{ .name = "vec4i", .lanes = 4 },
        .{ .name = "vec4u", .lanes = 4 },
    };
    for (table) |row| {
        if (std.mem.eql(u8, row.name, wgsl_type)) return row.lanes;
    }
    return null;
}

/// `elemCount` as `buildJoin` reads it: a truthiness test on a NUMBER.
/// Missing / JSON null ⇒ 0 (falsy); any numeric non-zero ⇒ skip. A
/// non-numeric spelling is off-spec for the file and refuses rather
/// than guessing JS truthiness for types the dump never carries.
fn elemCountOf(field: std.json.ObjectMap) JoinError!f64 {
    const v = field.get("elemCount") orelse return 0;
    return switch (v) {
        .null => 0,
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch return error.Malformed,
        else => error.Malformed,
    };
}

/// Reflection JSON (already parsed) → the host registry, replicating
/// `buildJoin` rule for rule. Names alias `value`'s strings; the caller
/// keeps the parsed JSON alive for as long as the compile holds the
/// targets (the CLI: the command arena).
pub fn joinFromReflection(a: Allocator, value: std.json.Value) JoinError![]pacer.Compile.Target {
    const root = switch (value) {
        .object => |o| o,
        // A reflection dump is ONE object; anything else is not the
        // specified file, and an empty registry here would silently
        // pack a score whose tracks then resolve against nothing.
        else => return error.Malformed,
    };

    var join: std.ArrayList(pacer.Compile.Target) = .empty;
    errdefer join.deinit(a);

    var it = root.iterator();
    while (it.next()) |entry| {
        const field = switch (entry.value_ptr.*) {
            .object => |o| o,
            else => return error.Malformed,
        };
        if (try elemCountOf(field) != 0) continue;
        const type_v = field.get("type") orelse continue;
        const wgsl_type = switch (type_v) {
            .string => |s| s,
            // An unknown or missing type skips the entry — buildJoin's
            // `LANES[field.type] === undefined` continue.
            else => continue,
        };
        const lanes = lanesOf(wgsl_type) orelse continue;
        if (join.items.len == pacer.Compile.MAX_TARGETS) return error.TooManyTargets;
        try join.append(a, .{ .name = entry.key_ptr.*, .ncomp = lanes, .registry = 0 });
    }
    return join.toOwnedSlice(a) catch return error.OutOfMemory;
}

/// Read the `--targets-json` file and build the join. The cap matches
/// the score input's (`Source.MAX_SOURCE_BYTES`): a reflection table is
/// a small document, and an unbounded read of a user-named file is a
/// hang, not a parse.
pub fn loadTargetsJson(a: Allocator, io: Io, path: []const u8) JoinError![]pacer.Compile.Target {
    const bytes = sjon.CappedRead.readFile(io, path, a, Source.MAX_SOURCE_BYTES) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.StreamTooLong, error.FileTooBig => error.TooLarge,
        else => error.ReadFailed,
    };
    const value = std.json.parseFromSliceLeaky(std.json.Value, a, bytes, .{}) catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        // Any decode refusal (bad JSON, nesting past the parser's depth
        // bound) is a file that is not the specified shape.
        else => error.Malformed,
    };
    return joinFromReflection(a, value);
}

/// The whole host registry one pack compiles against: the reflection
/// file's entries in file order, then any `--target` flags in argv
/// order. One flat list — the target_id space — exactly as a
/// `times.sjon` sequence and `--target` flags already combine.
pub fn hostJoin(
    a: Allocator,
    io: Io,
    json_path: []const u8,
    argv_targets: []const pacer.Compile.Target,
) JoinError![]const pacer.Compile.Target {
    const from_json = try loadTargetsJson(a, io, json_path);
    if (argv_targets.len == 0) return from_json;
    if (from_json.len + argv_targets.len > pacer.Compile.MAX_TARGETS)
        return error.TooManyTargets;
    const all = a.alloc(pacer.Compile.Target, from_json.len + argv_targets.len) catch
        return error.OutOfMemory;
    @memcpy(all[0..from_json.len], from_json);
    @memcpy(all[from_json.len..], argv_targets);
    return all;
}

/// The message a usage error carries for each adapter refusal — the
/// `Source.load` twin, so both inputs a pack names fail in one voice.
pub fn joinErrorMessage(e: JoinError) []const u8 {
    return switch (e) {
        error.OutOfMemory => "out of memory",
        error.ReadFailed => "could not read",
        error.TooLarge => "targets file exceeds the input cap",
        error.Malformed => "not a reflection dump (expected one JSON object of name → {\"type\", \"elemCount\"})",
        error.TooManyTargets => "too many reflected targets (max 1024)",
    };
}

// ---------------------------------------------------------------------------
// The verb
// ---------------------------------------------------------------------------

/// Write the `pack` envelope. Returns the exit code: 0 when the blob
/// landed, 1 for a score that cannot pack (compile diagnostics or pack
/// preflight refusals — both ride `diagnostics` as ordinary records),
/// 2 for an output that could not be written (stdout untouched), 3 for
/// a self-check failure (the encoder's own invariant broke — reported,
/// never packed anyway).
///
/// Order of operations IS the contract: encode, self-check, WRITE, and
/// only then the first report byte — the report never claims a pack
/// that did not land, and stdout never carries half an object on any
/// write failure.
pub fn write(
    gpa: Allocator,
    io: Io,
    w: *Writer,
    err: *Writer,
    ctx: Envelope.Ctx,
    host_targets: []const pacer.Compile.Target,
    opts: Args.PackOpts,
    packable: bool,
) Error!u8 {
    // Not packable: a dirty compile (its diagnostics voided the table)
    // or a preflight refusal the dispatcher appended. The envelope
    // shape never varies with the outcome: a score that cannot pack
    // still gets the whole object, `pack` present as null.
    if (ctx.result.table == null or !packable) {
        try Envelope.writeHead(w, ctx, "pack");
        try w.writeAll(",\n  \"pack\":null");
        try Envelope.writeTail(w);
        return Envelope.exitCode(ctx);
    }

    const blob = pacer.PacbEncode.encode(gpa, ctx.result, host_targets) catch
        return error.OutOfMemory;
    defer gpa.free(blob);

    // The invariant ring: decode our own output, prove the decoded
    // table equals the compiled one field-for-field, and prove the
    // embedded 'PACM' is a fresh encode of THIS compile — decode
    // presence alone proves nothing.
    const info = selfCheck(gpa, err, ctx.result, host_targets, blob) catch |e| switch (e) {
        error.SelfcheckFailed => return 3,
        else => |propagated| return propagated,
    };

    // The blob lands before the first report byte. Temp file + rename,
    // both beside the destination (same directory, same filesystem —
    // rename over the target is the atomic step). A failure here is a
    // usage error naming the path: the score packed; the disk said no.
    const tmp_path = std.fmt.allocPrint(gpa, "{s}.tmp", .{opts.out}) catch
        return error.OutOfMemory;
    defer gpa.free(tmp_path);
    const cwd = Io.Dir.cwd();
    cwd.writeFile(io, .{ .sub_path = tmp_path, .data = blob }) catch |e| {
        try err.print("pacer: {s}: could not write ({s})\n", .{ opts.out, @errorName(e) });
        return 2;
    };
    Io.Dir.rename(cwd, tmp_path, cwd, opts.out, io) catch |e| {
        // Leave no temp behind a failed rename.
        cwd.deleteFile(io, tmp_path) catch {};
        try err.print("pacer: {s}: could not write ({s})\n", .{ opts.out, @errorName(e) });
        return 2;
    };

    // Success: the report says what landed, where, and how big. The
    // blob itself never joins stdout — stdout is the JSON channel.
    const declared_count = ctx.result.targets.len - host_targets.len;
    try Envelope.writeHead(w, ctx, "pack");
    try w.writeAll(",\n  \"pack\":{\"out\":");
    try Json.string(w, opts.out);
    try w.print(
        ",\"bytes\":{d},\"sections\":{d},\"targets\":{{\"host\":{d},\"declared\":{d}}},\"pacm_bytes\":{d}}}",
        .{ blob.len, info.sections, host_targets.len, declared_count, info.pacm_bytes },
    );
    try Envelope.writeTail(w);
    return Envelope.exitCode(ctx);
}

// ---------------------------------------------------------------------------
// Self-check
// ---------------------------------------------------------------------------

pub const SelfcheckError = Error || error{SelfcheckFailed};

/// What a passing self-check learned about the blob — the report's own
/// numbers, read off the bytes that actually landed rather than off a
/// second guess.
pub const Selfcheck = struct {
    sections: u8,
    pacm_bytes: usize,
};

fn selfcheckFail(err: *Writer, comptime fmt: []const u8, args: anytype) SelfcheckError {
    // A dead stderr cannot be reported on either — the check failed and
    // the reason is gone; say only that.
    err.print("pacer: self-check: " ++ fmt ++ "\n", args) catch {};
    return error.SelfcheckFailed;
}

/// Bit-for-bit f64 equality — both sides spell one producer pass, so
/// equal BITS are the predicate; `==` would misread a NaN present on
/// both sides as a lie.
fn f64BitsEqual(a: f64, b: f64) bool {
    return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
}

/// Bit-for-bit `[4]f32` lane equality (`Pacb`'s own coherence rule).
fn lanesBitsEqual(a: [4]f32, b: [4]f32) bool {
    for (a, b) |x, y| {
        if (@as(u32, @bitCast(x)) != @as(u32, @bitCast(y))) return false;
    }
    return true;
}

/// Decode `blob` and prove it is THIS compile: the decoded table equals
/// the compiled one field-for-field everywhere the container carries
/// the field, and the embedded `'PACM'` byte-equals a fresh
/// `Abi.encodeMeta` pass over the same result. (`Pacb.decode` itself
/// already cross-checks the sections against the embedded metadata —
/// `verifyRouting` — so this adds the two things decode cannot know:
/// that the metadata is this compile's, and that the decoded table
/// equals the in-memory one.)
fn selfCheck(
    gpa: Allocator,
    err: *Writer,
    result: *const pacer.Compile.CompileResult,
    host_targets: []const pacer.Compile.Target,
    blob: []const u8,
) SelfcheckError!Selfcheck {
    var refusal: pacer.Pacb.Refusal = undefined;

    const directory = pacer.Pacb.parseDirectory(blob, &refusal) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return selfcheckFail(
            err,
            "own output refused at the directory ({s} at byte {d})",
            .{ @tagName(refusal.code), refusal.offset },
        ),
    };
    var decoded = pacer.Pacb.decode(gpa, blob, &refusal) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return selfcheckFail(
            err,
            "own output refused ({s} at byte {d})",
            .{ @tagName(refusal.code), refusal.offset },
        ),
    };
    defer decoded.deinit();

    const table = &result.table.?;
    const d = &decoded;

    // The embedded metadata is a fresh encode of THIS result.
    const pacm_len = pacer.Abi.metaEncodedLen(result);
    const pacm_buf = gpa.alloc(u8, pacm_len) catch return error.OutOfMemory;
    defer gpa.free(pacm_buf);
    const fresh_pacm = pacer.Abi.encodeMeta(result, pacm_buf) catch return error.OutOfMemory;
    if (!std.mem.eql(u8, fresh_pacm, d.pacm))
        return selfcheckFail(err, "embedded 'PACM' is not a fresh encode of this compile", .{});

    // Registry identity: the canonical 'PACT' spelling of THIS host join.
    const regs_len = pacer.PactCodec.targetsEncodedLen(host_targets);
    const regs_buf = gpa.alloc(u8, regs_len) catch return error.OutOfMemory;
    defer gpa.free(regs_buf);
    const fresh_regs = pacer.PactCodec.encodeTargets(host_targets, regs_buf) catch |e|
        return selfcheckFail(err, "registry re-encode failed ({s})", .{@errorName(e)});
    if (!std.mem.eql(u8, fresh_regs, d.regs))
        return selfcheckFail(err, "'REGS' is not the canonical spelling of this host join", .{});

    // Feature word: bit0 iff a pattern track exists.
    var want_features: u32 = 0;
    for (table.tracks) |tk| {
        if (tk.source == .pattern) want_features = pacer.Pacb.FEATURE_PATTERN_TRACKS;
    }
    if (d.required_features != want_features)
        return selfcheckFail(err, "feature word {d}, expected {d}", .{ d.required_features, want_features });

    // Transport scalars (bit-equal floats) and the authored tempo map.
    const wt = &table.transport;
    const dt = &d.transport;
    if (!f64BitsEqual(wt.map.bpm, dt.map.bpm) or
        wt.map.beats_per_bar != dt.map.beats_per_bar or
        wt.map.ticks_per_beat != dt.map.ticks_per_beat or
        !f64BitsEqual(wt.map.ticks_per_second, dt.map.ticks_per_second))
        return selfcheckFail(err, "transport map differs from the compiled one", .{});
    if (wt.dur != dt.dur or wt.end != dt.end)
        return selfcheckFail(err, "transport duration/end differ from the compiled one", .{});
    if ((wt.loop_secs == null) != (dt.loop_secs == null) or
        (wt.loop_secs != null and !f64BitsEqual(wt.loop_secs.?, dt.loop_secs.?)))
        return selfcheckFail(err, "transport loop length differs from the compiled one", .{});
    if (wt.segments.len != dt.segments.len)
        return selfcheckFail(err, "tempo map has {d} segments, compiled {d}", .{ dt.segments.len, wt.segments.len });
    for (wt.segments, dt.segments) |ws, ds| {
        if (ws.start_tick != ds.start_tick or !f64BitsEqual(ws.bpm, ds.bpm))
            return selfcheckFail(err, "tempo segment differs from the compiled one", .{});
    }
    if (wt.emit.len != dt.emit.len)
        return selfcheckFail(err, "emit lane count {d}, compiled {d}", .{ dt.emit.len, wt.emit.len });
    for (wt.emit, dt.emit) |we, de| {
        if (we.target_id != de.target_id or we.registry != de.registry)
            return selfcheckFail(err, "emit lane differs from the compiled one", .{});
    }

    // Tracks: identity fields plus the per-source routing (a keys
    // track's run indexes; a trigger's schedule; expr/pattern presence —
    // payload CONTENT is the PACM-equality ring above, not this one).
    if (table.tracks.len != d.tracks.len)
        return selfcheckFail(err, "{d} tracks decoded, compiled {d}", .{ d.tracks.len, table.tracks.len });
    for (table.tracks, d.tracks) |ct, cd| {
        if (ct.target_id != cd.target_id or ct.registry != cd.registry or
            ct.ncomp != cd.ncomp or ct.scene != cd.scene)
            return selfcheckFail(err, "track identity differs from the compiled one", .{});
        const schedule_ok = switch (ct.source) {
            .keys => |ck| switch (cd.source) {
                .keys => |dk| ck.start == dk.start and ck.len == dk.len,
                else => false,
            },
            .trigger => |ctr| switch (cd.source) {
                .trigger => |dtr| switch (ctr) {
                    .periodic => |cp| switch (dtr) {
                        .periodic => |dp| cp.every == dp.every and cp.offset == dp.offset,
                        else => false,
                    },
                    .at => |ca| switch (dtr) {
                        .at => |da| ca.len == da.len and std.mem.eql(i64, ca, da),
                        else => false,
                    },
                },
                else => false,
            },
            .expr => cd.source == .expr,
            .pattern => cd.source == .pattern,
        };
        if (!schedule_ok)
            return selfcheckFail(err, "track {d} source differs from the compiled one", .{ct.target_id});
    }

    // Keys: position, easing ref, and bit-equal lanes.
    if (table.keys.len != d.keys.len)
        return selfcheckFail(err, "{d} keys decoded, compiled {d}", .{ d.keys.len, table.keys.len });
    for (table.keys, d.keys) |ck, dk| {
        if (ck.at != dk.at or ck.ease_ref != dk.ease_ref or !lanesBitsEqual(ck.value, dk.value))
            return selfcheckFail(err, "a key differs from the compiled one", .{});
    }

    // Programs: count only — the 'EASE' payload is sliced verbatim out
    // of the PACM pass proven byte-equal above, and decode's own
    // verifyRouting checked the copy field-for-field.
    if (table.programs.len != d.programs.len)
        return selfcheckFail(err, "{d} easing programs decoded, compiled {d}", .{ d.programs.len, table.programs.len });

    // Controls: identity, target, kind, and values — all bit-equal.
    if (table.controls.len != d.controls.len)
        return selfcheckFail(err, "{d} controls decoded, compiled {d}", .{ d.controls.len, table.controls.len });
    for (table.controls, d.controls) |cc, dc| {
        const target_ok = (cc.target == null) == (dc.target == null) and
            (cc.target == null or (cc.target.?.id == dc.target.?.id and
                cc.target.?.registry == dc.target.?.registry));
        const range_ok = (cc.min == null) == (dc.min == null) and (cc.max == null) == (dc.max == null) and
            (cc.min == null or lanesBitsEqual(cc.min.?, dc.min.?)) and
            (cc.max == null or lanesBitsEqual(cc.max.?, dc.max.?));
        if (!std.mem.eql(u8, cc.id, dc.id) or cc.ncomp != dc.ncomp or cc.kind != dc.kind or
            !lanesBitsEqual(cc.value, dc.value) or !target_ok or !range_ok)
            return selfcheckFail(err, "control '{s}' differs from the compiled one", .{cc.id});
    }

    // Scenes: the window (names never ride the container).
    if (table.scenes.len != d.scenes.len)
        return selfcheckFail(err, "{d} scenes decoded, compiled {d}", .{ d.scenes.len, table.scenes.len });
    for (table.scenes, d.scenes) |cs, ds| {
        if (cs.start_tick != ds.start_tick or cs.dur_ticks != ds.dur_ticks)
            return selfcheckFail(err, "a scene window differs from the compiled one", .{});
    }

    // The declared tail (names never ride; arity and registry do).
    const declared = result.targets[host_targets.len..];
    if (declared.len != d.declared.len)
        return selfcheckFail(err, "{d} declared targets decoded, compiled {d}", .{ d.declared.len, declared.len });
    for (declared, d.declared) |td, dd| {
        if (td.ncomp != dd.ncomp or td.registry != dd.registry)
            return selfcheckFail(err, "declared target '{s}' differs from the compiled one", .{td.name});
    }

    return .{
        .sections = directory.len,
        .pacm_bytes = d.pacm.len,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn reflectionOf(a: Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
}

test "adapter: LANES maps every score-target WGSL type, both spellings" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // buildJoin's table verbatim: f32/i32/u32→1, vec2*→2, vec3*→3,
    // vec4*→4 — the twelve bare spellings.
    const cases = [_]struct { wgsl: []const u8, lanes: u8 }{
        .{ .wgsl = "f32", .lanes = 1 },
        .{ .wgsl = "i32", .lanes = 1 },
        .{ .wgsl = "u32", .lanes = 1 },
        .{ .wgsl = "vec2f", .lanes = 2 },
        .{ .wgsl = "vec2i", .lanes = 2 },
        .{ .wgsl = "vec2u", .lanes = 2 },
        .{ .wgsl = "vec3f", .lanes = 3 },
        .{ .wgsl = "vec3i", .lanes = 3 },
        .{ .wgsl = "vec3u", .lanes = 3 },
        .{ .wgsl = "vec4f", .lanes = 4 },
        .{ .wgsl = "vec4i", .lanes = 4 },
        .{ .wgsl = "vec4u", .lanes = 4 },
    };
    for (cases) |c| try t.expectEqual(c.lanes, lanesOf(c.wgsl));

    // Unknown types are skipped, never guessed: a matrix is nine lanes
    // and not a score target; the templated vector spelling is not one
    // of buildJoin's keys, so it is an unknown type too — exactly what
    // `LANES[field.type] === undefined` does in the player.
    try t.expectEqual(@as(?u8, null), lanesOf("mat3x3f"));
    try t.expectEqual(@as(?u8, null), lanesOf("texture_2d<f32>"));
    try t.expectEqual(@as(?u8, null), lanesOf("f16"));
    try t.expectEqual(@as(?u8, null), lanesOf("vec2<f32>"));
    _ = a;
}

test "adapter: buildJoin over a mixed reflection — keep, skip, order" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = try reflectionOf(a,
        \\{
        \\  "circle-radius": { "type": "f32", "elemCount": 0 },
        \\  "particles":    { "type": "array<Particle>", "elemCount": 64 },
        \\  "tint":         { "type": "vec4f", "elemCount": 0 },
        \\  "model":        { "type": "mat4x4f", "elemCount": 0 },
        \\  "gain":         { "type": "f32" },
        \\  "weights":      { "type": "vec3f", "elemCount": 0 }
        \\}
    );
    const join = try joinFromReflection(a, value);

    // Insertion order IS the target_id space: kept entries in file
    // order, skipped ones gone (the array field, the matrix), registry
    // 0, lanes from LANES. `gain` proves a missing elemCount reads as
    // falsy, exactly like `field.elemCount` on an absent key.
    try t.expectEqual(@as(usize, 4), join.len);
    try t.expectEqualStrings("circle-radius", join[0].name);
    try t.expectEqual(@as(u8, 1), join[0].ncomp);
    try t.expectEqual(@as(u8, 0), join[0].registry);
    try t.expectEqualStrings("tint", join[1].name);
    try t.expectEqual(@as(u8, 4), join[1].ncomp);
    try t.expectEqualStrings("gain", join[2].name);
    try t.expectEqual(@as(u8, 1), join[2].ncomp);
    try t.expectEqualStrings("weights", join[3].name);
    try t.expectEqual(@as(u8, 3), join[3].ncomp);
}

test "adapter: a non-object root, a non-object entry and bad elemCount refuse" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Not the specified file: refuse loudly rather than joining nothing.
    try t.expectError(error.Malformed, joinFromReflection(a, try reflectionOf(a, "[]")));
    try t.expectError(error.Malformed, joinFromReflection(a, try reflectionOf(a, "5")));
    try t.expectError(error.Malformed, joinFromReflection(a, try reflectionOf(a,
        \\{ "x": 7 }
    )));
    try t.expectError(error.Malformed, joinFromReflection(a, try reflectionOf(a,
        \\{ "x": { "type": "f32", "elemCount": "four" } }
    )));
}

test "adapter: elemCount zero, absent and null all keep; negative skips" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = try reflectionOf(a,
        \\{
        \\  "a": { "type": "f32", "elemCount": 0 },
        \\  "b": { "type": "f32", "elemCount": null },
        \\  "c": { "type": "f32" },
        \\  "d": { "type": "f32", "elemCount": -1 }
        \\}
    );
    const join = try joinFromReflection(a, value);
    // JS truthiness: 0/null/missing are falsy, any non-zero (negative
    // included) is truthy — `d` is an array field by that reading.
    try t.expectEqual(@as(usize, 3), join.len);
    try t.expectEqualStrings("a", join[0].name);
    try t.expectEqualStrings("b", join[1].name);
    try t.expectEqualStrings("c", join[2].name);
}

test "adapter: more reflected targets than MAX_TARGETS refuses, never asserts" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    try text.appendSlice(a, "{");
    for (0..pacer.Compile.MAX_TARGETS + 1) |i| {
        if (i != 0) try text.append(a, ',');
        const piece = try std.fmt.allocPrint(a, "\"t{d}\":{{\"type\":\"f32\",\"elemCount\":0}}", .{i});
        try text.appendSlice(a, piece);
    }
    try text.append(a, '}');
    try t.expectError(
        error.TooManyTargets,
        joinFromReflection(a, try reflectionOf(a, text.items)),
    );
}

test "adapter: the join compiles a score against it — end to end" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const value = try reflectionOf(a,
        \\{ "glow": { "type": "f32", "elemCount": 0 } }
    );
    const join = try joinFromReflection(a, value);

    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target glow
        \\  (key :at 0b :value 0.1)
        \\  (key :at 4b :value 0.9 :ease out-cubic))
    ;
    var schema = try pacer.Schema.load(t.allocator);
    defer schema.deinit();
    var r = try pacer.Compile.compile(t.allocator, &schema, source, join);
    defer r.deinit();
    try t.expect(r.ok());
    try t.expectEqual(@as(usize, 1), r.targets.len);
    try t.expectEqualStrings("glow", r.targets[0].name);
}

test "selfcheck: a fresh encode passes and yields the report's numbers" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(target :name glow :arity 1 :registry 0)
        \\(track :target glow
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8 :ease out-cubic))
    ;
    var schema = try pacer.Schema.load(t.allocator);
    defer schema.deinit();
    var r = try pacer.Compile.compile(t.allocator, &schema, source, &.{});
    defer r.deinit();
    try t.expect(r.ok());

    const blob = try pacer.PacbEncode.encode(a, &r, &.{});
    var sink: std.Io.Writer.Allocating = .init(t.allocator);
    defer sink.deinit();
    const info = try selfCheck(a, &sink.writer, &r, &.{}, blob);
    try t.expect(info.sections >= 2);
    try t.expect(info.pacm_bytes > 0);
    try t.expectEqualStrings("", sink.written());
}

test "selfcheck: a foreign compile and a tampered blob are caught" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const clean: [:0]const u8 =
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(target :name glow :arity 1 :registry 0)
        \\(track :target glow
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8 :ease out-cubic))
    ;
    const other: [:0]const u8 =
        \\(transport :bpm 121 :meter [4 4] :dur 2bar :end loop)
        \\(target :name glow :arity 1 :registry 0)
        \\(track :target glow
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8 :ease out-cubic))
    ;
    var schema = try pacer.Schema.load(t.allocator);
    defer schema.deinit();
    var r = try pacer.Compile.compile(t.allocator, &schema, clean, &.{});
    defer r.deinit();
    var r2 = try pacer.Compile.compile(t.allocator, &schema, other, &.{});
    defer r2.deinit();

    const blob = try pacer.PacbEncode.encode(a, &r, &.{});
    const foreign = try pacer.PacbEncode.encode(a, &r2, &.{});
    var sink: std.Io.Writer.Allocating = .init(t.allocator);
    defer sink.deinit();

    // A well-formed blob of ANOTHER score decodes fine — the PACM
    // equality ring is what catches it.
    try t.expectError(error.SelfcheckFailed, selfCheck(a, &sink.writer, &r, &.{}, foreign));
    try t.expect(std.mem.indexOf(u8, sink.written(), "fresh encode") != null);

    // A tampered tail byte is refused by decode itself.
    const tampered = try a.dupe(u8, blob);
    tampered[tampered.len - 1] ^= 0xff;
    try t.expectError(error.SelfcheckFailed, selfCheck(a, &sink.writer, &r, &.{}, tampered));
    try t.expect(std.mem.indexOf(u8, sink.written(), "refused") != null);
}
