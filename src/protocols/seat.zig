const std = @import("std");
const wls = @import("wayland").server.wl;

const alloc = std.heap.c_allocator;

pub const AllSeats = struct {
    pointers: wls.list.Head(wls.Pointer, null),
    keyboards: wls.list.Head(wls.Keyboard, null),
};

pub var all_seats: AllSeats = .{
    .pointers = undefined,
    .keyboards = undefined,
};

pub var pointer_created_event: wls.Signal(*wls.Pointer) = undefined;
pub var keyboard_created_event: wls.Signal(*wls.Keyboard) = undefined;

pub fn getPointerForClient(client: *wls.Client) ?*wls.Pointer {
    var iter = all_seats.pointers.iterator(.forward);
    while (iter.next()) |pointer| {
        if (pointer.getClient() == client) return pointer;
    }
    return null;
}

pub fn getKeyboardForClient(client: *wls.Client) ?*wls.Keyboard {
    var iter = all_seats.keyboards.iterator(.forward);
    while (iter.next()) |keyboard| {
        if (keyboard.getClient() == client) return keyboard;
    }
    return null;
}

pub fn createGlobal(display: *wls.Server) !*wls.Global {
    all_seats.pointers.init();
    all_seats.keyboards.init();

    return try wls.Global.create(display, wls.Seat, wls.Seat.generated_version, ?*anyopaque, null, bind);
}

var seat_num: usize = 0;
pub fn bind(client: *wls.Client, _: ?*anyopaque, version: u32, id: u32) void {
    var resource = wls.Seat.create(client, version, id) catch {
        std.log.err("OOM", .{});
        return;
    };
    resource.setHandler(?*anyopaque, handleRequest, null, null);
    resource.sendCapabilities(.{ .keyboard = true, .pointer = true });
    if (resource.getVersion() >= 2) {
        const seat_name = std.fmt.allocPrintSentinel(alloc, "seat{}", .{seat_num}, 0) catch {
            std.log.err("OOM", .{});
            return;
        };
        resource.sendName(seat_name.ptr);
        alloc.free(seat_name);
        seat_num += 1;
    }
}

fn handleRequest(resource: *wls.Seat, request: wls.Seat.Request, _: ?*anyopaque) void {
    switch (request) {
        .get_pointer => |req| {
            const pointer_resource = wls.Pointer.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
            pointer_resource.setHandler(?*anyopaque, handleRequestPointer, handleDestroyPointer, null);
            all_seats.pointers.append(pointer_resource);
            pointer_created_event.emit(pointer_resource);
        },

        .get_keyboard => |req| {
            const keyboard_resource = wls.Keyboard.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
            keyboard_resource.setHandler(?*anyopaque, handleRequestKeyboard, handleDestroyKeyboard, null);
            all_seats.keyboards.append(keyboard_resource);
            keyboard_created_event.emit(keyboard_resource);
        },

        .get_touch => |req| {
            const touch_resource = wls.Touch.create(resource.getClient(), resource.getVersion(), req.id) catch {
                std.log.err("OOM", .{});
                return;
            };
            touch_resource.setHandler(?*anyopaque, handleRequestTouch, null, null);
            // I'm not gonna implement this
        },

        .release => {
            // No need to keep track of this
        },
    }
}

fn handleRequestPointer(resource: *wls.Pointer, request: wls.Pointer.Request, _: ?*anyopaque) void {
    switch (request) {
        .set_cursor => {
            // I'm not gonna implement this
        },

        .release => resource.destroy(),
    }
}

fn handleDestroyPointer(resource: *wls.Pointer, _: ?*anyopaque) void {
    resource.getLink().remove();
}

fn handleRequestKeyboard(resource: *wls.Keyboard, request: wls.Keyboard.Request, _: ?*anyopaque) void {
    switch (request) {
        .release => resource.destroy(),
    }
}

fn handleDestroyKeyboard(resource: *wls.Keyboard, _: ?*anyopaque) void {
    resource.getLink().remove();
}

fn handleRequestTouch(resource: *wls.Touch, request: wls.Touch.Request, _: ?*anyopaque) void {
    switch (request) {
        .release => resource.destroy(),
    }
}
