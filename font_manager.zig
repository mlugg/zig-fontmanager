const std = @import("std");
const freetype = @import("freetype");
const harfbuzz = @import("harfbuzz");

pub fn FontManager(comptime TextureContext: type) type {
    return struct {
        const Self = @This();

        const RenderTexture = if (std.meta.trait.is(.Pointer)(TextureContext))
            std.meta.Child(TextureContext).RenderTexture
        else
            TextureContext.RenderTexture;

        allocator: std.mem.Allocator,
        texture_context: TextureContext,

        ft_lib: freetype.Library,
        font_faces: std.StringArrayHashMapUnmanaged(FontFace),
        font_pages: std.ArrayListUnmanaged(FontPage),

        const GlyphInfo = struct {
            page_idx: u32,
            top: f32,
            left: f32,
            bottom: f32,
            right: f32,
            layout_width: u32,
            layout_height: u32,
        };

        const FontFace = struct {
            face: freetype.Face,
            hb_font: harfbuzz.Font,
            glyphs: std.ArrayHashMapUnmanaged(GlyphKey, GlyphInfo, GlyphKey.Comparator, false),

            const GlyphKey = struct {
                glyph_idx: u32,
                size: u32,

                const Comparator = struct {
                    pub fn eql(_: Comparator, a: GlyphKey, b: GlyphKey, _: usize) bool {
                        return a.glyph_idx == b.glyph_idx and a.size == b.size;
                    }

                    pub fn hash(_: Comparator, k: GlyphKey) u32 {
                        return k.glyph_idx;
                    }
                };
            };
        };

        const FontPage = struct {
            width: u32,
            height: u32,
            tex_data: []u8, // width*height*4 (BGRA)
            tree: BspNode,
            arena: std.heap.ArenaAllocator,

            const page_size = 512; // default width and height of a font page

            const BspNode = union(enum) {
                free,
                occupied,
                branch_x: struct {
                    children: [*]BspNode, //*[2]BspNode, TODO: https://github.com/ziglang/zig/issues/12325
                    left_px: u32,
                },
                branch_y: struct {
                    children: [*]BspNode, //*[2]BspNode, TODO: https://github.com/ziglang/zig/issues/12325
                    top_px: u32,
                },

                fn splitX(self: *BspNode, arena: std.mem.Allocator, left_px: u32) !*[2]BspNode {
                    std.debug.assert(self.* == .free);

                    const children = try arena.create([2]BspNode);
                    children.* = .{ .free, .free };

                    self.* = .{ .branch_x = .{
                        .children = children,
                        .left_px = left_px,
                    } };

                    return children;
                }

                fn splitY(self: *BspNode, arena: std.mem.Allocator, top_px: u32) !*[2]BspNode {
                    std.debug.assert(self.* == .free);

                    const children = try arena.create([2]BspNode);
                    children.* = .{ .free, .free };

                    self.* = .{ .branch_y = .{
                        .children = children,
                        .top_px = top_px,
                    } };

                    return children;
                }

                const ReserveError = std.mem.Allocator.Error || error{BspNodeFull};

                fn reserve(
                    self: *BspNode,
                    arena: std.mem.Allocator,
                    target_width: u32,
                    target_height: u32,
                    cur_width: u32,
                    cur_height: u32,
                ) ReserveError![2]u32 {
                    if (cur_width < target_width or cur_height < target_height) {
                        return error.BspNodeFull;
                    }

                    switch (self.*) {
                        .free => {
                            // we have space! split the node up if needed

                            const extra_x = cur_width - target_width;
                            const extra_y = cur_height - target_height;

                            var node = self;

                            if (extra_x > extra_y) {
                                // split horizontally first
                                if (extra_x > 0) node = &(try node.splitX(arena, target_width))[0];
                                if (extra_y > 0) node = &(try node.splitY(arena, target_height))[0];
                            } else {
                                // split vertically first
                                if (extra_y > 0) node = &(try node.splitY(arena, target_height))[0];
                                if (extra_x > 0) node = &(try node.splitX(arena, target_width))[0];
                            }

                            node.* = .occupied;

                            return [2]u32{ 0, 0 };
                        },
                        .occupied => return error.BspNodeFull,
                        .branch_x => |branch| {
                            // try to find space on the left
                            if (branch.children[0].reserve(
                                arena,
                                target_width,
                                target_height,
                                branch.left_px,
                                cur_height,
                            )) |res| {
                                return res;
                            } else |err| switch (err) {
                                error.BspNodeFull => {},
                                else => |e| return e,
                            }

                            // try to find space on the right
                            if (branch.children[1].reserve(
                                arena,
                                target_width,
                                target_height,
                                cur_width - branch.left_px,
                                cur_height,
                            )) |res| {
                                return [2]u32{ res[0] + branch.left_px, res[1] };
                            } else |err| switch (err) {
                                error.BspNodeFull => {},
                                else => |e| return e,
                            }

                            return error.BspNodeFull;
                        },
                        .branch_y => |branch| {
                            // try to find space on the top
                            if (branch.children[0].reserve(
                                arena,
                                target_width,
                                target_height,
                                cur_width,
                                branch.top_px,
                            )) |res| {
                                return res;
                            } else |err| switch (err) {
                                error.BspNodeFull => {},
                                else => |e| return e,
                            }

                            // try to find space on the bottom
                            if (branch.children[1].reserve(
                                arena,
                                target_width,
                                target_height,
                                cur_width,
                                cur_height - branch.top_px,
                            )) |res| {
                                return [2]u32{ res[0], res[1] + branch.top_px };
                            } else |err| switch (err) {
                                error.BspNodeFull => {},
                                else => |e| return e,
                            }

                            return error.BspNodeFull;
                        },
                    }
                }
            };

            fn reserveNode(self: *FontPage, target_width: u32, target_height: u32) ![2]u32 {
                return self.tree.reserve(
                    self.arena.allocator(),
                    target_width,
                    target_height,
                    self.width,
                    self.height,
                );
            }
        };

        pub fn init(allocator: std.mem.Allocator, texture_context: TextureContext) !Self {
            const ft_lib = try freetype.Library.init();
            errdefer ft_lib.deinit();

            return Self{
                .allocator = allocator,
                .texture_context = texture_context,
                .ft_lib = ft_lib,
                .font_faces = .{},
                .font_pages = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.font_pages.items) |*font_page, i| {
                self.texture_context.destroyTexture(@intCast(u32, i));
                font_page.arena.deinit();
            }
            self.font_pages.deinit(self.allocator);

            for (self.font_faces.values()) |*font_face| {
                font_face.hb_font.deinit();
                font_face.face.deinit();
                font_face.glyphs.deinit(self.allocator);
            }
            self.font_faces.deinit(self.allocator);

            self.ft_lib.deinit();
        }

        pub fn registerFont(self: *Self, name: []const u8, path: []const u8, face_idx: i32) !void {
            const face = try self.ft_lib.createFace(path, face_idx);
            errdefer face.deinit();

            const result = try self.font_faces.getOrPut(self.allocator, name);
            if (result.found_existing) {
                return error.FontAlreadyExists;
            }

            result.value_ptr.* = .{
                .face = face,
                .hb_font = harfbuzz.Font.fromFreetypeFace(face),
                .glyphs = .{},
            };
        }

        const GlyphLocation = struct {
            page_idx: u32,
            x: u32,
            y: u32,
        };

        fn reserveSpaceForGlyph(self: *Self, width: u32, height: u32) !GlyphLocation {
            if (self.font_pages.items.len > 0) {
                // look for free space in the last page
                const page = &self.font_pages.items[self.font_pages.items.len - 1];
                if (page.reserveNode(width, height)) |pos| {
                    return GlyphLocation{
                        .page_idx = @intCast(u32, self.font_pages.items.len - 1),
                        .x = pos[0],
                        .y = pos[1],
                    };
                } else |err| switch (err) {
                    error.BspNodeFull => {},
                    else => |e| return e,
                }
            }

            // can't fit the glyph, allocate a new page

            const page_width: u32 = FontPage.page_size;
            const page_height: u32 = FontPage.page_size;

            if (width > page_width or height > page_height) return error.GlyphTooLarge;

            var page: FontPage = .{
                .width = page_width,
                .height = page_height,
                .tex_data = undefined,
                .tree = .free,
                .arena = std.heap.ArenaAllocator.init(self.allocator),
            };
            errdefer page.arena.deinit();

            page.tex_data = try page.arena.allocator().alloc(u8, page_width * page_height * 4);

            // initialize the texture to transparent white to prevent blending issues
            {
                var y: u32 = 0;
                while (y < page_height) : (y += 1) {
                    var x: u32 = 0;
                    while (x < page_width) : (x += 1) {
                        const i = y * page_width + x;
                        page.tex_data[i * 4 + 0] = 255;
                        page.tex_data[i * 4 + 1] = 255;
                        page.tex_data[i * 4 + 2] = 255;
                        page.tex_data[i * 4 + 3] = 0;
                    }
                }
            }

            const pos = page.reserveNode(width, height) catch |err| switch (err) {
                error.BspNodeFull => unreachable,
                else => |e| return e,
            };

            try self.texture_context.createTexture(
                @intCast(u32, self.font_pages.items.len),
                page.width,
                page.height,
                @as([]const u8, page.tex_data),
            );
            try self.font_pages.append(self.allocator, page);

            return GlyphLocation{
                .page_idx = @intCast(u32, self.font_pages.items.len - 1),
                .x = pos[0],
                .y = pos[1],
            };
        }

        fn getFontGlyph(self: *Self, font_face: *FontFace, glyph_idx: u32, size: u32, dpi: ?u16) !GlyphInfo {
            const glyph = try font_face.glyphs.getOrPut(self.allocator, .{
                .glyph_idx = glyph_idx,
                .size = size,
            });

            if (!glyph.found_existing) {
                try font_face.face.setCharSize(@intCast(i32, size), 0, dpi orelse 0, dpi orelse 0);
                try font_face.face.loadGlyph(glyph_idx, .{ .render = true });
                const bitmap = font_face.face.glyph().bitmap();

                // We want a 1px border around each glyph so that blending doesn't break everything
                const glyph_loc = try self.reserveSpaceForGlyph(bitmap.width() + 1, bitmap.rows() + 1);
                const page = self.font_pages.items[glyph_loc.page_idx];

                var y: u32 = 0;
                while (y < bitmap.rows()) : (y += 1) {
                    const ty = y + glyph_loc.y;
                    var x: u32 = 0;
                    while (x < bitmap.width()) : (x += 1) {
                        const tx = x + glyph_loc.x;

                        const i = ty * page.width + tx;
                        const j = y * bitmap.width() + x;

                        page.tex_data[i * 4 + 0] = 255;
                        page.tex_data[i * 4 + 1] = 255;
                        page.tex_data[i * 4 + 2] = 255;
                        page.tex_data[i * 4 + 3] = bitmap.buffer().?[j];
                    }
                }

                try self.texture_context.updateTexture(
                    glyph_loc.page_idx,
                    glyph_loc.x,
                    glyph_loc.y,
                    bitmap.width(),
                    bitmap.rows(),
                    @as([]const u8, page.tex_data),
                );

                const top = glyph_loc.y;
                const left = glyph_loc.x;
                const bottom = glyph_loc.y + bitmap.rows();
                const right = glyph_loc.x + bitmap.width();

                const metrics = font_face.face.glyph().metrics();

                glyph.value_ptr.* = .{
                    .page_idx = glyph_loc.page_idx,
                    .top = @intToFloat(f32, top) / @intToFloat(f32, page.height),
                    .left = @intToFloat(f32, left) / @intToFloat(f32, page.width),
                    .bottom = @intToFloat(f32, bottom) / @intToFloat(f32, page.height),
                    .right = @intToFloat(f32, right) / @intToFloat(f32, page.width),
                    .layout_width = @intCast(u32, metrics.width),
                    .layout_height = @intCast(u32, metrics.height),
                };
            }

            return glyph.value_ptr.*;
        }

        pub const GlyphRenderInfo = struct {
            render: struct {
                texture: RenderTexture,
                top: f32,
                left: f32,
                bottom: f32,
                right: f32,
            },
            layout: struct {
                x_advance: i32,
                y_advance: i32,
                x_offset: i32,
                y_offset: i32,
                width: u32,
                height: u32,
            },
        };

        pub const GlyphIterator = struct {
            manager: *Self,
            buf: harfbuzz.Buffer,
            font_face: *FontFace,
            infos: []harfbuzz.GlyphInfo,
            positions: []harfbuzz.Position,
            size: u32,
            dpi: ?u16,
            next_idx: u32,

            pub fn deinit(self: *GlyphIterator) void {
                self.buf.deinit();
            }

            pub fn next(self: *GlyphIterator) !?GlyphRenderInfo {
                if (self.next_idx == self.infos.len) {
                    return null;
                }

                const pos = self.positions[self.next_idx];
                const info = try self.manager.getFontGlyph(
                    self.font_face,
                    self.infos[self.next_idx].codepoint, // despite the name this is the glyph index
                    self.size,
                    self.dpi,
                );

                self.next_idx += 1;

                return GlyphRenderInfo{
                    .render = .{
                        .texture = self.manager.texture_context.getRenderTexture(info.page_idx),
                        .top = info.top,
                        .left = info.left,
                        .bottom = info.bottom,
                        .right = info.right,
                    },
                    .layout = .{
                        .x_advance = pos.x_advance,
                        .y_advance = pos.y_advance,
                        .x_offset = pos.x_offset,
                        .y_offset = pos.y_offset,
                        .width = info.layout_width,
                        .height = info.layout_height,
                    },
                };
            }
        };

        pub fn glyphIterator(self: *Self, face_name: []const u8, size: u32, dpi: ?u16, str: []const u8) !GlyphIterator {
            const font_face = self.font_faces.getPtr(face_name) orelse return error.NoSuchFace;

            const buf = harfbuzz.Buffer.init() orelse return error.BufferInitError;
            errdefer buf.deinit();

            buf.addUTF8(str, 0, null);
            buf.guessSegmentProps();

            font_face.hb_font.shape(buf, null);

            return GlyphIterator{
                .manager = self,
                .buf = buf,
                .font_face = font_face,
                .infos = buf.getGlyphInfos(),
                .positions = buf.getGlyphPositions().?,
                .size = size,
                .dpi = dpi,
                .next_idx = 0,
            };
        }
    };
}
