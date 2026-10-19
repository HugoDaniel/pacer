const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Expr = @import("Expr.zig");
const Plugin = @import("Plugin.zig");
const PluginValueCodec = @import("PluginValueCodec.zig");
const native_plugin_exec = !builtin.cpu.arch.isWasm() and build_options.plugin_exec;
const PluginRuntime = if (native_plugin_exec) @import("PluginRuntime.zig") else opaque {};
