//! Score compiler, stage 1: manifest prepend → `sjon.validateDocument`.
//!
//! The pacer schema manifest (`schema/pacer.sjon`, `@embedFile`'d via the
//! `pacer_schema` build import) is prepended to the user source and the
//! combined text validated in one call — no filesystem, works on
//! wasm32-freestanding. This is the pngine `Compiler.zig` pattern.
//!
//! Spans in the returned diagnostics index into the COMBINED text; user
//! coordinates are recovered by subtracting `Validated.prefix_len`
//! (manifest diagnostics — which only fire if the embedded manifest
//! itself is broken — sit below it). Stage 2 (the walk into the compiled
//! `TrackTable`) builds on the validated tree this stage keeps alive.
//!
//! Ownership: `validate` takes a `gpa` and returns an owned `Validated`;
//! the combined buffer's allocator is stored so `.deinit()` needs no
//! argument (the pngine precedent — SJON's pure-arena shape doesn't fit
//! here because the sentinel source buffer must outlive the HostResult
//! that borrows spans into it).

const std = @import("std");
const sjon = @import("sjon");
const Allocator = std.mem.Allocator;

/// The pacer score schema, embedded as a portable SJON manifest.
/// Provided as the `pacer_schema` anonymous import by build.zig.
pub const manifest_src: [:0]const u8 = @embedFile("pacer_schema");

/// Explicit error set. Validation FAILURES are not errors — they are
/// diagnostics on a successfully returned `Validated` (collection over
/// abort, the SJON discipline). Only resource exhaustion is an error.
pub const Error = error{OutOfMemory};

/// Owned result of `validate`. Holds the SJON `HostResult` (tree, schema,
/// data forest, diagnostics) plus the combined manifest+source text the
/// result's spans index into.
pub const Validated = struct {
    result: sjon.Host.HostResult,
    /// Manifest + "\n\n" + user source. Diagnostic/AST spans index here.
    combined: [:0]const u8,
    /// Byte offset where user source begins inside `combined`.
    prefix_len: usize,
    gpa: Allocator,

    pub fn deinit(self: *Validated) void {
        self.result.deinit();
        self.gpa.free(self.combined);
        self.* = undefined;
    }

    /// True when any diagnostic is an error (manifest or validation).
    pub fn hasErrors(self: *const Validated) bool {
        return self.result.hasErrors();
    }

    /// Map a combined-text byte offset into user-source coordinates.
    /// Asserts the offset lies in the user region — manifest spans have
    /// no user coordinate and must be filtered first.
    pub fn userOffset(self: *const Validated, combined_offset: usize) usize {
        std.debug.assert(combined_offset >= self.prefix_len);
        std.debug.assert(combined_offset <= self.combined.len);
        return combined_offset - self.prefix_len;
    }
};

/// Validate a pacer score. Always returns a `Validated` on success of the
/// machinery itself — check `.hasErrors()` / `.result.diagnostics` for
/// the score's actual verdict. O(manifest + source).
pub fn validate(gpa: Allocator, source: [:0]const u8) Error!Validated {
    std.debug.assert(source.len + manifest_src.len + 2 <= sjon.Binary.MAX_FILE_SIZE);
    const combined = std.fmt.allocPrintSentinel(gpa, "{s}\n\n{s}", .{ manifest_src, source }, 0) catch
        return error.OutOfMemory;
    errdefer gpa.free(combined);
    const prefix_len = manifest_src.len + 2;

    const result = sjon.validateDocument(gpa, combined, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    std.debug.assert(combined.len > prefix_len or source.len == 0);
    return .{ .result = result, .combined = combined, .prefix_len = prefix_len, .gpa = gpa };
}

/// First error diagnostic with the given code, or null. Test/debug helper;
/// production consumers iterate `result.diagnostics` themselves.
pub fn findCode(v: *const Validated, code: sjon.Ast.Diagnostic.Code) ?sjon.Host.HostDiagnostic {
    for (v.result.diagnostics) |d| {
        if (d.code == code) return d;
    }
    return null;
}

const t = std.testing;

const minimal_score: [:0]const u8 =
    \\(transport :bpm 120 :meter [4 4] :dur 16bar :end loop)
    \\(track :target circle-radius
    \\  (key :at 0b :value 0.2)
    \\  (key :at 4b :value 0.8 :ease out-cubic)
    \\  (key :at 8b :value 0.2 :ease smoothstep))
;

test "minimal score validates clean" {
    var v = try validate(t.allocator, minimal_score);
    defer v.deinit();
    for (v.result.diagnostics) |d| {
        std.debug.print("unexpected: {s} {s}\n", .{ @tagName(d.code), d.message });
    }
    try t.expect(!v.hasErrors());
}

test "composed easing program validates clean" {
    var v = try validate(t.allocator,
        \\(transport :bpm 90)
        \\(track :target logo-y
        \\  (key :at 0b :value 0.0)
        \\  (key :at 2b :value 1.0
        \\    :ease (seq (stage :ease out-cubic   :t 0.4  :v 1.15)
        \\               (stage :ease in-out-quad :t 0.35 :v -0.18)
        \\               (stage :ease (spring :damping 0.5 :periods 2) :t 0.25 :v 0.03))))
        \\(track :target tint
        \\  (key :at 0b :value [1 0 0])
        \\  (key :at 1bar :value [0 0 1] :ease (chain (cubic-bezier :p [0.4 0 0.2 1]) (steps :n 4 :jump end))))
    );
    defer v.deinit();
    try t.expect(!v.hasErrors());
}

test "bare number in a position slot is rejected (unit required)" {
    var v = try validate(t.allocator,
        \\(transport :bpm 120)
        \\(track :target x (key :at 4 :value 0.5))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
    try t.expect(findCode(&v, .unit_required) != null);
}

test "wrong unit on a position slot is rejected" {
    var v = try validate(t.allocator,
        \\(transport :bpm 120)
        \\(track :target x (key :at 4ms :value 0.5))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "unknown easing name is rejected" {
    var v = try validate(t.allocator,
        \\(transport :bpm 120)
        \\(track :target x
        \\  (key :at 0b :value 0)
        \\  (key :at 1b :value 1 :ease bouncy-magic))
    );
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "unknown form head is rejected" {
    var v = try validate(t.allocator, "(timeline :bpm 120)");
    defer v.deinit();
    try t.expect(v.hasErrors());
}

test "diagnostic spans map back into user source" {
    const bad_source: [:0]const u8 =
        \\(transport :bpm 120)
        \\(track :target x (key :at 4 :value 0.5))
    ;
    var v = try validate(t.allocator, bad_source);
    defer v.deinit();
    const d = findCode(&v, .unit_required).?;
    const user_start = v.userOffset(d.span.start);
    // The offending literal `4` sits inside the user text.
    try t.expectEqualStrings("4", bad_source[user_start .. user_start + 1]);
}

test "empty source validates clean (no data forms, no diagnostics)" {
    var v = try validate(t.allocator, "");
    defer v.deinit();
    try t.expect(!v.hasErrors());
}
