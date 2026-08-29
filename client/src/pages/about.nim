## About (`/about`) — Page-Descriptions §1's route map, and the target of §2's
## trust strip: "No account. No ads. No tracking. Complete history, no record
## caps." + link to the privacy summary.
##
## The one page besides the home and the chains index that is class I0
## (`index,follow`) in SEO-And-Crawl-Budget §5–§6, with the condition attached:
## "documentation must contain substantive unique content". So this page states
## the product's actual read path — which is unusual enough to be substantive,
## and is the evidence behind every claim in the trust strip rather than a
## restatement of them.

import isonim/ssr/escape
import isonim/dsl/ui
import ../viewutil

proc aboutPage*(chainCount: int): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          span: text "about"
        tdiv(class = "eyebrow"): text "About"
        h1(class = "h1"): text "What BlockTracer is, and what it costs you"
        p(class = "lead"):
          text "A block explorer whose transaction pages are debugging "
          text "sessions. Arriving at a transaction with a published trace "
          text "means arriving in its execution — not at a button that opens "
          text "one."

        h2(class = "sec-title next"): text "The read path"
        p(class = "lead"):
          text "The browser reads static files and nothing else. No API, no "
          text "database, no third-party endpoint, no per-request compute of "
          text "any kind. A page load is a series of GETs against an object "
          text "store behind a CDN, and most of those objects are immutable "
          text "and therefore free after the first visitor in a region."
        dl(class = "dl group"):
          dt: text "Mutable objects"
          dd(class = "measure"):
            text "One per chain — the generation pointer. Everything else a "
            text "page reads is written once and never modified, which is why "
            text "there is no coherence protocol and no cache to get wrong."
          dt: text "Chains published"
          dd(class = "tnum"): text $chainCount
          dt: text "Third parties"
          dd:
            span(class = "badge ok"): text "None"
          dt: text "Account"
          dd:
            span(class = "badge ok"): text "Not required to read anything"

        h2(class = "sec-title next"): text "The trust strip, itemised"
        dl(class = "dl group"):
          dt: text "No account"
          dd(class = "measure"):
            text "Every published trace opens anonymously. An account is "
            text "needed only to ASK the pipeline to generate a trace that "
            text "does not exist yet, because that costs us compute — and the "
            text "result is then public for everyone."
          dt: text "No ads"
          dd(class = "measure"):
            text "There is no advertising surface, and no market-data widget "
            text "either: each would cost a scheduled request per visitor and "
            text "none helps someone who arrived with a transaction to "
            text "understand."
          dt: text "No tracking"
          dd(class = "measure"):
            text "No third-party requests at all, so there is nothing to "
            text "track you with. What this deployment can observe is its own "
            text "CDN logs."
          dt: text "Complete history"
          dd(class = "measure"):
            text "The pipeline builds the address index, so every listed "
            text "chain has complete history and complete log coverage. There "
            text "is no capability to negotiate and no degraded variant of an "
            text "address page."
          dt: text "No record caps"
          dd(class = "measure"):
            text "History is stored as immutable segments keyed by block "
            text "range and paged by walking them, so the thousandth page "
            text "costs what the first one does. Nothing is truncated at a "
            text "row count."

        h2(class = "sec-title next"): text "What this product will not do"
        dl(class = "dl group"):
          dt: text "Guess"
          dd(class = "measure"):
            text "Where a fact is not published, the page says so and says "
            text "what would make it appear. An unconditional claim about "
            text "variable values is the one thing this product cannot afford."
          dt: text "Fall back to a node"
          dd(class = "measure"):
            text "No page falls back to a live tracing endpoint, and no page "
            text "computes anything itself. Both would reintroduce a "
            text "third-party dependency and a second source of truth."
        p(class = "muted stack"):
          a(href = settingsUrl()): text "What this deployment can observe →"
