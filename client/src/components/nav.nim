## Site navigation — the fixed top bar (brand mark, primary links, and the
## search box). The search box is a real form posting to `/search` for
## continuity with the pre-rendered entry pages, but the search RESULTS UI is
## deferred (M5 defers search; Search-And-Routing.md owns it) — the box is a
## stub target, not a working query path in this skeleton.

import isonim/ssr/escape
import isonim/dsl/ui

proc siteNav*(): string =
  ui:
    nav(class = "nav", id = "nav"):
      a(class = "brand", href = "/"):
        span(class = "sq")
        text "BlockTracer"
      tdiv(class = "links"):
        a(class = "opt", href = "/aztec/blocks"):
          text "Blocks"
        a(class = "opt", href = "/aztec"):
          text "Chain"
        form(action = "/search", `method` = "get"):
          input(name = "q", placeholder = "block · tx · address")
