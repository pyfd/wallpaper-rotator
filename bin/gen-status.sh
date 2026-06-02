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

mkdir -p "$WEBDIR"
[ -f "$LOG" ] || : > "$LOG"

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
dl_fail=$(grep -c '\[download\] fail' "$LOG" 2>/dev/null || echo 0)
dl_miss=$(grep -c '\[download\] src=.* miss' "$LOG" 2>/dev/null || echo 0)
pruned_total=$(grep -oP '\[prune\] removed=\K[0-9]+' "$LOG" 2>/dev/null | awk '{s+=$1} END{print s+0}')

# Thumbnail of the current wallpaper (resized; falls back to newest pool image).
thumb_src="$POOL/$cur_img"
[ -n "$cur_img" ] && [ -f "$thumb_src" ] || thumb_src=$(ls -t "$POOL"/*.jpg 2>/dev/null | head -1)
have_thumb=0
if [ -n "${thumb_src:-}" ] && [ -f "$thumb_src" ]; then
  convert "$thumb_src" -resize 520x "$WEBDIR/current.jpg" 2>/dev/null && have_thumb=1
fi

esc() { sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# Per-source download tallies -> HTML rows.
src_rows=""
for s in $SOURCES; do
  n=$(grep -c "\[download\] src=$s ok" "$LOG" 2>/dev/null || echo 0)
  src_rows="${src_rows}<tr><td>${s}</td><td class=num>${n}</td></tr>"
done

recent=$(tail -n 18 "$LOG" 2>/dev/null | tac | esc)
now=$(date '+%Y-%m-%d %H:%M:%S')

# --- emit page --------------------------------------------------------------
cat > "$WEBDIR/index.html" <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<meta http-equiv=refresh content=30>
<title>wallpaper-rotator</title>
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
</style></head><body><div class=wrap>
<h1>🖼️ wallpaper-rotator</h1>
<div class=sub>desktop: ${de:-?} · backend: ${backend:-?} · resolution: ${RES} · generated ${now}</div>
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
<h2>Downloads by source</h2>
<table>${src_rows}</table>
<h2>Recent activity</h2>
<pre>${recent:-（no activity logged yet）}</pre>
<div class=foot>Sources: ${SOURCES} · log: ${LOG} · auto-refreshes every 30s</div>
</div></body></html>
HTML
