/* ───────────────────────────────────────────────────────────────────────────
 * VENDORED COPY — do not edit below the sentinel.
 *
 * Source : workshop-service  infra/_shared/usage-beacon.js
 * Taken  : commit a8dd43c722ce8b4cce5e9976c19979f2f7e32711 (2026-11-07)
 *
 * WHY A COPY (#1815). The web UI serves its own page from this machine's
 * 127.0.0.1:8787, with no shared server behind it, and posts its rows to its
 * own /seen (named on the tag with data-endpoint). The house pattern is one
 * beacon everywhere, not a rewrite per app. wallpaper-web.py adds the tags to
 * every HTML response (one place), so a new page can't ship without them.
 *
 * THE COST IS DRIFT, MADE VISIBLE: tests/test_usage.py diffs everything below
 * the sentinel against the upstream file byte-for-byte, and fails loudly
 * rather than passing quietly when the upstream repo isn't cloned beside this
 * one (WR_NO_UPSTREAM=1 to run the other tests without it).
 *
 * To re-vendor: scripts/vendor-usage-beacon.sh
 * ─────────────────────────────────────────────────────────────────────────── */
/* ─── UPSTREAM COPY BEGINS ─── */
/**
 * /reports usage beacon (#625) — the client half.
 *
 * Injected into every HTML page under /reports by services/reportsUsage.js
 * (injector), so no dashboard has to remember to include it and the
 * deploy-excluded data/ copies get it too.
 *
 * WHY A CLIENT HALF EXISTS AT ALL. A server middleware counts requests, and a
 * request is not a read. At least eight dashboards here self-refresh on a 60s
 * setInterval, so one tab left open in a background window generates ~1,440
 * requests a day while nobody looks at it. Only the browser knows whether the
 * page was on screen and somebody was active on it. btn-beryl hit exactly this (a 30s
 * /dashboard poll with no document.hidden check) and fixed it before building
 * anything else; this is that cure, ported.
 *
 * WHAT IT MEASURES
 *   focus_ms  milliseconds the page was visible and not idle. Time stops when
 *             the tab is backgrounded or the window minimised, and again after
 *             IDLE_MS with no mouse, key or scroll activity.
 *   actions   clicks and control changes, counted per control so the dashboard
 *             can tell "operated" from "stared at". Labels are structural
 *             (tag + data-usage / id / class), never typed text or values —
 *             nothing a person entered leaves the page.
 *
 * WHY NOT document.hasFocus(). The first cut gated on visibility AND focus, and
 * that is too strict in the direction that matters: a dashboard open on a second
 * monitor while you work in another app is visible, unfocused, and genuinely
 * being read — it would have recorded zero. Under-counting reads the same as an
 * unused dashboard, which is the exact wrong conclusion this whole feature
 * exists to prevent. btn-beryl gates on visibilityState, and the real problem it
 * was solving is a BACKGROUNDED poller, which visibilityState already catches.
 * The idle cut-off below covers the remaining gap — a visible tab nobody is
 * touching — without punishing the second-monitor case.
 *
 * WHAT IT SENDS. One cumulative row per (session, page), re-sent on every hide,
 * on pagehide, and on a slow heartbeat. The server takes MAX(), so duplicates
 * and out-of-order delivery are harmless by design and a crashed tab still
 * leaves its last heartbeat behind.
 *
 * PRIVACY / FOOTPRINT. No cookie, no localStorage, no identifier that survives
 * the tab: the session id is a fresh random string per page load and exists only
 * to stitch heartbeats together. Server-side the row carries the tailnet IP and
 * user-agent, which is what makes the table personal data and why it is pruned
 * at 365 days.
 */
(function () {
  'use strict';
  if (window.__reportsUsageBeacon) return;
  window.__reportsUsageBeacon = true;

  // ANOTHER APP'S OWN STORE (#1670, 21 Oct 2026). A site that keeps its own
  // usage table (Song Journey, a Flask app on its own box) names its endpoint on
  // the tag: <script src="…usage-beacon.js" data-usage-beacon data-endpoint="/api/x">.
  // No attribute = /reports, as before. Read here, while currentScript is set.
  var ENDPOINT = (function () {
    try {
      var s = document.currentScript;
      var ep = s && s.getAttribute('data-endpoint');
      if (ep && ep.charAt(0) === '/') return ep;
    } catch (e) { /* older browser */ }
    return '/api/reports-usage';
  })();
  // A HASH-ROUTED PAGE (#1815, 7 Nov 2026). Song Journey's /music draws its tabs from location.hash (#/library,
  // #/analysis/mixes, …), so pathname + search read every tab as one page. The tag opts in:
  // data-hash-routes="2" keeps the hash's first 2 route segments in the recorded path (#/analysis/mixes/<id>/T4 →
  // #/analysis/mixes, so a mix's id or a transition index is not a page of its own); a bare data-hash-routes keeps
  // the whole route. A plain #anchor (no "/" after the #) is never a route. No attribute = the hash ignored, as before.
  var HASH_DEPTH = (function () {
    try {
      var s = document.currentScript;
      var v = s && s.getAttribute('data-hash-routes');
      if (v === null || v === undefined) return 0;
      var n = parseInt(v, 10);
      return n > 0 ? n : Infinity;
    } catch (e) { return 0; }   // older browser: as before
  })();
  var HEARTBEAT_MS = 120000;     // long: most reads end in a hide/pagehide
  var MIN_SEND_MS = 1000;        // below this a "visit" is a bounce, not a read
  // Long enough to read a dense dashboard without touching anything, short
  // enough that a tab left open all afternoon does not bank the afternoon.
  var IDLE_MS = 300000;          // 5 min of no mouse/key/scroll = not reading

  function newId() {
    try {
      if (window.crypto && window.crypto.randomUUID) return window.crypto.randomUUID();
    } catch (e) { /* older browser */ }
    return 'u' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
  }
  var session = newId();
  // TDR 11w.13 (3): a page that logs its own rows (HELM's surface_log) stamps this id on them, so its rows and this
  // page load's reports_usage row join exactly; before, the two loggers shared no key. Read-only, per load as above.
  window.__usageSession = session;

  // WHO (#632 D11, 16 Oct 2026). Claude-in-Chrome drives Paul's own Chrome, so its
  // tabs look exactly like his: same browser, same IP, and a cic test loop DOES
  // dwell and click every control. On HELM's first 12 sessions about half were
  // Claude's. A tab Claude opens carries `by=claude` in the first URL it loads
  // (~/cldev/claude/hooks/cic-batch-guard.py adds it); the mark is kept in
  // sessionStorage, so it holds for every later page in that tab and never
  // reaches a tab Paul opened. The param is left out of the recorded path.
  var by = (function () {
    try {
      if (/(?:^|[?&])by=claude(?:&|$)/.test(location.search)) sessionStorage.setItem('usage.by', 'claude');
      return sessionStorage.getItem('usage.by') === 'claude' ? 'claude' : null;
    } catch (e) { return null; }   // storage blocked: unmarked, as before
  })();
  function here() {
    var search = (location.search || '').replace(/([?&])by=claude(&|$)/, function (m, a, b) { return b ? a : ''; });
    return location.pathname + search + hashRoute();
  }
  function hashRoute() {
    if (!HASH_DEPTH) return '';
    var m = /^#\/([^?]*)/.exec(location.hash || '');
    if (!m) return '';
    var segs = m[1].split('/').filter(Boolean).slice(0, HASH_DEPTH);
    return segs.length ? '#/' + segs.join('/') : '';
  }
  var path = here();
  var routed = false;             // true once navigate() has moved this row on from the page load
  var focusMs = 0;
  var since = null;               // ms timestamp when the current focused span began
  var actions = 0;
  var byControl = Object.create(null);
  var lastSent = -1;

  var lastActivity = Date.now();

  function idle() { return Date.now() - lastActivity > IDLE_MS; }
  function reading() { return document.visibilityState === 'visible' && !idle(); }

  function startSpan() { if (since === null && reading()) since = Date.now(); }

  /**
   * Close the open span, banking only the time that was really reading.
   *
   * The cut-off is applied HERE, in the one place a span can close, rather than
   * in the callers. The first cut had a plain stopSpan() that banked
   * now - since and a separate capping pass that ran after it — so the
   * uncapped value was already committed by the time anything checked, and a
   * tab left open all afternoon banked the whole afternoon. One function, no
   * ordering to get wrong.
   */
  function closeSpan() {
    if (since === null) return;
    // If we went idle, the reading stopped at the cut-off, not now.
    var until = idle() ? Math.min(Date.now(), lastActivity + IDLE_MS) : Date.now();
    focusMs += Math.max(0, until - since);
    since = null;
  }

  function currentMs() {
    if (since !== null && !reading()) closeSpan();   // hidden or idle: settle up
    return focusMs + (since === null ? 0 : Date.now() - since);
  }

  function activity() {
    var wasIdle = idle();
    // Close BEFORE moving lastActivity, or the cut-off is computed against the
    // new timestamp and the idle gap gets banked after all.
    if (wasIdle) closeSpan();
    lastActivity = Date.now();
    if (wasIdle) startSpan();
  }

  /**
   * A stable, content-free label for whatever was interacted with.
   * data-usage wins so a dashboard can name its own controls; otherwise the
   * structural fallback keeps working on the ~78 pages that will never be
   * tagged. Deliberately never reads value/textContent — a filter box would
   * otherwise ship what was typed into it.
   */
  function labelFor(el) {
    var node, i;
    // TWO PASSES, and the order matters. A single pass that returned at the
    // first match gave "button" for the range selector on this very dashboard:
    // the <button> has no id and no class, so it produced the weakest possible
    // label while its parent carried data-usage="range" one level up. A control
    // label nobody can act on is the same as no label. Measured 2026-09-19 —
    // the first real click recorded came back as {"button":1}.
    for (node = el, i = 0; node && i < 4; i++, node = node.parentElement) {
      if (node.nodeType !== 1 || !node.getAttribute) continue;
      var tagged = node.getAttribute('data-usage');
      if (tagged) return String(tagged).slice(0, 60);
    }
    for (node = el, i = 0; node && i < 4; i++, node = node.parentElement) {
      if (node.nodeType !== 1) continue;
      var tag = (node.tagName || '').toLowerCase();
      if (tag === 'button' || tag === 'select' || tag === 'a' || tag === 'input' || tag === 'summary') {
        var id = node.id ? '#' + node.id : '';
        var cls = '';
        if (!id && node.className && typeof node.className === 'string') {
          cls = '.' + node.className.trim().split(/\s+/)[0];
        }
        // A bare tag with nothing to distinguish it is not worth a row.
        return id || cls ? (tag + (id || cls)).slice(0, 60) : null;
      }
    }
    return null;
  }

  function note(el) {
    var label = labelFor(el);
    if (!label) return;
    actions++;
    byControl[label] = (byControl[label] || 0) + 1;
  }

  /**
   * Use that is not a click or a change (#1683, 22 Oct 2026): a keyboard
   * shortcut, a search box used. The page names it the way data-usage names a
   * control, so it counts in the same per-control tally. Same rule as
   * labelFor: a structural name the page chose, never typed text.
   */
  window.__usageNote = function (label) {
    if (!label) return;
    activity();
    actions++;
    label = String(label).slice(0, 60);
    byControl[label] = (byControl[label] || 0) + 1;
  };

  /**
   * How long the page took to be usable, in ms from navigation start. A page
   * whose content arrives by fetch() after the HTML sets window.__reportsLoadMs
   * when its data is on screen (the todo dashboard does) — the browser's own
   * load event fires long before that and would call a 16s page fast. Other
   * pages fall back to loadEventEnd. null until there is a figure; the server
   * keeps the first one it gets for the session.
   */
  function loadMs() {
    var v = window.__reportsLoadMs;
    if (typeof v === 'number' && v > 0) return Math.round(v);
    // Such a page sets __reportsLoadPending up front, so a beacon fired while it
    // is still loading (tab hidden at 3s) sends nothing rather than the early
    // load event — which, being first, would otherwise stand.
    if (window.__reportsLoadPending) return null;
    // A row navigate() started was not a page load: the navigation entry is the
    // first page's, and would stand as this one's.
    if (routed) return null;
    try {
      var nav = performance.getEntriesByType('navigation')[0];
      if (nav && nav.loadEventEnd > 0) return Math.round(nav.loadEventEnd);
    } catch (e) { /* older browser */ }
    return null;
  }

  function send(useBeacon) {
    var ms = currentMs();
    // Nothing new to say. The server would MAX() it to the same value anyway;
    // skipping saves a request per background heartbeat.
    if (ms < MIN_SEND_MS || ms === lastSent) return;
    lastSent = ms;
    var payload = JSON.stringify({
      rows: [{
        kind: 'view',
        page: null,                       // server derives it from path
        path: path,
        session: session,
        focus_ms: Math.round(ms),
        actions: actions,
        detail: actions ? byControl : null,
        load_ms: loadMs(),
        actor: by || undefined,           // 'claude' on a cic tab; absent = the server's 'human'
      }],
    });
    try {
      if (useBeacon && navigator.sendBeacon) {
        navigator.sendBeacon(ENDPOINT, new Blob([payload], { type: 'application/json' }));
        return;
      }
      fetch(ENDPOINT, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: payload,
        keepalive: true,
      }).catch(function () { /* best effort, always */ });
    } catch (e) { /* best effort, always */ }
  }

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'visible') { activity(); startSpan(); }
    else { closeSpan(); send(true); }
  });
  // pagehide, not unload: unload is unreliable in modern browsers and is skipped
  // entirely when the page goes into the back/forward cache.
  window.addEventListener('pagehide', function () { closeSpan(); send(true); });

  ['mousemove', 'keydown', 'scroll', 'pointerdown', 'wheel'].forEach(function (ev) {
    window.addEventListener(ev, activity, { passive: true, capture: true });
  });

  document.addEventListener('click', function (e) { activity(); note(e.target); }, true);
  document.addEventListener('change', function (e) { activity(); note(e.target); }, true);

  setInterval(function () { if (reading()) send(false); }, HEARTBEAT_MS);

  /**
   * A single-page app's route change (#1670, 21 Oct 2026). Song Journey moves
   * between its home, a journey and the gallery with history.pushState, so the
   * page load above is only the first of several pages a tab shows, and every
   * later one would bank its time on the first path. The app calls this after
   * it has changed the URL: the current row is settled and sent, and a fresh
   * one starts for the new path under a new id (a return visit to a path is
   * its own row, never a MAX() against the earlier one). The click that made
   * the move is already counted on the page it was made on: the click listener
   * above runs in the capture phase, before the app's own handler.
   *
   * Opt-in: nothing here watches history, because /reports pages rewrite their
   * query string on every filter change and that is not a new page. Same URL =
   * nothing to do (a re-render).
   */
  window.__usageBeaconNavigate = function () {
    var next = here();
    if (next === path) return;
    closeSpan();
    send(true);
    session = newId();
    path = next;
    routed = true;
    focusMs = 0;
    actions = 0;
    byControl = Object.create(null);
    lastSent = -1;
    activity();
    startSpan();
  };

  startSpan();
})();
