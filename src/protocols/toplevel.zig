const std = @import("std");
const wls = @import("wayland").server.wl;
const xdgs = @import("wayland").server.xdg;
const XdgSurface = @import("xdg_shell.zig").XdgSurface;

const alloc = std.heap.c_allocator;

pub const Toplevel = struct {
    link: wls.list.Link,
    resource: *xdgs.Toplevel,
    xdg_surface: *XdgSurface,
    surface_destroyed_listener: wls.Listener(void),
    width: i32,
    height: i32,

    events: struct {
        destroyed: wls.Signal(void),
    },

    pub fn create(client: *wls.Client, version: u32, id: u32, xdg_surface: *XdgSurface, width: i32, height: i32) !*Toplevel {
        const resource = try xdgs.Toplevel.create(client, version, id);

        const toplevel = try alloc.create(Toplevel);
        toplevel.* = .{
            .link = undefined,
            .resource = resource,
            .xdg_surface = xdg_surface,
            .surface_destroyed_listener = .init(onSurfaceDestroyed),
            .width = width,
            .height = height,

            .events = undefined,
        };
        toplevel.events.destroyed.init();

        toplevel.xdg_surface.surface.events.destroyed.add(&toplevel.surface_destroyed_listener);

        resource.setHandler(*Toplevel, handleRequest, handleDestroy, toplevel);

        return toplevel;
    }
};

fn onSurfaceDestroyed(listener: *wls.Listener(void)) void {
    const toplevel: *Toplevel = @fieldParentPtr("surface_destroyed_listener", listener);
    toplevel.resource.destroy();
}

fn handleRequest(resource: *xdgs.Toplevel, request: xdgs.Toplevel.Request, toplevel: *Toplevel) void {
    _ = toplevel;
    switch (request) {
        .destroy => resource.destroy(),

        .set_parent => {
            // I'm not gonna implement this
        },

        .set_title => {
            // No need to keep track of this
        },

        .set_app_id => {
            // No need to keep track of this
        },

        .show_window_menu => {
            // I'm not gonna implement this
        },

        .move => {
            // I'm not gonna implement this
        },

        .resize => {
            // TODO
        },

        .set_max_size => {
            // TODO
        },

        .set_min_size => {
            // TODO
        },

        .set_maximized => {
            // I'm not gonna implement this
        },

        .unset_maximized => {
            // I'm not gonna implement this
        },

        .set_fullscreen => {
            // I'm not gonna implement this
        },

        .unset_fullscreen => {
            // I'm not gonna implement this
        },

        .set_minimized => {
            // I'm not gonna implement this
        },
    }
}

fn handleDestroy(_: *xdgs.Toplevel, toplevel: *Toplevel) void {
    toplevel.events.destroyed.emit();
    toplevel.surface_destroyed_listener.link.remove();
    alloc.destroy(toplevel);
}
