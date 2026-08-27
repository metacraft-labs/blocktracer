## Page shell for the BlockTracer explorer — the document `<head>` (meta +
## inlined design-system token layer + component CSS), the site nav, the page
## content (pre-rendered HTML inserted via `raw`), and the footer.
##
## The `<style>` block is assembled from three sources, in order:
##   1. design_system/tokens.emitTokensCss() — `:root{ --ct-* }`, resolved from
##      the codetracer-design-system DTCG JSON (the single source of truth).
##   2. styles.fontFaceCss — @font-face for the vendored brand faces.
##   3. styles.globalCss — the component rules, all `var(--ct-*)`.
## So every component's visual value traces back to the design system.
##
## `robots` carries the SEO crawl class (SEO-And-Crawl-Budget.md §5): the home is
## `index,follow`; ordinary entity pages are `noindex,follow`, matching the
## pre-rendered entry pages the demo generator already emits.

import isonim/ssr/renderer
import isonim/ssr/escape
import isonim/dsl/ui
import ./styles
import ./nav
import ./footer
import ../design_system/tokens

proc pageLayout*(title, description, content: string,
                 robots = "index,follow", canonical = ""): string =
  let css = emitTokensCss() & fontFaceCss & globalCss
  "<!doctype html>\n" & renderToString(proc(): string =
    ui:
      html(lang = "en"):
        head:
          meta(charset = "utf-8")
          meta(name = "viewport", content = "width=device-width, initial-scale=1")
          meta(name = "description", content = description)
          meta(name = "robots", content = robots)
          if canonical.len > 0:
            link(rel = "canonical", href = canonical)
          title:
            text title
          style:
            raw css
        body:
          raw siteNav()
          main(class = "pagebody"):
            raw content
          raw siteFooter()
  )
