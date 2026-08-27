## Site footer — a single honest line about what this build is (a demo-data
## render), plus the standing product credo.

import isonim/ssr/escape
import isonim/dsl/ui

proc siteFooter*(): string =
  ui:
    footer(class = "foot"):
      tdiv(class = "inner"):
        tdiv:
          text "BlockTracer — the block explorer where you can step "
          text "backwards through any transaction."
        tdiv(class = "muted"):
          text "Rendered from demo data ("
          code:
            text "blocktracer-demo-gen"
          text ") — no live chain, no account, no tracking."
