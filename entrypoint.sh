#!/usr/bin/env bash
set -euo pipefail

DEST="${DEST:-/data/zim}"
LIBRARY="${LIBRARY:-/data/library.xml}"
RSYNC_ROOT="${RSYNC_ROOT:-rsync://master.download.kiwix.org/download.kiwix.org/zim}"
UPDATE_SECS=$(( ${UPDATE_INTERVAL_HOURS:-24} * 3600 ))
KEEP=${KEEP_OLD_VERSIONS:-0}
PORT="${PORT:-8080}"
ITEM_DELAY="${ITEM_DELAY_SECONDS:-5}"
LIST_RETRIES="${LIST_RETRIES:-4}"
GET_RETRIES="${GET_RETRIES:-4}"
PREFER_FETCH="${PREFER_FETCH:-rsync,http}"   # order to try

DATE_RE='.*_[0-9]{4}-[0-9]{2}\.zim$'
HTTP_BASE="https://download.kiwix.org/zim"

mkdir -p "$DEST"
touch "$LIBRARY" || true

log(){ echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

rsync_list() {
  local sub="$1" ; rsync --list-only "$RSYNC_ROOT/$sub/" 2>&1
}

rsync_get() {
  local sub="$1" name="$2" ; rsync -v --progress "$RSYNC_ROOT/$sub/$name" "$DEST/" 2>&1
}

http_list() {
  local sub="$1"
  # returns plain list of *.zim filenames from HTML index
  curl -fsSL "$HTTP_BASE/$sub/" \
    | grep -oE 'href="[^"]+\.zim"' \
    | sed -E 's/^href="//; s/"$//'
}

http_get() {
  local sub="$1" name="$2"
  curl -fL --retry 5 --retry-delay 3 -o "$DEST/$name" "$HTTP_BASE/$sub/$name"
}

list_latest() {
  # tries fetchers in preferred order, outputs the latest matching filename
  local sub="$1" prefix="$2" out="" rc=0
  IFS=',' read -ra methods <<< "$PREFER_FETCH"
  for m in "${methods[@]}"; do
    for ((i=1;i<=LIST_RETRIES;i++)); do
      if [[ "$m" == "rsync" ]]; then
        out="$(rsync_list "$sub" || true)"
        rc=$?
        # rsync emits errors on stderr; ensure we only keep filenames
        if [[ $rc -eq 0 ]]; then
          out="$(printf '%s\n' "$out" | awk '$5 ~ /\.zim$/ {print $5}')"
        fi
      else
        out="$(http_list "$sub" || true)"
        rc=$?
      fi

      if [[ $rc -eq 0 && -n "$out" ]]; then
        # filter by prefix & known date pattern, then pick newest
        printf '%s\n' "$out" \
          | grep -E "^${prefix}.*\.zim$" \
          | grep -E "$DATE_RE" \
          | sort -V \
          | tail -n1
        return 0
      fi

      sleep $((i*2))  # backoff
    done
  done
  return 1
}

get_file() {
  local sub="$1" name="$2" rc=1
  IFS=',' read -ra methods <<< "$PREFER_FETCH"
  for m in "${methods[@]}"; do
    for ((i=1;i<=GET_RETRIES;i++)); do
      if [[ "$m" == "rsync" ]]; then
        rsync_get "$sub" "$name" && return 0 || rc=$?
      else
        http_get "$sub" "$name" && return 0 || rc=$?
      fi
      sleep $((i*2))
    done
  done
  return $rc
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
      # remove from library if present; ignore errors
      id=$(kiwix-manage "$LIBRARY" show 2>/dev/null | awk -v z="$base" '$2 ~ z {print $1}')
      [[ -n "${id:-}" ]] && kiwix-manage "$LIBRARY" remove "$id" || true
      rm -f -- "$f"
      log "Pruned $base"
    done
  fi
}

sync_once() {
  while read -r SUBDIR PREFIX; do
    [[ -z "${SUBDIR// }" || "$SUBDIR" =~ ^# ]] && continue

    local latest
    latest="$(list_latest "$SUBDIR" "$PREFIX" || true)"
    if [[ -z "$latest" ]]; then
      log "No match for $SUBDIR/${PREFIX}*.zim (all sources failed)"
      sleep "$ITEM_DELAY"
      continue
    fi

    local destfile="$DEST/$latest"
    if [[ -f "$destfile" ]]; then
      log "Up to date: $latest"
    else
      log "Downloading $SUBDIR/$latest"
      if get_file "$SUBDIR" "$latest"; then
        kiwix-manage "$LIBRARY" add "$destfile" || true
        log "Added to library: $latest"
      else
        log "Download failed for $latest"
      fi
    fi

    prune_old_versions "$PREFIX"
    sleep "$ITEM_DELAY"
  done < /items.conf
}

# updater loop (background)
(
  while true; do
    sync_once
    sleep "$UPDATE_SECS"
  done
) &

# serve in foreground; auto-reloads on library changes
exec kiwix-serve --library "$LIBRARY" --monitorLibrary --port "$PORT"
