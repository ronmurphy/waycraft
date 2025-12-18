const std = @import("std");
const xkb = @import("xkbcommon");
const za = @import("zalgebra");
const Mat4 = za.Mat4;
const Vec3 = za.Vec3;
const Vec4 = za.Vec4;
const Camera = @import("camera.zig").Camera;
const StackArray = @import("stack_array.zig").StackArray;
const World = @import("world.zig").World;
const Ray = @import("world.zig").Ray;
const Box = @import("world.zig").Box;
const rayIntersectsBox = @import("world.zig").rayIntersectsBox;

pub const CamController = struct {
    cam: *Camera,

    rotx: f32,
    roty: f32,
    velocity: Vec3,
    is_on_ground: bool,

    // It's unlikely the user will be pressing more than 10 keys at once
    // (they only have 10 fingers (probably))
    pressed_keys: StackArray(xkb.Keysym, 10),

    pub fn new(cam: *Camera) CamController {
        return .{
            .cam = cam,

            .rotx = 0,
            .roty = 0,
            .velocity = .zero(),
            .is_on_ground = false,

            .pressed_keys = .init(),
        };
    }

    const player_size: Vec3 = .new(0.25, 2, 0.25);
    const half_player_size = player_size.mul(.set(0.5));
    pub fn update(cc: *CamController, world: *World, dt: f32) void {
        const cam_pos = world.cam.transform.extractTranslation();
        const floor_ray = Ray{ .p0 = cam_pos, .dir = .new(0, -1, 0) };
        cc.is_on_ground = world.raycast(floor_ray, player_size.y()) != null;

        var input_vec = Vec3.zero();
        if (cc.pressed_keys.contains(.w)) {
            input_vec = input_vec.add(Vec3.new(0, 0, 1));
        }
        if (cc.pressed_keys.contains(.s)) {
            input_vec = input_vec.add(Vec3.new(0, 0, -1));
        }
        if (cc.pressed_keys.contains(.a)) {
            input_vec = input_vec.add(Vec3.new(-1, 0, 0));
        }
        if (cc.pressed_keys.contains(.d)) {
            input_vec = input_vec.add(Vec3.new(1, 0, 0));
        }
        if (cc.pressed_keys.contains(.space)) {
            input_vec = input_vec.add(Vec3.new(0, 1, 0));
        }
        if (cc.pressed_keys.contains(.Shift_L)) {
            input_vec = input_vec.add(Vec3.new(0, -1, 0));
        }
        input_vec = input_vec.norm().mul(.set(dt * 5));
        const horizontal_rot = Mat4.fromRotation(cc.rotx, .new(0, 1, 0));
        input_vec = horizontal_rot.mulByVec3(input_vec);

        var y_velocity: f32 = undefined;
        if (cc.is_on_ground) {
            if (cc.pressed_keys.contains(.space)) {
                y_velocity = 0.5;
            } else {
                y_velocity = @max(0, cc.velocity.y());
            }
        } else {
            y_velocity = cc.velocity.y() - 1 * dt;
        }

        cc.velocity = .new(input_vec.x(), y_velocity, input_vec.z());

        // const new_pos = cc.cam.transform.extractTranslation().add(cc.velocity);
        // const new_cam_box = Box{
        //     .min = new_pos.sub(.new(half_player_size.x(), player_size.y(), half_player_size.z())),
        //     .max = new_pos.add(.new(half_player_size.x(), 0, half_player_size.z())),
        // };
        // if (world.collides(new_cam_box)) |block_box| {
        //     const ray = Ray{ .p0 = cc.cam.transform.extractTranslation(), .dir = cc.velocity.norm() };
        //     const expanded_block_box = Box{
        //         .min = block_box.min.sub(half_player_size),
        //         .max = block_box.max.add(half_player_size),
        //     };
        //     var dist: f32 = undefined;
        //     if (rayIntersectsBox(ray, expanded_block_box, &dist)) {
        //         const hit_pos = ray.p0.add(ray.dir.mul(.set(dist)));
        //         cc.cam.transform.data[3] = .{ hit_pos.x(), hit_pos.y(), hit_pos.z(), 1 };
        //         cc.velocity = .zero();
        //     }
        // }

        cc.cam.transform = cc.cam.transform.translate(cc.velocity);
        cc.cam.updateProjView();
    }

    pub fn pointerMoved(cc: *CamController, dx: f32, dy: f32) void {
        const sensitivity = 0.1;
        cc.rotx += dx * sensitivity;
        cc.roty += dy * sensitivity;
        var transform = Mat4.fromEulerAngles(.new(cc.roty, cc.rotx, 0));
        transform.data[3] = cc.cam.transform.data[3];
        cc.cam.transform = transform;
        cc.cam.updateProjView();
    }

    pub fn keyPressed(cc: *CamController, key: xkb.Keysym) void {
        cc.pressed_keys.add(xkb.Keysym.toLower(key)) catch |err| switch (err) {
            error.ArrayIsFull => {},
        };
    }

    pub fn keyReleased(cc: *CamController, key: xkb.Keysym) void {
        cc.pressed_keys.remove(xkb.Keysym.toLower(key));
    }

    pub fn keyReleasedAll(cc: *CamController) void {
        cc.pressed_keys.clear();
    }
};
