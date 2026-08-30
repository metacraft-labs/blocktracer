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
  txWithOutcome,
  txWithTruncatedTrace,
  firstTracelessTx,
  densestTracelessTx,
  contractWithSource,
  addressWithSegments,
  segmentIdOf,
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
// returns, so `?t=` does not move the session in a captured build. It is
// carried because a capture URL must be the URL the product uses. Where a view
// needs a DIFFERENT session, it selects a different transaction — which is a
// real difference in the published tree — rather than a different query
// parameter.
//
// UPDATED 2026-08-30, and the update is a caveat rather than a change. The
// hydration bundle now READS this coordinate (Debugger-Integration §6.0a), so
// the same URL positions a live session for real — but only where the bundle
// is present, and `runExporter` in `capture.mjs` compiles `static_export.nim`
// with no `-d:hydrationBundle`, so a captured page carries no script and the
// query stays inert. What a capture must NOT start doing is stand in for a
// deep-link test: a bare `?t=` has no content witness, and §6.0's table treats
// a witness-less coordinate as unverifiable, so a HYDRATED build served this
// URL would open at the start of the execution and say so. That is correct
// behaviour and it is exercised where it belongs —
// `client/tests/test_debug_route.nim`'s §6.0a suite, case 5(b) — rather than
// inferred from a screenshot of a page with no script on it.
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
 *  and third rows). The demo tree publishes two: the on-demand transaction the
 *  metadata page has always been captured against, and — since the generator
 *  gained txH — a second, much denser one. Selected by availability rather than
 *  by position, because after §7.0 the availability is what decides which of
 *  the two shapes `/{chain}/tx/{hash}` serves; a positional selector would
 *  silently re-point a view at the other shape the first time a block's
 *  contents changed. */
const onDemandTx = txWithAvailability("onDemand");

/** §7.0's THIRD row, which had no subject in the published tree until VD.6 and
 *  therefore no view: `txWithAvailability("absent")` threw, and the two states
 *  `pages/tx.nim` argues hardest about — the pair that gets no control at all,
 *  "not even a disabled one" — had never been rendered by anything. The demo
 *  generator now publishes txI and txJ for them.
 *
 *  Two selectors and two views, never one. `absent` and `unsupported` are
 *  different facts about the world — there is nothing to record, and we cannot
 *  record it — and §14.1a is explicit that "presenting either as the other is
 *  the failure this table exists to prevent". A single view could be answered
 *  by a single image and the pair would be gradeable only against itself. */
const absentTx = txWithAvailability("absent");
const unsupportedTx = txWithAvailability("unsupported");

/** The transaction whose OUTCOME is a revert, which is what gives the event
 *  log its fifth entry kind a subject, and the one whose RECORDING was cut off
 *  at the profile's budget, which is what gives §14's truncation banner one.
 *  Both are published facts in the demo tree (`src/blocktracer/demo/
 *  generator.nim`, txF and txG), not query parameters asking a page to
 *  pretend — the same rule `debugger--divergent` already follows. */
const revertedTx = txWithOutcome("reverted");
const truncatedTx = txWithTruncatedTrace;

/** The densest transaction the METADATA page serves, and the guarantee that it
 *  is not the one `tx-detail` already captures. See `densestTracelessTx`. */
const denseTx = densestTracelessTx;

/** The two contract-source subjects, selected by whether a bundle for their
 *  code hash is PUBLISHED — never by position. The demo tree carries one of
 *  each: four of its five contracts executed a transaction whose trace was
 *  published (so their source was too), and the fifth is the on-demand
 *  transaction's target, which is genuinely unverified. */
const verifiedContract = contractWithSource(true);
const unverifiedContract = contractWithSource(false);

/** The address whose history the generation splits across more than one
 *  block-range segment — the only address on which the cursor pager renders an
 *  "Older" control at all. */
const pagedAddress = addressWithSegments(2);

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
    status: "ready",
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
    // The TREATMENT now exists: `components/degraded.notice` renders
    // `cdPipelineBehindTip`, `ssr.chainSnapshot` resolves it from the pinned
    // session's published `stale` flag, and `ChainOverviewDegradations` is the
    // sensitivity set that admits it here. What is missing is DATA — the demo
    // generator publishes one chain whose summary says `stale: false`, so no
    // route in the tree renders the notice.
    //
    // It cannot be fixed by flipping THIS chain's flag, which is the obvious
    // cheap move and is wrong: with one chain in the tree, a stale `aztec`
    // would put the notice on `chain-overview` too, and the two views would be
    // one URL under two names — the same duplication that kept
    // `tx-detail--dense` pending. It needs a SECOND, behind-the-tip chain.
    //
    // Scoped 2026-08-30, when the other three data gaps were closed, and
    // deliberately NOT taken in the same change. What was established:
    //
    //   * The consumers are ready. `reader.chains`, `ssr.renderHome`,
    //     `ssr.staticRoutes` and `pages/chains.nim` all loop over the registry
    //     already, `validator.validateTree` walks every chain under `/d`, and
    //     `lib/entities.mjs` builds `byChain` over all of them. A behind-the-tip
    //     chain also links nothing dangling: only `headHeight` is ever printed,
    //     never the head HASH, so a pointer above the highest indexed block
    //     produces no broken link.
    //   * The generator is not. `chain` is a module-level `const` read in ~45
    //     places, and — the part that makes this a restructure rather than a
    //     parameter — `/idx/hash/**` is a SHARED index across chains while each
    //     chain's `root.json` declares the shard list, so `generate` has to
    //     collect every chain's entities before it can write either.
    //   * Two ordering hazards, both silent if missed: the new slug must sort
    //     AFTER "aztec" (`primaryChain = chains[0]` re-points all 30-odd view
    //     routes otherwise, and `publishTree(...)[0]` is assumed to be aztec in
    //     sixteen places in `tests/tpublish.nim`), and its synthetic hashes must
    //     be keyed by slug as well as seed or both chains publish the same
    //     block, transaction and address hashes from one seed.
    //
    // That is a change to the one file whose byte-for-byte output IS the M5c
    // regression fixture, and it is separable from the three gaps this change
    // closes. Kept pending with the work scoped rather than half-done.
    pendingReason:
      "the staleness treatment is rendered by `components/degraded` and " +
      "resolved by `ssr.chainSnapshot`, and no chain in the demo tree is " +
      "behind its tip: the generator publishes one chain with `stale: false` " +
      "in its summary. Flipping that one chain's flag is not the fix — it would " +
      "put the notice on `chain-overview` as well and make the two views one " +
      "URL under two names. This needs a SECOND, behind-the-tip chain, which " +
      "means teaching the generator to emit N chains around a hash index that " +
      "is shared between them; the client, the validator and this harness " +
      "already handle N chains today",
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
    // Expansion is a script behaviour and this client ships none. The
    // CONTENT §5.1 asks the expansion to reveal — the block's transaction
    // hashes with per-row Debug actions — is one click away on the block's own
    // page, through the height cell, and is captured as `block-detail`.
    pendingReason:
      "row expansion needs script and this client ships none. What §5.1 asks " +
      "the expansion to reveal is the shared transactions table filtered to " +
      "the block, which the block's own page renders and `block-detail` " +
      "captures; the height cell links to it. This view is the EXPANDED " +
      "state, which only hydration can produce",
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
    status: "ready",
    route: (ix) => `/${ix.primaryChain}/txs`,
  },
  {
    id: "txs-list--cards",
    description: "Transactions table collapsed to stacked cards below 900px, Debug and status retained",
    covers: ["txs-list.cards"],
    register: "explorer",
    status: "ready",
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
    //
    // `firstTracelessTx` and not `onDemandTx`, now that a second traceless
    // transaction exists: `densestTracelessTx` guarantees `tx-detail--dense`
    // does not return the FIRST traceless transaction, and that guarantee is
    // only about this view if this view asks the same question. The two
    // resolve to the same transaction today; they would not if the tree ever
    // published an `absent`-only transaction ahead of the on-demand one, and
    // the pair would then have been silently comparing different things.
    route: (ix) => `/${ix.primaryChain}/tx/${firstTracelessTx(ix).hash}`,
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
    description: "The metadata page at the largest published payload — five roles, five cost rows and a 1 KB raw payload",
    covers: ["tx-detail"],
    register: "explorer",
    status: "ready",
    // Was pending twice over. It used to capture the last transaction in block
    // order, which has a published trace — so after §7.0 that URL became the
    // session, and capturing it here would have filed a debugging surface under
    // a view whose expectation block requires eight explorer sections. And
    // repointing it was not available: the metadata page is served only for
    // transactions with NO session, and the tree had exactly one, which is
    // `tx-detail`'s own subject.
    //
    // The generator now publishes txH — traceless, and by a distance the
    // densest transaction in the tree: five roles against one, five cost rows
    // against one, and a raw payload of a selector plus sixteen ABI words
    // against `0x`. `densestTracelessTx` picks it by CONTENT and refuses to
    // return `tx-detail`'s subject, so this view cannot quietly become a
    // duplicate of that one again.
    route: (ix) => `/${ix.primaryChain}/tx/${denseTx(ix).hash}`,
  },
  {
    id: "tx-detail--absent",
    description:
      "§7.0 `absent` — the metadata page for an execution with no call structure to record: the state as a badge, the reason as a sentence, and no control of any kind",
    covers: ["tx-detail.absent"],
    register: "explorer",
    status: "ready",
    // Was unfixturable rather than unrenderable, which is the distinction that
    // makes this a data change and not a client one: `pages/tx.nim` has always
    // had this branch and `viewutil.availabilityNote(taAbsent)` has always had
    // its sentence. Nothing in the demo tree ever reached them.
    //
    // What this image is reviewed for is the ABSENCE of a control. §7.0 gives
    // this row "no debugger, and no pretence of one", and `pages/tx.nim` spends
    // twelve lines on why that means no disabled button either: "a greyed `Not
    // observable` button is still a button: it occupies the position of the
    // primary action and invites the click it will refuse". A reviewer who sees
    // one here is looking at a regression, not at a design choice.
    route: (ix) => `/${ix.primaryChain}/tx/${absentTx(ix).hash}`,
  },
  {
    id: "tx-detail--unsupported",
    description:
      "§7.0 `unsupported` — the metadata page for an execution this product cannot record: the same shape as `absent` and NOT the same sentence",
    covers: ["tx-detail.unsupported"],
    register: "explorer",
    status: "ready",
    // The point of this view is comparative and it is the only one in the list
    // that is: read beside `tx-detail--absent`, does a visitor learn that these
    // are two different facts about the world? Both render a muted badge and a
    // sentence and offer nothing, so everything separating them is the wording
    // and the tone — §14.1a's "'Not now' and 'not ever' are different states"
    // one row further down, where the two terminal states have to be told apart
    // from each other rather than from a wait.
    route: (ix) => `/${ix.primaryChain}/tx/${unsupportedTx(ix).hash}`,
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
    description: "Address / contract — identity, code summary with verification, the shared transactions table with Debug on every row, and the events section",
    covers: ["address"],
    register: "explorer",
    status: "ready",
    // A CONTRACT, so §9's code-summary section has content. `firstAddress`
    // is the lexicographically first indexed address and is an account in this
    // tree, whose code summary is a single sentence saying there is no code —
    // a true statement, and not what this view is named for. The account case
    // is `address--account`.
    route: (ix) => `/${ix.primaryChain}/address/${verifiedContract(ix)}`,
  },
  {
    id: "address--account",
    description: "Address that is an account, not a contract — the code section states there is no code rather than showing an empty file list",
    covers: ["address"],
    register: "explorer",
    status: "ready",
    // The same page over a different SHAPE of subject, which is what makes it
    // a second view rather than a duplicate: an account has no code hash, so
    // §9's code summary is a statement instead of a table, and rule 2's "a
    // statement of why not" is what this image is reviewed for.
    route: (ix) => `/${ix.primaryChain}/address/${firstAddress(ix)}`,
  },
  {
    id: "address--older-page",
    description: "A later block-range segment of an address's history — the cursor pager, with Older and Newest and no page numbers",
    covers: ["address"],
    register: "explorer",
    status: "ready",
    // §2.2 rules out ordinal pagination outright, so the thing to review here
    // is the ABSENCE of page numbers as much as the presence of the controls:
    // a cursor page is addressed by the block range it covers, and the pager
    // states that range in words because a cursor URL does not tell a reader
    // where they are.
    route: (ix) => {
      const address = pagedAddress(ix);
      return `/${ix.primaryChain}/address/${address}/seg/${segmentIdOf(address, 1)(ix)}`;
    },
  },
  {
    id: "contract-source",
    description: "Verified source browser — verification, file tree, ABI, storage layout, deployments",
    covers: ["contract-source"],
    register: "explorer",
    status: "ready",
    // Pinned by whether a source bundle for the address's code hash is
    // PUBLISHED. `firstAddress` is the lexicographically first indexed
    // address, which in this tree is an account with no code at all — the
    // page would render "no code is bound to this address", filed under a view
    // named "verified source browser".
    route: (ix) => `/${ix.primaryChain}/address/${verifiedContract(ix)}/code`,
  },
  {
    id: "contract-source--unverified",
    description: "No verified source — instruction-level stepping with supply-sources prominent",
    covers: ["degraded.no-verified-source"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${ix.primaryChain}/address/${unverifiedContract(ix)}/code`,
  },
  {
    id: "search",
    description: "Search — how an identifier resolves, the chains that would be checked, and the published name corpus",
    covers: ["search"],
    register: "explorer",
    status: "ready",
    // No `?q=`. A static file server cannot read one, and the page is
    // deliberately not a results page: §11's resolution runs in the browser
    // (Search-And-Routing §1-§6) and this client ships no script. What the
    // route serves is what it genuinely holds — the mechanisms, the chains
    // that would be checked, and the whole published name corpus, browsable
    // without a query. The three query-DEPENDENT states below stay pending.
    route: () => "/search",
  },
  {
    id: "search--ambiguous",
    description: "Search — grouped, keyboard-navigable candidates across kinds",
    covers: ["search.ambiguous"],
    register: "explorer",
    status: "pending",
    // `/search` IS served now (see the `search` view), and this state is
    // not: it needs the page to have READ the query, and a static file server
    // cannot. Every mechanism that would produce grouped candidates for an ambiguous query runs in the browser.
    pendingReason:
      "/search is served, and this state is query-dependent: a static file " +
      "server cannot read `?q=`, and every resolution mechanism " +
      "(Search-And-Routing §1-§6) runs in the browser. It arrives with " +
      "hydration, not with a change to the route",
    route: () => "/search?q=0x27a6",
  },
  {
    id: "search--cross-chain",
    description: "Search — active chain's results first, 'found on other chains' below",
    covers: ["search.cross-chain"],
    register: "explorer",
    status: "pending",
    // `/search` IS served now (see the `search` view), and this state is
    // not: it needs the page to have READ the query, and a static file server
    // cannot. Every mechanism that would produce an active chain's results above a 'found on other chains' group runs in the browser.
    pendingReason:
      "/search is served, and this state is query-dependent: a static file " +
      "server cannot read `?q=`, and every resolution mechanism " +
      "(Search-And-Routing §1-§6) runs in the browser. It arrives with " +
      "hydration, not with a change to the route",
    route: () => "/search?q=0x27a6&scope=all",
  },
  {
    id: "search--not-found",
    description: "Search — what was tried and where, so a miss reads as a scoping answer",
    covers: ["search.not-found"],
    register: "explorer",
    status: "pending",
    // `/search` IS served now (see the `search` view), and this state is
    // not: it needs the page to have READ the query, and a static file server
    // cannot. Every mechanism that would produce the not-found answer for a specific query runs in the browser.
    pendingReason:
      "/search is served, and this state is query-dependent: a static file " +
      "server cannot read `?q=`, and every resolution mechanism " +
      "(Search-And-Routing §1-§6) runs in the browser. It arrives with " +
      "hydration, not with a change to the route",
    route: () => "/search?q=0xdeadbeef",
  },
  {
    id: "settings",
    description: "Settings — storage, debugger, privacy and advanced groups",
    covers: ["settings"],
    register: "explorer",
    status: "ready",
    route: () => "/settings",
  },
  {
    id: "static-content",
    description: "Static content — /about, the privacy summary the trust strip links to",
    covers: ["static-content"],
    register: "explorer",
    status: "ready",
    // `/about` is served; `/docs/*` is not, and is not a separate view: the
    // inventory entry names both and a view covers it when either renders.
    route: () => "/about",
  },
  {
    id: "not-found",
    description: "Object not found — 'not on this chain', naming the chains checked",
    covers: ["degraded.not-found"],
    register: "explorer",
    status: "ready",
    // `static_export` now writes `404.html`, and it writes the exact bytes
    // `renderRoute` returns with a 404 status — so the harness's server serves
    // the product's own page here rather than its own fallback, and the image
    // is the treatment rather than a placeholder.
    route: (ix) => `/${ix.primaryChain}/tx/0x0000000000000000000000000000000000000000`,
    expectHttpStatus: 404,
  },

  // ─────────────────────────── Debugger register ──────────────────────────
  {
    id: "debugger",
    description:
      "Full-viewport debugging session at the pinned time coordinate — controls in the identity bar, Code beside a tabbed Call Trace / Event Log region with Values below it",
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
    description:
      "Call trace at realistic depth and width, including the cost column — the OPEN tab of the navigation region",
    covers: ["debugger.call-trace"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // No fragment, deliberately. The call trace is the region's DEFAULT tab
    // (`session_layout.blockTracerReplayLayout`, `activeIndex = 0`), so the
    // bare route is what a visitor arrives at, and capturing it through
    // `#pane-calltrace` would photograph a state reached by a click rather
    // than the one the page opens in. Its sibling `debugger--event-log` DOES
    // carry a fragment, for exactly the same reason in the other direction.
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    // The REGION, not `#pane-calltrace`. Inside a stack the panel's own
    // `.panehead` is `display:none` and the tab strip is its sibling, so a clip
    // on the panel yields an image with no title on it at all — and the strip
    // is now part of this pane's chrome, not decoration around it. There is
    // exactly one `.ln.stack` in the served markup and `test_debug_route`
    // asserts that count, so the selector is as stable as an id would be.
    clip: ".ln.stack",
  },
  {
    id: "debugger--event-log",
    description:
      "Event log with all five entry kinds — calls, program output, storage writes, events and the revert that ends the transaction — the second tab of the navigation region, selected by its fragment",
    covers: ["debugger.event-log"],
    register: "debugger",
    status: "ready",
    // Was pending, and the reason was DATA rather than code: the renderer
    // handled all five kinds and `evRevert` was already exercised against the
    // real Embed SDK in `tests/tdebugpanes.nim`, but no transaction the demo
    // generator produced reverted. The pane refused to pretend otherwise —
    // `ooPartial` is the Aztec split with BOTH halves succeeded, not a revert,
    // and rendering a failed constraint against it would have been the pane
    // inventing an event the trace never carried. That refusal was right and
    // is unchanged.
    //
    // The generator now publishes txF: a genuinely reverted transaction whose
    // trace is `ready` and whose verdict is `match`, because the recorder
    // faithfully recorded a transaction that failed its own constraint. So the
    // subject moved from the DIVERGENT transaction — which was only ever
    // standing in, and could show four kinds — to the reverted one, and
    // nothing about the renderer changed.
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // The event log is the ALTERNATE half of the navigation region's tab pair
    // — it now pairs with the call trace rather than with the values pane —
    // so the URL carries the fragment that selects it. The tabs are
    // `:target`-driven CSS, so this is the same mechanism a visitor uses, not
    // a capture-only hook: the fragment IS the click.
    route: debugRoute(revertedTx, {
      t: DEBUG_TIME_COORDINATE_MID,
      extra: "#pane-eventlog",
    }),
    // The region, for the same reason as `debugger--call-trace` above: these
    // two views are the same region in its two states, and the strip that says
    // which state it is in has to be in both frames.
    clip: ".ln.stack",
  },
  {
    id: "debugger--values-pane",
    description: "Values pane with deeply nested values and long identifiers",
    covers: ["debugger.values-pane"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    // `#pane-state`, not `#pane-values`, and deliberately: the element id is
    // derived from CodeTracer's `PaneKind` spelling (`paneState` → `"state"`),
    // which is a wire format shared with the Embed SDK. The pane's TITLE is
    // BlockTracer's and is now "Values"; renaming the enum would be a
    // cross-repo change to a serialisation. See `debugger/session_layout.nim`.
    clip: "#pane-state",
  },
  {
    id: "debugger--source-pane",
    description: "Code pane, source-level session with the level boundary legible",
    covers: ["debugger.source-pane"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    // Same enum-versus-label split as `debugger--values-pane` above: the pane
    // is titled "Code" and its id is still `pane-editor`.
    clip: "#pane-editor",
  },
  {
    id: "debugger--omniscience",
    description: "Recorded values inline beside the code, and the loop rail above them",
    covers: ["debugger.omniscience", "debugger.loop-rail"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
    // The same clip as `debugger--source-pane`, and the same pixels — one pane,
    // captured twice, judged against two different questions. That is
    // deliberate rather than duplication: the source pane's review asks whether
    // the CODE is legible and correctly highlighted, and this one asks whether
    // the VALUES beside it are legible and whose pass they belong to. A single
    // block with fourteen must-shows is a block a reviewer reads once and
    // answers in aggregate, which is how the density findings in round 5 were
    // missed the round before.
    clip: "#pane-editor",
  },
  {
    id: "debugger--omniscience-earlier-pass",
    description: "The loop rail moved to an earlier pass — the values follow, with no JavaScript",
    covers: ["debugger.loop-rail"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // `#fit-0` is the rail's first segment, and following it is the whole
    // no-JavaScript claim: the fragment is a real `:target`, the stylesheet
    // swaps which pass's labels are displayed, and the values on screen become
    // pass 1's. Captured as a URL rather than as a scripted click for exactly
    // that reason — a click would prove nothing about a page that ships no
    // script, and this proves the control WORKS in the state the ladder's
    // bottom rung is about.
    //
    // It is also the one capture in this file that would not survive the
    // control being replaced by something that needs script, which is what
    // makes it worth its bytes.
    route: debugRoute(readyTx, {
      t: DEBUG_TIME_COORDINATE_MID,
      extra: "#fit-0",
    }),
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
    // The identity bar, because that is where all of this now lives: the phase
    // rail, the controls' status, and the inert stepping buttons whose state IS
    // the loading signal. The clip used to be a full-width explanatory band
    // above the session; that band was deleted, and a clip aimed at it would
    // capture nothing — which is why this selector moves with the change rather
    // than after the next review round notices.
    clip: ".dbgbar",
  },
  {
    id: "debugger--narrow",
    description: "Reduced read-only narrow session — code + call trace + values, limitation stated",
    covers: ["debugger.narrow"],
    register: "debugger",
    status: "ready",
    sizes: NARROW_SIZES,
    fullPage: false,
    route: debugRoute(readyTx, { t: DEBUG_TIME_COORDINATE_MID }),
  },
  {
    id: "debugger--truncated",
    description: "Trace-truncated banner over a fully usable session, with the option to request a deeper profile",
    covers: ["degraded.trace-truncated"],
    register: "debugger",
    status: "ready",
    // Was pending because nothing published `execution.truncated`; the banner
    // has been rendered from the manifest by `ssr.debugSessionFor` all along.
    // The generator now publishes txG, whose manifest sets the flag.
    //
    // The route lost its `&state=truncated`, and that is the substance of the
    // change rather than a tidy-up. A query parameter cannot alter what a
    // static file server returns, so the old URL was asking a page to pretend
    // and being served the ordinary session — this view would have photographed
    // a session with no banner on it and been graded for the missing banner.
    // The subject is now a transaction whose published recording really did
    // stop at the profile's budget, exactly as `debugger--divergent` pins a
    // genuinely divergent transaction rather than asking for a state.
    //
    // All four viewports, like `debugger--divergent` and unlike the pane views:
    // the banner competes with the session for vertical space, and how it
    // behaves at 375px is part of what is being judged.
    fullPage: false,
    route: debugRoute(truncatedTx, { t: DEBUG_TIME_COORDINATE_MID }),
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

  {
    id: "debugger--no-session",
    description:
      "The debug ADDRESS of a transaction with no session, on-demand — `pages/debug.noSession` in the region the panes would have occupied, with the generate action and no stepping toolbar",
    covers: ["debugger.no-session"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // This route is SERVED and was unphotographed. `ssr.staticRoutes` emits
    // `/debug` for every transaction, not only for the ones that open a
    // session, so `/{chain}/tx/{onDemand}/debug` has always resolved to a real
    // page — and every debugger view in this file pinned a transaction with a
    // trace, so the one surface in this register whose whole job is to NOT be a
    // debugger had never appeared in a review round.
    //
    // What it is reviewed for: that the pane region reads as a deliberate
    // statement rather than as a debugger that failed to load. It is a single
    // pane in a four-column shell, which is the arrangement most likely to look
    // like a broken layout when it is in fact the correct one.
    route: debugRoute(onDemandTx),
  },
  {
    id: "debugger--no-session-terminal",
    description:
      "The debug address of a transaction whose trace can never exist — the same region as `debugger--no-session` with NO action in it, which is the whole difference",
    covers: ["debugger.no-session"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    // The pair. `spAwaitingGeneration` renders a Generate control and a
    // sentence about quota; `spUnavailable` renders the sentence alone, because
    // §14 forbids "a retry that cannot succeed" and §7.0 forbids the pretence.
    // Captured separately so that the missing control is judged as the subject
    // of an image rather than noticed as a difference between two paragraphs.
    route: debugRoute(absentTx),
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
