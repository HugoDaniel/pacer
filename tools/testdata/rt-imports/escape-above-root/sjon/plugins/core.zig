const std = @import("std");
const Plugin = @import("../Plugin.zig");
const Expr = @import("../Expr.zig");

// MUTATION: from a one-deep directory, two `..` walk ABOVE the SJON leg
// root; the collapsed basename `Ast.zig` is allowlisted. The SJON leg
// must refuse this exactly like the pacer leg — both roots stay bounded.
const escaped = @import("../../Ast.zig");
