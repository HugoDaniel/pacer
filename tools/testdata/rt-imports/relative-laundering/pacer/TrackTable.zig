// Fixture module — minimal stand-in (the audit scans text, never compiles).
const std = @import("std");

// MUTATION: a relative .zig import laundering a write-side file past the
// module boundary (rule c — forbidden by absence from the allowlist).
const laundered = @import("../Parser.zig");
