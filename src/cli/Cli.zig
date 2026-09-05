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

    // A defective score is NOT an error here: `init` succeeds, `evaluator`
    // stays null, and the diagnostics sit on `result`. Only OOM fails —
    // and then `driver` is undefined and must NOT be deinited, which is
    // why the defer comes after.
    var driver: pacer.Driver = undefined;
    try driver.init(gpa, &schema, source, cmd.targets);
    defer driver.deinit();

    const ctx: Envelope.Ctx = .{
        .result = &driver.result,
        .source = source,
        .index = &index,
        .path = cmd.path,
        .host_target_count = cmd.targets.len,
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
