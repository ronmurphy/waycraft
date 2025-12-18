const std = @import("std");
const wls = @import("wayland").server.wl;
const Buffer = @import("buffer.zig").Buffer;

const alloc = std.heap.c_allocator;

const Shm = struct {
    is_released: bool,
    pools: wls.list.Head(wls.ShmPool, null),
};

pub fn createGlobal(display: *wls.Server) !*wls.Global {
    return try wls.Global.create(display, wls.Shm, wls.Shm.generated_version, ?*anyopaque, null, bind);
}

pub fn bind(client: *wls.Client, _: ?*anyopaque, version: u32, id: u32) void {
    var resource = wls.Shm.create(client, version, id) catch {
        std.log.err("OOM", .{});
        return;
    };

    const shm = alloc.create(Shm) catch {
        std.log.err("OOM", .{});
        return;
    };
    shm.* = .{
        .is_released = false,
        .pools = undefined,
    };
    shm.pools.init();

    resource.setHandler(*Shm, handleRequest, null, shm);

    // https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_shm-enum-format
    // All renderers should support argb8888 and xrgb8888 but any other formats are optional
    resource.sendFormat(.argb8888);
    resource.sendFormat(.xrgb8888);
}

pub const Pool = struct {
    is_destroyed: bool,
    resource: *wls.ShmPool,
    data: []align(std.heap.page_size_min) u8,
    buffers: wls.list.Head(wls.Buffer, null),
};

fn handleRequest(resource: *wls.Shm, request: wls.Shm.Request, shm: *Shm) void {
    switch (request) {
        .create_pool => |req| {
            if (shm.is_released) {
                std.log.err("Client tried using a released SHM", .{});
                return;
            }

            if (req.size < 0) {
                std.log.err("Error creating buffer: Size is negative.", .{});
                return;
            }

            var pool_resource = wls.ShmPool.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };

            const pool = alloc.create(Pool) catch {
                std.log.err("OOM", .{});
                return;
            };
            pool.* = .{
                .is_destroyed = false,
                .resource = pool_resource,
                .data = undefined,
                .buffers = undefined,
            };
            pool.data = std.posix.mmap(null, @intCast(req.size), std.posix.PROT.READ, .{ .TYPE = .SHARED }, req.fd, 0) catch |err| {
                std.log.err("Error mapping shared memory: {s}", .{@errorName(err)});
                alloc.destroy(pool);
                return;
            };
            std.posix.close(req.fd);
            pool.buffers.init();

            pool_resource.setHandler(*Pool, handleRequestPool, null, pool);

            shm.pools.append(pool_resource);
        },

        .release => shm.is_released = true,
    }
}

const PoolBuffer = struct {
    pool: *Pool,
    buffer: *Buffer,
    buffer_destroyed_listener: wls.Listener(void),

    fn onBufferDestroyed(listener: *wls.Listener(void)) void {
        listener.link.remove();

        const pool_buffer: *PoolBuffer = @fieldParentPtr("buffer_destroyed_listener", listener);
        const pool = pool_buffer.pool;

        if (pool.is_destroyed and pool.buffers.length() == 0) {
            alloc.destroy(pool_buffer);

            std.posix.munmap(pool.data);
            pool.resource.getLink().remove();
            alloc.destroy(pool);
        }
    }
};

fn handleRequestPool(resource: *wls.ShmPool, request: wls.ShmPool.Request, pool: *Pool) void {
    switch (request) {
        .create_buffer => |req| {
            if (req.offset < 0 or req.offset > pool.data.len) {
                std.log.err("Error creating buffer: Offset is negative or larger than the pool size.", .{});
                return;
            }
            const buffer_format: Buffer.Format = switch (req.format) {
                .argb8888 => .argb8888,
                .xrgb8888 => .xrgb8888,
                else => {
                    std.log.err("Unsupported buffer format: {s}", .{@tagName(req.format)});
                    return;
                },
            };
            const buffer = Buffer.create(resource.getClient(), resource.getVersion(), req.id, req.offset, req.width, req.height, req.stride, buffer_format, pool.data) catch |err| {
                std.log.err("Error creating buffer: {s}", .{@errorName(err)});
                return;
            };
            const pool_buffer = alloc.create(PoolBuffer) catch {
                std.log.err("OOM", .{});
                return;
            };
            pool_buffer.* = .{
                .pool = pool,
                .buffer = buffer,
                .buffer_destroyed_listener = .init(PoolBuffer.onBufferDestroyed),
            };
            buffer.events.destroyed.add(&pool_buffer.buffer_destroyed_listener);
            pool.buffers.append(buffer.resource);
        },

        .destroy => {
            if (pool.buffers.length() == 0) {
                pool.resource.destroy();
            } else {
                pool.is_destroyed = true;
            }
        },

        .resize => |req| {
            if (req.size < 0) {
                std.log.err("Error resizing buffer: Size is negative.", .{});
                return;
            }
            pool.data = std.posix.mremap(@ptrCast(pool.data), pool.data.len, @intCast(req.size), .{ .MAYMOVE = true }, null) catch |err| {
                std.log.err("Error mapping shared memory: {s}", .{@errorName(err)});
                return;
            };
        },
    }
}
