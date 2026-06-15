#!/bin/bash
# Pick a random image from the pool, crop/resize it to the screen resolution,
# and write it where the LightDM greeter expects the login background.
# Placeholders (@@...@@) are substituted by install.sh at install time.
set -e

WALLPAPER_DIR="@@POOL@@"
TARGET="@@TARGET@@"
RESOLUTION="@@RESOLUTION@@"
LOG="@@LOG@@"
# Split literal so install.sh's sed doesn't rewrite this guard too (see fetch-wallpaper.sh).
[ "$LOG" = "@@LOG""@@" ] && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

# --login = the per-login autostart invocation. Honour the LOGIN_ROTATE toggle
# only there; a manual run (no --login, e.g. the web UI "Refresh now") always
# refreshes. CONFIG split-literal like LOG above so install.sh's sed is exact.
CONFIG="@@CONFIG@@"
[ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
case " $* " in
  *" --login "*)
    rot=$(sed -n "s/^LOGIN_ROTATE=['\"]*\([0-9]\).*/\1/p" "$CONFIG" 2>/dev/null | tail -1)
    [ "$rot" = "0" ] && { log "[login] skip (login rotate off)"; exit 0; }
    ;;
esac

IMG=$(find "$WALLPAPER_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) 2>/dev/null | shuf -n 1)

if [ -n "$IMG" ]; then
  if convert "$IMG" -gravity center -resize "${RESOLUTION}^" -extent "$RESOLUTION" "$TARGET" 2>>"$LOG"; then
    log "[login] ok img=$(basename "$IMG")"
  else
    log "[login] fail img=$(basename "$IMG")"
  fi
else
  log "[login] skip (empty pool)"
fi
