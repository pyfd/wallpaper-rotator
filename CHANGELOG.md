# Changelog

All notable changes to wallpaper-rotator are recorded here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).
Entry headers carry the date + local time + machine the change was made on
(`## YYYY-MM-DD HH:MM TZ — <host>`).

## 2026-06-04 21:04 BST — Fam3

### Fixed
- **AI dreamed gens all silently missing (Horde KudosUpfront)** — AI Horde now
  403s anonymous requests over 665px ("KudosUpfront" policy), so every
  1024x576 submit failed in ~1s (`src=ai miss`). Anonymous gens now use
  640x384 (largest allowed 64-multiple frame; renderer crop-fills up); new
  optional `AI_HORDE_KEY` config (free stablehorde.net registration) restores
  full-res. Verified: first-ever `.ai.jpg` landed on Fam3 ~70s after the fix.
- **First-ever quote seed/refresh failed with no cache file** — the merge
  began `cat "$TMP" "$CACHE"`; with no cache yet, cat exits 1 and pipefail
  skipped the `mv`, so no cache was ever written (self-perpetuating). Inner
  cat now tolerates a missing cache.

### Added
- **Quote themes in the web UI** — new "theme" select in the Quote group
  (any / love / life / inspirational / humor / philosophy / wisdom /
  happiness / hope / success / romance / friendship / science). The bulk seed
  now keeps each quote's Quotes-500K category tags as a 5th cache field;
  `QUOTE_THEME` filters the shuffle-bag by tag substring (falls back to the
  whole pool when nothing matches, e.g. unseeded cache); theme changes
  rebuild the bag on the next render via a marker file.

## 2026-06-04 20:50 BST — Fam3

### Added
- **Bulk quote seeding (`fetch-quotes.sh --seed`)** — answers "the ~1450-quote
  pool will exhaust eventually": samples 30k length-filtered quotes from the
  Quotes-500K dataset (HuggingFace mirror, 144MB CSV, python3-parsed; fallback
  ~9k from dwyl/JamesFT/quotable GitHub sets), merged into the cache. Cache cap
  raised 500 → 50k, seen-history bound 1k → 60k to match. install.sh
  auto-seeds in the background when the cache is unseeded (<2000 lines).
  ~2 months of 3-min rotations with zero repeats; daily refreshes merge on
  top, and a future exhausted bag tops up before any history reset.

## 2026-06-04 20:41 BST — Fam3

### Fixed
- **Quote repetition (round 2)** — the shuffle-bag was sound but the refetch
  path defeated it: `fetch-quotes.sh` OVERWROTE the cache with each batch, and
  both fallback sources serve near-static batches (dummyjson without `skip` is
  literally the same 30 every call; zenquotes' free endpoint returned an
  identical 50 twice in a row when tested). A batch fully covered by the seen
  history emptied the bag and triggered the run-dry history reset — hence
  visible repeats. Now: dummyjson random-pages (`skip=$((RANDOM%1400))`) and
  refreshes MERGE into the cache (dedupe by text, newest first, cap 500), so
  the known pool grows toward hundreds and the no-repeat cycle stretches with it.

## 2026-06-04 20:37 BST — Fam3

### Changed
- **Pulse overlay restyled** — was 8 flat mono lines ("ready 8"), now: lines
  containing `|` render as two aligned columns (muted label left, ACCENT
  value right-aligned) so the numbers pop and carry context; new optional
  `PULSE_TITLE` config renders a header with a freshness time (cache mtime,
  `@ HH:MM`) over a thin accent rule. Plain lines unchanged — the overlay
  stays generic for any JSON endpoint. Web UI gains a Pulse "title" field
  (persisted via wallpaper-web; gen-status renders it). Pair with
  workshop-service `/api/pulse` `.lines_kv[]` for the SCB shape.

## 2026-06-04 20:25 BST — Fam3

### Added
- **Battery line in the stats overlay** — `bat 76% discharging` (capacity +
  status from the first `/sys/class/power_supply/BAT*`) appended under the
  disk line. Machines with no readable battery (desktops, Termux) skip the
  line entirely; the panel build now uses a file array instead of the fixed
  0–4 list so optional lines can join.

### Fixed
- Removed a stray root-level `set-wallpaper.sh` duplicate that the 14:08
  mirror committed to the standalone repo (the real script lives in `bin/`).

## 2026-06-04 14:08 BST — paul-HP-ProDesk-400-G4-SFF

### Changed
- **No-repeat image rotation (shuffle-bag)** — the 5-min rotate now draws from
  a shuffled queue (`images.bag` + `images.seen`, the same mechanism the quote
  overlay uses) so no image repeats until every pool image has shown once,
  then the cycle reshuffles. Replaces the plain `shuf -n1` pick, which
  produced obvious deja vu well inside a cycle. Pruned files are skipped at
  pop time; new downloads join at the next bag rebuild; single-image pools
  degrade gracefully.
- **Pool ceiling raised 30 → 60** (hourly prune keeps the 60 newest) — paired
  with the bag this gives a ~5-hour no-repeat cycle at the default 5-min
  rotation. Disk cost ~25 MB.

## 2026-06-04 11:51 BST — paul-HP-ProDesk-400-G4-SFF

### Fixed
- **"✦ dreamed" badge hidden behind the desktop panel** — it composited
  +12+8 from the image's bottom-right, and KDE/Cinnamon taskbars (~44-48px)
  cover exactly that strip, so on panel-at-bottom desktops the signature was
  never visible. Raised to +14+72 (clears typical panels with breathing room — Paul's
  eyeball after seeing +50 sit tight against the taskbar).

## 2026-06-04 11:34 BST — paul-HP-ProDesk-400-G4-SFF

### Fixed
- **KDE desktop frozen: cron runs misdetected the DE as GNOME** — with no
  `XDG_CURRENT_DESKTOP` under cron, the process-sniff fallback's bare
  `pgrep -f 'gnome-session'` matched **`at-spi2-registryd --use-gnome-session`**
  (the accessibility daemon, present on every desktop) and GNOME was checked
  before plasma — so on a KDE box every cron rotate set gsettings keys Plasma
  never reads, logging `status=ok` while the visible wallpaper never changed
  (875 such runs on paul-HP; only env-carrying manual/web-UI runs worked).
  Detection now checks the unambiguous sessions first (xfce, cinnamon, mate,
  plasma) and GNOME last with an anchored `(^|/)gnome-session` pattern that
  can't match the at-spi2 flag. Same fix applied to install.sh's cosmetic
  detection. (Surfaced as "rotator stopped working" right after the Pulse
  overlay was saved — coincidental; Pulse also needed a `PULSE_URL`.)

## 2026-06-04 07:42 BST — Fam1

### Fixed
- **Minute clock-refresh cron silently died after the config switched to
  single-quote escaping** (06:26): the cron line matched `OVERLAY_CLOCK="1"`
  literally, so once an Apply rewrote the config as `'1'` the every-minute
  re-render stopped (clock could lag up to the rotate interval). The match is
  now quote-agnostic (`=.?1`).

## 2026-06-04 07:37 BST — Fam1

### Changed
- **AI generation requests are now uncensored** (`nsfw:true, censor_nsfw:false`)
  per user preference — the worker returns the image as generated instead of
  substituting the card on a classifier false-positive. The censored-flag
  rejection stays as a net for workers that force-censor regardless.

## 2026-06-04 07:36 BST — Fam1

### Fixed
- **AI Horde "CENSORED" card no longer saved as a wallpaper.** A worker NSFW
  false-positive (on a sky prompt!) replaces the generation with a black
  text card and sets `generations[].censored` — one landed on the desktop.
  fetch_ai now checks the flag and rejects the card (falling through to the
  normal sources); the response was otherwise indistinguishable from a valid
  image.

## 2026-06-04 07:29 BST — Fam1

### Added
- **Subtle "✦ dreamed" signature on AI-generated wallpapers** — tiny, ~40%
  opacity, bottom-right edge. AI fetches are now named `*.ai.jpg` so
  provenance travels with the file (including into `favourites/`) with no
  manifest; the GUI's Current-image card also tags them "✦ AI dreamed".

## 2026-06-04 06:57 BST — Fam1

### Changed
- **Pulse gets a full-width control section** in the form: position + refresh
  interval (1/5/15/30 min, new `PULSE_TTL`), wide URL + jq-template fields, a
  **Test button** that dry-runs the URL + template server-side (new
  `/pulse_test` endpoint) and previews the lines without applying, and a live
  view of what the overlay is currently showing. Changing the URL/template
  also drops the cached lines so the Apply re-render fetches fresh.

## 2026-06-04 06:49 BST — Fam1

### Fixed
- **Apply hung on "Applying…" when switching AI dreamed on** — the convergence
  fetch ran synchronously inside the POST, and an AI generation takes minutes.
  The AI-on path now converges entirely in the background (generate → show →
  top up 3 more → prune → regen page); Apply returns immediately and the first
  dreamed image appears on the desktop when ready (~1-3 min).

## 2026-06-04 06:26 BST — Fam1

### Added
- **AI-dreamed wallpapers**: an `AI dreamed` toggle makes every new download try
  image *generation* first (normal sources stay as fallback). The prompt builds
  itself from live context — time of day, season, today's weather from the
  forecast cache, the picked background theme — plus optional user style words.
  Backend is **AI Horde** (stablehorde.net): free, anonymous, ~30s-few-minutes
  per image (pollinations.ai was tried first but its anonymous tier is
  rate-limited away; set `AI_TOKEN` in the config to use it as a fast path).
  Turning the toggle on fetches + shows one immediately, then tops up in the
  background.
- **Pulse overlay**: point `PULSE_URL` at ANY JSON endpoint (http/https/file://)
  and shape it with a `PULSE_JQ` template — each output line renders as a
  stats-style overlay line (max 8, cached 5 min). Business dashboards, CI
  status, home automation — whatever JSON you have.
- **Auto overlay placement**: every position select gains **auto** — the
  renderer ranks the 9 anchor regions of the current image by visual busyness
  (grayscale std-dev, cached per image) and gives each auto overlay the calmest
  remaining spot, reserving explicitly-placed overlays first. Text stops
  landing on busy detail.
- **Remote access controls in the GUI**: a `Remote access` toggle binds/unbinds
  the tailnet IP (config `WEB_BIND`; applying a change self-restarts the
  server), and the page + footer show the reachable tailnet URL when active.

### Changed
- Config is now written with single-quote shell escaping so jq templates,
  quotes and `$` in values survive sourcing verbatim.

## 2026-06-04 06:14 BST — Fam1

### Fixed
- **Stale-tab Apply no longer reverts settings changed elsewhere.** The form in
  an open tab never updated (soft refresh deliberately leaves it alone), so an
  Apply from a long-open tab silently submitted old state over newer config.
  Untouched fields now self-sync to the saved config on every soft refresh;
  fields the user has actually edited stay put (and count as in-sync again
  after a successful Apply).

## 2026-06-04 06:09 BST — Fam1

### Added
- **Curation buttons** under the web UI thumbnail: **⏭ Next** (rotate now),
  **★ Keep** (move to `favourites/` — stays in rotation forever: the pool
  subdir is found by set-wallpaper's recursive pick but every pruner globs
  only the top level), **🚫 Ban** (delete from pool + rotate; a replacement
  fetch tops the pool back up in the background). Pool card shows `★ N kept`.
- **Favourites gallery** in the web UI (collapsible, open by default):
  thumbnails of everything kept — click one to set it as the wallpaper,
  ✕ to move it back to the prunable pool. Served via the new `/fav/<name>`
  route; `/use` and `/unfav` endpoints.
- **Tailnet remote access**: new `WEB_BIND` config key (not in the form;
  service restart to apply). `WEB_BIND="tailscale"` also binds this machine's
  tailnet IP — control any machine's wallpaper from a phone; an explicit IP
  works too; default stays localhost-only. No auth — only open it to networks
  where everyone may control the wallpaper.
- **Multi-theme rotation**: the Background theme select is now a row of
  checkbox chips — tick several (e.g. forest + ocean + space) and each fetch
  picks one at random, so the pool converges to a mix. `THEME` becomes a
  space-separated list; none checked = any.
- **Analogue clock faces**: new `face` select in the Clock card —
  **classic** (12 ticks), **minimal** (quarter ticks), **dots** (12 dots,
  larger at quarters), **numbers** (12/3/6/9 numerals). `CLOCK_FACE` config
  key, default classic.

### Changed
- **Recent activity is collapsed by default** behind a chevron (native
  `<details>`); click to expand.

## 2026-06-04 05:54 BST — Fam1

### Changed
- **"Text" select relabelled "Text colour"** with options displayed as
  **white / black / accent** (stored values stay `light`/`dark`/`accent` for
  config + allow-list compat) — the theme-flavoured words were still easy to
  misread even after the inversion fix.

## 2026-06-04 05:52 BST — Fam1

### Fixed
- **"Text" colour select was inverted**: `OVERLAY_THEME` carried UI-theme
  semantics (dark theme → white text), so picking "dark" gave light text and
  vice versa. It now names the text colour itself — dark = black text,
  light = white text — and the shipped default flips from `dark` to `light`
  so the out-of-box look (white text) is unchanged. **Note for existing
  installs**: a saved `OVERLAY_THEME="dark"` now renders black text — re-pick
  in the web UI (or edit the config) if you want to stay white.

## 2026-06-04 05:47 BST — Fam1

### Changed
- **Two-column layout alignment polish**: controls panel now sits flush with
  the thumbnail top (heading hidden on wide screens), status cards render a
  neat 3+3 instead of auto-fit's ragged 4+2, and the odd-count Appearance
  group spans the full row instead of leaving an orphan gap.

## 2026-06-04 05:45 BST — Fam1

### Fixed
- **"Date" had no effect with the analogue clock** — it was only implemented
  for the digital style; the analogue branch silently ignored `CLOCK_DATE`.
  The analogue face now gets the same small date line underneath
  (`Thu 4 Jun`), sized to the face diameter.

## 2026-06-04 05:42 BST — Fam1

### Changed
- **Wide-screen two-column layout for the web UI.** The page was an 860px
  centre column, pushing Controls below the fold on a desktop monitor. Now up
  to 1560px wide: ≥1100px viewports get thumbnail + status cards on the left
  with the Controls form alongside on the right (downloads/recent-activity
  diagnostics flow below-left); narrow/mobile keeps the single-column stack.

## 2026-06-04 05:38 BST — Fam1

### Changed
- **Faster recovery from the 2-day forecast.** While the cached forecast still
  leads with a past day (wttr.in pre-rollover, so only Today + 1 render after
  the past-day drop), the raw cache TTL is cut from 3h to 30min — the third day
  reappears soon after the API catches up instead of waiting out the full cache.

## 2026-06-04 05:35 BST — Fam1

### Fixed
- **Forecast day labels off by one** ("Today Thu Fri" shown on a Thursday):
  wttr.in's `weather[0]` can still be *yesterday* early in the morning (its data
  generation lags), and "Today" was baked into the 3h cache at fetch time so it
  also went stale across midnight. The raw API dates are now cached instead and
  labels are resolved at render time — each day's real date is compared to the
  current date: past days are dropped, today's labelled "Today", the rest get
  their weekday name.

## 2026-06-04 05:28 BST — Fam1

### Changed
- **Smooth Apply + soft status refresh in the web UI.** "Apply changes" now
  submits via fetch() and stays on the page: the button shows a spinner +
  "Applying…" while the server works (a theme change can take a while), then
  "Applied ✓" (green) or "Failed — try again" (red) — no more jarring full-page
  POST→redirect→reload. The 30-second `<meta http-equiv=refresh>` full reload is
  gone too: a background fetch swaps just the status cards / thumbnail /
  downloads table / recent-activity log in place, never the form, so in-progress
  edits survive and the thumbnail only reloads when the image actually changed.

## 2026-06-04 05:20 BST — Fam1

### Fixed
- **Re-running install.sh didn't restart a running wallpaper-web**, so the old
  server kept handling POSTs from the freshly regenerated controls form — new
  settings it didn't know (e.g. Clock) were silently dropped from the config on
  every Apply. `systemctl --user enable --now` is a no-op when the unit is
  already active; install.sh now does `enable` + `restart` so an upgrade always
  brings the new server code live.

## 2026-06-03 10:46 BST — paul-HP-ProDesk-400-G4-SFF

### Changed
- **Controls form polish — toggle switches + active cards.** Each feature card
  (Quote / System stats / Weather / Clock) now has a header **toggle switch** for
  its enable, with the sub-options below; an enabled card gets a subtle accent
  border, and toggling off dims the card (a tiny inline script reflects the
  toggle state — controls are only *dimmed*, never `disabled`, so their values
  still submit and a saved position isn't lost when you toggle off + Apply).

### Fixed
- **Weather overlay didn't show after upgrading** if a pre-structured (legacy)
  `weather.txt` cache was <60 min old: the new `weather_line` keyed off the
  `|`-structured format but never force-refreshed the legacy one. It now also
  refreshes when the cache lacks `|`, so it self-heals on upgrade.

## 2026-06-03 10:04 BST — paul-HP-ProDesk-400-G4-SFF

### Changed
- **Modernised the web-UI controls form.** The controls had grown to ~24 mixed
  checkboxes/selects in a single flat wrap that read as cluttered. They're now
  grouped into labelled cards — **Rotation / Quote / System stats / Weather /
  Clock / Background / Appearance** — laid out in a responsive grid, with
  consistent input styling, accent-blue checkboxes, label+control pairs kept
  together on wrap (`.fld`, no orphaned labels), and a proper **Apply changes**
  button. Pure layout/CSS in `gen-status.sh`; same control names + behaviour, so
  `wallpaper-web.py` is unchanged. (Re-applied on top of the clock/forecast/
  overlay-style controls added in parallel on Fam3/e210.)

## 2026-06-03 08:58 BST — paul-e210

### Added
- **Version number + tracker, derived from the CHANGELOG.** The version *is* the
  newest CHANGELOG entry — this header's date (`v2026.06.03`), with the time +
  authoring host for precise tracking — so every entry auto-bumps it and there's no
  separate `VERSION` file to maintain.
  - `install.sh` parses the top `## YYYY-MM-DD HH:MM TZ — host` header and stamps
    `~/.local/state/wallpaper-rotator/version` (`WR_VERSION`, `WR_VERSION_ID`,
    authoring host, install time + host), and prints the version in its summary.
  - The **web UI** shows the version in the header subline (`v2026.06.03`) and the
    full id + install details in the footer — so each machine's `:8787` page tells
    you at a glance what it's running and when it was installed.
  - **`set-wallpaper.sh --version`** (`-V`) prints the installed version and exits.

## 2026-06-03 07:26 BST — Fam3

### Fixed
- **Quotes repeated through the day** (seen the same one earlier). `pick_quote` did
  `shuf -n1` each rotation, so repeats happened by chance. Now it's a **shuffle-bag**:
  draw from a shuffled queue (`quotes.bag`) so none repeats until all have shown.
  - When the bag is **exhausted**, it downloads a **fresh batch** (`fetch-quotes.sh`)
    for the next bag instead of reshuffling the same set.
  - A persistent **seen-list** (`quotes.seen`, by quote text, last ~1000) filters
    every new/re-downloaded bag, so an overlapping re-download never re-shows a
    quote already had — until the whole known set is exhausted, then the seen-list
    resets and cycling resumes. (`@@FETCHQ@@` added to set-wallpaper.sh.)
- **Wallpaper double-rendered / flickered every 3rd minute.** The web UI's
  `set_cron_interval` rewrote *every* line containing the set-wallpaper path to
  `*/N` — including the every-minute clock-refresh line — so both fired together and
  raced (two renders/sets in one second, and a race on the quote bag). Now it only
  rewrites the rotate line (the clock line references `current`), and set-wallpaper
  takes a **non-blocking lock** so two runs can never render at once (the later one
  skips that tick). Live crontab repaired (clock line back to `* * * * *`).

## 2026-06-03 07:13 BST — Fam3

### Changed
- **Forecast glyphs are now coloured** (when the weather "colour" toggle is on),
  matching the current-conditions icon — gold sun, blue rain, etc. The forecast
  cache is now stored **structured** (`label⇥condition⇥hi⇥lo` per day) so the line
  is composed per-day, letting each glyph take its condition colour; the colour
  toggle applies at render time without re-fetching. Spacing is via explicit
  transparent spacers (since `-trim` drops whitespace), and the strip is dimmed
  only lightly (0.85) so the colours read while staying secondary.

## 2026-06-03 06:55 BST — Fam3

### Changed
- **Weather forecast line restyled — was cramped/messy.** The forecast read like a
  second competing line (same weight, tight against the current line). Now it's
  clearly secondary: ~70% size, dimmed to 72% opacity, centred under the current
  line with a 14px gap. Reads as "now" + a quiet outlook instead of two dense rows.

## 2026-06-03 06:51 BST — Fam3

### Added
- **Weather forecast line** (`OVERLAY_WEATHER_FORECAST` + "forecast" checkbox). When
  on, the weather overlay gains a second, smaller line with a compact 3-day daily
  outlook — `Today ☀ 24/14 · Thu ☀ 24/16 · Fri ☀ 24/17` (day · condition glyph ·
  maxC/minC), parsed from wttr.in's `?format=j1` JSON via `weather_forecast()` and
  cached ~3h (forecasts move slowly). The current-conditions line is unchanged when
  the toggle is off. Forecast glyphs are rendered in DejaVu-Sans so they never tofu
  regardless of the chosen overlay font. (The existing weather line is still
  **current** conditions, not a forecast.)

## 2026-06-03 06:43 BST — Fam3

### Added
- **Clock overlay** (`OVERLAY_CLOCK`) — **digital** (big time + optional date,
  12/24h) or **analogue** (drawn dial: ring, 12 ticks, hour/minute hands, accent
  centre pin via `draw_clock`), with position + size (shared `OVERLAY_SIZE`) and a
  UI control row (Clock / style / position / 24h / date). Goes through the shared
  `style_block` so it gets the same panel/shadow/collision-avoidance.
  - Because the wallpaper is a static render, a **1-minute cron re-renders the
    current image while the clock is on** (no shuffle) so the baked-in clock stays
    accurate to the minute (and weather/stats refresh too); it's a no-op when the
    clock is off, so there's no extra churn otherwise.
  - To stop that 1-min refresh re-randomising the quote every minute, the quote is
    now **cached per current image** (re-picked only when the image actually
    rotates or the +attribution toggle changes).

## 2026-06-03 06:29 BST — Fam3

### Added
- **Favicon + informative window title for the web UI.** Added an inline SVG
  favicon (framed landscape — accent frame, gold sun, green hills) as a base64
  data-URI, so no server route or binary asset is needed. The `<title>` is now
  `Wallpaper Rotator · <host> — <N> imgs` (was just `wallpaper-rotator`), so the
  browser tab is identifiable per machine at a glance.

## 2026-06-03 06:26 BST — Fam3

### Added
- **Cycling theme** in the Background-theme dropdown (Wallhaven `q=cycling`) —
  fitting for the bike shop.

### Fixed
- **Background theme barely did anything.** Three causes: (1) hitting *Apply* only
  re-rendered the current image and never fetched, so theme changes had no visible
  effect; (2) only Wallhaven honours the theme, but it was 1 of 4 shuffled sources,
  so ~75% of downloads (Bing/Picsum) ignored it; (3) random rotation over a 30-img
  pool of mostly old/untargeted images diluted what little was themed. Now:
  - `fetch-wallpaper.sh` tries **Wallhaven first** when a theme is set (others as
    fallback), so new downloads actually honour it.
  - Changing the theme in the web UI **fetches a themed image immediately and
    displays it** (instant feedback), then tops up the pool with a background burst
    of themed images and trims to the newest ~12, so rotation **converges** to the
    theme. (`wallpaper-web.py` gained `@@FETCH@@`/`@@POOL@@`; a plain Apply with no
    theme change still just re-renders the current image.)

### Changed
- **Sparklines are now drawn graphics, not unicode block chars.** The old
  `▁▂▃▄▅▆▇█` row read like terminal ASCII-art and clashed with the frosted/scrim
  panels + coloured icons. Replaced with an anti-aliased **line + soft area-fill
  sparkline** drawn with ImageMagick (`draw_spark`), in the accent blue (`#7cc4ff`)
  that ties to the editorial accent bar and weather icon. To place the graphic
  precisely beside the load/mem lines, the stats panel is now assembled
  line-by-line (`stat_label` → fixed-height rows → vertical append) instead of one
  caption. Refactored `emit()` into `style_block()` (positions/styles a ready-made
  block PNG) + `emit()` (builds a text/icon block then calls it), so both text
  overlays and the composite stats block share the panel/positioning/collision
  code. Removed the old unicode `sparkline()` helper.

## 2026-06-03 05:51 BST — Fam3

### Added
- **Coloured weather icons** (new `OVERLAY_WEATHER_ICON_COLOR` + "colour" checkbox
  next to the icon toggle). When on, the condition glyph is rendered in a
  characteristic colour — gold `☀`, soft-amber `☼`, grey `☁`, blue `☔`, pale-blue
  `❄`, yellow `⚡` — instead of the overlay text colour. The glyph is rendered as
  its own trimmed element (always DejaVu-Sans, which has the glyphs) and prepended
  to the text, vertically centred with a small gap; `weather_line` now emits
  `glyph<TAB>colour<TAB>text` so the caller can render the icon separately.
  Monochrome icons (colour off) stay inline in the text as before.

## 2026-06-03 05:44 BST — Fam3

### Fixed
- **Overlay panels carried dead space** (stats panel was ~68% empty to the right).
  `mktext`'s `caption:` pads the block to the full `-size` width regardless of how
  short the text is, and the frosted/chips panel inherited that width. Added
  `-trim +repage` so each block crops to its actual text bbox (measured 598→193px
  on the stats lines); the width arg still bounds wrapping. Panels now hug their
  content; positioning/collision-avoidance key off the (now smaller) `bw/bh` so
  they keep working — the `northeast` block just sits flush to the right edge.

## 2026-06-03 05:35 BST — Fam3

### Fixed
- **Overlays could overlap each other** (weather=north ran into stats=northeast —
  both anchored to the top edge, since each overlay was positioned independently
  with no awareness of the others). Added a collision-avoidance pass: after a
  block's anchor position is computed it's nudged along its anchored axis
  (North*/centre → down, South* → up) until it clears every already-placed block,
  tracked in a `PLACED` rectangle list. Footprint padding (36px) covers the
  largest style panel so frosted/chips panels clear too, not just the text. The
  later-emitted block yields (weather drops below stats); generic — works for any
  position combination, not just this pairing.

## 2026-06-03 05:28 BST — Fam3

### Added
- **Weather overlay icons, with a UI toggle** (`OVERLAY_WEATHER_ICON`, new "icon"
  checkbox next to the weather location). Prepends a monochrome glyph mapped from
  the wttr.in condition — `☀` clear, `☁` cloud/overcast/fog, `☼` partly, `☔` rain,
  `❄` snow, `⚡` thunder. Glyphs are restricted to ones the overlay font (DejaVu
  Sans) actually contains — verified by render-test; `⛅` (partly-cloudy) is NOT in
  DejaVu and renders as tofu, so partly uses `☼`.

### Changed
- **Weather location is now title-cased** ("shoreham" → "Shoreham", "new york" →
  "New York"). wttr.in echoes `%l` in the case it was queried (lowercase); the
  overlay now capitalises it. The weather cache changed to structured fields
  (`loc|condition|metrics`) so location-casing and the icon toggle apply at render
  time without re-fetching; a legacy single-line cache is shown verbatim until it
  refreshes. Also trims the trailing space wttr's `%C` carries.
- **Quotes no longer render in Title Case.** Root cause was the source data, not
  our pipeline: the `dummyjson` API ships some quotes pre-mangled in Title Case
  (tell-tale `Can'T`). `fetch-quotes.sh` now (a) prefers the well-cased sources
  (`zenquotes`, then `quotable`) over `dummyjson`, and (b) runs a conservative
  normaliser that de-Title-Cases only fully title-cased quotes (≥80% of words
  capitalised) into sentence case, preserving ALL-CAPS acronyms and leaving
  properly-cased quotes (incl. proper nouns like "Bay of Bengal") untouched.

### Fixed
- **Font dropdown only ever showed "default".** A pre-existing pipefail bug in
  `gen-status.sh`: the font-availability check was `printf … | grep -qx "$fc"`, and
  under `set -o pipefail` grep -q's early exit SIGPIPEs printf (exit 141), so the
  pipeline reported failure even on a match — every candidate font was rejected.
  Switched to a here-string (`grep -qxF -- "$fc" <<<"$avail_fonts"`); all installed
  fonts (DejaVu/Liberation/Free families) now populate the dropdown.

## 2026-06-03 05:15 BST — Fam3

### Added
- **Web UI is now always-on via a systemd user service** (`wallpaper-web.service`).
  Previously the status + control page only existed while you kept `wallpaper-web`
  running in a terminal. `install.sh` now installs a templated `--user` unit to
  `~/.config/systemd/user/wallpaper-web.service` (substituting `@@WEB_BIN@@` →
  `/usr/local/bin/wallpaper-web`) and runs `systemctl --user enable --now`, so the
  page auto-starts at every login and restarts on crash — `http://127.0.0.1:8787`
  is just always there. A per-user localhost daemon is the natural fit for a
  `--user` unit (mirrors the box's existing `battery-warn` user units). The
  ad-hoc `wallpaper-web` launcher still works for boxes with no systemd user
  session. Optional `loginctl enable-linger` documented for pre-login/boot start.
  Install gracefully degrades (prints the manual `systemctl --user enable` command)
  when run without an active user session.

## 2026-06-02

### Fixed
- **Desktop rotation silently failed under cron on GNOME variants** (Zorin, and
  any setup whose session binary name is suffixed). `set-wallpaper.sh`'s
  no-`XDG_CURRENT_DESKTOP` fallback (the cron case) used `pgrep -x gnome-session`,
  but the running process is `gnome-session-binary` *and* the kernel truncates the
  comm name to 15 chars, so the exact match missed → `de=unknown` → it fell through
  to the `feh` branch → exit 127, wallpaper never set (desktop showed the GNOME
  fallback colour). Now matches the full command line via `pgrep -f` and maps to a
  clean DE keyword (`gnome`/`xfce`/`cinnamon`/`mate`/`plasma`); same hardening
  applied to `install.sh`'s detection fallback.
- **install.sh summary printed a hardcoded "rotates every 10 min"** regardless of
  the configured interval (the cron line itself was always correct). Now reports
  the actual `$CFG_INTERVAL`.

### Changed
- **Overlays completely restyled, with a style chooser.** Replaced the old
  per-line `-undercolor` boxes (ragged, unstyled, clunky) with four polished
  treatments selectable from the web UI ("Overlay style" → `OVERLAY_STYLE`,
  default `scrim`):
  - **scrim** — top/bottom gradient wash + drop-shadowed text, no boxes (default).
  - **frosted** — blurred "glass" rounded card behind each block + hairline
    border; serif-italic quotes.
  - **editorial** — bottom gradient + bold left-aligned text with an accent bar.
  - **chips** — flat translucent rounded panels.
  Text is now rendered via wrapped `caption:` with a soft drop shadow (or a real
  rounded/blurred panel) instead of opaque per-line rectangles. Each style still
  honours the enable toggles, positions, size, text colour (the old "Style"
  dark/light/accent control, relabelled "Text") and font override. Threaded
  through `set-wallpaper.sh`, `gen-status.sh`, `wallpaper-web.py` and the install
  default config.
- **Rotation no longer repeats the last image back-to-back.** The random pick now
  drops the previously-applied original (tracked in `current`) from the candidate
  list before shuffling, so consecutive ticks always change the picture when the
  pool has more than one image. Falls back to the unfiltered shuffle for a
  single-image pool; first run (no `current`) filters nothing.
- **First install now seeds a batch of images** (`SEED_COUNT`, default 15) instead
  of a single one, so random rotation has real variety from the first tick rather
  than repeating one image until cron slowly fills the pool. Each fetch shuffles
  sources so the batch is varied; only runs when the pool is empty (re-installs
  don't re-seed), and stays under the keep-30 prune ceiling.

### Docs
- Corrected the install.sh header and README intro, which still described the
  pool as refilled "from picsum.photos" only — it has been multi-source
  (Wallhaven, Bing, Picsum, local, with fallback) since the sources rework.

### Added (sources, overlays, weather, sparklines)
- **API-sourced quotes with local cache** — `fetch-quotes.sh` refreshes a local
  `quotes.cache` (text|author||) from a quotes API (dummyjson → zenquotes →
  quotable, first that works), cron-refreshed daily; `set-wallpaper.sh` picks a
  random cached quote (so they keep changing), falling back to `fortune`/bundled
  when the cache is empty. Feeds the `+attribution` toggle (author).
- **Local weather overlay** — a third overlay (host/wttr.in, no key), cached ~1h;
  config `OVERLAY_WEATHER` / `WEATHER_POS` / `WEATHER_LOCATION` + web UI toggle,
  position and location field.
- **Backgrounds by theme** — `THEME` config routed to Wallhaven `q=<theme>`
  (read live from config by `fetch-wallpaper.sh`); Bing/Picsum stay as untargeted
  fallback. Web UI background-theme select.
- **Load/RAM sparklines** — `STATS_SPARKLINE` toggle draws unicode block
  sparklines (▁▂▃▄▅▆▇█) beside load/mem from a rolling `metrics.csv` (last 30
  samples; bash/awk, no deps).
- **Fix:** bottom-edge overlays now inset 80px so a quote/stats at the South edge
  clears a desktop panel/taskbar (was hidden behind it). Config values are now
  quoted on write so `WEATHER_LOCATION` with spaces survives shell sourcing.
  Verified in-browser: weather + stats(+sparkline) + API quote(+attribution) +
  themed background all render together on KDE Plasma.

### Docs
- Added `TODO.md` (roadmap): API-sourced quotes w/ local cache, local-weather
  overlay, backgrounds-by-theme, load/RAM sparklines — each with a feasibility note.

### Added (overlay customisation)
- **Quote attribution** — bundled quotes now carry author / source / year; a
  **+attribution** toggle renders e.g. "… — Socrates, Apology (Plato) (~399 BC)".
  (`fortune` still used when attribution is off.)
- **Per-overlay position** — quote and stats can each be placed at any
  corner / edge / centre (`QUOTE_POS` / `STATS_POS` → ImageMagick gravity).
- **Size / theme / font** — text size (small/medium/large → pointsize), theme
  (dark / light / accent → fill + undercolour), and font (any installed
  ImageMagick font from a common set; falls back to default if unavailable).
- New config keys (`OVERLAY_QUOTE_DETAIL`, `QUOTE_POS`, `STATS_POS`,
  `OVERLAY_SIZE`, `OVERLAY_THEME`, `OVERLAY_FONT`); the web UI form gained the
  matching selects/checkboxes (validated server-side). Verified in-browser:
  quote+attribution top-left, stats bottom-right, large accent DejaVu-Serif.

### Added (web UI controls + overlays)
- **Interactive controls in the web UI.** The status page now has a controls form
  (`Apply` → POST `/set`): **rotation interval** (3/5/10/15/30/60 min, rewrites the
  rotate cron line), **quote overlay** toggle, and **system-stats overlay** toggle.
  The static `python3 -m http.server` is replaced by a small `wallpaper-web.py`
  (`BaseHTTPRequestHandler`, 127.0.0.1 only) that serves the page + thumbnail and
  handles the control POST (writes `config`, rewrites crontab, applies immediately,
  regenerates). Config lives at `~/.local/state/wallpaper-rotator/config`.
- **Overlays** (rendered by `set-wallpaper.sh` via ImageMagick onto a *copy* each
  tick, so pool originals stay clean and stats stay live; the derived frame gets a
  unique name so KDE repaints): **quote** (bottom; `fortune` if present, else a
  bundled list) and **system stats** (top-right: host, uptime, load, mem, disk).
  Rotate log gains an `overlay=…` tag.
- **Fixed** a status-page tally bug: `grep -c … || echo 0` printed `0\n0` for
  zero-count rows (e.g. `local 0 0`, `fails 0 0`) — `grep -c` already prints `0` and
  exits non-zero, so the `|| echo 0` doubled it. Capture directly + default instead.
- Rotate interval is now config-driven in the cron template (`*/@@INTERVAL@@`),
  preserved across re-installs. `uninstall.sh` removes the new bins + (on `--purge`)
  the state dir. (All verified live in-browser on KDE Plasma 5.24.7.)
- **Fixed overlay clipping.** Overlays were annotated onto the source image, which
  the DE then crop-fills to the screen — pushing the top-right stats / bottom quote
  off-screen. The overlay frame is now first resized + center-cropped to the screen
  resolution (`set-wallpaper.sh` gains `@@RES@@`), so text lands where it's visible.
- **Apply no longer shuffles the picture.** The control POST re-applied a *random*
  image, so changing an interval/overlay also jumped to a new wallpaper.
  `set-wallpaper.sh` now records the current pool original (`…/current`) and the
  server re-applies *that* on Apply — only overlays/interval change, not the image.
  (Scheduled cron rotations still pick a fresh random image.)

### Added (web UI)
- **Local status web front end.** New `bin/gen-status.sh` builds a self-contained
  status page (current wallpaper thumbnail, pool size/disk, per-source download
  tallies, miss/fail counts, prune totals, recent activity, config) from the
  activity log + pool. `bin/wallpaper-web.sh` (installed as `wallpaper-web`) serves
  it **on demand** via `python3 -m http.server` bound to `127.0.0.1:8787` — no
  always-on process, no network exposure. Cron regenerates the page each tick so it
  stays fresh while the server runs; the page auto-refreshes every 30s. `python3`
  added as a dependency; port configurable via `WEB_PORT` in `install.sh`.

### Added (image sources)
- **Multi-source fetcher with fallback** — new `bin/fetch-wallpaper.sh` replaces the
  single hardcoded picsum download. Pulls from **Wallhaven** (purpose-built wallpapers,
  screen-ratio matched via `atleast=<RES>`, SFW), **Bing** (curated daily images),
  **Picsum** (random floor), and an optional **local folder** (`LOCALDIR`). Each run
  shuffles the enabled sources (variety) and tries them in order until one yields a
  *valid* image — validated as non-trivial + `identify`-decodable, so tiny HTML error
  bodies are rejected (resilience). If all fail, the pool is left unchanged and rotation
  continues. Sources/priority configurable via `SOURCES`/`LOCALDIR` in `install.sh`;
  JSON parsed with `jq` (added as a dependency). Each fetch logs `src=<name> ok|miss` /
  overall `fail`. Cron now calls the fetcher instead of an inline curl.
- *Note:* the `@@...@@` substitution guards in the templated scripts use split string
  literals (`"@@X""@@"`) so `install.sh`'s sed doesn't rewrite the fallback checks
  themselves (an earlier `case *@@X@@*` form broke post-substitution on values with
  spaces and wrongly blanked `LOCALDIR`).

### Added
- **KDE Plasma desktop support.** `set-wallpaper.sh` now sets the desktop on KDE
  Plasma via `plasma-apply-wallpaperimage`, with a `qdbus`
  `org.kde.PlasmaShell.evaluateScript` fallback for older Plasma that lacks it.
  No `feh` needed. Plasma is detected from `XDG_CURRENT_DESKTOP`/`plasmashell`,
  and the cron path reuses the existing session-bus/`DISPLAY` re-establishment.
  `install.sh` adds a soft dependency check (warns if neither
  `plasma-apply-wallpaperimage` nor `qdbus` is present; no package is force-installed,
  as the setter ships with `plasma-workspace`). Support matrix updated.
  `set-wallpaper.sh` also now exports `XDG_RUNTIME_DIR` (derived from the uid) when
  unset and bases the D-Bus session address on it — X11 Plasma works without it,
  but Wayland sessions locate the bus via `XDG_RUNTIME_DIR`, so cron ticks there
  would otherwise fail to reach plasmashell.
  *Verified live on KDE Plasma 5.24.7 + SDDM (X11):* desktop rotates (incl. from a
  stripped cron-like env), login correctly skipped, install idempotent on re-run.

### Fixed
- **KDE wallpaper now actually changes on the live desktop.** The KDE backend
  preferred `plasma-apply-wallpaperimage`, which on Plasma 5.x only updates the
  config file and does **not** repaint the running session — so the cron rotation
  silently changed config and the desktop never visibly updated. The setter now
  **prefers `qdbus … org.kde.PlasmaShell.evaluateScript`** (runs inside plasmashell,
  applies live across all desktop containments and persists config), falling back
  to `plasma-apply-wallpaperimage` only when no `qdbus`/`qdbus6` is present.
  Verified the live flip both interactively and from a stripped cron-like env.

### Added (logging)
- **Activity log** at `${XDG_STATE_HOME:-~/.local/state}/wallpaper-rotator/wallpaper.log`
  (off `/tmp`, so it survives reboots). `set-wallpaper.sh` logs each rotate with the
  detected DE, backend, image, and the backend's **real exit status** (backend stderr
  is appended to the log instead of being discarded). Cron logs download ok/fail and
  prune counts; the login generator logs ok/fail/skip. Self-trimming to the last ~1000
  lines so it can't grow unbounded. README troubleshooting/verify updated to the new path.

### Notes
- Login background remains **LightDM-only**. KDE's default display manager is
  **SDDM**, which is theme-bound and intentionally out of scope — on a KDE+SDDM
  box the desktop rotates but the login screen is skipped.

## Baseline (prior to 2026-06-02)

- Portable, idempotent installer for an auto-rotating **desktop wallpaper**
  (XFCE / GNOME / Cinnamon / MATE, `feh` fallback) and a **LightDM login
  background**, fed by a single image pool that cron refills from picsum.photos.
- Multi-distro dependency install (`apt` / `dnf` / `pacman` / `zypper`) and a
  `curl | bash` bootstrap.
- Detects an actively-running rotator (Variety / Wallch / GNOME slideshow) and
  offers to disable it, else coexists (installs pool + login only).
