#!/bin/sh
# Smart initialization that works with any user ID
RUNTIME_UID=$(id -u)
RUNTIME_GID=$(id -g)

if [ "$RUNTIME_UID" = "0" ]; then
    echo "[init] Running as root - will create user and drop privileges"
    TARGET_UID=${PUID:-1000}
    TARGET_GID=${PGID:-1000}
    
    # Create group and user if they do not exist
    if ! getent group $TARGET_GID >/dev/null 2>&1; then
        groupadd -g $TARGET_GID app 2>/dev/null || true
    fi
    if ! getent passwd $TARGET_UID >/dev/null 2>&1; then
        useradd -u $TARGET_UID -g $TARGET_GID -d /home/app -s /bin/sh app 2>/dev/null || true
    fi
    
    # Fix ownership
    chown -R $TARGET_UID:$TARGET_GID /home/app 2>/dev/null || true
    echo "[init] Dropping to user $TARGET_UID:$TARGET_GID"
    exec su -s /bin/sh app -c "exec \"$@\"" -- "$@"
else
    echo "[init] Running as user $RUNTIME_UID:$RUNTIME_GID"
    # Fix ownership to match current user
    if [ -w /home/app ]; then
        chown -R $RUNTIME_UID:$RUNTIME_GID /home/app 2>/dev/null || true
    fi
    # Ensure data directory exists and is writable
    mkdir -p /home/app/data/zim/.tmp 2>/dev/null || true
    if [ ! -w /home/app/data ]; then
        echo "[init] ERROR: /home/app/data not writable by user $RUNTIME_UID:$RUNTIME_GID"
        echo "[init] "
        echo "[init] SOLUTIONS:"
        echo "[init] 1. Run with: docker run --user \$(id -u):\$(id -g) ..."
        echo "[init] 2. Or fix host permissions: chown -R \$(id -u):\$(id -g) ./data"
        echo "[init] 3. Or set PUID/PGID: -e PUID=\$(id -u) -e PGID=\$(id -g)"
        echo "[init] "
        exit 1
    fi
fi
exec "$@"