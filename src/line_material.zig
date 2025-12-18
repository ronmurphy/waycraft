const std = @import("std");
const wl = @import("wayland").server.wl;
const vk = @import("vulkan");
const vku = @import("vk_utils.zig");
const za = @import("zalgebra");
const Mat4 = za.Mat4;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Surface = @import("protocols/surface.zig").Surface;
const Geometry = @import("geometry.zig").Geometry;
const Renderer = @import("renderer.zig").Renderer;

const max_frames_in_flight = @import("renderer.zig").max_frames_in_flight;

const alloc = std.heap.c_allocator;

const vert_spv align(@alignOf(u32)) = @embedFile("line.vert.spv").*;
const frag_spv align(@alignOf(u32)) = @embedFile("line.frag.spv").*;

const PushConstants = struct {
    const range = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(PushConstants),
        .stage_flags = .{ .vertex_bit = true },
    };

    matrix: Mat4,
};

const Uniforms = struct {
    color: [4]f32,
};

const Dirt = packed struct {
    uniforms: bool = true,
};

pub const LineMaterial = struct {
    renderer: *Renderer,

    descriptor_pool: vk.DescriptorPool,
    descriptor_sets: [max_frames_in_flight]vk.DescriptorSet,
    uniforms_buf: vku.Buf,

    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

    dirt: []Dirt,

    pub fn create(renderer: *Renderer, color: [4]f32) !LineMaterial {
        const gc = &renderer.gc;

        var descriptor_pool_sizes = [_]vk.DescriptorPoolSize{
            .{ .type = .uniform_buffer, .descriptor_count = max_frames_in_flight },
        };
        const descriptor_pool = try gc.dev.createDescriptorPool(&.{
            .pool_size_count = descriptor_pool_sizes.len,
            .p_pool_sizes = @ptrCast(&descriptor_pool_sizes),
            .max_sets = @intCast(max_frames_in_flight),
        }, null);
        var descriptor_set_bindings = [_]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment_bit = true },
            },
        };
        var descriptor_set_layouts: [max_frames_in_flight]vk.DescriptorSetLayout = undefined;
        for (&descriptor_set_layouts) |*l| l.* = try gc.dev.createDescriptorSetLayout(&.{
            .binding_count = descriptor_set_bindings.len,
            .p_bindings = @ptrCast(&descriptor_set_bindings),
        }, null);
        var descriptor_sets: [max_frames_in_flight]vk.DescriptorSet = undefined;
        try gc.dev.allocateDescriptorSets(&.{
            .descriptor_pool = descriptor_pool,
            .descriptor_set_count = max_frames_in_flight,
            .p_set_layouts = &descriptor_set_layouts,
        }, &descriptor_sets);

        const uniforms = Uniforms{ .color = color };
        const uniforms_buf = try vku.Buf.create(gc, @sizeOf(Uniforms) * max_frames_in_flight, .{ .uniform_buffer_bit = true }, .{ .host_visible_bit = true, .host_coherent_bit = true });
        const uniforms_mem_mapped: [*]Uniforms = @ptrCast(@alignCast(try gc.dev.mapMemory(uniforms_buf.mem, 0, vk.WHOLE_SIZE, .{})));
        for (0..max_frames_in_flight) |i| {
            uniforms_mem_mapped[i] = uniforms;
        }
        gc.dev.unmapMemory(uniforms_buf.mem);

        const pipeline_layout = try gc.dev.createPipelineLayout(&.{
            .set_layout_count = @intCast(descriptor_set_layouts.len),
            .p_set_layouts = &descriptor_set_layouts,
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&PushConstants.range),
        }, null);
        const pipeline = try createPipeline(gc, pipeline_layout, renderer.render_pass);

        const dirt = try alloc.alloc(Dirt, max_frames_in_flight);
        @memset(dirt, .{});

        return .{
            .renderer = renderer,

            .descriptor_pool = descriptor_pool,
            .descriptor_sets = descriptor_sets,
            .uniforms_buf = uniforms_buf,

            .pipeline = pipeline,
            .pipeline_layout = pipeline_layout,

            .dirt = dirt,
        };
    }

    pub fn destroy(m: *const LineMaterial) void {
        const gc = &m.renderer.gc;

        defer gc.dev.destroyDescriptorPool(m.descriptor_pool, null);
        defer m.renderer.destroyBufAfterFrame(m.uniforms_buf);
        defer gc.dev.destroyPipelineLayout(m.pipeline_layout, null);
        defer gc.dev.destroyPipeline(m.pipeline, null);
        defer alloc.free(m.dirt);
    }

    fn createPipeline(
        gc: *const GraphicsContext,
        layout: vk.PipelineLayout,
        render_pass: vk.RenderPass,
    ) !vk.Pipeline {
        const vert = try gc.dev.createShaderModule(&.{
            .code_size = vert_spv.len,
            .p_code = @ptrCast(&vert_spv),
        }, null);
        defer gc.dev.destroyShaderModule(vert, null);

        const frag = try gc.dev.createShaderModule(&.{
            .code_size = frag_spv.len,
            .p_code = @ptrCast(&frag_spv),
        }, null);
        defer gc.dev.destroyShaderModule(frag, null);

        const pssci = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .stage = .{ .vertex_bit = true },
                .module = vert,
                .p_name = "main",
            },
            .{
                .stage = .{ .fragment_bit = true },
                .module = frag,
                .p_name = "main",
            },
        };

        const pvisci = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = 1,
            .p_vertex_binding_descriptions = @ptrCast(&Geometry.Vertex.binding_description),
            .vertex_attribute_description_count = Geometry.Vertex.attribute_description.len,
            .p_vertex_attribute_descriptions = &Geometry.Vertex.attribute_description,
        };

        const piasci = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = .line_list,
            .primitive_restart_enable = .false,
        };

        const pvsci = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .p_viewports = undefined, // set in createCommandBuffers with cmdSetViewport
            .scissor_count = 1,
            .p_scissors = undefined, // set in createCommandBuffers with cmdSetScissor
        };

        const prsci = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .line,
            .cull_mode = .{ .back_bit = true },
            .front_face = .clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0,
            .depth_bias_clamp = 0,
            .depth_bias_slope_factor = 0,
            .line_width = 4,
        };

        const pmsci = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 1,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };

        const pdssci = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = .true,
            .depth_write_enable = .true,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = .false,
            .min_depth_bounds = 0,
            .max_depth_bounds = 1,
            .stencil_test_enable = .false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
        };

        const pcbas = vk.PipelineColorBlendAttachmentState{
            .blend_enable = .false,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };

        const pcbsci = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&pcbas),
            .blend_constants = .{ 0, 0, 0, 0 },
        };

        const dynstate = [_]vk.DynamicState{ .viewport, .scissor };
        const pdsci = vk.PipelineDynamicStateCreateInfo{
            .flags = .{},
            .dynamic_state_count = dynstate.len,
            .p_dynamic_states = &dynstate,
        };

        const gpci = vk.GraphicsPipelineCreateInfo{
            .flags = .{},
            .stage_count = pssci.len,
            .p_stages = &pssci,
            .p_vertex_input_state = &pvisci,
            .p_input_assembly_state = &piasci,
            .p_tessellation_state = null,
            .p_viewport_state = &pvsci,
            .p_rasterization_state = &prsci,
            .p_multisample_state = &pmsci,
            .p_depth_stencil_state = &pdssci,
            .p_color_blend_state = &pcbsci,
            .p_dynamic_state = &pdsci,
            .layout = layout,
            .render_pass = render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try gc.dev.createGraphicsPipelines(
            .null_handle,
            1,
            @ptrCast(&gpci),
            null,
            @ptrCast(&pipeline),
        );
        return pipeline;
    }

    pub fn recordCommands(m: *LineMaterial, cmdbuf: vk.CommandBuffer, viewproj: Mat4) !void {
        const gc = &m.renderer.gc;

        try m.updateDirtyDescriptorSets();

        gc.dev.cmdBindPipeline(cmdbuf, .graphics, m.pipeline);

        const push_consts = PushConstants{ .matrix = viewproj };
        gc.dev.cmdPushConstants(cmdbuf, m.pipeline_layout, PushConstants.range.stage_flags, PushConstants.range.offset, PushConstants.range.size, &push_consts);

        const descriptor_set = m.descriptor_sets[m.renderer.frame_index];
        gc.dev.cmdBindDescriptorSets(cmdbuf, .graphics, m.pipeline_layout, 0, 1, @ptrCast(&descriptor_set), 0, null);
    }

    fn updateDirtyDescriptorSets(m: *LineMaterial) !void {
        const gc = &m.renderer.gc;

        const dirt = &m.dirt[m.renderer.frame_index];

        if (dirt.uniforms) {
            const write_uniforms_buf_info = vk.DescriptorBufferInfo{
                .buffer = m.uniforms_buf.buf,
                .offset = 0,
                .range = m.uniforms_buf.size,
            };
            const write_uniforms = vk.WriteDescriptorSet{
                .dst_set = m.descriptor_sets[m.renderer.frame_index],
                .dst_binding = 0,
                .dst_array_element = 0,
                .descriptor_type = .uniform_buffer,
                .descriptor_count = 1,
                .p_buffer_info = @ptrCast(&write_uniforms_buf_info),
                .p_image_info = &.{},
                .p_texel_buffer_view = &.{},
            };
            gc.dev.updateDescriptorSets(1, @ptrCast(&write_uniforms), 0, null);
        }

        dirt.* = .{
            .uniforms = false,
        };
    }
};
