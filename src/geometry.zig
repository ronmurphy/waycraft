const std = @import("std");
const vk = @import("vulkan");
const vku = @import("vk_utils.zig");
const za = @import("zalgebra");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Renderer = @import("renderer.zig").Renderer;

pub const Geometry = struct {
    pub const Vertex = struct {
        pub const binding_description = vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .input_rate = .vertex,
        };

        pub const attribute_description = [_]vk.VertexInputAttributeDescription{
            .{
                .binding = 0,
                .location = 0,
                .format = .r32g32b32_sfloat,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = .r32g32_sfloat,
                .offset = @offsetOf(Vertex, "tex_coord"),
            },
        };

        pos: [3]f32,
        tex_coord: [2]f32,
    };

    renderer: *Renderer,

    verts: []const Vertex,
    indices: []const u32,

    vert_buf: ?vku.Buf,
    index_buf: ?vku.Buf,

    pub fn fromVertsAndIndices(renderer: *Renderer, verts: []const Vertex, indices: []const u32) !Geometry {
        var geometry = Geometry{
            .renderer = renderer,

            .verts = verts,
            .indices = indices,

            .vert_buf = null,
            .index_buf = null,
        };
        try geometry.uploadVertsAndIndices();
        return geometry;
    }

    /// This doesn't free verts and indices, you need to do that yourself
    pub fn deinit(g: *Geometry) void {
        if (g.vert_buf) |buf| {
            g.renderer.destroyBufAfterFrame(buf);
            g.vert_buf = null;
        }
        if (g.index_buf) |buf| {
            g.renderer.destroyBufAfterFrame(buf);
            g.index_buf = null;
        }
    }

    pub fn uploadVertsAndIndices(g: *Geometry) !void {
        const gc = &g.renderer.gc;

        const vert_buf_size = g.verts.len * @sizeOf(Vertex);
        const index_buf_size = g.indices.len * @sizeOf(u32);

        if (g.vert_buf) |old_vert_buf| {
            if (old_vert_buf.size != vert_buf_size) {
                g.renderer.destroyBufAfterFrame(old_vert_buf);
                g.vert_buf = null;
            }
        }

        if (g.index_buf) |old_index_buf| {
            if (old_index_buf.size != index_buf_size) {
                g.renderer.destroyBufAfterFrame(old_index_buf);
                g.index_buf = null;
            }
        }

        const vert_buf = g.vert_buf orelse try vku.Buf.create(gc, vert_buf_size, .{ .vertex_buffer_bit = true, .transfer_dst_bit = true }, .{ .device_local_bit = true });
        try vert_buf.upload(gc, @ptrCast(g.verts));
        g.vert_buf = vert_buf;

        const index_buf = g.index_buf orelse try vku.Buf.create(gc, index_buf_size, .{ .index_buffer_bit = true, .transfer_dst_bit = true }, .{ .device_local_bit = true });
        try index_buf.upload(gc, @ptrCast(g.indices));
        g.index_buf = index_buf;
    }
};
