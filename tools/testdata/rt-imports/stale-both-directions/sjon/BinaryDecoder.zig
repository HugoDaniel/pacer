// Fixture-local decoder shape for THIS tree's mutation: unlike the real
// leaf, it does NOT reach `BinaryFormat.zig` — this fixture's SJON-side
// stale demonstration pins BinaryFormat.zig as unreached, and the
// ask30/M4 delta (2026-10-22) made BinaryDecoder.zig an always-seeded
// BFS root, so the fixture tree must stop reaching it here.
const std = @import("std");
const Ast = @import("Ast.zig");
