## About (`/about`) — Page-Descriptions §1's route map, and the target of §2's
## trust strip: "No account. No ads. No tracking. Complete history, no record
## caps." + link to the privacy summary.
##
## The one page besides the home and the chains index that is class I0
## (`index,follow`) in SEO-And-Crawl-Budget §5–§6, with the condition attached:
## "documentation must contain substantive unique content".
##
## ## REWRITTEN FOR A VISITOR, WHICH IS WHO ACTUALLY READS IT
##
## This page used to open "What BlockTracer is, and what it costs you" and then
## spend its first and largest section on "The read path" — GETs against an
## object store, immutable objects, "no coherence protocol and no cache to get
## wrong". That is the product's architecture, and it was here because the SEO
## condition above asks for substantive content and the architecture is the most
## unusual true thing this tree knows. But substantive is not the same as
## internal: a reader who clicks About wants to know what the thing DOES.
##
## So the order is inverted. `What you can do` leads, because it is the answer
## to the question the page is asked; `What it costs you` is §2's trust strip,
## which is what the page is FOR; `How it works` keeps the read path, cut to one
## paragraph in plain words, where it now serves as the evidence for "no
## tracking" rather than as the subject. The counters and badges are unchanged
## — they were always the concrete part.
##
## The section title "The trust strip, itemised" is gone. `trust strip` is
## §2's name for the row of claims, not a phrase any visitor has met, and a
## heading naming the internal artefact rather than its subject is the same
## fault this sweep removed everywhere else.

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
        h1(class = "h1"): text "What BlockTracer is"
        p(class = "lead"):
          text "A block explorer where a transaction is a debugging session. "
          text "Open one that has a recorded trace and you land inside its "
          text "execution — stepping, rewinding, and reading the values at "
          text "every line."

        h2(class = "sec-title next"): text "What you can do"
        dl(class = "dl group"):
          dt: text "Step and rewind"
          dd(class = "measure"):
            text "Move through a transaction one instruction at a time, "
            text "forwards or backwards. Nothing re-runs — the whole "
            text "execution is already recorded, so going back is as fast as "
            text "going on."
          dt: text "See the values"
          dd(class = "measure"):
            text "Every line shows the values it touched, as they were at the "
            text "point the session is stopped."
          dt: text "Read the call trace"
          dd(class = "measure"):
            text "The full tree of calls at a glance, with what each one cost "
            text "and where it went."
          dt: text "Read the source"
          dd(class = "measure"):
            text "Where the source is published, you step through the "
            text "program as it was written. Where it is not, you step "
            text "through the instructions instead."
          dt: text "Across chains and languages"
          dd(class = "measure"):
            text "The same session, whatever the chain, the VM or the "
            text "language it was written in."

        h2(class = "sec-title next"): text "What it costs you"
        dl(class = "dl group"):
          dt: text "No account"
          dd(class = "measure"):
            text "Every published trace opens anonymously. An account is "
            text "needed only to request a trace that does not exist yet, "
            text "because generating one costs us compute — and the result is "
            text "then public for everyone."
          dt: text "No ads"
          dd(class = "measure"):
            text "There is no advertising and no market-data widget. Neither "
            text "helps someone who arrived with a transaction to understand."
          dt: text "No tracking"
          dd(class = "measure"):
            text "No third-party requests at all, so there is nothing here to "
            text "track you with."
          dt: text "Nothing held back"
          dd(class = "measure"):
            text "Address history is complete and no list is cut off at a row "
            text "limit. The thousandth page costs what the first one does."

        h2(class = "sec-title next"): text "How it works"
        p(class = "lead"):
          text "Every page here is a static file. Your browser downloads it "
          text "and nothing else happens — no API, no database, no request to "
          text "anyone else. That is why there is nothing to track you with, "
          text "and why a page costs nothing to serve twice."
        dl(class = "dl group"):
          dt: text "Chains published"
          dd(class = "tnum"): text $chainCount
          dt: text "Third parties"
          dd:
            span(class = "badge ok"): text "None"
          dt: text "Account"
          dd:
            span(class = "badge ok"): text "Not required to read anything"

        h2(class = "sec-title next"): text "What it will not do"
        dl(class = "dl group"):
          dt: text "Guess"
          dd(class = "measure"):
            text "Where a fact is not published, the page says so instead of "
            text "guessing at it. You are never shown a value that was not "
            text "recorded."
          dt: text "Ask anyone else"
          dd(class = "measure"):
            text "No page calls out to a node or any other service to fill a "
            text "gap. What you see is what was published, from one source."
        p(class = "muted stack"):
          a(href = settingsUrl()): text "What this site can see →"
