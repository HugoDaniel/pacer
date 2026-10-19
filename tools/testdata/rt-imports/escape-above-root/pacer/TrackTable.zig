// Fixture module — minimal stand-in (the audit scans text, never compiles).
const std = @import("std");

// MUTATION: a column-0 import that walks ABOVE the pacer leg root. Its
// basename `Writes.zig` IS allowlisted, so a collapsing normalizer would
// silently accept the inside-root file while the import names an
// outside-root path (finding 2). The auditor must refuse the traversal
// itself, naming the escape.
const escaped = @import("../Writes.zig");
