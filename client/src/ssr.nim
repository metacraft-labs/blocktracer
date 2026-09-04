## SSR entry point — turns a data-plane `DataRoot` into rendered explorer pages,
## isonim-website style. Unlike a fixed-route marketing site, BlockTracer's routes
## are DERIVED from the data (one page per block, one per transaction), so the
## route set and every page body come from the same `/d/**` tree the browser
## reads. `staticRoutes` enumerates them; `renderRoute` dispatches one; both are
## driven by `reader`, so there is a single source of truth for "what exists".

import std/[options, strutils]
import reader
import viewutil
import debugger/demo_session
import debugger/source_document
import debugger/session_view
import components/layout
import components/degraded
import components/provenance
import pages/home as homePg
import pages/chains as chainsPg
import pages/chain as chainPg
import pages/blocklist as blockListPg
import pages/blockview as blockPg
import pages/txs as txsPg
import pages/tx as txPg
import pages/address as addressPg
import pages/code as codePg
import pages/search as searchPg
import pages/about as aboutPg
import pages/settings as settingsPg
import pages/notfound as notFoundPg
import pages/debug as debugPg

const SiteDomain* = "https://blocktracer.org"

# ── crawl classes (SEO-And-Crawl-Budget.md §5, §6) ─────────────────────────

type
  RouteClass* = enum
    ## The three indexability classes this product's routes fall into. §5 gives
    ## each one a robots policy and a sitemap answer; §6 assigns a class per
    ## route. Both halves are read from here, so a route cannot carry one class
    ## in its `<meta>` and be treated as another by the sitemap.
    rcCore = "index,follow"           ## I0 — home, /chains, /about, chain landing
    rcAddressable = "noindex,follow"  ## N1 — ordinary entities and their lists
    rcUtility = "noindex,nofollow"    ## N2 — search, settings and embeds

func isPaginationRoute*(route: string): bool =
  ## §6's last row: "Pagination, filter, sort and layout variants … Never
  ## submitted." The three cursor shapes this client serves, named by their
  ## path segment rather than by a count of slashes, so a fourth cursor added
  ## later has to be added here to be excluded — which is a visible edit.
  "/blocks/from/" in route or "/txs/from/" in route or "/address/" in route and
    "/seg/" in route

func routeClass*(route: string): RouteClass =
  ## The crawl class of a rendered route. A total function of the route's
  ## shape, so the class is decided in one place and both the `<meta robots>`
  ## and the sitemap read the same answer.
  let p = route.strip(chars = {'/'})
  if p.len == 0: return rcCore
  case p
  of "chains", "about": return rcCore
  of "search", "settings": return rcUtility
  else: discard
  # `/{chain}` — §6: "Chain is publicly supported", which is what being in the
  # registry means here.
  if '/' notin p: return rcCore
  rcAddressable

proc isSitemapRoute*(route: string): bool =
  ## Whether a rendered route belongs in `sitemap.xml`.
  ##
  ## A route that is RENDERED and a route that is SUBMITTED are two different
  ## questions, and this is where they part company.
  ##
  ## Three exclusions, each from a row of SEO-And-Crawl-Budget.md §6:
  ##
  ##   * **`/debug`** — the transaction's content at a second address. Its own
  ##     `<meta robots>` and canonical already say so; being absent from the
  ##     sitemap is the same statement made where a crawler reads it first, and
  ##     M8b requires this milestone to add no second indexable copy.
  ##   * **`/search` and `/settings`** — class N2, whose promotion column
  ##     reads "Never". Both are utilities a reader reaches deliberately, and
  ##     neither has content a search engine should rank: one resolves an
  ##     identifier the visitor already has, the other configures their own
  ##     browser. `routeClass` gives both `rcUtility` and the filter below
  ##     reads that, so neither is listed here by name.
  ##   * **Pagination variants** — "Never submitted". Every page of a cursor
  ##     walk is reachable by following the pager from the first page, which is
  ##     what `follow` is for.
  ##
  ## **What is deliberately NOT excluded, and why it is recorded here rather
  ## than fixed:** §5's class table also gives N1 "Sitemap: No", and this
  ## client submits N1 entity pages. That predates M9 — `test_debug_route`'s
  ## crawl-surface baseline records the transaction route's sitemap membership
  ## as it was — and narrowing it would change the crawl surface of every
  ## transaction and block in the product, which is a promotion-policy decision
  ## (§7) rather than a rendering one. It is left as it was, and named, because
  ## a rule whose comment claims more than its code does is the shape of a
  ## check that cannot fail.
  if route.endsWith("/debug"): return false
  if routeClass(route) == rcUtility: return false
  if isPaginationRoute(route): return false
  true

# ── per-route renderers ─────────────────────────────────────────────────────

proc debugSessionFor*(r: DataRoot, chain, hash: string): DebugSessionView =
  ## The session one transaction's debug route renders.
  ##
  ## Assembled here rather than inside the page so that the transaction route
  ## and the debug route can build the SAME value — §7.0's "both addresses
  ## reach the same session; they differ in what the visitor asked for" — and
  ## so the source-bundle preference is applied in one place.
  let info = chainInfo(r, chain)
  let v = txView(r, info, hash)
  let t = traceView(r, info, hash)
  result = demoSession(chain, v, info,
    containerPath = t.containerPath,
    containerBytes = t.containerBytes,
    contentHash = t.contentHash,
    totalSteps = (if t.steps > 0: t.steps else: 0),
    # The MANIFEST decides whether there are source positions, not the page and
    # not the chain's name. A container recorded at instruction level renders as
    # instruction level wherever it came from, and the client-side fixture
    # sources are offered only to a trace whose manifest claims source level.
    sourceLevel = t.sourceLevel,
    # …and, from the same manifest, WHERE THE RECORDING STOPS. This is the only
    # place both the transaction's facts and its trace manifest are in hand, so
    # it is the only place the §7.1 row producer can be given the fact. See
    # `viewutil.executionEndingRow` for why it is not the transaction's outcome.
    ending = t.ending)
  if t.languages.len > 0:
    result.languages = t.languages
  result.reconstructed = t.reconstructed
  if t.truncated:
    result.integrity = siTruncated
    result.integrityDetail =
      "The recorder stopped at " & $t.steps & " steps and " & $t.frames &
      " frames — the profile's budget. Everything before that point is " &
      "complete and steps normally."
  # Trace-Artifacts.md §4: the manifest's recommendation is "the
  # interpretation the page should use", so a published bundle wins over the
  # client's fixture sources.
  withPublishedSources(result, t.sourceBundle)
  # THE MIDDLE RUNG, between the manifest's whole-recording claim above and the
  # program counters below. A recording that positions SOME of its steps sets no
  # `sourceLevel` bit, so `withPublishedSources` declines it — and its bundle and
  # its per-step positions are both published and both were going unread. This
  # takes the pane only when the one above it did not, for the same coexistence
  # reason the listing does: whatever won keeps the pane.
  # The capture's own two counts travel with the stream, so a derived one can be
  # checked against what the recording session measured rather than trusted.
  withSourcePositions(result, t.sourceBundle, t.positions,
                      v.sources.positionedSteps, v.sources.totalSteps)
  # …and the floor, AFTER it and never over it. A pane that ended up with source
  # keeps source; one that did not gets the program counters the recording
  # carries instead of a paragraph describing them. The order is the coexistence
  # rule made mechanical — see `withInstructionListing`, which refuses any pane
  # that is not `srcUnverified` and any pane that already has documents.
  withInstructionListing(result, t.instructions)

proc demoSessionFor*(r: DataRoot): Option[DebugSessionView] =
  ## The home page's featured session: the first transaction in the tree whose
  ## recording `canHeadline`.
  ##
  ## Chosen by walking the published data rather than by naming a hash: the
  ## demo tree is a pure function of a seed, and a hard-coded hash would make a
  ## reseed silently produce a home page with no demo on it.
  ##
  ## THERE IS NO FALLBACK ARM, AND ITS ABSENCE IS THE FIX. This used to admit
  ## any session that was positioned, validated and not reconstructed — three
  ## clauses that between them exclude nothing a real chain publishes — and so
  ## it featured the first transaction it met, which was a rung-3 Aztec
  ## recording whose panes truthfully report three things they cannot show.
  ## `canHeadline` states what the exhibit must HAVE instead; see its comment
  ## for why that had to be a positive rule and not an exclusion.
  ##
  ## When nothing in the tree satisfies it the answer is `none`, and the home
  ## page carries no featured session at all. That is deliberate: a tree with no
  ## source-level recording in it has nothing to headline, and the alternative —
  ## relaxing the rule until something passes — is the fallback that put the
  ## floor of the fidelity ladder on the front page in the first place.
  for chain in chains(r):
    let info = chainInfo(r, chain)
    for h in blockHashes(r, info):
      for txh in readBlockDetail(r, info, h).transactions:
        var s = debugSessionFor(r, chain, txh)
        # `hasFrame`, not `phase == spReady`: the static route serves a
        # positioned frame with the replay engine still unfetched, and the
        # embed is that same frame. Gating on `spReady` would leave the home
        # page with no demo on it until hydration exists. (`canHeadline` asks
        # `hasFrame` for exactly this reason.)
        if canHeadline(s):
          # The embed has no scrollbar, so it opens ON the current line rather
          # than at line 1 of the file. Line numbers and anchors are unchanged,
          # so a link out of the embed lands on the same line of the full
          # session.
          #
          # AND THAT IS NOW SAID IN AN ARGUMENT RATHER THAN IN A COMMENT. This
          # narrowing drops the loop header — line 4, against a window of 20..44
          # — and the flow rail's "line 4" link was left pointing at `#L-…-4` on
          # a page that no longer contained it, which a reader reported as a link
          # that does nothing. `debugUrl` is this session's own full-file surface,
          # the one the button five lines down in `pages/home` already calls
          # "Open the full session", so the rail's link now goes exactly where
          # the sentence above always claimed it would.
          s.editor = windowAround(s.editor, radius = 12,
                                  fullDocumentUrl = debugUrl(s.chain, s.txHash))
          return some(s)
  none(DebugSessionView)

# ── §14, resolved once per surface ─────────────────────────────────────────
#
# Page-Descriptions §14: "Every row above is a value of an enum on a
# ViewModel, not a branch in a view." The snapshot below is built from
# published facts, `resolveChainDegradation` picks the most severe row the
# SURFACE renders, and `components/degraded` renders exactly one treatment for
# it. No page tests a condition of its own.

proc chainSnapshot(r: DataRoot, info: ChainInfo): ChainStateSnapshot =
  ## The axes every explorer surface shares, from the pinned session.
  result = initChainStateSnapshot()
  # §5 of Static-Site-Architecture: a consumer "surfaces staleness from
  # `summary.json` rather than inferring it". The published flag decides; the
  # height delta below only names HOW FAR.
  if info.stale: result.freshness = pfBehindTip
  if not info.hasRecorder: result.provenance = tpRecorderUnavailable

proc behindBy(r: DataRoot, info: ChainInfo): int =
  ## How far the sealed generation is behind the pointer's tip, in blocks.
  ##
  ## Read from the generation's height MAP (one object per epoch), never by
  ## walking block details: this number decorates a notice, and a decoration
  ## that costs one read per block would put back exactly the cap this
  ## milestone's pagination exists to remove. Zero when the generation is not
  ## behind — the notice then says so in words instead of in a number.
  let highest = highestIndexedHeight(r, info)
  if highest < 0 or info.headHeight <= highest: 0
  else: info.headHeight - highest

proc chainNotice(r: DataRoot, info: ChainInfo): DegradationNotice =
  ## `behindBy` is computed only when the published summary says the chain IS
  ## behind. §5: a consumer "surfaces staleness from `summary.json` rather than
  ## inferring it" — so the flag decides, the delta only names how far, and a
  ## page that is not showing a staleness notice pays nothing to find out it is
  ## not showing one.
  DegradationNotice(subject: info.slug,
                    behindBy: (if info.stale: behindBy(r, info) else: 0),
                    chainsChecked: chains(r))

# ── the pages ──────────────────────────────────────────────────────────────

proc renderHome*(r: DataRoot): string =
  var infos: seq[ChainInfo]
  for c in chains(r): infos.add chainInfo(r, c)
  pageLayout(
    "BlockTracer — the deepest view into every transaction",
    # The origin clause is gone, and the reason is recorded once, at the hero
    # in `pages/home.nim` — the SDK discards the `ct/load-locals` reply, so a
    # hydrated session holds no live values, and every published transaction is
    # rung 3, which carries no variable names. This string matters more than
    # the hero rather than less: it is what a search result shows to someone
    # who has not loaded the page and so cannot check it.
    "The deepest view into every transaction. Step and rewind every instruction and see the full call trace at a glance — across many chains, VMs and languages.",
    homePg.homePage(infos, demoSessionFor(r)),
    robots = $routeClass("/"),
    canonical = SiteDomain & "/")

proc renderChains*(r: DataRoot): string =
  pageLayout(
    "Supported chains — BlockTracer",
    "Every chain BlockTracer publishes: whether its data is captured from a network or synthetic, how many blocks and transactions each holds, and how close it is to the tip.",
    chainsPg.chainsPage(chainRows(r)),
    robots = $routeClass("/chains"),
    canonical = SiteDomain & "/chains")

proc renderAbout*(r: DataRoot): string =
  pageLayout(
    "About BlockTracer — what it is and what it costs you",
    "A block explorer where a transaction is a debugging session — its whole execution recorded and replayed, not reduced to what went in and what came out.",
    aboutPg.aboutPage(chains(r).len),
    robots = $routeClass("/about"),
    canonical = SiteDomain & "/about")

proc renderSettings*(r: DataRoot): string =
  ## The keyboard-shortcut preset, and the full list of what is bound.
  ##
  ## `scripts = settingsScriptTag()` is what separates this page from the one
  ## that was deleted at this address. That page had no controls and a header
  ## explaining that controls would need script the client did not ship; this
  ## one ships the script, so the chooser it serves is a control that acts.
  pageLayout(
    "Keyboard shortcuts — BlockTracer",
    "Choose which keys step a recorded trace, and see everything the debugger binds.",
    settingsPg.settingsPage(),
    robots = $routeClass("/settings"),
    canonical = SiteDomain & "/settings",
    scripts = settingsScriptTag())

proc renderSearch*(r: DataRoot): string =
  ## §11. The query is resolved in the browser (Search-And-Routing §1–§6), so
  ## this route renders what it genuinely holds: how an identifier resolves,
  ## which chains would be checked, and the published name corpus — browsable
  ## without a query at all.
  var named: seq[searchPg.NamedEntity]
  for chain in chains(r):
    for l in labels(r, chain):
      if l.id.len == 0 or l.name.len == 0: continue
      named.add searchPg.NamedEntity(
        chain: chain, id: l.id, name: l.name, symbol: l.symbol,
        kind: l.kind, provenance: l.provenance,
        href: addressUrl(chain, l.id))
  pageLayout(
    "Search — BlockTracer",
    "Resolve a transaction hash, block, or address. Resolution is identifier lookup, not a query.",
    searchPg.searchPage(chains(r), named,
                        resolvesInBrowser = SearchBundle.len > 0),
    robots = $routeClass("/search"),
    canonical = SiteDomain & "/search",
    scripts = searchScriptTag())

proc renderChain*(r: DataRoot, chain: string): string =
  let info = chainInfo(r, chain)
  let page = txsFrom(r, info, -1)
  let bs = blocksFrom(r, info, -1, size = 10).rows
  let d = resolveChainDegradation(chainSnapshot(r, info),
                                  ChainOverviewDegradations)
  pageLayout(
    chain & " — BlockTracer",
    "Chain overview for " & chain & ": latest blocks and transactions, each with the debugger as its primary action.",
    chainPg.chainPage(chain, info, bs, page.rows, d, chainNotice(r, info),
                      tour = tour(r, info)),
    robots = $routeClass("/" & chain),
    canonical = SiteDomain & "/" & chain,
    provenance = provenanceMarker(info))

proc renderBlockList*(r: DataRoot, chain: string, fromHeight: int): string =
  let info = chainInfo(r, chain)
  let page = blocksFrom(r, info, fromHeight)
  let d = resolveChainDegradation(chainSnapshot(r, info), BlockDegradations)
  let route = if fromHeight < 0: blocksUrl(chain)
              else: blocksFromUrl(chain, fromHeight)
  pageLayout(
    chain & " blocks — BlockTracer",
    "Blocks on " & chain & ", newest first, paginated by walking backwards.",
    blockListPg.blockListPage(chain, info, page, d, chainNotice(r, info)),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderTxList*(r: DataRoot, chain: string, fromHeight: int): string =
  let info = chainInfo(r, chain)
  let page = txsFrom(r, info, fromHeight)
  let d = resolveChainDegradation(chainSnapshot(r, info), BlockDegradations)
  let route = if fromHeight < 0: txsUrl(chain)
              else: txsFromUrl(chain, fromHeight)
  pageLayout(
    chain & " transactions — BlockTracer",
    "Transactions on " & chain & ", newest first, with Debug as the first column of every row.",
    txsPg.txsPage(chain, info, page, d, chainNotice(r, info)),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderBlock*(r: DataRoot, chain, hash: string): string =
  let info = chainInfo(r, chain)
  let detail = readBlockDetail(r, info, hash)
  var txs: seq[TxRow]
  for h in detail.transactions:
    txs.add txRow(r, info, h)
  # §2.1: a reorg is a change to the height map, not to the block. So the
  # question this page asks is whether the generation's map still points at
  # this hash for this height — and the block object is correct either way.
  let canonicalHere = canonicalBlockAt(r, info, detail.height)
  var snapshot = chainSnapshot(r, info)
  if canonicalHere.len > 0 and canonicalHere != detail.hash:
    snapshot.canonicality = ccReorganisedAway
  let d = resolveChainDegradation(snapshot, BlockDegradations)
  var note = chainNotice(r, info)
  note.subject = detail.hash
  if snapshot.canonicality != ccCanonical:
    note.detail = "At height " & $detail.height & " this generation's height " &
      "map points at " & canonicalHere & "."
    note.actionHref = blockUrl(chain, canonicalHere)
    note.actionLabel = "The canonical block at this height"
  pageLayout(
    "Block " & $detail.height & " — " & chain & " — BlockTracer",
    "Block " & $detail.height & " on " & chain & " with " & $detail.transactions.len & " transactions.",
    blockPg.blockPage(chain, info, detail, txs,
                      nextBlockHash(r, info, detail.height),
                      hasBlock(r, chain, detail.parentHash), d, note),
    robots = $routeClass("/" & chain & "/block/" & hash),
    canonical = SiteDomain & "/" & chain & "/block/" & hash,
    provenance = provenanceMarker(info))

proc addressCode(r: DataRoot, info: ChainInfo, address: string,
                 rows: seq[TxRow]): seq[SourceBundleView] =
  for h in codeHashesAt(r, info, address, rows):
    result.add sourceBundleAt(r, info.slug, h)

proc renderAddress*(r: DataRoot, chain, address, segmentId: string): string =
  ## §9. One block-range segment of an address's history, with Debug on every
  ## row — and the code bound to the address, where any is.
  let info = chainInfo(r, chain)
  let v = addressView(r, info, address, segmentId)
  let rows = addressRows(r, info, v)
  var snapshot = chainSnapshot(r, info)
  if not v.indexed: snapshot.presence = opNotOnThisChain
  let d = resolveChainDegradation(snapshot, AddressDegradations)
  var note = chainNotice(r, info)
  note.subject = address
  note.detail = v.reason
  let route = if segmentId.len > 0: addressSegmentUrl(chain, address, segmentId)
              else: addressUrl(chain, address)
  pageLayout(
    "Address " & truncHash(address) & " — " & chain & " — BlockTracer",
    "Complete transaction history for " & address & " on " & chain & ", with the debugger as the primary action on every row.",
    addressPg.addressPage(chain, info, v, rows,
                          labelFor(labels(r, chain), address),
                          addressCode(r, info, address, rows), d, note),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderAddressCode*(r: DataRoot, chain, address: string): string =
  ## §10. The verified-source browser for the code at an address.
  let info = chainInfo(r, chain)
  let v = addressView(r, info, address)
  let rows = addressRows(r, info, v)
  var snapshot = chainSnapshot(r, info)
  if not v.indexed: snapshot.presence = opNotOnThisChain
  let d = resolveChainDegradation(snapshot, AddressDegradations)
  var note = chainNotice(r, info)
  note.subject = address
  note.detail = v.reason
  let code = addressCode(r, info, address, rows)
  var deployments: seq[string]
  if code.len > 0:
    deployments = deploymentsOf(r, info, code[0].codeHash)
  let route = addressCodeUrl(chain, address)
  pageLayout(
    "Source for " & truncHash(address) & " — " & chain & " — BlockTracer",
    "Verified source, compiler settings and deployments for the code at " & address & " on " & chain & ".",
    codePg.codePage(chain, address, code, deployments, d, note),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderTx*(r: DataRoot, chain, hash: string): string =
  ## `/{chain}/tx/{hash}` — Page-Descriptions §7.0, whose whole point is that
  ## **what this route serves depends on the trace, not on a click**:
  ##
  ##   `ready`, `divergent`   the debugging interface, with the transaction's
  ##                          facts as the metadata pane inside it (§7.1)
  ##   `onDemand`             the metadata, and the generate action
  ##   `absent`, `unsupported` the metadata, with the reason stated
  ##
  ## The first row renders `debugPg.debugPage` over the SAME `debugSessionFor`
  ## value the `/debug` route renders, in the same `debugLayout`. That is what
  ## §7.0's "both addresses reach the same session" means as markup: the served
  ## BODIES are byte-identical, and the two routes differ only in the two head
  ## elements that describe the request — the `<title>` and the description —
  ## and in which address `sitemapRoutes` submits. `robots`, `canonical` and
  ## the inlined stylesheet are the same bytes on both, which is the part that
  ## matters: the crawl surface does not depend on which address was asked
  ## for. Arriving at a transaction is arriving in its execution, and
  ## there is no Debug button here because there is nothing left for one to do.
  ##
  ## What this costs, itemised, because §7.0 claims it costs nothing:
  ##
  ##   * **The crawl surface.** `robots` and `canonical` are the same values on
  ##     both branches and are unchanged from before this milestone; §7.2's
  ##     facts — the overview grid, the decoded input and the chain-native
  ##     payload — are in the metadata pane on the session branch, from
  ##     `viewutil`'s producers, so no fact left the transaction's own URL.
  ##   * **First paint.** Still static HTML; the replay engine is not on the
  ##     critical path and the page says so (`engineNotice`).
  ##   * **The fallback.** There is nothing to fall back to. The client ships
  ##     no JavaScript, so the frame served here is what every visitor sees,
  ##     and "no state renders less than the pre-hydration page" holds because
  ##     the pre-hydration page is all there is.
  let info = chainInfo(r, chain)
  let v = txView(r, info, hash)
  let short = hash[0 ..< min(10, hash.len)]
  let description = "Transaction on " & chain & " at block " & $v.height & "."
  let canonical = SiteDomain & "/" & chain & "/tx/" & hash
  let robots = $routeClass("/" & chain & "/tx/" & hash)
  let s = debugSessionFor(r, chain, hash)
  if s.hasFrame:
    debugLayout(
      "Transaction " & short & "… — " & chain & " — BlockTracer",
      description,
      debugPg.debugPage(s),
      robots = robots,
      canonical = canonical,
      # NO PROVENANCE BAND IN THIS SHELL. `debugLayout` has a metadata pane
      # that §7.1 puts on the page in every state, and `viewutil.txMetadataRows`
      # opens it with the provenance row — so the marker is on this page beside
      # the transaction's other facts rather than in a strip above them. See
      # `provenance.provenanceMarker` for the whole argument; the short form is
      # that a band costs ~190px of a 1080px viewport here and the pane costs a
      # row.
      provenance = "")
  else:
    pageLayout(
      "Transaction " & short & "… — " & chain & " — BlockTracer",
      description,
      txPg.txPage(chain, v, info),
      robots = robots,
      canonical = canonical,
      # NO band and no chip: this page has a METADATA SURFACE, and
      # `viewutil.txMetadataRows` opens it with the provenance row. The rule is
      # one marker per page — the row wherever a page has facts to put it among,
      # the band or the chip only where there is nowhere else for it to go. A
      # chip above a grid whose first row says the same thing is the redundancy
      # the band rule objected to, wearing a smaller element.
      provenance = "")

proc renderDebug*(r: DataRoot, chain, hash: string): string =
  let s = debugSessionFor(r, chain, hash)
  let info = chainInfo(r, chain)
  debugLayout(
    "Debug " & truncHash(hash) & " — " & chain & " — BlockTracer",
    "Step through transaction " & hash & " on " & chain & ".",
    debugPg.debugPage(s),
    robots = $routeClass("/" & chain & "/tx/" & hash & "/debug"),
    # The canonical address of this content is the TRANSACTION's URL. §7.0
    # makes that page the same session's first frame, and M8b requires the
    # transaction route's crawl surface to be unchanged — which a second
    # indexable copy of the same content would not leave it.
    canonical = SiteDomain & "/" & chain & "/tx/" & hash,
    # See `renderTx` above: this shell's provenance is the metadata pane's row.
    provenance = "")

proc renderNotFound*(r: DataRoot): string =
  ## §14's "Object not found" row, at a real 404 (SEO §6 class G0).
  ##
  ## `chains(r)` is what was ACTUALLY reachable, not the registry's declared
  ## list, for the same reason `SearchVM.chainsChecked` is: naming a chain that
  ## could not be read would claim a search that did not happen.
  ##
  ## Takes no path, so the body is a pure function of the tree and
  ## `static_export` can write these exact bytes to `404.html` — see
  ## `pages/notfound.nim`.
  pageLayout(
    "Not found — BlockTracer",
    "Nothing is published at this address.",
    notFoundPg.notFoundPage(chains(r)),
    robots = "noindex,nofollow")

# ── route enumeration + dispatch ────────────────────────────────────────────

proc staticRoutes*(r: DataRoot): seq[string] =
  ## Every clean-URL route the explorer renders from the data tree.
  ##
  ## Enumerated from the data rather than declared, which is what makes the
  ## route set and the page bodies the same source of truth: a block that is
  ## published gets a page, a page of a cursor walk exists exactly while the
  ## walk has one, and an address the generation indexes gets a page for every
  ## segment its own list carries. Nothing here is a literal path except the
  ## five site-level pages, which have no entity behind them.
  result.add "/"
  result.add "/chains"
  result.add "/about"
  result.add "/search"
  result.add "/settings"
  for chain in chains(r):
    let info = chainInfo(r, chain)
    result.add "/" & chain
    # Block list, walked to exhaustion by its own cursor — so a page exists
    # exactly when the pager offers a link to it, and never otherwise.
    result.add blocksUrl(chain)
    var page = blocksFrom(r, info, -1)
    while page.hasMore:
      result.add blocksFromUrl(chain, page.nextFrom)
      page = blocksFrom(r, info, page.nextFrom)
    result.add txsUrl(chain)
    var tp = txsFrom(r, info, -1)
    while tp.hasMore:
      result.add txsFromUrl(chain, tp.nextFrom)
      tp = txsFrom(r, info, tp.nextFrom)
    for h in blockHashes(r, info):
      result.add "/" & chain & "/block/" & h
      let bd = readBlockDetail(r, info, h)
      for txh in bd.transactions:
        result.add "/" & chain & "/tx/" & txh
        # Page-Descriptions §8: the explicit full-viewport route and the deep
        # link target. Enumerated for EVERY transaction, not only the ones with
        # a replayable trace, because §7.0's `absent`/`unsupported` rows are
        # states this route renders — "the metadata, with the reason stated" —
        # and a 404 there would be a different, worse answer.
        result.add "/" & chain & "/tx/" & txh & "/debug"
    for address in addressesInGeneration(r, info):
      result.add addressUrl(chain, address)
      result.add addressCodeUrl(chain, address)
      let listed = addressSegmentPaths(r, info, address)
      # Every segment but the first: the first IS the address page, and a
      # second URL serving identical bytes is the duplicate a canonical link
      # exists to prevent.
      for i in 1 ..< listed.paths.len:
        result.add addressSegmentUrl(chain, address, segmentIdOf(listed.paths[i]))

proc sitemapRoutes*(r: DataRoot): seq[string] =
  ## The subset of `staticRoutes` that is submitted to search engines.
  for route in staticRoutes(r):
    if isSitemapRoute(route): result.add route

proc renderRoute*(r: DataRoot, path: string): tuple[status: int, body: string, contentType: string] =
  ## Dispatch one clean-URL path to its renderer.
  let p = path.strip(chars = {'/'})
  if p.len == 0:
    return (200, renderHome(r), "text/html")
  let parts = p.split('/')
  # Every route below the site level is chain-scoped, and `chainInfo` RAISES on
  # a chain the registry does not publish (`DataPlaneError`, so that a page
  # silently omitting a chain fails the build rather than half-rendering). That
  # is right for the exporter and wrong for a dispatcher: an unknown slug in a
  # URL is a visitor's typo, and §14's answer to it is "not on this chain",
  # not an exception. So the slug is checked ONCE here, against the registry,
  # before any branch reaches a reader.
  if parts.len >= 2 and parts[0] notin chains(r):
    return (404, renderNotFound(r), "text/html")
  case parts.len
  of 1:
    case parts[0]
    of "chains": return (200, renderChains(r), "text/html")
    of "about": return (200, renderAbout(r), "text/html")
    of "search": return (200, renderSearch(r), "text/html")
    of "settings": return (200, renderSettings(r), "text/html")
    else:
      if parts[0] in chains(r):
        return (200, renderChain(r, parts[0]), "text/html")
  of 2:
    if parts[1] == "blocks":
      return (200, renderBlockList(r, parts[0], -1), "text/html")
    if parts[1] == "txs":
      return (200, renderTxList(r, parts[0], -1), "text/html")
  of 3:
    case parts[1]
    of "block":
      if hasBlock(r, parts[0], parts[2]):
        return (200, renderBlock(r, parts[0], parts[2]), "text/html")
    of "tx":
      if hasTx(r, parts[0], parts[2]):
        return (200, renderTx(r, parts[0], parts[2]), "text/html")
    of "address":
      let info = chainInfo(r, parts[0])
      if addressSegmentPaths(r, info, parts[2]).found:
        return (200, renderAddress(r, parts[0], parts[2], ""), "text/html")
    else: discard
  of 4:
    if parts[1] == "tx" and parts[3] == "debug" and hasTx(r, parts[0], parts[2]):
      return (200, renderDebug(r, parts[0], parts[2]), "text/html")
    if parts[1] == "address" and parts[3] == "code":
      let info = chainInfo(r, parts[0])
      if addressSegmentPaths(r, info, parts[2]).found:
        return (200, renderAddressCode(r, parts[0], parts[2]), "text/html")
    if parts[1] == "blocks" and parts[2] == "from":
      try:
        return (200, renderBlockList(r, parts[0], parseInt(parts[3])), "text/html")
      except ValueError: discard
    if parts[1] == "txs" and parts[2] == "from":
      try:
        return (200, renderTxList(r, parts[0], parseInt(parts[3])), "text/html")
      except ValueError: discard
  of 5:
    if parts[1] == "address" and parts[3] == "seg":
      let info = chainInfo(r, parts[0])
      let v = addressView(r, info, parts[2], parts[4])
      if v.indexed:
        return (200, renderAddress(r, parts[0], parts[2], parts[4]), "text/html")
  else: discard
  (404, renderNotFound(r), "text/html")
