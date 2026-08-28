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
import pages/home as homePg
import pages/chain as chainPg
import pages/blocklist as blockListPg
import pages/blockview as blockPg
import pages/tx as txPg
import pages/debug as debugPg

const SiteDomain* = "https://blocktracer.org"

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
  result = demoSession(chain, v,
    containerPath = t.containerPath,
    containerBytes = t.containerBytes,
    totalSteps = (if t.steps > 0: t.steps else: 0))
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

proc demoSessionFor*(r: DataRoot): Option[DebugSessionView] =
  ## The first replayable transaction in the tree, as a session — the home
  ## page's embedded demo.
  ##
  ## Chosen by walking the published data rather than by naming a hash: the
  ## demo tree is a pure function of a seed, and a hard-coded hash would make a
  ## reseed silently produce a home page with no demo on it. `none` when
  ## nothing is replayable, which is the honest state for a tree of
  ## on-demand-only chains.
  for chain in chains(r):
    let info = chainInfo(r, chain)
    for h in blockHashes(r, info):
      for txh in readBlockDetail(r, info, h).transactions:
        var s = debugSessionFor(r, chain, txh)
        # `hasFrame`, not `phase == spReady`: the static route serves a
        # positioned frame with the replay engine still unfetched, and the
        # embed is that same frame. Gating on `spReady` would leave the home
        # page with no demo on it until hydration exists.
        if s.hasFrame and s.integrity == siValidated and
           not s.reconstructed:
          # The embed has no scrollbar, so it opens ON the current line rather
          # than at line 1 of the file. Line numbers and anchors are unchanged,
          # so a link out of the embed lands on the same line of the full
          # session.
          s.editor = windowAround(s.editor, radius = 12)
          return some(s)
  none(DebugSessionView)

proc renderHome*(r: DataRoot): string =
  var infos: seq[ChainInfo]
  for c in chains(r): infos.add chainInfo(r, c)
  pageLayout(
    "BlockTracer — the deepest view into every transaction",
    "The deepest view into every transaction. Step and rewind every instruction, see the full call trace at a glance, and trace any value to its origin — across many chains, VMs and languages.",
    homePg.homePage(infos, demoSessionFor(r)),
    robots = "index,follow",
    canonical = SiteDomain & "/")

proc renderChain*(r: DataRoot, chain: string): string =
  let info = chainInfo(r, chain)
  let bs = blocks(r, info)
  # Latest transactions: walk the newest blocks, in block order.
  var txs: seq[TxRow]
  for b in bs:
    let bd = readBlockDetail(r, info, b.hash)
    for h in bd.transactions:
      txs.add txRow(r, info, h)
  pageLayout(
    chain & " — BlockTracer",
    "Chain overview for " & chain & ": latest blocks and transactions.",
    chainPg.chainPage(chain, info, bs, txs),
    robots = "noindex,follow",
    canonical = SiteDomain & "/" & chain)

proc renderBlockList*(r: DataRoot, chain: string): string =
  let info = chainInfo(r, chain)
  let bs = blocks(r, info)
  pageLayout(
    chain & " blocks — BlockTracer",
    "All blocks on " & chain & ", newest first.",
    blockListPg.blockListPage(chain, info, bs),
    robots = "noindex,follow",
    canonical = SiteDomain & "/" & chain & "/blocks")

proc renderBlock*(r: DataRoot, chain, hash: string): string =
  let info = chainInfo(r, chain)
  let detail = readBlockDetail(r, info, hash)
  var txs: seq[TxRow]
  for h in detail.transactions:
    txs.add txRow(r, info, h)
  pageLayout(
    "Block " & $detail.height & " — " & chain & " — BlockTracer",
    "Block " & $detail.height & " on " & chain & " with " & $detail.transactions.len & " transactions.",
    blockPg.blockPage(chain, detail, txs),
    robots = "noindex,follow",
    canonical = SiteDomain & "/" & chain & "/block/" & hash)

proc renderTx*(r: DataRoot, chain, hash: string): string =
  let info = chainInfo(r, chain)
  let v = txView(r, info, hash)
  pageLayout(
    "Transaction " & hash[0 ..< min(10, hash.len)] & "… — " & chain & " — BlockTracer",
    "Transaction on " & chain & " at block " & $v.height & ".",
    txPg.txPage(chain, v),
    robots = "noindex,follow",
    canonical = SiteDomain & "/" & chain & "/tx/" & hash)

proc renderDebug*(r: DataRoot, chain, hash: string): string =
  let s = debugSessionFor(r, chain, hash)
  debugLayout(
    "Debug " & truncHash(hash) & " — " & chain & " — BlockTracer",
    "Step through transaction " & hash & " on " & chain & ".",
    debugPg.debugPage(s),
    robots = "noindex,follow",
    # The canonical address of this content is the TRANSACTION's URL. §7.0
    # makes that page the same session's first frame, and M8b requires the
    # transaction route's crawl surface to be unchanged — which a second
    # indexable copy of the same content would not leave it.
    canonical = SiteDomain & "/" & chain & "/tx/" & hash)

# ── route enumeration + dispatch ────────────────────────────────────────────

proc staticRoutes*(r: DataRoot): seq[string] =
  ## Every clean-URL route the explorer renders from the data tree: home, and
  ## per chain the overview + block list + one page per block + one per tx.
  result.add "/"
  for chain in chains(r):
    let info = chainInfo(r, chain)
    result.add "/" & chain
    result.add "/" & chain & "/blocks"
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

proc isSitemapRoute*(route: string): bool =
  ## Whether a rendered route belongs in `sitemap.xml`.
  ##
  ## A route that is RENDERED and a route that is SUBMITTED are two different
  ## questions, and the debug route is the first case where they part company.
  ## SEO-And-Crawl-Budget.md §5's class table gives every `noindex` class
  ## "Sitemap: No", for the reason §6 gives: a sitemap is a submission, and
  ## submitting a URL that carries `noindex` spends crawl capacity to be told
  ## not to index something.
  ##
  ## It matters here beyond tidiness. M8b's requirement is that the
  ## transaction's crawl surface is UNCHANGED, and the debug route is the same
  ## content at a second address — exactly the duplicate a sitemap entry would
  ## invite a crawler to fetch and then discard. Its `<meta robots>` and its
  ## canonical already say so; being absent from the sitemap is the same
  ## statement made where a crawler reads it first.
  not route.endsWith("/debug")

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
  case parts.len
  of 1:
    return (200, renderChain(r, parts[0]), "text/html")
  of 2:
    if parts[1] == "blocks":
      return (200, renderBlockList(r, parts[0]), "text/html")
  of 3:
    case parts[1]
    of "block":
      if hasBlock(r, parts[0], parts[2]):
        return (200, renderBlock(r, parts[0], parts[2]), "text/html")
    of "tx":
      if hasTx(r, parts[0], parts[2]):
        return (200, renderTx(r, parts[0], parts[2]), "text/html")
    else: discard
  of 4:
    if parts[1] == "tx" and parts[3] == "debug" and hasTx(r, parts[0], parts[2]):
      return (200, renderDebug(r, parts[0], parts[2]), "text/html")
  else: discard
  let notFound =
    "<section class=\"sec\"><div class=\"inner\">" &
    "<h1 class=\"h2\">404 — not found</h1>" &
    "<p class=\"lead\">No such route in this static tree.</p></div></section>"
  (404, pageLayout("Not found — BlockTracer", "Page not found.", notFound,
                   robots = "noindex,follow"), "text/html")
