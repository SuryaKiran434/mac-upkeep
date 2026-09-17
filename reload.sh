#!/bin/bash
set -e
PLIST_NAME="com.suryakiran.brewauto.plist"
SOURCE_PATH="$HOME/IdeaProjects/mac-upkeep/$PLIST_NAME"
DEST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME"

TZWATCH_PLIST_NAME="com.suryakiran.tzwatch.plist"
TZWATCH_SOURCE="$HOME/IdeaProjects/mac-upkeep/$TZWATCH_PLIST_NAME"
TZWATCH_DEST="$HOME/Library/LaunchAgents/$TZWATCH_PLIST_NAME"

echo "Syncing and restarting Brew Automation..."

# Enforce .env permissions (should be readable only by owner)
if [ -f "$HOME/IdeaProjects/mac-upkeep/.env" ]; then
    chmod 600 "$HOME/IdeaProjects/mac-upkeep/.env" || {
        echo "ERROR: Failed to set .env permissions. Installation aborted."
        exit 1
    }
    echo "[OK] .env permissions: 600 (owner-only)"
fi

# Unload the old one
launchctl bootout gui/"$(id -u)" "$DEST_PATH" 2>/dev/null || true

# Substitute __HOME__ placeholder with the actual home directory and install
if ! sed "s|__HOME__|$HOME|g" "$SOURCE_PATH" > "$DEST_PATH"; then
    echo "ERROR: Failed to install plist. Check file permissions."
    exit 1
fi

# Load the new version
if ! launchctl bootstrap gui/"$(id -u)" "$DEST_PATH"; then
    echo "ERROR: Failed to load LaunchAgent. Check plist syntax:"
    plutil -lint "$DEST_PATH"
    exit 1
fi

echo "✓ LaunchAgent installed and loaded"

# Install and load the timezone watcher
launchctl bootout gui/"$(id -u)" "$TZWATCH_DEST" 2>/dev/null || true
chmod +x "$HOME/IdeaProjects/mac-upkeep/tzreload.sh"
if ! sed "s|__HOME__|$HOME|g" "$TZWATCH_SOURCE" > "$TZWATCH_DEST"; then
    echo "ERROR: Failed to install tzwatch plist."
    exit 1
fi
if ! launchctl bootstrap gui/"$(id -u)" "$TZWATCH_DEST"; then
    echo "ERROR: Failed to load tzwatch LaunchAgent."
    exit 1
fi
echo "✓ Timezone watcher installed and loaded"
echo "Done! The new schedule and logic are now active."

