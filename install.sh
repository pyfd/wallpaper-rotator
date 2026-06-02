#!/bin/bash
#
# wallpaper-rotator installer
# -------------------------------------------------------------------------
# Auto-rotating desktop wallpaper on any common Linux desktop (XFCE, GNOME,
# Cinnamon, MATE, or a feh fallback), plus an auto-rotating LightDM login
# background where LightDM is the display manager. One image pool, refilled by
# cron from several sources (Wallhaven, Bing, Picsum, local) with fallback,
# drives both.
#
# Run as your normal user (NOT root). It calls sudo only for the system bits.
# Idempotent: safe to re-run.
# -------------------------------------------------------------------------
set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as your normal user, not root (sudo is used internally)." >&2
  exit 1
fi

# Non-interactive answers for the "existing rotator detected" prompt.
DISABLE_OTHERS=""   # "yes" | "no" | "" (ask via /dev/tty)
for arg in "$@"; do
  case "$arg" in
    --yes-disable) DISABLE_OTHERS="yes" ;;
    --no-disable)  DISABLE_OTHERS="no"  ;;
  esac
done

TARGET_USER="$USER"
USER_HOME="$HOME"
POOL="$USER_HOME/Pictures/online-wallpapers"
TARGET_IMG="/usr/share/backgrounds/login-random.jpg"
LOGIN_BIN="/usr/local/bin/random-login-bg.sh"
SETWP_BIN="/usr/local/bin/set-wallpaper.sh"
FETCH_BIN="/usr/local/bin/fetch-wallpaper.sh"
FETCHQ_BIN="/usr/local/bin/fetch-quotes.sh"
GENSTATUS_BIN="/usr/local/bin/gen-status.sh"
WEB_BIN="/usr/local/bin/wallpaper-web"
WEB_PORT="8787"
# Image sources (priority is randomised per fetch for variety; the chain falls
# through to the next on any failure). picsum is the always-works floor.
SOURCES="wallhaven bing picsum local"
# Local image folder for the 'local' source — used only if it exists + has images.
LOCALDIR="$USER_HOME/Pictures/Wallpapers"
# How many images to download up front on a FIRST install, so random rotation has
# variety from the very first tick instead of repeating one image until cron fills
# the pool. Only runs when the pool is empty; re-installs don't re-seed. Kept under
# the keep-30 prune ceiling.
SEED_COUNT=15
# Activity log + web status dir (XDG state dir). Shared by the cron jobs, the
# setter, and the login generator. Created user-owned so the root-run login
# generator appends rather than taking ownership.
LOG_DIR="${XDG_STATE_HOME:-$USER_HOME/.local/state}/wallpaper-rotator"
LOG_FILE="$LOG_DIR/wallpaper.log"
WEBDIR="$LOG_DIR/web"
CONFIG_FILE="$LOG_DIR/config"          # interval + overlay toggles (web UI writes this)
PYBIN="/usr/local/bin/wallpaper-web.py"

echo "==> wallpaper-rotator install (user: $TARGET_USER)"

# --- helpers ------------------------------------------------------------
# ensure_pkg <binary> <apt> <dnf> <pacman> <zypper>
ensure_pkg() {
  local bin="$1" apt_p="$2" dnf_p="$3" pac_p="$4" zyp_p="$5"
  command -v "$bin" >/dev/null 2>&1 && return 0
  echo "    installing '$bin'..."
  if   command -v apt-get >/dev/null 2>&1; then sudo apt-get install -y "$apt_p" >/dev/null
  elif command -v dnf     >/dev/null 2>&1; then sudo dnf install -y "$dnf_p" >/dev/null
  elif command -v pacman  >/dev/null 2>&1; then sudo pacman -Sy --noconfirm "$pac_p" >/dev/null
  elif command -v zypper  >/dev/null 2>&1; then sudo zypper -n install "$zyp_p" >/dev/null
  else echo "    WARNING: no known package manager — install '$bin' manually." >&2; return 1; fi
}

# --- 1. desktop environment ---------------------------------------------
DE="$(printf '%s' "${XDG_CURRENT_DESKTOP:-}" | tr '[:upper:]' '[:lower:]')"
if [ -z "$DE" ]; then
  # Match full cmdline (pgrep -f), not the 15-char-truncated comm: e.g. Zorin/
  # GNOME runs `gnome-session-binary`, which `pgrep -x gnome-session` misses.
  if   pgrep -f 'xfce4-session'    >/dev/null 2>&1; then DE="xfce"
  elif pgrep -f 'gnome-session'    >/dev/null 2>&1; then DE="gnome"
  elif pgrep -f 'cinnamon-session' >/dev/null 2>&1; then DE="cinnamon"
  elif pgrep -f 'mate-session'     >/dev/null 2>&1; then DE="mate"
  elif pgrep -f 'plasmashell'      >/dev/null 2>&1; then DE="plasma"
  fi
fi
echo "    desktop: ${DE:-<unknown — will use feh fallback>}"

# --- 2. display manager (login background is LightDM-only) --------------
DM=""
[ -f /etc/X11/default-display-manager ] && DM="$(basename "$(cat /etc/X11/default-display-manager 2>/dev/null)")"
[ -z "$DM" ] && DM="$(systemctl status display-manager 2>/dev/null | grep -oE 'lightdm|gdm[0-9]*|sddm' | head -1)"
GREETER_CONF=""
if printf '%s' "$DM" | grep -qi lightdm || command -v lightdm >/dev/null 2>&1; then
  GS="$(grep -hriE '^[[:space:]]*greeter-session=' /etc/lightdm/ 2>/dev/null | head -1 | cut -d= -f2 | tr -d '[:space:]')"
  case "$GS" in
    *slick*) GREETER_CONF=/etc/lightdm/slick-greeter.conf ;;
    *gtk*)   GREETER_CONF=/etc/lightdm/lightdm-gtk-greeter.conf ;;
    *) if [ -f /etc/lightdm/slick-greeter.conf ]; then GREETER_CONF=/etc/lightdm/slick-greeter.conf
       else GREETER_CONF=/etc/lightdm/lightdm-gtk-greeter.conf; fi ;;
  esac
  echo "    display manager: LightDM (greeter conf: $GREETER_CONF)"
else
  echo "    display manager: ${DM:-unknown} — login background NOT supported, will skip (desktop rotation still works)"
fi

# --- 2b. existing wallpaper rotator? ------------------------------------
# If another manager (Variety, Wallch, a GNOME slideshow…) is already driving
# the desktop, ours would fight it. Offer to disable it; if declined, coexist
# (install the pool + LightDM login only, leave their desktop alone).
DESKTOP_ENABLED=1
OTHERS=""
for proc in variety wallch; do
  pgrep -x "$proc" >/dev/null 2>&1 && OTHERS="$OTHERS $proc"
done
if printf '%s' "$DE" | grep -qE 'gnome|ubuntu|budgie|cinnamon'; then
  CUR_URI="$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null | tr -d \")"
  printf '%s' "$CUR_URI" | grep -qiE '\.xml' && OTHERS="$OTHERS gnome-slideshow"
fi
OTHERS="$(printf '%s' "$OTHERS" | sed 's/^ *//')"

if [ -n "$OTHERS" ]; then
  echo "    ! existing wallpaper rotator detected: $OTHERS"
  ANS="$DISABLE_OTHERS"
  if [ -z "$ANS" ]; then
    if [ -e /dev/tty ]; then
      printf "    Disable it so wallpaper-rotator owns the desktop? [y/N] " > /dev/tty
      read -r REPLY_RAW < /dev/tty || REPLY_RAW=""
      case "$REPLY_RAW" in [Yy]*) ANS="yes" ;; *) ANS="no" ;; esac
    else
      ANS="no"   # non-interactive with no terminal — coexist by default
    fi
  fi
  if [ "$ANS" = "yes" ]; then
    for proc in $OTHERS; do
      [ "$proc" = "gnome-slideshow" ] && continue   # cleared by setting a still image
      echo "    disabling $proc"
      pkill -x "$proc" 2>/dev/null || pkill -f "$proc" 2>/dev/null || true
      UA="$HOME/.config/autostart/${proc}.desktop"
      [ -f "$UA" ] && mv -f "$UA" "${UA}.disabled"
      if [ -f "/etc/xdg/autostart/${proc}.desktop" ]; then   # mask a system autostart
        mkdir -p "$HOME/.config/autostart"
        printf '[Desktop Entry]\nHidden=true\n' > "$HOME/.config/autostart/${proc}.desktop"
      fi
    done
  else
    echo "    coexisting — leaving the desktop to the existing manager; installing pool + login only."
    DESKTOP_ENABLED=0
  fi
fi

# --- 3. screen resolution (for the login image only) --------------------
RES="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"
[ -z "$RES" ] && RES="1920x1080"
echo "    login-image resolution: $RES"

# --- 4. dependencies ----------------------------------------------------
echo "==> ensuring dependencies"
command -v apt-get >/dev/null 2>&1 && sudo apt-get update -qq
ensure_pkg convert  imagemagick imagemagick imagemagick ImageMagick
ensure_pkg curl     curl        curl        curl        curl
ensure_pkg crontab  cron        cronie      cronie      cron
ensure_pkg jq       jq          jq          jq          jq          # JSON parse for wallhaven/bing sources
ensure_pkg python3  python3     python3     python3     python3     # local status web UI (wallpaper-web)
case "$DE" in *xfce*) ensure_pkg xfconf-query xfconf xfconf xfconf xfconf ;; esac
# KDE Plasma sets the wallpaper via plasma-apply-wallpaperimage (ships with
# plasma-workspace, so normally already present) or a qdbus fallback. We don't
# pull a package for it — just warn if neither is available.
case "$DE" in
  *kde*|*plasma*)
    command -v plasma-apply-wallpaperimage >/dev/null 2>&1 || command -v qdbus >/dev/null 2>&1 \
      || echo "    WARNING: no plasma-apply-wallpaperimage or qdbus found — install plasma-workspace for KDE wallpaper setting." >&2 ;;
esac
# Make sure a cron daemon is actually running.
sudo systemctl enable --now cron    >/dev/null 2>&1 \
  || sudo systemctl enable --now cronie >/dev/null 2>&1 || true

# --- 5. image pool + multi-source fetcher -------------------------------
mkdir -p "$POOL"
# Activity log: create the dir + an empty user-owned file up front.
mkdir -p "$LOG_DIR" && touch "$LOG_FILE" 2>/dev/null
echo "    log: $LOG_FILE"
echo "    sources: $SOURCES"

# Fetcher feeds the pool for BOTH the desktop and login consumers, so it's
# installed regardless of coexist mode.
echo "==> installing $FETCH_BIN"
TMP="$(mktemp)"
sed -e "s#@@POOL@@#${POOL}#g" -e "s#@@LOG@@#${LOG_FILE}#g" -e "s#@@RES@@#${RES}#g" \
    -e "s#@@SOURCES@@#${SOURCES}#g" -e "s#@@LOCALDIR@@#${LOCALDIR}#g" -e "s#@@CONFIG@@#${CONFIG_FILE}#g" \
    "$REPO_DIR/bin/fetch-wallpaper.sh" > "$TMP"
sudo install -m 0755 -o root -g root "$TMP" "$FETCH_BIN"
rm -f "$TMP"

# Seed the pool now so nothing is blank until the first cron tick. Fetch a batch
# up front (SEED_COUNT) so random rotation has variety immediately rather than
# repeating one image while cron slowly fills the pool. Each fetch shuffles
# sources, so the batch is varied; failures (offline) just yield a smaller pool.
if ! ls "$POOL"/*.jpg >/dev/null 2>&1; then
  echo "==> seeding pool (up to $SEED_COUNT images)"
  got=0
  for _ in $(seq "$SEED_COUNT"); do
    "$FETCH_BIN" && got=$((got + 1))
  done
  if [ "$got" -gt 0 ]; then
    echo "    seeded $got/$SEED_COUNT"
  else
    echo "    WARNING: seed fetch failed (no internet?). Pool empty for now." >&2
  fi
fi

# Quote-cache refresher (keeps the overlay quotes changing via an API).
echo "==> installing $FETCHQ_BIN"
TMP="$(mktemp)"
sed -e "s#@@LOG@@#${LOG_FILE}#g" "$REPO_DIR/bin/fetch-quotes.sh" > "$TMP"
sudo install -m 0755 -o root -g root "$TMP" "$FETCHQ_BIN"
rm -f "$TMP"
"$FETCHQ_BIN" >/dev/null 2>&1 || true   # seed the quote cache once

# --- 5b. local status + control web UI ----------------------------------
echo "==> installing status web UI ($WEB_BIN)"
mkdir -p "$WEBDIR"
# Default config (preserved across re-installs).
if [ ! -f "$CONFIG_FILE" ]; then
  cat > "$CONFIG_FILE" <<'CFG'
# wallpaper-rotator config (managed by wallpaper-web)
INTERVAL_MIN=10
OVERLAY_QUOTE=0
OVERLAY_QUOTE_DETAIL=0
OVERLAY_STATS=0
QUOTE_POS=south
STATS_POS=northeast
OVERLAY_SIZE=medium
OVERLAY_THEME=dark
OVERLAY_FONT=default
STATS_SPARKLINE=0
OVERLAY_WEATHER=0
WEATHER_POS=north
WEATHER_LOCATION=
THEME=
CFG
fi

# Status-page generator.
TMP="$(mktemp)"
sed -e "s#@@POOL@@#${POOL}#g" -e "s#@@LOG@@#${LOG_FILE}#g" -e "s#@@WEBDIR@@#${WEBDIR}#g" \
    -e "s#@@RES@@#${RES}#g" -e "s#@@SOURCES@@#${SOURCES}#g" -e "s#@@CONFIG@@#${CONFIG_FILE}#g" \
    "$REPO_DIR/bin/gen-status.sh" > "$TMP"
sudo install -m 0755 -o root -g root "$TMP" "$GENSTATUS_BIN"
rm -f "$TMP"

# Control server (Python) + its launcher.
TMP="$(mktemp)"
sed -e "s#@@WEBDIR@@#${WEBDIR}#g" -e "s#@@PORT@@#${WEB_PORT}#g" -e "s#@@CONFIG@@#${CONFIG_FILE}#g" \
    -e "s#@@GENSTATUS@@#${GENSTATUS_BIN}#g" -e "s#@@SETWP@@#${SETWP_BIN}#g" \
    "$REPO_DIR/bin/wallpaper-web.py" > "$TMP"
sudo install -m 0755 -o root -g root "$TMP" "$PYBIN"
rm -f "$TMP"
TMP="$(mktemp)"
sed -e "s#@@PYBIN@@#${PYBIN}#g" "$REPO_DIR/bin/wallpaper-web.sh" > "$TMP"
sudo install -m 0755 -o root -g root "$TMP" "$WEB_BIN"
rm -f "$TMP"
"$GENSTATUS_BIN" 2>/dev/null || true   # generate the page once now

# --- 6. desktop wallpaper setter ----------------------------------------
if [ "$DESKTOP_ENABLED" = 1 ]; then
  echo "==> installing $SETWP_BIN"
  TMP="$(mktemp)"
  sed -e "s#@@POOL@@#${POOL}#g" -e "s#@@LOG@@#${LOG_FILE}#g" -e "s#@@CONFIG@@#${CONFIG_FILE}#g" -e "s#@@RES@@#${RES}#g" "$REPO_DIR/bin/set-wallpaper.sh" > "$TMP"
  sudo install -m 0755 -o root -g root "$TMP" "$SETWP_BIN"
  rm -f "$TMP"

  # XFCE: set zoom style + hand desktop cycling to cron (disable native cycler).
  case "$DE" in
    *xfce*)
      for ws in $(xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null | grep -oE '/backdrop/screen0/[^/]+/workspace[0-9]+' | sort -u); do
        xfconf-query -c xfce4-desktop -p "$ws/image-style" -n -t int -s 4 2>/dev/null \
          || xfconf-query -c xfce4-desktop -p "$ws/image-style" -s 4 2>/dev/null
        xfconf-query -c xfce4-desktop -p "$ws/backdrop-cycle-enable" -s false 2>/dev/null || true
      done ;;
  esac
else
  echo "==> SKIPPED desktop setup (coexisting with existing rotator)"
fi

# --- 7. cron jobs (download + prune + rotate) ---------------------------
echo "==> installing cron jobs"
# Rotate interval from config (preserved across re-installs; the web UI updates it).
CFG_INTERVAL="$(grep '^INTERVAL_MIN=' "$CONFIG_FILE" 2>/dev/null | cut -d= -f2 | tr -dc '0-9')"
[ -n "$CFG_INTERVAL" ] || CFG_INTERVAL=10
NEWCRON="$(sed -e "s#@@POOL@@#${POOL}#g" -e "s#@@SETWP@@#${SETWP_BIN}#g" -e "s#@@FETCH@@#${FETCH_BIN}#g" -e "s#@@FETCHQ@@#${FETCHQ_BIN}#g" -e "s#@@GENSTATUS@@#${GENSTATUS_BIN}#g" -e "s#@@INTERVAL@@#${CFG_INTERVAL}#g" -e "s#@@LOG@@#${LOG_FILE}#g" "$REPO_DIR/cron/wallpaper.cron")"
# Drop our managed block AND any legacy unwrapped wallpaper lines (pre-marker
# manual setups) so migrating/re-running never duplicates jobs.
# When coexisting, drop the desktop-rotate line so we never fight the other manager.
[ "$DESKTOP_ENABLED" = 1 ] || NEWCRON="$(printf '%s' "$NEWCRON" | grep -v '/set-wallpaper\.sh')"
EXISTING="$(crontab -l 2>/dev/null \
  | sed '/# >>> wallpaper-rotator >>>/,/# <<< wallpaper-rotator <<</d' \
  | grep -vE 'picsum\.photos|online-wallpapers/\*\.jpg|/set-wallpaper\.sh')"
printf '%s\n%s\n' "$EXISTING" "$NEWCRON" | sed '/^$/N;/^\n$/D' | crontab -

# Set the desktop now so it isn't blank until the first cron tick.
[ "$DESKTOP_ENABLED" = 1 ] && "$SETWP_BIN" || true

# --- 8. login background (LightDM only) ---------------------------------
if [ -n "$GREETER_CONF" ]; then
  echo "==> setting up LightDM login background"
  TMP="$(mktemp)"
  sed -e "s#@@POOL@@#${POOL}#g" -e "s#@@TARGET@@#${TARGET_IMG}#g" -e "s#@@RESOLUTION@@#${RES}#g" \
      -e "s#@@LOG@@#${LOG_FILE}#g" "$REPO_DIR/bin/random-login-bg.sh" > "$TMP"
  sudo install -m 0755 -o root -g root "$TMP" "$LOGIN_BIN"
  rm -f "$TMP"
  sudo "$LOGIN_BIN" || echo "    (login image not generated — pool may be empty)"

  TMP="$(mktemp)"
  sed "s#@@USER@@#${TARGET_USER}#g" "$REPO_DIR/sudoers.d/random-login-bg" > "$TMP"
  if sudo visudo -c -f "$TMP" >/dev/null; then
    sudo install -m 0440 -o root -g root "$TMP" /etc/sudoers.d/random-login-bg
  else
    echo "    ERROR: sudoers file failed validation; not installed." >&2
  fi
  rm -f "$TMP"

  mkdir -p "$USER_HOME/.config/autostart"
  install -m 0644 "$REPO_DIR/autostart/random-login-bg.desktop" \
    "$USER_HOME/.config/autostart/random-login-bg.desktop"

  sudo bash -c '
    conf="'"$GREETER_CONF"'"; img="'"$TARGET_IMG"'"
    [ -f "$conf" ] || printf "[greeter]\n" > "$conf"
    grep -q "^\[greeter\]" "$conf" || printf "\n[greeter]\n" >> "$conf"
    if grep -q "^background=" "$conf"; then
      sed -i "s#^background=.*#background=${img}#" "$conf"
    else
      sed -i "0,/^\[greeter\]/s##[greeter]\nbackground=${img}#" "$conf"
    fi
  '
else
  echo "==> SKIPPED login background (no LightDM)."
fi

echo
echo "Done."
if [ "$DESKTOP_ENABLED" = 1 ]; then
  echo "  Desktop  : rotates every ${CFG_INTERVAL} min via cron + set-wallpaper.sh (${DE:-feh fallback})"
else
  echo "  Desktop  : left to the existing rotator (coexist mode)"
fi
if [ -n "$GREETER_CONF" ]; then
  echo "  Login    : refreshes each login (LightDM, $RES)"
else
  echo "  Login    : skipped (LightDM not detected)"
fi
echo "  Pool     : $POOL"
echo "  Status UI: run 'wallpaper-web' -> http://127.0.0.1:${WEB_PORT}"
