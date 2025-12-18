const std = @import("std");
const vk = @import("vulkan");
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;

pub fn beginOneTimeCommandBuffer(gc: *const GraphicsContext) !vk.CommandBuffer {
    var cmdbuf: vk.CommandBuffer = undefined;
    try gc.dev.allocateCommandBuffers(&.{
        .command_pool = gc.cmdpool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf));

    try gc.dev.beginCommandBuffer(cmdbuf, &.{
        .flags = .{ .one_time_submit_bit = true },
    });

    return cmdbuf;
}

pub fn endOneTimeCommandBuffer(gc: *const GraphicsContext, cmdbuf: vk.CommandBuffer) !void {
    try gc.dev.endCommandBuffer(cmdbuf);

    const submit_info = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
    };
    try gc.dev.queueSubmit(gc.graphics_queue.handle, 1, @ptrCast(&submit_info), .null_handle);
    try gc.dev.queueWaitIdle(gc.graphics_queue.handle);

    gc.dev.freeCommandBuffers(gc.cmdpool, 1, @ptrCast(&cmdbuf));
}

pub const Buf = struct {
    size: vk.DeviceSize,
    buf: vk.Buffer,
    mem: vk.DeviceMemory,

    pub fn create(gc: *const GraphicsContext, size: vk.DeviceSize, usage: vk.BufferUsageFlags, mem_props: vk.MemoryPropertyFlags) !Buf {
        const buf = try gc.dev.createBuffer(&.{
            .size = size,
            .usage = usage,
            .sharing_mode = .exclusive,
        }, null);
        const mem_reqs = gc.dev.getBufferMemoryRequirements(buf);
        const mem = try gc.allocate(mem_reqs, mem_props);
        try gc.dev.bindBufferMemory(buf, mem, 0);
        return .{
            .size = size,
            .buf = buf,
            .mem = mem,
        };
    }

    pub fn destroy(buf: *const Buf, gc: *const GraphicsContext) void {
        gc.dev.destroyBuffer(buf.buf, null);
        gc.dev.freeMemory(buf.mem, null);
    }

    pub fn upload(buf: *const Buf, gc: *const GraphicsContext, data: []const u8) !void {
        const staging_buf = try create(gc, buf.size, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        defer staging_buf.destroy(gc);

        const staging_mem_mapped = try gc.dev.mapMemory(staging_buf.mem, 0, vk.WHOLE_SIZE, .{});
        @memcpy(@as([*]u8, @ptrCast(@alignCast(staging_mem_mapped))), data);
        gc.dev.unmapMemory(staging_buf.mem);

        try copyBuffer(gc, staging_buf.buf, buf.buf, buf.size);
    }
};

pub fn copyBuffer(gc: *const GraphicsContext, src: vk.Buffer, dst: vk.Buffer, size: vk.DeviceSize) !void {
    const cmdbuf = try beginOneTimeCommandBuffer(gc);

    const region = vk.BufferCopy{
        .src_offset = 0,
        .dst_offset = 0,
        .size = size,
    };
    gc.dev.cmdCopyBuffer(cmdbuf, src, dst, 1, @ptrCast(&region));

    try endOneTimeCommandBuffer(gc, cmdbuf);
}

pub const Image = struct {
    format: vk.Format,
    width: u32,
    height: u32,
    image: vk.Image,
    mem: vk.DeviceMemory,
    view: vk.ImageView,

    pub fn create(gc: *const GraphicsContext, format: vk.Format, width: u32, height: u32, tiling: vk.ImageTiling, usage: vk.ImageUsageFlags, mem_props: vk.MemoryPropertyFlags, aspect_mask: vk.ImageAspectFlags) !Image {
        const image = try gc.dev.createImage(&.{
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = tiling,
            .usage = usage,
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);

        const mem_reqs = gc.dev.getImageMemoryRequirements(image);
        const mem = try gc.allocate(mem_reqs, mem_props);
        try gc.dev.bindImageMemory(image, mem, 0);

        const view = try gc.dev.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = aspect_mask,
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);

        return .{
            .format = format,
            .width = width,
            .height = height,
            .image = image,
            .mem = mem,
            .view = view,
        };
    }

    pub fn destroy(image: *const Image, gc: *const GraphicsContext) void {
        gc.dev.destroyImageView(image.view, null);
        gc.dev.destroyImage(image.image, null);
        gc.dev.freeMemory(image.mem, null);
    }
};

fn hasStencilComponent(format: vk.Format) bool {
    return format == .d32_sfloat_s8_uint or format == .d24_unorm_s8_uint or format == .d16_unorm_s8_uint;
}

pub fn transitionImageLayout(gc: *const GraphicsContext, from: vk.ImageLayout, to: vk.ImageLayout, image: vk.Image, image_format: vk.Format) !void {
    const cmdbuf = try beginOneTimeCommandBuffer(gc);

    var barrier = vk.ImageMemoryBarrier{
        .old_layout = from,
        .new_layout = to,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = .{
            .aspect_mask = undefined,
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .src_access_mask = undefined,
        .dst_access_mask = undefined,
    };

    if (to == .depth_stencil_attachment_optimal) {
        barrier.subresource_range.aspect_mask = .{ .depth_bit = true };
        if (hasStencilComponent(image_format)) {
            barrier.subresource_range.aspect_mask.stencil_bit = true;
        }
    } else {
        barrier.subresource_range.aspect_mask = .{ .color_bit = true };
    }

    var src_stage: vk.PipelineStageFlags = undefined;
    var dst_stage: vk.PipelineStageFlags = undefined;
    if (from == .undefined and to == .transfer_dst_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .transfer_write_bit = true };

        src_stage = .{ .top_of_pipe_bit = true };
        dst_stage = .{ .transfer_bit = true };
    } else if (from == .transfer_dst_optimal and to == .shader_read_only_optimal) {
        barrier.src_access_mask = .{ .transfer_write_bit = true };
        barrier.dst_access_mask = .{ .shader_read_bit = true };

        src_stage = .{ .transfer_bit = true };
        dst_stage = .{ .fragment_shader_bit = true };
    } else if (from == .undefined and to == .depth_stencil_attachment_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .depth_stencil_attachment_read_bit = true, .depth_stencil_attachment_write_bit = true };

        src_stage = .{ .top_of_pipe_bit = true };
        dst_stage = .{ .early_fragment_tests_bit = true };
    } else if (from == .undefined and to == .transfer_src_optimal) {
        barrier.src_access_mask = .{};
        barrier.dst_access_mask = .{ .transfer_read_bit = true };

        src_stage = .{ .top_of_pipe_bit = true };
        dst_stage = .{ .transfer_bit = true };
    } else {
        return error.UnsupportedLayoutTransition;
    }

    gc.dev.cmdPipelineBarrier(cmdbuf, src_stage, dst_stage, .{}, 0, null, 0, null, 1, @ptrCast(&barrier));

    try endOneTimeCommandBuffer(gc, cmdbuf);
}

pub fn copyDataToImage(gc: *const GraphicsContext, src: []const u8, dst: *const Image) !void {
    const staging_buf = try Buf.create(gc, src.len, .{ .transfer_src_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
    defer staging_buf.destroy(gc);

    const staging_mem_mapped = try gc.dev.mapMemory(staging_buf.mem, 0, vk.WHOLE_SIZE, .{});
    @memcpy(@as([*]u8, @ptrCast(@alignCast(staging_mem_mapped))), src);
    gc.dev.unmapMemory(staging_buf.mem);

    try transitionImageLayout(gc, .undefined, .transfer_dst_optimal, dst.image, dst.format);
    try copyBufferToImage(gc, staging_buf.buf, dst);
    try transitionImageLayout(gc, .transfer_dst_optimal, .shader_read_only_optimal, dst.image, dst.format);
}

pub fn copyBufferToImage(gc: *const GraphicsContext, src: vk.Buffer, dst: *const Image) !void {
    const cmdbuf = try beginOneTimeCommandBuffer(gc);

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = dst.width, .height = dst.height, .depth = 1 },
    };
    gc.dev.cmdCopyBufferToImage(cmdbuf, src, dst.image, .transfer_dst_optimal, 1, @ptrCast(&region));

    try endOneTimeCommandBuffer(gc, cmdbuf);
}

pub fn copyImageToBuffer(gc: *const GraphicsContext, cmdpool: vk.CommandPool, src: vk.Image, dst: vk.Buffer, width: u32, height: u32) !void {
    const cmdbuf = try beginOneTimeCommandBuffer(gc, cmdpool);

    const region = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    gc.dev.cmdCopyImageToBuffer(cmdbuf, src, .transfer_src_optimal, dst, 1, @ptrCast(&region));

    try endOneTimeCommandBuffer(gc, cmdpool, cmdbuf);
}
