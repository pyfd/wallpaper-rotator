#!/bin/bash
# Set the desktop wallpaper across common Linux desktops.
# Usage: set-wallpaper.sh [/path/to/image]   (no arg = random image from the pool)
# Safe to call from cron: it re-establishes the session env (DISPLAY/DBUS) that
# cron jobs lack, and detects the desktop from running processes when
# XDG_CURRENT_DESKTOP is unset. @@POOL@@ and @@LOG@@ are substituted by install.sh.

POOL="@@POOL@@"

# Activity log (see install.sh). Fall back to the XDG state path when run from a
# raw checkout where @@LOG@@ wasn't substituted.
LOG="@@LOG@@"
case "$LOG" in *@@LOG@@*|"") LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log" ;; esac
mkdir -p "$(dirname "$LOG")" 2>/dev/null
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

IMG="${1:-}"
if [ -z "$IMG" ]; then
  IMG="$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | shuf -n 1)"
fi
[ -z "$IMG" ] && { log "[rotate] skip (empty pool)"; exit 0; }
[ -f "$IMG" ] || { log "[rotate] skip (missing file: $IMG)"; exit 0; }

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

if [ "$st" -eq 0 ]; then
  log "[rotate] de=${DE:-unknown} backend=$BACKEND img=$(basename "$IMG") status=ok"
else
  log "[rotate] de=${DE:-unknown} backend=$BACKEND img=$(basename "$IMG") status=fail:$st"
fi

# Keep the log bounded (cron writes ~144 rotate lines/day).
tail -n 1000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
