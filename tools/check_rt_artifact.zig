//! Physical closure gate for `pacer-rt.wasm` — layer 2 (02:239-278,
//! plan-binary02 T2.4).
//!
//! Layer 1 (`tools/audit_rt_imports.zig`) is a text scan with a stated,
//! frozen blind spot: indented imports and dynamically built names evade
//! it. The shipped bytes have no blind spot — anything actually referenced
//! gets linked (Zig's lazy analysis + DCE), and its imports, exports, or
//! strings fail HERE. This tool reads the BUILT `zig-out/bin/pacer-rt.wasm`
//! and fails unless:
//!
//!   (a) its import section is EMPTY or holds exactly one function import
//!       — module `env`, name `sjon_host_invoke_plugin`, signature
//!       `(i32, i32) -> i32` (the wasm-level spelling of `(req_ptr: u32,
//!       req_len: u32) callconv(.c) ?[*]u8`,
//!       `SJON/src/wasm_plugin_invoker.zig:78-80`). The signature is
//!       resolved through the type section and asserted, not just the
//!       name: the glue's instantiation must bind a stub matching what
//!       the artifact declares. The empty-or-one allowance is 02:242's
//!       frozen text (the import is statically unavoidable and
//!       dynamically inert with `plugin-exec=false`; a second import, the
//!       right name with a wrong kind/module/signature, or any lazily
//!       surfaced forbidden chain fails right here);
//!   (b) its export set equals the frozen seventeen `prt_*` names plus the
//!       linear-memory export `memory` (rdynamic would leak a stray
//!       `pub`);
//!   (c) the frozen MARKER list — compiler-only string constants, each
//!       with its own source provenance — appears NOWHERE in the artifact,
//!       with the control direction asserted the same run: every marker
//!       must be present in the full `zig-out/bin/pacer.wasm`, so a stale
//!       marker fails loudly too (02:259-263).
//!
//! The section parser is bounds-checked throughout: LEB128 reads are
//! over-long-guarded, section sizes are checked against the remaining
//! bytes — this is never a `search-by-name` scan of raw bytes.
//!
//! Usage: `check-rt-artifact <pacer-rt.wasm> <pacer.wasm>` (the control is
//! the full artifact; both are BUILT dependencies of the verb, never
//! stale reads of a previous build).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

/// The one frozen import (02:242-257). `?[*]u8` lowers to an i32 pointer.
const FROZEN_IMPORT_MODULE = "env";
const FROZEN_IMPORT_NAME = "sjon_host_invoke_plugin";

/// The frozen export set (02:103-106's seventeen + the linear memory,
/// spelling mirrored from the artifact the same way `src/wasm_entry.zig`'s
/// memory export is spelled — the default `memory` name both entries
/// produce). Exact set, both directions.
const ExportKind = enum(u8) { func = 0x00, table = 0x01, mem = 0x02, global = 0x03 };
const FrozenExport = struct { name: []const u8, kind: ExportKind };
const FROZEN_EXPORTS = [_]FrozenExport{
    .{ .name = "prt_abiVersion", .kind = .func },
    .{ .name = "prt_pacbPtr", .kind = .func },
    .{ .name = "prt_pacbCap", .kind = .func },
    .{ .name = "prt_targetsPtr", .kind = .func },
    .{ .name = "prt_targetsCap", .kind = .func },
    .{ .name = "prt_metaPtr", .kind = .func },
    .{ .name = "prt_metaLen", .kind = .func },
    .{ .name = "prt_writesPtr", .kind = .func },
    .{ .name = "prt_load", .kind = .func },
    .{ .name = "prt_loadError", .kind = .func },
    .{ .name = "prt_eval", .kind = .func },
    .{ .name = "prt_evalTicks", .kind = .func },
    .{ .name = "prt_setControl", .kind = .func },
    .{ .name = "prt_clearControl", .kind = .func },
    .{ .name = "prt_registerControl", .kind = .func },
    .{ .name = "prt_setBpm", .kind = .func },
    .{ .name = "prt_exprFailures", .kind = .func },
    .{ .name = "memory", .kind = .mem },
};

/// The frozen compiler-only marker list (≥3, each a DISTINCT source
/// provenance). Every entry must be ABSENT from `pacer-rt.wasm` and
/// PRESENT in the full `pacer.wasm` (the control direction, same run) —
/// presence in the control is what keeps a stale marker loud.
const MARKERS = [_]struct { bytes: []const u8, provenance: []const u8 }{
    .{
        .bytes = "target_arity_mismatch",
        .provenance = "pacer's compiler diagnostic vocabulary — src/Compile.zig's `Compile.Code` " ++
            "tag names ride the 'PACD' blob; the runtime never compiles a score",
    },
    .{
        .bytes = "repr-shape",
        .provenance = "pacer's score manifest f32-range key — schema/pacer.sjon is embedded via " ++
            "the `pacer_schema` build import ONLY into the full artifact's module (build.zig " ++
            "wires it to wasm_entry, never to rt_entry)",
    },
    .{
        .bytes = "use-plugin",
        .provenance = "SJON's text-parser plugin directive — ../SJON/src/Parser.zig; the runtime " ++
            "decodes PACB and ships no parser",
    },
};

const MAGIC = [_]u8{ 0x00, 0x61, 0x73, 0x6d };
const TYPE_SECTION_ID: u8 = 1;
const IMPORT_SECTION_ID: u8 = 2;
const EXPORT_SECTION_ID: u8 = 7;

const VALTYPE_I32: u8 = 0x7f;

/// A cursor over the module bytes. Every read is bounds-checked — a
/// truncated or hostile artifact must produce a clear `malformed`, never
/// a panic.
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) ?[]const u8 {
        if (self.pos + n > self.bytes.len) return null;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    fn byte(self: *Reader) ?u8 {
        const b = self.take(1) orelse return null;
        return b[0];
    }

    /// Unsigned LEB128, as every wasm length and count is encoded.
    /// Over-long encodings (> 5 bytes for u32) are malformed.
    fn uleb(self: *Reader) ?u32 {
        var result: u32 = 0;
        var shift: u5 = 0;
        while (true) {
            const b = self.byte() orelse return null;
            const payload: u32 = b & 0x7f;
            result |= payload << shift;
            if (b & 0x80 == 0) return result;
            if (shift >= 28) return null;
            shift += 7;
        }
    }

    /// A length-prefixed UTF-8 name (module or field).
    fn name(self: *Reader) ?[]const u8 {
        const len = self.uleb() orelse return null;
        return self.take(len);
    }
};

const Sig = struct { params: []const u8, results: []const u8 };
const Import = struct { module: []const u8, field: []const u8, kind: u8, typeidx: u32 };
const Export = struct { name: []const u8, kind: u8 };

/// The parsed module surface, or why it could not be walked.
const Module = struct {
    types: []const Sig,
    imports: []const Import,
    exports: []const Export,
};

const ParseError = error{ Malformed, OutOfMemory };

/// Parse the type, import, and export sections of `bytes`. `why` receives
/// a static message on malformed input.
fn parseModule(arena: Allocator, bytes: []const u8, why: *[]const u8) ParseError!Module {
    var r: Reader = .{ .bytes = bytes };
    const magic = r.take(4) orelse {
        why.* = "file shorter than the 4-byte magic";
        return error.Malformed;
    };
    if (!std.mem.eql(u8, magic, &MAGIC)) {
        why.* = "not a wasm module (bad magic)";
        return error.Malformed;
    }
    const version = r.take(4) orelse {
        why.* = "missing version word";
        return error.Malformed;
    };
    if (!std.mem.eql(u8, version, &WASM_VERSION)) {
        why.* = "unsupported wasm version (want 1.0.0.0)";
        return error.Malformed;
    }

    var types: std.ArrayList(Sig) = .empty;
    var imports: std.ArrayList(Import) = .empty;
    var exports: std.ArrayList(Export) = .empty;

    while (r.pos < bytes.len) {
        const id = r.byte() orelse {
            why.* = "truncated section id";
            return error.Malformed;
        };
        const size = r.uleb() orelse {
            why.* = "truncated or over-long section size";
            return error.Malformed;
        };
        const body = r.take(size) orelse {
            why.* = "section size runs past end of file";
            return error.Malformed;
        };
        var sec: Reader = .{ .bytes = body };
        switch (id) {
            TYPE_SECTION_ID => {
                const count = sec.uleb() orelse {
                    why.* = "truncated type count";
                    return error.Malformed;
                };
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const form = sec.byte() orelse {
                        why.* = "truncated type entry";
                        return error.Malformed;
                    };
                    if (form != 0x60) {
                        why.* = "type entry is not a function type (0x60)";
                        return error.Malformed;
                    }
                    const np = sec.uleb() orelse {
                        why.* = "truncated param count";
                        return error.Malformed;
                    };
                    const params = sec.take(np) orelse {
                        why.* = "truncated params";
                        return error.Malformed;
                    };
                    const nr = sec.uleb() orelse {
                        why.* = "truncated result count";
                        return error.Malformed;
                    };
                    const results = sec.take(nr) orelse {
                        why.* = "truncated results";
                        return error.Malformed;
                    };
                    try types.append(arena, .{ .params = params, .results = results });
                }
                if (sec.pos != body.len) {
                    why.* = "trailing bytes in type section";
                    return error.Malformed;
                }
            },
            IMPORT_SECTION_ID => {
                const count = sec.uleb() orelse {
                    why.* = "truncated import count";
                    return error.Malformed;
                };
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const mod_name = sec.name() orelse {
                        why.* = "truncated import module name";
                        return error.Malformed;
                    };
                    const field = sec.name() orelse {
                        why.* = "truncated import field name";
                        return error.Malformed;
                    };
                    const kind = sec.byte() orelse {
                        why.* = "truncated import kind";
                        return error.Malformed;
                    };
                    var typeidx: u32 = 0;
                    switch (kind) {
                        0x00 => typeidx = sec.uleb() orelse {
                            why.* = "truncated import type index";
                            return error.Malformed;
                        },
                        0x01 => { // table: reftype + limits
                            _ = sec.byte() orelse {
                                why.* = "truncated table reftype";
                                return error.Malformed;
                            };
                            try skipLimits(&sec, why);
                        },
                        0x02 => try skipLimits(&sec, why), // memory: limits
                        0x03 => { // global: valtype + mutability
                            _ = sec.take(2) orelse {
                                why.* = "truncated global descriptor";
                                return error.Malformed;
                            };
                        },
                        else => {
                            why.* = "unknown import kind";
                            return error.Malformed;
                        },
                    }
                    try imports.append(arena, .{ .module = mod_name, .field = field, .kind = kind, .typeidx = typeidx });
                }
                if (sec.pos != body.len) {
                    why.* = "trailing bytes in import section";
                    return error.Malformed;
                }
            },
            EXPORT_SECTION_ID => {
                const count = sec.uleb() orelse {
                    why.* = "truncated export count";
                    return error.Malformed;
                };
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    const nm = sec.name() orelse {
                        why.* = "truncated export name";
                        return error.Malformed;
                    };
                    const kind = sec.byte() orelse {
                        why.* = "truncated export kind";
                        return error.Malformed;
                    };
                    _ = sec.uleb() orelse { // index
                        why.* = "truncated export index";
                        return error.Malformed;
                    };
                    try exports.append(arena, .{ .name = nm, .kind = kind });
                }
                if (sec.pos != body.len) {
                    why.* = "trailing bytes in export section";
                    return error.Malformed;
                }
            },
            else => continue, // other sections are not the gate's business
        }
    }
    return .{ .types = types.items, .imports = imports.items, .exports = exports.items };
}

fn skipLimits(sec: *Reader, why: *[]const u8) ParseError!void {
    const flags = sec.uleb() orelse {
        why.* = "truncated limits flags";
        return error.Malformed;
    };
    _ = sec.uleb() orelse { // min
        why.* = "truncated limits min";
        return error.Malformed;
    };
    switch (flags) {
        0x00 => {},
        0x01, 0x03 => {
            _ = sec.uleb() orelse { // max
                why.* = "truncated limits max";
                return error.Malformed;
            };
        },
        else => {
            why.* = "unsupported limits flags";
            return error.Malformed;
        },
    }
}

/// The layer-2 verdict for one artifact.
pub const Report = struct {
    /// Gate failures (each names what is wrong). Empty on success.
    failures: []const []const u8,
    /// Set when the bytes could not even be walked as a bounded module.
    malformed: ?[]const u8,
    import_count: usize,
    export_count: usize,

    pub fn ok(self: Report) bool {
        return self.failures.len == 0 and self.malformed == null;
    }
};

/// Rules (a) + (b) against the rt artifact's bytes.
pub fn checkModule(arena: Allocator, bytes: []const u8) Allocator.Error!Report {
    var failures: std.ArrayList([]const u8) = .empty;
    var why: []const u8 = "";
    const mod = parseModule(arena, bytes, &why) catch |err| switch (err) {
        error.Malformed => return .{
            .failures = &.{},
            .malformed = why,
            .import_count = 0,
            .export_count = 0,
        },
        error.OutOfMemory => return error.OutOfMemory,
    };

    // (a) imports: empty, or exactly the one frozen function import with
    // the frozen signature RESOLVED through the type section.
    if (mod.imports.len == 1) {
        const imp = mod.imports[0];
        if (imp.kind != 0x00) {
            try failures.append(arena, try std.fmt.allocPrint(arena, "the single import {s}.{s} has kind 0x{x:0>2}, want 0x00 (function)", .{ imp.module, imp.field, imp.kind }));
        } else if (!std.mem.eql(u8, imp.module, FROZEN_IMPORT_MODULE) or
            !std.mem.eql(u8, imp.field, FROZEN_IMPORT_NAME))
        {
            try failures.append(arena, try std.fmt.allocPrint(arena, "the single import is {s}.{s}, want {s}.{s}", .{ imp.module, imp.field, FROZEN_IMPORT_MODULE, FROZEN_IMPORT_NAME }));
        } else if (imp.typeidx >= mod.types.len) {
            try failures.append(arena, try std.fmt.allocPrint(arena, "the frozen import's type index {d} is out of range ({d} types)", .{ imp.typeidx, mod.types.len }));
        } else {
            const sig = mod.types[imp.typeidx];
            const want_params = [_]u8{ VALTYPE_I32, VALTYPE_I32 };
            const want_results = [_]u8{VALTYPE_I32};
            if (!std.mem.eql(u8, sig.params, &want_params) or !std.mem.eql(u8, sig.results, &want_results)) {
                try failures.append(arena, try std.fmt.allocPrint(arena, "the frozen import's signature is not (i32, i32) -> i32", .{}));
            }
        }
    } else if (mod.imports.len > 1) {
        try failures.append(arena, try std.fmt.allocPrint(arena, "{d} imports declared, want empty or exactly one — first is {s}.{s}, second is {s}.{s}", .{
            mod.imports.len,
            mod.imports[0].module,
            mod.imports[0].field,
            mod.imports[1].module,
            mod.imports[1].field,
        }));
    }

    // (b) exports: the frozen set, exact both directions.
    for (FROZEN_EXPORTS) |want| {
        var found = false;
        for (mod.exports) |got| {
            if (std.mem.eql(u8, got.name, want.name)) {
                found = true;
                if (got.kind != @intFromEnum(want.kind)) {
                    try failures.append(arena, try std.fmt.allocPrint(arena, "export `{s}` has kind 0x{x:0>2}, want 0x{x:0>2}", .{ want.name, got.kind, @intFromEnum(want.kind) }));
                }
                break;
            }
        }
        if (!found) {
            try failures.append(arena, try std.fmt.allocPrint(arena, "frozen export `{s}` is missing", .{want.name}));
        }
    }
    for (mod.exports) |got| {
        var expected = false;
        for (FROZEN_EXPORTS) |want| {
            if (std.mem.eql(u8, got.name, want.name)) {
                expected = true;
                break;
            }
        }
        if (!expected) {
            try failures.append(arena, try std.fmt.allocPrint(arena, "unexpected export `{s}` (kind 0x{x:0>2}) — the frozen surface is append-only and reviewed", .{ got.name, got.kind }));
        }
    }

    return .{
        .failures = failures.items,
        .malformed = null,
        .import_count = mod.imports.len,
        .export_count = mod.exports.len,
    };
}

/// Rule (c): every marker ABSENT from the rt artifact, PRESENT in the
/// control (same run — a stale marker fails loudly).
pub fn checkMarkers(
    arena: Allocator,
    rt_bytes: []const u8,
    control_bytes: []const u8,
) Allocator.Error![]const []const u8 {
    var failures: std.ArrayList([]const u8) = .empty;
    for (MARKERS) |m| {
        if (std.mem.indexOf(u8, rt_bytes, m.bytes) != null) {
            try failures.append(arena, try std.fmt.allocPrint(arena, "marker `{s}` is PRESENT in the runtime artifact ({s})", .{ m.bytes, m.provenance }));
        }
        if (std.mem.indexOf(u8, control_bytes, m.bytes) == null) {
            try failures.append(arena, try std.fmt.allocPrint(arena, "marker `{s}` is ABSENT from the full-artifact control — the marker is stale, replace it ({s})", .{ m.bytes, m.provenance }));
        }
    }
    return failures.items;
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
    if (args.len < 3) {
        try out.print("check-rt-artifact: expected <pacer-rt.wasm> <pacer.wasm> (the control)\n", .{});
        return 2;
    }
    const rt_bytes = Io.Dir.cwd().readFileAlloc(io, args[1], arena, .unlimited) catch |err| {
        try out.print("check-rt-artifact: cannot read {s}: {s}\n", .{ args[1], @errorName(err) });
        return 2;
    };
    const control_bytes = Io.Dir.cwd().readFileAlloc(io, args[2], arena, .unlimited) catch |err| {
        try out.print("check-rt-artifact: cannot read control {s}: {s}\n", .{ args[2], @errorName(err) });
        return 2;
    };

    const report = try checkModule(arena, rt_bytes);
    const marker_failures = try checkMarkers(arena, rt_bytes, control_bytes);

    if (report.ok() and marker_failures.len == 0) {
        try out.print(
            "check-rt-artifact: OK — {s} ({d} bytes): {d} import(s) (the frozen empty-or-one " ++
                "allowance; env.sjon_host_invoke_plugin asserted (i32,i32)->i32 through the type " ++
                "section), export set exactly the frozen 17 prt_* + memory, {d} compiler-only " ++
                "marker(s) absent here and present in the {d}-byte control.\n",
            .{ args[1], rt_bytes.len, report.import_count, MARKERS.len, control_bytes.len },
        );
        return 0;
    }

    try out.print("check-rt-artifact: FAIL — {s} ({d} bytes):\n\n", .{ args[1], rt_bytes.len });
    if (report.malformed) |m| {
        try out.print("  x malformed module: {s}\n\n", .{m});
    }
    for (report.failures) |f| try out.print("  x {s}\n\n", .{f});
    for (marker_failures) |f| try out.print("  x {s}\n\n", .{f});
    try out.print(
        "The physical gate is the backstop for layer 1's stated blind spots: anything the\n" ++
            "source scan misses that is actually referenced gets linked, and its imports,\n" ++
            "exports, or strings fail here. The frozen surface (02:103-106, 242-272) is\n" ++
            "append-only and reviewed; a marker that drifted out of the full artifact must be\n" ++
            "re-picked with its provenance.\n",
        .{},
    );
    return 1;
}

// ---------------------------------------------------------------------------
// Tests — synthetic module bytes (02:263-268's edge matrix), never the real
// artifacts (the verb checks those; the parser's unit coverage must not
// depend on a build product).
// ---------------------------------------------------------------------------

const testing = std.testing;

const WASM_VERSION = [_]u8{ 0x01, 0x00, 0x00, 0x00 };
const HEADER = MAGIC ++ WASM_VERSION;

/// uleb128-encode `v` onto `out`.
fn encUleb(a: Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var x = v;
    while (true) {
        const b: u8 = @intCast(x & 0x7f);
        x >>= 7;
        if (x == 0) {
            try out.append(a, b);
            return;
        }
        try out.append(a, b | 0x80);
    }
}

fn section(a: Allocator, id: u8, body: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(a, id);
    try encUleb(a, &out, @intCast(body.len));
    try out.appendSlice(a, body);
    return out.items;
}

/// A type-section body holding one `(i32, i32) -> i32` entry (index 0),
/// plus a decoy `(i32) -> i32` at index 1 for the wrong-signature tests.
const TYPE_BODY = [_]u8{
    0x02, // two types
    0x60, 0x02, 0x7f, 0x7f, 0x01, 0x7f, // (i32,i32)->(i32)
    0x60, 0x01, 0x7f, 0x01, 0x7f, // (i32)->(i32)
};

fn typeSection(a: Allocator) ![]u8 {
    return section(a, TYPE_SECTION_ID, &TYPE_BODY);
}

fn importEntry(a: Allocator, module_: []const u8, field: []const u8, kind: u8, tail: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try encUleb(a, &out, @intCast(module_.len));
    try out.appendSlice(a, module_);
    try encUleb(a, &out, @intCast(field.len));
    try out.appendSlice(a, field);
    try out.append(a, kind);
    try out.appendSlice(a, tail);
    return out.items;
}

fn importSection(a: Allocator, entries: []const []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    try encUleb(a, &body, @intCast(entries.len));
    for (entries) |e| try body.appendSlice(a, e);
    return section(a, IMPORT_SECTION_ID, body.items);
}

/// The frozen single import at type index 0 = (i32,i32)->i32.
fn frozenImport(a: Allocator) ![]u8 {
    return importEntry(a, "env", "sjon_host_invoke_plugin", 0x00, &[_]u8{0x00});
}

fn exportBody(a: Allocator, extra: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    try encUleb(a, &body, @intCast(FROZEN_EXPORTS.len));
    for (FROZEN_EXPORTS) |e| {
        try encUleb(a, &body, @intCast(e.name.len));
        try body.appendSlice(a, e.name);
        try body.append(a, @intFromEnum(e.kind));
        try encUleb(a, &body, 0); // index — irrelevant to the gate
    }
    try body.appendSlice(a, extra);
    return body.items;
}

fn exportSection(a: Allocator) ![]u8 {
    return section(a, EXPORT_SECTION_ID, try exportBody(a, &.{}));
}

fn moduleWithHeader(a: Allocator, header: []const u8, sections: []const []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, header);
    for (sections) |s| try out.appendSlice(a, s);
    return out.items;
}

fn module(a: Allocator, sections: []const []const u8) ![]u8 {
    return moduleWithHeader(a, &HEADER, sections);
}

/// Run every synthetic-bytes test with one arena per test (the module
/// bytes and the report both die with it — nothing reaches
/// `testing.allocator` unchecked).
fn withArena(run: fn (Allocator) anyerror!void) !void {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    try run(arena_inst.allocator());
}

fn expectOk(a: Allocator, bytes: []const u8) !void {
    const report = try checkModule(a, bytes);
    if (!report.ok()) {
        std.debug.print("expected OK, got malformed={?s} failures:\n", .{report.malformed});
        for (report.failures) |f| std.debug.print("  {s}\n", .{f});
        return error.TestUnexpectedResult;
    }
}

/// Assert the module fails, and some failure names `needle`.
fn expectFailNaming(a: Allocator, bytes: []const u8, needle: []const u8) !void {
    const report = try checkModule(a, bytes);
    try testing.expect(!report.ok());
    try testing.expect(report.malformed == null);
    for (report.failures) |f| {
        if (std.mem.indexOf(u8, f, needle) != null) return;
    }
    std.debug.print("no failure names `{s}`:\n", .{needle});
    for (report.failures) |f| std.debug.print("  {s}\n", .{f});
    return error.TestUnexpectedResult;
}

fn expectMalformed(a: Allocator, bytes: []const u8) !void {
    const report = try checkModule(a, bytes);
    try testing.expect(report.malformed != null);
}

/// Assert the module is malformed AND the reason names `needle`.
fn expectMalformedNaming(a: Allocator, bytes: []const u8, needle: []const u8) !void {
    const report = try checkModule(a, bytes);
    const why = report.malformed orelse {
        std.debug.print("expected malformed naming `{s}`, got OK ({d} failures)\n", .{ needle, report.failures.len });
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOf(u8, why, needle) == null) {
        std.debug.print("malformed reason does not name `{s}`: {s}\n", .{ needle, why });
        return error.TestUnexpectedResult;
    }
}

test "empty import section passes; frozen exports pass" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            const m = try module(a, &.{ try typeSection(a), try section(a, IMPORT_SECTION_ID, &[_]u8{0x00}), try exportSection(a) });
            try expectOk(a, m);
        }
    }.run);
}

test "the single inert import at the frozen signature passes" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{try frozenImport(a)}), try exportSection(a) });
            try expectOk(a, m);
        }
    }.run);
}

test "wrong kind on the frozen name is rejected" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            // memory import: kind 0x02, limits flags 0x00 min 1
            const imp = try importEntry(a, "env", "sjon_host_invoke_plugin", 0x02, &[_]u8{ 0x00, 0x01 });
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{imp}), try exportSection(a) });
            try expectFailNaming(a, m, "kind");
        }
    }.run);
}

test "wrong module is rejected" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            const imp = try importEntry(a, "wasi_snapshot_preview1", "sjon_host_invoke_plugin", 0x00, &[_]u8{0x00});
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{imp}), try exportSection(a) });
            try expectFailNaming(a, m, "wasi_snapshot_preview1");
        }
    }.run);
}

test "wrong name is rejected" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            const imp = try importEntry(a, "env", "sjon_host_invoke_plugin_v2", 0x00, &[_]u8{0x00});
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{imp}), try exportSection(a) });
            try expectFailNaming(a, m, "sjon_host_invoke_plugin_v2");
        }
    }.run);
}

test "wrong signature is rejected (asserted through the type section, not the name)" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            // typeidx 1 = (i32)->(i32) — right module, right name, wrong shape.
            const imp = try importEntry(a, "env", "sjon_host_invoke_plugin", 0x00, &[_]u8{0x01});
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{imp}), try exportSection(a) });
            try expectFailNaming(a, m, "signature");
        }
    }.run);
}

test "any second import is rejected" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            const extra = try importEntry(a, "env", "evil", 0x00, &[_]u8{0x00});
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{ try frozenImport(a), extra }), try exportSection(a) });
            try expectFailNaming(a, m, "env.evil");
        }
    }.run);
}

test "a missing frozen export is rejected by name" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            // All exports except prt_eval.
            var body: std.ArrayList(u8) = .empty;
            try encUleb(a, &body, @intCast(FROZEN_EXPORTS.len - 1));
            for (FROZEN_EXPORTS) |e| {
                if (std.mem.eql(u8, e.name, "prt_eval")) continue;
                try encUleb(a, &body, @intCast(e.name.len));
                try body.appendSlice(a, e.name);
                try body.append(a, @intFromEnum(e.kind));
                try encUleb(a, &body, 0);
            }
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{try frozenImport(a)}), try section(a, EXPORT_SECTION_ID, body.items) });
            try expectFailNaming(a, m, "prt_eval");
        }
    }.run);
}

test "an unexpected extra export is rejected by name (rdynamic leak class)" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            var body: std.ArrayList(u8) = .empty;
            try encUleb(a, &body, @intCast(FROZEN_EXPORTS.len + 1));
            for (FROZEN_EXPORTS) |e| {
                try encUleb(a, &body, @intCast(e.name.len));
                try body.appendSlice(a, e.name);
                try body.append(a, @intFromEnum(e.kind));
                try encUleb(a, &body, 0);
            }
            try encUleb(a, &body, 13);
            try body.appendSlice(a, "compile_score");
            try body.append(a, 0x00);
            try encUleb(a, &body, 0);
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{try frozenImport(a)}), try section(a, EXPORT_SECTION_ID, body.items) });
            try expectFailNaming(a, m, "compile_score");
        }
    }.run);
}

test "the memory export with the wrong kind is rejected" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            var body: std.ArrayList(u8) = .empty;
            try encUleb(a, &body, @intCast(FROZEN_EXPORTS.len));
            for (FROZEN_EXPORTS) |e| {
                try encUleb(a, &body, @intCast(e.name.len));
                try body.appendSlice(a, e.name);
                const kind: u8 = if (std.mem.eql(u8, e.name, "memory")) 0x00 else @intFromEnum(e.kind);
                try body.append(a, kind);
                try encUleb(a, &body, 0);
            }
            const m = try module(a, &.{ try typeSection(a), try importSection(a, &.{try frozenImport(a)}), try section(a, EXPORT_SECTION_ID, body.items) });
            try expectFailNaming(a, m, "memory");
        }
    }.run);
}

test "each interpreted section must be consumed completely" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            // Type section: declared entries parsed, then a stray byte.
            const type_tail = TYPE_BODY ++ [_]u8{0xaa};
            const m1 = try module(a, &.{
                try section(a, TYPE_SECTION_ID, &type_tail),
                try section(a, IMPORT_SECTION_ID, &[_]u8{0x00}),
                try exportSection(a),
            });
            try expectMalformedNaming(a, m1, "trailing bytes in type section");

            // Import section: a ZERO count followed by a tail byte (the
            // reviewer's exact shape — "treated as empty" before).
            const m2 = try module(a, &.{
                try typeSection(a),
                try section(a, IMPORT_SECTION_ID, &[_]u8{ 0x00, 0xaa }),
                try exportSection(a),
            });
            try expectMalformedNaming(a, m2, "trailing bytes in import section");

            // Export section: the frozen set parsed, then a stray byte.
            const m3 = try module(a, &.{
                try typeSection(a),
                try section(a, IMPORT_SECTION_ID, &[_]u8{0x00}),
                try section(a, EXPORT_SECTION_ID, try exportBody(a, &[_]u8{0xaa})),
            });
            try expectMalformedNaming(a, m3, "trailing bytes in export section");
        }
    }.run);
}

test "a wrong wasm version is refused by name" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            const wrong_version = MAGIC ++ [_]u8{ 0x02, 0x00, 0x00, 0x00 };
            const m = try moduleWithHeader(a, &wrong_version, &.{
                try typeSection(a),
                try section(a, IMPORT_SECTION_ID, &[_]u8{0x00}),
                try exportSection(a),
            });
            try expectMalformedNaming(a, m, "version");
        }
    }.run);
}

test "malformed input is diagnosed, never panics" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            try expectMalformed(a, "");
            try expectMalformed(a, "nope");
            try expectMalformed(a, &(MAGIC ++ [_]u8{0x01}));
            // Section claiming more bytes than remain.
            try expectMalformed(a, &(HEADER ++ [_]u8{ 0x02, 0x7f }));
            // Over-long LEB128 in a section size (six continuation bytes).
            try expectMalformed(a, &(HEADER ++ [_]u8{ 0x02, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 }));
            // Import section whose body is absent (size 1, nothing there).
            try expectMalformed(a, &(HEADER ++ [_]u8{ 0x02, 0x01 }));
            // Import entry with a truncated module name.
            const bad = HEADER ++ [_]u8{ 0x02, 0x03, 0x01, 0x05, 'e' };
            try expectMalformed(a, &bad);
        }
    }.run);
}

test "marker scan: present-in-rt fails; absent-from-control fails (stale marker)" {
    try withArena(struct {
        fn run(a: Allocator) !void {
            // Both directions clean.
            try testing.expectEqual(@as(usize, 0), (try checkMarkers(a, "clean rt bytes", "target_arity_mismatch repr-shape use-plugin")).len);
            // A marker in the rt artifact fails, naming it.
            const f1 = try checkMarkers(a, "rt bytes carrying target_arity_mismatch text", "target_arity_mismatch repr-shape use-plugin");
            try testing.expect(f1.len == 1);
            try testing.expect(std.mem.indexOf(u8, f1[0], "target_arity_mismatch") != null);
            // A marker missing from the CONTROL fails too (the stale-marker direction).
            const f2 = try checkMarkers(a, "clean rt bytes", "target_arity_mismatch repr-shape");
            try testing.expect(f2.len == 1);
            try testing.expect(std.mem.indexOf(u8, f2[0], "use-plugin") != null);
        }
    }.run);
}
