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

    // `zig build wasm` — pacer.wasm, the browser driver artifact. The
    // SJON dependency is resolved a second time for wasm32 (modules
    // carry their resolved target). Same flags as SJON's own artifacts:
    // freestanding, no entry, rdynamic, ReleaseSmall.
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const sjon_wasm_dep = b.dependency("sjon", .{
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .@"plugin-exec" = false,
    });
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm_entry.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_wasm_dep.module("sjon") },
        },
    });
    wasm_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    const wasm = b.addExecutable(.{
        .name = "pacer",
        .root_module = wasm_mod,
    });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    const install_wasm = b.addInstallArtifact(wasm, .{});
    const wasm_step = b.step("wasm", "Build pacer.wasm (browser driver artifact)");
    wasm_step.dependOn(&install_wasm.step);

    // `zig build corpus` — the native half of the determinism gate:
    // walk corpus/<case>/, compile + eval each score, compare the
    // canonical rendering byte-equal against expected.sjon. Pass
    // `-- --update` to regenerate the goldens (review the diff). The
    // wasm half is npm/pacer/test/corpus.test.js rendering the same
    // text from pacer.wasm output against the same goldens.
    const corpus_mod = b.createModule(.{
        .root_source_file = b.path("src/corpus_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    corpus_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    const corpus_runner = b.addExecutable(.{
        .name = "corpus-runner",
        .root_module = corpus_mod,
    });
    const run_corpus = b.addRunArtifact(corpus_runner);
    run_corpus.addDirectoryArg(b.path("corpus"));
    if (b.args) |args| run_corpus.addArgs(args);
    run_corpus.has_side_effects = true;
    const corpus_step = b.step("corpus", "Verify the golden corpus (native); `-- --update` regenerates");
    corpus_step.dependOn(&run_corpus.step);

    // `zig build verify` — the whole gate in one verb: unit tests, the
    // native corpus half, then node --test against the freshly built
    // pacer.wasm (the JS suite includes the corpus parity walk, so this
    // is where native-vs-wasm byte equality is actually asserted).
    const node_test = b.addSystemCommand(&.{ "node", "--test" });
    node_test.setCwd(b.path("npm/pacer"));
    node_test.step.dependOn(&install_wasm.step);
    const verify_step = b.step("verify", "test + native corpus + node/wasm corpus parity");
    verify_step.dependOn(&run_tests.step);
    verify_step.dependOn(&run_corpus.step);
    verify_step.dependOn(&node_test.step);
}
