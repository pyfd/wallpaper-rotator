#!/bin/bash
# Generate a self-contained status page for wallpaper-rotator from the activity
# log + pool + config. Written to @@WEBDIR@@/index.html and served by
# wallpaper-web.sh. Run from cron each tick to keep it fresh, and once at
# wallpaper-web startup. Placeholders (@@...@@) substituted by install.sh.
set -uo pipefail

POOL="@@POOL@@"
LOG="@@LOG@@"
WEBDIR="@@WEBDIR@@"
RES="@@RES@@"
SOURCES="@@SOURCES@@"
# Split-literal guards so install.sh's sed doesn't rewrite them (see fetch-wallpaper.sh).
[ "$POOL"    = "@@POOL""@@" ]    && POOL="$HOME/Pictures/online-wallpapers"
[ "$LOG"     = "@@LOG""@@" ]     && LOG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/wallpaper.log"
[ "$WEBDIR"  = "@@WEBDIR""@@" ]  && WEBDIR="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/web"
[ "$RES"     = "@@RES""@@" ]     && RES="unknown"
[ "$SOURCES" = "@@SOURCES""@@" ] && SOURCES="wallhaven bing picsum local"

CONFIG="@@CONFIG@@"
[ "$CONFIG" = "@@CONFIG""@@" ] && CONFIG="${XDG_STATE_HOME:-$HOME/.local/state}/wallpaper-rotator/config"
INTERVAL_MIN=10; OVERLAY_QUOTE=0; OVERLAY_QUOTE_DETAIL=0; OVERLAY_STATS=0
QUOTE_POS=south; STATS_POS=northeast; OVERLAY_SIZE=medium; OVERLAY_THEME=dark; OVERLAY_FONT=default
OVERLAY_STYLE=scrim
STATS_SPARKLINE=0; OVERLAY_WEATHER=0; WEATHER_POS=north; WEATHER_LOCATION=; OVERLAY_WEATHER_ICON=0; OVERLAY_WEATHER_ICON_COLOR=0; OVERLAY_WEATHER_FORECAST=0
OVERLAY_CLOCK=0; CLOCK_STYLE=digital; CLOCK_POS=northwest; CLOCK_24H=1; CLOCK_DATE=0; THEME=
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

mkdir -p "$WEBDIR"
[ -f "$LOG" ] || : > "$LOG"

# Installed version (CL-derived, stamped by install.sh in the state dir).
WR_VERSION=; WR_VERSION_ID=; WR_VERSION_HOST=; WR_INSTALLED_AT=; WR_INSTALLED_ON=
VERFILE="$(dirname "$LOG")/version"
[ -f "$VERFILE" ] && . "$VERFILE" 2>/dev/null

# --- gather stats -----------------------------------------------------------
pool_count=$(ls "$POOL"/*.jpg "$POOL"/*.jpeg "$POOL"/*.png 2>/dev/null | wc -l)
pool_size=$(du -sh "$POOL" 2>/dev/null | cut -f1)
last_rotate=$(grep '\[rotate\]' "$LOG" 2>/dev/null | tail -1)
last_dl=$(grep '\[download\] src=.* ok' "$LOG" 2>/dev/null | tail -1)
cur_img=$(printf '%s' "$last_rotate" | grep -oP 'img=\K\S+' || true)
backend=$(printf '%s' "$last_rotate" | grep -oP 'backend=\K\S+' || true)
de=$(printf '%s' "$last_rotate" | grep -oP 'de=\K\S+' || true)
rotate_when=$(printf '%s' "$last_rotate" | grep -oP '^\S+ \S+' || true)
dl_when=$(printf '%s' "$last_dl" | grep -oP '^\S+ \S+' || true)
# NB: `grep -c` prints 0 AND exits non-zero on no match, so `|| echo 0` would
# append a SECOND 0 ("0\n0"). Capture directly and default an empty (missing file).
dl_fail=$(grep -c '\[download\] fail' "$LOG" 2>/dev/null); dl_fail=${dl_fail:-0}
dl_miss=$(grep -c '\[download\] src=.* miss' "$LOG" 2>/dev/null); dl_miss=${dl_miss:-0}
pruned_total=$(grep -oP '\[prune\] removed=\K[0-9]+' "$LOG" 2>/dev/null | awk '{s+=$1} END{print s+0}')

# Thumbnail of the current wallpaper (resized). When an overlay is active the
# real desktop shows the rendered frame, so prefer the newest rendered image.
thumb_src="$POOL/$cur_img"
if [ "${OVERLAY_QUOTE:-0}" = 1 ] || [ "${OVERLAY_STATS:-0}" = 1 ]; then
  r=$(ls -t "$(dirname "$LOG")/rendered"/*.jpg 2>/dev/null | head -1)
  [ -n "$r" ] && thumb_src="$r"
fi
[ -n "${thumb_src:-}" ] && [ -f "$thumb_src" ] || thumb_src=$(ls -t "$POOL"/*.jpg 2>/dev/null | head -1)
have_thumb=0
if [ -n "${thumb_src:-}" ] && [ -f "$thumb_src" ]; then
  convert "$thumb_src" -resize 520x "$WEBDIR/current.jpg" 2>/dev/null && have_thumb=1
fi

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Per-source download tallies -> HTML rows.
src_rows=""
for s in $SOURCES; do
  n=$(grep -c "\[download\] src=$s ok" "$LOG" 2>/dev/null); n=${n:-0}
  src_rows="${src_rows}<tr><td>${s}</td><td class=num>${n}</td></tr>"
done

recent=$(tail -n 18 "$LOG" 2>/dev/null | tac | esc)
now=$(date '+%Y-%m-%d %H:%M:%S')

# Controls form state (current config reflected in the widgets).
opts_for() {  # $1=current value, $2..=options -> <option> HTML
  local cur="$1"; shift; local o="" v s
  for v in "$@"; do s=""; [ "$cur" = "$v" ] && s=" selected"; o="$o<option value=\"$v\"$s>$v</option>"; done
  printf '%s' "$o"
}
int_opts=""
for n in 3 5 10 15 30 60; do
  sel=""; [ "${INTERVAL_MIN:-10}" = "$n" ] && sel=" selected"
  int_opts="${int_opts}<option value=\"$n\"$sel>${n} min</option>"
done
qchk="";  [ "${OVERLAY_QUOTE:-0}" = 1 ]        && qchk=" checked"
qdchk=""; [ "${OVERLAY_QUOTE_DETAIL:-0}" = 1 ] && qdchk=" checked"
schk="";  [ "${OVERLAY_STATS:-0}" = 1 ]        && schk=" checked"
spchk=""; [ "${STATS_SPARKLINE:-0}" = 1 ]      && spchk=" checked"
wchk="";  [ "${OVERLAY_WEATHER:-0}" = 1 ]      && wchk=" checked"
wichk=""; [ "${OVERLAY_WEATHER_ICON:-0}" = 1 ] && wichk=" checked"
wicchk="";[ "${OVERLAY_WEATHER_ICON_COLOR:-0}" = 1 ] && wicchk=" checked"
wfchk=""; [ "${OVERLAY_WEATHER_FORECAST:-0}" = 1 ] && wfchk=" checked"
clkchk="";[ "${OVERLAY_CLOCK:-0}" = 1 ]        && clkchk=" checked"
c24chk="";[ "${CLOCK_24H:-1}" = 1 ]            && c24chk=" checked"
cdchk=""; [ "${CLOCK_DATE:-0}" = 1 ]           && cdchk=" checked"
POSNS="northwest north northeast west center east southwest south southeast"
qpos_opts=$(opts_for "${QUOTE_POS:-south}" $POSNS)
spos_opts=$(opts_for "${STATS_POS:-northeast}" $POSNS)
wpos_opts=$(opts_for "${WEATHER_POS:-north}" $POSNS)
cpos_opts=$(opts_for "${CLOCK_POS:-northwest}" $POSNS)
cstyle_opts=$(opts_for "${CLOCK_STYLE:-digital}" digital analogue)
size_opts=$(opts_for "${OVERLAY_SIZE:-medium}" small medium large)
theme_opts=$(opts_for "${OVERLAY_THEME:-dark}" dark light accent)
style_opts=$(opts_for "${OVERLAY_STYLE:-scrim}" scrim frosted editorial chips)
# Background theme select: "any" (empty) + presets.
bg_cur="${THEME:-}"; bg_sel=""; [ -z "$bg_cur" ] && bg_sel=" selected"
bgtheme_opts="<option value=\"\"$bg_sel>any</option>"
for t in nature landscape minimal space city abstract cars cycling animals dark forest ocean; do
  s=""; [ "$bg_cur" = "$t" ] && s=" selected"
  bgtheme_opts="$bgtheme_opts<option value=\"$t\"$s>$t</option>"
done
wloc_val=$(printf '%s' "${WEATHER_LOCATION:-}" | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g')
# Font dropdown: "default" + any of a common set that ImageMagick actually has.
# NB: match via here-string, NOT `printf ... | grep -qx`. Under `set -o pipefail`
# grep -q's early exit SIGPIPEs printf (exit 141), so the pipeline reports failure
# even on a match and every font got rejected (only "default" showed).
font_sel=""; [ "${OVERLAY_FONT:-default}" = default ] && font_sel=" selected"
font_opts="<option value=\"default\"$font_sel>default</option>"
avail_fonts=$(convert -list font 2>/dev/null | sed -n 's/^ *Font: //p')
for fc in DejaVu-Sans DejaVu-Serif DejaVu-Sans-Mono Liberation-Sans Liberation-Serif FreeSans FreeSerif; do
  if grep -qxF -- "$fc" <<<"$avail_fonts"; then
    s=""; [ "${OVERLAY_FONT:-default}" = "$fc" ] && s=" selected"
    font_opts="$font_opts<option value=\"$fc\"$s>$fc</option>"
  fi
done

# Inline SVG favicon (framed landscape: accent frame, gold sun, green hills) as a
# base64 data-URI so no server route or binary asset is needed. base64 is
# attribute-safe, unlike a raw SVG with #/<>/quotes.
favicon_svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="2" y="5" width="28" height="22" rx="5" fill="#14161a" stroke="#7cc4ff" stroke-width="2"/><circle cx="11" cy="12" r="3" fill="#ffd23f"/><path d="M3 25 L12 16 L18 21 L23 15 L29 25 Z" fill="#5fd17a"/></svg>'
favicon_b64="$(printf '%s' "$favicon_svg" | base64 -w0 2>/dev/null)"
host="$(hostname 2>/dev/null)"

# --- emit page --------------------------------------------------------------
cat > "$WEBDIR/index.html" <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=30>
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,${favicon_b64}">
<title>Wallpaper Rotator${host:+ · $host}${pool_count:+ — ${pool_count} imgs}</title>
<style>
:root{color-scheme:dark}
body{margin:0;background:#14161a;color:#e6e8ec;font:14px/1.5 system-ui,sans-serif}
.wrap{max-width:860px;margin:0 auto;padding:24px}
h1{font-size:20px;margin:0 0 2px} .sub{color:#8a909a;font-size:12px;margin-bottom:20px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin:16px 0}
.card{background:#1c1f26;border:1px solid #262a33;border-radius:10px;padding:14px}
.card .k{color:#8a909a;font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.card .v{font-size:22px;font-weight:600;margin-top:4px}
.card .v small{font-size:13px;font-weight:400;color:#8a909a}
img.cur{width:100%;border-radius:10px;border:1px solid #262a33;display:block}
table{border-collapse:collapse;width:100%} td{padding:4px 8px;border-bottom:1px solid #23272f}
td.num{text-align:right;font-variant-numeric:tabular-nums}
h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:#8a909a;margin:24px 0 8px}
pre{background:#0f1115;border:1px solid #262a33;border-radius:10px;padding:12px;overflow:auto;font-size:12px;margin:0}
.ok{color:#5fd17a}.bad{color:#e06c75}
.foot{color:#5a606a;font-size:11px;margin-top:24px}
form.controls{background:#1c1f26;border:1px solid #262a33;border-radius:10px;padding:16px;display:flex;flex-wrap:wrap;gap:16px;align-items:center}
form.controls label{display:flex;align-items:center;gap:7px}
form.controls select{background:#0f1115;color:#e6e8ec;border:1px solid #2a2f39;border-radius:6px;padding:5px 7px}
form.controls button{background:#3a6df0;color:#fff;border:0;border-radius:6px;padding:8px 18px;cursor:pointer;font-weight:600;margin-left:auto}
form.controls button:hover{background:#2f5fd6}
</style></head><body><div class=wrap>
<h1>🖼️ wallpaper-rotator</h1>
<div class=sub>v${WR_VERSION:-unknown} · desktop: ${de:-?} · backend: ${backend:-?} · resolution: ${RES} · generated ${now}</div>
HTML

if [ "$have_thumb" = 1 ]; then
  echo "<img class=cur src=\"current.jpg?$(date +%s)\" alt=\"current wallpaper\">" >> "$WEBDIR/index.html"
fi

cat >> "$WEBDIR/index.html" <<HTML
<div class=grid>
  <div class=card><div class=k>Pool</div><div class=v>${pool_count} <small>images · ${pool_size:-?}</small></div></div>
  <div class=card><div class=k>Current image</div><div class=v style=font-size:14px>${cur_img:-none}</div></div>
  <div class=card><div class=k>Last rotate</div><div class=v style=font-size:14px>${rotate_when:-never}</div></div>
  <div class=card><div class=k>Last download</div><div class=v style=font-size:14px>${dl_when:-never}</div></div>
  <div class=card><div class=k>Pruned (total)</div><div class=v>${pruned_total:-0}</div></div>
  <div class=card><div class=k>Download misses / fails</div><div class=v>${dl_miss:-0} <small>/ ${dl_fail:-0}</small></div></div>
</div>
<h2>Controls</h2>
<form class=controls method=post action="/set">
  <label>Change every <select name=interval>${int_opts}</select></label>
  <label><input type=checkbox name=quote value=1${qchk}> Quote</label>
  <label><input type=checkbox name=quote_detail value=1${qdchk}> +attribution</label>
  <label>at <select name=quote_pos>${qpos_opts}</select></label>
  <label><input type=checkbox name=stats value=1${schk}> System stats</label>
  <label>at <select name=stats_pos>${spos_opts}</select></label>
  <label><input type=checkbox name=sparkline value=1${spchk}> sparklines</label>
  <label><input type=checkbox name=weather value=1${wchk}> Weather</label>
  <label>at <select name=weather_pos>${wpos_opts}</select></label>
  <label>loc <input type=text name=weather_location value="${wloc_val}" placeholder="Brighton" size=12></label>
  <label><input type=checkbox name=weather_icon value=1${wichk}> icon</label>
  <label><input type=checkbox name=weather_icon_color value=1${wicchk}> colour</label>
  <label><input type=checkbox name=weather_forecast value=1${wfchk}> forecast</label>
  <label><input type=checkbox name=clock value=1${clkchk}> Clock</label>
  <label><select name=clock_style>${cstyle_opts}</select></label>
  <label>at <select name=clock_pos>${cpos_opts}</select></label>
  <label><input type=checkbox name=clock_24h value=1${c24chk}> 24h</label>
  <label><input type=checkbox name=clock_date value=1${cdchk}> date</label>
  <label>Background theme <select name=theme>${bgtheme_opts}</select></label>
  <label>Overlay style <select name=overlay_style>${style_opts}</select></label>
  <label>Size <select name=size>${size_opts}</select></label>
  <label>Text <select name=overlay_theme>${theme_opts}</select></label>
  <label>Font <select name=font>${font_opts}</select></label>
  <button type=submit>Apply</button>
</form>
<h2>Downloads by source</h2>
<table>${src_rows}</table>
<h2>Recent activity</h2>
<pre>${recent:-（no activity logged yet）}</pre>
<div class=foot>v${WR_VERSION_ID:-unknown}${WR_VERSION_HOST:+ (authored on ${WR_VERSION_HOST})}${WR_INSTALLED_AT:+ · installed ${WR_INSTALLED_AT}}${WR_INSTALLED_ON:+ on ${WR_INSTALLED_ON}}<br>Sources: ${SOURCES} · log: ${LOG} · auto-refreshes every 30s</div>
</div></body></html>
HTML
