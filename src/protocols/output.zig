const std = @import("std");
const wls = @import("wayland").server.wl;

pub var outputs: wls.list.Head(wls.Output, null) = undefined;

pub fn createGlobal(display: *wls.Server) !*wls.Global {
    outputs.init();
    return try wls.Global.create(display, wls.Output, wls.Output.generated_version, ?*anyopaque, null, bind);
}

pub fn bind(client: *wls.Client, _: ?*anyopaque, version: u32, id: u32) void {
    var resource = wls.Output.create(client, version, id) catch {
        std.log.err("OOM", .{});
        return;
    };
    resource.setHandler(?*anyopaque, handleRequest, handleDestroy, null);

    outputs.append(resource);

    resource.sendGeometry(0, 0, 0, 0, .unknown, "Manufacture Co.", "The Thing 1.0", .normal);
    if (resource.getVersion() >= 4) resource.sendName("The only output");
    resource.sendMode(.{ .current = true, .preferred = true }, 1920, 1080, 144149);
    if (resource.getVersion() >= 2) resource.sendDone();
}

fn handleRequest(_: *wls.Output, request: wls.Output.Request, _: ?*anyopaque) void {
    switch (request) {
        .release => {
            // No need to keep track of this
        },
    }
}

fn handleDestroy(resource: *wls.Output, _: ?*anyopaque) void {
    resource.getLink().remove();
}
