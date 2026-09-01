// VD.1 — the per-view expected-elements blocks.
//
// This is the machine-readable source of truth for the mandatory
// "What is Expected on the Screenshot" section of the review brief
// (Methodologies/visual-design-iteration.md §"The Reusable Design Brief" item 3).
//
//   expectations.mjs  →  render-brief.mjs  →  tools/visual-review-brief.md
//
// `check-brief.mjs` enforces both directions: every view in `views.mjs` has an
// entry here, every entry names a real view, and the rendered section in the
// brief is byte-identical to what this file produces. A view without a block
// fails `verify_brief_has_expectation_block_per_view`.
//
// ── Why the blocks are specific rather than templated ──────────────────────
//
// The whole value of this section is that it lets a reviewer distinguish "the
// design is bad" from "the screenshot captured the wrong state". A block that
// says "the page renders, with a header and some content" cannot do that for
// any page. So every block names the elements THIS view must carry and nobody
// else's — the columns of this table, the phase word in this banner, the
// specific sentence this degraded state is required to say.
//
// ── Field meanings ─────────────────────────────────────────────────────────
//
//   summary      One line: what this view is, so the reviewer knows what they
//                are looking at before they look.
//   spec         The clause in Page-Descriptions (or a sibling spec) that the
//                block is derived from. A block with no spec anchor is an
//                opinion, and opinions do not belong in the presence check.
//   register     `explorer` or `debugger` — selects the rubric.
//   mustShow     Present, recognisable, and not a placeholder. Any item absent
//                is a P1 and caps the rating at 4. This is the presence check.
//   mustNotShow  Anti-requirements. Present ⇒ P1. These exist because several
//                of this product's failure modes are additions rather than
//                omissions: an empty list where a statement was required, a
//                spinner where a named phase was required, a retry button on a
//                terminal state.
//   watchFor     Per-view stress points, judged AFTER the presence check.
//                These are P2-grade: the specific ways this view is known to
//                be able to look bad while containing everything it must.
//
// `inherits` pulls in a named shared backbone. It is used only where the spec
// itself states the shared requirement — §14.1a's "the page never degrades"
// means every trace-availability state genuinely must show the whole
// transaction. Every view that inherits also carries its own specific items;
// nothing in this file is backbone alone.

// ── Shared backbones, each traceable to a spec clause ──────────────────────

export const BACKBONES = {
  // Page-Descriptions §14.1a: "The page never degrades. Every one of these
  // states shows the complete transaction; what varies is whether a debugger
  // can be opened over it."
  "tx-page-intact": {
    spec: "Page-Descriptions §14.1a",
    items: [
      "The complete transaction page behind the state — hero with status and hash, the overview grid (from/to, value, fee, block and index, nonce, resource usage), and the raw chain-native payload. This state changes what can be done, never what is shown.",
      "The state's treatment is a region inside the page, not a replacement for it. If the transaction facts are gone and only a notice remains, that is the finding.",
      "The hero's Debug affordance is visibly resolved into this state — enabled, replaced by another action, or absent-with-a-reason — and not left as a generic enabled button that would lie about what happens on click.",
    ],
  },

  // Page-Descriptions §8: the explorer chrome collapses to a slim identity bar
  // and the transaction's facts survive that collapse via the metadata pane.
  //
  // The FIRST item changed on 2026-08-29. It used to require "a link back to
  // the transaction detail page", copied from §8's summary, which was written
  // before §7.0. §7.0 made `/{chain}/tx/{hash}` serve the session itself for a
  // `ready` or `divergent` trace — the two routes' BODIES are byte-identical —
  // so the "detail page" a back link would target no longer exists as a
  // distinct surface to go back TO, and `client/src/pages/debug.nim` retargeted
  // the bar's link to `chainUrl(s.chain)` in 809e99c for exactly that reason.
  //
  // Left as it was, the item made the view UNREVIEWABLE against the shipped
  // page: the L5 reviewer derived the removed requirement from it and filed the
  // same P1 in two consecutive rounds, at two themes. Cited by REPORT PATH,
  // because the ledger ids those two findings had (`debugger/wide/dark/L5/1`,
  // `debugger/wide/light/L5/1`) have since been reused by rounds vd8-r2,
  // vd9-r1 and vd9-r2 and now name entirely different findings:
  //
  //   * reviews/rounds/vd5-round4/debugger__wide__dark__L5.md — "No link back
  //     to the transaction detail page. The only navigational affordance is
  //     '← aztec', which is styled as a link and labelled with the chain",
  //     P1, rating capped at 4.
  //   * reviews/rounds/vd5-round5/debugger__wide__light__L5.md — the next
  //     round, the other theme: "The MUST SHOW 'link back to the transaction
  //     detail page' is absent. The bar's only link is `← aztec`, which
  //     targets the chain overview (client/src/pages/debug.nim:172, href =
  //     chainUrl(s.chain))", P1, rating 4.
  //
  // Both are expectation defects, not page defects. The item is not weakened:
  // the bar must still carry the
  // identity, must still carry a way OUT of the debugger register, and must
  // still not be the explorer header. Only the TARGET of that way out moved,
  // and the item now states §7.0's reason inline so it is not re-derived.
  "debugger-shell": {
    spec: "Page-Descriptions §8, §7.0, Debugger-Integration §3, Design-System §2",
    items: [
      "A slim identity bar across the top carrying the transaction identity (truncated hash, chain), a way OUT of the debugger register that lands on the CHAIN, and — where a session is open — the stepping controls, the position readout and the phase rail. Not the full explorer header. The exit targets the chain and NOT the transaction's own URL, because under Page-Descriptions §7.0 that URL IS this session — for a `ready` or `divergent` trace the two routes serve byte-identical bodies, so a link to the transaction would be a link to the page the visitor is already on. A missing exit is a P1; an exit that targets the chain is CORRECT and is not a finding.",
      "Product-register surface: dark by default, dense, continuous with the CodeTracer desktop app. An explorer-register light marketing surface here is a register error, which is a P1.",
      "Every pane region below the identity bar is a pane: no separate toolbar row, no explorer footer, no marketing chrome, no page-level scrollbar. The full-width bands this register admits are the ABNORMAL-STATE ones — a divergent or truncated trace, an unavailable replay engine, a link-landing notice — and they are not panes and must not be judged as ones. THERE IS NO PROVENANCE BAND HERE any more, deliberately: provenance moved into the transaction pane as a row (see the next item), because a band interrupts and \"this data is real\" is not an interruption. A provenance band reappearing above the identity bar is now itself the finding.",
      "THE PROVENANCE MARKER, which in this register is the FIRST ROW of the transaction pane — labelled `Data`, carrying a toned badge naming what this data is, and the producer's own sentences beneath it. `debugLayout` drops the nav and the footer, so the pane is the only place a reader can learn whose data they are looking at — and this is the register where they are most likely to forget, because a trace recorded from a real node and a Noir program published under a synthetic hash step identically here. §7.1 puts that pane on the page in EVERY state, so the row is on every debug page including the ones where no session opens. Grade it as CONTENT, not decoration: missing, mislabelled, or a tone that contradicts the label is a P1. It used to be a full-width band above the identity bar and was moved on 2026-08-31 because the band spent ~190px of a 1080px viewport — roughly 17% — and both adversarial reviewers of the previous round independently named that cost the page's single weakest element. Judging whether the row is now TOO quiet for a claim this important is exactly the fair question to raise.",
    ],
  },

  // The same register requirements, minus everything a ONE-PANE capture cannot
  // contain. Several debugger views carry a `clip:` in views.mjs, so the image
  // a reviewer is handed is a single pane — not the viewport. `debugger-shell`
  // requires the identity bar and "every pane region BELOW the identity bar",
  // and both are out of frame by construction in such a capture: the
  // expectation can never be satisfied, however good the page is.
  //
  // That is not hypothetical. The L4 review of `debugger--call-trace` at
  // wide/dark reported `expectedElements: MISSING — the debugger-shell identity
  // bar` at P1, rating 4, and correctly diagnosed it as a harness mismatch
  // rather than a build defect: finding `debugger--call-trace/wide/dark/L4/1`,
  // in reviews/rounds/vd5-round5/debugger--call-trace__wide__dark__L4.md.
  //
  // That finding is cited by REPORT PATH and not as `ledger@…`, deliberately:
  // the report is HELD OUT of reviews/ledger.json pending this fix. It is 1 of
  // only 2 lenses captured for the view, and its P1 is against the expectation
  // this backbone replaces, so it will be re-run against the corrected block
  // before it is ingested. A `ledger@` pin here would not resolve, and B4's
  // whole point is that a citation which does not resolve is a comment that
  // reads as evidence and is not.
  //
  // A clipped capture is scoped to one pane, and the identity bar's absence
  // from such a frame is NOT a finding.
  //
  // What survives the clip is the register (a pane is rendered in the product
  // register whether or not the bar is in shot) and the pane's own chrome. What
  // the pane must CONTAIN is each view's own must-show list, which is where the
  // specificity lives anyway. `check-brief.mjs` check F refuses any view with a
  // `clip:` that still inherits `debugger-shell`.
  "debugger-pane": {
    spec: "Page-Descriptions §8, §7.1, Debugger-Integration §3, Design-System §2",
    items: [
      "Product-register surface: dark by default, dense, continuous with the CodeTracer desktop app. An explorer-register light marketing surface here is a register error, which is a P1. This survives the clip — a pane is drawn in the product register whether or not the identity bar is in shot.",
      "What is in frame is ONE self-contained region of the session's own chrome, with its own boundary and its own content. Where that region is a pane it carries the same pane chrome as the session's other panes, its title included (§7.1's 'the same pane chrome rather than a bespoke surface'); where the clip is the identity bar it is the slim bar itself, and not the full explorer header. Content bleeding past a boundary that is not drawn, or a pane with content and no title, is the finding.",
      "The region is populated, not blank and not a placeholder. A pane with nothing in it must say why rather than sit empty.",
      "This capture is CLIPPED to one pane. The identity bar, the sibling panes and the rest of the viewport are out of frame by construction — their absence from this image is not a finding, and nothing here may be reported as missing on the grounds that the surrounding session is not visible.",
    ],
  },

  // The explorer shell — the chrome `components/layout.pageLayout` puts around
  // every explorer page, and the one thing in this file that is the SAME object
  // on 47 routes rather than a property of one of them.
  //
  // It exists because the provenance strip shipped ungraded. The footer gained
  // "Built with <heart> by Metacraft Labs. Powered by CodeTracer <mark>" and a
  // GitHub mark linking the repository, in two inline-SVG marks taken from two
  // different repositories — and no block in this file named any of it, so six
  // reviewers per view could report `expectedElements: present` on an image in
  // which the strip was missing, unthemed, or drawn with a mark that had not
  // survived the token layer. A presence check that cannot see an element is
  // not evidence about that element.
  //
  // The rule is mechanical rather than per-view: an explorer-register view with
  // no `clip:` photographs the whole shell, so it inherits this; one WITH a
  // `clip:` photographs a region and must not (check-brief F, which lists this
  // key in VIEWPORT_BACKBONES for exactly that reason); and the debugger
  // register inherits `debugger-shell`, whose third item already requires the
  // opposite — "no explorer footer" — because `debugLayout` renders none.
  // check-brief G enforces the pairing, so a view that later loses its `clip:`
  // or a route that later lands cannot quietly skip it.
  "site-chrome": {
    spec: "Page-Descriptions §2, §12, Design-System §2",
    items: [
      "The site footer, closing the page: the product line, the About / Chains / Privacy & settings links, and the data disclosure — \"No account, no tracking\", plus a statement that each chain says on its own pages whether its data is synthetic (`blocktracer-demo-gen`) or captured from a network. It ENDS the page — on a page shorter than the viewport it sits at the bottom of the viewport, not partway down it with canvas underneath. The disclosure must NOT assert that this page is demo data: it is rendered on real-chain pages too, and until 2026-08-31 it claimed the opposite of the provenance marker on the same page on 632 of the tree's 819 pages.",
      "The provenance strip, as one readable sentence plus one link: 'Built with <heart> by Metacraft Labs. Powered by CodeTracer <mark>', and a GitHub mark labelled as the source of THIS repository. Every mark is drawn — a missing glyph, a tofu box, an emoji-presentation heart, or a mark that is invisible against the surface it sits on is a P1, and in the dark theme as much as the light one, because all three marks take their colour from the text around them.",
      "The fixed site nav, with the brand and the resolver field, above a body that does not run under it.",
      "THE PROVENANCE MARKER, on a chain-scoped page: a badge naming what this data IS — `Synthetic demo data` in the neutral tone, or `Real Aztec <network> data` in the affirmative tone. It is the only thing on the page that tells a reader whether the hashes in front of them exist on any network, so it is graded as CONTENT and not as decoration: missing, naming the wrong chain, carrying a tone that contradicts its label, or unreadable against its surface in either theme is a P1. WHICH FORM IT TAKES DEPENDS ON THE PAGE, and all three are correct — revised 2026-08-31, when a band on every page was replaced by a band only where something is abnormal: (a) a full-width `.notice` BAND with the producer's sentences, on a page whose data is SYNTHETIC and which has no facts grid of its own — a block, an address, a list, a chain overview; (b) a compact `.provchip` badge above the breadcrumb, on those same pages when the data is REAL; (c) a `Data` ROW at the top of the transaction facts grid, on any page that has one, carrying the badge and the producer's sentences. Exactly ONE of the three is present on any page — two markers is a finding, and so is none. Do not report the absence of a BAND on a real-chain page as missing provenance: that is the change, and the chip or the row is where to look.",
      "On a SITE-LEVEL page — `/about`, `/settings`, `/search`, `/chains`, 404 — the provenance marker is correctly ABSENT in ALL THREE of its forms, because those pages show no chain's data and the component returns nothing rather than inventing a claim on a producer's behalf. Its absence there is not a finding, and reporting it as one is the error this item exists to prevent in the other direction.",
    ],
  },

  // Page-Descriptions §14.1: "Phase, not percentage."
  "generation-job": {
    spec: "Page-Descriptions §14.1",
    items: [
      "The named phase as a word the user can read — not a percentage, and not an indeterminate spinner on its own.",
      "Elapsed time, and a coarse estimate explicitly labelled as an estimate where one is shown.",
      "A statement of what the user gets on completion: whether the resulting trace is retained or windowed, and for how long.",
    ],
  },
};

// ── The blocks ─────────────────────────────────────────────────────────────

export const EXPECTATIONS = [
  // ══════════════════════ Explorer register — entry ══════════════════════

  {
    id: "home",
    summary:
      "The home page: one screen that explains the product and gets a hash into the search box.",
    spec: "Page-Descriptions §2",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A hero whose headline claims DEPTH — that this is the deepest view into every transaction — supported by one line naming what that depth is: stepping and rewinding instructions, the whole call trace at a glance, and tracing a value to its origin, across many chains, VMs and languages. A headline whose main claim is time-travel alone is WRONG: stepping backwards is table stakes in this category, and the positioning is depth plus breadth. One headline and one supporting line, not a paragraph and not a tagline fragment.",
      "A search field, visibly the primary input of the page and visibly focused (focus ring rendered — it is focused on load).",
      "A chain strip listing supported chains, each with a debug-tier badge (T0–T2). Chain names must be legible; a row of unlabelled logos is not the chain strip.",
      "A 'how it works' explanation in three parts — we index the chain · we replay every transaction · you step in both directions — readable as three parallel items, not one run of prose.",
      "A trust strip stating: no account, no ads, no tracking, complete history, no record caps; with a link to the privacy summary.",
      "A region reserved for the embedded live demo (the pre-baked debugging session), even if the session itself is captured separately as `home--live-demo`.",
    ],
    mustNotShow: [
      "A price widget, a live ticker or an activity heat-map — Page-Descriptions §2 excludes these three by name — or a market-cap figure, which belongs to the same market-data register the section rules out. One appearing means the wrong page was captured or the wrong spec was implemented.",
      "A sign-in wall, a cookie banner, or a newsletter modal over the hero.",
    ],
    watchFor: [
      "Hero-to-search vertical rhythm: the search field is the page's call to action and must not be pushed below the fold at 1024×768.",
      "The chain strip at realistic chain counts — badges must stay aligned and the strip must not wrap into a ragged second row at laptop width.",
      "Whether the page reads as marketing-grade (generous whitespace, restraint, near-black type on light canvas per Design-System §1) rather than as a dashboard.",
    ],
  },

  {
    id: "home--live-demo",
    summary:
      "The embedded, pre-baked debugging session on the home page, reviewed as its own view — a product-register element inside a web-register page.",
    spec: "Page-Descriptions §2 (Live demo), Design-System §2",
    register: "debugger",
    mustShow: [
      "An actual debugger surface — source with a current-line indicator, and at least one of the call trace / event log / state panes — not a static image, not a video player with a play button, and not a screenshot in a browser frame.",
      "Evidence that it is already stepping: a position marker somewhere in the trace, so the demo is mid-session rather than at a cold start.",
      "An 'open full session' affordance leading out of the embed.",
      "The embed is visibly product register (dark, dense) and visibly bounded — a contained panel, so the register change reads as intentional rather than as the page breaking.",
    ],
    mustNotShow: [
      "A play/pause overlay, a video scrubber, or a poster frame — the spec says real debugger, not a video, and a video is the single most likely wrong implementation here.",
      "A loading skeleton: the session is pre-baked, so a skeleton in a deterministic capture means it never loaded.",
    ],
    watchFor: [
      "The seam between the light marketing page and the dark embed — Design-System §2 makes this crossing deliberate, so it must look designed, not like a missing background.",
      "Legibility of the debugger's small text when the embed is scaled down to fit a marketing section.",
    ],
  },

  {
    id: "chains-index",
    summary:
      "The honest capability inventory — a table of every chain in the registry, generated from the registry so it cannot drift.",
    spec: "Page-Descriptions §3",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A table whose every cell is a REGISTRY fact — chain slug, recorder id and version, trace schema, coverage mode, block and transaction counters, and freshness against the tip. A placeholder or a hand-written cell means the page was not generated from the registry, which is §3's one structural requirement.",
      "Coverage rendered in its own vocabulary — `eager` / `selective` / `on demand` — because that is what the Debug affordance will do on first click.",
      "Freshness as a state (at tip / behind tip) WITH the head and finalized heights beside it, so the claim is checkable rather than asserted.",
      "A statement, below the table, naming the two columns §3 asks for that have no published source yet — the debug tier and historical reach — and what would carry them. §3's table has eight columns; six are in the tree and this page must not let a reader mistake the other two for columns this chain lacks.",
      "The chain slug as a link into the chain overview: this page is the entry point a protocol team lands on.",
    ],
    mustNotShow: [
      "A 'Requires' or 'Supported' boolean column that flattens the coverage vocabulary back into yes/no.",
      "A debug tier badge or a historical-reach value INVENTED from the recorder pin. This is the one page in the product where a confident wrong answer costs the most, and a plausible T1 badge with no source behind it is exactly that.",
      "Placeholder chain rows (`Chain 1`, `example-chain`) — this page is registry-generated and placeholders mean it is not.",
    ],
    watchFor: [
      "A seven-column table with one row: check the table does not read as an empty frame, and that the single row is not lost against the header.",
      "The freshness cell carries a badge and a run of small text; check the two are grouped as one fact rather than reading as two columns that ran together.",
      "The absent-columns statement is prose under a data table — check it reads as a note about the table rather than as a footer of the page.",
    ],
  },

  {
    id: "chain-overview",
    summary:
      "A single chain's landing page: what it is, where its head is, and what has recently happened on it.",
    spec: "Page-Descriptions §4",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A head/finalized/blocks/transactions/coverage stat row, each figure labelled — the registry and pointer facts a visitor needs before reading either list.",
      "Latest blocks — the newest ~10 with per-block transaction counts and a finality badge per row.",
      "Latest transactions — the shared transactions table, with the Debug affordance as the FIRST column of every row (rule 1).",
      "A chain-notes section naming the recorder pinned for this chain, the trace schema, the coverage mode in words, and the generation every read on the page was pinned to.",
    ],
    mustNotShow: [
      "An empty 'latest blocks' or 'latest transactions' region. Rule 2 — nothing renders as an empty list; either data or a statement of why not.",
      "A Debug action that is present only at the end of a row that has scrolled out of view.",
      "A staleness notice on a chain whose published summary says it is at the tip — the notice is resolved from `summary.json`, and one appearing here would mean it is being inferred.",
    ],
    watchFor: [
      "Two lists of different lengths one above the other — check the section rhythm separates them more than the row rhythm separates their rows.",
      "The stat row is the densest text on an otherwise spacious page and is the most likely place for the explorer rubric's whitespace discipline to break down.",
      "The chain-notes grid repeats facts from the stat row in a different presentation; check that reads as detail rather than as duplication.",
    ],
  },

  {
    id: "chain-overview--stale",
    summary:
      "Chain overview when the pipeline is behind the chain tip — the staleness notice.",
    spec: "Page-Descriptions §4 (Degraded), §14 row 1",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A staleness notice that names HOW FAR BEHIND the tip the chain is — a concrete lag (blocks or duration), not the word 'stale' on its own.",
      "The complete chain overview still rendered beneath or around it: header, head, latest blocks, latest transactions. Published pages keep working; only new blocks are missing.",
      "Wording that makes clear the existing pages are unaffected, so a visitor does not read the notice as 'this chain is down'.",
    ],
    mustNotShow: [
      "An error treatment — red, an alert icon, a failure word. This is a freshness fact, not a fault, and dressing it as an error is a P1 tone failure.",
      "The page replaced by the notice.",
    ],
    watchFor: [
      "The notice's weight relative to the page: it must be noticed without dominating, which is exactly the case where a banner is usually either invisible or shouting.",
      "This view is also the canary's chart/graph rendering path (per-block resource bars, Page-Descriptions §5.1) — check the bars render as bars, with a consistent baseline and scale.",
    ],
  },

  {
    id: "blocks-list",
    summary: "The block list — descending from head, cursor-paginated by block number.",
    spec: "Page-Descriptions §5.1, Static-Site-Architecture §2.2",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Five columns headed and populated: height (linked to the block) · hash · transaction count · finality badge · parent.",
      "A finality badge per row, derived from the finalized height the chain pointer publishes, visually distinct from the other columns.",
      "Rows in descending height order, with the newest at the top.",
      "A cursor pager: a statement of which block range this page covers, and an 'Older' control where an older page exists. NO page numbers — §2.2 rules out ordinal pagination outright, so a numbered pager here is a P1 against the data model, not a styling choice.",
      "A statement naming the three columns §5.1 asks for that have no published source — age, resource usage with a bar, and producer — and that each is a pipeline field rather than a view. A reader must be able to tell 'not published' from 'this chain has none'.",
    ],
    mustNotShow: [
      "A resource-usage bar, an age, or a producer VALUE. There is no timestamp, no per-block usage aggregate and no consensus-role field in the published block object, so any of the three appearing means it was derived from the height — a fabricated fact on the product's most scannable surface.",
      "Numbered pagination, a page-size selector, or an offset in the URL.",
      "Numeric columns left-aligned or centre-aligned — heights and counts are numeric and must be right-aligned or tabular-figure aligned.",
      "A link on the parent of the oldest block, whose page this generation does not hold.",
    ],
    watchFor: [
      "Hash truncation: check that the truncation is consistent down the column and that the visible prefix/suffix is enough to distinguish adjacent rows.",
      "Tabular figures — with proportional digits, a column of block heights visibly ripples. This is the highest-value place in the product to check it.",
      "The pager sits under the table and carries prose plus controls; check it reads as part of the table's group rather than as a new section.",
    ],
  },

  {
    id: "blocks-list--row-expanded",
    summary:
      "A block list row expanded to reveal that block's transaction hashes with per-row Debug actions.",
    spec: "Page-Descriptions §5.1 (row expansion)",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Exactly one row visibly in an expanded state, with an open/closed disclosure indicator distinguishing it from its neighbours.",
      "The expanded region listing that block's transaction hashes.",
      "A Debug action on every transaction row inside the expansion — rule 1 applies inside the expansion as much as outside it.",
      "The surrounding collapsed rows still legible and still aligned to the same columns; the expansion must not shift the table's column grid.",
    ],
    mustNotShow: [
      "An expansion that duplicates the full transactions table's ten columns — this is a nested reveal, and reproducing the whole table inside a row is the failure mode.",
      "An expanded region with no visual containment, so it reads as loose rows appended to the table.",
    ],
    watchFor: [
      "The left indent or rule that ties the expansion to its parent row, and whether it survives at tablet width.",
      "Whether the expanded region's background level is a distinct surface step or the same colour as the table body, which would make the expansion invisible.",
    ],
  },

  {
    id: "block-detail",
    summary: "A single block: its header facts, its transactions, and its neighbours.",
    spec: "Page-Descriptions §5.2",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A header carrying the block number and a finality badge, above a fact grid with chain, full hash, height, parent (linked), finality and transaction count.",
      "Previous / next block navigation, both controls present, with a sentence stating where in the chain this block is.",
      "The shared transactions table filtered to this block, with Debug as its first column.",
      "A statement naming the family-extras zone §5.2 specifies (EVM base fee and blob gas, Move checkpoint and epoch, Solana slot and leader) and the field that would carry it — the published block object has no chain-native payload, unlike a transaction, and the absence must read as 'not published' rather than 'this family has none'.",
    ],
    mustNotShow: [
      "EVM-shaped labels on a non-EVM chain (a 'gas price' row on Solana), which would mean the family adapter was bypassed for a template.",
      "A timestamp, an age, a size or a producer — none is in the published block object, and each appearing would be a fabricated fact.",
      "An empty transactions region for a block that has transactions.",
    ],
    watchFor: [
      "The fact grid carries a 42-character hash as a value; check the label/value pairing survives it at every column width.",
      "Parent link and prev/next are three navigation affordances that mean similar things — check they are not three different visual treatments.",
      "The finality badge appears twice, beside the title and in the grid; check that reads as emphasis rather than as an inconsistency.",
    ],
  },

  {
    id: "block-detail--genesis-edge",
    summary:
      "Block detail at the oldest block this generation indexes — the boundary case where 'previous' has nowhere to go.",
    spec: "Page-Descriptions §5.2 (Navigation: disabled at genesis and head)",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The previous/next navigation with one direction VISIBLY DISABLED — the whole point of this view. A disabled control that looks identical to an enabled one is a P1.",
      "The disabled control still present rather than removed, so the navigation's shape does not change between blocks.",
      "A sentence naming WHICH edge this is: the oldest block this GENERATION indexes, not genesis. The generation's floor is a fact about this tree; genesis is a claim about the chain, and the tree does not know it.",
      "The parent hash still shown IN FULL, with no link on it and a statement that its page is below this generation's floor — the identifier is the chain's and the page is this tree's.",
      "The full block detail otherwise: header fact grid and the transactions table.",
    ],
    mustNotShow: [
      "Both controls enabled.",
      "A link on the parent hash. It resolves to no page in this tree, and a published explorer linking to a page it never wrote is the one failure it cannot explain away.",
      "The word 'genesis' presented as a fact about the chain.",
      "The disabled control rendered only as a colour change too subtle to read at a glance — disabled must be legible as a state, not inferred.",
    ],
    watchFor: [
      "The disabled treatment against the contrast floor: 'disabled' must not mean 'unreadable', and this is the view where that trade-off is visible.",
      "Whether the same disabled treatment is used here as on every other disabled control in the product (Design-System §2: shared primitives are shared).",
      "The unlinked parent hash sits in a grid where every other identifier of its kind IS a link; check the difference is legible without hovering.",
    ],
  },

  {
    id: "txs-list",
    summary:
      "Recent transactions — the shared TransactionsTable at full width, the densest surface in the explorer register.",
    spec: "Page-Descriptions §6",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Eight columns, in order, headed: Debug · Tx hash · Block · From · To/target · Method · Fee · Status.",
      "Debug as the FIRST column and always visible — not an icon at the end of the row (Page-Descriptions §6 states this explicitly). It must remain visible when the table scrolls horizontally.",
      "The Debug cell carrying an ACTION where the trace licenses one and a STATED REASON where it does not — and never a disabled control. A row whose execution is structurally unobservable gets a labelled state, not a greyed button.",
      "From and To rendered as address chips that LINK to the address page, and the Block cell linking to the block detail.",
      "The fee rendered from the transaction's cost VECTOR — every dimension, not the first one alone.",
      "A cursor pager stating which block range the page covers, with no page numbers.",
      "A statement naming the two §6 behaviours that need script and do not have it — the column picker, and sorting reverted rows to the top — and that reverted rows are ALREADY visually distinct, which is the half that works without script.",
    ],
    mustNotShow: [
      "A CSV export control. Page-Descriptions §6 excludes it by name in v1.",
      "An Age or a Value column. Neither has a published source — the block object carries no timestamp and the transaction schema carries no native value — so either appearing would be a fabricated fact in a table people scan.",
      "A sort control that does nothing, or a column picker that does not open. A control that cannot succeed is one this product does not ship.",
      "Horizontal scrolling of the page body — the table may scroll inside its own container, the page may not.",
    ],
    watchFor: [
      "Eight columns at 1440 px: check what gives, whether Debug and Status keep their width, and whether Hash/From/To truncate at sensible boundaries.",
      "Three adjacent monospace-ish columns (hash, from, to) — check they are distinguishable by more than position.",
      "The sticky Debug column against a scrolled table: check its background covers the columns passing under it in BOTH themes, with no bleed-through.",
      "The demo tree has no reverted transaction, so the reverted row treatment cannot be judged from this image. Say so rather than grading its absence — the treatment is exercised by `components/tables` and is blocked on demo data.",
    ],
  },

  {
    id: "txs-list--cards",
    summary:
      "The transactions table collapsed to stacked cards below 900 px, with Debug and status retained.",
    spec: "Page-Descriptions §6, §13",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Stacked cards, one per transaction — not a table with a horizontal scrollbar, which is the failure this view exists to rule out.",
      "The Debug action LEADING each card at full width, so the primary action is the first thing in the card rather than a labelled row among others (§13: the primary action is retained).",
      "The status, including its badge, present on every card.",
      "Every other cell carrying its column name as a label, so a value is never orphaned from what it means once the header row is gone.",
    ],
    mustNotShow: [
      "A horizontally scrolling table.",
      "A card that is just a re-flowed row of label:value pairs with no hierarchy — the collapse is a redesign, not a rotation.",
      "Any element extending past the viewport edge at 375 px.",
      "A visible column header row.",
    ],
    watchFor: [
      "Long hashes and addresses at 375 px — the single most likely source of horizontal overflow in the product.",
      "Card-to-card spacing versus intra-card spacing: if they are equal, the cards read as one list rather than as discrete records.",
      "Whether the Debug action clears the touch-target minimum, and whether the labelled rows below it stay legible at the label size.",
    ],
  },

  // ══════════════════ Explorer register — transaction page ═══════════════

  {
    id: "tx-detail",
    summary:
      "The transaction page for a trace that opens no session — §7.0's second and third rows. The most important page in the product for a transaction the debugger cannot open, and the one a competitor comparison lands on.",
    spec: "Page-Descriptions §7.0, §7.2",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Hero: status with decoded revert reason if any, the full hash with a copy affordance, finality badge, and — on the on-demand path — Generate trace as the PRIMARY button, visually the strongest control on the page.",
      "The trace's state named beside that action, and a note explaining that state in words.",
      // AGE, and why it is not in the line above.
      //
      // §7.2 section 1 asks for it and this expectation demanded it flatly,
      // which made it an expectation no page this product can build could ever
      // satisfy. There is no timestamp at any layer: `TransactionFacts` has no
      // field for one, `BlockDetail` has none so it cannot be borrowed from the
      // block, and the txstate overlay has none. That is not a gap in the
      // synthetic fixture — the REAL Aztec mainnet objects in this tree carry
      // `height`, `parentHash` and a transaction list and no time of any kind.
      //
      // The only way to turn the flat demand green would be to derive an age
      // from the block height, which is the one thing `pages/blocklist.nim`
      // says in as many words that this product does not do: "Nothing here is
      // derived from the height to stand in for one." An expectation whose only
      // satisfying implementation is a fabrication is an expectation that is
      // wrong, and it is being changed here — on its own, with the reason
      // stated — rather than folded into the commit that fixed the page.
      //
      // What replaces it is not weaker. It still fails a page that omits age in
      // silence, which is what `tx-detail/wide/light` was doing and what all
      // six of vd8-r3's reviewers filed: the page ran hero → hash → trace card
      // with nothing said about time at all. Rule 2 admits data or a statement
      // and nothing else, so the statement is now what is demanded where the
      // data cannot exist, and a reviewer who finds neither still reports the
      // element missing.
      "Age: either the transaction's age or timestamp, or — where the tree publishes no timestamp for this chain — a labelled statement saying so, in the same voice §5.1's block table uses for its three sourceless columns. An age silently absent is a failure of this element; an age derived from the block height would be a worse one.",
      "Overview grid: from/to, value, fee breakdown, block and index, nonce, resource limits and usage, transaction type — each labelled.",
      "A decoded-input section with the function/entry point and its parameters, or raw bytes with a 'supply an ABI' action when the selector is unknown.",
      "An events/logs section.",
      "An internal-calls section.",
      "A state-changes section.",
      "A raw section carrying the chain-native transaction and receipt JSON verbatim.",
      "Where a section's data comes from the trace and no trace exists, the single specified line — 'Internal calls and state changes come from the execution trace.' — beside the Debug action that requests it, rather than an empty panel.",
    ],
    mustNotShow: [
      "An empty panel for any section. Rule 2 admits data or a statement, never nothing.",
      "A Debug button. §7.0: 'a button that opens the debugger is a link to the primary action, not the primary action' — and this page is the shape served when there is no session to open, so a Debug affordance here could only lead somewhere that says no.",
      "A disabled control standing in for an absent one. `absent` and `unsupported` get 'no debugger, and no pretence of one'; a greyed button still occupies the primary action's position.",
      "Any section rendered as a bare 'coming soon' with no explanation of what would appear there.",
    ],
    watchFor: [
      "Eight sections in one scroll: check the section-heading treatment is strong enough to navigate by, and that the eye can find the hero → action → overview path without reading.",
      "The overview grid's label column against its value column — mixed proportional labels and monospace values are the classic misalignment here.",
      "The raw JSON block: it is the only preformatted region on the page and will dominate if its surface, size and containment are not deliberately handled.",
      "The revert reason if present — it is prose inside a hero of identifiers and must not be styled as another identifier.",
    ],
  },

  {
    id: "tx-detail--session",
    summary:
      "The transaction's own URL landing in the debugging interface — §7.0's central claim, that arriving at a transaction with a trace means arriving in its execution.",
    spec: "Page-Descriptions §7.0, §7.1",
    register: "debugger",
    mustShow: [
      "A debugging session occupying the viewport at `/{chain}/tx/{hash}` — source with a current line, the call trace, the values, and the stepping controls. This URL, not `/debug`.",
      "The transaction's facts as a PANE beside the debugger's own panes (§7.1) — status and revert reason, block, finality, roles, cost, and the execution list — with the same pane chrome as every other pane. (Not a dismiss control: this route has no JavaScript, and VD.5 removed the one that could not be honoured. §7.1's 'dismissible and restorable' is the hydrated view's expectation, not this one's.)",
      "The decoded input and the chain-native payload inside that pane. §7.1 makes §7.2 the definition of this metadata, so a fact that was on the page before must be in the pane now.",
      "The honest loading line: what is being waited for, how large it is, and the named phase — the engine has not been fetched, and the page says so rather than implying the toolbar can step.",
      "The stepping controls rendered VISIBLY inert, because no replay engine has loaded.",
    ],
    mustNotShow: [
      "A Debug button, or any link to `/debug`. The visitor is already in the session; a button to it would be the waiting room this view exists to prove is gone.",
      "An empty or skeleton debugger. The panes are populated from published data before any engine loads; grey boxes shaped like content would be the failure §7.0 rules out with 'no state renders less than the pre-hydration page'.",
      "The transaction's facts reduced to an identity bar. §7.1: 'An identity bar is too little.'",
      "Enabled-looking stepping controls. Nothing can move time yet, and a control that looks live would lie on the first click.",
    ],
    watchFor: [
      "This is a `noindex,follow` page a crawler is served and a visitor lands on cold. Judge it as an ARRIVAL, not as a session someone navigated into: is it legible without the context of having clicked Debug?",
      "The metadata pane against the debugger's panes — it carries prose, a definition list, a code block and a badge set, and it has to read as one of the panes rather than as an explorer page pasted into a slot.",
      "The raw chain-native payload inside a pane body that already scrolls: check it is contained rather than driving the pane's own scroll length.",
      "Whether anything on this surface still reads as 'a transaction page with a debugger on it' rather than 'the debugger, with the transaction's facts in it'.",
    ],
  },

  {
    id: "tx-detail--dense",
    summary:
      "The metadata page at the largest published payload — the density case the whole campaign exists to catch. Its subject is the demo tree's second traceless transaction (generator txH), added on 2026-08-30 for this view: five roles, five cost rows across five named resources, and a raw payload of a selector plus sixteen ABI words. Until then this view was pending, because §7.0 serves the metadata page only where there is no session and the tree held exactly one such transaction — `tx-detail`'s own subject.",
    spec: "Page-Descriptions §7.2, VD.4 verify_transaction_page_holds_at_extreme_content",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Everything the `tx-detail` block requires, at the fixture's largest payload.",
      "A visibly long content region — five roles, five cost rows and a raw payload of roughly a kilobyte — so the reviewer can confirm this is genuinely the dense case and not the same content as `tx-detail`, whose subject carries one role, one cost row and a `0x` payload.",
      "The roles list reading as a LIST of distinct parties: fee payer, sender, authwit provider, sequencer and portal contract are five different addresses and five different jobs, and a page that has only ever rendered one role has never been asked whether its role treatment scales.",
      "The cost vector with its units and tokens intact across five rows whose magnitudes span three orders of magnitude — Data-Contract's `Cost` is a vector and this is the transaction that makes that visible.",
      "Section boundaries still legible after the long regions, so the page's structure survives its own volume.",
    ],
    mustNotShow: [
      "Any content truncated with no affordance to see the rest.",
      "Horizontal page scroll caused by a long identifier or a wide raw payload line.",
      "Hierarchy collapse — where every section heading has been buried far enough apart that the page reads as one undifferentiated column.",
    ],
    watchFor: [
      "This is the view where overflow, truncation and density collapse actually appear. Report the specific element and the specific edge, with a location.",
      "Long unbroken hex strings in the raw section: check the wrapping strategy, and whether it breaks mid-token in a way that makes copying wrong.",
      "Whether the page's total length has passed the point where the Debug affordance is unreachable without scrolling back up — the primary action must remain findable.",
    ],
  },

  {
    id: "tx-detail--absent",
    summary:
      "§7.0's third row, first half: a transaction whose execution publishes no call structure at all. There is nothing to record, and there never will be. Its subject is the demo tree's end-to-end private Aztec transaction (generator txI), published on 2026-08-30 for this view — before it, `txWithAvailability(\"absent\")` threw and this state had never been rendered by anything.",
    spec: "Page-Descriptions §7.0 (row 3), §14.1a",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The trace's state as a BADGE and the reason as a SENTENCE, together, in the position the primary action occupies on the on-demand page — so the eye lands on an answer where it expects a control.",
      "A reason that says the absence is structural: the execution publishes no call structure, so there is nothing a recorder could have captured. 'No trace available' would be true and would not be this state.",
      "The internal-calls and state-changes sections stating that they are empty PERMANENTLY rather than yet. §14.1a: \"'Not now' and 'not ever' are different states.\"",
      "The transaction itself completely intact — this transaction succeeded, and the page must not read as though something went wrong with it.",
    ],
    mustNotShow: [
      "A control of ANY kind for the trace — including a disabled one, a greyed one, or one with a tooltip. §7.0 gives this row 'no debugger, and no pretence of one', and `pages/tx.nim` states why a disabled button is still a pretence: it occupies the primary action's position and invites the click it will refuse. A control here is a P1.",
      "'Yet', 'not available', 'coming soon', or any other wording that implies a wait. This state is terminal.",
      "A danger or error treatment. Nothing failed.",
      "Wording identical to `tx-detail--unsupported`'s. If the two pages read the same, that is the finding this pair exists to produce.",
    ],
    watchFor: [
      "Whether the badge-plus-sentence group holds the hero's weight now that no button anchors it. This is the layout most likely to look unfinished rather than deliberate, and the deliberateness is the whole design.",
      "Tone: read the page as a visitor who came here expecting to debug. Does it read as a refusal, or as an explanation of how this chain works?",
      "The badge tone: `absent` and `unsupported` both resolve to `muted` in `viewutil.availabilityClass`, so colour cannot be carrying the difference between them. Say whether anything else does.",
    ],
  },

  {
    id: "tx-detail--unsupported",
    summary:
      "§7.0's third row, second half: a transaction whose execution DOES have a call structure and which this product cannot record — the demo tree's transaction under an AVM revision the pinned recorder set does not cover (generator txJ, published 2026-08-30 for this view). Reviewed beside `tx-detail--absent`, and largely FOR the comparison.",
    spec: "Page-Descriptions §7.0 (row 3), §14 (Recorder unavailable for the VM), §14.1a",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The state as a badge and the reason as a sentence, in the primary action's position, exactly as `tx-detail--absent` does — the two states share a shape and that is correct.",
      "A reason that locates the limitation in THIS PRODUCT rather than in the chain: no recorder exists for this VM. The transaction is observable; we cannot observe it.",
      "The trace-derived sections saying that they stay empty until a recorder exists — a conditional, where `absent`'s is a permanent.",
      "The transaction itself completely intact.",
    ],
    mustNotShow: [
      "A control of any kind for the trace, for the reason recorded on `tx-detail--absent`.",
      "A retry, a 'check back later', or a generate action. §14 forbids 'a retry that cannot succeed'.",
      "Wording that would be equally true of `tx-detail--absent`. Read the two sentences side by side: if a visitor could not tell from this page whether the chain cannot be observed or BlockTracer cannot observe it, that is a P1 against §14.1a and is the specific reason this view exists.",
    ],
    watchFor: [
      "§14's row for this state asks for the recorder's status to be LINKED ('Debug absent, recorder status linked'). Say whether anything on the page lets a visitor find out when a recorder might arrive, or whether the page states a limitation and offers no way to learn more about it.",
      "'Yet' appears in this state's sentence and not in `absent`'s. Judge whether that single word is doing enough work to separate a temporary limitation from a permanent one, or whether it reads as hedging.",
      "Whether the two states differ anywhere a reviewer would notice at a glance — badge label, tone, section copy — or only in a sentence a visitor has to read closely.",
    ],
  },

  {
    id: "tx-detail--hydrated",
    summary:
      "The transaction page after the debugger has hydrated over its first frame — the TRANSITION, not the landing. `tx-detail--session` is the landing, and it is captured; what nothing produces yet is a live engine taking that frame over in place.",
    spec: "Page-Descriptions §7.0, §7.1",
    register: "debugger",
    mustShow: [
      "A LIVE debugging surface occupying the page — the stepping controls enabled and the session positioned by an engine, not by the pre-rendered frame — with the transaction metadata still available as a PANE beside the debugger's own panes (§7.1) rather than reduced to an identity bar.",
      "The metadata carrying the same pane chrome as the debugger's own panes — a pane, not a bespoke sidebar. It has no dismiss control, for the reason recorded on `debugger--metadata-pane`.",
      "Continuity with the pre-hydration frame: the same hash, the same status, the same facts, the same panes. A reviewer must be able to see that the engine arrived over the frame that was already there, not that a different surface replaced it.",
      "The debugger's own panes populated — source, and at least one of call trace / event log / state.",
    ],
    mustNotShow: [
      "A full-page loading state or a flash of an empty shell — hydration must never show the visitor less than the pre-hydration page (§7.0).",
      "The transaction facts lost to the hydration. If the metadata is gone, that is the P1 this view exists to catch.",
    ],
    watchFor: [
      "The transition itself: compare against `tx-detail--session` and state what visibly changed. If the only difference is that the toolbar stopped looking inert, say so — that is the correct answer and it is worth recording.",
      "Whether the metadata pane's density matches the debugger's panes or still carries the explorer's spacious rhythm.",
    ],
  },

  {
    id: "tx-detail--decoded-input",
    summary:
      "The decoded-input section on its own — function/entry point and ABI-decoded parameters.",
    spec: "Page-Descriptions §7.2.3",
    register: "explorer",
    mustShow: [
      "The function or entry-point name, decoded — not a bare 4-byte selector where the ABI is known.",
      "The parameter list with, per parameter, its name, its declared type, and its value.",
      "Values rendered in a form appropriate to their type — an address as an address chip, a uint as a number, bytes as hex — rather than every parameter as an undifferentiated hex string.",
      "For an unknown selector: the raw bytes AND a 'supply an ABI' action.",
    ],
    mustNotShow: [
      "Parameters shown as a raw JSON dump of the ABI decode result.",
      "A nested tuple or array parameter flattened into one unreadable line.",
    ],
    watchFor: [
      "Three-column (name / type / value) alignment when values vary wildly in length.",
      "Nested parameters — check the indentation depth is legible and that the nesting is expressed by more than whitespace.",
    ],
  },

  {
    id: "tx-detail--events",
    summary:
      "The events/logs section at realistic volume — decoded where an ABI is known, raw otherwise, each row linking into the debugger.",
    spec: "Page-Descriptions §7.2.4",
    register: "explorer",
    mustShow: [
      "Multiple log entries — enough to be the realistic-volume case; a two-row log list does not test this section.",
      "Per entry: the emitting address, the decoded event name with its named parameters where the ABI is known, and the raw topics/data where it is not.",
      "A per-row link into the debugger at the step that emitted the log. This link is what distinguishes this product's log list from every other explorer's, and its absence is a P1.",
      "Decoded and raw entries visibly distinguishable, so the visitor knows which they are reading.",
    ],
    mustNotShow: [
      "Every entry rendered raw when the fixture's ABI would decode some of them.",
      "The debugger link present only on hover with no static indication that it exists.",
    ],
    watchFor: [
      "Log index and topic columns are numeric/hex and repetitive — check for tabular alignment and for enough separation between entries to count them at a glance.",
      "The link affordance's weight: it appears on every row, so a heavy treatment turns the section into a wall of buttons.",
    ],
  },

  {
    id: "tx-detail--internal-calls",
    summary: "The internal-calls section — the call tree, from the trace.",
    spec: "Page-Descriptions §7.2.5",
    register: "explorer",
    mustShow: [
      "A tree, visibly nested to more than one level — a flat list of calls is not a call tree.",
      "Per call: the target address (as a chip, with a contract badge where applicable), the decoded method where known, the value transferred where non-zero, and the call's outcome.",
      "A failed or reverted call in the tree rendered distinctly, if the fixture has one — this is what a visitor came to find.",
      "Depth expressed by indentation AND a connecting rule or guide, so deep nesting stays traceable.",
    ],
    mustNotShow: [
      "Indentation deep enough to push content off the right edge.",
      "A tree with no way to collapse a subtree at realistic depth.",
    ],
    watchFor: [
      "Indentation unit versus address-chip width: at depth 6+ the chip is what runs out of room first.",
      "Whether the outcome indicator sits at a consistent horizontal position regardless of depth, so failures can be scanned down a column rather than hunted.",
    ],
  },

  {
    id: "tx-detail--state-changes",
    summary:
      "State changes — storage/object/account diffs, before → after, decoded to declared types where a layout is known.",
    spec: "Page-Descriptions §7.2.6",
    register: "explorer",
    mustShow: [
      "A before → after pairing for every changed slot, with both sides present. A single 'new value' column is not a diff.",
      "The changed account or object identified per group of changes.",
      "Where a storage layout is known, the DECLARED NAME and type of the variable — not only the raw slot hash.",
      "Where no layout is known, the raw slot key, so the section degrades to raw rather than to nothing.",
      "A visual direction cue (arrow, colour role, or column order) making it unambiguous which side is before.",
    ],
    mustNotShow: [
      "Before and after distinguished by colour alone.",
      "A slot whose value changed rendered identically to one that did not.",
    ],
    watchFor: [
      "Two 32-byte hex values side by side is the widest content in the explorer register — check the wrapping and whether the pair stays visually associated once wrapped.",
      "Diff colour roles in dark theme specifically (VD.7 will re-check this; note it here if it is already wrong).",
    ],
  },

  {
    id: "tx-detail--raw",
    summary: "The raw section — the chain-native transaction and receipt JSON, verbatim.",
    spec: "Page-Descriptions §7.2.8",
    register: "explorer",
    mustShow: [
      "Both payloads present and labelled — the transaction AND the receipt, distinguishable from each other.",
      "JSON rendered as formatted, indented JSON in a monospace face, not as one wrapped line.",
      "A contained, scrollable region rather than an unbounded expansion of the page.",
      "A copy affordance for the raw payload.",
    ],
    mustNotShow: [
      "Reformatted, re-ordered or pretty-printed-with-changes JSON. 'Verbatim' is the requirement; syntax colouring is fine, editing the bytes is not.",
      "The region extending the page body horizontally.",
    ],
    watchFor: [
      "Whether syntax highlighting is applied and, if so, whether it comes from the product lineage's editor tokens (Design-System §7 — source code looks like CodeTracer wherever it appears).",
      "Line-height and font-size of the JSON versus the rest of the page: this is a product-register element in a web-register page and the density difference must look deliberate.",
    ],
  },

  // ══════════════════ Explorer register — address, source, search ════════

  {
    id: "address",
    summary:
      "The address page for a CONTRACT — scoped in V1 to get you to a transaction worth tracing, with complete history and no capability to negotiate.",
    spec: "Page-Descriptions §9",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The address in full beneath a truncated heading, with a contract badge — and, where the tree publishes a label for it, the name WITH its provenance beside it, because a curated name and a self-declared one are different claims.",
      "The shared transactions table with Debug on every row, presented as COMPLETE history — no record cap, no 'showing the most recent N' apology.",
      "A code section carrying the code hash, the verification status, the provider and the compiler, with a route into the source browser.",
      "An events section that STATES why it is empty and what would fill it — §9 promises complete log coverage, so silence there would read as 'this address emitted none'.",
      "A statement that balances and token holdings are out of SCOPE in V1 rather than missing, with the reason.",
      "A cursor pager naming which block range this page of history covers.",
    ],
    mustNotShow: [
      "A balance, a token holdings list, a portfolio value, a price, a P/L figure or holder analytics. Page-Descriptions §9 excludes all of these by name for V1; one appearing means the wrong scope was built.",
      "A 'Requires' column or any capability-negotiation notice — its absence is the point of this page.",
      "A 'read contract' panel (deferred in V1).",
      "A code SIZE or a proxy relationship: neither has a published object, and either appearing would be invented.",
    ],
    watchFor: [
      "The header carries a 42-character identifier twice — truncated as the title and in full beneath it. Check the pair reads as one fact rather than as two.",
      "Three consecutive stated-absence blocks (events, balances, and whatever the code section says) risk reading as a page of apologies; check the transactions table still dominates.",
      "At 375 px this view has a known horizontal-overflow finding from VD.0 — measure whether content exceeds the viewport and name the element that does it.",
    ],
  },
  {
    id: "address--account",
    summary:
      "The address page for an ACCOUNT — no code is bound to it, so §9's code summary is a statement rather than a table.",
    spec: "Page-Descriptions §9, rule 2",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "An account badge rather than a contract badge, decided by whether the tree binds CODE to the address and not by the shape of the address.",
      "A code section that states there is no code bound to this address and what a code binding IS — a code edge on the transactions that ran it. This is rule 2 on a section rather than on a list, and an empty panel here is the finding.",
      "The shared transactions table with Debug on every row.",
      "The same pager, events statement and out-of-scope statement the contract case carries, so the two shapes of this page differ only where the data does.",
    ],
    mustNotShow: [
      "An empty file list, an empty verification panel, or a 'not verified' badge — there is no code here, so there is no verification question to answer, and answering it would be a category error.",
      "A link into the source browser presented as the primary next step.",
      "A balance or token holdings, as on the contract case.",
    ],
    watchFor: [
      "This page and `address` are the same template over two shapes of subject; check the difference is legible immediately from the badge and the code section rather than only on reading.",
      "The statement replaces a table: check it is given a measure and does not run the full width of the container.",
    ],
  },
  {
    id: "address--older-page",
    summary:
      "A later block-range segment of an address's history — the cursor pager with both directions live.",
    spec: "Page-Descriptions §9, Static-Site-Architecture §2.2",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A pager carrying BOTH a 'Newest' and an 'Older' control, since this page is neither the first nor necessarily the last.",
      "A statement of which block range this page covers and which segment of how many it is — a cursor URL, unlike `?page=3`, does not tell a reader where they are, and the honest answer to that is a sentence.",
      "The shared transactions table for THIS segment only, with Debug on every row.",
      "The address identity above it, so a reader deep in history still knows whose history they are in.",
    ],
    mustNotShow: [
      "Page numbers, a page-size selector, or an offset anywhere on the page or in the URL. §2.2 rules out ordinal pagination in BOTH directions; a numbered pager here is a P1 against the data model.",
      "A 'load more' control that would append rather than navigate — every page of history has its own address.",
      "Any suggestion that history has been truncated.",
    ],
    watchFor: [
      "The pager appears twice in the product with the same component (block list, transactions list) — check this instance is identical to those and not a variant.",
      "'Newest' and 'Older →' are the two controls; check the asymmetry in their labels reads as direction rather than as inconsistency.",
      "The segment-position sentence is the only thing telling a reader how deep they are; check it is not lost between the table and the buttons.",
    ],
  },

  {
    id: "contract-source",
    summary:
      "The verified source browser — a product-register element (the code view) inside a web-register page.",
    spec: "Page-Descriptions §10, Design-System §7",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A verification panel: the code hash, the match level, the provider, the compiler and its version, the language, and the bundle id — each labelled.",
      "A file list naming every source in the bundle, each linking to its own region.",
      "Every source file rendered with line numbers and SYNTAX HIGHLIGHTING from the same lexical palette the debugger's source pane uses — Design-System §7 makes this the one sanctioned register crossing, and a generic web highlighter is a register error.",
      "A deployments section naming the other addresses sharing this code hash, or stating that this hash is bound to one address and why that is the interesting fact (source is keyed by code hash, so a second deployment arrives already verified).",
      "A statement naming §10's ABI/interface view and storage layout as absent because this bundle publishes an empty debug object — and that with no ABI there is nothing to link 'transactions that called this function' FROM, so the link is absent rather than broken.",
    ],
    mustNotShow: [
      "Source rendered without syntax highlighting.",
      "An empty ABI panel or an empty storage-layout table — the absence is a statement, not a frame with nothing in it.",
      "An in-file search box that does nothing: search needs script and this client ships none.",
      "Highlighting that is visibly not the CodeTracer editor palette.",
    ],
    watchFor: [
      "A verification grid above several long code regions: check the page has a reading order and that the first file does not begin before the verification facts have been read.",
      "Long lines against the container width — horizontal scroll inside the code container is correct; horizontal scroll of the page is not.",
      "The code region is product-register colour inside an explorer-register page; check the crossing reads as deliberate (a bounded, elevated surface) rather than as the page breaking.",
      "Line-number gutter alignment across files of different line counts.",
    ],
  },

  {
    id: "contract-source--unverified",
    summary:
      "No verified source — instruction-level stepping stated as still available, with what would resolve it.",
    spec: "Page-Descriptions §14 (No verified source), §10",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The verification panel present, with the code hash shown and the status reading as unverified — what IS known, rather than a page that only says 'no'.",
      "The producer's own reason for there being no bundle, quoted rather than paraphrased.",
      "An explicit statement that this contract is STILL DEBUGGABLE at instruction level, which is the fidelity ladder's floor and holds with no source at all. Without it the page reads as a dead end, and that is the finding.",
      "What would resolve it: publishing a build output whose bytes hash to this code hash, and that doing so serves every deployment of the same code rather than this address alone.",
    ],
    mustNotShow: [
      "An empty file tree or an empty code region.",
      "An error treatment. This is a normal, expected state for most addresses on most chains.",
      "A 'verify this contract' call to action that implies BlockTracer runs a verification service.",
      "A control that would upload or supply sources, which needs script this client does not ship.",
    ],
    watchFor: [
      "Tone: informative, not apologetic. Read the copy and say which it is.",
      "The page is short. Check it has been composed rather than left as two blocks at the top of an empty viewport.",
      "The unverified status badge against the verified one on `contract-source`: check they are legibly different states of the same control rather than two unrelated treatments.",
    ],
  },

  {
    id: "search",
    summary:
      "The search route — what resolution IS, which chains would be checked, and the whole published name corpus, browsable without a query.",
    spec: "Page-Descriptions §11, Search-And-Routing §1–§8",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A search field as the page's primary input.",
      "A statement that this address cannot resolve a query yet and WHY — resolution runs in the browser and this deployment ships no script — phrased so that 'nothing was looked in' is legibly different from 'not found'. Search-And-Routing §8 requires a miss to name what was tried; this is that, for the case where nothing was.",
      "The four resolution mechanisms as a table with their REQUEST COST — 0, 1, 2, 1–2 — and what each handles. The cost column is the point: most explorer search is identifier resolution, and three of the four compute a path rather than querying anything.",
      "The chains that would be checked, each linked, so the scope of a miss is visible before one happens.",
      "The published name corpus as a browsable table — name, symbol, kind, PROVENANCE and address — with each row linking to the entity it names. This is data from files, and it is the part of §11 that needs no query at all.",
    ],
    mustNotShow: [
      "A results list, a candidate, or an echoed query. A static file server cannot read `?q=`, and a page that appeared to have resolved something it never saw is the one thing this product cannot afford.",
      "A zero-state illustration or advertising copy.",
      "A 'no results found' message, which would be an assertion about a query the page never received.",
    ],
    watchFor: [
      "Two data tables and a chain strip on one page: check the three regions are separated by the section rhythm rather than reading as one long run.",
      "The provenance column is the only place in the product where a name's trustworthiness is shown; check `curated` and `self-declared` are legibly different weights.",
      "The explanatory statement sits above the tables and is the page's most important text; check it is not styled as a caveat.",
    ],
  },

  {
    id: "search--ambiguous",
    summary:
      "Ambiguous input — grouped, keyboard-navigable candidates across kinds.",
    spec: "Page-Descriptions §11",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Candidates GROUPED BY KIND with visible group headings: transaction · block · address · name.",
      "More than one group populated — a single-group capture does not show the grouping this view exists to test.",
      "A visible keyboard-selection state on one candidate (the active row), since the list is specified as keyboard-navigable and the selection state is the only way to see that.",
      "The active chain's results first, above any other chains' results.",
    ],
    mustNotShow: [
      "An undifferentiated flat list of candidates.",
      "Keyboard affordance implied only by a hover style.",
    ],
    watchFor: [
      "Group heading weight versus candidate weight — the headings must be scannable without competing with the candidates.",
      "The active-row treatment against the hover treatment: if they are identical, keyboard and mouse states are indistinguishable.",
    ],
  },

  {
    id: "search--cross-chain",
    summary:
      "Cross-chain results — the active chain first, other configured chains below under a 'found on other chains' group.",
    spec: "Page-Descriptions §11",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A visible boundary between the active chain's results and the rest, with the 'found on other chains' group explicitly labelled.",
      "Results from at least two distinct chains, each row identifying its chain.",
      "The active chain's group first and visually primary.",
    ],
    mustNotShow: [
      "Chain identity carried by logo alone with no chain name.",
      "Other-chain results interleaved with the active chain's.",
    ],
    watchFor: [
      "The demotion of the secondary group: it must read as secondary without reading as disabled.",
      "Repeated chain identification on every row versus once per group — whichever is chosen, it must be consistent.",
    ],
  },

  {
    id: "search--not-found",
    summary:
      "A miss that reads as a scoping answer rather than a dead end — what was tried and where.",
    spec: "Page-Descriptions §11, Search-And-Routing §8",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The query, echoed.",
      "WHAT WAS TRIED, enumerated: the hash index, and which chains' paths were computed. This enumeration is the entire design of this state and its absence is a P1.",
      "A statement of what would change the answer — a different chain, a different scope, a transaction not yet indexed.",
      "The search field, still available and still holding or ready for input.",
    ],
    mustNotShow: [
      "A generic '0 results' or 'not found' message with no enumeration.",
      "A 404 illustration or a mascot.",
      "An error treatment — this is an answer, not a failure.",
    ],
    watchFor: [
      "The enumeration is a list of internal-sounding things (hash index, computed paths) shown to a general visitor; check the wording is legible to someone who does not know the architecture.",
      "Page balance: this state has little content and is the easiest one in the product to leave looking like an unstyled fragment on an empty canvas.",
    ],
  },

  {
    id: "settings",
    summary:
      "Preferences — entirely client-side, and notably short because there is nothing about data sources to configure.",
    spec: "Page-Descriptions §12, §13",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Four labelled groups: Privacy · Storage · Debugger · Advanced.",
      "The privacy group ANSWERED rather than described: no account, no ads, no third-party requests, telemetry off, what is logged (this deployment's own CDN logs), and no record caps. This group needs no script and must be complete.",
      "For each of the other three groups, a statement of what it will control and why it cannot act yet — measuring a cache, persisting a theme and overriding a registry at run time are all script operations.",
      "A link onward to the fuller privacy summary.",
    ],
    mustNotShow: [
      "ANY interactive control — no toggle, no select, no number field, no clear button. §13's rule is that a control that cannot succeed is one this product does not ship, and a settings control that appears to accept a value has told the user their preference was recorded.",
      "A telemetry switch, even one drawn as off.",
      "Any chain RPC, data-provider or indexer configuration — the page's shortness is a design statement and additions to it are a spec violation.",
      "An account, profile or sign-in section.",
    ],
    watchFor: [
      "A page of prose where a reviewer expects controls: check it reads as a deliberate account of what this deployment does rather than as an unfinished form.",
      "The privacy group is a real answer among three stated absences; check it dominates rather than being lost among them.",
      "A short page on a wide viewport: check whether it has been given a measure and a column, or left as full-width rows across 1920 px.",
    ],
  },

  {
    id: "static-content",
    summary:
      "Static content — /about, the privacy summary the home page's trust strip links to.",
    spec: "Page-Descriptions §1 route map, §2 Trust strip",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "Long-form prose with a heading hierarchy of at least two levels.",
      "A constrained measure — this is the one page in the product that is purely reading, and full-viewport-width body text at 1920 px is a P2 typography failure here specifically.",
      "The trust strip's five claims itemised with their EVIDENCE — no account, no ads, no tracking, complete history, no record caps — rather than restated. A claim repeated is not a privacy summary.",
      "An account of the read path: static files behind a CDN, one mutable object per chain, no third-party requests.",
      "The site's standard header and footer, so the page reads as part of the product.",
    ],
    mustNotShow: [
      "Unstyled default browser typography.",
      "Body text running the full width of a wide viewport.",
      "Marketing superlatives standing in for the specifics — this page is class I0 on the condition that it carries substantive unique content.",
    ],
    watchFor: [
      "This is the purest test of the type scale: heading levels, body, and the spacing rhythm between them, with no data to hide behind.",
      "The itemised claims are rendered as a definition grid rather than as prose; check that reads as evidence rather than as a specification table.",
      "Link treatment inside running prose, which appears nowhere else in the product at this density.",
    ],
  },

  {
    id: "not-found",
    summary:
      "Object not found — 'not on this chain', naming the chains checked, never a blank page.",
    spec: "Page-Descriptions §14 (Object not found)",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The §14 treatment as a bounded notice with a named condition, not a bare heading: the statement that nothing at this address is published, and the chains that WERE checked, enumerated by name.",
      "A route onward — the supported-chains index, the home page, and the resolution page.",
      "The product's own header and footer — this must be a BlockTracer page, not a server error page.",
      "A statement that an identifier from a chain BlockTracer does not cover will not be here, so a miss reads as a scoping answer rather than a dead end.",
    ],
    mustNotShow: [
      "A bare '404' or a web-server default error page.",
      "A blank page.",
      "The requested path echoed back. This one file is served for EVERY unmatched path, so a quoted URL would be right in the response body and wrong in the file — and the address is in the visitor's address bar either way.",
      "A stack trace or any internal identifier.",
    ],
    watchFor: [
      "This is the product's own 404 (`static_export` writes `404.html` with the same bytes `renderRoute` returns), so grade it as product design rather than noting it may be the harness's fallback.",
      "Tone: this is the most common way a visitor's first click fails, and it decides whether the product reads as considered.",
      "The notice is the same component every degraded state uses; check it does not look like an error dialog here and like a note elsewhere.",
    ],
  },

  // ═══════════════════════════ Debugger register ═════════════════════════

  {
    id: "debugger",
    summary:
      "The full-viewport CodeTracer session at the pinned time coordinate — the product register's flagship surface. Four panes: Code beside a navigation column of Call Trace, Event Log and Values, with the stepping controls in the identity bar.",
    spec: "Page-Descriptions §8, Debugger-Integration §3",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A pane titled **Code** with a visible current-position indicator at the pinned coordinate — the session is positioned, not merely loaded. It is titled Code and not Editor: it is a read-only listing, and at instruction-level fidelity it is not source at all.",
      "A call trace with more than one frame, occupying the region that carries the largest share of the column beside Code.",
      "**Call Trace and Event Log as ONE TABBED REGION, with Call Trace open.** They are the two ways of discovering chronological data and jumping to it, and tabs draw that pairing as peers in one region — each getting the full height of it, one strip naming both. Call Trace is the tab that opens because selection is the primary navigation gesture and the call trace is the primary selection surface. A tab strip pairing either of them with the Values pane, or with the metadata pane, is the P1 this item exists to catch.",
      "A pane titled **Values** with at least one value. Not titled State: `State` is the explorer's and the incumbents' word for a transaction's aggregate state diff, and this pane shows values at step N.",
      "Stepping controls in the identity bar, including both directions — reverse stepping is this product's entire premise and its controls must be visible, not hidden behind a menu. They belong in the bar and not in a pane: selection is the primary navigation gesture in this category and stepping is the secondary one.",
      "A timeline or scrubber expressing position within the trace.",
      "The transaction identity reachable — either the metadata pane or, at minimum, the identity bar's hash.",
    ],
    mustNotShow: [
      "An indeterminate spinner anywhere in a fully loaded session.",
      "Empty panes. A pane with nothing in it must say why, not sit blank.",
      "Explorer-register light chrome around the session.",
      "A full-width band of explanatory prose above the panes. The engine's loading state is carried by the controls' own status, the phase rail and the buttons' disabled state; a paragraph restating it was removed on 2026-08-29 and its return is a finding.",
      "A pane occupying a full-width row of its own above the others — the arrangement is one row of two columns, and a full-width band is how the controls pane used to outrank the call trace.",
      "The Values pane inside the tab strip. It is a pane BELOW the tabbed region, not a third tab: it answers 'what is true here', which is not a way of finding a position, and hiding it behind a tab is what this milestone spent hiding the event log.",
    ],
    watchFor: [
      "Pane proportions at 1920 versus 1440: which pane loses width first, and whether the Code pane keeps a usable measure. Code now keeps the full height of the region — say whether the extra rows are legible or merely present.",
      "The navigation region takes three fifths of its column for a call trace the fixture fills in its first third. Say how much of the region is empty below the last frame, and whether the region or the Values pane below it is the one that should have the height. This is a MEASUREMENT the change has not made.",
      "The identity bar carries identity, controls, scrubber, status, phase rail and two actions. Judge whether it reads as grouped or as a strip of unrelated objects, and say where it wraps at laptop width.",
      "Continuity with the CodeTracer desktop app — same pane vocabulary, same density. Control PLACEMENT deliberately diverges (the desktop app puts the toolbar in a pane); judge the placement on its own terms, not against the desktop app, and judge the vocabulary against it.",
      "Small-text legibility: the tool rubric rewards density, but 11 px text at low contrast is a P2 under it, not a win.",
    ],
  },

  {
    id: "debugger--metadata-pane",
    summary:
      "The transaction metadata pane inside the session — the answer to 'a visitor deep-linked into a stepping session still needs to know what they are looking at'.",
    spec: "Page-Descriptions §7.1",
    register: "debugger",
    // Clipped to `#pane-metadata` — one pane, not the viewport. See `debugger-pane`.
    inherits: ["debugger-pane"],
    mustShow: [
      "The metadata rendered as a PANE among the debugger's panes — same chrome and same header treatment as the Call Trace or Values pane.",
      "The §7.2 facts inside it: status with revert reason, value, roles (from/to), cost, finality, the execution list, and the private/public split where the chain has one.",
      "Addresses, targets and selectors legible in full, and marked as values that can be taken out of the page (§13: 'every hash, address and identifier is copyable with one click').",
      "The debugger's other panes still visible around it, so the pane is seen in context rather than as a full-screen overlay.",
    ],
    mustNotShow: [
      "A modal dialog or a full-viewport takeover — it is a pane (§7.1 says so explicitly, in contrast to 'a bespoke surface').",
      "A subset of the facts that drops the revert reason or the private/public split.",
      "Metadata rendered at explorer density inside a product-register session.",
      "A dismiss control. §7.1 used to call the pane 'dismissible and restorable like any other' while also requiring that the metadata survive the collapse to an identity bar in EVERY state — so a control whose success would violate the page's own invariant was never merely unimplemented. The control was removed on 2026-08-29 and the spec sentence moved with it: §7.1 now states that the pane carries no dismiss control, and gives the reason. Its return is a P1.",
    ],
    watchFor: [
      "This pane's content is the same data as the explorer's overview grid at a fraction of the width; check the label/value strategy that makes that work (stacked rather than two-column, probably) and whether it was actually chosen or merely inherited.",
      "The Aztec private/public split needs to be legible as a split, not as two similar-looking rows.",
    ],
  },

  {
    id: "debugger--call-trace",
    summary:
      "The call trace at realistic depth and width, including the cost column and the cost-sorted view. It is the OPEN tab of the navigation region, which gained the space the debug-controls pane used to occupy.",
    spec: "Page-Descriptions §8, Debugger-Integration §4.1, VD.5",
    register: "debugger",
    // Clipped to `.ln.stack` — the navigation REGION, not the viewport. See
    // `debugger-pane`; this is the view whose L4 review caught the mismatch.
    inherits: ["debugger-pane"],
    mustShow: [
      "A call tree at genuine depth — several levels of nesting visible, not a flat list of top-level calls.",
      "A per-frame cost column, aligned as a numeric column.",
      "The current frame indicated distinctly from the rest.",
      "Frame identification: function or entry-point name plus its contract/module, per frame, with the name legible as a value that can be taken out of the page.",
      "A sort or ordering affordance for the cost-sorted view.",
      "Enough vertical extent to be the session's primary navigation surface — its region carries the largest weight in the column, and a call trace whose rows end in the first third of a mostly empty region is the P2 this item exists to catch.",
      "A tab strip above it naming both this pane and the Event Log, with THIS tab marked as the open one. It is captured at the bare route because it is the tab the session opens in; a strip that marks the other tab, or that names only one pane, is a P1.",
    ],
    mustNotShow: [
      "Indentation that pushes frame names out of the pane at realistic depth with no horizontal containment.",
      "A cost column that is left-aligned or has inconsistent units between rows.",
    ],
    watchFor: [
      "Depth versus pane width is the defining tension of this pane. Say at what depth the frame name stops being readable.",
      "Whether deep frames can be collapsed, and whether the collapse state is legible.",
      "Cost magnitudes vary by orders of magnitude down the column — check the number formatting keeps them comparable at a glance.",
    ],
  },

  {
    id: "debugger--event-log",
    summary:
      "The event log with ALL FIVE entry kinds in one stream — calls, program output, storage writes, events, and the revert that ends the transaction. It is the SECOND tab of the navigation region, paired with the call trace, and is captured through the fragment that selects it. Its subject changed on 2026-08-30: the demo tree now publishes a genuinely reverted transaction (generator txF), so the fifth kind is present rather than absent. Until then this view was pending — the pane rendered four kinds and correctly refused to dress the Aztec `partial` split up as a revert, and its must-show required the fifth.",
    spec: "Page-Descriptions §8, Debugger-Integration §4.2, VD.5",
    register: "debugger",
    // Clipped to `.ln.stack` — the same region as `debugger--call-trace`, in
    // its other tab state. One pane, not the viewport. See `debugger-pane`.
    inherits: ["debugger-pane"],
    mustShow: [
      "All five entry kinds present in the same view: a call, program output, a storage write, an event, and a revert. The revert is the one that used to be missing; if it is absent, that is a DATA failure to report as such, not a design finding.",
      "The five kinds VISUALLY DISTINGUISHABLE from each other by more than their text — this is the pane's whole job and the reason it is captured against a mixed stream.",
      "The revert entry rendered as the terminal, significant event it is — it is the last row and it ended the transaction, and it must read as an outcome rather than as one more row.",
      "The revert naming WHAT failed — the constraint, not just the word 'revert'. The transaction's published revert reason and this row name the same assertion, and a reviewer should be able to see that they agree.",
      "A position/ordering that ties entries to the trace, so the log can be read as a sequence.",
      "The entry corresponding to the current position indicated.",
      "A tab strip above it naming both the Call Trace and this pane, with THIS tab marked as the open one — the capture reaches it through `#pane-eventlog`, which is the same `:target` mechanism a visitor's click uses. It is paired with the CALL TRACE now (changed 2026-08-29; it used to be the non-default half of a tab pair with the state pane, which paired it with the one pane it is not an alternative to).",
    ],
    mustNotShow: [
      "Five kinds rendered identically with only a differing label.",
      "Kind distinguished by colour alone.",
      "A log so uniformly dense that the revert does not stand out.",
      "The revert rendered as a system error or a fetch failure. The transaction reverted; the RECORDING is fine, its verdict is `match`, and the session is fully usable. Dressing a chain outcome as a tool malfunction is a P1 tone failure.",
      "A tab strip pairing it with the VALUES pane. Values is not an alternative way of finding a position — it answers what is true once you have arrived — and that pairing is the arrangement this change removed. Its return is a P1 against the `debugger` view's own must-show.",
    ],
    watchFor: [
      "The icon/badge/colour system across five kinds in both themes — this is the densest use of the status colour roles in the product.",
      "Row height consistency when entries carry different amounts of detail.",
      "It shares a region with the call trace and a column with the values pane below. Say whether the tab strip reads as a control — two peers, one open — or as a header with a stray word beside it. An inactive tab that reads as a label is the specific way this arrangement can look wrong, and it is the failure the strip this replaced actually had.",
    ],
  },

  {
    id: "debugger--values-pane",
    summary:
      "The Values pane with deeply nested values and long identifiers — variable values AT STEP N, which is a different thing from the transaction page's aggregate state diff.",
    spec: "Page-Descriptions §8, VD.5",
    register: "debugger",
    // Clipped to `#pane-state` — one pane, not the viewport. See `debugger-pane`.
    inherits: ["debugger-pane"],
    mustShow: [
      "The pane titled **Values**, not State (renamed 2026-08-29). `State` is Etherscan's and Blockscout's word for a whole-transaction state diff; a pane called State that shows values at one step collides with a convention every visitor arrives with.",
      "A value tree nested to at least three levels, expanded enough to show the nesting.",
      "Per entry: identifier, value, and type — in that reading order, which is the desktop app's.",
      "A long identifier present and handled — this pane is captured specifically for that case.",
      "Each value legible as something that can be taken out of the page in one gesture (§13), and visibly so — not a behaviour a reader has to guess at.",
      "Values whose type is not obvious from their rendering carrying a type annotation.",
    ],
    mustNotShow: [
      "A long identifier truncated with no way to see it in full.",
      "Nesting expressed only by indentation with no guides, at three levels or more.",
      "A flat key/value dump.",
      "The title `State`.",
    ],
    watchFor: [
      "The identifier column and the value column compete for a narrow pane; describe how that is resolved and whether the resolution survives the deepest nesting shown.",
      "Changed-since-last-step highlighting, if present — it is the pane's most valuable signal and the easiest to render too subtly.",
      "It is the lower of two regions in the column and the smaller of them, and it is the only one not behind a tab. Say whether it has enough rows to be useful, or whether it has become a strip — and whether being the column's one always-visible surface makes it read as more important than its rank.",
    ],
  },

  {
    id: "debugger--source-pane",
    summary:
      "The Code pane in a source-level session, with the source/instruction level boundary legible.",
    spec: "Page-Descriptions §8, §14 (No verified source), VD.5",
    register: "debugger",
    // Clipped to `#pane-editor` — one pane, not the viewport. See `debugger-pane`.
    // Its own must-show carries the "full height of the region beside the
    // navigation column" item, which is a shape a one-pane frame can still
    // report on; the identity bar above it is not.
    inherits: ["debugger-pane"],
    mustShow: [
      "The pane titled **Code**, not Editor (renamed 2026-08-29): it is a read-only listing with no editor behind it, and where fidelity drops to instruction level what it lists is not source at all — which is the case 'Source' would misname.",
      "The pane occupying the full height of the region beside the navigation column — nothing is stacked under it.",
      "Syntax-highlighted source from the product lineage's editor tokens (Design-System §7).",
      "Highlighting that carries LEXICAL MEANING, not decoration: comments, string literals, numeric literals, keywords, named types and called functions each visibly distinct from ordinary identifiers and from each other. A reviewer should be able to name which category a coloured run belongs to without reading the code.",
      "Comments visibly QUIETER than the code they annotate — they are the one category that must recede rather than attract.",
      "Line numbers.",
      "The current line indicated unambiguously — a highlight, a gutter marker, or both.",
      "Executable versus non-executable lines distinguishable, so a visitor knows where stepping can land.",
      "The file identity — path or module name — visible.",
      "Where the session mixes source-level and instruction-level regions, the BOUNDARY between them rendered explicitly, not as an unannounced change of content.",
    ],
    mustNotShow: [
      "Unhighlighted plain-text source, where the file's language IS one the exporter can lex (Noir today). Plain text is the CORRECT rendering for any other language and for instruction-level content — see the next item — so judge this against the pane's stated language, never on sight alone.",
      "Highlighting applied to content the exporter cannot actually lex — a bytecode or instruction listing wearing source colours, or a non-Noir file coloured by Noir's keyword list. Confident mis-tokenisation is a worse failure than plain text because it looks authoritative.",
      "Colour used for anything OTHER than lexical category inside the code area — a coloured run that means 'executed', 'changed' or 'selected' would collide with the palette and make both unreadable. Execution state is carried by the row's background and gutter marker, and must stay there. The inline VALUE LABELS are outside the code area, on their own surface with their own border, and are judged on `debugger--omniscience` instead.",
      "A current-line indicator that is indistinguishable from a selection or a hover.",
      "Instruction-level content presented as though it were source.",
      "The title `Editor`, or any affordance implying the listing can be edited.",
    ],
    watchFor: [
      "The inline value labels now share every row with the code (2026-08-30). Judge the CODE here — whether it is still the primary object on the row and still scannable down the pane — and judge the labels themselves on `debugger--omniscience`. If the labels have become what the eye lands on first, say so here, because it is the code pane's problem and not the overlay's.",
      "Line-height and font-size against the desktop app's source pane — the continuity requirement is strongest here because this is the pane a CodeTracer user knows best.",
      "The gutter's width budget with four-digit line numbers plus a marker.",
      "Highlighting palette in light theme: the mapped editor tokens are dark-first — mapped.json's four rungs have modes.Light identical to modes.Dark — so the light half is web-lineage work and is the case most likely to be wrong.",
      "Token legibility ON the current line and ON executed lines, not only against the plain code surface. Those rows have their own backgrounds, and a palette checked against one background only will fail on the row the eye goes to first.",
      "Comments in the LIGHT theme specifically: the desktop's white theme paints them #eb4f64, and this lineage deliberately does not, because red is the product's revert hue. If comments read as errors, that departure was wrong.",
      "Whether string and function colours are still separable — they are the closest pair in both themes, being the two warm categories.",
    ],
  },

  {
    id: "debugger--omniscience",
    summary:
      "Recorded values shown inline against the expressions that produced them, and the loop rail that says which pass they belong to. The product's stated differentiator: `Debugger-UX-Research.md` records that nobody else in this category ships it — Pernosco lists inline value display as a roadmap item.",
    spec: "Page-Descriptions §8, GUI/Debugging-Features/Omniscience-Flow.md",
    register: "debugger",
    inherits: ["debugger-pane"],
    mustShow: [
      "Values rendered BESIDE lines of code, one label per variable, in three visibly distinct shapes: a plain read (`shield_pct=90`), a CHANGE the line performed (`damage: 0 → 2000`), and a call's return (`→90`). A reviewer should be able to say which of the three a given label is without reading the numbers.",
      "The CHANGE labels distinguishable at a glance from the plain ones — this is the single most valuable thing an inline value says, and it is the one a uniform treatment would hide.",
      "The direction of a change unambiguous: which value was before and which is after, carried by more than left-to-right order alone.",
      "Each label attached to a specific LINE, visibly, so it is never in doubt which statement a value belongs to.",
      "The loop rail above the listing, naming the loop (`iterate_asteroids`, line 4) and stating the pass as a fraction — `Iteration 3 of 8`.",
      "A track with one segment per pass, and TWO marks on it that mean different things: where the SESSION is, and which pass's values are currently displayed. On this capture they coincide; a reviewer should still be able to see that they are two marks.",
      "Passes the session has not reached rendered visibly INERT and distinguishable from the reachable ones — the still frame has no values for them.",
      "The code still legible as code with the labels present: the labels must not be what the eye lands on first.",
      "The branch this pass did NOT take marked as such: line 29 (`damage = mass * 1;`) is inside the `if` arm that pass 3 declined, and carries a `⊘` in the gutter where other lines carry `·`, plus a recession on the code itself. A reviewer should be able to say 'that statement did not run' from the row alone.",
      "That mark reading as a statement about the EXECUTION, not as a disabled control. The line is still fully readable code — dimmed, not greyed out — and the gutter carries a mark rather than merely losing one.",
      "A counted `+N` pill on the rows whose values do not all fit beside them — `Debugger-UX-Research.md` row 9's counted elision. Every value on this pane is either drawn in full or counted by one of these; nothing is cut silently. A reviewer should be able to say, for any annotated row, how many values it recorded.",
      "Every `+N` pill wholly inside the pane, including on the rows whose CODE already runs past the right edge — those are the rows with the most to withhold, and a count that scrolled away with them would be the defect it exists to report.",
      "The pill reading as a COUNT and not as a value: dashed border where a value's is solid, and no value colour.",
      "Counts in ONE column, at the right of the listing, whether they sit beside their line or on a row of their own beneath it. A row of one's own is what a line whose code fills the pane gets; a reviewer should be able to say which line such a count belongs to.",
    ],
    mustNotShow: [
      "Two passes' values on one line at once. Every label on screen belongs to the pass the rail names; a line carrying `remaining_shield` twice with different values would be the overlay reporting two moments as one.",
      "Whole regions of the listing dimmed. Exactly one line is marked untaken on this capture, because that is what the recording can prove; a pane where every unexecuted-looking line receded would be claiming 'not taken' about lines that were merely never reached.",
      "An untaken line so faint that its code cannot be read, or one whose syntax colouring has been flattened to a single grey. The recession multiplies the existing hues; it does not replace them.",
      "A value with no visible relationship to any expression — a floating number, a label in the gutter, or a run of labels that could belong to the line above or the line below.",
      "A label wide enough to push the code off the pane, or one truncated so hard that the value is unreadable. A value that cannot be read is worse than a value that is absent.",
      "Placeholder or zeroed values on lines the session has not executed. Absent is correct there; approximate is not.",
      "A loop control that looks draggable, or arrows implying a slider gesture the page cannot perform. With no script this control is a set of links.",
      "The label colour colliding with the syntax palette so that a value reads as a token of the code.",
      "A `+N` pill styled as a button, a link or anything else that invites a click. The page ships no script and cannot expand it; the full list is on the element's `title` and nothing on screen may promise more than that.",
      "A `+0`, or a pill on a row whose values all fit. A row with nothing withheld says so by carrying no pill.",
      "A pill drawn ON a line of code. This is the specific defect the stacked row exists to prevent: a count landing mid-identifier produces a composite that reads as a token the program does not contain (`initial_shield` under a `+3` reading as `initial_sh+3ld`), which is the page inventing source text. Anything that looks like a chip sitting in the middle of a line is this, and is a finding.",
      "A count's own row mistakable for a line of the program. It carries no line number and no gutter marker, and it must not read as source that has lost its number.",
    ],
    watchFor: [
      "Density. This is the highest information density anywhere in the product — code, gutter, execution markers and up to five value labels on one row — and it is the case most likely to collapse into an undifferentiated stripe. Say whether the row still has a readable structure.",
      "The label's own internal hierarchy: the NAME should recede and the VALUE should not. If they read at one weight the run of labels becomes a wall.",
      "Long values. `masses=[100, 2000, 200, 100, 100, 50, 50, 14]` is a real recorded value on line 5 — describe what happens to it and whether the answer is legible.",
      "Whether the rail reads as part of the Code pane or as a bar that has landed on top of it. It is above the listing rather than at the loop's own header line, because the served window usually starts below that line.",
      "Light theme specifically: the change hue is the Values pane's `changed` mark, and it has to survive against the code surface as well as against the pane body.",
      "Whether a reviewer can tell, from the screenshot alone, that the values are RECORDED rather than computed by the page. If nothing on screen distinguishes them from a plausible fiction, that is a finding — it is the product's central claim.",
      "You are looking at the SAME PIXELS as `debugger--source-pane` at this size and theme — the two views share a clip and the captures are byte-identical by design. That is one pane judged against two questions, and yours is the VALUES question only: are the recorded values legible beside the code, and does the rail say which pass they belong to? Do not re-report the source renderer's findings here; they belong to the other block, and a finding filed twice is counted twice by the gate.",
    ],
  },

  {
    id: "debugger--omniscience-earlier-pass",
    summary:
      "The same pane with the loop rail moved to the loop's FIRST pass, reached by following a link. The whole of it works with no JavaScript, which is what makes the iteration control available on the capability ladder's bottom rung.",
    spec: "Page-Descriptions §8, §14.2, Omniscience-Flow.md (Loop Slider Control)",
    register: "debugger",
    inherits: ["debugger-pane"],
    mustShow: [
      "The rail reading `Iteration 1 of 8` — the selection followed the link.",
      "DIFFERENT values against the same lines than `debugger--omniscience` shows. This is the whole point of the capture: pass 1 wrote `remaining_shield: 10000 → 9900` where pass 3 has not written it at all.",
      "The two marks now SEPARATED: the session is still in pass 3 and the displayed pass is 1. A reviewer should be able to read both facts off the track.",
      "Lines whose values belong only to the session's pass now showing nothing, rather than showing the previous pass's numbers.",
      "The untaken-branch mark on a DIFFERENT line than `debugger--omniscience` shows. Pass 1 took the `if` arm and pass 3 took the `else`, so the `⊘` and the recession move from line 29 to line 32 — the two lines swap roles. Line 32 is also the session's own position, so on this capture one row carries both the current-line treatment and the untaken mark.",
      "The `+N` pills following the rail as well: this pass carries far more values than pass 3, so more rows have something withheld and the counts on the shared rows are different numbers. A count that did not move with the labels would be pass 3's arithmetic reported over pass 1's values.",
    ],
    mustNotShow: [
      "The same values as `debugger--omniscience`. Identical panes across the two captures means the control does nothing, which is the affordance-that-lies defect this route has removed twice.",
      "The untaken mark staying on line 29, or appearing on line 29 AND line 32 at once. Either would mean the dimming did not follow the rail — and a conditional cannot decline both of its arms.",
      "The session's own position marker moving. Selecting a pass to LOOK at is not stepping there; the current-line marker and the `here` mark must stay where the session is.",
      "Any suggestion that the session has moved — a changed step counter, a changed current line, a changed call trace.",
    ],
    watchFor: [
      "Whether it is obvious that the pane is showing a pass the session is NOT in. If the two states are indistinguishable without comparing screenshots, the second mark is not carrying its weight.",
      "Whether the selected segment is legible as selected at this size — it is a small target in a dense bar.",
    ],
  },

  {
    id: "debugger--loading-phases",
    summary:
      "Phased, honest loading — fetching, then opening, then positioning. Never an indeterminate spinner. Captured as the identity bar, which is where the whole loading account now lives: the phase rail, the controls' status and the inert stepping buttons.",
    spec: "Page-Descriptions §8, Trace-Processing §3.2",
    register: "debugger",
    // `debugger-pane`, deliberately — even though this view's clip (`.dbgbar`)
    // IS the identity bar, which is the one thing `debugger-shell` requires
    // that the other clipped views cannot show.
    //
    // Two reasons. First, `debugger-shell`'s bar item would be REDUNDANT here
    // and weaker than what is already below it: the mustShow list names the
    // phase word, the phase sequence, the quantified wait, the controls' inert
    // state and the identity, which is the bar's contents in far more detail
    // than "carrying the transaction identity … and the stepping controls".
    // Second, `debugger-shell`'s third item — "every pane region BELOW the
    // identity bar is a pane … no page-level scrollbar" — is exactly as out of
    // frame here as it is in a pane clip: this capture is the bar and nothing
    // under it. Inheriting `debugger-shell` would hand a reviewer one duplicate
    // requirement and one unreviewable one.
    //
    // What `debugger-pane` contributes is the part that does survive: the
    // product register, the bar as a bounded self-contained strip rather than
    // the explorer header, that it is populated, and — the item that matters
    // most for this view — that the rest of the viewport being out of frame is
    // not a finding.
    inherits: ["debugger-pane"],
    mustShow: [
      "A NAMED PHASE, in words, matching the phase the capture pins — fetching, opening or positioning. The name is the requirement; its absence is the P1 this view exists to catch.",
      "The phase sequence shown as a sequence, with the current member marked, so the visitor can see which phase they are in and what remains.",
      "What is being waited for, QUANTIFIED — the engine's size — so 'loading' is not an indeterminate spinner wearing words.",
      "The stepping controls rendered visibly inert, and inert AS CONTROLS: a disabled surface, a disabled foreground, and their state on the accessibility tree. Their appearance is what must carry it (changed 2026-08-29; a paragraph above the session used to).",
      "The transaction identity already present in the identity bar during loading.",
    ],
    mustNotShow: [
      "An indeterminate spinner as the only loading signal. Page-Descriptions §8 rules this out by name.",
      "A percentage, unless it is genuinely derived and labelled as an estimate.",
      "A blank viewport, or a skeleton. The panes behind this bar are already FULL — the route serves a positioned first frame from published data — so grey boxes shaped like content we already have would be a worse page, not a loading state.",
      "A full-width band of prose explaining why the controls cannot act. Removed 2026-08-29; the controls say it themselves now.",
    ],
    watchFor: [
      "The bar has to carry identity, controls, scrubber, status, phase rail and two actions at once. Say whether the loading account is findable in it, or whether it has become one small item among many.",
      "The phase rail's prominence: it is the sequence §8 requires and is usually rendered at label size in a muted colour, beside a toolbar that is visually louder than it.",
      "Compare against the `debugger` view: the loading account and the session are now the same strip, so judge whether a visitor can tell at a glance that stepping is not yet possible.",
    ],
  },

  {
    id: "debugger--narrow",
    summary:
      "The reduced, read-only narrow session — Code + Call Trace + Values, with the limitation stated in the UI.",
    spec: "Page-Descriptions §13",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A STATEMENT IN THE UI that this is a reduced session and what is missing. §13 says 'and says so'; an unannounced reduction is the P1 here.",
      "Exactly the three specified panes reachable: Code, Call Trace, Values. The event log is removed at this width, not present-and-broken — and its TAB is removed with it, because a tab that selects a hidden pane is a dead control. The Call Trace's strip is left naming one pane, which is what serves as its header here.",
      "A working way to move between the three panes at this width (tabs, an accordion, or a switcher) rather than three stacked panes each 100 px tall.",
      "Read-only presentation — the stepping controls absent from the identity bar, consistent with the stated limitation. They are removed rather than shrunk (changed 2026-08-29: they are removed from the BAR now, which is where they live).",
      "The phase rail still present in the bar. A narrow visitor is waiting on the same engine and is owed the same account of it; §8's 'phased and honest' is not a desktop-only requirement.",
    ],
    mustNotShow: [
      "The full desktop pane layout squeezed into 375 px.",
      "Horizontal page scroll.",
      "A reduced session that silently drops a pane with no statement.",
    ],
    watchFor: [
      "This is meant to be its own design rather than a squeeze (VD.8). Judge it as a designed narrow surface and say whether it reads as one.",
      "Source at 375 px: line length, gutter cost, and whether horizontal scroll inside the code container is offered.",
      "The limitation statement's tone — informative, not apologetic.",
    ],
  },

  {
    id: "debugger--truncated",
    summary:
      "The trace-truncated banner over a fully usable session, with the option to request a deeper profile. Its subject is a transaction whose PUBLISHED recording stopped at the profile's budget — the demo tree sets `execution.truncated` on one manifest (generator txG) — and the route reads that flag. Until 2026-08-30 this view was pending and its URL carried a `&state=truncated` that a static file server could not act on, so capturing it would have photographed an ordinary session and been graded for the missing banner.",
    spec: "Page-Descriptions §14 (Trace truncated)",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A banner stating the trace is truncated, and where — a step count, a depth, or a size, so 'truncated' is quantified rather than asserted. The quantity comes from the manifest, and the banner names both the step count and the frame count the recording reached.",
      "The option to request a deeper profile, as an action.",
      "The debugger fully usable behind the banner, with its panes populated. Truncated is not broken, and the wording must make that plain — everything before the budget is complete and steps normally.",
      "An indication in the trace surface itself — the timeline or call trace — of where the truncation falls, so the boundary is not only announced in the banner.",
      "The transaction's own status unaffected: this transaction SUCCEEDED, and the degradation is in the recording of it. A reviewer must be able to tell 'the recorder ran out of budget' from 'the transaction failed'.",
    ],
    mustNotShow: [
      "The banner as an error.",
      "A modal blocking the session.",
      "A truncation announced with no quantity.",
      "Any suggestion that the transaction itself failed, reverted or is untrustworthy. Truncation is a property of the recording; conflating the two is a P1 tone failure and the specific confusion this view exists to rule out.",
      "A divergence treatment. This is a different §14 row from `debugger--divergent` and the two must not be reported as the same finding: divergence says the recorder and the chain disagreed, truncation says the recorder stopped early.",
    ],
    watchFor: [
      "Banner height against the session's vertical budget — the debugger is desktop-dense and every row the banner takes comes out of a pane. This view is captured at all four viewports for that reason; say what the banner costs at 375px.",
      "Whether this banner and the divergence banner share one treatment; they should be one component at two severities, not two designs. Both are now capturable against real published data, so the two images can be compared directly.",
    ],
  },

  {
    id: "debugger--divergent",
    summary:
      "The non-dismissible divergence banner above the debugger, naming the specific mismatch.",
    spec: "Page-Descriptions §14 (Divergence detected), §8",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A banner above the debugger naming the SPECIFIC mismatch — which value, which step, expected versus observed. 'A divergence was detected' alone is not this state.",
      "No dismiss control. §8 says it cannot be dismissed, so a close button present is a P1 against the spec.",
      "The session still open and steppable beneath it.",
      "A severity treatment stronger than the truncation banner's — this is the one state where the replay may be wrong.",
    ],
    mustNotShow: [
      "A dismiss or close affordance.",
      "The banner rendered at the same weight as an informational notice.",
      "A generic error box with no mismatch detail.",
    ],
    watchFor: [
      "Non-dismissible means permanent screen cost; check the banner is as compact as its severity allows.",
      "The mismatch detail is technical content inside a banner — check it is legible and does not overflow the banner at laptop width.",
    ],
  },

  {
    id: "debugger--no-session",
    summary:
      "The `/debug` ADDRESS of a transaction that has no session to open — the on-demand case. The route is served for every transaction, not only for the ones with a trace, and until 2026-08-30 no named view pointed at it: the one surface in the debugger register whose job is to NOT be a debugger had never been captured.",
    spec: "Page-Descriptions §7.0, §8; Debugger-Integration §3",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "The identity bar with the transaction's identity, status and block — the facts survive the register's collapse even where no session opens.",
      "The metadata pane, populated. §8 requires it 'in every state, including the states where no session can open'.",
      "In the region the panes would have occupied: a titled statement of what state this is, the reason in words, and the generate action with its cost stated. Not an empty region, not a debugger shell with blank panes.",
      "A region that reads as DELIBERATE at the shell's full width — one pane where four would be is the layout most easily mistaken for a debugger that failed to load, and telling those apart is what this image is for.",
    ],
    mustNotShow: [
      "A stepping toolbar, a scrubber, a phase rail or a step counter. §7.0's 'no pretence of one' means the controls are absent, not inert: `identityBar` gates the whole control group on `hasFrame`.",
      "Share or download actions. There is no position to share and no container to download.",
      "Empty pane frames, skeleton boxes, or a grid of blank panels where the debugger would be.",
      "An error or danger treatment. Nothing has failed; this trace has not been generated.",
    ],
    watchFor: [
      "The vertical shape: the pane region is full-height and the statement inside it is a few lines. Say whether that reads as a considered empty state or as content that failed to arrive, and where the eye goes first.",
      "Whether the identity bar looks broken with its centre removed. The control group is the largest thing in that strip on every other debugger view, and this is the view where it is legitimately gone.",
      "Both themes: the statement pane is the only lit surface in the region, so the surface ladder is doing all the work.",
    ],
  },

  {
    id: "debugger--no-session-terminal",
    summary:
      "The same address for a transaction whose trace can never exist — §7.0's `absent` row in the debugger register. The pair to `debugger--no-session`, and the difference between them is one control.",
    spec: "Page-Descriptions §7.0 (row 3), §14, §14.1a",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "The identity bar and the populated metadata pane, as in `debugger--no-session`.",
      "A titled statement naming the state and a reason saying the absence is structural and permanent.",
      "NOTHING actionable in the region. The absence of the Generate control is the subject of this image — §14 forbids 'a retry that cannot succeed' and §7.0 forbids the pretence.",
    ],
    mustNotShow: [
      "Any action, enabled or disabled, in the pane region or the identity bar.",
      "A stepping toolbar, scrubber, phase rail or step counter.",
      "Wording that implies a wait.",
      "A treatment indistinguishable from `debugger--no-session`'s beyond the missing button — the two states differ in kind, and a reader should be able to tell which one they are on from the words.",
    ],
    watchFor: [
      "Compare directly with `debugger--no-session` and state what a visitor could tell apart at a glance. If the answer is 'one button', say so — that is a finding about whether the terminal state is designed or merely stripped.",
      "A pane region whose only content is a sentence, at full viewport height. This is the emptiest surface the product ships. Judge whether it is composed.",
    ],
  },

  // ══════════ §6.0a — where the link landed, and what it said (VD.7) ══════════
  //
  // Five blocks for five branches of one decision. The reviewer's job across
  // them is comparative and is stated in each `watchFor`: four sentences must
  // be tellable apart, three of them describe a session that is FINE, and the
  // fifth branch must produce no sentence at all.
  //
  // These are the first images of a hydrated page in the corpus. The brief's
  // generated table says so per view — see `render-brief.mjs` — because a
  // reviewer who does not know a page carries script cannot tell an intended
  // absence from a build that never ran one.

  {
    id: "debugger--link-exact",
    summary:
      "§6.0a step 2: the link's content witness matched the current trace, so its coordinate was honoured exactly and NOTHING is said about it. The control image for the other four — 'every branch below (2) is visible' is a claim about a difference, and this is the other side of it.",
    spec: "Debugger-Integration §6.0a (step 2), §6.0, §6.3",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "An ordinary, complete debugging session at the linked position — panes populated, the identity bar intact. This image's subject is that following a good link produces a page indistinguishable from arriving at it any other way.",
      "The stepping controls in their pre-engine inert rendering, and the phase rail naming a phase. The engine has not answered yet, and that is the state this capture pins.",
      "The call trace's current row and the source pane agreeing on where the session is. The link asked for a position; this is the page saying it got there, by showing it rather than by claiming it.",
    ],
    mustNotShow: [
      "ANY position notice, banner or badge about the link. This is the one branch §6.0a lets be silent, and a notice here would be the noise that trains a reader to ignore the four that matter. Present ⇒ P1.",
      "An engine-failure banner. The deadline has not been reached in this capture.",
      "ANY visible difference from `debugger` at the same size and theme. This capture is expected to be BYTE-IDENTICAL to it, and in the 2026-08-31 regeneration it was — same sha256, all four size/theme combinations. Anything you can see that `debugger` does not have is therefore a finding, not an allowance.",
    ],
    watchFor: [
      "Put this image beside `debugger--link-recovered-by-anchor` at the same size and theme. The ONLY difference should be the presence of the notice band. If the rest of the page also moved, the notice is displacing the session rather than sitting above it, and that is a finding about the band's cost.",
      "This block previously asked you to judge §13's copy affordances here, on the grounds that this was the first captured page carrying hydration. That instruction was WRONG and has been removed rather than left to be discovered: the engine scenario for this view is `silent`, the affordances do not render until the engine answers, and the capture is byte-identical to the non-hydrated `debugger`. There are no copy affordances in this image. Do not look for them, and do not report their absence — the corpus has no view that shows them, which is a coverage gap recorded against the harness and not a defect in this page.",
      "What this image IS good for is the negative claim, and it is a strong one: following a link that resolved exactly must leave no trace of itself. Read the page as a first-time visitor and say whether anything at all hints that a coordinate was supplied.",
    ],
  },

  {
    id: "debugger--link-recovered-by-anchor",
    summary:
      "§6.0a step 3: the trace was regenerated since the link was made, so the coordinate is not trusted — but the link's recovery anchor still resolves, and the session opens exactly where it named. The best outcome after an exact hit, and it has to read that way.",
    spec: "Debugger-Integration §6.0a (step 3), §6.0 (the content witness)",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A notice stating that the position was RECOVERED, naming the anchor kind it was recovered from and the reason the coordinate was not used. All three parts: an outcome, a mechanism and a cause.",
      "A complete, usable session behind the notice — the recovery succeeded, so nothing about the page is degraded.",
      "A treatment that is visibly NOT the divergence banner and NOT the truncation banner. Those are verdicts about the trace and stay true; this is one sentence about the link, on arrival.",
    ],
    mustNotShow: [
      "Error styling — a red or danger tone, a warning glyph, an alert role's visual vocabulary. `renderPositionNotice` is `role=\"status\"` and says why: 'nothing is wrong. A recovered position is the product working as designed.' A notice that looks like an error here is a P1.",
      "A dismiss control that cannot act, or any control at all. The notice is a statement.",
      "Wording that asks the reader to do something. There is nothing to do; the link worked.",
    ],
    watchFor: [
      "Read the sentence as prose, out loud. It is assembled from two fragments ('recovered from the link's … anchor because …') and the seam is the risk. Say whether it reads as one sentence a person wrote.",
      "'call' as an anchor kind is a wire spelling. Judge whether a visitor who has never read §6.0a can tell what a 'call anchor' is, or whether the sentence is true and opaque.",
      "Both themes: the notice's surface against the identity bar above it. A sibling round found that all five dark `status.*-bg` roles resolve to one neutral, so severity in dark is carried by text colour and a hued left rail. State whether this notice is distinguishable in dark from a banner that means something is wrong.",
    ],
  },

  {
    id: "debugger--link-nearest-frame",
    summary:
      "§6.0a step 4: the anchor names a frame this trace no longer has, so the session opens on the frame that ENCLOSES it and says so. A weaker claim than step 3 and a deliberately different sentence — and still a benign outcome, not a failure.",
    spec: "Debugger-Integration §6.0a (step 4)",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A notice saying the anchor could not be resolved AND that the nearest enclosing frame is shown instead. Both halves: what did not work, and where the reader therefore is.",
      "A complete, usable session at that enclosing frame, with the call trace's current row visible so the notice's claim is checkable on the page.",
      "A treatment that is legible as INFORMATION about the landing, at the same weight as `debugger--link-recovered-by-anchor`'s — the two are neighbouring steps of one precedence and must not be styled as different severities.",
    ],
    mustNotShow: [
      "Anything that reads as an error, a failure or a warning. This is the view that most tempts an error treatment and must not carry one: the link was honoured, approximately, and the page is fully usable. An error tone here is a P1.",
      "An offer to retry, reload, or 'find the exact position'. There is no exact position to find; §14 forbids a retry that cannot succeed.",
      "A sentence indistinguishable from step 3's. 'Recovered from the anchor' and 'the anchor did not resolve, here is the enclosing frame' are different facts, and a reader must be able to tell which happened.",
    ],
    watchFor: [
      "THE question for this view: does a reader who lands here think something went wrong? Answer it explicitly. Consider the tone, the placement, the colour, and the first three words.",
      "Whether the enclosing frame is identified anywhere a reader can see it — the notice says 'the nearest enclosing frame' without naming which. Say whether the page makes that discoverable or leaves it as a claim.",
      "Compare with `debugger--link-recovered-by-anchor` side by side. If the two images are distinguishable only by reading the full sentence, that is a finding about the family, not about either image.",
    ],
  },

  {
    id: "debugger--link-start-of-execution",
    summary:
      "§6.0a step 5: neither the coordinate nor the anchor survives, so the session opens at the start of the execution and the notice names WHICH of the four reasons applies. The weakest landing, and the one whose sentence must not overclaim.",
    spec: "Debugger-Integration §6.0a (step 5), §6.0 (the witness table)",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A notice stating that the session is showing the execution FROM ITS START, and the specific reason — not a generic 'the position could not be restored'. `resolvePosition` spends a paragraph on why: 'could not be restored' is true of a regenerated trace and false of an older link whose coordinate may still be correct and merely cannot be checked.",
      "A complete session behind the notice, with the call trace and the source pane populated. The landing is the weakest one §6.0a offers and the page is still the whole first frame the route serves.",
      "The notice as a statement about the LINK, not about the trace. The transaction and its recording are fine.",
    ],
    mustNotShow: [
      "A confident claim that the position was lost or is wrong, where the truth is that it could not be verified. This is the specific overclaim §6.0a is written to prevent.",
      "An error or danger treatment. The session opened; the page is complete.",
      "A retry, a 'try the original link' affordance, or anything else that cannot succeed.",
    ],
    watchFor: [
      "This sentence is the longest of the four and is assembled from three clauses joined by an em dash. Judge it as copy: whether it survives being read once, and whether the reason and the outcome are both findable at a glance or only at the end.",
      "THE SENTENCE AGAINST THE PANES, found on this view's first capture. The notice says the execution is shown from its start; the panes behind it are the SERVED frame, which is mid-trace — the call trace's current row is inside `calculate_damage` and the source pane is on the mid-trace line. §6.0a resolves before a byte of the engine is fetched, and the session is only MOVED to the resolved coordinate once the engine answers (`hydrate.goLive` → `gotoTicks(h.landing.coordinate)`). So the sentence is a statement about where the session will be, rendered beside a session that is somewhere else, for as long as the engine takes — and in this capture, which pins the pre-engine state, permanently. Say whether a reader is misled and by how much, and whether the fix belongs in the sentence's tense or in what the page does with the coordinate before the engine lands.",
      "Whether the notice's length changes the page's composition at this size — a three-clause sentence in a band above a session is the case where the band stops being a strip.",
      "Compare its first words with the other three notices. All four begin inside the same band with the same title; say whether the title plus first clause is enough to tell them apart without reading on.",
    ],
  },

  {
    id: "debugger--link-not-replayable",
    summary:
      "§6.0a step 1: a shared link into a transaction with no replayable artifact. Terminal, and the only branch that renders on a page with no panes — the notice lands on the no-session region, over a transaction that can never be debugged.",
    spec: "Debugger-Integration §6.0a (step 1), Page-Descriptions §7.0 (row 3), §14",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A notice saying the execution is not replayable AND that the linked position therefore cannot be shown. The link is answered, not ignored.",
      "The reassurance the sentence carries — that the transaction itself is unchanged — landing on a page that demonstrably still shows the transaction. The claim and its evidence must be in the same frame.",
      "The no-session region beneath it, with the identity bar and the metadata pane, exactly as `debugger--no-session-terminal` renders them.",
    ],
    mustNotShow: [
      "Any stepping toolbar, phase rail, scrubber or step counter. There is no session and none is coming.",
      "Any action — generate, retry, request. §7.0 gives this row 'no debugger, and no pretence of one'; §14 forbids a retry that cannot succeed.",
      "Two statements saying the same thing in different words. The region already carries a titled statement about why there is no session; a notice that merely repeats it is redundancy, not honesty.",
    ],
    watchFor: [
      "The stacking. This page now shows the region's own statement AND the link notice, one above the other, both about the absence of a session. Say whether they read as one account or as two systems each having their say.",
      "Whether the notice's placement makes sense when the thing it sits above is not a session. Its slot is the same one it uses on a live page; judge whether that placement still reads deliberately here.",
      "The tone against `debugger--link-nearest-frame`. This one IS terminal and the other is benign. If they carry the same treatment, the family has flattened five outcomes into one voice.",
      "The sentence's scope. `resolvePosition` step 1 has ONE sentence — 'This execution is not replayable' — and reaches it from `artifactAvailable = false`, which is true of all three §7.0 rows without a container: `absent`, `unsupported` AND `onDemand`. This image is the `absent` one, where the sentence is exactly right. Verified on the same build: the same link into the on-demand transaction renders the same sentence over a page offering a Generate control, where 'not replayable' is false — it is not replayable YET. Say whether the sentence should name which of the three it is, given that §14.1a's rule is that presenting any of them as another is the failure the catalogue exists to prevent.",
    ],
  },

  // ══════════ The replay engine will not run (VD.7) ══════════
  //
  // Three faults, three sentences, three blocks. The reviewer's comparative job
  // is the reason they were separated in the source: an engine that never
  // arrived and an engine that arrived and refused the container have different
  // fixes, and one sentence covering both cost hours.
  //
  // A note each block repeats, because it decides how the image may be graded:
  // the ENGINE in these captures is a harness stand-in and nothing in the image
  // is drawn by it. The banner is `components/debugger.renderEngineFailure`
  // over a string from `hydrate.nim`, on the page the real exporter wrote. The
  // brief's table states this per view.

  {
    id: "debugger--engine-worker-missing",
    summary:
      "Nothing is served at the engine's path: the worker module 404s and the page says so, within a second of load, in a banner. The state every build of this repository is in until the engine is copied to its own origin.",
    spec: "Page-Descriptions §8, §14 (terminal state with a reason), §14.2 (the ladder), CodeTracer-Embed-SDK §5.1",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A banner stating that the replay engine is unavailable AND naming the path that failed. The URL is the fact that matters — a missing or misconfigured `replayEngineBase` is almost always the cause — and `startWorkerImpl` carries it precisely because the browser's own ErrorEvent has nothing in it.",
      "The surviving rungs of §14.2's ladder still on screen and still usable: the container download in the identity bar, and the static call and event summary that is this whole page. A page that loses them has degraded below the pre-hydration page, which §7.0 forbids.",
      "The stepping controls rendered inert and SAYING they are inert — not merely greyed while the banner explains elsewhere.",
      "The phase rail GONE. `markUnavailable` removes it deliberately: 'a rail still pointing at Fetching beside a control that says the engine cannot start is the page contradicting itself.' Its absence here is correct and is NOT a finding.",
    ],
    mustNotShow: [
      "A retry control, a reload prompt, or anything else that cannot succeed. §14: 'a terminal state with a reason, never a retry that cannot succeed'.",
      "A spinner, a progress bar, or a phase rail still naming a phase.",
      "The reason living only in a tooltip or on the accessibility tree. That was the defect this banner was added to fix: a pointer user had to hover an inert button, a touch user could not reach it, and a screen-reader user was told more than a sighted one.",
      "An apology as the dominant content. The page below the banner is a useful one.",
    ],
    watchFor: [
      "Read the sentence: 'The replay engine did not start: the worker script at /replay-engine/worker.js could not be loaded.' It said 'stopped' until this view was first captured, which told a reader the engine had run and died. Judge the replacement: whether the two clauses say one thing or two, and whether the second is the reason for the first.",
      "Whether a raw URL path in a visitor-facing sentence reads as a diagnosis or as a leaked internal. It is genuinely the actionable fact for an operator; say who this sentence is written for.",
      "The banner's weight against the divergence banner (`debugger--divergent`). Both are `role=\"alert\"` page-level verdicts; say whether a reader could tell 'the recorder and the chain disagreed' from 'the engine did not load' by treatment alone.",
      "Both themes. A sibling round found the five dark `status.*-bg` roles all resolve to one neutral, so a danger banner and a warning banner share a surface and severity is carried by text colour plus a hued left rail. Say whether the rail is doing enough here.",
    ],
  },

  {
    id: "debugger--engine-never-loaded",
    summary:
      "§8's deadline, first sentence. Something answers at the engine's path but no engine ever does — the session would otherwise sit in a named phase for as long as the tab is open, which is a spinner with a name. After 45 s the page stops implying an engine is coming.",
    spec: "Page-Descriptions §8 (phased, honest loading), §14, Debugger-Integration §7",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A banner stating that the engine NEVER LOADED and naming the base URL it was expected from, plus what is still possible: the container can be downloaded and opened in CodeTracer.",
      "The ladder's surviving rungs — the download affordance and the static summary — present and usable.",
      "The stepping controls inert and saying so; the phase rail removed, for the reason `markUnavailable` removes it. Its absence is correct.",
      "A page that is otherwise complete. This is a terminal state on a useful page, not an error screen.",
    ],
    mustNotShow: [
      "Any retry, reload or 'try again' affordance.",
      "A phase rail, a spinner or a progress indicator of any kind.",
      "Wording that blames the visitor's connection, or that suggests waiting longer. The deadline exists precisely because waiting longer will not help.",
      "A sentence that could equally describe `debugger--engine-refused-container`. These two faults were given different sentences after one shared sentence cost hours of misdiagnosis; if a reader cannot tell them apart, that regression has returned in the design.",
    ],
    watchFor: [
      "Put this image beside `debugger--engine-refused-container` at the same size and theme and answer one question: from the page alone, could a reader tell which of the two faults occurred, and could they tell what to do differently? That comparison is the whole reason these are two views.",
      "'Nothing answered at that path' — judge whether that is legible to a non-operator, and whether the sentence's three clauses are in the order a reader needs them.",
      "The 45-second wait is invisible in a still image. Say whether the page reads as something that has given up after trying, or as something that never tried.",
    ],
  },

  {
    id: "debugger--engine-refused-container",
    summary:
      "§8's deadline, second sentence. The engine loaded, is running and is reachable — and it will not open THIS container. The fault the old shared sentence hid, and the reason the three sentences exist as three strings.",
    spec: "Page-Descriptions §8, §14, Debugger-Integration §7, dap_dialect §6",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A banner stating that the engine LOADED and would not open this trace container — both halves. 'The engine is running and reachable' is the half that makes this a different diagnosis from `debugger--engine-never-loaded`, and dropping it would recreate the defect.",
      "What is still possible, stated: the container can be downloaded and opened in CodeTracer. The ladder's floor is intact.",
      "The ladder's surviving rungs on screen — the download affordance in the identity bar, and the static call and event summary that is this page.",
      "The stepping controls inert and saying so; the phase rail removed.",
    ],
    mustNotShow: [
      "Any retry or reload affordance. The engine will refuse the same container again.",
      "A phase rail, spinner or progress indicator.",
      "A sentence indistinguishable from `debugger--engine-never-loaded`'s. This is the specific regression the separation prevents.",
      "Any suggestion that the trace is corrupt or that the transaction is at fault. The container is fine; this engine build will not read it.",
    ],
    watchFor: [
      "The comparative read against `debugger--engine-never-loaded` — the same question, from this side. Which of the two sentences lands faster, and does the difference between them survive being skimmed?",
      "'it rejected the container's format' is the actionable half for whoever can fix this, and is the half a visitor can do nothing with. Judge whether the sentence serves both readers or neither.",
      "Whether 'loaded but would not open' reads as a fault in the product or as a fault in the trace. It is the former, and a reader who concludes the latter has been misled by the copy.",
      "Both themes, and the banner against the identity bar above it. Note whether the failure banner and the divergence banner are separable in dark.",
    ],
  },

  {
    id: "debugger--copy-affordance",
    summary:
      "§13's one-click copy button, on the build that actually has one. The hydration bundle upgrades every full value and every truncated identifier into a `role=\"button\"` copy control; the stylesheet those pages inline has no rule for the class it adds. This is the first view whose subject exists only on the build a visitor loads, and the reader it is graded for is the one the page has already told that this is a button.",
    spec: "Page-Descriptions §13 (copyable with one click), §7.1; client/hydrate/hydrate.nim upgradeCopyAffordances; debugger/session_view.nim Copyable",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A FOCUSED copy control. The capture focuses the truncated identifier's control (`[data-copy].copybtn`) and fails rather than shoots if that element is absent, so something on this page is holding keyboard focus. Find it first — everything else in this block is about what it looks like.",
      "The truncated identifier itself, still readable. Whatever the upgrade does, it must not cost the value its legibility, and a treatment that obscured the very string the control copies would be worse than no treatment. The value is route-specific: this view resolves to the demo chain's ready transaction and the identity bar renders it `0xb63616…6359`. Do NOT check a literal hash against this block — check that the identifier is legible.",
      "The panes and the provenance row as every other debugger view shows them. The bundle does not rewrite them before the engine answers, so a difference HERE — in the Code, Call Trace, Values or Transaction panes — would be a finding about hydration and is worth filing as one.",
      "The engine-loading readout and the live phase rail — `Engine loading — 18 MB`, `FETCHING` — which are SERVER-RENDERED and appear identically on the plain build. They are not hydration's doing and they are not this view's subject; `debugger--loading-phases` is the view that grades them, and it is a plain-build capture of the same state. Present here, expected here, not a finding here.",
    ],
    mustNotShow: [
      "A copy control that has moved, resized or reflowed anything around it. The upgrade adds attributes and a class to an element the server already rendered; if the page relayouts when script runs, that is a visible layout shift on every debug page a visitor opens, and it is a P1.",
      "A confirmation, tick, toast or error state. Nothing has been clicked in this capture. `.copied` and `.copyfailed` are applied only on a clipboard result, and either of them appearing in this still would mean the capture photographed an interaction it did not perform.",
      "An engine-FAILURE banner, or a §6.0a landing notice. Distinct from the loading state above: this view opens an exact-hit link with a silent engine precisely so the notice has nothing to say and the deadline never trips, and either one arriving would put a second subject in the frame.",
    ],
    watchFor: [
      "THE CENTRAL QUESTION, and answer it in as many words as it takes: does the focused element read as a button? The page has given it `role=\"button\"` and `tabindex=\"0\"`, so a screen reader announces a button and the tab order stops here. Say what a sighted keyboard user actually sees at that stop, and whether the two accounts of this element agree.",
      "Compare it with the controls this register already draws — the stepping chips in the identity bar, `.dcbtn`, the `Supply sources` pill. Those are the vocabulary a reader has been taught on this surface. Is the focused element in that vocabulary, adjacent to it, or outside it entirely?",
      "THE RESTING STATE, which is what a pointer reader gets and what this element is in for all but one moment. `.copyable` values carry `cursor:copy` and a hover surface from the pre-hydration affordance; the two truncated `[data-copy]` identifiers carry neither, and they are the pair for which the clipboard is the ONLY route to the full value. Judge whether a visitor with a mouse has any way to discover that.",
      "Whether the page would be BETTER if the upgrade drew nothing and claimed nothing. §13 wants the button; this view is where the cost of promising one and not drawing it can finally be seen rather than argued about. A reviewer who concludes the promise is worth keeping should say what it should look like.",
      "The ring itself, in both themes, WITHOUT assuming who drew it. It is the product's own: `styles.nim`'s `:where(a,button,input,select,textarea,summary,[tabindex]):focus-visible` matches the `tabindex` the bundle adds, so `--bt-focus-ring` applies — and `web.tokens.json` calls focus \"one treatment for BOTH registers … colour is per-theme; geometry is not\". So the question is not whether the design system reaches this element. It is whether a focus ring, on its own and with no resting treatment under it, is a control vocabulary. Note also which token each theme's ring resolves THROUGH; they are not the same family.",
    ],
  },

  // ══════════ Degraded states on the transaction page (§14, §14.1, §14.1a) ══════════

  {
    id: "tx-detail--trace-awaiting",
    summary:
      "Trace awaiting generation — the entry state of the generation job, with observable phases.",
    spec: "Page-Descriptions §14, §14.1",
    register: "explorer",
    inherits: ["tx-page-intact", "generation-job", "site-chrome"],
    mustShow: [
      "A job surface with its phases enumerated so the visitor can see the whole sequence, not only the current step.",
      "The sections that depend on the trace (internal calls, state changes) showing the specified single line rather than empty panels.",
    ],
    mustNotShow: [
      "A bare spinner.",
      "A progress percentage across the recorder run.",
    ],
    watchFor: [
      "This is the state a visitor waits in, so it is the one that must not look like a stall. Judge whether the surface communicates ongoing work without animation (the capture has motion disabled — say whether the state is legible as active WITHOUT it).",
    ],
  },

  {
    id: "tx-detail--job-accepted",
    summary:
      "Generation accepted — the request was taken, quota consumed, and the visitor can still cancel.",
    spec: "Page-Descriptions §14.1 (accepted)",
    register: "explorer",
    inherits: ["tx-page-intact", "generation-job", "site-chrome"],
    mustShow: [
      "The phase word 'accepted' or its plain-language equivalent, distinguishable from 'queued'.",
      "A CANCEL control, enabled — accepted is cancellable and cancellation releases quota.",
      "A statement that quota was consumed, and that cancelling releases it.",
    ],
    mustNotShow: [
      "A cancel control that is absent or disabled.",
      "A queue position — that belongs to `queued`, and showing it here collapses two distinct states.",
    ],
    watchFor: [
      "Four of these job states are near-identical in structure and differ only in one word and one control. Say explicitly what distinguishes THIS capture from the queued one; if you cannot, that is the finding.",
    ],
  },

  {
    id: "tx-detail--job-queued",
    summary: "Generation queued — waiting for a worker, with the queue position known.",
    spec: "Page-Descriptions §14.1 (queued)",
    register: "explorer",
    inherits: ["tx-page-intact", "generation-job", "site-chrome"],
    mustShow: [
      "The phase word 'queued'.",
      "The QUEUE POSITION as a concrete number — §14.1 says 'position known', and a queued state without a position is the accepted state relabelled.",
      "A cancel control, enabled.",
    ],
    mustNotShow: [
      "A queue position rendered as a vague phrase ('soon', 'shortly') instead of a number.",
      "A disabled cancel control.",
    ],
    watchFor: [
      "The position number is the only content that distinguishes this state visually; check it is given enough prominence to do that job.",
    ],
  },

  {
    id: "tx-detail--job-recording",
    summary:
      "Recording — the recorder is executing the transaction. The compute is being spent, so cancellation is gone.",
    spec: "Page-Descriptions §14.1 (recording)",
    register: "explorer",
    inherits: ["tx-page-intact", "generation-job", "site-chrome"],
    mustShow: [
      "The phase word 'recording'.",
      "NO cancel control, or a cancel control visibly disabled with the reason — the transition out of cancellability is the meaning of this state.",
      "Elapsed time, and a coarse estimate labelled as an estimate.",
    ],
    mustNotShow: [
      "An enabled cancel control. §14.1: once recording begins the compute is spent and cancellation would only hide it.",
      "A percentage across the recorder run.",
    ],
    watchFor: [
      "The disappearance of a control between states is a layout event; check the surface does not jump or leave a gap where cancel used to be.",
    ],
  },

  {
    id: "tx-detail--job-validating",
    summary: "Validating — the recorder is checking its own output.",
    spec: "Page-Descriptions §14.1 (validating)",
    register: "explorer",
    inherits: ["tx-page-intact", "generation-job", "site-chrome"],
    mustShow: [
      "The phase word 'validating', with enough plain language that a visitor understands the recorder is checking itself rather than that something is wrong.",
      "Position within the phase sequence, showing that recording is complete and publishing is next.",
      "No cancel control.",
    ],
    mustNotShow: [
      "Wording that implies a problem was found.",
      "An enabled cancel control.",
    ],
    watchFor: [
      "'Validating' is the phase most likely to be misread as 'a check failed'. Judge the copy for that specific misreading.",
    ],
  },

  {
    id: "tx-detail--job-publishing",
    summary: "Publishing — the artifact is being written and made visible.",
    spec: "Page-Descriptions §14.1 (publishing)",
    register: "explorer",
    inherits: ["tx-page-intact", "generation-job", "site-chrome"],
    mustShow: [
      "The phase word 'publishing'.",
      "Position in the sequence showing this is the last phase before ready.",
      "The retention statement — retained or windowed, and for how long — since this is the last moment before the visitor gets the trace.",
    ],
    mustNotShow: ["An enabled cancel control.", "A completed/ready presentation before the trace exists."],
    watchFor: [
      "This phase is short-lived in reality and so is the one most likely to have been designed last. Check it carries the same treatment as the other phases rather than a reduced one.",
    ],
  },

  {
    id: "tx-detail--job-refused",
    summary:
      "Refused — this will not be attempted, and here is why. Distinct from failed.",
    spec: "Page-Descriptions §14.1 (refused)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The word 'refused' or an unambiguous plain-language equivalent, and THE REASON: out of quota, chain unsupported, or below the history floor.",
      "NO retry control. §14.1: collapsing refused into failed produces a retry button that can never succeed.",
      "Whatever recourse actually exists for the stated reason — a quota reset time, a link to the recorder's status — or an explicit statement that there is none.",
    ],
    mustNotShow: [
      "A retry button.",
      "A generic failure treatment shared with `job-failed`.",
      "A reason phrased as an internal error code.",
    ],
    watchFor: [
      "Refused and failed are the pair this catalogue most wants kept apart. Compare this capture against `tx-detail--job-failed` and state whether a visitor could tell them apart without reading the body text.",
    ],
  },

  {
    id: "tx-detail--job-failed",
    summary:
      "Failed — we tried and it did not succeed. Retry is offered only when the pipeline says retryable.",
    spec: "Page-Descriptions §14.1 (failed)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A statement that generation was ATTEMPTED and did not succeed — the attempt is what distinguishes this from refused.",
      "A retry control whose presence matches the fixture's `retryable` flag, with the flag's value legible from the surface (retry present, or retry absent with a statement that this is not retryable).",
      "What is known about the failure, in language a visitor can act on.",
    ],
    mustNotShow: [
      "A retry control on a non-retryable failure.",
      "A raw error string or stack trace.",
      "Identical presentation to `job-refused`.",
    ],
    watchFor: [
      "The retry control's prominence: it is the only action, but a failed generation is not a state to encourage hammering.",
    ],
  },

  {
    id: "tx-detail--job-timed-out",
    summary: "Timed out — the job exceeded its budget.",
    spec: "Page-Descriptions §14.1 (timedOut)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A statement that the job exceeded its BUDGET, with the budget or the elapsed time quantified.",
      "A retry control gated on `retryable`, exactly as in `job-failed`.",
      "Enough distinction from `job-failed` that a visitor can see this was a time limit rather than an error.",
    ],
    mustNotShow: ["An unquantified 'timed out'.", "A retry control on a non-retryable timeout."],
    watchFor: [
      "Timed-out shares its shape with failed. Say whether the two are distinguishable at a glance and whether they should be.",
    ],
  },

  {
    id: "tx-detail--replay-expired",
    summary:
      "The replay window expired — the transaction is intact, the trace is not currently retained, and renewal is a public good.",
    spec: "Page-Descriptions §14.1a (Window expired)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A statement that replay is NOT CURRENTLY available — the 'not now' framing, explicitly distinguishable from 'not ever'.",
      "A RENEW action, behind sign-in, with the sign-in requirement stated before the click.",
      "The statement that renewal serves every subsequent anonymous visitor for the whole window — §14.1a requires the prompt to say this rather than imply a per-user unlock.",
    ],
    mustNotShow: [
      "Wording that reads as permanent unavailability.",
      "A sign-in prompt that implies the product needs an account generally.",
      "A retry control (this is renewal, not retry).",
    ],
    watchFor: [
      "The public-good sentence is the distinctive copy of this state; check it is prominent enough to be read rather than buried in fine print.",
      "Compare with `tx-detail--unreplayable`: these two are the pair §14.1a exists to keep apart.",
    ],
  },

  {
    id: "tx-detail--replay-windowed",
    summary:
      "Windowed but live — the debugger opens immediately, and the retention terms are stated anyway.",
    spec: "Page-Descriptions §14.1a (Windowed, live)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The Debug affordance ENABLED and primary — this state is functionally identical to retained, and anything that makes it look degraded is wrong.",
      "A statement of the retention window and how long remains, so a visitor who bookmarks the link knows it may need regenerating.",
      "The retention statement rendered as information, not as a warning.",
    ],
    mustNotShow: [
      "A degraded or warning treatment on a state where everything works.",
      "A disabled or de-emphasised Debug button.",
      "No retention statement at all — 'say what the user is getting' applies here even though nothing is blocked.",
    ],
    watchFor: [
      "The whole difficulty of this state is showing a caveat without implying a problem. Judge that balance specifically.",
    ],
  },

  {
    id: "tx-detail--replay-never",
    summary:
      "Never generated on an on-demand chain — the same shape as an expired window, but for a trace that has not existed yet.",
    spec: "Page-Descriptions §14.1a (Never generated)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A GENERATE action, behind sign-in, with the sign-in requirement and its justification stated — that generating a trace costs compute (§7.2).",
      "A statement that no trace exists yet for this transaction, distinct from one having expired.",
      "The retention terms the generated trace will carry, stated BEFORE the request.",
      "The trace-derived sections showing the specified single line and the Debug action that requests generation.",
    ],
    mustNotShow: [
      "A 'renew' verb — nothing has expired.",
      "A sign-in prompt with no explanation of what it is for.",
      "Empty panels for internal calls and state changes.",
    ],
    watchFor: [
      "This state converts; §7.2 says so. Judge whether the surface reads as an invitation or as a wall.",
    ],
  },

  {
    id: "tx-detail--unreplayable",
    summary:
      "Permanently unreplayable — a terminal state with a reason, and no action that could succeed.",
    spec: "Page-Descriptions §14.1a (Unreplayable)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A statement that replay is PERMANENTLY unavailable, with the reason — capsule gone, chain state unobtainable.",
      "NO action at all. §14.1a: it is terminal. A retry, renew or generate control here is the P1 this view exists to catch.",
      "The complete transaction still rendered, since the page never degrades.",
    ],
    mustNotShow: [
      "Any retry, renew, generate or sign-in affordance.",
      "Wording that leaves the door open ('not currently', 'try again later') — that is the expired state, and conflating them is the failure §14.1a names.",
    ],
    watchFor: [
      "A state with no action is the hardest to make look finished rather than broken. Judge whether it reads as a considered terminal state.",
      "Compare directly against `tx-detail--replay-expired` and state the visual difference.",
    ],
  },

  {
    id: "tx-detail--recorder-unavailable",
    summary:
      "No recorder for this VM — Debug absent, with the recorder's status and a link to its spec.",
    spec: "Page-Descriptions §14 (Recorder unavailable)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The Debug affordance ABSENT — not disabled, not greyed. §14 says absent, and a greyed button is a different design decision.",
      "The recorder's status named — which recorder, and where it stands.",
      "A LINK TO THE RECORDER'S SPEC, present and legible.",
      "The chain-level explanation, so this reads as a property of the chain rather than of this transaction.",
    ],
    mustNotShow: [
      "A disabled Debug button.",
      "A status with no link.",
      "An apology, or wording that implies the product is incomplete rather than that this VM is not yet covered.",
    ],
    watchFor: [
      "Removing the page's primary action leaves a hole in the hero. Check the hero still has a composition rather than a gap.",
    ],
  },

  {
    id: "tx-detail--below-history-floor",
    summary:
      "The transaction is below the history floor — Debug absent, and prestate does not exist below it.",
    spec: "Page-Descriptions §14 (Below the history floor)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The Debug affordance absent.",
      "The FLOOR STATED as a concrete value — a block number, a date, or a window — not the phrase 'too old'.",
      "The explanation that prestate does not exist below the floor, so a visitor understands this is a data-availability fact and not a policy.",
      "This transaction's own position relative to the floor, so the gap is legible.",
    ],
    mustNotShow: [
      "An unquantified floor.",
      "A retry, generate or request affordance — nothing below the floor can be produced.",
      "An error treatment.",
    ],
    watchFor: [
      "Two numbers (the floor, and this transaction's block) need to be comparable at a glance. Check they are presented as a comparison rather than as two facts.",
    ],
  },

  {
    id: "tx-detail--reorganised",
    summary:
      "Reorganised away — the page switches to a reorg explanation, with the new location if the transaction was re-included.",
    spec: "Page-Descriptions §14 (Reorganised away)",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A reorg explanation in plain language — what a reorganisation is and what happened to this transaction.",
      "The OLD location (the block it was in) and, where it was re-included, the NEW location as a working link.",
      "Where it was not re-included, an explicit statement of that, rather than silence.",
      "The transaction's identity, so the visitor knows the page still concerns the hash they asked for.",
    ],
    mustNotShow: [
      "A generic 'not found' — the transaction was found; its position changed.",
      "The old, now-invalid block presented as though current.",
      "An error treatment.",
    ],
    watchFor: [
      "This is the one degraded state where the page's content genuinely changes shape rather than gaining a notice. Judge whether the reorg explanation is a designed page or a notice on a stripped one.",
      "Old-versus-new location is a before/after; check it uses the same directional vocabulary as the state-changes diff.",
    ],
  },

  {
    id: "tx-detail--quota-exhausted",
    summary:
      "Quota exhausted — a distinct state from not-signed-in, which says when the quota resets.",
    spec: "Page-Descriptions §7.2 Hero, §14.1",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A statement that the visitor's generation quota is exhausted — signed in, but out of allowance.",
      "WHEN THE QUOTA RESETS, as a concrete time or duration. §7.2 requires this explicitly.",
      "The generate affordance visibly unavailable, with the quota as the stated reason.",
      "Enough distinction from the sign-in state that a signed-in visitor is not asked to sign in again.",
    ],
    mustNotShow: [
      "A sign-in prompt.",
      "An unquantified 'try again later'.",
      "The state collapsed into a generic 'refused'.",
    ],
    watchFor: [
      "Compare directly against `tx-detail--sign-in-required`: §7.2 names these as distinct states and this pair is where they get collapsed.",
    ],
  },

  {
    id: "tx-detail--sign-in-required",
    summary:
      "The sign-in prompt on the on-demand path — stating what it is for, and appearing nowhere else.",
    spec: "Page-Descriptions §7.2 Hero",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The sign-in prompt scoped to the generate action, not to the page.",
      "A statement of WHAT IT IS FOR — that generating a trace costs compute — rather than a bare 'sign in to continue'.",
      "Clear indication that the rest of the product, and every ready trace, needs no account.",
      "The transaction page fully readable behind the prompt.",
    ],
    mustNotShow: [
      "A page-level sign-in wall or modal.",
      "Wording implying the product requires an account.",
      "A quota reset time — that belongs to `quota-exhausted`.",
    ],
    watchFor: [
      "This is the product's only authentication surface. Its tone carries disproportionate weight; judge it against the trust strip's promises on the home page.",
    ],
  },

  {
    id: "tx-detail--browser-cannot-debug",
    summary:
      "The browser cannot run the debugger — entry into the capability ladder, with the specific detected cause.",
    spec: "Page-Descriptions §14.2",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "The SPECIFIC failure named — WASM compilation, insufficient memory, broken/intercepted range requests, or unsupported worker behaviour. §14.2 gives each its own detection, and a generic 'your browser is unsupported' is the failure this table exists to prevent.",
      "The ladder offered as ordered options, so the visitor sees there is more than one way forward.",
      "The complete transaction page beneath, per §7.0 — no state renders less than the pre-hydration page.",
    ],
    mustNotShow: [
      "A generic browser-unsupported error.",
      "A browser-upgrade recommendation as the only remedy.",
      "The page reduced to the notice.",
    ],
    watchFor: [
      "VD.0 records that the four distinct §14.2 detections are currently collapsed into this single named view. Say which one this capture is showing, and whether the surface would look different for the other three.",
      "Tone: this is a statement about the environment, not about the visitor.",
    ],
  },

  {
    id: "tx-detail--ladder-download",
    summary: "Ladder step 1 — offer the trace download, so the user keeps something useful.",
    spec: "Page-Descriptions §14.2 (ladder 1)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A download action for the trace container, with its SIZE stated — a download of unknown size on a page that has just said the browser is constrained is a poor offer.",
      "A statement that the container is self-contained and what can be done with it.",
      "The remaining ladder steps visible below, so this reads as the first of several options.",
    ],
    mustNotShow: [
      "A download offered with no size and no explanation of what the file is.",
      "This step presented as the only option.",
    ],
    watchFor: [
      "Three ladder steps in sequence: check they are visually ordered as a ladder rather than as three equal-weight buttons.",
    ],
  },

  {
    id: "tx-detail--ladder-desktop",
    summary:
      "Ladder step 2 — open in CodeTracer desktop, the one path that always works.",
    spec: "Page-Descriptions §14.2 (ladder 2)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "An 'Open in CodeTracer desktop' action.",
      "A statement that the desktop application has none of these constraints — the reason this step is offered.",
      "A path for a visitor who does not have the desktop app, since the action assumes it.",
      "The remaining ladder steps still visible.",
    ],
    mustNotShow: [
      "A download-the-desktop-app pitch that overwhelms the transaction the visitor came for.",
      "A protocol-handler action with no fallback for a visitor without the app installed.",
    ],
    watchFor: [
      "This is the only place the explorer advertises another product. Check the promotion is proportionate and stays in the web register.",
    ],
  },

  {
    id: "tx-detail--ladder-summary",
    summary:
      "The ladder's floor — a static call and event summary rendered with no replay engine at all. The floor is a useful page, not an apology.",
    spec: "Page-Descriptions §14.2 (ladder 3)",
    register: "explorer",
    inherits: ["tx-page-intact", "site-chrome"],
    mustShow: [
      "A CALL SUMMARY — the call structure, rendered statically from the transaction's own published data.",
      "An EVENT SUMMARY — the events, likewise.",
      "Both populated with real content. An empty summary defeats the entire point of the ladder having a floor.",
      "No dependence on the replay engine visible anywhere — no debugger controls, no stepping affordances that cannot work.",
    ],
    mustNotShow: [
      "An apology as the dominant content. §14.2: 'the floor is a useful page, not an apology'.",
      "Empty call or event regions.",
      "Disabled debugger controls suggesting a session that cannot open.",
    ],
    watchFor: [
      "Judge this page on its own merits as though it were the only page — that is the test §14.2 sets for it.",
      "Compare its call structure rendering against `tx-detail--internal-calls`: they show the same data and should not be two different designs.",
    ],
  },

  {
    id: "shell--cdn-unreachable",
    summary:
      "CDN unreachable — the service worker serves the shell and anything previously viewed.",
    spec: "Page-Descriptions §14 (CDN unreachable)",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The product's shell rendered — header, navigation, footer, brand — proving the service worker served something rather than the browser showing its own offline page.",
      "An explicit statement that the network is unavailable and what is still reachable: anything previously viewed.",
      "A route to the cached content, so 'previously viewed' is actionable rather than a claim.",
      "The search field or navigation present but visibly constrained, so the limitation is legible before a click fails.",
    ],
    mustNotShow: [
      "The browser's own offline error page, a dinosaur, or a `net::ERR_` string — any of these means the service worker did not serve.",
      "A blank shell with no explanation.",
      "Navigation that looks fully functional while the network is down.",
    ],
    watchFor: [
      "This is the only view whose correctness is partly about WHAT SERVED IT. State whether what you see is plausibly the product's shell or the browser's fallback.",
      "The constrained-navigation treatment: it must read as temporary, not as a broken build.",
    ],
  },

  // ──────────────────── The real chains (VD.8) ─────────────────────────────
  //
  // Four views whose subject is data this product did not generate. Everything
  // else in this file is captured from `/aztec`, a chain that is a pure
  // function of a seed; these are captured from two snapshots taken off Aztec
  // nodes. The distinction is the entire reason `components/provenance.nim`
  // exists, and until 2026-08-31 no image in the corpus contained the
  // affirmative half of it.
  {
    id: "chain-overview--testnet",
    summary:
      "A chain overview whose data came off a node. The same page as `chain-overview`, and the point is that it IS the same page: a second chain is data, not a second explorer.",
    spec: "Page-Descriptions §4, §2; components/provenance.nim",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The provenance marker in its AFFIRMATIVE tone: `Real Aztec testnet data`. Since 2026-08-31 this page carries it as the compact CHIP above the breadcrumb, not as a band — real chain data is the ordinary case and no longer interrupts the page to announce itself. The chip is a badge only; the capture's own account of itself (endpoint, moment, block range) is NOT on this page any more, and its absence here is not a finding. What IS a finding: a chip that is missing, that names the wrong chain, whose tone contradicts its label, or that is so quiet a reader scanning the page would not register that they are looking at real network data.",
      "A head height, block count and transaction count that are plainly a real chain's rather than a fixture's — five-figure heights, an irregular transaction distribution.",
      "The chain notes: coverage mode, generation, and the recorder pin, exactly as the synthetic overview renders them. This view is partly a CONTROL — the surrounding page must not have changed because the data is real.",
    ],
    mustNotShow: [
      "Any suggestion that this chain is a demo, a sample or a preview. The neutral `Synthetic demo data` treatment appearing here would be the product telling a reader that real chain data is fake, which is a P1 in its own right even though it is the safer of the two directions.",
      "A layout that differs from `chain-overview` in any way not caused by the DATA. A second chain is data; a page that reshaped itself for it is a finding.",
    ],
    watchFor: [
      "Put this beside `chain-overview` at the same size and theme. The two now differ in FORM, not only in tone: this page carries a compact chip and the synthetic one carries a full band. That asymmetry is deliberate — a band means \"something here is not normal\" — and it is the thing to judge. Is the synthetic page's band loud enough to be read as a warning, and is this page's chip quiet without being missable? If the affirmative and neutral treatments are hard to tell apart at a glance, say so; colour alone must not be what separates them.",
      "Whether the capture detail reads as reassuring provenance or as debug output that escaped into the product.",
    ],
  },
  {
    id: "chain-overview--mainnet",
    summary:
      "The overview of a real chain on which NOTHING can be replayed — the honest aggregate view of a snapshot whose every transaction is below the node's pruning floor.",
    spec: "Page-Descriptions §4, §14; components/provenance.nim",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "The affirmative provenance CHIP naming `Real Aztec mainnet data` above the breadcrumb. The producer's account of why this snapshot carries no traces — the node prunes transaction bodies at the finalized tip — is no longer on this page: it travels with the transaction pages' `Data` row. Judge whether the page still explains its own emptiness without it; if it does not, that is a real finding about this page and not about the marker.",
      "Latest blocks and latest transactions populated. The chain is not empty and must not look empty; what it lacks is REPLAYABILITY, which is a different claim and belongs to the transactions rather than to the chain.",
      "The transactions table with its Debug column rendering a stated reason rather than an action, on every row — the aggregate form of §7.0's rule that a row whose execution is unobservable gets a labelled state and never a greyed button.",
    ],
    mustNotShow: [
      "An error, an empty state, or any treatment that reads as a failed load. This page is a successful render of a chain that genuinely has no traces, and the risk it carries is being mistaken for a broken one.",
      "A Debug affordance on any row, or a disabled control standing in for one.",
      "A staleness or degradation notice about the PIPELINE. Nothing is behind here; the data is current and the traces are absent by the node's design.",
    ],
    watchFor: [
      "This is the page most likely to be read as a bug while being exactly correct. Say plainly whether, on first look, you took it for a broken page — that judgement is the finding, more than any single element.",
      "Whether a reader could come away believing BlockTracer cannot debug Aztec mainnet at all, rather than that these particular transactions have aged out of the window.",
    ],
  },
  {
    id: "tx-detail--mainnet-zero-trace",
    summary:
      "§7.0's `absent` on real chain data: no trace is published for this transaction, and the page's job is to say WHY in the capture's own words. Two causes now reach this state and they are not interchangeable — the node no longer serves the body (permanent), or the follower reached it in time and our replay runtime refused (repairable). The reason, the tense and the durability claim must all be the ones that fit the cause this transaction actually hit.",
    spec: "Page-Descriptions §7.0 (absent), §7.2, §14; components/provenance.nim",
    register: "explorer",
    inherits: ["site-chrome"],
    mustShow: [
      "A `Not observable` badge on the execution, and beside it the PUBLISHED reason in the producer's own words. The reason must locate the limitation WHERE IT ACTUALLY IS, and there are now two places it can be. Chain-side: `getTxByHash` prunes at the finalized tip and this transaction is below it — nothing here failed. Recording-side: the follower reached the transaction inside the replay window with its body still served and the replay runtime refused it — the chain did nothing wrong and neither did the reader. Whichever it was, the sentence must say so and must be the one the capture actually recorded for THIS transaction; a page that reports the other cause is misattributing a fault, which is the defect this item exists to catch.",
      "The transaction's ordinary metadata, complete and unapologetic — the full hash, an outcome badge, and an Overview carrying block, canonicality, finality and cost. §7.0's second row is 'the metadata, with the reason stated', and the metadata half is not a consolation prize. Note that a real chain publishes FEWER fields than the fixture (no fee payer, no target): their absence is the snapshot's, not the page's, and is not a finding.",
      "Every content section present and each one saying why it is empty IN A TENSE THAT MATCHES THE PUBLISHED CAUSE. Where the body was pruned, the cause is permanent and the sections must say so — empty \"permanently, not yet\" — because a section that reads as pending would promise a trace that can never arrive. Where the cause is a REFUSAL BY OUR OWN REPLAY RUNTIME, the permanent tense is the same error in the other direction: a toolchain regression is by construction repairable, so a reader told the answer is permanent may never come back to a page that will have a trace on it. §14.1a is the rule and it cuts both ways — \"'Not now' and 'not ever' are different states … presenting either as the other is the failure this table exists to prevent.\"",
      "The affirmative provenance marker, which on THIS page is the `Data` row at the top of the transaction facts grid — a badge reading `Real Aztec mainnet data` with the capture's own sentences beneath it. That this is REAL data is what makes the absence of a trace meaningful; the same page on the synthetic chain would be a fixture choice rather than a fact about a network. Since 2026-08-31 it is a row rather than a band: judge whether, as the first fact in the grid, it still lands before a reader forms a conclusion about the empty sections below.",
      "A claim about DURABILITY that the published cause actually supports, and a reader able to tell which it is. Where the body was pruned: 'a permanent answer rather than a failed fetch' — returning tomorrow will not help. Where our replay runtime refused: the honest claim is that no trace exists NOW and why, not that none can ever exist. The failure mode here is asserting permanence with a repairable cause printed directly beneath it, which leaves the strongest sentence on the page unsupported by the only evidence offered for it.",
    ],
    mustNotShow: [
      "A Debug button, a 'Generate trace' affordance, a retry, a spinner, or a disabled control of any kind. There is nothing to retry and nothing to generate; an affordance here would promise something the chain cannot supply.",
      "Any trace reference, artifact id, container link or download. Zero, not empty-but-present.",
      "MISATTRIBUTION of the cause in either direction. Blaming the chain for a fault on this side is the worse one and is what this item was originally written against, back when the recorder never had the chance and every zero-trace mainnet transaction was one the node had pruned. It is no longer the only case: the follower has since caught transactions inside the window whose bodies were still served and had the replay runtime refuse them, so a page that says the chain did not retain THAT transaction is telling a reader the opposite of what happened. Naming a recording-side failure is therefore REQUIRED where that is what occurred, and forbidden where it is not.",
      "An error colour or a danger tone. This is a normal, correct page about a limitation, not a failure.",
    ],
    watchFor: [
      "The single most important judgement in this round: does this page read as CORRECT, or as broken? It is the state most likely to be mistaken for a defect while being exactly right, and it is the first time it has ever been captured.",
      "Read it beside `tx-detail--absent`, which is the same §7.0 state on the synthetic chain with a different reason (a private kernel execution, not a pruned body). Two reasons, one state: does the page make the REASON the thing a reader takes away, or do both pages collapse into one generic 'no trace' treatment? The reasons are published separately precisely so they do not.",
      "Whether the pruning explanation is legible to someone who does not know what a finalized tip is.",
    ],
  },
  {
    id: "debugger--testnet",
    summary:
      "A debugging session over a trace recorded from a real testnet transaction — the flagship claim, on data this product did not manufacture.",
    spec: "Page-Descriptions §8, §7.1, Debugger-Integration §3; components/provenance.nim",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "The affirmative provenance marker, which in this register is the FIRST ROW of the transaction pane: `Data`, a badge reading `Real Aztec testnet data`, and the capture's endpoint, moment and replay window beneath it. There is no band above the identity bar any more and there must not be one. In this register the pane row is the only provenance marker there is — no nav, no footer, no band — so grade it as content and say whether a row in the right-hand pane is enough to keep a reader oriented in a full-viewport session.",
      "The identity bar carrying a real transaction hash and a real block height, and a way out that lands on `aztec-testnet` rather than on the synthetic chain.",
      "AN INSTRUCTION-LEVEL SESSION, AND ITS EXPLANATION. This is the part that makes the view worth capturing and it is NOT what the synthetic session shows. An Aztec contract class publishes bytecode and no debug symbols — no file map, no source text, no local names — so this trace has no source to display. Each affected pane must say so IN ITS OWN WORDS rather than sitting blank: the Code pane that the recording is at instruction level and stepping is complete while only the text is missing; the Call Trace that frames are recorded but carry no function names or source positions; the Values pane that naming a local needs debug symbols this contract class does not publish.",
      "A route OUT of that limitation — a `Supply sources` affordance — so the missing text reads as something a user could supply rather than a wall.",
      "The transaction pane populated from real chain facts, including the replay telemetry the capture recorded (instructions executed, effects matched and mismatched). `effectsMismatched: 0` is the claim that this replay reproduced the chain's own effects, and it is the evidence the session is faithful.",
    ],
    mustNotShow: [
      "The synthetic banner, the `aztec` slug, or any content from the demo fixture. This view exists to prove the session is not the fixture wearing a different hash; fixture content leaking into it is a P1.",
      "INVENTED SOURCE. A file tab, a listing, a line number, a function name or a variable name has to have come from published debug symbols; this contract class publishes none, so any of them appearing here would be the debugger fabricating the one thing it does not have. That is the most serious failure this page could contain.",
      "A blank pane with no explanation. Empty is correct here; unexplained is not.",
      "An engine-failure banner. This is the static, server-rendered session and it is complete as served.",
    ],
    watchFor: [
      "Put this beside `debugger` at the same size and theme and note what a REAL trace costs. The fixture is a Noir program with sources, names and a loop rail; this is bytecode with none of them. Does the product degrade to instruction level with its dignity intact, or does it look broken?",
      "The panes are largely empty by necessity and the explanations are short. Judge the composition: a 900px pane holding two sentences at its top edge is honest but may read as a failed render. Say whether the empty regions look deliberate.",
      "Whether a reader learns that the LIMITATION IS THE CHAIN'S rather than this product's. The sentences say so; check that the visual treatment agrees and does not read as an error state.",
      "What the removed band BOUGHT. It used to be a full-width strip above the identity bar costing ~190px of this 1080px viewport; those rows are now in the panes. Judge whether the session reads better for it, and whether anything was lost in the trade beyond the band itself — the previous round's reviewers named that band the page's weakest element, so this is the change they asked for and it should be graded as one.",
      "The COST · TRANSACTIONFEE row. On real chain data the fee arrives as a 32-byte hex quantity and is rendered raw, wrapping across several lines and breaking the label/value grid — where the synthetic chain shows a formatted mana figure. Report what you see; this is a formatting path only real data reaches.",
    ],
  },
];

// ── Lookups and integrity ──────────────────────────────────────────────────

export const EXPECTATIONS_BY_ID = new Map(EXPECTATIONS.map((e) => [e.id, e]));

/** The full item list for a view, with inherited backbones resolved. */
export function resolveExpectation(id) {
  const e = EXPECTATIONS_BY_ID.get(id);
  if (!e) return null;
  const inherited = (e.inherits ?? []).map((key) => {
    const b = BACKBONES[key];
    if (!b) throw new Error(`${id}: unknown backbone '${key}'`);
    return { key, ...b };
  });
  return { ...e, inherited };
}
