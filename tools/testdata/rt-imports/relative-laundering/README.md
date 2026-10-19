# relative-laundering — `TrackTable.zig` gains `@import("../Parser.zig")`.
# Expected: layer 1 FAILS naming Parser.zig — the relative escape
# normalizes to a path that is simply not on the pacer allowlist
# (forbidden by absence; rule c).
