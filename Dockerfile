FROM ghcr.io/kiwix/kiwix-tools:3.7.0

# minimal extras: bash + rsync
RUN if command -v apk >/dev/null 2>&1; then \
      apk add --no-cache bash rsync coreutils ca-certificates; \
    elif command -v apt-get >/dev/null 2>&1; then \
      apt-get update && apt-get install -y --no-install-recommends bash rsync ca-certificates && rm -rf /var/lib/apt/lists/*; \
    else \
      echo "No supported package manager found" && exit 1; \
    fi

# config + entrypoint
COPY entrypoint.sh /entrypoint.sh
COPY items.conf /items.conf
RUN chmod +x /entrypoint.sh

ENV DEST=/data/zim \
    LIBRARY=/data/library.xml \
    RSYNC_ROOT=rsync://master.download.kiwix.org/download.kiwix.org/zim \
    UPDATE_INTERVAL_HOURS=24 \
    KEEP_OLD_VERSIONS=0 \
    PORT=8080

VOLUME ["/data"]
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
