# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Waycraft is a 3D spatial Wayland compositor written in Zig that renders applications as textures on blocks in a Minecraft-like virtual world. Users navigate in first-person and interact with applications as 3D objects in space.

**Key Concept**: Applications launched from waycraft connect to it as their Wayland compositor. Their window contents are rendered as textures on block faces in the 3D world.

**Purpose**: Waycraft is designed as:
- 🎮 An **educational tool** introducing kids to Linux through a Minecraft-familiar interface
- 🎨 A **spatial playground** for experimenting with 3D window organization
- 🎪 A **fun demo** showing what's possible with Wayland/Vulkan/Zig
- **NOT** a practical desktop replacement for daily productivity work

## Build System

Built using Zig's build system. The project requires:
- Zig compiler
- Vulkan SDK (set `VULKAN_SDK` environment variable)
- Wayland libraries (client and server)
- xkbcommon library
- glslc shader compiler (for GLSL to SPIR-V compilation)

### Common Commands

**Build the project:**
```bash
zig build
```

**Run waycraft:**
```bash
zig build run
```

**Check compilation (useful for ZLS):**
```bash
zig build check
```

**Run tests:**
```bash
zig build test
```

**Install dependencies (Arch Linux):**
```bash
./install.sh
```
Installs Zig, Wayland, Vulkan, and other required packages.

**Build and install to system PATH:**
```bash
sudo ./build-and-install.sh
```
Builds waycraft and installs the binary to `/usr/local/bin/waycraft`.

**Run in windowed mode:**
```bash
waycraft
```
Opens in a 1280x720 window.

**Run in immersive/fullscreen mode:**
```bash
waycraft --desktop
```
Requests fullscreen from the parent compositor.

**First time usage:**
1. When waycraft opens, you'll see "Click to start - then type / for commands"
2. **Click anywhere in the window** to lock the pointer and activate controls
3. Now you can use WASD to move, mouse to look, and type `/` for commands

This click requirement prevents the parent compositor from stealing keyboard input (e.g., Plasma's KRunner intercepting `/firefox` and launching it on the parent desktop instead of inside waycraft).

**IMPORTANT:** Waycraft is a **nested compositor** - it must run inside another Wayland compositor (like Plasma, Sway, or LabWC). It cannot run as a standalone session from a login manager because it requires a parent compositor to connect to. This is by design - waycraft is meant to be a fun environment you can jump in and out of, not a replacement for your actual desktop.

## Architecture

### Dual Compositor Role (Nested Architecture)

Waycraft is a **nested compositor** that acts as both a Wayland **client** and **server**:

1. **Client of parent compositor**: Connects to a host Wayland compositor (e.g., Plasma, Sway, LabWC) to create a window where the 3D world is rendered. **This parent compositor is required** - waycraft cannot run standalone.
2. **Server to child applications**: Provides Wayland compositor services to applications launched from within waycraft

**Critical limitation**: Waycraft cannot run as a primary compositor from a login manager. It will fail with `ConnectFailed` because `wl_backend.zig:64` always tries to connect to a parent Wayland display. To run as a standalone compositor would require significant architectural changes (DRM/KMS rendering, libinput handling, no parent connection).

### Core Components

**main.zig**: Entry point. Sets up the Wayland server event loop, creates protocol globals, and starts the update timer (30 FPS). Also spawns a test client thread.

**wl_backend.zig (WlBackend)**: Manages waycraft's role as a Wayland client. Connects to the parent compositor, sets up input handling (keyboard/mouse), manages pointer locking, and owns the Renderer.

**world.zig (World)**: Central game logic. Manages:
- Camera and camera controller
- Chunk system for terrain generation (Perlin noise-based)
- Toplevel renderables (windows as 3D objects)
- Active window focus tracking
- Command input system (type `/` then command to spawn apps)
- Raycast system for selecting blocks/windows with crosshair
- Keyboard/mouse input routing to active window or world navigation

**renderer.zig (Renderer)**: Vulkan rendering pipeline. Manages:
- Swapchain and framebuffers
- Render passes and command buffer recording
- Materials (SimpleMaterial for textured quads, LineMaterial for wireframes)
- Drawing chunks, windows, selection box, focus indicator, and center crosshair
- Screenshot functionality (press S key)
- Deferred resource destruction (per-frame cleanup queues)

**protocols/**: Wayland protocol implementations. Each file implements a specific Wayland protocol global (compositor, shm, seat, xdg_shell, etc.). These handle requests from client applications.

**toplevel_renderable.zig (ToplevelRenderable)**: Represents an application window as a 3D object. Creates geometry for rendering window contents on block faces (supports single-sided or two-sided rendering based on WindowSpec).

**chunk.zig**: Defines the chunk system and block types. Chunks are 16×16×256 blocks. Blocks can be terrain (grass, stone) or toplevels (application windows).

**graphics_context.zig (GraphicsContext)**: Vulkan instance, device, and queue setup. Handles physical device selection and VK-WSI integration.

**geometry.zig**: Vertex buffer and index buffer management for renderable meshes.

**camera.zig / cam_controller.zig**: First-person camera with WASD+mouse look controls. Supports flying (no gravity).

### Window Launch System

When the user types `/command args` in waycraft:
1. World parses the command and optional flags (e.g., `/gimp 3w 2h` = 3 blocks wide, 2 tall)
2. World spawns the process with WAYLAND_DISPLAY set to waycraft's socket
3. The app connects to waycraft as a Wayland client
4. Protocols handle the window creation (xdg_shell, compositor, etc.)
5. WlBackend.appendToplevel creates a ToplevelRenderable in the World
6. The window appears as a textured block in front of the player

### Input Routing

**Escape key behavior**:
- If a window is focused: Unfocus the window, return control to world navigation
- If no window is focused AND pointer is locked: Unlock pointer, show cursor

**When no window is focused**: Input controls camera (WASD movement, mouse look)

**When a window is focused**: Keyboard and mouse input are forwarded to that application via Wayland protocols

**Focus acquisition**: Click on a window (raycasted from center crosshair) to focus it

### Shader Pipeline

Shaders are in `shaders/` and compiled to SPIR-V during build:
- `simple.vert/frag`: Textured quad rendering (used for terrain and windows)
- `line.vert/frag`: Line rendering (used for selection box and focus indicator)

Compiled shaders are embedded as anonymous imports in the executable.

### Material System

**SimpleMaterial**: Binds a texture, creates descriptor sets, and has a graphics pipeline for textured rendering.

**LineMaterial**: Renders wireframe lines with a solid color (used for selection box in black, focus indicator in cyan).

### Resource Management

Vulkan resources (buffers, images, pipelines, descriptor pools) cannot be destroyed immediately as they may still be in use by in-flight frames. The Renderer maintains per-frame destruction queues (`bufs_to_destroy`, `images_to_destroy`, etc.) indexed by `frame_index`. Resources are queued for destruction and actually destroyed when that frame index comes around again (after the fence wait confirms the frame is done).

## Development Notes

- The project uses `std.heap.c_allocator` throughout (`const alloc = std.heap.c_allocator`)
- When adding new Wayland protocol bindings, use the Scanner in build.zig to generate code from XML
- The frame rate is hardcoded to ~30 FPS in main.zig (`millis_between_updates`)
- Collision detection with blocks is currently disabled (commented out in world.zig) to prevent getting stuck
- Window buffers are destroyed after 2 frames to avoid use-after-free with in-flight rendering

## Key Features (from ROADMAP.md)

- Two-sided window rendering: Windows appear on both front and back faces
- Visual focus indicator: Cyan wireframe box around active window
- Snap to grid: Press G to align active window to nearest block position
- Window sizing with flags: Launch with size like `/dolphin 3w 2h`
- Screenshot: Press S key (saves to ~/Pictures/waycraft_timestamp.png)

## Testing

The `test_client.zig` provides commented-out code for spawning test applications. Currently it does nothing by default. Uncomment the process spawn lines to automatically launch apps on startup.

To manually test, run waycraft and type commands like:
- `/alacritty` - terminal
- `/dolphin` - file manager
- `/mpv video.mp4` - video player
- `/gimp 3w 2h` - GIMP sized 3 blocks wide by 2 tall
