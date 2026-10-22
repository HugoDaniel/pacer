// Fixture SJON root — the export table the namespace→file map asserts against.
pub const Ast = @import("Ast.zig");
pub const Expr = @import("Expr.zig");
pub const Pattern = @import("Pattern.zig");
pub const PatternQuery = @import("PatternQuery.zig");
pub const BinaryCursor = @import("BinaryCursor.zig");
pub const Schema = @import("Schema.zig");
pub const Plugin = @import("Plugin.zig");
pub const trig = @import("trig.zig");
pub const plugins = struct {
    pub const core = @import("plugins/core.zig");
    pub const pattern = @import("plugins/pattern.zig");
};
pub const BinaryDecoder = @import("BinaryDecoder.zig");
