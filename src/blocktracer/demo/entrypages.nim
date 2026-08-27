## Pre-rendered HTML entry pages (Static-Site-Architecture.md §2, §3.1, §4;
## Rendering-And-Delivery.md §4.2).
##
## Every entity is addressable as its own HTML document with its data **inlined**, so
## a cold visit is a single request to first paint — no shell-then-fetch round trip
## (§3.1, §4.2). This module renders the four entry-page classes the spec enumerates:
##
##   /                             home — richly pre-rendered (I0, index,follow)
##   /{chain}/tx/{txHash}          transaction — the four-layer join, inlined
##   /{chain}/block/{blockHash}    block detail, inlined
##   /{chain}/address/{address}    address history, inlined
##
## Scope (M5c): these are the **minimal per-entity** pages of Rendering-And-Delivery
## §4.3 — correct metadata, a crawler-readable semantic summary, and the inlined data.
## They are NOT the full IsoNim client render (M5/M9); the constraint this slice meets
## is the *contract*: the URL structure of §2 and the inlined-data island of §4.2. The
## real render runs the same view code in the pre-render pass and the browser (§4);
## here the summary is deliberately structural.
##
## Robots policy (SEO-And-Crawl-Budget.md §5, class table): the home page is I0
## (`index,follow`); an ordinary demo transaction/block/address is N1 — addressable
## only (`noindex,follow`). Both are still real, inlined HTML — `noindex` governs the
## `<meta robots>`, not whether the page exists (§5, "still pre-rendered").

import std/[json, strutils]
import ../contract/entrypage

export siteBase, dataScriptId

proc escapeAttr(s: string): string =
  ## Minimal HTML-attribute / text escaping for the metadata fields.
  result = newStringOfCap(s.len)
  for c in s:
    case c
    of '<': result.add "&lt;"
    of '>': result.add "&gt;"
    of '&': result.add "&amp;"
    of '"': result.add "&quot;"
    else: result.add c

type
  Robots* = enum
    robotsIndex = "index,follow"        ## I0 — core pages
    robotsNoindex = "noindex,follow"    ## N1 — ordinary addressable entities

proc renderPage*(title, description, canonicalPath: string, robots: Robots,
                 summaryHtml: string, data: JsonNode): string =
  ## Assemble one entry page. `canonicalPath` is site-absolute (e.g. `/aztec/tx/0x…`).
  ## `data` is inlined verbatim (compact, escaped) as the `#bt-data` island — the
  ## materialised copy client-side navigation would otherwise fetch (§4.2).
  let inlined = escapeInline($data)   # compact JSON, deterministic key order preserved
  result = "<!doctype html>\n<html lang=\"en\">\n<head>\n"
  result.add "<meta charset=\"utf-8\">\n"
  result.add "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
  result.add "<title>" & escapeAttr(title) & "</title>\n"
  result.add "<meta name=\"description\" content=\"" & escapeAttr(description) & "\">\n"
  result.add "<link rel=\"canonical\" href=\"" & siteBase & canonicalPath & "\">\n"
  result.add "<meta name=\"robots\" content=\"" & $robots & "\">\n"
  result.add "</head>\n<body>\n"
  result.add "<main>\n" & summaryHtml & "\n</main>\n"
  result.add "<script type=\"application/json\" id=\"" & dataScriptId & "\">"
  result.add inlined
  result.add "</script>\n</body>\n</html>\n"

# ---------------------------------------------------------------------------
# Per-class renderers. Each builds the semantic summary + the inlined join.
# ---------------------------------------------------------------------------

proc shortHash(h: string): string =
  if h.len > 12: h[0 .. 7] & "…" & h[^4 .. ^1] else: h

proc renderTxPage*(chain, txHash: string, facts, txstate, overlay: JsonNode): string =
  ## The transaction entry page: the join of the four layers (§2.3b, §3.1) —
  ## immutable facts + generation txstate + the trace-selection overlay — materialised
  ## at publish time and inlined so the page paints in one request.
  let outcome = facts{"outcome"}{"overall"}.getStr("unknown")
  let height = facts{"order"}{"height"}.getInt(0)
  var traceAvail = "none"
  if overlay != nil:
    if "trace" in overlay: traceAvail = overlay["trace"]{"availability"}.getStr("")
    elif "executions" in overlay and overlay["executions"].len > 0:
      var avails: seq[string]
      for e in overlay["executions"]: avails.add e{"availability"}.getStr("")
      traceAvail = avails.join("+")
  let title = "Transaction " & shortHash(txHash) & " — " & chain & " — BlockTracer"
  let desc = capitalizeAscii(outcome) & " transaction on " & chain &
             " at block " & $height & "; trace " & traceAvail & "."
  var s = "<h1>Transaction</h1>\n"
  s.add "<dl>\n"
  s.add "<dt>Chain</dt><dd>" & escapeAttr(chain) & "</dd>\n"
  s.add "<dt>Hash</dt><dd><code>" & escapeAttr(txHash) & "</code></dd>\n"
  s.add "<dt>Block</dt><dd>" & $height & "</dd>\n"
  s.add "<dt>Outcome</dt><dd>" & escapeAttr(outcome) & "</dd>\n"
  s.add "<dt>Canonical</dt><dd>" & $(txstate{"canonical"}.getBool(false)) & "</dd>\n"
  s.add "<dt>Finality</dt><dd>" & escapeAttr(txstate{"finality"}.getStr("")) & "</dd>\n"
  s.add "<dt>Trace</dt><dd>" & escapeAttr(traceAvail) & "</dd>\n"
  s.add "</dl>\n"
  # The inlined join — exactly the layers client-side navigation would fetch.
  let data = %*{"kind": "tx", "chain": chain, "txHash": txHash,
                "facts": facts, "txstate": txstate, "trace": overlay}
  renderPage(title, desc, "/" & chain & "/tx/" & txHash, robotsNoindex, s, data)

proc renderBlockPage*(chain, blockHash: string, detail: JsonNode): string =
  let height = detail{"height"}.getInt(0)
  let txs = detail{"transactions"}
  let nTx = if txs != nil: txs.len else: 0
  let title = "Block " & $height & " — " & chain & " — BlockTracer"
  let desc = "Block " & $height & " on " & chain & " with " & $nTx &
             " transaction(s); hash " & shortHash(blockHash) & "."
  var s = "<h1>Block " & $height & "</h1>\n<dl>\n"
  s.add "<dt>Chain</dt><dd>" & escapeAttr(chain) & "</dd>\n"
  s.add "<dt>Hash</dt><dd><code>" & escapeAttr(blockHash) & "</code></dd>\n"
  s.add "<dt>Parent</dt><dd><code>" & escapeAttr(detail{"parentHash"}.getStr("")) & "</code></dd>\n"
  s.add "<dt>Transactions</dt><dd>" & $nTx & "</dd>\n</dl>\n"
  if nTx > 0:
    s.add "<ul>\n"
    for t in txs:
      let th = t.getStr
      s.add "<li><a href=\"/" & chain & "/tx/" & escapeAttr(th) & "\"><code>" &
            escapeAttr(shortHash(th)) & "</code></a></li>\n"
    s.add "</ul>\n"
  let data = %*{"kind": "block", "chain": chain, "blockHash": blockHash, "block": detail}
  renderPage(title, desc, "/" & chain & "/block/" & blockHash, robotsNoindex, s, data)

proc renderAddressPage*(chain, address: string, addrList: JsonNode,
                        segments: seq[JsonNode]): string =
  var nTx = 0
  for seg in segments:
    let st = seg{"transactions"}
    if st != nil: nTx += st.len
  let title = "Address " & shortHash(address) & " — " & chain & " — BlockTracer"
  let desc = "Address " & shortHash(address) & " on " & chain & " across " &
             $segments.len & " segment(s), " & $nTx & " transaction(s)."
  var s = "<h1>Address</h1>\n<dl>\n"
  s.add "<dt>Chain</dt><dd>" & escapeAttr(chain) & "</dd>\n"
  s.add "<dt>Address</dt><dd><code>" & escapeAttr(address) & "</code></dd>\n"
  s.add "<dt>Segments</dt><dd>" & $segments.len & "</dd>\n"
  s.add "<dt>Transactions</dt><dd>" & $nTx & "</dd>\n</dl>\n"
  let data = %*{"kind": "address", "chain": chain, "address": address,
                "addressList": addrList, "segments": segments}
  renderPage(title, desc, "/" & chain & "/address/" & address, robotsNoindex, s, data)

proc renderHomePage*(chains: seq[string]): string =
  ## The home page (Page-Descriptions.md §2): explain the product and get a hash into
  ## the search box. Class I0 — the one demo page that is `index,follow` and rich.
  let title = "BlockTracer — step backwards through any transaction"
  let desc = "The block explorer where you can step backwards through any transaction."
  var s = "<h1>BlockTracer</h1>\n"
  s.add "<p>The block explorer where you can step backwards through any transaction.</p>\n"
  s.add "<form action=\"/search\" method=\"get\"><input name=\"q\" placeholder=\"" &
        "block, tx hash, or address\" autofocus></form>\n"
  s.add "<h2>Chains</h2>\n<ul>\n"
  for c in chains:
    s.add "<li><a href=\"/" & escapeAttr(c) & "\">" & escapeAttr(c) & "</a></li>\n"
  s.add "</ul>\n"
  let data = %*{"kind": "home", "chains": chains}
  renderPage(title, desc, "/", robotsIndex, s, data)
