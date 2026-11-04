#!/bin/bash
# Prune the image pool to its limits, oldest first. Two caps, both read live
# from the config so the web UI can change them without a re-install:
#
#   POOL_MAX     keep at most this many images (default 5000)
#   POOL_MAX_MB  keep the pool at or under this many MB (default 0 = no size cap)
#
# The count cap applies first, then the size cap trims more of the oldest until
# the pool fits. Never pruned: favourites/ (a subdir; only top-level files are
# considered), the image on the desktop right now, and the newest 12 images (the
# same floor the web UI's flushes always used, so a tiny cap can't empty the pool).
# A pruned image's `.quote` sidecar goes with it.
#
# Called hourly by cron and by the web UI after a theme/AI flush or a change to
# either cap. Logs one `[prune] removed=N ...` line when it removes anything
# (gen-status.sh sums the removed= counts).
#
#   prune-pool.sh             prune now
#   prune-pool.sh --dry-run   list what would go, change nothing
#
# Placeholders (@@...@@) are substituted by install.sh; a raw checkout falls back
# to the default paths.
set -uo pipefail

POOL="@@POOL@@"
LOG="@@LOG@@"
CONFIG="@@CONFIG@@"
[ "$POOL"   = "@@POOL""@@" ]   && POOL="$HOME/Pictures/online-wallpapers"
[ "$LOG"    = "@@LOG""@@" ]    && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
[ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
# Test hooks: point a run at a scratch pool without editing the real config.
POOL="${WR_POOL:-$POOL}"; LOG="${WR_LOG:-$LOG}"; CONFIG="${WR_CONFIG:-$CONFIG}"

DRY=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "prune-pool.sh: unknown argument '$a' (takes --dry-run)" >&2; exit 2 ;;
  esac
done

FLOOR=12
POOL_MAX=5000; POOL_MAX_MB=0
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null
case "$POOL_MAX" in ''|*[!0-9]*) POOL_MAX=5000 ;; esac
case "$POOL_MAX_MB" in ''|*[!0-9]*) POOL_MAX_MB=0 ;; esac
[ "$POOL_MAX" -lt "$FLOOR" ] && POOL_MAX=$FLOOR
CUR="$(cat "$(dirname "$CONFIG")/current" 2>/dev/null || true)"

[ -d "$POOL" ] || exit 0

# One prune at a time: the web UI fires one per cap change, and two changes in
# quick succession used to run side by side and both log the same files
# (measured in the sandbox, 4 Nov: 33 logged, 20 actually removed).
mkdir -p "$(dirname "$LOG")" 2>/dev/null
exec 9>"$(dirname "$LOG")/.prune.lock"
flock -w 120 9 || { echo "prune-pool.sh: another prune held the lock for 120s; skipped" >&2; exit 1; }

# Newest first: "<mtime> <bytes> <path>". One find, no per-file spawns.
# awk walks the list: rank > POOL_MAX -> "count"; past the size budget -> "size".
plan="$(find "$POOL" -maxdepth 1 -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) \
          -printf '%T@ %s %p\n' 2>/dev/null | sort -rn -k1,1 \
        | awk -v max="$POOL_MAX" -v cap="$((POOL_MAX_MB * 1024 * 1024))" -v floor="$FLOOR" -v cur="$CUR" '
            { n++; sz=$2; p=$0; sub(/^[^ ]+ [^ ]+ /, "", p)
              if (p == cur) { kept += sz; next }            # on the desktop now: never
              if (n <= floor) { kept += sz; next }          # newest FLOOR: never
              if (n > max) { print "count " sz " " p; next }
              # once over budget, everything older goes too (oldest-first, no
              # keeping a small old image after dropping a bigger newer one)
              if (cap > 0 && (over || kept + sz > cap)) { over = 1; print "size " sz " " p; next }
              kept += sz }')"

[ -n "$plan" ] || exit 0

by_count=0; by_size=0; bytes=0
while read -r why sz path; do
  [ -n "$path" ] && [ -e "$path" ] || continue
  if [ "$DRY" = 1 ]; then
    printf 'would remove (%s cap) %s\n' "$why" "$path"
  else
    rm -f -- "$path" "$path.quote"
  fi
  bytes=$((bytes + sz))
  if [ "$why" = count ]; then by_count=$((by_count + 1)); else by_size=$((by_size + 1)); fi
done <<< "$plan"

n=$((by_count + by_size)); mb=$(( (bytes + 524288) / 1048576 ))
if [ "$DRY" = 1 ]; then
  echo "dry run: would remove $n image(s), ${mb} MB (count cap $POOL_MAX: $by_count, size cap ${POOL_MAX_MB} MB: $by_size)"
else
  echo "$(date '+%F %T') [prune] removed=$n freed=${mb}MB count_cap=$POOL_MAX:$by_count size_cap=${POOL_MAX_MB}MB:$by_size" >> "$LOG"
fi
