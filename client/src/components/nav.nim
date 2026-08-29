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
          # Site-level destinations only. The two chain-scoped links this bar
          # used to carry — `/aztec` and `/aztec/blocks` — named a chain the
          # nav cannot know it is on: the nav is rendered into every page of
          # every chain, and a hard-coded slug is a link that is wrong on all
          # but one of them. `/chains` is the chain-scoped entry point and is
          # generated from the registry, so it cannot name a chain that has
          # stopped being published.
          a(class = "opt", href = "/chains"):
            text "Chains"
          a(class = "opt", href = "/about"):
            text "About"
          form(action = "/search", `method` = "get"):
            input(name = "q", placeholder = "block · tx · address")
