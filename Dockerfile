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
      useradd --uid 10001 --gid 10001 --create-home --home-dir /home/kiwix --shell /usr/sbin/nologin kiwix; \
      apt-get update; \
      apt-get install -y --no-install-recommends bash curl ca-certificates; \
      rm -rf /var/lib/apt/lists/*; \
    else \
      echo "No supported package manager found" >&2; exit 1; \
    fi && \
    # Make sure CA bundle is registered if the base supports it (no-op otherwise)
    (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true)

# config + entrypoint
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# App config
ENV DEST=/data/zim \
    LIBRARY=/data/library.xml \
    HTTP_BASE=https://download.kiwix.org/zim \
    UPDATE_INTERVAL_HOURS=24 \
    KEEP_OLD_VERSIONS=0 \
    ITEM_DELAY_SECONDS=5 \
    PORT=8080 \
    HOME=/home/kiwix

# Prepare writable mount and own it
VOLUME ["/data"]

# Create /data now so we can set ownership without relying on runtime flags
RUN mkdir -p /data && chown -R 10001:10001 /data
RUN chmod 0750 /data || true

# Copy entrypoint with tight permissions and correct ownership
# (Use --chmod/--chown so we don’t need an extra layer to chmod/chown)
COPY --chown=10001:10001 --chmod=0555 entrypoint.sh /entrypoint.sh

# Drop root
USER 10001:10001

# Keep the working directory non-root owned
WORKDIR /home/kiwix

EXPOSE 8080/tcp

HEALTHCHECK --interval=30s --timeout=5s --retries=5 --start-period=60s \
  CMD sh -c 'curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null || exit 1'
  
ENTRYPOINT ["/entrypoint.sh"]