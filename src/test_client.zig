const std = @import("std");
const wl = @import("wayland").client.wl;
const xdg = @import("wayland").client.xdg;

const alloc = std.heap.c_allocator;

pub fn main() !void {
    // wl-info type thing
    // const display = try wl.Display.connect(null);
    // defer display.disconnect();
    // const registry = try display.getRegistry();
    // registry.setListener(?*anyopaque, struct {
    //     fn registryListener(_: *wl.Registry, event: wl.Registry.Event, _: ?*anyopaque) void {
    //         switch (event) {
    //             .global => |global| {
    //                 std.debug.print("hey! {s}\n", .{global.interface});
    //             },
    //             .global_remove => {},
    //         }
    //     }
    // }.registryListener, null);
    // if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    // Spawn proper application
    // var proc = std.process.Child.init(&.{"pcmanfm"}, alloc);
    // try proc.spawn();

    // Test thing
    // try main2();
}

const Context = struct {
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*xdg.WmBase = null,
};

fn main2() !void {
    const display = try wl.Display.connect(null);
    defer display.disconnect();

    // Bind to globals

    const registry = try display.getRegistry();
    var context = Context{};
    registry.setListener(*Context, registryListener, &context);
    if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

    const compositor = context.compositor orelse return error.NoWlCompositor;
    const shm = context.shm orelse return error.NoWlShm;
    const wm_base = context.wm_base orelse return error.NoXdgWmBase;

    // Create our buffer

    const buffer = blk: {
        const width = 128;
        const height = 128;
        const stride = width * 4;
        const size = stride * height;

        const fd = try std.posix.memfd_create("hello-zig-wayland", 0);
        try std.posix.ftruncate(fd, size);
        const data = try std.posix.mmap(
            null,
            size,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        const sqsize = 8;
        for (0..height) |y| {
            for (0..width) |x| {
                const i = y * stride + x * 4;
                const color: u8 = if (((x + y) / sqsize) % 2 == 0) 64 else 255;
                data[i] = le(255);
                data[i + 1] = le(color);
                data[i + 2] = le(color);
                data[i + 3] = le(color);
            }
        }

        const pool = try shm.createPool(fd, size);
        defer pool.destroy();

        break :blk try pool.createBuffer(0, width, height, stride, .argb8888);
    };
    defer buffer.destroy();

    const surface = try compositor.createSurface();
    defer surface.destroy();
    const xdg_surface = try wm_base.getXdgSurface(surface);
    defer xdg_surface.destroy();
    const xdg_toplevel = try xdg_surface.getToplevel();
    defer xdg_toplevel.destroy();

    var running = true;

    wm_base.setListener(?*anyopaque, xdgWmBaseListener, null);
    xdg_surface.setListener(*wl.Surface, xdgSurfaceListener, surface);
    xdg_toplevel.setListener(*bool, xdgToplevelListener, &running);

    surface.attach(buffer, 0, 0);
    surface.commit();

    while (running) {
        if (display.dispatch() != .SUCCESS) return error.DispatchFailed;
    }
}

fn le(i: u8) u8 {
    return if (@import("builtin").target.cpu.arch.endian() == .little) i else @byteSwap(i);
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, context: *Context) void {
    switch (event) {
        .global => |global| {
            if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                context.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name) == .eq) {
                context.shm = registry.bind(global.name, wl.Shm, 1) catch return;
            } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                context.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
            }
        },
        .global_remove => {},
    }
}

fn xdgWmBaseListener(wm_base: *xdg.WmBase, event: xdg.WmBase.Event, data: ?*anyopaque) void {
    _ = data;
    wm_base.pong(event.ping.serial);
}

fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, surface: *wl.Surface) void {
    switch (event) {
        .configure => |configure| {
            xdg_surface.ackConfigure(configure.serial);
            surface.commit();
        },
    }
}

fn xdgToplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, running: *bool) void {
    switch (event) {
        .configure => {},
        .close => running.* = false,
        .configure_bounds => {},
        .wm_capabilities => {},
    }
}
