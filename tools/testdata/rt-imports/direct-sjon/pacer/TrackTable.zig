// Fixture module — minimal stand-in (the audit scans text, never compiles).
const std = @import("std");

// MUTATION: a direct module import at column 0 outside the window (rule a).
const sjon = @import("sjon");
