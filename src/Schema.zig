//! The pacer score schema, preloaded once.
//!
//! `schema/pacer.sjon` is a portable SJON manifest describing every score
//! form. It is `@embedFile`'d via the `pacer_schema` build import, so it
//! reaches wasm32-freestanding with no filesystem.
//!
//! This module owns the TWO-PHASE construction: the manifest is parsed,
//! loaded, and aggregate-validated ONCE into a `sjon.Host.PreloadedSchema`,
//! and every `Compile.validate` hands that bundle back through
//! `HostOptions.preloaded`. The document is then parsed on its own, so
//! diagnostic spans are DOCUMENT coordinates by construction — there is no
//! prefix to subtract and no manifest region to filter. (pacer used to
//! prepend the manifest text to every score and rebase every span by the
//! prefix length; SJON's `Host.zig` header names that pattern as the one
//! preload replaces.)
//!
//! Lifetime — the borrow-whole rule gains an outer ring. A
//! `Compile.CompileResult` borrows the bundle: its `HostResult` aliases the
//! preloaded `Plugin` structs, and `eval_schema` copies them by value while
//! their interiors stay in the preload arena. So the nesting is
//!
//!     Schema  ⊃  CompileResult  ⊃  Eval.Evaluator
//!
//! and teardown runs inside-out. `Driver` encodes the inner two as
//! structure; this one is the host's: build a `Schema` once, above every
//! `Driver`, and deinit it last.
//!
//! ```zig
//! var schema = try pacer.Schema.load(gpa);
//! defer schema.deinit();
//! var d: Driver = undefined;
//! try d.init(gpa, &schema, source, targets);
//! defer d.deinit();
//! ```

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;

const Schema = @This();

/// Explicit error set. A malformed manifest is not an error here — see
/// `load`: pacer's own schema being well-formed is a build invariant, so a
/// defect is an assert, not a diagnostic the caller has to handle.
pub const Error = error{OutOfMemory};

/// The pacer score schema source, embedded as a portable SJON manifest.
/// Provided as the `pacer_schema` anonymous import by build.zig.
pub const manifest_src: [:0]const u8 = @embedFile("pacer_schema");

/// The loaded bundle. Borrowed by every `CompileResult` built against it.
preloaded: sjon.Host.PreloadedSchema,

/// Preload the embedded pacer schema. O(manifest), paid ONCE per host —
/// not once per compile, as the prepend did.
///
/// Asserts the manifest loaded with zero diagnostics. That is not laxity
/// about user input (the SJON discipline is collection over abort for
/// *documents*): this manifest is `@embedFile`'d repo content, so a defect
/// in it is a build defect with no user to report it to, and re-proving its
/// well-formedness on every compile is what the prepend was doing. The
/// assert is non-vacuous — `loadSource` on a broken manifest is what the
/// test below feeds it.
pub fn load(gpa: Allocator) Error!Schema {
    return loadChecked(gpa, manifest_src);
}

/// `load` over an arbitrary EMBEDDED manifest — same build invariant, same
/// assert. The corpus runner preloads its harness vocabulary
/// (`schema/pacer-corpus.sjon`) through here: a second repo-owned manifest,
/// deliberately NOT composed with the score schema (both declare a `target`
/// form, and one schema holding two would make every unqualified
/// `(target …)` `ambiguous_form`).
pub fn loadChecked(gpa: Allocator, source: [:0]const u8) Error!Schema {
    var self = try loadSource(gpa, source);
    errdefer self.deinit();
    std.debug.assert(self.preloaded.diagnostics.len == 0);
    return self;
}

/// `loadChecked` without the assert. Not API: it exists so the test below
/// can show the assert biting. Production code calls `load` / `loadChecked`.
fn loadSource(gpa: Allocator, source: [:0]const u8) Error!Schema {
    const sources = [_][:0]const u8{source};
    return .{ .preloaded = try sjon.Host.preloadSchema(gpa, &sources) };
}

/// Release the bundle. Every `CompileResult` (and every `Driver`) built
/// against it must be deinited FIRST — see the module header.
pub fn deinit(self: *Schema) void {
    self.preloaded.deinit();
    self.* = undefined;
}

const t_ = std.testing;

test "Schema: the embedded manifest preloads clean" {
    var schema = try load(t_.allocator);
    defer schema.deinit();

    try t_.expectEqual(@as(usize, 0), schema.preloaded.diagnostics.len);
    try t_.expect(!schema.preloaded.hasErrors());
    // One manifest in, one plugin out — and it is pacer's.
    try t_.expectEqual(@as(usize, 1), schema.preloaded.plugins.len);
    try t_.expectEqualStrings("pacer", schema.preloaded.plugins[0].name);
}

test "Schema: load's assert is non-vacuous — a broken manifest does diagnose" {
    // Same code path as `load`, minus the assert: `:underlying` names a
    // shape that does not exist, so the loader reports and the plugin
    // carries the defect. If this ever came back clean, `load`'s assert
    // would be guarding nothing.
    var schema = try loadSource(t_.allocator,
        \\(plugin :name broken
        \\  (value-kind :name nope :underlying not-a-shape))
    );
    defer schema.deinit();

    try t_.expect(schema.preloaded.diagnostics.len > 0);
}

test "Schema: the score vocabulary is reachable through the bundle" {
    // The preloaded schema is user-only (no `core` seeded) — the document
    // pipeline prepends core itself. Prove the pacer forms resolve.
    var schema = try load(t_.allocator);
    defer schema.deinit();

    for ([_][]const u8{ "transport", "track", "scene", "trigger", "control", "tempo", "target" }) |head| {
        try t_.expect(schema.preloaded.schema.lookupForm(head, null) == .found);
    }
    // …and `key` / `stage` are NOT among them: they are slot-local to
    // (track …) / (seq …), so the only way to reach one is through its
    // parent's positional head-set.
    for ([_][]const u8{ "key", "stage" }) |head| {
        try t_.expect(schema.preloaded.schema.lookupForm(head, null) != .found);
    }
}

test "Schema: the manifest declares no :version — one spelling of the version, not two" {
    // `:version` exists to be pinned by a `(use-plugin … :version …)` in a
    // document; pacer's scores never write one (the schema is preloaded, not
    // referenced by name), so a number here is read by nobody and drifts from
    // the real triple — package.json / build.zig.zon / src/root.zig, which
    // `npm/pacer/test/exports.test.js` keeps in lockstep. It drifted: the
    // manifest said 0.1.0 while the package said 0.2.0.
    var schema = try load(t_.allocator);
    defer schema.deinit();

    try t_.expectEqualStrings("", schema.preloaded.plugins[0].version);
}

test "Schema: the workspace project file composes this same manifest" {
    // `sjon-project.sjon` is what `sjon-lsp` and the `sjon` CLI read to
    // learn the score vocabulary; `manifest_src` is what the compiler
    // embeds. Nothing but this test says they are the same file — a
    // renamed manifest, a stale `:plugins` path, or a typo'd project key
    // costs every corpus score and every example its editor support and
    // breaks nothing that builds.
    //
    // The route is the real one: `sjon.loadProject` over the repo root is
    // precisely what `lsp/Handler.loadProject` calls.
    const repo_root = @import("build_options").repo_root;

    var project = try sjon.loadProject(t_.allocator, .{
        .project_root = repo_root,
        .io = t_.io,
    });
    defer project.deinit();

    // Project-file parse failures, unknown project keys (advisory) and
    // per-manifest load failures all land here.
    try t_.expectEqual(@as(usize, 0), project.diagnostics.len);

    // `plugins[0]` is `core`, seeded by the loader; pacer is what the
    // project file contributed.
    try t_.expectEqual(@as(usize, 2), project.plugins.len);
    try t_.expectEqualStrings("pacer", project.plugins[1].name);

    // Head for head: every form the compiler preloads resolves through
    // the workspace schema an editor builds.
    var schema = try load(t_.allocator);
    defer schema.deinit();
    for (schema.preloaded.plugins[0].forms) |form| {
        try t_.expect(project.schema.lookupForm(form.name, null) == .found);
    }
}
