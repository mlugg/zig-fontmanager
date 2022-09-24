const std = @import("std");

pub fn pkg(comptime freetype: anytype) std.build.Pkg {
    return .{
        .name = "fontmanager",
        .source = .{ .path = comptime thisDir() ++ "/font_manager.zig" },
        .dependencies = &.{ freetype.pkg, freetype.harfbuzz_pkg },
    };
}

fn thisDir() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}
