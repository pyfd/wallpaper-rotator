#!/bin/bash
# Set the desktop wallpaper across common Linux desktops.
# Usage: set-wallpaper.sh [/path/to/image]   (no arg = random image from the pool)
# Safe to call from cron: it re-establishes the session env (DISPLAY/DBUS) that
# cron jobs lack, and detects the desktop from running processes when
# XDG_CURRENT_DESKTOP is unset. @@POOL@@ is substituted by install.sh.

POOL="@@POOL@@"

IMG="${1:-}"
if [ -z "$IMG" ]; then
  IMG="$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | shuf -n 1)"
fi
[ -z "$IMG" ] && exit 0           # empty pool — nothing to do
[ -f "$IMG" ] || exit 0

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

case "$DE" in
  *xfce*)
    # Set every monitor/workspace backdrop image property.
    while IFS= read -r prop; do
      xfconf-query -c xfce4-desktop -p "$prop" -s "$IMG" 2>/dev/null
    done < <(xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null | grep -E '/last-image$')
    ;;
  *gnome*|*ubuntu*|*budgie*|*unity*)
    gsettings set org.gnome.desktop.background picture-uri "file://$IMG" 2>/dev/null
    gsettings set org.gnome.desktop.background picture-uri-dark "file://$IMG" 2>/dev/null
    ;;
  *cinnamon*)
    gsettings set org.cinnamon.desktop.background picture-uri "file://$IMG" 2>/dev/null
    ;;
  *mate*)
    gsettings set org.mate.background picture-filename "$IMG" 2>/dev/null
    ;;
  *kde*|*plasma*)
    # KDE Plasma: the official setter talks to the running plasmashell over the
    # session bus (re-established above for cron). On older Plasma without
    # plasma-apply-wallpaperimage, drive plasmashell directly via D-Bus.
    if command -v plasma-apply-wallpaperimage >/dev/null 2>&1; then
      plasma-apply-wallpaperimage "$IMG" >/dev/null 2>&1
    elif command -v qdbus >/dev/null 2>&1; then
      qdbus org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript \
        "var d=desktops();for(i=0;i<d.length;i++){d[i].wallpaperPlugin='org.kde.image';d[i].currentConfigGroup=['Wallpaper','org.kde.image','General'];d[i].writeConfig('Image','file://$IMG');}" >/dev/null 2>&1
    fi
    ;;
  *)
    # Generic X11 fallback (i3/openbox/etc.) — needs feh if present.
    if command -v feh >/dev/null 2>&1; then
      feh --bg-fill "$IMG" 2>/dev/null
    fi
    ;;
esac
