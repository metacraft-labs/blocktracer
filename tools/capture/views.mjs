// The named view list, the viewport set, the theme axis and the determinism
// canary — VD.0's single source of truth for "what gets captured".
//
// Every entry in `VIEWS` must map onto the surface inventory in
// `spec-inventory.mjs` via `covers:`, and every inventory entry must be
// covered by at least one view. `check-coverage.mjs` enforces both directions.
//
// ── status: ready | pending ────────────────────────────────────────────────
//
// The view list is deliberately COMPLETE with respect to Page-Descriptions,
// while the client currently renders five route types. A view whose route the
// client does not yet serve is `status: "pending"` with a `pendingReason`. It
// is listed, counted, and reported as an unmet capture — never silently
// dropped, and never captured against a 404 that would be mistaken for a
// styled page. When the route lands, flipping `status` is the whole change.

import { headBlock, nthBlock, nthTx, firstAddress } from "./lib/entities.mjs";

// ── Viewport set ───────────────────────────────────────────────────────────
// Four sizes. deviceScaleFactor is pinned to 1 everywhere: a 2x capture is a
// different rasterisation path and would make the tier-1 hash depend on which
// machine's default DPR won.

export const SIZES = {
  wide: { width: 1920, height: 1080, deviceScaleFactor: 1 },
  laptop: { width: 1440, height: 900, deviceScaleFactor: 1 },
  tablet: { width: 1024, height: 768, deviceScaleFactor: 1 },
  mobile: { width: 375, height: 812, deviceScaleFactor: 1 },
};

export const ALL_SIZES = Object.keys(SIZES);

/** The debugger is desktop-first (Page-Descriptions §13); its panes are judged
 *  at wide and laptop (VD.5), and its narrow presentation is its own view. */
export const DESKTOP_SIZES = ["wide", "laptop"];
export const NARROW_SIZES = ["tablet", "mobile"];

// ── Theme axis ─────────────────────────────────────────────────────────────
// Light and dark are captured independently — separate contexts, separate
// files, no inheritance. The capture sets BOTH signals a page could use:
// the `prefers-color-scheme` media query (Playwright's colorScheme) and an
// explicit `data-theme` attribute on <html>, because Page-Descriptions §13
// specifies "dark and light via prefers-color-scheme WITH a toggle".

export const THEMES = ["light", "dark"];

// ── Frozen clock ───────────────────────────────────────────────────────────
// A fixed instant, in UTC, installed before the first navigation. Anything
// that reads the wall clock — relative ages, "x minutes ago", a ticking head,
// a timestamp in a footer — resolves to the same value on every run.

export const FROZEN_TIME = new Date("2026-01-15T12:00:00.000Z");

// The seeded value handed to Math.random inside the page, so any incidental
// randomness (ids, placeholder shuffles) is reproducible too.
export const RANDOM_SEED = 0x5eed_10ce;

// ── Debugger time coordinate ───────────────────────────────────────────────
// VD.0: "capture of the debugger at a fixed time coordinate so panes hold
// identical content between runs". Every debugger view pins `?t=` explicitly
// rather than capturing wherever the session happens to open — an unpinned
// debugger capture is non-deterministic by construction, because the panes
// show whatever step the loader landed on.
//
// `?t=` is a step identity inside the trace container (Debugger-Integration
// §6.2), so the value below has to come from the pinned demo trace fixture.
// It is a PLACEHOLDER until the /debug route exists; the mechanism (a single
// constant, referenced by every debugger view) is what VD.0 delivers.
export const DEBUG_TIME_COORDINATE = "1";

// A second, deeper coordinate, for the views that must show a loaded session
// mid-trace rather than at its first step.
export const DEBUG_TIME_COORDINATE_MID = "128";

const debugRoute = (txSel, { t = DEBUG_TIME_COORDINATE, extra = "" } = {}) => (ix) => {
  const tx = txSel(ix);
  return `/${ix.primaryChain}/tx/${tx.hash}/debug?t=${t}${extra}`;
};

const PENDING_ROUTE = "route not yet served by the client";
const PENDING_STATE = "state not yet modelled by the client ViewModel";

// ── The named view list ────────────────────────────────────────────────────

export const VIEWS = [
  // ─────────────────────────── Explorer register ──────────────────────────
  {
    id: "home",
    description: "Home — hero, search field, chain strip, how-it-works, trust strip",
    covers: ["home"],
    register: "explorer",
    status: "ready",
    route: () => "/",
  },
  {
    id: "home--live-demo",
    description: "Home — the embedded pre-baked debugging session, reviewed as its own view (VD.3)",
    covers: ["home.live-demo"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: the embedded live demo is not built yet`,
    route: () => "/",
    clip: "#live-demo",
  },
  {
    id: "chains-index",
    description: "Chains index — capability inventory table with debug-tier badges",
    covers: ["chains-index"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /chains is not rendered by static_export`,
    route: () => "/chains",
  },
  {
    id: "chain-overview",
    description: "Chain overview — header, head, latest blocks, latest transactions, chain notes",
    covers: ["chain-overview"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${ix.primaryChain}`,
  },
  {
    id: "chain-overview--stale",
    description: "Chain overview with the staleness notice — pipeline behind the chain tip",
    covers: ["degraded.pipeline-behind"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: no staleness notice in the chain view`,
    route: (ix) => `/${ix.primaryChain}`,
  },
  {
    id: "blocks-list",
    description: "Block list — height, hash, age, tx count, resource bar, producer, finality",
    covers: ["blocks-list"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${ix.primaryChain}/blocks`,
  },
  {
    id: "blocks-list--row-expanded",
    description: "Block list with a row expanded to its transaction hashes and per-row Debug actions",
    covers: ["blocks-list.row-expanded"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: row expansion is not implemented`,
    route: (ix) => `/${ix.primaryChain}/blocks`,
  },
  {
    id: "block-detail",
    description: "Block detail — header zone, family extras, transactions table, prev/next navigation",
    covers: ["block-detail"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${ix.primaryChain}/block/${headBlock(ix).hash}`,
  },
  {
    id: "block-detail--genesis-edge",
    description: "Block detail at the oldest published block — prev/next disabled state",
    covers: ["block-detail"],
    register: "explorer",
    status: "ready",
    route: (ix) => {
      const bs = ix.chain().blocks;
      return `/${ix.primaryChain}/block/${bs[bs.length - 1].hash}`;
    },
  },
  {
    id: "txs-list",
    description: "Recent transactions — the shared TransactionsTable, Debug first column",
    covers: ["txs-list"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /{chain}/txs is not rendered by static_export`,
    route: (ix) => `/${ix.primaryChain}/txs`,
  },
  {
    id: "txs-list--cards",
    description: "Transactions table collapsed to stacked cards below 900px, Debug and status retained",
    covers: ["txs-list.cards"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /{chain}/txs is not rendered by static_export`,
    sizes: NARROW_SIZES,
    route: (ix) => `/${ix.primaryChain}/txs`,
  },
  {
    id: "tx-detail",
    description: "Transaction detail — hero, overview grid, decoded input, events, calls, state, raw",
    covers: ["tx-detail"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}`,
  },
  {
    id: "tx-detail--dense",
    description: "Transaction detail at the largest published payload — the density case",
    covers: ["tx-detail"],
    register: "explorer",
    status: "ready",
    route: (ix) => {
      const txs = ix.chain().txs;
      return `/${ix.primaryChain}/tx/${txs[txs.length - 1].hash}`;
    },
  },
  {
    id: "tx-detail--hydrated",
    description: "Transaction detail after the debugger hydrates over it in place (§7.0, trace ready)",
    covers: ["tx-detail.hydrated"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_STATE}: hydration is not implemented`,
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}`,
  },
  {
    id: "tx-detail--decoded-input",
    description: "Decoded input section — function/entry point and ABI-decoded parameters",
    covers: ["tx-detail.decoded-input"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the section renders a placeholder, not decoded parameters`,
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}`,
    clip: "#decoded-input",
  },
  {
    id: "tx-detail--events",
    description: "Events/logs section at realistic volume, each row linking into the debugger",
    covers: ["tx-detail.events"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the events section is not populated`,
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}`,
    clip: "#events",
  },
  {
    id: "tx-detail--internal-calls",
    description: "Internal calls — the call tree from the trace",
    covers: ["tx-detail.internal-calls"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the internal-calls section is not populated`,
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}`,
    clip: "#internal-calls",
  },
  {
    id: "tx-detail--state-changes",
    description: "State changes — before → after diffs decoded to declared types",
    covers: ["tx-detail.state-changes"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the state-changes section is not populated`,
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}`,
    clip: "#state-changes",
  },
  {
    id: "tx-detail--raw",
    description: "Raw section — chain-native transaction and receipt JSON, verbatim",
    covers: ["tx-detail.raw"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the raw section is not rendered`,
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}`,
    clip: "#raw",
  },
  {
    id: "address",
    description: "Address / account — header, code summary, transactions with Debug on every row, events",
    covers: ["address"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${ix.primaryChain}/address/${firstAddress(ix)}`,
  },
  {
    id: "contract-source",
    description: "Verified source browser — verification, file tree, ABI, storage layout, deployments",
    covers: ["contract-source"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /{chain}/address/{address}/code is not rendered`,
    route: (ix) => `/${ix.primaryChain}/address/${firstAddress(ix)}/code`,
  },
  {
    id: "contract-source--unverified",
    description: "No verified source — instruction-level stepping with supply-sources prominent",
    covers: ["degraded.no-verified-source"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: the code route is not rendered`,
    route: (ix) => `/${ix.primaryChain}/address/${firstAddress(ix)}/code`,
  },
  {
    id: "search",
    description: "Search resolution — the unambiguous single-candidate presentation",
    covers: ["search"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /search is not rendered (M14 Search And Routing)`,
    route: () => "/search?q=0x27a6c250bda5f426cac12790abe9cff80fb29a6c",
  },
  {
    id: "search--ambiguous",
    description: "Search — grouped, keyboard-navigable candidates across kinds",
    covers: ["search.ambiguous"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /search is not rendered (M14)`,
    route: () => "/search?q=0x27a6",
  },
  {
    id: "search--cross-chain",
    description: "Search — active chain's results first, 'found on other chains' below",
    covers: ["search.cross-chain"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /search is not rendered (M14)`,
    route: () => "/search?q=0x27a6&scope=all",
  },
  {
    id: "search--not-found",
    description: "Search — what was tried and where, so a miss reads as a scoping answer",
    covers: ["search.not-found"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /search is not rendered (M14)`,
    route: () => "/search?q=0xdeadbeef",
  },
  {
    id: "settings",
    description: "Settings — storage, debugger, privacy and advanced groups",
    covers: ["settings"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /settings is not rendered`,
    route: () => "/settings",
  },
  {
    id: "static-content",
    description: "Static content — /about, the privacy summary the trust strip links to",
    covers: ["static-content"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /about and /docs/* are not rendered`,
    route: () => "/about",
  },
  {
    id: "not-found",
    description: "Object not found — 'not on this chain', naming the chains checked",
    covers: ["degraded.not-found"],
    register: "explorer",
    status: "pending",
    pendingReason:
      "static_export writes only the 200 routes: renderRoute() has a 404 body but no 404.html is emitted, so a capture here would photograph the dev server's fallback, not the product",
    route: (ix) => `/${ix.primaryChain}/tx/0x0000000000000000000000000000000000000000`,
    expectHttpStatus: 404,
  },

  // ─────────────────────────── Debugger register ──────────────────────────
  {
    id: "debugger",
    description: "Full-viewport debugging session at the pinned time coordinate, slim explorer bar",
    covers: ["debugger"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /{chain}/tx/{hash}/debug is not rendered`,
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0)),
  },
  {
    id: "debugger--metadata-pane",
    description: "The transaction metadata pane inside the session (§7.1)",
    covers: ["debugger.metadata-pane"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0), { extra: "&pane=metadata" }),
  },
  {
    id: "debugger--call-trace",
    description: "Call trace at realistic depth and width, including the cost column",
    covers: ["debugger.call-trace"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0), { t: DEBUG_TIME_COORDINATE_MID, extra: "&pane=calltrace" }),
  },
  {
    id: "debugger--event-log",
    description: "Event log with mixed calls, storage writes, events and a revert",
    covers: ["debugger.event-log"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0), { t: DEBUG_TIME_COORDINATE_MID, extra: "&pane=eventlog" }),
  },
  {
    id: "debugger--state-pane",
    description: "State pane with deeply nested values and long identifiers",
    covers: ["debugger.state-pane"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0), { t: DEBUG_TIME_COORDINATE_MID, extra: "&pane=state" }),
  },
  {
    id: "debugger--source-pane",
    description: "Source pane, source-level session with the level boundary legible",
    covers: ["debugger.source-pane"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0), { t: DEBUG_TIME_COORDINATE_MID, extra: "&pane=source" }),
  },
  {
    id: "debugger--loading-phases",
    description: "Phased, honest loading — fetching, opening, positioning; never a spinner",
    covers: ["debugger.loading-phases"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0), { extra: "&phase=opening" }),
  },
  {
    id: "debugger--narrow",
    description: "Reduced read-only narrow session — source + call trace + values, limitation stated",
    covers: ["debugger.narrow"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    sizes: NARROW_SIZES,
    fullPage: false,
    route: debugRoute(nthTx(0)),
  },
  {
    id: "debugger--truncated",
    description: "Trace-truncated banner, with the option to request a deeper profile",
    covers: ["degraded.trace-truncated"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    fullPage: false,
    route: debugRoute(nthTx(0), { extra: "&state=truncated" }),
  },
  {
    id: "debugger--divergent",
    description: "Non-dismissible divergence banner above the debugger, naming the mismatch",
    covers: ["degraded.divergence"],
    register: "debugger",
    status: "pending",
    pendingReason: `${PENDING_ROUTE}: /debug is not rendered`,
    fullPage: false,
    route: debugRoute(nthTx(0), { extra: "&state=divergent" }),
  },

  // ─────────────────── Degraded states on the transaction page ────────────
  ...[
    ["degraded.trace-awaiting-generation", "trace-awaiting", "Trace awaiting generation — the job, with observable phases"],
    ["degraded.job.accepted", "job-accepted", "Generation accepted — quota consumed, cancellable"],
    ["degraded.job.queued", "job-queued", "Generation queued — queue position shown, cancellable"],
    ["degraded.job.recording", "job-recording", "Recording — phase and elapsed time, not cancellable"],
    ["degraded.job.validating", "job-validating", "Validating the recorder's own output"],
    ["degraded.job.publishing", "job-publishing", "Publishing the artifact"],
    ["degraded.job.refused", "job-refused", "Refused — will not be attempted, with the reason; no retry"],
    ["degraded.job.failed", "job-failed", "Failed — retry offered only when the pipeline says retryable"],
    ["degraded.job.timed-out", "job-timed-out", "Timed out — exceeded the job budget"],
    ["degraded.replay-window-expired", "replay-expired", "Replay window expired — transaction intact, Renew behind sign-in"],
    ["degraded.replay.windowed-live", "replay-windowed", "Windowed but live — debugger opens immediately, retention stated"],
    ["degraded.replay.never-generated", "replay-never", "Never generated on an on-demand chain — Generate behind sign-in"],
    ["degraded.permanently-unreplayable", "unreplayable", "Permanently unreplayable — terminal, with the reason, no retry"],
    ["degraded.recorder-unavailable", "recorder-unavailable", "Recorder unavailable for the VM — Debug absent, recorder status linked"],
    ["degraded.below-history-floor", "below-history-floor", "Below the history floor — Debug absent, floor stated"],
    ["degraded.reorganised", "reorganised", "Reorganised away — reorg explanation and the new location"],
    ["degraded.quota-exhausted", "quota-exhausted", "Quota exhausted — distinct from not-signed-in, says when it resets"],
    ["degraded.sign-in-required", "sign-in-required", "Sign-in prompt on the on-demand path, stating what it is for"],
    ["degraded.browser-cannot-debug", "browser-cannot-debug", "Browser cannot run the debugger — entry into the capability ladder"],
    ["degraded.ladder.download-trace", "ladder-download", "Ladder step 1 — offer the trace download"],
    ["degraded.ladder.open-in-desktop", "ladder-desktop", "Ladder step 2 — open in CodeTracer desktop"],
    ["degraded.ladder.static-summary", "ladder-summary", "Ladder floor — static call and event summary, a useful page not an apology"],
  ].map(([covers, slug, description]) => ({
    id: `tx-detail--${slug}`,
    description,
    covers: [covers],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the TraceSelection availability enum is not surfaced in the view`,
    route: (ix) => `/${ix.primaryChain}/tx/${nthTx(0)(ix).hash}?state=${slug}`,
  })),

  {
    id: "shell--cdn-unreachable",
    description: "CDN unreachable — the service worker serves the shell and anything previously viewed",
    covers: ["degraded.cdn-unreachable"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: no service worker is registered yet`,
    route: () => "/",
    offline: true,
  },
];

// ── Determinism canary (tier 1) ────────────────────────────────────────────
//
// Deliberately a handful of {view, size, theme} triples, NOT the full corpus.
// Its job is to answer "is the capture harness still deterministic?", and it
// is scoped to the distinct rendering paths named in the methodology:
// dense text, a data table, a chart, one dark-theme view — plus a narrow
// reflow, because layout at 375px exercises a different path again.
//
// Exact comparison over hundreds of images eventually flakes somewhere, and
// the response to a flaky mandatory gate is always to switch it off. So this
// stays small, and its failure invalidates the tier-2 baselines rather than
// being ratcheted away.

export const CANARY = [
  {
    view: "home",
    size: "wide",
    theme: "light",
    renderingPath: "prose + hero typography — the brand type path",
  },
  {
    view: "blocks-list",
    size: "wide",
    theme: "light",
    renderingPath: "data table — many rows, aligned numeric columns",
  },
  {
    view: "tx-detail--dense",
    size: "laptop",
    theme: "light",
    renderingPath: "dense monospace text — hashes, addresses, decoded values",
  },
  {
    view: "chain-overview",
    size: "wide",
    theme: "dark",
    renderingPath: "the dark-theme view",
  },
  {
    view: "block-detail",
    size: "mobile",
    theme: "light",
    renderingPath: "narrow reflow — 375px layout and long-identifier handling",
  },
  {
    // The chart/graph rendering path. Page-Descriptions §5.1 specifies a
    // per-block resource bar; the client renders a placeholder line instead
    // (client/src/pages/blocklist.nim). Kept in the canary and reported as an
    // uncovered rendering path rather than dropped, so the gap stays visible.
    view: "chain-overview--stale",
    size: "wide",
    theme: "light",
    renderingPath: "chart / graph — per-block resource bars",
  },
];

// ── Lookups ────────────────────────────────────────────────────────────────

export const VIEWS_BY_ID = new Map(VIEWS.map((v) => [v.id, v]));

export function sizesFor(view) {
  return view.sizes ?? ALL_SIZES;
}

export function themesFor(view) {
  return view.themes ?? THEMES;
}

/** `<view>__<size>__<theme>.png` — the only place the filename shape is defined. */
export function imageName(viewId, size, theme) {
  return `${viewId}__${size}__${theme}.png`;
}

const NAME_RE = /^(.+)__([^_]+)__([^_]+)\.png$/;

export function parseImageName(filename) {
  const m = NAME_RE.exec(filename);
  if (!m) return null;
  return { viewId: m[1], size: m[2], theme: m[3] };
}

/** Every {view, size, theme} the full corpus contains. */
export function expandedTargets(views = VIEWS) {
  const out = [];
  for (const view of views) {
    for (const size of sizesFor(view)) {
      for (const theme of themesFor(view)) {
        out.push({ view, size, theme, file: imageName(view.id, size, theme) });
      }
    }
  }
  return out;
}
