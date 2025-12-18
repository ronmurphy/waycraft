const std = @import("std");
const wls = @import("wayland").server.wl;
const xdgs = @import("wayland").server.xdg;
const Surface = @import("surface.zig").Surface;
const Toplevel = @import("toplevel.zig").Toplevel;

const backend = &@import("../main.zig").backend;

const alloc = std.heap.c_allocator;

pub fn createGlobal(display: *wls.Server) !*wls.Global {
    return try wls.Global.create(display, xdgs.WmBase, xdgs.WmBase.generated_version, ?*anyopaque, null, bind);
}

fn bind(client: *wls.Client, _: ?*anyopaque, version: u32, id: u32) void {
    var resource = xdgs.WmBase.create(client, version, id) catch {
        std.log.err("OOM", .{});
        return;
    };

    resource.setHandler(?*anyopaque, handleRequest, null, null);
}

pub const XdgSurface = struct {
    resource: *xdgs.Surface,
    surface: *Surface,
    surface_destroyed_listener: wls.Listener(void),
};

fn handleRequest(resource: *xdgs.WmBase, request: xdgs.WmBase.Request, _: ?*anyopaque) void {
    switch (request) {
        .destroy => resource.destroy(),

        .create_positioner => |req| {
            const positioner_resource = xdgs.Positioner.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };

            positioner_resource.setHandler(?*anyopaque, handleRequestPositioner, null, null);
        },

        .get_xdg_surface => |req| {
            var xdg_surface_resource = xdgs.Surface.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };

            const xdg_surface = alloc.create(XdgSurface) catch {
                std.log.err("OOM", .{});
                return;
            };
            xdg_surface.* = .{
                .resource = xdg_surface_resource,
                .surface = @ptrCast(@alignCast(req.surface.getUserData().?)),
                .surface_destroyed_listener = .init(onSurfaceDestroyed),
            };

            xdg_surface.surface.events.destroyed.add(&xdg_surface.surface_destroyed_listener);

            xdg_surface_resource.setHandler(*XdgSurface, handleRequestXdgSurface, handleDestroyXdgSurface, xdg_surface);
        },

        .pong => {
            // No need to keep track of this
        },
    }
}

fn onSurfaceDestroyed(listener: *wls.Listener(void)) void {
    const xdg_surface: *XdgSurface = @fieldParentPtr("surface_destroyed_listener", listener);
    xdg_surface.resource.destroy();
}

fn handleRequestXdgSurface(resource: *xdgs.Surface, request: xdgs.Surface.Request, xdg_surface: *XdgSurface) void {
    switch (request) {
        .destroy => resource.destroy(),

        .get_toplevel => |req| {
            // Get window spec if available, otherwise use 1×1 default
            const WindowSpec = @import("../world.zig").WindowSpec;
            const spec = backend.world.next_window_spec orelse WindowSpec{};

            // Calculate pixel dimensions: 1 block = 1024 pixels
            const pixels_per_block = 1024;
            const width_px: i32 = @intCast(spec.width * pixels_per_block);
            const height_px: i32 = @intCast(spec.height * pixels_per_block);

            const toplevel = Toplevel.create(resource.getClient(), resource.getVersion(), req.id, xdg_surface, width_px, height_px) catch {
                std.log.err("OOM", .{});
                return;
            };
            backend.appendToplevel(toplevel) catch |err| {
                std.log.err("Failed to create toplevel: {s}", .{@errorName(err)});
                return;
            };

            sendConfigure(toplevel, resource.getClient().getDisplay().nextSerial(), -1, -1);
        },

        .get_popup => |req| {
            const popup_resource = xdgs.Popup.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
            popup_resource.setHandler(?*anyopaque, handleRequestPopup, null, null);
        },

        .ack_configure => {
            // No need to keep track of this
        },

        .set_window_geometry => {
            // No need to keep track of this
        },
    }
}

fn handleDestroyXdgSurface(_: *xdgs.Surface, xdg_surface: *XdgSurface) void {
    xdg_surface.surface_destroyed_listener.link.remove();
    alloc.destroy(xdg_surface);
}

fn sendConfigure(toplevel: *const Toplevel, serial: u32, width: i32, height: i32) void {
    const w = if (width < 0) toplevel.width else width;
    const h = if (height < 0) toplevel.height else height;

    var array: wls.Array = .{ .size = 0, .alloc = 0, .data = null };
    if (toplevel.resource.getVersion() >= 4) toplevel.resource.sendConfigureBounds(toplevel.width, toplevel.height);
    toplevel.resource.sendConfigure(w, h, &array);
    toplevel.xdg_surface.resource.sendConfigure(serial);
}

fn handleRequestPositioner(resource: *xdgs.Positioner, request: xdgs.Positioner.Request, _: ?*anyopaque) void {
    switch (request) {
        .destroy => resource.destroy(),

        .set_size => {
            // I'm not gonna implement popups
        },

        .set_anchor_rect => {
            // I'm not gonna implement popups
        },

        .set_anchor => {
            // I'm not gonna implement popups
        },

        .set_gravity => {
            // I'm not gonna implement popups
        },

        .set_constraint_adjustment => {
            // I'm not gonna implement popups
        },

        .set_offset => {
            // I'm not gonna implement popups
        },

        .set_reactive => {
            // I'm not gonna implement popups
        },

        .set_parent_size => {
            // I'm not gonna implement popups
        },

        .set_parent_configure => {
            // I'm not gonna implement popups
        },
    }
}

fn handleRequestPopup(resource: *xdgs.Popup, request: xdgs.Popup.Request, _: ?*anyopaque) void {
    switch (request) {
        .destroy => resource.destroy(),

        .grab => {
            // I'm not gonna implement popups
        },

        .reposition => {
            // I'm not gonna implement popups
        },
    }
}
