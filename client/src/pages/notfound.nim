## The not-found page — Page-Descriptions §14's "Object not found" row:
## **"'Not on this chain' with the chains checked, not a blank page."**
##
## SEO-And-Crawl-Budget §6 gives an unknown entity class G0: "Real `404`, never
## a successful generic shell." So this body is served with a 404 status by
## `ssr.renderRoute`, and the exporter also writes it to `404.html`, which is
## what a static host serves for an unmatched path. Both are the same bytes,
## because a page whose 404 body differs from its 404 file is two answers to one
## question.
##
## The treatment itself is `components/degraded.notice(cdObjectNotFound, …)` —
## the same renderer every other surface uses for the same row, so the sentence
## a visitor gets here and the sentence they get from a mis-typed address inside
## a chain page are the same sentence. Reinventing it here is exactly what
## §14's "so each has one canonical treatment rather than being reinvented per
## page" rules out.

import isonim/ssr/escape
import isonim/dsl/ui
import ../viewutil
import ../components/degraded

proc notFoundPage*(chainsChecked: seq[string]): string =
  ## Deliberately no `path` parameter.
  ##
  ## A static host serves ONE file for every unmatched path, so a page that
  ## quoted the requested URL would be right in the response body and wrong in
  ## `404.html` — two answers to one question, and only the one the test
  ## happened to render would be checked. Not naming it makes the body a pure
  ## function of the tree, which is what lets `static_export` write the very
  ## bytes `renderRoute` returns and lets the suite assert they are the same.
  ## The address is in the visitor's address bar either way.
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "eyebrow"): text "Not found"
        h1(class = "h1"): text "Nothing is published at this address"
        raw degraded.notice(cdObjectNotFound, DegradationNotice(
          chainsChecked: chainsChecked,
          detail: "",
          actionHref: chainsUrl(),
          actionLabel: "Supported chains"))
        p(class = "lead"):
          # "— which is a scoping answer rather than a dead end" is the page
          # arguing with the reader's disappointment. It also tells them nothing
          # to do next. The list of covered chains is one click away and the
          # notice above already links it, so the sentence points there instead.
          text "If this identifier is from a chain BlockTracer does not cover, "
          text "it will not be here. The supported chains are listed above."
        tdiv(class = "linkrow group"):
          a(class = "btn ghost", href = "/"): text "Home"
          a(class = "btn ghost", href = searchUrl()): text "Resolve an identifier"
