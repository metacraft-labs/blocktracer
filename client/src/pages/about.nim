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
            # "ASK" WAS RENDERING IN LITERAL CAPITALS TO VISITORS. This
            # repository shouts for emphasis in commits, specs and comments,
            # where it is a useful signal to the next reader of the source; it
            # had leaked through a `text` literal onto a product page, where it
            # just reads as raised voice. The distinction it was drawing — that
            # the account is for REQUESTING work, not for reading — survives in
            # the word "request", which carries it without shouting.
            #
            # The rest is kept, including "costs us compute". That looks like
            # the register this sweep is removing but is not: "why do I need an
            # account?" is a question a reader genuinely arrives with, and the
            # honest answer is that generating a trace costs money. It is a
            # reason offered to the reader, not a design decision defended.
            text "Every published trace opens anonymously. An account is "
            text "needed only to request a trace that does not exist yet, "
            text "because generating one costs us compute — and the result is "
            text "then public for everyone."
          dt: text "No ads"
          dd(class = "measure"):
            text "There is no advertising surface, and no market-data widget "
            text "either: each would cost a scheduled request per visitor and "
            text "none helps someone who arrived with a transaction to "
            text "understand."
          dt: text "No tracking"
          dd(class = "measure"):
            text "No third-party requests at all, so there is nothing to "
            text "track you with. What this site can see is its own "
            text "CDN logs."
          dt: text "Complete history"
          dd(class = "measure"):
            # "no capability to negotiate and no degraded variant of an address
            # page" is the same internal phrase `pages/address` carried, and it
            # describes an architecture rather than a promise. What it means for
            # a reader is that every chain gets the same complete page.
            text "Every listed chain has complete history and complete log "
            text "coverage — the same full address page on all of them, with "
            text "no reduced version anywhere."
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
            # "An unconditional claim about variable values is the one thing
            # this product cannot afford" states the RISK TO US of getting this
            # wrong. The reader's version of the same commitment is a promise
            # about what they will be shown, which is what the second sentence
            # is now.
            text "Where a fact is not published, the page says so instead of "
            text "guessing at it. You are never shown a value that was not "
            text "recorded."
          dt: text "Fall back to a node"
          dd(class = "measure"):
            text "No page falls back to a live tracing endpoint, and no page "
            text "computes anything itself. Both would reintroduce a "
            text "third-party dependency and a second source of truth."
        p(class = "muted stack"):
          a(href = settingsUrl()): text "What this site can see →"
