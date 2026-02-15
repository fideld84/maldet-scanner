# maldet-scanner

Lightweight Docker container combining **Linux Malware Detect (maldet)** and **ClamAV** for malware scanning on Unraid systems. Zero memory usage between scans — no background daemons.

## Features

- **Dual-engine scanning** — ClamAV signatures + maldet heuristics
- **Three operation modes** — full scan, real-time file monitor, signature update only
- **Lightweight** — no clamd daemon; loads scanner only when needed, exits when done
- **Resource-friendly** — CPU pinning, `nice -n 19`, `ionice -c3` (idle class)
- **Telegram notifications** — scan results with threat details
- **Auto-quarantine** — infected files copied to quarantine directory
- **Real-time progress** — periodic status updates in Docker logs
- **Smart exclusions** — skip media libraries, databases, and other non-threat directories
- **Auto-updated signatures** — ClamAV + maldet databases updated before every scan
- **Weekly image rebuilds** — GitHub Actions rebuilds every Sunday for latest Alpine/ClamAV packages
- **FDA Dashboard integration** — scan results reported in daily/weekly AI security reports

## Quick Start

### Unraid (Community Applications)

1. Add the container template URL in Unraid Docker:
   ```
   https://raw.githubusercontent.com/fideld84/maldet-scanner/main/unraid-template.xml
   ```
2. Configure scan target, Telegram alerts, and exclusions
3. Click **Apply** — the container runs a scan and exits

### Docker CLI

```bash
docker run --rm \
  -v /mnt/user:/scan:ro \
  -v /mnt/user/appdata/maldet-scanner:/data \
  -e MODE=scan \
  -e TELEGRAM_ENABLED=true \
  -e TELEGRAM_BOT_TOKEN=your_token \
  -e TELEGRAM_CHAT_ID=your_chat_id \
  -e SCAN_EXCLUDES="/scan/Media|/scan/isos|/scan/Backups" \
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
      - SCAN_EXCLUDES=/scan/Media|/scan/isos|/scan/Backups
      - PROGRESS_INTERVAL=30
    cpuset: "0,1,8,9"
```

## Operation Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| `scan` | Full recursive scan, then exit | Scheduled weekly/daily scans |
| `monitor` | Watch files via inotify, scan on change | Continuous real-time protection |
| `update` | Update ClamAV + maldet signatures, then exit | Keep signatures fresh between scans |

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MODE` | `scan` | Operation mode: `scan`, `monitor`, or `update` |
| `SCAN_PATH` | `/scan` | Directory to scan (mount target) |
| `QUARANTINE_ENABLED` | `true` | Copy infected files to `/data/quarantine/` |
| `SCAN_EXCLUDES` | *(empty)* | Pipe-separated paths to exclude (e.g. `/scan/Media\|/scan/isos`) |
| `TELEGRAM_ENABLED` | `false` | Enable Telegram scan result notifications |
| `TELEGRAM_BOT_TOKEN` | *(empty)* | Bot token from [@BotFather](https://t.me/BotFather) |
| `TELEGRAM_CHAT_ID` | *(empty)* | Telegram chat or group ID |
| `PROGRESS_INTERVAL` | `30` | Seconds between progress updates in logs |
| `TZ` | `America/Los_Angeles` | Container timezone |

### Volumes

| Container Path | Purpose | Mode |
|---------------|---------|------|
| `/scan` | Directory to scan | `ro` (read-only recommended) |
| `/data` | Persistent storage (signatures, quarantine, logs) | `rw` |

### Persistent Data (`/data/`)

```
/data/
  clamav/          # ClamAV signature database (main.cvd, daily.cld, etc.)
  quarantine/      # Quarantined infected files (timestamped copies)
  logs/            # Scan reports
    last-scan-report.txt   # Most recent scan report
```

## Default Exclusions

These directories are always excluded (hardcoded):
- `PlexMediaServer`, `Plex-Media-Server`, `jellyfin`, `maldet-scanner`, `clamav`

Recommended user exclusions for Unraid (set via `SCAN_EXCLUDES`):
```
/scan/Media|/scan/isos|/scan/NVR|/scan/roms|/scan/Backups|/scan/domains|/scan/system
```

## Scan Parameters

ClamAV runs with these limits:

| Parameter | Value | Purpose |
|-----------|-------|---------|
| `--max-filesize` | 100 MB | Skip files larger than this |
| `--max-scansize` | 400 MB | Max extracted content per file |
| `--max-recursion` | 16 | Nested archive depth |
| `--max-dir-recursion` | 30 | Directory nesting depth |
| `nice -n 19` | Lowest CPU priority | Won't impact running services |
| `ionice -c3` | Idle I/O class | Only uses disk when idle |

## Scheduling

maldet-scanner is designed to run on-demand. Schedule it using:

### Unraid User Scripts (Recommended)

Create a User Script with a cron schedule:

```bash
#!/bin/bash
# Weekly malware scan — Monday 2 AM
docker start maldet-scanner
```

Cron expression: `0 2 * * 1`

### Crontab

```cron
# Weekly scan Monday 2 AM
0 2 * * 1 docker start maldet-scanner
```

## Telegram Notifications

When `TELEGRAM_ENABLED=true`, you'll receive messages like:

**Clean scan:**
> **✅ Malware Scan Complete**
> **Target:** /scan
> **Duration:** 42m 15s
> **Files scanned:** 15,234
> **Result:** Clean

**Threats found:**
> **🚨 Malware Scan Complete**
> **Target:** /scan
> **Duration:** 42m 15s
> **Files scanned:** 15,234
> **Result:** 2 THREATS FOUND
> ```
> /scan/appdata/downloads/suspicious.php: Win.Trojan.Agent FOUND
> /scan/appdata/www/shell.php: PHP.Webshell FOUND
> ```

## CI/CD

The Docker image is built automatically via GitHub Actions:

- **On push** to `main` branch or version tags (`v*`)
- **Weekly** on Sundays at 6 AM UTC (picks up Alpine + ClamAV package updates)
- **Manual** trigger via GitHub Actions UI

Images are published to `ghcr.io/fideld84/maldet-scanner`.

## Building Locally

```bash
git clone https://github.com/fideld84/maldet-scanner.git
cd maldet-scanner
docker build -t maldet-scanner .
docker run --rm -v /path/to/scan:/scan:ro -v /tmp/maldet-data:/data maldet-scanner
```

## Architecture

```
┌─────────────────────────────────────────────┐
│  maldet-scanner container (Alpine 3.21)     │
│                                             │
│  entrypoint.sh                              │
│    ├── update_signatures()                  │
│    │     ├── freshclam (ClamAV DB)          │
│    │     └── maldet --update                │
│    ├── run_scan()                           │
│    │     ├── build_excludes()               │
│    │     ├── progress_monitor() [background]│
│    │     ├── clamscan (nice/ionice)         │
│    │     ├── parse results                  │
│    │     ├── quarantine threats             │
│    │     └── send_telegram()                │
│    ├── run_monitor()                        │
│    │     ├── inotifywait (file watcher)     │
│    │     ├── clamscan per file              │
│    │     └── send_telegram() on threat      │
│    └── run_update()                         │
│          └── update_signatures()            │
│                                             │
│  Volumes:                                   │
│    /scan  ← Host filesystem (read-only)     │
│    /data  ← Persistent (sigs, quarantine)   │
└─────────────────────────────────────────────┘
```

## License

This project uses:
- [Linux Malware Detect](https://github.com/rfxn/linux-malware-detect) (GPLv2)
- [ClamAV](https://www.clamav.net/) (GPLv2)
