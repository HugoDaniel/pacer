# boundary-crossing — SJON-side `Expr.zig` gains `@import("Parser.zig")`.
# Expected: layer 1 FAILS naming Parser.zig with the chain back through
# the RtSjon window (the module boundary is crossed inside the dependency
# tree, not at the named import).
