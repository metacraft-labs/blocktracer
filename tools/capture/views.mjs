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

import {
  headBlock,
  nthBlock,
  nthTx,
  firstAddress,
  txWithAvailability,
  txWithSplitExecutions,
} from "./lib/entities.mjs";

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
//
// The /debug route now serves a positioned session, and it positions itself:
// `client/src/debugger/demo_session.nim` opens at step 128 of the recorded
// `zk_shields` trace, inside `calculate_damage` on the third iteration of the
// loop. So the mid-trace constant is that step, and it is the one every
// debugger view pins.
//
// The route is STATIC, which has a consequence worth stating rather than
// discovering: a query string cannot change what a static file server
// returns, so `?t=` does not yet move the session. It is carried because a
// capture URL must be the URL the product uses, and because the moment
// hydration lands (WorkerBackendService, Debugger-Integration §2) the same URL
// starts positioning the session for real. Where a view needs a DIFFERENT
// session, it selects a different transaction — which is a real difference in
// the published tree — rather than a different query parameter.
export const DEBUG_TIME_COORDINATE = "1";
export const DEBUG_TIME_COORDINATE_MID = "128";

const debugRoute = (txSel, { t = DEBUG_TIME_COORDINATE, extra = "" } = {}) => (ix) => {
  const tx = txSel(ix);
  return `/${ix.primaryChain}/tx/${tx.hash}/debug?t=${t}${extra}`;
};

/** The transaction the plain debugger views open: the first one in block order
 *  whose trace is published, undisputed and natively recorded. Selected by
 *  what the trace IS, not by position: the demo tree's first transaction in
 *  block order is on-demand and the next is heuristically reconstructed, so
 *  `nthTx(0)` would file the no-session state under the flagship view's name
 *  and `nthTx(1)` would put a "Reconstructed" caveat badge on it. */
const readyTx = txWithAvailability("ready", { reconstructed: false });
const divergentTx = txWithAvailability("divergent");

/** The transaction whose URL is NOT a session (Page-Descriptions §7.0's second
 *  and third rows). The demo tree publishes one: the on-demand transaction.
 *  Selected by availability rather than by position, because after §7.0 the
 *  availability is what decides which of the two shapes `/{chain}/tx/{hash}`
 *  serves — a positional selector would silently re-point a view at the other
 *  shape the first time a block's contents changed. */
const onDemandTx = txWithAvailability("onDemand");

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
    status: "ready",
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
  // ── The transaction route has TWO shapes (Page-Descriptions §7.0) ────────
  //
  // "One URL, and what it becomes depends on the trace, not on a click."
  // `ready`/`divergent` land in the debugging interface with the transaction's
  // facts as §7.1's metadata pane; `onDemand`/`absent`/`unsupported` get the
  // metadata page. Both shapes are served at `/{chain}/tx/{hash}`, so each
  // needs its own named view and each view has to pin a transaction whose
  // availability produces the shape the view's name claims — the same rule the
  // debugger views already follow.
  {
    id: "tx-detail",
    description: "Transaction page for a trace that opens no session (§7.0) — hero, overview grid, decoded input, events, calls, state, raw",
    covers: ["tx-detail"],
    register: "explorer",
    status: "ready",
    // Pinned by AVAILABILITY, not by position. `nthTx(0)` is the on-demand
    // transaction only by accident of block order, and after §7.0 that
    // accident decides which of the two shapes this view photographs.
    route: (ix) => `/${ix.primaryChain}/tx/${onDemandTx(ix).hash}`,
  },
  {
    id: "tx-detail--session",
    description: "The transaction's own URL landing in the debugging session (§7.0) — panes, with the transaction's facts as the metadata pane",
    covers: ["tx-detail"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // §7.0's first row, at the transaction's own address rather than at
    // /debug. This is the view that would have caught the divergence it now
    // documents: before it, the only capture of this URL was `tx-detail`, and
    // a page carrying a Debug BUTTON satisfied that view's name perfectly.
    route: (ix) => `/${ix.primaryChain}/tx/${readyTx(ix).hash}`,
  },
  {
    id: "tx-detail--dense",
    description: "The metadata page at the largest published payload — the density case",
    covers: ["tx-detail"],
    register: "explorer",
    status: "pending",
    // It used to capture the last transaction in block order, which has a
    // published trace — so after §7.0 that URL is the session, and capturing
    // it here would file a debugging surface under a view whose expectation
    // block requires eight explorer sections.
    //
    // Repointing it is not available either: the metadata page is now served
    // only for transactions with NO session, and the demo tree has exactly one
    // — the on-demand transaction, which is already `tx-detail`'s subject.
    // Capturing the same URL twice would answer VD.4's
    // `verify_transaction_page_holds_at_extreme_content` with a duplicate.
    pendingReason:
      "after §7.0 the metadata page is served only for a transaction with no " +
      "session, and the demo tree has exactly one — the on-demand transaction, " +
      "which is `tx-detail`'s own subject. A dense metadata page needs a " +
      "second traceless transaction with many roles, many cost rows and a long " +
      "raw payload in the demo generator, not a change to the route",
    route: (ix) => `/${ix.primaryChain}/tx/${onDemandTx(ix).hash}`,
  },
  {
    id: "tx-detail--hydrated",
    description: "Transaction detail after the debugger hydrates over it in place (§7.0, trace ready)",
    covers: ["tx-detail.hydrated"],
    register: "debugger",
    status: "pending",
    // What remains missing is narrower than it was. The transaction's own URL
    // now SERVES the session (`tx-detail--session`), so §7.0's landing rule is
    // captured; what nothing produces is the transition — the pre-rendered
    // frame being taken over by a live engine, in place, without the visitor
    // seeing less at any point. That is hydration, and the client ships no
    // JavaScript at all.
    pendingReason:
      "the transaction route now serves the session itself (see " +
      "`tx-detail--session`), but nothing hydrates it: the client ships no " +
      "JavaScript at all, and the SPA/hydration shell is the deferred half of " +
      "Front-End-Architecture §2's layer 4. The engine is unfetched, so the " +
      "panes are the pre-hydration frame and the stepping toolbar is inert — " +
      "capturing that under the hydrated view's name would file a static " +
      "first frame as a live session",
    route: (ix) => `/${ix.primaryChain}/tx/${readyTx(ix).hash}`,
  },
  {
    id: "tx-detail--decoded-input",
    description: "Decoded input section — function/entry point and ABI-decoded parameters",
    covers: ["tx-detail.decoded-input"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the section renders a placeholder, not decoded parameters`,
    route: (ix) => `/${ix.primaryChain}/tx/${onDemandTx(ix).hash}`,
    clip: "#decoded-input",
  },
  {
    id: "tx-detail--events",
    description: "Events/logs section at realistic volume, each row linking into the debugger",
    covers: ["tx-detail.events"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the events section is not populated`,
    route: (ix) => `/${ix.primaryChain}/tx/${onDemandTx(ix).hash}`,
    clip: "#events",
  },
  {
    id: "tx-detail--internal-calls",
    description: "Internal calls — the call tree from the trace",
    covers: ["tx-detail.internal-calls"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the internal-calls section is not populated`,
    route: (ix) => `/${ix.primaryChain}/tx/${onDemandTx(ix).hash}`,
    clip: "#internal-calls",
  },
  {
    id: "tx-detail--state-changes",
    description: "State changes — before → after diffs decoded to declared types",
    covers: ["tx-detail.state-changes"],
    register: "explorer",
    status: "pending",
    pendingReason: `${PENDING_STATE}: the state-changes section is not populated`,
    route: (ix) => `/${ix.primaryChain}/tx/${onDemandTx(ix).hash}`,
    clip: "#state-changes",
  },
  {
    id: "tx-detail--raw",
    description: "Raw section — chain-native transaction and receipt JSON, verbatim",
    covers: ["tx-detail.raw"],
    register: "explorer",
    status: "ready",
    // Was pending on "the raw section is not rendered", which had stopped
    // being true: the section renders, but its heading carried no id, so the
    // clip selector resolved to nothing. §7.0's work gave both trace-derived
    // §7.2 sections stable anchors — the metadata pane needs them too — so
    // the clip now addresses the section it names.
    route: (ix) => `/${ix.primaryChain}/tx/${onDemandTx(ix).hash}`,
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
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
  },
  {
    id: "debugger--metadata-pane",
    description: "The transaction metadata pane inside the session (§7.1)",
    covers: ["debugger.metadata-pane"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // The split transaction: its private half is structurally absent and its
    // public half is ready, so the pane's execution list has the §7.1
    // private/public split to render rather than a single row.
    route: debugRoute(txWithSplitExecutions, { t: DEBUG_TIME_COORDINATE_MID }),
    clip: "#pane-metadata",
  },
  {
    id: "debugger--call-trace",
    description: "Call trace at realistic depth and width, including the cost column",
    covers: ["debugger.call-trace"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    clip: "#pane-calltrace",
  },
  {
    id: "debugger--event-log",
    description: "Event log with mixed calls, storage writes, events and a revert",
    covers: ["debugger.event-log"],
    register: "debugger",
    status: "pending",
    // The renderer handles all five kinds and `evRevert` is exercised against
    // the real Embed SDK in `tests/tdebugpanes.nim`. What is missing is DATA:
    // no transaction the demo generator produces reverts, and the pane refuses
    // to pretend otherwise — `ooPartial` is the Aztec split with both halves
    // succeeded, not a revert, and rendering a failed constraint against it
    // would be the pane inventing an event the trace never carried.
    //
    // So this view can only ever photograph four of the five kinds, and its
    // own "must show" requires the fifth: "the revert entry rendered as the
    // terminal, significant event it is". Capturing it `ready` would file a
    // four-kind log under a view whose expectation names five, and spend a
    // review round rediscovering a gap that is already written down. Same
    // shape as `debugger--truncated` below, and given the same status.
    //
    // The fix is one reverted transaction in the demo generator. Then this
    // becomes `ready` against `txWithOutcome("reverted")` and nothing about
    // the renderer changes.
    pendingReason:
      `${PENDING_STATE}: no transaction in the demo tree reverts, so the ` +
      "event log can show four of its five kinds and this view's own " +
      "must-show list requires the fifth",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // The event log shares a tabbed region with the state pane and is the
    // NON-default tab, so the URL carries the fragment that selects it. The
    // tabs are `:target`-driven CSS, so this is the same mechanism a visitor
    // uses — not a capture-only hook.
    route: debugRoute(divergentTx, {
      t: DEBUG_TIME_COORDINATE_MID,
      extra: "#pane-eventlog",
    }),
    clip: "#pane-eventlog",
  },
  {
    id: "debugger--state-pane",
    description: "State pane with deeply nested values and long identifiers",
    covers: ["debugger.state-pane"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    clip: "#pane-state",
  },
  {
    id: "debugger--source-pane",
    description: "Source pane, source-level session with the level boundary legible",
    covers: ["debugger.source-pane"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    clip: "#pane-editor",
  },
  {
    id: "debugger--loading-phases",
    description: "Phased, honest loading — fetching, opening, positioning; never a spinner",
    covers: ["debugger.loading-phases"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // The route's REAL state, not a staged one. Every statically exported page
    // is `fetching`: the panes are populated from published data and the
    // replay engine — 18 MB of wasm from `replay_engine.ReplayEngineBase` —
    // has not been fetched, so the phase rail names `fetching` and the
    // stepping toolbar renders visibly inert. `opening` and `positioning` are
    // states only hydration passes through and are not capturable until
    // WorkerBackendService lands; asking for them with a query parameter would
    // be staging a screenshot, which is what this view exists to rule out.
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    clip: ".enginenotice",
  },
  {
    id: "debugger--narrow",
    description: "Reduced read-only narrow session — source + call trace + values, limitation stated",
    covers: ["debugger.narrow"],
    register: "debugger",
    status: "ready",
    sizes: NARROW_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
  },
  {
    id: "debugger--truncated",
    description: "Trace-truncated banner, with the option to request a deeper profile",
    covers: ["degraded.trace-truncated"],
    register: "debugger",
    status: "pending",
    pendingReason:
      "the route renders the truncation banner from the manifest's " +
      "`execution.truncated`, and no artifact the demo generator publishes " +
      "sets it — the packaged `noir_space_ship` trace ran to completion. " +
      "This needs a truncated artifact in the demo tree (M5c), not a change " +
      "to the route",
    fullPage: false,
    route: debugRoute(readyTx, { extra: "&state=truncated" }),
  },
  {
    id: "debugger--divergent",
    description: "Non-dismissible divergence banner above the debugger, naming the mismatch",
    covers: ["degraded.divergence"],
    register: "debugger",
    status: "ready",
    fullPage: false,
    // A genuinely divergent transaction in the published tree, not a query
    // parameter asking the page to pretend. `?state=` never decided this:
    // §7.0's rule is that availability decides the landing.
    route: debugRoute(divergentTx, { t: DEBUG_TIME_COORDINATE_MID }),
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
    // Was `tx-detail--dense`, which §7.0 turned into a pending view: the URL
    // it captured now serves the session. `tx-detail` renders the same
    // rendering path — a page of hashes, addresses and decoded values in the
    // monospace face — and is ready, so the canary keeps covering it.
    view: "tx-detail",
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
