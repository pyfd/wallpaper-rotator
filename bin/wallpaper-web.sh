#!/bin/bash
# Serve the wallpaper-rotator status page locally, on demand.
# Regenerates the page once, then serves it on 127.0.0.1:<port> until Ctrl-C.
# Placeholders (@@...@@) substituted by install.sh.
set -uo pipefail

WEBDIR="@@WEBDIR@@"
GENSTATUS="@@GENSTATUS@@"
PORT="@@PORT@@"
# Split-literal guards so install.sh's sed doesn't rewrite them (see fetch-wallpaper.sh).
[ "$WEBDIR"    = "@@WEBDIR""@@" ]    && WEBDIR="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/web"
[ "$GENSTATUS" = "@@GENSTATUS""@@" ] && GENSTATUS="$(dirname "$0")/gen-status.sh"
[ "$PORT"      = "@@PORT""@@" ]      && PORT="8787"

command -v python3 >/dev/null 2>&1 || { echo "wallpaper-web: python3 is required." >&2; exit 1; }

# Refresh the page once up front (cron keeps it fresh while the server runs).
[ -x "$GENSTATUS" ] && "$GENSTATUS" 2>/dev/null || true
mkdir -p "$WEBDIR"

echo "Serving wallpaper-rotator status at http://127.0.0.1:${PORT}"
echo "(Ctrl-C to stop)"
exec python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$WEBDIR"
