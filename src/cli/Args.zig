//! Argument parsing — PURE. No io, no printing, no process state: `parse`
//! returns a value and the caller renders it, which is what lets every
//! invocation be tested by calling one function.
//!
//! Flag style is `--flag VALUE` (space-separated), matching pngine's CLI
//! rather than SJON's `--flag=value`, because the values here are
//! whitespace-free tokens (`tint:3`, `sway-amt=0.2`) that read better
//! unglued.
//!
//! Everything a `Command` borrows — the path, target names — ALIASES
//! argv. That is deliberate and load-bearing: `Compile.Target.name` is
//! borrowed for the compile's lifetime and `CompileResult.targets` keeps
//! aliasing it, so a rendered target name is read straight out of argv.
//! argv lives on the process arena for the whole run. A caller that
//! synthesises argv (a test) must keep it alive just as long.

const std = @import("std");
const pacer = @import("pacer");
const Allocator = std.mem.Allocator;

pub const Verb = enum { check, ir };

pub const Command = struct {
    verb: Verb,
    /// Score path, or `-` for stdin. Aliases argv.
    path: []const u8,
    /// Host registries in FLAT ORDER — which is the `target_id` space,
    /// exactly as a `times.sjon`'s `(target …)` sequence is. Empty is
    /// legal and is the default: a compose-mode score declares its own.
    targets: []const pacer.Compile.Target,
    json: bool = false,
};

pub const Action = union(enum) {
    help,
    version,
    /// A message for stderr. The caller prints it and the usage text.
    usage: []const u8,
    command: Command,
};

pub fn parse(a: Allocator, argv: []const [:0]const u8) Action {
    // `--help` anywhere wins, scanned up front so it answers even when a
    // required positional is missing (`pacer check --help` must print help,
    // not "check requires a score path").
    for (argv[@min(1, argv.len)..]) |arg| {
        if (eq(arg, "--help") or eq(arg, "-h")) return .help;
        if (eq(arg, "--version") or eq(arg, "-V")) return .version;
    }
    if (argv.len < 2) return .{ .usage = "expected a command" };

    const verb = std.meta.stringToEnum(Verb, argv[1]) orelse
        return .{ .usage = say(a, "unknown command `{s}`", .{argv[1]}, "unknown command") };

    var out: Command = .{ .verb = verb, .path = undefined, .targets = &.{}, .json = false };
    var path: ?[]const u8 = null;
    var targets: std.ArrayList(pacer.Compile.Target) = .empty;

    var i: usize = 2;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eq(arg, "--target")) {
            i += 1;
            if (i >= argv.len) return .{ .usage = "--target requires a value" };
            const tg = parseTarget(argv[i]) catch
                return .{ .usage = say(a, "bad --target `{s}` (expected NAME[:ncomp[:registry]], ncomp 1..4)", .{argv[i]}, "bad --target") };
            // `Compile.compile` ASSERTS this bound; refuse before it fires.
            if (targets.items.len == pacer.Compile.MAX_TARGETS)
                return .{ .usage = say(a, "too many --target flags (max {d})", .{pacer.Compile.MAX_TARGETS}, "too many --target flags") };
            targets.append(a, tg) catch return .{ .usage = "out of memory collecting --target" };
        } else if (eq(arg, "--json")) {
            out.json = true;
        } else if (isFlag(arg)) {
            return .{ .usage = say(a, "unknown option `{s}`", .{arg}, "unknown option") };
        } else if (path != null) {
            return .{ .usage = say(a, "unexpected extra argument `{s}`", .{arg}, "unexpected extra argument") };
        } else {
            path = arg;
        }
    }

    out.path = path orelse
        return .{ .usage = say(a, "{s} requires a score path (use `-` for stdin)", .{@tagName(verb)}, "missing score path") };
    out.targets = targets.toOwnedSlice(a) catch return .{ .usage = "out of memory collecting --target" };
    return .{ .command = out };
}

/// `NAME[:ncomp[:registry]]`. ncomp defaults 1, registry 0 — the same
/// defaults `schema/pacer-corpus.sjon` gives a harness `(target …)`.
fn parseTarget(spec: []const u8) error{BadTarget}!pacer.Compile.Target {
    var it = std.mem.splitScalar(u8, spec, ':');
    const name = it.next().?;
    if (name.len == 0) return error.BadTarget;

    var out: pacer.Compile.Target = .{ .name = name, .ncomp = 1, .registry = 0 };
    if (it.next()) |s| {
        out.ncomp = std.fmt.parseInt(u8, s, 10) catch return error.BadTarget;
        if (out.ncomp < 1 or out.ncomp > 4) return error.BadTarget;
    }
    if (it.next()) |s| {
        out.registry = std.fmt.parseInt(u8, s, 10) catch return error.BadTarget;
    }
    if (it.next() != null) return error.BadTarget;
    return out;
}

/// A bare `-` is deliberately NOT a flag: it is the stdin path and must
/// reach the positional branch.
fn isFlag(arg: []const u8) bool {
    return arg.len > 1 and arg[0] == '-';
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Format a usage message, falling back to a static one when the arena is
/// exhausted — a failure to allocate the words must not become a
/// different KIND of failure.
fn say(a: Allocator, comptime fmt: []const u8, args: anytype, comptime fallback: []const u8) []const u8 {
    return std.fmt.allocPrint(a, fmt, args) catch fallback;
}


const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseOk(a: std.mem.Allocator, argv: []const [:0]const u8) !Command {
    return switch (parse(a, argv)) {
        .command => |c| c,
        else => error.TestExpectedCommand,
    };
}

fn usageMessage(a: std.mem.Allocator, argv: []const [:0]const u8) ![]const u8 {
    return switch (parse(a, argv)) {
        .usage => |m| m,
        else => error.TestExpectedUsage,
    };
}

test "parse: the check verb takes one positional score path" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cmd = try parseOk(arena.allocator(), &.{ "pacer", "check", "a.sjon" });
    try t.expectEqual(Verb.check, cmd.verb);
    try t.expectEqualStrings("a.sjon", cmd.path);
    try t.expectEqual(false, cmd.json);
    try t.expectEqual(@as(usize, 0), cmd.targets.len);
}

test "parse: a bare `-` is the stdin path, not an unknown flag" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cmd = try parseOk(arena.allocator(), &.{ "pacer", "check", "-" });
    try t.expectEqualStrings("-", cmd.path);
}

test "parse: --help and --version are their own actions, before any positional" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    try t.expectEqual(Action.help, parse(arena.allocator(), &.{ "pacer", "--help" }));
    try t.expectEqual(Action.help, parse(arena.allocator(), &.{ "pacer", "check", "--help" }));
    try t.expectEqual(Action.version, parse(arena.allocator(), &.{ "pacer", "--version" }));
}

test "parse: no arguments, unknown verb, and a missing positional are usage errors" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try usageMessage(a, &.{"pacer"});
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "pacer", "wat", "x" }), "wat") != null);
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "pacer", "check" }), "check") != null);
}

test "parse: an unknown flag, a duplicate positional and a valueless flag are usage errors" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expect(std.mem.indexOf(u8, try usageMessage(a, &.{ "pacer", "check", "--bogus", "a.sjon" }), "--bogus") != null);
    _ = try usageMessage(a, &.{ "pacer", "check", "a.sjon", "b.sjon" });
    _ = try usageMessage(a, &.{ "pacer", "check", "a.sjon", "--target" });
}

test "parse: --target grammar is NAME[:ncomp[:registry]], flat order is the id space" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cmd = try parseOk(arena.allocator(), &.{
        "pacer", "check", "a.sjon",
        "--target", "circle-radius",
        "--target", "tint:3",
        "--target", "click:4:1",
    });
    try t.expectEqual(@as(usize, 3), cmd.targets.len);
    try t.expectEqualStrings("circle-radius", cmd.targets[0].name);
    try t.expectEqual(@as(u8, 1), cmd.targets[0].ncomp);
    try t.expectEqual(@as(u8, 0), cmd.targets[0].registry);
    try t.expectEqual(@as(u8, 3), cmd.targets[1].ncomp);
    try t.expectEqualStrings("click", cmd.targets[2].name);
    try t.expectEqual(@as(u8, 4), cmd.targets[2].ncomp);
    try t.expectEqual(@as(u8, 1), cmd.targets[2].registry);
}

test "parse: --target rejects a bad ncomp, a bad registry and an empty name" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{ "x:0", "x:5", "x:1:999", "x:z", ":1", "", "x:1:2:3" }) |spec| {
        _ = usageMessage(a, &.{ "pacer", "check", "a.sjon", "--target", spec }) catch |e| {
            std.debug.print("expected a usage error for --target {s}\n", .{spec});
            return e;
        };
    }
}

test "parse: --json is accepted by check" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cmd = try parseOk(arena.allocator(), &.{ "pacer", "check", "a.sjon", "--json" });
    try t.expectEqual(true, cmd.json);
}

test "parse: more targets than Compile.MAX_TARGETS is a usage error, not an assert" {
    // `Compile.compile` ASSERTS `targets.len <= MAX_TARGETS`; a host
    // contract, so the CLI must refuse before it can fire.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var argv: std.ArrayList([:0]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ "pacer", "check", "a.sjon" });
    for (0..pacer.Compile.MAX_TARGETS + 1) |_| try argv.appendSlice(a, &.{ "--target", "t" });
    _ = try usageMessage(a, argv.items);
}
