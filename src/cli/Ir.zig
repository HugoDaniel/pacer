//! `pacer ir` — the compiled IR as JSON.
//!
//! Rendered from `CompileResult` / `TrackTable` in MEMORY, not from the
//! `'PACM'` blob, because the blob is lossy in exactly the places this
//! output promises to be useful:
//!
//! - **no emit lanes at all** (`Transport.emit` has no wire record, so a
//!   score with `(transport :emit [beat])` would show nothing about it),
//! - no target NAMES, only ids,
//! - no scene names, only spans,
//! - no expr / pattern SOURCE TEXT — the wire track record is a `source`
//!   byte 0..3 and nothing more,
//! - no join origins: `CompileResult.targets` is a native-side view that
//!   preserves host indices then appends compose-mode declarations.
//!
//! `corpus_runner` renders the other way round and should: its job is
//! proving `'PACM'` byte-identical native and wasm. The CLI is native-only
//! and makes no parity claim, so round-tripping through a wasm-boundary
//! format to produce native-only output would be ritual, not proof.

const std = @import("std");
const pacer = @import("pacer");
const sjon = @import("sjon");
const Envelope = @import("Envelope.zig");
const Json = @import("Json.zig");
const Source = @import("Source.zig");
const TrackTable = pacer.TrackTable;
const Easing = pacer.Easing;
const Writer = std.Io.Writer;
const t = std.testing;

/// Write the `ir` envelope. Returns the exit code (diagnostics still set
/// it, even though the payload rendered).
pub fn write(w: *Writer, ctx: Envelope.Ctx) Writer.Error!u8 {
    try Envelope.writeHead(w, ctx, "ir");

    try w.writeAll(",\n  \"targets\":[");
    for (ctx.result.targets, 0..) |tg, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\n    {{\"id\":{d},\"name\":", .{i});
        try Json.string(w, tg.name);
        try w.print(",\"ncomp\":{d},\"registry\":{d},\"origin\":", .{ tg.ncomp, tg.registry });
        try Json.string(w, ctx.targetOrigin(@intCast(i)));
        try w.writeByte('}');
    }
    if (ctx.result.targets.len != 0) try w.writeAll("\n  ");
    try w.writeByte(']');

    // A defective score has no table. Every key below still appears —
    // `transport` as null, the arrays as empty — so a consumer never
    // branches on whether a key exists.
    const table = ctx.result.table orelse {
        try w.writeAll(
            ",\n  \"transport\":null,\n  \"scenes\":[],\n  \"tracks\":[],\n  \"controls\":[],\n  \"easing\":[]",
        );
        try Envelope.writeTail(w);
        return Envelope.exitCode(ctx);
    };

    try writeTransport(w, ctx, &table.transport);
    try writeScenes(w, ctx, table.scenes);
    try writeTracks(w, ctx, &table);
    try writeControls(w, ctx, table.controls);
    try writeEasing(w, table.programs);

    try Envelope.writeTail(w);
    return Envelope.exitCode(ctx);
}

fn writeTransport(w: *Writer, ctx: Envelope.Ctx, tp: *const TrackTable.Transport) Writer.Error!void {
    const map = &tp.map;
    try w.print(
        ",\n  \"transport\":{{\"bpm\":{d},\"beats_per_bar\":{d},\"ppc\":{d},\"ticks_per_beat\":{d},\"ticks_per_second\":{d},\"end\":\"{s}\"",
        .{ map.bpm, map.beats_per_bar, sjon.Pattern.PPC, map.ticks_per_beat, map.ticks_per_second, @tagName(tp.end) },
    );
    if (tp.dur) |dur| {
        try w.print(",\"dur_ticks\":{d},\"dur_seconds\":", .{dur});
        // Compile's own number (`loop_secs`, set whenever `:dur` is), not a
        // conversion re-spelled here — the seconds↔ticks seam has one home.
        try Json.number(w, tp.loop_secs orelse 0);
    } else {
        try w.writeAll(",\"dur_ticks\":null,\"dur_seconds\":null");
    }

    try w.writeAll(",\"emit\":[");
    for (tp.emit, 0..) |lane, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try Json.string(w, @tagName(lane.name));
        try w.print(",\"target_id\":{d},\"target\":", .{lane.target_id});
        try Json.string(w, ctx.targetName(lane.target_id));
        try w.print(",\"registry\":{d}}}", .{lane.registry});
    }

    // The tempo map, segment 0 INCLUDED so a consumer needs no transport
    // join. `map.segments` is empty for a constant score (the degenerate
    // pin keeps that path untouched), so synthesise the one segment rather
    // than making the key's presence depend on the score's shape.
    try w.writeAll("],\"tempo\":[");
    if (map.segments.len == 0) {
        try w.print("{{\"tick\":0,\"bpm\":{d},\"start_seconds\":0}}", .{map.bpm});
    } else for (map.segments, 0..) |seg, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("{{\"tick\":{d},\"bpm\":{d},\"start_seconds\":", .{ seg.start_tick, seg.bpm });
        try Json.number(w, seg.start_sec);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn writeScenes(w: *Writer, ctx: Envelope.Ctx, scenes: []const TrackTable.Scene) Writer.Error!void {
    try w.writeAll(",\n  \"scenes\":[");
    for (scenes, 0..) |scene, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\n    {{\"index\":{d},\"name\":", .{i});
        // The wire carries a scene's name as a SPAN; the name itself only
        // exists in the source, so this is one of the places the CLI must
        // hold both.
        try Json.string(w, slice(ctx.source, scene.name_span));
        try w.print(",\"start_tick\":{d},\"dur_ticks\":{d},\"name_span\":", .{ scene.start_tick, scene.dur_ticks });
        try Envelope.writeSpan(w, ctx, scene.name_span);
        try w.writeByte('}');
    }
    if (scenes.len != 0) try w.writeAll("\n  ");
    try w.writeByte(']');
}

fn writeTracks(w: *Writer, ctx: Envelope.Ctx, table: *const TrackTable) Writer.Error!void {
    const tree = &ctx.result.validated.result.tree;
    try w.writeAll(",\n  \"tracks\":[");
    for (table.tracks, table.track_spans, 0..) |track, span, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\n    {{\"index\":{d},\"target_id\":{d},\"target\":", .{ i, track.target_id });
        try Json.string(w, ctx.targetName(track.target_id));
        try w.print(",\"registry\":{d},\"ncomp\":{d},\"scene\":", .{ track.registry, track.ncomp });
        if (track.scene == TrackTable.NO_SCENE) try w.writeAll("null") else try w.print("{d}", .{track.scene});
        try w.writeAll(",\"source\":");
        try Json.string(w, @tagName(track.source));
        try w.writeAll(",\"span\":");
        try Envelope.writeSpan(w, ctx, span);

        switch (track.source) {
            .keys => {},
            // The source TEXT, sliced from the score. `'PACM'` cannot
            // express this, and it is the thing a person most wants to see
            // beside a track that has no keys.
            .expr => |node| {
                try w.writeAll(",\"expr\":");
                try Json.string(w, slice(ctx.source, tree.spanOf(node)));
            },
            .pattern => |node| {
                try w.writeAll(",\"pattern\":");
                try Json.string(w, slice(ctx.source, tree.spanOf(node)));
            },
            .trigger => |trig| {
                try w.writeAll(",\"trigger\":");
                switch (trig) {
                    .periodic => |p| try w.print(
                        "{{\"kind\":\"periodic\",\"every\":{d},\"offset\":{d}}}",
                        .{ p.every, p.offset },
                    ),
                    .at => |ticks| {
                        try w.writeAll("{\"kind\":\"at\",\"at\":[");
                        for (ticks, 0..) |tick, k| {
                            if (k != 0) try w.writeByte(',');
                            try w.print("{d}", .{tick});
                        }
                        try w.writeAll("]}");
                    },
                }
            },
        }

        // Always present, empty for a non-key source — one shape. Guarded
        // on the tag because `trackKeys` ASSERTS a keys-sourced track: it
        // is a library invariant, not a query.
        try w.writeAll(",\"keys\":[");
        if (track.source == .keys) {
            const start = track.source.keys.start;
            for (table.trackKeys(&track), 0..) |key, k| {
                if (k != 0) try w.writeByte(',');
                try w.print("\n      {{\"at\":{d},\"value\":", .{key.at});
                try Json.lanes(w, key.value, track.ncomp);
                try w.print(",\"ease\":{d},\"span\":", .{key.ease_ref});
                // The key spans run parallel to the flat key stream, so a
                // track's k-th key is `key_spans[start + k]`.
                try Envelope.writeSpan(w, ctx, table.key_spans[start + k]);
                try w.writeByte('}');
            }
            try w.writeAll("\n    ");
        }
        try w.writeAll("]}");
    }
    if (table.tracks.len != 0) try w.writeAll("\n  ");
    try w.writeByte(']');
}

fn writeControls(w: *Writer, ctx: Envelope.Ctx, controls: []const TrackTable.Control) Writer.Error!void {
    try w.writeAll(",\n  \"controls\":[");
    for (controls, 0..) |ctl, i| {
        if (i != 0) try w.writeByte(',');
        // The index IS the `--set` slot: `TrackTable.controls` is document
        // order, which is the `drv_setControl` index space.
        try w.print("\n    {{\"index\":{d},\"id\":", .{i});
        try Json.string(w, ctl.id);
        try w.writeAll(",\"type\":");
        try Json.string(w, @tagName(ctl.kind));
        try w.print(",\"ncomp\":{d}", .{ctl.ncomp});
        if (ctl.target) |tg| {
            try w.print(",\"target_id\":{d},\"target\":", .{tg.id});
            try Json.string(w, ctx.targetName(tg.id));
            try w.print(",\"registry\":{d}", .{tg.registry});
        } else {
            // An env-only control: it feeds expressions and writes nothing.
            try w.writeAll(",\"target_id\":null,\"target\":null,\"registry\":null");
        }
        try w.writeAll(",\"value\":");
        try Json.lanes(w, ctl.value, ctl.ncomp);
        try w.writeAll(",\"min\":");
        try writeRail(w, ctl.min, ctl.ncomp);
        try w.writeAll(",\"max\":");
        try writeRail(w, ctl.max, ctl.ncomp);
        try w.writeAll(",\"value_span\":");
        try Envelope.writeSpan(w, ctx, ctl.value_span);
        try w.writeByte('}');
    }
    if (controls.len != 0) try w.writeAll("\n  ");
    try w.writeByte(']');
}

/// `:min` / `:max` are editor metadata the driver never clamps against,
/// so absent is `null` rather than a zero-filled array that would read as
/// a real rail.
fn writeRail(w: *Writer, rail: ?[4]f32, ncomp: u8) Writer.Error!void {
    const lanes = rail orelse return w.writeAll("null");
    try Json.lanes(w, lanes, ncomp);
}

/// The deduped easing table. `programs[0]` is always the default linear,
/// and a key's `ease` indexes here.
fn writeEasing(w: *Writer, programs: []const Easing.Program) Writer.Error!void {
    try w.writeAll(",\n  \"easing\":[");
    for (programs, 0..) |prog, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\n    {{\"index\":{d},\"stages\":[", .{i});
        for (prog.stages[0..prog.len], 0..) |stage, s| {
            if (s != 0) try w.writeByte(',');
            try w.writeAll("{\"t_end\":");
            try Json.number32(w, stage.t_end);
            try w.writeAll(",\"v_base\":");
            try Json.number32(w, stage.v_base);
            try w.writeAll(",\"v_span\":");
            try Json.number32(w, stage.v_span);
            try w.writeAll(",\"ops\":[");
            for (stage.ops[0..stage.ops_len], 0..) |op, o| {
                if (o != 0) try w.writeByte(',');
                try w.writeAll("{\"op\":");
                // `@tagName(Easing.Op)` — the wire-stable spelling the
                // corpus goldens already pin.
                try Json.string(w, @tagName(op.code));
                try w.writeAll(",\"params\":");
                try Json.lanes(w, op.params, 4);
                try w.writeByte('}');
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    if (programs.len != 0) try w.writeAll("\n  ");
    try w.writeByte(']');
}

fn slice(source: []const u8, span: sjon.Ast.Span) []const u8 {
    const start = @min(span.start, source.len);
    return source[start..@min(@max(span.end, start), source.len)];
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A JSON number, whichever arm the parser chose. `{d}` renders 120 as
/// `120`, which parses as an integer — the distinction is Zig's, not
/// JSON's, so a test must not depend on it.
fn num(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => std.math.nan(f64),
    };
}

/// Compile `source`, render the `ir` envelope, and hand back a parsed
/// tree. Everything is torn down before returning, so the caller only
/// holds JSON — which is the point: the renderer must not leave live
/// borrows in its output.
fn irOf(a: std.mem.Allocator, source: [:0]const u8, targets: []const pacer.Compile.Target) !std.json.Parsed(std.json.Value) {
    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    var r = try pacer.Compile.compile(a, &schema, source, targets);
    defer r.deinit();
    var index = try Source.LineIndex.build(a, source);
    defer index.deinit(a);

    var aw: Writer.Allocating = .init(a);
    defer aw.deinit();
    _ = try write(&aw.writer, .{
        .result = &r,
        .source = source,
        .index = &index,
        .path = "t.sjon",
        .host_target_count = targets.len,
    });
    return std.json.parseFromSlice(std.json.Value, a, aw.written(), .{});
}

test "ir: a compose-mode score names its own targets and marks them declared" {
    var p = try irOf(t.allocator,
        \\(target :name glow :arity 1 :registry 0)
        \\(target :name tint :arity 4 :registry 1)
        \\(transport :bpm 120 :meter [4 4] :dur 2bar :end loop)
        \\(track :target glow
        \\  (key :at 0b :value 0.2)
        \\  (key :at 4b :value 0.8 :ease out-cubic))
    , &.{});
    defer p.deinit();
    const root = p.value.object;
    try t.expectEqual(true, root.get("ok").?.bool);
    try t.expectEqualStrings("ir", root.get("command").?.string);

    const targets = root.get("targets").?.array.items;
    try t.expectEqual(@as(usize, 2), targets.len);
    try t.expectEqualStrings("glow", targets[0].object.get("name").?.string);
    try t.expectEqualStrings("declared", targets[0].object.get("origin").?.string);
    try t.expectEqual(@as(i64, 1), targets[1].object.get("registry").?.integer);
    try t.expectEqual(@as(i64, 4), targets[1].object.get("ncomp").?.integer);

    const tr = root.get("transport").?.object;
    try t.expectEqual(@as(f64, 120), num(tr.get("bpm").?));
    try t.expectEqual(@as(i64, 4), tr.get("beats_per_bar").?.integer);
    try t.expectEqual(@as(i64, 720720), tr.get("ppc").?.integer);
    try t.expectEqualStrings("loop", tr.get("end").?.string);
    try t.expectEqual(@as(i64, 8 * 180180), tr.get("dur_ticks").?.integer);

    const tracks = root.get("tracks").?.array.items;
    try t.expectEqual(@as(usize, 1), tracks.len);
    const t0 = tracks[0].object;
    try t.expectEqualStrings("keys", t0.get("source").?.string);
    try t.expectEqualStrings("glow", t0.get("target").?.string);
    try t.expectEqual(@as(std.json.Value, .null), t0.get("scene").?);
    const keys = t0.get("keys").?.array.items;
    try t.expectEqual(@as(usize, 2), keys.len);
    try t.expectEqual(@as(i64, 0), keys[0].object.get("at").?.integer);
    try t.expectEqual(@as(i64, 4 * 180180), keys[1].object.get("at").?.integer);
    // A scalar target renders ONE lane, not four zero-padded ones.
    try t.expectEqual(@as(usize, 1), keys[1].object.get("value").?.array.items.len);
    // The non-linear ease is a program past index 0 (which is linear).
    try t.expect(keys[1].object.get("ease").?.integer > 0);
    try t.expect(root.get("easing").?.array.items.len > 1);
}

test "ir: expr and pattern tracks carry their SOURCE TEXT, which no blob has" {
    var p = try irOf(t.allocator,
        \\(target :name a :arity 1)
        \\(target :name p :arity 1)
        \\(target :name f :arity 4)
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target a :expr (* 2 beat))
        \\(track :target p :pattern (euclid 3 8 0.9))
        \\(trigger :target f :every 1b)
    , &.{});
    defer p.deinit();
    const tracks = p.value.object.get("tracks").?.array.items;
    try t.expectEqual(@as(usize, 3), tracks.len);

    try t.expectEqualStrings("expr", tracks[0].object.get("source").?.string);
    try t.expectEqualStrings("(* 2 beat)", tracks[0].object.get("expr").?.string);
    try t.expectEqual(@as(usize, 0), tracks[0].object.get("keys").?.array.items.len);

    try t.expectEqualStrings("pattern", tracks[1].object.get("source").?.string);
    try t.expectEqualStrings("(euclid 3 8 0.9)", tracks[1].object.get("pattern").?.string);

    try t.expectEqualStrings("trigger", tracks[2].object.get("source").?.string);
    const trig = tracks[2].object.get("trigger").?.object;
    try t.expectEqualStrings("periodic", trig.get("kind").?.string);
    try t.expectEqual(@as(i64, 180180), trig.get("every").?.integer);
    try t.expectEqual(@as(i64, 0), trig.get("offset").?.integer);
}

test "ir: scenes, a tempo map, emit lanes and a control pin all surface" {
    var p = try irOf(t.allocator,
        \\(target :name r :arity 1)
        \\(target :name beat :arity 1)
        \\(transport :bpm 120 :meter [4 4] :dur 8bar :end loop :emit [beat])
        \\(tempo :at 8b :bpm 160)
        \\(control :id sway :type slider :min 0 :max 0.3 :value 0.12)
        \\(scene :name drop :at 2bar :dur 2bar
        \\  (track :target r
        \\    (key :at 0b :value 30)
        \\    (key :at 4b :value 140 :ease (steps :n 8))))
    , &.{});
    defer p.deinit();
    const root = p.value.object;

    const tr = root.get("transport").?.object;
    const emit = tr.get("emit").?.array.items;
    try t.expectEqual(@as(usize, 1), emit.len);
    try t.expectEqualStrings("beat", emit[0].object.get("name").?.string);
    try t.expectEqualStrings("beat", emit[0].object.get("target").?.string);

    // The tempo map: segment 0 is INCLUDED, so a consumer needs no join.
    const tempo = tr.get("tempo").?.array.items;
    try t.expectEqual(@as(usize, 2), tempo.len);
    try t.expectEqual(@as(i64, 0), tempo[0].object.get("tick").?.integer);
    try t.expectEqual(@as(f64, 120), num(tempo[0].object.get("bpm").?));
    try t.expectEqual(@as(i64, 8 * 180180), tempo[1].object.get("tick").?.integer);
    try t.expectEqual(@as(f64, 160), num(tempo[1].object.get("bpm").?));
    try t.expectEqual(@as(f64, 4), num(tempo[1].object.get("start_seconds").?));

    const scenes = root.get("scenes").?.array.items;
    try t.expectEqual(@as(usize, 1), scenes.len);
    try t.expectEqualStrings("drop", scenes[0].object.get("name").?.string);
    try t.expectEqual(@as(i64, 8 * 180180), scenes[0].object.get("start_tick").?.integer);

    // A scened track's key ticks are ABSOLUTE, and it names its scene.
    const tracks = root.get("tracks").?.array.items;
    try t.expectEqual(@as(i64, 0), tracks[0].object.get("scene").?.integer);
    try t.expectEqual(@as(i64, 8 * 180180), tracks[0].object.get("keys").?.array.items[0].object.get("at").?.integer);

    const controls = root.get("controls").?.array.items;
    try t.expectEqual(@as(usize, 1), controls.len);
    const c0 = controls[0].object;
    try t.expectEqualStrings("sway", c0.get("id").?.string);
    try t.expectEqualStrings("slider", c0.get("type").?.string);
    // An env-only control has no target — null, not a sentinel.
    try t.expectEqual(@as(std.json.Value, .null), c0.get("target").?);
    try t.expectEqual(@as(f64, 0.3), num(c0.get("max").?.array.items[0]));
    try t.expectEqual(@as(f64, 0.12), num(c0.get("value").?.array.items[0]));
    // The :value byte span is the editor's commit-to-text anchor: it must
    // bracket the literal, not the whole form.
    const vs = c0.get("value_span").?.object;
    try t.expectEqual(@as(i64, 4), vs.get("end").?.integer - vs.get("start").?.integer);
}

test "ir: host targets keep their indices and read as origin host" {
    const targets = [_]pacer.Compile.Target{
        .{ .name = "circle-radius", .ncomp = 1 },
        .{ .name = "tint", .ncomp = 3 },
    };
    var p = try irOf(t.allocator,
        \\(transport :bpm 120)
        \\(track :target tint :expr [1 0 0])
    , &targets);
    defer p.deinit();
    const got = p.value.object.get("targets").?.array.items;
    try t.expectEqual(@as(usize, 2), got.len);
    for (got) |g| try t.expectEqualStrings("host", g.object.get("origin").?.string);
    try t.expectEqual(@as(i64, 1), p.value.object.get("tracks").?.array.items[0].object.get("target_id").?.integer);
}

test "ir: every tick is a JSON-safe integer" {
    var p = try irOf(t.allocator,
        \\(target :name g :arity 1)
        \\(transport :bpm 120 :meter [4 4] :dur 4bar)
        \\(track :target g (key :at 0b :value 0) (key :at 16b :value 1))
    , &.{});
    defer p.deinit();
    const max: i64 = 1 << 53;
    for (p.value.object.get("tracks").?.array.items) |tr| {
        for (tr.object.get("keys").?.array.items) |k| {
            const at = k.object.get("at").?.integer; // .integer, never .float
            try t.expect(at >= -max and at <= max);
        }
    }
}

test "ir: a defective score keeps the whole shape, with empty payload arrays" {
    var p = try irOf(t.allocator,
        \\(transport :bpm 120)
        \\(track :target nonexistent :expr 1)
    , &.{});
    defer p.deinit();
    const root = p.value.object;
    try t.expectEqual(false, root.get("ok").?.bool);
    try t.expect(root.get("diagnostics").?.array.items.len > 0);
    // Present but empty — a consumer never branches on key existence.
    try t.expectEqual(@as(usize, 0), root.get("tracks").?.array.items.len);
    try t.expectEqual(@as(usize, 0), root.get("controls").?.array.items.len);
    try t.expectEqual(@as(usize, 0), root.get("scenes").?.array.items.len);
    try t.expectEqual(@as(std.json.Value, .null), root.get("transport").?);
}
