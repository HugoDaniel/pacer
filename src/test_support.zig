//! Test-only shared fixtures.
//!
//! Only referenced from `test { … }` bodies, so Zig never analyses it in a
//! normal build (a top-level `@import` used solely inside tests is lazy).

const std = @import("std");
const Schema = @import("Schema.zig");

/// The preloaded pacer schema, built once for the whole test binary and
/// never torn down.
///
/// This mirrors what a real host does — `wasm_entry` keeps exactly one
/// `Schema` for the instance's lifetime, and the corpus runner keeps one
/// for the whole walk — so tests exercise the production lifetime shape
/// rather than a per-test one. It is deliberately NOT allocated from
/// `std.testing.allocator`: that allocator's leak check runs per test, and
/// this fixture outlives every test by design.
var shared: ?Schema = null;

/// Borrowed handle to the shared schema. Stable for the process lifetime —
/// `shared` is a file-scope optional, so `&shared.?` never moves.
pub fn schema() *const Schema {
    if (shared == null) {
        shared = Schema.load(std.heap.page_allocator) catch
            @panic("test_support: preloading schema/pacer.sjon failed");
    }
    return &shared.?;
}
