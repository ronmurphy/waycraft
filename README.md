# waycraft
a wayland compositor in a minecraft like world
run your apps inside of this virtual environment.

![waycraft](https://github.com/user-attachments/assets/f0ed5837-38b8-4bc6-85c1-1eddb1372cbd)

## Controls
- **WASD**: Move
- **Space**: Jump
- **Shift**: Sneak
- **Left Click**: Break block / Close window
- **Right Click**: Focus window
- **G**: Snap active window to grid

## Running Applications

Press `/` to open the command entry mode, type a command, and hit enter:
- `/thunar`: Launch Thunar (if it's already running on your desktop, it may just focus the existing window)
- `/drs thunar`: Launch Thunar in an isolated D-Bus session (forces a new instance inside Waycraft)
- `/screencap`: Take a screenshot
- `/exit`: Exit Waycraft

> [!WARNING]
> This is super alpha software. It may crash often!
