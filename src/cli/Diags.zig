//! Diagnostics — the one array all three verbs carry, plus `check`'s two
//! renderings.
//!
//! Read from `CompileResult` in memory, NOT from the `'PACD'` blob. The
//! blob carries a code ORDINAL; a person reading a report wants the NAME,
//! and only the in-memory enum has it. (`corpus_runner` goes the other
//! way, and should: its whole job is proving the blob byte-identical
//! native and wasm. The CLI is native-only and makes no parity claim, so
//! encoding through a wasm-boundary format to render native-only output
//! would be ritual, not proof.)
//!
//! What rendering from memory re-spells is the MERGE — `Abi.encodeDiags`
//! writes every SJON validation diagnostic first, then every pacer load
//! code. That is a second spelling and it can drift, so it is pinned by a
//! counterfactual test against the blob rather than by a decoder.

const std = @import("std");
const pacer = @import("pacer");
const sjon = @import("sjon");
const Json = @import("Json.zig");
const Envelope = @import("Envelope.zig");
const Source = @import("Source.zig");
const Writer = std.Io.Writer;

pub const Record = struct {
    /// Reusing `Abi`'s wire enum rather than a private twin, so the CLI's
    /// spelling of "who produced this" cannot drift from the blob's.
    producer: pacer.Abi.DiagSource,
    severity: pacer.Abi.DiagSeverity,
    /// `@tagName` of the producer's own code enum — the readable half.
    code: []const u8,
    /// The wire ordinal — the STABLE half. Both, because the name is what
    /// a person greps and the ordinal is what is pinned append-only.
    code_id: u16,
    message: []const u8,
    span: sjon.Ast.Span,
};

pub const Counts = struct { errors: u32 = 0, warnings: u32 = 0 };

/// Walk every diagnostic in `Abi.encodeDiags` order: SJON validation
/// first, then pacer load codes.
pub const Iter = struct {
    result: *const pacer.Compile.CompileResult,
    i: usize = 0,

    pub fn next(self: *Iter) ?Record {
        const sjon_diags = self.result.validated.result.diagnostics;
        if (self.i < sjon_diags.len) {
            const d = sjon_diags[self.i];
            self.i += 1;
            return .{
                .producer = .sjon,
                .severity = switch (d.severity) {
                    .err => .err,
                    .warning => .warning,
                },
                .code = @tagName(d.code),
                .code_id = @intCast(@intFromEnum(d.code)),
                .message = d.message,
                .span = d.span,
            };
        }
        const k = self.i - sjon_diags.len;
        if (k >= self.result.diagnostics.len) return null;
        const d = self.result.diagnostics[k];
        self.i += 1;
        return .{
            // Pacer load diagnostics are always errors — they void the table.
            .producer = .pacer,
            .severity = .err,
            .code = @tagName(d.code),
            .code_id = @intFromEnum(d.code),
            .message = d.message,
            .span = d.span,
        };
    }
};

pub fn iterate(result: *const pacer.Compile.CompileResult) Iter {
    return .{ .result = result };
}

pub fn count(result: *const pacer.Compile.CompileResult) Counts {
    var c: Counts = .{};
    var it = iterate(result);
    while (it.next()) |d| switch (d.severity) {
        .err => c.errors += 1,
        .warning => c.warnings += 1,
    };
    return c;
}

/// The `diagnostics` array — shared by every verb's envelope, so a
/// defective score reports identically whichever verb found it.
pub fn writeArray(w: *Writer, ctx: Envelope.Ctx) Writer.Error!void {
    try w.writeAll("[");
    var it = iterate(ctx.result);
    var first = true;
    while (it.next()) |d| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("\n    {\"producer\":");
        try Json.string(w, @tagName(d.producer));
        try w.writeAll(",\"severity\":");
        try Json.string(w, @tagName(d.severity));
        try w.writeAll(",\"code\":");
        try Json.string(w, d.code);
        try w.print(",\"code_id\":{d},\"message\":", .{d.code_id});
        try Json.string(w, d.message);
        try w.writeAll(",\"span\":");
        try Envelope.writeSpan(w, ctx, d.span);
        try w.writeAll(",\"text\":");
        try Json.string(w, excerpt(ctx.source, d.span));
        try w.writeByte('}');
    }
    if (!first) try w.writeAll("\n  ");
    try w.writeAll("]");
}

/// The source the span covers, capped so a diagnostic over a whole form
/// does not paste the form into the report.
fn excerpt(source: []const u8, span: sjon.Ast.Span) []const u8 {
    const start = @min(span.start, source.len);
    const end = @min(@max(span.end, start), source.len);
    return source[start..@min(end, start + 120)];
}

/// `check --json`. Returns the exit code so the caller has one thing to
/// forward. `check`'s payload IS the diagnostics array, so the shared
/// preamble is the whole envelope.
pub fn renderJson(w: *Writer, ctx: Envelope.Ctx) Writer.Error!u8 {
    try Envelope.writeHead(w, ctx, "check");
    try Envelope.writeTail(w);
    return Envelope.exitCode(ctx);
}

/// `check`, human. One grep-stable `file:line:col: severity: code: message`
/// line per diagnostic, then a count — GNU style, the shape an editor's
/// error parser and a `grep` pipeline both already understand.
pub fn renderHuman(w: *Writer, ctx: Envelope.Ctx) Writer.Error!u8 {
    const label = Source.label(ctx.path);
    var it = iterate(ctx.result);
    while (it.next()) |d| {
        const pos = ctx.index.at(d.span.start);
        try w.print("{s}:{d}:{d}: {s}: {s}: {s}\n", .{
            label,
            pos.line,
            pos.col,
            if (d.severity == .err) "error" else "warning",
            d.code,
            d.message,
        });
    }
    const c = count(ctx.result);
    if (c.errors == 0 and c.warnings == 0) {
        try w.print("{s}: no diagnostics\n", .{label});
        return 0;
    }
    try w.print("{d} error{s}, {d} warning{s}\n", .{
        c.errors,   if (c.errors == 1) "" else "s",
        c.warnings, if (c.warnings == 1) "" else "s",
    });
    return if (c.errors > 0) 1 else 0;
}

const t = std.testing;
// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// Compile one source against a fresh schema and assert the CLI's walk
/// agrees with `Abi.encodeDiags` record for record. The merge is the one
/// thing rendering from memory re-spells, so it is pinned here rather than
/// by decoding.
fn expectMatchesBlob(source: [:0]const u8) !void {
    var schema = try pacer.Schema.load(t.allocator);
    defer schema.deinit();
    var r = try pacer.Compile.compile(t.allocator, &schema, source, &.{});
    defer r.deinit();

    const buf = try t.allocator.alloc(u8, pacer.Abi.diagsEncodedLen(&r));
    defer t.allocator.free(buf);
    const view = pacer.Abi.decodeDiags(pacer.Abi.encodeDiags(&r, buf)).?;

    var wanted = view.records();
    var seen: u32 = 0;
    var it = iterate(&r);
    while (it.next()) |got| : (seen += 1) {
        const want = wanted.next() orelse return error.TestBlobRanOutFirst;
        try t.expectEqual(want.source, got.producer);
        try t.expectEqual(want.severity, got.severity);
        try t.expectEqual(want.code, got.code_id);
        try t.expectEqual(want.span.start, got.span.start);
        try t.expectEqual(want.span.end, got.span.end);
        try t.expectEqualStrings(want.message, got.message);
    }
    try t.expectEqual(@as(?pacer.Abi.DiagRecord, null), wanted.next());
    try t.expectEqual(view.count, seen);
}

test "pacer-produced diagnostics walk in 'PACD' order" {
    try expectMatchesBlob(
        \\(transport :bpm 120)
        \\(control :id knob :value 1)
        \\(control :id knob :value 2)
        \\(track :target nonexistent :expr 1)
    );
}

test "SJON-produced diagnostics walk in 'PACD' order" {
    try expectMatchesBlob(
        \\(transport :bpm 120)
        \\(trak :target tint)
    );
}

test "the two producers cannot both report: a SJON error voids pacer's pass" {
    // `Compile.compile` runs the builder only `if (!v.hasErrors())`, so a
    // document that fails SJON validation never reaches pacer's own
    // checks. That is WHY the merge above is only ever all-of-one — worth
    // pinning, because the day it stops being true the merge order starts
    // mattering for real and this test is the one that says so.
    var schema = try pacer.Schema.load(t.allocator);
    defer schema.deinit();
    var r = try pacer.Compile.compile(t.allocator, &schema,
        \\(transport :bpm 120)
        \\(trak :target tint)
        \\(track :target nonexistent :expr 1)
    , &.{});
    defer r.deinit();
    try t.expect(r.validated.result.hasErrors());
    try t.expectEqual(@as(usize, 0), r.diagnostics.len);
}

test "a clean score yields no records and no error count" {
    var schema = try pacer.Schema.load(t.allocator);
    defer schema.deinit();
    var r = try pacer.Compile.compile(t.allocator, &schema,
        \\(transport :bpm 120)
        \\(target :name glow :arity 1)
        \\(track :target glow :expr 1)
    , &.{});
    defer r.deinit();
    try t.expect(r.ok());
    var it = iterate(&r);
    try t.expectEqual(@as(?Record, null), it.next());
    try t.expectEqual(Counts{ .errors = 0, .warnings = 0 }, count(&r));
}
