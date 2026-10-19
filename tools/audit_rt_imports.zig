//! Import-closure gate for `pacer-rt.wasm` — layer 1: the syntactic gate
//! (02:199-238, plan-binary02 T2.3).
//!
//! The playback runtime must carry no compiler in its import closure, and
//! pacer reaches SJON through a NAMED module (`@import("sjon")`) whose root
//! is the kitchen-sink aggregate: following the module into `root.zig`
//! would drag the whole write side in, while a `.zig`-only scan would miss
//! `sjon.Parser` member usage entirely. The boundary is therefore fixed at
//! ONE audited pacer file (`src/RtSjon.zig`) and proved physically by
//! layer 2 (`tools/check_rt_artifact.zig`, T2.4 — chained into this verb).
//!
//! Column-0 BFS from `rt_entry.zig` (the SJON convention verbatim:
//! production deps are column-0; test-only imports live indented inside
//! test bodies — the audited honest split) with three module-aware rules:
//!
//!   (a) `@import("sjon")` is legal ONLY inside `RtSjon.zig` — a direct
//!       module import anywhere else in the closure fails by name.
//!   (b) `RtSjon.zig` must match the strict alias grammar: exactly the nine
//!       frozen rows (`pub const X = sjon.X;`, with `plugins.core` nested
//!       under `pub const plugins = struct { … }` — Zig has no dotted decl
//!       names) plus the one `const sjon = @import("sjon");` line, and no
//!       other `sjon` token in any code line (comments are stripped
//!       before the scan) — closing alias and `@field` laundering at the
//!       one crossing.
//!   (c) `.zig` imports resolve against the pacer allowlist (the frozen
//!       02:234-236 twelve); anything else fails by absence. A relative
//!       `..` that walks ABOVE the leg root is refused BY NAME — never
//!       collapsed onto an inside-root path (a collapsed `../Writes.zig`
//!       would otherwise read the allowlisted `Writes.zig` while naming
//!       an outside-root file). Named (non-`.zig`) column-0 imports other than
//!       `std`/`builtin` fail the same way — a column-0
//!       `@import("pacer_schema")` would embed the text schema in the
//!       runtime.
//!
//! The namespace→file map (`Expr` → `Expr.zig`, `plugins.core` →
//! `plugins/core.zig`, …) is asserted against `../SJON/src/root.zig`'s
//! export table on EVERY run, so it cannot drift — `root.zig` is read for
//! the map but never traversed (it is the kitchen sink). From the nine
//! mapped files the same BFS continues inside the SJON tree under the SJON
//! allowlist — the true transitive closure, with SJON's own ALLOWED as the
//! evidence base (`SJON/tools/audit_wasm_imports.zig:84-108`). `Binary.zig`
//! is absent BY DESIGN (C1: the closure's one write-side constant need is
//! the frozen `Pacb.MAX_TREE_DEPTH` copy, equality-pinned in
//! `src/root.zig`). `PluginRuntime.zig` / `runtimes/wasmtime.zig` ride the
//! same audited `comptime_excluded` mechanism SJON uses — textually present
//! through `wasm_plugin_invoker.zig`'s comptime-gated import, never linked
//! on wasm32. A stale entry fails BOTH lists in BOTH directions, exactly as
//! in SJON's tool.
//!
//! ## Blind spot (acceptable, named)
//!
//! An INDENTED `@import` (inside a fn/test body, or a test-only helper
//! struct's field) evades this scan — by design: the SJON doctrine
//! localizes genuinely test-only imports, and Zig's lazy analysis + DCE
//! strips anything the exports don't reach. Layer 2 is the physical
//! backstop for exactly this class; the `honest-split` mutation fixture
//! under `tools/testdata/rt-imports/` pins the pass. A test-only import
//! written at column 0 IS flagged — the fix is to localize it (02's
//! convention), never to weaken the checker.
//!
//! Reads source as text (no `sjon` import) so it stays a cheap leaf tool.
//!
//! Usage: `audit-rt-imports [pacer-src-root] [sjon-src-root]` — the
//! root-dir parameters are what the mutation fixtures exercise (proof by
//! mutation, 02:280-290); build.zig's `audit-rt-imports` step passes the
//! real roots.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// Entry point of the runtime closure (pacer-root-relative).
const PACER_ENTRY = "rt_entry.zig";
/// The one audited window file (pacer-root-relative).
const RT_SJON = "RtSjon.zig";

/// One member of an intended closure, with the role that earns its place.
/// Allowlist, not blocklist — anything unlisted fails by absence, and a
/// listed-but-unreached entry fails as stale (the list can only shrink or
/// grow by accident otherwise). See SJON's tool header for the doctrine.
const Allowed = struct {
    path: []const u8,
    why: []const u8,
    /// True when the module is reachable in *text* but comptime-excluded
    /// from the wasm32 artifact. See `COMPTIME_NOTE`.
    comptime_excluded: bool = false,
};

/// Why two host-runtime modules sit in the closure's text.
const COMPTIME_NOTE =
    "reached only through `wasm_plugin_invoker.zig`'s " ++
    "`if (native_plugin_exec) @import(...)`, which is false on wasm32 — " ++
    "so it is textually reachable but never linked into the artifact. " ++
    "This is the one audited exception to the column-0 rule.";

/// The frozen pacer-side closure (02:234-236).
const PACER_ALLOWED = [_]Allowed{
    .{ .path = "rt_entry.zig", .why = "the runtime entry itself" },
    .{ .path = "RtSjon.zig", .why = "the one audited SJON window" },
    .{ .path = "PactCodec.zig", .why = "'PACT' target codec (std-only)" },
    .{ .path = "Pacb.zig", .why = "the 'PACB' decoder" },
    .{ .path = "Pacm.zig", .why = "the 'PACM' meta reader (std-only)" },
    .{ .path = "EvalCore.zig", .why = "the one engine (tree|binary leaf source)" },
    .{ .path = "ExprTrack.zig", .why = "expr tracks (evalAt / evalAtBinary)" },
    .{ .path = "PatternTrack.zig", .why = "pattern tracks (tree arm; the binary arm is P4)" },
    .{ .path = "TrackTable.zig", .why = "the compiled tick-grid table" },
    .{ .path = "TimeMap.zig", .why = "seconds↔tick conversions" },
    .{ .path = "Easing.zig", .why = "easing programs" },
    .{ .path = "Writes.zig", .why = "the 'PACW' write buffer (std-only)" },
};

/// The frozen SJON-side closure (02:215-224, re-derived against this
/// checkout — see the `plugins/core.zig` row's why). `Binary.zig` absent
/// by design (C1).
const SJON_ALLOWED = [_]Allowed{
    .{ .path = "Ast.zig", .why = "the SoA tree + wire-stable Diagnostic.Code" },
    .{ .path = "Expr.zig", .why = "evalBinary — expression evaluation over IR" },
    .{ .path = "Pattern.zig", .why = "tick algebra" },
    .{ .path = "PatternQuery.zig", .why = "the pattern query engine (tree arm)" },
    .{ .path = "BinaryCursor.zig", .why = "the single-pass IR reader" },
    .{ .path = "BinaryFormat.zig", .why = "wire-format constants and header parsing" },
    .{ .path = "Schema.zig", .why = "schema lookup over registered plugins" },
    .{ .path = "Plugin.zig", .why = "the plugin vocabulary types" },
    .{ .path = "trig.zig", .why = "vendored transcendentals — native/wasm bit reproducibility" },
    .{ .path = "Date.zig", .why = "date atoms (leaf, std-only)" },
    .{ .path = "Time.zig", .why = "time atoms (leaf, std-only)" },
    // Not in 02:215-224's enumeration — a re-derivation correction: the
    // plugins.core row's own file, AND column-0-reached from Schema.zig's
    // test region (SJON/src/Schema.zig:2407). Required by the stale rule.
    .{ .path = "plugins/core.zig", .why = "the core expression vocabulary — the plugins.core row's file" },
    .{ .path = "wasm_plugin_invoker.zig", .why = "host-invoke bridge; declarative-only with plugin-exec=false" },
    .{ .path = "PluginValueCodec.zig", .why = "plugin value encoding across the ABI" },
    .{ .path = "PluginRuntime.zig", .why = COMPTIME_NOTE, .comptime_excluded = true },
    .{ .path = "runtimes/wasmtime.zig", .why = COMPTIME_NOTE, .comptime_excluded = true },
};

/// The frozen namespace→file map — asserted against SJON's `root.zig`
/// export table every run, then used to seed the SJON-leg BFS.
const NS_MAP = [_]struct { ns: []const u8, file: []const u8 }{
    .{ .ns = "Ast", .file = "Ast.zig" },
    .{ .ns = "Expr", .file = "Expr.zig" },
    .{ .ns = "Pattern", .file = "Pattern.zig" },
    .{ .ns = "PatternQuery", .file = "PatternQuery.zig" },
    .{ .ns = "BinaryCursor", .file = "BinaryCursor.zig" },
    .{ .ns = "Schema", .file = "Schema.zig" },
    .{ .ns = "Plugin", .file = "Plugin.zig" },
    .{ .ns = "trig", .file = "trig.zig" },
    .{ .ns = "plugins.core", .file = "plugins/core.zig" },
};

/// The strict alias grammar (rule b): the only lines of `RtSjon.zig` that
/// may mention `sjon` at all. Spellings frozen — a renamed LHS, a plucked
/// member (`sjon.Ast.Parser`), an extra row, or an `@field(sjon, …)` all
/// fail here. (Whitespace-trimmed comparison; `zig fmt` keeps the
/// canonical spelling.)
const RTSJON_IMPORT_LINE = "const sjon = @import(\"sjon\");";
const RTSJON_ROWS = [_][]const u8{
    "pub const Ast = sjon.Ast;",
    "pub const Expr = sjon.Expr;",
    "pub const Pattern = sjon.Pattern;",
    "pub const PatternQuery = sjon.PatternQuery;",
    "pub const BinaryCursor = sjon.BinaryCursor;",
    "pub const Schema = sjon.Schema;",
    "pub const Plugin = sjon.Plugin;",
    "pub const trig = sjon.trig;",
    "pub const core = sjon.plugins.core;",
};
const RTSJON_PLUGINS_OPEN = "pub const plugins = struct {";

/// Named (non-`.zig`) imports allowed at column 0, per leg.
const PACER_NAMED_ALLOWED = [_][]const u8{ "std", "builtin" };
const SJON_NAMED_ALLOWED = [_][]const u8{ "std", "builtin", "build_options" };

/// One gate failure, with everything the message needs.
pub const Finding = struct {
    kind: Kind,
    /// The offending module path, row text, or namespace.
    path: []const u8,
    /// Where the offending line sits: `"<root-label>:<file>:<line>"`.
    where: []const u8,
    /// The raw import argument or the offending source line (trimmed).
    detail: []const u8,
    /// The discovery chain for closure findings ("a.zig → b.zig → …"),
    /// empty for grammar/map findings.
    chain: []const u8,

    pub const Kind = enum {
        /// `@import("sjon")` at column 0 outside RtSjon.zig.
        direct_sjon,
        /// A `.zig` import resolved outside the leg's allowlist.
        forbidden_zig,
        /// A relative import whose `..` walks above the leg root.
        escape_above_root,
        /// A column-0 named import outside the leg's allowed set.
        named_import,
        /// RtSjon.zig broke the strict alias grammar.
        rtsjon_grammar,
        /// The namespace→file map disagrees with SJON's root.zig.
        ns_map,
    };
};

pub const Report = struct {
    findings: []const Finding,
    stale_pacer: []const []const u8,
    stale_sjon: []const []const u8,
    visited_pacer: usize,
    visited_sjon: usize,

    pub fn ok(self: Report) bool {
        return self.findings.len == 0 and
            self.stale_pacer.len == 0 and
            self.stale_sjon.len == 0;
    }
};

const AuditError = error{ UnreadableEntry, OutOfMemory };

/// Run the whole layer-1 audit. `arena` owns the returned report.
/// `pacer_root` / `sjon_root` are directory paths (the real gate gets
/// `src` and the SJON dependency's `src`; fixtures point at their trees).
/// Errors only on unreadable allowlisted files / entry / SJON root —
/// forbidden hits are findings, never errors (the tool never descends into
/// them, so it never needs to read them).
pub fn audit(
    arena: Allocator,
    io: Io,
    pacer_root: []const u8,
    sjon_root: []const u8,
) AuditError!Report {
    var findings: std.ArrayList(Finding) = .empty;

    // ---- Pacer leg: column-0 BFS from rt_entry.zig ----------------------
    var pacer_nodes: std.ArrayList(Node) = .empty;
    var pacer_visited: std.StringHashMapUnmanaged(void) = .empty;
    var pacer_reported: std.StringHashMapUnmanaged(void) = .empty;
    try pacer_nodes.append(arena, .{ .path = PACER_ENTRY, .parent = null });
    try pacer_visited.put(arena, PACER_ENTRY, {});

    var sjon_seeded = false;
    var sjon_nodes: std.ArrayList(Node) = .empty;
    var sjon_visited: std.StringHashMapUnmanaged(void) = .empty;
    var sjon_reported: std.StringHashMapUnmanaged(void) = .empty;

    var i: usize = 0;
    while (i < pacer_nodes.items.len) : (i += 1) {
        const node = pacer_nodes.items[i];
        const bytes = try readUnder(arena, io, pacer_root, node.path, "src");
        const dir = dirOf(node.path);
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (!isColumnZero(line)) continue;
            var imports: std.ArrayList([]const u8) = .empty;
            try collectImports(arena, line, &imports);
            for (imports.items) |raw| {
                if (std.mem.eql(u8, raw, "sjon")) {
                    if (std.mem.eql(u8, node.path, RT_SJON)) continue; // rule (a)'s one legal site
                    if (!pacer_reported.contains(raw)) {
                        try pacer_reported.put(arena, raw, {});
                        try findings.append(arena, .{
                            .kind = .direct_sjon,
                            .path = raw,
                            .where = try where(arena, "src", node.path, line_no),
                            .detail = raw,
                            .chain = try chain(arena, pacer_nodes.items, i),
                        });
                    }
                    continue;
                }
                if (!std.mem.endsWith(u8, raw, ".zig")) {
                    if (!namedAllowed(&PACER_NAMED_ALLOWED, raw)) {
                        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ node.path, raw });
                        if (!pacer_reported.contains(key)) {
                            try pacer_reported.put(arena, key, {});
                            try findings.append(arena, .{
                                .kind = .named_import,
                                .path = raw,
                                .where = try where(arena, "src", node.path, line_no),
                                .detail = raw,
                                .chain = try chain(arena, pacer_nodes.items, i),
                            });
                        }
                    }
                    continue;
                }
                const resolved = normalizeJoin(arena, dir, raw) catch |err| switch (err) {
                    error.TraversalAboveRoot => {
                        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ node.path, raw });
                        if (!pacer_reported.contains(key)) {
                            try pacer_reported.put(arena, key, {});
                            try findings.append(arena, .{
                                .kind = .escape_above_root,
                                .path = raw,
                                .where = try where(arena, "src", node.path, line_no),
                                .detail = raw,
                                .chain = try chain(arena, pacer_nodes.items, i),
                            });
                        }
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (allowedEntry(&PACER_ALLOWED, resolved) == null) {
                    if (!pacer_reported.contains(resolved)) {
                        try pacer_reported.put(arena, resolved, {});
                        try findings.append(arena, .{
                            .kind = .forbidden_zig,
                            .path = resolved,
                            .where = try where(arena, "src", node.path, line_no),
                            .detail = raw,
                            .chain = try chain(arena, pacer_nodes.items, i),
                        });
                    }
                    continue; // sink: never descend into a forbidden module
                }
                if (!pacer_visited.contains(resolved)) {
                    try pacer_visited.put(arena, resolved, {});
                    try pacer_nodes.append(arena, .{ .path = resolved, .parent = i });
                }
            }
        }

        // ---- The one crossing: grammar + map assert + SJON-leg seed -----
        if (std.mem.eql(u8, node.path, RT_SJON) and !sjon_seeded) {
            sjon_seeded = true;
            if (checkWindowGrammar(arena, bytes)) |viol| {
                try findings.append(arena, .{
                    .kind = .rtsjon_grammar,
                    .path = viol.path,
                    .where = try where(arena, "src", RT_SJON, viol.line),
                    .detail = viol.detail,
                    .chain = "",
                });
            }
            // The namespace→file map, asserted against SJON's own export
            // table every run. root.zig is READ, never traversed.
            const root_bytes = try readUnder(arena, io, sjon_root, "root.zig", "sjon");
            var export_map: std.StringHashMapUnmanaged([]const u8) = .empty;
            try parseRootExports(arena, root_bytes, &export_map);
            for (NS_MAP) |row| {
                const got = export_map.get(row.ns);
                if (got == null or !std.mem.eql(u8, got.?, row.file)) {
                    try findings.append(arena, .{
                        .kind = .ns_map,
                        .path = row.ns,
                        .where = try where(arena, "sjon", "root.zig", 0),
                        .detail = try std.fmt.allocPrint(arena, "map claims {s} → {s}; root.zig {s}", .{
                            row.ns, row.file, if (got) |g| g else "has no such export",
                        }),
                        .chain = "",
                    });
                    continue;
                }
                // Map row verified ⇒ seed the SJON leg at its file.
                if (!sjon_visited.contains(row.file)) {
                    try sjon_visited.put(arena, row.file, {});
                    try sjon_nodes.append(arena, .{ .path = row.file, .parent = null });
                }
            }
        }
    }

    // ---- SJON leg: the same BFS inside the dependency tree --------------
    var j: usize = 0;
    while (j < sjon_nodes.items.len) : (j += 1) {
        const node = sjon_nodes.items[j];
        const bytes = try readUnder(arena, io, sjon_root, node.path, "sjon");
        const dir = dirOf(node.path);
        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (!isColumnZero(line)) continue;
            var imports: std.ArrayList([]const u8) = .empty;
            try collectImports(arena, line, &imports);
            for (imports.items) |raw| {
                if (!std.mem.endsWith(u8, raw, ".zig")) {
                    if (!namedAllowed(&SJON_NAMED_ALLOWED, raw)) {
                        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ node.path, raw });
                        if (!sjon_reported.contains(key)) {
                            try sjon_reported.put(arena, key, {});
                            try findings.append(arena, .{
                                .kind = .named_import,
                                .path = raw,
                                .where = try where(arena, "sjon", node.path, line_no),
                                .detail = raw,
                                .chain = try chain(arena, sjon_nodes.items, j),
                            });
                        }
                    }
                    continue;
                }
                const resolved = normalizeJoin(arena, dir, raw) catch |err| switch (err) {
                    error.TraversalAboveRoot => {
                        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ node.path, raw });
                        if (!sjon_reported.contains(key)) {
                            try sjon_reported.put(arena, key, {});
                            try findings.append(arena, .{
                                .kind = .escape_above_root,
                                .path = raw,
                                .where = try where(arena, "sjon", node.path, line_no),
                                .detail = raw,
                                .chain = try chain(arena, sjon_nodes.items, j),
                            });
                        }
                        continue;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                if (allowedEntry(&SJON_ALLOWED, resolved) == null) {
                    if (!sjon_reported.contains(resolved)) {
                        try sjon_reported.put(arena, resolved, {});
                        try findings.append(arena, .{
                            .kind = .forbidden_zig,
                            .path = resolved,
                            .where = try where(arena, "sjon", node.path, line_no),
                            .detail = raw,
                            .chain = try chain(arena, sjon_nodes.items, j),
                        });
                    }
                    continue;
                }
                if (!sjon_visited.contains(resolved)) {
                    try sjon_visited.put(arena, resolved, {});
                    try sjon_nodes.append(arena, .{ .path = resolved, .parent = j });
                }
            }
        }
    }

    // ---- Stale entries fail both lists, both directions ------------------
    var stale_pacer: std.ArrayList([]const u8) = .empty;
    for (PACER_ALLOWED) |e| {
        if (!pacer_visited.contains(e.path)) try stale_pacer.append(arena, e.path);
    }
    var stale_sjon: std.ArrayList([]const u8) = .empty;
    for (SJON_ALLOWED) |e| {
        if (!sjon_visited.contains(e.path)) try stale_sjon.append(arena, e.path);
    }

    return .{
        .findings = findings.items,
        .stale_pacer = stale_pacer.items,
        .stale_sjon = stale_sjon.items,
        .visited_pacer = pacer_nodes.items.len,
        .visited_sjon = sjon_nodes.items.len,
    };
}

/// Render a report (OK or FAIL) exactly as the gate prints it.
pub fn render(out: *std.Io.Writer, report: Report) !void {
    if (report.ok()) {
        var linked: usize = 0;
        for (SJON_ALLOWED) |e| {
            if (!e.comptime_excluded) linked += 1;
        }
        try out.print(
            "audit-rt-imports: OK — the runtime closure is exactly the {d} allowlisted pacer module(s) " ++
                "+ the {d} allowlisted SJON module(s) ({d} linked, {d} comptime-excluded on wasm32); " ++
                "the namespace→file map matches SJON's root.zig.\n",
            .{ report.visited_pacer, report.visited_sjon, linked, report.visited_sjon - linked },
        );
        return;
    }
    try out.print("audit-rt-imports: FAIL — the runtime closure gate (layer 1) found:\n\n", .{});
    for (report.findings) |f| {
        switch (f.kind) {
            .direct_sjon => try out.print(
                "  x direct @import(\"sjon\") outside RtSjon.zig\n      {s}\n      {s}\n\n",
                .{ f.where, f.chain },
            ),
            .forbidden_zig => try out.print(
                "  x {s}\n      {s}\n      reached as `{s}` via {s}\n\n",
                .{ f.path, whyForbidden(f.path), f.detail, f.chain },
            ),
            .escape_above_root => try out.print(
                "  x relative import `{s}` escapes above the leg root\n      {s}\n      {s}\n\n",
                .{ f.detail, f.where, f.chain },
            ),
            .named_import => try out.print(
                "  x column-0 named import `{s}` is not std/builtin (or build_options on the SJON leg)\n      {s}\n      {s}\n\n",
                .{ f.path, f.where, f.chain },
            ),
            .rtsjon_grammar => try out.print(
                "  x RtSjon.zig strict-grammar violation\n      {s}\n      {s}\n\n",
                .{ f.where, f.detail },
            ),
            .ns_map => try out.print(
                "  x namespace→file map drift\n      {s}\n\n",
                .{f.detail},
            ),
        }
    }
    if (report.stale_pacer.len > 0) {
        try out.print("  x {d} pacer-allowlisted module(s) are no longer in the closure:\n", .{report.stale_pacer.len});
        for (report.stale_pacer) |p| try out.print("      - {s}\n", .{p});
        try out.print("\n", .{});
    }
    if (report.stale_sjon.len > 0) {
        try out.print("  x {d} SJON-allowlisted module(s) are no longer in the closure:\n", .{report.stale_sjon.len});
        for (report.stale_sjon) |p| try out.print("      - {s}\n", .{p});
        try out.print("\n", .{});
    }
    try out.print(
        "The pacer-rt.wasm runtime ships the playback closure and nothing else. A test-only\n" ++
            "import belongs INDENTED inside its fn/test body (the audited honest split; layer 2\n" ++
            "— tools/check_rt_artifact.zig — is the physical backstop for that class). A genuine\n" ++
            "new production dependency joins PACER_ALLOWED/SJON_ALLOWED with its role stated.\n",
        .{},
    );
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    var out_buf: [8192]u8 = undefined;
    var out_file = Io.File.stdout();
    var out_writer = out_file.writer(io, &out_buf);
    defer out_writer.interface.flush() catch {};
    const out = &out_writer.interface;

    var arena_inst = std.heap.ArenaAllocator.init(gpa);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const args = try init.minimal.args.toSlice(arena);
    const pacer_root = if (args.len > 1) args[1] else "src";
    const sjon_root = if (args.len > 2) args[2] else "../SJON/src";

    const report = audit(arena, io, pacer_root, sjon_root) catch |err| {
        try out.print("audit-rt-imports: cannot read the closure: {s}\n", .{@errorName(err)});
        return 2;
    };
    try render(out, report);
    return if (report.ok()) 0 else 1;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

/// A visited module in the BFS. `parent` threads the discovery chain back
/// to the entry so a forbidden hit can print how it was reached.
const Node = struct { path: []const u8, parent: ?usize };

fn readUnder(arena: Allocator, io: Io, root: []const u8, rel: []const u8, label: []const u8) AuditError![]u8 {
    _ = label;
    const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root, rel });
    return Io.Dir.cwd().readFileAlloc(io, full, arena, .unlimited) catch {
        return error.UnreadableEntry;
    };
}

fn where(arena: Allocator, label: []const u8, path: []const u8, line: usize) Allocator.Error![]u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}:{d}", .{ label, path, line });
}

/// Print `entry → … → via` by walking parent pointers.
fn chain(arena: Allocator, nodes: []const Node, via: usize) Allocator.Error![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    var cur: ?usize = via;
    while (cur) |c| {
        try parts.append(arena, nodes[c].path);
        cur = nodes[c].parent;
    }
    var out: std.ArrayList(u8) = .empty;
    var n = parts.items.len;
    while (n > 0) {
        n -= 1;
        try out.appendSlice(arena, parts.items[n]);
        if (n > 0) try out.appendSlice(arena, " → ");
    }
    return out.items;
}

/// The allowlist entry for `path`, or null when it does not belong.
fn allowedEntry(list: []const Allowed, path: []const u8) ?Allowed {
    for (list) |e| {
        if (std.mem.eql(u8, path, e.path)) return e;
    }
    return null;
}

fn namedAllowed(list: []const []const u8, name: []const u8) bool {
    for (list) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    return false;
}

/// Why `path` must not appear, for the commonly-forbidden modules on
/// either leg. Falls back to a generic message so an unrecognised newcomer
/// still fails actionably.
fn whyForbidden(path: []const u8) []const u8 {
    const known = [_]struct { pat: []const u8, why: []const u8 }{
        .{ .pat = "Compile.zig", .why = "the text-path compiler — the runtime decodes PACB, never compiles" },
        .{ .pat = "Schema.zig", .why = "pacer's text-schema loader (src/Schema.zig) — the runtime's schema is the frozen core-only one" },
        .{ .pat = "Driver.zig", .why = "the text-path driver pair — compiler side" },
        .{ .pat = "Abi.zig", .why = "the drv_* blob codec — compiler/driver side" },
        .{ .pat = "Eval.zig", .why = "the facade — outside the runtime closure (EvalCore is the engine)" },
        .{ .pat = "PacbEncode.zig", .why = "the PACB encoder — write side (`pacer pack`)" },
        .{ .pat = "wasm_entry.zig", .why = "the drv_* entry — the OTHER artifact" },
        .{ .pat = "corpus_runner.zig", .why = "the golden-corpus runner — a test driver" },
        .{ .pat = "parity_runner.zig", .why = "a test driver" },
        .{ .pat = "cli", .why = "the native CLI — a consumer of the public module, never runtime" },
        .{ .pat = "test_support.zig", .why = "test helpers — never production" },
        .{ .pat = "fuzz.zig", .why = "the fuzz harness — never production" },
        .{ .pat = "root.zig", .why = "the kitchen-sink aggregate — pulls the entire write side" },
        .{ .pat = "Parser.zig", .why = "the text parser — the runtime decodes IR, never parses source" },
        .{ .pat = "Printer.zig", .why = "the canonical printer — write-side only" },
        .{ .pat = "Json.zig", .why = "the std.json bridge — write-side only" },
        .{ .pat = "Edit.zig", .why = "structural edits — write-side only" },
        .{ .pat = "Binary.zig", .why = "the write-side Binary encoder/decoder — absent BY DESIGN (C1)" },
        .{ .pat = "Validator.zig", .why = "the document validator — compile-side" },
        .{ .pat = "Host.zig", .why = "the validating host — drags in Parser / ManifestLoader / Lowering" },
        .{ .pat = "ManifestLoader.zig", .why = "manifest loading — host/write-side" },
        .{ .pat = "Lowering.zig", .why = "form lowering — host-side" },
        .{ .pat = "Lexer.zig", .why = "the lexer — text tokenization, parse-side" },
    };
    for (known) |k| {
        if (std.mem.startsWith(u8, path, k.pat)) return k.why;
    }
    return "not on the closure allowlist — if it genuinely belongs, add it with its role";
}

/// A strict-grammar violation in RtSjon.zig.
const GrammarViolation = struct { path: []const u8, detail: []const u8, line: usize };

/// Rule (b): every CODE line of `bytes` that mentions `sjon` must be one
/// of the frozen spellings, and each frozen row must appear exactly once.
/// Line comments are stripped first — the grammar governs code; prose may
/// discuss the module freely (no frozen line's string literal contains a
/// "//"). Returns the first violation, or null when the grammar holds.
fn checkWindowGrammar(arena: Allocator, bytes: []const u8) ?GrammarViolation {
    var row_counts = [_]usize{0} ** RTSJON_ROWS.len;
    var import_seen: usize = 0;
    var open_seen: usize = 0;

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const code_end = std.mem.indexOf(u8, line, "//") orelse line.len;
        const trimmed = std.mem.trim(u8, line[0..code_end], " \t\r");
        if (trimmed.len == 0) continue;
        // The nested block's opener carries no `sjon` token — count it first.
        if (std.mem.eql(u8, trimmed, RTSJON_PLUGINS_OPEN)) {
            open_seen += 1;
            continue;
        }
        if (std.mem.indexOf(u8, trimmed, "sjon") == null) continue;
        if (std.mem.eql(u8, trimmed, RTSJON_IMPORT_LINE)) {
            import_seen += 1;
            continue;
        }
        var matched = false;
        for (RTSJON_ROWS, 0..) |row, k| {
            if (std.mem.eql(u8, trimmed, row)) {
                row_counts[k] += 1;
                matched = true;
                break;
            }
        }
        if (!matched) {
            return .{
                .path = RT_SJON,
                .detail = std.fmt.allocPrint(arena, "line not in the frozen grammar: `{s}`", .{trimmed}) catch trimmed,
                .line = line_no,
            };
        }
    }
    if (import_seen != 1) return .{ .path = RT_SJON, .detail = "the window must hold exactly one `const sjon = @import(\"sjon\");`", .line = 0 };
    if (open_seen != 1) return .{ .path = RT_SJON, .detail = "the nested `pub const plugins = struct {` opener must appear exactly once", .line = 0 };
    for (RTSJON_ROWS, 0..) |row, k| {
        if (row_counts[k] != 1) {
            return .{
                .path = RT_SJON,
                .detail = std.fmt.allocPrint(arena, "frozen row `{s}` appears {d} time(s), want exactly 1", .{ row, row_counts[k] }) catch row,
                .line = 0,
            };
        }
    }
    return null;
}

/// Parse SJON root.zig's export table: `pub const X = @import("Y");` rows,
/// plus the nested `pub const plugins = struct { … }` block (recorded as
/// `plugins.<name>`). Anything else is ignored — the map assert only ever
/// looks the nine frozen namespaces up.
fn parseRootExports(
    arena: Allocator,
    bytes: []const u8,
    out: *std.StringHashMapUnmanaged([]const u8),
) Allocator.Error!void {
    const PREFIX = "pub const ";
    const MIDDLE = " = @import(\"";
    var in_plugins = false;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (in_plugins) {
            if (std.mem.eql(u8, trimmed, "};")) {
                in_plugins = false;
                continue;
            }
            if (!std.mem.startsWith(u8, trimmed, PREFIX)) continue;
            const rest = trimmed[PREFIX.len..];
            const mid = std.mem.indexOf(u8, rest, MIDDLE) orelse continue;
            const after = rest[mid + MIDDLE.len ..];
            const close = std.mem.indexOfScalar(u8, after, '"') orelse continue;
            const key = try std.fmt.allocPrint(arena, "plugins.{s}", .{rest[0..mid]});
            try out.put(arena, key, after[0..close]);
            continue;
        }
        // The nested block's opener is its own line shape (no @import).
        if (std.mem.eql(u8, trimmed, "pub const plugins = struct {")) {
            in_plugins = true;
            continue;
        }
        if (!std.mem.startsWith(u8, trimmed, PREFIX)) continue;
        const rest = trimmed[PREFIX.len..];
        const mid = std.mem.indexOf(u8, rest, MIDDLE) orelse continue;
        const after = rest[mid + MIDDLE.len ..];
        const close = std.mem.indexOfScalar(u8, after, '"') orelse continue;
        try out.put(arena, rest[0..mid], after[0..close]);
    }
}

/// Directory portion of a root-relative path ("" for a top-level file).
fn dirOf(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| return path[0..idx];
    return "";
}

/// True when `line` begins at column 0 (no leading whitespace) — the
/// marker for a file-scope, production `const X = @import(...)` line.
fn isColumnZero(line: []const u8) bool {
    return line.len > 0 and line[0] != ' ' and line[0] != '\t';
}

const IMPORT_NEEDLE = "@import(\"";

/// Append every `@import("…")` argument on `line` to `out` (slices into
/// `line`; filtering is the caller's job). An unterminated `@import("` is
/// skipped.
fn collectImports(gpa: Allocator, line: []const u8, out: *std.ArrayList([]const u8)) Allocator.Error!void {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, IMPORT_NEEDLE)) |idx| {
        const start = idx + IMPORT_NEEDLE.len;
        const end_rel = std.mem.indexOfScalar(u8, line[start..], '"') orelse {
            pos = start;
            continue;
        };
        try out.append(gpa, line[start .. start + end_rel]);
        pos = start + end_rel + 1;
    }
}

/// Join `base_dir` (root-relative, possibly "") with an `@import` argument
/// `rel`, collapsing `.` / `..` / empty segments. Returns an owned,
/// root-relative, forward-slashed path. A `..` with no base component left
/// is `error.TraversalAboveRoot`: it names a path OUTSIDE the leg root, so
/// collapsing it onto an inside-root file (`../Writes.zig` → `Writes.zig`)
/// would audit a different file than the import names. Escapes that stay
/// below the root resolve normally and the allowlist decides them.
fn normalizeJoin(gpa: Allocator, base_dir: []const u8, rel: []const u8) (Allocator.Error || error{TraversalAboveRoot})![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(gpa);

    var it_base = std.mem.splitScalar(u8, base_dir, '/');
    while (it_base.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        try parts.append(gpa, seg);
    }
    var it_rel = std.mem.splitScalar(u8, rel, '/');
    while (it_rel.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len == 0) return error.TraversalAboveRoot;
            _ = parts.pop();
            continue;
        }
        try parts.append(gpa, seg);
    }
    return try std.mem.join(gpa, "/", parts.items);
}

// ---------------------------------------------------------------------------
// Tests — pure helpers plus the six mutation fixture trees (02:280-290:
// proof by mutation; each fixture runs the REAL audit over an altered
// source tree and asserts the failure names the shape).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dirOf: top-level, one, and two segments" {
    try testing.expectEqualStrings("", dirOf("Ast.zig"));
    try testing.expectEqualStrings("plugins", dirOf("plugins/core.zig"));
    try testing.expectEqualStrings("runtimes", dirOf("runtimes/wasmtime.zig"));
}

test "isColumnZero: file-scope vs indented vs blank" {
    try testing.expect(isColumnZero("const Ast = @import(\"Ast.zig\");"));
    try testing.expect(!isColumnZero("    const Parser = @import(\"Parser.zig\");"));
    try testing.expect(!isColumnZero("\tconst x = 1;"));
    try testing.expect(!isColumnZero(""));
}

test "collectImports: every arg, unfiltered by extension" {
    const a = testing.allocator;
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(a);
    try collectImports(a, "const Ast = @import(\"Ast.zig\");", &out);
    try collectImports(a, "const v = @import(\"version.zig\").string;", &out);
    try collectImports(a, "const s = @import(\"std\");", &out);
    try collectImports(a, "no imports on this line", &out);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("Ast.zig", out.items[0]);
    try testing.expectEqualStrings("version.zig", out.items[1]);
    try testing.expectEqualStrings("std", out.items[2]);
}

test "normalizeJoin: resolves within the leg, refuses traversal above it" {
    const a = testing.allocator;
    const cases = [_]struct { base: []const u8, rel: []const u8, want: []const u8 }{
        .{ .base = "", .rel = "Ast.zig", .want = "Ast.zig" },
        .{ .base = "plugins", .rel = "../Ast.zig", .want = "Ast.zig" },
        .{ .base = "plugins", .rel = "./pattern.zig", .want = "plugins/pattern.zig" },
        .{ .base = "a/b", .rel = "../x.zig", .want = "a/x.zig" }, // one level, still inside
        .{ .base = "a/b", .rel = "../../x.zig", .want = "x.zig" }, // exactly the root, still inside
    };
    for (cases) |c| {
        const got = try normalizeJoin(a, c.base, c.rel);
        defer a.free(got);
        try testing.expectEqualStrings(c.want, got);
    }

    // Escapes are refused, never collapsed onto an inside-root path — even
    // when the escaped basename IS allowlisted (the real collision shape).
    const escapes = [_]struct { base: []const u8, rel: []const u8 }{
        .{ .base = "", .rel = "../Parser.zig" },
        .{ .base = "", .rel = "../Writes.zig" },
        .{ .base = "plugins", .rel = "../../Ast.zig" },
        .{ .base = "a/b", .rel = "../../../x.zig" },
    };
    for (escapes) |c| {
        if (normalizeJoin(a, c.base, c.rel)) |got| {
            a.free(got);
            return error.TestExpectedError;
        } else |err| {
            try testing.expectEqual(error.TraversalAboveRoot, err);
        }
    }
}

test "allowedEntry: the closure sets pass, compiler/write-side modules do not" {
    try testing.expect(allowedEntry(&PACER_ALLOWED, "rt_entry.zig") != null);
    try testing.expect(allowedEntry(&PACER_ALLOWED, "RtSjon.zig") != null);
    try testing.expect(allowedEntry(&PACER_ALLOWED, "EvalCore.zig") != null);
    try testing.expect(allowedEntry(&PACER_ALLOWED, "Compile.zig") == null);
    try testing.expect(allowedEntry(&PACER_ALLOWED, "Eval.zig") == null);
    try testing.expect(allowedEntry(&PACER_ALLOWED, "PacbEncode.zig") == null);
    try testing.expect(allowedEntry(&PACER_ALLOWED, "Schema.zig") == null);
    try testing.expect(allowedEntry(&SJON_ALLOWED, "Ast.zig") != null);
    try testing.expect(allowedEntry(&SJON_ALLOWED, "plugins/core.zig") != null);
    try testing.expect(allowedEntry(&SJON_ALLOWED, "Binary.zig") == null); // absent by design (C1)
    try testing.expect(allowedEntry(&SJON_ALLOWED, "Parser.zig") == null);
    try testing.expect(allowedEntry(&SJON_ALLOWED, "root.zig") == null);
    try testing.expect(allowedEntry(&SJON_ALLOWED, "PluginRuntime.zig").?.comptime_excluded);
    try testing.expect(allowedEntry(&SJON_ALLOWED, "runtimes/wasmtime.zig").?.comptime_excluded);
}

test "strict grammar: the real spellings pass; laundering fails by name" {
    const a = testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const good =
        "//! doc mentioning SJON (uppercase is not the token)\n" ++
        "const sjon = @import(\"sjon\");\n" ++
        "\n" ++
        "pub const Ast = sjon.Ast;\n" ++
        "pub const Expr = sjon.Expr;\n" ++
        "pub const Pattern = sjon.Pattern;\n" ++
        "pub const PatternQuery = sjon.PatternQuery;\n" ++
        "pub const BinaryCursor = sjon.BinaryCursor;\n" ++
        "pub const Schema = sjon.Schema;\n" ++
        "pub const Plugin = sjon.Plugin;\n" ++
        "pub const trig = sjon.trig;\n" ++
        "pub const plugins = struct {\n" ++
        "    pub const core = sjon.plugins.core;\n" ++
        "};\n";
    try testing.expect(checkWindowGrammar(arena, good) == null);

    // Alias laundering: an extra row for a write-side namespace.
    const extra = good ++ "pub const Parser = sjon.Parser;\n";
    const v1 = checkWindowGrammar(arena, extra).?;
    try testing.expect(std.mem.indexOf(u8, v1.detail, "sjon.Parser") != null);

    // Member plucking off a legal row's RHS.
    const plucked = try std.mem.replaceOwned(u8, arena, good, "pub const Ast = sjon.Ast;", "pub const Ast = sjon.Ast.Parser;");
    try testing.expect(checkWindowGrammar(arena, plucked) != null);

    // @field laundering: `sjon` outside the frozen lines at all.
    const field = good ++ "const P = @field(sjon, \"Parser\");\n";
    try testing.expect(checkWindowGrammar(arena, field) != null);

    // A missing row fails the exact-set rule.
    const missing = try std.mem.replaceOwned(u8, arena, good, "pub const trig = sjon.trig;\n", "");
    const v4 = checkWindowGrammar(arena, missing).?;
    try testing.expect(std.mem.indexOf(u8, v4.detail, "trig") != null);
}

test "parseRootExports: flat rows and the nested plugins block" {
    const a = testing.allocator;
    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const root =
        "pub const Ast = @import(\"Ast.zig\");\n" ++
        "pub const Expr = @import(\"Expr.zig\");\n" ++
        "pub const Parser = @import(\"Parser.zig\");\n" ++
        "pub const plugins = struct {\n" ++
        "    pub const core = @import(\"plugins/core.zig\");\n" ++
        "    pub const pattern = @import(\"plugins/pattern.zig\");\n" ++
        "};\n" ++
        "pub const Mode = Ast.Mode;\n";
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    try parseRootExports(arena, root, &map);
    try testing.expectEqualStrings("Ast.zig", map.get("Ast").?);
    try testing.expectEqualStrings("Expr.zig", map.get("Expr").?);
    try testing.expectEqualStrings("Parser.zig", map.get("Parser").?);
    try testing.expectEqualStrings("plugins/core.zig", map.get("plugins.core").?);
    try testing.expectEqualStrings("plugins/pattern.zig", map.get("plugins.pattern").?);
    try testing.expect(map.get("Mode") == null); // not an @import row
}

// -- The mutation fixtures ---------------------------------------------------

const Fixture = struct {
    name: []const u8,
    want_ok: bool,
    /// Every needle must appear in some finding (path/detail) or stale
    /// list — the tool NAMES the shape; the test carries no list oracle.
    fail_needles: []const []const u8 = &.{},
    /// The rendered report must carry these words too, so a generic
    /// "forbidden" hit cannot stand in for a NAMED refusal.
    fail_render_needles: []const []const u8 = &.{},
};

const FIXTURES = [_]Fixture{
    .{ .name = "direct-sjon", .want_ok = false, .fail_needles = &.{ "sjon", "TrackTable.zig" } },
    .{ .name = "rtsjon-extra-row", .want_ok = false, .fail_needles = &.{"sjon.Parser"} },
    .{ .name = "relative-laundering", .want_ok = false, .fail_needles = &.{"Parser.zig"} },
    .{
        .name = "escape-above-root",
        .want_ok = false,
        .fail_needles = &.{ "../Writes.zig", "../../Ast.zig" },
        .fail_render_needles = &.{"escapes above the leg root"},
    },
    .{ .name = "boundary-crossing", .want_ok = false, .fail_needles = &.{ "Parser.zig", "Expr.zig" } },
    .{ .name = "stale-both-directions", .want_ok = false, .fail_needles = &.{ "Writes.zig", "BinaryFormat.zig" } },
    .{ .name = "honest-split", .want_ok = true },
};

fn runFixture(arena: Allocator, name: []const u8) !Report {
    const repo_root = @import("build_options").repo_root;
    const pacer_root = try std.fmt.allocPrint(arena, "{s}/tools/testdata/rt-imports/{s}/pacer", .{ repo_root, name });
    const sjon_root = try std.fmt.allocPrint(arena, "{s}/tools/testdata/rt-imports/{s}/sjon", .{ repo_root, name });
    return audit(arena, std.testing.io, pacer_root, sjon_root);
}

test "mutation fixtures: the tool fails each bad tree naming the shape, passes the honest split" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    for (FIXTURES) |fx| {
        const report = try runFixture(arena, fx.name);
        if (fx.want_ok) {
            if (!report.ok()) {
                var aw: Io.Writer.Allocating = .init(testing.allocator);
                defer aw.deinit();
                try render(&aw.writer, report);
                std.debug.print("fixture {s} expected OK, got:\n{s}\n", .{ fx.name, aw.written() });
                return error.TestUnexpectedResult;
            }
            continue;
        }
        if (report.ok()) {
            std.debug.print("fixture {s} expected FAIL, got OK\n", .{fx.name});
            return error.TestUnexpectedResult;
        }
        for (fx.fail_needles) |needle| {
            var named = false;
            for (report.findings) |f| {
                if (std.mem.indexOf(u8, f.path, needle) != null or
                    std.mem.indexOf(u8, f.detail, needle) != null or
                    std.mem.indexOf(u8, f.where, needle) != null or
                    std.mem.indexOf(u8, f.chain, needle) != null) named = true;
            }
            for (report.stale_pacer) |p| {
                if (std.mem.indexOf(u8, p, needle) != null) named = true;
            }
            for (report.stale_sjon) |p| {
                if (std.mem.indexOf(u8, p, needle) != null) named = true;
            }
            if (!named) {
                var aw: Io.Writer.Allocating = .init(testing.allocator);
                defer aw.deinit();
                try render(&aw.writer, report);
                std.debug.print("fixture {s}: no finding names `{s}`; report:\n{s}\n", .{ fx.name, needle, aw.written() });
                return error.TestUnexpectedResult;
            }
        }
        if (fx.fail_render_needles.len > 0) {
            var aw: Io.Writer.Allocating = .init(testing.allocator);
            defer aw.deinit();
            try render(&aw.writer, report);
            for (fx.fail_render_needles) |needle| {
                if (std.mem.indexOf(u8, aw.written(), needle) == null) {
                    std.debug.print("fixture {s}: rendered report does not name `{s}`; report:\n{s}\n", .{ fx.name, needle, aw.written() });
                    return error.TestUnexpectedResult;
                }
            }
        }
    }
}

test "render: a failure report names the offending file and the chain" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const report = try runFixture(arena, "direct-sjon");
    try testing.expect(!report.ok());
    var aw: Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    try render(&aw.writer, report);
    const text = aw.written();
    try testing.expect(std.mem.indexOf(u8, text, "FAIL") != null);
    try testing.expect(std.mem.indexOf(u8, text, "TrackTable.zig") != null);
    try testing.expect(std.mem.indexOf(u8, text, "@import(\"sjon\")") != null);
    try testing.expect(std.mem.indexOf(u8, text, "rt_entry.zig") != null); // the chain leads home
}

test "the REAL tree passes layer 1 (the gate's own green pin inside `zig build test`)" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const repo_root = @import("build_options").repo_root;
    const sjon_root = @import("build_options").sjon_src_root;
    const report = try audit(arena, std.testing.io, repo_root ++ "/src", sjon_root);
    if (!report.ok()) {
        var aw: Io.Writer.Allocating = .init(testing.allocator);
        defer aw.deinit();
        try render(&aw.writer, report);
        std.debug.print("real tree FAIL:\n{s}\n", .{aw.written()});
        return error.TestUnexpectedResult;
    }
    // The closure sizes are pinned: 12 pacer + 16 SJON.
    try testing.expectEqual(@as(usize, 12), report.visited_pacer);
    try testing.expectEqual(@as(usize, 16), report.visited_sjon);
}
