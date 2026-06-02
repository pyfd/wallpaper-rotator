#!/bin/bash
#
# wallpaper-rotator installer
# -------------------------------------------------------------------------
# Sets up an auto-rotating desktop wallpaper (XFCE/xfdesktop folder-cycle)
# AND an auto-rotating LightDM login background, both fed from one image pool
# that cron refills every 10 minutes from picsum.photos.
#
# Run as your normal user (NOT root). It calls sudo only for the system bits.
# Idempotent: safe to re-run after a `git pull`.
# -------------------------------------------------------------------------
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 0. sanity ----------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  echo "ERROR: run as your normal user, not root (sudo is used internally)." >&2
  exit 1
fi

TARGET_USER="$USER"
USER_HOME="$HOME"
POOL="$USER_HOME/Pictures/online-wallpapers"
TARGET_IMG="/usr/share/backgrounds/login-random.jpg"
BIN_DST="/usr/local/bin/random-login-bg.sh"
GREETER_CONF="/etc/lightdm/lightdm-gtk-greeter.conf"

echo "==> wallpaper-rotator install (user: $TARGET_USER)"

# --- 1. screen resolution (login image) ---------------------------------
RES="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"
if [ -z "${RES:-}" ]; then
  RES="1366x768"
  echo "    xrandr gave nothing; defaulting login image to $RES"
else
  echo "    detected resolution: $RES"
fi

# --- 2. active monitor node for xfdesktop -------------------------------
# Prefer a node xfconf already knows about; else derive from xrandr.
MON="$(xfconf-query -c xfce4-desktop -p /backdrop -l 2>/dev/null \
        | grep -oE 'monitor[^/]+' | head -1 || true)"
if [ -z "${MON:-}" ]; then
  CONN="$(xrandr 2>/dev/null | awk '/ connected/{print $1; exit}')"
  [ -n "${CONN:-}" ] && MON="monitor${CONN}"
fi
echo "    xfce monitor node: ${MON:-<none — desktop step will be skipped>}"

# --- 3. dependencies ----------------------------------------------------
echo "==> installing apt dependencies"
sudo apt-get update -qq
sudo apt-get install -y imagemagick curl cron lightdm lightdm-gtk-greeter xfconf >/dev/null

# --- 4. image pool ------------------------------------------------------
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

# --- 5. login-bg script -------------------------------------------------
echo "==> installing $BIN_DST"
TMP_BIN="$(mktemp)"
sed -e "s#@@POOL@@#${POOL}#g" \
    -e "s#@@TARGET@@#${TARGET_IMG}#g" \
    -e "s#@@RESOLUTION@@#${RES}#g" \
    "$REPO_DIR/bin/random-login-bg.sh" > "$TMP_BIN"
sudo install -m 0755 -o root -g root "$TMP_BIN" "$BIN_DST"
rm -f "$TMP_BIN"
# generate the first login image now
sudo "$BIN_DST" || echo "    (login image not generated — pool may be empty)"

# --- 6. sudoers ---------------------------------------------------------
echo "==> installing /etc/sudoers.d/random-login-bg"
TMP_SUDO="$(mktemp)"
sed "s#@@USER@@#${TARGET_USER}#g" "$REPO_DIR/sudoers.d/random-login-bg" > "$TMP_SUDO"
if sudo visudo -c -f "$TMP_SUDO" >/dev/null; then
  sudo install -m 0440 -o root -g root "$TMP_SUDO" /etc/sudoers.d/random-login-bg
else
  echo "    ERROR: sudoers file failed validation; not installed." >&2
fi
rm -f "$TMP_SUDO"

# --- 7. autostart entry -------------------------------------------------
echo "==> installing autostart entry"
mkdir -p "$USER_HOME/.config/autostart"
install -m 0644 "$REPO_DIR/autostart/random-login-bg.desktop" \
  "$USER_HOME/.config/autostart/random-login-bg.desktop"

# --- 8. greeter background line -----------------------------------------
echo "==> pointing greeter at $TARGET_IMG"
sudo bash -c '
  set -e
  conf="'"$GREETER_CONF"'"
  img="'"$TARGET_IMG"'"
  [ -f "$conf" ] || printf "[greeter]\n" > "$conf"
  if grep -q "^\[greeter\]" "$conf"; then :; else printf "\n[greeter]\n" >> "$conf"; fi
  if grep -q "^background=" "$conf"; then
    sed -i "s#^background=.*#background=${img}#" "$conf"
  else
    sed -i "0,/^\[greeter\]/s##[greeter]\nbackground='"$TARGET_IMG"'#" "$conf"
  fi
'

# --- 9. cron jobs -------------------------------------------------------
echo "==> installing cron jobs (download + prune)"
NEWCRON="$(sed "s#@@POOL@@#${POOL}#g" "$REPO_DIR/cron/wallpaper.cron")"
# strip any previous managed block, then append the fresh one
EXISTING="$(crontab -l 2>/dev/null | sed '/# >>> wallpaper-rotator >>>/,/# <<< wallpaper-rotator <<</d')"
printf '%s\n%s\n' "$EXISTING" "$NEWCRON" | sed '/^$/N;/^\n$/D' | crontab -

# --- 10. xfdesktop folder-cycle ----------------------------------------
if [ -n "${MON:-}" ]; then
  echo "==> enabling XFCE wallpaper folder-cycle on $MON"
  BASE="/backdrop/screen0/${MON}/workspace0"
  FIRST="$(ls -t "$POOL"/*.jpg 2>/dev/null | head -1 || true)"
  set_prop() { xfconf-query -c xfce4-desktop -p "$1" -n -t "$2" -s "$3" 2>/dev/null \
               || xfconf-query -c xfce4-desktop -p "$1" -s "$3"; }
  [ -n "$FIRST" ] && set_prop "$BASE/last-image" string "$FIRST"
  set_prop "$BASE/image-style"                 int  4
  set_prop "$BASE/backdrop-cycle-enable"       bool true
  set_prop "$BASE/backdrop-cycle-random-order" bool true
else
  echo "==> SKIPPED desktop cycle (no monitor node; run inside an XFCE session)."
fi

echo
echo "Done. Login background rotates each login; desktop cycles via xfdesktop."
echo "Pool: $POOL   |   Login image: $TARGET_IMG   |   Resolution: $RES"
