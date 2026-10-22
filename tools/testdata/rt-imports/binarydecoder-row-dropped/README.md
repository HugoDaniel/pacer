# honest-split — `TrackTable.zig` gains an INDENTED test-only
# `@import("Compile.zig")`. Expected: layer 1 PASSES (exit 0) — the
# column-0 scan cannot see indented imports; that is the documented,
# frozen blind spot, with layer 2 as its named backstop.
