#!/bin/bash
set -euo pipefail

# ============================================================
# maldet-scanner entrypoint
# Modes: scan (default), update, monitor
# ============================================================

LOG_DIR="/data/logs"
QUARANTINE_DIR="/data/quarantine"
CLAM_DB="/data/clamav"
REPORT_FILE="${LOG_DIR}/last-scan-report.txt"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

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
    echo "[$TIMESTAMP] Updating ClamAV signatures..."
    # Point clamscan at our persistent DB
    if [ ! -f "$CLAM_DB/main.cvd" ] && [ ! -f "$CLAM_DB/main.cld" ]; then
        echo "[$TIMESTAMP] First run — downloading ClamAV database (this takes a few minutes)..."
    fi
    freshclam --datadir="$CLAM_DB" --config-file=/etc/clamav/freshclam.conf --foreground 2>&1 | tail -10 || {
        echo "[$TIMESTAMP] freshclam failed, trying without config..."
        freshclam --datadir="$CLAM_DB" --no-dns 2>&1 | tail -10 || echo "[$TIMESTAMP] WARNING: ClamAV signature update failed. Using existing signatures if available."
    }
    echo "[$TIMESTAMP] ClamAV signatures updated."

    echo "[$TIMESTAMP] Updating maldet signatures..."
    /usr/local/maldetect/maldet --update 2>&1 | tail -5 || echo "[$TIMESTAMP] maldet signature update skipped (may not have new sigs)"
    echo "[$TIMESTAMP] maldet signatures updated."
}

# ---- Build exclude arguments ----
build_excludes() {
    local excludes=""
    if [ -n "${SCAN_EXCLUDES:-}" ]; then
        IFS='|' read -ra EXCLUDE_ARRAY <<< "$SCAN_EXCLUDES"
        for pattern in "${EXCLUDE_ARRAY[@]}"; do
            pattern=$(echo "$pattern" | xargs) # trim whitespace
            if [ -n "$pattern" ]; then
                excludes="${excludes} --exclude-dir=${pattern}"
            fi
        done
    fi
    echo "$excludes"
}

# ---- Run scan ----
run_scan() {
    local scan_target="${1:-$SCAN_PATH}"
    local start_time=$(date +%s)

    echo ""
    echo "============================================================"
    echo "  maldet + ClamAV Scanner"
    echo "  Target: $scan_target"
    echo "  Started: $TIMESTAMP"
    echo "============================================================"
    echo ""

    # Update signatures first
    update_signatures

    # Configure maldet to use our ClamAV DB
    export CLAM_DB_PATH="$CLAM_DB"

    # Build clamscan command with excludes
    local excludes=$(build_excludes)

    echo "[$TIMESTAMP] Starting scan of $scan_target..."
    echo "[$TIMESTAMP] Excludes: ${SCAN_EXCLUDES:-none}"

    # Use clamscan directly with maldet's + ClamAV's signatures for best results
    # clamscan uses memory only during scan, then releases it
    local scan_result=0
    local scan_output

    scan_output=$(nice -n 19 ionice -c3 clamscan \
        --database="$CLAM_DB" \
        --recursive \
        --infected \
        --suppress-ok-results \
        --max-filesize=100M \
        --max-scansize=400M \
        --max-recursion=16 \
        --max-dir-recursion=30 \
        $excludes \
        "$scan_target" 2>&1) || scan_result=$?

    local end_time=$(date +%s)
    local duration=$(( end_time - start_time ))
    local duration_min=$(( duration / 60 ))
    local duration_sec=$(( duration % 60 ))

    # Parse results
    local files_scanned=$(echo "$scan_output" | grep "Scanned files:" | awk '{print $NF}')
    local infected=$(echo "$scan_output" | grep "Infected files:" | awk '{print $NF}')
    local data_scanned=$(echo "$scan_output" | grep "Data scanned:" | awk '{print $3, $4}')

    # Get list of infected files
    local infected_list=$(echo "$scan_output" | grep "FOUND$" || true)

    # Build report
    {
        echo "============================================================"
        echo "  SCAN REPORT — $(date '+%Y-%m-%d %H:%M:%S')"
        echo "============================================================"
        echo ""
        echo "Target:     $scan_target"
        echo "Duration:   ${duration_min}m ${duration_sec}s"
        echo "Files:      ${files_scanned:-unknown}"
        echo "Data:       ${data_scanned:-unknown}"
        echo "Infected:   ${infected:-0}"
        echo ""
        if [ -n "$infected_list" ]; then
            echo "THREATS FOUND:"
            echo "$infected_list"
            echo ""
        fi
        echo "--- Full Summary ---"
        echo "$scan_output" | tail -15
    } > "$REPORT_FILE"

    # Print report to stdout (Docker logs)
    cat "$REPORT_FILE"

    # Handle quarantine
    if [ "${infected:-0}" != "0" ] && [ "$QUARANTINE_ENABLED" = "true" ]; then
        echo ""
        echo "[$TIMESTAMP] Quarantining infected files..."
        echo "$infected_list" | while IFS= read -r line; do
            local filepath=$(echo "$line" | cut -d: -f1)
            if [ -f "$filepath" ]; then
                local basename=$(basename "$filepath")
                local qpath="${QUARANTINE_DIR}/${basename}.$(date +%s)"
                cp "$filepath" "$qpath" 2>/dev/null && echo "  Quarantined: $basename" || true
            fi
        done
    fi

    # Send Telegram notification
    if [ "$TELEGRAM_ENABLED" = "true" ]; then
        local status_icon="✅"
        local status_text="Clean"
        if [ "${infected:-0}" != "0" ]; then
            status_icon="🚨"
            status_text="${infected} THREATS FOUND"
        fi

        local tg_message="<b>${status_icon} Malware Scan Complete</b>

<b>Target:</b> ${scan_target}
<b>Duration:</b> ${duration_min}m ${duration_sec}s
<b>Files scanned:</b> ${files_scanned:-unknown}
<b>Data scanned:</b> ${data_scanned:-unknown}
<b>Result:</b> ${status_text}"

        if [ -n "$infected_list" ]; then
            # Truncate to avoid Telegram message limit
            local threat_summary=$(echo "$infected_list" | head -10 | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')
            tg_message="${tg_message}

<b>Threats:</b>
<pre>${threat_summary}</pre>"
        fi

        send_telegram "$tg_message"
    fi

    echo ""
    echo "[$TIMESTAMP] Scan complete. Report saved to $REPORT_FILE"

    # Exit with appropriate code
    if [ "${infected:-0}" != "0" ]; then
        return 1
    fi
    return 0
}

# ---- Monitor mode (inotify) ----
run_monitor() {
    echo "[$TIMESTAMP] Starting inotify monitor on $SCAN_PATH..."
    update_signatures

    send_telegram "🔍 <b>Malware Monitor Started</b>
Watching: ${SCAN_PATH}
New/modified files will be scanned automatically."

    inotifywait -m -r -e create -e modify -e moved_to "$SCAN_PATH" --format '%w%f' 2>/dev/null | while IFS= read -r file; do
        if [ -f "$file" ]; then
            echo "[$(date '+%H:%M:%S')] Scanning: $file"
            local result
            result=$(clamscan --database="$CLAM_DB" --infected --no-summary "$file" 2>&1) || true
            if echo "$result" | grep -q "FOUND"; then
                echo "🚨 THREAT: $result"
                send_telegram "🚨 <b>Malware Detected!</b>
<pre>$(echo "$result" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</pre>"

                if [ "$QUARANTINE_ENABLED" = "true" ]; then
                    local basename=$(basename "$file")
                    cp "$file" "${QUARANTINE_DIR}/${basename}.$(date +%s)" 2>/dev/null || true
                    echo "  Quarantined: $basename"
                fi
            fi
        fi
    done
}

# ---- Update only mode ----
run_update() {
    update_signatures
    echo "[$TIMESTAMP] Signature update complete."

    # Show signature stats
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
        run_scan "$SCAN_PATH"
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
