const std = @import("std");

pub fn module(b: *std.Build, comptime freetype: anytype) *std.Build.Module {
    return b.createModule(.{
        .source_file = .{ .path = comptime thisDir() ++ "/font_manager.zig" },
        .dependencies = &.{
            .{ .name = "freetype", .module = freetype.module(b) },
            .{ .name = "harfbuzz", .module = freetype.harfbuzzModule(b) },
        },
    });
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
