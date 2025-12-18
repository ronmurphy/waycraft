const std = @import("std");
const wls = @import("wayland").server.wl;
const Buffer = @import("buffer.zig").Buffer;

const alloc = std.heap.c_allocator;

pub fn createGlobal(display: *wls.Server) !*wls.Global {
    return try wls.Global.create(display, wls.DataDeviceManager, wls.DataDeviceManager.generated_version, ?*anyopaque, null, bind);
}

pub fn bind(client: *wls.Client, _: ?*anyopaque, version: u32, id: u32) void {
    var resource = wls.DataDeviceManager.create(client, version, id) catch {
        std.log.err("OOM", .{});
        return;
    };

    resource.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(resource: *wls.DataDeviceManager, request: wls.DataDeviceManager.Request, _: ?*anyopaque) void {
    switch (request) {
        .create_data_source => |req| {
            const data_source_resource = wls.DataSource.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
            data_source_resource.setHandler(?*anyopaque, handleRequestDataSource, null, null);
        },

        .get_data_device => |req| {
            const data_device_resource = wls.DataDevice.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
            data_device_resource.setHandler(?*anyopaque, handleRequestDataDevice, null, null);
        },
    }
}

fn handleRequestDataSource(resource: *wls.DataSource, request: wls.DataSource.Request, _: ?*anyopaque) void {
    switch (request) {
        .offer => {
            // I'm not going to implement this
        },

        .destroy => resource.destroy(),

        .set_actions => {
            // I'm not going to implement this
        },
    }
}

fn handleRequestDataDevice(resource: *wls.DataDevice, request: wls.DataDevice.Request, _: ?*anyopaque) void {
    switch (request) {
        .start_drag => {
            // I'm not going to implement this
        },

        .set_selection => {
            // I'm not going to implement this
        },

        .release => resource.destroy(),
    }
}
