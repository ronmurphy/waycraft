# Waycraft Development Roadmap

A 3D spatial window manager that organizes applications in virtual space.

## Core Philosophy
Make waycraft a **practical 3D workspace** with spatial organization, not just a tech demo.

**Target Audiences:**
1. **Power users**: Want spatial organization for productivity
2. **Kids/Linux newcomers**: Minecraft-like introduction to Linux desktop computing
3. **Creative users**: Build custom workspaces, movie theaters, collaborative spaces

The Minecraft-familiar interface makes Linux approachable for young users while being genuinely useful for professionals. Focus on making it both fun and functional.

---

## Phase 1: Quick Wins (Tonight - 2-3 hours)
Essential usability improvements that make the experience dramatically better.

- [x] **Two-sided window rendering** (~30 min)
  - Render windows on front AND back faces
  - No more circling blocks to find content
  - Improves navigation significantly
  - *Files: `src/toplevel_renderable.zig`*

- [x] **Visual focus indicator** (~45 min)
  - Cyan wireframe box around active window
  - Instantly see what has keyboard/mouse focus
  - Uses separate LineMaterial with cyan color
  - *Files: `src/renderer.zig`, `src/line_material.zig`*

- [x] **Snap to grid** (~30 min)
  - Press G key to align active window to nearest block
  - Makes layouts clean and professional
  - Easy to organize windows precisely
  - *Files: `src/world.zig` (keyPressed)*

---

## Phase 2: Core Productivity (This Week - 6-8 hours)

### Window Management
- [x] **Window sizing with flags** (Experimental)
  - `/dolphin 3w 2h` - create 3-wide by 2-tall window
  - Works for simple cases, mouse mapping has edge cases
  - Default 1×1 works perfectly
  - *Files: `src/world.zig`, `src/protocols/xdg_shell.zig`*

- [ ] **Window rotation with flags** (~1 hour)
  - `/gimp 3w 2h 90r` - rotate window 90 degrees
  - Support 0, 90, 180, 270 degree rotation
  - Add to flag parser, modify geometry generation
  - *Files: `src/world.zig` (parseCommand), `src/toplevel_renderable.zig`*

- [ ] **Save/Load layouts** (~2 hours)
  - Persist window positions, sizes, rotations to JSON
  - Load on startup or via `/load layout-name`
  - Store in `~/.config/waycraft/layouts/`
  - Makes waycraft practical for daily use
  - *Files: Create `src/layout.zig`, modify `src/world.zig`*

### File Associations & Launching
- [ ] **File type associations** (~2 hours)
  - External config file: `~/.config/waycraft/mimeapps.conf`
  - Format: `mkv=mpv`, `pdf=zathura`, `jpg=feh`
  - Type filename in console → auto-launches app
  - Example: `/~/Videos/movie.mkv` → opens in mpv
  - Support size hints: `mkv=mpv:4w:3h` (default size for mkv files)
  - *Files: Create `src/file_associations.zig`, modify `src/world.zig`*

- [ ] **Direct file opening** (~1 hour)
  - `/open ~/Documents/file.pdf` → opens in associated app
  - `/open file.mkv 5w 4h` → override default size
  - Parse file extensions, launch correct app
  - *Files: `src/world.zig` (command handler)*

### Spatial Organization
- [ ] **Rooms/Virtual Workspaces with Portals** (~3 hours) ⭐
  - Different "rooms" = different contexts/workspaces
  - Walk through portal blocks to switch rooms
  - Each room has its own chunk space and windows
  - Room switcher UI (press Tab to see all rooms?)
  - Examples:
    - Work Room: Editors, terminals, documentation
    - Media Room: Video players, music apps
    - Social Room: Discord, chat apps, email
    - Research Room: Browsers, PDFs, notes
  - Rooms are persistent across sessions
  - *Files: Create `src/room.zig`, modify `src/world.zig`, `src/main.zig`*

---

## Phase 3: Creative Features (Next 2 Weeks - 10-15 hours)

### Building & Placement
- [ ] **Placeable building blocks** (~2 hours)
  - Left-click empty space to place grass/stone/wood blocks
  - Build walls, floors, structures
  - Create literal "rooms" and "desks" and "walls"
  - Block inventory/hotbar (press 1-9 to select block type)
  - *Files: `src/world.zig`, `src/chunk.zig`*

- [ ] **Mount windows on walls** (~1 hour)
  - Place window on any block face, not just in front of you
  - Right-click block face → next window spawns there
  - Build a "desk" and mount terminal above it
  - Build a "theater wall" and mount video player
  - *Files: `src/world.zig` (pointer interaction), `src/toplevel_renderable.zig`*

- [ ] **Delete blocks** (~30 min)
  - Currently can only destroy windows
  - Allow breaking placed blocks (not terrain)
  - Shift+Left-click to break blocks?
  - *Files: `src/world.zig`*

### Media & Theater Mode
- [ ] **Media theater setup** (~1 hour)
  - Build a room with blocks
  - Place large video player on wall: `/mpv movie.mkv 8w 6h`
  - "Cinema mode" - darken surroundings, focus on screen
  - Could pause world updates when watching
  - *Combines building + file associations + large windows*

### Polish
- [ ] **Minimap/Overview mode** (~2 hours)
  - Press M for top-down map view of current room
  - Shows all window positions
  - Click to teleport camera to that location
  - Essential for navigation in large spaces
  - *Files: Create `src/minimap.zig`, modify `src/renderer.zig`*

- [ ] **Window gravity/stacking** (~2 hours)
  - Windows "fall" and stack on ground or other windows
  - Physics-based automatic organization
  - Option to toggle physics per window
  - *Files: `src/world.zig`, `src/physics.zig`*

- [ ] **Smooth camera transitions** (~1 hour)
  - Animate camera when teleporting between rooms
  - Smooth focus transitions
  - Makes movement feel polished
  - *Files: `src/camera.zig`, `src/cam_controller.zig`*

---

## Running Waycraft as a Desktop Environment

Waycraft can be run as a standalone desktop session from your login screen!

**Installation:**
```bash
sudo ./install-session.sh
```

This installs:
- Waycraft binary to `/usr/local/bin/waycraft`
- Session file to `/usr/share/wayland-sessions/waycraft.desktop`

**Usage:**
1. Log out
2. At login screen, select "Waycraft" from the session menu
3. Log in - you'll boot directly into the 3D environment!

**Benefits:**
- No nested compositor issues
- Apps launched from waycraft stay in waycraft
- Full control of the display
- Proper desktop environment experience

---

## Phase 4: Advanced Features (Future)

### Multi-user & Collaboration
- [ ] **Shared spaces** (~8 hours)
  - Multiple users in same waycraft world
  - See each other's cursors and windows
  - Collaborative workspaces
  - *Major undertaking - networking required*

### Performance & Stability
- [ ] **Multi-monitor support**
  - Detect and use all connected displays
  - Each monitor = portal to different room?

- [ ] **Vulkan performance optimizations**
  - Fix buffer destruction timing issues
  - Implement proper memory pooling
  - Reduce validation warnings

- [ ] **Better collision detection**
  - Re-enable player collision with blocks
  - Prevent walking through walls/windows
  - Make built structures feel solid

### Configuration & Customization
- [ ] **Config file for settings**
  - Movement speed, mouse sensitivity
  - Key bindings
  - Default window sizes per app
  - Theme/colors

- [ ] **Custom block textures**
  - User-provided texture packs
  - Change grass/stone appearance
  - Personalize your workspace

- [ ] **Window transparency/blur**
  - See-through windows
  - Blur inactive windows
  - Layer windows in 3D space

---

## Example Use Cases

### Daily Productivity Workflow
```
🏠 Morning:
1. Launch waycraft
2. Auto-load "work" layout
3. Work Room loads with:
   - Code editor (4w 3h) on left wall
   - 3 terminals (2w 2h each) stacked on right
   - Documentation browser (3w 4h) on back wall
4. Type "/open daily-notes.md" → opens in editor
5. Work for hours with spatial organization
```

### Movie Night
```
🎬 Evening:
1. Switch to Media Room (walk through portal)
2. Use building mode to create theater:
   - Place wall blocks in a curve
   - Mount large video player: /mpv movie.mkv 10w 6h
3. Type: ~/Videos/movie.mkv
   - Auto-detects .mkv → launches mpv
   - Uses configured default size (10w 6h)
4. Sit back and watch in your custom theater
```

### Research Session
```
📚 Research:
1. Research Room with L-shaped desk
2. Main browser (5w 4h) on main wall
3. PDF viewer (3w 4h) on side wall
4. Note-taking app (2w 3h) on desk
5. Reference images scattered on walls
6. Everything persists for tomorrow
```

---

## Technical Architecture Notes

### File Association Format
```conf
# ~/.config/waycraft/mimeapps.conf
# Format: extension=app[:default_width:default_height[:rotation]]

# Video
mkv=mpv:6:4
mp4=mpv:6:4
avi=mpv:6:4

# Documents
pdf=zathura:3:4
txt=nvim:4:3
md=nvim:4:3

# Images
jpg=feh:4:4
png=feh:4:4
gif=mpv:4:4

# Audio
mp3=mpv:2:1
flac=mpv:2:1
```

### Layout File Format (JSON)
```json
{
  "name": "work-layout",
  "room": "Work",
  "windows": [
    {
      "command": "nvim project.zig",
      "position": {"x": 5, "y": 1, "z": 3},
      "size": {"w": 4, "h": 3},
      "rotation": 0
    },
    {
      "command": "alacritty",
      "position": {"x": 10, "y": 1, "z": 3},
      "size": {"w": 2, "h": 2},
      "rotation": 90
    }
  ]
}
```

---

## Contributing

When implementing features:
1. Test with multiple apps (alacritty, dolphin, gimp, mpv)
2. Update this roadmap with completion status
3. Document any new command flags or config options
4. Commit with clear messages explaining the feature

---

*Last Updated: 2025-12-17*
*Status: Phase 1 in progress*
