FROM ghcr.io/kiwix/kiwix-tools:3.7.0 AS kiwix_base
FROM kiwix_base

# Use a consistent, safer shell for build steps
SHELL ["/bin/sh", "-eux", "-c"]

# Install runtime dependencies - no user creation yet, we'll do that dynamically
RUN if command -v apk >/dev/null 2>&1; then \
      apk add --no-cache bash coreutils curl ca-certificates shadow; \
    elif command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      apt-get update; \
      apt-get install -y --no-install-recommends bash curl ca-certificates; \
      rm -rf /var/lib/apt/lists/*; \
    else \
      echo "No supported package manager found" >&2; exit 1; \
    fi && \
    # Make sure CA bundle is registered if the base supports it (no-op otherwise)
    (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true)

# Create the app directory structure - ownership will be set dynamically
RUN mkdir -p /home/app/data /home/app/data/zim && \
    chmod -R 777 /home/app

# Copy the init script with proper permissions
COPY --chmod=0755 init.sh /init.sh

ENV APP_UMASK=027

# Don't set a specific user - let the init script handle it dynamically

# Set home directory as working directory
WORKDIR /home/app

# Prepare writable mount and own it
VOLUME ["/home/app/data"]

# App config
ENV DEST=/home/app/data/zim \
    LIBRARY=/home/app/data/library.xml \
    HTTP_BASE=https://download.kiwix.org/zim \
    UPDATE_INTERVAL_HOURS=24 \
    KEEP_OLD_VERSIONS=0 \
    ITEM_DELAY_SECONDS=5 \
    ITEMS_PATH=/home/app/data/items.conf \
    PORT=8080 \
    HOME=/home/app

# Copy entrypoint with tight permissions and correct ownership
# (Use --chmod/--chown so we don’t need an extra layer to chmod/chown)
COPY --chmod=0755 entrypoint.sh /entrypoint.sh

EXPOSE 8080/tcp

HEALTHCHECK --interval=30s --timeout=10s --retries=3 --start-period=60s \
  CMD sh -c 'curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null && \
             [ -f /home/app/data/library.xml ] && \
             [ "$(find /home/app/data/zim -name "*.zim" | wc -l)" -gt 0 ] || exit 1'
  
ENTRYPOINT ["/init.sh", "/entrypoint.sh"]