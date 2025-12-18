const std = @import("std");
const wls = @import("wayland").server.wl;
const vk = @import("vulkan");
const vku = @import("vk_utils.zig");
const za = @import("zalgebra");
const Mat4 = za.Mat4;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Geometry = @import("geometry.zig").Geometry;
const SimpleMaterial = @import("simple_material.zig").SimpleMaterial;
const Toplevel = @import("protocols/toplevel.zig").Toplevel;
const World = @import("world.zig").World;
const Renderer = @import("renderer.zig").Renderer;

const alloc = std.heap.c_allocator;

const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;

const PushConstants = struct {
    const range = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(PushConstants),
        .stage_flags = .{ .vertex_bit = true },
    };

    matrix: Mat4,
};

const verts = [_]Geometry.Vertex{
    .{ .pos = .{ 0, 0, 0 }, .tex_coord = .{ 0, 1 } },
    .{ .pos = .{ 0, 1, 0 }, .tex_coord = .{ 0, 0 } },
    .{ .pos = .{ 1, 0, 0 }, .tex_coord = .{ 1, 1 } },
    .{ .pos = .{ 1, 1, 0 }, .tex_coord = .{ 1, 0 } },
};

const indices = [_]u32{
    0, 1, 2,
    1, 3, 2,
};

const Uniforms = struct {
    color: [4]f32,
};
const uniforms: Uniforms = .{
    .color = .{ 1, 0, 0, 1 },
};

pub const ToplevelRenderable = struct {
    link: wls.list.Link,

    toplevel: *Toplevel,
    packed_data_buffer: ?[]u8,
    surface_changed_listener: wls.Listener(void),
    surface_destroyed_listener: wls.Listener(void),

    transform: Mat4,
    geometry: Geometry,
    material: SimpleMaterial,

    is_destroyed: bool = false,
    is_material_dirty: bool = false,

    pub fn init(toplevel: *Toplevel, renderer: *Renderer, width: u32, height: u32, render_sides: u32) !*ToplevelRenderable {
        const tr = try alloc.create(ToplevelRenderable);

        // Create scaled vertices based on requested size
        const w = @as(f32, @floatFromInt(width));
        const h = @as(f32, @floatFromInt(height));

        // Create geometry based on render_sides
        const geometry = if (render_sides == 1) blk: {
            // Single-sided: just the front face
            const scaled_verts = [_]Geometry.Vertex{
                .{ .pos = .{ 0, 0, 0 }, .tex_coord = .{ 0, 1 } },
                .{ .pos = .{ 0, h, 0 }, .tex_coord = .{ 0, 0 } },
                .{ .pos = .{ w, 0, 0 }, .tex_coord = .{ 1, 1 } },
                .{ .pos = .{ w, h, 0 }, .tex_coord = .{ 1, 0 } },
            };
            break :blk try Geometry.fromVertsAndIndices(renderer, &scaled_verts, &indices);
        } else blk: {
            // Two-sided: front face + back face with reversed winding
            const two_sided_verts = [_]Geometry.Vertex{
                // Front face (indices 0-3)
                .{ .pos = .{ 0, 0, 0 }, .tex_coord = .{ 0, 1 } },
                .{ .pos = .{ 0, h, 0 }, .tex_coord = .{ 0, 0 } },
                .{ .pos = .{ w, 0, 0 }, .tex_coord = .{ 1, 1 } },
                .{ .pos = .{ w, h, 0 }, .tex_coord = .{ 1, 0 } },
                // Back face (indices 4-7) - same positions, will use reversed indices
                .{ .pos = .{ 0, 0, 0 }, .tex_coord = .{ 0, 1 } },
                .{ .pos = .{ 0, h, 0 }, .tex_coord = .{ 0, 0 } },
                .{ .pos = .{ w, 0, 0 }, .tex_coord = .{ 1, 1 } },
                .{ .pos = .{ w, h, 0 }, .tex_coord = .{ 1, 0 } },
            };
            const two_sided_indices = [_]u32{
                // Front face
                0, 1, 2,
                1, 3, 2,
                // Back face (reversed winding)
                4, 6, 5,
                5, 6, 7,
            };
            break :blk try Geometry.fromVertsAndIndices(renderer, &two_sided_verts, &two_sided_indices);
        };

        tr.* = .{
            .link = undefined,
            .toplevel = toplevel,
            .packed_data_buffer = null,
            .surface_changed_listener = .init(onSurfaceChanged),
            .surface_destroyed_listener = .init(onSurfaceDestroyed),
            .transform = .identity(),
            .geometry = geometry,
            .material = try SimpleMaterial.create(renderer),
        };
        tr.link.init();

        tr.toplevel.xdg_surface.surface.events.state_changed.add(&tr.surface_changed_listener);
        tr.toplevel.xdg_surface.surface.events.destroyed.add(&tr.surface_destroyed_listener);

        return tr;
    }

    fn onSurfaceChanged(listener: *wls.Listener(void)) void {
        const tr: *ToplevelRenderable = @fieldParentPtr("surface_changed_listener", listener);
        tr.is_material_dirty = true;

        if (tr.packed_data_buffer) |d| alloc.free(d);
        tr.packed_data_buffer = null;
        if (tr.toplevel.xdg_surface.surface.state.buffer) |buffer| {
            const packed_stride = buffer.width * 4;
            tr.packed_data_buffer = alloc.alloc(u8, @intCast(buffer.height * packed_stride)) catch {
                std.log.err("OOM", .{});
                return;
            };
        }
    }

    fn onSurfaceDestroyed(listener: *wls.Listener(void)) void {
        const tr: *ToplevelRenderable = @fieldParentPtr("surface_destroyed_listener", listener);
        tr.is_destroyed = true;
    }

    pub fn render(tr: *ToplevelRenderable, gc: *const GraphicsContext, cmdbuf: vk.CommandBuffer, world: *const World) !void {
        if (tr.is_destroyed) {
            tr.link.remove();
            if (tr.packed_data_buffer) |d| alloc.free(d);
            tr.packed_data_buffer = null;
            tr.surface_changed_listener.link.remove();
            tr.surface_destroyed_listener.link.remove();
            tr.geometry.deinit();
            tr.material.destroy();
            alloc.destroy(tr);
            return;
        }

        if (tr.is_material_dirty) {
            if (tr.toplevel.xdg_surface.surface.state.buffer) |buffer| {
                var is_image_null_or_different_size = true;
                if (tr.material.image) |image| {
                    if (image.width == buffer.width and image.height == buffer.height) {
                        is_image_null_or_different_size = false;
                    }
                }
                if (is_image_null_or_different_size) {
                    const image = try vku.Image.create(
                        gc,
                        .b8g8r8a8_srgb,
                        @intCast(buffer.width),
                        @intCast(buffer.height),
                        .optimal,
                        .{ .sampled_bit = true, .transfer_dst_bit = true },
                        .{ .device_local_bit = true },
                        .{ .color_bit = true },
                    );
                    tr.material.setImage(image);
                }
                const packed_data_buffer = tr.packed_data_buffer.?;
                const packed_stride = buffer.width * 4; // We only support 4 byte color formats
                for (0..@intCast(buffer.height)) |y| {
                    const dst_i = @as(i32, @intCast(y)) * packed_stride;
                    const dst = packed_data_buffer[@intCast(dst_i)..@intCast(dst_i + packed_stride)];
                    const src_i = @as(i32, @intCast(y)) * buffer.stride + buffer.offset;
                    const src = buffer.pool_data[@intCast(src_i)..@intCast(src_i + packed_stride)];
                    @memcpy(dst, src);
                }
                try vku.copyDataToImage(gc, packed_data_buffer, &tr.material.image.?);
                buffer.resource.sendRelease();
            } else {
                tr.material.setImage(null);
            }

            tr.is_material_dirty = false;
        }

        try tr.material.recordCommands(cmdbuf, world.cam.projview.mul(tr.transform));
        gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&tr.geometry.vert_buf.?.buf), &.{0});
        gc.dev.cmdBindIndexBuffer(cmdbuf, tr.geometry.index_buf.?.buf, 0, .uint32);
        gc.dev.cmdDrawIndexed(cmdbuf, @intCast(tr.geometry.indices.len), 1, 0, 0, 0);
    }
};
