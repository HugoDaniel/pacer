//! Native-only measurement harness (plan 06 Group C, C4/C5).
//!
//! This executable is NOT part of any shipped artifact and is not a named
//! export. It links the two production native objects (the actual
//! `wasm_entry.zig` text entry and the actual `rt_entry.zig` playback entry)
//! through their std-only facades, exactly as `native-composition` does, and
//! points the entries' comptime-native allocator seams at counting GPAs. So
//! the measured work is the production `drv_load`/`drv_eval` and
//! `prt_load`/`prt_eval` composition — only the allocator is observed.
//!
//! Output is raw TSV (one row per frame) plus a load/memory TSV and a
//! summary TSV. The report recomputes nothing it can read from here.
//!
//! Usage:
//!   perf-harness --score all-features --doc PATH --pacb PATH \
//!     --target NAME[:ncomp[:registry]] ... --out DIR [--frames N]
//!
//! The scripted-time generator is deliberately deterministic:
//!   phase 0 (N/4): monotonic 0 -> 10 s (crosses scene and loop wrap)
//!   phase 1 (N/4): scene seeks (exact boundaries plus jitter)
//!   phase 2 (N/4): non-monotonic revisits (descending windows)
//!   phase 3 (N/4): wrap/hold crossing repetitions
//! Both paths receive the identical sequence for a score.

const std = @import("std");
const builtin = @import("builtin");
const pacer = @import("pacer");
const NativeRt = @import("NativeRt.zig");
const NativeText = @import("NativeText.zig");

comptime {
    if (builtin.target.cpu.arch.isWasm())
        @compileError("perf_harness: native-only");
}

const Snapshot = struct {
    allocs: u64,
    frees: u64,
    live: i64,
    total: u64,
    peak: u64,
};

const Counter = struct {
    backing: std.mem.Allocator,
    allocs: u64 = 0,
    frees: u64 = 0,
    live: i64 = 0,
    total: u64 = 0,
    peak: u64 = 0,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn init(backing: std.mem.Allocator) Counter {
        return .{ .backing = backing };
    }

    fn allocator(self: *Counter) std.mem.Allocator {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn resetPhase(self: *Counter) void {
        self.allocs = 0;
        self.frees = 0;
        self.total = 0;
        self.peak = if (self.live > 0) @intCast(self.live) else 0;
    }

    fn snapshot(self: *const Counter) Snapshot {
        return .{
            .allocs = self.allocs,
            .frees = self.frees,
            .live = self.live,
            .total = self.total,
            .peak = self.peak,
        };
    }

    fn bump(self: *Counter, len: usize) void {
        self.live += @intCast(len);
        self.total += len;
        if (self.live > 0 and @as(u64, @intCast(self.live)) > self.peak)
            self.peak = @intCast(self.live);
    }

    fn drop(self: *Counter, len: usize) void {
        self.live -= @intCast(len);
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.allocs += 1;
        self.bump(len);
        return p;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) self.bump(new_len - memory.len) else self.drop(memory.len - new_len);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        const p = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) self.bump(new_len - memory.len) else self.drop(memory.len - new_len);
        return p;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Counter = @ptrCast(@alignCast(ctx));
        self.frees += 1;
        self.drop(memory.len);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

const Options = struct {
    score: []const u8 = "all-features",
    doc: []const u8,
    pacb: []const u8,
    out: []const u8,
    frames: usize = 100_000,
    targets: []const pacer.Compile.Target = &.{},
};

const ScoreKind = enum { all_features, meridian_minimal };

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const opts = try parseArgs(init.arena.allocator(), args);
    const kind: ScoreKind = if (std.mem.eql(u8, opts.score, "all-features"))
        .all_features
    else if (std.mem.eql(u8, opts.score, "meridian-minimal"))
        .meridian_minimal
    else
        return error.UnknownScore;

    const doc = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.doc, init.gpa, .limited(8 * 1024 * 1024));
    defer init.gpa.free(doc);
    const pacb = try std.Io.Dir.cwd().readFileAlloc(init.io, opts.pacb, init.gpa, .limited(8 * 1024 * 1024));
    defer init.gpa.free(pacb);

    var pact_buf: [64 * 1024]u8 = undefined;
    const pact = try pacer.PactCodec.encodeTargets(opts.targets, &pact_buf);

    var text_counter = Counter.init(std.heap.page_allocator);
    var binary_counter = Counter.init(std.heap.page_allocator);

    const tsc_hz = calibrateTsc();
    const clock_ns = clockOverhead();

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, opts.out);

    // --- text path ------------------------------------------------------
    NativeText.setGpa(@ptrCast(&text_counter), &Counter.vtable);
    defer NativeText.reset();
    NativeText.reset();

    if (doc.len > NativeText.docCap()) return error.DocTooLong;
    if (pact.len > NativeText.targetsCap()) return error.PactTooLong;
    @memcpy(NativeText.docPtr()[0..doc.len], doc);
    @memcpy(NativeText.targetsPtr()[0..pact.len], pact);

    text_counter.resetPhase();
    const text_cold = NativeText.load(@intCast(doc.len), @intCast(pact.len));
    const text_cold_snap = text_counter.snapshot();
    if (text_cold != 0) return error.TextLoadFailed;

    text_counter.resetPhase();
    const text_warm = NativeText.load(@intCast(doc.len), @intCast(pact.len));
    const text_warm_snap = text_counter.snapshot();
    if (text_warm != 0) return error.TextLoadFailed;

    const text_frames = try init.gpa.alloc(Frame, opts.frames);
    defer init.gpa.free(text_frames);
    try sweep(kind, .text, text_frames, &text_counter, tsc_hz);

    text_counter.resetPhase();
    try steady(kind, .text, 1000);
    const text_frame_snap = text_counter.snapshot();

    // --- binary path ----------------------------------------------------
    NativeRt.setGpa(@ptrCast(&binary_counter), &Counter.vtable);
    defer NativeRt.reset();
    NativeRt.reset();

    if (pacb.len > NativeRt.pacbCap()) return error.PacbTooLong;
    if (pact.len > NativeRt.targetsCap()) return error.PactTooLong;
    @memcpy(NativeRt.pacbPtr()[0..pacb.len], pacb);
    @memcpy(NativeRt.targetsPtr()[0..pact.len], pact);

    binary_counter.resetPhase();
    const bin_cold = NativeRt.load(@intCast(pacb.len), @intCast(pact.len));
    const bin_cold_snap = binary_counter.snapshot();
    if (bin_cold != 0) return error.BinaryLoadFailed;

    binary_counter.resetPhase();
    const bin_warm = NativeRt.load(@intCast(pacb.len), @intCast(pact.len));
    const bin_warm_snap = binary_counter.snapshot();
    if (bin_warm != 0) return error.BinaryLoadFailed;

    const bin_frames = try init.gpa.alloc(Frame, opts.frames);
    defer init.gpa.free(bin_frames);
    try sweep(kind, .binary, bin_frames, &binary_counter, tsc_hz);

    binary_counter.resetPhase();
    try steady(kind, .binary, 1000);
    const bin_frame_snap = binary_counter.snapshot();

    // --- the DecodedScore ownership copy (production `Pacb.decode`) -----
    var owned_counter = Counter.init(std.heap.page_allocator);
    owned_counter.resetPhase();
    var decoded = try pacer.Pacb.decode(owned_counter.allocator(), pacb, null);
    const owned_peak = owned_counter.snapshot();
    decoded.deinit();
    const owned_freed = owned_counter.snapshot();

    // --- write raw data -------------------------------------------------
    var name_buf: [256]u8 = undefined;
    const base = try std.fmt.bufPrint(&name_buf, "{s}", .{opts.score});

    var path_buf: [512]u8 = undefined;
    try writeFrames(init.io, try std.fmt.bufPrint(&path_buf, "{s}/{s}.text.frames.tsv", .{ opts.out, base }), text_frames);
    try writeFrames(init.io, try std.fmt.bufPrint(&path_buf, "{s}/{s}.binary.frames.tsv", .{ opts.out, base }), bin_frames);
    try writeSummaries(init.io, opts.out, base, text_frames, bin_frames);
    try writeLoads(init.io, opts.out, base, .{
        .text_cold = text_cold_snap,
        .text_warm = text_warm_snap,
        .bin_cold = bin_cold_snap,
        .bin_warm = bin_warm_snap,
        .text_frame = text_frame_snap,
        .bin_frame = bin_frame_snap,
        .owned_peak = owned_peak,
        .owned_freed = owned_freed,
        .text_status = text_cold,
        .bin_status = bin_cold,
    });
    try writeMeta(init.io, opts.out, base, tsc_hz, clock_ns);
}

const Frame = struct {
    t: f64,
    ns: u64,
    allocs: u64,
    frees: u64,
    bytes: i64,
    frame_len: u32,
    hash: u64,
};

const PathKind = enum { text, binary };

fn sweep(
    kind: ScoreKind,
    path: PathKind,
    out: []Frame,
    counter: *Counter,
    tsc_hz: u64,
) !void {
    for (out, 0..) |*frame, i| {
        const t = scriptedTime(kind, i, out.len);
        const before = counter.snapshot();
        const start = rdtsc();
        const len = switch (path) {
            .text => NativeText.evalSeconds(t),
            .binary => NativeRt.evalSeconds(t),
        };
        const end = rdtsc();
        const hash = switch (path) {
            .text => fnv1a(NativeText.writesPtr()[0..len]),
            .binary => fnv1a(NativeRt.writesPtr()[0..len]),
        };
        const after = counter.snapshot();
        if (len == 0) return error.EmptyFrame;
        frame.* = .{
            .t = t,
            .ns = @intCast((@as(u128, end - start) * std.time.ns_per_s) / tsc_hz),
            .allocs = after.allocs - before.allocs,
            .frees = after.frees - before.frees,
            .bytes = after.live - before.live,
            .frame_len = len,
            .hash = hash,
        };
    }
}

/// The x86-64 cycle counter. On this host `clock_gettime` itself costs
/// ~20 us (measured; see the meta row), which would swamp a frame; the
/// per-frame distribution therefore uses `rdtsc` and converts with a
/// calibration measured against `CLOCK_MONOTONIC` at run start.
fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn calibrateTsc() u64 {
    const start_ns = fastNow();
    const start_tsc = rdtsc();
    var now_ns = start_ns;
    while (now_ns - start_ns < 200 * std.time.ns_per_ms) : (now_ns = fastNow()) {}
    const end_tsc = rdtsc();
    const elapsed_ns = now_ns - start_ns;
    return @intCast((@as(u128, end_tsc - start_tsc) * std.time.ns_per_s) / elapsed_ns);
}

fn clockOverhead() u64 {
    const n = 1000;
    const start = fastNow();
    var sink: u64 = 0;
    for (0..n) |_| sink +%= fastNow();
    const end = fastNow();
    return (end - start) / n;
}

/// `CLOCK_MONOTONIC` directly (nanoseconds). The 0.16 `Io` clock vtable is
/// an event-loop call and costs far more than the frame under test; the
/// measurement must not be dominated by its own instrument. On OpenBSD this
/// is the ordinary `clock_gettime` syscall.
fn fastNow() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    const ns: i128 = @as(i128, ts.sec) * std.time.ns_per_s + @as(i128, ts.nsec);
    return @intCast(ns);
}

/// Deterministic scripted times. N is split into four equal phases; the
/// final phase absorbs any remainder. All values are valid f64 seconds for
/// the score's clock (the engine applies hold/loop itself).
fn scriptedTime(kind: ScoreKind, i: usize, total: usize) f64 {
    const quarter = total / 4;
    const phase = i / quarter;
    const j = i % quarter;
    return switch (kind) {
        .all_features => switch (phase) {
            0 => @as(f64, @floatFromInt(j)) * 0.0004, // 0 -> 10 s; 4 s scene, 6 s wrap
            1 => sceneSeek(j, &.{ 0.0, 3.99, 4.0, 5.99, 6.0 }),
            2 => 6.5 - @as(f64, @floatFromInt(j % 200)) * 0.01, // descending revisits
            else => 5.9 + @as(f64, @floatFromInt(j % 20)) * 0.01, // wrap crossings
        },
        .meridian_minimal => switch (phase) {
            0 => @as(f64, @floatFromInt(j)) * 0.0014, // 0 -> 35 s; 4bar/8bar scenes
            1 => sceneSeek(j, &.{ 0.0, 11.707317, 23.414634, 35.121951 }),
            2 => 30.0 - @as(f64, @floatFromInt(j % 200)) * 0.01,
            else => 35.0 + @as(f64, @floatFromInt(j % 20)) * 0.01, // hold-end crossing
        },
    };
}

fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf29ce484222325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    return h;
}

fn expectFrameParity(text: []const Frame, binary: []const Frame) !void {
    if (text.len != binary.len) return error.FrameParityMismatch;
    for (text, binary) |a, b| {
        if (a.frame_len != b.frame_len or a.hash != b.hash)
            return error.FrameParityMismatch;
    }
}

fn sceneSeek(j: usize, bases: []const f64) f64 {
    const base = bases[j % bases.len];
    const jitter = @as(f64, @floatFromInt((j / bases.len) % 7)) * 0.0001;
    return base + jitter;
}

fn writeFrames(io: std.Io, path: []const u8, data: []const Frame) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("frame\tt_seconds\tns\tallocs\tfrees\tbytes\tframe_len\tfnv1a64\n");
    for (data, 0..) |f, i| {
        try w.print("{d}\t{d:.9}\t{d}\t{d}\t{d}\t{d}\t{d}\t{x}\n", .{
            i, f.t, f.ns, f.allocs, f.frees, f.bytes, f.frame_len, f.hash,
        });
    }
    try w.flush();
}

const LoadSnapshots = struct {
    text_cold: Snapshot,
    text_warm: Snapshot,
    bin_cold: Snapshot,
    bin_warm: Snapshot,
    text_frame: Snapshot,
    bin_frame: Snapshot,
    owned_peak: Snapshot,
    owned_freed: Snapshot,
    text_status: u32,
    bin_status: u32,
};

fn steady(kind: ScoreKind, path: PathKind, n: usize) !void {
    for (0..n) |i| {
        const t = scriptedTime(kind, i, n);
        const len = switch (path) {
            .text => NativeText.evalSeconds(t),
            .binary => NativeRt.evalSeconds(t),
        };
        if (len == 0) return error.EmptyFrame;
    }
}

fn writeMeta(io: std.Io, out: []const u8, base: []const u8, tsc_hz: u64, clock_ns: u64) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.meta.tsv", .{ out, base });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("key\tvalue\n");
    try w.print("tsc_hz\t{d}\n", .{tsc_hz});
    try w.print("clock_gettime_ns_per_call\t{d}\n", .{clock_ns});
    try w.flush();
}

fn writeLoads(io: std.Io, out: []const u8, base: []const u8, s: LoadSnapshots) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.memory.tsv", .{ out, base });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("row\tstatus\tallocs\tfrees\ttotal_alloc_bytes\tpeak_bytes\tlive_after_bytes\n");
    try row(w, "text-cold-load", s.text_status, s.text_cold);
    try row(w, "text-warm-reload", 0, s.text_warm);
    try row(w, "binary-cold-load", s.bin_status, s.bin_cold);
    try row(w, "binary-warm-reload", 0, s.bin_warm);
    try row(w, "text-steady-frame-1000", 0, s.text_frame);
    try row(w, "binary-steady-frame-1000", 0, s.bin_frame);
    try row(w, "decodedscore-ownership-copy", 0, s.owned_peak);
    try row(w, "decodedscore-after-deinit", 0, s.owned_freed);
    try w.flush();
}

fn row(w: *std.Io.Writer, name: []const u8, status: u32, s: Snapshot) !void {
    try w.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        name, status, s.allocs, s.frees, s.total, s.peak, s.live,
    });
}

fn writeSummaries(io: std.Io, out: []const u8, base: []const u8, text: []const Frame, bin: []const Frame) !void {
    var path_buf: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}.summary.tsv", .{ out, base });
    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buf: [16 * 1024]u8 = undefined;
    var fw = file.writer(io, &buf);
    const w = &fw.interface;
    try w.writeAll("path\tframes\tp50_ns\tp95_ns\tp99_ns\tmax_ns\tmedian_abs_dev_ns\tmean_ns\talloc_frames\ttotal_allocs\n");
    try summaryRow(w, "text", text);
    try summaryRow(w, "binary", bin);
    try w.flush();
}

fn summaryRow(w: *std.Io.Writer, name: []const u8, frames: []const Frame) !void {
    const n = frames.len;
    const ns = try std.heap.page_allocator.alloc(u64, n);
    defer std.heap.page_allocator.free(ns);
    var total_allocs: u64 = 0;
    var alloc_frames: u64 = 0;
    var sum: u128 = 0;
    for (frames, 0..) |f, i| {
        ns[i] = f.ns;
        sum += f.ns;
        total_allocs += f.allocs;
        if (f.allocs > 0) alloc_frames += 1;
    }
    std.mem.sort(u64, ns, {}, std.sort.asc(u64));
    const p50 = ns[(n * 50) / 100];
    const p95 = ns[@min(n - 1, (n * 95) / 100)];
    const p99 = ns[@min(n - 1, (n * 99) / 100)];
    const max = ns[n - 1];
    const dev = try std.heap.page_allocator.alloc(u64, n);
    defer std.heap.page_allocator.free(dev);
    for (ns, 0..) |v, i| dev[i] = if (v > p50) v - p50 else p50 - v;
    std.mem.sort(u64, dev, {}, std.sort.asc(u64));
    const mad = dev[(n * 50) / 100];
    try w.print("{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n", .{
        name, n, p50, p95, p99, max, mad, sum / n, alloc_frames, total_allocs,
    });
}

fn parseArgs(a: std.mem.Allocator, args: []const []const u8) !Options {
    var opts: Options = .{ .doc = "", .pacb = "", .out = "" };
    var targets: std.ArrayList(pacer.Compile.Target) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--score")) {
            i += 1;
            opts.score = args[i];
        } else if (std.mem.eql(u8, arg, "--doc")) {
            i += 1;
            opts.doc = args[i];
        } else if (std.mem.eql(u8, arg, "--pacb")) {
            i += 1;
            opts.pacb = args[i];
        } else if (std.mem.eql(u8, arg, "--out")) {
            i += 1;
            opts.out = args[i];
        } else if (std.mem.eql(u8, arg, "--frames")) {
            i += 1;
            opts.frames = try std.fmt.parseInt(usize, args[i], 10);
        } else if (std.mem.eql(u8, arg, "--target")) {
            i += 1;
            try targets.append(a, try parseTarget(a, args[i]));
        } else {
            return error.UnknownArgument;
        }
    }
    if (opts.doc.len == 0 or opts.pacb.len == 0 or opts.out.len == 0) return error.MissingArgument;
    if (opts.frames == 0 or opts.frames % 4 != 0) return error.BadFrameCount;
    opts.targets = targets.items;
    return opts;
}

fn parseTarget(a: std.mem.Allocator, spec: []const u8) !pacer.Compile.Target {
    var it = std.mem.splitScalar(u8, spec, ':');
    const name = it.next() orelse return error.BadTarget;
    var ncomp: u8 = 1;
    var registry: u8 = 0;
    if (it.next()) |n| ncomp = try std.fmt.parseInt(u8, n, 10);
    if (it.next()) |r| registry = try std.fmt.parseInt(u8, r, 10);
    if (it.next() != null) return error.BadTarget;
    // `name` aliases argv, which lives for the whole run.
    _ = a;
    return .{ .name = name, .ncomp = ncomp, .registry = registry };
}
