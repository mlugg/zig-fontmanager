pub fn build(b: *std.Build) void {
    const ft = b.dependency("mach-freetype", .{});
    _ = b.addModule("fontmanager", .{
        .root_source_file = b.path("font_manager.zig"),
        .imports = &.{
            .{ .name = "freetype", .module = ft.module("mach-freetype") },
            .{ .name = "harfbuzz", .module = ft.module("mach-harfbuzz") },
        },
    });
}

const std = @import("std");
