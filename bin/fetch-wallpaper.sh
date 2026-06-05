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
THEME=""; AI_WALLPAPER=0; AI_PROMPT=""; AI_TOKEN=""; AI_HORDE_KEY=""
OVERLAY_QUOTE=0; QUOTE_MATCH_IMAGE=0
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null
# THEME may be a space-separated list (multi-theme rotation): each fetch picks
# one at random, so the pool converges to a MIX of the selected themes.
if [ -n "${THEME:-}" ]; then THEME="$(printf '%s\n' $THEME | shuf -n1)"; fi

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

fetch_ai() {  # AI-generated. The prompt builds itself from live context — time
              # of day, season, today's weather (forecast cache), the picked
              # theme — plus the user's optional AI_PROMPT style words.
              # Default backend: AI Horde (stablehorde.net) — free, anonymous,
              # crowdsourced SD; typically ~30-60s, worst case a few minutes.
              # Optional fast path: set AI_TOKEN in the config for
              # pollinations.ai (their anonymous tier is rate-limited away).
  command -v jq >/dev/null 2>&1 || return 1
  local hour mon tod season cond prompt
  # Quote-linked generation (QUOTE_MATCH_IMAGE): draw a random quote from the
  # shuffle-bag (cache as fallback) and let IT drive the scene instead of
  # THEME. QLINE is deliberately global — the main loop writes it as a
  # "<image>.quote" sidecar after a successful save, and the renderer then
  # shows that quote whenever this image is on screen.
  QLINE=""
  if [ "${QUOTE_MATCH_IMAGE:-0}" = 1 ] && [ "${OVERLAY_QUOTE:-0}" = 1 ]; then
    local qsrc="$(dirname "$CONFIG")/quotes.bag"
    [ -s "$qsrc" ] || qsrc="$(dirname "$CONFIG")/quotes.cache"
    QLINE="$(shuf -n1 "$qsrc" 2>/dev/null)"
  fi
  hour=$(date +%-H); mon=$(date +%-m)
  if   [ "$hour" -lt 5 ];  then tod="deep night, starlight"
  elif [ "$hour" -lt 9 ];  then tod="dawn, soft first light"
  elif [ "$hour" -lt 12 ]; then tod="fresh morning light"
  elif [ "$hour" -lt 17 ]; then tod="bright daylight"
  elif [ "$hour" -lt 21 ]; then tod="golden hour, dusk"
  else tod="night, moonlit"; fi
  case "$mon" in 12|1|2) season=winter;; 3|4|5) season=spring;; 6|7|8) season=summer;; *) season=autumn;; esac
  cond="$(awk -F'|' 'NR==1{print tolower($4)}' "$(dirname "$CONFIG")/forecast.raw" 2>/dev/null)"
  if [ -n "$QLINE" ]; then
    prompt="an evocative, beautiful scene inspired by the quote: \"${QLINE%%|*}\", $season, $tod${cond:+, $cond weather}${AI_PROMPT:+, $AI_PROMPT}, cinematic lighting, highly detailed, no text, no words, no lettering"
  else
    prompt="a breathtaking wallpaper of ${THEME:-a landscape}, $season, $tod${cond:+, $cond weather}${AI_PROMPT:+, $AI_PROMPT}, cinematic lighting, highly detailed, no text"
  fi
  if [ -n "${AI_TOKEN:-}" ]; then
    local eprompt seed
    eprompt="$(jq -rn --arg s "$prompt" '$s|@uri')"
    seed="$(( $(date +%s%N) % 1000000 ))"
    curl -fsL --max-time 90 \
      "https://image.pollinations.ai/prompt/${eprompt}?width=${RES%x*}&height=${RES#*x}&seed=${seed}&nologo=true&token=${AI_TOKEN}" \
      -o "$TMP" 2>>"$LOG" && return 0
  fi
  # AI Horde: async submit -> poll -> download. Dims must be multiples of 64;
  # the renderer crop-fills to screen res, so a 16:9 gen upscales fine.
  local w=1024 h=576 body id i img key="${AI_HORDE_KEY:-0000000000}"
  [ "${RES%x*}" -ge 2560 ] 2>/dev/null && { w=1536; h=896; }
  # Horde policy (caught 2026-06-04): KudosUpfront — requests over 665px
  # (anonymous) / 705px (registered) 403 unless the account already holds the
  # kudos (~13 for 1024x576), so every gen silently missed. Pick the largest
  # frame the account can actually afford (the renderer crop-fills upward):
  # kudos-rich registered key -> full res; plain registered key -> 704x448
  # (+ queue priority); anonymous -> 640x384. AI_HORDE_KEY: free registration
  # at stablehorde.net; kudos are earned by running a worker or transfers.
  if [ "$key" = "0000000000" ]; then
    w=640; h=384
  else
    kud="$(curl -fsS --max-time 10 -H "apikey: $key" "https://stablehorde.net/api/v2/find_user" 2>>"$LOG" | jq -r '.kudos // 0' 2>/dev/null)"
    [ "${kud%.*}" -ge 15 ] 2>/dev/null || { w=704; h=448; }
  fi
  # nsfw:true + censor_nsfw:false = return the image as generated, never the
  # black "CENSORED" card (worker NSFW classifiers false-positive on plain
  # landscape prompts). The censored-flag check below stays as a net for
  # workers configured to force-censor anyway.
  body="$(jq -n --arg p "$prompt" --argjson w "$w" --argjson h "$h" \
          '{prompt:$p, params:{width:$w, height:$h, steps:25}, nsfw:true, censor_nsfw:false}')"
  id="$(curl -fsS --max-time 20 -X POST "https://stablehorde.net/api/v2/generate/async" \
        -H "apikey: $key" -H "Content-Type: application/json" \
        -d "$body" 2>>"$LOG" | jq -r '.id // empty')"
  [ -n "$id" ] || return 1
  i=0
  while [ "$i" -lt 36 ]; do                              # up to ~6 min
    sleep 10
    [ "$(curl -fsS --max-time 15 "https://stablehorde.net/api/v2/generate/check/$id" 2>>"$LOG" \
         | jq -r '.done // empty')" = true ] && break
    i=$((i+1))
  done
  local stj
  stj="$(curl -fsS --max-time 15 "https://stablehorde.net/api/v2/generate/status/$id" 2>>"$LOG")"
  img="$(printf '%s' "$stj" | jq -r '.generations[0].img // empty')"
  # A worker NSFW false-positive replaces the image with a text "CENSORED"
  # card and sets generations[].censored — reject it (fall through to the
  # normal sources) instead of saving the card as a wallpaper (Fam1
  # 2026-06-04: the card ended up on the desktop).
  if [ "$(printf '%s' "$stj" | jq -r '.generations[0].censored // false')" = "true" ]; then
    log "[download] ai censored-card rejected (worker NSFW false-positive)"
    return 1
  fi
  [ -n "$img" ] || return 1
  curl -fsL --max-time 60 "$img" -o "$TMP.webp" 2>>"$LOG" || { rm -f "$TMP.webp"; return 1; }
  convert "$TMP.webp" jpg:"$TMP" 2>>"$LOG"               # horde serves webp; pool is jpg
  rm -f "$TMP.webp"
  [ -s "$TMP" ]
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
# Sweep orphaned quote sidecars (the hourly prune only removes *.jpg, and
# Keep/Ban moves leave sidecars behind) — cheap, runs every fetch.
for _q in "$POOL"/*.quote; do
  [ -e "$_q" ] || continue
  [ -f "${_q%.quote}" ] || rm -f "$_q"
done

case " $SOURCES " in *" wallhaven "*) has_wh=1 ;; *) has_wh=0 ;; esac
if [ -n "${THEME:-}" ] && [ "$has_wh" = 1 ]; then
  rest="$(printf '%s\n' $SOURCES | grep -vx wallhaven | shuf | tr '\n' ' ')"
  ORDER="wallhaven $rest"
else
  ORDER="$(printf '%s\n' $SOURCES | shuf | tr '\n' ' ')"
fi
# AI mode: while on, every new download tries generation first (normal sources
# stay as fallback for outages/slow gens) — the pool converges to AI images.
[ "${AI_WALLPAPER:-0}" = 1 ] && ORDER="ai $ORDER"
# One-shot source override (the web UI's "Dream now" sets WR_FORCE_SRC=ai):
# try ONLY this source — no fallback, so a failed dream doesn't surprise-swap
# the wallpaper with a random download.
[ -n "${WR_FORCE_SRC:-}" ] && ORDER="$WR_FORCE_SRC"
for src in $ORDER; do
  : > "$TMP"
  if "fetch_$src" 2>>"$LOG" && valid_image "$TMP"; then
    # AI generations carry provenance in the filename (.ai.jpg) so the
    # renderer can mark them subtly and the GUI can tag them — survives
    # moves to favourites/ with no manifest to maintain.
    ext="jpg"; [ "$src" = ai ] && ext="ai.jpg"
    DEST="$POOL/$(date +%s).$$.$ext"
    mv "$TMP" "$DEST"
    # Quote-linked gen: persist the quote beside its image; the renderer
    # prefers the sidecar over a fresh bag draw when this image is shown.
    linked=""
    if [ "$src" = ai ] && [ -n "${QLINE:-}" ]; then
      printf '%s\n' "$QLINE" > "$DEST.quote" 2>>"$LOG" && linked=" (quote-linked)"
    fi
    log "[download] src=$src ok img=$(basename "$DEST")$linked"
    exit 0
  fi
  log "[download] src=$src miss"
done

log "[download] fail (all sources exhausted: $SOURCES) — pool unchanged"
exit 1
