#!/bin/bash
#
# wallpaper-rotator installer
# -------------------------------------------------------------------------
# Auto-rotating desktop wallpaper on any common Linux desktop (XFCE, GNOME,
# Cinnamon, MATE, or a feh fallback), plus an auto-rotating LightDM login
# background where LightDM is the display manager. One image pool, refilled
# from picsum.photos by cron, drives both.
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

TARGET_USER="$USER"
USER_HOME="$HOME"
POOL="$USER_HOME/Pictures/online-wallpapers"
TARGET_IMG="/usr/share/backgrounds/login-random.jpg"
LOGIN_BIN="/usr/local/bin/random-login-bg.sh"
SETWP_BIN="/usr/local/bin/set-wallpaper.sh"

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
  for p in xfce4-session gnome-session cinnamon-session mate-session plasmashell; do
    pgrep -x "$p" >/dev/null 2>&1 && { DE="$p"; break; }
  done
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
case "$DE" in *xfce*) ensure_pkg xfconf-query xfconf xfconf xfconf xfconf ;; esac
# Make sure a cron daemon is actually running.
sudo systemctl enable --now cron    >/dev/null 2>&1 \
  || sudo systemctl enable --now cronie >/dev/null 2>&1 || true

# --- 5. image pool (seed one image) -------------------------------------
mkdir -p "$POOL"
if ! ls "$POOL"/*.jpg >/dev/null 2>&1; then
  echo "==> seeding pool with one image"
  if curl -fsL "https://picsum.photos/1600/900" -o /tmp/wall.jpg \
       && file --mime-type /tmp/wall.jpg | grep -q 'image/'; then
    mv /tmp/wall.jpg "$POOL/$(date +%s).jpg"
  else
    echo "    WARNING: seed download failed (no internet?). Pool is empty for now." >&2
    rm -f /tmp/wall.jpg
  fi
fi

# --- 6. desktop wallpaper setter ----------------------------------------
echo "==> installing $SETWP_BIN"
TMP="$(mktemp)"
sed "s#@@POOL@@#${POOL}#g" "$REPO_DIR/bin/set-wallpaper.sh" > "$TMP"
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

# --- 7. cron jobs (download + prune + rotate) ---------------------------
echo "==> installing cron jobs"
NEWCRON="$(sed -e "s#@@POOL@@#${POOL}#g" -e "s#@@SETWP@@#${SETWP_BIN}#g" "$REPO_DIR/cron/wallpaper.cron")"
# Drop our managed block AND any legacy unwrapped wallpaper lines (pre-marker
# manual setups) so migrating/re-running never duplicates jobs.
EXISTING="$(crontab -l 2>/dev/null \
  | sed '/# >>> wallpaper-rotator >>>/,/# <<< wallpaper-rotator <<</d' \
  | grep -vE 'picsum\.photos|online-wallpapers/\*\.jpg|/set-wallpaper\.sh')"
printf '%s\n%s\n' "$EXISTING" "$NEWCRON" | sed '/^$/N;/^\n$/D' | crontab -

# Set the desktop now so it isn't blank until the first cron tick.
"$SETWP_BIN" || true

# --- 8. login background (LightDM only) ---------------------------------
if [ -n "$GREETER_CONF" ]; then
  echo "==> setting up LightDM login background"
  TMP="$(mktemp)"
  sed -e "s#@@POOL@@#${POOL}#g" -e "s#@@TARGET@@#${TARGET_IMG}#g" -e "s#@@RESOLUTION@@#${RES}#g" \
      "$REPO_DIR/bin/random-login-bg.sh" > "$TMP"
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
echo "  Desktop  : rotates every 10 min via cron + set-wallpaper.sh (${DE:-feh fallback})"
if [ -n "$GREETER_CONF" ]; then
  echo "  Login    : refreshes each login (LightDM, $RES)"
else
  echo "  Login    : skipped (LightDM not detected)"
fi
echo "  Pool     : $POOL"
