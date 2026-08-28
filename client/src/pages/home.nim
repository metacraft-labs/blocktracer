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
          text "Step "
          span(class = "accent"):
            text "backwards"
          text " through any transaction."
        p(class = "lead sub"):
          text "BlockTracer is a block explorer where every transaction can "
          text "carry a full time-travel debugging trace. The browser reads "
          text "static files and nothing else — no API, no database."
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
