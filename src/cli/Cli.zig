//! Verb dispatch and the one load path every verb shares.
//!
//! `run` is the TEST SEAM: it takes its two writers and its argv as
//! parameters, so every end-to-end test drives exactly the code the binary
//! runs, in process, under `std.testing.allocator` — which is also the
//! leak gate (`std.process.Init`'s allocator explicitly does not affect
//! the return code, so there is nothing to check at the process level).
//!
//! ## Channels
//!
//! `check` is a REPORT verb: its report is the product, so it goes to
//! stdout. `ir` and `eval` are DATA verbs: stdout carries JSON and nothing
//! else, diagnostics go to stderr, and on any failure stdout gets ZERO
//! bytes — a piped consumer never sees a half-written object. Usage errors
//! and `--help` are always stderr.

const std = @import("std");
const pacer = @import("pacer");
const sjon = @import("sjon");
const Args = @import("Args.zig");
const Diags = @import("Diags.zig");
const Envelope = @import("Envelope.zig");
const Frames = @import("Frames.zig");
const Ir = @import("Ir.zig");
const Pack = @import("Pack.zig");
const Source = @import("Source.zig");
const Writer = std.Io.Writer;
const Io = std.Io;
const Allocator = std.mem.Allocator;

comptime {
    // Ticks are emitted as bare JSON numbers, which is only safe while the
    // grid ceiling stays inside the integer range every JSON parser rounds
    // through — which is exactly what MAX_TICK is chosen to be.
    std.debug.assert(sjon.Pattern.MAX_TICK <= 1 << 53);
}

/// Exit codes — SJON's table, not pngine's. A pacer score IS an SJON
/// document and the two binaries will sit in the same pipelines, so
/// `sjon check x.sjon && pacer check x.sjon` must not mean two different
/// things by the same number.
pub const Exit = struct {
    /// Ran, and the score compiled clean.
    pub const ok: u8 = 0;
    /// The score has diagnostics. The JSON on stdout is still complete
    /// and well-formed — `ok: false` with a populated `diagnostics`.
    pub const errors: u8 = 1;
    /// Bad invocation: unknown verb or flag, malformed `--target`, or an
    /// input that could not be read. A file you named that is not there is
    /// a user error like any other. Nothing reaches stdout.
    pub const usage: u8 = 2;
    /// Anything `run` propagates — OOM, a dead stdout. `main` collapses
    /// the error set here rather than letting the Zig runtime print a
    /// trace and exit 1, which would be indistinguishable from "your score
    /// has errors".
    pub const internal: u8 = 3;
};

/// Everything `run` propagates to `main`, which collapses all of it to
/// `Exit.internal`. The narrowness IS the contract: a verb reports the
/// USER's problem as a message and an exit code, never as a Zig error.
pub const Error = Allocator.Error || Writer.Error;

pub const usage_text =
    \\pacer — a deterministic animation driver conducted by an SJON score.
    \\
    \\Usage:
    \\  pacer check FILE            Validate a score; report diagnostics.
    \\  pacer check -               Validate from stdin.
    \\  pacer ir FILE               Print the compiled IR as JSON.
    \\  pacer eval FILE --at SECS   Print the write frames at given times.
    \\  pacer pack FILE             Compile the score to a 'PACB' file.
    \\
    \\Options:
    \\  --target NAME[:ncomp[:registry]]
    \\                              Declare one host registry entry. Repeatable;
    \\                              flat order is the target_id space. ncomp
    \\                              defaults to 1, registry to 0. Omit entirely
    \\                              for a compose-mode score, which declares its
    \\                              own targets with (target ...).
    \\  --json                      Emit the JSON envelope instead of the
    \\                              human report (check only).
    \\
    \\Options for eval:
    \\  --at SECONDS                Sample one time. Repeatable; order is kept.
    \\  --from S --to S --fps N     Sweep a range: t = from + i/fps, endpoint
    \\                              included. All three flags or none.
    \\  --set ID=V[,V,V,V]          Hold a (control ...) for the whole run. ID
    \\                              is a control :id, or a slot index.
    \\
    \\Options for pack:
    \\  --targets-json FILE         Host registry from a pngine getUniforms
    \\                              dump: name -> {"type", "elemCount"}.
    \\                              Arrays and unknown types are skipped; file
    \\                              order is the target_id space, registry 0.
    \\  --out FILE.pacb             Where the 'PACB' bytes go. Default: the
    \\                              score path with .pacb; required when the
    \\                              score is stdin. Stdout stays JSON.
    \\
    \\  -h, --help                  Show this help.
    \\  -V, --version               Show the version.
    \\
    \\Exit codes:
    \\  0  No diagnostics.
    \\  1  The score has diagnostics.
    \\  2  Usage error (bad flags, or an input that could not be read).
    \\  3  Internal error (out of memory, or a dead output stream).
    \\
;

pub fn run(
    gpa: Allocator,
    io: Io,
    argv: []const [:0]const u8,
    out: *Writer,
    err: *Writer,
) Error!u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    switch (Args.parse(arena_state.allocator(), argv)) {
        .help => {
            try err.writeAll(usage_text);
            return Exit.ok;
        },
        .version => {
            try err.print("pacer {s}\n", .{pacer.version});
            return Exit.ok;
        },
        .usage => |message| {
            try err.print("pacer: {s}\n\n", .{message});
            try err.writeAll(usage_text);
            return Exit.usage;
        },
        .command => |cmd| return runCommand(gpa, io, cmd, out, err),
    }
}

/// The one load path all verbs share.
///
/// Lifetime order is the point, and it is the nesting CLAUDE.md names:
/// `Schema ⊃ CompileResult ⊃ Evaluator`, torn down inside-out. `Driver`
/// owns the inner two (in-place `init` — the pointer receiver IS the
/// placement contract, so it is never moved after); `Schema` is built here,
/// above it, and deinits last.
///
/// `cmd.targets` alias ARGV, which is fine: `Compile.Target.name` is
/// borrowed for the compile call only — `CompileResult.targets` copies
/// every name it keeps into the result's arena.
fn runCommand(gpa: Allocator, io: Io, cmd: Args.Command, out: *Writer, err: *Writer) Error!u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const source = Source.load(a, io, cmd.path) catch |e| {
        try err.print("pacer: {s}: {s}\n", .{ Source.label(cmd.path), switch (e) {
            error.TooLarge => "score exceeds the input cap",
            error.ReadFailed => "could not read",
            error.OutOfMemory => return error.OutOfMemory,
        } });
        return Exit.usage;
    };
    var index = try Source.LineIndex.build(a, source);
    defer index.deinit(a);

    var schema = try pacer.Schema.load(gpa);
    defer schema.deinit();

    // `pack` is the one verb whose flags shape the load itself: the
    // `--targets-json` registry feeds the compile join, so the adapter
    // runs BEFORE `Driver.init`. Reflection entries come first, then
    // any `--target` flags — one flat order, the target_id space.
    var host_targets: []const pacer.Compile.Target = cmd.targets;
    if (cmd.verb == .pack) {
        if (cmd.pack.targets_json) |json_path| {
            host_targets = Pack.hostJoin(a, io, json_path, cmd.targets) catch |e| {
                if (e == error.OutOfMemory) return error.OutOfMemory;
                try err.print("pacer: {s}: {s}\n", .{ json_path, Pack.joinErrorMessage(e) });
                return Exit.usage;
            };
        }
    }

    // A defective score is NOT an error here: `init` succeeds, `evaluator`
    // stays null, and the diagnostics sit on `result`. Only OOM fails —
    // and then `driver` is undefined and must NOT be deinited, which is
    // why the defer comes after.
    var driver: pacer.Driver = undefined;
    try driver.init(gpa, &schema, source, host_targets);
    defer driver.deinit();

    const ctx: Envelope.Ctx = .{
        .result = &driver.result,
        .source = source,
        .index = &index,
        .path = cmd.path,
        .host_target_count = host_targets.len,
    };
    return switch (cmd.verb) {
        .check => if (cmd.json) Diags.renderJson(out, ctx) else Diags.renderHuman(out, ctx),
        // A DATA verb: stdout is JSON only, so its diagnostics go to
        // stderr as well as into the envelope — a `| jq` pipeline that
        // discards stderr still sees a complete, parseable object.
        .ir => blk: {
            const code = try Ir.write(out, ctx);
            if (code != 0) _ = try Diags.renderHuman(err, ctx);
            break :blk code;
        },
        .eval => blk: {
            const ev = if (driver.evaluator) |*e| e else null;
            const code = try Frames.write(out, err, ctx, ev, cmd.eval);
            if (code == 1) _ = try Diags.renderHuman(err, ctx);
            break :blk code;
        },
        .pack => blk: {
            // Pack preflight (the v1 gates) rides the SAME envelope the
            // compile's own diagnostics do: ordinary pacer records,
            // collection over abort. A refusal is data about the score
            // (exit 1) — not a usage error, not an internal one.
            var packable = true;
            if (driver.result.table != null) {
                var refused: std.ArrayList(pacer.Compile.Diagnostic) = .empty;
                try pacer.PacbEncode.preflight(a, &driver.result, &refused);
                if (refused.items.len > 0) {
                    // `diagnostics` is a slice: rebuild it with the
                    // refusals appended. `ctx` aliases this same result,
                    // so the envelope and the human render see them.
                    const all = a.alloc(
                        pacer.Compile.Diagnostic,
                        driver.result.diagnostics.len + refused.items.len,
                    ) catch return error.OutOfMemory;
                    @memcpy(all[0..driver.result.diagnostics.len], driver.result.diagnostics);
                    @memcpy(all[driver.result.diagnostics.len..], refused.items);
                    driver.result.diagnostics = all;
                    packable = false;
                }
            }
            const code = try Pack.write(gpa, io, out, err, ctx, host_targets, cmd.pack, packable);
            if (code == Exit.errors) _ = try Diags.renderHuman(err, ctx);
            break :blk code;
        },
    };
}

const t = std.testing;
test {
    // `src/root.zig`'s discovery block cannot reach these: they
    // `@import("pacer")`, which inside the core test binary would resolve
    // to a second, distinct instance of the module. So `Cli.zig` plays
    // root.zig's role one level down, and `build.zig` roots the CLI test
    // artifact here.
    _ = @import("Args.zig");
    _ = @import("Diags.zig");
    _ = @import("Envelope.zig");
    _ = @import("Frames.zig");
    _ = @import("Ir.zig");
    _ = @import("Json.zig");
    _ = @import("Pack.zig");
    _ = @import("Source.zig");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Captured = struct {
    code: u8,
    out: std.Io.Writer.Allocating,
    err: std.Io.Writer.Allocating,
    fn deinit(self: *Captured) void {
        self.out.deinit();
        self.err.deinit();
    }
};

/// Drive `run` in process, under `std.testing.allocator` so a leak in any
/// verb fails the test rather than merely being reported. `argv` must
/// outlive the call: `--target` names are BORROWED all the way into
/// `CompileResult.targets`.
fn invoke(argv: []const [:0]const u8) !Captured {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    var err: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer err.deinit();
    const code = try run(t.allocator, std.testing.io, argv, &out.writer, &err.writer);
    return .{ .code = code, .out = out, .err = err };
}

/// An absolute path to a repo file. Handed in by `build.zig` rather than
/// resolved from the cwd, which depends on where `zig build` was invoked.
fn repoPath(a: std.mem.Allocator, rel: []const u8) ![:0]u8 {
    const root = @import("build_options").repo_root;
    return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, rel }, 0);
}

test "check: a compose-mode score needs no targets and exits ok" {
    const path = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "check", path });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());
    try t.expect(std.mem.indexOf(u8, c.out.written(), "no diagnostics") != null);
}

test "check --json: a clean score is a well-formed envelope with ok true" {
    const path = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "check", path, "--json" });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try t.expectEqual(true, root.get("ok").?.bool);
    try t.expectEqualStrings("check", root.get("command").?.string);
    try t.expectEqual(@as(usize, 0), root.get("diagnostics").?.array.items.len);
    try t.expectEqual(@as(i64, 0), root.get("counts").?.object.get("errors").?.integer);
    try t.expectEqualStrings(pacer.version, root.get("pacer").?.object.get("version").?.string);
}

test "check --json: diag-controls reports its five diagnostics and exits 1" {
    // The same score and host registry the corpus pins, so this test and
    // `corpus/diag-controls/expected.sjon` move together.
    const path = try repoPath(t.allocator, "corpus/diag-controls/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "check", path, "--target", "tint:3", "--json" });
    defer c.deinit();
    try t.expectEqual(Exit.errors, c.code);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try t.expectEqual(false, root.get("ok").?.bool);
    const diags = root.get("diagnostics").?.array.items;
    try t.expectEqual(@as(usize, 5), diags.len);
    try t.expectEqual(@as(i64, 5), root.get("counts").?.object.get("errors").?.integer);

    // Codes ride as NAMES beside the wire ordinal — the whole reason the
    // CLI renders from memory rather than from the 'PACD' blob.
    const first = diags[0].object;
    try t.expectEqualStrings("pacer", first.get("producer").?.string);
    try t.expectEqualStrings("control_duplicate_id", first.get("code").?.string);
    try t.expectEqual(@as(i64, 20), first.get("code_id").?.integer);
    // Spans carry byte offsets AND a 1-based line/col the CLI computes.
    const span = first.get("span").?.object;
    try t.expect(span.get("line").?.integer >= 1);
    try t.expect(span.get("col").?.integer >= 1);
}

test "check: the human report is grep-stable file:line:col and rides stdout" {
    const path = try repoPath(t.allocator, "corpus/diag-controls/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "check", path, "--target", "tint:3" });
    defer c.deinit();
    try t.expectEqual(Exit.errors, c.code);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "control_duplicate_id") != null);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "5 errors") != null);
}

test "ir: stdout is JSON alone, and a defective score still parses" {
    // A DATA verb, so the human diagnostics go to stderr while stdout
    // stays a single complete object — `pacer ir bad.sjon 2>/dev/null |
    // jq` must still work.
    const path = try repoPath(t.allocator, "corpus/diag-controls/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "ir", path, "--target", "tint:3" });
    defer c.deinit();
    try t.expectEqual(Exit.errors, c.code);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "control_duplicate_id") != null);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    try t.expectEqual(false, parsed.value.object.get("ok").?.bool);
    try t.expectEqualStrings("ir", parsed.value.object.get("command").?.string);
    try t.expectEqual(@as(usize, 5), parsed.value.object.get("diagnostics").?.array.items.len);
}

test "a usage error writes nothing to stdout, so a piped consumer sees no half object" {
    var c = try invoke(&.{ "pacer", "check", "--bogus", "a.sjon" });
    defer c.deinit();
    try t.expectEqual(Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "--bogus") != null);
}

test "an unreadable input is a usage error, not an internal one" {
    var c = try invoke(&.{ "pacer", "check", "no/such/score.sjon" });
    defer c.deinit();
    try t.expectEqual(Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
}

test "--help exits ok on stderr; stdout stays free for data" {
    var c = try invoke(&.{ "pacer", "--help" });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "pacer check") != null);
}

// ---------------------------------------------------------------------------
// pack
// ---------------------------------------------------------------------------

test "pack: a clean compose-mode score reports ok under command pack" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/clean.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);
    const path = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "pack", path, "--out", out });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try t.expectEqualStrings("pack", root.get("command").?.string);
    try t.expectEqual(true, root.get("ok").?.bool);
    try t.expectEqual(@as(usize, 0), root.get("diagnostics").?.array.items.len);
}

test "pack: a defective score keeps the envelope shape and exits 1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/defective.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);
    const path = try repoPath(t.allocator, "corpus/diag-controls/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "pack", path, "--target", "tint:3", "--out", out });
    defer c.deinit();
    try t.expectEqual(Exit.errors, c.code);

    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try t.expectEqual(false, root.get("ok").?.bool);
    try t.expectEqualStrings("pack", root.get("command").?.string);
    try t.expectEqual(@as(usize, 5), root.get("diagnostics").?.array.items.len);
    // The human rendering rides stderr, like the other data verbs.
    try t.expect(std.mem.indexOf(u8, c.err.written(), "control_duplicate_id") != null);
}

test "pack: stdin without --out is a usage error, nothing on stdout" {
    var c = try invoke(&.{ "pacer", "pack", "-" });
    defer c.deinit();
    try t.expectEqual(Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "--out") != null);
}

test "pack: --targets-json feeds the compile join" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const reflect = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/reflect.json", .{tmp.sub_path}, 0);
    defer t.allocator.free(reflect);
    const score = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/score.sjon", .{tmp.sub_path}, 0);
    defer t.allocator.free(score);
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/out.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "reflect.json",
        .data =
        \\{ "glow": { "type": "f32", "elemCount": 0 },
        \\  "tint": { "type": "vec3f", "elemCount": 0 } }
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "score.sjon",
        .data =
        \\(transport :bpm 120 :meter [4 4])
        \\(track :target glow
        \\  (key :at 0b :value 0.1)
        \\  (key :at 4b :value 0.9 :ease out-cubic))
        ,
    });

    // With the reflection: compiles clean against the joined registry.
    var ok_run = try invoke(&.{ "pacer", "pack", score, "--targets-json", reflect, "--out", out });
    defer ok_run.deinit();
    try t.expectEqual(Exit.ok, ok_run.code);
    try t.expect(std.mem.indexOf(u8, ok_run.out.written(), "\"ok\":true") != null);

    // Without it: the join is empty and the score's own diagnostics say
    // so — the adapter never mines the score for target names.
    var bare = try invoke(&.{ "pacer", "pack", score, "--out", out });
    defer bare.deinit();
    try t.expectEqual(Exit.errors, bare.code);
    try t.expect(std.mem.indexOf(u8, bare.out.written(), "unknown_target") != null);
}

test "pack: a malformed targets-json file is a usage error naming the file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const reflect = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/reflect.json", .{tmp.sub_path}, 0);
    defer t.allocator.free(reflect);
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/out.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "reflect.json", .data = "[1,2,3]" });

    const path = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "pack", path, "--targets-json", reflect, "--out", out });
    defer c.deinit();
    try t.expectEqual(Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "reflect.json") != null);
    try t.expect(std.mem.indexOf(u8, c.err.written(), "reflection") != null);
}

test "pack: an over-long target name is a usage error, not a codec assert" {
    // Final-review I2 (binary01-fc): both host-registry inputs a pack
    // can name — a --target flag and a reflection entry — are bounded
    // by the 'PACT' name_len u16 field, refused as usage (exit 2)
    // BEFORE the codec's assert can see the bytes.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cap = std.math.maxInt(u16);

    const path = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(path);
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/o.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);

    // argv --target: the long name is plain ASCII, exactly one byte over.
    const over = try t.allocator.allocSentinel(u8, cap + 1, 0);
    defer t.allocator.free(over);
    @memset(over, 'x');
    var c = try invoke(&.{ "pacer", "pack", path, "--target", over, "--out", out });
    defer c.deinit();
    try t.expectEqual(Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "65535") != null);

    // reflection file: same boundary, the adapter's own refusal.
    const reflect_json = blk: {
        const at_cap = try t.allocator.alloc(u8, cap);
        defer t.allocator.free(at_cap);
        @memset(at_cap, 'y');
        const over2 = try t.allocator.alloc(u8, cap + 1);
        defer t.allocator.free(over2);
        @memset(over2, 'z');
        break :blk try std.fmt.allocPrint(t.allocator, "{{\"{s}\":{{\"type\":\"f32\",\"elemCount\":0}},\"{s}\":{{\"type\":\"f32\",\"elemCount\":0}}}}", .{ at_cap, over2 });
    };
    defer t.allocator.free(reflect_json);
    const reflect = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/r.json", .{tmp.sub_path}, 0);
    defer t.allocator.free(reflect);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "r.json", .data = reflect_json });
    var c2 = try invoke(&.{ "pacer", "pack", path, "--targets-json", reflect, "--out", out });
    defer c2.deinit();
    try t.expectEqual(Exit.usage, c2.code);
    try t.expectEqualStrings("", c2.out.written());
    try t.expect(std.mem.indexOf(u8, c2.err.written(), "r.json") != null);
}

test "pack: a :pattern track packs (refusal lifted 2026-10-22, A3+A4)" {
    // The same registry `cli_golden.sh` pins for starter (its STARTER
    // argv), so this pack and the starter golden move together. Starter
    // compiles CLEAN against it and — since the interim refusal was
    // lifted (plan 06 A3+A4; the SJON pattern query env delivered and
    // adopted) — packs: the `:pattern` track rides the PACB as compact
    // IR, `required_features` bit0 set, exactly like `corpus` replay.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/starter.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);
    const path = try repoPath(t.allocator, "examples/starter.score.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{
        "pacer",     "pack",            path,
        "--target",  "circle-radius",   "--target",
        "circle-x",  "--target",        "circle-y",
        "--target",  "tint:3",          "--target",
        "flash:4",   "--target",        "spark",
        "--target",  "master-gain:1:1", "--target",
        "click:4:1", "--out",           out,
    });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);
    // The COMPILE succeeded, so `ok` stays true (docs/cli.md); the pack
    // is no longer null — the envelope carries the real written blob.
    // The wire spelling has no space after the colon; this pin is exact
    // on purpose.
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"ok\":true") != null);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "pack_patterns_unsupported") == null);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"pack\":{") != null);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"sections\":") != null);
    // The blob exists — a successful pack lands real bytes.
    const blob = try tmp.dir.readFileAlloc(std.testing.io, "starter.pacb", t.allocator, .limited(8 << 20));
    defer t.allocator.free(blob);
    try t.expect(blob.len > 4);
    try t.expectEqualSlices(u8, "PACB", blob[0..4]);
    // No temp file left behind — the write is atomic.
    try t.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "starter.pacb.tmp", .{}));
}

test "pack: a malformed time position is an ordinary exit-1 diagnostic, never a crash" {
    // Final-review I1 pin (binary01-fc): the validator owns the
    // user-facing error (bare `:at` integers caught at the element,
    // with a span); pack renders it as data — exit 1, complete
    // envelope, `ok:false` (the compile itself failed), nothing
    // written. The builder's defense-in-depth guards sit behind this.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "score.sjon",
        .data = "(transport :bpm 120 :meter [4 4])\n(trigger :target radius :at [1 2 3])\n",
    });
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/out.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);
    const path = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/score.sjon", .{tmp.sub_path}, 0);
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "pack", path, "--out", out });
    defer c.deinit();
    try t.expectEqual(Exit.errors, c.code);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"pack\":null") != null);
    try t.expect(std.mem.indexOf(u8, c.out.written(), "\"ok\":false") != null);
    // The diagnostic is the validator's own words, rendered as data.
    try t.expect(std.mem.indexOf(u8, c.out.written(), "without unit") != null);
    // Nothing landed, no temp left.
    try t.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "out.pacb", .{}));
    try t.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "out.pacb.tmp", .{}));
}

test "pack: a clean compose-mode score lands a decodable .pacb" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/landed.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);
    const path = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "pack", path, "--out", out });
    defer c.deinit();
    try t.expectEqual(Exit.ok, c.code);
    try t.expectEqualStrings("", c.err.written());

    // The report says what landed, where, and how big — the blob itself
    // never joins stdout.
    var parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, c.out.written(), .{});
    defer parsed.deinit();
    const pack = parsed.value.object.get("pack").?.object;
    try t.expectEqualStrings(out, pack.get("out").?.string);
    try t.expect(pack.get("bytes").?.integer > 0);
    try t.expect(pack.get("sections").?.integer >= 2);
    try t.expectEqual(@as(i64, 0), pack.get("targets").?.object.get("host").?.integer);
    try t.expectEqual(@as(i64, 3), pack.get("targets").?.object.get("declared").?.integer);
    try t.expect(pack.get("pacm_bytes").?.integer > 0);

    // The file: exactly the reported size, and it decodes clean back to
    // the score's own shape (three declared targets, 120 bpm).
    const blob = try tmp.dir.readFileAlloc(std.testing.io, "landed.pacb", t.allocator, .limited(1 << 20));
    defer t.allocator.free(blob);
    try t.expectEqual(@as(usize, @intCast(pack.get("bytes").?.integer)), blob.len);
    var refusal: pacer.Pacb.Refusal = undefined;
    var decoded = try pacer.Pacb.decode(t.allocator, blob, &refusal);
    defer decoded.deinit();
    try t.expectEqual(@as(usize, 3), decoded.declared.len);
    try t.expectEqual(@as(usize, 3), decoded.tracks.len);
    try t.expectEqual(@as(usize, 4), decoded.keys.len);
}

test "pack: an --out that cannot be written is a usage error, stdout untouched" {
    const path = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(path);
    var c = try invoke(&.{ "pacer", "pack", path, "--out", "no/such/dir/x.pacb" });
    defer c.deinit();
    try t.expectEqual(Exit.usage, c.code);
    try t.expectEqualStrings("", c.out.written());
    try t.expect(std.mem.indexOf(u8, c.err.written(), "no/such/dir/x.pacb") != null);
}

// Final-review L3 (binary01-fc): the atomic write's MID-FAILURE arm.
// The test above covers refusal at create (no temp ever exists); this
// one forces a refusal PART-WAY through the blob — a real OS EFBIG via
// RLIMIT_FSIZE in a forked child (SIGXFSZ ignored there so the write
// returns instead of killing the writer), with the limit set to half
// the blob's measured size so genuine partial bytes land first. From
// OUTSIDE the child, a mid-write refusal must leave: exit 2, stdout
// untouched, the prior destination byte-identical (the rename never
// ran), and NO `<out>.tmp` behind. Not a mock: the kernel refuses.
const fork_c = struct {
    extern "c" fn fork() c_int;
    extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
    extern "c" fn _exit(code: c_int) noreturn;
};

test "pack: a real mid-write refusal leaves no temp and never touches the prior output" {
    // OpenBSD-only mechanics (fork/setrlimit/SIGXFSZ); the build's only
    // native test host is obs, but keep the guard honest anyway.
    if (@import("builtin").os.tag != .openbsd) return error.SkipZigTest;

    const prior = "PRIOR-OUTPUT-BYTES";
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/out.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(out);
    const tmp_out = try std.fmt.allocPrint(t.allocator, "{s}.tmp", .{out});
    defer t.allocator.free(tmp_out);
    const result = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/result.txt", .{tmp.sub_path}, 0);
    defer t.allocator.free(result);
    const score = try repoPath(t.allocator, "corpus/target-declared/doc.sjon");
    defer t.allocator.free(score);

    // Measure the real blob first: a successful pack's report carries
    // `"bytes":N`. The refusal limit is half of that, so the temp file
    // provably holds PART of the blob when the kernel says no.
    const probe_out = try std.fmt.allocPrintSentinel(t.allocator, ".zig-cache/tmp/{s}/probe.pacb", .{tmp.sub_path}, 0);
    defer t.allocator.free(probe_out);
    var probe = try invoke(&.{ "pacer", "pack", score, "--out", probe_out });
    defer probe.deinit();
    try t.expectEqual(Exit.ok, probe.code);
    const bytes_field = std.mem.indexOf(u8, probe.out.written(), "\"bytes\":") orelse
        return error.TestUnexpectedResult;
    const digits = probe.out.written()[bytes_field + "\"bytes\":".len ..];
    var n: usize = 0;
    for (digits) |ch| {
        if (ch < '0' or ch > '9') break;
        n = n * 10 + (ch - '0');
    }
    try t.expect(n > 1);
    const fsize: std.posix.rlim_t = @intCast(n / 2);

    // Seed the destination with prior bytes — the failure must leave
    // them untouched (the rename is the only thing that ever replaces).
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = out, .data = prior });

    // Ignore SIGXFSZ pre-fork so the child's refused write RETURNS
    // EFBIG instead of dying by signal; restore the disposition after.
    const ign = std.posix.Sigaction{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    var old: std.posix.Sigaction = undefined;
    std.posix.sigaction(std.posix.SIG.XFSZ, &ign, &old);

    const pid = fork_c.fork();
    try t.expect(pid >= 0);
    if (pid == 0) {
        // Child: cap file sizes at half the blob, run the REAL verb.
        std.posix.setrlimit(.FSIZE, .{ .cur = fsize, .max = fsize }) catch fork_c._exit(99);
        var cout: std.Io.Writer.Allocating = .init(t.allocator);
        var cerr: std.Io.Writer.Allocating = .init(t.allocator);
        const code = run(t.allocator, std.testing.io, &.{ "pacer", "pack", score, "--out", out }, &cout.writer, &cerr.writer) catch fork_c._exit(98);
        var buf: [48]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "{d} {d} {d}", .{ code, cout.written().len, cerr.written().len }) catch fork_c._exit(97);
        std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = result, .data = line }) catch fork_c._exit(96);
        fork_c._exit(0);
    }
    var status: c_int = 0;
    _ = fork_c.waitpid(pid, &status, 0);
    std.posix.sigaction(std.posix.SIG.XFSZ, &old, null);

    const ustatus: u32 = @bitCast(status);
    try t.expect(std.posix.W.IFEXITED(ustatus));
    try t.expectEqual(@as(u32, 0), std.posix.W.EXITSTATUS(ustatus));

    // The child's verdict: usage-class refusal, stdout untouched.
    const marker = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, result, t.allocator, .limited(4096));
    defer t.allocator.free(marker);
    var parts = std.mem.tokenizeScalar(u8, marker, ' ');
    const code = try std.fmt.parseInt(u8, parts.next() orelse return error.TestUnexpectedResult, 10);
    const outlen = try std.fmt.parseInt(usize, parts.next() orelse return error.TestUnexpectedResult, 10);
    try t.expectEqual(Exit.usage, code);
    try t.expectEqual(@as(usize, 0), outlen);

    // The prior output is byte-identical — the rename never ran.
    const after = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, out, t.allocator, .limited(4096));
    defer t.allocator.free(after);
    try t.expectEqualStrings(prior, after);

    // And the partial temp is GONE — no `<out>.tmp` litter behind a
    // refused mid-write. (RED until the write-failure arm cleans up.)
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, tmp_out, .{}));
}
