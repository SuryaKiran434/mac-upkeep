#!/bin/bash
# Fires when launchd detects a change under /private/etc (via WatchPaths in the
# tzwatch plist) — this is where the /etc/localtime symlink lives, so a timezone
# change triggers it. Reloads the brew auto-update LaunchAgent only when the
# timezone value actually changed.

STATEFILE="$HOME/.brewauto_timezone"
PLIST="$HOME/Library/LaunchAgents/com.suryakiran.brewauto.plist"
LOG="$HOME/IdeaProjects/mac-upkeep/system_stdout.log"

TZ_LINK=$(readlink /private/etc/localtime 2>/dev/null) || exit 0
current_tz=$(printf '%s' "$TZ_LINK" | sed 's|.*/zoneinfo/||')
[ -z "$current_tz" ] && exit 0
# Reject unexpected characters in timezone string
case "$current_tz" in
    *[!A-Za-z0-9/_+-]*) exit 0 ;;
esac
last_tz=$(cat "$STATEFILE" 2>/dev/null)

if [ "$current_tz" != "$last_tz" ]; then
    printf '%s\n' "$current_tz" > "${STATEFILE}.tmp" && mv "${STATEFILE}.tmp" "$STATEFILE"
    if [ -n "$last_tz" ]; then
        # Only reload if we had a previous known timezone (skip first run)
        launchctl bootout gui/"$(id -u)" "$PLIST" 2>/dev/null || true
        launchctl bootstrap gui/"$(id -u)" "$PLIST"
        echo "[$(date)] Timezone changed: $last_tz → $current_tz — reloaded $PLIST" >> "$LOG"
    else
        echo "[$(date)] Timezone initialized: $current_tz" >> "$LOG"
    fi
fi
