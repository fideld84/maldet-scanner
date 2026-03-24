#!/bin/bash
set -euo pipefail

# ============================================================
# maldet-scanner entrypoint v2
# Include-only model: scan specific high-risk directories
# Modes: scan (default), update, monitor
# ============================================================

LOG_DIR="/data/logs"
QUARANTINE_DIR="/data/quarantine"
CLAM_DB="/data/clamav"
REPORT_FILE="${LOG_DIR}/last-scan-report.txt"
SCAN_LOG="${LOG_DIR}/clamscan-current.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ---- High-risk scan targets (include-only model) ----
# Only these directories get scanned. Everything else is ignored.
# Override via SCAN_TARGETS env var (pipe-separated paths relative to /scan)
DEFAULT_SCAN_TARGETS=(
    # Nextcloud — scan all of it, internal cache dirs excluded below
    "/scan/nextcloud"
    # Internet downloads
    "/scan/Download"
    # Shared files
    "/scan/Share"
    # Dev repos (node_modules excluded below)
    "/scan/VSC_Projects"
    # User scripts
    "/scan/scripts"
    # Internet-facing services
    "/scan/appdata/swag"
    "/scan/appdata/authentik"
    "/scan/appdata/n8n"
    "/scan/appdata/code-server"
    "/scan/appdata/bitwarden"
    "/scan/appdata/cloudflared"
    "/scan/appdata/fda-chronicle"
    "/scan/appdata/fda-dashboard"
    "/scan/appdata/fda-homepage"
    "/scan/appdata/trip-planner"
    "/scan/appdata/auth-manager"
    "/scan/appdata/open-webui"
)

# Global directory excludes — large generated/cache dirs within scan targets
GLOBAL_EXCLUDES=(
    "node_modules"
    ".git"
    "__pycache__"
    ".next"
    ".vite"
    "dist"
    ".cache"
    # Nextcloud internal dirs (cache, previews, updater) — not user files
    "appdata_ocfczqns5ien"
    "appdata_oc5mu3v8qzpe"
    "appdata_ocup9j4vbqge"
    "updater-oc5mu3v8qzpe"
    "files_external"
)

mkdir -p "$LOG_DIR" "$QUARANTINE_DIR" "$CLAM_DB"

# Fix permissions — freshclam runs as UID 100 (clamav user)
chown -R clamav:clamav "$CLAM_DB" 2>/dev/null || chown -R 100:101 "$CLAM_DB" 2>/dev/null || chmod -R 777 "$CLAM_DB"
chmod -R u+rw "$LOG_DIR" "$QUARANTINE_DIR" 2>/dev/null || true

# ---- Telegram helper ----
send_telegram() {
    local message="$1"
    if [ "$TELEGRAM_ENABLED" = "true" ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d parse_mode="HTML" \
            -d text="$message" \
            --max-time 10 > /dev/null 2>&1 || true
    fi
}

# ---- Update signatures ----
update_signatures() {
    echo "[$(date '+%H:%M:%S')] Updating ClamAV signatures..."
    if [ ! -f "$CLAM_DB/main.cvd" ] && [ ! -f "$CLAM_DB/main.cld" ]; then
        echo "[$(date '+%H:%M:%S')] First run — downloading ClamAV database (this takes a few minutes)..."
    fi
    freshclam --datadir="$CLAM_DB" --config-file=/etc/clamav/freshclam.conf --foreground 2>&1 | tail -10 || {
        echo "[$(date '+%H:%M:%S')] freshclam failed, trying without config..."
        freshclam --datadir="$CLAM_DB" --no-dns 2>&1 | tail -10 || echo "[$(date '+%H:%M:%S')] WARNING: ClamAV signature update failed. Using existing signatures if available."
    }
    echo "[$(date '+%H:%M:%S')] ClamAV signatures updated."

    echo "[$(date '+%H:%M:%S')] Updating maldet signatures..."
    /usr/local/maldetect/maldet --update 2>&1 | tail -5 || echo "[$(date '+%H:%M:%S')] maldet signature update skipped (may not have new sigs)"
    echo "[$(date '+%H:%M:%S')] maldet signatures updated."
}

# ---- Build scan target list ----
build_scan_targets() {
    local targets=()

    if [ -n "${SCAN_TARGETS:-}" ]; then
        # User override via env var (pipe-separated)
        IFS='|' read -ra targets <<< "$SCAN_TARGETS"
    else
        targets=("${DEFAULT_SCAN_TARGETS[@]}")
    fi

    # Filter to only existing directories
    local valid_targets=()
    for t in "${targets[@]}"; do
        t=$(echo "$t" | xargs) # trim whitespace
        if [ -d "$t" ]; then
            valid_targets+=("$t")
        else
            echo "[$(date '+%H:%M:%S')] Skipping non-existent: $t" >&2
        fi
    done

    echo "${valid_targets[@]}"
}

# ---- Build exclude arguments ----
build_excludes() {
    local excludes=""
    for dir in "${GLOBAL_EXCLUDES[@]}"; do
        excludes="${excludes} --exclude-dir=${dir}"
    done

    # Additional user excludes from SCAN_EXCLUDES env var (pipe-separated)
    if [ -n "${SCAN_EXCLUDES:-}" ]; then
        IFS='|' read -ra EXCLUDE_ARRAY <<< "$SCAN_EXCLUDES"
        for pattern in "${EXCLUDE_ARRAY[@]}"; do
            pattern=$(echo "$pattern" | xargs)
            if [ -n "$pattern" ]; then
                excludes="${excludes} --exclude-dir=${pattern}"
            fi
        done
    fi
    echo "$excludes"
}

# ---- Progress monitor (background) ----
progress_monitor() {
    local log_file="$1"
    local start_time="$2"
    local interval="${PROGRESS_INTERVAL:-30}"

    local wait_count=0
    while [ ! -f "$log_file" ] && [ $wait_count -lt 30 ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done

    local last_count=0
    while [ -f "$log_file.running" ]; do
        sleep "$interval"
        [ -f "$log_file" ] || continue

        local current_count=$(wc -l < "$log_file" 2>/dev/null || echo 0)
        local elapsed=$(( $(date +%s) - start_time ))
        local elapsed_min=$((elapsed / 60))
        local elapsed_sec=$((elapsed % 60))
        local new_files=$((current_count - last_count))
        local rate=0
        if [ $elapsed -gt 0 ]; then
            rate=$((current_count * 60 / elapsed))
        fi

        local infected_so_far
        infected_so_far=$(grep -c "FOUND$" "$log_file" 2>/dev/null) || infected_so_far=0
        local infected_msg=""
        if [ "$infected_so_far" -gt 0 ] 2>/dev/null; then
            infected_msg=" | THREATS: ${infected_so_far}"
        fi

        echo "[$(date '+%H:%M:%S')] Progress: ${current_count} files scanned (${elapsed_min}m${elapsed_sec}s, ~${rate}/min, +${new_files} since last)${infected_msg}"
        last_count=$current_count
    done
}

# ---- Run scan ----
run_scan() {
    local start_time=$(date +%s)

    # Build target list
    local scan_targets_str=$(build_scan_targets)
    read -ra scan_targets <<< "$scan_targets_str"

    if [ ${#scan_targets[@]} -eq 0 ]; then
        echo "[$(date '+%H:%M:%S')] ERROR: No valid scan targets found!"
        exit 1
    fi

    echo ""
    echo "============================================================"
    echo "  maldet + ClamAV Scanner (v2 — targeted scan)"
    echo "  Targets: ${#scan_targets[@]} directories"
    echo "  Started: $TIMESTAMP"
    echo "============================================================"
    echo ""
    echo "Scan targets:"
    for t in "${scan_targets[@]}"; do
        echo "  -> $t"
    done
    echo ""

    # Update signatures first
    update_signatures

    # Build excludes
    local excludes=$(build_excludes)
    echo "[$(date '+%H:%M:%S')] Global excludes: ${GLOBAL_EXCLUDES[*]}"
    echo "[$(date '+%H:%M:%S')] Starting targeted scan..."
    echo "[$(date '+%H:%M:%S')] Progress updates every ${PROGRESS_INTERVAL:-30}s"
    echo ""

    # Create sentinel file and start progress monitor
    : > "$SCAN_LOG"
    touch "${SCAN_LOG}.running"
    progress_monitor "$SCAN_LOG" "$start_time" &
    local monitor_pid=$!

    # Run clamscan on all target directories at once
    local scan_result=0
    nice -n 19 ionice -c3 clamscan \
        --database="$CLAM_DB" \
        --recursive \
        --max-filesize=100M \
        --max-scansize=400M \
        --max-recursion=16 \
        --max-dir-recursion=30 \
        $excludes \
        "${scan_targets[@]}" > "$SCAN_LOG" 2>&1 || scan_result=$?

    # Stop progress monitor
    rm -f "${SCAN_LOG}.running"
    kill $monitor_pid 2>/dev/null || true
    wait $monitor_pid 2>/dev/null || true

    local end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    local duration_min=$(( duration / 60 ))
    local duration_sec=$(( duration % 60 ))

    # Parse results
    local scan_output=$(cat "$SCAN_LOG" 2>/dev/null || echo "")
    local files_scanned=$(echo "$scan_output" | grep "Scanned files:" | awk '{print $NF}')
    local infected=$(echo "$scan_output" | grep "Infected files:" | awk '{print $NF}')
    local data_scanned=$(echo "$scan_output" | grep "Data scanned:" | awk '{print $3, $4}')
    local infected_list=$(echo "$scan_output" | grep "FOUND$" || true)

    # Build report
    {
        echo "============================================================"
        echo "  SCAN REPORT — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "============================================================"
        echo ""
        echo "Targets:    ${#scan_targets[@]} directories"
        echo "Duration:   ${duration_min}m ${duration_sec}s"
        echo "Files:      ${files_scanned:-unknown}"
        echo "Data:       ${data_scanned:-unknown}"
        echo "Infected:   ${infected:-0}"
        echo ""
        echo "Scanned directories:"
        for t in "${scan_targets[@]}"; do
            echo "  -> $t"
        done
        echo ""
        if [ -n "$infected_list" ]; then
            echo "THREATS FOUND:"
            echo "$infected_list"
            echo ""
        fi
        echo "--- Full Summary ---"
        echo "$scan_output" | tail -15
    } > "$REPORT_FILE"

    echo ""
    echo "============================================================"
    echo "  SCAN COMPLETE"
    echo "============================================================"
    cat "$REPORT_FILE"

    # Handle quarantine
    if [ "${infected:-0}" != "0" ] && [ "$QUARANTINE_ENABLED" = "true" ]; then
        echo ""
        echo "[$(date '+%H:%M:%S')] Quarantining infected files..."
        echo "$infected_list" | while IFS= read -r line; do
            local filepath=$(echo "$line" | cut -d: -f1)
            if [ -f "$filepath" ]; then
                local bname=$(basename "$filepath")
                local qpath="${QUARANTINE_DIR}/${bname}.$(date +%s)"
                cp "$filepath" "$qpath" 2>/dev/null && echo "  Quarantined: $bname" || true
            fi
        done
    fi

    # Send Telegram notification
    if [ "$TELEGRAM_ENABLED" = "true" ]; then
        local status_icon="OK"
        local status_text="Clean"
        if [ "${infected:-0}" != "0" ]; then
            status_icon="ALERT"
            status_text="${infected} THREATS FOUND"
        fi

        local tg_message="<b>${status_icon} Malware Scan Complete</b>

<b>Targets:</b> ${#scan_targets[@]} directories
<b>Duration:</b> ${duration_min}m ${duration_sec}s
<b>Files scanned:</b> ${files_scanned:-unknown}
<b>Data scanned:</b> ${data_scanned:-unknown}
<b>Result:</b> ${status_text}"

        if [ -n "$infected_list" ]; then
            local threat_summary=$(echo "$infected_list" | head -10 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            tg_message="${tg_message}

<b>Threats:</b>
<pre>${threat_summary}</pre>"
        fi

        send_telegram "$tg_message"
    fi

    echo ""
    echo "[$(date '+%H:%M:%S')] Scan complete. Report saved to $REPORT_FILE"
    rm -f "$SCAN_LOG" "${SCAN_LOG}.running"

    if [ "${infected:-0}" != "0" ]; then
        return 1
    fi
    return 0
}

# ---- Monitor mode (inotify) ----
run_monitor() {
    echo "[$TIMESTAMP] Starting inotify monitor on scan targets..."
    update_signatures

    local scan_targets_str=$(build_scan_targets)
    read -ra scan_targets <<< "$scan_targets_str"

    send_telegram "<b>Malware Monitor Started</b>
Watching: ${#scan_targets[@]} directories
New/modified files will be scanned automatically."

    # Monitor all target directories
    inotifywait -m -r -e create -e modify -e moved_to "${scan_targets[@]}" --format '%w%f' 2>/dev/null | while IFS= read -r file; do
        if [ -f "$file" ]; then
            echo "[$(date '+%H:%M:%S')] Scanning: $file"
            local result
            result=$(clamscan --database="$CLAM_DB" --infected --no-summary "$file" 2>&1) || true
            if echo "$result" | grep -q "FOUND"; then
                echo "THREAT: $result"
                send_telegram "<b>Malware Detected!</b>
<pre>$(echo "$result" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"

                if [ "$QUARANTINE_ENABLED" = "true" ]; then
                    local bname=$(basename "$file")
                    cp "$file" "${QUARANTINE_DIR}/${bname}.$(date +%s)" 2>/dev/null || true
                    echo "  Quarantined: $bname"
                fi
            fi
        fi
    done
}

# ---- Update only mode ----
run_update() {
    update_signatures
    echo "[$TIMESTAMP] Signature update complete."

    echo ""
    echo "ClamAV DB files:"
    ls -lh "$CLAM_DB"/*.c?d 2>/dev/null || echo "  No ClamAV DB files found"
    echo ""
    echo "maldet signatures:"
    ls /usr/local/maldetect/sigs/ 2>/dev/null | wc -l
    echo " signature files"
}

# ---- Main ----
case "${MODE:-scan}" in
    scan)
        run_scan
        ;;
    monitor)
        run_monitor
        ;;
    update)
        run_update
        ;;
    *)
        echo "Unknown mode: $MODE"
        echo "Valid modes: scan, update, monitor"
        exit 1
        ;;
esac
