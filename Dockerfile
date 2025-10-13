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

# Create a smart init script that adapts to the runtime user
RUN printf '#!/bin/sh\n\
# Smart initialization that works with any user ID\n\
RUNTIME_UID=$(id -u)\n\
RUNTIME_GID=$(id -g)\n\
\n\
if [ "$RUNTIME_UID" = "0" ]; then\n\
    echo "[init] Running as root - will create user and drop privileges"\n\
    # Create a user matching a common ID or use 1000 as fallback\n\
    TARGET_UID=${PUID:-1000}\n\
    TARGET_GID=${PGID:-1000}\n\
    \n\
    # Create group and user if they do not exist\n\
    if ! getent group $TARGET_GID >/dev/null 2>&1; then\n\
        groupadd -g $TARGET_GID app 2>/dev/null || true\n\
    fi\n\
    if ! getent passwd $TARGET_UID >/dev/null 2>&1; then\n\
        useradd -u $TARGET_UID -g $TARGET_GID -d /home/app -s /bin/sh app 2>/dev/null || true\n\
    fi\n\
    \n\
    # Fix ownership\n\
    chown -R $TARGET_UID:$TARGET_GID /home/app 2>/dev/null || true\n\
    echo "[init] Dropping to user $TARGET_UID:$TARGET_GID"\n\
    exec su -s /bin/sh -c "exec \\"$@\\"" "#$TARGET_UID" -- "$@"\n\
else\n\
    echo "[init] Running as user $RUNTIME_UID:$RUNTIME_GID"\n\
    # Fix ownership to match current user\n\
    if [ -w /home/app ]; then\n\
        chown -R $RUNTIME_UID:$RUNTIME_GID /home/app 2>/dev/null || true\n\
    fi\n\
    # Ensure data directory exists and is writable\n\
    mkdir -p /home/app/data/zim/.tmp 2>/dev/null || true\n\
    if [ ! -w /home/app/data ]; then\n\
        echo "[init] ERROR: /home/app/data not writable by user $RUNTIME_UID:$RUNTIME_GID"\n\
        echo "[init] "\n\
        echo "[init] SOLUTIONS:"\n\
        echo "[init] 1. Run with: docker run --user \$(id -u):\$(id -g) ..."\n\
        echo "[init] 2. Or fix host permissions: chown -R \$(id -u):\$(id -g) ./data"\n\
        echo "[init] 3. Or set PUID/PGID: -e PUID=\$(id -u) -e PGID=\$(id -g)"\n\
        echo "[init] "\n\
        exit 1\n\
    fi\n\
fi\n\
exec "$@"\n' > /init.sh && \
    chmod +x /init.sh

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

HEALTHCHECK --interval=30s --timeout=5s --retries=5 --start-period=60s \
  CMD sh -c 'curl -fsS "http://localhost:${PORT:-8080}/" >/dev/null || exit 1'
  
ENTRYPOINT ["/init.sh", "/entrypoint.sh"]