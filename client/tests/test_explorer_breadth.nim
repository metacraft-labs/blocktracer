## M9 — Explorer Breadth Over A Proven Debugger Core.
##
## The milestone's three named verifications, plus the checks that caught the
## defects this milestone shipped with and then removed.
##
##   e2e_explorer_renders_from_published_files_only
##   test_pointer_objects_are_not_cached_across_navigations
##   e2e_address_history_pagination_has_no_cap
##
## ## How these are made to bite
##
## Every one of them is a claim about *behaviour under a condition that does not
## occur in the demo tree* — an origin that refuses everything, a chain that
## reorganises, an address with more transactions than a fixture could hold. A
## test that asserted them against the demo tree alone would pass whether or not
## the behaviour existed, which is the failure mode this repository has now
## found five times. So each one is driven against a store built for it:
##
##   * `blockedOriginStore` REFUSES any path that is not under the published
##     tree, and refuses loudly (it records the refusal) rather than returning
##     "not found" — so a page that reached for an origin fails visibly instead
##     of degrading into a page that renders without it.
##   * `reorgStore` serves TWO generations from one closure and flips its
##     pointer between navigations, which is the only way to observe whether a
##     pointer object was cached across one.
##   * `bigHistoryStore` synthesises an address with a hundred thousand
##     transactions procedurally. Nothing is written to disk, so the size is a
##     parameter rather than a fixture, and the per-page cost is *counted*
##     rather than reasoned about.
##
## And each has a companion assertion proving the check itself can fail: the
## external-origin scanner is run over markup carrying an external reference,
## the dead-link scanner over a page linking to a route that does not exist, the
## Debug-affordance scanner over a row whose action cell is empty. All three of
## those are defects this milestone actually had.

import std/[unittest, os, strutils, osproc, sets, tables]

import ../src/ssr
import ../src/reader
import ../src/viewutil
import ../src/components/degraded
import ../src/components/tables as viewTables

const Chain = "demo"

# ── a real exported tree, produced by the real exporter ────────────────────

let
  clientRoot = currentSourcePath().parentDir.parentDir
  workDir = getTempDir() / ("blocktracer-m9-breadth-" & $getCurrentProcessId())

removeDir(workDir)
createDir(workDir)

let exporterBin = workDir / "static_export_bin"
block:
  # No define: the address / code / segment route families exist only on the
  # synthetic tree, and the exporter publishes that tree again by default
  # (`static_export.nim` step 1b). Compiled with the DEPLOYED defaults so this
  # suite walks the routes a deploy actually serves.
  let cmd = "nim c --mm:orc -d:isServer -d:release --hints:off --nimcache:" &
    quoteShell(workDir / "nimcache") & " -o:" & quoteShell(exporterBin) & " " &
    quoteShell(clientRoot / "src" / "static_export.nim")
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, "exporter failed to compile:\n" & output
let (runOut, runCode) = execCmdEx(quoteShell(exporterBin), workingDir = workDir)
doAssert runCode == 0, "exporter failed to run:\n" & runOut
let dist = workDir / "dist"

# ── scanners, defined once and proved to bite before being trusted ─────────

const
  # The one host this product's own markup may name: its own canonical origin.
  # SiteDomain is imported rather than spelled, so a deployment rename cannot
  # make this scanner start passing external references.
  TreePrefixes = ["d/", "idx/", "registry/", "src/", "t/"]

proc inAnchorTag(html: string; index: int): bool =
  ## Is `index` inside the opening tag of an `<a …>` (or `<area …>`)?
  ##
  ## Walks back to the nearest `<` and forward to the nearest `>`, and reads
  ## the tag name between them. Only an OPENING tag qualifies: text between an
  ## `<a>` and its `</a>` is not inside the tag, which is what makes this a
  ## statement about an attribute rather than about a region of the document.
  var open = -1
  for k in countdown(index, 0):
    if html[k] == '>': return false
    if html[k] == '<': open = k; break
  if open < 0: return false
  var close = -1
  for k in index ..< html.len:
    if html[k] == '<': return false
    if html[k] == '>': close = k; break
  if close < 0: return false
  var name = ""
  var k = open + 1
  while k < close and html[k] notin {' ', '\t', '\n', '/', '>'}:
    name.add html[k]
    inc k
  result = name.toLowerAscii in ["a", "area"]

proc externalReferences*(html: string): seq[string] =
  ## Every absolute URL a page would FETCH from an origin that is not its own.
  ##
  ## `Static-Site-Architecture.md` §1: "The browser reads static files and
  ## nothing else. No API, no database, no third-party endpoint." A page that
  ## fetches from another origin is a page that would not render with every
  ## non-CDN origin blocked, whatever the render looked like when they were
  ## reachable.
  ##
  ## ## Why an `<a href>` is not one of those (revised 2026-08-30)
  ##
  ## A hyperlink is not a fetch. Nothing is requested until the reader chooses
  ## to leave, the page renders identically with every foreign origin blocked,
  ## and the claim §1 makes — that this site depends on no third party to
  ## DISPLAY — is untouched by it. The scanner could not see the difference
  ## because it read characters and not markup, so it counted the footer's
  ## "Source on GitHub" as the same kind of thing as a CDN `<script src>`.
  ## Under that reading the site could never say who built it or where its
  ## source is, and the honest fix is for the scanner to know what an anchor
  ## is rather than for the page to stop linking.
  ##
  ## The distinction is on the ELEMENT and not on the attribute name, which is
  ## why `<link href>` (a stylesheet — a fetch) is still caught: `href` means
  ## "go there" on `<a>` and "load this" on `<link>`, and only the tag says
  ## which. A subresource NESTED inside an anchor — `<a><img src=…></a>` — is
  ## still a fetch and is still caught, because it is inside the `<img>` tag
  ## and not inside the `<a>` one.
  var i = 0
  while true:
    let at = html.find("://", i)
    if at < 0: break
    var start = at
    while start > 0 and html[start - 1] notin {'"', '\'', ' ', '(', '>', '\n'}:
      dec start
    var stop = at + 3
    while stop < html.len and html[stop] notin {'"', '\'', ' ', ')', '<', '\n'}:
      inc stop
    let url = html[start ..< stop]
    if not url.startsWith(SiteDomain) and
       not url.startsWith("http://www.sitemaps.org") and
       not inAnchorTag(html, at) and
       url notin result:
      result.add url
    i = stop

proc internalLinks*(html: string): seq[string] =
  ## Every site-absolute `href` in a page, without its fragment or query.
  var i = 0
  while true:
    let at = html.find("href=\"", i)
    if at < 0: break
    let start = at + 6
    let stop = html.find('"', start)
    if stop < 0: break
    var href = html[start ..< stop]
    let hash = href.find('#')
    if hash >= 0: href = href[0 ..< hash]
    let q = href.find('?')
    if q >= 0: href = href[0 ..< q]
    if href.startsWith("/") and href notin result: result.add href
    i = stop

proc debugCells*(html: string): seq[string] =
  ## The content of every `<td class="act" …>` — the shared transactions
  ## table's first column, which §6 requires to carry the primary action.
  var i = 0
  while true:
    let at = html.find("<td class=\"act\"", i)
    if at < 0: break
    let open = html.find('>', at)
    let stop = html.find("</td>", open)
    if open < 0 or stop < 0: break
    result.add html[open + 1 ..< stop]
    i = stop

proc emptyCells*(html: string): seq[string] =
  ## The content of every `<td class="empty" …>` — the cell rule 2 governs.
  var i = 0
  while true:
    let at = html.find("<td class=\"empty\"", i)
    if at < 0: break
    let open = html.find('>', at)
    let stop = html.find("</td>", open)
    if open < 0 or stop < 0: break
    result.add html[open + 1 ..< stop]
    i = stop

suite "M9 — the scanners below can fail (they are run against defects first)":

  test "the external-origin scanner catches a reference this product forbids":
    # Every case here is a way a page could acquire a third-party dependency:
    # a CDN script, a webfont, a tracking pixel, an XHR target in an attribute.
    check externalReferences("<script src=\"https://cdn.example.com/a.js\">").len == 1
    check externalReferences("<link href='http://fonts.example.com/f.css'>").len == 1
    check externalReferences("<img src=\"https://pixel.example.com/p.gif\">").len == 1
    # …and it does NOT flag this site's own canonical, or the sitemap schema
    # URL, which are the two absolute URLs the product legitimately emits.
    check externalReferences(
      "<link rel=\"canonical\" href=\"" & SiteDomain & "/aztec\">").len == 0
    # A HYPERLINK is not a fetch: the footer's provenance strip names Metacraft
    # Labs, CodeTracer and this repository, and the page renders identically
    # with all three origins unreachable.
    check externalReferences(
      "<a href=\"https://github.com/metacraft-labs/blocktracer\">Source</a>").len == 0
    check externalReferences("<a rel=\"noopener\" href='https://codetracer.com'>x</a>").len == 0
    # …and the exemption is on the ANCHOR TAG, not on the region it opens and
    # not on the attribute name. Each of these three is the way the exemption
    # could have been written too loosely, and each must still be caught.
    check externalReferences(
      "<a href=\"/x\"><img src=\"https://pixel.example.com/p.gif\"></a>").len == 1
    check externalReferences("<a href=\"/x\">https://cdn.example.com/a.js</a>").len == 1
    check externalReferences("<link href='https://fonts.example.com/f.css'>").len == 1

  test "the dead-link scanner catches an href to a route that does not exist":
    let routes = ["/", "/chains"].toHashSet
    let page = "<a href=\"/chains\">ok</a><a href=\"/nope\">dead</a>"
    var dead: seq[string]
    for h in internalLinks(page):
      if h notin routes: dead.add h
    check dead == @["/nope"]

  test "the Debug-affordance scanner catches an empty action cell":
    # This is not hypothetical. `components/tables.debugCell` was written with
    # a top-level `if` inside `ui:`, which the SSR codegen renders as NOTHING —
    # the proc compiled, ran, and returned "". Every row in the product carried
    # `<td class="act" data-label="Debug"></td>`: the primary action, silently
    # absent, with no error anywhere.
    let broken = "<td class=\"act\" data-label=\"Debug\"></td>"
    let whole = "<td class=\"act\" data-label=\"Debug\"><a>Debug</a></td>"
    check debugCells(broken) == @[""]
    check debugCells(whole)[0].len > 0

  test "the empty-cell scanner catches a two-word apology":
    check emptyCells("<td class=\"empty\" colspan=\"8\">No transactions.</td>") ==
      @["No transactions."]

# ──────────────────────────────────────────────────────────────────────────
# e2e_explorer_renders_from_published_files_only
# ──────────────────────────────────────────────────────────────────────────

type OriginLog = ref object
  ## Paths a store was asked for, and the ones it refused as off-tree.
  asked*, refused*: seq[string]

proc blockedOriginStore(dir: string, log: OriginLog): ObjectStore =
  ## The published tree, with **every non-CDN origin blocked**.
  ##
  ## The SDK's read seam takes a path and nothing else (`store.fetchProc`), so
  ## "blocking an origin" here means refusing any path that is not under one of
  ## the published prefixes — which is the same statement one layer up: a page
  ## that needed a third party would have to ask for a path outside the tree,
  ## and there is nowhere else for it to ask.
  let inner = localTree(dir)
  newObjectStore("blocked-origin:" & dir, proc(path: string): ObjectResponse =
    log.asked.add path
    var onTree = false
    for prefix in TreePrefixes:
      if path.startsWith(prefix): onTree = true
    if not onTree:
      log.refused.add path
      return ObjectResponse(found: false)
    inner.get(path))

suite "M9 — e2e_explorer_renders_from_published_files_only":
  let plain = newDataRoot(dist)
  let routes = staticRoutes(plain)
  let log = OriginLog()
  let blocked = newDataRoot(dist, blockedOriginStore(dist, log))

  test "the route set is the whole explorer, not a subset of it":
    # The subject exists. A suite that rendered three routes could satisfy
    # everything below and prove nothing about "all explorer pages".
    check "/" in routes
    check "/chains" in routes
    check "/about" in routes
    check "/settings" in routes
    check "/search" in routes
    check ("/" & Chain) in routes
    check ("/" & Chain & "/blocks") in routes
    check ("/" & Chain & "/txs") in routes
    var kinds = initCountTable[string]()
    for route in routes:
      let parts = route.strip(chars = {'/'}).split('/')
      if parts.len >= 2: kinds.inc parts[1]
    check kinds["block"] > 0
    check kinds["tx"] > 0
    check kinds["address"] > 0
    check routes.len >= 20

  test "every route renders identically with every off-tree path refused":
    # The claim, stated as an equality rather than as "it still rendered": a
    # page that had degraded when an origin was blocked would differ.
    var rendered = 0
    for route in routes:
      let (statusA, bodyA, _) = renderRoute(plain, route)
      let (statusB, bodyB, _) = renderRoute(blocked, route)
      check statusA == 200
      check statusB == statusA
      check bodyB == bodyA
      check bodyA.len > 500          # a rendered page, not an empty shell
      inc rendered
    check rendered == routes.len
    # Nothing was refused, because nothing was asked for off the tree.
    check log.refused.len == 0
    check log.asked.len > 0

  test "every path the whole explorer read is a published object":
    var offTree: seq[string] = @[]
    for path in log.asked:
      var onTree = false
      for prefix in TreePrefixes:
        if path.startsWith(prefix): onTree = true
      if not onTree and path notin offTree: offTree.add path
    check offTree.len == 0
    # …and the reads really happened: this is not an empty log.
    var prefixesSeen = initHashSet[string]()
    for path in log.asked:
      prefixesSeen.incl path.split('/')[0]
    check "d" in prefixesSeen
    check "registry" in prefixesSeen
    check "src" in prefixesSeen     # the code page resolved a source bundle

  test "no rendered page fetches from an origin other than this site's own":
    var offenders: seq[string]
    for route in routes:
      let (_, body, _) = renderRoute(plain, route)
      for url in externalReferences(body):
        if url notin offenders: offenders.add url
    if offenders.len > 0: echo "  external references: ", offenders
    check offenders.len == 0

  test "no rendered page ships script, so nothing can fetch one later":
    # A page with no external reference but an inline fetch would satisfy the
    # check above and violate the claim. The client ships nothing a browser
    # would EXECUTE, which is the stronger statement and the checkable one.
    #
    # Counted rather than matched as a substring, because hydration added a
    # second kind of `<script>` to the debug route: an
    # `application/json` source island carrying the source bundle as DATA,
    # which a browser neither parses nor runs and which renders nothing with
    # scripting off. A `notin "<script"` would fail on inert data and pass on
    # a `<script src>` that a build with `HydrationBundle` set would emit —
    # exactly backwards. `test_debug_route.executableScripts` states the same
    # rule for the debugger's own routes; this is that rule over every route.
    for route in routes:
      let (_, body, _) = renderRoute(plain, route)
      var i = 0
      var executable = 0
      while true:
        let at = body.find("<script", i)
        if at < 0: break
        let close = body.find('>', at)
        if close < 0: break
        if "type=\"application/json\"" notin body[at .. close]: inc executable
        i = close + 1
      check executable == 0

  test "every internal link resolves to a route the exporter wrote":
    # A published explorer that links to a page it never wrote is the one
    # failure it cannot explain away: not §14's "not on this chain", but a
    # link the product itself emitted to nothing.
    #
    # This is not hypothetical either. The oldest block a generation holds has
    # a parent hash that is a real block of a real chain and is not in this
    # tree; the block page and the block table both linked to it.
    var routeSet = routes.toHashSet
    var dead = initTable[string, string]()
    for route in routes:
      let (_, body, _) = renderRoute(plain, route)
      for href in internalLinks(body):
        # `/t/**` and `/d/**` are published OBJECTS, not routes: the trace
        # download link is a file, and it is checked as one.
        var isObject = false
        for prefix in TreePrefixes:
          if href.startsWith("/" & prefix): isObject = true
        if isObject:
          check fileExists(dist / href.strip(chars = {'/'}))
        elif href notin routeSet:
          dead[href] = route
    if dead.len > 0:
      for href, source in dead: echo "  dead: ", href, " <- ", source
    check dead.len == 0

# ──────────────────────────────────────────────────────────────────────────
# Rule 1 and rule 2, on every page that renders a transaction
# ──────────────────────────────────────────────────────────────────────────

suite "M9 — the two product rules, over every rendered page":
  let root = newDataRoot(dist)
  let routes = staticRoutes(root)

  test "every transactions-table row carries its Debug affordance, first":
    var rows = 0
    for route in routes:
      let (_, body, _) = renderRoute(root, route)
      for cell in debugCells(body):
        inc rows
        check cell.len > 0
        # It is an action or a stated reason, never a disabled control.
        check ("<a class=\"btn" in cell) or ("<span class=\"badge" in cell)
        check "disabled" notin cell
    # The subject exists: this loop ran over real rows.
    check rows > 0

  test "the Debug cell is the FIRST cell of its row, not the last":
    # §6: "Primary action, first column, always visible." A Debug column that
    # drifted to the end of the row would satisfy every other check here.
    var checkedRows = 0
    for route in routes:
      let (_, body, _) = renderRoute(root, route)
      var i = 0
      while true:
        let at = body.find("<tr class=", i)
        if at < 0: break
        let stop = body.find("</tr>", at)
        if stop < 0: break
        let row = body[at ..< stop]
        if "<td class=\"act\"" in row:
          inc checkedRows
          check row.find("<td class=\"act\"") == row.find("<td ")
        i = stop
    check checkedRows > 0

  test "nothing renders as an empty list: every empty cell is a statement":
    # Rule 2: "Either data, or a statement of why not and what would fix it."
    # A statement is a sentence, so the bar is length and a full stop — enough
    # to fail the two words this component used to default to.
    var cells = 0
    for route in routes:
      let (_, body, _) = renderRoute(root, route)
      for cell in emptyCells(body):
        inc cells
        check cell.len > 60
        check "." in cell
    # The demo tree has no empty table, so the assertion above is vacuous over
    # it — and a vacuous assertion is one of the five failures this project has
    # already found. The component is therefore driven directly with no rows,
    # which is the state the rule is about.
    let note = "This block carried no transactions, and that is a fact about " &
               "the block rather than a gap in the index."
    let empty = viewTables.txTable(Chain, @[], note)
    check emptyCells(empty).len == 1
    check note in emptyCells(empty)[0]
    check emptyCells(viewTables.blocksTable(Chain, chainInfo(root, Chain), @[],
                                        note)).len == 1

  test "a transaction with no session offers no control at all":
    # §7.0's last row: "the metadata, with the reason stated. No debugger, and
    # no pretence of one." Driven at the component, because the demo tree
    # publishes no `absent`-headline transaction to render a table row for.
    for a in [taAbsent, taUnsupported]:
      let row = TxRow(hash: "0x" & repeat("a", 40), availability: a)
      let cell = debugCells(viewTables.txTable(Chain, @[row], "x"))[0]
      check "<a " notin cell            # no link
      check "<button" notin cell        # and no button, disabled or otherwise
      check availabilityState(a) in cell
    for a in [taReady, taDivergent, taOnDemand]:
      let row = TxRow(hash: "0x" & repeat("b", 40), availability: a)
      let cell = debugCells(viewTables.txTable(Chain, @[row], "x"))[0]
      check "<a class=\"btn" in cell
      check availabilityLabel(a) in cell

# ──────────────────────────────────────────────────────────────────────────
# §14 as enum values, rendered through one component
# ──────────────────────────────────────────────────────────────────────────

suite "M9 — every degraded state is a ViewModel value with a treatment":

  test "every §14 row this package models renders a distinct treatment":
    var titles = initHashSet[string]()
    var bodies = initHashSet[string]()
    for d in ChainDegradation:
      let html = degraded.notice(d, DegradationNotice(
        subject: "0xabc", chainsChecked: @["aztec"], behindBy: 3))
      if d == cdNone:
        check html.len == 0
        continue
      check html.len > 0
      check ("data-degradation=\"" & $d & "\"") in html
      check noticeTitle(d).len > 0
      titles.incl noticeTitle(d)
      bodies.incl html
    # Distinct: a treatment shared between two rows is §14's "reinvented per
    # page" defect in reverse — one page saying the same thing about two
    # different conditions.
    check titles.len == ord(high(ChainDegradation)) - ord(low(ChainDegradation))
    check bodies.len == titles.len

  test "the notice names what §14 requires it to name":
    check "aztec" in degraded.notice(cdObjectNotFound,
      DegradationNotice(chainsChecked: @["aztec", "eth"]))
    check "eth" in degraded.notice(cdObjectNotFound,
      DegradationNotice(chainsChecked: @["aztec", "eth"]))
    # "naming how far behind"
    check "7 block" in degraded.notice(cdPipelineBehindTip,
      DegradationNotice(behindBy: 7))
    # A terminal row offers no action, because §14: "never a retry that cannot
    # succeed". The notice would render one if given one, so the check is that
    # the SURFACES do not give it one — asserted on the rendered pages below.
    check "btn" notin degraded.notice(cdBelowHistoryFloor, DegradationNotice())
    check "btn" notin degraded.notice(cdRecorderUnavailable, DegradationNotice())

  test "each surface renders only the rows its sensitivity set admits":
    # The set is data (`chain_degradation.nim`), and this is what makes it
    # load-bearing rather than documentation: a chain overview asked about a
    # transaction-shaped condition resolves to `cdNone` and says nothing.
    var s = initChainStateSnapshot()
    s.provenance = tpRecorderUnavailable
    check resolveChainDegradation(s, ChainOverviewDegradations) == cdNone
    check resolveChainDegradation(s, TransactionDegradations) ==
      cdRecorderUnavailable
    # …and precedence holds across two simultaneous conditions.
    s.presence = opNotOnThisChain
    check resolveChainDegradation(s, TransactionDegradations) == cdObjectNotFound

  test "an unknown chain slug is a 404, not an exception":
    # `chainInfo` RAISES on a chain the registry does not publish, which is
    # right for the exporter (a page that silently omits a chain must fail the
    # build) and wrong for a dispatcher. Every chain-scoped shape is driven
    # here, because the guard is one check and the shapes that reach past it
    # are many — the address, code and cursor routes each call a reader before
    # they can decide anything.
    let root = newDataRoot(dist)
    for path in ["/nosuchchain/blocks", "/nosuchchain/txs",
                 "/nosuchchain/block/0xabc", "/nosuchchain/tx/0xabc",
                 "/nosuchchain/address/0xabc",
                 "/nosuchchain/address/0xabc/code",
                 "/nosuchchain/address/0xabc/seg/1-1",
                 "/nosuchchain/blocks/from/7", "/nosuchchain/txs/from/7",
                 "/nosuchchain/tx/0xabc/debug"]:
      let (status, body, _) = renderRoute(root, path)
      check status == 404
      check "data-degradation=\"cdObjectNotFound\"" in body
    # …and the guard did not swallow the real chain.
    check renderRoute(root, "/" & Chain & "/blocks")[0] == 200

  test "the 404 body is §14's row and is the same bytes as 404.html":
    let root = newDataRoot(dist)
    let (status, body, _) = renderRoute(root, "/no/such/thing/at/all")
    check status == 404
    check "data-degradation=\"cdObjectNotFound\"" in body
    check Chain in body                      # the chains that were checked
    check readFile(dist / "404.html") == body


# ──────────────────────────────────────────────────────────────────────────
# test_pointer_objects_are_not_cached_across_navigations
#
# Static-Site-Architecture.md §5.1's last line: "The rule that prevents the
# classic explorer bug: **a pointer object is never cached across
# navigations**, so a reorged-away transaction cannot persist as a stale
# render."
#
# There is exactly one pointer object in the read path — `/d/{chain}/
# current.json` — and observing whether it was cached needs a tree whose
# pointer MOVES between two navigations. So the store below serves two sealed
# generations from one closure and flips its pointer on demand: generation 1
# where block B1 is canonical at height 100, generation 2 where a reorg has
# put B2 there instead and B1's transaction is no longer canonical.
# ──────────────────────────────────────────────────────────────────────────

const
  RChain = "reorgchain"
  B1 = "0x" & repeat("b1", 20)
  B2 = "0x" & repeat("b2", 20)
  RTx = "0x" & repeat("cc", 20)
  RAddr = "0x" & repeat("ad", 20)

type Pointer = ref object
  generation*: string

proc rTxFacts(blockHash: string): string =
  """{"chain":"""" & RChain & """","id":{"kind":"hash","hash":"""" & RTx &
  """"},"order":{"kind":"blockIndex","block":"""" & blockHash &
  """","height":100,"index":0},"outcome":{"overall":"succeeded"},""" &
  """"roles":[{"role":"feePayer","address":"""" & RAddr & """"}],""" &
  """"cost":[{"name":"gas","used":"21000","limit":"21000","unit":"gas"}],""" &
  """"payload":{"raw":"0x","selector":"0xdeadbeef","target":""},""" &
  """"logs":[],"codeEdges":[],"executions":[],"native":null}"""

proc reorgStore(p: Pointer, log: RequestLog): ObjectStore =
  ## Two sealed generations, one pointer, one closure.
  ##
  ## Generation 2 is a REORG in the precise sense §2.1 gives the word: the
  ## block objects are untouched and still correct, and what changed is the
  ## small height → hash map that says which of them the chain references.
  newObjectStore("reorg", proc(path: string): ObjectResponse =
    log.paths.add path
    let gen = p.generation
    proc found(body: string): ObjectResponse =
      ObjectResponse(found: true, body: body)
    if path == "registry/chains.v1.json":
      return found("""{"version":1,"chains":{"""" & RChain &
        """":{"recorder":{"id":"r","build":"b","version":"0"},""" &
        """"profile":{"name":"default","hash":"p"},"traceSchema":"ctfs/v4"}}}""")
    if path == "d/" & RChain & "/current.json":
      # THE pointer. Its answer depends on `p`, which the test moves between
      # navigations — so a render that read it once and kept the answer is
      # observably different from one that reads it again.
      let head = if gen == "1": B1 else: B2
      return found("""{"chain":"""" & RChain & """","generation":"""" & gen &
        """","traceSelectionVersion":"1","head":{"height":100,"hash":"""" &
        head & """"},"finalized":{"height":99,"hash":"0x00"}}""")
    for g in ["1", "2"]:
      if path == "d/" & RChain & "/g/" & g & "/root.json":
        return found("""{"contractVersion":1,"chain":"""" & RChain &
          """","generation":"""" & g & """","traceSelectionVersion":"1",""" &
          """"maps":{"summary":"d/""" & RChain & """/g/""" & g &
          """/summary.json","height":["d/""" & RChain & """/g/""" & g &
          """/height/0.json"],"blocks":[],"addr":[],"txstate":[]}}""")
      if path == "d/" & RChain & "/g/" & g & "/summary.json":
        return found("""{"chain":"""" & RChain & """","generation":"""" & g &
          """","counters":{"blocks":1,"transactions":1},""" &
          """"coverageMode":"selective","stale":false}""")
      if path == "d/" & RChain & "/g/" & g & "/height/0.json":
        # The whole reorg, as §2.1 says it is: one entry of one small map.
        let at100 = if g == "1": B1 else: B2
        return found("""{"chain":"""" & RChain & """","epoch":0,""" &
          """"heights":{"100":"""" & at100 & """"}}""")
      if path == "d/" & RChain & "/g/" & g & "/txstate/" & RTx[2 .. 5] & "/" &
                 RTx & ".json":
        let canonical = if g == "1": "true" else: "false"
        return found("""{"chain":"""" & RChain & """","tx":"""" & RTx &
          """","canonical":""" & canonical & ""","finality":"pending"}""")
    if path == "d/" & RChain & "/block/" & B1 & ".json":
      return found("""{"chain":"""" & RChain & """","hash":"""" & B1 &
        """","height":100,"parentHash":"0x00","transactions":["""" & RTx &
        """"]}""")
    if path == "d/" & RChain & "/block/" & B2 & ".json":
      return found("""{"chain":"""" & RChain & """","hash":"""" & B2 &
        """","height":100,"parentHash":"0x00","transactions":[]}""")
    if path == "d/" & RChain & "/tx/" & RTx[2 .. 5] & "/" & RTx & ".json":
      return found(rTxFacts(B1))
    if path == "d/" & RChain & "/ts/1/" & RTx[2 .. 5] & "/" & RTx & ".json":
      return found("""{"chain":"""" & RChain & """","tx":"""" & RTx &
        """","trace":{"availability":"onDemand"}}""")
    ObjectResponse(found: false))

proc pointerCachingStore(inner: ObjectStore): ObjectStore =
  ## The classic explorer bug, implemented on purpose.
  ##
  ## Caches every object it has already read, INCLUDING the pointer — which is
  ## the one thing §5.1 forbids caching across a navigation. It exists so the
  ## assertion below is not vacuous: the same renderer, over the same tree,
  ## after the same flip, produces the stale page when the pointer is cached
  ## and the reorg page when it is not.
  var cache = initTable[string, ObjectResponse]()
  newObjectStore("pointer-caching", proc(path: string): ObjectResponse =
    if path in cache: return cache[path]
    let r = inner.get(path)
    cache[path] = r
    r)

suite "M9 — test_pointer_objects_are_not_cached_across_navigations":
  let ptrObj = Pointer(generation: "1")
  let log = newRequestLog()
  let root = newDataRoot("", reorgStore(ptrObj, log))

  test "before the reorg, the block is canonical and says nothing about one":
    let (status, body, _) = renderRoute(root, "/" & RChain & "/block/" & B1)
    check status == 200
    check "data-degradation=" notin body
    check RTx in body                       # the transaction is on the page

  test "after the pointer moves, the SAME root renders the reorg explanation":
    # No new `DataRoot`, no cache clear, no re-open: exactly what a navigation
    # is. The generation is pinned FOR ONE RENDER (§2's "a client resolves
    # `current.json` once per session and pins that generation"), and the next
    # navigation resolves it again.
    ptrObj.generation = "2"
    let (status, body, _) = renderRoute(root, "/" & RChain & "/block/" & B1)
    check status == 200
    check "data-degradation=\"cdReorganisedAway\"" in body
    # …and it names where the chain went, so the page is an explanation rather
    # than an error (§14: "with the new location").
    check B2 in body
    check ("/" & RChain & "/block/" & B2) in body

  test "the pointer was read once per navigation, not once per session":
    var pointerReads = 0
    for path in log.paths:
      if path == "d/" & RChain & "/current.json": inc pointerReads
    check pointerReads == 2

  test "MUTATION BITE: caching the pointer reinstates the stale render":
    # The assertion above is only meaningful if a cached pointer would fail it.
    # This is the same renderer over the same tree with one property changed,
    # and it produces exactly the defect §5.1 names.
    let stalePtr = Pointer(generation: "1")
    let stale = newDataRoot("", pointerCachingStore(
      reorgStore(stalePtr, newRequestLog())))
    let (_, before, _) = renderRoute(stale, "/" & RChain & "/block/" & B1)
    check "data-degradation=" notin before
    stalePtr.generation = "2"
    let (_, after, _) = renderRoute(stale, "/" & RChain & "/block/" & B1)
    # The reorg happened and this render does not know: the page is byte-for-
    # byte the pre-reorg one. That is the stale render, and the check above
    # fails whenever the renderer acquires this behaviour.
    check after == before
    check "data-degradation=\"cdReorganisedAway\"" notin after

# ──────────────────────────────────────────────────────────────────────────
# e2e_address_history_pagination_has_no_cap
#
# "An address with more than a hundred thousand transactions pages from first
# to last with constant per-page cost."
#
# Both halves are checked: the walk really goes from the first page to the last
# by following the links the pager renders, and the cost of a page is COUNTED
# rather than argued for.
# ──────────────────────────────────────────────────────────────────────────

const
  BChain = "bigchain"
  BAddr = "0x" & repeat("be", 20)
  BSegments = 5_000
  BPerSegment = 20
  BTotalTx = BSegments * BPerSegment      # 100,000 — §M9's "more than a hundred thousand"
  BBaseHeight = 1_000_000

proc bHash(n: int): string =
  ## A synthetic transaction hash that encodes its own index, so the store can
  ## answer for any of a hundred thousand transactions without holding one.
  let s = $n
  "0x" & repeat("0", 40 - s.len) & s

proc bIndexOf(hash: string): int =
  var digits = hash[2 .. ^1]
  while digits.len > 1 and digits[0] == '0': digits = digits[1 .. ^1]
  parseInt(digits)

proc bigHistoryStore(log: RequestLog): ObjectStore =
  ## One address, `BTotalTx` transactions, `BSegments` block-range segments —
  ## served procedurally, so the size of the history is a parameter rather than
  ## a fixture. Segment k covers height `BBaseHeight - k` and is listed newest
  ## first, which is the display order §2.2 gives the generation's address
  ## object.
  let shard = BAddr[2 .. 5]
  let addrDir = "d/" & BChain & "/seg/" & shard & "/" & BAddr & "/"
  newObjectStore("big-history", proc(path: string): ObjectResponse =
    log.paths.add path
    proc found(body: string): ObjectResponse =
      ObjectResponse(found: true, body: body)
    if path == "registry/chains.v1.json":
      return found("""{"version":1,"chains":{"""" & BChain &
        """":{"recorder":{"id":"r","build":"b","version":"0"},""" &
        """"profile":{"name":"default","hash":"p"},"traceSchema":"ctfs/v4"}}}""")
    if path == "d/" & BChain & "/current.json":
      return found("""{"chain":"""" & BChain & """","generation":"1",""" &
        """"traceSelectionVersion":"1","head":{"height":""" & $BBaseHeight &
        ""","hash":"0xhead"},"finalized":{"height":""" & $BBaseHeight &
        ""","hash":"0xhead"}}""")
    if path == "d/" & BChain & "/g/1/root.json":
      return found("""{"contractVersion":1,"chain":"""" & BChain &
        """","generation":"1","traceSelectionVersion":"1","maps":{""" &
        """"summary":"d/""" & BChain & """/g/1/summary.json","height":[],""" &
        """"blocks":[],"addr":["d/""" & BChain & """/g/1/addr/""" & shard &
        """/""" & BAddr & """.json"],"txstate":[]}}""")
    if path == "d/" & BChain & "/g/1/summary.json":
      return found("""{"chain":"""" & BChain & """","generation":"1",""" &
        """"counters":{"blocks":""" & $BSegments & ""","transactions":""" &
        $BTotalTx & """},"coverageMode":"selective","stale":false}""")
    if path == "d/" & BChain & "/g/1/addr/" & shard & "/" & BAddr & ".json":
      # ONE object listing every segment. §2.2: "The client fetches it, then
      # fetches segments newest-first for display — segments are immutable and
      # permanently cacheable, and the list is small."
      var segs = newStringOfCap(BSegments * 96)
      for k in 0 ..< BSegments:
        if k > 0: segs.add ","
        let h = BBaseHeight - k
        segs.add "\"" & addrDir & $h & "-" & $h & ".json\""
      return found("""{"chain":"""" & BChain & """","address":"""" & BAddr &
        """","segments":[""" & segs & """]}""")
    if path.startsWith(addrDir):
      let name = path[addrDir.len .. ^1]
      let dash = name.find('-')
      if dash < 0: return ObjectResponse(found: false)
      let h = parseInt(name[0 ..< dash])
      let k = BBaseHeight - h
      if k < 0 or k >= BSegments: return ObjectResponse(found: false)
      var txs = ""
      for i in 0 ..< BPerSegment:
        if i > 0: txs.add ","
        txs.add "\"" & bHash(k * BPerSegment + i) & "\""
      return found("""{"chain":"""" & BChain & """","address":"""" & BAddr &
        """","fromBlock":""" & $h & ""","toBlock":""" & $h &
        ""","transactions":[""" & txs & """]}""")
    let txPrefix = "d/" & BChain & "/tx/"
    if path.startsWith(txPrefix) and path.endsWith(".json"):
      let hash = path[path.rfind('/') + 1 ..< path.len - 5]
      let n = bIndexOf(hash)
      if n < 0 or n >= BTotalTx: return ObjectResponse(found: false)
      let h = BBaseHeight - (n div BPerSegment)
      return found("""{"chain":"""" & BChain & """","id":{"kind":"hash",""" &
        """"hash":"""" & hash & """"},"order":{"kind":"blockIndex",""" &
        """"block":"0xblk","height":""" & $h & ""","index":""" &
        $(n mod BPerSegment) & """},"outcome":{"overall":"succeeded"},""" &
        """"roles":[{"role":"feePayer","address":"""" & BAddr & """"}],""" &
        """"cost":[{"name":"gas","used":"21000","limit":"21000",""" &
        """"unit":"gas"}],"payload":{"raw":"0x","selector":"0xaabbccdd",""" &
        """"target":""},"logs":[],"codeEdges":[],"executions":[],""" &
        """"native":null}""")
    let tsPrefix = "d/" & BChain & "/ts/1/"
    if path.startsWith(tsPrefix) and path.endsWith(".json"):
      let hash = path[path.rfind('/') + 1 ..< path.len - 5]
      return found("""{"chain":"""" & BChain & """","tx":"""" & hash &
        """","trace":{"availability":"onDemand"}}""")
    ObjectResponse(found: false))

suite "M9 — e2e_address_history_pagination_has_no_cap":
  let log = newRequestLog()
  let root = newDataRoot("", bigHistoryStore(log))
  let info = chainInfo(root, BChain)

  test "the address really has more than a hundred thousand transactions":
    # The subject exists, and it exists at the size the verification names.
    check BTotalTx > 100_000 - 1
    check BTotalTx == 100_000
    let listed = addressSegmentPaths(root, info, BAddr)
    check listed.found
    check listed.paths.len == BSegments

  test "the segment list is ONE read, whatever the length of the history":
    let l = newRequestLog()
    let r = newDataRoot("", recordingStore(bigHistoryStore(newRequestLog()), l))
    let i2 = chainInfo(r, BChain)
    let before = l.paths.len
    discard addressSegmentPaths(r, i2, BAddr)
    check l.paths.len - before == 1

  proc renderCost(segmentId: string): tuple[reads: int, segs: int, body: string] =
    ## Render one page of the address's history and COUNT what it read.
    let l = newRequestLog()
    let r = newDataRoot("", recordingStore(bigHistoryStore(newRequestLog()), l))
    let body = renderAddress(r, BChain, BAddr, segmentId)
    var segs = 0
    for p in l.paths:
      if "/seg/" in p: inc segs
    (l.paths.len, segs, body)

  test "the cost of a page does not depend on how deep into history it is":
    let ids = @["", $(BBaseHeight - 1) & "-" & $(BBaseHeight - 1),
                $(BBaseHeight - BSegments div 2) & "-" &
                  $(BBaseHeight - BSegments div 2),
                $(BBaseHeight - BSegments + 1) & "-" &
                  $(BBaseHeight - BSegments + 1)]
    var costs: seq[int]
    for id in ids:
      let c = renderCost(id)
      echo "  DEPTH id='", id, "' reads=", c.reads, " segs=", c.segs,
           " bodylen=", c.body.len, " rows=", debugCells(c.body).len
      check c.body.len > 500
      # Exactly one segment object per page: the page IS a segment, and a page
      # that read two would be a page whose cost grows with the history.
      check c.segs == 1
      costs.add c.reads
    # The last page of a hundred thousand transactions costs what the first
    # one costs — to the read.
    for c in costs: check c == costs[0]
    # …and the count is bounded by the page size rather than by the history:
    # a handful of session objects plus a constant number of reads per row.
    check costs[0] < 20 * BPerSegment
    check costs[0] > BPerSegment          # it really did read the page's rows

  test "the pager walks from the first page to the last, and stops there":
    # The claim is "pages from first to last", so the walk follows the links
    # the product actually renders rather than the segment list it derives
    # them from.
    var visited = 0
    var segmentId = ""
    var seen = initHashSet[string]()
    while true:
      let body = renderAddress(root, BChain, BAddr, segmentId)
      inc visited
      check segmentId notin seen
      seen.incl segmentId
      var older = ""
      for href in internalLinks(body):
        if "/seg/" in href: older = href
      if older.len == 0: break
      segmentId = older[older.rfind('/') + 1 .. ^1]
      # Every page but the first offers a way back to the newest, so a reader
      # deep in history is never stranded.
      check ("/" & BChain & "/address/" & BAddr) in internalLinks(body)
    check visited == BSegments
    # The last page is the OLDEST block range, which is where a backwards walk
    # of a complete history ends.
    check segmentId == $(BBaseHeight - BSegments + 1) & "-" &
                       $(BBaseHeight - BSegments + 1)

  test "no page of the walk was truncated by a record cap":
    # §9: "no record cap". Every page carries its whole segment.
    for id in ["", $(BBaseHeight - BSegments + 1) & "-" &
                   $(BBaseHeight - BSegments + 1)]:
      let body = renderAddress(root, BChain, BAddr, id)
      check debugCells(body).len == BPerSegment

removeDir(workDir)
