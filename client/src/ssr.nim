## SSR entry point — turns a data-plane `DataRoot` into rendered explorer pages,
## isonim-website style. Unlike a fixed-route marketing site, BlockTracer's routes
## are DERIVED from the data (one page per block, one per transaction), so the
## route set and every page body come from the same `/d/**` tree the browser
## reads. `staticRoutes` enumerates them; `renderRoute` dispatches one; both are
## driven by `reader`, so there is a single source of truth for "what exists".

import std/strutils
import reader
import components/layout
import pages/home as homePg
import pages/chain as chainPg
import pages/blocklist as blockListPg
import pages/blockview as blockPg
import pages/tx as txPg

const SiteDomain* = "https://blocktracer.org"

# ── per-route renderers ─────────────────────────────────────────────────────

proc renderHome*(r: DataRoot): string =
  var infos: seq[ChainInfo]
  for c in chains(r): infos.add chainInfo(r, c)
  pageLayout(
    "BlockTracer — the deepest view into every transaction",
    "The deepest view into every transaction. Step and rewind every instruction, see the full call trace at a glance, and trace any value to its origin — across many chains, VMs and languages.",
    homePg.homePage(infos),
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
  else: discard
  let notFound =
    "<section class=\"sec\"><div class=\"inner\">" &
    "<h1 class=\"h2\">404 — not found</h1>" &
    "<p class=\"lead\">No such route in this static tree.</p></div></section>"
  (404, pageLayout("Not found — BlockTracer", "Page not found.", notFound,
                   robots = "noindex,follow"), "text/html")
