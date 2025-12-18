const std = @import("std");
const Scanner = @import("wayland").Scanner;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "waycraft",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.root_module.addImport("zalgebra", b.dependency("zalgebra", .{}).module("zalgebra"));

    exe.root_module.addImport("xkbcommon", b.dependency("xkbcommon", .{}).module("xkbcommon"));
    exe.linkSystemLibrary("xkbcommon");

    exe.root_module.addImport("zigimg", b.dependency("zigimg", .{}).module("zigimg"));

    exe.root_module.addImport("perlin", b.dependency("perlin", .{}).module("perlin"));

    // Wayland dependencies

    const scanner = Scanner.create(b, .{});
    scanner.addSystemProtocol("stable/xdg-shell/xdg-shell.xml");
    scanner.addSystemProtocol("stable/tablet/tablet-v2.xml");
    scanner.addSystemProtocol("unstable/pointer-constraints/pointer-constraints-unstable-v1.xml");
    scanner.addSystemProtocol("unstable/relative-pointer/relative-pointer-unstable-v1.xml");
    scanner.addSystemProtocol("staging/cursor-shape/cursor-shape-v1.xml");
    scanner.generate("wl_compositor", 6);
    scanner.generate("wl_shm", 2);
    scanner.generate("wl_output", 4);
    scanner.generate("wl_seat", 10);
    scanner.generate("wl_data_device_manager", 3);
    scanner.generate("wl_subcompositor", 1);
    scanner.generate("xdg_wm_base", 7);
    scanner.generate("zwp_tablet_manager_v2", 2);
    scanner.generate("wp_cursor_shape_manager_v1", 2);
    scanner.generate("zwp_pointer_constraints_v1", 1);
    scanner.generate("zwp_relative_pointer_manager_v1", 1);
    const wayland = b.createModule(.{ .root_source_file = scanner.result });

    exe.root_module.link_libc = true;
    exe.root_module.linkSystemLibrary("wayland-server", .{});
    exe.root_module.linkSystemLibrary("wayland-client", .{});
    exe.root_module.addImport("wayland", wayland);

    // Vulkan dependencies

    var env_map = try std.process.getEnvMap(b.allocator);
    defer env_map.deinit();
    var sdk_path: ?[]const u8 = null;
    if (env_map.get("VULKAN_SDK")) |_sdk_path| {
        sdk_path = _sdk_path;

        std.debug.print("Found Vulkan SDK: {s}\n", .{_sdk_path});

        const lib_path = b.pathJoin(&.{ _sdk_path, "lib" });
        const include_path = b.pathJoin(&.{ _sdk_path, "include" });

        exe.addLibraryPath(.{ .cwd_relative = lib_path });
        exe.addIncludePath(.{ .cwd_relative = include_path });

        std.debug.print("Added library path: {s}\n", .{lib_path});
        std.debug.print("Added include path: {s}\n", .{include_path});
    }

    const vk_lib_name = if (target.result.os.tag == .windows) "vulkan-1" else "vulkan";
    exe.linkSystemLibrary(vk_lib_name);

    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vulkan = b.dependency("vulkan", .{ .registry = registry }).module("vulkan-zig");
    exe.root_module.addImport("vulkan", vulkan);

    // Compile shaders

    const shader_names = [_][]const u8{
        "simple.vert", "simple.frag",
        "line.vert",   "line.frag",
    };

    for (shader_names) |name| {
        const compile_cmd = b.addSystemCommand(&.{
            "glslc",
            "--target-env=vulkan1.2",
            "-o",
        });
        const spv_name = b.fmt("{s}.spv", .{name});
        const spv = compile_cmd.addOutputFileArg(spv_name);
        compile_cmd.addFileArg(b.path(b.fmt("shaders/{s}", .{name})));
        exe.root_module.addAnonymousImport(spv_name, .{
            .root_source_file = spv,
        });
    }

    b.installArtifact(exe);

    // Run command

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Test step

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    // Check step (for ZLS)

    const exe_check = b.addExecutable(.{
        .name = "waycraft",
        .root_module = exe.root_module,
    });
    const check_step = b.step("check", "Check if it compiles");
    check_step.dependOn(&exe_check.step);
}
