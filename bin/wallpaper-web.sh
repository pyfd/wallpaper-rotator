#!/bin/bash
# Launch the wallpaper-rotator status + control server (localhost, on demand).
# Thin wrapper around the Python server (which holds the substituted paths and
# regenerates the page on startup). @@PYBIN@@ substituted by install.sh.
set -uo pipefail

PYBIN="@@PYBIN@@"
# Split literal so install.sh's sed doesn't rewrite this guard (see fetch-wallpaper.sh).
[ "$PYBIN" = "@@PYBIN""@@" ] && PYBIN="$(dirname "$0")/wallpaper-web.py"

command -v python3 >/dev/null 2>&1 || { echo "wallpaper-web: python3 is required." >&2; exit 1; }
exec python3 "$PYBIN"
