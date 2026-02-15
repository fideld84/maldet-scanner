# maldet-scanner User Guide

Complete guide for setting up, running, and managing the maldet-scanner container on Unraid.

---

## Table of Contents

1. [Installation](#installation)
2. [First Run](#first-run)
3. [Configuring Scan Targets](#configuring-scan-targets)
4. [Setting Up Telegram Alerts](#setting-up-telegram-alerts)
5. [Scheduling Scans](#scheduling-scans)
6. [Understanding Scan Results](#understanding-scan-results)
7. [Managing Quarantined Files](#managing-quarantined-files)
8. [Real-Time File Monitoring](#real-time-file-monitoring)
9. [Signature Updates](#signature-updates)
10. [Tuning Exclusions](#tuning-exclusions)
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
5. Configure the settings (see below) and click **Apply** to create the container

### Option B: Manual Docker Setup

Pull the image and create the container manually:

```bash
docker pull ghcr.io/fideld84/maldet-scanner:latest
```

Then run with your preferred configuration (see [Quick Start](../README.md#quick-start) in README).

---

## First Run

On the very first run, the container needs to download the full ClamAV signature database. This is a one-time download of approximately **300-400 MB** and takes **2-5 minutes** depending on your connection.

**What happens during first run:**

1. Directories are created (`/data/clamav`, `/data/quarantine`, `/data/logs`)
2. ClamAV signatures are downloaded (main.cvd + daily.cld)
3. maldet signatures are updated
4. The scan begins

**Expected Docker log output on first run:**

```
[14:30:00] Updating ClamAV signatures...
[14:30:00] First run — downloading ClamAV database (this takes a few minutes)...
[14:33:45] ClamAV signatures updated.
[14:33:45] Updating maldet signatures...
[14:33:47] maldet signatures updated.
[14:33:47] Starting scan of /scan...
```

Subsequent runs reuse the cached signatures and only download incremental updates (~1-2 MB), which takes seconds.

---

## Configuring Scan Targets

### What to Scan

The container mounts a host directory to `/scan` inside the container. Configure what to scan:

| Scan Target | Host Path | Scope | Typical Duration |
|-------------|-----------|-------|------------------|
| Entire user share | `/mnt/user` | Everything (with exclusions) | 30-90 min |
| Appdata only | `/mnt/user/appdata` | Application configs | 10-30 min |
| Specific share | `/mnt/user/downloads` | Downloads only | 5-15 min |

**Recommendation:** Scan `/mnt/user` with smart exclusions. This covers appdata, downloads, and all user-accessible files while skipping large media libraries.

### Setting the Scan Target in Unraid

1. Go to Docker > maldet-scanner > Edit
2. Under **Scan Target**, set the host path (e.g., `/mnt/user`)
3. This maps to `/scan` inside the container

> **Important:** The scan target is mounted **read-only** (`ro`). The scanner cannot modify or delete your files — it only reads them. Quarantine creates copies, not moves.

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
3. Find `"chat":{"id":123456789}` in the response — that number is your chat ID

### Step 3: Configure the Container

Set these environment variables in Unraid:

| Variable | Value |
|----------|-------|
| `TELEGRAM_ENABLED` | `true` |
| `TELEGRAM_BOT_TOKEN` | Your bot token |
| `TELEGRAM_CHAT_ID` | Your chat ID |

### What You'll Receive

- **After every scan:** Summary with file count, duration, and result (clean or threat details)
- **Monitor mode:** Instant alert when malware is detected in a new/modified file
- **Threats include:** File path and threat name (first 10 listed)

---

## Scheduling Scans

The container in `scan` mode runs once and exits. To run periodic scans, use a scheduler.

### Using Unraid User Scripts Plugin

1. Install **User Scripts** from Community Applications (if not already installed)
2. Go to **Settings > User Scripts**
3. Click **Add New Script**, name it `malware-scan`
4. Click the script name, then **Edit Script**:

```bash
#!/bin/bash
# Start the maldet-scanner container for a full scan
docker start maldet-scanner
```

5. Set the schedule:

| Schedule | Cron Expression | Description |
|----------|----------------|-------------|
| Weekly Monday 2 AM | `0 2 * * 1` | Recommended for most users |
| Daily 3 AM | `0 3 * * *` | For security-sensitive environments |
| Bi-weekly Sunday 1 AM | `0 1 * * 0/2` | Low-frequency alternative |

### Manual Scan

Start a scan anytime from the Unraid Docker UI by clicking the **Start** button, or via CLI:

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
  maldet + ClamAV Scanner
  Target: /scan
  Started: 2026-02-16 02:00:00
============================================================

[02:00:05] Updating ClamAV signatures...
[02:00:12] ClamAV signatures updated.
[02:00:12] Starting scan of /scan...
[02:00:42] Progress: 1,245 files scanned (0m30s, ~2490/min, +1245 since last)
[02:01:12] Progress: 3,891 files scanned (1m0s, ~3891/min, +2646 since last)
...
============================================================
  SCAN COMPLETE
============================================================
Target:     /scan
Duration:   42m 15s
Files:      15,234
Data:       8.2 GB
Infected:   0
```

### Progress Updates

Every 30 seconds (configurable via `PROGRESS_INTERVAL`), you'll see:

```
[02:05:42] Progress: 8,432 files scanned (5m30s, ~1533/min, +1105 since last)
```

If threats are found during the scan, the progress line includes a threat count:

```
[02:10:12] Progress: 12,100 files scanned (10m0s, ~1210/min, +980 since last) | THREATS: 2
```

### Scan Report

After each scan, a report is saved to `/data/logs/last-scan-report.txt`:

```
============================================================
  SCAN REPORT — 2026-02-16 02:42:15
============================================================

Target:     /scan
Duration:   42m 15s
Files:      15,234
Data:       8.2 GB
Infected:   0
```

If threats are found, the report includes file paths and threat names.

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Scan completed — no threats found |
| `1` | Scan completed — threats were detected |

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
2. Copy it back to its original location:
   ```bash
   cp /mnt/user/appdata/maldet-scanner/quarantine/filename.ext.1708070400 /original/path/filename.ext
   ```
3. Consider adding the directory to `SCAN_EXCLUDES` if it triggers repeatedly

### Cleaning Up Quarantine

Periodically remove old quarantined files:

```bash
# Remove quarantine files older than 30 days
find /mnt/user/appdata/maldet-scanner/quarantine/ -type f -mtime +30 -delete
```

> **Note:** The original infected files remain in place on the filesystem. Quarantine only creates copies for your review. If you confirm a file is malicious, manually delete the original.

---

## Real-Time File Monitoring

Monitor mode uses Linux `inotifywait` to watch for file changes and scans them immediately.

### Enabling Monitor Mode

Set `MODE=monitor` in the container settings. The container runs continuously instead of exiting after a scan.

### How It Works

1. Container starts and updates signatures
2. `inotifywait` watches `/scan` recursively for:
   - New files (`create`)
   - Modified files (`modify`)
   - Moved/renamed files (`moved_to`)
3. Each detected file is scanned immediately with ClamAV
4. Threats trigger Telegram alerts and quarantine

### When to Use Monitor Mode

- **High-risk directories** (e.g., `/mnt/user/downloads`) where new files arrive frequently
- **Web server directories** where uploaded files need immediate scanning
- **Not recommended** for the entire `/mnt/user` — generates too many events

### Resource Usage

Monitor mode keeps `inotifywait` running (minimal CPU/RAM) but scans each changed file individually. For directories with heavy write activity, this can generate significant I/O.

---

## Signature Updates

### Automatic Updates

Signatures are automatically updated at the start of every scan or monitor session:

- **ClamAV** (`freshclam`): Downloads incremental updates from ClamAV mirrors
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

## Tuning Exclusions

### Why Exclude?

Scanning large media files (movies, music, ISOs) wastes time since malware doesn't hide in MP4/MKV files. Excluding these directories dramatically reduces scan time.

### Default Exclusions (Always Applied)

These container names/directories are always excluded:
- `PlexMediaServer`, `Plex-Media-Server` — Plex database/metadata
- `jellyfin` — Jellyfin media server data
- `maldet-scanner` — Scanner's own data directory
- `clamav` — ClamAV database files

### User Exclusions

Set `SCAN_EXCLUDES` with pipe-separated paths:

```
/scan/Media|/scan/isos|/scan/NVR|/scan/roms|/scan/Backups
```

### Recommended Exclusions for Unraid

```
/scan/Media|/scan/isos|/scan/NVR|/scan/roms|/scan/Backups|/scan/domains|/scan/system|/scan/appdata/binhex-krusader|/scan/appdata/docker|/scan/nextcloud/appdata_ocfczqns5ien/preview
```

**Why these?**
- `Media`, `isos`, `NVR`, `roms` — Large media files, not malware targets
- `Backups` — Backup archives (scan originals instead)
- `domains` — Domain data not relevant
- `system` — Unraid system files
- `binhex-krusader` — File manager cache
- `docker` — Docker overlay data
- `nextcloud/.../preview` — Thumbnail cache (thousands of small files)

### Finding What to Exclude

Run a scan and check which directories take the longest:

```bash
docker logs maldet-scanner 2>&1 | grep "Progress"
```

If a directory contains only media or known-safe binary data, add it to exclusions.

---

## FDA Dashboard Integration

maldet-scanner integrates with the [FDA Dashboard](https://github.com/fideld84/fda-dashboard) for centralized security reporting.

### How It Works

The FDA Dashboard reads the scan report from the shared filesystem and includes malware scan status in:

- **Daily AI security reports** (Telegram digest)
- **Weekly executive summaries** (Monday 8 AM)
- **Dashboard health overview**

### Report Format

The scan report at `/data/logs/last-scan-report.txt` is parsed by the FDA Dashboard. The dashboard shows:

```
Malware Scan: ✅ Last scan 2026-02-16 — 15,234 files, clean (42m)
```

Or if threats were found:

```
Malware Scan: 🚨 Last scan 2026-02-16 — 2 threats detected!
```

### Stale Scan Warning

If no scan has run in over 8 days, the dashboard flags it:

```
Malware Scan: ⚠️ Last scan 9 days ago — schedule a scan
```

---

## Troubleshooting

### "First run — downloading ClamAV database" takes forever

**Cause:** Slow connection to ClamAV mirror or DNS issues.

**Fix:** Wait up to 10 minutes. If it fails, restart the container. The download resumes from where it left off. Alternatively, check DNS resolution inside the container:

```bash
docker exec maldet-scanner nslookup database.clamav.net
```

### "freshclam failed" warning

**Cause:** ClamAV mirror temporarily unavailable or rate-limited.

**Impact:** Minimal — the scanner falls back to existing signatures. They're still effective.

**Fix:** No action needed. The next scan will try again. If persistent, check your network/DNS.

### Scan takes too long

**Cause:** Scanning too many files, especially large directories.

**Fix:**
1. Add large media directories to `SCAN_EXCLUDES`
2. Reduce scan scope (e.g., `/mnt/user/appdata` instead of `/mnt/user`)
3. Increase CPU pinning (add more cores to `CPUset`)

### Container exits immediately

**Cause:** In `scan` mode, the container exits after completing the scan. This is normal.

**Fix:** This is expected behavior. Check `docker logs maldet-scanner` for the scan report.

### Quarantine is empty but threats were reported

**Cause:** `QUARANTINE_ENABLED` may be `false`, or the infected file was deleted before quarantine.

**Fix:** Set `QUARANTINE_ENABLED=true` in container settings.

### Permission errors on /data/clamav

**Cause:** ClamAV requires specific ownership on its database directory.

**Fix:** The entrypoint handles this automatically. If issues persist:

```bash
chown -R 100:101 /mnt/user/appdata/maldet-scanner/clamav/
```

---

## FAQ

**Q: Does the scanner delete infected files?**
No. When `QUARANTINE_ENABLED=true`, the scanner **copies** infected files to the quarantine directory. Original files are never modified or deleted. You must manually remove confirmed malware.

**Q: How much disk space do signatures use?**
ClamAV signatures use approximately 350-400 MB in `/data/clamav/`. This is a one-time download; updates are incremental.

**Q: Can I scan a specific directory on-demand?**
Yes. Override the scan target at runtime:

```bash
docker run --rm \
  -v /mnt/user/downloads:/scan:ro \
  -v /mnt/user/appdata/maldet-scanner:/data \
  ghcr.io/fideld84/maldet-scanner:latest
```

**Q: Will the scanner slow down my server?**
Minimal impact. The scanner uses:
- `nice -n 19` (lowest CPU priority)
- `ionice -c3` (idle I/O class — only uses disk when nothing else needs it)
- CPU pinning to specific cores

Other services are prioritized over the scanner automatically.

**Q: How often should I scan?**
- **Weekly** is recommended for most home servers
- **Daily** for servers handling untrusted uploads or downloads
- **Real-time monitoring** for specific high-risk directories

**Q: Is the scan target mounted read-only?**
Yes, by default. The container cannot modify files in the scan target. Quarantine copies are stored in `/data/quarantine/` (separate volume).

**Q: What happens if malware is found during a scan?**
1. The infected file path and threat name are logged
2. The file is copied to quarantine (if enabled)
3. A Telegram notification is sent (if enabled)
4. The scan report includes threat details
5. The container exits with code `1`
6. The original file remains in place — you decide what to do with it

**Q: How do I update the scanner?**
The Docker image auto-rebuilds weekly. In Unraid: Docker tab > Check for Updates > Update. Your `/data/` volume (signatures, quarantine, logs) persists across updates.
