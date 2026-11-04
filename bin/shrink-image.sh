#!/bin/bash
# Shrink pool images to a chosen level, to save disk. The level is the config's
# POOL_SHRINK (set in the web UI), or --level to override it:
#
#   off      leave images as downloaded (the default)
#   4k       fit-to-fill 3840x2160, JPEG quality 92   (sample: -62% bytes)
#   1440hq   fit-to-fill 2560x1440, JPEG quality 92   (sample: -77%)
#   screen   fit-to-fill this machine's screen, q88   (sample: -89%)
#
# (Sample = 40 pool images measured on cc-desktop, 3 Nov 2026, #1786.)
#
# "Fit-to-fill" means the image still COVERS the target box, the way the desktop
# crops it, so nothing is ever scaled up later. An image is only touched when
# it is larger than the box on both sides; one already at or under the target is
# never re-encoded. The result replaces the original only if it is smaller, and
# keeps the original's timestamp: pruning goes by age, so a shrink must not make
# an old image look new.
#
#   shrink-image.sh FILE...                 fetch-wallpaper.sh calls this per new image
#   shrink-image.sh --pool                  one-off pass over the whole pool (not favourites)
#   shrink-image.sh --level 4k --pool       ... at a level other than the configured one
#   shrink-image.sh --dry-run --pool        report what it would save, change nothing
#
# Placeholders (@@...@@) are substituted by install.sh.
set -uo pipefail

POOL="@@POOL@@"
LOG="@@LOG@@"
CONFIG="@@CONFIG@@"
RES="@@RES@@"
[ "$POOL"   = "@@POOL""@@" ]   && POOL="$HOME/Pictures/online-wallpapers"
[ "$LOG"    = "@@LOG""@@" ]    && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
[ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
[ "$RES"    = "@@RES""@@" ]    && RES="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"
POOL="${WR_POOL:-$POOL}"; LOG="${WR_LOG:-$LOG}"; CONFIG="${WR_CONFIG:-$CONFIG}"; RES="${WR_RES:-$RES}"

POOL_SHRINK=off
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null
LEVEL="$POOL_SHRINK"; DRY=0; WHOLE=0; FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --level) [ $# -ge 2 ] || { echo "shrink-image.sh: --level needs a value" >&2; exit 2; }
             LEVEL="$2"; shift 2; continue ;;
    --dry-run) DRY=1 ;;
    --pool) WHOLE=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    -*) echo "shrink-image.sh: unknown argument '$1' (takes --level L, --pool, --dry-run, FILE...)" >&2; exit 2 ;;
    *) FILES+=("$1") ;;
  esac
  shift
done

case "${LEVEL:-off}" in
  off|'') exit 0 ;;
  4k)     BOX=3840x2160; Q=92 ;;
  1440hq) BOX=2560x1440; Q=92 ;;
  screen) BOX="$RES"; Q=88
          case "$BOX" in [0-9]*x[0-9]*) ;; *) echo "shrink-image.sh: level 'screen' but no screen size known (RES='$BOX')" >&2; exit 2 ;; esac ;;
  *) echo "shrink-image.sh: unknown level '$LEVEL' (off, 4k, 1440hq, screen)" >&2; exit 2 ;;
esac
BW=${BOX%x*}; BH=${BOX#*x}
command -v convert >/dev/null 2>&1 || { echo "shrink-image.sh: ImageMagick (convert) not installed" >&2; exit 1; }

if [ "$WHOLE" = 1 ]; then
  while IFS= read -r f; do FILES+=("$f"); done < <(find "$POOL" -maxdepth 1 -type f \
      \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | sort)
fi
[ ${#FILES[@]} -gt 0 ] || exit 0

seen=0; shrunk=0; before=0; after=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  seen=$((seen + 1))
  read -r w h < <(identify -format '%w %h\n' "$f[0]" 2>/dev/null | head -1)
  case "${w:-}${h:-}" in ''|*[!0-9]*) continue ;; esac
  [ "$w" -gt "$BW" ] && [ "$h" -gt "$BH" ] || continue      # already at or under the box
  case "${f,,}" in *.png) fmt=png ;; *) fmt=jpg ;; esac
  tmp="$(mktemp "${f%/*}/.shrink.XXXXXX")" || continue
  if convert "$f[0]" -auto-orient -resize "${BW}x${BH}^" -quality "$Q" -strip "$fmt:$tmp" 2>>"$LOG"; then
    old=$(stat -c %s "$f"); new=$(stat -c %s "$tmp")
    if [ "$new" -gt 0 ] && [ "$new" -lt "$old" ]; then
      before=$((before + old)); after=$((after + new)); shrunk=$((shrunk + 1))
      if [ "$DRY" = 1 ]; then
        printf 'would shrink %s  %sx%s  %s -> %s KB\n' "$f" "$w" "$h" $((old / 1024)) $((new / 1024))
        rm -f "$tmp"
      else
        touch -r "$f" "$tmp" && chmod --reference="$f" "$tmp" 2>/dev/null; mv -f "$tmp" "$f"
      fi
      continue
    fi
  fi
  rm -f "$tmp"
done

saved=$(awk -v b=$((before - after)) 'BEGIN{printf "%.1f", b/1048576}')
if [ "$DRY" = 1 ]; then
  echo "dry run: level $LEVEL ($BOX q$Q): $shrunk of $seen image(s) would shrink, saving ${saved} MB"
elif [ "$shrunk" -gt 0 ]; then
  echo "$(date '+%F %T') [shrink] level=$LEVEL box=$BOX q=$Q shrunk=$shrunk of $seen saved=${saved}MB" >> "$LOG"
fi
