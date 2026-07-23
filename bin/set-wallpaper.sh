#!/bin/bash
# Set the desktop wallpaper across common Linux desktops.
# Usage: set-wallpaper.sh [/path/to/image]   (no arg = random image from the pool)
# Safe to call from cron: it re-establishes the session env (DISPLAY/DBUS) that
# cron jobs lack, and detects the desktop from running processes when
# XDG_CURRENT_DESKTOP is unset. @@POOL@@ and @@LOG@@ are substituted by install.sh.

POOL="@@POOL@@"
# Screen resolution (for overlay framing). @@RES@@ substituted by install.sh.
RES="@@RES@@"
[ "$RES" = "@@RES""@@" ] && RES=""

# Activity log (see install.sh). Fall back to the XDG state path when run from a
# raw checkout where @@LOG@@ wasn't substituted.
LOG="@@LOG@@"
# Split literal so install.sh's sed doesn't rewrite this guard too (see fetch-wallpaper.sh).
[ "$LOG" = "@@LOG""@@" ] && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

# Optional overlays are toggled from the web UI (wallpaper-web), which writes
# this config. @@CONFIG@@ substituted by install.sh.
CONFIG="@@CONFIG@@"
[ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
# Quote fetcher — re-run to pull a fresh batch when the shuffle-bag is exhausted.
FETCHQ="@@FETCHQ@@"
[ "$FETCHQ" = "@@FETCHQ""@@" ] && FETCHQ="$(dirname "$0")/fetch-quotes.sh"
# Overlay defaults (the web UI overwrites these in the config).
OVERLAY_QUOTE=0; OVERLAY_QUOTE_DETAIL=0; QUOTE_THEME=""; OVERLAY_STATS=0
QUOTE_POS=south; STATS_POS=northeast
OVERLAY_SIZE=medium; OVERLAY_THEME=light; OVERLAY_FONT=default
OVERLAY_STYLE=scrim
STATS_SPARKLINE=0
OVERLAY_WEATHER=0; WEATHER_POS=north; WEATHER_LOCATION=; OVERLAY_WEATHER_ICON=0
OVERLAY_WEATHER_ICON_COLOR=0; OVERLAY_WEATHER_FORECAST=0
OVERLAY_CLOCK=0; CLOCK_STYLE=digital; CLOCK_POS=northwest; CLOCK_24H=1; CLOCK_DATE=0
CLOCK_FACE=classic
OVERLAY_PULSE=0; PULSE_POS=east; PULSE_URL=""; PULSE_JQ="."; PULSE_TTL=5; PULSE_TITLE=""; PULSE_MAX=20
THEME=
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

STATEDIR="$(dirname "$LOG")"

# Print the installed version (CL-derived, stamped by install.sh) and exit.
# Done before the flock so a version query never waits on a render.
if [ "${1:-}" = "--version" ] || [ "${1:-}" = "-V" ]; then
  VERFILE="$STATEDIR/version"
  if [ -f "$VERFILE" ]; then
    # shellcheck disable=SC1090
    . "$VERFILE" 2>/dev/null
    echo "wallpaper-rotator ${WR_VERSION_ID:-unknown}${WR_VERSION_HOST:+ (authored on $WR_VERSION_HOST)}"
    [ -n "${WR_INSTALLED_AT:-}" ] && echo "installed ${WR_INSTALLED_AT}${WR_INSTALLED_ON:+ on $WR_INSTALLED_ON}"
  else
    echo "wallpaper-rotator version unknown (re-run install.sh to stamp it)"
  fi
  exit 0
fi

# Serialise runs: the rotate cron and the 1-min clock-refresh cron coincide every
# Nth minute and would otherwise double-render (wallpaper flicker) and race on the
# quote bag. Non-blocking — if another run holds the lock, skip this tick. Falls
# through harmlessly if flock is unavailable.
if command -v flock >/dev/null 2>&1 && exec 9>"$STATEDIR/.setwp.lock" 2>/dev/null; then
  flock -n 9 || exit 0
fi

# Map a config position token to an ImageMagick -gravity value ($2 = default).
imgrav() {
  case "$1" in
    northwest) echo NorthWest;; north) echo North;; northeast) echo NorthEast;;
    west) echo West;; center) echo Center;; east) echo East;;
    southwest) echo SouthWest;; south) echo South;; southeast) echo SouthEast;;
    *) echo "$2";;
  esac
}

# Build the shuffle-bag from the quote cache, EXCLUDING quotes already shown
# (tracked by text in $2). Keeps a re-downloaded batch from repeating earlier
# quotes. If everything known has been seen, the history resets so we can cycle
# again rather than run dry.
build_quote_bag() {  # $1=cache $2=seen $3=bag
  local cache="$1" seen="$2" bag="$3" pool="$cache"
  # QUOTE_THEME: keep only quotes whose tags field (5th — populated by the
  # bulk seed from the Quotes-500K categories) mentions the theme. Substring
  # match, so "inspirational" also catches "inspirational-quotes". Falls back
  # to the whole cache when nothing matches (e.g. unseeded cache).
  if [ -n "${QUOTE_THEME:-}" ]; then
    awk -F'|' -v t="$QUOTE_THEME" 'index(tolower($5), t)' "$cache" > "$bag.pool" 2>/dev/null
    [ -s "$bag.pool" ] && pool="$bag.pool"
  fi
  if [ -s "$seen" ]; then
    awk -F'|' 'NR==FNR{s[$0]=1; next} !($1 in s)' "$seen" "$pool" | shuf > "$bag" 2>/dev/null
  else
    shuf "$pool" > "$bag" 2>/dev/null
  fi
  if [ ! -s "$bag" ]; then            # every known quote already seen -> reset + cycle
    : > "$seen"
    shuf "$pool" > "$bag" 2>/dev/null
  fi
  rm -f "$bag.pool"
}

# A quote for the overlay. With detail, append attribution (author, source, year)
# from the bundled list. Without detail, `fortune -s` is used if installed.
pick_quote() {
  local detail="${1:-0}"
  # Prefer the API cache (text|author||) refreshed by fetch-quotes.sh, so quotes
  # keep changing; fall back to fortune (non-detail) then the bundled list.
  # Shuffle-BAG, not a random pick: draw quotes from a shuffled queue so none
  # repeats until every quote has been shown. When the bag is EXHAUSTED, download a
  # FRESH batch (fetch-quotes.sh) for the next bag. A persistent "seen" list (quote
  # texts already shown) filters every new bag, so a re-download — which overlaps
  # with earlier batches — never re-shows a quote until the whole known set is
  # exhausted, at which point the seen list resets. (Plain `shuf -n1` repeated all
  # day by chance.)
  local cache="$STATEDIR/quotes.cache" bag="$STATEDIR/quotes.bag" seen="$STATEDIR/quotes.seen" line=""
  local tmark="$STATEDIR/quotes.bag.theme"
  # Quote-linked AI image: fetch-wallpaper generated this image FROM a quote
  # and left it in a "<image>.quote" sidecar — show that quote, not a bag
  # draw. Mark it seen and pull it from the bag so it doesn't come round
  # again as an unlinked repeat.
  if [ -n "${ORIG:-}" ] && [ -s "$ORIG.quote" ]; then
    line="$(head -n1 "$ORIG.quote" 2>/dev/null)"
    if [ -n "$line" ]; then
      printf '%s\n' "${line%%|*}" >> "$seen"
      if [ -f "$bag" ] && grep -qF "$line" "$bag" 2>/dev/null; then
        grep -vF "$line" "$bag" > "$bag.tmp" 2>/dev/null && mv "$bag.tmp" "$bag" 2>/dev/null
      fi
    fi
  fi
  if [ -z "$line" ] && [ -s "$cache" ]; then
    if [ "$(cat "$tmark" 2>/dev/null)" != "${QUOTE_THEME:-}" ]; then
      printf '%s' "${QUOTE_THEME:-}" > "$tmark"     # theme changed (web UI) -> rebuild bag to match
      build_quote_bag "$cache" "$seen" "$bag"
    elif [ ! -e "$bag" ] || [ "$cache" -nt "$bag" ]; then
      build_quote_bag "$cache" "$seen" "$bag"       # first build, or cache refreshed by the daily cron
    elif [ ! -s "$bag" ]; then
      "$FETCHQ" >/dev/null 2>&1 || true             # bag empty = every quote shown -> pull a new batch
      build_quote_bag "$cache" "$seen" "$bag"
    fi
    line="$(head -n1 "$bag" 2>/dev/null)"
    tail -n +2 "$bag" > "$bag.tmp" 2>/dev/null && mv "$bag.tmp" "$bag" 2>/dev/null
    if [ -n "$line" ]; then                         # record as seen (by text), bounded to recent history
      printf '%s\n' "${line%%|*}" >> "$seen"
      # bound must exceed the seeded cache (fetch-quotes --seed, ~30k) or the
      # history would wrap mid-cycle and let early quotes repeat
      tail -n 60000 "$seen" > "$seen.tmp" 2>/dev/null && mv "$seen.tmp" "$seen" 2>/dev/null
    fi
  fi
  if [ -z "$line" ]; then
    if [ "$detail" != 1 ] && command -v fortune >/dev/null 2>&1; then
      fortune -s 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c1-160
      return
    fi
    line=""
  fi
  if [ -n "$line" ]; then
    local text author source year tags
    # 5th field = category tags (bulk seed) — read it so it can't spill into
    # year and show up in the attribution
    IFS='|' read -r text author source year tags <<< "$line"
    if [ "$detail" = 1 ] && [ -n "$author" ]; then
      local attr="$author"; [ -n "$source" ] && attr="$attr, $source"; [ -n "$year" ] && attr="$attr ($year)"
      printf '%s\n— %s' "$text" "$attr"
    else
      printf '%s' "$text"
    fi
    return
  fi
  # text | author | source | year
  local list=(
    "The best way to predict the future is to invent it.|Alan Kay||1971"
    "Simplicity is the ultimate sophistication.|Leonardo da Vinci||"
    "What we do in life echoes in eternity.|Marcus Aurelius|Meditations|~170 AD"
    "The journey of a thousand miles begins with one step.|Lao Tzu|Tao Te Ching|~6th c. BC"
    "Stay hungry, stay foolish.|Steve Jobs|Stanford commencement|2005"
    "Less, but better.|Dieter Rams||"
    "The obstacle is the way.|Marcus Aurelius|Meditations|~170 AD"
    "We are what we repeatedly do.|Will Durant|The Story of Philosophy|1926"
    "The unexamined life is not worth living.|Socrates|Apology (Plato)|~399 BC"
    "It always seems impossible until it's done.|Nelson Mandela||"
  )
  local text author source year pick
  pick="${list[$((RANDOM % ${#list[@]}))]}"
  IFS='|' read -r text author source year <<< "$pick"
  if [ "$detail" = 1 ] && [ -n "$author" ]; then
    local attr="$author"
    [ -n "$source" ] && attr="$attr, $source"
    [ -n "$year" ] && attr="$attr ($year)"
    printf '%s\n— %s' "$text" "$attr"
  else
    printf '%s' "$text"
  fi
}

# Map a wttr.in condition string to a monochrome weather glyph the overlay font
# (DejaVu Sans) actually contains — verified present: ☀ ☁ ☼ ❄ ⚡ ☔ (⛅ is NOT in
# DejaVu, renders as tofu, so partly-cloudy uses ☼). Order matters: check
# 'partly' before the generic 'cloud'.
weather_icon() {
  local c; c="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$c" in
    *thunder*|*storm*)                      printf '⚡' ;;
    *snow*|*sleet*|*blizzard*|*ice*)        printf '❄' ;;
    *rain*|*drizzle*|*shower*)              printf '☔' ;;
    *partly*)                               printf '☼' ;;
    *overcast*|*cloud*|*fog*|*mist*|*haze*) printf '☁' ;;
    *clear*|*sunny*)                        printf '☀' ;;
    *)                                      printf '☼' ;;
  esac
}

# Characteristic colour for each weather glyph (used only when coloured icons are
# enabled). Same condition buckets as weather_icon().
weather_icon_color() {
  local c; c="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$c" in
    *thunder*|*storm*)                      printf '#ffe14d' ;;  # yellow
    *snow*|*sleet*|*blizzard*|*ice*)        printf '#dff1ff' ;;  # pale blue
    *rain*|*drizzle*|*shower*)              printf '#5aa9e6' ;;  # blue
    *partly*)                               printf '#ffd27f' ;;  # soft amber
    *overcast*|*cloud*|*fog*|*mist*|*haze*) printf '#cfd8e3' ;;  # light grey
    *clear*|*sunny*)                        printf '#ffd23f' ;;  # gold
    *)                                      printf '#ffd27f' ;;
  esac
}

# Local weather via wttr.in (no key); cached ~1h so we don't hammer it. Cached as
# structured fields ("loc|condition|metrics") so the location can be title-cased
# and the icon toggled at render time without re-fetching. Outputs three TAB-
# separated fields: "glyph<TAB>colour<TAB>text" (glyph/colour empty when the icon
# is off) so the caller can render a COLOURED icon separately from the text.
weather_line() {
  local cache="$STATEDIR/weather.txt" loc="${WEATHER_LOCATION:-}"
  # Refresh if missing, >60min old, OR in the pre-structured legacy format (no '|')
  # — so a cache left over from an older version self-heals on upgrade.
  # .fail marker = 10-min backoff after a failed fetch. Without it a flaky/down
  # wttr.in is re-attempted INLINE on every render (the cache mtime never moves),
  # taxing each rotate with up to 12s of curl (seen 2026-06-05 on Fam3).
  if { [ ! -f "$cache" ] || find "$cache" -mmin +60 2>/dev/null | grep -q . \
       || ! grep -q '|' "$cache" 2>/dev/null; } \
     && ! find "$cache.fail" -mmin -10 2>/dev/null | grep -q .; then
    if curl -fsL --max-time 12 "https://wttr.in/${loc// /+}?format=%l|%C|%t,+%h,+%w" \
         -o "$cache.new" 2>>"$LOG" && [ -s "$cache.new" ]; then
      mv "$cache.new" "$cache"; rm -f "$cache.fail"
    else
      rm -f "$cache.new"; touch "$cache.fail"
    fi
  fi
  local raw wl wc wm glyph="" color=""
  raw="$(cat "$cache" 2>/dev/null)"; [ -n "$raw" ] || return 0
  case "$raw" in
    *"|"*) : ;;                                  # new structured format
    *) printf '\t\t%s' "$raw"; return 0 ;;       # legacy single-line cache: text only
  esac
  IFS='|' read -r wl wc wm <<< "$raw"
  wc="${wc%"${wc##*[![:space:]]}"}"   # wttr's %C carries a trailing space -> trim it
  # Title-case the location ("shoreham" -> "Shoreham", "new york" -> "New York").
  wl="$(printf '%s' "$wl" | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')"
  if [ "${OVERLAY_WEATHER_ICON:-0}" = 1 ]; then
    glyph="$(weather_icon "$wc")"; color="$(weather_icon_color "$wc")"
  fi
  printf '%s\t%s\t%s: %s %s' "$glyph" "$color" "$wl" "$wc" "$wm"
}

# 3-day daily forecast from wttr.in's JSON (j1), cached ~3h (forecasts move
# slowly). Cached STRUCTURED — one day per line, "label<TAB>condition<TAB>hi<TAB>lo"
# — so the renderer can colour each day's glyph (and the colour toggle applies at
# render time without re-fetching). Returns the structured text (empty if none).
# Needs jq.
weather_forecast() {
  local cache="$STATEDIR/forecast.struct" raw="$STATEDIR/forecast.raw" loc="${WEATHER_LOCATION:-}"
  command -v jq >/dev/null 2>&1 || return 0
  # raw holds "date|hi|lo|condition" straight from the API, cached ~3h — but
  # only ~30min while its first day is already in the past (wttr.in serves
  # yesterday-led data pre-rollover early in the morning), so the dropped-day
  # 2-day display recovers to 3 days soon after the API catches up.
  local ttl=180 today; today="$(date +%F)"
  [ -f "$raw" ] && [[ "$(head -c10 "$raw" 2>/dev/null)" < "$today" ]] && ttl=30
  # Same 10-min failure backoff as weather_line (15s inline curl otherwise).
  if { [ ! -f "$raw" ] || find "$raw" -mmin +$ttl 2>/dev/null | grep -q .; } \
     && ! find "$raw.fail" -mmin -10 2>/dev/null | grep -q .; then
    if curl -fsL --max-time 15 "https://wttr.in/${loc// /+}?format=j1" -o "$cache.json" 2>>"$LOG" && [ -s "$cache.json" ]; then
      jq -r '.weather[0:3][] | "\(.date)|\(.maxtempC)|\(.mintempC)|\(.hourly[4].weatherDesc[0].value)"' "$cache.json" 2>/dev/null > "$raw.tmp"
      [ -s "$raw.tmp" ] && { mv "$raw.tmp" "$raw"; rm -f "$raw.fail"; }
    else
      touch "$raw.fail"
    fi
    rm -f "$cache.json" "$raw.tmp"
  fi
  # Label at RENDER time, not fetch time: wttr.in's weather[0] can still be
  # YESTERDAY early in the morning (its data generation lags), and a "Today"
  # baked into a 3h cache goes stale across midnight. Compare each day's real
  # date to the current date — past days are DROPPED, today gets "Today",
  # the rest get their weekday name. (Caught on Fam1 2026-06-04: showed
  # "Today Thu Fri" on a Thursday.)
  local d hi lo desc dn
  while IFS='|' read -r d hi lo desc; do
    [ -n "$d" ] || continue
    [[ "$d" < "$today" ]] && continue
    if [ "$d" = "$today" ]; then dn="Today"; else dn="$(date -d "$d" +%a 2>/dev/null || echo "$d")"; fi
    printf '%s\t%s\t%s\t%s\n' "$dn" "$desc" "$hi" "$lo"
  done < "$raw" 2>/dev/null > "$cache.tmp"
  if [ -s "$cache.tmp" ]; then mv "$cache.tmp" "$cache"; else rm -f "$cache.tmp"; fi
  cat "$cache" 2>/dev/null
}

IMG="${1:-}"
if [ -z "$IMG" ]; then
  # Shuffle-BAG pick, mirroring the quote overlay's no-repeat mechanism: images
  # are drawn from a shuffled queue (images.bag) and recorded in images.seen,
  # so NO image repeats until every pool image has shown once — plain
  # `shuf -n1` from a ~30-60 image pool produced obvious deja vu well inside a
  # cycle (and could even repeat back-to-back). When the unseen set runs dry,
  # the seen list resets and a fresh full shuffle starts. New downloads join
  # at the next bag rebuild; pruned files are skipped at pop time (the pool
  # churns under the bag). Single-image pools degrade gracefully: bag of one,
  # reset every pick.
  IBAG="$STATEDIR/images.bag"; ISEEN="$STATEDIR/images.seen"
  pool_list() { find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null; }
  build_image_bag() {
    if [ -s "$ISEEN" ]; then
      pool_list | grep -vxF -f "$ISEEN" | shuf > "$IBAG" 2>/dev/null
    else
      pool_list | shuf > "$IBAG" 2>/dev/null
    fi
    if [ ! -s "$IBAG" ]; then       # every pool image already seen -> reset + recycle
      : > "$ISEEN"
      pool_list | shuf > "$IBAG" 2>/dev/null
    fi
  }
  [ -s "$IBAG" ] || build_image_bag
  # Pop until we hit a file that still exists (prune may have removed entries).
  while [ -z "$IMG" ] && [ -s "$IBAG" ]; do
    IMG="$(head -n1 "$IBAG" 2>/dev/null)"
    tail -n +2 "$IBAG" > "$IBAG.tmp" 2>/dev/null && mv "$IBAG.tmp" "$IBAG" 2>/dev/null
    [ -f "$IMG" ] || IMG=""
    if [ -z "$IMG" ] && [ ! -s "$IBAG" ]; then build_image_bag; fi
  done
  if [ -n "$IMG" ]; then            # record as seen, bounded to recent history
    printf '%s\n' "$IMG" >> "$ISEEN"
    # Cap must exceed POOL_MAX (default 5000) or the no-repeat guarantee breaks:
    # when the bag drains, it rebuilds from `pool minus seen`, and if seen has
    # forgotten images shown earlier this cycle they'd resurface before the
    # cycle truly ends. 50000 covers a very large pool with room to spare and a
    # trimmed 50k-line path list is still tiny. (Was 500 — fine only while the
    # pool was hard-capped at 60; that cap is now POOL_MAX.)
    tail -n 50000 "$ISEEN" > "$ISEEN.tmp" 2>/dev/null && mv "$ISEEN.tmp" "$ISEEN" 2>/dev/null
  fi
  # Belt-and-braces: never end up with nothing while the pool has images.
  [ -z "$IMG" ] && IMG="$(pool_list | shuf -n 1)"
fi
[ -z "$IMG" ] && { log "[rotate] skip (empty pool)"; exit 0; }
[ -f "$IMG" ] || { log "[rotate] skip (missing file: $IMG)"; exit 0; }

# Remember the current pool original so the web UI can RE-apply the same image
# with changed overlay settings (Apply re-renders, doesn't shuffle the picture).
ORIG="$IMG"
printf '%s\n' "$ORIG" > "$(dirname "$LOG")/current" 2>/dev/null

# Overlays: composite quote and/or system stats onto a COPY of the pool image so
# the original stays clean. The derived file gets a UNIQUE name each tick — a
# constant path wouldn't repaint (KDE caches by path), and stats must stay live.
OVERLAYS=""
if { [ "${OVERLAY_QUOTE:-0}" = 1 ] || [ "${OVERLAY_STATS:-0}" = 1 ] || [ "${OVERLAY_WEATHER:-0}" = 1 ] || [ "${OVERLAY_CLOCK:-0}" = 1 ]; } \
     && command -v convert >/dev/null 2>&1; then
  RDIR="$STATEDIR/rendered"; mkdir -p "$RDIR"
  RENDER="$RDIR/$(date +%s).$$.jpg"
  # Frame the base at the SCREEN resolution first (crop-to-fill) so overlays land
  # where they're actually visible. Otherwise the DE crop-fills the source image
  # and the overlays get pushed off-screen.
  if { [ -n "$RES" ] && convert "$IMG" -resize "${RES}^" -gravity center -extent "$RES" "$RENDER" 2>>"$LOG"; } \
       || cp "$IMG" "$RENDER" 2>>"$LOG"; then
    # OVERLAY_STYLE selects the visual treatment; the per-overlay enable toggles,
    # positions (QUOTE_POS/STATS_POS/WEATHER_POS), OVERLAY_SIZE, OVERLAY_THEME
    # (text colour) and OVERLAY_FONT (override) still apply. Styles:
    #   scrim     - gradient wash top/bottom + drop-shadowed text (no box)
    #   frosted   - blurred "glass" rounded card behind each block + hairline border
    #   editorial - bottom gradient + bold left-aligned text + accent bar, shadow
    #   chips     - flat translucent rounded chip behind each block
    STYLE="${OVERLAY_STYLE:-scrim}"
    ACCENT='#7cc4ff'
    case "$OVERLAY_SIZE" in small) BASEPS=20;; large) BASEPS=34;; *) BASEPS=27;; esac
    # OVERLAY_THEME names the TEXT colour (the control is labelled "Text"):
    # dark = black text, light = white text. It used to mean the UI-theme sense
    # (dark theme -> white text), which read backwards in the GUI (Fam1 2026-06-04).
    case "$OVERLAY_THEME" in dark) TXT=black;; accent) TXT="$ACCENT";; *) TXT=white;; esac
    CW=$(identify -format '%w' "$RENDER" 2>/dev/null); [ -n "$CW" ] || CW="${RES%x*}"
    CH=$(identify -format '%h' "$RENDER" 2>/dev/null); [ -n "$CH" ] || CH="${RES#*x}"
    FONT_OVERRIDE=""
    [ "${OVERLAY_FONT:-default}" != default ] && [ -n "${OVERLAY_FONT:-}" ] \
      && convert -list font 2>/dev/null | grep -q "Font: ${OVERLAY_FONT}$" && FONT_OVERRIDE="$OVERLAY_FONT"

    role_font() {  # $1=role -> font; style picks the aesthetic unless user overrode
      if [ -n "$FONT_OVERRIDE" ]; then printf '%s' "$FONT_OVERRIDE"; return; fi
      case "$STYLE:$1" in
        frosted:quote) echo FreeSerif-Italic;;
        editorial:*)   echo DejaVu-Sans-Bold;;
        *:stats)       echo DejaVu-Sans-Mono;;
        *)             echo DejaVu-Sans;;
      esac
    }
    # Absolute top-left of a WxH block at an IM gravity, inset from the edges.
    coords() {  # $1=gravity $2=w $3=h -> sets OX OY
      local g="$1" bw="$2" bh="$3" ins=44 mb=72
      case "$g" in *East) OX=$((CW-bw-ins));; *West) OX=$ins;; *) OX=$(((CW-bw)/2));; esac
      case "$g" in South*) OY=$((CH-bh-mb));; North*) OY=$ins;; *) OY=$(((CH-bh)/2));; esac
      [ "$OX" -lt 0 ] && OX=0; [ "$OY" -lt 0 ] && OY=0
    }
    # Overlays are positioned independently, so two anchors can collide (e.g.
    # weather=north running into stats=northeast). After coords(), nudge this block
    # along its anchored axis (North*/centre -> down, South* -> up) until it clears
    # every already-placed block, then record its footprint in PLACED. PAD covers
    # the largest style panel (frosted: bw+68/bh+44) so panels clear, not just text.
    PLACED=()
    avoid() {  # $1=gravity ; reads bw/bh/OX, adjusts OY, appends to PLACED
      local g="$1" pad=36 gap=14 tries=0 r rx ry rw rh hit oy0="$OY"
      local x=$((OX-pad)) y=$((OY-pad)) w=$((bw+2*pad)) h=$((bh+2*pad)) dir=1
      case "$g" in South*) dir=-1;; esac
      while [ "$tries" -lt 40 ]; do
        hit=0
        for r in "${PLACED[@]}"; do
          set -- $r; rx=$1; ry=$2; rw=$3; rh=$4
          if [ "$x" -lt $((rx+rw)) ] && [ $((x+w)) -gt "$rx" ] \
             && [ "$y" -lt $((ry+rh)) ] && [ $((y+h)) -gt "$ry" ]; then
            if [ "$dir" -gt 0 ]; then y=$((ry+rh+gap)); else y=$((ry-h-gap)); fi
            hit=1; break
          fi
        done
        [ "$hit" -eq 0 ] && break
        tries=$((tries+1))
      done
      OY=$((y+pad))
      # If clearing every placed block walked us off-screen (tall block on a
      # crowded axis), do NOT clamp onto the opposite edge — that teleports a
      # southeast block to the top, straight over whatever is anchored there
      # (sectioned pulse vs northeast stats). Revert to the configured anchor
      # and accept the residual overlap — it is usually pad-vs-pad only.
      if [ "$OY" -lt 0 ] || [ $((OY+bh)) -gt "$CH" ]; then OY="$oy0"; fi
      PLACED+=("$x $((OY-pad)) $w $h")   # x unchanged by the nudge; y follows OY
    }
    mktext() {  # out font ps fill width align text -> wrapped transparent PNG
      # caption: pads to the FULL -size width even when the text is far narrower,
      # leaving dead space inside panels (stats was ~68% empty). -trim crops the
      # block to its actual text bbox so panels hug the content; the width arg
      # still bounds wrapping. +repage resets the virtual canvas after the crop.
      convert -background none -font "$2" -pointsize "$3" -fill "$4" -size "${5}x" \
        -gravity "$6" caption:"$7" -trim +repage "$1" 2>>"$LOG"
    }
    # Accent line+area sparkline (drawn, anti-aliased) from a space-separated
    # series -> PNG at $1. Height tracks the pointsize ($3). Fill is ACCENT at low
    # opacity. Needs >=2 samples, else returns non-zero so the caller omits it.
    draw_spark() {  # $1=out $2=series $3=pointsize
      local out="$1" series="$2" ps="${3:-18}" w=140 h pts area
      h=$(( ps + 2 )); [ "$h" -lt 12 ] && h=12
      IFS=$'\t' read -r pts area < <(awk -v s="$series" -v w="$w" -v h="$h" 'BEGIN{
        n=split(s,a," "); if(n<2) exit;
        mn=a[1];mx=a[1]; for(i=1;i<=n;i++){if(a[i]<mn)mn=a[i];if(a[i]>mx)mx=a[i]} r=mx-mn; if(r==0)r=1;
        pad=2; us=h-2*pad; line="";
        for(i=1;i<=n;i++){x=(i-1)*(w-1)/(n-1); y=pad+us-((a[i]-mn)/r)*us; line=line sprintf("%.1f,%.1f ",x,y)}
        printf "%s\t0,%d %s%d,%d", line, h-1, line, w-1, h-1 }')
      [ -n "$pts" ] || return 1
      convert -size ${w}x${h} xc:none \
        -fill "rgba(124,196,255,0.22)" -stroke none -draw "polygon $area" \
        -fill none -stroke "$ACCENT" -strokewidth 1.4 -draw "polyline $pts" \
        "$out" 2>>"$LOG" || return 1
    }
    # One stats line -> fixed-height ($5), left-aligned, text-colour label PNG, so
    # lines (incl. ones with a sparkline appended) stack with even spacing.
    stat_label() {  # $1=out $2=text $3=font $4=ps $5=lineheight
      convert -background none -font "$3" -pointsize "$4" -fill "$TXT" \
        label:"$2" -trim +repage -background none -gravity West -extent "x$5" "$1" 2>>"$LOG"
    }
    # Analogue clock face -> transparent PNG at $1, diameter $2, for time $3:$4
    # (H M). CLOCK_FACE picks the face: classic (ring + 12 ticks), minimal
    # (quarter ticks only), dots (12 dots, larger at quarters), numbers
    # (12/3/6/9 numerals, ticks elsewhere). Hands + accent centre pin are
    # common to all. Built as one MVG -draw program (colours single-quoted so
    # '#' isn't an MVG comment; gravity is reset to NorthWest after the
    # numeral placement so the hands' absolute coords stay top-left-relative).
    draw_clock() {  # $1=out $2=diameter $3=hour $4=min
      local out="$1" d="$2" H="$3" M="$4" face="${CLOCK_FACE:-classic}" prog
      prog="$(awk -v d="$d" -v H="$H" -v M="$M" -v col="$TXT" -v acc="$ACCENT" -v face="$face" 'BEGIN{
        pi=3.14159265; cx=d/2; cy=d/2; R=cx-3;
        printf "stroke-linecap round stroke %c%s%c fill none stroke-width 2 ", 39,col,39;
        printf "circle %.1f,%.1f %.1f,%.1f ", cx,cy, cx, cy-R;
        if(face=="minimal"){
          for(i=0;i<12;i+=3){a=i/12*2*pi-pi/2; printf "line %.1f,%.1f %.1f,%.1f ",
            cx+0.88*R*cos(a),cy+0.88*R*sin(a), cx+0.97*R*cos(a),cy+0.97*R*sin(a)}
        } else if(face=="dots"){
          printf "stroke none fill %c%s%c ", 39,col,39;
          for(i=0;i<12;i++){a=i/12*2*pi-pi/2; r=(i%3==0)?0.055*R:0.032*R; if(r<1.6)r=1.6;
            px=cx+0.90*R*cos(a); py=cy+0.90*R*sin(a);
            printf "circle %.1f,%.1f %.1f,%.1f ", px,py, px,py+r}
          printf "stroke %c%s%c fill none ", 39,col,39;
        } else if(face=="numbers"){
          for(i=0;i<12;i++){ if(i%3==0) continue; a=i/12*2*pi-pi/2; printf "line %.1f,%.1f %.1f,%.1f ",
            cx+0.90*R*cos(a),cy+0.90*R*sin(a), cx+0.97*R*cos(a),cy+0.97*R*sin(a)}
          printf "stroke none fill %c%s%c ", 39,col,39;
          printf "gravity North text 0,%.1f %c12%c gravity South text 0,%.1f %c6%c ", 0.055*d,39,39, 0.055*d,39,39;
          printf "gravity East text %.1f,0 %c3%c gravity West text %.1f,0 %c9%c ", 0.055*d,39,39, 0.055*d,39,39;
          printf "gravity NorthWest stroke %c%s%c fill none ", 39,col,39;
        } else {
          for(i=0;i<12;i++){a=i/12*2*pi-pi/2; printf "line %.1f,%.1f %.1f,%.1f ",
            cx+0.86*R*cos(a),cy+0.86*R*sin(a), cx+0.97*R*cos(a),cy+0.97*R*sin(a)}
        }
        ha=((H%12)+M/60)/12*2*pi-pi/2; printf "stroke-width 3 line %.1f,%.1f %.1f,%.1f ",
          cx,cy, cx+0.50*R*cos(ha),cy+0.50*R*sin(ha);
        ma=(M/60)*2*pi-pi/2; printf "stroke-width 2 line %.1f,%.1f %.1f,%.1f ",
          cx,cy, cx+0.74*R*cos(ma),cy+0.74*R*sin(ma);
        printf "stroke none fill %c%s%c circle %.1f,%.1f %.1f,%.1f", 39,acc,39, cx,cy, cx,cy+3.2 }')"
      convert -size "${d}x${d}" xc:none -font DejaVu-Sans -pointsize "$(( d / 7 ))" -draw "$prog" "$out" 2>>"$LOG"
    }
    # Compose the forecast line PNG from the structured cache so each day's glyph
    # can take its CONDITION COLOUR (when OVERLAY_WEATHER_ICON_COLOR=1; else the
    # text colour). Each day = "label " + glyph + " hi/lo", days joined by " · ",
    # appended horizontally and vertically centred. Reads $STATEDIR/forecast.struct.
    build_forecast_strip() {  # $1=out $2=pointsize
      local out="$1" fps="$2" struct="$STATEDIR/forecast.struct"
      [ -s "$struct" ] || return 1
      local fd="$STATEDIR/_fc.$$"; mkdir -p "$fd"
      # -trim drops whitespace, so explicit transparent spacers (not spaces in the
      # labels) provide the gaps; widths scale with the font size.
      local g=$(( fps*2/5 )); [ "$g" -lt 5 ] && g=5; local gs=$(( fps )); [ "$gs" -lt 10 ] && gs=10
      convert -size "${g}x1"  xc:none "$fd/g.png"  2>>"$LOG"
      convert -size "${gs}x1" xc:none "$fd/gs.png" 2>>"$LOG"
      convert -background none -font DejaVu-Sans -pointsize "$fps" -fill "$TXT" label:"·" -trim +repage "$fd/sep.png" 2>>"$LOG"
      local n=0 label cond hi lo glyph gcol
      while IFS=$'\t' read -r label cond hi lo; do
        [ -n "$label" ] || continue
        glyph="$(weather_icon "$cond")"
        if [ "${OVERLAY_WEATHER_ICON_COLOR:-0}" = 1 ]; then gcol="$(weather_icon_color "$cond")"; else gcol="$TXT"; fi
        convert -background none -font DejaVu-Sans -pointsize "$fps" -fill "$TXT"  label:"$label"      -trim +repage "$fd/${n}a.png" 2>>"$LOG"
        convert -background none -font DejaVu-Sans -pointsize "$fps" -fill "$gcol" label:"$glyph"      -trim +repage "$fd/${n}b.png" 2>>"$LOG"
        convert -background none -font DejaVu-Sans -pointsize "$fps" -fill "$TXT"  label:"${hi}/${lo}" -trim +repage "$fd/${n}c.png" 2>>"$LOG"
        n=$((n+1))
      done < "$struct"
      [ "$n" -gt 0 ] || { rm -rf "$fd"; return 1; }
      local args=() i=0
      while [ "$i" -lt "$n" ]; do
        [ "$i" -gt 0 ] && args+=("$fd/gs.png" "$fd/sep.png" "$fd/gs.png")
        args+=("$fd/${i}a.png" "$fd/g.png" "$fd/${i}b.png" "$fd/g.png" "$fd/${i}c.png")
        i=$((i+1))
      done
      convert "${args[@]}" -background none -gravity center +append "$out" 2>>"$LOG"
      rm -rf "$fd"
      [ -s "$out" ]
    }
    # Position + style a READY-MADE block PNG ($3) onto RENDER at gravity $1 (role
    # $2 selects minor tweaks). Shared by emit() (text/icon blocks) and the stats
    # builder (text + drawn sparklines).
    style_block() {  # $1=gravity $2=role $3=block.png
      local g="$1" role="$2" t="$3" bw bh PX PY PW PH rad
      bw=$(identify -format '%w' "$t" 2>/dev/null); bh=$(identify -format '%h' "$t" 2>/dev/null)
      [ -n "$bw" ] && [ -n "$bh" ] || { rm -f "$t"; return 1; }
      coords "$g" "$bw" "$bh"
      avoid "$g"
      case "$STYLE" in
        frosted)
          PX=$((OX-34)); PY=$((OY-22)); PW=$((bw+68)); PH=$((bh+44))
          [ "$PX" -lt 0 ] && PX=0; [ "$PY" -lt 0 ] && PY=0
          [ $((PX+PW)) -gt "$CW" ] && PW=$((CW-PX)); [ $((PY+PH)) -gt "$CH" ] && PH=$((CH-PY))
          convert "$RENDER" -crop ${PW}x${PH}+${PX}+${PY} +repage -colorspace sRGB -type TrueColor \
            -blur 0x14 -brightness-contrast -42x4 "$STATEDIR/_cb.png" 2>>"$LOG"
          convert -size ${PW}x${PH} xc:none -draw "roundrectangle 0,0,$((PW-1)),$((PH-1)),24,24" "$STATEDIR/_cm.png" 2>>"$LOG"
          convert "$STATEDIR/_cb.png" "$STATEDIR/_cm.png" -alpha off -compose CopyOpacity -composite \
            -fill "rgba(0,0,0,0.46)" -draw "roundrectangle 0,0,$((PW-1)),$((PH-1)),24,24" "$STATEDIR/_cd.png" 2>>"$LOG"
          convert "$RENDER" "$STATEDIR/_cd.png" -geometry +${PX}+${PY} -composite \
            -fill none -stroke "rgba(255,255,255,0.26)" -strokewidth 1 \
            -draw "roundrectangle ${PX},${PY},$((PX+PW-1)),$((PY+PH-1)),24,24" \
            "$t" -geometry +${OX}+${OY} -composite "$RENDER" 2>>"$LOG"
          rm -f "$STATEDIR/_cb.png" "$STATEDIR/_cm.png" "$STATEDIR/_cd.png"
          ;;
        chips)
          PX=$((OX-32)); PY=$((OY-20)); PW=$((bw+64)); PH=$((bh+40)); rad=18
          [ "$PX" -lt 0 ] && PX=0; [ "$PY" -lt 0 ] && PY=0
          [ "$role" = weather ] && rad=$((PH/2))
          convert "$RENDER" \( -size ${PW}x${PH} xc:none -fill "rgba(18,22,30,0.62)" \
            -draw "roundrectangle 0,0,$((PW-1)),$((PH-1)),${rad},${rad}" \) -geometry +${PX}+${PY} -composite \
            "$t" -geometry +${OX}+${OY} -composite "$RENDER" 2>>"$LOG"
          ;;
        editorial)
          convert "$t" -fill black -colorize 100 -channel A -blur 0x3 +channel "$STATEDIR/_sh.png" 2>>"$LOG"
          convert "$RENDER" "$STATEDIR/_sh.png" -geometry +$((OX+2))+$((OY+2)) -composite \
            "$t" -geometry +${OX}+${OY} -composite \
            -fill "$ACCENT" -draw "roundrectangle $((OX-22)),${OY} $((OX-16)),$((OY+bh)) 3,3" "$RENDER" 2>>"$LOG"
          rm -f "$STATEDIR/_sh.png"
          ;;
        *)  # scrim
          convert "$t" -fill black -colorize 100 -channel A -blur 0x4 +channel "$STATEDIR/_sh.png" 2>>"$LOG"
          convert "$RENDER" "$STATEDIR/_sh.png" -geometry +$((OX+2))+$((OY+2)) -composite \
            "$t" -geometry +${OX}+${OY} -composite "$RENDER" 2>>"$LOG"
          rm -f "$STATEDIR/_sh.png"
          ;;
      esac
      rm -f "$t"
    }
    emit() {  # $1=gravity $2=role $3=text [$4=icon glyph $5=icon colour]
      #         Build a text block (optional coloured icon prepended) then style it.
      local g="$1" role="$2" txt="$3" icon="${4:-}" icol="${5:-}" f ps align maxw t
      f="$(role_font "$role")"
      case "$role" in quote) ps=$BASEPS;; *) ps=$(( BASEPS * 3 / 4 ));; esac
      case "$STYLE" in
        editorial) align=West;;
        scrim) case "$g" in *East) align=East;; *West) align=West;; *) align=Center;; esac;;
        *) align=West;;
      esac
      if [ "$role" = quote ]; then maxw=$(( CW * 60 / 100 )); else maxw=$(( CW * 44 / 100 )); fi
      t="$STATEDIR/_ovl.$$.png"
      mktext "$t" "$f" "$ps" "$TXT" "$maxw" "$align" "$txt" || { rm -f "$t"; return 1; }
      # Coloured icon: render the glyph in its own colour (DejaVu-Sans has the
      # weather glyphs) and prepend it, vertically centred, with a small gap.
      if [ -n "$icon" ] && [ -n "$icol" ]; then
        local icn="$STATEDIR/_icn.$$.png"
        if convert -background none -font DejaVu-Sans -pointsize "$ps" -fill "$icol" \
             label:"$icon" -trim +repage "$icn" 2>>"$LOG" && [ -s "$icn" ]; then
          convert "$icn" \( -size 12x1 xc:none \) "$t" -background none -gravity center +append "$t" 2>>"$LOG"
        fi
        rm -f "$icn"
      fi
      style_block "$g" "$role" "$t"
    }

    # "auto" overlay position: rank the 9 anchor regions of the frame by visual
    # busyness (grayscale std-dev of a 34% corner crop) and give each auto-
    # positioned overlay the CALMEST remaining spot, so text never sits on top
    # of detail. Explicit positions of enabled overlays are reserved up front
    # so auto never lands on one. The ranking is cached per source image — the
    # 1-min clock re-render reuses it instead of re-analysing.
    calm_rank() {
      local g v
      for g in northwest north northeast west center east southwest south southeast; do
        v="$(convert "$RENDER" -gravity "$(imgrav "$g" Center)" -crop 34%x34%+0+0 +repage \
              -colorspace Gray -resize 64x64 -format '%[fx:standard_deviation]' info: 2>>"$LOG")"
        printf '%s %s\n' "${v:-1}" "$g"
      done | sort -n | awk '{printf "%s ",$2}'
    }
    AUTO_RANK=""; AUTO_USED=" "
    for _p in "${OVERLAY_QUOTE:-0}:${QUOTE_POS:-south}" "${OVERLAY_STATS:-0}:${STATS_POS:-northeast}" \
              "${OVERLAY_WEATHER:-0}:${WEATHER_POS:-north}" "${OVERLAY_CLOCK:-0}:${CLOCK_POS:-northwest}" \
              "${OVERLAY_PULSE:-0}:${PULSE_POS:-east}"; do
      [ "${_p%%:*}" = 1 ] && [ "${_p#*:}" != auto ] && AUTO_USED="$AUTO_USED${_p#*:} "
    done
    pick_grav() {  # $1=configured pos $2=IM fallback -> sets PG (no subshell: state!)
      local pos="$1" fb="$2" g cache key
      if [ "$pos" != auto ]; then PG="$(imgrav "$pos" "$fb")"; return; fi
      if [ -z "$AUTO_RANK" ]; then
        cache="$STATEDIR/calm.cache"
        key="$IMG $(stat -c%Y "$IMG" 2>/dev/null) $STYLE"
        if [ -f "$cache" ] && [ "$(head -1 "$cache" 2>/dev/null)" = "$key" ]; then
          AUTO_RANK="$(tail -1 "$cache")"
        else
          AUTO_RANK="$(calm_rank)"
          printf '%s\n%s\n' "$key" "$AUTO_RANK" > "$cache" 2>/dev/null
        fi
      fi
      for g in $AUTO_RANK; do
        case "$AUTO_USED" in *" $g "*) continue;; esac
        AUTO_USED="$AUTO_USED$g "
        PG="$(imgrav "$g" "$fb")"; return
      done
      PG="$(imgrav "$fb" "$fb")"
    }

    # Global gradient wash so edge text reads: scrim washes top+bottom, editorial
    # just the bottom. frosted/chips carry their own panels, so no global wash.
    case "$STYLE" in
      scrim)
        convert "$RENDER" \( -size ${CW}x$((CH*42/100)) gradient:none-black \) -gravity south -composite \
                          \( -size ${CW}x$((CH*22/100)) gradient:black-none \) -gravity north -composite "$RENDER" 2>>"$LOG" ;;
      editorial)
        convert "$RENDER" \( -size ${CW}x$((CH*38/100)) gradient:none-black \) -gravity south -composite "$RENDER" 2>>"$LOG" ;;
    esac

    if [ "${OVERLAY_STATS:-0}" = 1 ]; then
      load3="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
      memhr="$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}')"
      # Network: primary-route iface + IP from `ip route get`; rx/tx throughput
      # from /proc/net/dev byte-counter deltas between renders (state in
      # net.prev: "epoch rx tx"). First render after boot/install has no prev
      # sample, so the rate lines just don't appear until the next one. Degrades
      # to no net lines where `ip`/`/proc/net/dev` are unavailable (Termux).
      NIF=""; NIP=""; NRX=""; NTX=""
      read -r NIF NIP < <(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<NF;i++){if($i=="dev")d=$(i+1);if($i=="src")s=$(i+1)}print d,s;exit}')
      if [ -n "$NIF" ]; then
        read -r nrxb ntxb < <(awk -v i="$NIF:" '$1==i{print $2,$10}' /proc/net/dev 2>/dev/null)
        if [ -n "$nrxb" ]; then
          nnow="$(date +%s)"; npf="$STATEDIR/net.prev"
          if IFS=' ' read -r npts nprx nptx < "$npf" 2>/dev/null; then
            ndt=$((nnow-npts))
            # Counter reset (reboot/iface change) shows as cur<prev: skip rates.
            if [ "$ndt" -gt 0 ] && [ "$nrxb" -ge "$nprx" ] && [ "$ntxb" -ge "$nptx" ]; then
              NRX=$(( (nrxb-nprx)/ndt )); NTX=$(( (ntxb-nptx)/ndt ))
            fi
          fi
          printf '%s %s %s\n' "$nnow" "$nrxb" "$ntxb" > "$npf"
        fi
      fi
      hr_rate() {  # bytes/s -> "1.2M" / "340K" / "12B"
        awk -v b="$1" 'BEGIN{if(b>=1048576)printf "%.1fM",b/1048576; else if(b>=1024)printf "%.0fK",b/1024; else printf "%dB",b}'
      }
      # Build the stats panel line-by-line so a drawn (anti-aliased) line+area
      # sparkline can sit beside load/mem instead of blocky unicode chars.
      sf="$(role_font stats)"; sps=$(( BASEPS * 3 / 4 )); slh=$(( sps * 6 / 5 ))
      RD="$STATEDIR/_st.$$"; mkdir -p "$RD"
      stat_label "$RD/0.png" "$(hostname)"                              "$sf" "$sps" "$slh"
      stat_label "$RD/1.png" "up $(uptime -p 2>/dev/null | sed 's/^up //')" "$sf" "$sps" "$slh"
      stat_label "$RD/2.png" "load ${load3}"                            "$sf" "$sps" "$slh"
      stat_label "$RD/3.png" "mem ${memhr}"                             "$sf" "$sps" "$slh"
      stat_label "$RD/4.png" "disk $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2}')" "$sf" "$sps" "$slh"
      slines=("$RD/0.png" "$RD/1.png" "$RD/2.png" "$RD/3.png" "$RD/4.png")
      # Battery (laptops): first BAT* under /sys/class/power_supply; desktops have
      # none and Termux can't read it, so the line just doesn't appear there.
      bat="$(ls -d /sys/class/power_supply/BAT* 2>/dev/null | head -1)"
      if [ -n "$bat" ] && [ -r "$bat/capacity" ]; then
        bst="$(tr '[:upper:]' '[:lower:]' < "$bat/status" 2>/dev/null)"
        stat_label "$RD/5.png" "bat $(cat "$bat/capacity")% ${bst}" "$sf" "$sps" "$slh"
        slines+=("$RD/5.png")
      fi
      # Network lines: "net <ip> (<iface>)", then rx/tx rates once a prev sample
      # exists (sparklines appended below, same pattern as load/mem).
      if [ -n "$NIF" ]; then
        stat_label "$RD/6.png" "net ${NIP:-?} (${NIF})" "$sf" "$sps" "$slh"
        slines+=("$RD/6.png")
        if [ -n "$NRX" ]; then
          stat_label "$RD/7.png" "rx $(hr_rate "$NRX")/s" "$sf" "$sps" "$slh"
          stat_label "$RD/8.png" "tx $(hr_rate "$NTX")/s" "$sf" "$sps" "$slh"
          slines+=("$RD/7.png" "$RD/8.png")
        fi
      fi
      if [ "${STATS_SPARKLINE:-0}" = 1 ]; then
        # Roll a small history (last 30 samples) and draw sparklines from it.
        # Columns: load,mem%,rx_Bps,tx_Bps (rx/tx blank on pre-net rows/renders;
        # draw_spark just sees a shorter series).
        M="$STATEDIR/metrics.csv"
        printf '%s,%s,%s,%s\n' "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" \
          "$(free 2>/dev/null | awk '/^Mem:/{printf "%.0f",$3/$2*100}')" \
          "${NRX:-}" "${NTX:-}" >> "$M"
        tail -n 30 "$M" > "$M.tmp" 2>/dev/null && mv "$M.tmp" "$M"
        if draw_spark "$RD/ls.png" "$(cut -d, -f1 "$M" | tr '\n' ' ')" "$sps"; then
          convert "$RD/2.png" \( -size 10x1 xc:none \) "$RD/ls.png" -background none -gravity center +append "$RD/2.png" 2>>"$LOG"
        fi
        if draw_spark "$RD/ms.png" "$(cut -d, -f2 "$M" | tr '\n' ' ')" "$sps"; then
          convert "$RD/3.png" \( -size 10x1 xc:none \) "$RD/ms.png" -background none -gravity center +append "$RD/3.png" 2>>"$LOG"
        fi
        if [ -n "$NRX" ] && [ -f "$RD/7.png" ]; then
          if draw_spark "$RD/rs.png" "$(cut -d, -f3 "$M" | tr '\n' ' ')" "$sps"; then
            convert "$RD/7.png" \( -size 10x1 xc:none \) "$RD/rs.png" -background none -gravity center +append "$RD/7.png" 2>>"$LOG"
          fi
          if draw_spark "$RD/ts.png" "$(cut -d, -f4 "$M" | tr '\n' ' ')" "$sps"; then
            convert "$RD/8.png" \( -size 10x1 xc:none \) "$RD/ts.png" -background none -gravity center +append "$RD/8.png" 2>>"$LOG"
          fi
        fi
      fi
      block="$STATEDIR/_stats.$$.png"
      if convert "${slines[@]}" \
           -background none -gravity West -append "$block" 2>>"$LOG"; then
        pick_grav "${STATS_POS:-northeast}" NorthEast
        style_block "$PG" stats "$block" && OVERLAYS="stats"
      fi
      rm -rf "$RD"
    fi
    if [ "${OVERLAY_QUOTE:-0}" = 1 ]; then
      # Reuse the quote while the SAME image stays current, so the 1-min clock
      # refresh (re-rendering the current image) doesn't re-randomise it every
      # minute. Cache = line1 "IMG<US>detail", remaining lines = the quote.
      quote=""; qcache="$STATEDIR/.quote"
      if [ -f "$qcache" ]; then
        IFS=$'\x1f' read -r qimg qdetail < <(head -1 "$qcache")
        if [ "$qimg" = "$ORIG" ] && [ "$qdetail" = "${OVERLAY_QUOTE_DETAIL:-0}" ]; then
          quote="$(tail -n +2 "$qcache")"
        fi
      fi
      if [ -z "$quote" ]; then
        quote="$(pick_quote "${OVERLAY_QUOTE_DETAIL:-0}")"
        { printf '%s\x1f%s\n' "$ORIG" "${OVERLAY_QUOTE_DETAIL:-0}"; printf '%s' "$quote"; } > "$qcache"
      fi
      pick_grav "${QUOTE_POS:-south}" South
      emit "$PG" quote "$quote" && OVERLAYS="${OVERLAYS:+$OVERLAYS+}quote"
    fi
    if [ "${OVERLAY_WEATHER:-0}" = 1 ]; then
      # weather_line emits "glyph<TAB>colour<TAB>text" (glyph/colour empty if icon off)
      IFS=$'\t' read -r wicon wcolor wtext < <(weather_line)
      if [ -n "$wtext" ]; then
        pick_grav "${WEATHER_POS:-north}" North; wgrav="$PG"
        fcast=""; [ "${OVERLAY_WEATHER_FORECAST:-0}" = 1 ] && fcast="$(weather_forecast)"
        if [ -z "$fcast" ]; then
          # single current-conditions line (unchanged path)
          if [ -n "$wicon" ] && [ "${OVERLAY_WEATHER_ICON_COLOR:-0}" = 1 ]; then
            emit "$wgrav" weather "$wtext" "$wicon" "$wcolor"    # coloured icon, separate
          elif [ -n "$wicon" ]; then
            emit "$wgrav" weather "$wicon $wtext"                # monochrome icon, inline
          else
            emit "$wgrav" weather "$wtext"
          fi && OVERLAYS="${OVERLAYS:+$OVERLAYS+}weather"
        else
          # current line + a smaller forecast line, composed into one block
          wf="$(role_font weather)"; wps=$(( BASEPS * 3 / 4 )); wmaxw=$(( CW * 52 / 100 ))
          wc1="$STATEDIR/_wxc.$$.png"; wc2="$STATEDIR/_wxf.$$.png"; wblk="$STATEDIR/_wx.$$.png"
          if [ -n "$wicon" ] && [ "${OVERLAY_WEATHER_ICON_COLOR:-0}" = 1 ]; then ctext="$wtext"; else ctext="${wicon:+$wicon }$wtext"; fi
          if mktext "$wc1" "$wf" "$wps" "$TXT" "$wmaxw" West "$ctext"; then
            if [ -n "$wicon" ] && [ "${OVERLAY_WEATHER_ICON_COLOR:-0}" = 1 ]; then
              icn="$STATEDIR/_wxi.$$.png"
              if convert -background none -font DejaVu-Sans -pointsize "$wps" -fill "$wcolor" label:"$wicon" -trim +repage "$icn" 2>>"$LOG" && [ -s "$icn" ]; then
                convert "$icn" \( -size 12x1 xc:none \) "$wc1" -background none -gravity center +append "$wc1" 2>>"$LOG"
              fi
              rm -f "$icn"
            fi
            # forecast line: clearly SECONDARY — smaller + slightly dimmed (so the
            # panel reads as "now" + a quiet outlook). Composed per-day so each
            # glyph can be coloured; dimmed only lightly so the colours still read.
            fps=$(( wps * 7 / 10 )); [ "$fps" -lt 13 ] && fps=13
            if build_forecast_strip "$wc2" "$fps"; then
              convert "$wc2" -channel A -evaluate multiply 0.85 +channel "$wc2" 2>>"$LOG"
            fi
            if [ -s "$wc2" ]; then
              convert "$wc1" \( -size 1x14 xc:none \) "$wc2" -background none -gravity center -append "$wblk" 2>>"$LOG"
            else
              cp "$wc1" "$wblk" 2>>"$LOG"
            fi
            [ -s "$wblk" ] && style_block "$wgrav" weather "$wblk" && OVERLAYS="${OVERLAYS:+$OVERLAYS+}weather"
          fi
          rm -f "$wc1" "$wc2"
        fi
      fi
    fi
    if [ "${OVERLAY_CLOCK:-0}" = 1 ]; then
      pick_grav "${CLOCK_POS:-northwest}" NorthWest; cgrav="$PG"
      cblock="$STATEDIR/_clock.$$.png"
      if [ "${CLOCK_STYLE:-digital}" = analogue ]; then
        case "$OVERLAY_SIZE" in small) cd=104;; large) cd=176;; *) cd=136;; esac
        if draw_clock "$cblock" "$cd" "$(date +%-H)" "$(date +%-M)"; then
          if [ "${CLOCK_DATE:-0}" = 1 ]; then
            # date under the face — same secondary treatment as the digital style
            # (was silently ignored for analogue, caught on Fam1 2026-06-04)
            dps=$(( cd / 6 )); [ "$dps" -lt 14 ] && dps=14
            cf="$(role_font clock)"; cdp="$STATEDIR/_cld.$$.png"
            if convert -background none -font "$cf" -pointsize "$dps" -fill "$TXT" label:"$(date +'%a %-d %b')" -trim +repage "$cdp" 2>>"$LOG" && [ -s "$cdp" ]; then
              convert "$cblock" \( -size 1x6 xc:none \) "$cdp" -background none -gravity center -append "$cblock" 2>>"$LOG"
            fi
            rm -f "$cdp"
          fi
          style_block "$cgrav" clock "$cblock" && OVERLAYS="${OVERLAYS:+$OVERLAYS+}clock"
        fi
      else
        # digital: big time + optional small date, stacked & centred
        if [ "${CLOCK_24H:-1}" = 1 ]; then ctime="$(date +%H:%M)"; else ctime="$(date +'%-I:%M %p')"; fi
        case "$OVERLAY_SIZE" in small) cps=44;; large) cps=76;; *) cps=58;; esac
        cf="$(role_font clock)"; CRD="$STATEDIR/_cl.$$"; mkdir -p "$CRD"
        convert -background none -font "$cf" -pointsize "$cps" -fill "$TXT" label:"$ctime" -trim +repage "$CRD/t.png" 2>>"$LOG"
        if [ "${CLOCK_DATE:-0}" = 1 ]; then
          dps=$(( cps * 2 / 5 )); [ "$dps" -lt 14 ] && dps=14
          convert -background none -font "$cf" -pointsize "$dps" -fill "$TXT" label:"$(date +'%a %-d %b')" -trim +repage "$CRD/d.png" 2>>"$LOG"
          convert "$CRD/t.png" \( -size 1x6 xc:none \) "$CRD/d.png" -background none -gravity center -append "$cblock" 2>>"$LOG"
        else
          cp "$CRD/t.png" "$cblock" 2>>"$LOG"
        fi
        rm -rf "$CRD"
        [ -s "$cblock" ] && style_block "$cgrav" clock "$cblock" && OVERLAYS="${OVERLAYS:+$OVERLAYS+}clock"
      fi
    fi
    if [ "${OVERLAY_PULSE:-0}" = 1 ] && [ -n "${PULSE_URL:-}" ] && command -v jq >/dev/null 2>&1; then
      # "Pulse" overlay: any JSON endpoint + a jq template -> a stats-style text
      # block (one rendered line per output line, up to PULSE_MAX). Generic —
      # point PULSE_URL at a business/home-automation/CI endpoint and shape the
      # lines with PULSE_JQ. file:// URLs work too (curl), so a local script
      # can feed it. Cached ~5 min so renders don't hammer the endpoint.
      pcache="$STATEDIR/pulse.txt"
      if [ ! -f "$pcache" ] || find "$pcache" -mmin +"${PULSE_TTL:-5}" 2>/dev/null | grep -q .; then
        curl -fsL --max-time 6 "$PULSE_URL" 2>>"$LOG" | jq -r "${PULSE_JQ:-.}" > "$pcache.tmp" 2>>"$LOG"
        if [ -s "$pcache.tmp" ]; then mv "$pcache.tmp" "$pcache"; else rm -f "$pcache.tmp"; fi
      fi
      if [ -s "$pcache" ]; then
        pf="$(role_font stats)"; pps=$(( BASEPS * 3 / 4 )); plh=$(( pps * 6 / 5 ))
        PD="$STATEDIR/_pl.$$"; mkdir -p "$PD"; pn=0
        # Lines containing "|" render as a two-column row — muted label left,
        # bold ACCENT value right-aligned — so the numbers pop and carry their
        # context. Plain lines keep the old flat stats-style rendering.
        pkv=0
        while IFS= read -r pline; do
          [ -n "$pline" ] || continue
          case "$pline" in
            "## "*)
              # Section heading (endpoint emits "## Today" etc). Rendered on its
              # own as an accent-coloured label a touch larger than the rows,
              # with a little top padding so the groups read apart. No label|value
              # split — it flows into the vertical append as a single image.
              convert -background none -font "$pf" -pointsize "$(( pps * 11 / 10 ))" -fill "$ACCENT" \
                label:"${pline#\#\# }" -trim +repage -bordercolor none -border 0x3 \
                "$PD/$pn.png" 2>>"$LOG" ;;
            *"|"*)
              convert -background none -font "$pf" -pointsize "$pps" -fill "$TXT" \
                label:"${pline%%|*}" -trim +repage -channel A -evaluate multiply 0.78 +channel \
                "$PD/$pn.l.png" 2>>"$LOG"
              convert -background none -font "$pf" -pointsize "$pps" -fill "$ACCENT" \
                label:"${pline#*|}" -trim +repage "$PD/$pn.v.png" 2>>"$LOG" \
                || stat_label "$PD/$pn.png" "${pline%%|*} ${pline#*|}" "$pf" "$pps" "$plh"
              pkv=1 ;;
            *) stat_label "$PD/$pn.png" "$pline" "$pf" "$pps" "$plh" ;;
          esac
          pn=$((pn+1)); [ "$pn" -ge "${PULSE_MAX:-20}" ] && break
        done < "$pcache"
        if [ "$pn" -gt 0 ]; then
          # Column widths: align every label column and right-align every value.
          pmaxl=0; pmaxv=0
          if [ "$pkv" = 1 ]; then
            for f in "$PD"/*.l.png; do [ -f "$f" ] || continue
              w=$(identify -format '%w' "$f" 2>/dev/null) && [ "$w" -gt "$pmaxl" ] && pmaxl=$w; done
            for f in "$PD"/*.v.png; do [ -f "$f" ] || continue
              w=$(identify -format '%w' "$f" 2>/dev/null) && [ "$w" -gt "$pmaxv" ] && pmaxv=$w; done
          fi
          pblock="$STATEDIR/_pulse.$$.png"
          pargs=(); pi=0
          while [ "$pi" -lt "$pn" ]; do
            if [ -f "$PD/$pi.l.png" ] && [ -f "$PD/$pi.v.png" ]; then
              convert \( "$PD/$pi.l.png" -background none -gravity West -extent "${pmaxl}x$plh" \) \
                      \( -size $(( pps * 4 / 3 ))x1 xc:none \) \
                      \( "$PD/$pi.v.png" -background none -gravity East -extent "${pmaxv}x$plh" \) \
                      -background none -gravity center +append "$PD/$pi.png" 2>>"$LOG"
            fi
            [ -f "$PD/$pi.png" ] && pargs+=("$PD/$pi.png")
            pi=$((pi+1))
          done
          if [ "${#pargs[@]}" -gt 0 ] && convert "${pargs[@]}" -background none -gravity West -append "$pblock" 2>>"$LOG"; then
            # Optional header: PULSE_TITLE + freshness time (cache mtime) over a
            # thin accent rule — answers "what is this and how current is it?".
            if [ -n "${PULSE_TITLE:-}" ]; then
              tps=$(( BASEPS * 7 / 8 ))
              convert -background none -font "$pf" -pointsize "$tps" -fill "$TXT" \
                label:"$PULSE_TITLE" -trim +repage "$PD/t.png" 2>>"$LOG"
              ptime="$(date -r "$pcache" +%H:%M 2>/dev/null)"
              if [ -n "$ptime" ] && [ -f "$PD/t.png" ]; then
                convert -background none -font "$pf" -pointsize $(( pps * 4 / 5 )) -fill "$TXT" \
                  label:"@ $ptime" -trim +repage -channel A -evaluate multiply 0.55 +channel "$PD/tt.png" 2>>"$LOG"
                [ -f "$PD/tt.png" ] && convert "$PD/t.png" \( -size ${pps}x1 xc:none \) "$PD/tt.png" \
                  -background none -gravity South +append "$PD/t.png" 2>>"$LOG"
              fi
              if [ -f "$PD/t.png" ]; then
                pbw=$(identify -format '%w' "$pblock" 2>/dev/null); tw=$(identify -format '%w' "$PD/t.png" 2>/dev/null)
                [ -n "$pbw" ] && [ -n "$tw" ] || pbw=""
                if [ -n "$pbw" ]; then
                  [ "$tw" -gt "$pbw" ] && pbw=$tw
                  convert -size "${pbw}x2" "xc:$ACCENT" -alpha set -channel A -evaluate set 60% +channel "$PD/rule.png" 2>>"$LOG"
                  convert "$PD/t.png" \( -size 1x5 xc:none \) "$PD/rule.png" \( -size 1x8 xc:none \) "$pblock" \
                    -background none -gravity West -append "$pblock.tmp" 2>>"$LOG" && mv "$pblock.tmp" "$pblock"
                fi
              fi
            fi
            pick_grav "${PULSE_POS:-east}" East
            style_block "$PG" pulse "$pblock" && OVERLAYS="${OVERLAYS:+$OVERLAYS+}pulse"
          fi
        fi
        rm -rf "$PD"
      fi
    fi
    # AI-dreamed images (named *.ai.jpg by fetch-wallpaper) get a subtle
    # signature: tiny, ~40% opacity, tucked into the bottom-right corner.
    # 72px up from the bottom edge, NOT 8: desktop panels/taskbars (~44-48px
    # on KDE/Cinnamon) sit over the bottom strip of the wallpaper, and at +8
    # the badge was invisible behind them; +50 cleared the panel but sat
    # tight against it, +72 per Paul's eyeball (paul-HP, 2026-06-04).
    case "$ORIG" in *.ai.jpg)
      sig="$STATEDIR/_sig.$$.png"
      if convert -background none -font DejaVu-Sans -pointsize 13 -fill white \
           label:"✦ dreamed" -trim +repage -channel A -evaluate multiply 0.4 +channel \
           "$sig" 2>>"$LOG" && [ -s "$sig" ]; then
        convert "$RENDER" "$sig" -gravity SouthEast -geometry +14+72 -composite "$RENDER" 2>>"$LOG"
      fi
      rm -f "$sig"
    ;; esac
    # Infra-alert badge (Phase 1 of the wr-alerting design). check-alerts.sh
    # polls the aggregator and writes $STATEDIR/alerts.json; here we render a
    # loud top-centre badge when an active critical (red) or warn (amber) alert
    # is present and the state file is fresh (<10 min old). Text only — no
    # rotation takeover yet (that's Phase 3). Drawn last so it sits over every
    # other overlay.
    ASTATE="$STATEDIR/alerts.json"
    if command -v jq >/dev/null 2>&1 && [ -s "$ASTATE" ] \
       && ! find "$ASTATE" -mmin +10 2>/dev/null | grep -q . ; then
      # Stack each active alert on its OWN line (criticals first) so several
      # alerts read clearly, instead of one joined line that overflows the
      # screen. Band colour = red if any critical, else amber. Cap the lines and
      # summarise the rest ("+N more") -- a static wallpaper can't scroll.
      ncrit=$(jq -r '[.active[]?|select(.severity=="critical")]|length' "$ASTATE" 2>/dev/null)
      # title \t first_seen \t cleared-flag \t last_seen per alert — the badge
      # carries the fired date/time, and "· cleared HH:MM" for a critical that
      # recovered but lingers until acked (else a 2-min blip reads as ongoing).
      ALINES=$(jq -r '([.active[]?|select(.severity=="critical")]+[.active[]?|select(.severity=="warn")])|.[]|[.title, .first_seen_at//"", (if .cleared then "1" else "0" end), .last_seen_at//""]|@tsv' "$ASTATE" 2>/dev/null)
      ntot=$(printf '%s\n' "$ALINES" | grep -c .)
      abg=""; atxt=""
      if [ "${ntot:-0}" -gt 0 ] 2>/dev/null; then
        if [ "${ncrit:-0}" -gt 0 ] 2>/dev/null; then abg="#c0392b"; else abg="#b9770e"; fi
        MAXL=5; n=0
        TAB=$(printf '\t')
        while IFS="$TAB" read -r t fs cl ls; do
          [ -z "$t" ] && continue
          [ "$n" -ge "$MAXL" ] && break
          [ "${#t}" -gt 64 ] && t="${t:0:61}..."
          # "13 Jul 19:49" local time (GNU date; silently omitted if unsupported),
          # cleared time date-less when it falls on the same day as the raise.
          awhen=""
          if [ -n "$fs" ]; then
            awhen=$(date -d "$fs" +"%-d %b %H:%M" 2>/dev/null) || awhen=""
            if [ -n "$awhen" ] && [ "$cl" = "1" ] && [ -n "$ls" ]; then
              if [ "$(date -d "$fs" +%Y%m%d 2>/dev/null)" = "$(date -d "$ls" +%Y%m%d 2>/dev/null)" ]; then
                awhen="$awhen · cleared $(date -d "$ls" +%H:%M 2>/dev/null)"
              else
                awhen="$awhen · cleared $(date -d "$ls" +"%-d %b %H:%M" 2>/dev/null)"
              fi
            fi
          fi
          atxt="${atxt}${atxt:+$'\n'}⚠  ${t}${awhen:+   ${awhen}}"
          n=$((n+1))
        done <<EOF
$ALINES
EOF
        extra=$(( ntot - n ))
        [ "$extra" -gt 0 ] && atxt="${atxt}"$'\n'"      + ${extra} more"
      fi
      if [ -n "$abg" ] && [ -n "$atxt" ]; then
        aps=$(( ${BASEPS:-30} * 9 / 10 )); [ "$aps" -lt 20 ] && aps=20
        afont=DejaVu-Sans-Bold
        convert -list font 2>/dev/null | grep -q "Font: ${afont}$" || afont=DejaVu-Sans
        ab="$STATEDIR/_alert.$$.png"; ash="$STATEDIR/_alertsh.$$.png"
        # label: renders the embedded newlines as a centred multi-line block.
        if convert -background "$abg" -fill white -font "$afont" -pointsize "$aps" \
             label:"$atxt" -bordercolor "$abg" -border 26x14 "$ab" 2>>"$LOG" \
           && [ -s "$ab" ]; then
          # Soft drop shadow so the badge reads on any wallpaper.
          convert "$ab" -fill black -colorize 100 -channel A -blur 0x6 +channel "$ash" 2>>"$LOG"
          [ -s "$ash" ] && convert "$RENDER" "$ash" -gravity North -geometry +0+22 -composite "$RENDER" 2>>"$LOG"
          convert "$RENDER" "$ab" -gravity North -geometry +0+24 -composite "$RENDER" 2>>"$LOG" \
            && OVERLAYS="${OVERLAYS:+$OVERLAYS+}alert"
        fi
        rm -f "$ab" "$ash"
      fi
    fi
    IMG="$RENDER"
    # Keep only the newest few rendered frames.
    ls -t "$RDIR"/*.jpg 2>/dev/null | tail -n +4 | xargs -r rm -- 2>/dev/null
  fi
fi

# Cron has no session bus / display; assume the usual single-user session.
[ -z "${DISPLAY:-}" ] && export DISPLAY=:0
# XDG_RUNTIME_DIR holds the session-bus socket; Qt/KDE tools
# (plasma-apply-wallpaperimage) need it and the bus path below derives from it.
# X11 Plasma works without it, but Wayland sessions locate the bus via this.
[ -z "${XDG_RUNTIME_DIR:-}" ] && export XDG_RUNTIME_DIR="/run/user/$(id -u)"
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/bus"
fi

DE="$(printf '%s' "${XDG_CURRENT_DESKTOP:-}" | tr '[:upper:]' '[:lower:]')"
if [ -z "$DE" ]; then            # fall back to process sniffing (cron context)
  # Match the full command line (pgrep -f), NOT the comm name: the comm is
  # truncated to 15 chars and the real binary is often suffixed (e.g. Zorin/
  # GNOME runs `gnome-session-binary --session=zorin`, so `pgrep -x gnome-session`
  # misses and we'd wrongly fall through to feh). Map to a clean DE keyword the
  # case below matches (*gnome*/*xfce*/…).
  # GNOME is checked LAST with an anchored pattern: at-spi2-registryd runs as
  # `--use-gnome-session` on EVERY desktop, so a bare `pgrep -f gnome-session`
  # matched it and misdetected KDE/cinnamon/mate boxes as GNOME — cron runs
  # (no XDG env) then set gsettings keys Plasma never reads, freezing the
  # desktop wallpaper while logging status=ok (paul-HP, 2026-06-04). The
  # `(^|/)` anchor requires gnome-session* as the executable itself.
  if   pgrep -f 'xfce4-session'        >/dev/null 2>&1; then DE="xfce"
  elif pgrep -f 'cinnamon-session'     >/dev/null 2>&1; then DE="cinnamon"
  elif pgrep -f 'mate-session'         >/dev/null 2>&1; then DE="mate"
  elif pgrep -f 'plasmashell'          >/dev/null 2>&1; then DE="plasma"
  elif pgrep -f '(^|/)gnome-session'   >/dev/null 2>&1; then DE="gnome"
  fi
fi

# Each branch records the backend it used and its real exit status (backend
# stderr is appended to the log rather than discarded, so failures are visible).
st=0
BACKEND="none"
case "$DE" in
  *xfce*)
    BACKEND="xfconf"
    # Set every monitor/workspace backdrop image property.
    while IFS= read -r prop; do
      xfconf-query -c xfce4-desktop -p "$prop" -s "$IMG" 2>>"$LOG"
    done < <(xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null | grep -E '/last-image$')
    st=$?
    ;;
  *gnome*|*ubuntu*|*budgie*|*unity*)
    BACKEND="gsettings:gnome"
    gsettings set org.gnome.desktop.background picture-uri "file://$IMG" 2>>"$LOG" &&
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$IMG" 2>>"$LOG"
    st=$?
    ;;
  *cinnamon*)
    BACKEND="gsettings:cinnamon"
    gsettings set org.cinnamon.desktop.background picture-uri "file://$IMG" 2>>"$LOG"
    st=$?
    ;;
  *mate*)
    BACKEND="gsettings:mate"
    gsettings set org.mate.background picture-filename "$IMG" 2>>"$LOG"
    st=$?
    ;;
  *kde*|*plasma*)
    # KDE Plasma. Prefer driving the RUNNING plasmashell via D-Bus
    # evaluateScript: it applies the wallpaper LIVE *and* persists config across
    # every desktop containment. plasma-apply-wallpaperimage only updates config
    # and does NOT reliably repaint a running Plasma 5.x session (verified on
    # 5.24: config changed but the desktop didn't), so it's only the fallback
    # when no qdbus is available. (qdbus6 / qdbus-qt6 on Plasma 6 / Qt6.)
    QDBUS="$(command -v qdbus || command -v qdbus6 || command -v qdbus-qt6 || true)"
    if [ -n "$QDBUS" ]; then
      BACKEND="qdbus-evaluatescript"
      "$QDBUS" org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        "var d=desktops();for(i=0;i<d.length;i++){d[i].wallpaperPlugin='org.kde.image';d[i].currentConfigGroup=['Wallpaper','org.kde.image','General'];d[i].writeConfig('Image','file://$IMG');}" >/dev/null 2>>"$LOG"
      st=$?
    elif command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
      BACKEND="plasma-apply(config-only)"
      plasma-apply-wallpaperimage "$IMG" >/dev/null 2>>"$LOG"
      st=$?
    else
      st=127   # no KDE setter available
    fi
    ;;
  *)
    # Generic X11 fallback (i3/openbox/etc.) — needs feh if present.
    if command -v feh >/dev/null 2>&1; then
      BACKEND="feh"
      feh --bg-fill "$IMG" 2>>"$LOG"
      st=$?
    else
      st=127   # no fallback available
    fi
    ;;
esac

tag=""; [ -n "$OVERLAYS" ] && tag=" overlay=$OVERLAYS"
if [ "$st" -eq 0 ]; then
  BAGSTAT=""
  if [ -f "$STATEDIR/images.bag" ]; then
    BAGSTAT=" bag=$(wc -l < "$STATEDIR/images.bag" 2>/dev/null || echo '?')/$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | wc -l)"
  fi
  log "[rotate] de=${DE:-unknown} backend=$BACKEND img=$(basename "$ORIG")${tag}${BAGSTAT} status=ok"
else
  log "[rotate] de=${DE:-unknown} backend=$BACKEND img=$(basename "$ORIG")${tag} status=fail:$st"
fi

# Keep the log bounded (cron writes ~144 rotate lines/day).
tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
