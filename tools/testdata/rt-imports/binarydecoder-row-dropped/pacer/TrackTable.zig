// Fixture module — minimal stand-in (the audit scans text, never compiles).
const std = @import("std");

// MUTATION: an indented (test-only) forbidden import — the layer-1 blind
// spot, PASSING by design; layer 2 (tools/check_rt_artifact.zig) is the
// named physical backstop for exactly this class (02:273-278).
test "honest split" {
    const Compile = @import("Compile.zig");
    _ = Compile;
}
