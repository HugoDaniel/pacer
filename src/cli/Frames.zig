//! `pacer eval` — the write frames at a set of times, as JSON.
//!
//! ## Frames STREAM; they are never collected
//!
//! `Eval.evalSeconds` returns a slice ALIASING the evaluator's reused
//! entry buffer, so frame *i* is rendered in full before frame *i+1* is
//! sampled. Gathering frames into a list first would leave every element
//! pointing at the last frame's writes — silently, with no crash — which
//! is why two differing samples are a test rather than an assumption.
//!
//! ## The tick comes from the evaluator, never from a second conversion
//!
//! `evalSeconds` wraps SECONDS for a mapped score and then converts, while
//! `evalTicks` wraps in the tick domain. Calling `tickFromSeconds` again
//! here would answer a different question on any looping score, and
//! re-spelling the wrap would duplicate a pinned determinism seam. So the
//! frame's `tick` is `Evaluator.last_tick`, the probe that exists for
//! exactly this.

const std = @import("std");
const pacer = @import("pacer");
const Args = @import("Args.zig");
const Envelope = @import("Envelope.zig");
const Json = @import("Json.zig");
const Source = @import("Source.zig");
const Writer = std.Io.Writer;
const t = std.testing;

const Resolved = struct {
    index: usize,
    spec: Args.Override,
};

/// Write the `eval` envelope. Returns the exit code — 2 when a `--set`
/// names nothing, and then stdout has NOT been touched.
pub fn write(
    w: *Writer,
    err: *Writer,
    ctx: Envelope.Ctx,
    evaluator: ?*pacer.Eval.Evaluator,
    opts: Args.EvalOpts,
) Writer.Error!u8 {
    const ev = evaluator orelse {
        // No table, so no frames — but the shape does not vary with the
        // outcome, so every key still appears.
        try Envelope.writeHead(w, ctx, "eval");
        try w.writeAll(",\n  \"targets\":[],\n  \"overrides\":[],\n  \"frames\":[],\n  \"expr_failures\":0");
        try Envelope.writeTail(w);
        return Envelope.exitCode(ctx);
    };
    const controls = ctx.result.table.?.controls;

    // Resolve and apply every override BEFORE the first byte of stdout: a
    // `--set` that names nothing is a usage error, and a usage error must
    // leave stdout empty rather than half an object.
    var resolved: [pacer.TrackTable.MAX_CONTROLS]Resolved = undefined;
    var n_set: usize = 0;
    for (opts.sets) |spec| {
        if (n_set == resolved.len) {
            try err.print("pacer: more --set flags than the score has controls ({d})\n", .{controls.len});
            return 2;
        }
        const idx = resolve(spec, controls) orelse {
            try err.print("pacer: --set `{s}` names no control", .{spec.key});
            if (controls.len == 0) {
                try err.writeAll(" (this score declares none)\n");
            } else {
                try err.writeAll("; this score declares: ");
                for (controls, 0..) |c, i| {
                    if (i != 0) try err.writeAll(", ");
                    try err.print("{s} (slot {d})", .{ c.id, i });
                }
                try err.writeByte('\n');
            }
            return 2;
        };
        // `setControl` folds a bad index and a non-finite lane into one
        // false. The index is resolved above and the lanes were checked at
        // parse, so a false here would be a contract break, not user input.
        if (!ev.setControl(idx, spec.value)) {
            try err.print("pacer: --set `{s}` was rejected by the driver\n", .{spec.key});
            return 2;
        }
        resolved[n_set] = .{ .index = idx, .spec = spec };
        n_set += 1;
    }

    try Envelope.writeHead(w, ctx, "eval");

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

    // Echo the held overrides, each with the slot its key resolved to, so
    // a consumer reading this can address the same control numerically.
    try w.writeAll(",\n  \"overrides\":[");
    for (resolved[0..n_set], 0..) |r, i| {
        if (i != 0) try w.writeByte(',');
        try w.writeAll("\n    {\"key\":");
        try Json.string(w, r.spec.key);
        try w.print(",\"index\":{d},\"lanes\":{d},\"value\":", .{ r.index, r.spec.lanes });
        try Json.lanes(w, r.spec.value, r.spec.lanes);
        try w.writeByte('}');
    }
    if (n_set != 0) try w.writeAll("\n  ");
    try w.writeByte(']');

    // Explicit `--at` times first, in argv order, then the sweep. No
    // sorting and no dedup: the frames array indexes 1:1 with what was
    // asked, and sorting would hide a mistake.
    try w.writeAll(",\n  \"frames\":[");
    var written: usize = 0;
    for (opts.at) |time| {
        try writeFrame(w, ctx, ev, time, written);
        written += 1;
    }
    if (opts.sweep) |sweep| {
        for (0..sweep.count()) |i| {
            try writeFrame(w, ctx, ev, sweep.at(i), written);
            written += 1;
        }
    }
    if (written != 0) try w.writeAll("\n  ");
    try w.writeByte(']');

    try w.print(",\n  \"expr_failures\":{d}", .{ev.expr_failures});
    try Envelope.writeTail(w);
    return Envelope.exitCode(ctx);
}

/// A key that parsed as an integer addresses a slot directly; anything
/// else is a `(control :id …)` name. The control index space is document
/// order, which is what `TrackTable.controls` is.
fn resolve(spec: Args.Override, controls: []const pacer.TrackTable.Control) ?usize {
    if (spec.slot) |slot| return if (slot < controls.len) slot else null;
    for (controls, 0..) |c, i| {
        if (std.mem.eql(u8, c.id, spec.key)) return i;
    }
    return null;
}

fn writeFrame(
    w: *Writer,
    ctx: Envelope.Ctx,
    ev: *pacer.Eval.Evaluator,
    time: f64,
    ordinal: usize,
) Writer.Error!void {
    if (ordinal != 0) try w.writeByte(',');
    try w.writeAll("\n    {\"t\":");
    try Json.number(w, time);

    const entries = ev.evalSeconds(time) catch |e| {
        // `drv_eval` answers an out-of-range clock with a zero-length
        // frame; the CLI says so out loud and keeps going. An unreachable
        // time is data about the score, not a tool failure, so the exit
        // code does not move.
        try w.print(",\"tick\":null,\"out_of_range\":true,\"reason\":\"{s}\",\"writes\":[]}}", .{@errorName(e)});
        return;
    };
    try w.print(",\"tick\":{d},\"out_of_range\":false,\"writes\":[", .{ev.last_tick});
    for (entries, 0..) |e, i| {
        if (i != 0) try w.writeByte(',');
        try w.print("\n      {{\"target_id\":{d},\"target\":", .{e.target_id});
        try Json.string(w, ctx.targetName(e.target_id));
        // `flags` IS the registry index today; the JSON spells what it
        // means rather than what the struct field is called.
        try w.print(",\"registry\":{d},\"ncomp\":{d},\"value\":", .{ e.flags, e.ncomp });
        try Json.lanes(w, e.value, e.ncomp);
        try w.writeByte('}');
    }
    if (entries.len != 0) try w.writeAll("\n    ");
    try w.writeAll("]}");
}


// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Run = struct {
    code: u8,
    out: []u8,
    err: []u8,
    fn deinit(self: *Run, a: std.mem.Allocator) void {
        a.free(self.out);
        a.free(self.err);
    }
};

/// Compile, evaluate and render — the whole `eval` verb minus argv and io.
fn run(a: std.mem.Allocator, source: [:0]const u8, targets: []const pacer.Compile.Target, opts: Args.EvalOpts) !Run {
    var schema = try pacer.Schema.load(a);
    defer schema.deinit();
    // `Driver` owns the CompileResult/Evaluator pair; it must never move
    // once initialised, which a never-reassigned local satisfies.
    var driver: pacer.Driver = undefined;
    try driver.init(a, &schema, source, targets);
    defer driver.deinit();
    var index = try Source.LineIndex.build(a, source);
    defer index.deinit(a);

    var out: Writer.Allocating = .init(a);
    errdefer out.deinit();
    var err: Writer.Allocating = .init(a);
    errdefer err.deinit();
    const code = try write(&out.writer, &err.writer, .{
        .result = &driver.result,
        .source = source,
        .index = &index,
        .path = "t.sjon",
        .host_target_count = targets.len,
    }, if (driver.evaluator) |*ev| ev else null, opts);
    return .{ .code = code, .out = try out.toOwnedSlice(), .err = try err.toOwnedSlice() };
}

fn parsed(a: std.mem.Allocator, r: Run) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, a, r.out, .{});
}

fn num(v: std.json.Value) f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => std.math.nan(f64),
    };
}

const ramp: [:0]const u8 =
    \\(target :name radius :arity 1)
    \\(transport :bpm 120 :meter [4 4] :dur 4b :end loop)
    \\(track :target radius (key :at 0b :value 0) (key :at 4b :value 1))
;

test "eval: successive frames are rendered before the next sample is taken" {
    // `evalSeconds` returns a slice ALIASING the evaluator's reused entry
    // buffer, so the renderer must stream. Collecting frames first would
    // make every frame show the LAST one's writes — which is exactly what
    // two differing samples catch.
    var r = try run(t.allocator, ramp, &.{}, .{ .at = &.{ 0, 1 } });
    defer r.deinit(t.allocator);
    var p = try parsed(t.allocator, r);
    defer p.deinit();

    const frames = p.value.object.get("frames").?.array.items;
    try t.expectEqual(@as(usize, 2), frames.len);
    const v0 = num(frames[0].object.get("writes").?.array.items[0].object.get("value").?.array.items[0]);
    const v1 = num(frames[1].object.get("writes").?.array.items[0].object.get("value").?.array.items[0]);
    try t.expectEqual(@as(f64, 0), v0);
    try t.expectEqual(@as(f64, 0.5), v1);
}

test "eval: a frame reports the tick it was ACTUALLY computed at" {
    // dur is 4b = 2 s, so t = 2.5 s wraps to 0.5 s = beat 1 = tick 180180.
    var r = try run(t.allocator, ramp, &.{}, .{ .at = &.{2.5} });
    defer r.deinit(t.allocator);
    var p = try parsed(t.allocator, r);
    defer p.deinit();
    const f0 = p.value.object.get("frames").?.array.items[0].object;
    try t.expectEqual(@as(f64, 2.5), num(f0.get("t").?));
    try t.expectEqual(@as(i64, 180180), f0.get("tick").?.integer);
    try t.expectEqual(false, f0.get("out_of_range").?.bool);
}

test "eval: a sweep yields floor((to-from)*fps)+1 frames, endpoints included" {
    var r = try run(t.allocator, ramp, &.{}, .{ .sweep = .{ .from = 0, .to = 1, .fps = 4 } });
    defer r.deinit(t.allocator);
    var p = try parsed(t.allocator, r);
    defer p.deinit();
    const frames = p.value.object.get("frames").?.array.items;
    try t.expectEqual(@as(usize, 5), frames.len);
    try t.expectEqual(@as(f64, 0), num(frames[0].object.get("t").?));
    try t.expectEqual(@as(f64, 0.25), num(frames[1].object.get("t").?));
    try t.expectEqual(@as(f64, 1), num(frames[4].object.get("t").?));
}

test "eval: explicit --at times come before the sweep, in argv order" {
    var r = try run(t.allocator, ramp, &.{}, .{
        .at = &.{ 1.5, 0.25 },
        .sweep = .{ .from = 0, .to = 0.5, .fps = 2 },
    });
    defer r.deinit(t.allocator);
    var p = try parsed(t.allocator, r);
    defer p.deinit();
    const frames = p.value.object.get("frames").?.array.items;
    try t.expectEqual(@as(usize, 4), frames.len);
    try t.expectEqual(@as(f64, 1.5), num(frames[0].object.get("t").?));
    try t.expectEqual(@as(f64, 0.25), num(frames[1].object.get("t").?));
    try t.expectEqual(@as(f64, 0), num(frames[2].object.get("t").?));
}

const knob: [:0]const u8 =
    \\(target :name out :arity 1)
    \\(transport :bpm 120)
    \\(control :id depth :target out :min 0 :max 1 :value 0.25)
;

test "eval: --set holds a control by id, and by slot, for the whole run" {
    var by_id = try run(t.allocator, knob, &.{}, .{
        .at = &.{0},
        .sets = &.{.{ .key = "depth", .slot = null, .value = .{ 0.75, 0, 0, 0 }, .lanes = 1 }},
    });
    defer by_id.deinit(t.allocator);
    var p = try parsed(t.allocator, by_id);
    defer p.deinit();
    const writes = p.value.object.get("frames").?.array.items[0].object.get("writes").?.array.items;
    try t.expectEqual(@as(f64, 0.75), num(writes[0].object.get("value").?.array.items[0]));

    // The echo says WHICH slot the id resolved to, so a consumer can go
    // straight to the numeric form next time.
    const ov = p.value.object.get("overrides").?.array.items[0].object;
    try t.expectEqualStrings("depth", ov.get("key").?.string);
    try t.expectEqual(@as(i64, 0), ov.get("index").?.integer);

    var by_slot = try run(t.allocator, knob, &.{}, .{
        .at = &.{0},
        .sets = &.{.{ .key = "0", .slot = 0, .value = .{ 0.75, 0, 0, 0 }, .lanes = 1 }},
    });
    defer by_slot.deinit(t.allocator);
    var q = try parsed(t.allocator, by_slot);
    defer q.deinit();
    try t.expectEqual(
        @as(f64, 0.75),
        num(q.value.object.get("frames").?.array.items[0].object.get("writes").?.array.items[0].object.get("value").?.array.items[0]),
    );
}

test "eval: an unresolvable --set writes NOTHING to stdout and names what exists" {
    var r = try run(t.allocator, knob, &.{}, .{
        .at = &.{0},
        .sets = &.{.{ .key = "nope", .slot = null, .value = .{ 1, 0, 0, 0 }, .lanes = 1 }},
    });
    defer r.deinit(t.allocator);
    try t.expectEqual(@as(u8, 2), r.code);
    try t.expectEqualStrings("", r.out);
    try t.expect(std.mem.indexOf(u8, r.err, "nope") != null);
    // The message lists the ids the score actually declares.
    try t.expect(std.mem.indexOf(u8, r.err, "depth") != null);

    var slot = try run(t.allocator, knob, &.{}, .{
        .at = &.{0},
        .sets = &.{.{ .key = "9", .slot = 9, .value = .{ 1, 0, 0, 0 }, .lanes = 1 }},
    });
    defer slot.deinit(t.allocator);
    try t.expectEqual(@as(u8, 2), slot.code);
    try t.expectEqualStrings("", slot.out);
}

test "eval: an unreachable clock is data about the score, not a tool failure" {
    var r = try run(t.allocator, ramp, &.{}, .{ .at = &.{ 0, 1e300 } });
    defer r.deinit(t.allocator);
    // Exit stays 0: the score is fine, that time simply is not on the grid.
    try t.expectEqual(@as(u8, 0), r.code);
    var p = try parsed(t.allocator, r);
    defer p.deinit();
    const frames = p.value.object.get("frames").?.array.items;
    try t.expectEqual(@as(usize, 2), frames.len);
    const bad = frames[1].object;
    try t.expectEqual(true, bad.get("out_of_range").?.bool);
    try t.expectEqual(@as(std.json.Value, .null), bad.get("tick").?);
    try t.expectEqual(@as(usize, 0), bad.get("writes").?.array.items.len);
    try t.expect(bad.get("reason").?.string.len > 0);
}

test "eval: a runtime expr failure omits the write and is counted, not hidden" {
    // `(/ 1 (- 2 beat))` divides by zero at beat 2, which is 1.0 s at
    // 120 bpm. The frame keeps going and simply omits that track's write.
    var r = try run(t.allocator,
        \\(target :name a :arity 1)
        \\(target :name b :arity 1)
        \\(transport :bpm 120)
        \\(track :target a :expr (/ 1 (- 2 beat)))
        \\(track :target b :expr 1)
    , &.{}, .{ .at = &.{ 0, 1.0 } });
    defer r.deinit(t.allocator);
    try t.expectEqual(@as(u8, 0), r.code);
    var p = try parsed(t.allocator, r);
    defer p.deinit();
    const frames = p.value.object.get("frames").?.array.items;
    try t.expectEqual(@as(usize, 2), frames[0].object.get("writes").?.array.items.len);
    // The failing frame drops one write and keeps the other — an omission,
    // never a NaN reaching the buffer.
    try t.expectEqual(@as(usize, 1), frames[1].object.get("writes").?.array.items.len);
    try t.expectEqualStrings("b", frames[1].object.get("writes").?.array.items[0].object.get("target").?.string);
    try t.expectEqual(@as(i64, 1), p.value.object.get("expr_failures").?.integer);
}

test "eval: a defective score keeps the shape, with no frames" {
    var r = try run(t.allocator,
        \\(transport :bpm 120)
        \\(track :target nonexistent :expr 1)
    , &.{}, .{ .at = &.{0} });
    defer r.deinit(t.allocator);
    try t.expectEqual(@as(u8, 1), r.code);
    var p = try parsed(t.allocator, r);
    defer p.deinit();
    const root = p.value.object;
    try t.expectEqual(false, root.get("ok").?.bool);
    try t.expectEqual(@as(usize, 0), root.get("frames").?.array.items.len);
    try t.expect(root.get("diagnostics").?.array.items.len > 0);
}

test "eval: a write names its target and carries the registry, not the raw flags byte" {
    const targets = [_]pacer.Compile.Target{.{ .name = "gain", .ncomp = 1, .registry = 1 }};
    var r = try run(t.allocator,
        \\(transport :bpm 120)
        \\(track :target gain :expr 0.5)
    , &targets, .{ .at = &.{0} });
    defer r.deinit(t.allocator);
    var p = try parsed(t.allocator, r);
    defer p.deinit();
    const wr = p.value.object.get("frames").?.array.items[0].object.get("writes").?.array.items[0].object;
    try t.expectEqualStrings("gain", wr.get("target").?.string);
    try t.expectEqual(@as(i64, 0), wr.get("target_id").?.integer);
    try t.expectEqual(@as(i64, 1), wr.get("registry").?.integer);
    try t.expectEqual(@as(i64, 1), wr.get("ncomp").?.integer);
}
