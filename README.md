# maldet-scanner

Lightweight Docker container combining **Linux Malware Detect (maldet)** and **ClamAV** for malware scanning on Unraid systems. Zero memory usage between scans -- no background daemons.

## Features

- **Targeted scan model** -- only scans high-risk directories (user files, downloads, web services), skipping media libraries entirely
- **Dual-engine scanning** -- ClamAV signatures (3.6M+) + maldet heuristics
- **Three operation modes** -- full scan, real-time file monitor, signature update only
- **Media-aware** -- automatically skips image/video/audio files (JPEG, MOV, MP4, HEIC, etc.) that are not malware vectors
- **Fast** -- typical full scan completes in **~9 minutes** scanning ~5,000 high-risk files
- **Lightweight** -- no clamd daemon; loads scanner only when needed, exits when done
- **Resource-friendly** -- `nice -n 19`, `ionice -c3` (idle I/O class)
- **Anchored regex excludes** -- directory patterns use anchored regex to prevent false matches
- **Telegram notifications** -- scan results with threat details
- **Auto-quarantine** -- infected files copied to quarantine directory
- **Real-time progress** -- periodic status updates in Docker logs
- **Auto-updated signatures** -- ClamAV + maldet databases updated before every scan
- **Weekly image rebuilds** -- GitHub Actions rebuilds every Sunday for latest Alpine/ClamAV packages
- **FDA Dashboard integration** -- scan results reported in daily/weekly AI security reports
- **CI/CD pipeline** -- ShellCheck linting + Trivy vulnerability scanning on every push

## Quick Start

### Unraid (Community Applications)

1. Add the container template URL in Unraid Docker:
   ```
   https://raw.githubusercontent.com/fideld84/maldet-scanner/main/unraid-template.xml
   ```
2. Configure Telegram alerts and any custom scan targets
3. Click **Apply** -- the container runs a scan and exits

### Docker CLI

```bash
docker run --rm \
  -v /mnt/user:/scan:ro \
  -v /mnt/user/appdata/maldet-scanner:/data \
  -e MODE=scan \
  -e TELEGRAM_ENABLED=true \
  -e TELEGRAM_BOT_TOKEN=your_token \
  -e TELEGRAM_CHAT_ID=your_chat_id \
  --cpuset-cpus="0,1,8,9" \
  ghcr.io/fideld84/maldet-scanner:latest
```

### Docker Compose

```yaml
services:
  maldet-scanner:
    image: ghcr.io/fideld84/maldet-scanner:latest
    container_name: maldet-scanner
    volumes:
      - /mnt/user:/scan:ro
      - /mnt/user/appdata/maldet-scanner:/data
    environment:
      - MODE=scan
      - TZ=America/Los_Angeles
      - TELEGRAM_ENABLED=false
      - QUARANTINE_ENABLED=true
      - PROGRESS_INTERVAL=30
    cpuset: "0,1,8,9"
```

## How It Works -- Targeted Scan Model (v2)

Instead of scanning everything and excluding directories, v2 uses an **include-only model**: only specific high-risk directories are scanned. Everything else is ignored.

### Default Scan Targets

| Target | Why It Is Scanned |
|--------|-----------------|
| `/scan/nextcloud` | User-uploaded files from all Nextcloud accounts |
| `/scan/Download` | Internet downloads -- highest risk |
| `/scan/Share` | Shared files between users |
| `/scan/VSC_Projects` | Dev repos -- scripts, configs |
| `/scan/scripts` | User shell scripts |
| `/scan/appdata/swag` | Reverse proxy configs (internet-facing) |
| `/scan/appdata/authentik` | Auth service (internet-facing) |
| `/scan/appdata/n8n` | Automation workflows |
| `/scan/appdata/code-server` | Web IDE (internet-facing) |
| `/scan/appdata/bitwarden` | Password manager data |
| `/scan/appdata/cloudflared` | Tunnel configs |
| `/scan/appdata/fda-chronicle` | AI photo companion |
| `/scan/appdata/fda-dashboard` | Server dashboard |
| `/scan/appdata/fda-homepage` | Homepage app |
| `/scan/appdata/trip-planner` | Trip planner app |
| `/scan/appdata/auth-manager` | Auth management |
| `/scan/appdata/open-webui` | LLM web interface |

Override with the `SCAN_TARGETS` env var (pipe-separated paths relative to `/scan`).

### What Gets Excluded Within Targets

**Directory excludes** (anchored regex -- no false matches):
- `node_modules`, `.git`, `__pycache__`, `.next`, `.vite`, `dist`, `.cache`
- Nextcloud internal dirs: `appdata_oc*`, `updater-oc*`, `files_external`, `files_trashbin`, `files_versions`, `cache`

**File type excludes** (media files that are not malware vectors):
- Images: `.jpg`, `.jpeg`, `.heic`, `.png`, `.gif`, `.bmp`, `.tiff`, `.webp`, `.svg`, `.ico`, `.raw`, `.cr2`, `.nef`, `.arw`, `.dng`
- Video: `.mov`, `.mp4`, `.avi`, `.mkv`, `.wmv`, `.flv`, `.webm`, `.m4v`, `.3gp`
- Audio: `.mp3`, `.wav`, `.flac`, `.aac`, `.ogg`, `.m4a`, `.wma`, `.aiff`
- 3D/CAD: `.stl`, `.3mf`, `.obj`, `.gcode`, `.prt`
- Also handles Nextcloud trash naming (e.g., `photo.heic.d1602379038`)

### What Actually Gets Scanned

After filtering, ClamAV deep-scans only files that can contain malware:
- **Documents**: PDF, DOC/DOCX, XLS/XLSX, PPT
- **Archives**: ZIP, RAR, 7Z, TAR.GZ
- **Scripts**: JS, PY, SH, PHP, HTML, CSS
- **Executables**: EXE, DLL, BAT, MSI
- **Code/Config**: JSON, YAML, XML, TOML, SQL
- **Databases**: SQLite, DB files

## Operation Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `scan` | Full targeted scan, then exit | Scheduled scans (every 6 hours) |
| `monitor` | Watch files via inotify, scan on change | Continuous real-time protection |
| `update` | Update ClamAV + maldet signatures, then exit | Keep signatures fresh between scans |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MODE` | `scan` | Operation mode: `scan`, `monitor`, or `update` |
| `SCAN_PATH` | `/scan` | Directory to scan (mount target) |
| `SCAN_TARGETS` | *(empty)* | Override default scan targets (pipe-separated paths) |
| `SCAN_EXCLUDES` | *(empty)* | Additional directory excludes (pipe-separated, added to built-in list) |
| `QUARANTINE_ENABLED` | `true` | Copy infected files to `/data/quarantine/` |
| `TELEGRAM_ENABLED` | `false` | Enable Telegram scan result notifications |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat or group ID |
| `PROGRESS_INTERVAL` | `30` | Seconds between progress updates in logs |
| `TZ` | `America/Los_Angeles` | Container timezone |

### Volumes

| Container Path | Purpose | Mode |
|---------------|---------|------|
| `/scan` | Root mount point for scan targets | `ro` (read-only) |
| `/data` | Persistent storage (signatures, quarantine, logs) | `rw` |

### Persistent Data (`/data/`)

```
/data/
  clamav/          # ClamAV signature database (~350 MB)
  quarantine/      # Quarantined infected files (timestamped copies)
  logs/
    last-scan-report.txt   # Most recent scan report
```

## Scan Parameters

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `--max-filesize` | 100 MB | Skip files larger than this |
| `--max-scansize` | 400 MB | Max extracted content per file |
| `--max-recursion` | 16 | Nested archive depth |
| `--max-dir-recursion` | 30 | Directory nesting depth |
| `nice -n 19` | Lowest CPU priority | Will not impact running services |
| `ionice -c3` | Idle I/O class | Only uses disk when idle |

## Scheduling

maldet-scanner runs on-demand and exits. Schedule it for periodic scans.

### Recommended: Every 6 Hours

With ~9-minute scans, running every 6 hours provides same-day threat detection with only **36 minutes of total scan time per day**.

### Unraid User Scripts

Create a User Script:

```bash
#!/bin/bash
docker start maldet-scanner
```

Cron expression: `0 */6 * * *` (every 6 hours at :00)

### Alternative Schedules

| Schedule | Cron | Total Daily Scan Time |
|----------|------|-----------------------|
| Every 6 hours | `0 */6 * * *` | ~36 min |
| Every 12 hours | `0 */12 * * *` | ~18 min |
| Daily at 3 AM | `0 3 * * *` | ~9 min |
| Weekly Monday 2 AM | `0 2 * * 1` | ~1.3 min/day avg |

## Telegram Notifications

When `TELEGRAM_ENABLED=true`, you receive messages like:

**Clean scan:**
> **OK Malware Scan Complete**
> **Targets:** 17 directories
> **Duration:** 9m 8s
> **Files scanned:** 4,756
> **Data scanned:** 2,702.62 MB
> **Result:** Clean

**Threats found:**
> **ALERT Malware Scan Complete**
> **Targets:** 17 directories
> **Duration:** 9m 15s
> **Files scanned:** 4,756
> **Result:** 2 THREATS FOUND
> ```
> /scan/appdata/downloads/suspicious.php: Win.Trojan.Agent FOUND
> /scan/appdata/www/shell.php: PHP.Webshell FOUND
> ```

## CI/CD

The Docker image is built automatically via GitHub Actions:

- **ShellCheck linting** -- enforces shell script quality (severity: warning)
- **Docker build** -- multi-stage with BuildKit caching
- **Trivy vulnerability scan** -- checks for CRITICAL/HIGH CVEs in the image
- **GHCR push** -- published to `ghcr.io/fideld84/maldet-scanner`
- **Weekly rebuilds** -- Sundays at 6 AM UTC for latest Alpine/ClamAV packages
- **Dependabot** -- auto-updates GitHub Actions dependencies

## Building Locally

```bash
git clone https://github.com/fideld84/maldet-scanner.git
cd maldet-scanner
docker build -t maldet-scanner .
docker run --rm -v /path/to/scan:/scan:ro -v /tmp/maldet-data:/data maldet-scanner
```

## Architecture

```
+---------------------------------------------+
|  maldet-scanner container (Alpine 3.21)     |
|                                             |
|  entrypoint.sh (v2 -- targeted scan model)  |
|    +-- update_signatures()                  |
|    |     +-- freshclam (ClamAV DB)          |
|    |     +-- maldet --update                |
|    +-- run_scan()                           |
|    |     +-- build_scan_targets()           |
|    |     |     +-- 17 default dirs or       |
|    |     |         SCAN_TARGETS override    |
|    |     +-- build_excludes()               |
|    |     |     +-- anchored dir regex       |
|    |     |     +-- media file skip regex    |
|    |     |     +-- user SCAN_EXCLUDES       |
|    |     +-- progress_monitor() [background]|
|    |     +-- clamscan (nice/ionice)         |
|    |     +-- parse results + report         |
|    |     +-- quarantine threats             |
|    |     +-- send_telegram()                |
|    +-- run_monitor()                        |
|    |     +-- inotifywait (file watcher)     |
|    |     +-- clamscan per file              |
|    |     +-- send_telegram() on threat      |
|    +-- run_update()                         |
|          +-- update_signatures()            |
|                                             |
|  Volumes:                                   |
|    /scan  <- Host filesystem (read-only)    |
|    /data  <- Persistent (sigs, quarantine)  |
+---------------------------------------------+
```

## Performance

| Metric | v1 (exclude model) | v2 (include model) |
|--------|--------------------|--------------------|
| Scan time | 9+ hours | ~9 minutes |
| Files traversed | 200,000+ | ~16,000 |
| Files deep-scanned | 25,000+ | ~5,000 |
| Media files scanned | All (wasted) | Skipped |
| I/O impact | Heavy | Minimal |

## License

This project uses:
- [Linux Malware Detect](https://github.com/rfxn/linux-malware-detect) (GPLv2)
- [ClamAV](https://www.clamav.net/) (GPLv2)
