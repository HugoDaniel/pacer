# escape-above-root — traversal above EITHER leg root is refused by name.

- `pacer/TrackTable.zig` gains `@import("../Writes.zig")`: from the pacer
  root, `..` walks above the leg; the escaped basename `Writes.zig` IS on
  the pacer allowlist, so a normalizer that collapses the `..` would read
  the inside-root file and report OK.
- `sjon/plugins/core.zig` gains `@import("../../Ast.zig")`: from a
  one-deep directory, two `..` walk above the SJON root; the collapsed
  basename `Ast.zig` IS on the SJON allowlist.
# Expected: layer 1 FAILS naming both escapes ("escapes above the leg
# root") — never resolves either to the colliding allowlisted entry.
# Valid one-level relative imports (`plugins/../Ast.zig`, exercised by the
# real tree and the relative-laundering fixture) remain permitted.
