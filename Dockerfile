FROM ghcr.io/kiwix/kiwix-tools:3.7.0 AS kiwix_base
FROM kiwix_base

# Use a consistent, safer shell for build steps
SHELL ["/bin/sh", "-eux", "-c"]

# Minimal runtime deps + non-root user creation for both Alpine and Debian/Ubuntu
# - Installs: bash (for your script if it uses bashisms), curl (healthcheck), ca-certs
# - Creates dedicated kiwix user/group with a stable UID/GID that won't collide with system users
# - Cleans up package lists
RUN if command -v apk >/dev/null 2>&1; then \
      addgroup -g 10001 -S kiwix && adduser -S -D -H -u 10001 -G kiwix kiwix; \
      apk add --no-cache bash coreutils curl ca-certificates; \
    elif command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      groupadd --gid 10001 kiwix || true; \
      useradd --uid 10001 --gid 10001 --create-home --home-dir /data --shell /usr/sbin/nologin kiwix; \
      apt-get update; \
      apt-get install -y --no-install-recommends bash curl ca-certificates; \
      rm -rf /var/lib/apt/lists/*; \
    else \
      echo "No supported package manager found" >&2; exit 1; \
    fi && \
    # Make sure CA bundle is registered if the base supports it (no-op otherwise)
    (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true)

# Ensure /data exists, is owned by the runtime user, and is SGID + group-writable
# SGID (2) on dirs ⇒ new files/dirs inherit the group (10001)
RUN mkdir -p /data /data/zim && \
    chown -R 10001:10001 /data && \
    chmod -R 2770 /data

# Create a permission-fixing init script for hardened environments
RUN printf '#!/bin/sh\n\
# Fix permissions when running in hardened environments\n\
if [ "$(id -u)" = "0" ]; then\n\
    echo "[init] Running as root, fixing /data permissions..."\n\
    chown -R 10001:10001 /data 2>/dev/null || true\n\
    chmod -R 2770 /data 2>/dev/null || true\n\
    echo "[init] Dropping to user 10001:10001..."\n\
    exec su -s /bin/sh -c "exec \\"$@\\"" kiwix -- "$@"\n\
elif [ ! -w /data ]; then\n\
    echo "[init] WARNING: /data not writable by current user $(id -u):$(id -g)"\n\
    echo "[init] You may need to fix mount permissions or run with --user 10001:10001"\n\
fi\n\
exec "$@"\n' > /init.sh && \
    chmod +x /init.sh



ENV APP_UMASK=027

# Drop root
USER 10001:10001

# Keep the working directory non-root owned
WORKDIR /data

# Prepare writable mount and own it
VOLUME ["/data"]

# App config
ENV DEST=/data/zim \
    LIBRARY=/data/library.xml \
    HTTP_BASE=https://download.kiwix.org/zim \
    UPDATE_INTERVAL_HOURS=24 \
    KEEP_OLD_VERSIONS=0 \
    ITEM_DELAY_SECONDS=5 \
    ITEMS_PATH=/data/items.conf \
    PORT=8080 \
    HOME=/data

# Copy entrypoint with tight permissions and correct ownership
# (Use --chmod/--chown so we don’t need an extra layer to chmod/chown)
COPY --chown=10001:10001 --chmod=0555 entrypoint.sh /entrypoint.sh

EXPOSE 8080/tcp

HEALTHCHECK --interval=30s --timeout=5s --retries=5 --start-period=60s \
  CMD sh -c 'curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null || exit 1'
  
ENTRYPOINT ["/init.sh", "/entrypoint.sh"]