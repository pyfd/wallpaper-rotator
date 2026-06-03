#!/bin/bash
# Fetch ONE wallpaper into the pool from a configured set of sources.
#
# Two goals: variety (pull from several sources) and resilience (if one source
# is down/blocked, fall through to the next). Each run shuffles the enabled
# sources, then tries them in that order until one yields a VALID image — so
# over time every source contributes, and any single outage is covered.
#
# Placeholders (@@...@@) are substituted by install.sh. Falls back to sensible
# defaults when run from a raw checkout.
set -uo pipefail

POOL="@@POOL@@"
LOG="@@LOG@@"
RES="@@RES@@"                 # WIDTHxHEIGHT, e.g. 1680x1050
SOURCES="@@SOURCES@@"         # space-separated, e.g. "wallhaven bing picsum local"
LOCALDIR="@@LOCALDIR@@"       # local image folder (used only if it exists + has images)

# Raw-checkout fallback: when run before install.sh substitutes the @@...@@
# tokens, fall back to defaults. The comparison literals are split
# ("@@POOL""@@") so install.sh's sed — which rewrites the contiguous token
# @@POOL@@ in the assignments above — does NOT also rewrite these guards.
[ "$POOL"     = "@@POOL""@@" ]     && POOL="$HOME/Pictures/online-wallpapers"
[ "$LOG"      = "@@LOG""@@" ]      && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
[ "$RES"      = "@@RES""@@" ]      && RES="1920x1080"
[ "$SOURCES"  = "@@SOURCES""@@" ]  && SOURCES="wallhaven bing picsum local"
[ "$LOCALDIR" = "@@LOCALDIR""@@" ] && LOCALDIR=""

# THEME is read live from the config (set via the web UI) so it can change
# without re-running install.sh. Empty = no theme (untargeted).
CONFIG="@@CONFIG@@"
[ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
THEME=""
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

mkdir -p "$POOL" "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

TMP="$(mktemp --suffix=.img 2>/dev/null || echo /tmp/wall.$$.img)"
trap 'rm -f "$TMP"' EXIT

# A file is a usable wallpaper only if it's a non-trivial, decodable image.
# (Sources sometimes return tiny HTML error bodies with a 200.)
valid_image() {
  [ -s "$1" ] || return 1
  local sz; sz="$(stat -c%s "$1" 2>/dev/null || echo 0)"
  [ "$sz" -ge 10240 ] || return 1                      # >= 10 KB
  identify "$1" >/dev/null 2>&1                         # imagemagick can decode it
}

# --- per-source fetchers: populate "$TMP", return 0 on success ---------------

fetch_wallhaven() {                                     # purpose-built wallpapers, ratio-matched
  local url q=""
  [ -n "${THEME:-}" ] && q="&q=$(printf '%s' "$THEME" | sed 's/ /+/g')"   # theme search
  url="$(curl -fsL --max-time 15 \
    "https://wallhaven.cc/api/v1/search?categories=100&purity=100&atleast=${RES}${q}&sorting=random" \
    2>>"$LOG" | jq -r '.data[].path' 2>/dev/null | shuf -n1)"
  [ -n "$url" ] || return 1
  curl -fsL --max-time 30 "$url" -o "$TMP" 2>>"$LOG"
}

fetch_bing() {                                          # curated daily images
  local base
  base="$(curl -fsL --max-time 15 \
    "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=en-GB" \
    2>>"$LOG" | jq -r '.images[].urlbase' 2>/dev/null | shuf -n1)"
  [ -n "$base" ] || return 1
  # Bing serves fixed sizes; 1920x1080 is always available. UHD if present.
  curl -fsL --max-time 30 "https://www.bing.com${base}_1920x1080.jpg" -o "$TMP" 2>>"$LOG"
}

fetch_picsum() {                                        # always-works random floor
  curl -fsL --max-time 30 "https://picsum.photos/${RES%x*}/${RES#*x}" -o "$TMP" 2>>"$LOG"
}

fetch_local() {                                         # offline / your own folder
  [ -n "$LOCALDIR" ] && [ -d "$LOCALDIR" ] || return 1
  local f
  f="$(find "$LOCALDIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | shuf -n1)"
  [ -n "$f" ] || return 1
  cp "$f" "$TMP" 2>>"$LOG"
}

# --- try sources in order until one yields a valid image ---------------------
# Normally shuffle for variety. But only wallhaven honours THEME (bing=curated,
# picsum=random), so when a theme is set, try wallhaven FIRST (rest shuffled as
# fallback) — otherwise themed downloads are drowned out by the theme-blind
# sources. (case-match for membership, NOT `printf|grep -q`, which SIGPIPEs the
# producer under `set -o pipefail` and would mis-report.)
case " $SOURCES " in *" wallhaven "*) has_wh=1 ;; *) has_wh=0 ;; esac
if [ -n "${THEME:-}" ] && [ "$has_wh" = 1 ]; then
  rest="$(printf '%s\n' $SOURCES | grep -vx wallhaven | shuf | tr '\n' ' ')"
  ORDER="wallhaven $rest"
else
  ORDER="$(printf '%s\n' $SOURCES | shuf | tr '\n' ' ')"
fi
for src in $ORDER; do
  : > "$TMP"
  if "fetch_$src" 2>>"$LOG" && valid_image "$TMP"; then
    DEST="$POOL/$(date +%s).$$.jpg"
    mv "$TMP" "$DEST"
    log "[download] src=$src ok img=$(basename "$DEST")"
    exit 0
  fi
  log "[download] src=$src miss"
done

log "[download] fail (all sources exhausted: $SOURCES) — pool unchanged"
exit 1
