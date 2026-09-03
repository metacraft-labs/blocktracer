## Search (`/search?q=`) — Page-Descriptions §11, Search-And-Routing.md.
##
## ## The honest shape of this page on a client that ships no script
##
## §11's first bullet is "Unambiguous input navigates immediately, without an
## intermediate results page", and Search-And-Routing §1 is explicit that "most
## explorer search is not search — it is identifier resolution": the input says
## what it is, and the client computes where the answer lives. Every one of the
## four mechanisms — shape detection on every keystroke, local inference from
## the head pointers, the direct path, the index shards — runs **in the
## browser**. A static file server cannot read `?q=`, so this route cannot
## resolve anything, and there is no arrangement of markup that makes it able
## to.
##
## What follows from that is a decision, not a workaround. The page does not
## render a results list it did not compute, and it does not render an empty
## one either. It renders the two things it genuinely knows:
##
##   1. **Where resolution happens and why**, in the form Search-And-Routing §8
##      requires of a miss — "not-found messaging names what was tried", so that
##      a miss reads as a scoping answer rather than a dead end. Here the
##      scoping answer is that nothing was tried yet, and by what.
##   2. **The published index, browsable.** The chains the registry lists, and
##      the curated name corpus `/d/{chain}/labels/**` publishes, each linked to
##      the entity it names. That is data, from files, and it is the part of
##      §11's answer that does not need a query at all.
##
## The alternative — a results page rendered from a query the server never saw —
## is the one thing this product cannot afford: a confident answer that is
## sometimes wrong.
##
## §5 of SEO-And-Crawl-Budget puts this route in class N2, `noindex,nofollow`,
## and `ssr.renderSearch` sets it there.

import isonim/ssr/escape
import isonim/dsl/ui
import ../viewutil

type
  NamedEntity* = object
    ## One row of the browsable name directory: a published label joined to the
    ## route of the thing it names.
    chain*, id*, name*, symbol*, kind*, provenance*, href*: string

proc searchPage*(chains: seq[string], named: seq[NamedEntity]): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          span: text "search"
        tdiv(class = "eyebrow"): text "Search"
        h1(class = "h1"): text "Resolve an identifier"
        form(class = "search", action = searchUrl(), `method` = "get"):
          input(name = "q", placeholder = "Paste a block, tx hash, or address")
          button(class = "btn primary", `type` = "submit"):
            text "Search"

        tdiv(class = "stub group"):
          tdiv(class = "measure"):
            # WHAT THIS SENTENCE HAS TO DO, which the old one did not. A reader
            # arrives here having typed something and got no result, and needs
            # two things: to know their query was not looked up and REJECTED —
            # so they do not conclude their hash is absent — and a way to reach
            # the page anyway.
            #
            # The old copy delivered the first as a tour of the implementation:
            # "the input's shape selects one of four mechanisms, and three of
            # them compute a path rather than querying anything. This deployment
            # ships no script, so none of them ran." How many mechanisms there
            # are, which of them compute rather than fetch, and whether the
            # build ships script are facts about this program. The reader's
            # version of all of it is one clause: search is not running here.
            #
            # "and here is exactly what was tried" is the register the report
            # named — it answers an accusation of hand-waving that nobody made,
            # and it was not even true, since the point of the sentence is that
            # nothing was tried.
            b: text "Search is not running on this deployment, so nothing was "
            b: text "looked up. "
            text "This is not a result — it does not mean your identifier is "
            text "absent. Every block, transaction and address here has a "
            text "stable address you can go to directly, and the table below "
            text "gives the form for each kind."

        h2(class = "sec-title next"): text "How an identifier resolves"
        tdiv(class = "tablewrap"):
          table(class = "tbl"):
            thead:
              tr:
                th: text "Mechanism"
                th(class = "num"): text "Requests"
                th: text "Handles"
                th: text "Where it lands"
            tbody:
              tr:
                td: text "Local inference"
                td(class = "num"): text "0"
                td: text "Block numbers, slots, checkpoints"
                td(class = "mono"): text "/{chain}/block/{hash}"
              tr:
                td: text "Direct path"
                td(class = "num"): text "1"
                td: text "Any identifier on a chain the URL already pins"
                td(class = "mono"): text "/{chain}/tx/{hash}"
              tr:
                td: text "Hash index"
                td(class = "num"): text "2"
                td: text "A hash when the chain is unknown"
                td(class = "mono"): text "/idx/hash/{version}/{prefix}.bin"
              tr:
                td: text "Name shards"
                td(class = "num"): text "1–2"
                td: text "Contract names, symbols, labels"
                td(class = "mono"): text "/idx/{chain}/names/{shard}.bin"

        h2(class = "sec-title next"): text "Chains that would be checked"
        p(class = "lead"):
          text "A hash whose chain is unknown is resolved against every chain "
          text "the registry publishes, concurrently; exactly one answers."
        tdiv(class = "chainstrip"):
          for c in chains:
            a(class = "chaincard", href = chainUrl(c)):
              tdiv(class = "name"): text c
              tdiv(class = "meta"): text "direct path · hash index"

        h2(class = "sec-title next"): text "Published names"
        if named.len == 0:
          tdiv(class = "stub"):
            tdiv(class = "measure"):
              # "Names arrive as a labels object per chain, outside the
              # generation, so one landing costs no republication" explained the
              # publishing model's cost to a reader who wanted to search by
              # name. The fact they need is that there are no names to search.
              text "No chain here publishes contract names or labels yet, so "
              text "there is nothing to search by name."
        else:
          p(class = "lead"):
            # "name corpus", "this deployment", "what a text query would be
            # matched against" — three pieces of vocabulary for one idea a
            # reader already has: these are the names you could search for, and
            # here they all are.
            text "Every name published here. Browse them directly."
          tdiv(class = "tablewrap"):
            table(class = "tbl"):
              thead:
                tr:
                  th: text "Name"
                  th: text "Symbol"
                  th: text "Kind"
                  th: text "Provenance"
                  th: text "Address"
              tbody:
                for e in named:
                  tr:
                    td:
                      a(class = "addr", href = e.href): text e.name
                    td:
                      if e.symbol.len > 0:
                        span(class = "mono"): text e.symbol
                      else:
                        span(class = "muted"): text "—"
                    td: text e.kind
                    td:
                      span(class = "badge " &
                           (if e.provenance == "curated": "ok" else: "muted")):
                        text e.provenance
                    td(class = "hash"):
                      a(href = e.href): text truncHash(e.id)
