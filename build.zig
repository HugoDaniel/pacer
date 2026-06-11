const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // SJON without the executable-plugin runtime: pacer only needs the
    // parser/validator/Expr/Pattern/trig surface, never libwasmtime.
    const sjon_dep = b.dependency("sjon", .{
        .target = target,
        .optimize = optimize,
        .@"plugin-exec" = false,
    });
    const sjon_mod = sjon_dep.module("sjon");

    const pacer_mod = b.addModule("pacer", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    pacer_mod.addImport("sjon", sjon_mod);
    pacer_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });

    // `zig build test` — root.zig forces discovery of every submodule's
    // inline tests via its `test { _ = X; }` block (the SJON discipline).
    const test_step = b.step("test", "Run unit tests");
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    test_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    const tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
