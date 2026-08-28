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
import ./debugger_css
import ./nav
import ./footer
import ../design_system/tokens

proc siteCss(): string =
  ## One stylesheet for both registers.
  ##
  ## `debugRouteCss` is inlined on EVERY page, not only on the debug route, for
  ## two reasons. The home page carries an embedded session (§2's live demo),
  ## so the product register's rules have to reach an explorer-register page
  ## anyway. And a second `<style>` payload that only some routes carry is a
  ## second thing for `tools/design/check-tokens.mjs` D1 to be right or wrong
  ## about; one payload means the shipped CSS is the same bytes everywhere and
  ## the cross-check measures the whole of it.
  ##
  ## Nothing leaks: the shell rules are scoped to `[data-register="debugger"]`
  ## and the pane rules are class-scoped to markup no explorer page emits.
  emitTokensCss() & fontFaceCss & globalCss & debugRouteCss

proc pageLayout*(title, description, content: string,
                 robots = "index,follow", canonical = ""): string =
  let css = siteCss()
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

proc debugLayout*(title, description, content: string,
                  robots = "noindex,follow", canonical = ""): string =
  ## The debug route's shell — Page-Descriptions §8: "the explorer chrome
  ## collapses to a slim identity bar".
  ##
  ## Three differences from `pageLayout`, and each is a decision rather than an
  ## omission:
  ##
  ##   * `data-register="debugger"`. Design-System.md §2 makes the register a
  ##     property of the SURFACE, and the debug route is the product lineage.
  ##     The token layer already keys density and default theme off this
  ##     attribute — 16→14px body, 12→4px cell padding, 1.6→1.35 line-height,
  ##     light→dark — so this one attribute is the whole register change. No
  ##     new token, no second stylesheet, no override.
  ##
  ##   * No site nav and no footer. The identity bar replaces the first and
  ##     nothing replaces the second: a full-viewport session has no room for
  ##     marketing chrome, and every row it took would come out of a pane.
  ##
  ##   * The content is the whole of `<body>`, not `<main class="pagebody">`,
  ##     because `.pagebody` reserves the fixed nav's height and there is no
  ##     fixed nav here.
  ##
  ## `robots` defaults to `noindex,follow`: the transaction's own URL is the
  ## canonical, indexable address (SEO-And-Crawl-Budget.md §5), and this route
  ## is the same content behind a deep link. M8b requires the transaction
  ## route's crawl surface to be UNCHANGED by this milestone, and giving the
  ## debug route its own indexable copy would change it by adding a duplicate.
  let css = siteCss()
  "<!doctype html>\n" & renderToString(proc(): string =
    ui:
      html(lang = "en", `data-register` = "debugger"):
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
          raw content
  )
