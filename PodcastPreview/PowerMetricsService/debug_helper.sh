#!/bin/bash
# PowerMetrics Helper Debug Script
# Run this to diagnose helper installation and XPC connection issues

set -e

HELPER_ID="com.chrisizatt.PodcastPreview.PowerMetricsService"
HELPER_PATH="/Library/PrivilegedHelperTools/$HELPER_ID"
PLIST_PATH="/Library/LaunchDaemons/$HELPER_ID.plist"

echo "═══════════════════════════════════════════════════════════════"
echo "  PowerMetrics Helper Service Diagnostic Tool"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Detect macOS version
OS_VERSION=$(sw_vers -productVersion)
OS_MAJOR=$(echo "$OS_VERSION" | cut -d. -f1)
echo "macOS Version: $OS_VERSION"

if [ "$OS_MAJOR" -ge 13 ]; then
    echo "Expected Method: SMAppService (modern)"
else
    echo "Expected Method: SMJobBless (legacy)"
fi
echo ""

# Check if helper is loaded in launchd
echo "─────────────────────────────────────────────────────────────"
echo "1. Launchd Status"
echo "─────────────────────────────────────────────────────────────"
if sudo launchctl list | grep -q "$HELPER_ID"; then
    echo "[OK] Helper is loaded in launchd"
    sudo launchctl list | grep "$HELPER_ID"
else
    echo "[FAIL] Helper NOT loaded in launchd"
fi
echo ""

# Check helper binary
echo "─────────────────────────────────────────────────────────────"
echo "2. Helper Binary"
echo "─────────────────────────────────────────────────────────────"
if [ -f "$HELPER_PATH" ]; then
    echo "[OK] Helper binary exists at: $HELPER_PATH"
    ls -lh "$HELPER_PATH"
    echo ""
    echo "Code Signing Info:"
    codesign -dv "$HELPER_PATH" 2>&1 | grep -E "(Identifier|Authority|TeamIdentifier)"
else
    echo "[FAIL] Helper binary NOT found at: $HELPER_PATH"
    
    # Check if it might be in SMAppService location
    if [ "$OS_MAJOR" -ge 13 ]; then
        echo ""
        echo "Checking SMAppService locations..."
        find ~/Library/Application\ Support/com.apple.SMAppService -name "$HELPER_ID" 2>/dev/null || echo "Not found in SMAppService directories"
    fi
fi
echo ""

# Check plist
echo "─────────────────────────────────────────────────────────────"
echo "3. Launchd Property List"
echo "─────────────────────────────────────────────────────────────"
if [ -f "$PLIST_PATH" ]; then
    echo "[OK] Launchd plist exists at: $PLIST_PATH"
    echo ""
    echo "Label:"
    /usr/libexec/PlistBuddy -c "Print :Label" "$PLIST_PATH" 2>/dev/null || echo "(not found)"
    echo ""
    echo "MachServices:"
    /usr/libexec/PlistBuddy -c "Print :MachServices" "$PLIST_PATH" 2>/dev/null || echo "(not found)"
else
    echo "[FAIL] Launchd plist NOT found at: $PLIST_PATH"
fi
echo ""

# Check stderr/stdout logs
echo "─────────────────────────────────────────────────────────────"
echo "4. Helper Logs"
echo "─────────────────────────────────────────────────────────────"
if [ -f "/tmp/PowerMetricsService.stderr" ]; then
    echo "[OK] stderr log exists"
    echo "Last 20 lines of stderr:"
    echo "---"
    tail -20 /tmp/PowerMetricsService.stderr
else
    echo "[FAIL] No stderr log found (helper may not have run yet)"
fi
echo ""

if [ -f "/tmp/PowerMetricsService.stdout" ]; then
    echo "[OK] stdout log exists"
    echo "Last 20 lines of stdout:"
    echo "---"
    tail -20 /tmp/PowerMetricsService.stdout
else
    echo "[FAIL] No stdout log found"
fi
echo ""

# Check app bundle
echo "─────────────────────────────────────────────────────────────"
echo "5. App Bundle Check"
echo "─────────────────────────────────────────────────────────────"
APP_PATH="/Applications/PodcastPreview.app"
if [ -d "$APP_PATH" ]; then
    echo "[OK] App found at: $APP_PATH"
    
    # Check if helper is embedded
    EMBEDDED_HELPER="$APP_PATH/Contents/Library/LaunchServices/$HELPER_ID"
    if [ -f "$EMBEDDED_HELPER" ]; then
        echo "[OK] Helper embedded in app bundle"
        ls -lh "$EMBEDDED_HELPER"
    else
        echo "[FAIL] Helper NOT embedded in app bundle at expected location:"
        echo "  Expected: $EMBEDDED_HELPER"
    fi
    
    # Check for launchd plist in resources
    RESOURCE_PLIST="$APP_PATH/Contents/Resources/PowerMetricsService-Info.plist"
    if [ -f "$RESOURCE_PLIST" ]; then
        echo "[OK] Launchd plist in app resources"
    else
        echo "[FAIL] Launchd plist NOT in app resources"
        echo "  Expected: $RESOURCE_PLIST"
    fi
    
    echo ""
    echo "Main App Code Signing:"
    codesign -dv "$APP_PATH" 2>&1 | grep -E "(Identifier|Authority|TeamIdentifier)"
else
    echo "[FAIL] App NOT found at: $APP_PATH"
    echo "  (Update APP_PATH in this script if installed elsewhere)"
fi
echo ""

# XPC Connection Test
echo "─────────────────────────────────────────────────────────────"
echo "6. XPC Connection Test"
echo "─────────────────────────────────────────────────────────────"
echo "To test XPC connection, run your app and check Console.app for:"
echo "  - Subsystem: com.chrisizatt.PodcastPreview"
echo "  - Category: PowerMetricsServiceRegistrar"
echo ""

# Recommendations
echo "═══════════════════════════════════════════════════════════════"
echo "  Recommendations"
echo "═══════════════════════════════════════════════════════════════"

ISSUES=0

if ! sudo launchctl list | grep -q "$HELPER_ID"; then
    echo "Helper not loaded. Try:"
    echo "   - Run your app to trigger registration"
    echo "   - Check Console.app for registration errors"
    ISSUES=$((ISSUES + 1))
fi

if [ ! -f "$HELPER_PATH" ] && [ "$OS_MAJOR" -lt 13 ]; then
    echo "Helper binary not installed (SMJobBless)"
    echo "   - Verify SMPrivilegedExecutables in app Info.plist"
    echo "   - Verify SMAuthorizedClients in helper Info.plist"
    echo "   - Ensure code signing matches"
    ISSUES=$((ISSUES + 1))
fi

if [ "$ISSUES" -eq 0 ]; then
    echo "[OK] No obvious issues detected!"
    echo ""
    echo "If you're still having problems:"
    echo "  1. Check Console.app logs during app launch"
    echo "  2. Verify Team ID in both Info.plists"
    echo "  3. Try uninstalling and reinstalling (see guide)"
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Offer to show live logs
read -p "Monitor helper logs in real-time? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Watching /tmp/PowerMetricsService.stderr (Ctrl+C to stop)..."
    touch /tmp/PowerMetricsService.stderr
    tail -f /tmp/PowerMetricsService.stderr
fi
