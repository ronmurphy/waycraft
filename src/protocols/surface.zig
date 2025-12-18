const std = @import("std");
const wls = @import("wayland").server.wl;
const Buffer = @import("buffer.zig").Buffer;

const outputs = &@import("output.zig").outputs;

const alloc = std.heap.c_allocator;

pub const Surface = struct {
    const State = struct {
        buffer: ?*Buffer,
        is_damaged: bool,
        frame_callbacks: wls.list.Head(wls.Callback, null),
    };

    resource: *wls.Surface,
    state: State,
    pending: struct {
        requests: packed struct {
            attach: bool = false,
            damage: bool = false,
            frame: bool = false,
        },
        state: State,
    },

    events: struct {
        state_changed: wls.Signal(void),
        destroyed: wls.Signal(void),
    },

    pub fn create(client: *wls.Client, version: u32, id: u32) !*Surface {
        const resource = try wls.Surface.create(client, version, id);

        var surface = try alloc.create(Surface);
        surface.* = .{
            .resource = resource,
            .state = .{
                .buffer = null,
                .is_damaged = false,
                .frame_callbacks = undefined,
            },
            .pending = .{
                .requests = .{},
                .state = surface.state,
            },
            .events = undefined,
        };
        surface.pending.state.frame_callbacks.init();
        surface.state.frame_callbacks.init();
        surface.events.state_changed.init();
        surface.events.destroyed.init();

        resource.setHandler(*Surface, handleRequest, handleDestroy, surface);

        var outputs_iter = outputs.iterator(.forward);
        while (outputs_iter.next()) |output| {
            if (output.getClient() == resource.getClient()) resource.sendEnter(output);
        }

        return surface;
    }
};

fn handleRequest(resource: *wls.Surface, request: wls.Surface.Request, surface: *Surface) void {
    switch (request) {
        .destroy => resource.destroy(),

        .attach => |req| {
            surface.pending.requests.attach = true;
            surface.pending.state.buffer = if (req.buffer) |b| @ptrCast(@alignCast(b.getUserData())) else null;
        },

        .damage => {
            surface.pending.requests.damage = true;
            surface.pending.state.is_damaged = true;
            // Just repaint it all. No need to consider performance rn.
        },

        .frame => |req| {
            surface.pending.requests.frame = true;
            const callback = wls.Callback.create(resource.getClient(), resource.getVersion(), req.callback) catch {
                std.log.err("OOM", .{});
                return;
            };
            callback.setHandler(?*anyopaque, null, null);
            surface.pending.state.frame_callbacks.append(callback);
        },

        .set_opaque_region => {
            // I'm not gonna implement this
        },

        .set_input_region => {
            // I'm not gonna implement this
        },

        .commit => {
            if (surface.pending.requests.attach) {
                surface.state.buffer = surface.pending.state.buffer;
                surface.pending.requests.attach = false;
            }

            if (surface.pending.requests.damage) {
                surface.state.is_damaged = surface.pending.state.is_damaged;
                surface.pending.requests.damage = false;
            }

            if (surface.pending.requests.frame) {
                surface.state.frame_callbacks.appendList(&surface.pending.state.frame_callbacks);
                surface.pending.state.frame_callbacks.init();
                surface.pending.requests.frame = false;
            }

            surface.events.state_changed.emit();
        },

        .damage_buffer => {
            surface.pending.requests.damage = true;
            surface.pending.state.is_damaged = true;
            // Just repaint it all. No need to consider performance rn.
        },

        .offset => {
            // I'm not gonna implement this
        },

        .set_buffer_scale => {
            // I'm not gonna implement this
        },

        .set_buffer_transform => {
            // I'm not gonna implement this
        },
    }
}

fn handleDestroy(_: *wls.Surface, surface: *Surface) void {
    surface.events.destroyed.emit();
    alloc.destroy(surface);
}
