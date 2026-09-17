#!/bin/bash
set -e

# ============================================================================
# mac-upkeep Executor: Updates brew, uv, and Python packages
# ============================================================================

# Parse flags
MANUAL=false
# shellcheck disable=SC2034  # currently unreferenced; rate limiting is enforced
#                            via the lock-file timestamp check, not this value.
RATE_LIMIT_MINUTES=5
for arg in "$@"; do
    [ "$arg" = "--manual" ] && MANUAL=true
done

# ============================================================================
# SETUP: Paths, Config, Validation
# ============================================================================

BASE_DIR="$HOME/IdeaProjects/mac-upkeep"
TODAY=$(date "+%Y-%m-%d")
TIMESTAMP=$(date)
START_EPOCH=$(date +%s)  # run start, used to report duration in the email

# Log file selection based on run type
if [ "$MANUAL" = true ]; then
    LOG_FILE="$BASE_DIR/brew_update_manual.log"
    ERROR_LOG="$BASE_DIR/error_manual.log"
    SKIP_LOG=""
    EMAIL_SUBJECT_SUCCESS="Brew Update Manual Run Complete — $TODAY"
    EMAIL_SUBJECT_FAIL="Brew Update Manual Run FAILED — $TODAY"
else
    LOG_FILE="$BASE_DIR/brew_update.log"
    ERROR_LOG="$BASE_DIR/error.log"
    SKIP_LOG="$BASE_DIR/skips.log"
    EMAIL_SUBJECT_SUCCESS="Brew Update Complete — $TODAY"
    EMAIL_SUBJECT_FAIL="Brew Update FAILED — $TODAY"
fi

LOCK_FILE="$BASE_DIR/brew_update.lock"
LOCK_DIR="${LOCK_FILE}.d"
LOCK_TIMEOUT=3600  # 1 hour

# Initialize logging
mkdir -p "$BASE_DIR"
touch "$LOG_FILE" "$ERROR_LOG"
chmod 600 "$LOG_FILE" "$ERROR_LOG"
if [ -n "$SKIP_LOG" ]; then
    touch "$SKIP_LOG"
    chmod 600 "$SKIP_LOG"
fi

# ============================================================================
# CONFIGURATION: Parse .env safely (don't expose all env vars)
# ============================================================================

BREW=""
UV=""
SENDER_EMAIL=""
SENDER_APP_PASSWORD=""
RECIPIENT_EMAIL=""

if [ -f "$BASE_DIR/.env" ]; then
    # Parse only needed variables to avoid exposing credentials to all children
    BREW=$(grep "^BREW_PATH=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    UV=$(grep "^UV_PATH=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    SENDER_EMAIL=$(grep "^SENDER_EMAIL=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    SENDER_APP_PASSWORD=$(grep "^SENDER_APP_PASSWORD=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    RECIPIENT_EMAIL=$(grep "^RECIPIENT_EMAIL=" "$BASE_DIR/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
fi

# Apply defaults if not in .env
BREW="${BREW:-/opt/homebrew/bin/brew}"
UV="${UV:-/opt/homebrew/bin/uv}"

# Homebrew 6.0 (April 2026) changed the default so `brew upgrade` now re-runs the
# installers of casks with `auto_updates true`. Those casks update themselves, and
# some (e.g. docker-desktop) prompt for sudo during install, which blocks this
# unattended run. This env var restores the long-standing pre-6.0 behavior: leave
# self-updating casks alone. Keep it exported before any brew call below.
export HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1

# ============================================================================
# VALIDATION: Check tools and Python early (before setting up traps/locking)
# ============================================================================

validate_tools() {
    if [ ! -x "$BREW" ]; then
        echo "[$(date)] ERROR: brew not found at '$BREW'" | tee -a "$ERROR_LOG" >&2
        exit 1
    fi
    if [ ! -x "$UV" ]; then
        echo "[$(date)] ERROR: uv not found at '$UV'" | tee -a "$ERROR_LOG" >&2
        exit 1
    fi
}

find_python() {
    # Try pyenv first, then system python3
    local py
    if command -v pyenv &>/dev/null; then
        py=$(pyenv which python 2>/dev/null || true)
        if [ -n "$py" ] && [ -x "$py" ]; then
            echo "$py"
            return 0
        fi
    fi
    if command -v python3 &>/dev/null; then
        echo "$(command -v python3)"
        return 0
    fi
    return 1
}

validate_tools
PYTHON_PATH=$(find_python || true)

# ============================================================================
# HTML EMAIL GENERATION: Styled templates for success/failure
# ============================================================================

# Parse the captured upgrade output into grouped, deduplicated HTML sections.
#
# The temp file is annotated with "@@CAT@@ <name>" marker lines (written by the
# execution stages below) so each block of output is attributed to its source:
# Homebrew Formulae, Applications (casks), CLI Tools (uv), Python Packages (pip).
#
# All parsing runs in awk — it has associative arrays for dedup/grouping, which
# macOS /bin/bash 3.2 lacks, and it HTML-escapes each field. brew echoes every
# "name old -> new" line 2-3 times (listing + progress + summary), so dedup by
# category+package keeps exactly one row per upgraded package.
#
# Output: line 1 is "@@COUNT@@ <n>" (total packages), the rest is the HTML body
# (grouped category tables, or a celebratory empty state when nothing changed).
generate_upgrade_summary() {
    awk '
    function esc(s){ gsub(/&/,"\\&amp;",s); gsub(/</,"\\&lt;",s); gsub(/>/,"\\&gt;",s); gsub(/"/,"\\&quot;",s); gsub(/\x27/,"\\&#39;",s); return s }
    function emit(c,p,o,n,   k){
        if(c=="") return
        k=c SUBSEP p; if(k in seen) return; seen[k]=1
        if(!(c in cnt)) order[++ncat]=c
        cnt[c]++
        # Disk-cleanup rows are reclaimed caches, not upgraded packages — they
        # get their own table but must not inflate the "N packages updated"
        # subtitle that the caller derives from @@COUNT@@.
        if(c !~ /^Disk Cleanup/) total++
        rows[c]=rows[c] "<tr><td class=\"name\">" esc(p) "</td><td class=\"ver\"><span class=\"old\">" esc(o) "</span><span class=\"arw\"> \342\206\222 </span><span class=\"new\">" esc(n) "</span></td></tr>\n"
    }
    # Disk-cleanup rows carry one figure, not a transition. Rendering them
    # through emit() would borrow the version column\x27s "old -> new" shape,
    # which greys out the reclaimed size and bolds the "0B" it became — the
    # least informative half of the row. This emits the size alone, emphasised.
    function emit_size(c,p,sz,   k){
        if(c=="") return
        k=c SUBSEP p; if(k in seen) return; seen[k]=1
        if(!(c in cnt)) order[++ncat]=c
        cnt[c]++
        rows[c]=rows[c] "<tr><td class=\"name\">" esc(p) "</td><td class=\"ver\"><span class=\"new\">" esc(sz) "</span></td></tr>\n"
    }
    /^@@CAT@@/ { c=$0; sub(/^@@CAT@@ /,"",c); next }
    # Homebrew formulae & casks:  name  old  ->  new  [(size)]
    (c=="Homebrew Formulae" || c=="Applications") && $3=="->" && $2 ~ /^[0-9]/ && $1 ~ /^[A-Za-z0-9@._+-]+$/ { emit(c,$1,$2,$4); next }
    # Disk cleanup:  "<label>\t<size>"  (from cache_cleanup.sh). Tab-separated
    # so the label keeps its spaces and the size keeps its unit.
    c ~ /^Disk Cleanup/ && index($0,"\t")>0 { split($0,dc,"\t"); emit_size(c,dc[1],dc[2]); next }
    # uv tools:  Updated|Upgraded  name  vOLD  ->  vNEW
    c=="CLI Tools" && ($1=="Updated"||$1=="Upgraded") && $4=="->" && $3 ~ /^v?[0-9]/ { emit(c,$2,$3,$5); next }
    # Python (uv pip) diff:  - name==old   /   + name==new
    c=="Python Packages" && /^[[:space:]]*-[[:space:]]+[A-Za-z0-9._+-]+==/ { s=$0; sub(/^[[:space:]]*-[[:space:]]+/,"",s); i=index(s,"=="); pyold[substr(s,1,i-1)]=substr(s,i+2); next }
    c=="Python Packages" && /^[[:space:]]*\+[[:space:]]+[A-Za-z0-9._+-]+==/ { s=$0; sub(/^[[:space:]]*\+[[:space:]]+/,"",s); i=index(s,"=="); nm=substr(s,1,i-1); nv=substr(s,i+2); ov=(nm in pyold)?pyold[nm]:"\342\200\224"; emit(c,nm,ov,nv); next }
    END{
        print "@@COUNT@@ " total+0
        # Render on ncat, not total: a run that upgraded nothing but reclaimed
        # disk space still has a table to show.
        if(ncat==0){
            print "<div class=\"empty\"><div class=\"big\">\360\237\216\211</div><div class=\"t\">Everything\342\200\231s current</div><div class=\"s\">No packages needed updating today.</div></div>"
        } else {
            for(j=1;j<=ncat;j++){ c=order[j]
                print "<div class=\"cat\"><div class=\"cat-h\"><span class=\"name\">" esc(c) "</span><span class=\"count\">" cnt[c] "</span></div><table class=\"pkgs\">"
                printf "%s", rows[c]
                print "</table></div>"
            }
        }
    }
    ' "$1"
}

# Emit the email shell with placeholders. Placeholders are substituted by the
# caller: HEAD_CLASS (ok|fail), GLYPH (✓|✕), TITLE, TAGLINE, DATE, TIME,
# RUN_TYPE, DURATION, RECLAIMED (disk freed by the cleanup step), and BODY
# (the grouped package tables or the error box).
generate_html_email() {
    cat <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <style>
        body { margin:0; background:#f4f2ee; color:#1d1d1f; font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif; -webkit-font-smoothing:antialiased; padding:28px 12px; }
        .container { max-width:560px; margin:0 auto; background:#ffffff; border-radius:16px; overflow:hidden; box-shadow:0 6px 24px rgba(60,50,30,.10); border:1px solid #eeeae3; }
        .head { padding:30px 30px 26px; text-align:center; color:#ffffff; }
        .head.ok { background:linear-gradient(135deg,#20b47c 0%,#128a5e 100%); }
        .head.fail { background:linear-gradient(135deg,#e85d62 0%,#c9353b 100%); }
        .glyph { width:52px; height:52px; line-height:52px; margin:0 auto 14px; border-radius:50%; background:rgba(255,255,255,.18); font-size:26px; font-weight:700; }
        .head h1 { margin:0; font-size:21px; font-weight:600; letter-spacing:-.01em; }
        .head .sub { margin:6px 0 0; font-size:15px; font-weight:500; opacity:.94; }
        .meta { width:100%; border-collapse:collapse; background:#faf8f4; border-bottom:1px solid #eeeae3; }
        .meta td { width:50%; padding:14px 30px; vertical-align:top; border-top:1px solid #eeeae3; }
        .meta tr:first-child td { border-top:none; }
        .meta .k { font-size:10.5px; letter-spacing:.07em; text-transform:uppercase; color:#86868b; font-weight:600; margin-bottom:3px; }
        .meta .v { font-size:14px; font-weight:500; color:#1d1d1f; }
        .body { padding:24px 30px 8px; }
        .cat { margin-bottom:22px; }
        .cat-h { display:flex; align-items:center; gap:9px; margin:0 0 8px; padding-bottom:8px; border-bottom:1px solid #eeeae3; }
        .cat-h .name { font-size:11.5px; letter-spacing:.05em; text-transform:uppercase; font-weight:700; color:#a1620f; }
        .cat-h .count { font-size:11px; font-weight:700; color:#a1620f; background:#fbefd9; border-radius:20px; padding:1px 8px; min-width:20px; text-align:center; }
        .pkgs { width:100%; border-collapse:collapse; font-family:ui-monospace,'SF Mono',Menlo,Monaco,'Courier New',monospace; font-variant-numeric:tabular-nums; }
        .pkgs td { padding:8px 0; border-bottom:1px solid #f5f2ec; font-size:13.5px; }
        .pkgs tr:last-child td { border-bottom:none; }
        .pkgs .name { color:#1d1d1f; font-weight:500; }
        .pkgs .ver { text-align:right; white-space:nowrap; font-size:13px; }
        .old { color:#86868b; }
        .arw { color:#cfcabf; padding:0 3px; }
        .new { color:#17a06a; font-weight:600; }
        .empty { text-align:center; padding:20px 16px 30px; }
        .empty .big { font-size:38px; line-height:1; }
        .empty .t { margin-top:12px; font-size:16px; font-weight:600; color:#1d1d1f; }
        .empty .s { margin-top:4px; font-size:13.5px; color:#86868b; }
        .errbox { background:#fdeceb; border:1px solid #f6cfce; border-radius:12px; padding:16px 18px; font-size:14px; line-height:1.55; color:#1d1d1f; }
        .errbox .row { margin-bottom:6px; }
        .errbox .row:last-child { margin-bottom:0; }
        .errbox .lbl { color:#86868b; }
        .errbox .step { font-family:ui-monospace,'SF Mono',Menlo,monospace; font-size:13px; background:#f9dbda; color:#a5292e; padding:2px 7px; border-radius:5px; }
        .retry { margin-top:14px; font-size:13px; color:#86868b; text-align:center; }
        .foot { padding:16px 30px 20px; border-top:1px solid #eeeae3; text-align:center; font-size:12px; color:#86868b; }
        .foot .brand { font-weight:600; color:#a1620f; }
    </style>
</head>
<body>
    <div class="container">
        <div class="head HEAD_CLASS_PLACEHOLDER">
            <div class="glyph">GLYPH_PLACEHOLDER</div>
            <h1>TITLE_PLACEHOLDER</h1>
            <p class="sub">TAGLINE_PLACEHOLDER</p>
        </div>
        <table class="meta">
            <tr>
                <td><div class="k">Date</div><div class="v">DATE_PLACEHOLDER</div></td>
                <td><div class="k">Time</div><div class="v">TIME_PLACEHOLDER</div></td>
            </tr>
            <tr>
                <td><div class="k">Run type</div><div class="v">RUN_TYPE_PLACEHOLDER</div></td>
                <td><div class="k">Duration</div><div class="v">DURATION_PLACEHOLDER</div></td>
            </tr>
            <tr>
                <td colspan="2"><div class="k">Disk reclaimed</div><div class="v">RECLAIMED_PLACEHOLDER</div></td>
            </tr>
        </table>
        <div class="body">
            BODY_PLACEHOLDER
        </div>
        <div class="foot"><span class="brand">&#127866; Mac Upkeep</span> &middot; full logs in your automation directory</div>
    </div>
</body>
</html>
EOF
}

# Format a duration in whole seconds as "Ns", "Nm Ns", or "Nh Nm".
format_duration() {
    local s="$1"
    if [ "$s" -lt 60 ]; then
        echo "${s}s"
    elif [ "$s" -lt 3600 ]; then
        echo "$((s / 60))m $((s % 60))s"
    else
        echo "$((s / 3600))h $(((s % 3600) / 60))m"
    fi
}

# HTML-escape a single string for safe embedding.
html_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

# ============================================================================


check_lock() {
    if [ ! -f "$LOCK_FILE" ]; then
        return 0  # No lock, safe to proceed
    fi

    # Read PID and timestamp from lock
    read -r PID LOCK_TIME < "$LOCK_FILE" 2>/dev/null || return 0
    CURRENT_TIME=$(date +%s)
    LOCK_AGE=$((CURRENT_TIME - LOCK_TIME))

    # Check if process still running
    if kill -0 "$PID" 2>/dev/null; then
        return 1  # Process running, skip
    fi

    # Check if lock is stale (older than timeout)
    if [ "$LOCK_AGE" -gt "$LOCK_TIMEOUT" ]; then
        rm -f "$LOCK_FILE"
        return 0  # Stale lock removed, safe to proceed
    fi

    return 1  # Lock is valid but process missing (shouldn't happen)
}

# For manual runs, check rate limiting
if [ "$MANUAL" = true ]; then
    if ! check_lock; then
        echo "[$(date)] Skip: Manual trigger already in progress or recently run" >> "$ERROR_LOG"
        exit 0
    fi
fi

# Reclaim a lock directory left behind by a process that died without running
# its cleanup trap (e.g. killed by the Tue/Thu 9:00 AM restart mid-update).
# Without this, one abandoned run blocks every subsequent run forever.
reclaim_stale_lock_dir() {
    local owner_pid="" lock_epoch="" dir_epoch age

    if [ -f "$LOCK_FILE" ]; then
        read -r owner_pid lock_epoch < "$LOCK_FILE" 2>/dev/null || true
    fi

    # Owning process still alive: a real run is in progress, leave it alone.
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        return 1
    fi

    # No live owner. Fall back to the directory's own age when the lock file is
    # missing or unparseable, so an orphaned dir can never wedge us permanently.
    # `[ "$x" -eq "$x" ]` was the classic shell test for "is this an integer",
    # relying on -eq failing on non-numeric input. It works, but it reads as a
    # comparison of a value with itself -- which is what a real typo looks like,
    # and what shellcheck and SonarCloud both flag. A glob says it directly.
    # The '' branch covers the unset case too, so no separate -z test is needed.
    case "$lock_epoch" in
        ''|*[!0-9]*)
            dir_epoch=$(stat -f %m "$LOCK_DIR" 2>/dev/null) || return 1
            lock_epoch="$dir_epoch"
            ;;
    esac

    age=$(( $(date +%s) - lock_epoch ))
    [ "$age" -lt 0 ] && age=0
    if [ "$age" -le "$LOCK_TIMEOUT" ]; then
        return 1
    fi

    echo "[$(date)] Note: Removed stale lock dir (age: ${age}s, owner PID ${owner_pid:-unknown} not running)" >> "$ERROR_LOG"
    rm -f "$LOCK_FILE"
    rm -rf "$LOCK_DIR"
    return 0
}

# Atomically acquire lock using mkdir to prevent race conditions
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    if ! reclaim_stale_lock_dir || ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "[$(date)] Skip: Another instance is acquiring the lock" >> "$ERROR_LOG"
        exit 0
    fi
fi
echo "$$ $(date +%s)" > "$LOCK_FILE"

# ============================================================================
# ERROR HANDLING: Trap and cleanup on exit
# ============================================================================

FAILED_STEP="initializing"

cleanup() {
    local exit_code=$?
    rm -f "$LOCK_FILE"
    rm -rf "$LOCK_DIR"

    if [ $exit_code -ne 0 ]; then
        local error_msg
        error_msg="[$(date)] ERROR: Failed during '$FAILED_STEP' (exit code $exit_code)"
        if [ "$MANUAL" = false ]; then
            error_msg="$error_msg. Next retry at 8:00 AM tomorrow."
        fi

        echo "$error_msg" | tee -a "$LOG_FILE" "$ERROR_LOG" >&2

        # Send error email with HTML
        if [ -n "$PYTHON_PATH" ] && [ -x "$PYTHON_PATH" ] && [ -n "$SENDER_EMAIL" ] && [ -n "$SENDER_APP_PASSWORD" ] && [ -n "$RECIPIENT_EMAIL" ]; then
            local failed_step_escaped duration retry_line
            failed_step_escaped=$(html_escape "$FAILED_STEP")
            duration=$(format_duration $(( $(date +%s) - START_EPOCH )))
            local error_body="Brew update failed on $TODAY during step: $FAILED_STEP (exit code $exit_code). See logs for details."

            # Focused error box; only automated runs mention the next retry.
            retry_line=""
            if [ "$MANUAL" = false ]; then
                retry_line="<div class=\"retry\">Next automatic retry at 8:00 AM tomorrow.</div>"
            fi
            local error_summary="<div class=\"errbox\"><div class=\"row\"><span class=\"lbl\">Failed step:</span> <span class=\"step\">$failed_step_escaped</span></div><div class=\"row\"><span class=\"lbl\">Exit code:</span> $exit_code</div><div class=\"row\"><span class=\"lbl\">Details:</span> see error.log in your automation directory.</div></div>$retry_line"

            local esc_run_type esc_time
            esc_run_type=$([ "$MANUAL" = true ] && echo "Manual" || echo "Automated")
            esc_time=$(html_escape "$(date '+%H:%M:%S %Z')")

            local html_error
            html_error=$(generate_html_email)
            html_error="${html_error//HEAD_CLASS_PLACEHOLDER/fail}"
            html_error="${html_error//GLYPH_PLACEHOLDER/✕}"
            html_error="${html_error//TITLE_PLACEHOLDER/Mac Upkeep Failed}"
            html_error="${html_error//TAGLINE_PLACEHOLDER/Stopped during \'$failed_step_escaped\'}"
            html_error="${html_error//DATE_PLACEHOLDER/$(html_escape "$TODAY")}"
            html_error="${html_error//TIME_PLACEHOLDER/$esc_time}"
            html_error="${html_error//RUN_TYPE_PLACEHOLDER/$esc_run_type}"
            html_error="${html_error//DURATION_PLACEHOLDER/$duration}"
            # May fire before the cleanup step ran, so default rather than
            # leaking the raw placeholder into a failure email.
            html_error="${html_error//RECLAIMED_PLACEHOLDER/$(html_escape "${RECLAIMED:-—}")}"
            html_error="${html_error//BODY_PLACEHOLDER/$error_summary}"

            SENDER_EMAIL="$SENDER_EMAIL" SENDER_APP_PASSWORD="$SENDER_APP_PASSWORD" RECIPIENT_EMAIL="$RECIPIENT_EMAIL" \
            "$PYTHON_PATH" "$BASE_DIR/notify.py" \
                "$EMAIL_SUBJECT_FAIL" \
                "$error_body" \
                "$html_error"
            if [ $? -ne 0 ]; then
                echo "[$(date)] WARNING: Failed to send error email" >> "$ERROR_LOG"
            fi
        fi
    fi
}
trap cleanup EXIT

# ============================================================================
# LOGGING SETUP: Capture stderr
# ============================================================================

echo "" >> "$ERROR_LOG"
echo "=== Run started: $TIMESTAMP ===" >> "$ERROR_LOG"
exec 2> >(tee -a "$ERROR_LOG" >&2)

# ============================================================================
# EXECUTION: Brew, UV, Python upgrades
# ============================================================================

UPGRADE_TEMP=$(mktemp) || { echo "[$(date)] ERROR: Failed to create temp file" >&2; exit 1; }
chmod 600 "$UPGRADE_TEMP"

FAILED_STEP="brew outdated"
echo "--- LOGGING START: $TIMESTAMP ---" >> "$LOG_FILE"
echo "Outdated packages:" >> "$LOG_FILE"
"$BREW" outdated >> "$LOG_FILE" 2>&1 || true

FAILED_STEP="brew update"
echo "--- Updating Homebrew ---"
"$BREW" update 2>&1 | tee -a "$UPGRADE_TEMP" >/dev/null

# HOMEBREW_NO_AUTO_UPDATE=1 on the upgrade steps: `brew update` already ran
# just above, so brew's auto-update would redundantly re-fetch the taps. Scoped
# to these two commands so `brew outdated` above keeps its current behaviour.
FAILED_STEP="brew upgrade --formula"
echo "@@CAT@@ Homebrew Formulae" >> "$UPGRADE_TEMP"
HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" upgrade --formula 2>&1 | tee -a "$UPGRADE_TEMP" >/dev/null

# Upgrade casks without naming them explicitly: an explicit cask name overrides
# HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS (set above) and would re-run the
# sudo-prompting installer for self-updating casks like docker-desktop. Letting
# brew pick the targets respects that env var, so only non-self-updating casks
# get upgraded and the run never blocks on a password prompt.
FAILED_STEP="brew upgrade --cask"
echo "@@CAT@@ Applications" >> "$UPGRADE_TEMP"
HOMEBREW_NO_AUTO_UPDATE=1 "$BREW" upgrade --cask 2>&1 | tee -a "$UPGRADE_TEMP" >/dev/null

FAILED_STEP="uv tool upgrade"
echo "--- Updating UV Tools ---"
echo "@@CAT@@ CLI Tools" >> "$UPGRADE_TEMP"
"$UV" tool upgrade --all 2>&1 | tee -a "$UPGRADE_TEMP" >/dev/null

# Python pip upgrades (non-fatal if pyenv unavailable)
if [ -n "$PYTHON_PATH" ] && [ -x "$PYTHON_PATH" ]; then
    if command -v pyenv &>/dev/null; then
        PYENV_PYTHON=$(pyenv which python 2>/dev/null || true)
        if [ -n "$PYENV_PYTHON" ] && [ -x "$PYENV_PYTHON" ]; then
            FAILED_STEP="uv pip upgrade"
            echo "--- Updating Python Libs ---"
            echo "@@CAT@@ Python Packages" >> "$UPGRADE_TEMP"
            PKGS=$("$UV" pip list --python "$PYENV_PYTHON" --format freeze 2>/dev/null | cut -d= -f1 || true)
            if [ -n "$PKGS" ]; then
                echo "$PKGS" | tr '\n' '\0' | xargs -0 "$UV" pip install --upgrade --python "$PYENV_PYTHON" 2>&1 | tee -a "$UPGRADE_TEMP" >/dev/null
            fi
        else
            echo "[$(date)] WARNING: pyenv python not found, skipping pip upgrades" >> "$LOG_FILE"
        fi
    fi
fi

FAILED_STEP="brew cleanup"
"$BREW" cleanup --prune=all >/dev/null 2>&1 || true

# ----------------------------------------------------------------------------
# Cache cleanup (regenerable caches only — see cache_cleanup.sh for the list of
# protected paths; aerial wallpapers and the Claude VM are deliberately exempt).
#
# Runs with --apply: it deletes and reports what it reclaimed into the summary
# email. It runs unconditionally — there is no free-space threshold, because
# macOS and the apps regenerate these caches every day regardless of how much
# room is left, and letting them accumulate until the disk is tight is the
# problem this exists to prevent. Drop --apply to return it to report-only. It
# is intentionally not fatal — a cleanup failure must never fail an otherwise
# successful update run.
# ----------------------------------------------------------------------------
FAILED_STEP="cache cleanup"
RECLAIMED="—"
if [ -x "$BASE_DIR/cache_cleanup.sh" ]; then
    CLEANUP_TEMP=$(mktemp) || CLEANUP_TEMP=""
    if [ -n "$CLEANUP_TEMP" ]; then
        "$BASE_DIR/cache_cleanup.sh" --apply --emit-summary > "$CLEANUP_TEMP" 2>/dev/null || true
        # First line is the @@RECLAIMED@@ stat for the email header; it must not
        # reach the table parser, so it is split off rather than appended.
        RECLAIMED_LINE=$(sed -n '1s/^@@RECLAIMED@@ //p' "$CLEANUP_TEMP")
        # An `if`, not `[ ... ] && VAR=`: under `set -e` that idiom exits the
        # whole run whenever the test is false (nothing reclaimable).
        if [ -n "$RECLAIMED_LINE" ]; then
            RECLAIMED="$RECLAIMED_LINE"
        fi
        sed '1{/^@@RECLAIMED@@/d;}' "$CLEANUP_TEMP" >> "$UPGRADE_TEMP"
        rm -f "$CLEANUP_TEMP"
    fi
fi

# ============================================================================
# SUCCESS: Generate HTML email and send notification
# ============================================================================

# Parse captured output: line 1 is "@@COUNT@@ <n>", the rest is the HTML body.
PARSED_SUMMARY=$(generate_upgrade_summary "$UPGRADE_TEMP")
UPGRADE_COUNT=$(printf '%s\n' "$PARSED_SUMMARY" | sed -n '1s/^@@COUNT@@ //p')
UPGRADE_COUNT=${UPGRADE_COUNT:-0}
UPGRADE_SUMMARY=$(printf '%s\n' "$PARSED_SUMMARY" | sed '1d')

# Human-readable subtitle: "N packages updated" or "Already up to date".
if [ "$UPGRADE_COUNT" -gt 0 ] 2>/dev/null; then
    if [ "$UPGRADE_COUNT" -eq 1 ]; then
        SUCCESS_SUBTITLE="1 package updated"
    else
        SUCCESS_SUBTITLE="$UPGRADE_COUNT packages updated"
    fi
else
    SUCCESS_SUBTITLE="Already up to date"
fi

# The header tagline carries both halves of what the run did: packages and
# disk. RECLAIMED is set by the cache-cleanup step above.
if [ "$RECLAIMED" != "—" ]; then
    SUCCESS_SUBTITLE="$SUCCESS_SUBTITLE · $RECLAIMED"
fi

if [ -n "$PYTHON_PATH" ] && [ -x "$PYTHON_PATH" ] && [ -n "$SENDER_EMAIL" ] && [ -n "$SENDER_APP_PASSWORD" ] && [ -n "$RECIPIENT_EMAIL" ]; then
    success_body="Brew update completed successfully on $TODAY at $(date).
$SUCCESS_SUBTITLE.
$([ "$MANUAL" = true ] && echo "This was a manual run." || echo "")"

    duration=$(format_duration $(( $(date +%s) - START_EPOCH )))
    esc_run_type=$([ "$MANUAL" = true ] && echo "Manual" || echo "Automated")
    esc_time=$(html_escape "$(date '+%H:%M:%S %Z')")

    # Generate HTML email from template
    html_body=$(generate_html_email)
    html_body="${html_body//HEAD_CLASS_PLACEHOLDER/ok}"
    html_body="${html_body//GLYPH_PLACEHOLDER/✓}"
    html_body="${html_body//TITLE_PLACEHOLDER/Mac Upkeep Complete}"
    html_body="${html_body//TAGLINE_PLACEHOLDER/$(html_escape "$SUCCESS_SUBTITLE")}"
    html_body="${html_body//RECLAIMED_PLACEHOLDER/$(html_escape "$RECLAIMED")}"
    html_body="${html_body//DATE_PLACEHOLDER/$(html_escape "$TODAY")}"
    html_body="${html_body//TIME_PLACEHOLDER/$esc_time}"
    html_body="${html_body//RUN_TYPE_PLACEHOLDER/$esc_run_type}"
    html_body="${html_body//DURATION_PLACEHOLDER/$duration}"
    html_body="${html_body//BODY_PLACEHOLDER/$UPGRADE_SUMMARY}"

    SENDER_EMAIL="$SENDER_EMAIL" SENDER_APP_PASSWORD="$SENDER_APP_PASSWORD" RECIPIENT_EMAIL="$RECIPIENT_EMAIL" \
    "$PYTHON_PATH" "$BASE_DIR/notify.py" \
        "$EMAIL_SUBJECT_SUCCESS" \
        "$success_body" \
        "$html_body"
    if [ $? -ne 0 ]; then
        echo "[$(date)] WARNING: Failed to send success email" >> "$LOG_FILE"
    fi
fi

rm -f "$UPGRADE_TEMP"

# ============================================================================
# FINALIZATION (automation-only): Completion marker and log rotation
# ============================================================================

if [ "$MANUAL" = false ]; then
    echo "Running bubu has been completed on $TODAY ($(date))" >> "$LOG_FILE"

    # Clear error log on clean run
    : > "$ERROR_LOG"

    # Log rotation: keep only the last 30 days of completion markers
    # Use portable date command (try BSD first, then GNU)
    CUTOFF=$(date -v-30d "+%Y-%m-%d" 2>/dev/null || date -d "30 days ago" "+%Y-%m-%d" 2>/dev/null || date "+%Y-%m-%d")

    awk -v cutoff="$CUTOFF" '
        /Running bubu has been completed on [0-9]{4}-[0-9]{2}-[0-9]{2}/ {
            match($0, /[0-9]{4}-[0-9]{2}-[0-9]{2}/)
            if (substr($0, RSTART, RLENGTH) >= cutoff) print
            next
        }
    ' "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"

    if [ -n "$SKIP_LOG" ]; then
        tail -n 100 "$SKIP_LOG" > "${SKIP_LOG}.tmp" && mv "${SKIP_LOG}.tmp" "$SKIP_LOG"
    fi
else
    # Manual runs: rotate logs after 50 entries (keep recent runs)
    if [ -f "$LOG_FILE" ] && [ "$(wc -l < "$LOG_FILE")" -gt 500 ]; then
        tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
fi
