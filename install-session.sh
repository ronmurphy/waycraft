#!/bin/bash
# Install waycraft as a desktop session for SDDM/GDM/LightDM

set -e

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (use sudo)"
    exit 1
fi

# Build waycraft
echo "Building waycraft..."
zig build -Doptimize=ReleaseSafe

# Install binary
echo "Installing waycraft binary to /usr/local/bin..."
cp zig-out/bin/waycraft /usr/local/bin/

# Install desktop session file
echo "Installing Wayland session file..."
mkdir -p /usr/share/wayland-sessions
cp waycraft.desktop /usr/share/wayland-sessions/

echo ""
echo "✅ Waycraft installed successfully!"
echo ""
echo "To use waycraft:"
echo "1. Log out of your current session"
echo "2. At the login screen, click the session switcher (usually bottom-left or top-right)"
echo "3. Select 'Waycraft'"
echo "4. Log in"
echo ""
echo "Waycraft will run as a full desktop environment in 3D!"
