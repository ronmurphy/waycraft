const std = @import("std");
const wls = @import("wayland").server.wl;
const Surface = @import("surface.zig").Surface;

pub fn createGlobal(display: *wls.Server) !*wls.Global {
    return try wls.Global.create(display, wls.Compositor, wls.Compositor.generated_version, ?*anyopaque, null, bind);
}

pub fn bind(client: *wls.Client, _: ?*anyopaque, version: u32, id: u32) void {
    var compositor = wls.Compositor.create(client, version, id) catch {
        std.log.err("OOM", .{});
        return;
    };
    compositor.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(resource: *wls.Compositor, request: wls.Compositor.Request, _: ?*anyopaque) void {
    switch (request) {
        .create_surface => |req| {
            _ = Surface.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
        },

        .create_region => |req| {
            const region_resource = wls.Region.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };

            region_resource.setHandler(?*anyopaque, handleRequestRegion, null, null);
        },
    }
}

fn handleRequestRegion(resource: *wls.Region, request: wls.Region.Request, _: ?*anyopaque) void {
    switch (request) {
        .destroy => resource.destroy(),

        .add => {
            // I'm not gonna implement this
        },

        .subtract => {
            // I'm not gonna implement this
        },
    }
}
