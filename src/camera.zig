const za = @import("zalgebra");
const Mat4 = za.Mat4;

pub const Camera = struct {
    half_fovy_degrees: f32,
    near: f32,
    far: f32,
    aspect: f32,
    transform: Mat4,
    projview: Mat4,

    pub fn new() Camera {
        var cam: Camera = .{
            .half_fovy_degrees = 33,
            .near = 0.1,
            .far = 10_000,
            .aspect = 1,
            .transform = .{
                .data = .{
                    .{ 1, 0, 0, 0 },
                    .{ 0, 1, 0, 0 },
                    .{ 0, 0, 1, 0 },
                    .{ 0.5, 0, 0.5, 1 },
                },
            },
            .projview = undefined,
        };
        cam.updateProjView();
        return cam;
    }

    pub fn updateProjView(cam: *Camera) void {
        const f = 1 / @tan(za.toRadians(cam.half_fovy_degrees));
        const x = 1 / (cam.far - cam.near);
        const proj = Mat4{
            .data = .{
                .{ f / cam.aspect, 0, 0, 0 },
                .{ 0, -f, 0, 0 },
                .{ 0, 0, (cam.far + cam.near) * x, 1 },
                .{ 0, 0, -2 * cam.far * cam.near * x, 0 },
            },
        };
        cam.projview = proj.mul(cam.transform.inv());
    }
};
