#!/usr/bin/env bash
set -euo pipefail

DEST="${DEST:-/data/zim}"
LIBRARY="${LIBRARY:-/data/library.xml}"
RSYNC_ROOT="${RSYNC_ROOT:-rsync://master.download.kiwix.org/download.kiwix.org/zim}"
UPDATE_SECS=$(( ${UPDATE_INTERVAL_HOURS:-24} * 3600 ))
KEEP=${KEEP_OLD_VERSIONS:-0}
PORT="${PORT:-8080}"

DATE_RE='.*_[0-9]{4}-[0-9]{2}\.zim$'

mkdir -p "$DEST"
touch "$LIBRARY" || true

log(){ echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

latest_remote() {
  local dir="$1" prefix="$2"
  # list remote .zim names, filter by prefix, sort by YYYY-MM, pick last
  rsync --list-only "$RSYNC_ROOT/$dir/" \
    | awk '$5 ~ /\.zim$/ {print $5}' \
    | grep -E "^${prefix}.*\.zim$" \
    | grep -E "$DATE_RE" \
    | sort -V \
    | tail -n1
}

sync_once() {
  while read -r SUBDIR PREFIX; do
    [[ -z "${SUBDIR// }" || "$SUBDIR" =~ ^# ]] && continue
    local latest
    latest=$(latest_remote "$SUBDIR" "$PREFIX" || true)
    if [[ -z "$latest" ]]; then
      log "No match for ${SUBDIR}/${PREFIX}*.zim"
      continue
    fi

    local destfile="$DEST/$latest"
    if [[ -f "$destfile" ]]; then
      log "Up to date: $latest"
    else
      log "Downloading $SUBDIR/$latest"
      rsync -v --progress "$RSYNC_ROOT/$SUBDIR/$latest" "$DEST/"
      # add/refresh entry in library
      kiwix-manage "$LIBRARY" add "$destfile" || true
    fi

    # prune old versions (keep latest + KEEP)
    mapfile -t files < <(ls -1 "$DEST"/"${PREFIX}"*.zim 2>/dev/null \
      | grep -E "$DATE_RE" \
      | sort -V)
    local to_remove=$(( ${#files[@]} - (KEEP + 1) ))
    if (( to_remove > 0 )); then
      for f in "${files[@]:0:to_remove}"; do
        # remove from library if present; ignore errors
        id=$(kiwix-manage "$LIBRARY" show 2>/dev/null | awk -v z="$(basename "$f")" '$2 ~ z {print $1}')
        [[ -n "$id" ]] && kiwix-manage "$LIBRARY" remove "$id" || true
        rm -f -- "$f"
        log "Pruned $(basename "$f")"
      done
    fi

  done < /items.conf
}

# kick off updater loop in background
(
  while true; do
    sync_once
    sleep "$UPDATE_SECS"
  done
) &

# serve in foreground; auto-reloads library on changes
exec kiwix-serve --library "$LIBRARY" --monitorLibrary --port "$PORT"
