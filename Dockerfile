FROM alpine:3.21

LABEL maintainer="fideld84"
LABEL org.opencontainers.image.source="https://github.com/fideld84/maldet-scanner"
LABEL org.opencontainers.image.description="Maldet + ClamAV scanner for Unraid"

# Install dependencies
RUN apk add --no-cache \
    bash \
    clamav \
    clamav-libunrar \
    curl \
    inotify-tools \
    perl \
    wget \
    ca-certificates \
    tzdata

# Install maldet
ARG MALDET_VERSION=1.6.6.1
RUN wget -q "https://github.com/rfxn/linux-malware-detect/archive/refs/tags/${MALDET_VERSION}.tar.gz" -O /tmp/maldet.tar.gz \
    && cd /tmp \
    && tar xzf maldet.tar.gz \
    && cd "linux-malware-detect-${MALDET_VERSION}" \
    && bash install.sh \
    && rm -rf /tmp/maldet.tar.gz /tmp/linux-malware-detect-*

# Create persistent directories
RUN mkdir -p /data/clamav /data/quarantine /data/logs /scan

# Configure freshclam for persistent DB directory (run as root, no privilege drop)
RUN printf '%s\n' \
    "DatabaseDirectory /data/clamav" \
    "DatabaseMirror database.clamav.net" \
    "MaxAttempts 3" \
    "ScriptedUpdates yes" \
    "DatabaseOwner root" \
    "NotifyClamd no" \
    > /etc/clamav/freshclam.conf

# Configure maldet defaults
RUN sed -i 's|^quarantine_hits=.*|quarantine_hits="1"|' /usr/local/maldetect/conf.maldet \
    && sed -i 's|^quarantine_clean=.*|quarantine_clean="0"|' /usr/local/maldetect/conf.maldet \
    && sed -i 's|^scan_clamscan=.*|scan_clamscan="1"|' /usr/local/maldetect/conf.maldet \
    && sed -i 's|^scan_cpunice=.*|scan_cpunice="19"|' /usr/local/maldetect/conf.maldet \
    && sed -i 's|^scan_ionice=.*|scan_ionice="7"|' /usr/local/maldetect/conf.maldet

# Copy entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

VOLUME ["/scan", "/data"]

ENV TZ=America/Los_Angeles \
    SCAN_PATH=/scan \
    TELEGRAM_ENABLED=false \
    TELEGRAM_BOT_TOKEN="" \
    TELEGRAM_CHAT_ID="" \
    QUARANTINE_ENABLED=true \
    SCAN_EXCLUDES="" \
    MODE=scan

ENTRYPOINT ["/entrypoint.sh"]
