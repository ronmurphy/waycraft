const std = @import("std");
const perlin = @import("perlin");
const vk = @import("vulkan");
const za = @import("zalgebra");
const Vec2 = za.Vec2;
const ChunkPos = za.Vec2_i32;
const BlockPos = za.Vec3_i32;
const World = @import("world.zig").World;
const Geometry = @import("geometry.zig").Geometry;
const SimpleMaterial = @import("simple_material.zig").SimpleMaterial;
const GraphicsContext = @import("graphics_context.zig").GraphicsContext;
const Renderer = @import("renderer.zig").Renderer;
const ToplevelRenderable = @import("toplevel_renderable.zig").ToplevelRenderable;

const alloc = std.heap.c_allocator;

pub const Block = union(enum) {
    not_generated: void,
    air: void,
    grass: void,
    toplevel: *ToplevelRenderable,
};

pub const Chunk = struct {
    pub const x_size: u16 = 16;
    pub const z_size: u16 = 16;
    pub const y_size: u16 = 16;
    pub const size: u16 = x_size * z_size * y_size;

    const base_height: u16 = 8;

    pos: ChunkPos,
    blocks: []Block,

    geometry: ?Geometry = null,
    is_geometry_dirty: bool = false,

    pub fn init(seed: Vec2, pos: ChunkPos) !*Chunk {
        var blocks = try alloc.alloc(Block, size);

        var z: u16 = 0;
        while (z < z_size) : (z += 1) {
            var x: u16 = 0;
            while (x < x_size) : (x += 1) {
                const noise_x = (seed.x() + @as(f32, @floatFromInt(pos.x() + x))) / 12;
                const noise_z = (seed.y() + @as(f32, @floatFromInt(pos.y() + z))) / 6;
                const noise = perlin.noise(f32, perlin.permutation, .{ .x = noise_x, .y = 0, .z = noise_z }) + 1;
                const height = base_height + @as(u16, @intFromFloat(noise * 3));
                var y: u16 = 0;
                while (y < height) : (y += 1) {
                    blocks[i(.new(x, y, z))] = .grass;
                }
                while (y < y_size) : (y += 1) {
                    blocks[i(.new(x, y, z))] = .air;
                }
            }
        }

        const chunk = try alloc.create(Chunk);
        chunk.* = .{
            .pos = pos,
            .blocks = blocks,
        };
        return chunk;
    }

    pub fn at(chunk: *const Chunk, pos: BlockPos) Block {
        return chunk.atLocal(.new(
            pos.x() - chunk.pos.x(),
            pos.y(),
            pos.z() - chunk.pos.y(),
        ));
    }
    pub fn atLocal(chunk: *const Chunk, pos: BlockPos) Block {
        return chunk.blocks[i(pos)];
    }

    pub fn setAt(chunk: *Chunk, pos: BlockPos, block: Block) void {
        chunk.setAtLocal(
            .new(
                pos.x() - chunk.pos.x(),
                pos.y(),
                pos.z() - chunk.pos.y(),
            ),
            block,
        );
    }
    pub fn setAtLocal(chunk: *Chunk, pos: BlockPos, block: Block) void {
        chunk.blocks[i(pos)] = block;
        chunk.is_geometry_dirty = true;
    }

    fn i(pos: BlockPos) u16 {
        return @intCast(pos.y() * (x_size * z_size) + pos.z() * x_size + pos.x());
    }

    pub fn getGeometry(chunk: *Chunk, world: *const World, renderer: *Renderer) !*const Geometry {
        if (chunk.is_geometry_dirty) {
            if (chunk.geometry) |*geometry| {
                geometry.deinit();
                chunk.geometry = null;
            }
            chunk.is_geometry_dirty = false;
        } else if (chunk.geometry) |*geometry| {
            return geometry;
        }
        var verts = try std.ArrayList(Geometry.Vertex).initCapacity(alloc, @as(usize, Chunk.size) * 6 * 4);
        var indices = try std.ArrayList(u32).initCapacity(alloc, @as(usize, Chunk.size) * 6 * 6);

        var idx_offset: u32 = 0;

        var y: i32 = 0;
        while (y < Chunk.y_size) : (y += 1) {
            var z: i32 = chunk.pos.y();
            while (z < chunk.pos.y() + Chunk.z_size) : (z += 1) {
                var x: i32 = chunk.pos.x();
                while (x < chunk.pos.x() + Chunk.x_size) : (x += 1) {
                    const block = chunk.at(.new(x, y, z));
                    if (block == .air or block == .toplevel)
                        continue;
                    const xf: f32 = @floatFromInt(x);
                    const yf: f32 = @floatFromInt(y);
                    const zf: f32 = @floatFromInt(z);
                    // TODO: change texture based on block type
                    if (world.at(.new(x + 1, y, z)) == .air) {
                        try verts.appendSlice(alloc, &rightFaceVerts(.{ xf, yf, zf }));
                        try indices.appendSlice(alloc, &rightFaceIndices(idx_offset));
                        idx_offset += 4;
                    }
                    if (world.at(.new(x - 1, y, z)) == .air) {
                        try verts.appendSlice(alloc, &leftFaceVerts(.{ xf, yf, zf }));
                        try indices.appendSlice(alloc, &leftFaceIndices(idx_offset));
                        idx_offset += 4;
                    }
                    if (world.at(.new(x, y, z + 1)) == .air) {
                        try verts.appendSlice(alloc, &backFaceVerts(.{ xf, yf, zf }));
                        try indices.appendSlice(alloc, &backFaceIndices(idx_offset));
                        idx_offset += 4;
                    }
                    if (world.at(.new(x, y, z - 1)) == .air) {
                        try verts.appendSlice(alloc, &frontFaceVerts(.{ xf, yf, zf }));
                        try indices.appendSlice(alloc, &frontFaceIndices(idx_offset));
                        idx_offset += 4;
                    }
                    if (world.at(.new(x, y + 1, z)) == .air) {
                        try verts.appendSlice(alloc, &topFaceVerts(.{ xf, yf, zf }));
                        try indices.appendSlice(alloc, &topFaceIndices(idx_offset));
                        idx_offset += 4;
                    }
                    if (world.at(.new(x, y - 1, z)) == .air) {
                        try verts.appendSlice(alloc, &bottomFaceVerts(.{ xf, yf, zf }));
                        try indices.appendSlice(alloc, &bottomFaceIndices(idx_offset));
                        idx_offset += 4;
                    }
                }
            }
        }

        chunk.geometry = try Geometry.fromVertsAndIndices(renderer, try verts.toOwnedSlice(alloc), try indices.toOwnedSlice(alloc));
        return &chunk.geometry.?;
    }
};

// Number of blocks along the X and Y axes of the texture
const bcx = 6;
const bcy = 6;

fn bp(offset: [2]f32, uv: [2]f32) [2]f32 {
    return .{ (offset[0] + uv[0]) / bcx, (offset[1] + uv[1]) / bcy };
}

fn frontFaceVerts(pos: [3]f32) [4]Geometry.Vertex {
    return .{
        .{ .pos = .{ pos[0] + 0, pos[1] + 0, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 1 }) },
        .{ .pos = .{ pos[0] + 0, pos[1] + 1, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 0 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 0, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 1 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 1, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 0 }) },
    };
}

fn backFaceVerts(pos: [3]f32) [4]Geometry.Vertex {
    return .{
        .{ .pos = .{ pos[0] + 0, pos[1] + 0, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 1 }) },
        .{ .pos = .{ pos[0] + 0, pos[1] + 1, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 0 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 0, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 1 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 1, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 0 }) },
    };
}

fn leftFaceVerts(pos: [3]f32) [4]Geometry.Vertex {
    return .{
        .{ .pos = .{ pos[0] + 0, pos[1] + 0, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 1 }) },
        .{ .pos = .{ pos[0] + 0, pos[1] + 1, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 0 }) },
        .{ .pos = .{ pos[0] + 0, pos[1] + 0, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 1 }) },
        .{ .pos = .{ pos[0] + 0, pos[1] + 1, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 0 }) },
    };
}

fn rightFaceVerts(pos: [3]f32) [4]Geometry.Vertex {
    return .{
        .{ .pos = .{ pos[0] + 1, pos[1] + 0, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 1 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 1, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 0 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 0, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 1 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 1, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 0 }) },
    };
}

fn bottomFaceVerts(pos: [3]f32) [4]Geometry.Vertex {
    return .{
        .{ .pos = .{ pos[0] + 0, pos[1] + 0, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 1 }) },
        .{ .pos = .{ pos[0] + 0, pos[1] + 0, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 0, 0 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 0, pos[2] + 0 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 1 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 0, pos[2] + 1 }, .tex_coord = bp(.{ 2, 0 }, .{ 1, 0 }) },
    };
}

fn topFaceVerts(pos: [3]f32) [4]Geometry.Vertex {
    return .{
        .{ .pos = .{ pos[0] + 0, pos[1] + 1, pos[2] + 0 }, .tex_coord = bp(.{ 0, 0 }, .{ 0, 1 }) },
        .{ .pos = .{ pos[0] + 0, pos[1] + 1, pos[2] + 1 }, .tex_coord = bp(.{ 0, 0 }, .{ 0, 0 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 1, pos[2] + 0 }, .tex_coord = bp(.{ 0, 0 }, .{ 1, 1 }) },
        .{ .pos = .{ pos[0] + 1, pos[1] + 1, pos[2] + 1 }, .tex_coord = bp(.{ 0, 0 }, .{ 1, 0 }) },
    };
}

fn indicesWoundA(offset: u32) [6]u32 {
    return .{
        offset + 0, offset + 1, offset + 2,
        offset + 1, offset + 3, offset + 2,
    };
}
fn frontFaceIndices(offset: u32) [6]u32 {
    return indicesWoundA(offset);
}
fn rightFaceIndices(offset: u32) [6]u32 {
    return indicesWoundA(offset);
}
fn topFaceIndices(offset: u32) [6]u32 {
    return indicesWoundA(offset);
}

fn indicesWoundB(offset: u32) [6]u32 {
    return .{
        offset + 0, offset + 2, offset + 1,
        offset + 1, offset + 2, offset + 3,
    };
}
fn backFaceIndices(offset: u32) [6]u32 {
    return indicesWoundB(offset);
}
fn leftFaceIndices(offset: u32) [6]u32 {
    return indicesWoundB(offset);
}
fn bottomFaceIndices(offset: u32) [6]u32 {
    return indicesWoundA(offset);
}
