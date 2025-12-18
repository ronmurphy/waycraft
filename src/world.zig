const std = @import("std");
const xkb = @import("xkbcommon");
const za = @import("zalgebra");
const vk = @import("vulkan");
const vku = @import("vk_utils.zig");
const img = @import("zigimg");
const wls = @import("wayland").server.wl;
const wc_seat = @import("protocols/seat.zig");
const Vec2 = za.Vec2;
const Vec3 = za.Vec3;
const Mat4 = za.Mat4;
const ChunkPos = za.Vec2_i32;
const BlockPos = za.Vec3_i32;
const Cam = @import("camera.zig").Camera;
const CamController = @import("cam_controller.zig").CamController;
const Chunk = @import("chunk.zig").Chunk;
const Block = @import("chunk.zig").Block;
const Geometry = @import("geometry.zig").Geometry;
const SimpleMaterial = @import("simple_material.zig").SimpleMaterial;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Renderer = @import("renderer.zig").Renderer;
const Toplevel = @import("protocols/toplevel.zig").Toplevel;
const ToplevelRenderable = @import("toplevel_renderable.zig").ToplevelRenderable;

const alloc = std.heap.c_allocator;

pub const Ray = struct {
    p0: Vec3,
    dir: Vec3,
};

pub const Box = struct {
    min: Vec3,
    max: Vec3,

    pub fn size(a: Box) Vec3 {
        return a.max.sub(a.min);
    }

    pub fn getOverlapWith(a: Box, b: Box) Vec3 {
        const start = a.min.max(b.min);
        const end = a.max.min(b.max);
        return end.sub(start);
    }

    test getOverlapWith {
        std.debug.assert(getOverlapWith(
            .{ .min = .new(0, 0, 0), .max = .new(3, 3, 3) },
            .{ .min = .new(2, 1, 2.5), .max = .new(7, 6, 6) },
        ).eql(.new(1, 2, 0.5)));
    }
};

pub const WindowSpec = struct {
    width: u32 = 1,
    height: u32 = 1,
    render_sides: u32 = 2, // 1 = single-sided, 2 = two-sided (default)
    // Future: rotation: f32, face: u8, position: Vec3, etc.
};

// Parse command with flags like "gimp 3w 2h" into command and WindowSpec
fn parseCommand(input: []const u8, cmd_buf: []u8) struct { cmd: []const u8, spec: WindowSpec } {
    var spec = WindowSpec{};
    var cmd_len: usize = 0;

    var iter = std.mem.tokenizeScalar(u8, input, ' ');
    while (iter.next()) |token| {
        if (token.len == 0) continue;

        // Check if this is a flag (ends with w, h, or r)
        const last_char = token[token.len - 1];
        if (last_char == 'w' or last_char == 'h' or last_char == 'r') {
            // Try to parse the number before the flag
            const num_str = token[0..token.len-1];
            const num = std.fmt.parseInt(u32, num_str, 10) catch {
                // Not a valid number+flag, treat as command
                if (cmd_len > 0) {
                    cmd_buf[cmd_len] = ' ';
                    cmd_len += 1;
                }
                @memcpy(cmd_buf[cmd_len..cmd_len + token.len], token);
                cmd_len += token.len;
                continue;
            };

            // Valid flag, apply it
            if (last_char == 'w') {
                spec.width = num;
            } else if (last_char == 'h') {
                spec.height = num;
            } else if (last_char == 'r') {
                spec.render_sides = num;
            }
        } else {
            // Regular command part
            if (cmd_len > 0) {
                cmd_buf[cmd_len] = ' ';
                cmd_len += 1;
            }
            @memcpy(cmd_buf[cmd_len..cmd_len + token.len], token);
            cmd_len += token.len;
        }
    }

    return .{ .cmd = cmd_buf[0..cmd_len], .spec = spec };
}

// https://tavianator.com/2011/ray_box.html
pub fn rayIntersectsBox(r: Ray, b: Box, out_distance: *f32) bool {
    const eps = std.math.floatEps(f32);
    const inv_dir = Vec3.new(
        1 / r.dir.x() + eps,
        1 / r.dir.y() + eps,
        1 / r.dir.z() + eps,
    );

    const tx1 = (b.min.x() - r.p0.x()) * inv_dir.x();
    const tx2 = (b.max.x() - r.p0.x()) * inv_dir.x();
    var tmin = @min(tx1, tx2);
    var tmax = @max(tx1, tx2);

    const ty1 = (b.min.y() - r.p0.y()) * inv_dir.y();
    const ty2 = (b.max.y() - r.p0.y()) * inv_dir.y();
    tmin = @max(tmin, @min(ty1, ty2));
    tmax = @min(tmax, @max(ty1, ty2));

    const tz1 = (b.min.z() - r.p0.z()) * inv_dir.z();
    const tz2 = (b.max.z() - r.p0.z()) * inv_dir.z();
    tmin = @max(tmin, @min(tz1, tz2));
    tmax = @min(tmax, @max(tz1, tz2));

    out_distance.* = tmin;
    return tmax >= 0 and tmax >= tmin;
}

fn boxIntersectsBox(a: Box, b: Box) bool {
    return a.min.x() <= b.max.x() and
        a.max.x() >= b.min.x() and
        a.min.y() <= b.max.y() and
        a.max.y() >= b.min.y() and
        a.min.z() <= b.max.z() and
        a.max.z() >= b.min.z();
}

pub const World = struct {
    cam: Cam,
    cam_controller: CamController,
    cam_look_distance: u8 = 4,

    seed: Vec2,
    chunks: std.AutoHashMap(ChunkPos, *Chunk),
    toplevel_renderables: std.ArrayList(*ToplevelRenderable),

    active_toplevel: ?*const Toplevel,
    active_toplevel_changed_event: wls.Signal(void),
    active_toplevel_destroyed_listener: wls.Listener(void),

    is_entering_cmd: bool,
    cmd_chars: std.ArrayList(u8),
    child_processes: std.ArrayList(std.process.Child),
    next_window_spec: ?WindowSpec,

    blocks_material: ?SimpleMaterial,
    char_geometry: std.AutoHashMap(u8, Geometry),
    font_material: ?SimpleMaterial,

    is_raycast_dirty: bool = false,
    raycast_result: ?RaycastResult = null,

    pub fn init(world: *World) !void {
        world.* = .{
            .cam = .new(),
            .cam_controller = .new(&world.cam),

            .seed = Vec2.zero(),
            .chunks = .init(alloc),
            .toplevel_renderables = try .initCapacity(alloc, 4),

            .is_entering_cmd = false,
            .cmd_chars = try .initCapacity(alloc, 16),
            .child_processes = try .initCapacity(alloc, 4),
            .next_window_spec = null,

            .active_toplevel = null,
            .active_toplevel_changed_event = undefined,
            .active_toplevel_destroyed_listener = .init(activeToplevelDestroyed),

            .blocks_material = null,
            .char_geometry = .init(alloc),
            .font_material = null,
        };
        world.active_toplevel_changed_event.init();

        _ = try world.getChunksAroundCamera();

        const chunk = world.chunkAt(.new(0, 0)).?;
        var cam_y: f32 = 0;
        for (0..Chunk.y_size) |y| {
            if (chunk.atLocal(.new(0, @intCast(y), 0)) == .air) {
                cam_y = @floatFromInt(y + 2);
                break;
            }
        }
        world.cam.transform = world.cam.transform.translate(Vec3.new(0, cam_y, 0));
        world.cam.updateProjView();
    }

    pub fn update(world: *World, dt: f32) !void {
        world.cam_controller.update(world, dt);
    }

    pub fn getChunksAroundCamera(world: *World) ![16]*Chunk {
        const cam_chunk_pos = posToChunkPos(world.cam.transform.extractTranslation());

        var chunks: [16]*Chunk = undefined;

        var i: usize = 0;

        var z: i32 = -2;
        while (z < 2) : (z += 1) {
            var x: i32 = -2;
            while (x < 2) : (x += 1) {
                const chunk_pos = ChunkPos.new(cam_chunk_pos.x() + x * Chunk.x_size, cam_chunk_pos.y() + z * Chunk.z_size);
                chunks[i] = try world.getOrGenerateChunkAt(chunk_pos);
                i += 1;
            }
        }

        return chunks;
    }

    const RaycastResult = struct {
        dist: f32,
        block_pos: BlockPos,
    };
    pub fn raycast(world: *World, ray: Ray, max_dist: f32) ?RaycastResult {
        var closest_block: ?BlockPos = null;
        var min_dist: f32 = max_dist;

        const max_dist_with_padding: i32 = @intFromFloat(max_dist + 1);
        const ray_pos = ray.p0;
        const ray_block_pos = posToBlockPos(ray_pos);

        var y = -max_dist_with_padding;
        while (y < max_dist_with_padding) : (y += 1) {
            var z = -max_dist_with_padding;
            while (z < max_dist_with_padding) : (z += 1) {
                var x = -max_dist_with_padding;
                while (x < max_dist_with_padding) : (x += 1) {
                    const block_pos = BlockPos.new(x, y, z).add(ray_block_pos);
                    const block = world.at(block_pos);
                    if (block != .not_generated and block != .air) {
                        const block_pos_f32 = block_pos.cast(f32);
                        var dist: f32 = undefined;

                        // For toplevel windows, use their actual dimensions instead of 1×1×1
                        const block_box = if (block == .toplevel) blk: {
                            const tr = block.toplevel;
                            // Convert pixel dimensions back to block dimensions (1 block = 1024 pixels)
                            const pixels_per_block: f32 = 1024.0;
                            const w = @as(f32, @floatFromInt(tr.toplevel.width)) / pixels_per_block;
                            const h = @as(f32, @floatFromInt(tr.toplevel.height)) / pixels_per_block;
                            break :blk Box{
                                .min = block_pos_f32,
                                .max = block_pos_f32.add(Vec3.new(w, h, 0.1))
                            };
                        } else blk: {
                            break :blk Box{
                                .min = block_pos_f32,
                                .max = block_pos_f32.add(Vec3.one())
                            };
                        };

                        if (rayIntersectsBox(ray, block_box, &dist) and dist < min_dist) {
                            closest_block = block_pos;
                            min_dist = dist;
                        }
                    }
                }
            }
        }

        if (closest_block) |block_pos| {
            return .{
                .dist = min_dist,
                .block_pos = block_pos,
            };
        }
        return null;
    }

    pub fn collides(world: *World, box: Box) ?Box {
        const min_block_pos = posToBlockPos(box.min).sub(.set(1));
        const max_block_pos = posToBlockPos(box.max).add(.set(1));

        var y = min_block_pos.y();
        while (y < max_block_pos.y()) : (y += 1) {
            var z = min_block_pos.z();
            while (z < max_block_pos.z()) : (z += 1) {
                var x = min_block_pos.x();
                while (x < max_block_pos.x()) : (x += 1) {
                    const block_pos = BlockPos.new(x, y, z);
                    const block = world.at(block_pos);
                    if (block != .not_generated and block != .air) {
                        const block_pos_f32 = block_pos.cast(f32);
                        const block_box = Box{
                            .min = block_pos_f32,
                            .max = block_pos_f32.add(.set(1)),
                        };
                        if (boxIntersectsBox(block_box, box))
                            return block_box;
                    }
                }
            }
        }

        return null;
    }

    pub fn pointerMoved(world: *World, dx: f64, dy: f64) void {
        world.is_raycast_dirty = true;

        if (world.active_toplevel) |active_toplevel| {
            const client = active_toplevel.resource.getClient();
            if (wc_seat.getPointerForClient(client)) |pointer| {
                if (world.raycast_result) |raycast_result| {
                    const cam_pos = world.cam.transform.extractTranslation();
                    const cam_forward = Vec3.fromSlice(&world.cam.transform.data[2]);
                    const hit_pos = cam_pos.add(cam_forward.mul(.set(raycast_result.dist)));
                    const rel_hit_pos = hit_pos.sub(raycast_result.block_pos.cast(f32));
                    const surface_x = rel_hit_pos.x() * @as(f32, @floatFromInt(active_toplevel.width));
                    const surface_y = (1 - rel_hit_pos.y()) * @as(f32, @floatFromInt(active_toplevel.height));
                    const t = std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME) catch {
                        std.log.err("Error getting timestamp???", .{});
                        return;
                    };
                    pointer.sendMotion(@intCast(@divFloor(t.nsec, std.time.ns_per_ms)), wls.Fixed.fromDouble(surface_x), wls.Fixed.fromDouble(surface_y));
                    pointer.sendFrame();
                }
            }
        }

        const deltax: f32 = @floatCast(dx);
        const deltay: f32 = @floatCast(dy);

        world.cam_controller.pointerMoved(deltax, deltay);
    }

    pub fn pointerPressed(world: *World, button: u32) void {
        if (world.active_toplevel) |active_toplevel| {
            const client = active_toplevel.resource.getClient();
            if (wc_seat.getPointerForClient(client)) |pointer| {
                const t = std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME) catch {
                    std.log.err("Error getting timestamp???", .{});
                    return;
                };
                pointer.sendButton(client.getDisplay().nextSerial(), @intCast(@divFloor(t.nsec, std.time.ns_per_ms)), button, .pressed);
                pointer.sendFrame();
            }
            return;
        }

        // https://github.com/torvalds/linux/blob/master/include/uapi/linux/input-event-codes.h#L357
        if (button == 0x110) { // Left
            if (world.raycast_result) |raycast_result| {
                const look_at_block = world.at(raycast_result.block_pos);
                switch (look_at_block) {
                    .air => {},
                    .toplevel => |toplevel| {
                        toplevel.toplevel.resource.sendClose();
                    },
                    else => {
                        world.setAt(raycast_result.block_pos, .air) catch {
                            std.log.err("OOM", .{});
                            return;
                        };
                    },
                }
            }
        } else if (button == 0x111) { // Right
            if (world.raycast_result) |raycast_result| {
                const look_at_block = world.at(raycast_result.block_pos);
                switch (look_at_block) {
                    .toplevel => |toplevel| {
                        world.active_toplevel = toplevel.toplevel;
                        world.active_toplevel_changed_event.emit();
                        toplevel.toplevel.events.destroyed.add(&world.active_toplevel_destroyed_listener);
                    },
                    else => {},
                }
            }
        }
    }

    pub fn pointerReleased(world: *World, button: u32) void {
        if (world.active_toplevel) |active_toplevel| {
            const client = active_toplevel.resource.getClient();
            if (wc_seat.getPointerForClient(client)) |pointer| {
                const t = std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME) catch {
                    std.log.err("Error getting timestamp???", .{});
                    return;
                };
                pointer.sendButton(client.getDisplay().nextSerial(), @intCast(@divFloor(t.nsec, std.time.ns_per_ms)), button, .released);
                pointer.sendFrame();
            }
            return;
        }
    }

    pub fn keyPressed(world: *World, key: xkb.Keysym) void {
        // Snap to grid - press G to align active window to nearest block
        if ((key == xkb.Keysym.g or key == xkb.Keysym.G) and !world.is_entering_cmd) {
            if (world.active_toplevel) |active_toplevel| {
                // Find the ToplevelRenderable for this window
                for (world.toplevel_renderables.items) |tr| {
                    if (tr.toplevel == active_toplevel) {
                        // Get current position from transform
                        const current_pos = tr.transform.extractTranslation();

                        // Round to nearest integer block coordinates
                        const snapped_pos = Vec3.new(
                            @round(current_pos.x()),
                            @round(current_pos.y()),
                            @round(current_pos.z())
                        );

                        // Update transform with snapped position
                        tr.transform = Mat4.fromTranslate(snapped_pos);

                        // Update the block in the world to the new position
                        const old_block_pos = posToBlockPos(current_pos);
                        const new_block_pos = posToBlockPos(snapped_pos);

                        if (!old_block_pos.eql(new_block_pos)) {
                            world.setAt(old_block_pos, .air) catch {};
                            world.setAt(new_block_pos, .{ .toplevel = tr }) catch {};
                        }

                        break;
                    }
                }
            }
        }

        if (key == xkb.Keysym.slash) {
            world.is_entering_cmd = true;
        }
        if (world.is_entering_cmd) {
            if (key == xkb.Keysym.BackSpace) {
                if (world.cmd_chars.items.len == 1)
                    world.is_entering_cmd = false;
                _ = world.cmd_chars.pop();
            } else if (key == xkb.Keysym.Return) {
                const input = world.cmd_chars.items[1..];

                // Parse command and extract window spec
                var cmd_buf: [256]u8 = undefined;
                const parsed = parseCommand(input, &cmd_buf);

                // Store the spec for the next window that spawns
                world.next_window_spec = parsed.spec;

                // Execute the actual command (without flags)
                var proc = std.process.Child.init(&.{ "sh", "-c", parsed.cmd }, alloc);
                proc.spawn() catch |err| {
                    std.log.err("Error spawning child process: {s}", .{@errorName(err)});
                    world.next_window_spec = null; // Clear spec on failure
                    return;
                };
                world.child_processes.append(alloc, proc) catch {
                    std.log.err("OOM", .{});
                    return;
                };
                world.is_entering_cmd = false;
                world.cmd_chars.clearRetainingCapacity();
            } else {
                var key_buf: [8]u8 = undefined;
                if (key.toUTF8(&key_buf, key_buf.len) > 0) world.cmd_chars.append(alloc, key_buf[0]) catch {
                    std.log.err("OOM", .{});
                    return;
                };
            }
            return;
        }

        world.cam_controller.keyPressed(key);
    }

    pub fn keyReleased(world: *World, key: xkb.Keysym) void {
        world.cam_controller.keyReleased(key);
    }

    pub fn keyReleasedAll(world: *World) void {
        world.cam_controller.keyReleasedAll();
    }

    fn activeToplevelDestroyed(listener: *wls.Listener(void)) void {
        const world: *World = @alignCast(@fieldParentPtr("active_toplevel_destroyed_listener", listener));
        listener.link.remove();
        world.active_toplevel = null;
        world.active_toplevel_changed_event.emit();
    }

    pub fn render(world: *World, renderer: *Renderer, cmdbuf: vk.CommandBuffer) !void {
        if (world.is_raycast_dirty) {
            const cam_pos = world.cam.transform.extractTranslation();
            const cam_forward = Vec3.fromSlice(&world.cam.transform.data[2]);
            const ray = Ray{ .p0 = cam_pos, .dir = cam_forward };
            world.raycast_result = world.raycast(ray, @floatFromInt(world.cam_look_distance));
            world.is_raycast_dirty = false;
        }

        const gc = &renderer.gc;

        // Ensure the blocks material exists
        if (world.blocks_material == null) {
            @branchHint(.unlikely);
            var image_read_buffer: [img.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
            const blocks_image = try img.Image.fromFilePath(alloc, "blocks.png", &image_read_buffer);
            const blocks_image_vk = try vku.Image.create(
                &renderer.gc,
                .r8g8b8a8_srgb,
                @intCast(blocks_image.width),
                @intCast(blocks_image.height),
                .optimal,
                .{ .sampled_bit = true, .transfer_dst_bit = true },
                .{ .device_local_bit = true },
                .{ .color_bit = true },
            );
            try vku.copyDataToImage(&renderer.gc, @ptrCast(@alignCast(blocks_image.pixels.rgba32)), &blocks_image_vk);
            world.blocks_material = try .createFromImage(renderer, blocks_image_vk);
        }
        const blocks_material = &world.blocks_material.?;

        // Ensure the font material exists
        if (world.font_material == null) {
            @branchHint(.unlikely);
            var image_read_buffer: [img.io.DEFAULT_BUFFER_SIZE]u8 = undefined;
            const font_image = try img.Image.fromFilePath(alloc, "font.png", &image_read_buffer);
            const font_image_vk = try vku.Image.create(
                &renderer.gc,
                .r8g8b8a8_srgb,
                @intCast(font_image.width),
                @intCast(font_image.height),
                .optimal,
                .{ .sampled_bit = true, .transfer_dst_bit = true },
                .{ .device_local_bit = true },
                .{ .color_bit = true },
            );
            try vku.copyDataToImage(&renderer.gc, @ptrCast(@alignCast(font_image.pixels.rgba32)), &font_image_vk);
            world.font_material = try .createFromImage(renderer, font_image_vk);
        }

        // Render the normal blocks
        try blocks_material.recordCommands(cmdbuf, world.cam.projview);
        for (try world.getChunksAroundCamera()) |chunk| {
            const geometry = try chunk.getGeometry(world, renderer);
            gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&geometry.vert_buf.?.buf), &.{0});
            gc.dev.cmdBindIndexBuffer(cmdbuf, geometry.index_buf.?.buf, 0, .uint32);
            gc.dev.cmdDrawIndexed(cmdbuf, @intCast(geometry.indices.len), 1, 0, 0, 0);
        }

        // Tell all of the toplevels that they can render a new frame
        for (world.toplevel_renderables.items) |tr| {
            if (tr.is_destroyed == false) {
                var frame_callbacks_iter = tr.toplevel.xdg_surface.surface.state.frame_callbacks.safeIterator(.forward);
                while (frame_callbacks_iter.next()) |frame_callback| {
                    const t = std.posix.clock_gettime(std.posix.CLOCK.BOOTTIME) catch {
                        std.log.err("Error getting timestamp???", .{});
                        return;
                    };
                    frame_callback.destroySendDone(@intCast(@divFloor(t.nsec, std.time.ns_per_ms)));
                    frame_callback.getLink().remove();
                }
            }
        }

        // Render the toplevels
        var i: usize = 0;
        for (world.toplevel_renderables.items) |tr| {
            if (tr.is_destroyed == false) {
                world.toplevel_renderables.items[i] = tr;
                i += 1;
                try tr.render(gc, cmdbuf, world);
            } else {
                try world.setAt(tr.transform.extractTranslation().cast(i32), .air);
            }
        }
        world.toplevel_renderables.items.len = i;

        // Render the text
        if (world.char_geometry.unmanaged.size == 0) {
            @branchHint(.unlikely);
            const chars = [_]u8{ 'A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z', 'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z', '1', '2', '3', '4', '5', '6', '7', '8', '9', '+', '-', '=', '(', ')', '[', ']', '{', '}', '<', '>', '/', '*', ':', '#', '%', '!', '?', '.', ',', '\'', '"', '@', '&', '$' };
            for (chars) |ch| {
                const ch_geom = try createGeomForChar(renderer, ch);
                try world.char_geometry.put(ch, ch_geom.?);
            }
        }
        if (world.cmd_chars.items.len > 0) {
            try world.font_material.?.recordCommandsNoTransform(cmdbuf);
        }
        var x: f32 = 0;
        for (world.cmd_chars.items) |ch| {
            const ch_transform = Mat4{
                .data = .{
                    .{ 1, 0, 0, 0 },
                    .{ 0, world.cam.aspect, 0, 0 },
                    .{ 0, 0, 1, 0 },
                    .{ x, 0, 0, 1 },
                },
            };
            try world.font_material.?.pushTransform(cmdbuf, ch_transform);

            const geom = world.char_geometry.get(ch) orelse world.char_geometry.get('?').?;
            gc.dev.cmdBindVertexBuffers(cmdbuf, 0, 1, @ptrCast(&geom.vert_buf.?.buf), &.{0});
            gc.dev.cmdBindIndexBuffer(cmdbuf, geom.index_buf.?.buf, 0, .uint32);
            gc.dev.cmdDrawIndexed(cmdbuf, @intCast(geom.indices.len), 1, 0, 0, 0);

            x += font_size_x;
        }
    }

    pub fn createToplevelBlock(world: *World, toplevel: *Toplevel, renderer: *Renderer) !void {
        const cam_pos = world.cam.transform.extractTranslation();
        const cam_forward = Vec3.fromSlice(&world.cam.transform.data[2]);
        const toplevel_pos = posToBlockPos(cam_pos.add(cam_forward));

        // Use pending window spec if available, otherwise default to 1x1
        const spec = world.next_window_spec orelse WindowSpec{};
        world.next_window_spec = null; // Clear after using

        const renderable = ToplevelRenderable.init(toplevel, renderer, spec.width, spec.height, spec.render_sides) catch |err| {
            std.log.err("Error creating toplevel renderable: {s}", .{@errorName(err)});
            return;
        };
        renderable.transform = .fromTranslate(toplevel_pos.cast(f32));
        try world.toplevel_renderables.append(alloc, renderable);

        try world.setAt(toplevel_pos, .{ .toplevel = renderable });
    }

    pub fn posToBlockPos(pos: Vec3) BlockPos {
        return .new(
            @intFromFloat(@floor(pos.x())),
            @intFromFloat(@floor(pos.y())),
            @intFromFloat(@floor(pos.z())),
        );
    }
    pub fn blockPosToChunkPos(pos: BlockPos) ChunkPos {
        return .new(
            @divFloor(pos.x(), Chunk.x_size) * Chunk.x_size,
            @divFloor(pos.z(), Chunk.z_size) * Chunk.z_size,
        );
    }
    pub fn posToChunkPos(pos: Vec3) ChunkPos {
        return blockPosToChunkPos(posToBlockPos(pos));
    }

    pub fn getOrGenerateChunkAt(world: *World, pos: ChunkPos) !*Chunk {
        if (world.chunkAt(pos)) |chunk| {
            return chunk;
        }
        try world.chunks.put(pos, try Chunk.init(world.seed, pos));
        return world.chunkAt(pos).?;
    }

    pub fn chunkAt(world: *const World, pos: ChunkPos) ?*Chunk {
        return world.chunks.get(pos);
    }

    pub fn at(world: *const World, pos: BlockPos) Block {
        if (pos.y() < 0 or pos.y() > Chunk.y_size - 1) {
            return .not_generated;
        }
        if (world.chunkAt(blockPosToChunkPos(pos))) |chunk| {
            return chunk.at(pos);
        }
        return .not_generated;
    }

    pub fn setAt(world: *World, pos: BlockPos, block: Block) !void {
        const chunk = try world.getOrGenerateChunkAt(blockPosToChunkPos(pos));
        chunk.setAt(pos, block);
    }

    const font_size_x: f32 = 0.06;
    const font_size_y: f32 = 0.1;
    fn createGeomForChar(r: *Renderer, ch: u8) !?Geometry {
        // zig fmt: off
        const ch_pos: [2]f32 = switch (ch) {
            'A' => .{ 0, 0 }, 'a' => .{ 0, 2 },
            'B' => .{ 1, 0 }, 'b' => .{ 1, 2 },
            'C' => .{ 2, 0 }, 'c' => .{ 2, 2 },
            'D' => .{ 3, 0 }, 'd' => .{ 3, 2 },
            'E' => .{ 4, 0 }, 'e' => .{ 4, 2 },
            'F' => .{ 5, 0 }, 'f' => .{ 5, 2 },
            'G' => .{ 6, 0 }, 'g' => .{ 6, 2 },
            'H' => .{ 7, 0 }, 'h' => .{ 7, 2 },
            'I' => .{ 8, 0 }, 'i' => .{ 8, 2 },
            'J' => .{ 9, 0 }, 'j' => .{ 9, 2 },
            'K' => .{ 10, 0 }, 'k' => .{ 10, 2 },
            'L' => .{ 11, 0 }, 'l' => .{ 11, 2 },
            'M' => .{ 12, 0 }, 'm' => .{ 12, 2 },
            'N' => .{ 0, 1 }, 'n' => .{ 0, 3 },
            'O' => .{ 1, 1 }, 'o' => .{ 1, 3 },
            'P' => .{ 2, 1 }, 'p' => .{ 2, 3 },
            'Q' => .{ 3, 1 }, 'q' => .{ 3, 3 },
            'R' => .{ 4, 1 }, 'r' => .{ 4, 3 },
            'S' => .{ 5, 1 }, 's' => .{ 5, 3 },
            'T' => .{ 6, 1 }, 't' => .{ 6, 3 },
            'U' => .{ 7, 1 }, 'u' => .{ 7, 3 },
            'V' => .{ 8, 1 }, 'v' => .{ 8, 3 },
            'W' => .{ 9, 1 }, 'w' => .{ 9, 3 },
            'X' => .{ 10, 1 }, 'x' => .{ 10, 3 },
            'Y' => .{ 11, 1 }, 'y' => .{ 11, 3 },
            'Z' => .{ 12, 1 }, 'z' => .{ 12, 3 },
            '0' => .{ 0, 4 },
            '1' => .{ 1, 4 },
            '2' => .{ 2, 4 },
            '3' => .{ 3, 4 },
            '4' => .{ 4, 4 },
            '5' => .{ 5, 4 },
            '6' => .{ 6, 4 },
            '7' => .{ 7, 4 },
            '8' => .{ 8, 4 },
            '9' => .{ 9, 4 },
            '+' => .{ 10, 4 },
            '-' => .{ 11, 4 },
            '=' => .{ 12, 4 },
            '(' => .{ 0, 5 }, ')' => .{ 1, 5 },
            '[' => .{ 2, 5 }, ']' => .{ 3, 5 },
            '{' => .{ 4, 5 }, '}' => .{ 5, 5 },
            '<' => .{ 6, 5 }, '>' => .{ 7, 5 },
            '/' => .{ 8, 5 },
            '*' => .{ 9, 5 },
            ':' => .{ 10, 5 },
            '#' => .{ 11, 5 },
            '%' => .{ 12, 5 },
            '!' => .{ 0, 6 },
            '?' => .{ 1, 6 },
            '.' => .{ 2, 6 },
            ',' => .{ 3, 6 },
            '\'' => .{ 4, 6 },
            '"' => .{ 5, 6 },
            '@' => .{ 6, 6 },
            '&' => .{ 7, 6 },
            '$' => .{ 8, 6 },
            else => return null,
        };
        // zig fmt: on
        const tc1 = [2]f32{ ch_pos[0] / 13, ch_pos[1] / 7 };
        const tc2 = [2]f32{ (ch_pos[0] + 1) / 13, ch_pos[1] / 7 };
        const tc3 = [2]f32{ (ch_pos[0] + 1) / 13, (ch_pos[1] + 1) / 7 };
        const tc4 = [2]f32{ ch_pos[0] / 13, (ch_pos[1] + 1) / 7 };
        const vertices = try alloc.alloc(Geometry.Vertex, 4);
        @memcpy(vertices, &[_]Geometry.Vertex{
            .{ .pos = .{ 0, 0, 0 }, .tex_coord = tc1 },
            .{ .pos = .{ font_size_x, 0, 0 }, .tex_coord = tc2 },
            .{ .pos = .{ font_size_x, font_size_y, 0 }, .tex_coord = tc3 },
            .{ .pos = .{ 0, font_size_y, 0 }, .tex_coord = tc4 },
        });
        const indices = try alloc.alloc(u32, 6);
        @memcpy(indices, &[_]u32{ 0, 1, 2, 2, 3, 0 });
        return try .fromVertsAndIndices(r, vertices, indices);
    }
};
