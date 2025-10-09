#!/usr/bin/env bash
set -euo pipefail

echo "[bootstrap] HTTP-only updater active; no rsync calls will be made."

DEST="${DEST:-/data/zim}"
LIBRARY="${LIBRARY:-/data/library.xml}"
UPDATE_SECS=$(( ${UPDATE_INTERVAL_HOURS:-24} * 3600 ))
KEEP=${KEEP_OLD_VERSIONS:-0}
PORT="${PORT:-8080}"
ITEM_DELAY="${ITEM_DELAY_SECONDS:-5}"
HTTP_BASE="${HTTP_BASE:-https://download.kiwix.org/zim}"
WAIT_FOR_FIRST="${WAIT_FOR_FIRST:-0}"

DATE_RE='.*_[0-9]{4}-[0-9]{2}\.zim$'

mkdir -p "$DEST"
touch "$LIBRARY" || true

log(){ echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

http_list() {
  # prints *.zim filenames in a directory
  local sub="$1"
  curl -fsSL "$HTTP_BASE/$sub/" \
    | grep -oE 'href="[^"]+\.zim"' \
    | sed -E 's/^href="//; s/"$//'
}

latest_from_prefix() {
  local sub="$1" prefix="$2"
  http_list "$sub" \
    | grep -E "^${prefix}.*\.zim$" \
    | grep -E "$DATE_RE" \
    | sort -V \
    | tail -n1
}

download_http() {
  local sub="$1" name="$2"
  curl -fL --retry 5 --retry-delay 3 -o "$DEST/$name" "$HTTP_BASE/$sub/$name"
}

prune_old_versions() {
  local prefix="$1"
  mapfile -t files < <(ls -1 "$DEST"/"${prefix}"*.zim 2>/dev/null \
    | grep -E "$DATE_RE" \
    | sort -V)
  local to_remove=$(( ${#files[@]} - (KEEP + 1) ))
  if (( to_remove > 0 )); then
    for f in "${files[@]:0:to_remove}"; do
      local base="$(basename "$f")"
      id=$(kiwix-manage "$LIBRARY" show 2>/dev/null | awk -v z="$base" '$2 ~ z {print $1}')
      [[ -n "${id:-}" ]] && kiwix-manage "$LIBRARY" remove "$id" || true
      rm -f -- "$f"; log "Pruned $base"
    done
  fi
}

sync_once() {
  while read -r SUBDIR NAME; do
    [[ -z "${SUBDIR// }" || "$SUBDIR" =~ ^# ]] && continue

    local target="$NAME"
    if [[ "$NAME" =~ \.zim$ ]]; then
      # exact filename (e.g. ..._latest.zim or a specific release)
      :
    else
      # treat as prefix
      target="$(latest_from_prefix "$SUBDIR" "$NAME" || true)"
      if [[ -z "$target" ]]; then
        log "No match via HTTP for $SUBDIR/${NAME}*.zim"
        sleep "$ITEM_DELAY"; continue
      fi
    fi

    local destfile="$DEST/$target"
    if [[ -f "$destfile" ]]; then
      log "Up to date: $target"
    else
      log "Downloading $SUBDIR/$target"
      if download_http "$SUBDIR" "$target"; then
        kiwix-manage "$LIBRARY" add "$destfile" || true
        log "Added to library: $target"
      else
        log "Download failed: $target"
      fi
    fi

    # rotate only for prefix-tracked items
    [[ "$NAME" =~ \.zim$ ]] || prune_old_versions "$NAME"
    sleep "$ITEM_DELAY"
  done < /items.conf
}

# write config from compose (if provided)
if [ -n "${ITEMS:-}" ]; then
  # normalize CRLF just in case
  printf '%s\n' "$ITEMS" | sed 's/\r$//' > /items.conf
  echo "[config] Wrote $(wc -l < /items.conf) lines to /items.conf from \$ITEMS"
fi

# allow manual bootstrap
if [[ "${1:-}" == "--oneshot" ]]; then
  sync_once; exit 0
fi

# background updater loop
( while true; do sync_once; sleep "$UPDATE_SECS"; done ) &

# optional: wait until at least one ZIM exists before serving
if [[ "$WAIT_FOR_FIRST" = "1" ]]; then
  log "Waiting for first ZIM..."
  until ls -1 "$DEST"/*.zim >/dev/null 2>&1; do sleep 5; done
fi

# serve in foreground; auto-reload on library changes
exec kiwix-serve --library "$LIBRARY" --monitorLibrary --port "$PORT"
