#!/bin/zsh
# Time Machine Excluder

SKIP_FIRST_PART=false
DEBUG_MODE=false
DRY_RUN=false
MAX_DEPTH=15

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-first|-s)
      SKIP_FIRST_PART=true
      shift
      ;;
    --debug|-d)
      DEBUG_MODE=true
      shift
      ;;
    --dry-run|-n)
      DRY_RUN=true
      shift
      ;;
    --max-depth|-m)
      if [[ -n "$2" && "$2" =~ ^[0-9]+$ ]]; then
        MAX_DEPTH="$2"
        shift 2
      else
        echo "Error: --max-depth requires a numeric argument"
        exit 1
      fi
      ;;
    --help|-h)
      echo "Time Machine Node Modules & pnpm Excluder"
      echo "======================================================="
      echo "This script helps manage Time Machine exclusions by:"
      echo "1. Finding and excluding node_modules and .pnpm-store directories under ~/git"
      echo "2. Excluding static cache paths (~/.npm, ~/Library/pnpm/store, ~/Library/Caches/pnpm)"
      echo "3. Cleaning up hanging exclusions (paths that no longer exist)"
      echo ""
      echo "Exclusions are fixed-path (SkipPaths) entries: they live in one central,"
      echo "auditable list and are only ever added by you or this script (apps/macOS use"
      echo "the privilege-free sticky xattr instead). This is why adding AND removing"
      echo "require administrator rights (sudo) and Full Disk Access."
      echo ""
      echo "Usage: $0 [options]"
      echo ""
      echo "Options:"
      echo "  --skip-first, -s     Skip the node_modules + pnpm exclusion part, only clean hanging exclusions"
      echo "  --debug, -d          Enable debug mode (shows detailed exclusion information)"
      echo "  --dry-run, -n        Run in simulation mode without making actual changes"
      echo "  --max-depth, -m N    Set maximum directory depth to search (default: 15)"
      echo "  --help, -h           Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0                   Run node_modules + pnpm exclusion and hanging exclusion cleanup"
      echo "  $0 --skip-first      Only clean up hanging exclusions"
      echo "  $0 --debug           Show detailed exclusion information"
      echo "  $0 --dry-run         Simulate changes without applying them"
      echo "  $0 --max-depth 20    Set search depth to 20 directories deep"
      echo "  $0 -s -d             Skip first part and show debug information"
      echo ""
      echo "Notes:"
      echo "- By default, the script will make actual changes to Time Machine exclusions"
      echo "- Use --dry-run if you want to see what would happen without making changes"
      echo "- The script automatically finds exclusions from both preferences and extended attributes"
      echo "- Default maximum search depth is 15 directories"
      echo "- Adding and removing exclusions both need admin rights (sudo) and Full Disk"
      echo "  Access, because fixed-path exclusions live in a root-owned system plist"
      echo "- Run as your normal user (NOT with sudo); the script elevates only the"
      echo "  individual tmutil calls that need it"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo "Use --help or -h for usage information"
      exit 1
      ;;
  esac
done

cleanup() {
    jobs -p | /usr/bin/xargs kill 2>/dev/null
    /bin/rm -f "$RESULTS_FILE" "$EXCLUSIONS_FILE" "$HANGING_FILE" 2>/dev/null
    exit
}
trap cleanup EXIT INT TERM

TMP_BASE="${TMPDIR:-/tmp}"
RESULTS_FILE=$(/usr/bin/mktemp "${TMP_BASE%/}/tm_nodemodules.XXXXXX")
EXCLUSIONS_FILE=$(/usr/bin/mktemp "${TMP_BASE%/}/tm_exclusions.XXXXXX")
HANGING_FILE=$(/usr/bin/mktemp "${TMP_BASE%/}/tm_hanging.XXXXXX")

if [[ $EUID -eq 0 ]]; then
    echo "⚠️  Do NOT run as root/sudo. Run with regular user privileges."
    exit 1
fi

if ! /usr/bin/mdutil -s / | /usr/bin/grep -q "Indexing enabled"; then
    echo "⚠️  Warning: Spotlight indexing may not be enabled. Extended attribute exclusions might not be found."
fi

if ! /usr/bin/which tmutil &> /dev/null; then
    echo "❌ tmutil not found - this script requires macOS Time Machine"
    exit 1
fi

# Returns 0 if the calling process appears to have Full Disk Access, 1 otherwise.
# There's no API to query TCC status, so we probe: reading the user's TCC
# database is permission-denied unless the caller (the terminal app) holds FDA.
has_full_disk_access() {
    /bin/cat "$HOME/Library/Application Support/com.apple.TCC/TCC.db" >/dev/null 2>&1
}

# Best-effort nudge: post a notification and deep-link to the FDA settings pane.
# macOS won't let a script trigger the native FDA grant dialog, so this is the
# closest we can get to "prompting" the user.
open_fda_settings() {
    /usr/bin/osascript -e 'display notification "Grant your terminal Full Disk Access, then re-run." with title "Time Machine Excluder"' >/dev/null 2>&1
    /usr/bin/open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null
}

# Advisory pre-flight: warn early (before the long find) if FDA looks missing.
# The probe runs as your user while the real work runs under sudo, so it can't
# perfectly predict the tmutil outcome — hence advisory, not a hard block.
if [[ $DRY_RUN == false ]] && ! has_full_disk_access; then
    echo "⚠️  Full Disk Access does not appear to be granted to this terminal."
    echo "   tmutil exclusion changes will likely fail without it."
    echo "   Opening: System Settings → Privacy & Security → Full Disk Access"
    open_fda_settings
    echo ""
    echo "❓ Continue anyway? (y/N) "
    read -q FDA_REPLY
    echo ""
    if [[ ! $FDA_REPLY =~ ^[Yy]$ ]]; then
        echo "🛑 Stopped. Grant Full Disk Access to your terminal and re-run."
        exit 1
    fi
fi

if [[ $DRY_RUN == true ]]; then
    echo "🔍 Running in DRY RUN mode - no changes will be made"
else
    echo "🔧 Running in LIVE mode - changes WILL be applied"
fi

if [[ $SKIP_FIRST_PART == false ]]; then
    # ===========================
    # PART 1: Exclude node_modules + .pnpm-store under ~/git, plus static caches
    # ===========================

    # Search roots — edit for your environment
    SEARCH_PATHS=(
        "$HOME/git"
    )

    echo "🔍 Search depth set to $MAX_DEPTH directories deep"

    echo "🔍 Searching for node_modules directories and pnpm store/cache paths..."
    echo "   This may take a while depending on the size of your filesystem..."

    for search_path in "${SEARCH_PATHS[@]}"; do
        echo "Searching in $search_path..."

        # progress spinner
        (
            i=0
            while true; do
                i=$((i+1))
                echo -n "."
                if [[ $((i % 60)) -eq 0 ]]; then
                    current=$(/usr/bin/wc -l < "$RESULTS_FILE" 2>/dev/null || echo "0")
                    echo " Found $current so far"
                fi
                /bin/sleep 1
            done
        ) &
        PROGRESS_PID=$!

        # -prune stops descent at each match, so a node_modules/.pnpm-store nested
        # inside an already-matched dir is never reported (and not redundantly excluded).
        /usr/bin/find "$search_path" -maxdepth "$MAX_DEPTH" -type d \( -name "node_modules" -o -name ".pnpm-store" \) -prune -print 2>/dev/null >> "$RESULTS_FILE" || true

        kill $PROGRESS_PID 2>/dev/null
        wait $PROGRESS_PID 2>/dev/null
        echo " Done."

        current=$(/usr/bin/wc -l < "$RESULTS_FILE" 2>/dev/null || echo "0")
        echo "   → Found $current node_modules directories so far"
    done

    # Static caches (added only if present); the find above never reaches these.
    STATIC_PATHS=(
        "$HOME/.npm"
        "$HOME/Library/pnpm/store"
        "$HOME/Library/Caches/pnpm"
    )
    echo "🔍 Checking for static cache paths..."
    for static_path in "${STATIC_PATHS[@]}"; do
        if [[ -d "$static_path" ]]; then
            echo "   → Found static path: $static_path"
            echo "$static_path" >> "$RESULTS_FILE"
        fi
    done

    echo "Sorting and removing duplicates..."
    /usr/bin/sort -u "$RESULTS_FILE" -o "$RESULTS_FILE"

    RESULT_COUNT=$(/usr/bin/wc -l < "$RESULTS_FILE" | /usr/bin/tr -d ' ')

    if [[ $RESULT_COUNT -eq 0 ]]; then
        echo "✅ No node_modules or pnpm directories found"
        /bin/rm -f "$RESULTS_FILE"
    else
        echo "📦 Found $RESULT_COUNT node_modules / pnpm directories:"
        echo "===================="
        /bin/cat "$RESULTS_FILE"
        echo "===================="
        echo "Total: $RESULT_COUNT directories"

        echo ""
        echo "❓ Proceed with excluding these from Time Machine? (y/N) "
        read -q REPLY
        echo ""

        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "🛑 Operation canceled"
            /bin/rm -f "$RESULTS_FILE"
        else
            echo "⏳ Starting exclusion process..."
            EXCLUDED=0
            SKIPPED=0
            FAILED=0

            # Fixed-path (-p) exclusions live in a root-owned plist, so they need sudo.
            # Cache creds once; sudo reads /dev/tty, so the loop's stdin redirect below
            # doesn't steal the password prompt.
            if [[ $DRY_RUN == false ]]; then
                echo "🔑 Adding fixed-path exclusions requires administrator rights."
                if ! /usr/bin/sudo -v; then
                    echo "❌ Could not obtain administrator rights; no exclusions were added."
                    /bin/rm -f "$RESULTS_FILE"
                    exit 1
                fi
            fi

            # NB: do NOT name this loop var "path" — in zsh that's the special array
            # tied to $PATH, so `read path` would clobber PATH and break bare commands.
            while read -r target_path; do
                if /usr/bin/tmutil isexcluded "$target_path" | /usr/bin/grep -q "\[Excluded\]"; then
                    echo "🔹 [Skipped] Already excluded: $target_path"
                    (( ++SKIPPED ))
                    continue
                fi

                if [[ $DRY_RUN == true ]]; then
                    echo "🔸 [Dry Run] Would exclude (fixed-path): $target_path"
                else
                    if err=$(/usr/bin/sudo /usr/bin/tmutil addexclusion -p "$target_path" 2>&1); then
                        echo "✅ [Excluded] $target_path"
                        (( ++EXCLUDED ))
                    else
                        echo "❌ [Failed] $target_path"
                        [[ $DEBUG_MODE == true ]] && echo "      ↳ ${err:-(no error output)}"
                        (( ++FAILED ))
                    fi
                fi
            done < "$RESULTS_FILE"

            /bin/rm -f "$RESULTS_FILE"

            echo ""
            echo "🛠️  Final checks:"
            if [[ $DRY_RUN == true ]]; then
                echo "⚠️  DRY RUN MODE - No changes made"
                echo "   To apply exclusions, re-run without --dry-run"
            else
                echo "✅ Summary:"
                echo "   - Excluded: $EXCLUDED paths (fixed-path)"
                echo "   - Skipped: $SKIPPED paths (already excluded)"
                echo "   - Failed: $FAILED paths"
                if [[ $FAILED -gt 0 ]]; then
                    echo ""
                    echo "💡 If exclusions failed, grant your terminal Full Disk Access and retry:"
                    echo "   System Settings → Privacy & Security → Full Disk Access"
                    echo "   (re-run with --debug to see the underlying tmutil errors)"
                    open_fda_settings
                fi
            fi

            echo ""
            echo "💡 Remember to restart Time Machine backups:"
            echo "   sudo tmutil startbackup"
        fi
    fi

    echo ""
    echo "🧹 Would you like to check for hanging exclusions (excluded paths that no longer exist)? (y/N) "
    read -q CLEAN_REPLY
    echo ""

    if [[ ! $CLEAN_REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping cleanup. Script complete."
        exit 0
    fi
else
    echo "🔄 Skipping node_modules search as requested..."
fi

# ===========================
# PART 2: Clean up hanging exclusions
# ===========================
# Part 1 writes fixed-path (SkipPaths) entries and macOS never auto-cleans them, so a
# deleted project leaves a stale entry pointing at nothing. This prunes those.

echo "⏳ Fetching all Time Machine exclusions..."

# SkipPaths from the TM plist; PlistBuddy prints one element per line verbatim (paths
# with spaces/quotes survive); sed strips the "Array {" / "}" wrapper and leading space.
/usr/libexec/PlistBuddy -c "Print :SkipPaths" \
    /Library/Preferences/com.apple.TimeMachine.plist 2>/dev/null \
    | /usr/bin/sed -e '1d' -e '$d' -e 's/^[[:space:]]*//' > "$EXCLUSIONS_FILE"

# xattr exclusions (no sudo needed)
echo "Searching for files with Time Machine exclusion attributes..."
/usr/bin/mdfind "com_apple_backup_excludeItem = 'com.apple.backupd'" >> "$EXCLUSIONS_FILE" 2>/dev/null

# dedupe (both sources can report the same path)
/usr/bin/sort -u "$EXCLUSIONS_FILE" -o "$EXCLUSIONS_FILE"

TOTAL_EXCLUSIONS=$(/usr/bin/wc -l < "$EXCLUSIONS_FILE" | /usr/bin/tr -d ' ')
echo "Found $TOTAL_EXCLUSIONS total exclusions."

if [[ $DEBUG_MODE == true ]]; then
    echo ""
    echo "🔍 DEBUG: All Time Machine exclusions found:"
    echo "===================="
    if [[ $TOTAL_EXCLUSIONS -gt 0 ]]; then
        /bin/cat "$EXCLUSIONS_FILE"
    else
        echo "No exclusions found."
    fi
    echo "===================="
    echo ""
fi

# Fallback: read exclusions from the latest backup
if [[ $TOTAL_EXCLUSIONS -eq 0 ]]; then
    echo "Trying alternative method to get exclusions..."

    # 'destinationinfo' labels the path field "Mount Point", value after " : " (first dest).
    TM_VOLUMES=$(/usr/bin/tmutil destinationinfo 2>/dev/null | /usr/bin/awk -F' : ' '/Mount Point/{print $2; exit}')

    if [[ -n "$TM_VOLUMES" && -d "$TM_VOLUMES" ]]; then
        LATEST_BACKUP=$(/bin/ls -t "$TM_VOLUMES" | /usr/bin/grep -v "Latest" | /usr/bin/head -1)
        if [[ -n "$LATEST_BACKUP" && -d "$TM_VOLUMES/$LATEST_BACKUP" ]]; then
            EXCLUSION_PLIST="$TM_VOLUMES/$LATEST_BACKUP/.exclusions.plist"
            if [[ -f "$EXCLUSION_PLIST" ]]; then
                echo "Reading exclusions from backup: $EXCLUSION_PLIST"
                /usr/bin/plutil -p "$EXCLUSION_PLIST" | /usr/bin/grep "UserExcludedPaths" -A 100 | /usr/bin/grep " => " | /usr/bin/awk -F' => ' '{print $2}' | /usr/bin/sed 's/"//g' > "$EXCLUSIONS_FILE"
                TOTAL_EXCLUSIONS=$(/usr/bin/wc -l < "$EXCLUSIONS_FILE" | /usr/bin/tr -d ' ')
                echo "Found $TOTAL_EXCLUSIONS total exclusions from backup."
            fi
        fi
    fi
fi

echo "⏳ Checking for hanging exclusions (this may take a moment)..."
HANGING_COUNT=0

while read -r excluded_path; do
    if [[ -z "$excluded_path" ]]; then
        continue
    fi

    if [[ ! -e "$excluded_path" ]]; then
        echo "$excluded_path" >> "$HANGING_FILE"
        (( ++HANGING_COUNT ))
    fi
done < "$EXCLUSIONS_FILE"

if [[ $HANGING_COUNT -eq 0 ]]; then
    echo "✅ No hanging exclusions found. All excluded paths exist."

    if [[ $DEBUG_MODE == true ]]; then
        echo ""
        echo "🔍 DEBUG: All excluded paths were verified to exist on the filesystem."
        echo ""
    fi

    /bin/rm -f "$EXCLUSIONS_FILE" "$HANGING_FILE" 2>/dev/null
    exit 0
fi

echo "🗑️ Found $HANGING_COUNT hanging exclusions (paths that no longer exist):"
echo "===================="
/bin/cat "$HANGING_FILE"
echo "===================="

if [[ $DEBUG_MODE == true ]]; then
    echo ""
    echo "🔍 DEBUG: Hanging exclusions represent $HANGING_COUNT out of $TOTAL_EXCLUSIONS total exclusions."
    echo "🔍 DEBUG: $((TOTAL_EXCLUSIONS - HANGING_COUNT)) exclusions still point to existing paths."
    echo ""
fi

echo ""
echo "❓ Do you want to remove these hanging exclusions from Time Machine? (y/N) "
read -q REMOVE_REPLY
echo ""

if [[ ! $REMOVE_REPLY =~ ^[Yy]$ ]]; then
    echo "🛑 Removal canceled. Hanging exclusions remain in Time Machine."
    /bin/rm -f "$EXCLUSIONS_FILE" "$HANGING_FILE" 2>/dev/null
    exit 0
fi

echo "⏳ Removing hanging exclusions..."
REMOVED=0
FAILED=0

# NB: loop var is "target_path", not "path" — in zsh "path" is bound to $PATH.
if [[ $DRY_RUN == true ]]; then
    while read -r target_path; do
        echo "🔸 [Dry Run] Would remove exclusion: $target_path"
    done < "$HANGING_FILE"
else
    # Fixed-path removal needs -p AND root (root-owned plist); elevate via sudo, creds cached once.
    echo "🔑 Removing fixed-path exclusions requires administrator rights."
    if ! /usr/bin/sudo -v; then
        echo "❌ Could not obtain administrator rights; no exclusions were removed."
        /bin/rm -f "$EXCLUSIONS_FILE" "$HANGING_FILE" 2>/dev/null
        exit 1
    fi

    while read -r target_path; do
        if err=$(/usr/bin/sudo /usr/bin/tmutil removeexclusion -p "$target_path" 2>&1); then
            echo "✅ [Removed] $target_path"
            (( ++REMOVED ))
        else
            echo "❌ [Failed] $target_path"
            [[ $DEBUG_MODE == true ]] && echo "      ↳ ${err:-(no error output)}"
            (( ++FAILED ))
        fi
    done < "$HANGING_FILE"
fi

/bin/rm -f "$EXCLUSIONS_FILE" "$HANGING_FILE" 2>/dev/null

echo ""
echo "🛠️  Hanging exclusions cleanup summary:"
if [[ $DRY_RUN == true ]]; then
    echo "⚠️  DRY RUN MODE - No changes made"
    echo "   Would have removed $HANGING_COUNT hanging exclusions"
    echo "   To apply removals, re-run without --dry-run"
else
    echo "✅ Successfully removed: $REMOVED exclusions"
    echo "❌ Failed to remove: $FAILED exclusions"
    if [[ $FAILED -gt 0 ]]; then
        echo ""
        echo "💡 If removals failed, grant your terminal Full Disk Access and retry:"
        echo "   System Settings → Privacy & Security → Full Disk Access"
        echo "   (re-run with --debug to see the underlying tmutil errors)"
        open_fda_settings
    fi
fi

echo ""
echo "Script complete!"
