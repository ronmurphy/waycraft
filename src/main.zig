const std = @import("std");
const wls = @import("wayland").server.wl;
const WlBackend = @import("wl_backend.zig").WlBackend;
const c = @cImport({
    @cInclude("stdlib.h");
});
const World = @import("world.zig").World;

pub var backend: WlBackend = undefined;
pub var world: World = undefined;

const millis_between_updates: u64 = @intFromFloat(std.time.ms_per_s / 30); // About 30 FPS
var prev_frame_time: std.time.Instant = undefined;
var update_timer: *wls.EventSource = undefined;

pub fn main() !void {
    // Parse command line arguments
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    var desktop_mode = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--desktop")) {
            desktop_mode = true;
        }
    }

    try world.init();

    // Init backend (must be done before setting the env variable)
    try backend.init(&world, desktop_mode);

    const display = try wls.Server.create();

    // Create globals
    const compositor = try @import("protocols/compositor.zig").createGlobal(display);
    const shm = try @import("protocols/shm.zig").createGlobal(display);
    const seat = try @import("protocols/seat.zig").createGlobal(display);
    const data_device_manager = try @import("protocols/data_device_manager.zig").createGlobal(display);
    const subcompositor = try @import("protocols/subcompositor.zig").createGlobal(display);
    const output = try @import("protocols/output.zig").createGlobal(display);
    const xdg_shell = try @import("protocols/xdg_shell.zig").createGlobal(display);
    defer compositor.destroy();
    defer shm.destroy();
    defer seat.destroy();
    defer data_device_manager.destroy();
    defer subcompositor.destroy();
    defer output.destroy();
    defer xdg_shell.destroy();

    // Setup a socket for clients to connect to
    var socket_name_buf: [11]u8 = undefined;
    const socket_name = try display.addSocketAuto(&socket_name_buf);
    if (c.setenv("WAYLAND_DISPLAY", socket_name.ptr, 1) != 0) return error.SetEnv;

    // Import WAYLAND_DISPLAY into systemd user session so D-Bus activated apps
    // (like file associations in dolphin) connect to waycraft instead of the parent compositor
    var import_env = std.process.Child.init(&.{ "systemctl", "--user", "import-environment", "WAYLAND_DISPLAY" }, std.heap.c_allocator);
    _ = import_env.spawn() catch |err| {
        std.log.warn("Failed to import WAYLAND_DISPLAY into systemd: {s}", .{@errorName(err)});
        // Non-fatal, continue anyway
    };

    // Update loop
    prev_frame_time = try .now();
    update_timer = try display.getEventLoop().addTimer(?*anyopaque, updateCLike, null);
    try update_timer.timerUpdate(1);

    // Run test client after everything is set up
    _ = try display.getEventLoop().addIdle(?*anyopaque, startTestClient, null);

    // Run the Wayland event loop
    display.run();
}

fn updateCLike(_: ?*anyopaque) c_int {
    update() catch |err| {
        std.log.err("Error running update: {s}", .{@errorName(err)});
        return -1;
    };
    return 0;
}

fn update() !void {
    const now = try std.time.Instant.now();
    const dt_nanos = now.since(prev_frame_time);
    prev_frame_time = now;

    const dt = @as(f32, @floatFromInt(dt_nanos)) / std.time.ns_per_s;

    try world.update(dt);
    try backend.update();

    try update_timer.timerUpdate(millis_between_updates);
}

fn startTestClient(_: ?*anyopaque) void {
    const testClientMain = @import("test_client.zig").main;
    _ = std.Thread.spawn(.{}, testClientMain, .{}) catch |err| {
        std.log.err("Error starting test client: {s}", .{@errorName(err)});
    };
}

test {
    std.testing.refAllDeclsRecursive(@This());
}
