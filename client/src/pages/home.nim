## Home (`/`) — Page-Descriptions §2. Not a dashboard: one sentence explaining
## the product, a search box (a stub target — see components/nav), and the chain
## strip. Deliberately no live tickers or price widgets.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil

proc homePage*(infos: seq[ChainInfo]): string =
  ui:
    section(class = "sec hero"):
      tdiv(class = "inner"):
        h1(class = "display"):
          text "The "
          span(class = "accent"):
            text "deepest"
          text " view into every transaction."
        p(class = "lead sub"):
          text "Step and rewind every instruction. See the full call trace "
          text "at a glance. Trace any value to its origin — across many "
          text "chains, VMs and languages."
        form(class = "search", action = "/search", `method` = "get"):
          input(name = "q", placeholder = "Paste a block, tx hash, or address")
          button(class = "btn primary", `type` = "submit"):
            text "Search"
        tdiv(class = "chainstrip"):
          for info in infos:
            a(class = "chaincard", href = chainUrl(info.slug)):
              tdiv(class = "name"): text info.slug
              tdiv(class = "meta"):
                text $info.blockCount & " blocks · " & $info.txCount & " txs · head " & $info.headHeight
