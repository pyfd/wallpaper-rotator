#!/bin/bash
# Generate the wallpaper-rotator web app's data + shell:
#   $WEBDIR/state.json  — everything the UI shows (config, pool, live overlay
#                         content, counters) — regenerated on every run
#   $WEBDIR/index.html  — the static one-page "canvas editor" app (same bytes
#                         every run; renders entirely from /state.json)
#   $WEBDIR/current.jpg — downscaled preview of what's on the desktop now
# Served by wallpaper-web.py. Placeholders (@@...@@) substituted by install.sh.
#
# UI paradigm (2026-06-05 redesign, "canvas editor"): the wallpaper is an
# editable canvas — overlays are draggable objects whose 3×3 snap zone IS the
# *_POS config; click an object for a floating inspector; every control
# applies instantly (POST /setone); the pool is a filmstrip. Replaces the old
# two-column status+form page.
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
STATEDIR="$(dirname "$CONFIG")"
INTERVAL_MIN=10; OVERLAY_QUOTE=0; OVERLAY_QUOTE_DETAIL=0; QUOTE_THEME=""; QUOTE_MATCH_IMAGE=0; OVERLAY_STATS=0
QUOTE_POS=south; STATS_POS=northeast; OVERLAY_SIZE=medium; OVERLAY_THEME=dark; OVERLAY_FONT=default
OVERLAY_STYLE=scrim
STATS_SPARKLINE=0; OVERLAY_WEATHER=0; WEATHER_POS=north; WEATHER_LOCATION=; OVERLAY_WEATHER_ICON=0; OVERLAY_WEATHER_ICON_COLOR=0; OVERLAY_WEATHER_FORECAST=0
OVERLAY_CLOCK=0; CLOCK_STYLE=digital; CLOCK_POS=northwest; CLOCK_24H=1; CLOCK_DATE=0; THEME=
CLOCK_FACE=classic; AI_WALLPAPER=0; AI_PROMPT=
OVERLAY_PULSE=0; PULSE_POS=east; PULSE_URL=; PULSE_JQ=.; PULSE_TTL=5; PULSE_TITLE=""
WEB_BIND=
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

PORT="@@PORT@@"
[ "$PORT" = "@@PORT""@@" ] && PORT=8787

mkdir -p "$WEBDIR"
[ -f "$LOG" ] || : > "$LOG"

WR_VERSION=; WR_VERSION_ID=; WR_VERSION_HOST=; WR_INSTALLED_AT=; WR_INSTALLED_ON=
VERFILE="$STATEDIR/version"
[ -f "$VERFILE" ] && . "$VERFILE" 2>/dev/null

# --- gather ------------------------------------------------------------------
pool_count=$(ls "$POOL"/*.jpg "$POOL"/*.jpeg "$POOL"/*.png 2>/dev/null | wc -l)
pool_size=$(du -sh "$POOL" 2>/dev/null | cut -f1)
fav_count=$(ls "$POOL"/favourites/*.jpg "$POOL"/favourites/*.jpeg "$POOL"/favourites/*.png 2>/dev/null | wc -l)
last_rotate=$(grep '\[rotate\]' "$LOG" 2>/dev/null | tail -1)
last_dl=$(grep '\[download\] src=.* ok' "$LOG" 2>/dev/null | tail -1)
cur_img=$(printf '%s' "$last_rotate" | grep -oP 'img=\K\S+' || true)
backend=$(printf '%s' "$last_rotate" | grep -oP 'backend=\K\S+' || true)
de=$(printf '%s' "$last_rotate" | grep -oP 'de=\K\S+' || true)
rotate_when=$(printf '%s' "$last_rotate" | grep -oP '^\S+ \S+' || true)
dl_when=$(printf '%s' "$last_dl" | grep -oP '^\S+ \S+' || true)
dl_fail=$(grep -c '\[download\] fail' "$LOG" 2>/dev/null); dl_fail=${dl_fail:-0}
dl_miss=$(grep -c '\[download\] src=.* miss' "$LOG" 2>/dev/null); dl_miss=${dl_miss:-0}
pruned_total=$(grep -oP '\[prune\] removed=\K[0-9]+' "$LOG" 2>/dev/null | awk '{s+=$1} END{print s+0}')
quote_cache=$(wc -l < "$STATEDIR/quotes.cache" 2>/dev/null || echo 0)
quote_bag=$(wc -l < "$STATEDIR/quotes.bag" 2>/dev/null || echo 0)

# Preview of what's on the desktop now (rendered frame when overlays active).
thumb_src="$POOL/$cur_img"
if [ "${OVERLAY_QUOTE:-0}" = 1 ] || [ "${OVERLAY_STATS:-0}" = 1 ] || [ "${OVERLAY_WEATHER:-0}" = 1 ] \
   || [ "${OVERLAY_CLOCK:-0}" = 1 ] || [ "${OVERLAY_PULSE:-0}" = 1 ]; then
  r=$(ls -t "$STATEDIR/rendered"/*.jpg 2>/dev/null | head -1)
  [ -n "$r" ] && thumb_src="$r"
fi
[ -n "${thumb_src:-}" ] && [ -f "$thumb_src" ] || thumb_src=$(ls -t "$POOL"/*.jpg 2>/dev/null | head -1)
if [ -n "${thumb_src:-}" ] && [ -f "$thumb_src" ]; then
  convert "$thumb_src" -resize 1100x "$WEBDIR/current.jpg" 2>/dev/null
fi
# Clean (un-rendered) original for the editor canvas — the draggable overlay
# objects represent the overlays, so the backdrop must not also contain them.
canvas_src="$(cat "$STATEDIR/current" 2>/dev/null)"
[ -n "$canvas_src" ] && [ -f "$canvas_src" ] || canvas_src="$thumb_src"
if [ -n "${canvas_src:-}" ] && [ -f "$canvas_src" ]; then
  convert "$canvas_src" -resize 1100x "$WEBDIR/canvas.jpg" 2>/dev/null
fi

# Live overlay content so canvas objects mirror the real desktop.
quote_now=""
[ -f "$STATEDIR/.quote" ] && quote_now="$(tail -n +2 "$STATEDIR/.quote" 2>/dev/null | head -4)"
weather_now=""
[ -f "$STATEDIR/forecast.raw" ] && weather_now="$(head -1 "$STATEDIR/forecast.raw" 2>/dev/null | awk -F'|' '{print $4" "$2"°/"$3"°"}')"
pulse_now=""
[ -s "$STATEDIR/pulse.txt" ] && pulse_now="$(head -8 "$STATEDIR/pulse.txt")"
pulse_age=""
[ -s "$STATEDIR/pulse.txt" ] && pulse_age="$(date -r "$STATEDIR/pulse.txt" +%H:%M 2>/dev/null)"
stats_now="$(hostname) · load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null) · mem $(free -h 2>/dev/null | awk '/^Mem:/{print $3"/"$2}')"

# Per-source tallies (JSON object).
src_json="{"
first=1
for s in $SOURCES ai; do
  n=$(grep -c "\[download\] src=$s ok" "$LOG" 2>/dev/null); n=${n:-0}
  [ $first = 1 ] || src_json="$src_json,"
  src_json="$src_json\"$s\":$n"; first=0
done
src_json="$src_json}"

# Pool list (newest first, top-level + favourites), JSON array via jq.
pool_json="$( {
  ls -t "$POOL"/*.jpg "$POOL"/*.jpeg "$POOL"/*.png 2>/dev/null | while IFS= read -r f; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; ai=false; case "$b" in *.ai.jpg) ai=true;; esac
    jq -n --arg n "$b" --argjson ai "$ai" '{n:$n, ai:$ai, fav:false}'
  done
  ls -t "$POOL"/favourites/*.jpg "$POOL"/favourites/*.jpeg "$POOL"/favourites/*.png 2>/dev/null | while IFS= read -r f; do
    [ -f "$f" ] || continue
    b="$(basename "$f")"; ai=false; case "$b" in *.ai.jpg) ai=true;; esac
    jq -n --arg n "$b" --argjson ai "$ai" '{n:$n, ai:$ai, fav:true}'
  done
} | jq -s . )"
[ -n "$pool_json" ] || pool_json="[]"

# Fonts ImageMagick actually has (subset offered in Appearance).
fonts_json="$( {
  echo default
  avail_fonts=$(convert -list font 2>/dev/null | sed -n 's/^ *Font: //p')
  for fc in DejaVu-Sans DejaVu-Serif DejaVu-Sans-Mono Liberation-Sans Liberation-Serif FreeSans FreeSerif; do
    grep -qxF -- "$fc" <<<"$avail_fonts" && echo "$fc"
  done
} | jq -R . | jq -s . )"

remote_url=""
if [ -n "${WEB_BIND:-}" ]; then
  if [ "$WEB_BIND" = tailscale ]; then ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"; else ts_ip="$WEB_BIND"; fi
  [ -n "${ts_ip:-}" ] && remote_url="http://${ts_ip}:${PORT}"
fi

recent_json="$(tail -n 14 "$LOG" 2>/dev/null | tac | jq -R . | jq -s .)"
[ -n "$recent_json" ] || recent_json="[]"

host="$(hostname 2>/dev/null)"
now="$(date '+%Y-%m-%d %H:%M:%S')"

# --- emit state.json ---------------------------------------------------------
jq -n \
  --arg version "${WR_VERSION:-unknown}" --arg vid "${WR_VERSION_ID:-}" --arg vhost "${WR_VERSION_HOST:-}" \
  --arg host "$host" --arg de "${de:-?}" --arg backend "${backend:-?}" --arg res "$RES" --arg now "$now" \
  --arg cur "$cur_img" --arg rotate_when "${rotate_when:-}" --arg dl_when "${dl_when:-}" \
  --arg pool_size "${pool_size:-?}" --arg remote "$remote_url" --arg sources "$SOURCES" \
  --arg quote_now "$quote_now" --arg weather_now "$weather_now" --arg pulse_now "$pulse_now" \
  --arg pulse_age "$pulse_age" --arg stats_now "$stats_now" \
  --argjson pool_count "${pool_count:-0}" --argjson fav_count "${fav_count:-0}" \
  --argjson pruned "${pruned_total:-0}" --argjson miss "${dl_miss:-0}" --argjson fail "${dl_fail:-0}" \
  --argjson quote_cache "${quote_cache:-0}" --argjson quote_bag "${quote_bag:-0}" \
  --argjson srcs "$src_json" --argjson pool "$pool_json" --argjson fonts "$fonts_json" --argjson recent "$recent_json" \
  --arg c_interval "${INTERVAL_MIN}" \
  --arg c_quote "${OVERLAY_QUOTE}" --arg c_quote_detail "${OVERLAY_QUOTE_DETAIL}" \
  --arg c_quote_theme "${QUOTE_THEME}" --arg c_quote_match "${QUOTE_MATCH_IMAGE}" --arg c_quote_pos "${QUOTE_POS}" \
  --arg c_stats "${OVERLAY_STATS}" --arg c_sparkline "${STATS_SPARKLINE}" --arg c_stats_pos "${STATS_POS}" \
  --arg c_weather "${OVERLAY_WEATHER}" --arg c_weather_pos "${WEATHER_POS}" --arg c_weather_location "${WEATHER_LOCATION}" \
  --arg c_weather_icon "${OVERLAY_WEATHER_ICON}" --arg c_weather_icon_color "${OVERLAY_WEATHER_ICON_COLOR}" --arg c_weather_forecast "${OVERLAY_WEATHER_FORECAST}" \
  --arg c_clock "${OVERLAY_CLOCK}" --arg c_clock_style "${CLOCK_STYLE}" --arg c_clock_face "${CLOCK_FACE}" \
  --arg c_clock_pos "${CLOCK_POS}" --arg c_clock_24h "${CLOCK_24H}" --arg c_clock_date "${CLOCK_DATE}" \
  --arg c_pulse "${OVERLAY_PULSE}" --arg c_pulse_pos "${PULSE_POS}" --arg c_pulse_url "${PULSE_URL}" \
  --arg c_pulse_jq "${PULSE_JQ}" --arg c_pulse_ttl "${PULSE_TTL}" --arg c_pulse_title "${PULSE_TITLE}" \
  --arg c_ai "${AI_WALLPAPER}" --arg c_ai_prompt "${AI_PROMPT}" \
  --arg c_style "${OVERLAY_STYLE}" --arg c_size "${OVERLAY_SIZE}" --arg c_text "${OVERLAY_THEME}" --arg c_font "${OVERLAY_FONT}" \
  --arg c_theme "${THEME}" --arg c_web_bind "${WEB_BIND}" \
'{
  version:$version, version_id:$vid, version_host:$vhost,
  host:$host, de:$de, backend:$backend, res:$res, now:$now,
  cur:$cur, rotate_when:$rotate_when, dl_when:$dl_when,
  pool_count:$pool_count, pool_size:$pool_size, fav_count:$fav_count,
  pruned:$pruned, miss:$miss, fail:$fail,
  quote_cache:$quote_cache, quote_bag:$quote_bag,
  srcs:$srcs, pool:$pool, fonts:$fonts, recent:$recent,
  remote:$remote, sources:$sources,
  live:{quote:$quote_now, weather:$weather_now, pulse:$pulse_now, pulse_age:$pulse_age, stats:$stats_now},
  cfg:{
    interval:$c_interval,
    quote:$c_quote, quote_detail:$c_quote_detail, quote_theme:$c_quote_theme,
    quote_match:$c_quote_match, quote_pos:$c_quote_pos,
    stats:$c_stats, sparkline:$c_sparkline, stats_pos:$c_stats_pos,
    weather:$c_weather, weather_pos:$c_weather_pos, weather_location:$c_weather_location,
    weather_icon:$c_weather_icon, weather_icon_color:$c_weather_icon_color, weather_forecast:$c_weather_forecast,
    clock:$c_clock, clock_style:$c_clock_style, clock_face:$c_clock_face,
    clock_pos:$c_clock_pos, clock_24h:$c_clock_24h, clock_date:$c_clock_date,
    pulse:$c_pulse, pulse_pos:$c_pulse_pos, pulse_url:$c_pulse_url,
    pulse_jq:$c_pulse_jq, pulse_ttl:$c_pulse_ttl, pulse_title:$c_pulse_title,
    ai:$c_ai, ai_prompt:$c_ai_prompt,
    style:$c_style, size:$c_size, text:$c_text, font:$c_font,
    theme:$c_theme, web_bind:$c_web_bind
  }
}' > "$WEBDIR/state.json.tmp" && mv "$WEBDIR/state.json.tmp" "$WEBDIR/state.json"

# --- emit the static app shell (same bytes every run) ------------------------
favicon_svg='<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><rect x="2" y="5" width="28" height="22" rx="5" fill="#14161a" stroke="#7cc4ff" stroke-width="2"/><circle cx="11" cy="12" r="3" fill="#ffd23f"/><path d="M3 25 L12 16 L18 21 L23 15 L29 25 Z" fill="#5fd17a"/></svg>'
favicon_b64="$(printf '%s' "$favicon_svg" | base64 -w0 2>/dev/null)"

{
cat <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,${favicon_b64}">
<title>Wallpaper Rotator</title>
HTML
cat <<'HTML'
<style>
:root{color-scheme:dark;--txt:#eef1f6;--mut:#98a0ac;--acc:#7cc4ff;--acc2:#3a6df0;--ok:#5fd17a;--bad:#e06c75;--warn:#ffd23f}
*{box-sizing:border-box}
body{margin:0;font:13px/1.45 system-ui,sans-serif;color:var(--txt);height:100vh;overflow:hidden;background:#101218;display:flex;flex-direction:column}
button{font:inherit}
/* ── infra-alert banner ── */
.alertbar{display:flex;flex-direction:column;gap:6px;padding:0 16px}
.alertbar:not(:empty){padding:9px 16px;border-bottom:1px solid #23262f}
.alert{display:flex;align-items:center;gap:10px;padding:8px 12px;border-radius:8px;font-size:12.5px;font-weight:600}
.alert.critical{background:#c0392b;color:#fff}
.alert.warn{background:#3a2f12;color:#ffd23f;border:1px solid #6b551c}
.alert .ahost{opacity:.85;font-weight:700;font-size:11px;text-transform:uppercase}
.alert .atitle{flex:1;min-width:0}
.alert .aack{background:rgba(0,0,0,.25);border:1px solid rgba(255,255,255,.35);color:inherit;border-radius:7px;padding:3px 11px;font-size:11.5px;font-weight:600;cursor:pointer;white-space:nowrap}
.alert .aack:hover{background:rgba(0,0,0,.45)}
/* ── top bar ── */
.bar{display:flex;align-items:center;gap:12px;padding:9px 16px;background:#15171e;border-bottom:1px solid #23262f;z-index:7;flex-wrap:wrap}
.bar .ttl{font-weight:700;font-size:13.5px;white-space:nowrap}
.bar .crumb{color:var(--mut);font-size:12px;white-space:nowrap}
.bar .livedot{color:var(--ok);font-size:11.5px;white-space:nowrap}
.bar .busy{display:none;color:var(--warn);font-size:11.5px}
.bar .busy.show{display:inline}
.actions{margin-left:auto;display:flex;gap:6px}
.bbtn{background:#1d212b;border:1px solid #2a2f3a;color:var(--txt);border-radius:8px;padding:5px 13px;font-size:12px;font-weight:600;cursor:pointer;white-space:nowrap}
.bbtn:hover{border-color:var(--acc2)}
.bbtn.primary{background:var(--acc2);border-color:var(--acc2);color:#fff}
.bbtn.danger:hover{border-color:var(--bad);color:#eea}
.bbtn:disabled{opacity:.5;cursor:progress}
/* ── work area ── */
.work{flex:1;display:grid;place-items:center;position:relative;min-height:0;background:radial-gradient(circle at 50% 40%,#181b23 0%,#101218 75%);padding:6px 16px}
.cwrap{display:flex;flex-direction:column;gap:8px;width:min(96%,calc((100vh - 238px)*1.78));min-width:340px}
/* auto-tray: overlays with position=auto live here */
.tray{display:flex;gap:8px;align-items:center;min-height:30px}
.tray .tl{font-size:9.5px;letter-spacing:.12em;color:var(--mut);text-transform:uppercase}
.tray:not(.has) .tl::after{content:" — drag an overlay here to let the renderer place it"}
.canvas{position:relative;width:100%;aspect-ratio:16/9;border-radius:10px;overflow:hidden;box-shadow:0 24px 80px rgba(0,0,0,.6);outline:1px solid #2a2f3a;background:#000}
.canvas>img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}
.zones{position:absolute;inset:0;display:grid;grid-template:repeat(3,1fr)/repeat(3,1fr);z-index:2}
.zone{border:1px dashed transparent;transition:.15s}
.canvas.dragging .zone{border-color:rgba(124,196,255,.22)}
.zone.hot{background:rgba(58,109,240,.2);border-color:var(--acc)}
/* overlay objects */
.obj{position:absolute;z-index:3;background:rgba(8,10,14,.62);backdrop-filter:blur(8px);border:1.5px solid transparent;border-radius:10px;padding:7px 11px;font-size:11px;color:#e7ecf3;cursor:grab;user-select:none;transition:border-color .15s,box-shadow .15s,opacity .2s;max-width:46%;touch-action:none}
.obj .on{font-size:9.5px;letter-spacing:.07em;text-transform:uppercase;color:var(--acc);font-weight:700}
.obj:hover{border-color:rgba(124,196,255,.6)}
.obj.sel{border-color:var(--acc);box-shadow:0 0 0 3px rgba(124,196,255,.22)}
.obj.dim{opacity:.38;filter:grayscale(.8)}
.obj.intray{position:static;max-width:none;cursor:grab}
.obj .bodytxt{display:block;max-height:3.1em;overflow:hidden}
/* inspector */
.insp{position:fixed;z-index:20;width:248px;background:rgba(15,17,23,.96);backdrop-filter:blur(20px);border:1px solid rgba(255,255,255,.13);border-radius:14px;box-shadow:0 18px 50px rgba(0,0,0,.55);padding:13px 15px;opacity:0;pointer-events:none;transform:translateY(6px) scale(.98);transition:.18s}
.insp.show{opacity:1;pointer-events:auto;transform:none}
.insp h3{margin:0 0 9px;font-size:12.5px;display:flex;align-items:center;gap:8px}
.insp h3 .auto{margin-left:auto;font-size:10px;color:var(--mut);cursor:pointer;border:1px solid #2a2f3a;border-radius:6px;padding:2px 7px}
.insp h3 .auto:hover{color:var(--acc);border-color:var(--acc2)}
.insp .row{display:flex;flex-wrap:wrap;gap:7px 10px;align-items:center;margin-bottom:8px}
.insp .lbl{color:var(--mut);font-size:10.5px}
.insp select,.insp input[type=text]{background:rgba(0,0,0,.45);color:var(--txt);border:1px solid rgba(255,255,255,.14);border-radius:7px;padding:4px 7px;font-size:11.5px;outline:none;max-width:150px}
.insp input.wide{max-width:none;width:100%}
.insp label{display:flex;gap:5px;align-items:center;font-size:11px;color:#cfd3da}
.insp input[type=checkbox]{accent-color:var(--acc2);margin:0}
.insp .chips{display:flex;flex-wrap:wrap;gap:5px}
.insp .chip{border:1px solid #2a2f39;border-radius:999px;padding:2px 9px;font-size:10.5px;cursor:pointer;color:#cfd3da}
.insp .chip.cur{background:rgba(58,109,240,.3);border-color:var(--acc2);color:#fff}
.insp pre{background:rgba(0,0,0,.5);border:1px solid rgba(255,255,255,.1);border-radius:9px;padding:8px 10px;font-size:10.5px;color:#9fb4cc;max-height:110px;overflow:auto;margin:0;white-space:pre-wrap}
.insp .mut{font-size:10px;color:var(--mut)}
.tgl{display:inline-flex;cursor:pointer}.tgl input{position:absolute;opacity:0}
.tgl .sw{width:32px;height:18px;border-radius:10px;background:#3a3f4a;position:relative;transition:.15s;display:inline-block}
.tgl .sw::after{content:"";position:absolute;top:2px;left:2px;width:14px;height:14px;border-radius:50%;background:#fff;transition:left .15s}
.tgl input:checked+.sw{background:var(--acc2)}.tgl input:checked+.sw::after{left:16px}
/* layers panel */
.layers{position:fixed;left:14px;top:60px;width:178px;background:rgba(15,17,23,.88);backdrop-filter:blur(16px);border:1px solid rgba(255,255,255,.1);border-radius:13px;padding:9px;z-index:8;max-height:calc(100vh - 220px);overflow:auto}
.layers h4{margin:2px 6px 7px;font-size:10px;letter-spacing:.09em;text-transform:uppercase;color:var(--mut)}
.lay{display:flex;align-items:center;gap:8px;padding:6px 8px;border-radius:8px;cursor:pointer;font-size:12px;transition:.12s}
.lay:hover{background:rgba(255,255,255,.07)}
.lay.sel{background:rgba(58,109,240,.22)}
.lay.dim{opacity:.45}
.lay .eye{margin-left:auto;cursor:pointer;font-size:12px;opacity:.85;padding:0 2px}
.lay .eye:hover{transform:scale(1.2)}
/* filmstrip */
.strip{display:flex;gap:8px;align-items:center;padding:10px 14px;background:#13151b;border-top:1px solid #23262f;overflow-x:auto;z-index:5;min-height:96px}
.fr{position:relative;flex:none;width:118px;aspect-ratio:16/9;border-radius:8px;overflow:hidden;cursor:pointer;outline:2px solid transparent;outline-offset:1px;transition:.15s;background:#1a1e26}
.fr:hover{outline-color:rgba(124,196,255,.55);transform:translateY(-2px)}
.fr.cur{outline-color:var(--acc)}
.fr img{width:100%;height:100%;object-fit:cover;display:block}
.fr .tag{position:absolute;top:4px;left:4px;background:rgba(0,0,0,.62);border-radius:5px;font-size:9px;padding:1px 6px;color:var(--warn)}
.fr .star{position:absolute;top:4px;right:4px;font-size:11px;text-shadow:0 1px 3px #000}
.fr .acts{position:absolute;inset:auto 0 0 0;display:flex;justify-content:space-between;padding:3px 7px;background:linear-gradient(0deg,rgba(0,0,0,.75),transparent);opacity:0;transition:.15s;font-size:12px}
.fr:hover .acts{opacity:1}
.fr .acts span:hover{transform:scale(1.3)}
.strip .more{flex:none;color:var(--mut);font-size:11px;padding:0 10px;white-space:nowrap}
.toast{position:fixed;top:52px;left:50%;transform:translateX(-50%);background:rgba(46,158,91,.95);color:#fff;padding:7px 16px;border-radius:9px;font-size:12.5px;font-weight:600;opacity:0;transition:.3s;z-index:40;pointer-events:none}
.toast.show{opacity:1}
.toast.err{background:rgba(181,84,79,.96)}
@media(max-width:900px){
  .layers{position:static;width:auto;max-height:none;display:flex;gap:4px;overflow-x:auto;border-radius:0;background:#13151b;border:0;border-bottom:1px solid #23262f;padding:6px 10px}
  .layers h4{display:none}.lay{white-space:nowrap}
  .cwrap{width:96%}
}
</style></head><body>

<div class=bar>
  <span class=ttl>🖼️ wallpaper-rotator</span>
  <span class=crumb id=crumb></span>
  <span class=livedot>● live — edits apply to the real desktop</span>
  <span class=busy id=busy>⟳ rendering…</span>
  <div class=actions>
    <button class=bbtn id=b-next>⏭ Next</button>
    <button class=bbtn id=b-keep>★ Keep</button>
    <button class="bbtn danger" id=b-ban>🚫 Ban</button>
    <button class="bbtn primary" id=b-dream>✦ Dream</button>
  </div>
</div>

<div class=alertbar id=alertbar></div>

<div class=layers id=layers></div>

<div class=work id=work>
  <div class=cwrap>
    <div class=tray id=tray><span class=tl>auto-placed</span></div>
    <div class=canvas id=cv>
      <img id=cvimg src="canvas.jpg">
      <div class=zones id=zones></div>
    </div>
  </div>
</div>
<div class=insp id=insp></div>

<div class=strip id=strip></div>
<div class=toast id=toast></div>

<script>
'use strict';
let S=null;                                   // latest /state.json
const $=id=>document.getElementById(id);
const ZONES=['northwest','north','northeast','west','center','east','southwest','south','southeast'];
const OVERLAYS={
  quote:  {ic:'❝', name:'Quote',   posKey:'quote_pos',   onKey:'quote'},
  weather:{ic:'☀', name:'Weather', posKey:'weather_pos', onKey:'weather'},
  stats:  {ic:'📈', name:'Stats',   posKey:'stats_pos',   onKey:'stats'},
  clock:  {ic:'🕐', name:'Clock',   posKey:'clock_pos',   onKey:'clock'},
  pulse:  {ic:'📊', name:'Pulse',   posKey:'pulse_pos',   onKey:'pulse'},
};
const CANVAS_ITEMS={
  appearance:{ic:'🎨', name:'Appearance'},
  rotation:  {ic:'🗂', name:'Rotation & themes'},
  ai:        {ic:'✦', name:'AI dreamed'},
  system:    {ic:'⚙', name:'Status & remote'},
};
const esc=s=>String(s??'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');

// ── server I/O ──────────────────────────────────────────────
async function setone(kv,msg){
  busy(true);
  try{
    const body=new URLSearchParams();
    for(const [k,v] of Object.entries(kv)){
      if(Array.isArray(v)) v.forEach(x=>body.append(k,x)); else body.append(k,v);
    }
    const r=await fetch('/setone',{method:'POST',body});
    if(!r.ok) throw new Error(await r.text());
    toast(msg||'Saved — rendering…');
    pollSoon();
  }catch(e){toast('save failed: '+e.message,1)}
}
async function act(path,form,msg){
  busy(true);
  try{
    const r=await fetch(path,{method:'POST',body:form?new URLSearchParams(form):undefined});
    if(!r.ok) throw new Error(await r.text());
    toast(msg||'Done'); pollSoon();
  }catch(e){toast('failed: '+e.message,1)}
}
let pollTimer=null, pollSeq=0;
function pollSoon(){ clearTimeout(pollTimer); let n=0; const seq=++pollSeq;
  const tick=async()=>{ if(seq!==pollSeq)return; await refresh(); if(++n<10) pollTimer=setTimeout(tick,2600); else busy(false); };
  pollTimer=setTimeout(tick,1700);
}
async function refresh(){
  try{
    const r=await fetch('/state.json?t='+Date.now());
    S=await r.json(); render(); busy(false);
  }catch(e){/* server restarting (web_bind) — retry next poll */}
}
function busy(b){$('busy').classList.toggle('show',b)}
function toast(t,err){const e=$('toast');e.textContent=t;e.classList.toggle('err',!!err);e.classList.add('show');clearTimeout(e._t);e._t=setTimeout(()=>e.classList.remove('show'),err?4500:1700)}

// ── render everything from S ────────────────────────────────
function render(){
  const c=S.cfg;
  $('crumb').textContent=`${S.host} · ${S.de} · ${S.res} · every ${c.interval} min`;
  $('cvimg').src='canvas.jpg?'+Date.now();
  renderLayers(); renderObjects(); renderStrip();
}
function renderLayers(){
  const c=S.cfg; let h='<h4>Overlays</h4>';
  for(const [k,o] of Object.entries(OVERLAYS)){
    const on=c[o.onKey]==='1';
    h+=`<div class="lay ${on?'':'dim'}" data-sel="${k}">${o.ic} ${o.name}
        <span class=eye data-eye="${k}" title="${on?'disable':'enable'}">${on?'👁':'—'}</span></div>`;
  }
  h+='<h4>Canvas</h4>';
  for(const [k,o] of Object.entries(CANVAS_ITEMS))
    h+=`<div class=lay data-sel="${k}">${o.ic} ${o.name}</div>`;
  $('layers').innerHTML=h;
}
function objBody(k){
  const c=S.cfg,L=S.live;
  if(k==='quote')  return esc(L.quote||'— next quote draws at rotate —');
  if(k==='weather')return '☀ '+esc((c.weather_location||'?')+' '+(L.weather||''));
  if(k==='stats')  return esc(L.stats||'');
  if(k==='clock')  return new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit',hour12:c.clock_24h!=='1'})+' · '+esc(c.clock_style);
  if(k==='pulse'){
    const lines=(L.pulse||'').split('\n').filter(Boolean).slice(0,3)
      .map(l=>{const i=l.indexOf('|');return i>0? esc(l.slice(0,i))+' <b style="color:var(--acc)">'+esc(l.slice(i+1))+'</b>' : esc(l)});
    return lines.length?lines.join(' · '):'— no data yet —';
  }
  return '';
}
function renderObjects(){
  const c=S.cfg, cv=$('cv'), tray=$('tray');
  cv.querySelectorAll('.obj').forEach(o=>o.remove());
  tray.querySelectorAll('.obj').forEach(o=>o.remove());
  let trayHas=false;
  for(const [k,o] of Object.entries(OVERLAYS)){
    const on=c[o.onKey]==='1', pos=c[o.posKey];
    const el=document.createElement('div');
    el.className='obj'+(on?'':' dim'); el.dataset.k=k;
    const title=k==='pulse'&&c.pulse_title?esc(c.pulse_title):o.name;
    const sub=k==='pulse'&&S.live.pulse_age?' · @'+S.live.pulse_age:'';
    el.innerHTML=`<span class=on ${on?'':'style="color:var(--mut)"'}>${o.ic} ${title}${on?'':' — off'}${sub}</span><span class=bodytxt>${objBody(k)}</span>`;
    if(pos==='auto'){ el.classList.add('intray'); tray.appendChild(el); trayHas=true; }
    else { el.dataset.z=ZONES.indexOf(pos); cv.appendChild(el); }
  }
  tray.classList.toggle('has',trayHas);
  placeObjects();
}
function placeObjects(){
  $('cv').querySelectorAll('.obj:not(.intray)').forEach(o=>{
    const z=+o.dataset.z, col=z%3, row=(z/3)|0;
    o.style.left=(col===0?'2.2%':col===1?'50%':'97.8%');
    o.style.top =(row===0?'4%':row===1?'50%':'96%');
    o.style.transform=`translate(${col===0?'0':col===1?'-50%':'-100%'},${row===0?'0':row===1?'-50%':'-100%'})`;
  });
}
function renderStrip(){
  const cur=S.cur, list=S.pool||[];
  let h='';
  for(const p of list){
    const src='/thumb?f='+encodeURIComponent(p.n)+(p.fav?'&fav=1':'');
    h+=`<div class="fr ${p.n===cur?'cur':''}" data-img="${esc(p.n)}" data-fav="${p.fav?1:0}" title="${esc(p.n)} — click to set as wallpaper">
      <img loading=lazy src="${src}">
      ${p.ai?'<span class=tag>✦ ai</span>':''}${p.fav?'<span class=star>★</span>':''}
      <div class=acts><span data-fr-act="${p.fav?'unfav':'fav'}" title="${p.fav?'remove from favourites':'keep in favourites'}">${p.fav?'✕':'★'}</span><span data-fr-act=ban title="delete">🚫</span></div></div>`;
  }
  h+=`<span class=more>${S.pool_count} in pool · ${S.fav_count} kept · ${S.pool_size}</span>`;
  $('strip').innerHTML=h;
}

// ── inspector ───────────────────────────────────────────────
function cb(key,label,cfgKey){const c=S.cfg;return `<label><input type=checkbox data-set="${key}" ${c[cfgKey??key]==='1'?'checked':''}> ${label}</label>`}
function sel(key,opts,cur){return `<select data-set="${key}">${opts.map(o=>`<option ${o===cur?'selected':''}>${o}</option>`).join('')}</select>`}
function inspHtml(k){
  const c=S.cfg;
  const head=(o,onKey)=>`<h3>${o.ic} ${o.name}
    ${onKey?`<label class=tgl><input type=checkbox data-set="${onKey}" ${c[onKey]==='1'?'checked':''}><span class=sw></span></label>`:''}
    ${OVERLAYS[k]?`<span class=auto data-auto="${k}" title="let the renderer pick the calmest spot">${c[OVERLAYS[k].posKey]==='auto'?'auto ✓':'↺ auto'}</span>`:''}</h3>`;
  if(k==='quote') return head(OVERLAYS[k],'quote')+
    `<div class=row><span class=lbl>theme</span>${sel('quote_theme',['any','love','life','inspirational','humor','philosophy','wisdom','happiness','hope','success','romance','friendship','science'],c.quote_theme||'any')}</div>
     <div class=row>${cb('quote_detail','Attribution')}</div>
     <div class=row>${cb('quote_match','Match image to quote')}</div>
     <div class=row><span class=mut>pool ${S.quote_cache.toLocaleString()} quotes · bag ${S.quote_bag.toLocaleString()} left</span></div>`;
  if(k==='weather') return head(OVERLAYS[k],'weather')+
    `<div class=row><input type=text data-set=weather_location value="${esc(c.weather_location)}" placeholder=Location size=12></div>
     <div class=row>${cb('weather_icon','Icon')}${cb('weather_icon_color','Colour')}${cb('weather_forecast','Forecast')}</div>`;
  if(k==='stats') return head(OVERLAYS[k],'stats')+
    `<div class=row>${cb('sparkline','Sparklines')}</div>
     <div class=row><span class=mut>${esc(S.live.stats)}</span></div>`;
  if(k==='clock') return head(OVERLAYS[k],'clock')+
    `<div class=row>${sel('clock_style',['analogue','digital'],c.clock_style)}<span class=lbl>face</span>${sel('clock_face',['classic','minimal','dots','numbers'],c.clock_face)}</div>
     <div class=row>${cb('clock_24h','24h')}${cb('clock_date','Date')}</div>`;
  if(k==='pulse') return head(OVERLAYS[k],'pulse')+
    `<div class=row><span class=lbl>title</span><input type=text data-set=pulse_title value="${esc(c.pulse_title)}" size=12>
       <span class=lbl>every</span>${sel('pulse_ttl',['1','5','15','30'],c.pulse_ttl)}<span class=lbl>min</span></div>
     <div class=row><span class=lbl>URL</span><input type=text class=wide data-set=pulse_url value="${esc(c.pulse_url)}" placeholder="https://host/api or file:///path.json"></div>
     <div class=row><span class=lbl>template</span><input type=text class=wide data-set=pulse_jq value="${esc(c.pulse_jq)}" placeholder=".lines[]"></div>
     <div class=row><button class=bbtn id=pulse-test>Test</button></div>
     <pre id=pulse-pre>${esc(S.live.pulse||'(no data yet)')}</pre>`;
  if(k==='appearance') return `<h3>🎨 Appearance</h3>
     <div class=row><span class=lbl>Style</span>${sel('overlay_style',['frosted','scrim','editorial','chips'],c.style)}
       <span class=lbl>Size</span>${sel('size',['small','medium','large'],c.size)}</div>
     <div class=row><span class=lbl>Text</span>${sel('overlay_theme',['light','dark','accent'],c.text)}
       <span class=lbl>Font</span>${sel('font',S.fonts,c.font)}</div>`;
  if(k==='rotation'){
    const themes=['nature','landscape','minimal','space','city','abstract','cars','cycling','animals','dark','forest','ocean'];
    const cur=new Set((c.theme||'').split(' ').filter(Boolean));
    return `<h3>🗂 Rotation & themes</h3>
     <div class=row><span class=lbl>Change every</span>${sel('interval',['3','5','10','15','30','60'],c.interval)}<span class=lbl>min</span></div>
     <div class=row><span class=lbl>image themes (none = any)</span></div>
     <div class=chips>${themes.map(t=>`<span class="chip ${cur.has(t)?'cur':''}" data-chip="${t}">${t}</span>`).join('')}</div>
     <div class=row style=margin-top:8px><span class=mut>sources: ${esc(S.sources)} — wallhaven honours themes</span></div>`;
  }
  if(k==='ai') return `<h3>✦ AI dreamed
     <label class=tgl><input type=checkbox data-set=ai ${c.ai==='1'?'checked':''}><span class=sw></span></label></h3>
     <div class=row><input type=text class=wide data-set=ai_prompt value="${esc(c.ai_prompt)}" placeholder="extra style words (optional)"></div>
     <div class=row><span class=mut>prompts build from time · season · weather · theme${c.quote_match==='1'?' · quote':''}</span></div>
     <div class=row><button class=bbtn id=dream2>✦ Dream now</button></div>`;
  if(k==='system') return `<h3>⚙ Status & remote</h3>
     <div class=row><label class=tgl><input type=checkbox data-set=web_bind ${c.web_bind?'checked':''}><span class=sw></span></label>
       <span class=lbl>tailnet access${S.remote?` — <a style="color:var(--acc)" href="${esc(S.remote)}">${esc(S.remote)}</a>`:''}</span></div>
     <div class=row><span class=mut>v${esc(S.version)} · ${esc(S.de)} · ${esc(S.backend)}<br>
       rotate ${esc(S.rotate_when)} · download ${esc(S.dl_when)}<br>
       pruned ${S.pruned} · miss ${S.miss} / fail ${S.fail}<br>
       sources: ${Object.entries(S.srcs).map(([a,b])=>a+' '+b).join(' · ')}</span></div>
     <pre>${(S.recent||[]).slice(0,8).map(esc).join('\n')}</pre>`;
  return '';
}
let inspFor=null;
function showInsp(k,anchor){
  inspFor=k;
  const p=$('insp'); p.innerHTML=inspHtml(k);
  const r=anchor.getBoundingClientRect();
  let x=r.right+12, y=r.top;
  if(x+260>innerWidth) x=r.left-262;
  if(x<6)x=6;
  y=Math.min(Math.max(8,y),innerHeight-330);
  p.style.left=x+'px'; p.style.top=y+'px';
  p.classList.add('show');
  document.querySelectorAll('.lay').forEach(l=>l.classList.toggle('sel',l.dataset.sel===k));
}
function hideInsp(){$('insp').classList.remove('show');inspFor=null;
  document.querySelectorAll('.lay').forEach(l=>l.classList.remove('sel'))}

// ── events ──────────────────────────────────────────────────
document.addEventListener('click',e=>{
  const eye=e.target.closest('[data-eye]');
  if(eye){const k=eye.dataset.eye,o=OVERLAYS[k];
    setone({[o.onKey]:S.cfg[o.onKey]==='1'?'0':'1'},o.name+(S.cfg[o.onKey]==='1'?' off':' on'));
    e.stopPropagation();return}
  const lay=e.target.closest('[data-sel]');
  if(lay){const k=lay.dataset.sel;
    const obj=document.querySelector(`.obj[data-k="${k}"]`);
    showInsp(k,obj||lay);return}
  const au=e.target.closest('[data-auto]');
  if(au){const k=au.dataset.auto,o=OVERLAYS[k];
    setone({[o.posKey]:'auto'},o.name+' → auto-placed');return}
  const chip=e.target.closest('[data-chip]');
  if(chip){chip.classList.toggle('cur');
    const picked=[...document.querySelectorAll('.chip.cur')].map(c=>c.dataset.chip);
    setone({theme:picked},'themes: '+(picked.join(' ')||'any'));return}
  const fr=e.target.closest('.fr');
  if(fr){
    const a=e.target.closest('[data-fr-act]');
    const form={img:fr.dataset.img,fav:fr.dataset.fav};
    if(a){form.act=a.dataset.frAct;act('/img-act',form,{fav:'★ kept',unfav:'back to pool',ban:'🚫 deleted'}[form.act]);e.stopPropagation()}
    else {form.act='use';act('/img-act',form,'set as wallpaper')}
    return}
  if(e.target.id==='pulse-test'){
    const u=document.querySelector('[data-set=pulse_url]').value,
          j=document.querySelector('[data-set=pulse_jq]').value;
    fetch('/pulse_test',{method:'POST',body:new URLSearchParams({url:u,jq:j})})
      .then(r=>r.text()).then(t=>{$('pulse-pre').textContent=t});return}
  if(e.target.id==='dream2'){act('/dream',null,'✦ dreaming… ~40s');hideInsp();return}
  if(!e.target.closest('.insp')&&!e.target.closest('.obj')) hideInsp();
});
document.addEventListener('change',e=>{
  const k=e.target.dataset.set; if(!k)return;
  const v=e.target.type==='checkbox'?(e.target.checked?'1':'0'):e.target.value;
  setone({[k]:v});
});
document.addEventListener('keydown',e=>{if(e.key==='Escape')hideInsp()});
$('b-next').onclick=()=>act('/next',null,'⏭ rotating…');
$('b-keep').onclick=()=>act('/keep',null,'★ kept');
$('b-ban').onclick=()=>act('/ban',null,'🚫 banned — rotating…');
$('b-dream').onclick=()=>act('/dream',null,'✦ dreaming… ~40s');

// drag objects between zones (and out of the auto tray)
let drag=null;
document.addEventListener('pointerdown',e=>{
  const o=e.target.closest('.obj'); if(!o)return;
  drag={el:o,moved:false}; o.classList.add('sel');
  e.preventDefault();
});
document.addEventListener('pointermove',e=>{
  if(!drag)return; drag.moved=true;
  const cv=$('cv'), r=cv.getBoundingClientRect();
  cv.classList.add('dragging');
  const x=Math.min(Math.max(e.clientX-r.left,0),r.width), y=Math.min(Math.max(e.clientY-r.top,0),r.height);
  const col=Math.min(2,(x/r.width*3)|0), row=Math.min(2,(y/r.height*3)|0), z=row*3+col;
  document.querySelectorAll('.zone').forEach(zz=>zz.classList.toggle('hot',+zz.dataset.i===z));
  if(drag.el.classList.contains('intray')){drag.el.classList.remove('intray');$('cv').appendChild(drag.el)}
  drag.el.dataset.z=z; placeObjects();
});
document.addEventListener('pointerup',e=>{
  if(!drag)return;
  const o=drag.el, moved=drag.moved; drag=null;
  $('cv').classList.remove('dragging');
  document.querySelectorAll('.zone').forEach(zz=>zz.classList.remove('hot'));
  o.classList.remove('sel');
  const k=o.dataset.k, ov=OVERLAYS[k];
  if(moved && o.dataset.z!==undefined){
    const pos=ZONES[+o.dataset.z];
    if(S.cfg[ov.posKey]!==pos) setone({[ov.posKey]:pos},`${ov.name} → ${pos}`);
  } else showInsp(k,o);
});

// ── infra-alert banner (Phase 3) ──────────────────────────
// Polls /alerts.json (the live cache check-alerts.sh maintains) and renders
// active critical/warn alerts with an Ack button. Ack POSTs to /ack, which the
// server proxies to the aggregator. Self-contained — independent of the main
// render loop, so an alerts hiccup never affects the rest of the UI.
async function pollAlerts(){
  let d;
  try{ d=await (await fetch('/alerts.json?t='+Date.now())).json(); }
  catch(e){ return; }                                   // endpoint blip — keep last paint
  const bar=$('alertbar'); if(!bar) return;
  const active=(d.active||[]).filter(a=>a.severity==='critical'||a.severity==='warn');
  active.sort((a,b)=> (a.severity==='critical'?0:1)-(b.severity==='critical'?0:1));
  bar.innerHTML=active.map(a=>
    `<div class="alert ${a.severity==='critical'?'critical':'warn'}">`+
    `<span class=ahost>${esc(a.host||'')}</span>`+
    `<span class=atitle>${esc(a.title||a.key||'')}</span>`+
    `<button class=aack data-h="${esc(a.host||'')}" data-k="${esc(a.key||'')}">Ack</button>`+
    `</div>`).join('');
  // The overlays menu (.layers) is position:fixed at top:60px and would cover
  // the left of the banners. Push it below the banner while alerts are present
  // (variable height: 1+ banners), restore the CSS default when clear.
  const lay=$('layers');
  if(lay){ lay.style.top = active.length ? (Math.round(bar.getBoundingClientRect().bottom)+8)+'px' : ''; }
}
document.getElementById('alertbar').addEventListener('click',async e=>{
  const b=e.target.closest('.aack'); if(!b) return;
  b.disabled=true; b.textContent='…';
  try{
    const r=await fetch('/ack',{method:'POST',body:new URLSearchParams({host:b.dataset.h,key:b.dataset.k})});
    if(!r.ok) throw new Error(await r.text());
    toast('Alert acknowledged'); pollAlerts();
  }catch(err){ b.disabled=false; b.textContent='Ack'; toast('ack failed: '+err.message,1); }
});

// boot + slow poll
const zs=$('zones');
for(let i=0;i<9;i++){const d=document.createElement('div');d.className='zone';d.dataset.i=i;zs.appendChild(d)}
refresh();
setInterval(refresh,30000);
pollAlerts();
setInterval(pollAlerts,20000);
</script>
</body></html>
HTML
} > "$WEBDIR/index.html"
