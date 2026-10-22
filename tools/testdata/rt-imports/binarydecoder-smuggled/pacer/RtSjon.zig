// Fixture window — the strict-grammar ten rows (the one legal sjon import).
const sjon = @import("sjon");

pub const Ast = sjon.Ast;
pub const Expr = sjon.Expr;
pub const Pattern = sjon.Pattern;
pub const PatternQuery = sjon.PatternQuery;
pub const BinaryCursor = sjon.BinaryCursor;
pub const BinaryDecoder = sjon.BinaryDecoder;
pub const Schema = sjon.Schema;
pub const Plugin = sjon.Plugin;
pub const trig = sjon.trig;
pub const plugins = struct {
    pub const core = sjon.plugins.core;
    pub const pattern = sjon.plugins.pattern;
};
