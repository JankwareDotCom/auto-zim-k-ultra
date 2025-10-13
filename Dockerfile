FROM ghcr.io/kiwix/kiwix-tools:3.7.0 AS kiwix_base
FROM kiwix_base

# Accept build args for user/group IDs to match host user
ARG USER_ID=10001
ARG GROUP_ID=10001

# Use a consistent, safer shell for build steps
SHELL ["/bin/sh", "-eux", "-c"]

# Minimal runtime deps + non-root user creation for both Alpine and Debian/Ubuntu
# - Installs: bash (for your script if it uses bashisms), curl (healthcheck), ca-certs
# - Creates dedicated user/group with a stable UID/GID that won't collide with system users
# - Cleans up package lists
RUN if command -v apk >/dev/null 2>&1; then \
      addgroup -g ${GROUP_ID} -S app && adduser -S -D -u ${USER_ID} -G app -h /home/app app; \
      apk add --no-cache bash coreutils curl ca-certificates; \
    elif command -v apt-get >/dev/null 2>&1; then \
      export DEBIAN_FRONTEND=noninteractive; \
      groupadd --gid ${GROUP_ID} app || true; \
      useradd --uid ${USER_ID} --gid ${GROUP_ID} --create-home --home-dir /home/app --shell /usr/sbin/nologin app; \
      apt-get update; \
      apt-get install -y --no-install-recommends bash curl ca-certificates; \
      rm -rf /var/lib/apt/lists/*; \
    else \
      echo "No supported package manager found" >&2; exit 1; \
    fi && \
    # Make sure CA bundle is registered if the base supports it (no-op otherwise)
    (command -v update-ca-certificates >/dev/null 2>&1 && update-ca-certificates || true)

# Ensure home directory exists, is owned by the runtime user, and is SGID + group-writable
# SGID (2) on dirs ⇒ new files/dirs inherit the group
RUN mkdir -p /home/app/data /home/app/data/zim && \
    chown -R ${USER_ID}:${GROUP_ID} /home/app && \
    chmod -R 2770 /home/app

# Create a minimal init script for root handling and clear error messages
RUN printf '#!/bin/sh\n\
if [ "$(id -u)" = "0" ]; then\n\
    echo "[init] Running as root, fixing permissions and dropping to user app..."\n\
    chown -R %s:%s /home/app 2>/dev/null || true\n\
    exec su -s /bin/sh -c "exec \\"$@\\"" app -- "$@"\n\
fi\n\
exec "$@"\n' "${USER_ID}" "${GROUP_ID}" > /init.sh && \
    chmod +x /init.sh

ENV APP_UMASK=027

# Drop root
USER ${USER_ID}:${GROUP_ID}

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
COPY --chown=${USER_ID}:${GROUP_ID} --chmod=0555 entrypoint.sh /entrypoint.sh

EXPOSE 8080/tcp

HEALTHCHECK --interval=30s --timeout=5s --retries=5 --start-period=60s \
  CMD sh -c 'curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null || exit 1'
  
ENTRYPOINT ["/init.sh", "/entrypoint.sh"]