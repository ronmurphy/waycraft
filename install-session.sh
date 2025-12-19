#!/bin/bash
# ⚠️  WARNING: This script is DEPRECATED and will NOT work!
#
# Waycraft is a NESTED compositor that requires a parent Wayland compositor.
# It cannot run as a standalone session from the login screen.
#
# If you run this, waycraft will crash with "ConnectFailed" because there's
# no parent compositor to connect to.
#
# Use build-and-install.sh instead, then run waycraft from within your
# normal desktop session (LabWC, Plasma, Sway, etc.)

echo "⚠️  ERROR: This script is deprecated!"
echo ""
echo "Waycraft is a NESTED compositor and cannot run as a standalone session."
echo "It will crash with 'ConnectFailed' if you try to launch it from the login screen."
echo ""
echo "Instead:"
echo "  1. Run: sudo ./build-and-install.sh"
echo "  2. Log into your normal desktop (LabWC, Plasma, Sway, etc.)"
echo "  3. Open a terminal and run: waycraft"
echo ""
exit 1
