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
STATS_SPARKLINE=0
OVERLAY_WEATHER=0; WEATHER_POS=north; WEATHER_LOCATION=
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

# Unicode sparkline from space-separated numbers. awk computes 0-7 levels (float
# math is fine there); bash maps to block chars (reliable multibyte handling).
sparkline() {
  local levels chars=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █) out="" l
  levels="$(awk -v RS='[ \n]' 'NF{a[n++]=$1} END{if(n==0)exit; mn=a[0];mx=a[0];
    for(i=0;i<n;i++){if(a[i]<mn)mn=a[i];if(a[i]>mx)mx=a[i]} r=mx-mn;
    for(i=0;i<n;i++) printf "%d ",(r>0)?int((a[i]-mn)/r*7+0.5):0}' <<<"$1")"
  for l in $levels; do out="$out${chars[$l]}"; done
  printf '%s' "$out"
}

# Local weather via wttr.in (no key); cached ~1h so we don't hammer it.
weather_line() {
  local cache="$STATEDIR/weather.txt" loc="${WEATHER_LOCATION:-}"
  if [ ! -f "$cache" ] || find "$cache" -mmin +60 2>/dev/null | grep -q .; then
    if curl -fsL --max-time 12 "https://wttr.in/${loc// /+}?format=%l:+%C+%t,+%h,+%w" \
         -o "$cache.new" 2>>"$LOG" && [ -s "$cache.new" ]; then
      mv "$cache.new" "$cache"
    else
      rm -f "$cache.new"
    fi
  fi
  cat "$cache" 2>/dev/null
}

IMG="${1:-}"
if [ -z "$IMG" ]; then
  IMG="$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | shuf -n 1)"
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
    # Style from config: size -> pointsize, theme -> fill + undercolor, font.
    case "$OVERLAY_SIZE" in small) PS=18;; large) PS=34;; *) PS=24;; esac
    case "$OVERLAY_THEME" in
      light)  FILL=black;     UNDER='#ffffffaa';;
      accent) FILL='#6cb6ff'; UNDER='#000000aa';;
      *)      FILL=white;     UNDER='#000000aa';;   # dark
    esac
    FONTARG=()
    if [ "${OVERLAY_FONT:-default}" != default ] && [ -n "${OVERLAY_FONT:-}" ] \
         && convert -list font 2>/dev/null | grep -q "Font: ${OVERLAY_FONT}$"; then
      FONTARG=(-font "$OVERLAY_FONT")
    fi
    # Offset from the chosen gravity: corners/edges inset 30px; centred edges get
    # x=0; dead-centre gets y=0 too.
    # Offset from gravity: 30px inset; bottom edge insets further (80px) to clear
    # a desktop panel/taskbar; dead-centre sits at 0,0.
    place() {
      gx=30; gy=30
      case "$1" in North|South|Center) gx=0;; esac
      case "$1" in South*) gy=80;; esac
      case "$1" in Center) gy=0;; esac
    }
    draw() {  # $1=position token  $2=default gravity  $3=text
      local g; g="$(imgrav "$1" "$2")"; place "$g"
      convert "$RENDER" "${FONTARG[@]}" -gravity "$g" -pointsize "$PS" -fill "$FILL" \
        -undercolor "$UNDER" -annotate "+${gx}+${gy}" "$3 " "$RENDER" 2>>"$LOG"
    }

    if [ "${OVERLAY_STATS:-0}" = 1 ]; then
      load3="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
      memhr="$(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}')"
      lspark=""; mspark=""
      if [ "${STATS_SPARKLINE:-0}" = 1 ]; then
        # Roll a small history (last 30 samples) and draw sparklines from it.
        M="$STATEDIR/metrics.csv"
        printf '%s,%s\n' "$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" \
          "$(free 2>/dev/null | awk '/^Mem:/{printf "%.0f",$3/$2*100}')" >> "$M"
        tail -n 30 "$M" > "$M.tmp" 2>/dev/null && mv "$M.tmp" "$M"
        lspark=" $(sparkline "$(cut -d, -f1 "$M" | tr '\n' ' ')")"
        mspark=" $(sparkline "$(cut -d, -f2 "$M" | tr '\n' ' ')")"
      fi
      stats="$(printf '%s\n' \
        "$(hostname)" \
        "up $(uptime -p 2>/dev/null | sed 's/^up //')" \
        "load ${load3}${lspark}" \
        "mem ${memhr}${mspark}" \
        "disk $(df -h / 2>/dev/null | awk 'NR==2{print $3"/"$2}')")"
      draw "${STATS_POS:-northeast}" NorthEast "$stats" && OVERLAYS="stats"
    fi
    if [ "${OVERLAY_QUOTE:-0}" = 1 ]; then
      quote="$(pick_quote "${OVERLAY_QUOTE_DETAIL:-0}" | fold -s -w 52)"
      draw "${QUOTE_POS:-south}" South "$quote" && OVERLAYS="${OVERLAYS:+$OVERLAYS+}quote"
    fi
    if [ "${OVERLAY_WEATHER:-0}" = 1 ]; then
      weather="$(weather_line | fold -s -w 60)"
      [ -n "$weather" ] && draw "${WEATHER_POS:-north}" North "$weather" \
        && OVERLAYS="${OVERLAYS:+$OVERLAYS+}weather"
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
  for p in xfce4-session gnome-session cinnamon-session mate-session plasmashell; do
    if pgrep -x "$p" >/dev/null 2>&1; then DE="$p"; break; fi
  done
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
