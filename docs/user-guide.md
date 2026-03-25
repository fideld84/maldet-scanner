# maldet-scanner User Guide

Complete guide for setting up, running, and managing the maldet-scanner container on Unraid.

---

## Table of Contents

1. [Installation](#installation)
2. [First Run](#first-run)
3. [How Scanning Works (v2)](#how-scanning-works-v2)
4. [Configuring Scan Targets](#configuring-scan-targets)
5. [Setting Up Telegram Alerts](#setting-up-telegram-alerts)
6. [Scheduling Scans](#scheduling-scans)
7. [Understanding Scan Results](#understanding-scan-results)
8. [Managing Quarantined Files](#managing-quarantined-files)
9. [Real-Time File Monitoring](#real-time-file-monitoring)
10. [Signature Updates](#signature-updates)
11. [FDA Dashboard Integration](#fda-dashboard-integration)
12. [Troubleshooting](#troubleshooting)
13. [FAQ](#faq)

---

## Installation

### Option A: Unraid Docker Template (Recommended)

1. In the Unraid web UI, go to **Docker** tab
2. Click **Add Container**
3. Set **Template Repository** to:
   ```
   https://raw.githubusercontent.com/fideld84/maldet-scanner/main/unraid-template.xml
   ```
4. Click **Apply** to load the template
5. Configure Telegram alerts (optional) and click **Apply** to create the container

### Option B: Manual Docker Setup

Pull the image and create the container manually:

```bash
docker pull ghcr.io/fideld84/maldet-scanner:latest
```

Then run with your preferred configuration (see [Quick Start](../README.md#quick-start) in README).

---

## First Run

On the very first run, the container downloads the full ClamAV signature database. This is a one-time download of approximately **300-400 MB** and takes **2-5 minutes** depending on your connection.

**What happens during first run:**

1. Directories are created (`/data/clamav`, `/data/quarantine`, `/data/logs`)
2. ClamAV signatures are downloaded (main.cvd + daily.cld)
3. maldet signatures are updated
4. Scan targets are validated (non-existent dirs are skipped with a warning)
5. The scan begins

**Expected Docker log output on first run:**

```
[14:30:00] Updating ClamAV signatures...
[14:30:00] First run -- downloading ClamAV database (this takes a few minutes)...
[14:33:45] ClamAV signatures updated.
[14:33:45] Updating maldet signatures...
[14:33:47] maldet signatures updated.
[14:33:47] Global excludes: /node_modules$ /\.git$ /__pycache__$ ...
[14:33:47] Starting targeted scan...
```

Subsequent runs reuse the cached signatures and only download incremental updates (~1-2 MB), which takes seconds.

---

## How Scanning Works (v2)

### The Include-Only Model

Version 2 fundamentally changed how scanning works. Instead of scanning your entire `/mnt/user` share and trying to exclude everything that does not need scanning (slow, error-prone), v2 **only scans specific high-risk directories**.

**Why this matters:**
- A typical Unraid `/mnt/user` share has 200,000+ files across media libraries, Docker overlays, databases, etc.
- Only ~5,000 of those files can actually contain malware (documents, scripts, executables, archives)
- v1 took **9+ hours** scanning everything. v2 takes **~9 minutes**.

### Three Layers of Filtering

1. **Target directories** -- only 17 specific directories are scanned (Nextcloud, Downloads, dev repos, internet-facing services)
2. **Directory excludes** -- within those targets, generated/cache dirs are skipped (`node_modules`, `.git`, Nextcloud internal dirs, trash, versions)
3. **Media file skipping** -- image, video, and audio files are excluded because they cannot contain executable malware

### What ClamAV Actually Scans

After all filtering, ClamAV deep-scans approximately **5,000 files** -- every one of which could theoretically contain malware:

- PDFs, Office documents (macro malware)
- ZIP/RAR archives (embedded malware)
- Shell scripts, Python, JavaScript, PHP (web shells, backdoors)
- Executables and DLLs
- Config files (YAML, JSON, XML)
- Database files (SQLite)
- HTML/CSS (XSS payloads, phishing)

---

## Configuring Scan Targets

### Default Targets

The scanner includes 17 built-in scan targets covering the highest-risk areas on a typical Unraid server. See the [README](../README.md#default-scan-targets) for the full list.

### Overriding Scan Targets

Set the `SCAN_TARGETS` env var with pipe-separated paths (relative to `/scan`):

```
/scan/nextcloud|/scan/Download|/scan/appdata/swag|/scan/appdata/custom-app
```

This **replaces** the default targets entirely. Only the directories you list will be scanned.

### Adding a New Service

When you install a new internet-facing Docker container, add its appdata directory to the scan targets:

1. Edit the container in Unraid Docker UI
2. Set `SCAN_TARGETS` to include the new directory
3. Or, to keep the defaults and add one more, leave `SCAN_TARGETS` empty and add the new service to the `DEFAULT_SCAN_TARGETS` array in `entrypoint.sh`

### Scan Target Validation

The scanner checks that each target directory exists before scanning. Non-existent directories are logged and skipped:

```
[14:33:47] Skipping non-existent: /scan/appdata/removed-app
```

> **Important:** The scan target mount is **read-only** (`ro`). The scanner cannot modify or delete your files. Quarantine creates copies in a separate volume.

---

## Setting Up Telegram Alerts

### Step 1: Create a Telegram Bot

1. Open Telegram and search for **@BotFather**
2. Send `/newbot`
3. Follow the prompts to name your bot
4. Copy the **bot token** (looks like `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)

### Step 2: Get Your Chat ID

1. Send any message to your new bot
2. Open this URL in a browser (replace YOUR_TOKEN):
   ```
   https://api.telegram.org/botYOUR_TOKEN/getUpdates
   ```
3. Find `"chat":{"id":123456789}` in the response -- that number is your chat ID

### Step 3: Configure the Container

Set these environment variables in Unraid:

| Variable | Value |
|----------|-------|
| `TELEGRAM_ENABLED` | `true` |
| `TELEGRAM_BOT_TOKEN` | Your bot token |
| `TELEGRAM_CHAT_ID` | Your chat ID |

### What You Receive

- **After every scan:** Summary with target count, file count, duration, and result
- **Monitor mode:** Instant alert when malware is detected in a new/modified file
- **Threats include:** File path and threat name (first 10 listed)

---

## Scheduling Scans

The container in `scan` mode runs once and exits. Use a scheduler for periodic scans.

### Recommended: Every 6 Hours

With ~9-minute scans, running every 6 hours gives you same-day threat detection with only **36 minutes of total scan time per day**. Any new malware is caught within 6 hours.

### Using Unraid User Scripts Plugin

1. Install **User Scripts** from Community Applications (if not already installed)
2. Go to **Settings > User Scripts**
3. Click **Add New Script**, name it `MaldetAntivirusScan`
4. Click the script name, then **Edit Script**:

```bash
#!/bin/bash
docker start maldet-scanner
```

5. Set the schedule to **Custom** with cron: `0 */6 * * *`

### Parity Check Awareness

The included User Script template detects running parity checks and skips the scan to avoid I/O contention. This is important for large arrays where parity checks can take 24+ hours.

### Manual Scan

Start a scan anytime from the Unraid Docker UI by clicking **Start**, or via CLI:

```bash
docker start maldet-scanner
```

Watch progress in real-time:

```bash
docker logs -f maldet-scanner
```

---

## Understanding Scan Results

### Docker Log Output

During a scan, the Docker logs show:

```
============================================================
  maldet + ClamAV Scanner (v2 -- targeted scan)
  Targets: 17 directories
  Started: 2026-03-24 13:23:18
============================================================

Scan targets:
  -> /scan/nextcloud
  -> /scan/Download
  -> /scan/Share
  -> /scan/VSC_Projects
  -> /scan/scripts
  -> /scan/appdata/swag
  ...

[13:14:28] Updating ClamAV signatures...
[13:14:35] ClamAV signatures updated.
[13:23:18] Starting targeted scan...
[13:23:48] Progress: 542 files scanned (0m30s, ~1084/min, +542 since last)
[13:24:18] Progress: 1,203 files scanned (1m0s, ~1203/min, +661 since last)
...

============================================================
  SCAN COMPLETE
============================================================
Targets:    17 directories
Duration:   9m 8s
Files:      4756
Data:       2702.62 MB
Infected:   0
```

### Scan Report

After each scan, a report is saved to `/data/logs/last-scan-report.txt` containing:
- Number of targets and which directories were scanned
- Duration, file count, data scanned
- Infection count and details (if any)
- Full ClamAV summary

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Scan completed -- no threats found |
| `1` | Scan completed -- threats were detected |

---

## Managing Quarantined Files

When `QUARANTINE_ENABLED=true` (default), infected files are **copied** (not moved) to:

```
/data/quarantine/filename.extension.1708070400
```

The timestamp suffix prevents filename collisions.

### Viewing Quarantined Files

```bash
ls -la /mnt/user/appdata/maldet-scanner/quarantine/
```

### Restoring a False Positive

If a quarantined file is a false positive:

1. Verify the file is safe (check with VirusTotal, etc.)
2. Copy it back to its original location
3. Consider adding the directory to `SCAN_EXCLUDES` if it triggers repeatedly

### Cleaning Up Quarantine

Periodically remove old quarantined files:

```bash
# Remove quarantine files older than 30 days
find /mnt/user/appdata/maldet-scanner/quarantine/ -type f -mtime +30 -delete
```

> **Note:** Original infected files remain in place on the filesystem. Quarantine only creates copies for your review. If you confirm a file is malicious, manually delete the original.

---

## Real-Time File Monitoring

Monitor mode uses Linux `inotifywait` to watch for file changes and scans them immediately.

### Enabling Monitor Mode

Set `MODE=monitor` in the container settings. The container runs continuously instead of exiting after a scan.

### How It Works

1. Container starts and updates signatures
2. `inotifywait` watches all scan target directories recursively for:
   - New files (`create`)
   - Modified files (`modify`)
   - Moved/renamed files (`moved_to`)
3. Each detected file is scanned immediately with ClamAV
4. Threats trigger Telegram alerts and quarantine

### When to Use Monitor Mode

- **High-risk directories** (e.g., downloads) where new files arrive frequently
- **Web server directories** where uploaded files need immediate scanning
- **Not recommended** as a replacement for scheduled scans -- use both together

### Resource Usage

Monitor mode keeps `inotifywait` running (minimal CPU/RAM) but scans each changed file individually. For directories with heavy write activity, this can generate significant I/O.

---

## Signature Updates

### Automatic Updates

Signatures are automatically updated at the start of every scan or monitor session:

- **ClamAV** (`freshclam`): Downloads incremental updates from ClamAV mirrors (~3.6M signatures)
- **maldet**: Updates from the maldet signature server

### Manual Signature Update

Run an update without scanning:

```bash
docker run --rm \
  -v /mnt/user/appdata/maldet-scanner:/data \
  -e MODE=update \
  ghcr.io/fideld84/maldet-scanner:latest
```

### Signature Persistence

Signatures are stored in `/data/clamav/` which persists across container restarts and updates. You only download the full database once (~350 MB); subsequent updates are incremental (~1-2 MB).

### Weekly Image Rebuilds

The Docker image is automatically rebuilt every Sunday via GitHub Actions. This ensures the base Alpine packages and ClamAV binaries stay up to date. Update your container periodically via Unraid Docker UI to get the latest image.

---

## FDA Dashboard Integration

maldet-scanner integrates with the FDA Dashboard for centralized security reporting.

### How It Works

The User Script wrapper (scheduled via Unraid User Scripts) generates a JSON result file after each scan:

```json
{
  "timestamp": "2026-03-24 13:32:26",
  "startTime": "2026-03-24 13:23:18",
  "endTime": "2026-03-24 13:32:26",
  "durationSeconds": 548,
  "durationMinutes": 9,
  "target": "/mnt/user",
  "filesScanned": 4756,
  "infected": 0,
  "dataScanned": "2702.62 MB",
  "exitCode": 0,
  "status": "clean"
}
```

The FDA Dashboard reads this from `/mnt/user/appdata/maldet-scanner/logs/last-scan-result.json` and includes malware scan status in:

- **Daily AI security reports** (Telegram digest)
- **Weekly executive summaries**
- **Dashboard health overview**

### Stale Scan Warning

If no scan has run in over 8 days, the dashboard flags it as a warning.

---

## Troubleshooting

### "First run -- downloading ClamAV database" takes forever

**Cause:** Slow connection to ClamAV mirror or DNS issues.

**Fix:** Wait up to 10 minutes. If it fails, restart the container. The download resumes from where it left off.

### "freshclam failed" warning

**Cause:** ClamAV mirror temporarily unavailable or rate-limited.

**Impact:** Minimal -- the scanner falls back to existing signatures. They are still effective.

**Fix:** No action needed. The next scan will try again.

### Scan skipped -- parity check in progress

**Cause:** The User Script detected a running parity check and skipped the scan to avoid I/O contention.

**Impact:** None -- the scan will run at the next scheduled time after parity completes.

### Container exits immediately

**Cause:** In `scan` mode, the container exits after completing the scan. This is normal behavior.

**Fix:** Check `docker logs maldet-scanner` for the scan report.

### Quarantine is empty but threats were reported

**Cause:** `QUARANTINE_ENABLED` may be `false`, or the infected file was deleted before quarantine.

**Fix:** Set `QUARANTINE_ENABLED=true` in container settings.

### Permission errors on /data/clamav

**Cause:** ClamAV requires specific ownership on its database directory.

**Fix:** The entrypoint handles this automatically. If issues persist:

```bash
chown -R 100:101 /mnt/user/appdata/maldet-scanner/clamav/
```

### "Skipping non-existent" warnings

**Cause:** A default scan target directory does not exist on your system.

**Impact:** None -- the scanner skips it and continues with other targets.

**Fix:** This is normal if you do not have all the default services installed. No action needed.

---

## FAQ

**Q: Does the scanner delete infected files?**
No. When `QUARANTINE_ENABLED=true`, the scanner **copies** infected files to the quarantine directory. Original files are never modified or deleted. You must manually remove confirmed malware.

**Q: How much disk space do signatures use?**
ClamAV signatures use approximately 350-400 MB in `/data/clamav/`. This is a one-time download; updates are incremental.

**Q: Why does it only scan ~5,000 files when I have millions?**
Version 2 uses a targeted scan model. It only scans file types that can contain malware (documents, scripts, archives, executables). Media files (images, video, audio) are skipped because they cannot contain executable malware code. This reduces scan time from 9+ hours to ~9 minutes with no loss of security coverage.

**Q: Can I scan a specific directory on-demand?**
Yes. Override the scan target at runtime:

```bash
docker run --rm \
  -v /mnt/user/downloads:/scan:ro \
  -v /mnt/user/appdata/maldet-scanner:/data \
  ghcr.io/fideld84/maldet-scanner:latest
```

**Q: Will the scanner slow down my server?**
Minimal impact. The scanner uses `nice -n 19` (lowest CPU priority) and `ionice -c3` (idle I/O class -- only uses disk when nothing else needs it). With v2 targeted scans completing in ~9 minutes, the I/O window is very short.

**Q: How often should I scan?**
- **Every 6 hours** is recommended (36 min/day total scan time)
- **Daily** is the minimum for reasonable security
- **Weekly** for low-risk servers with minimal untrusted file uploads
- **Real-time monitoring** can supplement scheduled scans for specific high-risk directories

**Q: Is the scan target mounted read-only?**
Yes, by default. The container cannot modify files in the scan target. Quarantine copies are stored in `/data/quarantine/` (separate volume).

**Q: What happens if malware is found during a scan?**
1. The infected file path and threat name are logged
2. The file is copied to quarantine (if enabled)
3. A Telegram notification is sent (if enabled)
4. The scan report includes threat details
5. The container exits with code `1`
6. The original file remains in place -- you decide what to do with it

**Q: How do I update the scanner?**
The Docker image auto-rebuilds weekly. In Unraid: Docker tab > Check for Updates > Update. Your `/data/` volume (signatures, quarantine, logs) persists across updates.

**Q: What if I add a new Docker container that is internet-facing?**
Add its appdata directory to `SCAN_TARGETS` or request it be added to the default targets list in `entrypoint.sh`. Any directory under `/mnt/user/appdata/` that handles untrusted input should be scanned.
