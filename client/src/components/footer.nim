## Site footer — a single honest line about what this build is (a demo-data
## render), plus the standing product credo.

import isonim/ssr/escape
import isonim/dsl/ui

proc siteFooter*(): string =
  ui:
    footer(class = "foot"):
      tdiv(class = "inner"):
        tdiv:
          text "BlockTracer — the deepest view into every transaction."
          # §2's trust strip links to the privacy summary, and §12 is where a
          # visitor goes to read what this deployment can observe. Both are
          # site-level pages with no chain in their address, so the footer is
          # where they belong: a page-level link to them would have to be
          # repeated on every surface to be reachable from all of them.
          tdiv(class = "footlinks"):
            a(href = "/about"): text "About"
            a(href = "/chains"): text "Chains"
            a(href = "/settings"): text "Privacy & settings"
        tdiv(class = "muted"):
          text "Rendered from demo data ("
          span(class = "mono"):
            text "blocktracer-demo-gen"
          text ") — no live chain, no account, no tracking."
