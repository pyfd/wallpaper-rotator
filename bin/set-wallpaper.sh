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
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
  export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
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
  *)
    # Generic X11 fallback (i3/openbox/etc.) — needs feh if present.
    if command -v feh >/dev/null 2>&1; then
      feh --bg-fill "$IMG" 2>/dev/null
    fi
    ;;
esac
