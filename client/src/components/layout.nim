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
import ../debugger/replay_engine

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

proc provenanceRegion(provenance: string): string =
  ## The banner placed in the page's OWN content column.
  ##
  ## `.pagebody` is full-bleed and every section inside it opens an `.inner`
  ## (`max-width:--bt-layout-container;margin:0 auto`). A notice spliced
  ## straight into the body therefore ran from viewport edge to viewport edge
  ## while the breadcrumb directly beneath it started at the gutter — so at
  ## 1920px the one element on the page that says whether the data is real was
  ## also the only element not aligned to the column it belongs to, with its
  ## left rounded corner sheared off at x=0. It read as a rendering fault on a
  ## banner whose entire job is to be believed.
  ##
  ## Returns "" for a site-level page rather than an empty container, which is
  ## the rule `hydrationScriptTag` below already follows and for the same
  ## reason: an empty `.inner` is a box with the section's margins and none of
  ## its content, and the next reader would have to prove it was harmless.
  if provenance.len == 0: return ""
  ui:
    tdiv(class = "inner"):
      raw provenance

proc pageLayout*(title, description, content: string,
                 robots = "index,follow", canonical = "",
                 provenance = "", scripts = ""): string =
  ## `scripts` is a pre-rendered string and defaults to "" — the explorer
  ## register is server-rendered and the overwhelming majority of these pages
  ## ship no JavaScript at all. It exists for the one route that CANNOT be
  ## server-rendered: `/search?q=` is resolved from the query string, which a
  ## static file server never sees. Passing a tag here is what closes that
  ## route; before it existed the search form submitted to a page that could
  ## not read what it was given, and did not say so.
  ##
  ## Same shape as `hydrationScriptTag` below and for the same reason: a STRING
  ## the caller places, never a top-level `if` inside `ui:`.
  ##
  ## `provenance` is a pre-rendered string and defaults to "": a site-level page
  ## has no chain and therefore makes no claim about whose data it shows. Every
  ## chain-scoped route passes one — see `components/provenance.nim` for why the
  ## marker has to be on the page rather than somewhere a reader might not go.
  ##
  ## It is wrapped by `provenanceRegion` so it lands in the same column as the
  ## content it qualifies. The DEBUGGER shell deliberately does not wrap it:
  ## that register has no centered column, and there the banner spanning the
  ## viewport is the correct full-width treatment rather than an escape from one.
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
            raw provenanceRegion(provenance)
            raw content
          raw siteFooter()
          raw scripts
  )

proc hydrationScriptTag(): string =
  ## The `<script defer>` for the hydration bundle: a proc that returns a
  ## STRING, never a top-level `if` inside `ui:`.
  ##
  ## `ui:` renders a top-level `if` as NOTHING — `uiSsrImpl` sends each
  ## top-level node through `ssrNodeExpr`, which returns nil for anything that
  ## is not a call, and a nil is simply not concatenated. M9 met this in
  ## `debugCell`, where it silently emitted `<td class="act"></td>` for every
  ## row and removed the Debug affordance from the product. That precedent is
  ## real, and it is why this proc returns a STRING.
  ##
  ## Written the other way round — a proc that returns "" when there is no
  ## bundle — it cannot fail silently: the empty string is a value the caller
  ## must place, not a node the codegen can drop.
  ##
  ## The *guard* is what has to stay out of `ui:`; the *tag* does not, and
  ## hand-concatenating it was a defect of its own. A string spliced through
  ## `raw` is markup the isonim DSL never sees, so the token layer cannot reach
  ## it and `tools/design/check-tokens.mjs` A7 cannot scan it — the rule exists
  ## precisely so no attribute or value hides in one. Inside the proc the `if`
  ## has already returned, so the `ui:` body is a single element call, which is
  ## the shape the SSR codegen renders. The emitted attribute is `defer=""`,
  ## which HTML defines as identical to a bare `defer` for a boolean attribute.
  ##
  ## CORRECTION, 2026-08-30. This proc was introduced by 9f551ec, whose message
  ## — and the first version of this comment, and a4e1606 — said the hydration
  ## tag had been lost to that same construct. It had not. The claim is
  ## withdrawn; the construct above is still worth avoiding, but it is not what
  ## happened here.
  ##
  ## The pre-9f551ec `if HydrationBundle.len > 0:` was nested under `body:`,
  ## not at the `ui:` body's top level, and a nested `if` never reaches
  ## `ssrNodeExpr` — it goes through `ssrChildrenExpr`, which has rendered
  ## `nnkIfStmt` branches into an if-expression since isonim 2026-04-07,
  ## including in the rev this repo pins (2a24d95, byte-identical to the
  ## sibling checkout across that region). The old form emitted the tag.
  ##
  ## Measured on the deployed bytes rather than argued. The live promotion of
  ## 5d1e44a — the deploy that was fetched, and that started the investigation
  ## — is still retrievable, and every debug and transaction page it served
  ## ends with
  ##     <script src="/assets/hydrate.js" defer="defer"></script>
  ## and the bundle it names is served next to it. What that deploy did NOT
  ## serve is /replay-engine/worker.js, which 404'd; that is what left every
  ## session a still frame with its controls waiting on an engine nothing would
  ## load, and 0cb840e is the commit that actually fixed it, by publishing the
  ## engine and asserting it on the bytes about to be uploaded. The page that
  ## genuinely carries no script tag is the home page, and that is by design:
  ## `pageLayout` deliberately has none.
  ##
  ## So this proc keeps its shape on its own merits — it is the form that
  ## cannot fail silently, and M9 proves the failure mode is not hypothetical —
  ## but it did not restore a live session, and nobody should undo the engine
  ## step believing this one replaced it.
  if HydrationBundle.len == 0: return ""
  ui:
    script(src = HydrationBundle, `defer` = "")

const SearchBundle* {.strdefine: "searchBundle".} = ""
  ## Where `client/searchboot/search.js` was published, or "" for a build that
  ## did not produce it.
  ##
  ## Separate from `HydrationBundle` because the two bundles have nothing in
  ## common but the word "script". `hydrate.js` links the CodeTracer Embed SDK,
  ## is 1.3 MB, and is deferred by the debug route only. `search.js` is 40 KB of
  ## this repository's own code with no debugger on its Nim path — AGENTS.md
  ## §1a's property — and is deferred by exactly one route. Folding them into
  ## one define would make `/search` depend on the Embed SDK to work, and would
  ## make a build that has the SDK but not the search bundle indistinguishable
  ## from one that has both.

proc searchScriptTag*(): string =
  ## The `<script defer>` for the search bundle. Same STRING-returning shape as
  ## `hydrationScriptTag`, and the same reasoning applies unchanged: a top-level
  ## `if` inside `ui:` renders as nothing, silently.
  ##
  ## `defer` rather than `async` or inline: the bundle writes into
  ## `#search-result`, which the document has to have parsed first.
  if SearchBundle.len == 0: return ""
  ui:
    script(src = SearchBundle, `defer` = "")

const SettingsBundle* {.strdefine: "settingsBundle".} = ""
  ## Where `client/settingsboot/settings.js` was published, or "" for a build
  ## that did not produce it.
  ##
  ## A THIRD DEFINE RATHER THAN A REUSED ONE, for the reason `SearchBundle`
  ## gives about the second: the three bundles have nothing in common but the
  ## word "script". This one is the smallest of them by a wide margin — it
  ## toggles two attributes and reads one `localStorage` key, and it links
  ## neither the Embed SDK nor the search corpus. Folding it into either would
  ## make `/settings` depend on a debugger to let a reader pick a keymap, and
  ## would make a build with one bundle and not the other indistinguishable
  ## from a build with both.

proc settingsScriptTag*(): string =
  ## The `<script defer>` for the settings bundle.
  ##
  ## `defer` for a sharper reason than the search bundle's: this script's first
  ## act is to unhide the preset chooser, which is served `hidden` precisely so
  ## that it does not exist as a dead control before the code that makes it
  ## live has run. Executing before the document is parsed would find neither
  ## the chooser nor the panels.
  if SettingsBundle.len == 0: return ""
  ui:
    script(src = SettingsBundle, `defer` = "")

proc debugLayout*(title, description, content: string,
                  robots = "noindex,follow", canonical = "",
                  provenance = ""): string =
  ## The debugging session's shell — Page-Descriptions §8: "the explorer chrome
  ## collapses to a slim identity bar".
  ##
  ## Two routes reach it, and §7.0 is why: `/{chain}/tx/{hash}` uses it
  ## wherever a trace is published, because "arriving at a transaction means
  ## arriving in its execution", and `/{chain}/tx/{hash}/debug` uses it always.
  ## The shell is the same on both; what differs is the `<title>`, the
  ## description, and which of the two addresses `sitemapRoutes` submits. The
  ## `robots` class and the canonical link are the same values either way, so
  ## the crawl surface does not depend on which address was asked for.
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
          # FIRST IN THE SESSION SHELL, not omitted from it. This is the
          # register where a reader is most likely to forget which chain they
          # are on — the nav and the footer are gone, the viewport is the
          # debugger, and the thing on screen is an execution. A trace that is
          # a recorded Noir program published under a synthetic hash and a
          # trace that is a real testnet transaction step identically here.
          raw provenance
          raw content
          # The hydration bundle, and ONLY on this shell.
          #
          # `defer`, and last in the body, because §7.0 requires "first paint
          # is static HTML, with no wasm on the critical path". A `defer`d
          # external script is parsed after the document and executed before
          # `DOMContentLoaded`; it cannot delay the served frame, and the
          # engine it goes on to fetch is 18 MB that a visitor must never wait
          # on to READ this page.
          #
          # Emitted only when a bundle was actually built. An empty
          # `HydrationBundle` is the ordinary case for a build without the
          # Embed SDK on its path, and it produces the page this route has
          # always produced — which is §7.0's guarantee made structural rather
          # than promised: there is no code path here that removes anything.
          #
          # `pageLayout` deliberately does NOT get this. The explorer shell has
          # no session to hydrate, and a script on it would be bytes fetched to
          # do nothing.
          raw hydrationScriptTag()
  )
