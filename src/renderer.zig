const std = @import("std");
const wl = @import("wayland").client.wl;
const wls = @import("wayland").server.wl;
const vk = @import("vulkan");
const vku = @import("vk_utils.zig");
const za = @import("zalgebra");
const img = @import("zigimg");
const Vec3 = za.Vec3;
const Mat4 = za.Mat4;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const ToplevelRenderable = @import("toplevel_renderable.zig").ToplevelRenderable;
const Toplevel = @import("protocols/toplevel.zig").Toplevel;
const Buffer = @import("protocols/buffer.zig").Buffer;
const World = @import("world.zig").World;
const Chunk = @import("chunk.zig").Chunk;
const Geometry = @import("geometry.zig").Geometry;
const SimpleMaterial = @import("simple_material.zig").SimpleMaterial;
const LineMaterial = @import("line_material.zig").LineMaterial;

pub const max_frames_in_flight = 2;

const alloc = std.heap.c_allocator;

const SwapchainImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    framebuf: vk.Framebuffer,
    render_finished_semaphore: vk.Semaphore,
};

const Frame = struct {
    cmdbuf: vk.CommandBuffer,

    image_acquired_semaphore: vk.Semaphore,
    fence: vk.Fence,
};

const wire_box_verts = [_]Geometry.Vertex{
    .{ .pos = .{ 0, 0, 0 }, .tex_coord = .{ 0, 0 } },
    .{ .pos = .{ 1, 0, 0 }, .tex_coord = .{ 0, 0 } },
    .{ .pos = .{ 1, 1, 0 }, .tex_coord = .{ 0, 0 } },
    .{ .pos = .{ 0, 1, 0 }, .tex_coord = .{ 0, 0 } },

    .{ .pos = .{ 0, 0, 1 }, .tex_coord = .{ 0, 0 } },
    .{ .pos = .{ 1, 0, 1 }, .tex_coord = .{ 0, 0 } },
    .{ .pos = .{ 1, 1, 1 }, .tex_coord = .{ 0, 0 } },
    .{ .pos = .{ 0, 1, 1 }, .tex_coord = .{ 0, 0 } },
};

const wire_box_indices = [_]u32{
    // Front face
    0, 1, 1, 2, 2, 3, 3, 0,
    // Back face
    4, 5, 5, 6, 6, 7, 7, 4,
    // Left lines
    0, 4, 3, 7,
    // Right lines
    1, 5, 2, 6,
};

pub const Renderer = struct {
    world: *World,
    display: *wl.Display,
    surface: *wl.Surface,
    extent: vk.Extent2D,
    new_extent: ?vk.Extent2D = null,

    gc: GraphicsContext,
    surface_format: vk.SurfaceFormatKHR,
    depth_format: vk.Format,
    render_pass: vk.RenderPass,
    present_mode: vk.PresentModeKHR,
    depth_image: vku.Image,
    swapchain: vk.SwapchainKHR,
    swapchain_images: []SwapchainImage,
    frames_in_flight: [max_frames_in_flight]Frame,
    frame_index: usize = 0,

    center_cross_geometry: Geometry,
    center_cross_material: SimpleMaterial,
    wire_box_geometry: Geometry,
    wire_box_material: LineMaterial,
    focus_indicator_material: LineMaterial,

    bufs_to_destroy: std.ArrayList(vku.Buf),
    images_to_destroy: std.ArrayList(vku.Image),

    pub fn init(r: *Renderer, world: *World, display: *wl.Display, surface: *wl.Surface, desktop_mode: bool) !void {
        const gc = try GraphicsContext.init(alloc, "waycraft", @ptrCast(display), @ptrCast(surface));

        // In desktop mode, use fullscreen resolution. Otherwise use windowed resolution.
        const extent: vk.Extent2D = if (desktop_mode) blk: {
            // Try to get screen resolution, fallback to 1920x1080
            break :blk .{ .width = 1920, .height = 1080 };
        } else blk: {
            break :blk .{ .width = 1280, .height = 720 };
        };

        r.* = .{
            .world = world,
            .display = display,
            .surface = surface,
            .extent = extent,

            .gc = gc,
            .surface_format = undefined,
            .depth_format = undefined,
            .render_pass = undefined,
            .present_mode = undefined,
            .depth_image = undefined,
            .swapchain = undefined,
            .swapchain_images = undefined,
            .frames_in_flight = undefined,

            .center_cross_geometry = undefined,
            .center_cross_material = undefined,
            .wire_box_geometry = undefined,
            .wire_box_material = undefined,
            .focus_indicator_material = undefined,

            .bufs_to_destroy = try .initCapacity(alloc, 4),
            .images_to_destroy = try .initCapacity(alloc, 4),
        };

        try r.initFormats();
        try r.createRenderPass();
        try r.initSwapchain();

        var cmdbufs: [max_frames_in_flight]vk.CommandBuffer = undefined;
        try gc.dev.allocateCommandBuffers(&.{
            .command_pool = gc.cmdpool,
            .level = .primary,
            .command_buffer_count = max_frames_in_flight,
        }, &cmdbufs);
        for (&r.frames_in_flight, 0..) |*frame, i| frame.* = .{
            .cmdbuf = cmdbufs[i],

            .image_acquired_semaphore = try gc.dev.createSemaphore(&.{}, null),
            .fence = try gc.dev.createFence(&.{ .flags = .{ .signaled_bit = true } }, null),
        };

        r.wire_box_geometry = try .fromVertsAndIndices(r, &wire_box_verts, &wire_box_indices);
        r.wire_box_material = try .create(r, .{ 0, 0, 0, 1 }); // Black for raycast selection
        r.focus_indicator_material = try .create(r, .{ 0, 1, 1, 1 }); // Cyan for focus indicator

        // Center cross
        {
            const cross_size = 0.05;
            const half_cross_size = cross_size * 0.5;
            const vertices = try alloc.alloc(Geometry.Vertex, 4);
            @memcpy(vertices, &[_]Geometry.Vertex{
                .{ .pos = .{ -half_cross_size, -half_cross_size, 0 }, .tex_coord = .{ 0, 0 } },
                .{ .pos = .{ half_cross_size, -half_cross_size, 0 }, .tex_coord = .{ 1, 0 } },
                .{ .pos = .{ half_cross_size, half_cross_size, 0 }, .tex_coord = .{ 1, 1 } },
                .{ .pos = .{ -half_cross_size, half_cross_size, 0 }, .tex_coord = .{ 0, 1 } },
            });
            const indices = try alloc.alloc(u32, 6);
            @memcpy(indices, &[_]u32{ 0, 1, 2, 2, 3, 0 });
            r.center_cross_geometry = try .fromVertsAndIndices(r, vertices, indices);

            var image_read_buffer: [img.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
            const image = try img.Image.fromFilePath(alloc, "cross.png", &image_read_buffer);
            const image_vk = try vku.Image.create(
                &r.gc,
                .r8g8b8a8_srgb,
                @intCast(image.width),
                @intCast(image.height),
                .optimal,
                .{ .sampled_bit = true, .transfer_dst_bit = true },
                .{ .device_local_bit = true },
                .{ .color_bit = true },
            );
            try vku.copyDataToImage(&r.gc, @ptrCast(@alignCast(image.pixels.rgba32)), &image_vk);
            r.center_cross_material = try .createFromImage(r, image_vk);
        }
    }

    pub fn deinit(this: *@This()) void {
        const gc = &this.gc;

        gc.dev.deviceWaitIdle() catch {};

        defer gc.deinit();
        defer gc.dev.destroyCommandPool(this.cmdpool, null);
        defer {
            this.deinitSwapchain();
            alloc.free(this.swapchain_images);
        }
        defer gc.dev.destroyRenderPass(this.render_pass, null);
        defer this.deinitFramebufs();

        defer {
            for (this.bufs_to_destroy.items) |buf| buf.destroy(gc);
            this.bufs_to_destroy.deinit(alloc);
        }
        defer {
            for (this.images_to_destroy.items) |image| image.destroy(gc);
            this.images_to_destroy.deinit(alloc);
        }

        defer {
            const toplevel_iter = this.toplevels.safeIterator(.forward);
            while (toplevel_iter.next()) |toplevel| toplevel.deinit(gc);
        }
    }

    fn initFormats(r: *Renderer) !void {
        const gc = &r.gc;

        r.surface_format = try findSurfaceFormat(gc);
        r.depth_format = try findDepthFormat(gc);
    }

    fn initSwapchain(r: *Renderer) !void {
        const gc = &r.gc;

        r.present_mode = try findPresentMode(gc);

        const depth_image = try vku.Image.create(
            gc,
            r.depth_format,
            r.extent.width,
            r.extent.height,
            .optimal,
            .{ .depth_stencil_attachment_bit = true },
            .{ .device_local_bit = true },
            .{ .depth_bit = true },
        );
        try vku.transitionImageLayout(gc, .undefined, .depth_stencil_attachment_optimal, depth_image.image, depth_image.format);

        const caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) {
            image_count = @min(image_count, caps.max_image_count);
        }

        var swapchain_create_info = vk.SwapchainCreateInfoKHR{
            .surface = gc.surface,
            .min_image_count = image_count,
            .image_format = r.surface_format.format,
            .image_color_space = r.surface_format.color_space,
            .image_extent = r.extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = r.present_mode,
            .clipped = .true,
        };
        if (gc.graphics_queue.family != gc.present_queue.family) {
            const qfi = [_]u32{ gc.graphics_queue.family, gc.present_queue.family };
            swapchain_create_info.image_sharing_mode = .concurrent;
            swapchain_create_info.queue_family_index_count = qfi.len;
            swapchain_create_info.p_queue_family_indices = &qfi;
        }
        const swapchain = try gc.dev.createSwapchainKHR(&swapchain_create_info, null);

        const images = try gc.dev.getSwapchainImagesAllocKHR(swapchain, alloc);
        defer alloc.free(images);

        const swapchain_images = try alloc.alloc(SwapchainImage, image_count);
        for (swapchain_images, 0..) |*swapchain_image, i| {
            const view = try gc.dev.createImageView(&.{
                .image = images[i],
                .view_type = .@"2d",
                .format = r.surface_format.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);

            const framebuf = try gc.dev.createFramebuffer(&.{
                .render_pass = r.render_pass,
                .attachment_count = 2,
                .p_attachments = &.{ view, depth_image.view },
                .width = r.extent.width,
                .height = r.extent.height,
                .layers = 1,
            }, null);

            swapchain_image.* = .{
                .image = images[i],
                .view = view,
                .framebuf = framebuf,
                .render_finished_semaphore = try gc.dev.createSemaphore(&.{}, null),
            };
        }

        r.depth_image = depth_image;
        r.swapchain = swapchain;
        r.swapchain_images = swapchain_images;
    }

    fn deinitSwapchain(r: *Renderer) void {
        const gc = &r.gc;

        for (r.swapchain_images) |swapchain_image| {
            gc.dev.destroySemaphore(swapchain_image.render_finished_semaphore, null);
            gc.dev.destroyFramebuffer(swapchain_image.framebuf, null);
            gc.dev.destroyImageView(swapchain_image.view, null);
        }
        gc.dev.destroySwapchainKHR(r.swapchain, null);
        r.depth_image.destroy(gc);
    }

    pub fn resize(r: *Renderer, w: u32, h: u32) !void {
        const gc = &r.gc;

        const caps = try gc.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(gc.pdev, gc.surface);
        const actual_extent = findActualExtent(caps, .{ .width = w, .height = h });
        if (actual_extent.width == 0 or actual_extent.height == 0) {
            return error.InvalidSurfaceDimensions;
        }

        r.world.cam.aspect = @as(f32, @floatFromInt(actual_extent.width)) / @as(f32, @floatFromInt(actual_extent.height));
        r.world.cam.updateProjView();

        r.new_extent = actual_extent;
    }

    pub fn destroyBufAfterFrame(r: *Renderer, buf: vku.Buf) void {
        r.bufs_to_destroy.append(alloc, buf) catch {
            std.log.err("OOM", .{});
            return;
        };
    }

    pub fn destroyImageAfterFrame(r: *Renderer, image: vku.Image) void {
        r.images_to_destroy.append(alloc, image) catch {
            std.log.err("OOM", .{});
            return;
        };
    }

    fn recreateSwapchain(r: *Renderer) !void {
        const gc = &r.gc;

        gc.dev.deviceWaitIdle() catch {};

        r.deinitSwapchain();
        try r.initSwapchain();
    }

    fn acquireNextImage(r: *Renderer) !u32 {
        const frame = &r.frames_in_flight[r.frame_index];

        while (true) {
            const acquire_next_image_result = try r.gc.dev.acquireNextImageKHR(r.swapchain, std.math.maxInt(u64), frame.image_acquired_semaphore, .null_handle);
            const result = acquire_next_image_result.result;
            const image_index = acquire_next_image_result.image_index;

            if (result == .success or result == .suboptimal_khr) {
                return image_index;
            } else if (result == .error_out_of_date_khr) {
                try r.recreateSwapchain();
            } else {
                return error.FailedAcquireSwapchainImage;
            }
        }
    }

    pub fn render(this: *@This()) !void {
        // Don't present or resize swapchain while the window is minimized
        if (this.extent.width == 0 or this.extent.height == 0) {
            return;
        }

        const gc = &this.gc;
        const frame = &this.frames_in_flight[this.frame_index];

        // Wait for this frame to finish rendering from last time
        _ = try gc.dev.waitForFences(1, @ptrCast(&frame.fence), .true, std.math.maxInt(u64));
        // Reset the frame fence so that it will wait the next time we get here
        try gc.dev.resetFences(1, @ptrCast(&frame.fence));

        // Acquire the swapchain image index for this frame
        const image_index = try this.acquireNextImage();
        const swapchain_image = this.swapchain_images[image_index];

        // Record the command buffer
        try this.recordCommandBuffers(frame.cmdbuf, swapchain_image.framebuf);

        // Submit the command buffer (only after the next swap image is acquired)
        try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, &[_]vk.SubmitInfo{.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.image_acquired_semaphore),
            .p_wait_dst_stage_mask = &.{.{ .color_attachment_output_bit = true }},
            .command_buffer_count = 1,
            .p_command_buffers = @ptrCast(&frame.cmdbuf),
            .signal_semaphore_count = 1,
            .p_signal_semaphores = @ptrCast(&swapchain_image.render_finished_semaphore),
        }}, frame.fence);

        // Present the result (only after the queue has finished executing)
        const present_result = try gc.dev.queuePresentKHR(gc.present_queue.handle, &.{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&swapchain_image.render_finished_semaphore),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&this.swapchain),
            .p_image_indices = @ptrCast(&image_index),
        });

        if (present_result == .error_out_of_date_khr or present_result == .suboptimal_khr or this.new_extent != null) {
            if (this.new_extent) |new_extent| {
                this.extent = new_extent;
                this.new_extent = null;
            }
            try this.recreateSwapchain();
        } else if (present_result != .success) {
            return error.FailedToPresent;
        }

        this.frame_index = (this.frame_index + 1) % max_frames_in_flight;

        // Cleanup
        for (this.bufs_to_destroy.items) |buf| buf.destroy(gc);
        this.bufs_to_destroy.clearRetainingCapacity();
        for (this.images_to_destroy.items) |image| image.destroy(gc);
        this.images_to_destroy.clearRetainingCapacity();
    }

    fn createRenderPass(r: *Renderer) !void {
        const gc = &r.gc;

        const color_attachment = vk.AttachmentDescription{
            .format = r.surface_format.format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .store,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .present_src_khr,
        };
        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = .color_attachment_optimal,
        };

        const depth_attachment = vk.AttachmentDescription{
            .format = r.depth_format,
            .samples = .{ .@"1_bit" = true },
            .load_op = .clear,
            .store_op = .dont_care,
            .stencil_load_op = .dont_care,
            .stencil_store_op = .dont_care,
            .initial_layout = .undefined,
            .final_layout = .depth_stencil_attachment_optimal,
        };
        const depth_attachment_ref = vk.AttachmentReference{
            .attachment = 1,
            .layout = .depth_stencil_attachment_optimal,
        };

        const subpass = vk.SubpassDescription{
            .pipeline_bind_point = .graphics,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment_ref),
            .p_depth_stencil_attachment = @ptrCast(&depth_attachment_ref),
        };

        const dependency = vk.SubpassDependency{
            .src_subpass = vk.SUBPASS_EXTERNAL,
            .dst_subpass = 0,
            .src_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .src_access_mask = .{},
            .dst_stage_mask = .{ .color_attachment_output_bit = true, .early_fragment_tests_bit = true },
            .dst_access_mask = .{ .color_attachment_write_bit = true, .depth_stencil_attachment_write_bit = true },
        };

        r.render_pass = try gc.dev.createRenderPass(&.{
            .attachment_count = 2,
            .p_attachments = &.{ color_attachment, depth_attachment },
            .subpass_count = 1,
            .p_subpasses = @ptrCast(&subpass),
            .dependency_count = 1,
            .p_dependencies = @ptrCast(&dependency),
        }, null);
    }

    fn recordCommandBuffers(r: *Renderer, cmdbuf: vk.CommandBuffer, framebuf: vk.Framebuffer) !void {
        const gc = &r.gc;
        const world = r.world;

        const clear_values = [_]vk.ClearValue{
            .{ .color = .{ .float_32 = .{ 0.5, 0.69, 1, 1 } } },
            .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
        };

        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(r.extent.width),
            .height = @floatFromInt(r.extent.height),
            .min_depth = 0,
            .max_depth = 1,
        };

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = r.extent,
        };

        try gc.dev.resetCommandBuffer(cmdbuf, .{});

        try gc.dev.beginCommandBuffer(cmdbuf, &.{});

        gc.dev.cmdSetViewport(cmdbuf, 0, 1, @ptrCast(&viewport));
        gc.dev.cmdSetScissor(cmdbuf, 0, 1, @ptrCast(&scissor));

        gc.dev.cmdBeginRenderPass(cmdbuf, &.{
            .render_pass = r.render_pass,
            .framebuffer = framebuf,
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = r.extent,
            },
            .clear_value_count = clear_values.len,
            .p_clear_values = &clear_values,
        }, .@"inline");

        try world.render(r, cmdbuf);

        if (world.raycast_result) |raycast_result| {
            const block = world.at(raycast_result.block_pos);

            // Scale the selection box to match window dimensions and use window's transform
            const wire_box_transform = if (block == .toplevel) blk: {
                const tr = block.toplevel;
                // Convert pixel dimensions to block dimensions (1 block = 1024 pixels)
                const pixels_per_block: f32 = 1024.0;
                const w = @as(f32, @floatFromInt(tr.toplevel.width)) / pixels_per_block;
                const h = @as(f32, @floatFromInt(tr.toplevel.height)) / pixels_per_block;
                const depth = 0.1;
                const scale = Mat4.fromScale(Vec3.new(w, h, depth));
                // Use the window's actual transform instead of just block position
                break :blk tr.transform.mul(scale);
            } else blk: {
                break :blk Mat4.fromTranslate(raycast_result.block_pos.cast(f32));
            };

            try r.wire_box_material.recordCommands(cmdbuf, world.cam.projview.mul(wire_box_transform));
            gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&r.wire_box_geometry.vert_buf.?.buf), &.{0});
            gc.dev.cmdBindIndexBuffer(cmdbuf, r.wire_box_geometry.index_buf.?.buf, 0, .uint32);
            gc.dev.cmdDrawIndexed(cmdbuf, @intCast(r.wire_box_geometry.indices.len), 1, 0, 0, 0);
        }

        // Focus indicator - draw cyan wireframe around active window
        if (world.active_toplevel) |active_toplevel| {
            for (world.toplevel_renderables.items) |tr| {
                if (tr.toplevel == active_toplevel) {
                    // Convert pixel dimensions to block dimensions (1 block = 1024 pixels)
                    const pixels_per_block: f32 = 1024.0;
                    const w = @as(f32, @floatFromInt(tr.toplevel.width)) / pixels_per_block;
                    const h = @as(f32, @floatFromInt(tr.toplevel.height)) / pixels_per_block;
                    const depth = 0.1; // Small depth for visibility

                    const scale = Mat4.fromScale(Vec3.new(w, h, depth));
                    const focus_box_transform = tr.transform.mul(scale);

                    try r.focus_indicator_material.recordCommands(cmdbuf, world.cam.projview.mul(focus_box_transform));
                    gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&r.wire_box_geometry.vert_buf.?.buf), &.{0});
                    gc.dev.cmdBindIndexBuffer(cmdbuf, r.wire_box_geometry.index_buf.?.buf, 0, .uint32);
                    gc.dev.cmdDrawIndexed(cmdbuf, @intCast(r.wire_box_geometry.indices.len), 1, 0, 0, 0);
                    break;
                }
            }
        }

        const cross_transform = Mat4{
            .data = .{
                .{ 1, 0, 0, 0 },
                .{ 0, world.cam.aspect, 0, 0 },
                .{ 0, 0, 1, 0 },
                .{ 0, 0, 0, 1 },
            },
        };
        try r.center_cross_material.recordCommands(cmdbuf, cross_transform);
        gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&r.center_cross_geometry.vert_buf.?.buf), &.{0});
        gc.dev.cmdBindIndexBuffer(cmdbuf, r.center_cross_geometry.index_buf.?.buf, 0, .uint32);
        gc.dev.cmdDrawIndexed(cmdbuf, @intCast(r.center_cross_geometry.indices.len), 1, 0, 0, 0);

        gc.dev.cmdEndRenderPass(cmdbuf);

        try gc.dev.endCommandBuffer(cmdbuf);
    }
};

fn findDepthFormat(gc: *const GraphicsContext) !vk.Format {
    const format_props = gc.instance.getPhysicalDeviceFormatProperties(gc.pdev, .d32_sfloat);
    if (format_props.optimal_tiling_features.depth_stencil_attachment_bit) {
        return .d32_sfloat;
    }
    return error.NoSuitableDepthFormat;
}

fn findSurfaceFormat(gc: *const GraphicsContext) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try gc.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(gc.pdev, gc.surface, alloc);
    defer alloc.free(surface_formats);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

fn findPresentMode(gc: *const GraphicsContext) !vk.PresentModeKHR {
    const present_modes = try gc.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(gc.pdev, gc.surface, alloc);
    defer alloc.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn findActualExtent(caps: vk.SurfaceCapabilitiesKHR, extent: vk.Extent2D) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) {
        return caps.current_extent;
    } else {
        return .{
            .width = std.math.clamp(extent.width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(extent.height, caps.min_image_extent.height, caps.max_image_extent.height),
        };
    }
}
