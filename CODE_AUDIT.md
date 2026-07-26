# wallpaper-rotator — code audit

Read-only review of the whole codebase (4,139 lines across 9 scripts), triggered by
a UI bug report: *"dragging overlays to new locations looks like it works, then
after a delay they spring back to the original position — sometimes it then works,
but it seems inconsistent."*

**Audit date:** 2026-07-26 · **Host:** Fam3 (4 cores, 8 GB, Zorin/GNOME, 1360×768)
**Scope:** `bin/*.sh`, `bin/wallpaper-web.py`, `install.sh`
**Method:** read the sources, reproduce in a real browser (Claude-in-Chrome), measure
with `time`/`bash -x` traces, and diff old-vs-new behaviour where a fix changed output.

Every measurement below was taken on Fam3 and is reproducible with the commands shown.

---

## The reported bug (root cause)

Three separate defects compounded. Only the third is visible; the first two set the
size of the window in which it can bite.

Reproduction, captured by sampling the DOM every 150 ms while driving a real drag:

| time | event |
|---|---|
| 05:26:03 | drop lands, clock renders in centre — config file written `CLOCK_POS='center'` |
| 05:26:11 | **springs back to northwest** — a poll fetched `/state.json`, still `northwest` (mtime 4 min old) |
| 05:26:47 | `state.json` finally regenerates with `center` |
| 05:27:08 | next poll → snaps back to centre, sticks |

The save always worked. What you watch is the UI overwriting itself with a stale
server snapshot, then eventually agreeing again ~1 minute later.

**1. `gen-status.sh` took 54 s.** The pool listing forked `jq -n` once per pool image
(`bin/gen-status.sh:110`). With 369 images that loop alone measured **48.7 s of the
54 s** — the script was O(pool size) in process spawns.

**2. `regen()` killed it at 30 s** (`bin/wallpaper-web.py:161`). `gen-status` writes
`state.json` atomically at the very end, so a timeout killed it *without refreshing
anything*. At 54 s > 30 s, the poll path could never refresh state on this machine.

**3. The client had no optimistic state.** `setone()` posted and never touched
`S.cfg`; `refresh()` replaced `S` wholesale and `renderObjects()` rebuilt every
overlay from `S.cfg[posKey]`. Any `state.json` arriving before the server caught up
reverted the drop. Nothing guarded against a poll landing mid-drag either — that
deletes and rebuilds the very element under the pointer, leaving `drag.el` detached.

### Result after the fix

| | before | after |
|---|---|---|
| `gen-status.sh` runtime | 54.1 s | **1.9 s** |
| `state.json` lag after a drop | 44 s | ~1 s |
| spring-backs observed | 1 per drag | **0** (5 min / ~15 poll cycles, incl. rapid successive drags) |

The pool-list rewrite was differential-tested against the old implementation across
all 370 real files (50 of them `.ai.jpg`): output is byte-identical, so ordering and
the `ai`/`fav` flags are unchanged.

---

## Findings

Ordered by impact. Severity is about this deployment, not a generic threat model.

### 1. Full wallpaper re-render every 60 seconds — High (performance)

`cron` runs, whenever `OVERLAY_CLOCK=1`:

```
* * * * * ... set-wallpaper.sh "$(cat .../current)"
```

That re-composites the **entire** wallpaper — re-frames the base image
(`set-wallpaper.sh:372`) and rebuilds every overlay from scratch — purely to advance
the clock by one minute.

Measured: **10.4 s wall / 9.3 s user CPU, every minute, permanently.** The log agrees:
`[rotate]` entries at :13 past every minute, same image, six overlays each time.

A `bash -x` trace shows **118 `convert` + 42 `identify` invocations in 9.7 s** — about
60 ms each. There is no single hot spot; the cost is process-spawn count. The bulk is
the pulse block, which renders one or more `convert` calls *per feed line* (up to
`PULSE_MAX`, default 20).

This is also why `gen-status.sh` measured 54 s rather than its own ~2 s baseline: it
was competing with this for CPU. Load average during testing was 21.9 on 4 cores.

**Fix applied:** layer caching at two levels.

- A content-addressed store (`textcache/`) behind `mktext` and `stat_label`. Both are
  pure functions of their arguments, so an unchanged line becomes a file copy instead
  of an ImageMagick spawn. This one change covers the quote caption (the single
  slowest step, 0.54 s), the weather line, every stats row and every pulse feed row.
  Entries are touched on hit and pruned at `-mtime +2`, so it is plain LRU and cannot
  grow without bound as stats/clock text churns.
- A block-level cache (`layers/`) for the finished pulse panel, which also skips the
  per-row append and header composites, and for the forecast strip (~3 spawns per
  forecast day, rebuilt every minute for data that moves every 3 hours).
- The framed base image is memoised on (image, mtime, resolution) — it is the same
  crop-to-fill of the same file on every clock tick.

Deliberately *not* done: reordering the overlay blocks into static/dynamic phases.
`avoid()` (`:416`) appends to `PLACED` and nudges each block clear of the ones already
placed, so **block order determines layout**, not just z-order. Reordering would move
overlays whenever two blocks collide. Caching preserves order and placement exactly —
the cached PNG is composited at the same point, and `bw`/`bh` still come from it.

Stats, the clock and the alert badge stay uncached: they are live by design.

**Measured result: 10.4 s → 3.9 s** on the warm (per-minute) path; `convert` spawns
118 → 61, `identify` 42 → 12.

Verification that the cached path renders the same picture:

- the framed-base cache is pixel-identical to a fresh `convert` (`compare -metric AE`
  = **0**);
- a cold-cache render vs a warm-cache render differs only inside the stats block
  (connected-components bounding boxes all fall in x 44–284, y 339–465, which is where
  `STATS_POS` was during the test) — i.e. only the overlay that is *supposed* to
  change. Everything cached is stable;
- all six overlays still appear in the log line
  (`overlay=stats+quote+weather+clock+pulse+alert`).

The remaining 3.9 s is dominated by layers that must stay live — the analogue clock
face, the stats rows, the alert badge — plus one `style_block` blur-crop per overlay.
Going materially below that needs the batching rewrite listed under *Not changed*.

### 2. `write_config()` is not atomic — Medium (correctness / silent corruption)

`bin/wallpaper-web.py:131` opens the config with `"w"` (truncate) and writes it line
by line. Meanwhile `set-wallpaper.sh` and `gen-status.sh` `. "$CONFIG"` it **every
minute** from cron. A source landing mid-write reads a truncated config: missing
settings silently fall back to defaults, so overlays vanish or positions reset for a
tick, with no error recorded anywhere.

Same class as the reported bug, and `gen-status.sh:196` already does it correctly for
`state.json` (`.tmp` + `mv`).

Related: the server is a `ThreadingHTTPServer` and `/setone` is an unlocked
read-modify-write, so two near-simultaneous saves can lose one. The UI does fire those
— rapid successive drags are exactly that pattern.

**Fix applied:** write to a temp file and `os.replace()` (atomic rename); serialise
the read-modify-write behind a lock.

### 3. No CSRF protection on destructive endpoints — Medium (security)

There is no `Origin`, `Referer` or token check anywhere in the server (verified by
grep). Every POST is a simple form post, so **any website the user visits can fire
them blind** — including `POST /ban`, which deletes the currently-displayed pool image
and needs no knowledge of filenames. Responses aren't readable (no CORS), but the
writes land.

The "localhost trust model, no network exposure" note at `wallpaper-web.py:2-10`
doesn't cover this: the browser is the confused deputy. That comment is also stale —
`WEB_BIND` supports tailnet and arbitrary-IP binds.

**Fix applied:** state-changing POSTs must carry a same-origin `Origin`/`Referer`, or
neither (curl and the install's own calls send no such header). Header comment
corrected. Verified: same-origin POST → 200, `Origin: https://evil.example` → 403,
no-Origin curl → 200, and a real browser drag still saves.

### 4. `/pulse_test` is an unauthenticated SSRF + arbitrary local file read — Medium (security, latent)

`wallpaper-web.py:631` accepts `file://` by design (so a local script can feed the
pulse overlay) with **no path restriction**, and returns the fetched content in the
response body. `PULSE_URL` takes the same validator and persists, making the wallpaper
itself a read-back channel.

On Fam3 this is currently inert: `WEB_BIND=''` and only `127.0.0.1:8787` is listening
(confirmed via `ss -ltnp`), and Paul does not use the GUI remotely. It matters only if
the tailnet bind — a supported, documented mode — is ever switched on, at which point
anyone on the tailnet can read any file the user can read and reach internal HTTP
endpoints.

**Fix applied:** `file://` restricted to `$STATE/feeds` (`feed_url_ok()`), resolved
via `realpath` so `..` and symlink escapes are rejected. `http(s)` is unaffected — the
live `PULSE_URL` and `ALERTS_URL` are both `http://scb-ubuntu:3000/...` and keep
working. Hardening, not a live-incident fix.

### 5. Temp-dir leak — Medium (robustness), confirmed on disk

`_pl.$$` (pulse layers) and `_fc.$$` (forecast) directories are removed only on the
happy path (`set-wallpaper.sh:954`); there is no `trap` in the file. Any early exit
leaks one. **7 orphaned directories were sitting in `~/.local/state/wallpaper-rotator/`
at audit time.**

**Fix applied:** a `trap cleanup_tmp EXIT INT TERM` covering the shared
`$STATEDIR/_<what>.$$` naming, plus a startup sweep of `_*` entries older than 60
minutes (safe under the flock — no other run can be in flight). Orphan count 7 → 0.

### 6. `wallpaper.log` never rotates, and it is in the hot path — Medium (growth)

No rotation exists anywhere in the repo. The 1-minute clock cadence adds ~1,400 lines
a day. `gen-status.sh:56-57` plus the per-source `grep -c` loop perform roughly **six
full-file scans per run**, and `gen-status` runs on every UI poll.

Only 145 KB today, so the cost is small — but it is unbounded growth inside the loop
this audit just optimised.

**Fix applied:** `set-wallpaper.sh` caps the log at `LOG_MAX_LINES` (5,000, trimmed in
batches with 1,000 lines of hysteresis so it is not rewritten every run). That bounds
`gen-status`'s scans automatically, so its greps were left alone — switching them to a
`tail -n` window would have been a *new* bug, because `grep '[rotate]' | tail -1` must
still find the last rotate even when it is older than the window.

Trimming would otherwise have walked the UI's per-source download counters backwards,
since they are derived by grepping this log. So the trim banks the tallies it drops
into `dl-counts`, and `gen-status.sh` adds them back. Verified on a synthetic 8,000-line
log: 300 download lines dropped, totals still exactly 200/100 afterwards, and the bank
accumulates correctly across a second trim (bing 100 → total 140).

### 7. Pulse fetch has no failure fence — Low/Medium (performance under failure)

Weather has a `.fail` 10-minute fence (`set-wallpaper.sh:242`); pulse does not
(`:870`). Because the cache mtime never moves on failure, a dead `PULSE_URL` costs a
6-second `curl` inside **every** render — i.e. every minute.

**Fix applied:** mirrored the weather fence.

### 8. `regen()` can stack — Low (waste)

`ThreadingHTTPServer` with no lock: two concurrent `/state.json` requests that both
see a stale file both spawn `gen-status`. The comment at `:291` says the mtime check
throttles this, but it does not *serialise*. Output is safe (atomic write), just
wasted CPU — and the config-mtime staleness check added for the reported bug slightly
widens the window.

**Fix applied:** a coalescing lock around `regen()`. A waiter reuses the in-flight run
*only* if that run finished after the waiter's own request — otherwise it does its own
pass, since a run that started before the caller's config write would hand back exactly
the pre-write snapshot this audit was chasing.

### 9. Image paths interpolated into shell strings — Low (latent injection)

`wallpaper-web.py:512` and the `/setone` fallback build `bash -c` strings with
single-quoted paths. Pool names are always generated as `<epoch>.<pid>.<ext>`
(`fetch-wallpaper.sh:297`), so this is safe today — but a manually-added
`Paul's photo.jpg` breaks out of the quoting. Apostrophes in filenames are ordinary,
so this is a correctness trap as much as a security one.

**Fix applied:** `shlex.quote()` on every interpolated path.

### 10. `exec 9>lock 2>/dev/null` silences stderr for the whole script — Low (debuggability)

`set-wallpaper.sh:63`. `exec` with redirections and no command applies them
**permanently**, so the `2>/dev/null` intended to hide a failed lock-open discards all
unredirected stderr for the rest of the run. Found while profiling: a `bash -x` trace
died at exactly this line, which is what the flag does to every error message too.

**Fix applied:** scope the suppression to the lock-open only.

---

## Not changed (deliberately)

- **Overlay block ordering.** See finding 1 — `avoid()` makes order significant to
  layout. Any future static/dynamic split has to account for that.
- **The wider auth model.** The server remains unauthenticated on `127.0.0.1`. That is
  the documented trust model and it is sound for a single-user desktop; finding 3 is
  about crossing it via the browser, which is fixed, and finding 4 is about crossing
  it via the network, which is fenced.
- **Rewriting the renderer to batch `convert` calls.** The 60 ms-per-spawn cost is
  inherent to invoking ImageMagick ~160 times. Batching would beat caching, but it
  means restructuring a 1,150-line renderer with no test suite that owns the desktop.
  Caching gets most of the win at a fraction of the risk.

## Reproducing the measurements

```sh
time /usr/local/bin/gen-status.sh                         # finding: pool list
time /usr/local/bin/set-wallpaper.sh "$(cat ~/.local/state/wallpaper-rotator/current)"
PS4='+${EPOCHREALTIME} ' bash -x ./set-wallpaper.sh …     # per-step trace (needs finding 10 fixed)
ls -d ~/.local/state/wallpaper-rotator/_pl.* _fc.*        # finding 5
ss -ltnp | grep 8787                                      # finding 4
```
