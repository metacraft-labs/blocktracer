# blocktracer — AGENTS.md

[blocktracer.org](https://blocktracer.org) — a block/transaction explorer. The
browsable web front-end is an **isonim** static site living in **`client/`**;
the repo root holds the Nim CLI tools that generate, validate, and publish the
trace/chain data the site renders.

**Two Justfiles — mind which one:**
- **Repo root `Justfile`** — data-pipeline tasks (`just test`, `demo-gen`,
  `validate`, `demo`, `publish`, `build`) over root `src/` (`blocktracer_*.nim`).
- **`client/Justfile`** — the isonim site. Run its targets as
  **`cd client && just …`**. Everything in §3–§5 below refers to this one.

## 1. Purpose & how it ships

**To change site content and ship it, follow
[`metacraft-dev-guidelines/policies/managing-web-site-content.md`](../metacraft-dev-guidelines/policies/managing-web-site-content.md).**
Edit `client/src/`, test locally (§4), open a PR to the target branch, and merge.
**Merging auto-deploys — there is no manual deploy step.**

Branch → Cloudflare Pages project (one project per env; see
`.github/workflows/deploy.yml`). This publishes the **demo / static explorer**;
CI builds hermetically via `nix build .#default` and deploys with
flake-pinned `wrangler pages deploy`:

| Branch | Pages project | Preview alias |
|--------|---------------|---------------|
| `live` | `blocktracer` | — (production) |
| `staging` | `blocktracer-staging` | — |
| `dev` | `blocktracer-dev` | — |
| any PR | `blocktracer-dev` | `<head-ref>.blocktracer-dev.pages.dev` |

The production **blocktracer.org** apex is served by a separate **Cloudflare R2
delta-publisher** path (bucket bound to the `blocktracer.org` zone), documented
in [`DEPLOY.md`](./DEPLOY.md) — not by the Pages projects above.

**If a deploy is starved by the runner pool, it re-enqueues itself.**
`eph-linux-x64` is shared across the org and deploys routinely queue behind it,
which is silent: production keeps serving the previous commit and nothing goes
red. `.github/workflows/deploy-requeue.yml` watches every finished `Deploy` run
and re-runs the ones the *infrastructure* killed. It will **not** retry a
`failure` (that is this repository's own content, and a retry would hide it),
and it will **not** retry a `cancelled` run whose commit is no longer its
branch's tip (that cancel was a `cancel-in-progress` supersede, and re-running
it would publish the older commit over the newer one). The bound is GitHub's
`run_attempt`; at 5 it opens an issue and goes red instead of retrying again.
The policy is a pure function in `tools/ci/requeue-decide.mjs` with a 14-arm
selftest in the `deploy-gates` CI job. Kill switch: set the
`DEPLOY_REQUEUE_DISABLED` repository variable.

## 1a. `@blocktracer/client` — the Client SDK (M12a)

The chain-aware read layer lives in **`src/blocktracer_client.nim`** (the
facade) plus `src/blocktracer_client/**` (private). It reads the published
`/d/**` tree, pins a generation, resolves a transaction to a trace, parses and
emits debug deep links, and resolves source bundles per code hash. Spec:
[`../codetracer-specs/BlockTracer/Client-SDK.md`](../codetracer-specs/BlockTracer/Client-SDK.md).

**Two layers, one direction.** The Client SDK depends on the CodeTracer **Embed
SDK** (`codetracer_embed`, in the `codetracer` repo) and never the reverse. The
dependency lives in exactly one module, `src/blocktracer_client_embed.nim`,
which converts a `ResolvedTrace` into the Embed SDK's `TraceSource`. Everything
else compiles with no debugger on the Nim path at all — that is the layering,
not a comment about it.

| Rule | Enforced by |
|------|-------------|
| A consumer imports only `blocktracer_client` (or `blocktracer_client_embed`) | `ci/test/client-sdk-boundary.sh` |
| The SDK reaches no renderer, no producer, no socket, no identity | same |
| The Embed SDK contains no chain concept and never imports this package | same, `--embed-root` / `$CODETRACER_SRC` |
| Every rule above actually bites | `ci/test/client-sdk-boundary-test.sh` (synthetic trees with deliberate violations) |

`client/` is a **declared consumer** (`client/.sdk-consumer`): `client/src/reader.nim`
is now a presentation projection over the SDK, not a second reader.

| Command | What it does |
|---------|--------------|
| `just sdk-test` | `tests/tclientsdk.nim` — the consumer-side conformance suite (no Embed SDK needed) |
| `just sdk-boundary` | the bidirectional import lint plus its own self-test |
| `just sdk-test-embed` | `tests/tembedhandoff.nim` against the real Embed SDK; needs `$CODETRACER_SRC` or a `../codetracer` checkout — pinned commit in `ci/embed-sdk-pin.env` |
| `just debug-panes` | `tests/tdebugpanes.nim` — the debug route's five pane renderers over the Embed SDK's OWN `EditorVM`/`CalltraceVM`/`StateVM`/`EventLogVM`/`DebugControlsVM`, driven through `MockBackendService`. Needs the Embed SDK |
| `just noir-engine-dap` | **The engine seam.** CodeTracer's Noir DAP tests — `noir_flow_dap_test.rs`, `origin_noir_dap_test.rs` and the `noir-space-ship` GUI journey — ported to `tests/e2e/noir_engine_dap.nim` and run against the PUBLISHED wasm32 replay engine in a Node worker, over `fixtures/trace/noir_space_ship/zk_shields.ct`, through the same `WorkerBackendService` `client/hydrate/` drives. The only lane here that opens a real replay session. Every check names an artefact (a position, a frame count, a value, a loop iteration) and never a `success: true` — Verification-Harness-Traps §2's worked example is this exact protocol. Positions are cross-checked against `client/fixtures/demo-session/flow.json`, which `ct-print` derived from the same container bytes, so the engine is measured against the container's own reading of itself. **rc 124 = a request the engine never answered**, which is not a slow test but a dropped one |
| `just noir-engine-dap-test` | its self-test: each mutation arm verified to redden the check written for it (a kill by a different check is a MISS), plus `expect-observed` — the control a suite whose deliverable is failures needs, proving every red check goes green on the engine's own values and is not stuck red |
| `just layout-vendor` | BOTH vendored copies of CodeTracer modules — `headless_app/layout_model.nim` (the pane arrangement) and `viewmodel/viewmodels/flow_layout.nim` + `ui/flow_loop_math.nim` (the Omniscience layout arithmetic) — still hash to their manifests and still agree with upstream on every observable, plus the self-tests that drive every failure path. The flow manifest's commit must EQUAL `ci/embed-sdk-pin.env`, because those two files are inside the tree the pin names and `client/hydrate/` compiles against it |

**`just noir-engine-dap` and `just noir-engine-dap-test` RUN NOWHERE IN CI, on
purpose, and that is written down.** They are recorded in
`ci/test/ci-coverage.known-dark.txt` with what wiring them would cost. The
reason is in the lane's own commit — *"Ten checks are red and one request is
never answered, so the lane exits 124. Nothing is fixed here. Every finding is
in the engine, which is a published artifact from another repository."* A gate
that is red by design against today's engine, wired as an ordinary step, turns a
truthful diagnostic into a permanently-failing job, and a job that is always red
is one everybody learns to ignore.

That register is **not an exemption list** — it says these gates SHOULD run and
nothing runs them — and `ci/test/ci-coverage.sh` fails on it in both directions:
an entry whose gate becomes reachable, or stops existing, fails by name and
demands the line be deleted. So when the engine findings are fixed upstream, the
entry cannot quietly outlive them.

## 1b. `client/hydrate/` — the debug route's live session

The debug route ships a **second compilation**: `nim js` over
`client/hydrate/hydrate.nim`, with the Embed SDK on the Nim path, producing the
bundle `pages/debug.nim` defers. It is the only build in this repository that
links a debugger — **everything under `client/src` still compiles with none**,
which is the §1a layering and is what keeps `static_export.nim` hermetic.

| Path | Role |
|------|------|
| `client/hydrate/hydrate.nim` | the entry point: reads the served DOM, runs §14.2's capability ladder, drives the worker, re-renders panes on every stop |
| `client/hydrate/session_project.nim` | the ONE projection from CodeTracer's five ViewModels onto the pane types. `tests/tdebugpanes.nim` imports it, so `just debug-panes` drives the shipping code rather than a lookalike |
| `client/hydrate/engine_transport.nim` | the browser half of the transport — `new Worker`, `load-trace`, clipboard, `history.replaceState`. `WorkerBackendService` deliberately owns none of this |
| `client/hydrate/build.sh` | the build. Exit 3 = no Embed SDK found, which is a **valid** outcome: no bundle, no `<script>`, and the page this route has always served |

| Command | What it does |
|---------|--------------|
| `cd client && just hydrate` | build the bundle → `client/hydrate/hydrate.js` |
| `cd client && just export-hydrated` | build the bundle, then export with `-d:hydrationBundle=/assets/hydrate.js` |
| `cd client && just replay-engine` | copy the published `worker.js` + `pkg/` into `dist/replay-engine/` (§5.1's "copy to own origin"; `new Worker` requires same-origin) |
| `cd client && just preview-live` | all three, then serve — a genuinely live session on :8080 |

**`replay_engine.HydrationBundle` is empty by default**, and that default is
Page-Descriptions §7.0's guarantee made structural: a build that cannot produce
the bundle emits no `<script>` and serves exactly today's page. Never make the
page carry a script tag for a file the build might not have written —
`installHydrationBundle` fails the build rather than shipping one.

**The two engine assets are not vendored and not in `dist` by default.** A
deploy either copies them to its own origin (`just replay-engine`) or points
`-d:replayEngineBase` at an origin that already serves them. With neither,
hydration reports that it could not start and the served page stands.

### The artefact you photograph is not the artefact the visitor loads

`cd client && just export` writes `client/dist` and it contains **zero
JavaScript**. `flake.nix`'s `packages.default` — which is what
`.github/workflows/deploy-cloudflare-pages.yml` builds and uploads — runs the
same exporter with `-d:hydrationBundle=/assets/hydrate.js`. `debugLayout` emits
that `<script>`; `pageLayout` does not. So **every `debugger*` route and every
transaction serving a session diverge between the two builds**, and the
explorer's other routes do not.

This has already produced two defects in the review record, and neither was
carelessness. A `Supply sources` reason string shipped saying "this route ships
no client script" — true of `client/dist`, false of the deployed site. A
reviewer nearly filed a P1 on an engine-loading state that only the capture
build shows. Both authors were reasoning correctly about the artefact in front
of them, and it was the wrong artefact.

    just capture-hydration-divergence        # which views diverge, and what the
                                             # bundle adds that nothing draws

H1 decides the per-view answer from the two built trees and writes
`tools/capture/hydration-divergence.json`; `render-brief.mjs` and
`review-prompt.mjs` render it into every view's block through
`tools/capture/lib/provenance.mjs`, so a reviewer is told which build is in
front of them. H2 asserts that every class the shipped bundle adds has a rule in
the stylesheet those pages inline — it currently FAILS on `.copybtn`, `.copied`
and `.copyfailed`, which is `reviews/QUEUED-DECISIONS.md` Q23.

**Before writing a sentence, a comment or a finding that names a build-dependent
mechanism, check which build you mean.** An explanation naming a mechanism is a
claim about an artefact.

## 1b-i. The instruction listing — the Code pane's floor

A chain recording is **rung 3**: no step resolves to a source line, because
nothing resolved the contract's compiled artifact. That does not mean a step has
no coordinate. Every step in these containers carries a **program counter**, an
**opcode number** and a **gas reading**, and until `instruction_listing.nim` none
of it reached a page — the pane described an instruction-level recording in prose
and then rendered no instructions.

| Path | Role |
|------|------|
| `tools/chain/derive-instructions.mjs` | lifts the per-step stream out of a `.ct` into `<snapshot>/instructions/<tx>.json`. Needs `ct-print` and is **run by hand**, exactly like `client/fixtures/demo-session/extract-flow.mjs` — the site build is hermetic and cannot open a container. `just chain-instructions` |
| `src/blocktracer/chain/ingest.nim` | publishes whatever it finds as `instructions.json` beside `trace.ct`, refusing a listing whose step count disagrees with the manifest's |
| `client/src/debugger/avm_opcodes.nim` | the opcode table, with each instruction's encoded LENGTH — and `explainsProgramCounters`, which is why a mnemonic may be shown at all |
| `client/src/debugger/instruction_listing.nim` | the stream → `SourceLine` rows, so `renderSource` draws them and every mark it already knows how to draw composes by construction |

**The names are earned per recording, never asserted.** A mnemonic is an
interpretation of a number against a version of the instruction set. The table
predicts something falsifiable instead: for two consecutive steps that did not
branch, `pc[i+1] - pc[i]` must equal the first instruction's encoded length. All
2026 non-branching transitions across the eight chain containers published when
this was measured match, with zero mismatches — re-run it rather than reading the
figure as current — and a recording the table cannot explain renders `opcode 39`
rather than a guess, and says why.

**A snapshot with no `instructions/` is a valid tree.** The pane falls back to
the stated reason it has always shown. Same shape as `client/hydrate/build.sh`
exit 3.

**Do not write that the chain publishes no source.** `ContractClassPublic`
carries `artifactHash` precisely so a client can verify an artifact fetched
**off-chain**, and verified artifacts resolve — fidelity is a per-transaction
answer, not a constant of the chain. The user-facing copy says what is true of
*this recording*, and `test_chain_provenance` asserts the retired clause is
absent from every transaction page.

## 1c. The demo chain's capability tour

`/demo` is not a ledger anyone can look anything up in — it is generated from a
fixed seed and badged **Synthetic demo data** on every page. What it is FOR is
answering "what can this debugger show me?", and until 2026-09-01 it answered
badly: one recording (`noir_space_ship` / `zk_shields`) stood behind all ten of
its transactions, so opening any of them opened the same program.

The corpus is **`fixtures/trace/tour/`** — one small Noir program per
capability, each with its own `.ct` container recorded by `nargo trace`, and a
`manifest.json` saying what each demonstrates and what its recording must
contain. **`manifest.json`'s `programs[]` is the set** — read it there rather
than from a count in prose; it grew from eight to nine when `limits` landed. Read its
[README](./fixtures/trace/tour/README.md) before touching it.

| | |
|---|---|
| Publish | `generate` reads `DemoConfig.tourDir` and emits one transaction per program in **block 90**, each with its OWN container bytes and its OWN source bundle |
| Index | `d/{chain}/g/{gen}/tour.json`, read by `reader.tour` and rendered by `pages/chain.nim` above both tables. A chain with no `tour.json` renders no tour — real chains never have one |
| Re-record | `fixtures/trace/tour/record.sh` — **deliberately, not on every build**. `nargo trace` is not byte-deterministic |
| Check | `cd client && just test-capability-tour` |

Three rules that are load-bearing rather than stylistic:

- **Block 90, below the M5c tree's 100–102.** `tools/capture/lib/entities.mjs`
  walks newest block first and pins every debugger view by what the trace IS.
  A `ready` transaction above 102 would take `readyTx` from the
  transaction the review corpus is recorded against. The tour ADDS subjects; it
  moves none. Same argument that put txF–txJ at the end of block 100.
- **The tour's fee payers and contracts are keyed `500 + i`**, disjoint from
  everything else, so no existing address history gains a segment and
  `pagedAddress` / `contractWithSource` keep their subjects.
- **`demo_session.nim`'s replay describes ONE program.** Its position, call
  frames, values and event stream are `zk_shields`, and `withPublishedSources`
  now checks whether the bundle that won is that program's — a tour page would
  otherwise render `triangular` in the Code pane and `iterate_asteroids` in the
  Call Trace beside it. Where it is not, the three replay panes say the detail
  needs the engine and the controls report no position. **This is the tour's
  known gap on the static route**: the source is the program's own, the replay
  is nobody's until hydration runs.

## 2. isonim architecture

**isonim** is a cross-platform reactive UI framework for Nim (signals / effects /
memos, no virtual DOM; SolidJS-inspired). This site uses only the **server-side
HTML string** path (`renderToString`) to statically export pages. Framework
overview: [`../isonim/README.md`](../isonim/README.md).

Layout under **`client/src/`**:

| Path | Role |
|------|------|
| `ssr.nim` | **Route table** (`staticRoutes`) + `renderRoute` dispatcher; `SiteDomain = "https://blocktracer.org"` for canonical URLs |
| `static_export.nim` | Export entry (`just export` compiles & runs it → `dist/`) |
| `reader.nim`, `viewutil.nim` | Chain-data loading + view helpers. `viewutil.txMetadataRows` is the ONE producer of the transaction's facts — the tx page's overview grid and the debugger's metadata pane both render it (§7.1: "from one source", and they "cannot be allowed to diverge") |
| `pages/*.nim` | `home`, `chains`, `chain`, `blocklist`, `blockview`, `txs`, `tx`, `debug`, `address`, `code`, `search`, `settings`, `about`, `notfound` |
| `components/*.nim` | `layout` (both shells), `styles`, `debugger_css`, `nav`, `footer`, `tables` (the shared `<TransactionsTable>`), `pager` (the cursor pager — §2.2 rules out ordinal pages, so there are no page numbers anywhere), `degraded` (the ONE `case` over `ChainDegradation` in the explorer: §14's treatments, rendered from the enum `viewmodel/chain_degradation.nim` resolves), `debugger` (the pane renderers + the LayoutNode walk) |
| `debugger/*.nim` | The debug route's renderer-free layer: `layout_model.nim` (a VENDORED copy of CodeTracer's — see `layout_model.vendor.json` and `ci/test/layout-model-vendor.sh`), `session_view.nim` (what a pane renders), `source_document.nim` (the static source renderer's input), `demo_session.nim` (the static tree's producer), `flow_view.nim` (**omniscience** — recorded values placed against the source, over the vendored `vendor/frontend/**` layout arithmetic), `demo_flow.nim` (the static tree's flow window, extracted from the REAL `zk_shields.ct` by `client/fixtures/demo-session/extract-flow.mjs`) |
| `design_system/tokens.nim` | Design-system tokens |

**Route table** (`client/src/ssr.nim`) — routes are **data-derived** (one per
chain / block / tx), not a fixed page list:

```
/                                   → home
/chains                             → the registry-generated capability inventory
/about, /settings, /search          → static content, preferences, resolution
/<chain>                            → chain overview      (e.g. /aztec)
/<chain>/blocks                     → block list          (page 1)
/<chain>/blocks/from/<height>       → block list          (cursor page)
/<chain>/block/<hash>               → block detail
/<chain>/txs                        → transactions list   (page 1)
/<chain>/txs/from/<height>          → transactions list   (cursor page)
/<chain>/tx/<hash>                  → transaction detail — the session where a trace is published (§7.0)
/<chain>/tx/<hash>/debug            → the full-viewport debugging session (M8a/M8b)
/<chain>/address/<addr>             → address history     (newest segment)
/<chain>/address/<addr>/seg/<a>-<b> → address history     (one block-range segment)
/<chain>/address/<addr>/code        → verified source browser
404.html                            → §14's "not on this chain", the same bytes `renderRoute` returns
```

**Pagination is by CURSOR, never by ordinal page.** Static-Site-Architecture.md
§2.2 rules out ordinal pages in BOTH directions, so a page's identity in the URL
is the same thing the object's identity is: a block number for the two lists, a
block RANGE for address history. There is no `?page=`, no `?offset=` and no page
number in any pager. `components/pager.nim` states why.

**Crawl class is a function of the route** (`ssr.routeClass`, SEO-And-Crawl-Budget
§5–§6), and `isSitemapRoute` reads the same answer — so a route cannot carry one
class in its `<meta robots>` and be treated as another by the sitemap. `/search`
and `/settings` are N2 and every cursor page is a pagination variant; neither is
submitted.

The debug route is the **product register**: `components/layout.debugLayout`
sets `<html data-register="debugger">` and drops the nav and the footer, and the
token layer keys density and default theme off that one attribute. Its pane
arrangement is not written here — `renderLayout` walks CodeTracer's
`defaultReplayLayout()`, mapping `weight` to a flex-fraction class and `stack`
to `:target` tabs, so the whole session is navigable with scripting off.

`staticRoutes` enumerates the concrete URLs to pre-render from the chain data;
`renderRoute` dispatches by pattern (unknown → 404). **To add a page kind, add a
pattern to both `staticRoutes` enumeration and `renderRoute`.**

Reference guides (the isonim-docs SSG is a sibling consumer of isonim; these
cover routing, live components, theming, and the API/library reference model):
[getting-started](../isonim-docs/site/content/getting-started.md),
[components](../isonim-docs/site/content/components.md),
[routing](../isonim-docs/site/content/routing.md),
[api-reference](../isonim-docs/site/content/api-reference.md),
[library-reference](../isonim-docs/site/content/library-reference.md),
[theming](../isonim-docs/site/content/theming.md).

## 3. Idiomatic DSL

Pages are `proc(data): string` whose body is a single `ui:` block. Because
routes are data-driven, pages take typed chain data as parameters and use plain
Nim `for`/`if` **inside** the `ui:` block. Reserved-word attributes are
backtick-escaped (`` `method` ``, `` `type` ``).

```nim
import isonim/dsl/ui, isonim/ssr/escape

proc homePage*(infos: seq[ChainInfo]): string =
  ui:
    section(class = "sec hero"):
      tdiv(class = "inner"):
        h1(class = "display"):
          text "Step "
          span(class = "accent"):
            text "backwards"
          text " through any transaction."
        form(class = "search", action = "/search", `method` = "get"):
          input(name = "q", placeholder = "Paste a block, tx hash, or address")
          button(class = "btn primary", `type` = "submit"):
            text "Search"
```

Do:
- Use `tdiv` for `<div>`; attributes as keyword args; backtick-escape Nim
  reserved words used as attribute names (`` `method` ``, `` `type` ``).
- Emit text with `text "..."` (auto-escaped); splice rendered children/CSS with
  `raw`. Drive lists/conditionals with ordinary Nim `for`/`if` in the block.
- Assemble the page shell CSS in `layout.nim` from
  `emitTokensCss() & fontFaceCss & globalCss`.

Don't:
- Don't hand-concatenate HTML or hardcode design values — use `tables.nim`
  helpers and `design_system/tokens.nim`.
- **Don't write a raw colour, a raw pixel value, a brand primitive, an inline
  `style=` attribute, or a hand-built HTML fragment in a page or component.**
  Layer 2 sees semantic `var(--bt-*)` tokens and utility classes and nothing
  else. This is checked: `node tools/design/check-tokens.mjs` (a step of the
  `visual-design` CI job) fails on any of them — A1 colours, A2 lengths, A3
  primitives, **A5 inline styles**, **A7 hand-built markup** — and
  `check-tokens-selftest.mjs` proves it by planting each violation in the real
  source and restoring it byte-identically.
- "Raw colour" includes the **CSS system colours** (`ButtonFace`, `Canvas`,
  `CanvasText`, `LinkText`, `Field`, `Highlight`, `GrayText`, `AccentColor`,
  and the rest of the CSS Color 4 set). `ButtonFace` is not a footnote: it is
  the value that made the primary action measure 1.04:1, because `.btn` set no
  `background` and the user agent supplied one.
- Every string literal in a Layer 2 file is scanned, not only the ones that
  look like CSS. A colour inside a `raw "<span style=…>"` fragment and a colour
  in a bare attribute value (`meta(name = "theme-color", content = "#4f46e5")`)
  both fail. So do the ways of writing the same value that a text search misses:
  a CSS identifier escape (`\42 uttonFace`), a Nim numeric escape
  (`"\x42uttonFace"`), a value split across a `&` concatenation, `@IMPORT` in
  another case, and the whole of CSS Color 4 and CSS Values 4 — `hwb()`,
  `color()`, `100dvh`, `20cqw`.
- **A Layer 2 view lives in `client/src/components/` or `client/src/pages/`.**
  A `.nim` anywhere else under `client/src` that imports the isonim DSL or
  carries a stylesheet fails A0, because the two-directory scan cannot see it
  and every other rule would then report a clean pass over a subset.
- Three things the checker knowingly does NOT catch, listed so nobody assumes
  otherwise: a value built at run time from non-literal parts; a value routed
  through a `const` in a module outside those two directories; and — in the
  other direction — a single-word capitalised label such as `text "Menu"` or
  `text "Orange"`, which fails A1 as a colour. Long prose is safe; a one-word
  label that happens to be a colour name is not.
- **Cite a review finding as `ledger@<revision>:<id>`** — e.g.
  `ledger@2026-08-28.3:tx-detail/wide/light/L1/8`. A round that replaces its
  predecessor reuses the ids, so an unversioned `L1/1` silently comes to mean a
  different finding; check B4 fails on a citation that no longer resolves.

### The design tokens (VD.2)

One source of truth: **`client/src/design_system/web.tokens.json`**, the *web
lineage* of the CodeTracer design system. `tokens.nim` emits it as `--bt-*`
custom properties — `:root` (light + theme-independent), a
`prefers-color-scheme: dark` block, both `[data-theme]` overrides, and
`[data-register="debugger"]`; `check-tokens.mjs` reads the same file, so the
emitter and the linter cannot drift.

Every leaf is either **`bkToken`** (a `{ref}` into the pinned
`codetracer-design-system` brand/alias/mapped JSON) or **`bkLiteral`** (a value
no lineage supplies), and a `bkLiteral` MUST name a row in
`docs/DESIGN-DIVERGENCES-WEB.md` — `tokens.nim` raises at BUILD time if it does
not, so an untracked literal never reaches a page.

The primitive `--ct-*` ramp is deliberately no longer emitted. A brand
primitive in a view is therefore undefined as well as forbidden.

Adding a design value:

1. Add the token to `web.tokens.json`, as a `{ref}` if the brand has one.
2. If it is a literal, add `$extensions: {"bt.divergence": "D-nn"}` and the
   matching row in `docs/DESIGN-DIVERGENCES-WEB.md`.
3. `node tools/design/check-tokens.mjs --write-bindings` to refresh §4's table.
4. `just design-verify`.
- Don't push untrusted strings through `raw`.

## 4. Local testing & iteration

Exact `client/Justfile` targets (run from `client/`; verified):

| Command | What it does |
|---------|--------------|
| `cd client && just test` | every `test-*` target in `client/Justfile` — read the `test:` line there rather than this cell, which listed four of the ten |
| `cd client && just test-instruction-listing` | `tests/test_instruction_listing.nim` — the Code pane's honest floor, over the COMMITTED captures through the real producers. A recording no source resolved for renders the program counters it carries; the mnemonics are earned per recording (the opcode table must reproduce that recording's own program counters or the rows show numbers); exactly one row is marked and it is the step the toolbar counts; no branch glyph and no lexer reaches a listing; a source-level session is untouched; and the island a hydrated session re-renders from carries the whole listing rather than the served window |
| `cd client && just test-explorer-breadth` | `tests/test_explorer_breadth.nim` — M9's three verifications (renders from published files only, pointer objects are not cached across navigations, address history pages with constant per-page cost) plus the two product rules over EVERY rendered page. Built `-d:release`: one case walks a synthetic address of 100,000 transactions from its first page to its last |
| `cd client && just test-debug-route` | `tests/test_debug_route.nim` — M8a/M8b: the route, the arrangement against `LayoutNode`, the source renderer's stable line ids, §7.0's availability-decides-the-landing rule, and the stored crawl-surface baseline. No debugger on the Nim path |
| `cd client && just export` | Compiles + runs `src/static_export.nim` → writes `dist/` |
| `cd client && just preview` | Runs `export`, then serves `dist/` at **http://localhost:8080** |
| `cd client && just clean` | Removes `dist/ nimcache` + built test/export binaries |

### Journey conformance — the layer that judges what a visitor sees

Everything above asserts one component's contract over rendered *markup*. The
**journey layer** (`tools/journeys/`, run from the repository root) asserts spec
sentences — *"a visitor who opens X sees Y"* — by loading the artefact CI
deploys in a real browser. It exists because four user-visible defects passed
every gate in this repository, and none of those gates ever stated an
end-to-end claim.

| Command | What it does |
|---------|--------------|
| `just journeys-engine` | once: fetch the replay engine into `client/.replay-engine-cache` (NOT into `dist/`, which the exporter removes) |
| `just journeys-build` | `export-hydrated`, then run every journey |
| `just journeys-deployed` | the same over `nix build .#default` — byte-for-byte what the deploy uploads |
| `just journeys-selftest` | one mutation per ARM in real product source, each aimed at one named assertion — `ARMS` in `tools/journeys/selftest.mjs` is the set (this cell said "four" while there were dozens) |

CI: the **`journeys`** job in `.github/workflows/ci.yml`.

Three rules a new journey must obey — the full list is
[`tools/journeys/README.md`](./tools/journeys/README.md):

- **Never name a fixture.** No journey may name a file, a line, a step, a chain
  or a transaction. Subjects are selected by a property read off the exported
  tree; expectations are relations between two things the page reports. The
  `Nargo.toml` defect survived 115 cases because the fixture supplied the
  position they asserted back.
- **Assert what is RENDERED.** The source pane holds every file at once and
  hides all but one with CSS, so `.srcline` counts lines that *exist*. Go
  through `checkVisibility`, as `lib/probe.mjs` does.
- **Declare the assertion count.** A journey exports `assertions`, and the
  runner fails on a mismatch in either direction — an early return reports
  fewer passes, not a failure, unless the count is checked.

**`just export` vs `just export-hydrated` is not a detail.** The two disagree
about the debug route: the served frame marks the execution position and the
hydration bundle currently does not. `packages.default` ships the bundle, so the
journeys refuse a non-hydrated tree with exit 2 rather than judging a product no
visitor is served.

`ledger.json` records the journeys currently RED, with evidence and an owner.
It fails in **both** directions — a ledgered journey that goes green fails the
run, so an entry cannot outlive its defect.

`just preview` is a plain static server (rebuild + refresh — **no hot reload**).
isonim's framework dev server offers websocket live-reload (see
[dev-server.md](../isonim-docs/site/content/dev-server.md)) but this repo's
Justfile does not wire it up.

## 5. The isonim editor

**Not present.** There is no `client/src/editor/`, no `EditorWorkspace`, and no
`editor` target in either Justfile. (The sibling isonim sites
`metacraft-web-site` and `reprobuild-web-site` ship a read-only editor workspace
and are the model to follow if one is added here.)
