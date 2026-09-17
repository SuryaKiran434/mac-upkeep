# BrewAutomation

Automated Homebrew, uv, and Python package updates on macOS with **hardened security**, error handling, and email notifications. Includes both automated scheduling and manual triggers.

## Features

- ✅ **Daily package updates** (brew, casks, uv tools, Python libraries)
- ✅ **Scheduled system restarts** (Tuesday & Thursday 9:00 AM)
- ✅ **HTML email notifications** (success & failure with package details)
- ✅ **Secure credential storage** (encrypted env vars, restricted permissions)
- ✅ **Robust error handling** (visible failures, detailed logs, retry detection)
- ✅ **Duplicate prevention** (lock files with timestamp-based expiration)
- ✅ **Graceful degradation** (iTerm2 fallback to background execution)
- ✅ **Manual triggers** (immediate updates/restarts with separate logging)
- ✅ **Log rotation** (automatic 30-day retention for automation logs)
- ✅ **Timezone watcher** (reloads the schedule when the system timezone changes)
- ✅ **Shell lint in CI** (`bash -n` + ShellCheck on pushes to `main` and every PR)

---

## How It Works

### Brew Updates
```
com.suryakiran.brewauto LaunchAgent (plist, daily at 8:00 AM)
    └─> brew_autoupdate.sh          (guard: skip if already completed today)
            ├─> Lock file check     (PID liveness + 1-hour staleness)
            └─> bubu_executor.sh    (opens iTerm2; falls back to background)
                    ├── validate BREW_PATH / UV_PATH, resolve python
                    ├── acquire lock atomically (mkdir brew_update.lock.d)
                    ├── brew outdated              ──► run log
                    ├── brew update                ──┐
                    ├── brew upgrade --formula       │  each tagged with an
                    ├── brew upgrade --cask          ├─► @@CAT@@ marker into
                    ├── uv tool upgrade --all        │  a 600-perm temp file
                    ├── uv pip install --upgrade   ──┘  (pyenv Python)
                    ├── brew cleanup --prune=all
                    ├── cache_cleanup.sh --emit-summary  (dry run by default)
                    ├── awk parses the temp file: dedup + group by category,
                    │   HTML-escape, emit "@@COUNT@@ n" + the HTML table body
                    ├── notify.py  ──► Gmail SMTP_SSL, HTML + plain-text
                    └── completion marker, error-log clear, log rotation
```

The `awk` stage is doing real work, not just formatting. `brew` echoes each
`name old -> new` line two or three times (listing, progress, summary), and
macOS ships `/bin/bash` 3.2, which has no associative arrays — so dedup,
grouping by category, and HTML-escaping all happen inside `awk`, which does
have them.

**Homebrew env vars.** Two are in play, and the difference between them is
deliberate:

| Variable | Scope | Why |
|---|---|---|
| `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1` | **exported**, file-level | Homebrew 6.0 (April 2026) changed the default so `brew upgrade` re-runs the installers of casks marked `auto_updates true`. Some of those (e.g. `docker-desktop`) prompt for sudo mid-install, which would hang an unattended run. This restores the pre-6.0 behaviour for every brew call. |
| `HOMEBREW_NO_AUTO_UPDATE=1` | **per-command prefix** on the two `brew upgrade` lines only | `brew update` already ran immediately above, so brew's implicit auto-update would redundantly re-fetch the taps. It is scoped rather than exported on purpose: `brew outdated` runs *earlier* in the script, and exporting the variable would change its behaviour — and therefore the "Outdated packages" listing recorded at the top of the run log. |

The casks are upgraded without naming them explicitly for a related reason: an
explicit cask name overrides `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS`, which
would re-invoke the sudo-prompting installer. Letting `brew` pick the targets
respects the variable, so the run never blocks on a password prompt.

**Automated:** Runs daily at 8:00 AM; only executes once per calendar day (duplicate guard prevents multiple runs).

> **Why 8:00 AM (before the Tue/Thu 9:00 AM restart)?** The update is a user-level LaunchAgent, so it can only run inside a logged-in GUI session. Scheduling it *before* the restart means it completes during your morning session; the restart (and any day you don't log back in afterward) can no longer cause it to be skipped. If you're not logged in by 8:00 AM, launchd runs the missed job the next time you log in that day.

**Manual:** `bubu_executor.sh --manual` triggers an immediate run with separate logging.

### System Restarts
```
LaunchDaemon (plist, Tue & Thu at 9:00 AM)
    └─> restart_script.sh (with 3-second confirmation prompt)
            └─> sudo shutdown -r now
```

**Automated:** Scheduled for Tuesday and Thursday mornings (no confirmation).

**Manual:** `restart_script.sh --manual` triggers a restart after 3-second confirmation. Pass `--force` to skip the confirmation.

### Timezone Watcher
```
com.suryakiran.tzwatch LaunchAgent (WatchPaths: /private/etc, RunAtLoad)
    └─> tzreload.sh
            ├── readlink /private/etc/localtime ──► current zone name
            ├── reject anything outside [A-Za-z0-9/_+-]
            ├── compare against ~/.brewauto_timezone
            └── if changed (and not the first run):
                    launchctl bootout  gui/$(id -u) com.suryakiran.brewauto.plist
                    launchctl bootstrap gui/$(id -u) com.suryakiran.brewauto.plist
```

`StartCalendarInterval` is evaluated against the timezone in force when the
agent was loaded, so an 8:00 AM job silently drifts after you fly somewhere.
`/etc/localtime` is a symlink into the zoneinfo database, so watching
`/private/etc` catches the change; the state file is written `tmp` → `mv` so a
crash mid-write cannot leave a half-written zone name behind.

### Installer and helper scripts

| Script | Run it | What it does |
|---|---|---|
| `reload.sh` | `bash reload.sh` | Installs **both** user LaunchAgents. Enforces `chmod 600` on `.env` (aborts if that fails), substitutes `__HOME__` in the plist templates into `~/Library/LaunchAgents/`, then `bootout` + `bootstrap` for `com.suryakiran.brewauto` and `com.suryakiran.tzwatch`. On a load failure it runs `plutil -lint` so you see the syntax error. |
| `reload_restart.sh` | `bash reload_restart.sh` | Installs the **system** LaunchDaemon (needs `sudo`). Same `.env` permission check, then writes the plist to `/Library/LaunchDaemons/`, `chown root:wheel`, `chmod 644`, pre-creates the restart logs at `600` so launchd appends rather than creating them world-readable, and `bootstrap system`. |
| `restart_script.sh` | `bash restart_script.sh --manual [--force]` | Logs the restart, emails a notification, then `sudo /sbin/shutdown -r now`. Scheduled runs get no prompt; `--manual` gets a 3-second Ctrl+C window unless `--force`. |
| `tzreload.sh` | event-driven, not called by hand | The timezone watcher above. |

Both installers are idempotent — `bootout` before `bootstrap` means re-running
them is the normal way to apply a change.

---

## Security & Reliability

### Credential Management
- ✅ `.env` file permissions enforced to `600` (owner-only readable)
- ✅ Email credentials **never exposed** to child processes (`set -a` removed)
- ✅ Credentials passed via **scoped environment variables** to subprocess — invisible to `ps`/`/proc`
- ✅ `notify.py` strips surrounding quotes from `.env` values before use
- ✅ SMTP error messages don't leak credentials or sensitive info

### Error Handling
- ✅ `set -e` halts scripts on any error (fail-fast)
- ✅ Trap handlers clean up resources on failure
- ✅ Email notifications sent on both success and failure
- ✅ Visible errors in LaunchAgent logs (`restart_stdout.log`, `restart_stderr.log`)
- ✅ Proper exit codes from `notify.py` (0=success, 1=config error, 2=network error)

### Lock File Safety
- ✅ Lock files include timestamp-based expiration (1-hour timeout)
- ✅ PID verification (prevent stale process detection)
- ✅ Atomic lock creation via `mkdir` (race-condition-free)
- ✅ Rate limiting for manual triggers (prevents duplicate execution)
- ✅ Clock skew protection (negative lock age clamped to zero)
- ✅ Abandoned lock directories reclaimed (a run killed by the Tue/Thu restart cannot wedge every future run)

> **On rate limiting.** `bubu_executor.sh` defines `RATE_LIMIT_MINUTES=5`, but
> nothing reads it — it carries a `# shellcheck disable=SC2034` annotation
> explaining exactly that. The rate limiting is real, it is just enforced
> elsewhere: `check_lock()` reads the PID and epoch out of `brew_update.lock`,
> skips the run while the owning PID is alive, and only clears the lock once it
> is older than `LOCK_TIMEOUT` (3600s). The **lock-file timestamp check** is the
> mechanism; `RATE_LIMIT_MINUTES` is a leftover constant kept for readability.

There are two layers of locking, which is easy to misread:

| Artifact | Written by | Purpose |
|---|---|---|
| `brew_update.lock` | `echo "$$ $(date +%s)" >` | Holds `PID epoch`. Answers "is a run alive, and how old is it?" |
| `brew_update.lock.d/` | `mkdir` | The actual mutex. `mkdir` is atomic, so two racing processes cannot both win. |

`reclaim_stale_lock_dir()` handles the case where a run died without firing its
`EXIT` trap — killed by the 9:00 AM restart, say. It refuses to touch the lock
while the owning PID is alive, falls back to the directory's own mtime when the
lock file is missing or unparseable, and only then removes both.

### Tool Validation
- ✅ Brew and uv paths validated early (before traps/logging)
- ✅ Python path resolution standardized (pyenv preferred, system fallback)
- ✅ Missing tools produce clear error messages (not silent failures)
- ✅ iTerm2 fallback to background execution if missing

### Log Management
- ✅ Automated logs rotate to keep last 30 days (completion markers only)
- ✅ The manual run log rotates to keep the last 500 lines (separate from automation)
- ✅ Error logs cleared on successful automation runs
- ✅ All log files created with `600` permissions (owner-only readable)
- ✅ Temporary files created with `600` permissions
- ✅ All timestamps recorded for audit trail

---

## Email Notifications

Both automations send **styled HTML emails** on success and failure with:

- **Status badge** (✓ Success / ✗ Failed) with visual indicators
- **Metadata** (Run type, date, timestamp, duration)
- **Package upgrade table** (package name, old version → new version)
- **Plain text fallback** for email clients that don't support HTML
- **Fully HTML-escaped output** (all 5 special chars including `'`) — no injection possible
- **Proper error messages** without credential leakage

### Success Example
```
Subject: Brew Update Complete — 2026-04-01

Brew update completed successfully on 2026-04-01 at Wed Apr 1 08:00:45 CDT 2026.
```

### Failure Example
```
Subject: Brew Update FAILED — 2026-04-01

Brew update failed on 2026-04-01.

Failed step: brew upgrade
Exit code: 1

See ~/IdeaProjects/BrewAutomation/error.log for details.

Next retry at 8:00 AM tomorrow.
```

---

## Setup

### 1. Clone/Copy to Home Directory
```bash
git clone <repo> ~/IdeaProjects/BrewAutomation
cd ~/IdeaProjects/BrewAutomation
chmod +x *.sh  # Make scripts executable
```

> The scripts resolve every path from `$HOME/IdeaProjects/BrewAutomation`. If
> you clone somewhere else, update `BASE_DIR` at the top of `brew_autoupdate.sh`,
> `bubu_executor.sh`, and `restart_script.sh`, and the `SOURCE_PATH` variables in
> the two installers.

### 2. Configure Gmail Credentials

Create `.env` in the project root. **These are placeholders — substitute your
own values.** `.env` is gitignored and must never be committed:

```bash
SENDER_EMAIL=your-email@gmail.com
SENDER_APP_PASSWORD="xxxx xxxx xxxx xxxx"
RECIPIENT_EMAIL=your-email@gmail.com
BREW_PATH=/opt/homebrew/bin/brew
UV_PATH=/opt/homebrew/bin/uv
```

| Variable | Required | Notes |
|---|---|---|
| `SENDER_EMAIL` | for email | Gmail address the notification is sent from |
| `SENDER_APP_PASSWORD` | for email | 16-character Gmail **App Password**, not your login password. Surrounding quotes are stripped on read, so either form works. |
| `RECIPIENT_EMAIL` | for email | Where notifications are delivered |
| `BREW_PATH` | no | Defaults to `/opt/homebrew/bin/brew` |
| `UV_PATH` | no | Defaults to `/opt/homebrew/bin/uv` |

If any of the three email variables is empty the run still completes — the
send is simply skipped. Updates never fail because email is misconfigured.

The values are read one at a time with targeted `grep`s rather than sourced, so
the credentials never enter the environment of every child process, and they are
passed to `notify.py` as scoped environment variables rather than argv — keeping
them out of `ps` output.

**To get a Gmail App Password:**
1. Enable 2-Step Verification: https://myaccount.google.com/security
2. Generate App Password: https://myaccount.google.com/apppasswords (select "Other (custom name)")
3. Copy the 16-character password (with spaces) into `.env`

**Security reminder:** `.env` contains plaintext credentials. The setup script enforces `chmod 600` (readable only by owner). Keep your app password secret and never commit `.env` to version control.

### 3. Install LaunchAgents
```bash
bash reload.sh                    # brew auto-update + timezone watcher (user-level)
bash reload_restart.sh            # restart automation (system-level, needs sudo)
```

Each installer substitutes the `__HOME__` placeholder in the plist template,
writes the result to the launchd directory, then loads it with the modern
`launchctl bootstrap` (`bootout` first, so re-running is safe):

```bash
# what reload.sh does, per agent
launchctl bootout    gui/"$(id -u)" ~/Library/LaunchAgents/com.suryakiran.brewauto.plist
launchctl bootstrap  gui/"$(id -u)" ~/Library/LaunchAgents/com.suryakiran.brewauto.plist

# what reload_restart.sh does
sudo launchctl bootout    system /Library/LaunchDaemons/com.suryakiran.restart.plist
sudo launchctl bootstrap  system /Library/LaunchDaemons/com.suryakiran.restart.plist
```

Output should show:
```
[OK] .env permissions: 600 (owner-only)
✓ LaunchAgent installed and loaded
✓ Timezone watcher installed and loaded
```

### 4. Verify Installation
```bash
launchctl list | grep suryakiran
```

Should show:
- `com.suryakiran.brewauto` (LaunchAgent, user-level)
- `com.suryakiran.restart` (LaunchDaemon, system-level)

---

## Manual Triggers

### Trigger Brew Update
```bash
~/IdeaProjects/BrewAutomation/bubu_executor.sh --manual
```
- Runs immediately in iTerm2 (or background if iTerm2 unavailable)
- Logs to separate `brew_update_manual.log` and `error_manual.log`
- Sends success/failure email
- Does NOT write completion marker (doesn't affect daily automation guard)
- Does NOT skip if already ran today (manual runs always execute)

### Trigger System Restart
```bash
bash ~/IdeaProjects/BrewAutomation/restart_script.sh --manual
```
- Prompts: "System restart will occur in 3 seconds. Press Ctrl+C to cancel."
- Logs to separate `restart_history_manual.log`
- Sends email notification
- **Use `--force` to skip the confirmation prompt:**
  ```bash
  bash ~/IdeaProjects/BrewAutomation/restart_script.sh --manual --force
  ```

---

## Monitoring

### Check Logs
```bash
# Automated brew run
tail -f ~/IdeaProjects/BrewAutomation/brew_update.log

# Manual brew run
tail -f ~/IdeaProjects/BrewAutomation/brew_update_manual.log

# Errors (automated)
tail -f ~/IdeaProjects/BrewAutomation/error.log

# Errors (manual)
tail -f ~/IdeaProjects/BrewAutomation/error_manual.log

# Skipped runs
tail -f ~/IdeaProjects/BrewAutomation/skips.log

# Restart history (automated)
cat ~/IdeaProjects/BrewAutomation/restart_history.log

# Restart history (manual)
cat ~/IdeaProjects/BrewAutomation/restart_history_manual.log

# LaunchAgent system output
tail -f ~/IdeaProjects/BrewAutomation/system_stderr.log
tail -f ~/IdeaProjects/BrewAutomation/system_stdout.log

# LaunchDaemon system output (restart)
tail -f ~/IdeaProjects/BrewAutomation/restart_stdout.log
tail -f ~/IdeaProjects/BrewAutomation/restart_stderr.log
```

### Check LaunchAgent Status
```bash
# View current state
launchctl list com.suryakiran.brewauto
launchctl list com.suryakiran.restart

# View next scheduled time
launchctl list | grep suryakiran
```

### Health Check
A healthy system shows:
- ✅ Completion marker in `brew_update.log` once per day
- ✅ Email received on success/failure
- ✅ No errors in `error.log` (or cleared after success)
- ✅ Lock file removed after run completes
- ✅ No stale locks older than 1 hour

---

## Log Rotation & Retention

| Log File | Rotation Policy | Retention |
|---|---|---|
| `brew_update.log` | Date-based (completion markers only) | Last 30 days |
| `brew_update_manual.log` | Line-based (last 500 lines) | Latest 500 lines (~50 runs) |
| `error.log` | Cleared on success, preserved on failure | Current failure or empty |
| `error_manual.log` | None — only the automation run clears its error log | Unbounded |
| `skips.log` | Line-based (last 100 lines) | Latest 100 lines (~30-50 days) |
| `brew_update_background.log` | iTerm2 fallback output (no rotation) | Unbounded |
| `system_stderr.log` | LaunchAgent output (no rotation) | Unbounded |
| `system_stdout.log` | LaunchAgent output (no rotation) | Unbounded |
| `restart_stdout.log` | LaunchDaemon output (no rotation) | Unbounded |
| `restart_stderr.log` | LaunchDaemon output (no rotation) | Unbounded |

All log files are created with `600` permissions (owner-only readable).

---

## File Reference

| File | Purpose |
|---|---|
| `brew_autoupdate.sh` | Guard script — checks for duplicates, manages lock file, launches executor |
| `bubu_executor.sh` | Executor script — runs all upgrades (brew, uv, python) with error handling |
| `restart_script.sh` | System restart — logs and sends email notification, with confirmation prompt |
| `tzreload.sh` | Timezone watcher — reloads LaunchAgent when system timezone changes |
| `notify.py` | Email sender — sends HTML/plain text emails via Gmail SMTP |
| `com.suryakiran.brewauto.plist` | LaunchAgent definition (brew updates, daily 8:00 AM) |
| `com.suryakiran.restart.plist` | LaunchDaemon definition (restart, Tue/Thu 9:00 AM) |
| `com.suryakiran.tzwatch.plist` | LaunchAgent definition (timezone watcher, event-driven via `WatchPaths` on `/private/etc`) |
| `reload.sh` | Installer — deploys brew LaunchAgent and tzwatch, enforces permissions |
| `reload_restart.sh` | Installer — deploys restart LaunchDaemon, enforces permissions |
| `.env` | Credentials (gitignored) — Gmail & tool paths |
| `.gitignore` | Git exclusions — credentials, logs, lock directory, IDE files |
| `.github/workflows/ci.yml` | Shell lint — `bash -n` + ShellCheck, then an advisory SonarCloud scan |
| `.github/workflows/dependabot-auto-merge.yml` | Queues Dependabot's patch/minor PRs to merge once `Shell lint` passes; majors wait for a human |
| `.github/workflows/slack-notify.yml` | Posts a Slack message on every push (any branch); skips silently if `SLACK_WEBHOOK_URL` is unset |
| `.github/dependabot.yml` | Weekly `github-actions` updates, minor/patch collapsed into one grouped PR |
| `sonar-project.properties` | SonarCloud project config for the CI-based scan |
| `LICENSE` | MIT |
| `README.md` | This file |

---

## Troubleshooting

### Brew automation not running
**Symptoms:** No logs updated, no emails received, missing completion marker

**Debug steps:**
1. Check LaunchAgent is loaded: `launchctl list com.suryakiran.brewauto`
   - Should show `0` (loaded) or `1` (exited successfully)
2. Check for errors: `tail ~/IdeaProjects/BrewAutomation/system_stderr.log`
3. Check LaunchAgent environment: `launchctl getenv PATH` (verify it includes brew path)
4. Reload the agent: `bash reload.sh`
5. Test manually: `bash ~/IdeaProjects/BrewAutomation/bubu_executor.sh --manual`

### Emails not sending
**Symptoms:** No email received on success/failure

**Debug steps:**
1. Verify `.env` has all credentials:
   ```bash
   grep -c "^SENDER_EMAIL\|^SENDER_APP_PASSWORD\|^RECIPIENT_EMAIL" ~/IdeaProjects/BrewAutomation/.env
   ```
   Expect `3`. (Counting rather than printing keeps the app password off your
   screen and out of your shell history.)
2. Verify app password is correct (not Gmail login password): https://myaccount.google.com/apppasswords
3. Verify 2-Step Verification is enabled: https://myaccount.google.com/security
4. Check for SMTP errors:
   ```bash
   tail -50 ~/IdeaProjects/BrewAutomation/error.log | grep -i "smtp\|auth\|network"
   ```
5. Test email sending (credentials loaded from `.env` automatically):
   ```bash
   cd ~/IdeaProjects/BrewAutomation && python3 notify.py "Test Email" "This is a test." ""
   ```

### Tools not found (brew, uv, python)
**Symptoms:** Error log shows "brew not found at..." / "uv not found at..."

**Debug steps:**
1. Find actual paths:
   ```bash
   which brew
   which uv
   which python3
   ```
2. Update `.env` with correct paths:
   ```bash
   BREW_PATH=$(which brew)
   UV_PATH=$(which uv)
   ```
3. Reload: `bash reload.sh`

### Manual run already in progress
**Symptoms:** Manual trigger returns immediately without running

**Debug steps:**
1. Check if lock file exists: `ls -la ~/IdeaProjects/BrewAutomation/brew_update.lock`
2. If it does, check the PID: `cat ~/IdeaProjects/BrewAutomation/brew_update.lock`
3. If that process doesn't exist, remove the stale lock and lock directory:
   ```bash
   rm -f ~/IdeaProjects/BrewAutomation/brew_update.lock
   rm -rf ~/IdeaProjects/BrewAutomation/brew_update.lock.d
   ```

### System restart confirmation appears even on scheduled run
**Symptoms:** 3-second countdown appears during the scheduled Tue/Thu 9:00 AM run

**This shouldn't happen** (no confirmation on automated runs), but if it does:
1. Check if `restart_script.sh --manual` was called instead of scheduled run
2. Check the scheduled time in plist: `cat ~/Library/LaunchDaemons/com.suryakiran.restart.plist | grep -A 5 StartCalendarInterval`

---

## Continuous Integration

There is no test suite — these scripts drive a live machine. CI lints instead,
on every push to `main` and every pull request. The **`Shell lint`** check is a
required status check on `main`.

Two stages, over every `*.sh` in the repo:

```bash
bash -n "$f"                                    # parse-only syntax check
shellcheck -S warning -e SC1091 *.sh            # warnings and above
```

A SonarCloud scan runs after the two lint stages. It is advisory rather than a
gate — the required check is `Shell lint` alone, so a SonarCloud outage never
blocks a merge.

`-S warning` is deliberate: style and info notes are advisory on a mature
script and would have turned the job red on day one for no correctness gain.
`SC1091` (cannot follow non-constant source) is excluded for the same reason.

Reproduce it locally before pushing:

```bash
brew install shellcheck
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 shellcheck -S warning -e SC1091
```

**Do not introduce new warnings.** Fixes already made to satisfy this gate,
worth knowing so they are not "tidied" back:

- `launchctl` targets are written `gui/"$(id -u)"`, not `gui/$(id -u)` — the
  command substitution is quoted (SC2086).
- The error log is truncated with `: > "$ERROR_LOG"`, not a bare
  `> "$ERROR_LOG"` (SC2188 — a redirection with no command).
- `local error_msg` is declared on its own line, separate from its assignment.
  Combining them masks the exit status of the command substitution (SC2155).
- `RATE_LIMIT_MINUTES` carries an explicit `# shellcheck disable=SC2034` with a
  comment pointing at the lock-file timestamp check that actually enforces the
  rate limit.

### Dependency updates

`.github/dependabot.yml` watches a single ecosystem — `github-actions`. This
repo is shell scripts plus a stdlib-only `notify.py`, so there is no package
manifest for anything else to read. Minor and patch bumps are collapsed into
**one grouped PR per week**; majors are excluded from the group and arrive as
their own PRs.

`.github/workflows/dependabot-auto-merge.yml` keys on exactly that split. A
grouped patch/minor PR has auto-merge enabled, so it merges itself once
`Shell lint` goes green; a major is left open for review. Auto-merge only
*queues* the merge — a red required check leaves the PR sitting there.

### Other workflows

`.github/workflows/slack-notify.yml` posts a push notification to Slack on
**every branch**, not just `main`. It is not a gate and not a required check:
if `SLACK_WEBHOOK_URL` is not set on the repository it prints how to set it and
exits `0`.

---

## Uninstalling

To disable and remove automations:

```bash
# Unload brew automation and timezone watcher
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.suryakiran.brewauto.plist
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.suryakiran.tzwatch.plist

# Unload restart automation (needs sudo for LaunchDaemon)
sudo launchctl bootout system /Library/LaunchDaemons/com.suryakiran.restart.plist

# Remove the project directory (optional)
rm -rf ~/IdeaProjects/BrewAutomation
```

---

## Requirements

- **macOS** 10.14+ (launchd, `osascript`, BSD `date`/`stat` flags)
- **Homebrew** — path taken from `BREW_PATH`, default `/opt/homebrew/bin/brew`
- **uv** — path taken from `UV_PATH`, default `/opt/homebrew/bin/uv`
- **Python 3** — for `notify.py`; pyenv's python is preferred, `python3` on `PATH` is the fallback
- **Optional:** pyenv (the `uv pip` library-upgrade step is skipped without it)
- **Optional:** iTerm2 (falls back to background execution if missing)

> Homebrew and uv are **not** optional. `validate_tools()` runs before the traps
> and locking are set up and exits `1` with a clear message if either path is
> not executable. `notify.py` uses only the standard library — there is nothing
> to `pip install`.

---

## Environment

This project uses `$HOME` for all paths — works on any macOS user account after installation. The plist templates contain `__HOME__` placeholders which are substituted during `reload.sh` installation.

---

## Version History

### v3.1 (Current — Homebrew 6.0 compatibility & lint gate)
- ✅ `HOMEBREW_NO_AUTO_UPDATE=1` scoped as a per-command prefix on the two `brew upgrade` calls — not exported, so `brew outdated` earlier in the run keeps its behaviour and the "Outdated packages" listing is unchanged
- ✅ `HOMEBREW_NO_UPGRADE_AUTO_UPDATES_CASKS=1` exported for Homebrew 6.0, which otherwise re-runs sudo-prompting cask installers unattended
- ✅ Casks upgraded without explicit names, so the above env var is not overridden
- ✅ Abandoned lock directories reclaimed via `reclaim_stale_lock_dir()`
- ✅ ShellCheck fixes: quoted `$(id -u)` in `launchctl gui/` targets, `: >` instead of a bare `>` truncation, `local error_msg` split from its assignment
- ✅ `RATE_LIMIT_MINUTES` annotated with a `shellcheck disable=SC2034` explaining that rate limiting is enforced by the lock-file timestamp check
- ✅ CI added: `bash -n` + ShellCheck (`-S warning`) as a required check on `main`

### v3.0 (Comprehensive Security Hardening)
- ✅ Credentials passed via scoped env vars — no longer visible in `ps` output
- ✅ Fixed `notify.py` quote-stripping bug (SMTP auth was failing when loaded from `.env`)
- ✅ Fixed missing `error_body` variable (error emails had blank plain-text body)
- ✅ Fixed `/bin/bash` missing from restart LaunchDaemon plist (restarts were silently failing)
- ✅ Fixed `notify.py` argument order in `restart_script.sh` (sender/password were shifted)
- ✅ Full HTML escaping on all email output including single-quote (`&#39;`)
- ✅ HTML-escaped date, time, and run-type fields in email templates
- ✅ Atomic lock acquisition via `mkdir` (race-condition-free)
- ✅ Atomic timezone state file write via `tmp → mv`
- ✅ Timezone string format validated before use
- ✅ `|| true` error handling on all `.env` grep calls in `restart_script.sh`
- ✅ `xargs -0` with null-delimited input for pip package names
- ✅ All log files created with `600` permissions (owner-only)
- ✅ Clock skew protection in lock age calculation
- ✅ `mktemp` result validated before use
- ✅ `awk` field count guard before package name extraction
- ✅ `$BASE_DIR` path escaped before osascript heredoc embedding
- ✅ Background fallback logs to `brew_update_background.log` instead of `/dev/null`
- ✅ `set -e` added to `brew_autoupdate.sh`, `reload.sh`, `reload_restart.sh`
- ✅ Restart log files pre-created at `600` in `reload_restart.sh`
- ✅ `brew_update.lock.d/` added to `.gitignore`
- ✅ Deprecated `launchctl unload` replaced with `bootout` throughout

### v2.0 (Security & Hardening Release)
- ✅ Added confirmation prompt to system restarts (prevent accidental data loss)
- ✅ Fixed credential exposure (no more `set -a`)
- ✅ Added stdout/stderr logging to LaunchDaemon
- ✅ Fixed silent email failures (proper exit codes)
- ✅ Enforced `.env` permissions (`chmod 600`)
- ✅ Fixed command injection risks (proper quoting)
- ✅ Added iTerm2 fallback (background execution)
- ✅ Improved lock file safety (timestamp-based expiration)
- ✅ Standardized Python resolution
- ✅ Added LaunchAgent validation (exit code checks)
- ✅ Manual log rotation for long-term retention
- ✅ Detailed troubleshooting guide

### v1.0 (Initial Release)
- Basic brew/uv/python automation
- Email notifications
- LaunchAgent scheduling
- Manual triggers

---

## License

[MIT](LICENSE)

---

## Disk / Cache Cleanup

`cache_cleanup.sh` reclaims regenerable cache space. It is **dry-run by
default** — it prints what it would delete and deletes nothing until `--apply`
is passed.

```bash
./cache_cleanup.sh                 # report only (default)
./cache_cleanup.sh --apply         # actually delete
./cache_cleanup.sh --emit-summary  # @@CAT@@ rows for the summary email
./cache_cleanup.sh --apply --force # ignore the free-space floor
```

It runs from `bubu_executor.sh` immediately after `brew cleanup`, appending a
**Disk Cleanup** table to the notification email. It is currently wired in
**dry-run mode**: once a few reports look right, add `--apply` to that line to
let it delete for real. A failure there is swallowed — a cleanup problem must
never fail an otherwise successful update run.

In `--apply` mode it exits early when the disk already has more than
`MIN_FREE_GB` (default 40) free; cleaning caches on a healthy disk only slows
the next build down.

### What it cleans

uv / npm / gh / Homebrew caches · Electron caches for Claude, VS Code and
Cursor · Chrome's cache · `__pycache__`, `.ruff_cache`, `.pytest_cache`,
`.mypy_cache` under `IdeaProjects` · Maven and Gradle artifacts unaccessed for
90+ days · Trash items older than 30 days.

### What it deliberately does *not* touch

| Path | Why |
|---|---|
| `com.apple.wallpaper/aerials` | The aerial videos were downloaded **on purpose** so the lock screen can shuffle all 164 offline. They look like a ~58 GB cache and are not one — this is user data. |
| `Claude/vm_bundles` | Local agent-mode VM; re-provisioning is a large download. |
| `~/Downloads`, `~/Documents`, `~/Desktop` | User files. |
| `node_modules`, `.venv`, `~/.pyenv`, `~/.nvm` | Reinstall cost outweighs the space. |
| `com.docker.docker` | Deleting the VM image destroys named volumes too. |

The `node_modules`/`.venv`/`.git` directories are `-prune`d from the project
sweep rather than filtered out of its results, so the walk never descends into
them.
