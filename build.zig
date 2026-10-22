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

    // The shared corpus-harness parser is a named std/SJON-only leaf. It
    // owns the harness vocabulary's embedded manifest; consumers (`test`'s
    // cap pin and the corpus executable) import it by name rather than by a
    // parallel relative source path. Its own parser tests get a separate
    // test root below, because a named dependency's tests are not assumed to
    // be discovered by the root test binary.
    const corpus_harness_mod = b.createModule(.{
        .root_source_file = b.path("src/CorpusHarness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    corpus_harness_mod.addAnonymousImport("pacer_corpus_schema", .{
        .root_source_file = b.path("schema/pacer-corpus.sjon"),
    });

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
            .{ .name = "corpus_harness", .module = corpus_harness_mod },
        },
    });
    test_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    // The repo root, handed to the test binaries as an absolute path so the
    // `sjon-project.sjon` test can load the workspace the way `sjon-lsp`
    // does. A cwd-relative path would depend on where `zig build` was
    // invoked from; this does not. Both test roots below (`src/root.zig`
    // and `src/fuzz.zig`) reach `Schema`'s tests, so both need the module.
    const build_options = b.addOptions();
    build_options.addOptionPath("repo_root", b.path("."));
    // The SJON sibling checkout's src dir — the closure gate's SJON leg
    // root (tools/audit_rt_imports.zig fixture tests resolve it here).
    build_options.addOptionPath("sjon_src_root", sjon_dep.path("src"));
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

    // `zig build wasm-rt` — pacer-rt.wasm, the playback runtime artifact
    // (02 T2.2). The `wasm` recipe verbatim: wasm32-freestanding,
    // ReleaseSmall, rdynamic, entry disabled, sjon `.@"plugin-exec" =
    // false`; root `src/rt_entry.zig`, name `pacer-rt`. The resolved
    // wasm32 SJON module is shared with the `wasm` step above. No
    // `pacer_schema` import: the runtime never loads a text schema (the
    // binary arm's schema is the frozen core-only one, `rt_entry.zig`).
    const wasm_rt_mod = b.createModule(.{
        .root_source_file = b.path("src/rt_entry.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .link_libc = false,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_wasm_dep.module("sjon") },
        },
    });
    const wasm_rt = b.addExecutable(.{
        .name = "pacer-rt",
        .root_module = wasm_rt_mod,
    });
    wasm_rt.entry = .disabled;
    wasm_rt.rdynamic = true;
    const install_wasm_rt = b.addInstallArtifact(wasm_rt, .{});
    const wasm_rt_step = b.step("wasm-rt", "Build pacer-rt.wasm (playback runtime artifact)");
    wasm_rt_step.dependOn(&install_wasm_rt.step);

    // The text object is a SECOND separate compilation, rooted at
    // `native_text_bridge.zig` → actual `wasm_entry.zig`. It owns the real
    // `drv_*` definitions and the anonymous score manifest; it imports no
    // public `pacer` and no corpus manifest, and defines no plugin stub.
    // `page_allocator` is the only production portability correction, so
    // the shipped wasm artifact remains byte-identical on wasm32.
    //
    // Declared before its consumers below: the corpus runner links it so a
    // lifecycle script can execute the ACTUAL text entry, and the parity
    // executable/test root link both private objects.
    const native_text_mod = b.createModule(.{
        .root_source_file = b.path("src/native_text_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    native_text_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    const native_text_object = b.addObject(.{
        .name = "pacer-native-text",
        .root_module = native_text_mod,
    });

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
            .{ .name = "corpus_harness", .module = corpus_harness_mod },
        },
    });
    corpus_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    corpus_mod.addObject(native_text_object);
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

    // The shared parser's tests are their OWN root. `src/root.zig` no longer
    // imports the corpus runner (whose parser tests moved into the leaf), and
    // this explicit test root proves discovery instead of assuming a named
    // dependency's inline tests run in the root test binary. It is a second
    // module instance over the same file, so it owns its own anonymous corpus
    // manifest and imports the same `sjon` module.
    const corpus_harness_test_mod = b.createModule(.{
        .root_source_file = b.path("src/CorpusHarness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    corpus_harness_test_mod.addAnonymousImport("pacer_corpus_schema", .{
        .root_source_file = b.path("schema/pacer-corpus.sjon"),
    });
    const corpus_harness_tests = b.addTest(.{ .root_module = corpus_harness_test_mod });
    const run_corpus_harness_tests = b.addRunArtifact(corpus_harness_tests);
    test_step.dependOn(&run_corpus_harness_tests.step);

    // The corpus renderer's lifecycle adapter is tested in its OWN root:
    // it imports the source-owning runner (the actual `TextAdapter` and
    // `renderCase`) and links the separately compiled text object, so the
    // regression exercises the real `drv_*` entry rather than a local copy.
    const corpus_lifecycle_test_mod = b.createModule(.{
        .root_source_file = b.path("src/CorpusLifecycleTests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "corpus_harness", .module = corpus_harness_mod },
        },
    });
    corpus_lifecycle_test_mod.addAnonymousImport("pacer_schema", .{
        .root_source_file = b.path("schema/pacer.sjon"),
    });
    corpus_lifecycle_test_mod.addImport("build_options", build_options_mod);
    corpus_lifecycle_test_mod.addObject(native_text_object);
    const corpus_lifecycle_tests = b.addTest(.{ .root_module = corpus_lifecycle_test_mod });
    const run_corpus_lifecycle_tests = b.addRunArtifact(corpus_lifecycle_tests);
    test_step.dependOn(&run_corpus_lifecycle_tests.step);

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

    // The binary-level golden: run the freshly built CLI over pinned
    // scores and diff the committed JSON. The in-process tests check shape
    // and rules one assertion at a time; this checks the WHOLE envelope in
    // one reviewable diff, and catches a reshuffle nothing asserted.
    // Same check-by-default / `--update`-to-write shape as
    // `tools/score_docs.sh`, so the gate compares what the verb produces.
    const cli_golden_check = b.addSystemCommand(&.{"tools/cli_golden.sh"});
    cli_golden_check.setCwd(b.path("."));
    cli_golden_check.addArtifactArg(cli_exe);

    const cli_golden_update = b.addSystemCommand(&.{"tools/cli_golden.sh"});
    cli_golden_update.setCwd(b.path("."));
    cli_golden_update.addArtifactArg(cli_exe);
    cli_golden_update.addArg("--update");
    cli_golden_update.has_side_effects = true;
    const cli_golden_step = b.step("cli-golden", "Regenerate the CLI JSON goldens (review the diff)");
    cli_golden_step.dependOn(&cli_golden_update.step);

    // `zig build verify` — the whole gate in one verb: unit tests, the
    // native corpus half, then node --test against the freshly built
    // pacer.wasm + pacer-rt.wasm (the JS suite includes the corpus
    // parity walk and the rt artifact tests, so this is where
    // native-vs-wasm byte equality is actually asserted).
    const node_test = b.addSystemCommand(&.{ "node", "--test" });
    node_test.setCwd(b.path("npm/pacer"));
    node_test.step.dependOn(&install_wasm.step);
    node_test.step.dependOn(&install_wasm_rt.step);
    // rt.test.js consumes the SAME fresh CLI pack the npm pretest hook
    // makes; verify builds it here so a clean checkout is self-contained.
    const rt_fixture = b.addRunArtifact(cli_exe);
    rt_fixture.setCwd(b.path("."));
    rt_fixture.addArgs(&.{
        "pack",
        "tools/testdata/pacb/full-small.score.sjon",
        "--out",
        "npm/pacer/test/rt-fixture.pacb",
    });
    rt_fixture.has_side_effects = true;
    node_test.step.dependOn(&rt_fixture.step);
    // A5: the rt-corpus fixtures — the SAME generator the npm pretest hook
    // runs (one real `pacer pack` per corpus case + the digest manifest the
    // walk verifies). Depends on the installed CLI and BOTH wasm artifacts
    // so the manifest's producer identities are fresh, and node --test can
    // never race a fixture write.
    const rt_corpus_fixtures = b.addSystemCommand(&.{ "node", "npm/pacer/tools/generate-rt-fixtures.js" });
    rt_corpus_fixtures.setCwd(b.path("."));
    rt_corpus_fixtures.step.dependOn(&install_cli.step);
    rt_corpus_fixtures.step.dependOn(&install_wasm.step);
    rt_corpus_fixtures.step.dependOn(&install_wasm_rt.step);
    rt_corpus_fixtures.has_side_effects = true;
    // A5: refresh the shipped runtime copy exactly as the npm pretest's
    // `build:wasm-rt-copy` hook does, so the walk's copy-identity check
    // holds under verify too (no missing-sibling/hidden-pretest gap).
    const wasm_rt_copy = b.addSystemCommand(&.{
        "node",
        "-e",
        "require('node:fs').copyFileSync('zig-out/bin/pacer-rt.wasm','npm/pacer/pacer-rt.wasm')",
    });
    wasm_rt_copy.setCwd(b.path("."));
    wasm_rt_copy.step.dependOn(&install_wasm_rt.step);
    wasm_rt_copy.has_side_effects = true;
    node_test.step.dependOn(&rt_corpus_fixtures.step);
    node_test.step.dependOn(&wasm_rt_copy.step);
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
    verify_step.dependOn(&run_corpus_harness_tests.step);
    verify_step.dependOn(&run_corpus_lifecycle_tests.step);
    verify_step.dependOn(&node_test.step);
    verify_step.dependOn(&cli_golden_check.step);

    // `zig build native-composition` — binary03 T1: prove the real PUBLIC
    // `pacer` module composes with a SEPARATELY COMPILED playback object.
    //
    // The object is rooted at `native_rt_bridge.zig`, which imports the
    // actual `rt_entry.zig` and takes the address of every internal
    // production alias so the real `prt_*` exports are analyzed/linked.
    // The probe is a consumer: it imports only the named `pacer` module
    // and the std-only `NativeRt` extern facade, never runtime source.
    // `addObject` links the emitted object; it is never used as an
    // `addImport`, so the two source graphs stay separate. The object is
    // built with `addObject`, never `addTest`: rt_entry's existing tests
    // remain in the source-owning root test binary, which does NOT link
    // this object (it already defines `prt_*`).
    const native_rt_mod = b.createModule(.{
        .root_source_file = b.path("src/native_rt_bridge.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sjon", .module = sjon_mod },
        },
    });
    const native_rt_object = b.addObject(.{
        .name = "pacer-native-rt",
        .root_module = native_rt_mod,
    });
    const probe_mod = b.createModule(.{
        .root_source_file = b.path("src/native_composition_probe.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pacer", .module = pacer_mod },
        },
    });
    probe_mod.addObject(native_rt_object);
    probe_mod.addObject(native_text_object);
    const probe = b.addExecutable(.{
        .name = "native-composition-probe",
        .root_module = probe_mod,
    });
    const run_probe = b.addRunArtifact(probe);
    run_probe.has_side_effects = true;
    // The separate test root runs the SAME assertion function in its own
    // process; this is the required second composition link mode, not a
    // root-test substitute.
    const probe_tests = b.addTest(.{ .root_module = probe_mod });
    const run_probe_tests = b.addRunArtifact(probe_tests);
    const composition_step = b.step("native-composition", "Check private native loader composition");
    composition_step.dependOn(&run_probe.step);
    composition_step.dependOn(&run_probe_tests.step);
    test_step.dependOn(&run_probe.step);
    test_step.dependOn(&run_probe_tests.step);
    verify_step.dependOn(&run_probe.step);
    verify_step.dependOn(&run_probe_tests.step);

    // `zig build perf-measure` — plan 06 Group C's native-only counting-GPA
    // harness (C4/C5). It links the SAME production objects as
    // `native-composition` and points their comptime-native allocator seams
    // at counting GPAs; no shipped export or artifact changes. Arguments
    // after `--` are forwarded (see `src/perf_harness.zig`).
    const perf_mod = b.createModule(.{
        .root_source_file = b.path("src/perf_harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pacer", .module = pacer_mod },
        },
    });
    perf_mod.addObject(native_rt_object);
    perf_mod.addObject(native_text_object);
    const perf_exe = b.addExecutable(.{
        .name = "perf-harness",
        .root_module = perf_mod,
    });
    const run_perf = b.addRunArtifact(perf_exe);
    if (b.args) |args| run_perf.addArgs(args);
    run_perf.has_side_effects = true;
    const perf_step = b.step("perf-measure", "Run the native counting-GPA measurement harness (args after `--`)");
    perf_step.dependOn(&run_perf.step);

    // `zig build parity` — binary03 T3 (plan 03 P1): the native playback
    // parity runner. A public-`pacer` consumer, exactly like the CLI: it
    // imports the actual `pacer` module + named `corpus_harness` leaf and
    // links T1's separately compiled `native_rt_object`. No relative Pacer
    // core/runtime import appears in this source graph.
    //
    // The run step gets exactly one directory argument and NO `b.args`
    // forwarding: `zig build parity -- --update` cannot regenerate goldens.
    // It depends on a CHECK-ONLY native corpus run (also no forwarded args),
    // so the parity verb exercises the current committed corpus first.
    // `has_side_effects` keeps the comparisons running on every invocation.
    const parity_mod = b.createModule(.{
        .root_source_file = b.path("src/parity_runner.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pacer", .module = pacer_mod },
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "corpus_harness", .module = corpus_harness_mod },
        },
    });
    parity_mod.addImport("build_options", build_options_mod);
    parity_mod.addObject(native_rt_object);
    parity_mod.addObject(native_text_object);
    const parity_exe = b.addExecutable(.{
        .name = "parity-runner",
        .root_module = parity_mod,
    });
    const run_parity = b.addRunArtifact(parity_exe);
    run_parity.addDirectoryArg(b.path("corpus"));
    run_parity.has_side_effects = true;

    const run_corpus_parity_check = b.addRunArtifact(corpus_runner);
    run_corpus_parity_check.addDirectoryArg(b.path("corpus"));
    run_corpus_parity_check.has_side_effects = true;

    const parity_step = b.step("parity", "Native text/binary parity over the golden corpus");
    parity_step.dependOn(&run_corpus_parity_check.step);
    parity_step.dependOn(&run_parity.step);
    // The runner accepts exactly its directory argument. Any build-level
    // extra argument (including the corpus verb's `--update`) is rejected
    // here, never forwarded: parity measures, it cannot regenerate.
    if (b.args) |args| {
        if (args.len != 0) {
            const reject_parity_args = b.addFail("parity: extra arguments (including --update) are rejected");
            parity_step.dependOn(&reject_parity_args.step);
        }
    }

    // The parity runner's tests are their OWN root (the CLI precedent). They
    // link the same real runtime object and never become part of `src/root.zig`.
    const parity_test_mod = b.createModule(.{
        .root_source_file = b.path("src/ParityTests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pacer", .module = pacer_mod },
            .{ .name = "sjon", .module = sjon_mod },
            .{ .name = "corpus_harness", .module = corpus_harness_mod },
        },
    });
    parity_test_mod.addImport("build_options", build_options_mod);
    parity_test_mod.addObject(native_rt_object);
    parity_test_mod.addObject(native_text_object);
    const parity_tests = b.addTest(.{ .root_module = parity_test_mod });
    const run_parity_tests = b.addRunArtifact(parity_tests);
    test_step.dependOn(&run_parity_tests.step);
    // `verify` currently depends on the root test run explicitly, not on the
    // whole `test` step; attach this root here too so the parity tests are
    // never silently skipped by the whole gate.
    verify_step.dependOn(&run_parity_tests.step);

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

    // `zig build audit-rt-imports` — the runtime closure gate, layer 1
    // (02 T2.3): column-0 BFS from `src/rt_entry.zig` under the module-aware
    // rules (the one `@import("sjon")` window, the strict RtSjon alias
    // grammar, the pacer + SJON allowlists with stale-entry failure both
    // directions, the namespace→file map asserted against SJON's root.zig
    // every run). T2.4 chains layer 2 (the physical artifact check) into
    // this same verb. `has_side_effects` so the gate runs EVERY invocation —
    // a cached pass must never let an edited source slip through.
    const audit_rt_imports = b.addExecutable(.{
        .name = "audit-rt-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audit_rt_imports.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_audit_rt_imports = b.addRunArtifact(audit_rt_imports);
    run_audit_rt_imports.setCwd(b.path("."));
    run_audit_rt_imports.addDirectoryArg(b.path("src"));
    run_audit_rt_imports.addDirectoryArg(sjon_dep.path("src"));
    run_audit_rt_imports.has_side_effects = true;
    const audit_rt_imports_step = b.step("audit-rt-imports", "Audit the pacer-rt import closure (layer 1: source)");

    // Layer 2 (02 T2.4) — the physical gate, chained into the same verb:
    // layer 1 → the wasm-rt artifact (and the full-wasm control) BUILT as
    // dependencies, never stale → the artifact check. Reads the INSTALLED
    // zig-out/bin paths (the SJON lsp-audit wiring verbatim).
    const check_rt_artifact = b.addExecutable(.{
        .name = "check-rt-artifact",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_rt_artifact.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_check_rt_artifact = b.addRunArtifact(check_rt_artifact);
    run_check_rt_artifact.setCwd(b.path("."));
    run_check_rt_artifact.addArg("zig-out/bin/pacer-rt.wasm");
    run_check_rt_artifact.addArg("zig-out/bin/pacer.wasm");
    run_check_rt_artifact.step.dependOn(&run_audit_rt_imports.step);
    run_check_rt_artifact.step.dependOn(&install_wasm_rt.step);
    run_check_rt_artifact.step.dependOn(&install_wasm.step);
    run_check_rt_artifact.has_side_effects = true;
    audit_rt_imports_step.dependOn(&run_check_rt_artifact.step);

    // The gate's own unit + mutation-fixture tests ride `zig build test`
    // (02:280-290: proof by mutation — the six fixture trees under
    // tools/testdata/rt-imports/ each carry one known-bad shape).
    const audit_rt_imports_test_mod = b.createModule(.{
        .root_source_file = b.path("tools/audit_rt_imports.zig"),
        .target = target,
        .optimize = optimize,
    });
    audit_rt_imports_test_mod.addImport("build_options", build_options_mod);
    const audit_rt_imports_tests = b.addTest(.{ .root_module = audit_rt_imports_test_mod });
    test_step.dependOn(&b.addRunArtifact(audit_rt_imports_tests).step);

    // Layer 2's synthetic-bytes tests ride `zig build test` too (the
    // 02:263-268 edge matrix: empty imports pass; the single inert import
    // passes; wrong kind/module/name/signature or any second import fails).
    const check_rt_artifact_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_rt_artifact.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(check_rt_artifact_tests).step);
}
