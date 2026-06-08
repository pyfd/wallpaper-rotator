#!/bin/bash
# Poll the infra-alerts aggregator and cache the active set for set-wallpaper.sh.
# Phase 1 of the wr-alerting design (see ALERTS_DESIGN.md in the dotfiles repo).
#
# Run from cron every minute. Off by default: does nothing unless ALERTS_URL is
# set in the config (the web UI / a hand edit points it at the aggregator's
# GET .../admin/alerts.json). When the active critical/warn set CHANGES, it
# re-renders the CURRENT wallpaper so the badge appears within one poll cycle,
# independent of the rotate/clock crons.

CONFIG="@@CONFIG@@"
[ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
SETWP="@@SETWP@@"
[ "$SETWP" = "@@SETWP""@@" ] && SETWP="$(dirname "$0")/set-wallpaper.sh"
CURRENT="@@CURRENT@@"
[ "$CURRENT" = "@@CURRENT""@@" ] && CURRENT="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/current"

ALERTS_URL=""
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

STATEDIR="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator"
OUT="$STATEDIR/alerts.json"
SIGFILE="$STATEDIR/alerts.sig"

# Feature off unless configured.
[ -n "${ALERTS_URL:-}" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
mkdir -p "$STATEDIR"

tmp="$OUT.tmp.$$"
if curl -fsL --max-time 8 "$ALERTS_URL" -o "$tmp" 2>/dev/null \
   && [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then
  mv "$tmp" "$OUT"
else
  # Endpoint unreachable / bad payload: keep the previous file. set-wallpaper's
  # 10-min freshness guard drops a stale badge on its own.
  rm -f "$tmp"
  exit 0
fi

# Signature of the active critical+warn set. A change (new alert, cleared alert,
# severity change) triggers an immediate re-render of the current image.
SIG=$(jq -r '[.active[]?|select(.severity=="critical" or .severity=="warn")
              |"\(.severity):\(.host):\(.key)"]|sort|join("|")' "$OUT" 2>/dev/null)
PREV=""; [ -f "$SIGFILE" ] && PREV="$(cat "$SIGFILE" 2>/dev/null)"
if [ "$SIG" != "$PREV" ]; then
  printf '%s' "$SIG" > "$SIGFILE" 2>/dev/null
  # Re-render the current image (no shuffle) so the badge updates now.
  if [ -x "$SETWP" ] && [ -s "$CURRENT" ]; then
    "$SETWP" "$(cat "$CURRENT")" >/dev/null 2>&1 || true
  fi
fi
exit 0
