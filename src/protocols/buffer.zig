const std = @import("std");
const wls = @import("wayland").server.wl;
const Pool = @import("shm.zig").Pool;

const alloc = std.heap.c_allocator;

pub const Buffer = struct {
    pub const Format = enum {
        argb8888,
        xrgb8888,
    };

    resource: *wls.Buffer,
    offset: i32,
    width: i32,
    height: i32,
    stride: i32,
    format: Format,
    pool: *Pool,

    events: struct {
        destroyed: wls.Signal(void),
    },

    pub fn create(client: *wls.Client, version: u32, id: u32, offset: i32, width: i32, height: i32, stride: i32, format: Format, pool: *Pool) !*Buffer {
        const resource = try wls.Buffer.create(client, version, id);

        const buffer = try alloc.create(Buffer);
        buffer.* = .{
            .resource = resource,
            .offset = offset,
            .width = width,
            .height = height,
            .stride = stride,
            .format = format,
            .pool = pool,

            .events = .{
                .destroyed = undefined,
            },
        };
        buffer.events.destroyed.init();

        resource.setHandler(*Buffer, handleRequest, handleDestroy, buffer);

        return buffer;
    }
};

fn handleRequest(resource: *wls.Buffer, request: wls.Buffer.Request, _: *Buffer) void {
    switch (request) {
        .destroy => resource.destroy(),
    }
}

fn handleDestroy(_: *wls.Buffer, buffer: *Buffer) void {
    buffer.events.destroyed.emit();
    alloc.destroy(buffer);
}
