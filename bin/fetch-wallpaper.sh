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

# --- perceptual de-duplication ----------------------------------------------
# The md5 guard further down only catches BYTE-identical re-downloads. Curated
# feeds also re-serve the SAME picture at a different resolution / JPEG quality
# / crop -> different bytes -> md5 sees it as new, and the no-repeat shuffle-bag
# then shows it as a "different" wallpaper (this was the real cause of the déjà
# vu even with a small pool). An 8x8 average-hash (aHash) is
# resolution/quality-independent, so near-identical re-serves collapse to a
# near-identical 64-bit fingerprint and get discarded. Needs ImageMagick; if
# `convert` is absent we silently fall back to md5-only (no worse than before).
STATEDIR="$(dirname "$LOG")"
PHASH_INDEX="$STATEDIR/images.phash"     # "<64-bit-string>\t<path>" per pool image
PHASH_MAXDIST="${PHASH_MAXDIST:-6}"      # <= this many differing bits => same picture

ahash() {   # $1 = image file -> 64-char 0/1 string on stdout (nothing on failure)
  convert "$1" -alpha off -resize 8x8! -colorspace Gray -depth 8 txt:- 2>/dev/null \
    | grep -oP '(?:graya|gray)\(\K[0-9]+' \
    | awk '{v[NR]=$1; s+=$1} END{ if(NR<64) exit 1; m=s/NR; o="";
            for(i=1;i<=NR;i++) o=o (v[i]>m?"1":"0"); print o }'
}

# Keep the fingerprint index in step with the pool: drop entries whose file no
# longer exists (pruned/banned) and hash any pool image not yet indexed. Cheap
# in steady state (0-1 new files per fetch); the first run after upgrade pays a
# one-off cost to seed the existing pool.
sync_phash_index() {
  command -v convert >/dev/null 2>&1 || return 0
  local tmp="$PHASH_INDEX.tmp" h p
  : > "$tmp"
  if [ -f "$PHASH_INDEX" ]; then
    while IFS=$'\t' read -r h p; do
      [ -n "$p" ] && [ -f "$p" ] && printf '%s\t%s\n' "$h" "$p"
    done < "$PHASH_INDEX" >> "$tmp"
  fi
  mv "$tmp" "$PHASH_INDEX" 2>/dev/null
  # hash the un-indexed pool files (favourites included, so a re-serve of a
  # favourited picture is caught too)
  find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null \
    | grep -vxF -f <(cut -f2 "$PHASH_INDEX" 2>/dev/null) 2>/dev/null \
    | while IFS= read -r p; do
        h="$(ahash "$p")" && [ -n "$h" ] && printf '%s\t%s\n' "$h" "$p" >> "$PHASH_INDEX"
      done
}

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
    # Content-hash dedup: curated feeds re-serve the same picture for hours
    # (bing's 8-image daily archive especially), and every re-download used
    # to land as a NEW pool file under a fresh timestamped name -- by
    # 2026-06-05 13 of 84 pool files were byte-copies of just 4 pictures, so
    # the no-repeat shuffle-bag dutifully showed "different" entries that
    # were the same wallpaper. Hash the candidate against the existing pool
    # (favourites included) and discard matches. The "dup ... discarded" log
    # line is the future-verification hook: a healthy pool logs these often
    # while `md5sum pool/* | uniq -cd` stays empty.
    newsum="$(md5sum "$TMP" 2>/dev/null | cut -d' ' -f1)"
    if [ -n "$newsum" ]; then
      dupof="$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -print0 2>/dev/null \
               | xargs -0 md5sum 2>/dev/null | awk -v s="$newsum" '$1==s{print $2; exit}')"
      if [ -n "$dupof" ]; then
        log "[download] src=$src dup (md5 matches $(basename "$dupof")) -- discarded, trying next source"
        continue
      fi
    fi
    # Perceptual near-dup guard: same picture re-served at a different
    # resolution/quality/crop passes the md5 check above (different bytes) but
    # is caught here by aHash. Skipped entirely (md5-only) when ImageMagick is
    # unavailable. CAND is reused below to index the accepted image.
    CAND=""
    if command -v convert >/dev/null 2>&1; then
      sync_phash_index
      CAND="$(ahash "$TMP")"
      if [ -n "$CAND" ]; then
        pdup="$(awk -F'\t' -v c="$CAND" -v max="$PHASH_MAXDIST" '
          { d=0; n=length(c);
            for(i=1;i<=n;i++) if(substr(c,i,1)!=substr($1,i,1)) d++;
            if(d<=max){ print $2; exit } }' "$PHASH_INDEX" 2>/dev/null)"
        if [ -n "$pdup" ]; then
          log "[download] src=$src near-dup (phash <=$PHASH_MAXDIST bits of $(basename "$pdup")) -- discarded, trying next source"
          continue
        fi
      fi
    fi
    # AI generations carry provenance in the filename (.ai.jpg) so the
    # renderer can mark them subtly and the GUI can tag them — survives
    # moves to favourites/ with no manifest to maintain.
    ext="jpg"; [ "$src" = ai ] && ext="ai.jpg"
    DEST="$POOL/$(date +%s).$$.$ext"
    mv "$TMP" "$DEST"
    # Record the accepted image's fingerprint so future fetches dedup against it.
    [ -n "$CAND" ] && printf '%s\t%s\n' "$CAND" "$DEST" >> "$PHASH_INDEX"
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
