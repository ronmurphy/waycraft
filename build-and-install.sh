#!/bin/bash
# Build and install waycraft binary to /usr/local/bin

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
chmod +x /usr/local/bin/waycraft

echo ""
echo "✅ Waycraft installed to /usr/local/bin/waycraft"
echo ""
echo "Waycraft is a fun 3D Minecraft-like environment for running Linux apps!"
echo "Perfect for:"
echo "  🎮 Teaching kids Linux in a game-like interface"
echo "  🎨 Experimenting with spatial window organization"
echo "  🎪 Showing off what Wayland + Vulkan + Zig can do"
echo ""
echo "To use waycraft:"
echo "1. Make sure you're in your normal desktop (LabWC, Plasma, Sway, etc.)"
echo "2. Run: waycraft              (opens in a window)"
echo "   or:  waycraft --desktop    (fullscreen immersive mode)"
echo ""
echo "Inside waycraft:"
echo "  • FIRST: Click anywhere to lock pointer and activate controls"
echo "  • Type / to enter commands (like /dolphin or /alacritty)"
echo "  • WASD to move, mouse to look around"
echo "  • Click on windows to focus them"
echo "  • Press Escape to unfocus or exit fullscreen"
echo ""
echo "NOTE: Waycraft is a NESTED compositor - it runs inside your existing"
echo "      desktop, not as a replacement for it. This is intentional!"
echo ""
