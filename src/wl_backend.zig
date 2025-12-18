const std = @import("std");
const wl = @import("wayland").client.wl;
const wls = @import("wayland").server.wl;
const xdg = @import("wayland").client.xdg;
const zwp = @import("wayland").client.zwp;
const wp = @import("wayland").client.wp;
const xkb = @import("xkbcommon");
const wc_seat = @import("protocols/seat.zig");
const Renderer = @import("renderer.zig").Renderer;
const Toplevel = @import("protocols/toplevel.zig").Toplevel;
const ToplevelRenderable = @import("toplevel_renderable.zig").ToplevelRenderable;
const World = @import("world.zig").World;
const display = &@import("main.zig").display;
const c = @cImport({
    @cInclude("unistd.h");
    @cInclude("stdio.h");
    @cInclude("sys/mman.h");
});

const alloc = std.heap.c_allocator;

pub const WlBackend = struct {
    world: *World,

    active_toplevel_changed_listener: wls.Listener(void),
    keyboard_created_listener: wls.Listener(*wls.Keyboard),

    display: *wl.Display,

    registry: *wl.Registry,
    compositor: *wl.Compositor,
    xdg_wm_base: *xdg.WmBase,
    cursor_shape_manager: *wp.CursorShapeManagerV1,
    seat: *wl.Seat,
    pointer_constraints: *zwp.PointerConstraintsV1,
    relative_pointer_manager: *zwp.RelativePointerManagerV1,

    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    xdg_toplevel: *xdg.Toplevel,

    frame_callback: *wl.Callback,
    renderer: Renderer,

    xkb_context: *xkb.Context,
    pointer: ?*wl.Pointer,
    cursor_shape: ?*wp.CursorShapeDeviceV1,
    locked_pointer: ?*zwp.LockedPointerV1,
    relative_pointer: ?*zwp.RelativePointerV1,
    keyboard: ?*wl.Keyboard,
    xkb_state: ?*xkb.State,
    keymap: ?*xkb.Keymap,

    pub fn init(self: *WlBackend, world: *World, desktop_mode: bool) !void {
        self.world = world;

        self.active_toplevel_changed_listener = .init(onActiveToplevelChanged);
        self.keyboard_created_listener = .init(onKeyboardCreated);
        self.world.active_toplevel_changed_event.add(&self.active_toplevel_changed_listener);
        wc_seat.pointer_created_event.init();
        wc_seat.keyboard_created_event.init();
        wc_seat.keyboard_created_event.add(&self.keyboard_created_listener);

        self.display = try wl.Display.connect(null);

        // Bind to globals

        const RegistryData = struct {
            compositor: ?*wl.Compositor = null,
            wm_base: ?*xdg.WmBase = null,
            cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
            seat: ?*wl.Seat = null,
            pointer_constraints: ?*zwp.PointerConstraintsV1 = null,
            relative_pointer_manager: ?*zwp.RelativePointerManagerV1 = null,

            fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, data: *@This()) void {
                switch (event) {
                    .global => |global| {
                        if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                            data.compositor = registry.bind(global.name, wl.Compositor, global.version) catch return;
                        } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                            data.wm_base = registry.bind(global.name, xdg.WmBase, global.version) catch return;
                        } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                            data.cursor_shape_manager = registry.bind(global.name, wp.CursorShapeManagerV1, global.version) catch return;
                        } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                            data.seat = registry.bind(global.name, wl.Seat, global.version) catch return;
                        } else if (std.mem.orderZ(u8, global.interface, zwp.PointerConstraintsV1.interface.name) == .eq) {
                            data.pointer_constraints = registry.bind(global.name, zwp.PointerConstraintsV1, global.version) catch return;
                        } else if (std.mem.orderZ(u8, global.interface, zwp.RelativePointerManagerV1.interface.name) == .eq) {
                            data.relative_pointer_manager = registry.bind(global.name, zwp.RelativePointerManagerV1, global.version) catch return;
                        }
                    },
                    .global_remove => {},
                }
            }
        };
        self.registry = try self.display.getRegistry();
        var registry_data = RegistryData{};
        self.registry.setListener(*RegistryData, RegistryData.registryListener, &registry_data);
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        self.compositor = registry_data.compositor orelse return error.NoWlCompositor;
        self.xdg_wm_base = registry_data.wm_base orelse return error.NoXdgWmBase;
        self.cursor_shape_manager = registry_data.cursor_shape_manager orelse return error.NoCursorShapeManager;
        self.seat = registry_data.seat orelse return error.NoSeat;
        self.pointer_constraints = registry_data.pointer_constraints orelse return error.NoPointerConstraints;
        self.relative_pointer_manager = registry_data.relative_pointer_manager orelse return error.NoRelativePointerManager;

        // Create a surface

        self.surface = try self.compositor.createSurface();
        self.xdg_surface = try self.xdg_wm_base.getXdgSurface(self.surface);
        self.xdg_toplevel = try self.xdg_surface.getToplevel();

        self.xdg_wm_base.setListener(?*anyopaque, xdgWmBaseListener, null);
        self.xdg_surface.setListener(*WlBackend, xdgSurfaceListener, self);
        self.xdg_toplevel.setListener(*WlBackend, xdgToplevelListener, self);

        self.xdg_toplevel.setTitle("waycraft");
        self.xdg_toplevel.setAppId("zacoons.waycraft");

        self.frame_callback = try self.surface.frame();
        self.frame_callback.setListener(*WlBackend, frame, self);

        self.surface.commit();

        // Seat

        self.xkb_context = xkb.Context.new(.no_flags) orelse return error.OutOfMemory;
        self.pointer = null;
        self.locked_pointer = null;
        self.relative_pointer = null;
        self.keyboard = null;
        self.xkb_state = null;
        self.keymap = null;

        self.seat.setListener(*WlBackend, wlSeatListener, self);

        // Render loop

        self.renderer = undefined;
        try self.renderer.init(world, self.display, self.surface, desktop_mode);
    }

    pub fn deinit(self: *WlBackend) void {
        defer self.display.disconnect();

        defer self.registry.destroy();
        defer self.compositor.destroy();
        defer self.xdg_wm_base.destroy();
        defer self.cursor_shape_manager.destroy();
        defer self.seat.destroy();
        defer self.pointer_constraints.destroy();
        defer self.relative_pointer_manager.destroy();

        defer self.surface.destroy();
        defer self.xdg_surface.destroy();
        defer self.xdg_toplevel.destroy();

        defer self.frame_callback.destroy();
        defer self.renderer.deinit();
    }

    pub fn update(self: *const WlBackend) !void {
        var result: std.posix.E = undefined;

        result = self.display.flush();
        if (result != .SUCCESS) {
            std.log.err("Error flushing events to parent compositor: {s}", .{@tagName(result)});
            return;
        }

        if (self.display.prepareRead()) {
            result = self.display.readEvents();
            if (result != .SUCCESS) {
                std.log.err("Error preparing to read events from parent compositor: {s}", .{@tagName(result)});
                return;
            }
            result = self.display.dispatchPending();
            if (result != .SUCCESS) {
                std.log.err("Error dispatching events from parent compositor: {s}", .{@tagName(result)});
                return;
            }
        } else {
            result = self.display.dispatch();
            if (result != .SUCCESS) {
                std.log.err("Error dispatching events from parent compositor: {s}", .{@tagName(result)});
                return;
            }
        }

        while (true) {
            const ret = @intFromEnum(self.display.dispatchPending());
            result = self.display.flush();
            if (result != .SUCCESS) {
                std.log.err("Error flushing events to parent compositor: {s}", .{@tagName(result)});
                return;
            }
            if (ret <= 0) break;
        }
    }

    pub fn appendToplevel(backend: *WlBackend, toplevel: *Toplevel) !void {
        try backend.world.createToplevelBlock(toplevel, &backend.renderer);
    }
};

fn xdgWmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, _: ?*anyopaque) void {
    wm_base.pong(event.ping.serial);
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *WlBackend) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            self.renderer.render() catch |err| {
                std.log.err("Error rendering frame: {s}", .{@errorName(err)});
            };
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *WlBackend) void {
    switch (event) {
        .configure => |e| {
            self.renderer.resize(@max(0, e.width), @max(0, e.height)) catch |err| {
                std.log.err("Error resizing: {s}", .{@errorName(err)});
            };
        },

        .close => {
            // TODO: notify World
        },

        .configure_bounds => {},

        .wm_capabilities => {},
    }
}

fn wlSeatListener(resource: *wl.Seat, event: wl.Seat.Event, self: *WlBackend) void {
    switch (event) {
        .capabilities => |e| {
            if (e.capabilities.pointer) {
                const pointer = resource.getPointer() catch {
                    std.log.err("OOM", .{});
                    return;
                };
                pointer.setListener(*WlBackend, wlPointerListener, self);
                self.pointer = pointer;

                self.cursor_shape = self.cursor_shape_manager.getPointer(pointer) catch {
                    std.log.err("OOM", .{});
                    return;
                };

                const relative_pointer = self.relative_pointer_manager.getRelativePointer(pointer) catch {
                    std.log.err("OOM", .{});
                    return;
                };
                relative_pointer.setListener(*WlBackend, zwpRelativePointerListener, self);
                self.relative_pointer = relative_pointer;
            } else {
                self.pointer.?.release();
                self.pointer = null;
            }

            if (e.capabilities.keyboard) {
                const keyboard = resource.getKeyboard() catch {
                    std.log.err("OOM", .{});
                    return;
                };
                keyboard.setListener(*WlBackend, wlKeyboardListener, self);
                self.keyboard = keyboard;
            } else {
                self.keyboard.?.release();
                self.keyboard = null;
            }
        },

        .name => {},
    }
}

fn zwpRelativePointerListener(_: *zwp.RelativePointerV1, event: zwp.RelativePointerV1.Event, self: *WlBackend) void {
    // Ignore input if pointer is not locked
    if (self.locked_pointer == null) {
        return;
    }

    switch (event) {
        .relative_motion => |e| {
            self.world.pointerMoved(e.dx.toDouble(), e.dy.toDouble());
        },
    }
}

fn wlPointerListener(resource: *wl.Pointer, event: wl.Pointer.Event, self: *WlBackend) void {
    if (self.locked_pointer == null) {
        // Lock pointer on left click
        switch (event) {
            .enter => |e| {
                self.cursor_shape.?.setShape(e.serial, .default);
            },

            .button => |e| {
                if (e.button == 0x110) {
                    resource.setCursor(e.serial, null, 0, 0);

                    self.locked_pointer = self.pointer_constraints.lockPointer(self.surface, resource, null, .persistent) catch |err| {
                        std.log.err("Error locking pointer: {s}", .{@errorName(err)});
                        return;
                    };

                    return;
                }
            },
            else => {},
        }
    }

    switch (event) {
        .button => |e| {
            switch (e.state) {
                .pressed => self.world.pointerPressed(e.button),
                .released => self.world.pointerReleased(e.button),
                else => {
                    std.log.err("Invalid pointer button state: {}", .{@intFromEnum(e.state)});
                    return;
                },
            }
        },
        else => {},
    }
}

fn onActiveToplevelChanged(listener: *wls.Listener(void)) void {
    const backend: *WlBackend = @fieldParentPtr("active_toplevel_changed_listener", listener);
    if (backend.world.active_toplevel) |active_toplevel| {
        const client = active_toplevel.resource.getClient();
        if (wc_seat.getKeyboardForClient(client)) |kb| {
            var keys = wls.Array{ .size = 0, .alloc = 0, .data = null }; // Too lazy to get the already pressed keys
            kb.sendEnter(client.getDisplay().nextSerial(), active_toplevel.xdg_surface.surface.resource, &keys);
            kb.sendModifiers(client.getDisplay().nextSerial(), 0, 0, 0, 0);
        }
        if (wc_seat.getPointerForClient(client)) |pointer| {
            pointer.sendEnter(client.getDisplay().nextSerial(), active_toplevel.xdg_surface.surface.resource, wls.Fixed.fromDouble(0), wls.Fixed.fromDouble(0));
            pointer.sendFrame();
        }
    } else {
        // Active toplevel was cleared (app closed) - unlock pointer and restore cursor
        if (backend.cursor_shape) |cursor_shape| {
            cursor_shape.setShape(1, .default);
        }
        if (backend.locked_pointer) |locked_pointer| {
            locked_pointer.destroy();
        }
        backend.locked_pointer = null;
    }
}

fn onKeyboardCreated(listener: *wls.Listener(*wls.Keyboard), kb: *wls.Keyboard) void {
    if (kb.getVersion() >= 4) kb.sendRepeatInfo(16, std.time.ms_per_s / 2);

    const backend: *WlBackend = @fieldParentPtr("keyboard_created_listener", listener);
    const keymap_str = std.mem.sliceTo(backend.xkb_state.?.getKeymap().getAsString(.text_v1), 0);
    const keymap_fd, const keymap_fd_name = fdFromStr(keymap_str) catch |err| {
        std.log.err("Error creating keymap fd: {s}", .{@errorName(err)});
        return;
    };
    kb.sendKeymap(.xkb_v1, keymap_fd, @intCast(keymap_str.len));
    _ = std.c.shm_unlink(keymap_fd_name);
}

var i: u32 = 0;
fn fdFromStr(str: []u8) !struct { i32, [:0]u8 } {
    const name = try std.fmt.allocPrintSentinel(alloc, "/wc_fd{}", .{i}, 0);
    i += 1;
    const fd = std.c.shm_open(name, @bitCast(std.c.O{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true }), 0o600);
    if (fd == -1) {
        return switch (@as(std.c.E, @enumFromInt(std.c._errno().*))) {
            .ACCES => error.PermissionDenied,
            .EXIST => error.AlreadyExists,
            .INVAL => error.NameInvalid,
            .MFILE, .NFILE => error.LimitReached,
            .NAMETOOLONG => error.NameTooLong,
            else => error.ShmOpen,
        };
    }
    try std.posix.ftruncate(fd, str.len);
    const ptr = try std.posix.mmap(null, str.len, std.posix.PROT.READ | std.posix.PROT.WRITE, .{ .TYPE = .SHARED }, fd, 0);
    @memcpy(ptr, str.ptr);
    std.posix.munmap(ptr);
    return .{ fd, name };
}

fn wlKeyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *WlBackend) void {
    switch (event) {
        .keymap => |e| {
            defer std.posix.close(e.fd);

            if (e.format != .xkb_v1) {
                std.log.err("Unsupported keymap format {d}", .{@intFromEnum(e.format)});
                return;
            }

            const keymap_string = std.posix.mmap(null, e.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, e.fd, 0) catch |err| {
                std.log.err("Failed to mmap() keymap fd: {s}", .{@errorName(err)});
                return;
            };
            defer std.posix.munmap(keymap_string);

            const keymap = xkb.Keymap.newFromBuffer(
                self.xkb_context,
                keymap_string.ptr,
                // The string is 0 terminated
                keymap_string.len - 1,
                .text_v1,
                .no_flags,
            ) orelse {
                std.log.err("Failed to parse xkb keymap", .{});
                return;
            };
            defer keymap.unref();

            const state = xkb.State.new(keymap) orelse {
                std.log.err("Failed to create xkb state", .{});
                return;
            };
            defer state.unref();

            if (self.xkb_state) |s| s.unref();
            self.xkb_state = state.ref();

            if (self.world.active_toplevel) |active_toplevel| {
                if (wc_seat.getKeyboardForClient(active_toplevel.resource.getClient())) |kb| {
                    const keymap_str = std.mem.sliceTo(self.xkb_state.?.getKeymap().getAsString(.text_v1), 0);
                    const keymap_fd, const keymap_fd_name = fdFromStr(keymap_str) catch |err| {
                        std.log.err("Error creating keymap fd: {s}", .{@errorName(err)});
                        return;
                    };
                    kb.sendKeymap(.xkb_v1, keymap_fd, @intCast(keymap_str.len));
                    _ = std.c.shm_unlink(keymap_fd_name);
                }
            }
        },
        else => {},
    }

    switch (event) {
        .leave => self.world.keyReleasedAll(),

        .key => |e| {
            const xkb_state = self.xkb_state orelse return;
            const keysym = xkb_state.keyGetOneSym(e.key + 8);
            if (keysym == .NoSymbol) {
                return;
            }

            // Handle Escape to unfocus from active toplevel
            if (keysym == xkb.Keysym.Escape and self.world.active_toplevel != null) {
                if (self.world.active_toplevel) |active_toplevel| {
                    const client = active_toplevel.resource.getClient();
                    if (wc_seat.getKeyboardForClient(client)) |kb| {
                        kb.sendLeave(client.getDisplay().nextSerial(), active_toplevel.xdg_surface.surface.resource);
                    }
                    if (wc_seat.getPointerForClient(client)) |pointer| {
                        pointer.sendLeave(client.getDisplay().nextSerial(), active_toplevel.xdg_surface.surface.resource);
                        pointer.sendFrame();
                    }
                    self.world.active_toplevel_destroyed_listener.link.remove();
                    self.world.active_toplevel = null;
                    self.world.active_toplevel_changed_event.emit();
                }
                return;
            }

            // Forward other keys to active toplevel
            // Store this early to avoid accessing potentially destroyed pointer multiple times
            const maybe_toplevel = self.world.active_toplevel;
            if (maybe_toplevel) |active_toplevel| {
                // Immediately re-check in case it was cleared
                if (self.world.active_toplevel != active_toplevel) return;

                const client = active_toplevel.resource.getClient();

                // One more check after getting client
                if (self.world.active_toplevel != active_toplevel) return;

                var iter = wc_seat.all_seats.keyboards.iterator(.forward);
                while (iter.next()) |kb| {
                    if (kb.getClient() == client) {
                        kb.sendKey(client.getDisplay().nextSerial(), e.time, e.key, e.state);
                    }
                }
                return;
            }

            switch (e.state) {
                .pressed => {
                    if (keysym == xkb.Keysym.Escape) {
                        self.cursor_shape.?.setShape(e.serial, .default);
                        if (self.locked_pointer) |locked_pointer| locked_pointer.destroy();
                        self.locked_pointer = null;
                        return;
                    }
                    self.world.keyPressed(keysym);
                },
                .released => self.world.keyReleased(keysym),
                else => {
                    std.log.err("Invalid key state: {}", .{@intFromEnum(e.state)});
                    return;
                },
            }
        },

        .modifiers => |e| {
            if (self.world.active_toplevel) |active_toplevel| {
                const client = active_toplevel.resource.getClient();
                if (wc_seat.getKeyboardForClient(client)) |kb| {
                    kb.sendModifiers(client.getDisplay().nextSerial(), e.mods_depressed, e.mods_latched, e.mods_locked, e.group);
                }
                return;
            }

            if (self.xkb_state) |xkb_state| {
                _ = xkb_state.updateMask(e.mods_depressed, e.mods_latched, e.mods_locked, 0, 0, e.group);
            }
        },

        else => {},
    }
}

fn frame(callback: *wl.Callback, event: wl.Callback.Event, self: *WlBackend) void {
    switch (event) {
        .done => {
            callback.destroy();

            self.frame_callback = self.surface.frame() catch |err| {
                std.log.err("Error creating frame callback: {s}", .{@errorName(err)});
                return;
            };
            self.frame_callback.setListener(*WlBackend, frame, self);

            self.renderer.render() catch |err| {
                std.log.err("Error rendering frame: {s}", .{@errorName(err)});
            };
        },
    }
}
