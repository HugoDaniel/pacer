//! pacer CLI entry point — `pacer check <score.sjon>`.
//!
//! Thin dispatcher: build the stdio writers, collect argv off the process
//! arena, hand everything to `Cli.run`. Every behavioural concern —
//! argument parsing, source loading, rendering, exit policy — lives in
//! `Cli.zig`, so the in-source tests drive the same code the binary runs.
//!
//! The one thing that cannot live behind that seam is the outermost catch:
//! `run` returns `!u8`, and anything it propagates would otherwise reach
//! the Zig runtime, which prints a trace and exits 1 — the same code as
//! "your score has diagnostics".
//!
//! ## The JSON on stdout is NOT a wire-stable surface
//!
//! pacer's four `'PAC*'` blobs are append-only because a second,
//! INDEPENDENT implementation decodes them (`npm/pacer/src/index.js`). A
//! format with two implementations must be frozen or they drift. This
//! JSON has one producer and no second decoder, so it is VERSIONED instead
//! of frozen: `"pacer": {"format": N}` bumps on a breaking envelope change
//! and never on an added field.
//!
//! What IS stable is every value in it — `Compile.Code` names and
//! ordinals, `Easing.Op` names, the tick grid, the f32 lane shape —
//! because each of those is already pinned elsewhere. The envelope may
//! move; the meanings cannot.

const std = @import("std");
const Cli = @import("Cli.zig");

fn reportInternal(stderr: *std.Io.Writer, err: anyerror) u8 {
    // `catch {}` with no fallback: this IS the fallback. If stderr is
    // itself the failing channel there is nowhere left to report, and the
    // exit code has to carry the whole signal.
    stderr.print("pacer: internal error: {s}\n", .{@errorName(err)}) catch {};
    return Cli.Exit.internal;
}

pub fn main(init: std.process.Init) u8 {
    var stdout_buf: [64 * 1024]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(init.io, &stdout_buf);

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.stderr();
    var stderr_writer = stderr_file.writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Built BEFORE argv is collected, so even an OOM in `toSlice` has
    // somewhere to be reported.
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch |err|
        return reportInternal(stderr, err);

    var code = Cli.run(init.gpa, init.io, args, &stdout_writer.interface, stderr) catch |err|
        reportInternal(stderr, err);

    // A failed stdout flush means the user never received the output the
    // exit code is describing — that outranks whatever `run` decided.
    stdout_writer.interface.flush() catch |err| {
        code = reportInternal(stderr, err);
    };
    stderr.flush() catch return Cli.Exit.internal;
    return code;
}
