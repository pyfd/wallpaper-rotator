# wallpaper-rotator — TODO / roadmap

## Done (2026-06-04, second batch)
- ✅ AI-dreamed wallpapers (AI Horde, anonymous; context-built prompt; optional
  pollinations AI_TOKEN fast path) with UI toggle + style-words field.
- ✅ Pulse overlay: any JSON endpoint (+jq template) -> overlay lines; full-width
  UI section with refresh-interval select, Test/preview button (`/pulse_test`),
  and current-lines view.
- ✅ Auto overlay placement ("auto" in every position select; busyness-ranked,
  cached per image, explicit positions reserved).
- ✅ Remote-access GUI: tailnet toggle (self-restarting bind), URL shown in
  Remote card + footer.
- ✅ Form-drift guard (untouched fields self-sync on soft refresh).

## Done (2026-06-04)
- ✅ Curation buttons (Next / ★ Keep / 🚫 Ban) + favourites gallery in the web UI;
  `favourites/` pool subdir is rotation-included but prune-exempt.
- ✅ Tailnet remote access (`WEB_BIND="tailscale"` config key, dual bind).
- ✅ Multi-theme rotation (checkbox chips; THEME = space-separated list).
- ✅ Analogue clock face styles (classic / minimal / dots / numbers).
- ✅ Smooth AJAX Apply + soft 30s status refresh (no full-page reloads).
- ✅ Two-column wide-screen layout; Recent activity collapsed by default.
- ✅ Forecast day labels resolved at render time (wttr.in pre-rollover lag).
- ✅ Clock date line for the analogue style; Text-colour select de-inverted.

## Done (2026-06-03)
- ✅ Web UI always-on via a systemd user service (`wallpaper-web.service`).
- ✅ Weather icons (DejaVu-safe glyph set) with a UI toggle; location title-cased.
- ✅ Coloured weather icons (condition-mapped colour) with a UI toggle.
- ✅ Weather forecast line (3-day daily outlook from wttr.in j1) with a UI toggle.
- ✅ Quotes no longer Title-Cased (source reorder + conservative de-Title-Case).
- ✅ Overlay collision-avoidance (independent anchors no longer overlap).
- ✅ Overlay panels hug their text (`-trim`), no more dead space.
- ✅ Drawn line+area sparklines (ImageMagick `-draw`) replacing blocky unicode.
- ✅ Fixed font dropdown only ever showing "default" (pipefail + `grep -q` bug).

## Done (2026-06-02)
- ✅ Quotes from an API with local cache (`fetch-quotes.sh`, cron-refreshed).
- ✅ Local weather overlay (wttr.in).
- ✅ Backgrounds by theme (Wallhaven `q=`).
- ✅ Load/RAM sparklines in the stats overlay.

## Open

- [ ] **Option to link the image to the quote** (added 2026-06-04, Paul; design
  discussion in dotfiles CHANGELOG 4 Jun). Make the wallpaper relate to the
  quote being shown. Sketch: (a) **AI-dreamed pairing** — fetch-wallpaper
  pre-draws the NEXT quote from the shuffle-bag, builds the gen prompt from it
  ("an evocative scene inspired by: <quote>"), saves the quote as a sidecar
  (`<img>.ai.jpg.quote`) beside the pool image; set-wallpaper prefers the
  sidecar quote when rendering that image (slots into the existing per-image
  quote cache). (b) **tag-matched sourcing** — map the quote's category tags
  (5th cache field) to a wallhaven search for non-AI mode; much coarser.
  GUI: "match image to quote" toggle in the Quote group, AI-mode first.
  Open questions: gen failures fall back to unlinked pairing; anonymous Horde
  640x384 res cap; whether linked mode replaces or interleaves the normal pool.

## Ideas / later
- Weather: hourly (next-few-slots) forecast variant; the 3-day daily forecast line
  and the icon set are now done.
- Theme: per-source theming for Bing/Unsplash; multiple themes rotating.
- Sparklines: longer history window (the drawn `-draw` graph itself is now done).
- Quote sources: allow a user-supplied quotes file; category/tag filtering.
