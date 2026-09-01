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

pub const Verb = enum { check, ir, eval };

/// Upper bound on frames one invocation may request. `--fps 1e9` over a
/// second is not a request, it is a hang.
pub const MAX_FRAMES: usize = 1 << 20;

/// A swept sample range: `t_i = from + i/fps`, computed from `i` rather
/// than accumulated, so a long sweep does not drift and frame 3600 is the
/// same f64 whether you asked for one frame or ten thousand.
pub const Sweep = struct {
    from: f64,
    to: f64,
    fps: f64,

    /// Frames this sweep yields — `floor((to - from) * fps) + 1`, the
    /// endpoint included.
    pub fn count(self: Sweep) usize {
        return @as(usize, @intFromFloat(@floor((self.to - self.from) * self.fps))) + 1;
    }

    pub fn at(self: Sweep, i: usize) f64 {
        return self.from + @as(f64, @floatFromInt(i)) / self.fps;
    }
};

/// One `--set` override, in argv order. `key` aliases argv.
pub const Override = struct {
    key: []const u8,
    /// Set when the key parses WHOLE as an integer — a slot index into the
    /// control space (document controls in table order). A control can
    /// never be NAMED an integer, since `:id` is a symbol, so this is
    /// unambiguous.
    slot: ?usize,
    /// Lanes past the ones written are ZERO — the `Key.value` padding
    /// convention, so `--set tint=1,0,0` and a 3-comp target agree with no
    /// special case.
    value: [4]f32,
    /// How many lanes were actually written, echoed in the JSON so a
    /// consumer can see `--set knob=1` was one lane and not four.
    lanes: u8,
};

pub const EvalOpts = struct {
    /// Explicit `--at` times, in argv order. Never sorted, never deduped:
    /// the frames array indexes 1:1 with what was asked.
    at: []const f64 = &.{},
    sweep: ?Sweep = null,
    sets: []const Override = &.{},
};

pub const Command = struct {
    verb: Verb,
    /// Score path, or `-` for stdin. Aliases argv.
    path: []const u8,
    /// Host registries in FLAT ORDER — which is the `target_id` space,
    /// exactly as a `times.sjon`'s `(target …)` sequence is. Empty is
    /// legal and is the default: a compose-mode score declares its own.
    targets: []const pacer.Compile.Target,
    json: bool = false,
    eval: EvalOpts = .{},
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
    var at: std.ArrayList(f64) = .empty;
    var sets: std.ArrayList(Override) = .empty;
    var from: ?f64 = null;
    var to: ?f64 = null;
    var fps: ?f64 = null;

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
            targets.append(a, tg) catch return .{ .usage = oom };
        } else if (eq(arg, "--json")) {
            out.json = true;
        } else if (eq(arg, "--at") or eq(arg, "--from") or eq(arg, "--to") or eq(arg, "--fps") or eq(arg, "--set")) {
            // Eval-only. `ir` reports the DOCUMENT's IR, which a live
            // override does not change — the table is a pure function of
            // the document, and a dump that shifted under `--set` would
            // break exactly that.
            if (verb != .eval)
                return .{ .usage = say(a, "{s} is only valid for eval", .{arg}, "flag is only valid for eval") };
            i += 1;
            if (i >= argv.len) return .{ .usage = say(a, "{s} requires a value", .{arg}, "flag requires a value") };
            const v = argv[i];
            if (eq(arg, "--set")) {
                const ov = parseSet(v) catch
                    return .{ .usage = say(a, "bad --set `{s}` (expected ID=V[,V,V,V], up to 4 finite lanes)", .{v}, "bad --set") };
                sets.append(a, ov) catch return .{ .usage = oom };
                continue;
            }
            const x = finite(v) catch
                return .{ .usage = say(a, "{s} expects a finite number, got `{s}`", .{ arg, v }, "expected a finite number") };
            if (eq(arg, "--at")) at.append(a, x) catch return .{ .usage = oom };
            if (eq(arg, "--from")) from = x;
            if (eq(arg, "--to")) to = x;
            if (eq(arg, "--fps")) fps = x;
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
    out.targets = targets.toOwnedSlice(a) catch return .{ .usage = oom };

    if (verb == .eval) {
        if (from != null or to != null or fps != null) {
            if (from == null or to == null or fps == null)
                return .{ .usage = "a sweep needs all three of --from, --to and --fps" };
            const sw: Sweep = .{ .from = from.?, .to = to.?, .fps = fps.? };
            if (sw.fps <= 0) return .{ .usage = "--fps must be greater than zero" };
            if (sw.to < sw.from) return .{ .usage = "--to must not precede --from" };
            const span = (sw.to - sw.from) * sw.fps;
            if (!std.math.isFinite(span) or span + 1 >= @as(f64, MAX_FRAMES))
                return .{ .usage = say(a, "that sweep asks for more than {d} frames", .{MAX_FRAMES}, "sweep is too large") };
            out.eval.sweep = sw;
        }
        // No default sample time: adding one later is additive, removing
        // one is breaking.
        if (at.items.len == 0 and out.eval.sweep == null)
            return .{ .usage = "eval needs sample times: --at SECONDS (repeatable), or --from/--to/--fps" };
        out.eval.at = at.toOwnedSlice(a) catch return .{ .usage = oom };
        out.eval.sets = sets.toOwnedSlice(a) catch return .{ .usage = oom };
    }
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

const oom = "out of memory collecting arguments";

/// A finite f64, or an error. `parseFloat` ACCEPTS "nan" and "inf"; both
/// would reach the driver as a clock it must reject, and both render as
/// bare words JSON has no term for. A non-finite time is a typo, so it is
/// refused here where the message can say which token.
fn finite(s: []const u8) error{NotFinite}!f64 {
    const x = std.fmt.parseFloat(f64, s) catch return error.NotFinite;
    if (!std.math.isFinite(x)) return error.NotFinite;
    return x;
}

/// `ID=V[,V[,V[,V]]]` — see `Override`.
fn parseSet(spec: []const u8) error{BadSet}!Override {
    const eqi = std.mem.indexOfScalar(u8, spec, '=') orelse return error.BadSet;
    const key = spec[0..eqi];
    if (key.len == 0) return error.BadSet;

    var out: Override = .{ .key = key, .slot = null, .value = @splat(0), .lanes = 0 };
    // `parseInt` refuses a leading '+' and any trailing byte, so `0x10`
    // and `1 ` are names, not slots.
    out.slot = std.fmt.parseInt(usize, key, 10) catch null;

    var it = std.mem.splitScalar(u8, spec[eqi + 1 ..], ',');
    while (it.next()) |lane| {
        if (out.lanes == 4) return error.BadSet;
        const x = finite(lane) catch return error.BadSet;
        out.value[out.lanes] = @floatCast(x);
        out.lanes += 1;
    }
    // `--set k=` splits to one EMPTY lane, which `finite` already refused.
    std.debug.assert(out.lanes >= 1);
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

test "parse: --at is repeatable and keeps argv order, never sorted" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cmd = try parseOk(arena.allocator(), &.{
        "pacer", "eval", "a.sjon", "--at", "1.5", "--at", "0", "--at", "3",
    });
    // Sampling order is the user's: the frames array indexes 1:1 with what
    // was asked, and sorting would hide a mistake.
    try t.expectEqualSlices(f64, &.{ 1.5, 0, 3 }, cmd.eval.at);
    try t.expectEqual(@as(?Sweep, null), cmd.eval.sweep);
}

test "parse: the sweep is all three flags or none" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cmd = try parseOk(a, &.{ "pacer", "eval", "a.sjon", "--from", "0", "--to", "2", "--fps", "4" });
    try t.expectEqual(Sweep{ .from = 0, .to = 2, .fps = 4 }, cmd.eval.sweep.?);

    for ([_][]const [:0]const u8{
        &.{ "pacer", "eval", "a.sjon", "--from", "0" },
        &.{ "pacer", "eval", "a.sjon", "--from", "0", "--to", "2" },
        &.{ "pacer", "eval", "a.sjon", "--to", "2", "--fps", "4" },
    }) |argv| _ = try usageMessage(a, argv);
}

test "parse: the sweep rejects a bad fps, a reversed range and an absurd frame count" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const [:0]const u8{
        &.{ "pacer", "eval", "a.sjon", "--from", "0", "--to", "2", "--fps", "0" },
        &.{ "pacer", "eval", "a.sjon", "--from", "0", "--to", "2", "--fps", "-1" },
        &.{ "pacer", "eval", "a.sjon", "--from", "2", "--to", "0", "--fps", "4" },
        // 1e9 fps over a second is not a request, it is a hang.
        &.{ "pacer", "eval", "a.sjon", "--from", "0", "--to", "1", "--fps", "1e9" },
    }) |argv| _ = try usageMessage(a, argv);
}

test "parse: a non-finite time is refused at parse, never handed to the driver" {
    // `parseFloat` accepts "nan" and "inf"; a non-finite f64 would also
    // render as bare `nan` in JSON, which no parser accepts.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{ "nan", "inf", "-inf" }) |bad| {
        _ = try usageMessage(a, &.{ "pacer", "eval", "a.sjon", "--at", bad });
    }
}

test "parse: --set takes a control id or a slot, and pads lanes with zero" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const cmd = try parseOk(arena.allocator(), &.{
        "pacer", "eval", "a.sjon", "--at", "0",
        "--set", "sway-amt=0.2",
        "--set", "pan=0.25,0.5",
        "--set", "0=0.5",
    });
    try t.expectEqual(@as(usize, 3), cmd.eval.sets.len);

    try t.expectEqualStrings("sway-amt", cmd.eval.sets[0].key);
    try t.expectEqual(@as(?usize, null), cmd.eval.sets[0].slot);
    try t.expectEqual(@as(u8, 1), cmd.eval.sets[0].lanes);
    try t.expectEqual([4]f32{ 0.2, 0, 0, 0 }, cmd.eval.sets[0].value);

    try t.expectEqual(@as(u8, 2), cmd.eval.sets[1].lanes);
    try t.expectEqual([4]f32{ 0.25, 0.5, 0, 0 }, cmd.eval.sets[1].value);

    // A key that parses WHOLE as an integer is a slot. No control can be
    // named `0` — `:id` is a symbol — so this is unambiguous.
    try t.expectEqual(@as(?usize, 0), cmd.eval.sets[2].slot);
}

test "parse: --set rejects a missing =, an empty key, five lanes and a non-finite lane" {
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{ "sway", "=0.5", "k=1,2,3,4,5", "k=", "k=x", "k=nan", "k=inf" }) |bad| {
        _ = usageMessage(a, &.{ "pacer", "eval", "a.sjon", "--at", "0", "--set", bad }) catch |e| {
            std.debug.print("expected a usage error for --set {s}\n", .{bad});
            return e;
        };
    }
}

test "parse: eval with no sample times is a usage error, not a silent default of 0" {
    // Adding a default later is additive; removing one is breaking.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const msg = try usageMessage(arena.allocator(), &.{ "pacer", "eval", "a.sjon" });
    try t.expect(std.mem.indexOf(u8, msg, "--at") != null);
}

test "parse: the eval-only flags are refused by ir and check" {
    // `ir` reports the DOCUMENT's IR, which a live override does not
    // change — the table is a pure function of the document, and an `ir`
    // dump that shifted under `--set` would break exactly that.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][:0]const u8{ "ir", "check" }) |verb| {
        _ = try usageMessage(a, &.{ "pacer", verb, "a.sjon", "--set", "k=1" });
        _ = try usageMessage(a, &.{ "pacer", verb, "a.sjon", "--at", "0" });
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
