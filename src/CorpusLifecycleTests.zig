//! Separate test root for the native corpus renderer's lifecycle adapter —
//! binary03 P2 correction.
//!
//! The adapter tests must exercise the ACTUAL renderer and the ACTUAL text
//! object, never a local copy of the load logic. This root imports the
//! source-owning `corpus_runner.zig` (so `renderCase` and `TextAdapter` are
//! the same code the `corpus` verb runs) and links
//! `native_text_object`, whose real `drv_*` exports are reached through the
//! std-only `NativeText` facade.

const std = @import("std");
const CorpusHarness = @import("corpus_harness");
const runner = @import("corpus_runner.zig");
const Compile = @import("Compile.zig");
const Driver = @import("Driver.zig");
const Schema = @import("Schema.zig");
const NativeText = @import("NativeText.zig");

const t = std.testing;

const TARGETS = [_]Compile.Target{
    .{ .name = "alpha", .ncomp = 1, .registry = 0 },
    .{ .name = "bravo", .ncomp = 1, .registry = 0 },
};

const SOURCE: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4])
    \\(track :target alpha (key :at 0b :value 0.2) (key :at 4b :value 0.8))
    \\(track :target bravo :expr (/ 1 (- beat 1)))
;

const HALF_BITS: u64 = 0x3FE0000000000000;

fn render(
    a: std.mem.Allocator,
    steps: []const CorpusHarness.Step,
) ![]const u8 {
    var schema = try Schema.load(a);
    defer schema.deinit();
    var driver: Driver = undefined;
    try driver.init(a, &schema, SOURCE, &TARGETS);
    defer driver.deinit();
    try t.expect(driver.result.ok());

    const harness: CorpusHarness.Harness = .{ .targets = &.{}, .steps = steps };
    var diagnostics: std.Io.Writer.Allocating = .init(a);
    defer diagnostics.deinit();
    var golden: std.Io.Writer.Allocating = .init(a);
    defer golden.deinit();

    defer NativeText.reset();
    const ok = try runner.renderCase(
        a,
        &diagnostics.writer,
        "corpus-lifecycle-test",
        &golden.writer,
        &driver,
        harness,
        SOURCE,
        &TARGETS,
    );
    if (!ok) {
        std.debug.print("corpus lifecycle renderer refused: {s}\n", .{diagnostics.written()});
        return error.TestUnexpectedResult;
    }
    return golden.written();
}

test "corpus lifecycle renderer: diagnostics then bad-call keeps the actual prior state" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // A bad call preserves whatever state precedes it. After diagnostics that
    // state is unloaded text / live binary, and the echo must report the
    // actual prior `loaded` value rather than require a live text score.
    const text = try render(a, &.{
        .{ .reload = .diagnostics },
        .{ .reload = .bad_call },
        .{ .eval = HALF_BITS },
    });
    try t.expect(std.mem.indexOf(u8, text, "(reload :kind diagnostics :status 1 :loaded false)") != null);
    try t.expect(std.mem.indexOf(u8, text, "(reload :kind bad-call :status 2 :loaded false)") != null);
    try t.expect(std.mem.indexOf(u8, text, "(eval :t \"3FE0000000000000\" :unloaded true)") != null);
}

test "corpus lifecycle renderer: terminal diagnostics finishes without a current reload" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The specified outcome is text unloaded / binary still live; no final
    // `current` is part of the lifecycle contract.
    const text = try render(a, &.{
        .{ .reload = .diagnostics },
    });
    try t.expect(std.mem.indexOf(u8, text, "(reload :kind diagnostics :status 1 :loaded false)") != null);
}
