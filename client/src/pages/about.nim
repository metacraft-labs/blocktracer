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
            # "with what each one COST" was a fourth sense of the word on a page
            # whose section heading already owns it. See the note on the cost
            # section below.
            text "The full tree of calls at a glance, with how much work each "
            text "one did and where it went."
          dt: text "Read the source"
          dd(class = "measure"):
            text "Where the source is published, you step through the "
            text "program as it was written. Where it is not, you step "
            text "through the instructions instead."
          dt: text "Across chains and languages"
          dd(class = "measure"):
            text "The same session, whatever the chain, the VM or the "
            text "language it was written in."
          # THIS ITEM MOVED HERE FROM `What it costs you`, WHERE A READER SAID
          # THEY COULD NOT PARSE IT. It read:
          #
          #   Nothing held back — Address history is complete and no list is
          #   cut off at a row limit. The thousandth page costs what the first
          #   one does.
          #
          # Three faults, and the last explains the others. `Nothing held back`
          # is a label naming an ABSENCE, so a reader must work out what was
          # supposedly being held back before the label means anything.
          # `costs` collided with the heading four lines above it — `What it
          # costs you` means what you give up, this `costs` meant how much work
          # a page is. And every clause denied a failure mode the page never
          # introduced: truncated lists, row caps, pagination that degrades with
          # depth. A reader who has hit those in another explorer gets it
          # instantly; everyone else gets a riddle.
          #
          # The fact underneath is worth keeping and is genuinely
          # distinguishing, so this is a rewrite rather than a deletion — and it
          # belongs HERE because it was never a cost. It is a thing the reader
          # can do.
          dt: text "Go back as far as you like"
          dd(class = "measure"):
            text "Page through an address's entire history. Nothing is cut "
            text "off at a row limit, and the oldest page is no slower to "
            text "load than the newest."

        # THREE ITEMS, AND THE SECTION NOW MEANS ONE THING.
        #
        # Re-read in one pass rather than line by line, the FRAMING was as much
        # at fault as the sentence a reader could not parse. `What it costs you`
        # asks one question — what do I give up — and three of the four items
        # answered it. The fourth was a capability wearing a denial, so the
        # section asked the reader to hold two questions at once. With it moved,
        # every item is a direct answer and all three answers are "nothing",
        # which is the whole point of asking.
        #
        # IT ALSO ENDS A COLLISION ON `cost`, which was doing four jobs on this
        # page: the heading (what you give up), "costs us compute" (our
        # expense), "the thousandth page costs what the first one does" (how
        # much work a page is), and the call trace's "what each one cost"
        # (opcodes). Only the heading keeps the word.
        h2(class = "sec-title next"): text "What it costs you"
        dl(class = "dl group"):
          dt: text "No account"
          dd(class = "measure"):
            # "ASK" USED TO RENDER IN LITERAL CAPITALS HERE. This repository
            # shouts for emphasis in commits, specs and comments, where it
            # signals something to the next reader of the source; it had leaked
            # through a `text` literal onto a product page, where it is just a
            # raised voice.
            #
            # THE REASON IS KEPT AND THE WORD `costs` IS NOT. Explaining why an
            # account exists earns its line: the sentence has just told the
            # reader there IS a case where they must register, so "why?" is a
            # question the text itself raises rather than one invented for them.
            # What the answer must not do is spend the heading's own word on a
            # different meaning, so the expense is now named concretely. It
            # makes the same point — the gate is metering, not identity
            # collection.
            text "Reading is anonymous — every published trace opens without "
            text "an account. You need one only to ask for a trace that does "
            text "not exist yet, because generating it replays the transaction "
            text "on our hardware. The result is then public for everyone."
          dt: text "No ads"
          dd(class = "measure"):
            text "There is no advertising and no market-data widget. Neither "
            text "helps you understand a transaction."
          dt: text "No tracking"
          dd(class = "measure"):
            # THE TWO FACTS THAT SURVIVED `/settings`. That page was removed as
            # a reader-reported redundancy, and all but two of its statements
            # were already made here in this same list. These two were not: that
            # this site keeps CDN logs at all, and what it leaves on the
            # reader's machine. Both are real constraints rather than
            # reassurance, and a reader who has navigated to a section headed
            # `What it costs you` has asked for exactly them — so they land
            # here rather than disappearing with the page.
            text "No third-party requests at all, so there is nothing here to "
            text "track you with. This site keeps its own CDN logs and nothing "
            text "else, and leaves nothing on your machine beyond the ordinary "
            text "browser cache."

        h2(class = "sec-title next"): text "How it works"
        p(class = "lead"):
          text "Every page here is a static file. Your browser downloads it "
          text "and nothing else happens — no API, no database, no request to "
          # "and why a page costs nothing to serve twice" was a FIFTH sense
          # of `cost` on this page — our hosting bill — and it is the one
          # reading no visitor has any use for. What it costs us to serve is
          # not what they came to find out.
          text "anyone else. That is why there is nothing here to track you "
          text "with."
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
