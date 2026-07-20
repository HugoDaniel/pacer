//! Driver — the compile-result + evaluator pair with the borrow-whole
//! lifetime encoded as structure.
//!
//! `Eval.Evaluator` borrows a `Compile.CompileResult` WHOLE (expr and
//! pattern tracks re-read the tree + schema every frame — the anti-drift
//! trade), which imposes three obligations no type checks on a raw pair:
//! the result must sit in its final memory location before
//! `Evaluator.init`, must never be reassigned while borrowed, and must be
//! torn down AFTER the evaluator. This struct owns the pair and the
//! ordering, collapsing the three to one, stated by `init`'s signature:
//! place the Driver, init it in place, don't move it.
//!
//! `result` and `evaluator` are deliberately pub with no forwarding
//! shims — the Driver owns lifetime, not API. Callers reach `setBpm`,
//! `setControl`, diagnostics, and meta encoding through the fields.
//!
//! Ownership: SJON convention — `deinit()` releases everything; the
//! struct never retains the caller's GPA beyond what `CompileResult`
//! itself keeps (its `Validated` holds the gpa for follow-up allocation).

const std = @import("std");
const Compile = @import("Compile.zig");
const Eval = @import("Eval.zig");

const Driver = @This();

pub const Error = Compile.Error;

/// The compiled score. Always live after a successful `init` — a score
/// with defects still yields readable diagnostics here (`ok() == false`).
result: Compile.CompileResult,
/// Non-null iff `result.ok()` — armed by `init`, borrowing `result`.
evaluator: ?Eval.Evaluator,

/// In-place init: the POINTER receiver is the contract — `self` is the
/// final memory location, visibly, in the signature itself. Compiles
/// `source` into `self.result` (the by-value move lands BEFORE any
/// borrow is taken), then arms `self.evaluator` from `&self.result` when
/// the compile is clean. A defective score is NOT an error: `init`
/// succeeds with `evaluator == null` and the diagnostics readable on
/// `result`. On `error.OutOfMemory` nothing survives — `self` is
/// undefined and needs no deinit.
pub fn init(self: *Driver, gpa: std.mem.Allocator, source: [:0]const u8, targets: []const Compile.Target) Error!void {
    self.result = try Compile.compile(gpa, source, targets);
    self.evaluator = if (self.result.ok())
        Eval.Evaluator.init(gpa, &self.result) catch |err| {
            self.result.deinit();
            self.* = undefined;
            return err;
        }
    else
        null;
}

/// Teardown in the borrow order — evaluator first, then the result it
/// borrows — encoded once, here. Safe after both `init` outcomes.
/// Reload = `deinit` then `init` on the same storage.
pub fn deinit(self: *Driver) void {
    if (self.evaluator) |*ev| ev.deinit();
    self.result.deinit();
    self.* = undefined;
}

const t_ = std.testing;

const test_targets = [_]Compile.Target{
    .{ .name = "radius", .ncomp = 1 },
};

const clean_source: [:0]const u8 =
    \\(transport :bpm 120)
    \\(track :target radius
    \\  (key :at 0b :value 0.5)
    \\  (key :at 4b :value 1.0))
;

const broken_source: [:0]const u8 =
    \\(transport :bpm 120)
    \\(track :target nope (key :at 0b :value 0.5))
;

test "Driver: a clean score arms the evaluator and evals" {
    var d: Driver = undefined;
    try d.init(t_.allocator, clean_source, &test_targets);
    defer d.deinit();
    try t_.expect(d.result.ok());
    try t_.expect(d.evaluator != null);
    const entries = try d.evaluator.?.evalSeconds(0.0);
    try t_.expectEqual(@as(usize, 1), entries.len);
    try t_.expectEqual(@as(f32, 0.5), entries[0].value[0]);
}

test "Driver: a defective score leaves the evaluator null, diagnostics readable" {
    var d: Driver = undefined;
    try d.init(t_.allocator, broken_source, &test_targets);
    defer d.deinit();
    try t_.expect(!d.result.ok());
    try t_.expect(d.evaluator == null);
    try t_.expect(d.result.findDiag(.unknown_target) != null);
}

test "Driver: reload in place — deinit + re-init on the same storage" {
    var d: Driver = undefined;
    try d.init(t_.allocator, broken_source, &test_targets);
    try t_.expect(!d.result.ok());
    d.deinit();

    try d.init(t_.allocator, clean_source, &test_targets);
    defer d.deinit();
    try t_.expect(d.result.ok());
    // 120 bpm ⇒ 2 beats/s: 1.0 s = beat 2, the segment midpoint.
    const entries = try d.evaluator.?.evalSeconds(1.0);
    try t_.expectEqual(@as(usize, 1), entries.len);
    try t_.expectEqual(@as(f32, 0.75), entries[0].value[0]);
}
