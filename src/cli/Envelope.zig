//! The JSON envelope every verb shares — the preamble, the span object,
//! and the render context.
//!
//! **The shape never varies.** Every key a verb declares is present in
//! every outcome: a defective score gets `"ok": false`, a populated
//! `diagnostics`, and the verb's own keys present but empty. A consumer
//! never branches on whether a key exists, and a failure is still a
//! parseable object rather than an empty stdout with an exit code.
//!
//! This envelope is NOT a wire-stable surface — see `main.zig`'s header
//! for why, and for what `format` means.

const std = @import("std");
const pacer = @import("pacer");
const sjon = @import("sjon");
const Diags = @import("Diags.zig");
const Json = @import("Json.zig");
const Source = @import("Source.zig");
const Writer = std.Io.Writer;

/// The envelope's own version. Bumped only on a BREAKING change; an added
/// field never bumps it.
pub const format_version: u32 = 1;

/// Everything a renderer needs, and nothing it does not: no allocator, no
/// io. Each renderer is a pure function of this plus a writer.
pub const Ctx = struct {
    result: *const pacer.Compile.CompileResult,
    source: []const u8,
    index: *const Source.LineIndex,
    /// As given on the command line; `-` for stdin.
    path: []const u8,
    /// How many `--target` flags the invocation carried.
    /// `CompileResult.targets` is the MERGED join — the host's registries
    /// with their indices preserved, then any compose-mode `(target …)`
    /// the host did not already provide, appended. So this count is
    /// exactly the boundary between `origin: "host"` and
    /// `origin: "declared"`, which is information no wire blob carries.
    host_target_count: usize,

    /// The merged join's name for a target id. Total: an id past the join
    /// cannot occur (the table stores ids the join produced), but a
    /// renderer must not be the thing that panics if it ever does.
    pub fn targetName(self: *const Ctx, id: u16) []const u8 {
        return if (id < self.result.targets.len) self.result.targets[id].name else "?";
    }

    pub fn targetOrigin(self: *const Ctx, id: u16) []const u8 {
        return if (id < self.host_target_count) "host" else "declared";
    }
};

/// Open the object and write everything through `"diagnostics"`, leaving
/// it OPEN for the verb's own keys — each of which the verb prefixes with
/// `,\n  `.
pub fn writeHead(w: *Writer, ctx: Ctx, command: []const u8) Writer.Error!void {
    try w.print("{{\n  \"pacer\":{{\"version\":\"{s}\",\"format\":{d}}},\n  \"command\":", .{
        pacer.version, format_version,
    });
    try Json.string(w, command);
    try w.writeAll(",\n  \"source\":{\"path\":");
    try Json.string(w, Source.label(ctx.path));
    const counts = Diags.count(ctx.result);
    try w.print(",\"bytes\":{d}}},\n  \"ok\":{},\n  \"counts\":{{\"errors\":{d},\"warnings\":{d}}},\n  \"diagnostics\":", .{
        ctx.source.len, ctx.result.ok(), counts.errors, counts.warnings,
    });
    try Diags.writeArray(w, ctx);
}

pub fn writeTail(w: *Writer) Writer.Error!void {
    try w.writeAll("\n}\n");
}

/// A span: the raw byte offsets AND the 1-based line/column the CLI
/// computes from them. Both, because the offsets are what every other
/// pacer surface speaks and the line/column is what a person reads.
pub fn writeSpan(w: *Writer, ctx: Ctx, span: sjon.Ast.Span) Writer.Error!void {
    const start = ctx.index.at(span.start);
    const end = ctx.index.at(span.end);
    try w.print(
        "{{\"start\":{d},\"end\":{d},\"line\":{d},\"col\":{d},\"end_line\":{d},\"end_col\":{d}}}",
        .{ span.start, span.end, start.line, start.col, end.line, end.col },
    );
}

/// The exit code a completed render carries: diagnostics are the score's
/// problem, so they set the code even when the payload rendered fine.
pub fn exitCode(ctx: Ctx) u8 {
    return if (Diags.count(ctx.result).errors > 0) 1 else 0;
}
