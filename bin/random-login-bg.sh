#!/bin/bash
# Pick a random image from the pool, crop/resize it to the screen resolution,
# and write it where the LightDM greeter expects the login background.
# Placeholders (@@...@@) are substituted by install.sh at install time.
set -e

WALLPAPER_DIR="@@POOL@@"
TARGET="@@TARGET@@"
RESOLUTION="@@RESOLUTION@@"

IMG=$(find "$WALLPAPER_DIR" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) 2>/dev/null | shuf -n 1)

if [ -n "$IMG" ]; then
  convert "$IMG" -gravity center -resize "${RESOLUTION}^" -extent "$RESOLUTION" "$TARGET"
fi
