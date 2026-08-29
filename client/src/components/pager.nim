## The cursor pager shared by the block list, the transactions list and the
## address history.
##
## Static-Site-Architecture.md §2.2 rules out ordinal pagination outright, in
## BOTH directions, and the reason is not tidiness: "Ordinal pages number
## history relative to *the history we have found so far*. Tip-first ingestion
## publishes an address's recent activity while historical backfill is still
## running; when backfill later discovers older transactions for that address,
## oldest-first numbering means page 0 is no longer the oldest page — **every
## existing page shifts, and every one of them was cached as immutable.**"
##
## So there is no `?page=`, no `?offset=` and no page number anywhere in this
## component. A page's identity in the URL is the same thing the object's
## identity is: a block number, or a block range. Which is also why the control
## says **Older** and **Newest** rather than "Next" and "1 2 3 …" — an ordinal
## label on a cursor is an invitation to build the thing §2.2 forbids.
##
## The control is a pair of links and never a control that cannot succeed:
## where there is no older page, the affordance is absent rather than disabled.

import isonim/ssr/escape
import isonim/dsl/ui

type
  Pager* = object
    ## `olderHref` empty ⇒ this is the last page and no Older control renders.
    ## `newestHref` empty ⇒ this IS the first page.
    olderHref*: string
    newestHref*: string
    summary*: string
      ## What this page covers, in the chain's own coordinates — "blocks 102 to
      ## 100", "block 101". Stated because a cursor URL, unlike `?page=3`, does
      ## not tell a reader where they are, and the honest answer to that is a
      ## sentence rather than a number.

proc pager*(p: Pager): string =
  ui:
    tdiv(class = "pager"):
      if p.summary.len > 0:
        span(class = "pagerwhere"): text p.summary
      tdiv(class = "pagerbtns"):
        if p.newestHref.len > 0:
          a(class = "btn ghost sm", href = p.newestHref): text "Newest"
        if p.olderHref.len > 0:
          a(class = "btn ghost sm", href = p.olderHref): text "Older →"
