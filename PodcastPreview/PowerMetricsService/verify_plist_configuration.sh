#!/bin/bash
# verify_plist_configuration.sh
# Quick verification script for SMJobBless plist configuration

set +e

APP_PATH="/Applications/PodcastPreview.app"
MAIN_PLIST="$APP_PATH/Contents/Info.plist"
HELPER_PATH="$APP_PATH/Contents/Library/LaunchServices/com.chrisizatt.PodcastPreview.PowerMetricsService"
EXPECTED_TEAM_ID="QWB2SUQVJ3"
HELPER_ID="com.chrisizatt.PodcastPreview.PowerMetricsService"

echo "═══════════════════════════════════════════════════════════════"
echo "  SMJobBless Plist Configuration Verification"
echo "═══════════════════════════════════════════════════════════════"
echo ""

ISSUES=0

# 1. Check main app Info.plist
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "1. Main App Info.plist"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$MAIN_PLIST" ]; then
    echo "FAIL: App not found at $APP_PATH"
    echo "   Build and install to /Applications first"
    exit 1
fi

echo "Checking for SMPrivilegedExecutables..."
if /usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables" "$MAIN_PLIST" &>/dev/null; then
    echo "PASS: SMPrivilegedExecutables key exists"
    
    # Check if helper ID is present
    if /usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables:$HELPER_ID" "$MAIN_PLIST" &>/dev/null; then
        echo "PASS: Helper ID found in SMPrivilegedExecutables"
        
        # Get the requirement string
        REQ=$(/usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables:$HELPER_ID" "$MAIN_PLIST")
        echo ""
        echo "Requirement string:"
        echo "$REQ"
        echo ""
        
        # Check if Team ID is in requirement
        if echo "$REQ" | grep -q "$EXPECTED_TEAM_ID"; then
            echo "PASS: Team ID ($EXPECTED_TEAM_ID) found in requirement"
        else
            echo "FAIL: Team ID ($EXPECTED_TEAM_ID) NOT found in requirement"
            echo "   Expected to see: certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\""
            ISSUES=$((ISSUES + 1))
        fi
        
        # Check for proper identifier
        if echo "$REQ" | grep -q "identifier \"$HELPER_ID\""; then
            echo "PASS: Helper identifier found in requirement"
        else
            echo "FAIL: Helper identifier NOT found correctly"
            echo "   Expected: identifier \"$HELPER_ID\""
            ISSUES=$((ISSUES + 1))
        fi
        
    else
        echo "FAIL: Helper ID ($HELPER_ID) not in SMPrivilegedExecutables"
        echo "   Add this key with code signing requirement"
        ISSUES=$((ISSUES + 1))
    fi
else
    echo "FAIL: SMPrivilegedExecutables key missing!"
    echo ""
    echo "Add this to your main app's Info.plist:"
    echo ""
    echo "<key>SMPrivilegedExecutables</key>"
    echo "<dict>"
    echo "    <key>$HELPER_ID</key>"
    echo "    <string>anchor apple generic and identifier \"$HELPER_ID\" and (certificate leaf[field.1.2.840.113635.100.6.1.9] or certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"$EXPECTED_TEAM_ID\")</string>"
    echo "</dict>"
    echo ""
    ISSUES=$((ISSUES + 1))
fi

echo ""

# 2. Check helper binary (embedded plist)
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "2. Helper Binary Info.plist"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ ! -f "$HELPER_PATH" ]; then
    echo "FAIL: Helper binary not found at:"
    echo "   $HELPER_PATH"
    echo "   Check Copy Files build phase"
    ISSUES=$((ISSUES + 1))
else
    echo "PASS: Helper binary exists"
    
    # Extract Info.plist from helper binary
    echo ""
    echo "Checking embedded plist for required keys..."
    
    # Check for Label key
    if strings "$HELPER_PATH" | grep -A1 "<key>Label</key>" | grep -q "<string>$HELPER_ID</string>"; then
        echo "PASS: Label key found and correct"
    else
        if strings "$HELPER_PATH" | grep -q "<key>Label</key>"; then
            echo "WARN: Label key found but may not match helper ID"
            echo "   Expected: <string>$HELPER_ID</string>"
        else
            echo "FAIL: Label key MISSING from helper plist"
            echo "   This is REQUIRED for launchd"
            echo "   Add to PowerMetricsService-Helper-Info.plist:"
            echo "   <key>Label</key>"
            echo "   <string>$HELPER_ID</string>"
            ISSUES=$((ISSUES + 1))
        fi
    fi
    
    # Check for SMAuthorizedClients
    if strings "$HELPER_PATH" | grep -q "SMAuthorizedClients"; then
        echo "PASS: SMAuthorizedClients key found"
        
        # Check if Team ID is in it
        if strings "$HELPER_PATH" | grep -A5 "SMAuthorizedClients" | grep -q "$EXPECTED_TEAM_ID"; then
            echo "PASS: Team ID ($EXPECTED_TEAM_ID) found in SMAuthorizedClients"
        else
            echo "WARN: Team ID might not be in SMAuthorizedClients"
            ISSUES=$((ISSUES + 1))
        fi
    else
        echo "FAIL: SMAuthorizedClients key missing"
        ISSUES=$((ISSUES + 1))
    fi
    
    # Check for MachServices
    if strings "$HELPER_PATH" | grep -q "MachServices"; then
        echo "PASS: MachServices key found"
    else
        echo "FAIL: MachServices key missing"
        ISSUES=$((ISSUES + 1))
    fi
    
    # Check for invalid Clients key
    if strings "$HELPER_PATH" | grep -q "<key>Clients</key>"; then
        echo "FAIL: Invalid 'Clients' key found!"
        echo "   This is not a standard launchd key and should be removed"
        ISSUES=$((ISSUES + 1))
    else
        echo "PASS: No invalid 'Clients' key found"
    fi
fi

echo ""

# 3. Code signing verification
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "3. Code Signing"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -d "$APP_PATH" ]; then
    MAIN_TEAM=$(codesign -dv "$APP_PATH" 2>&1 | grep TeamIdentifier | cut -d'=' -f2)
    echo "Main app Team ID: $MAIN_TEAM"
    
    if [ "$MAIN_TEAM" = "$EXPECTED_TEAM_ID" ]; then
        echo "PASS: Main app signed with expected Team ID"
    else
        echo "FAIL: Team ID mismatch"
        echo "   Expected: $EXPECTED_TEAM_ID"
        echo "   Found:    $MAIN_TEAM"
        ISSUES=$((ISSUES + 1))
    fi
fi

if [ -f "$HELPER_PATH" ]; then
    HELPER_TEAM=$(codesign -dv "$HELPER_PATH" 2>&1 | grep TeamIdentifier | cut -d'=' -f2)
    echo "Helper Team ID:   $HELPER_TEAM"
    
    if [ "$HELPER_TEAM" = "$EXPECTED_TEAM_ID" ]; then
        echo "PASS: Helper signed with expected Team ID"
    else
        echo "FAIL: Helper Team ID mismatch"
        echo "   Expected: $EXPECTED_TEAM_ID"
        echo "   Found:    $HELPER_TEAM"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [ "$MAIN_TEAM" = "$HELPER_TEAM" ]; then
        echo "PASS: Team IDs match between app and helper"
    else
        echo "FAIL: Team IDs don't match!"
        ISSUES=$((ISSUES + 1))
    fi
fi

echo ""

# 4. Test requirement against helper
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "4. Requirement Validation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [ -f "$MAIN_PLIST" ] && [ -f "$HELPER_PATH" ]; then
    if /usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables:$HELPER_ID" "$MAIN_PLIST" &>/dev/null; then
        REQ=$(/usr/libexec/PlistBuddy -c "Print :SMPrivilegedExecutables:$HELPER_ID" "$MAIN_PLIST")
        
        echo "Testing if helper satisfies app's requirement..."
        if codesign -v -R="$REQ" "$HELPER_PATH" 2>&1; then
            echo "PASS: Helper satisfies requirement!"
        else
            echo "FAIL: Helper does NOT satisfy requirement"
            echo "   This will cause SMJobBless to fail"
            ISSUES=$((ISSUES + 1))
        fi
    fi
fi

echo ""

# Summary
echo "═══════════════════════════════════════════════════════════════"
echo "  Summary"
echo "═══════════════════════════════════════════════════════════════"

if [ "$ISSUES" -eq 0 ]; then
    echo "ALL CHECKS PASSED!"
    echo ""
    echo "Your plist configuration looks correct for SMJobBless."
    echo ""
    echo "If SMJobBless still fails, check:"
    echo "  • Hardened Runtime enabled on both targets"
    echo "  • Helper embedded in Contents/Library/LaunchServices/"
    echo "  • System logs during blessing attempt"
else
    echo "FOUND $ISSUES ISSUE(S)"
    echo ""
    echo "Fix the issues above and rebuild before testing SMJobBless."
fi

echo ""
echo "═══════════════════════════════════════════════════════════════"
