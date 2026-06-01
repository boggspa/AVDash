#!/bin/bash
# PowerMetrics Helper Uninstall Script
# Use this to completely remove the helper service for clean testing

set -e

HELPER_ID="com.chrisizatt.PodcastPreview.PowerMetricsService"
HELPER_PATH="/Library/PrivilegedHelperTools/$HELPER_ID"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_ID.plist"

echo "═══════════════════════════════════════════════════════════════"
echo "  PowerMetrics Helper Service Uninstaller"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "This will remove the PowerMetrics helper service from your system."
echo "This is useful for:"
echo "  - Testing fresh installations"
echo "  - Troubleshooting registration issues"
echo "  - Cleaning up after development"
echo ""

# Detect macOS version
OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
echo "macOS Version: $OS_VERSION"

if [ "$OS_MAJOR" -ge 13 ]; then
    echo "Note: On macOS 13+, SMAppService may auto-reinstall when app runs."
else
    echo "Using SMJobBless uninstall method."
fi
echo ""

read -p "Continue with uninstallation? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cancelled."
    exit 0
fi

echo ""
echo "─────────────────────────────────────────────────────────────"
echo "Unloading helper from launchd..."
echo "─────────────────────────────────────────────────────────────"

if sudo launchctl list | grep -q "$HELPER_ID"; then
    echo "Found running helper, unloading..."
    
    # Try bootout first (modern)
    if [ "$OS_MAJOR" -ge 11 ]; then
        sudo launchctl bootout system "$PLIST_PATH" 2>/dev/null || \
        sudo launchctl unload "$PLIST_PATH" 2>/dev/null || \
        echo "Helper may already be unloaded"
    else
        sudo launchctl unload "$PLIST_PATH" 2>/dev/null || \
        echo "Helper may already be unloaded"
    fi
    
    echo "[OK] Unloaded"
else
    echo "Helper not currently loaded"
fi

echo ""
echo "─────────────────────────────────────────────────────────────"
echo "Removing helper files..."
echo "─────────────────────────────────────────────────────────────"

# Remove plist
if [ -f "$PLIST_PATH" ]; then
    echo "Removing: $PLIST_PATH"
    sudo rm -f "$PLIST_PATH"
    echo "[OK] Removed plist"
else
    echo "Plist not found (already removed)"
fi

# Remove binary
if [ -f "$HELPER_PATH" ]; then
    echo "Removing: $HELPER_PATH"
    sudo rm -f "$HELPER_PATH"
    echo "[OK] Removed helper binary"
else
    echo "Helper binary not found (already removed)"
fi

# Remove logs
echo ""
echo "─────────────────────────────────────────────────────────────"
echo "Cleaning up logs..."
echo "─────────────────────────────────────────────────────────────"

if [ -f "/tmp/PowerMetricsService.stderr" ]; then
    rm -f /tmp/PowerMetricsService.stderr
    echo "[OK] Removed stderr log"
fi

if [ -f "/tmp/PowerMetricsService.stdout" ]; then
    rm -f /tmp/PowerMetricsService.stdout
    echo "[OK] Removed stdout log"
fi

# Check for SMAppService remnants (macOS 13+)
if [ "$OS_MAJOR" -ge 13 ]; then
    echo ""
    echo "─────────────────────────────────────────────────────────────"
    echo "Checking SMAppService locations..."
    echo "─────────────────────────────────────────────────────────────"
    
    SM_PATH="$HOME/Library/Application Support/com.apple.SMAppService"
    if [ -d "$SM_PATH" ]; then
        echo "Found SMAppService directory"
        
        # Look for our helper
        if find "$SM_PATH" -name "$HELPER_ID" -type f 2>/dev/null | grep -q .; then
            echo "Found helper in SMAppService locations"
            echo "Note: SMAppService manages these automatically"
            echo "They will be recreated when app runs"
        else
            echo "No helper found in SMAppService locations"
        fi
    fi
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Uninstallation Complete!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "The PowerMetrics helper service has been removed."
echo ""
echo "Next steps:"
echo "  1. Build and run your app to test fresh installation"
echo "  2. You may be prompted for authorization (expected on macOS 11-12)"
echo "  3. Check debug_helper.sh to verify reinstallation"
echo ""
echo "If you want to also remove the app:"
echo "  sudo rm -rf /Applications/PodcastPreview.app"
echo ""
