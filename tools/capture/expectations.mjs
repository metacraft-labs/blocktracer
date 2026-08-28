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
  "debugger-shell": {
    spec: "Page-Descriptions §8, Design-System §2",
    items: [
      "A slim identity bar across the top carrying the transaction identity (truncated hash, chain) and a link back to the transaction detail page — not the full explorer header.",
      "Product-register surface: dark by default, dense, continuous with the CodeTracer desktop app. An explorer-register light marketing surface here is a register error, which is a P1.",
      "The session occupies the full viewport below the identity bar. No explorer footer, no marketing chrome, no page-level scrollbar.",
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
    mustShow: [
      "A hero carrying one sentence of positioning — that this is the block explorer where you can step backwards through any transaction. One sentence, not a paragraph and not a tagline fragment.",
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
    mustShow: [
      "A table with all eight specified columns present and headed: Chain (name, logo, slug, CAIP-2 id) · VM · Debug tier · Historical reach · Source level · Coverage · Freshness · Status notes.",
      "Debug tier rendered as a T0–T2 badge, not as bare text.",
      "Historical reach showing its actual vocabulary — `archive`, `windowed(7d)`, `version-addressed` or `recent-only` — not a boolean tick.",
      "Coverage showing `eager` / `selective` / `on demand`, which is what the Debug button will do on first click.",
      "Freshness as a lag behind the chain tip, with a unit.",
      "Status notes as free text, including at least one real limitation — this column exists to be honest, and an all-empty notes column reads as a table that has nothing to admit.",
    ],
    mustNotShow: [
      "A 'Requires' or 'Supported' boolean column that flattens the tier and reach vocabulary back into yes/no.",
      "Placeholder chain rows (`Chain 1`, `example-chain`) — this page is registry-generated and placeholders mean it is not.",
    ],
    watchFor: [
      "Eight columns is wide. At laptop width, check whether the table has already collapsed a column into a tooltip, and whether the columns that survive are the ones that matter (tier, reach, coverage).",
      "Badge and free-text in the same row: the notes column will be the tallest cell and drags row height; check vertical alignment of the badge columns against it.",
      "Logos at mixed aspect ratios sitting on a common baseline.",
    ],
  },

  {
    id: "chain-overview",
    summary:
      "A single chain's landing page: what it is, where its head is, and what has recently happened on it.",
    spec: "Page-Descriptions §4",
    register: "explorer",
    mustShow: [
      "A header carrying name, VM, chain id, debug tier, finality rule and coverage mode — six registry facts, each labelled.",
      "The head: latest block number with its age. This is the ticking element, so it must be present and legible at a glance.",
      "Latest blocks — a list of the last ~10 with per-block transaction counts.",
      "Latest transactions — a list of the last ~25, with a Debug action visible on every row (Page-Descriptions rule 1).",
      "Chain notes: limitations in plain language, from the registry.",
    ],
    mustNotShow: [
      "An empty 'latest blocks' or 'latest transactions' region. Rule 2 — nothing renders as an empty list; either data or a statement of why not.",
      "A Debug action that is present only at the end of a row that has scrolled out of view.",
    ],
    watchFor: [
      "Two lists of different lengths side by side — check they do not leave a large dead column, and that the shorter one does not stretch its rows to match.",
      "Head age is the only element that would change between captures; in a frozen-clock capture it must show a stable, plausible value rather than '0s ago' or 'NaN'.",
      "The six header facts as a group: they are the densest text on an otherwise spacious page and are the most likely place for the explorer rubric's whitespace discipline to break down.",
    ],
  },

  {
    id: "chain-overview--stale",
    summary:
      "Chain overview when the pipeline is behind the chain tip — the staleness notice.",
    spec: "Page-Descriptions §4 (Degraded), §14 row 1",
    register: "explorer",
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
    spec: "Page-Descriptions §5.1",
    register: "explorer",
    mustShow: [
      "All seven columns headed and populated: height · hash · age · tx count · gas/resource usage WITH A BAR · producer/proposer · finality badge.",
      "The resource-usage bar rendered as a graphical bar with a common scale across rows — this is the one chart on the page and the column is specified as a bar, not a number.",
      "A finality badge per row, visually distinct from the other columns.",
      "Rows in descending height order, with enough rows present to judge density (a three-row table is not this page).",
      "Pagination that walks backwards — a cursor control, not numbered pages.",
    ],
    mustNotShow: [
      "The resource column rendered as a bare number or a placeholder line where the bar should be.",
      "Numeric columns left-aligned or centre-aligned — heights, counts and usage are numeric and must be right-aligned or tabular-figure aligned.",
    ],
    watchFor: [
      "Hash truncation: check that the truncation is consistent down the column and that the visible prefix/suffix is enough to distinguish adjacent rows.",
      "Tabular figures — with proportional digits, a column of block heights visibly ripples. This is the highest-value place in the product to check it.",
      "Row height against the bar's height: the bar must sit on the text baseline grid rather than inflating the row.",
    ],
  },

  {
    id: "blocks-list--row-expanded",
    summary:
      "A block list row expanded to reveal that block's transaction hashes with per-row Debug actions.",
    spec: "Page-Descriptions §5.1 (row expansion)",
    register: "explorer",
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
    summary: "A single block: its header facts, family extras, its transactions, and its neighbours.",
    spec: "Page-Descriptions §5.2",
    register: "explorer",
    mustShow: [
      "The header zone with all eight facts: hash, number, timestamp with age, parent link, producer, size, resource usage, finality state.",
      "A family-extras region — for an EVM chain, base fee / blob gas / withdrawals; for Move, checkpoint/epoch; for Solana, slot, leader, parent slot. Whichever family the fixture is, its rows must come from the adapter and be labelled with that family's vocabulary.",
      "The shared transactions table filtered to this block, with Debug as its first column.",
      "Previous / next block navigation, both controls present.",
    ],
    mustNotShow: [
      "EVM-shaped labels on a non-EVM chain (a 'gas price' row on Solana), which would mean the family adapter was bypassed for a template.",
      "An empty transactions region for a block that has transactions.",
    ],
    watchFor: [
      "The header is a nine-item fact grid; check the label/value pairing is unambiguous at every column width and that long values (hashes) do not push their labels out of alignment.",
      "Parent link and prev/next are three navigation affordances that mean similar things — check they are not three different visual treatments.",
    ],
  },

  {
    id: "block-detail--genesis-edge",
    summary:
      "Block detail at the oldest published block — the boundary case where 'previous' has nowhere to go.",
    spec: "Page-Descriptions §5.2 (Navigation: disabled at genesis and head)",
    register: "explorer",
    mustShow: [
      "The previous/next navigation with one direction VISIBLY DISABLED — the whole point of this view. A disabled control that looks identical to an enabled one is a P1.",
      "The disabled control still present rather than removed, so the navigation's shape does not change between blocks.",
      "The full block detail otherwise: header zone, family extras, transactions table.",
    ],
    mustNotShow: [
      "Both controls enabled.",
      "The disabled control rendered only as a colour change too subtle to read at a glance — disabled must be legible as a state, not inferred.",
    ],
    watchFor: [
      "The disabled treatment against the contrast floor: 'disabled' must not mean 'unreadable', and this is the view where that trade-off is visible.",
      "Whether the same disabled treatment is used here as on every other disabled control in the product (Design-System §2: shared primitives are shared).",
    ],
  },

  {
    id: "txs-list",
    summary:
      "Recent transactions — the shared TransactionsTable at full width, the densest surface in the explorer register.",
    spec: "Page-Descriptions §6",
    register: "explorer",
    mustShow: [
      "All ten columns, in order, headed: Debug · Hash · Block · Age · From · To/target · Method · Value · Fee · Status.",
      "Debug as the FIRST column and always visible — not an icon at the end of the row (Page-Descriptions §6 states this explicitly).",
      "At least one reverted transaction, rendered VISUALLY DISTINCT from successful ones. Reverted transactions are the population this product exists for; a table with no visible revert treatment cannot be judged.",
      "A control that sorts reverted transactions to the top. Page-Descriptions §6 asks for both halves — 'visually distinct AND sortable to the top' — and a table that only tints them still makes a visitor scroll to find the one they came for.",
      "A revert reason inline in the status cell where the reason is decodable.",
      "From/To rendered as address chips, with a contract badge on contract targets and a decoded method name where the ABI is known.",
      "A column picker affordance for the family-specific extras.",
      "Enough rows to judge density — this is a virtualised table and a short table hides every problem it has.",
    ],
    mustNotShow: [
      "A CSV export control. Page-Descriptions §6 excludes it by name in v1.",
      "Raw undecoded selectors in the Method column where the fixture has an ABI.",
      "Horizontal scrolling of the page body — the table may scroll inside its own container, the page may not.",
    ],
    watchFor: [
      "Ten columns at 1440 px is the hardest layout problem in the explorer register. Check what gives: which columns compress, whether Debug and Status keep their width, and whether Hash/From/To truncate at sensible boundaries.",
      "Three different monospace-ish columns (hash, from, to) adjacent — check they are distinguishable by more than position.",
      "The revert treatment against the status colour role: it must survive both themes and must not be the only signal (colour alone fails).",
    ],
  },

  {
    id: "txs-list--cards",
    summary:
      "The transactions table collapsed to stacked cards below 900 px, with Debug and status retained.",
    spec: "Page-Descriptions §6, §13",
    register: "explorer",
    mustShow: [
      "Stacked cards, one per transaction — not a table with a horizontal scrollbar, which is the failure this view exists to rule out.",
      "The Debug action prominent on every card (§13: the primary action is retained).",
      "The status, including revert treatment, prominent on every card.",
      "Hash, age and value present on the card; the columns that did not survive the collapse must be the low-value ones, and the reviewer should be able to say which were dropped.",
    ],
    mustNotShow: [
      "A horizontally scrolling table.",
      "A card that is just a re-flowed row of label:value pairs with no hierarchy — the collapse is a redesign, not a rotation.",
      "Any element extending past the viewport edge at 375 px.",
    ],
    watchFor: [
      "Long hashes and addresses at 375 px — the single most likely source of horizontal overflow in the product.",
      "Card-to-card spacing versus intra-card spacing: if they are equal, the cards read as one list rather than as discrete records.",
      "Whether the Debug action is a full-width button per card (thumb-reachable) or a small link, and whether it clears the touch-target minimum.",
    ],
  },

  // ══════════════════ Explorer register — transaction page ═══════════════

  {
    id: "tx-detail",
    summary:
      "The transaction page — the most important page in the product, and the one a competitor comparison lands on.",
    spec: "Page-Descriptions §7.2",
    register: "explorer",
    mustShow: [
      "Hero: status with decoded revert reason if any, the full hash with a copy affordance, age, finality badge, and Debug as the PRIMARY button — visually the strongest control on the page.",
      "The Debug button's state matching the trace availability shown beside it, and a note explaining that state in words.",
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
      "A sign-in prompt on a page whose trace is ready — the prompt appears only on the on-demand generation path.",
      "Any section rendered as a bare 'coming soon' with no explanation of what would appear there.",
    ],
    watchFor: [
      "Eight sections in one scroll: check the section-heading treatment is strong enough to navigate by, and that the eye can find the hero → Debug → overview path without reading.",
      "The overview grid's label column against its value column — mixed proportional labels and monospace values are the classic misalignment here.",
      "The raw JSON block: it is the only preformatted region on the page and will dominate if its surface, size and containment are not deliberately handled.",
      "The revert reason if present — it is prose inside a hero of identifiers and must not be styled as another identifier.",
    ],
  },

  {
    id: "tx-detail--dense",
    summary:
      "The transaction page at the largest published payload — the density case the whole campaign exists to catch.",
    spec: "Page-Descriptions §7.2, VD.4 verify_transaction_page_holds_at_extreme_content",
    register: "explorer",
    mustShow: [
      "Everything the `tx-detail` block requires, at the fixture's largest payload.",
      "A visibly long content region — many roles, many cost rows, a long raw payload — so the reviewer can confirm this is genuinely the dense case and not the same content as `tx-detail`.",
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
    id: "tx-detail--hydrated",
    summary:
      "The transaction page after the debugger has hydrated over it in place — §7.0's central claim, that the page IS the debugger's first frame.",
    spec: "Page-Descriptions §7.0, §7.1",
    register: "debugger",
    mustShow: [
      "A live debugging surface occupying the page, with the transaction metadata still available as a PANE beside the debugger's own panes (§7.1) rather than reduced to an identity bar.",
      "The metadata pane visibly dismissible/restorable like any other pane — a pane, not a bespoke sidebar.",
      "Continuity with the pre-hydration page: the same hash, the same status, the same facts. A reviewer must be able to see that this is the same transaction, not a different surface.",
      "The debugger's own panes populated — source, and at least one of call trace / event log / state.",
    ],
    mustNotShow: [
      "A full-page loading state or a flash of an empty shell — hydration must never show the visitor less than the pre-hydration page (§7.0).",
      "The transaction facts lost to the hydration. If the metadata is gone, that is the P1 this view exists to catch.",
    ],
    watchFor: [
      "The register crossing: this URL is explorer-register before hydration and product-register after. Check that the result looks like one designed surface and not two pasted together.",
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
      "The address page — scoped in V1 to get you to a transaction worth tracing, with complete history and no capability to negotiate.",
    spec: "Page-Descriptions §9",
    register: "explorer",
    mustShow: [
      "Header: the full address with a copy affordance, a resolved name if any, a contract/EOA badge, and the proxy relationship where one exists.",
      "A code summary: code hash, size, verification status, compiler.",
      "The shared transactions table with Debug on every row, presented as COMPLETE history — no record cap, no 'showing the most recent N' apology.",
      "An events section listing logs emitted by this address.",
    ],
    mustNotShow: [
      "A balance, a token holdings list, a portfolio value, a price, a P/L figure or holder analytics. Page-Descriptions §9 excludes all of these by name for V1; one appearing means the wrong scope was built.",
      "A 'Requires' column or any capability-negotiation notice — its absence is the point of this page.",
      "A 'read contract' panel (deferred in V1).",
    ],
    watchFor: [
      "The header carries a long identifier as its title. Check the treatment: it is the page's H1 and it is 42 characters of hex.",
      "Contract/EOA badge and proxy relationship are two different kinds of fact adjacent to each other; check they are not styled identically.",
      "At 375 px this view has a known horizontal-overflow finding from VD.0 — measure whether content exceeds the viewport and name the element that does it.",
    ],
  },

  {
    id: "contract-source",
    summary:
      "The verified source browser — a product-register element (the code view) inside a web-register page.",
    spec: "Page-Descriptions §10, Design-System §7",
    register: "explorer",
    mustShow: [
      "A verification panel: match level (full/partial), provider, compiler and settings, SPDX licence — all four.",
      "A file tree of sources with more than one file, and syntax-highlighted source in the reading pane.",
      "An in-file search affordance.",
      "A rendered ABI/interface view with copy-per-item.",
      "A storage layout listing declared state variables against slots.",
      "A deployments list of other addresses sharing this code hash.",
      "A supply-sources affordance for dropping a build output.",
      "Function entries in the ABI view linking to transactions that called them, where permitted — and where not permitted, the link ABSENT rather than present-and-broken.",
    ],
    mustNotShow: [
      "Source rendered without syntax highlighting.",
      "A single-file view with no tree, when the fixture has multiple sources.",
      "Highlighting that is visibly not the CodeTracer editor palette — Design-System §7 makes this the one sanctioned register crossing, and a generic web highlighter is a P2 register error.",
    ],
    watchFor: [
      "Six panels plus a tree plus a source pane is the most complex layout in the explorer register. Check the reading order and whether the source pane is given the space it needs.",
      "Long Solidity/Move lines against the pane width — horizontal scroll inside the code container is correct; horizontal scroll of the page is not.",
      "Match level 'partial' is a caveat; check it reads as a caveat and not as a pass.",
    ],
  },

  {
    id: "contract-source--unverified",
    summary:
      "No verified source — instruction-level stepping, with the supply-sources action prominent.",
    spec: "Page-Descriptions §14 (No verified source), §10",
    register: "explorer",
    mustShow: [
      "A clear statement that no verified source is available for this address, and what that means for stepping.",
      "The supply-sources action rendered PROMINENTLY — this is the specified treatment, so a small link at the bottom is a P1 against the spec, not a P3.",
      "The instruction-level alternative offered explicitly, so the visitor knows stepping is still possible.",
      "Whatever IS known — code hash, size, compiler if detectable — rather than a page that only says 'no'.",
    ],
    mustNotShow: [
      "An empty file tree.",
      "An error treatment. This is a normal, expected state for most addresses on most chains.",
      "A 'verify this contract' call to action that implies BlockTracer runs a verification service.",
    ],
    watchFor: [
      "The tone requirement from VD.6: informative, not apologetic. Read the copy and say which it is.",
      "The balance between the absence notice and the supply-sources action — the action is the point of the page and must not be subordinate to the explanation.",
    ],
  },

  {
    id: "search",
    summary:
      "Search resolution for an unambiguous input — which normally navigates immediately, so this view is the resolution surface itself.",
    spec: "Page-Descriptions §11, Search-And-Routing",
    register: "explorer",
    mustShow: [
      "The query echoed back, so the visitor can see what was searched.",
      "The single resolved candidate with its kind labelled (transaction / block / address / name) and its chain.",
      "A visible path onward to the resolved object.",
    ],
    mustNotShow: [
      "A results page for an input that Page-Descriptions §11 says navigates immediately, presented as though an intermediate page were the design — if this surface exists at all it must read as a resolution step, not as a search-engine results page.",
      "Zero-state advertising copy.",
    ],
    watchFor: [
      "How the candidate's kind is expressed — a badge, a section heading, or an icon — and whether that vocabulary matches the ambiguous view's grouping.",
      "The search field's own state on this page versus on home: the same component in two contexts.",
    ],
  },

  {
    id: "search--ambiguous",
    summary:
      "Ambiguous input — grouped, keyboard-navigable candidates across kinds.",
    spec: "Page-Descriptions §11",
    register: "explorer",
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
    spec: "Page-Descriptions §12",
    register: "explorer",
    mustShow: [
      "Four labelled groups: Storage · Debugger · Privacy · Advanced.",
      "Storage: local trace-cache usage shown as a real figure, a ceiling control, and a clear button.",
      "Debugger: theme, keybinding set, pane layout, and a reduced-motion honouring control.",
      "Privacy: a statement of what this deployment can observe — only its own CDN logs — and the opt-in telemetry switch shown OFF.",
      "Advanced: the registry override URL field.",
    ],
    mustNotShow: [
      "The telemetry switch defaulting to on.",
      "Any chain RPC, data-provider or indexer configuration beyond the single registry override above — the page's shortness is a design statement and additions to it are a spec violation.",
      "An account, profile or sign-in section.",
    ],
    watchFor: [
      "A short page on a wide viewport: check whether it has been given a measure and a column, or left as full-width rows across 1920 px.",
      "Control alignment down the left edge across four groups with different control types (a number, a button, a select, a toggle, a text field).",
      "The privacy statement is prose among controls; check it is not styled as a control label.",
    ],
  },

  {
    id: "static-content",
    summary:
      "Static content — /about and the privacy summary the home page's trust strip links to.",
    spec: "Page-Descriptions §1 route map, §2 Trust strip",
    register: "explorer",
    mustShow: [
      "Long-form prose with a heading hierarchy of at least two levels.",
      "A constrained measure — this is the one page in the product that is purely reading, and full-viewport-width body text at 1920 px is a P2 typography failure here specifically.",
      "The site's standard header and footer, so the page reads as part of the product.",
      "The privacy content the trust strip promises, reachable and present.",
    ],
    mustNotShow: [
      "Unstyled default browser typography.",
      "Body text running the full width of a wide viewport.",
    ],
    watchFor: [
      "This is the purest test of the type scale: heading levels, body, and the spacing rhythm between them, with no data to hide behind.",
      "Link treatment inside running prose, which appears nowhere else in the product at this density.",
    ],
  },

  {
    id: "not-found",
    summary:
      "Object not found — 'not on this chain', naming the chains checked, never a blank page.",
    spec: "Page-Descriptions §14 (Object not found)",
    register: "explorer",
    mustShow: [
      "The statement that the object is not on this chain — specific to the chain, not a generic 404.",
      "The chains that WERE checked, enumerated by name.",
      "The identifier that was looked up, echoed back.",
      "A route onward: search, the chain overview, or the chains index.",
      "The product's own header and footer — this must be a BlockTracer page, not a server error page.",
    ],
    mustNotShow: [
      "A bare '404' or a web-server default error page.",
      "A blank page.",
      "A stack trace or any internal identifier.",
    ],
    watchFor: [
      "Note explicitly whether this capture is the product's 404 or the capture server's fallback — VD.0 records that `static_export` emits no `404.html`, so a plausible-looking page here may not be the product's.",
      "Tone: this is the most common way a visitor's first click fails, and it decides whether the product reads as considered.",
    ],
  },

  // ═══════════════════════════ Debugger register ═════════════════════════

  {
    id: "debugger",
    summary:
      "The full-viewport CodeTracer session at the pinned time coordinate — the product register's flagship surface.",
    spec: "Page-Descriptions §8, Debugger-Integration",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A source pane with a visible current-position indicator at the pinned coordinate — the session is positioned, not merely loaded.",
      "A call trace pane with more than one frame.",
      "A state/values pane with at least one value.",
      "Stepping controls, including both directions — reverse stepping is this product's entire premise and its controls must be visible, not hidden behind a menu.",
      "A timeline or scrubber expressing position within the trace.",
      "The transaction identity reachable — either the metadata pane or, at minimum, the identity bar's hash.",
    ],
    mustNotShow: [
      "An indeterminate spinner anywhere in a fully loaded session.",
      "Empty panes. A pane with nothing in it must say why, not sit blank.",
      "Explorer-register light chrome around the session.",
    ],
    watchFor: [
      "Pane proportions at 1920 versus 1440: which pane loses width first, and whether the source pane keeps a usable measure.",
      "Continuity with the CodeTracer desktop app — same pane vocabulary, same density, same control placement. Divergences are findings (VD.5 records them).",
      "Small-text legibility: the tool rubric rewards density, but 11 px text at low contrast is a P2 under it, not a win.",
    ],
  },

  {
    id: "debugger--metadata-pane",
    summary:
      "The transaction metadata pane inside the session — the answer to 'a visitor deep-linked into a stepping session still needs to know what they are looking at'.",
    spec: "Page-Descriptions §7.1",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "The metadata rendered as a PANE among the debugger's panes — same chrome, same header treatment, same dismiss affordance as a call-trace or state pane.",
      "The §7.2 facts inside it: status with revert reason, value, roles (from/to), cost, finality, the execution list, and the private/public split where the chain has one.",
      "A dismiss control, and evidence that the pane is restorable like any other.",
      "The debugger's other panes still visible around it, so the pane is seen in context rather than as a full-screen overlay.",
    ],
    mustNotShow: [
      "A modal dialog or a full-viewport takeover — it is a pane (§7.1 says so explicitly, in contrast to 'a bespoke surface').",
      "A subset of the facts that drops the revert reason or the private/public split.",
      "Metadata rendered at explorer density inside a product-register session.",
    ],
    watchFor: [
      "This pane's content is the same data as the explorer's overview grid at a fraction of the width; check the label/value strategy that makes that work (stacked rather than two-column, probably) and whether it was actually chosen or merely inherited.",
      "The Aztec private/public split needs to be legible as a split, not as two similar-looking rows.",
    ],
  },

  {
    id: "debugger--call-trace",
    summary:
      "The call trace at realistic depth and width, including the cost column and the cost-sorted view.",
    spec: "Page-Descriptions §8, Debugger-Integration, VD.5",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A call tree at genuine depth — several levels of nesting visible, not a flat list of top-level calls.",
      "A per-frame cost column, aligned as a numeric column.",
      "The current frame indicated distinctly from the rest.",
      "Frame identification: function or entry-point name plus its contract/module, per frame.",
      "A sort or ordering affordance for the cost-sorted view.",
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
      "The event log with mixed entry kinds — calls, storage writes, events and a revert in one stream.",
    spec: "Page-Descriptions §8, VD.5",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "All four entry kinds present in the same view: a call, a storage write, an event, and a revert.",
      "The four kinds VISUALLY DISTINGUISHABLE from each other by more than their text — this is the pane's whole job and the reason it is captured with a mixed fixture.",
      "The revert entry rendered as the terminal, significant event it is.",
      "A position/ordering that ties entries to the trace, so the log can be read as a sequence.",
      "The entry corresponding to the current position indicated.",
    ],
    mustNotShow: [
      "Four kinds rendered identically with only a differing label.",
      "Kind distinguished by colour alone.",
      "A log so uniformly dense that the revert does not stand out.",
    ],
    watchFor: [
      "The icon/badge/colour system across four kinds in both themes — this is the densest use of the status colour roles in the product.",
      "Row height consistency when entries carry different amounts of detail.",
    ],
  },

  {
    id: "debugger--state-pane",
    summary: "The state pane with deeply nested values and long identifiers.",
    spec: "Page-Descriptions §8, VD.5",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A value tree nested to at least three levels, expanded enough to show the nesting.",
      "Per entry: identifier, type, and value.",
      "A long identifier present and handled — this pane is captured specifically for that case.",
      "Expand/collapse affordances on composite values.",
      "Values whose type is not obvious from their rendering carrying a type annotation.",
    ],
    mustNotShow: [
      "A long identifier truncated with no way to see it in full.",
      "Nesting expressed only by indentation with no guides, at three levels or more.",
      "A flat key/value dump.",
    ],
    watchFor: [
      "The identifier column and the value column compete for a narrow pane; describe how that is resolved and whether the resolution survives the deepest nesting shown.",
      "Changed-since-last-step highlighting, if present — it is the pane's most valuable signal and the easiest to render too subtly.",
    ],
  },

  {
    id: "debugger--source-pane",
    summary:
      "The source pane in a source-level session, with the source/instruction level boundary legible.",
    spec: "Page-Descriptions §8, §14 (No verified source), VD.5",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "Syntax-highlighted source from the product lineage's editor tokens (Design-System §7).",
      "Line numbers.",
      "The current line indicated unambiguously — a highlight, a gutter marker, or both.",
      "Executable versus non-executable lines distinguishable, so a visitor knows where stepping can land.",
      "The file identity — path or module name — visible.",
      "Where the session mixes source-level and instruction-level regions, the BOUNDARY between them rendered explicitly, not as an unannounced change of content.",
    ],
    mustNotShow: [
      "Unhighlighted plain-text source.",
      "A current-line indicator that is indistinguishable from a selection or a hover.",
      "Instruction-level content presented as though it were source.",
    ],
    watchFor: [
      "Line-height and font-size against the desktop app's source pane — the continuity requirement is strongest here because this is the pane a CodeTracer user knows best.",
      "The gutter's width budget with four-digit line numbers plus a marker.",
      "Highlighting palette in light theme: the editor tokens are dark-first and light is the case most likely to be wrong.",
    ],
  },

  {
    id: "debugger--loading-phases",
    summary:
      "Phased, honest loading — fetching, then opening, then positioning. Never an indeterminate spinner.",
    spec: "Page-Descriptions §8, Trace-Processing §3.2",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A NAMED PHASE, in words, matching the phase the capture pins — fetching, opening or positioning. The name is the requirement; its absence is the P1 this view exists to catch.",
      "The phase sequence shown, so the visitor can see which phase they are in and what remains.",
      "The panes' eventual layout already indicated — skeletons matching the shape of what will replace them (VD.9) rather than a blank void.",
      "The transaction identity already present in the identity bar during loading.",
    ],
    mustNotShow: [
      "An indeterminate spinner as the only loading signal. Page-Descriptions §8 rules this out by name.",
      "A percentage, unless it is genuinely derived and labelled as an estimate.",
      "A blank viewport.",
    ],
    watchFor: [
      "Whether the skeleton geometry actually matches the loaded layout — compare against the `debugger` view and say whether the panes land where the skeleton promised.",
      "The phase label's prominence: it is the only honest information on screen and is usually rendered at caption size in a muted colour.",
    ],
  },

  {
    id: "debugger--narrow",
    summary:
      "The reduced, read-only narrow session — source + call trace + values, no flow pane, with the limitation stated in the UI.",
    spec: "Page-Descriptions §13",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A STATEMENT IN THE UI that this is a reduced session and what is missing. §13 says 'and says so'; an unannounced reduction is the P1 here.",
      "Exactly the three specified panes reachable: source, call trace, values. The flow pane must be absent, not present-and-broken.",
      "A working way to move between the three panes at this width (tabs, an accordion, or a switcher) rather than three stacked panes each 100 px tall.",
      "Read-only presentation — stepping controls either absent or visibly disabled, consistent with the stated limitation.",
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
      "The trace-truncated banner, with the option to request a deeper profile.",
    spec: "Page-Descriptions §14 (Trace truncated)",
    register: "debugger",
    inherits: ["debugger-shell"],
    mustShow: [
      "A banner stating the trace is truncated, and where — a step count, a depth, or a size, so 'truncated' is quantified rather than asserted.",
      "The option to request a deeper profile, as an action.",
      "The debugger fully usable behind the banner, with its panes populated. Truncated is not broken.",
      "An indication in the trace surface itself — the timeline or call trace — of where the truncation falls, so the boundary is not only announced in the banner.",
    ],
    mustNotShow: [
      "The banner as an error.",
      "A modal blocking the session.",
      "A truncation announced with no quantity.",
    ],
    watchFor: [
      "Banner height against the session's vertical budget — the debugger is desktop-dense and every row the banner takes comes out of a pane.",
      "Whether this banner and the divergence banner share one treatment; they should be one component at two severities, not two designs.",
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

  // ══════════ Degraded states on the transaction page (§14, §14.1, §14.1a) ══════════

  {
    id: "tx-detail--trace-awaiting",
    summary:
      "Trace awaiting generation — the entry state of the generation job, with observable phases.",
    spec: "Page-Descriptions §14, §14.1",
    register: "explorer",
    inherits: ["tx-page-intact", "generation-job"],
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
    inherits: ["tx-page-intact", "generation-job"],
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
    inherits: ["tx-page-intact", "generation-job"],
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
    inherits: ["tx-page-intact", "generation-job"],
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
    inherits: ["tx-page-intact", "generation-job"],
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
    inherits: ["tx-page-intact", "generation-job"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
    inherits: ["tx-page-intact"],
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
