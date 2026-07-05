#!/bin/bash
# build-gdm-greeter.sh — set the GDM (GNOME) login-screen background, the
# GDM-equivalent of the LightDM `background=` line.
#
# GDM has no plain config key for the greeter background: the login wallpaper is
# the GNOME-Shell theme's `#lockDialogGroup` rule, compiled into a *.gresource.
# St (the shell CSS engine) only reliably renders a background image that is
# EMBEDDED in the gresource (an external file:// path silently fails in the
# greeter sandbox — that's how Zorin ships its own assets/login-background.png).
# So we rebuild the active theme gresource with our image embedded as that asset,
# then select it via update-alternatives.
#
# Because the image is baked in, rotating the login background means rebuilding
# the gresource — cheap (~1-2s) and done at each login by the autostart entry,
# so the NEXT login shows a fresh image. We always rebase on the stock/Zorin
# theme (never on our own output), so re-runs never compound.
#
# Re-run after a major gnome-shell / theme package update to rebase on the new
# stock theme (the old wr gresource keeps working until you do).
#
# Usage:
#   build-gdm-greeter.sh <IMAGE>   embed the given image (any format ImageMagick reads)
#   build-gdm-greeter.sh --refresh pick a random image from the pool and embed it
#   build-gdm-greeter.sh           embed $TARGET if it exists
#   needs: gresource + glib-compile-resources (libglib2.0-bin + libglib2.0-dev-bin),
#          ImageMagick `convert`, sudo
set -e

# --- config (placeholders substituted by install.sh; fall back when run raw) --
POOL="@@POOL@@";       [ "$POOL" = "@@POOL""@@" ]             && POOL="$HOME/Pictures/online-wallpapers"
TARGET="@@TARGET@@";   [ "$TARGET" = "@@TARGET""@@" ]         && TARGET="/usr/share/backgrounds/login-random.jpg"
RES="@@RESOLUTION@@";  [ "$RES" = "@@RESOLUTION""@@" ]        && RES="$(xrandr 2>/dev/null | awk '/\*/{print $1; exit}')"; [ -n "$RES" ] || RES="1920x1080"
LOG="@@LOG@@";         [ "$LOG" = "@@LOG""@@" ]               && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null; }

WR_OUT="/usr/share/gnome-shell/gnome-shell-theme-wr.gresource"   # our compiled theme
ALT_LINK="/usr/share/gnome-shell/gdm-theme.gresource"           # update-alternatives master link
ALT_NAME="gdm-theme.gresource"
PREFIX="/org/gnome/shell/theme"
ASSET="assets/login-background.png"                             # the embedded bg asset

for bin in gresource glib-compile-resources convert; do
  command -v "$bin" >/dev/null 2>&1 || { echo "ERROR: $bin not found (need libglib2.0-bin, libglib2.0-dev-bin, imagemagick)" >&2; exit 1; }
done

# --- login-rotate toggle ------------------------------------------------------
# The per-login autostart passes --login; honour LOGIN_ROTATE only there. A
# manual rebuild (web UI "Refresh now", or install.sh) omits --login and always
# rebuilds, so the toggle never blocks an explicit refresh.
CONFIG="@@CONFIG@@"; [ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
case " $* " in
  *" --login "*)
    rot=$(sed -n "s/^LOGIN_ROTATE=['\"]*\([0-9]\).*/\1/p" "$CONFIG" 2>/dev/null | tail -1)
    [ "$rot" = "0" ] && { log "[gdm] skip (login rotate off)"; exit 0; }
    ;;
esac

# --- resolve the image to embed -----------------------------------------------
case "${1:-}" in
  --refresh) IMAGE="$(find "$POOL" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) 2>/dev/null | shuf -n 1)" ;;
  "")        IMAGE="$TARGET" ;;
  *)         IMAGE="$1" ;;
esac
[ -n "$IMAGE" ] && [ -f "$IMAGE" ] || { echo "ERROR: no source image (pool empty or path missing): '${IMAGE:-}'" >&2; log "[gdm] skip (no image)"; exit 1; }

# --- pick the SOURCE gresource: HIGHEST-PRIORITY candidate that is NOT ours, so
# we rebase on the real active theme (e.g. ZorinBlue-Dark, not stock GNOME) and
# re-runs stay correct even once our alt is selected.
SRC=""
if update-alternatives --query "$ALT_NAME" >/dev/null 2>&1; then
  SRC="$(update-alternatives --query "$ALT_NAME" 2>/dev/null | awk -v wr="$WR_OUT" '
    /^Alternative: /{p=$2}
    /^Priority: /{if(p!=wr){print $2"\t"p}}
  ' | sort -rn | while IFS=$'\t' read -r prio path; do [ -f "$path" ] && echo "$path" && break; done)"
fi
if [ -z "$SRC" ]; then
  cand="$(readlink -f "$ALT_LINK" 2>/dev/null)"
  [ -n "$cand" ] && [ "$cand" != "$WR_OUT" ] && SRC="$cand"
fi
[ -n "$SRC" ] && [ -f "$SRC" ] || { echo "ERROR: could not locate a stock GDM gresource to rebase on" >&2; exit 1; }
echo "==> source theme gresource: $SRC"

# --- extract every entry into a build tree (strip the resource prefix) --------
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
mapfile -t ENTRIES < <(gresource list "$SRC")
[ "${#ENTRIES[@]}" -gt 0 ] || { echo "ERROR: gresource has no entries" >&2; exit 1; }
for res in "${ENTRIES[@]}"; do
  rel="${res#"$PREFIX"/}"
  dst="$BUILD/$rel"
  mkdir -p "$(dirname "$dst")"
  gresource extract "$SRC" "$res" > "$dst"
done

# --- locate the greeter stylesheet inside the extracted tree ------------------
# St loads the theme's default stylesheet. Stock GNOME ships gnome-shell.css flat
# at $PREFIX/gnome-shell.css (the greeter's gdm.css @imports it), but distro
# themes vary: some nest or rename it, and some ship a *self-contained* greeter
# theme with ONLY gdm.css and no gnome-shell.css at all (Zorin's ZorinBlue-Dark
# gdm-theme.gresource is one — it bundles the full rule set into gdm.css). So
# discover the stylesheet from the extracted entries, preferring the in-session
# sheet where present and falling back to the greeter's own gdm.css otherwise:
#   1. exact gnome-shell.css (shallowest match)
#   2. a gnome-shell*.css variant (e.g. gnome-shell-dark.css)
#   3. gdm.css — the greeter stylesheet itself (self-contained distro themes)
CSS_REL="$(cd "$BUILD" && find . -name 'gnome-shell.css'  -printf '%d\t%P\n' 2>/dev/null | sort -n | head -1 | cut -f2-)"
[ -n "$CSS_REL" ] || \
CSS_REL="$(cd "$BUILD" && find . -name 'gnome-shell*.css' -printf '%d\t%P\n' 2>/dev/null | sort -n | head -1 | cut -f2-)"
[ -n "$CSS_REL" ] || \
CSS_REL="$(cd "$BUILD" && find . -name 'gdm.css'          -printf '%d\t%P\n' 2>/dev/null | sort -n | head -1 | cut -f2-)"
if [ -z "$CSS_REL" ]; then
  echo "ERROR: no greeter stylesheet (gnome-shell.css or gdm.css) found in source gresource: $SRC" >&2
  echo "       gresource entries were:" >&2
  printf '         %s\n' "${ENTRIES[@]}" >&2
  exit 1
fi
CSS="$BUILD/$CSS_REL"
CSS_DIR="$(dirname "$CSS_REL")"               # "." (flat) or e.g. "ZorinBlue-Dark"
echo "==> greeter stylesheet: $CSS_REL"

# --- embed our image as the login-background asset (cover-fit to screen) -------
# Sit it alongside the stylesheet (CSS_DIR/assets/…) so the relative url() below
# resolves whether the CSS is flat or nested under a theme subdir. ASSET stays
# the CSS-relative reference ("assets/login-background.png"); ASSET_REL is its
# actual path within the gresource tree.
if [ "$CSS_DIR" = "." ]; then ASSET_REL="$ASSET"; else ASSET_REL="$CSS_DIR/$ASSET"; fi
mkdir -p "$BUILD/$(dirname "$ASSET_REL")"
convert "$IMAGE" -gravity center -resize "${RES}^" -extent "$RES" "$BUILD/$ASSET_REL"
# Ensure the asset is in the file list (a theme may not ship one at this path).
HAVE_ASSET=0; for res in "${ENTRIES[@]}"; do [ "${res#"$PREFIX"/}" = "$ASSET_REL" ] && HAVE_ASSET=1; done
[ "$HAVE_ASSET" = 1 ] || ENTRIES+=("$PREFIX/$ASSET_REL")

# --- ensure a last-wins #lockDialogGroup rule points at that embedded asset ----
# url() is relative to the CSS file, so reference "assets/…" (the asset sits in
# CSS_DIR/assets). Resource-relative renders reliably (unlike an external
# file://). Appended so it overrides whatever the theme set, and covers themes
# with no image rule.
MARKER="wallpaper-rotator GDM login background"
if ! grep -qF "$MARKER" "$CSS"; then
  printf '\n/* %s */\n#lockDialogGroup { background: #1a1a1a url("%s"); background-size: cover; background-repeat: no-repeat; background-position: center; }\n' \
    "$MARKER" "$ASSET" >> "$CSS"
fi

# --- regenerate the gresource XML listing every file --------------------------
XML="$BUILD/wr.gresource.xml"
{
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<gresources>\n  <gresource prefix="%s">\n' "$PREFIX"
  for res in "${ENTRIES[@]}"; do printf '    <file>%s</file>\n' "${res#"$PREFIX"/}"; done
  printf '  </gresource>\n</gresources>\n'
} > "$XML"

# --- compile + install --------------------------------------------------------
OUT="$BUILD/out.gresource"
glib-compile-resources "$XML" --target="$OUT" --sourcedir="$BUILD"
sudo install -m 0644 -o root -g root "$OUT" "$WR_OUT"
echo "==> installed $WR_OUT ($(stat -c%s "$WR_OUT") bytes, embedded $(basename "$IMAGE"))"
log "[gdm] ok img=$(basename "$IMAGE")"

# --- register + select via update-alternatives (manual, reversible) -----------
sudo update-alternatives --install "$ALT_LINK" "$ALT_NAME" "$WR_OUT" 200 >/dev/null
sudo update-alternatives --set "$ALT_NAME" "$WR_OUT" >/dev/null
echo "==> GDM greeter theme set to wallpaper-rotator (alternative selected)"
echo "    revert any time: sudo update-alternatives --remove $ALT_NAME $WR_OUT"
