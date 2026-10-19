// Fixture window — the strict-grammar nine rows (the one legal sjon import).
const sjon = @import("sjon");

pub const Ast = sjon.Ast;
pub const Expr = sjon.Expr;
pub const Pattern = sjon.Pattern;
pub const PatternQuery = sjon.PatternQuery;
pub const BinaryCursor = sjon.BinaryCursor;
pub const Schema = sjon.Schema;
pub const Plugin = sjon.Plugin;
pub const trig = sjon.trig;
pub const plugins = struct {
    pub const core = sjon.plugins.core;
};
