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
# Overlay defaults (the web UI overwrites these in the config).
OVERLAY_QUOTE=0; OVERLAY_QUOTE_DETAIL=0; OVERLAY_STATS=0
QUOTE_POS=south; STATS_POS=northeast
OVERLAY_SIZE=medium; OVERLAY_THEME=dark; OVERLAY_FONT=default
OVERLAY_STYLE=scrim
STATS_SPARKLINE=0
OVERLAY_WEATHER=0; WEATHER_POS=north; WEATHER_LOCATION=; OVERLAY_WEATHER_ICON=0
OVERLAY_WEATHER_ICON_COLOR=0
THEME=
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

STATEDIR="$(dirname "$LOG")"

# Map a config position token to an ImageMagick -gravity value ($2 = default).
imgrav() {
  case "$1" in
    northwest) echo NorthWest;; north) echo North;; northeast) echo NorthEast;;
    west) echo West;; center) echo Center;; east) echo East;;
    southwest) echo SouthWest;; south) echo South;; southeast) echo SouthEast;;
    *) echo "$2";;
  esac
}

# A quote for the overlay. With detail, append attribution (author, source, year)
# from the bundled list. Without detail, `fortune -s` is used if installed.
pick_quote() {
  local detail="${1:-0}"
  # Prefer the API cache (text|author||) refreshed by fetch-quotes.sh, so quotes
  # keep changing; fall back to fortune (non-detail) then the bundled list.
  local cache="$STATEDIR/quotes.cache" line=""
  [ -s "$cache" ] && line="$(shuf -n1 "$cache" 2>/dev/null)"
  if [ -z "$line" ]; then
    if [ "$detail" != 1 ] && command -v fortune >/dev/null 2>&1; then
      fortune -s 2>/dev/null | tr '\n\t' '  ' | sed 's/  */ /g' | cut -c1-160
      return
    fi
    line=""
  fi
  if [ -n "$line" ]; then
    local text author source year
    IFS='|' read -r text author source year <<< "$line"
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
  if [ ! -f "$cache" ] || find "$cache" -mmin +60 2>/dev/null | grep -q .; then
    if curl -fsL --max-time 12 "https://wttr.in/${loc// /+}?format=%l|%C|%t,+%h,+%w" \
         -o "$cache.new" 2>>"$LOG" && [ -s "$cache.new" ]; then
      mv "$cache.new" "$cache"
    else
      rm -f "$cache.new"
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

IMG="${1:-}"
if [ -z "$IMG" ]; then
  # Avoid an immediate repeat: drop the previously-applied original (stored in
  # `current`) from the candidate list before the random pick. grep -vxF removes
  # exactly that one path; if filtering leaves nothing (single-image pool, or the
  # only files ARE the last one) fall back to the unfiltered shuffle so we always
  # set something. Empty LAST (first run) filters nothing.
  LAST=""; [ -f "$STATEDIR/current" ] && LAST="$(cat "$STATEDIR/current" 2>/dev/null)"
  IMG="$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null \
          | grep -vxF "$LAST" | shuf -n 1)"
  [ -z "$IMG" ] && IMG="$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | shuf -n 1)"
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
if { [ "${OVERLAY_QUOTE:-0}" = 1 ] || [ "${OVERLAY_STATS:-0}" = 1 ] || [ "${OVERLAY_WEATHER:-0}" = 1 ]; } \
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
    case "$OVERLAY_THEME" in light) TXT=black;; accent) TXT="$ACCENT";; *) TXT=white;; esac
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
      local g="$1" pad=36 gap=14 tries=0 r rx ry rw rh hit
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
      [ "$OY" -lt 0 ] && OY=0
      [ $((OY+bh)) -gt "$CH" ] && OY=$((CH-bh))
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
      # Build the stats panel line-by-line so a drawn (anti-aliased) line+area
      # sparkline can sit beside load/mem instead of blocky unicode chars.
      sf="$(role_font stats)"; sps=$(( BASEPS * 3 / 4 )); slh=$(( sps * 6 / 5 ))
      RD="$STATEDIR/_st.$$"; mkdir -p "$RD"
      stat_label "$RD/0.png" "$(hostname)"                              "$sf" "$sps" "$slh"
      stat_label "$RD/1.png" "up $(uptime -p 2>/dev/null | sed 's/^up //')" "$sf" "$sps" "$slh"
      stat_label "$RD/2.png" "load ${load3}"                            "$sf" "$sps" "$slh"
      stat_label "$RD/3.png" "mem ${memhr}"                             "$sf" "$sps" "$slh"
      stat_label "$RD/4.png" "disk $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2}')" "$sf" "$sps" "$slh"
      if [ "${STATS_SPARKLINE:-0}" = 1 ]; then
        # Roll a small history (last 30 samples) and draw sparklines from it.
        M="$STATEDIR/metrics.csv"
        printf '%s,%s\n' "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" \
          "$(free 2>/dev/null | awk '/^Mem:/{printf "%.0f",$3/$2*100}')" >> "$M"
        tail -n 30 "$M" > "$M.tmp" 2>/dev/null && mv "$M.tmp" "$M"
        if draw_spark "$RD/ls.png" "$(cut -d, -f1 "$M" | tr '\n' ' ')" "$sps"; then
          convert "$RD/2.png" \( -size 10x1 xc:none \) "$RD/ls.png" -background none -gravity center +append "$RD/2.png" 2>>"$LOG"
        fi
        if draw_spark "$RD/ms.png" "$(cut -d, -f2 "$M" | tr '\n' ' ')" "$sps"; then
          convert "$RD/3.png" \( -size 10x1 xc:none \) "$RD/ms.png" -background none -gravity center +append "$RD/3.png" 2>>"$LOG"
        fi
      fi
      block="$STATEDIR/_stats.$$.png"
      if convert "$RD/0.png" "$RD/1.png" "$RD/2.png" "$RD/3.png" "$RD/4.png" \
           -background none -gravity West -append "$block" 2>>"$LOG"; then
        style_block "$(imgrav "${STATS_POS:-northeast}" NorthEast)" stats "$block" && OVERLAYS="stats"
      fi
      rm -rf "$RD"
    fi
    if [ "${OVERLAY_QUOTE:-0}" = 1 ]; then
      quote="$(pick_quote "${OVERLAY_QUOTE_DETAIL:-0}")"
      emit "$(imgrav "${QUOTE_POS:-south}" South)" quote "$quote" && OVERLAYS="${OVERLAYS:+$OVERLAYS+}quote"
    fi
    if [ "${OVERLAY_WEATHER:-0}" = 1 ]; then
      # weather_line emits "glyph<TAB>colour<TAB>text" (glyph/colour empty if icon off)
      IFS=$'\t' read -r wicon wcolor wtext < <(weather_line)
      if [ -n "$wtext" ]; then
        wgrav="$(imgrav "${WEATHER_POS:-north}" North)"
        if [ -n "$wicon" ] && [ "${OVERLAY_WEATHER_ICON_COLOR:-0}" = 1 ]; then
          emit "$wgrav" weather "$wtext" "$wicon" "$wcolor"      # coloured icon, separate
        elif [ -n "$wicon" ]; then
          emit "$wgrav" weather "$wicon $wtext"                  # monochrome icon, inline
        else
          emit "$wgrav" weather "$wtext"
        fi && OVERLAYS="${OVERLAYS:+$OVERLAYS+}weather"
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
  if   pgrep -f 'xfce4-session'    >/dev/null 2>&1; then DE="xfce"
  elif pgrep -f 'gnome-session'    >/dev/null 2>&1; then DE="gnome"
  elif pgrep -f 'cinnamon-session' >/dev/null 2>&1; then DE="cinnamon"
  elif pgrep -f 'mate-session'     >/dev/null 2>&1; then DE="mate"
  elif pgrep -f 'plasmashell'      >/dev/null 2>&1; then DE="plasma"
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
  log "[rotate] de=${DE:-unknown} backend=$BACKEND img=$(basename "$ORIG")${tag} status=ok"
else
  log "[rotate] de=${DE:-unknown} backend=$BACKEND img=$(basename "$ORIG")${tag} status=fail:$st"
fi

# Keep the log bounded (cron writes ~144 rotate lines/day).
tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
