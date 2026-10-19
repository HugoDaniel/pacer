//! Shared corpus-harness parser — the flat target join + ordered script.
//!
//! This is a deliberately std + `sjon`-only leaf. It imports no pacer source
//! module, not even in its tests, so the native corpus runner and the future
//! public-module parity consumer can share one parser without mixing nominal
//! `Schema` / `Compile.Target` types from two module instances. The harness
//! vocabulary is embedded here through the `pacer_corpus_schema` anonymous
//! import; `parse` accepts anything carrying a `.preloaded` field, which is
//! the existing `sjon.Host.PreloadedSchema` surface rather than a new wrapper
//! API.
//!
//! The harness format's documentation of record remains
//! `src/corpus_runner.zig`'s `//!` header. This leaf owns the parser, its
//! sequence/value checks, `MAX_TARGETS`, and the parser tests that moved out
//! of that runner; the runner keeps file walking and canonical rendering.
//!
//! `Target` is intentionally neutral: `targetsAs` copies its three fields
//! into each consumer's own target type (`Compile.Target` natively, the
//! public `pacer.Compile.Target` in the parity executable).

const std = @import("std");
const sjon = @import("sjon");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const Ast = sjon.Ast;
const NodeIndex = Ast.NodeIndex;

/// Harness-only frozen copy of pacer's host-target ceiling. This leaf cannot
/// import `Abi`, so `src/root.zig`'s source-owning test equality-pins this
/// copy to `Abi.MAX_TARGETS`; a divergence fails the root test rather than
/// silently changing the parser's ceiling.
pub const MAX_TARGETS: usize = 1024;

/// The harness vocabulary, embedded as a portable SJON manifest via the
/// `pacer_corpus_schema` build import. Preloaded ONCE for the whole walk and
/// never composed with the score schema — see `schema/pacer-corpus.sjon`'s
/// header for why two bundles rather than one.
pub const manifest_src: [:0]const u8 = @embedFile("pacer_corpus_schema");

/// One neutral host-target record in flat target-id order. Names are duped
/// into the parse arena; `targetsAs` borrows them for the caller's lifetime.
pub const Target = struct {
    name: []const u8,
    ncomp: u8,
    registry: u8,
};

/// One script form, executed in document order against a live evaluator.
pub const Step = union(enum) {
    /// One eval at these f64 seconds bits (render-verbatim, `{X:0>16}`).
    eval: u64,
    /// Hold a live control value: f32 bit patterns (echoed verbatim, and
    /// `@bitCast` to f32 for the call — so a lane can pin ±inf/NaN).
    set_control: struct { index: u32, bits: [4]u32 },
    /// Return a control to document authority.
    clear_control: u32,
    /// Live tempo nudge — f64 bits, so a case can pin NaN rejection.
    set_bpm: u64,
    /// Lift a dynamic slot for an unpinned target.
    register_control: struct { target_id: u16, registry: u8, ncomp: u8 },
};

pub const Harness = struct {
    targets: []const Target,
    steps: []const Step,
};

/// Read `times.sjon`. Null = the case is void (already reported); the names
/// in the returned targets are duped into `a` and outlive the tree.
///
/// SHAPE is the schema's: the source is validated against the preloaded
/// harness vocabulary, so a bad `:ncomp`, a missing `:index`, a three-lane
/// `:value`, a bare-number time or an unknown head is an SJON diagnostic with
/// a SPAN before a single field is read. What stays here is what a
/// form-at-a-time schema cannot see: document ORDER, the non-decreasing
/// registry rule, the hex WIDTHS, the target ceiling, and "at least one
/// script form".
///
/// `harness_schema` is `anytype` on purpose: callers pass their own holder
/// carrying the existing `.preloaded` field, so this leaf never names pacer's
/// nominal `Schema`. The preload need only outlive this call — returned
/// target names are duped into `a`.
pub fn parse(
    a: Allocator,
    gpa: Allocator,
    harness_schema: anytype,
    out: *Io.Writer,
    name: []const u8,
    src: [:0]const u8,
) !?Harness {
    // Validation never aborts on malformed input (collection over abort) —
    // parse errors arrive as diagnostics alongside schema ones.
    var v = sjon.validateDocument(gpa, src, .{ .preloaded = &harness_schema.preloaded }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer v.deinit();
    if (v.hasErrors()) {
        try out.print("corpus: {s}: times.sjon does not validate:\n", .{name});
        for (v.diagnostics) |d| {
            if (d.severity != .err) continue;
            try out.print("  {s}: {d}..{d}: {s}\n", .{ @tagName(d.code), d.span.start, d.span.end, d.message });
        }
        return null;
    }
    const tree = &v.tree;
    const view: sjon.EffectiveView.EffectiveView = .init(&v.tree, &v.materialized_defaults);

    var targets: std.ArrayList(Target) = .empty;
    var steps: std.ArrayList(Step) = .empty;
    var last_registry: u8 = 0;
    var seen_script = false;

    for (tree.root) |idx| {
        if (tree.tagOf(idx) != .form) {
            // A bare value at the root is not a form, so no `(form …)`
            // declaration governs it and the validator has nothing to say.
            try out.print("corpus: {s}: times.sjon: only (target …) and script forms allowed\n", .{name});
            return null;
        }
        const hdr = tree.formHeader(idx);
        if (std.mem.eql(u8, hdr.head, "target")) {
            if (seen_script) {
                // Flat order IS the target_id space, so the join has to be
                // complete before the first call reads it. Document order
                // is a sequence fact; a schema sees one form at a time.
                try out.print("corpus: {s}: times.sjon: (target …) forms must precede all script forms\n", .{name});
                return null;
            }
            var target_name: ?[]const u8 = null;
            for (hdr.children) |c| {
                if (tree.tagOf(c) == .symbol) {
                    target_name = tree.symbolText(c);
                    break;
                }
            }
            // `:positional target-name` types the slot but cannot demand it
            // be occupied — an empty `(target)` is still ours to refuse.
            const tname = target_name orelse {
                try out.print("corpus: {s}: times.sjon: (target …) needs a symbol name\n", .{name});
                return null;
            };
            const registry = effInt(&view, tree, idx, "registry");
            if (registry < last_registry) {
                // The JS runner regroups the flat list by registry index;
                // non-decreasing order keeps both flat orders identical.
                try out.print("corpus: {s}: times.sjon: registry indices must be non-decreasing\n", .{name});
                return null;
            }
            last_registry = @intCast(registry);
            try targets.append(a, .{
                .name = try a.dupe(u8, tname),
                .ncomp = @intCast(effInt(&view, tree, idx, "ncomp")),
                .registry = @intCast(registry),
            });
        } else if (std.mem.eql(u8, hdr.head, "times")) {
            seen_script = true;
            for (hdr.children) |c| {
                // `:positional f64-bits` (underlying string) already ruled
                // out every other tag.
                std.debug.assert(tree.tagOf(c) == .string);
                const text = tree.stringText(c);
                const bits = parseHexBits(text) orelse {
                    try out.print("corpus: {s}: times.sjon: `{s}` is not 16 hex digits\n", .{ name, text });
                    return null;
                };
                try steps.append(a, .{ .eval = bits });
            }
        } else if (std.mem.eql(u8, hdr.head, "set-control")) {
            seen_script = true;
            const bits = readHexVec4(tree, hdr.children, "value") orelse {
                try out.print("corpus: {s}: times.sjon: (set-control …) :value lanes are not 8 hex digits\n", .{name});
                return null;
            };
            try steps.append(a, .{ .set_control = .{
                .index = @intCast(effInt(&view, tree, idx, "index")),
                .bits = bits,
            } });
        } else if (std.mem.eql(u8, hdr.head, "clear-control")) {
            seen_script = true;
            try steps.append(a, .{ .clear_control = @intCast(effInt(&view, tree, idx, "index")) });
        } else if (std.mem.eql(u8, hdr.head, "set-bpm")) {
            seen_script = true;
            const node = kvNode(tree, hdr.children, "bpm").?;
            std.debug.assert(tree.tagOf(node) == .string);
            const bits = parseHexBits(tree.stringText(node)) orelse {
                try out.print("corpus: {s}: times.sjon: (set-bpm …) :bpm is not 16 hex digits\n", .{name});
                return null;
            };
            try steps.append(a, .{ .set_bpm = bits });
        } else {
            // `unknown_form` is an error, and an erroring document never
            // reaches here — so the head is one of the six declared.
            std.debug.assert(std.mem.eql(u8, hdr.head, "register-control"));
            seen_script = true;
            try steps.append(a, .{ .register_control = .{
                .target_id = @intCast(effInt(&view, tree, idx, "target-id")),
                .registry = @intCast(effInt(&view, tree, idx, "registry")),
                .ncomp = @intCast(effInt(&view, tree, idx, "ncomp")),
            } });
        }
    }

    if (targets.items.len > MAX_TARGETS) {
        try out.print("corpus: {s}: times.sjon: at most {d} targets\n", .{ name, MAX_TARGETS });
        return null;
    }
    // Zero host targets is legal: a compose-mode score declares its own
    // via (target …) and compiles standalone; the join then comes wholly
    // from the score (rendered via result.targets, not this host list).
    if (steps.items.len == 0) {
        try out.print("corpus: {s}: times.sjon: no script forms (need at least one (times …) or directive)\n", .{name});
        return null;
    }
    return .{ .targets = targets.items, .steps = steps.items };
}

/// Copy the neutral target records into `T`, field by field. Callers pass
/// their own nominal target type; the leaf never names one. The copied
/// `name` slices borrow the parse arena (`a`), exactly like the harness.
pub fn targetsAs(comptime T: type, a: Allocator, harness: Harness) error{OutOfMemory}![]const T {
    const out = try a.alloc(T, harness.targets.len);
    for (harness.targets, out) |src, *dst| {
        dst.name = src.name;
        dst.ncomp = src.ncomp;
        dst.registry = src.registry;
    }
    return out;
}

/// The effective `:key` on `form` as a non-negative integer — the author's
/// literal when written, else the manifest's `:default` (the B3 rule: a
/// default has ONE spelling, and it is the schema's). Every key read this
/// way is declared `:integer true` with bounds, so the switches below are
/// exhaustive by validation rather than by hope.
fn effInt(
    view: *const sjon.EffectiveView.EffectiveView,
    tree: *const Ast.Tree,
    form: NodeIndex,
    key: []const u8,
) u64 {
    const ev = view.getEffectiveValue(form, key).?;
    const n: f64 = switch (ev) {
        .author => |node| switch (tree.tagOf(node)) {
            .number => tree.numberOf(node),
            .number_i64 => @floatFromInt(tree.numberI64Of(node)),
            .number_u64 => @floatFromInt(tree.numberU64Of(node)),
            else => unreachable,
        },
        .default => |entry| switch (entry.value) {
            .number => |x| x,
            else => unreachable,
        },
    };
    std.debug.assert(n >= 0 and n == @floor(n));
    return @intFromFloat(n);
}

/// `:key [ "H8" "H8" "H8" "H8" ]` — four f32 bit patterns. The schema
/// pinned the key's presence, the vector's length and every element's
/// underlying; the WIDTH of a bit pattern is what is left to check.
fn readHexVec4(tree: *const Ast.Tree, children: []const NodeIndex, key: []const u8) ?[4]u32 {
    const node = kvNode(tree, children, key).?;
    const elems = tree.vectorElements(node);
    std.debug.assert(elems.len == 4);
    var out: [4]u32 = undefined;
    for (elems, 0..) |e, i| {
        std.debug.assert(tree.tagOf(e) == .string);
        out[i] = parseHexBits32(tree.stringText(e)) orelse return null;
    }
    return out;
}

fn kvNode(tree: *const Ast.Tree, children: []const NodeIndex, key: []const u8) ?NodeIndex {
    for (children) |c| {
        if (tree.tagOf(c) != .kvpair) continue;
        const kv = tree.kvpairHeader(c);
        if (std.mem.eql(u8, kv.key, key)) return kv.value;
    }
    return null;
}

/// Exactly 16 hex digits (either case) → the raw u64 bit pattern.
fn parseHexBits(text: []const u8) ?u64 {
    if (text.len != 16) return null;
    return std.fmt.parseInt(u64, text, 16) catch null;
}

/// Exactly 8 hex digits (either case) → the raw u32 (f32) bit pattern.
fn parseHexBits32(text: []const u8) ?u32 {
    if (text.len != 8) return null;
    return std.fmt.parseInt(u32, text, 16) catch null;
}

// ---------------------------------------------------------------------------
// Tests — this file is ALSO its own explicit test root in build.zig. No pacer
// source import appears here; the manifest is preloaded through shared SJON.
// ---------------------------------------------------------------------------

const t_ = std.testing;

/// One harness source through the real reader, with the report captured.
/// `.harness` is null exactly when the runner would fail the case; `.report`
/// is what it printed — which is how the tests below pin WHICH layer
/// refused, the schema or the runner.
const ParseProbe = struct { harness: ?Harness, report: []const u8 };

fn testParse(a: Allocator, src: [:0]const u8) !ParseProbe {
    var hs: struct { preloaded: sjon.Host.PreloadedSchema } = .{
        .preloaded = try sjon.Host.preloadSchema(t_.allocator, &.{manifest_src}),
    };
    defer hs.preloaded.deinit();
    try t_.expectEqual(@as(usize, 0), hs.preloaded.diagnostics.len);

    var sink: Io.Writer.Allocating = .init(a);
    const h = try parse(a, t_.allocator, &hs, &sink.writer, "test", src);
    return .{ .harness = h, .report = sink.written() };
}

/// The first line of a schema report — `parse` prints it before the
/// per-diagnostic lines and nothing else does.
const SCHEMA_REFUSED = "does not validate";

test "corpus harness: the embedded manifest preloads clean" {
    var hs: struct { preloaded: sjon.Host.PreloadedSchema } = .{
        .preloaded = try sjon.Host.preloadSchema(t_.allocator, &.{manifest_src}),
    };
    defer hs.preloaded.deinit();

    try t_.expectEqual(@as(usize, 0), hs.preloaded.diagnostics.len);
    try t_.expectEqual(@as(usize, 1), hs.preloaded.plugins.len);
    try t_.expectEqualStrings("pacer-corpus", hs.preloaded.plugins[0].name);
    for ([_][]const u8{ "target", "times", "set-control", "clear-control", "set-bpm", "register-control" }) |head| {
        try t_.expect(hs.preloaded.schema.lookupForm(head, null) == .found);
    }
}

test "corpus harness: a well-formed file reads through the schema" {
    var arena = std.heap.ArenaAllocator.init(t_.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = (try testParse(a,
        \\(target radius :registry 0 :ncomp 1)
        \\(target tint :registry 0 :ncomp 3)
        \\(target cutoff :registry 1)
        \\(times "0000000000000000" "3FE0000000000000")
        \\(set-control :index 0 :value ["3F000000" "00000000" "00000000" "00000000"])
        \\(clear-control :index 0)
        \\(set-bpm :bpm "4059000000000000")
        \\(register-control :target-id 2 :registry 1 :ncomp 1)
    )).harness.?;

    try t_.expectEqual(@as(usize, 3), h.targets.len);
    try t_.expectEqualStrings("tint", h.targets[1].name);
    try t_.expectEqual(@as(u8, 3), h.targets[1].ncomp);
    // `cutoff` omits `:ncomp` — the schema's `:default 1` is what fills it,
    // read back through `EffectiveView` (B3's rule: one spelling per default).
    try t_.expectEqual(@as(u8, 1), h.targets[2].ncomp);
    try t_.expectEqual(@as(u8, 1), h.targets[2].registry);

    try t_.expectEqual(@as(usize, 6), h.steps.len);
    try t_.expectEqual(@as(u64, 0x3FE0000000000000), h.steps[1].eval);
    try t_.expectEqual(@as(u32, 0x3F000000), h.steps[2].set_control.bits[0]);
    try t_.expectEqual(@as(u64, 0x4059000000000000), h.steps[4].set_bpm);
    try t_.expectEqual(@as(u16, 2), h.steps[5].register_control.target_id);
}

test "corpus harness: targetsAs copies the three neutral fields" {
    var arena = std.heap.ArenaAllocator.init(t_.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const h = (try testParse(a,
        \\(target radius :registry 0 :ncomp 1)
        \\(target tint :registry 1 :ncomp 3)
        \\(times "0000000000000000")
    )).harness.?;

    const Copy = struct { name: []const u8, ncomp: u8, registry: u8 };
    const copied = try targetsAs(Copy, a, h);
    try t_.expectEqual(h.targets.len, copied.len);
    try t_.expectEqualStrings("tint", copied[1].name);
    try t_.expectEqual(@as(u8, 3), copied[1].ncomp);
    try t_.expectEqual(@as(u8, 1), copied[1].registry);
}

test "corpus harness: the target ceiling accepts the cap and refuses one over" {
    var arena = std.heap.ArenaAllocator.init(t_.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var at_cap: Io.Writer.Allocating = .init(a);
    defer at_cap.deinit();
    for (0..MAX_TARGETS) |i| {
        try at_cap.writer.print("(target t{d})\n", .{i});
    }
    try at_cap.writer.writeAll("(times \"0000000000000000\")\n");
    const at_cap_src = try at_cap.toOwnedSliceSentinel(0);
    const accepted = (try testParse(a, at_cap_src)).harness.?;
    try t_.expectEqual(MAX_TARGETS, accepted.targets.len);

    var over_cap: Io.Writer.Allocating = .init(a);
    defer over_cap.deinit();
    for (0..MAX_TARGETS + 1) |i| {
        try over_cap.writer.print("(target t{d})\n", .{i});
    }
    try over_cap.writer.writeAll("(times \"0000000000000000\")\n");
    const over_cap_src = try over_cap.toOwnedSliceSentinel(0);
    const refused = try testParse(a, over_cap_src);
    try t_.expect(refused.harness == null);
    try t_.expect(std.mem.indexOf(u8, refused.report, "at most 1024 targets") != null);
}

test "corpus harness: the schema refuses what the runner used to hand-check" {
    var arena = std.heap.ArenaAllocator.init(t_.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every one of these was a bespoke `corpus: …` line pointing at nothing.
    // Each is now an SJON diagnostic carrying a span — pinned by CODE, so a
    // runner check silently taking the refusal back would fail here.
    const cases = [_]struct { src: [:0]const u8, code: []const u8 }{
        .{ .src = "(target radius :ncomp 9)\n(times \"0000000000000000\")", .code = "number_above_max" },
        .{ .src = "(target radius :registry -1)\n(times \"0000000000000000\")", .code = "number_below_min" },
        .{ .src = "(target radius :ncomp 1.5)\n(times \"0000000000000000\")", .code = "number_not_integer" },
        .{ .src = "(target radius)\n(times 0.5)", .code = "wrong_underlying" },
        .{ .src = "(target radius)\n(set-control :value [\"00000000\" \"00000000\" \"00000000\" \"00000000\"])", .code = "missing_required_key" },
        .{ .src = "(target radius)\n(set-control :index 0 :value [\"00000000\" \"00000000\"])", .code = "vector_length_mismatch" },
        .{ .src = "(target radius)\n(clear-control :index 0 :bogus 1)", .code = "unknown_key" },
        .{ .src = "(target radius)\n(set-bpm :bpm 120)", .code = "wrong_underlying" },
        .{ .src = "(target radius)\n(register-control :target-id 70000)", .code = "number_above_max" },
        .{ .src = "(target radius)\n(rewind :to 0)", .code = "unknown_form" },
    };
    for (cases) |c| {
        const probe = try testParse(a, c.src);
        try t_.expect(probe.harness == null);
        try t_.expect(std.mem.indexOf(u8, probe.report, SCHEMA_REFUSED) != null);
        try t_.expect(std.mem.indexOf(u8, probe.report, c.code) != null);
    }
}

test "corpus harness: what a schema cannot see stays the runner's" {
    var arena = std.heap.ArenaAllocator.init(t_.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Document ORDER, the non-decreasing registry rule the JS runner's
    // regrouping depends on, hex WIDTH, the target ceiling and "at least one
    // script form" are sequence- or value-level facts. A schema validates one
    // form at a time against one shape; none of these is that — so each of
    // these refusals must come from the runner, NOT from a diagnostic.
    const srcs = [_][:0]const u8{
        "(times \"0000000000000000\")\n(target radius)", // targets precede the script
        "(target a :registry 1)\n(target b :registry 0)\n(times \"0000000000000000\")",
        "(target radius)\n(times \"3FE\")", // not 16 hex digits
        "(target radius)\n(set-control :index 0 :value [\"3F0000\" \"00000000\" \"00000000\" \"00000000\"])", // not 8
        "(target radius)", // no script forms
        "(target radius)\n(times \"0000000000000000\")\nradius", // a bare value at root
        "(target)\n(times \"0000000000000000\")", // typed positional, but unoccupied
    };
    for (srcs) |src| {
        const probe = try testParse(a, src);
        try t_.expect(probe.harness == null);
        try t_.expect(std.mem.indexOf(u8, probe.report, SCHEMA_REFUSED) == null);
    }
}
