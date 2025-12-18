const xkb = @import("xkbcommon");

pub fn StackArray(T: type, capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]?T,
        len: usize,

        pub fn init() Self {
            return .{
                .items = .{null} ** capacity,
                .len = 0,
            };
        }

        pub fn add(arr: *Self, item: T) !void {
            if (arr.len == capacity) {
                return error.ArrayIsFull;
            }
            arr.items[arr.len] = item;
            arr.len += 1;
        }

        pub fn remove(arr: *Self, item: T) void {
            var i: usize = 0;

            // Reach the index of the item
            while (i < arr.len) {
                if (arr.items[i] == item) {
                    break;
                }
                i += 1;
            } else {
                // Item not included
                return;
            }

            while (i < arr.len - 1) {
                arr.items[i] = arr.items[i + 1];
                i += 1;
            }
            arr.items[arr.len - 1] = null;
            arr.len -= 1;
        }

        pub fn clear(arr: *Self) void {
            arr.len = 0;
        }

        pub fn contains(arr: *const Self, item: T) bool {
            for (arr.items) |arr_item| {
                if (item == arr_item) {
                    return true;
                }
            }
            return false;
        }
    };
}
