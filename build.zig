const std = @import("std");
const freetype = @import("mach-freetype/build.zig");

pub const pkg = std.build.Pkg{
    .name = "fontmanager",
    .source = .{ .path = thisDir() ++ "/font_manager.zig" },
    .dependencies = &.{ freetype.pkg, freetype.harfbuzz_pkg },
};

pub fn link(b: *std.build.Builder, step: *std.build.LibExeObjStep) void {
    freetype.link(b, step, .{ .harfbuzz = .{} });
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
