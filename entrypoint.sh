#!/usr/bin/env bash
set -euo pipefail

echo "[bootstrap] HTTP-only updater active"
ITEMS_PATH="${ITEMS_PATH:-/home/app/data/items.conf}"
DEST="${DEST:-/home/app/data/zim}"
LIBRARY="${LIBRARY:-/home/app/data/library.xml}"
UPDATE_SECS=$(( ${UPDATE_INTERVAL_HOURS:-24} * 3600 ))
KEEP=${KEEP_OLD_VERSIONS:-0}
PORT="${PORT:-8080}"
ITEM_DELAY="${ITEM_DELAY_SECONDS:-5}"
HTTP_BASE="${HTTP_BASE:-https://download.kiwix.org/zim}"
WAIT_FOR_FIRST="${WAIT_FOR_FIRST:-0}"

DATE_RE='.*_[0-9]{4}-[0-9]{2}\.zim$'
TMP_DIR="${TMP_DIR:-$DEST/.tmp}"
TMP_MAX_AGE_DAYS="${TMP_MAX_AGE_DAYS:-14}"

PRUNE_UNLISTED="${PRUNE_UNLISTED:-0}"
UNLISTED_GRACE_HOURS="${UNLISTED_GRACE_HOURS:-24}"
UNLISTED_DRY_RUN="${UNLISTED_DRY_RUN:-0}"

# Define log function early
log(){ echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

# Ensure directories exist and are writable
ensure_writable_dir() {
  local dir="$1"
  
  # First try to create the directory
  if ! mkdir -p "$dir" 2>/dev/null; then
    log "ERROR: Cannot create directory: $dir"
    log "This usually means the data directory is mounted read-only or has permission issues."
    log "Current user: $(id -u):$(id -g)"
    log "Try using PUID/PGID environment variables to match your host user:"
    log "  environment:"
    log "    - PUID=$(id -u)"
    log "    - PGID=$(id -g)"
    exit 1
  fi
  
  # Then check if it's writable
  if ! [ -w "$dir" ]; then
    log "ERROR: Directory not writable: $dir"
    log "Current user: $(id -u):$(id -g)"
    log "Directory permissions: $(ls -ld "$dir" 2>/dev/null || echo "cannot stat")"
    log "Try using PUID/PGID environment variables to match your host user:"
    log "  environment:"
    log "    - PUID=$(id -u)"
    log "    - PGID=$(id -g)"
    exit 1
  fi
}

ensure_writable_dir "$TMP_DIR"
ensure_writable_dir "$DEST"
ensure_writable_dir "$(dirname "$LIBRARY")"

# Ensure library.xml exists and is writable
if ! touch "$LIBRARY" 2>/dev/null; then
  log "ERROR: Cannot create/write library file: $LIBRARY"
  log "Current user: $(id -u):$(id -g)"
  log "Directory permissions: $(ls -ld "$(dirname "$LIBRARY")" 2>/dev/null || echo "cannot stat")"
  log "File permissions: $(ls -l "$LIBRARY" 2>/dev/null || echo "file does not exist")"
  exit 1
fi

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

sweep_temp() {
  local dir="${TMP_DIR:-$DEST/.tmp}"
  [ -d "$dir" ] || return 0
  # delete very old partials
  find "$dir" -type f -name '*.part' -mtime +"$TMP_MAX_AGE_DAYS" -print -delete || true
  # clean stray checksum helpers older than a day
  find "$dir" -type f \( -name '*.sha256' -o -name '*.sha256sum' \) -mtime +1 -print -delete || true
}


download_http() {
  # $1=subdir, $2=filename (exact)
  local sub="$1" name="$2"
  local final="$DEST/$name"
  local part="$TMP_DIR/$name.part"
  local sha_remote="$HTTP_BASE/$sub/$name.sha256"

  mkdir -p "$(dirname "$part")"

  # log target URLs
    echo "[download] URL: $HTTP_BASE/$sub/$name"

  # resume if partial exists
  curl -fL --retry 5 --retry-delay 3 -C - -o "$part" "$HTTP_BASE/$sub/$name"

  # try checksum verification first
  if curl -fsSL "$sha_remote" -o "$part.sha256"; then
    # accept either "HASH  FILE" or "SHA256 (FILE) = HASH"
    if grep -qi '^sha256 ' "$part.sha256"; then
      # transform "SHA256 (file) = hash" -> "hash  file"
      awk '
        BEGIN{IGNORECASE=1}
        match($0,/=\s*([0-9a-f0-9]{64})/,m){hash=m[1]}
        match($0,/^\s*SHA256\s*\(([^)]+)\)/,f){file=f[1]}
        END{ if(hash!=""&&file!="") printf("%s  %s\n",hash,file) }
      ' "$part.sha256" > "$part.sha256sum"
    else
      # assume "hash  filename" or "hash filename"
      awk '{print $1"  "$2}' "$part.sha256" > "$part.sha256sum"
    fi

    # point the check at the *actual path* we just downloaded to
    # rewrite filename in the checksum line to our $part path
    hash="$(awk '{print $1}' "$part.sha256sum")"
    echo "$hash  $part" > "$part.sha256sum"

    if ! sha256sum -c "$part.sha256sum"; then
      echo "[verify] SHA256 failed for $name; keeping partial for resume."
      return 1
    fi
  else
    # fallback: compare size with Content-Length
    cl=$(curl -fsSI "$HTTP_BASE/$sub/$name" | awk 'tolower($1)=="content-length:"{print $2}' | tr -d '\r')
    if [ -n "$cl" ]; then
      size=$(stat -c %s "$part" 2>/dev/null || wc -c <"$part")
      if [ "$size" != "$cl" ]; then
        echo "[verify] Size mismatch for $name (have $size, need $cl); keeping partial for resume."
        return 1
      fi
    fi
  fi

  # passed verification -> atomic move then clean up
  mv -f "$part" "$final"
  rm -f "$part.sha256" "$part.sha256sum"
  return 0
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

build_allowlist() {
  ALLOWLIST="$(mktemp)"
  # Guard if config is missing
  [ -f "$ITEMS_PATH" ] || { : > "$ALLOWLIST"; return; }

  # Create list of allowed basenames from config
  while read -r SUBDIR NAME; do
    [[ -z "${SUBDIR// }" || "$SUBDIR" =~ ^# ]] && continue
    if [[ "$NAME" =~ \.zim$ ]]; then
      # exact file tracking
      echo "$NAME" >> "$ALLOWLIST"
    else
      # prefix tracking: allow any local file matching the prefix
      for f in "$DEST"/"${NAME}"*.zim; do
        [ -e "$f" ] || continue
        basename "$f" >> "$ALLOWLIST"
      done
    fi
  done < "$ITEMS_PATH"
}

prune_unlisted() {
  [ "$PRUNE_UNLISTED" = "1" ] || return 0

  build_allowlist

  # map library: basename -> id
  declare -A LIBMAP
  while read -r id path; do
    base="$(basename "$path")"
    LIBMAP["$base"]="$id"
  done < <(kiwix-manage "$LIBRARY" show 2>/dev/null | awk '$2 ~ /\.zim$/ {print $1, $2}')

  # evaluate local files
  shopt -s nullglob
  for f in "$DEST"/*.zim; do
    base="$(basename "$f")"
    if ! grep -qxF "$base" "$ALLOWLIST"; then
      # honor grace window to avoid racing brand-new files
      if find "$DEST" -maxdepth 1 -name "$base" -mmin +"$((UNLISTED_GRACE_HOURS*60))" | grep -q .; then
        if [ "$UNLISTED_DRY_RUN" = "1" ]; then
          log "[dry-run] would remove unlisted: $base"
          [ -n "${LIBMAP[$base]:-}" ] && log "[dry-run] would kiwix-manage remove ${LIBMAP[$base]}"
        else
          if [ -n "${LIBMAP[$base]:-}" ]; then
            kiwix-manage "$LIBRARY" remove "${LIBMAP[$base]}" || true
            log "Removed from library: $base"
          fi
          rm -f -- "$f"
          log "Deleted unlisted file: $base"
        fi
      else
        log "Unlisted but within grace window: $base (skipping for now)"
      fi
    fi
  done
  rm -f "$ALLOWLIST" 2>/dev/null || true
}

sync_once() {
  # Check if config file exists and is readable
  if [ ! -f "$ITEMS_PATH" ]; then
    log "WARNING: Items config file not found: $ITEMS_PATH"
    log "Create this file with content like: 'wikipedia wikipedia_en_top'"
    return 0
  fi
  
  if [ ! -r "$ITEMS_PATH" ]; then
    log "ERROR: Cannot read items config file: $ITEMS_PATH"
    log "Current user: $(id -u):$(id -g)"
    log "File permissions: $(ls -l "$ITEMS_PATH" 2>/dev/null || echo "file does not exist")"
    return 1
  fi

  while read -r SUBDIR NAME; do
    # skip blanks and comments
    [[ -z "${SUBDIR// }" || "$SUBDIR" =~ ^# ]] && continue

    # Decide whether NAME is an exact filename (*.zim) or a prefix
    local target="$NAME"
    if [[ "$NAME" =~ \.zim$ ]]; then
      # exact file (e.g., ..._latest.zim or a specific month)
      :
    else
      # NAME is a prefix; resolve the latest available filename via HTTP listing
      target="$(latest_from_prefix "$SUBDIR" "$NAME" || true)"
      if [[ -z "$target" ]]; then
        log "No match via HTTP for $SUBDIR/${NAME}*.zim"
        sleep "$ITEM_DELAY"
        continue
      fi
    fi

    local destfile="$DEST/$target"

    if [[ -f "$destfile" ]]; then
      # already have the final, verified file
      log "Up to date: $target"
    else
      # === guarded download + verify + atomic move ===
      log "Downloading $SUBDIR/$target"
      if download_http "$SUBDIR" "$target"; then
        # only after download_http() verifies and atomically moves .part -> final
        if kiwix-manage "$LIBRARY" add "$destfile" 2>/dev/null; then
          log "Added to library: $target"
        else
          log "WARNING: Failed to add $target to library (continuing anyway)"
        fi
      else
        # on failure/partial, we do nothing except keep the .part for resume
        log "Download/verify not complete yet for: $target (will resume next run)"
      fi
    fi

    # rotate older versions only for prefix-tracked items
    if [[ ! "$NAME" =~ \.zim$ ]]; then
      prune_old_versions "$NAME"
    fi

    sleep "$ITEM_DELAY"
  done < "$ITEMS_PATH"
}

# write config from compose (if provided)
if [ -n "${ITEMS:-}" ]; then
  # ensure items config directory is writable
  ensure_writable_dir "$(dirname "$ITEMS_PATH")"
  
  # normalize CRLF just in case and write config
  if ! printf '%s\n' "$ITEMS" | sed 's/\r$//' > "$ITEMS_PATH" 2>/dev/null; then
    log "ERROR: Cannot write items config to: $ITEMS_PATH"
    log "Current user: $(id -u):$(id -g)"
    log "Directory permissions: $(ls -ld "$(dirname "$ITEMS_PATH")" 2>/dev/null || echo "cannot stat")"
    exit 1
  fi
  echo "[config] Wrote $(wc -l < "$ITEMS_PATH") lines to '$ITEMS_PATH' from \$ITEMS"
fi


# allow manual bootstrap
if [[ "${1:-}" == "--oneshot" ]]; then
  sync_once; 
  sweep_temp;
  prune_unlisted;
  exit 0
fi

# background updater loop
( while true; do
    sync_once
    sweep_temp
    prune_unlisted
    sleep "$UPDATE_SECS"
  done ) &

# optional: wait until at least one ZIM exists before serving
if [[ "$WAIT_FOR_FIRST" = "1" ]]; then
  log "Waiting for first ZIM..."
  until ls -1 "$DEST"/*.zim >/dev/null 2>&1; do sleep 5; done
fi

# serve in foreground; auto-reload on library changes
exec kiwix-serve --library "$LIBRARY" --monitorLibrary --port "$PORT"
