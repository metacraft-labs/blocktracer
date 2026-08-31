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
  witnessOf,
  staleWitnessOf,
  currentCallAnchorOf,
  unresolvableChildAnchorOf,
  unresolvableLogAnchorOf,
  zeroTraceTxOn,
  tracedTxOn,
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

// ── The two real chains, named once ────────────────────────────────────────
//
// A slug appears here and nowhere else in the view list, and it never appears
// without `realChain` around it. The slug alone would be the guess
// `components/provenance.nim` refuses to make; `realChain` turns it into a
// checked claim by asserting the chain is present AND that its generation
// published `live-capture`. If a rename or a re-capture makes either untrue the
// view fails loudly at resolve time, which is the behaviour every other
// selector in this harness has.
const TESTNET = "aztec-testnet";
// The Aztec mainnet IS `/aztec` — the canonical slug, not a qualified one. It used to be
// `aztec-mainnet` while the synthetic fixture held `aztec`; the fixture has moved to
// `demo` and is no longer published on the site at all. `realChain` still checks the
// published provenance rather than trusting this string, which is what makes the rename
// a one-line change here instead of a silent re-point of two views.
const MAINNET = "aztec";

const realChain = (ix, slug) => {
  const c = ix.chain(slug); // throws when the chain is not in the tree
  if (c.provenanceKind !== "live-capture") {
    throw new Error(
      `chain "${slug}" publishes provenance kind "${c.provenanceKind || "(none)"}", ` +
      `not "live-capture" — this view's subject is REAL chain data and would ` +
      `otherwise photograph something else under that name`);
  }
  return slug;
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

// ── The hydration-only half of this route (VD.7) ───────────────────────────
//
// Two families of user-visible sentence are drawn by the hydration bundle and
// by nothing else, so until VD.7 neither had ever been rendered by anything:
//
//   * §6.0a's landing notice. The payload is in the QUERY, a static export
//     serves one file per PATH, and `pages/debug.nim` says so where it emits
//     the slot: "`?t=` cannot select a rendering". Four of the five branches
//     carry a sentence, and no human had seen one.
//   * `hydrate.markUnavailable`'s three engine-failure sentences, separated at
//     their source because one sentence covering two faults cost hours of
//     misdiagnosis — a separation defended entirely by unread text.
//
// A view below carrying `hydrated: true` is captured from `client/dist-hydrated`
// (`capture.mjs`'s `runHydratedExporter`) instead of `client/dist`, and names
// the `engine:` scenario the capture server runs at `/replay-engine/worker.js`
// (`lib/engine-stubs.mjs`). The static tree and the 63 views over it are
// untouched.
//
// What is substituted in these images and what is not, stated once here and
// again in every affected expectation block: the page is the one the real
// exporter wrote, the bundle is the real `nim js` build of `hydrate.nim`, and
// every sentence is drawn by `components/debugger` from a string in
// `hydrate.nim` or `blocktracer_client/deeplink.nim`. What the harness supplies
// is the ENGINE — the 18 MB wasm worker this repository deliberately does not
// vendor, whose absence, silence or refusal is the subject.

/** Mirrors `hydrate.EngineDeadlineMs`. The watchdog is NOT shortened to suit
 *  the harness — §8's rule that "a phase rail stuck on `opening` is a spinner
 *  with a name" is exactly what it enforces, and a 45 s deadline that trips at
 *  5 s would report a broken engine to a visitor whose engine was arriving.
 *  Instead the capture advances the FROZEN clock the whole corpus is captured
 *  under, so the deadline fires at its real value in page-time and costs no
 *  wall-clock at all. If the product's deadline ever moves past this, the two
 *  views that depend on it fail their post-conditions loudly rather than
 *  photographing a page that is still loading. */
const ENGINE_DEADLINE_ADVANCE_MS = 46_000;

/** `blocktracer_client/deeplink.encodeValue`, in JavaScript. The set of
 *  unreserved characters is the contract — `:` survives, so `a=call:0.2.6` is
 *  written the way the product writes it and not as `a=call%3A0.2.6`. */
const encodeLinkValue = (s) =>
  [...s]
    .map((c) =>
      /[A-Za-z0-9\-._~:]/.test(c)
        ? c
        : "%" + c.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0"),
    )
    .join("");

/** A `/debug` URL carrying a §6.0a payload in the query, exactly as
 *  `deeplink_landing.positionQuery` writes it: `v`, then `t`, then `c`, then
 *  `a`. `fields` is given the resolved transaction so every value can be
 *  derived from the published trace rather than written down. */
const positionRoute = (txSel, fields) => (ix) => {
  const tx = txSel(ix);
  const f = fields(tx, ix);
  const parts = ["v=1"];
  if (f.t) parts.push(`t=${f.t}`);
  if (f.c) parts.push(`c=${encodeLinkValue(f.c)}`);
  if (f.a) parts.push(`a=${encodeLinkValue(f.a)}`);
  return `/${ix.primaryChain}/tx/${tx.hash}/debug?${parts.join("&")}`;
};

/** The URL the engine-failure views open, and it is a WHOLE §6.0a link rather
 *  than the bare `?t=` every other debugger view pins.
 *
 *  Found by looking at the first capture of these views: `?t=128` alone is a
 *  coordinate with no content witness, which §6.0 treats as unverifiable — so a
 *  hydrated build served the corpus's own debugger URL renders step 5's notice
 *  as well as the engine banner, and the image meant to be about one sentence
 *  carried two. (views.mjs predicted exactly this in the comment above
 *  `DEBUG_TIME_COORDINATE`; what it did not predict is that the first hydrated
 *  capture would be of a different subject.)
 *
 *  So these three open the link this page's own Share control emits — `v`, `t`,
 *  `c` and `a`, exact hit, notice silent — and the only thing said on the page
 *  is the engine's verdict. `requireEngineFailure` asserts the notice stayed
 *  silent, so the two families cannot start bleeding into each other again. */
const engineFailureRoute = positionRoute(readyTx, (tx) => ({
  t: DEBUG_TIME_COORDINATE_MID,
  c: witnessOf(tx),
  a: currentCallAnchorOf(tx),
}));

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** Poll from Node until `selector`'s text contains `needle`.
 *
 *  Node-side, because the page's clock is frozen and faked: an in-page poll
 *  would be waiting on timers that only advance when this harness advances
 *  them. Throwing is the point — a capture that did not reach the state its
 *  view is named for must fail, not produce an image filed under that name. */
async function waitForText(page, selector, needle, what) {
  let seen = "";
  for (let i = 0; i < 60; i++) {
    seen = await page.evaluate((s) => document.querySelector(s)?.innerText ?? "", selector);
    if (seen.includes(needle)) return seen;
    await sleep(50);
  }
  throw new Error(
    `${what}: '${selector}' never said ${JSON.stringify(needle)} (it said ${JSON.stringify(seen.slice(0, 160))})`,
  );
}

/** Every hydrated view's precondition: the bundle actually ran.
 *
 *  Load-bearing, and most of all for the view whose subject is an ABSENCE. An
 *  un-hydrated page and an exact-hit page both show an empty notice slot, and
 *  they are pixel-identical — so without a positive signal that the script ran,
 *  `debugger--link-exact` would be satisfied by a build with no script at all,
 *  which is precisely the thing it is there to distinguish. §13's copy buttons
 *  are that signal: `upgradeCopyAffordances` runs first and unconditionally,
 *  before any engine work, and adds `.copybtn` to values the served page
 *  renders without one. */
async function requireHydrated(page) {
  for (let i = 0; i < 100; i++) {
    if (await page.evaluate(() => !!document.querySelector(".dbg .copybtn"))) return;
    await sleep(50);
  }
  throw new Error(
    "the hydration bundle did not run (no `.copybtn` was upgraded) — this image " +
      "would be a capture of the static page under a hydration-only view's name",
  );
}

/** Post-condition for a §6.0a landing view: the branch that rendered is the
 *  branch the view is named for, read off `data-landing` rather than off the
 *  sentence. */
const requireLanding = (outcome) => async (page) => {
  await requireHydrated(page);
  let got = "<none>";
  for (let i = 0; i < 60; i++) {
    got = await page.evaluate(
      () =>
        document
          .querySelector("#dbg-position-notice .dbgnotice")
          ?.getAttribute("data-landing") ?? "<none>",
    );
    if (got === outcome) return;
    await sleep(50);
  }
  throw new Error(`§6.0a: expected landing '${outcome}', the page resolved '${got}'`);
};

/** Post-condition for the one branch that is SILENT. */
const requireNoLanding = async (page) => {
  await requireHydrated(page);
  const n = await page.evaluate(
    () => document.querySelectorAll("#dbg-position-notice .dbgnotice").length,
  );
  if (n !== 0) {
    throw new Error(
      "§6.0a step 2 is the one branch that renders nothing, and this page " +
        "rendered a notice",
    );
  }
};

/** Post-condition for an engine-failure view, optionally after tripping the
 *  deadline. `needle` is a fragment of the sentence THIS fault produces, so
 *  the two deadline views cannot pass on each other's banner. */
const requireEngineFailure = ({ advanceClock = false, needle }) =>
  async (page) => {
    await requireHydrated(page);
    if (advanceClock) {
      await page.context().clock.runFor(ENGINE_DEADLINE_ADVANCE_MS);
    }
    await waitForText(page, "#dbg-engine-failure", needle, "engine failure");
    // One subject per image. These views open an exact-hit link precisely so
    // §6.0a says nothing here; a notice would mean the URL stopped being one.
    const stray = await page.evaluate(
      () => document.querySelector("#dbg-position-notice .dbgnotice")?.innerText ?? "",
    );
    if (stray.length > 0) {
      throw new Error(
        `an engine-failure capture also rendered a §6.0a notice (${JSON.stringify(stray.slice(0, 120))}) — ` +
          "the image would carry two unrelated subjects",
      );
    }
    // The clock advance can have started a face loading in the re-rendered
    // banner; do not screenshot mid-swap.
    await page.evaluate(() => document.fonts.ready.then(() => undefined)).catch(() => {});
  };

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
    // Also the synthetic half of the provenance pair: this route resolves
    // through `primaryChain`, which is the demo chain, so it is where the
    // neutral-tone banner is graded. Its `--testnet` and `--mainnet` siblings
    // below carry the affirmative-tone half.
    covers: ["chain-overview", "provenance.synthetic"],
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
    // Narrower again, and the old reason is now WRONG rather than merely
    // incomplete — corrected with VD.7. It said "the client ships no JavaScript
    // at all", which stopped being true when the hydration bundle landed and is
    // demonstrably not true of the tree the eight `hydrated: true` views below
    // are captured from: those pages carry the bundle, it runs, and §13's copy
    // affordances are upgraded in every one of their images.
    //
    // What is still missing is the ENGINE. This view's subject is the
    // transition — a pre-rendered frame taken over by a LIVE session, in place,
    // without the visitor seeing less at any point — and that needs the 18 MB
    // wasm the deploy fetches from another repository and this one deliberately
    // does not vendor. The harness will not stand in for it: `lib/engine-stubs
    // .mjs` supplies engines that FAIL, because a failure is a fact about the
    // environment and the sentence about it is the product's. An engine that
    // pretended to replay would put a fabricated session under a view whose
    // whole claim is that the session is real, which is the one thing a fixture
    // may never do.
    pendingReason:
      "the transaction route serves the session (`tx-detail--session`) and the " +
      "hydration bundle now runs over it (see the `hydrated: true` views, " +
      "captured from `client/dist-hydrated`), so what is missing is no longer " +
      "script — it is the ENGINE. This view's subject is the live takeover, and " +
      "the 18 MB replay wasm is published by another repository and not " +
      "vendored here. The capture harness stands in for engines that FAIL, " +
      "never for one that replays: a stub that pretended to step would file a " +
      "fabricated session under the name of a real one. Point a build at a " +
      "published engine (`just replay-engine`, or `-d:replayEngineBase=`) and " +
      "this view becomes capturable — at the cost of a capture whose bytes " +
      "depend on a third party's deploy",
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

  // ──────── §6.0a: where a shared link landed, and what it said (VD.7) ─────
  //
  // Five branches, five views, and the fifth is the SILENT one. Splitting it
  // out is not bookkeeping: §6.0a's whole rule is "every branch below (2) is
  // visible — the client never silently lands somewhere other than where the
  // link pointed", and "visible" is only a claim if the one branch that is
  // legitimately silent is also on the record. Without `--link-exact`, four
  // images show a notice and nothing shows that an exact hit does not.
  //
  // Each route's `c` and `a` are DERIVED from the published trace
  // (`lib/entities.mjs`), so a link that is meant to disagree with the witness
  // cannot decay into one that agrees after a reseed, and an anchor that is
  // meant not to resolve cannot decay into one that does. Each view then
  // asserts the branch it reached off `data-landing`, so an image can never be
  // filed under the wrong branch's name.
  {
    id: "debugger--link-exact",
    description:
      "§6.0a step 2 — the link's witness matches and its coordinate is honoured. The ONE branch that renders no notice, captured so that 'every other branch is visible' is a comparison and not an assertion",
    covers: ["debugger.link-landing"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "silent",
    route: positionRoute(readyTx, (tx) => ({
      t: DEBUG_TIME_COORDINATE_MID,
      c: witnessOf(tx),
      a: currentCallAnchorOf(tx),
    })),
    setup: requireNoLanding,
  },
  {
    id: "debugger--link-recovered-by-anchor",
    description:
      "§6.0a step 3 — the trace was regenerated, so the coordinate is not trusted and the link's anchor is used instead; the notice names the anchor kind and the reason",
    covers: ["debugger.link-landing"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "silent",
    route: positionRoute(readyTx, (tx) => ({
      t: DEBUG_TIME_COORDINATE_MID,
      c: staleWitnessOf(tx),
      a: currentCallAnchorOf(tx),
    })),
    setup: requireLanding("recoveredByAnchor"),
  },
  {
    id: "debugger--link-nearest-frame",
    description:
      "§6.0a step 4 — the anchor names a frame this trace does not have, so the nearest enclosing frame is shown and said. A BENIGN outcome: the link worked, approximately, and the page must not read as an error",
    covers: ["debugger.link-landing"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "silent",
    route: positionRoute(readyTx, (tx) => ({
      t: DEBUG_TIME_COORDINATE_MID,
      c: staleWitnessOf(tx),
      a: unresolvableChildAnchorOf(tx),
    })),
    setup: requireLanding("nearestEnclosingFrame"),
  },
  {
    id: "debugger--link-start-of-execution",
    description:
      "§6.0a step 5 — neither the coordinate nor the anchor survives, so the session opens at the start and the notice names WHICH of the four reasons applies",
    covers: ["debugger.link-landing"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "silent",
    // A `log:` anchor past the last event. `resolveAnchor` gives the two
    // consensus-recorded kinds no enclosing frame on purpose — "nothing
    // encloses a log index that does not exist" — so this is step 5 and not
    // step 4, which is the distinction the two views exist to keep apart.
    route: positionRoute(readyTx, (tx) => ({
      t: DEBUG_TIME_COORDINATE_MID,
      c: staleWitnessOf(tx),
      a: unresolvableLogAnchorOf(tx),
    })),
    setup: requireLanding("startOfExecution"),
  },
  {
    id: "debugger--link-not-replayable",
    description:
      "§6.0a step 1 — a link into a transaction with no replayable artifact. Terminal, and the only branch that renders on a page with no panes at all",
    covers: ["debugger.link-landing"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "silent",
    // `absentTx`, not `onDemandTx`. Step 1's sentence is "this execution is not
    // replayable" full stop, which is true of `absent` and is a half-truth
    // about a transaction whose trace can still be generated — and the
    // no-session page underneath the notice is the one with no action on it, so
    // the pair reads consistently. Whether it reads consistently is what the
    // block asks the reviewer.
    route: positionRoute(absentTx, (tx, ix) => ({
      t: DEBUG_TIME_COORDINATE_MID,
      // This transaction publishes no container, so it has no witness of its
      // own; the link carries a well-formed one from a trace that does exist,
      // which is what a shared link into a since-withdrawn artifact looks like.
      // Step 1 is reached before the witness is consulted at all — but a `t`
      // with no `c` is a link the grammar rejects (§6.0a), and photographing a
      // malformed link under this branch's name would test the parser rather
      // than the branch.
      c: witnessOf(readyTx(ix)),
      a: currentCallAnchorOf(readyTx(ix)),
    })),
    setup: requireLanding("noReplayableArtifact"),
  },

  // ──────── The replay engine will not run, said on the page (VD.7) ────────
  //
  // Three faults, three sentences, three views — and they are three views for
  // the reason the sentences are three strings. `hydrate.nim`: an engine that
  // never arrived and an engine that arrived and refused the container "are
  // different faults with different fixes, and a single sentence covering both
  // sent a real diagnosis down the wrong path for hours". A single view could
  // be answered by a single image and the distinction would be gradeable only
  // against itself.
  //
  // What the harness supplies is the ENGINE, never the sentence: see
  // `lib/engine-stubs.mjs`, and the `engine:` scenario each view names.
  {
    id: "debugger--engine-worker-missing",
    description:
      "The engine's worker script is not there — nothing is served at `/replay-engine/`, the module 404s, and the page says so within a second of load",
    covers: ["degraded.engine-unavailable"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "unreachable",
    // The state EVERY build of this repository is in until `just replay-engine`
    // copies 18 MB of another repository's output into `dist/` — so this is the
    // failure a first-time local preview actually meets, and it had never been
    // photographed.
    route: engineFailureRoute,
    setup: requireEngineFailure({ needle: "could not be loaded" }),
  },
  {
    id: "debugger--engine-never-loaded",
    description:
      "§8's deadline, first sentence — something answered at the engine's path but no engine ever did, so after 45 s the page stops implying one is coming",
    covers: ["degraded.engine-unavailable"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "silent",
    route: engineFailureRoute,
    setup: requireEngineFailure({ advanceClock: true, needle: "never loaded from" }),
  },
  {
    id: "debugger--engine-refused-container",
    description:
      "§8's deadline, second sentence — the engine is running and reachable and it will not open THIS container. The fault the shared sentence used to hide",
    covers: ["degraded.engine-unavailable"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    fullPage: false,
    hydrated: true,
    engine: "refusing",
    route: engineFailureRoute,
    setup: requireEngineFailure({ advanceClock: true, needle: "would not open" }),
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

  // ───────────────────── The real chains (VD.8) ──────────────────────────
  //
  // Every view above resolves through `ix.primaryChain` — `chains.sort()[0]`,
  // which is `aztec`, the SYNTHETIC chain. That was correct while the tree
  // published one chain. The 2026-08-31 regeneration published three and still
  // captured 232 images of `/aztec`, 48 site-level images and NOT ONE of
  // `/aztec-testnet` or `/aztec-mainnet` — while `check-coverage` reported
  // 67/67, because the inventory had no per-chain entry to be missing.
  //
  // These four views are the other arm. They are selected by the provenance the
  // GENERATION published, never by slug, because that is the rule the product
  // itself follows (`components/provenance.nim`: "keying the banner off the
  // chain's name would be a guess that survives exactly until someone renames a
  // chain"). A harness that selected by slug while the product selected by tree
  // would be able to disagree with it, silently, about which chain it had
  // photographed.
  {
    id: "chain-overview--testnet",
    description:
      "Chain overview on a REAL chain — the live-capture provenance banner, and a head that came from a node",
    covers: ["chain-overview", "provenance.live-capture"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${realChain(ix, TESTNET)}`,
  },
  {
    id: "chain-overview--mainnet",
    description:
      "Chain overview on the zero-trace real chain — every transaction in the window is below the node's pruning floor",
    covers: ["chain-overview", "provenance.live-capture"],
    register: "explorer",
    status: "ready",
    route: (ix) => `/${realChain(ix, MAINNET)}`,
  },
  {
    id: "tx-detail--mainnet-zero-trace",
    description:
      "Transaction on mainnet with no trace and none possible — 'Not observable', the published pruning reason, and no debug affordance",
    covers: ["tx-detail.absent", "provenance.live-capture"],
    register: "explorer",
    status: "pending",
    // NOT DELETED, AND NOT RE-POINTED. The deployed tree stopped publishing this
    // state: `static_export` ingests real chains at `IngestScope.isCurated`,
    // which publishes the contiguous block range in which EVERY transaction
    // opens a container — so a real chain no longer carries a transaction with
    // no trace, and `/aztec`, which recorded none, publishes 24 blocks and no
    // transactions at all. `zeroTraceTxOn` threw rather than resolving, which is
    // the harness working: assertion E refuses a ready view whose subject is
    // gone instead of letting it photograph something else.
    //
    // `pending` is the honest filing, and the alternatives were both worse.
    // DELETING it would drop `tx-detail.absent`-on-real-data from the inventory
    // silently and orphan a live review round's ledger entries. RE-POINTING it
    // at the synthetic chain would keep the id while making its expectation
    // block false: that block's whole subject is that the data is REAL — "the
    // same page on the synthetic chain would be a fixture choice rather than a
    // fact about a network" — and `tx-detail--absent` already photographs the
    // fixture's version.
    //
    // The state itself is untouched and still tested: an `isFull` ingest
    // publishes every pruned and refused transaction with the producer's own
    // words, and `test_chain_provenance` suites 2 and 8 grade both the sentence
    // and the scoping decision. What is pending is a SUBJECT on the deployed
    // tree, which returns the moment a curated real chain carries one.
    pendingReason:
      "the deployed tree publishes real chains curated to the window where every " +
      "transaction opens, so no real chain carries a trace-less transaction to " +
      "photograph; `isFull` still publishes the state and it is graded there",
    route: (ix) => {
      const slug = realChain(ix, MAINNET);
      return `/${slug}/tx/${zeroTraceTxOn(slug)(ix).hash}`;
    },
  },
  {
    id: "debugger--testnet",
    description:
      "A debugging session over REAL testnet chain data — the same panes, a live-capture banner, and a trace recorded from a node",
    covers: ["debugger", "provenance.live-capture"],
    register: "debugger",
    status: "ready",
    sizes: DESKTOP_SIZES,
    route: (ix) => {
      const slug = realChain(ix, TESTNET);
      return `/${slug}/tx/${tracedTxOn(slug)(ix).hash}/debug?t=${DEBUG_TIME_COORDINATE}`;
    },
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
