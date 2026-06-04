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
CLOCK_FACE=classic; AI_WALLPAPER=0; AI_PROMPT=
OVERLAY_PULSE=0; PULSE_POS=east; PULSE_URL=; PULSE_JQ=.; PULSE_TTL=5
WEB_BIND=
[ -f "$CONFIG" ] && . "$CONFIG" 2>/dev/null

PORT="@@PORT@@"
[ "$PORT" = "@@PORT""@@" ] && PORT=8787

mkdir -p "$WEBDIR"
[ -f "$LOG" ] || : > "$LOG"

# Installed version (CL-derived, stamped by install.sh in the state dir).
WR_VERSION=; WR_VERSION_ID=; WR_VERSION_HOST=; WR_INSTALLED_AT=; WR_INSTALLED_ON=
VERFILE="$(dirname "$LOG")/version"
[ -f "$VERFILE" ] && . "$VERFILE" 2>/dev/null

# --- gather stats -----------------------------------------------------------
pool_count=$(ls "$POOL"/*.jpg "$POOL"/*.jpeg "$POOL"/*.png 2>/dev/null | wc -l)
pool_size=$(du -sh "$POOL" 2>/dev/null | cut -f1)
fav_count=$(ls "$POOL"/favourites/*.jpg "$POOL"/favourites/*.jpeg "$POOL"/favourites/*.png 2>/dev/null | wc -l)
fav_bit=""; [ "${fav_count:-0}" -gt 0 ] && fav_bit=" · ★ ${fav_count} kept"
# Favourites gallery: thumbnails served by the web server's /fav/ route.
# Click = set as wallpaper, ✕ = move back to the (prunable) pool.
fav_html=""
for f in "$POOL"/favourites/*.jpg "$POOL"/favourites/*.jpeg "$POOL"/favourites/*.png; do
  [ -f "$f" ] || continue
  fb="$(basename "$f")"
  fav_html="$fav_html<div class=fav><img src=\"fav/$fb\" loading=lazy data-img=\"$fb\" title=\"Set as wallpaper\"><button type=button class=unfav data-img=\"$fb\" title=\"Remove from favourites\">&#10005;</button></div>"
done
[ -z "$fav_html" ] && fav_html="<span class=muted style=font-size:12px>none yet — &#9733; Keep the current wallpaper to start a collection</span>"
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
for s in $SOURCES ai; do
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
aichk=""; [ "${AI_WALLPAPER:-0}" = 1 ]         && aichk=" checked"
plschk="";[ "${OVERLAY_PULSE:-0}" = 1 ]        && plschk=" checked"
wbchk=""; [ -n "${WEB_BIND:-}" ]               && wbchk=" checked"
wicchk="";[ "${OVERLAY_WEATHER_ICON_COLOR:-0}" = 1 ] && wicchk=" checked"
wfchk=""; [ "${OVERLAY_WEATHER_FORECAST:-0}" = 1 ] && wfchk=" checked"
clkchk="";[ "${OVERLAY_CLOCK:-0}" = 1 ]        && clkchk=" checked"
c24chk="";[ "${CLOCK_24H:-1}" = 1 ]            && c24chk=" checked"
cdchk=""; [ "${CLOCK_DATE:-0}" = 1 ]           && cdchk=" checked"
# "auto" lets the renderer pick the calmest region of each image per overlay.
POSNS="auto northwest north northeast west center east southwest south southeast"
qpos_opts=$(opts_for "${QUOTE_POS:-south}" $POSNS)
spos_opts=$(opts_for "${STATS_POS:-northeast}" $POSNS)
wpos_opts=$(opts_for "${WEATHER_POS:-north}" $POSNS)
cpos_opts=$(opts_for "${CLOCK_POS:-northwest}" $POSNS)
ppos_opts=$(opts_for "${PULSE_POS:-east}" $POSNS)
pttl_opts=""
for n in 1 5 15 30; do
  s=""; [ "${PULSE_TTL:-5}" = "$n" ] && s=" selected"
  pttl_opts="${pttl_opts}<option value=\"$n\"$s>${n} min</option>"
done
# Current cached pulse lines (what the overlay is actually showing right now)
pulse_now=""
[ -s "$(dirname "$LOG")/pulse.txt" ] && pulse_now="$(head -8 "$(dirname "$LOG")/pulse.txt" | sed 's/&/\&amp;/g; s/</\&lt;/g')"
cstyle_opts=$(opts_for "${CLOCK_STYLE:-digital}" digital analogue)
cface_opts=$(opts_for "${CLOCK_FACE:-classic}" classic minimal dots numbers)
size_opts=$(opts_for "${OVERLAY_SIZE:-medium}" small medium large)
# Stored values stay dark/light/accent (config + server allow-list compat);
# the DISPLAYED labels are the actual colours so the control can't mislead.
theme_opts=""
for pair in "light:white" "dark:black" "accent:accent"; do
  v="${pair%%:*}"; lbl="${pair#*:}"
  s=""; [ "${OVERLAY_THEME:-light}" = "$v" ] && s=" selected"
  theme_opts="$theme_opts<option value=\"$v\"$s>$lbl</option>"
done
style_opts=$(opts_for "${OVERLAY_STYLE:-scrim}" scrim frosted editorial chips)
# Background themes: multi-select chips (THEME is a space-separated list;
# none checked = any). Each fetch picks one of the checked themes at random.
bg_cur=" ${THEME:-} "
bgtheme_opts=""
for t in nature landscape minimal space city abstract cars cycling animals dark forest ocean; do
  s=""; case "$bg_cur" in *" $t "*) s=" checked";; esac
  bgtheme_opts="$bgtheme_opts<label class=chip><input type=checkbox name=theme value=\"$t\"$s>$t</label>"
done
wloc_val=$(printf '%s' "${WEATHER_LOCATION:-}" | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g')
aip_val=$(printf '%s' "${AI_PROMPT:-}"   | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g')
purl_val=$(printf '%s' "${PULSE_URL:-}"  | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g')
pjq_val=$(printf '%s' "${PULSE_JQ:-.}"   | sed 's/&/\&amp;/g; s/"/\&quot;/g; s/</\&lt;/g')
# Remote-access line: resolve the URL actually reachable from the tailnet.
remote_url=""
if [ -n "${WEB_BIND:-}" ]; then
  if [ "$WEB_BIND" = tailscale ]; then
    ts_ip="$(tailscale ip -4 2>/dev/null | head -1)"
  else
    ts_ip="$WEB_BIND"
  fi
  [ -n "$ts_ip" ] && remote_url="http://${ts_ip}:${PORT}"
fi
# Pre-built snippets: quotes inside a ${var:+...} expansion would be consumed
# by the shell (quote removal applies within parameter expansions).
remote_card=""; remote_foot=""
if [ -n "$remote_url" ]; then
  remote_card="<span class=fld><a href=\"$remote_url\" style=\"color:#7cc4ff\">$remote_url</a></span>"
  remote_foot="<br>Remote (tailnet): <a href=\"$remote_url\" style=\"color:#7cc4ff\">$remote_url</a>"
fi
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
<link rel="icon" type="image/svg+xml" href="data:image/svg+xml;base64,${favicon_b64}">
<title>Wallpaper Rotator${host:+ · $host}${pool_count:+ — ${pool_count} imgs}</title>
<style>
:root{color-scheme:dark}
body{margin:0;background:#14161a;color:#e6e8ec;font:14px/1.5 system-ui,sans-serif}
.wrap{max-width:1560px;margin:0 auto;padding:20px 28px}
/* Wide screens: status (thumb + cards) left, controls right — interactive bits
   above the fold; downloads/activity diagnostics flow below-left. Narrow
   screens keep the original single-column stack (source order). */
@media(min-width:1100px){
  .cols{display:grid;grid-template-columns:minmax(0,1.15fr) minmax(0,1fr);column-gap:28px;align-items:start}
  .col-status{grid-column:1;grid-row:1}
  .col-ctl{grid-column:2;grid-row:1/span 2}
  .col-extra{grid-column:1;grid-row:2}
  /* drop the heading so the panel top aligns flush with the thumbnail top */
  .col-ctl>h2:first-child{display:none}
  /* 6 status cards as a neat 3+3 instead of auto-fit's ragged 4+2 */
  .col-status .grid{grid-template-columns:repeat(3,1fr)}
}
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
form.controls{background:#1c1f26;border:1px solid #262a33;border-radius:12px;padding:18px}
.ctl-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:14px}
/* odd group count: let the last (Appearance) span the row instead of orphaning */
.ctl-grid>.ctl-grp:last-child{grid-column:1/-1}
.ctl-grid>.ctl-wide{grid-column:1/-1}
.pulse-pre{flex:1;background:#0f1115;border:1px solid #23272f;border-radius:8px;padding:8px 12px;font-size:12px;margin:0;min-height:34px;max-height:140px;overflow:auto;color:#9fb4cc}
.ctl-grp{background:#15181e;border:1px solid #23272f;border-radius:10px;padding:12px 14px}
.ctl-lbl{display:block;font-size:11px;text-transform:uppercase;letter-spacing:.06em;color:#7c828c;margin:0 0 9px}
.ctl-row{display:flex;flex-wrap:wrap;align-items:center;gap:10px 14px}
.ctl-row label{display:flex;align-items:center;gap:6px;color:#cfd3da;font-size:13px;margin:0}
.ctl-row .muted{color:#7c828c;font-size:12px}
.ctl-row .fld{display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
form.controls select,form.controls input[type=text]{background:#0f1115;color:#e6e8ec;border:1px solid #2a2f39;border-radius:6px;padding:5px 8px;font-size:13px;outline:none}
form.controls select:hover{border-color:#37425a}
form.controls input[type=text]:focus,form.controls select:focus{border-color:#3a6df0}
form.controls input[type=checkbox]{accent-color:#3a6df0;width:15px;height:15px;margin:0}
.ctl-apply{margin-top:16px;background:#3a6df0;color:#fff;border:0;border-radius:8px;padding:10px 24px;cursor:pointer;font-weight:600;font-size:14px;min-width:170px;transition:background .15s}
.ctl-apply:hover{background:#2f5fd6}
/* AJAX submit states — colour-only feedback, min-width keeps the button steady */
.ctl-apply.busy{background:#2a3b66;cursor:progress}
.ctl-apply.done{background:#2e9e5b}
.ctl-apply.err{background:#b5544f}
.ctl-apply .spin{display:inline-block;width:12px;height:12px;margin-right:8px;vertical-align:-1px;border:2px solid rgba(255,255,255,.35);border-top-color:#fff;border-radius:50%;animation:ctlspin .7s linear infinite}
@keyframes ctlspin{to{transform:rotate(360deg)}}
/* card header with the feature name + an enable toggle on the right */
.ctl-hd{display:flex;align-items:center;justify-content:space-between;margin:0 0 9px}
.ctl-hd .ctl-lbl{margin:0}
/* toggle switch (checkbox hidden, sibling span is the track+knob) */
.tgl{display:inline-flex;cursor:pointer}
.tgl input{position:absolute;opacity:0;width:0;height:0}
.tgl .sw{width:34px;height:19px;border-radius:10px;background:#363b45;position:relative;transition:background .15s;display:inline-block}
.tgl .sw::after{content:"";position:absolute;top:2px;left:2px;width:15px;height:15px;border-radius:50%;background:#fff;transition:left .15s}
.tgl input:checked + .sw{background:#3a6df0}
.tgl input:checked + .sw::after{left:17px}
/* enabled card gets a subtle accent; disabled sub-controls dim out */
.ctl-grp.on{border-color:#34508f;background:#171b22}
.ctl-grp [disabled]{opacity:.38;cursor:not-allowed}
.ctl-grp.off .ctl-row{opacity:.55}
/* curation buttons under the thumbnail */
.cur-actions{display:flex;gap:10px;margin:10px 0 2px}
.act{background:#1c1f26;color:#e6e8ec;border:1px solid #2a2f39;border-radius:8px;padding:7px 16px;min-width:96px;cursor:pointer;font-size:13px;font-weight:600;transition:border-color .15s,background .15s}
.act:hover{border-color:#3a6df0}
.act.danger:hover{border-color:#b5544f;color:#e8a9a5}
.act:disabled{opacity:.45;cursor:progress}
/* background-theme chips */
.chip{background:#0f1115;border:1px solid #2a2f39;border-radius:999px;padding:3px 10px;font-size:12px;display:inline-flex;align-items:center;gap:5px;cursor:pointer;color:#cfd3da}
.chip input{accent-color:#3a6df0;width:13px;height:13px;margin:0}
.chip:has(input:checked){border-color:#3a6df0;background:#1b2536}
/* favourites gallery */
.favs{display:grid;grid-template-columns:repeat(auto-fill,minmax(120px,1fr));gap:10px}
.fav{position:relative}
.fav img{width:100%;aspect-ratio:16/9;object-fit:cover;border-radius:8px;border:1px solid #262a33;display:block;cursor:pointer;transition:border-color .15s}
.fav img:hover{border-color:#3a6df0}
.fav .unfav{position:absolute;top:4px;right:4px;width:20px;height:20px;line-height:1;background:rgba(0,0,0,.55);color:#e6e8ec;border:0;border-radius:6px;cursor:pointer;font-size:11px;transition:background .15s}
.fav .unfav:hover{background:#b5544f}
/* collapsed-by-default recent activity with a chevron */
details.ra summary{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:#8a909a;margin:24px 0 8px;cursor:pointer;list-style:none;display:flex;align-items:center;gap:8px;user-select:none}
details.ra summary::-webkit-details-marker{display:none}
details.ra summary::before{content:"";width:7px;height:7px;border-right:2px solid #8a909a;border-bottom:2px solid #8a909a;transform:rotate(-45deg);transition:transform .15s;flex:none}
details.ra[open] summary::before{transform:rotate(45deg)}
</style></head><body><div class=wrap>
<h1>🖼️ wallpaper-rotator</h1>
<div class=sub id=page-sub>v${WR_VERSION:-unknown} · desktop: ${de:-?} · backend: ${backend:-?} · resolution: ${RES} · generated ${now}</div>
<div class=cols><div class=col-status>
HTML

if [ "$have_thumb" = 1 ]; then
  echo "<img class=cur id=cur-img data-img=\"${cur_img:-}\" src=\"current.jpg?$(date +%s)\" alt=\"current wallpaper\">" >> "$WEBDIR/index.html"
fi
cat >> "$WEBDIR/index.html" <<'HTML'
<div class=cur-actions>
<button type=button class=act data-act=next title="Rotate to another wallpaper now">&#9197; Next</button>
<button type=button class=act data-act=keep title="Move to favourites — stays in rotation, never pruned">&#9733; Keep</button>
<button type=button class="act danger" data-act=ban title="Delete this image from the pool and rotate">&#128683; Ban</button>
</div>
HTML

cat >> "$WEBDIR/index.html" <<HTML
<div class=grid id=status-cards>
  <div class=card><div class=k>Pool</div><div class=v>${pool_count} <small>images · ${pool_size:-?}${fav_bit}</small></div></div>
  <div class=card><div class=k>Current image</div><div class=v style=font-size:14px>${cur_img:-none}</div></div>
  <div class=card><div class=k>Last rotate</div><div class=v style=font-size:14px>${rotate_when:-never}</div></div>
  <div class=card><div class=k>Last download</div><div class=v style=font-size:14px>${dl_when:-never}</div></div>
  <div class=card><div class=k>Pruned (total)</div><div class=v>${pruned_total:-0}</div></div>
  <div class=card><div class=k>Download misses / fails</div><div class=v>${dl_miss:-0} <small>/ ${dl_fail:-0}</small></div></div>
</div>
</div><div class=col-ctl>
<h2>Controls</h2>
<form class=controls method=post action="/set">
<div class=ctl-grid>
  <div class=ctl-grp><div class=ctl-hd><span class=ctl-lbl>Rotation</span></div>
    <div class=ctl-row><span class=fld><span class=muted>Change every</span><select name=interval>${int_opts}</select></span></div></div>
  <div class=ctl-grp data-feat=quote><div class=ctl-hd><span class=ctl-lbl>Quote</span>
      <label class=tgl><input type=checkbox name=quote value=1${qchk}><span class=sw></span></label></div>
    <div class=ctl-row>
      <label><input type=checkbox name=quote_detail value=1${qdchk}> Attribution</label>
      <span class=fld><span class=muted>at</span><select name=quote_pos>${qpos_opts}</select></span>
    </div></div>
  <div class=ctl-grp data-feat=stats><div class=ctl-hd><span class=ctl-lbl>System stats</span>
      <label class=tgl><input type=checkbox name=stats value=1${schk}><span class=sw></span></label></div>
    <div class=ctl-row>
      <label><input type=checkbox name=sparkline value=1${spchk}> Sparklines</label>
      <span class=fld><span class=muted>at</span><select name=stats_pos>${spos_opts}</select></span>
    </div></div>
  <div class=ctl-grp data-feat=weather><div class=ctl-hd><span class=ctl-lbl>Weather</span>
      <label class=tgl><input type=checkbox name=weather value=1${wchk}><span class=sw></span></label></div>
    <div class=ctl-row>
      <span class=fld><span class=muted>at</span><select name=weather_pos>${wpos_opts}</select></span>
      <input type=text name=weather_location value="${wloc_val}" placeholder="Location" size=10>
      <label><input type=checkbox name=weather_icon value=1${wichk}> Icon</label>
      <label><input type=checkbox name=weather_icon_color value=1${wicchk}> Colour</label>
      <label><input type=checkbox name=weather_forecast value=1${wfchk}> Forecast</label>
    </div></div>
  <div class=ctl-grp data-feat=clock><div class=ctl-hd><span class=ctl-lbl>Clock</span>
      <label class=tgl><input type=checkbox name=clock value=1${clkchk}><span class=sw></span></label></div>
    <div class=ctl-row>
      <select name=clock_style>${cstyle_opts}</select>
      <span class=fld><span class=muted>face</span><select name=clock_face>${cface_opts}</select></span>
      <span class=fld><span class=muted>at</span><select name=clock_pos>${cpos_opts}</select></span>
      <label><input type=checkbox name=clock_24h value=1${c24chk}> 24h</label>
      <label><input type=checkbox name=clock_date value=1${cdchk}> Date</label>
    </div></div>
  <div class=ctl-grp><div class=ctl-hd><span class=ctl-lbl>Background themes</span><span class=muted style=font-size:11px>none = any</span></div>
    <div class=ctl-row style="gap:6px">${bgtheme_opts}</div></div>
  <div class=ctl-grp data-feat=ai><div class=ctl-hd><span class=ctl-lbl>AI dreamed</span>
      <label class=tgl><input type=checkbox name=ai value=1${aichk}><span class=sw></span></label></div>
    <div class=ctl-row>
      <input type=text name=ai_prompt value="${aip_val}" placeholder="extra style words (optional)" size=22>
      <span class=muted>generates images from live context (time, season, weather, theme) — ~30s each</span>
    </div></div>
  <div class="ctl-grp ctl-wide" data-feat=pulse><div class=ctl-hd><span class=ctl-lbl>Pulse &mdash; live JSON on the wallpaper</span>
      <label class=tgl><input type=checkbox name=pulse value=1${plschk}><span class=sw></span></label></div>
    <div class=ctl-row style="margin-bottom:8px">
      <span class=fld><span class=muted>at</span><select name=pulse_pos>${ppos_opts}</select></span>
      <span class=fld><span class=muted>refresh every</span><select name=pulse_ttl>${pttl_opts}</select></span>
      <span class=muted>any JSON endpoint (http/https/file) + a jq template &rarr; one overlay line per output line (max 8)</span>
    </div>
    <div class=ctl-row style="margin-bottom:8px">
      <span class=fld style="flex:1"><span class=muted>URL</span><input type=text name=pulse_url value="${purl_val}" placeholder="https://host:3000/api/pulse or file:///path/data.json" style="flex:1;min-width:260px"></span>
      <span class=fld style="flex:1"><span class=muted>template</span><input type=text name=pulse_jq value="${pjq_val}" placeholder='.lines[]  or  "jobs \(.jobs)","mail \(.mail)"' style="flex:1;min-width:200px"></span>
      <button type=button class=act id=pulse-test style="min-width:70px">Test</button>
    </div>
    <div class=ctl-row>
      <pre id=pulse-preview class=pulse-pre>${pulse_now:-（press Test to preview, or Apply to go live）}</pre>
    </div></div>
  <div class=ctl-grp data-feat=remote><div class=ctl-hd><span class=ctl-lbl>Remote access</span>
      <label class=tgl><input type=checkbox name=web_bind value=1${wbchk}><span class=sw></span></label></div>
    <div class=ctl-row>
      ${remote_card}
      <span class=muted>binds the tailnet IP (no auth &mdash; trusted networks only); applying a change restarts the server, page back in ~2s</span>
    </div></div>
  <div class=ctl-grp><div class=ctl-hd><span class=ctl-lbl>Appearance</span></div>
    <div class=ctl-row>
      <span class=fld><span class=muted>Style</span><select name=overlay_style>${style_opts}</select></span>
      <span class=fld><span class=muted>Size</span><select name=size>${size_opts}</select></span>
      <span class=fld><span class=muted>Text colour</span><select name=overlay_theme>${theme_opts}</select></span>
      <span class=fld><span class=muted>Font</span><select name=font>${font_opts}</select></span>
    </div></div>
</div>
<button type=submit class=ctl-apply>Apply changes</button>
</form>
<script>
(function(){
  // Reflect each feature's enable toggle on its card (accent when on, dim when
  // off). Controls are only DIMMED, never disabled — disabled fields aren't
  // submitted, which would reset a saved position when you toggle off + Apply.
  function sync(){
    document.querySelectorAll('.ctl-grp[data-feat]').forEach(function(g){
      var cb=g.querySelector('.tgl input'); if(!cb)return;
      g.classList.toggle('on',cb.checked); g.classList.toggle('off',!cb.checked);
    });
  }
  document.addEventListener('change',function(e){if(e.target.closest('.tgl'))sync();});
  sync();

  // NB: this block sits inside gen-status.sh's UNQUOTED heredoc — no backticks,
  // no template literals, no dollar signs anywhere in the JS.

  // Form-drift guard: fields the user has TOUCHED are left alone, but every
  // untouched field self-syncs to the saved config on each soft refresh —
  // otherwise a long-open tab's Apply silently reverts settings changed from
  // another tab/machine (clock-date flip-flop, Fam1 2026-06-04).
  var dirty={};
  document.addEventListener('input',function(e){
    if(e.target.name&&e.target.closest('form.controls'))dirty[e.target.name]=1;
  });
  function syncForm(d){
    var lf=document.querySelector('form.controls'),nf=d.querySelector('form.controls');
    if(!lf||!nf)return;
    lf.querySelectorAll('input,select').forEach(function(el){
      if(!el.name||dirty[el.name])return;
      var cands=nf.querySelectorAll('[name="'+el.name+'"]');
      if(el.type==='checkbox'){
        var match=null;
        cands.forEach(function(c){if(c.value===el.value)match=c;});
        el.checked=!!(match&&match.checked);
      } else if(cands[0]){ el.value=cands[0].value; }
    });
    sync();   // re-apply the card on/off accents to the synced state
  }

  // Pull fresh status out of a fetched copy of this page and swap it in place.
  // In-progress form edits survive a refresh (see the drift guard above).
  function swapStatus(html){
    var d=new DOMParser().parseFromString(html,'text/html');
    ['page-sub','status-cards','src-table','recent-pre','fav-count','fav-grid'].forEach(function(id){
      var n=d.getElementById(id),o=document.getElementById(id);
      if(n&&o)o.innerHTML=n.innerHTML;
    });
    syncForm(d);
    // Only reload the thumbnail when the underlying image actually changed
    // (the src cache-buster differs every regen and would flicker otherwise).
    var ni=d.getElementById('cur-img'),oi=document.getElementById('cur-img');
    if(ni&&oi&&ni.getAttribute('data-img')!==oi.getAttribute('data-img')){
      oi.setAttribute('data-img',ni.getAttribute('data-img')||'');
      oi.src=ni.getAttribute('src');
    }
  }
  function refresh(){fetch('/').then(function(r){return r.text();}).then(swapStatus).catch(function(){});}
  setInterval(refresh,30000);   // soft update — replaces the old meta-refresh full reload

  // Pulse "Test": dry-run the URL + template server-side, show the lines.
  var pt=document.getElementById('pulse-test');
  if(pt)pt.addEventListener('click',function(){
    var f=document.querySelector('form.controls');
    var pv=document.getElementById('pulse-preview'); if(!f||!pv)return;
    var body=new URLSearchParams();
    body.set('url',(f.elements.pulse_url&&f.elements.pulse_url.value)||'');
    body.set('jq',(f.elements.pulse_jq&&f.elements.pulse_jq.value)||'.');
    pt.disabled=true;pv.textContent='testing…';
    fetch('/pulse_test',{method:'POST',body:body})
      .then(function(r){return r.text();})
      .then(function(t){pv.textContent=t;})
      .catch(function(){pv.textContent='test failed (network)';})
      .then(function(){pt.disabled=false;});
  });

  // Curation buttons (Next/Keep/Ban): POST the action, swap fresh status in.
  var acts=document.querySelectorAll('.act[data-act]');
  acts.forEach(function(b){
    b.addEventListener('click',function(){
      acts.forEach(function(x){x.disabled=true;});
      var t0=b.textContent;b.textContent='working…';
      fetch('/'+b.getAttribute('data-act'),{method:'POST'})
        .then(function(r){if(!r.ok)throw new Error('http '+r.status);return r.text();})
        .then(swapStatus).catch(function(){})
        .then(function(){b.textContent=t0;acts.forEach(function(x){x.disabled=false;});});
    });
  });

  // Favourites gallery: click a thumb = set as wallpaper, ✕ = unfavourite.
  // Delegated — the grid's innerHTML is replaced by status swaps.
  document.addEventListener('click',function(e){
    var un=e.target.closest('.unfav');
    var im=un?null:e.target.closest('.fav img');
    var el=un||im; if(!el)return;
    var name=el.getAttribute('data-img'); if(!name)return;
    var body=new URLSearchParams(); body.set('img',name);
    el.style.opacity='.4';
    fetch(un?'/unfav':'/use',{method:'POST',body:body})
      .then(function(r){if(!r.ok)throw new Error('http '+r.status);return r.text();})
      .then(swapStatus).catch(function(){})
      .then(function(){el.style.opacity='';});
  });

  // AJAX Apply: stay on the page, show progress on the button itself.
  var form=document.querySelector('form.controls');
  var btn=form&&form.querySelector('.ctl-apply');
  if(form&&btn)form.addEventListener('submit',function(e){
    e.preventDefault();
    if(btn.disabled)return;
    var idle='Apply changes';
    btn.disabled=true;btn.classList.add('busy');
    btn.innerHTML='<span class=spin></span>Applying…';
    fetch('/set',{method:'POST',body:new URLSearchParams(new FormData(form))})
      .then(function(r){if(!r.ok)throw new Error('http '+r.status);return r.text();})
      .then(function(html){          // POST redirects to /, so this IS the fresh page
        dirty={};                    // server state now matches the form
        swapStatus(html);
        btn.classList.remove('busy');btn.classList.add('done');btn.textContent='Applied ✓';
        setTimeout(function(){btn.classList.remove('done');btn.textContent=idle;btn.disabled=false;},1600);
      })
      .catch(function(){
        btn.classList.remove('busy');btn.classList.add('err');btn.textContent='Failed — try again';
        setTimeout(function(){btn.classList.remove('err');btn.textContent=idle;btn.disabled=false;},2600);
      });
  });
})();
</script>
</div><div class=col-extra>
<details class=ra open><summary>Favourites (<span id=fav-count>${fav_count}</span>)</summary>
<div class=favs id=fav-grid>${fav_html}</div>
</details>
<h2>Downloads by source</h2>
<table id=src-table>${src_rows}</table>
<details class=ra><summary>Recent activity</summary>
<pre id=recent-pre>${recent:-（no activity logged yet）}</pre>
</details>
</div></div>
<div class=foot>v${WR_VERSION_ID:-unknown}${WR_VERSION_HOST:+ (authored on ${WR_VERSION_HOST})}${WR_INSTALLED_AT:+ · installed ${WR_INSTALLED_AT}}${WR_INSTALLED_ON:+ on ${WR_INSTALLED_ON}}<br>Sources: ${SOURCES} · log: ${LOG} · status auto-updates every 30s${remote_foot}</div>
</div></body></html>
HTML
