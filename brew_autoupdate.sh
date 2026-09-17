#!/bin/bash
set -e

# ============================================================================
# mac-upkeep Guard: Prevents duplicate runs and launches executor
# ============================================================================

# Paths
BASE_DIR="$HOME/IdeaProjects/mac-upkeep"
LOG_FILE="$BASE_DIR/brew_update.log"
SKIP_LOG="$BASE_DIR/skips.log"
LOCK_FILE="$BASE_DIR/brew_update.lock"
TODAY=$(date "+%Y-%m-%d")
TIMESTAMP=$(date)
LOCK_TIMEOUT=3600  # 1 hour

# Ensure files exist
mkdir -p "$BASE_DIR"
touch "$LOG_FILE" "$SKIP_LOG"

# ============================================================================
# CHECK 1: Already completed today?
# ============================================================================

if grep -q "Running bubu has been completed on $TODAY" "$LOG_FILE"; then
    echo "[$TIMESTAMP] Skip: Update already completed for $TODAY." >> "$SKIP_LOG"
    exit 0
fi

# ============================================================================
# CHECK 2: Update already in progress?
# ============================================================================

cleanup_stale_lock() {
    if [ ! -f "$LOCK_FILE" ]; then
        return 0
    fi

    # Read PID and timestamp from lock file
    read -r PID LOCK_TIME < "$LOCK_FILE" 2>/dev/null || return 0

    # Check if process is still running
    if kill -0 "$PID" 2>/dev/null; then
        echo "[$TIMESTAMP] Skip: Update already in progress (PID $PID)." >> "$SKIP_LOG"
        return 1  # Process still running, don't proceed
    fi

    # Check if lock is stale (older than timeout)
    CURRENT_TIME=$(date +%s)
    LOCK_AGE=$((CURRENT_TIME - LOCK_TIME))
    [ "$LOCK_AGE" -lt 0 ] && LOCK_AGE=0
    if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT" ]; then
        echo "[$TIMESTAMP] Note: Removed stale lock file (age: ${LOCK_AGE}s)." >> "$SKIP_LOG"
        rm -f "$LOCK_FILE"
        return 0  # Stale lock removed, safe to proceed
    fi

    return 0  # Lock is valid but process missing, allow retry
}

if ! cleanup_stale_lock; then
    exit 0
fi

# ============================================================================
# EXECUTE: Launch executor via iTerm2 (with fallback)
# ============================================================================

attempt_iterm() {
    local script_path
    script_path=$(printf '%s' "$BASE_DIR/bubu_executor.sh" | sed 's/\\/\\\\/g; s/"/\\"/g')
    osascript <<EOF 2>/dev/null
tell application "iTerm"
    activate
    set newWindow to (create window with default profile)
    tell current session of newWindow
        write text "$script_path"
    end tell
end tell
EOF
    return $?
}

# Try iTerm2 first
if attempt_iterm; then
    exit 0
fi

# Fallback: Run in background if iTerm2 fails or is not available
echo "[$TIMESTAMP] iTerm2 unavailable or failed (exit code $?), running in background..." >> "$SKIP_LOG"
"$BASE_DIR/bubu_executor.sh" >> "$BASE_DIR/brew_update_background.log" 2>&1 &
exit 0
