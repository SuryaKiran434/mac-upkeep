#!/bin/bash

# Parse flags
MANUAL=false
FORCE=false
for arg in "$@"; do
    [ "$arg" = "--manual" ] && MANUAL=true
    [ "$arg" = "--force" ] && FORCE=true
done

# Paths
BASE_DIR="$HOME/IdeaProjects/mac-upkeep"

# Load config from .env (email credentials) - parse individually to avoid exposing all vars
SENDER_EMAIL=""
SENDER_APP_PASSWORD=""
RECIPIENT_EMAIL=""
if [ -f "$BASE_DIR/.env" ]; then
    SENDER_EMAIL=$(grep "^SENDER_EMAIL=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    SENDER_APP_PASSWORD=$(grep "^SENDER_APP_PASSWORD=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    RECIPIENT_EMAIL=$(grep "^RECIPIENT_EMAIL=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
fi

TODAY=$(date "+%Y-%m-%d")
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Determine log file
if [ "$MANUAL" = true ]; then
    HISTORY_LOG="$BASE_DIR/restart_history_manual.log"
    EMAIL_SUBJECT="System Restart Manual Trigger — $TODAY"
else
    HISTORY_LOG="$BASE_DIR/restart_history.log"
    EMAIL_SUBJECT="System Restart Scheduled — $TODAY"
fi

# Resolve Python for email notifications
PYTHON_PATH=""
if command -v python3 &>/dev/null; then
    PYTHON_PATH=$(command -v python3)
fi

# For manual triggers, require confirmation unless --force
if [ "$MANUAL" = true ] && [ "$FORCE" != true ]; then
    echo "⚠️  System restart will occur in 3 seconds."
    echo "Press Ctrl+C to cancel, or pass --force to skip this warning."
    sleep 3
fi

# Log the restart (logged just before the shutdown call is issued)
echo "System restart initiated on $TIMESTAMP" >> "$HISTORY_LOG"

# Send email notification (credentials passed via environment, not command-line arguments)
if [ -n "$PYTHON_PATH" ] && [ -x "$PYTHON_PATH" ]; then
    SENDER_EMAIL="$SENDER_EMAIL" SENDER_APP_PASSWORD="$SENDER_APP_PASSWORD" RECIPIENT_EMAIL="$RECIPIENT_EMAIL" \
    "$PYTHON_PATH" "$BASE_DIR/notify.py" \
        "$EMAIL_SUBJECT" \
        "$(printf 'System restart initiated on %s.\n\n%s' \
            "$TODAY" "$([ "$MANUAL" = true ] && echo 'This was a manual trigger.' || echo 'This was a scheduled restart.')")" \
        "" || true
fi

# Restart the system
sudo /sbin/shutdown -r now
