#!/bin/bash

# Waycraft - Arch Linux dependency installer

set -e

echo "Installing Waycraft dependencies for Arch Linux..."
echo ""

# Check if running on Arch Linux
if [ ! -f /etc/arch-release ]; then
    echo "Warning: This script is designed for Arch Linux"
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Install dependencies
sudo pacman -S --needed \
    zig \
    wayland \
    wayland-protocols \
    libxkbcommon \
    vulkan-devel \
    vulkan-validation-layers \
    shaderc

echo ""
echo "Dependencies installed successfully!"
echo ""
echo "You can now build and run waycraft:"
echo "  zig build        # Compile the project"
echo "  zig build run    # Build and run"
