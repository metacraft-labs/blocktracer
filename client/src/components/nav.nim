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
      # The header sits inside the SAME `.inner` container as every page body,
      # so the brand and the search field align to the content beneath them.
      # The VD.1 round measured header content at x=24→1896 against a body
      # column at x=390→1530: two unrelated grids. That round's ledger has been
      # superseded by revision 2026-08-28.3, which reuses the same finding ids
      # for different findings, so no id is cited here — the measurement is
      # recorded in docs/DESIGN-DIVERGENCES-WEB.md row D-07.
      tdiv(class = "inner"):
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
