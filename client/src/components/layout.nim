## Page shell for the BlockTracer explorer — the document `<head>` (meta +
## inlined design-system token layer + component CSS), the site nav, the page
## content (pre-rendered HTML inserted via `raw`), and the footer.
##
## The `<style>` block is assembled from three sources, in order:
##   1. design_system/tokens.emitTokensCss() — the web-lineage `--bt-*` layer:
##      `:root` (light + theme-independent), the `prefers-color-scheme: dark`
##      block, both `[data-theme]` overrides, and the debugger register —
##      resolved from client/src/design_system/web.tokens.json over the
##      codetracer-design-system DTCG JSON.
##   2. styles.fontFaceCss — @font-face for the vendored brand faces.
##   3. styles.globalCss — the component rules, all `var(--bt-*)`.
## So every component's visual value traces back to the design system.
##
## `<html data-register="explorer">` is set explicitly rather than left to the
## default. Design-System.md §2 makes the register a property of the surface —
## explorer chrome is the web lineage, the debug route is the product lineage —
## and the token layer keys its density and default theme off this attribute.
## Writing it out means the debug route's `data-register="debugger"` is a change
## of value rather than the introduction of a new mechanism.
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
      html(lang = "en", `data-register` = "explorer"):
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
