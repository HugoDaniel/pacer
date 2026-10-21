//! RtSjon — the runtime closure's single window into SJON (02 P2, C1).
//!
//! The playback runtime must carry no compiler in its import closure,
//! and SJON is consumed here as a NAMED module whose root is the
//! kitchen-sink aggregate — parser, printer, write-side binary codec,
//! host, manifest loader, all exported from one file. Traversing that
//! root would drag the whole write side into the runtime, so the
//! boundary is fixed HERE: this file holds the closure's only import of
//! the module, behind a frozen re-export table of exactly the ten
//! runtime namespaces. Every other runtime-closure file imports
//! `RtSjon.zig`, never the module.
//!
//! The named module is one instance, so each row re-exports the SAME
//! namespace — a row here IS the module's own decl, not a copy, and
//! types interoperate with compiler-side spellings unchanged.
//! `BinaryFormat` is absent because SJON exports no such root name
//! (C1's correction of the 02 draft table); the write-side `Binary`
//! stays out by design — the one constant the closure needed from it
//! (`MAX_TREE_DEPTH`) is a frozen copy in `Pacb.zig`, equality-pinned
//! by a test in `src/root.zig`'s frozen-copy family.
//!
//! The table is frozen and minimal (the stale-entry rule): every row is
//! reached by the closure files, and nothing else joins. The
//! `plugins.pattern` row joined 2026-10-21 at P4/A2 — the delivered
//! env-carrying binary pattern query (`PatternQuery.queryBinaryWithEnv`)
//! is adopted and the runtime schema carries core ⊕ pattern. Write-side
//! surfaces (the parser, the binary encoder, document validation, the
//! host) are reachable in closure files ONLY through indented
//! test-block imports, never through this window.

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
    pub const pattern = sjon.plugins.pattern;
};
