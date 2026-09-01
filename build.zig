const std = @import("std");
const builtin = @import("builtin");

comptime {
    // `.minimum_zig_version` only gates package-manager consumers; this
    // gives a direct `zig build` on an older toolchain a clear message.
    const required = std.SemanticVersion.parse("0.16.0") catch unreachable;
    if (builtin.zig_version.order(required) == .lt)
        @compileError("pacer requires zig >= 0.16.0 (build.zig.zon minimum_zig_version)");
}

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
    test_mod.addAnonymousImport("pacer_corpus_schema", .{
        .root_source_file = b.path("schema/pacer-corpus.sjon"),
    });
    // The repo root, handed to the test binaries as an absolute path so the
    // `sjon-project.sjon` test can load the workspace the way `sjon-lsp`
    // does. A cwd-relative path would depend on where `zig build` was
    // invoked from; this does not. Both test roots below (`src/root.zig`
    // and `src/fuzz.zig`) reach `Schema`'s tests, so both need the module.
    const build_options = b.addOptions();
    build_options.addOptionPath("repo_root", b.path("."));
    const build_options_mod = build_options.createModule();
    test_mod.addImport("build_options", build_options_mod);
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
    corpus_mod.addAnonymousImport("pacer_corpus_schema", .{
        .root_source_file = b.path("schema/pacer-corpus.sjon"),
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

    // `zig build cli` — the native `pacer` binary: `ir` / `eval` / `check`,
    // JSON on stdout, everything else on stderr.
    //
    // Built against the PUBLIC `pacer` module rather than the sources
    // (which is what `corpus_runner` does, because it lives in `src/` and
    // rides root.zig's test discovery). The CLI is a CONSUMER — the first
    // native one — so going through `@import("pacer")` makes root.zig's
    // export list load-bearing: a surface a host needs and the module does
    // not export fails here. `sjon` rides along for the comptime pins the
    // JSON contract rests on.
    //
    // Installed through its OWN step, not `b.installArtifact`: nothing in
    // this build attaches to the default install step, so a bare
    // `zig build` is a no-op and should stay one. Same shape as the wasm.
    const cli_imports = [_]std.Build.Module.Import{
        .{ .name = "pacer", .module = pacer_mod },
        .{ .name = "sjon", .module = sjon_mod },
    };
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &cli_imports,
    });
    const cli_exe = b.addExecutable(.{ .name = "pacer", .root_module = cli_mod });
    const install_cli = b.addInstallArtifact(cli_exe, .{});
    const cli_step = b.step("cli", "Build the pacer CLI (native)");
    cli_step.dependOn(&install_cli.step);

    // `zig build run -- check score.sjon` — the CLI without the install path.
    const run_cli = b.addRunArtifact(cli_exe);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the pacer CLI (args after `--`)");
    run_step.dependOn(&run_cli.step);

    // The CLI's tests are their OWN root. `src/root.zig`'s `test {}` block
    // cannot reach them: these files import the `pacer` MODULE, which
    // inside the core test binary resolves to a second, distinct instance.
    // `src/cli/Cli.zig` plays root.zig's role one level down.
    const cli_test_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/Cli.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &cli_imports,
    });
    cli_test_mod.addImport("build_options", build_options_mod);
    const cli_tests = b.addTest(.{ .root_module = cli_test_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);
    test_step.dependOn(&run_cli_tests.step);

    // `zig build verify` — the whole gate in one verb: unit tests, the
    // native corpus half, then node --test against the freshly built
    // pacer.wasm (the JS suite includes the corpus parity walk, so this
    // is where native-vs-wasm byte equality is actually asserted).
    const node_test = b.addSystemCommand(&.{ "node", "--test" });
    node_test.setCwd(b.path("npm/pacer"));
    node_test.step.dependOn(&install_wasm.step);
    // Verify runs the corpus through its OWN run step, without `b.args`:
    // `zig build verify -- --update` must never regenerate goldens while
    // the parallel node --test step is reading them (regen is the
    // `corpus` verb's business alone).
    const run_corpus_verify = b.addRunArtifact(corpus_runner);
    run_corpus_verify.addDirectoryArg(b.path("corpus"));
    run_corpus_verify.has_side_effects = true;
    const verify_step = b.step("verify", "test + native corpus + node/wasm corpus parity");
    verify_step.dependOn(&run_tests.step);
    verify_step.dependOn(&run_corpus_verify.step);
    verify_step.dependOn(&node_test.step);

    // `zig build fuzz` — never-panic harnesses over the byte-eating and
    // arbitrary-input entrypoints (compile, decodeTargets, Writes.decode,
    // Easing builders). A SEPARATE target so `verify` stays fast; same
    // module wiring as `test_mod` (sjon + the embedded schema). Each
    // harness runs its corpus on a plain invocation and Smith-generated
    // inputs under the instrumented fuzzer.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    fuzz_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    fuzz_mod.addImport("build_options", build_options_mod);
    const fuzz_test = b.addTest(.{ .root_module = fuzz_mod });
    const run_fuzz = b.addRunArtifact(fuzz_test);
    const fuzz_step = b.step("fuzz", "Run never-panic fuzz harnesses");
    fuzz_step.dependOn(&run_fuzz.step);

    // `zig build score-docs` — render `docs/score-language.md` from the
    // manifest's own `:description`s, so the score language's prose has one
    // source rather than two. SJON's CLI is not exposed as a dependency
    // artifact (its build wires `sjon` to its own `cli` step, not to the
    // install step), so pacer builds it from the dependency's source with
    // the same recipe SJON uses — one module, one import.
    const sjon_cli = b.addExecutable(.{
        .name = "sjon",
        .root_module = b.createModule(.{
            .root_source_file = sjon_dep.path("src/cli/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sjon", .module = sjon_mod }},
        }),
    });
    const score_docs = b.addSystemCommand(&.{"tools/score_docs.sh"});
    score_docs.setCwd(b.path("."));
    score_docs.addArtifactArg(sjon_cli);
    score_docs.addArg("--update");
    score_docs.has_side_effects = true;
    const score_docs_step = b.step("score-docs", "Regenerate docs/score-language.md from schema/pacer.sjon");
    score_docs_step.dependOn(&score_docs.step);

    // …and the drift leg of the same script, folded into `verify`: a
    // manifest edit that never reached the page fails the gate.
    const score_docs_check = b.addSystemCommand(&.{"tools/score_docs.sh"});
    score_docs_check.setCwd(b.path("."));
    score_docs_check.addArtifactArg(sjon_cli);
    verify_step.dependOn(&score_docs_check.step);

    // `zig build audit-diagnostics` — assert every `Compile.Code` variant
    // is exercised by name in some `test {}` body (corpus goldens carry
    // numeric codes, so they can't satisfy the check). Keeps a new code
    // from landing without a test, or a test from drifting to a
    // message-only assertion when a code is renamed.
    const audit_diagnostics_step = b.step("audit-diagnostics", "Audit Compile.Code test coverage");
    const audit_diagnostics = b.addSystemCommand(&.{"tools/audit_diagnostic_coverage.sh"});
    // A Run step with no cwd inherits the build-runner's — pin it so the
    // relative argv[0] survives `--build-file` from elsewhere.
    audit_diagnostics.setCwd(b.path("."));
    audit_diagnostics_step.dependOn(&audit_diagnostics.step);
}
