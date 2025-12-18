const std = @import("std");
const wls = @import("wayland").server.wl;

pub fn createGlobal(display: *wls.Server) !*wls.Global {
    return try wls.Global.create(display, wls.Subcompositor, wls.Subcompositor.generated_version, ?*anyopaque, null, bind);
}

pub fn bind(client: *wls.Client, _: ?*anyopaque, version: u32, id: u32) void {
    var resource = wls.Subcompositor.create(client, version, id) catch {
        std.log.err("OOM", .{});
        return;
    };
    resource.setHandler(?*anyopaque, handleRequest, null, null);
}

fn handleRequest(resource: *wls.Subcompositor, request: wls.Subcompositor.Request, _: ?*anyopaque) void {
    switch (request) {
        .destroy => resource.destroy(),

        .get_subsurface => |req| {
            const subsurface_resource = wls.Subsurface.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
            subsurface_resource.setHandler(?*anyopaque, handleRequestSubsurface, null, null);
        },
    }
}

fn handleRequestSubsurface(resource: *wls.Subsurface, request: wls.Subsurface.Request, _: ?*anyopaque) void {
    switch (request) {
        .destroy => resource.destroy(),

        .set_position => {
            // I'm not gonna implement this
        },

        .place_above => {
            // I'm not gonna implement this
        },

        .place_below => {
            // I'm not gonna implement this
        },

        .set_sync => {
            // I'm not gonna implement this
        },

        .set_desync => {
            // I'm not gonna implement this
        },
    }
}
