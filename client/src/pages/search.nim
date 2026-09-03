## Search (`/search?q=`) — Page-Descriptions §11, Search-And-Routing.md.
##
## ## Nothing the SERVER renders can resolve a query, and that is still true
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
## CORRECTION, and it is the whole of the defect this page was in. That
## paragraph was true and complete, and it was read as though it settled the
## matter — so for the life of this route NOTHING resolved a query, the form on
## the home page submitted here, the page returned 200, and a visitor who pasted
## a transaction hash got a mechanism table. "Markup cannot do it" is not "it
## cannot be done": `client/searchboot/` is a 41 KB `nim js` bundle that reads
## `?q=` and resolves it, `ResultSlotId` below is where it writes, and
## `ssr.renderSearch` defers it. What this page renders is what a SERVER
## genuinely knows; the browser supplies the rest.
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
import ../viewmodel/search_shapes   # `ResultSlotId` — shared with the bundle

type
  NamedEntity* = object
    ## One row of the browsable name directory: a published label joined to the
    ## route of the thing it names.
    chain*, id*, name*, symbol*, kind*, provenance*, href*: string

proc searchPage*(chains: seq[string], named: seq[NamedEntity],
                 resolvesInBrowser: bool): string =
  ## `resolvesInBrowser` is whether this build published the search bundle.
  ##
  ## It is a parameter rather than a `SearchBundle.len > 0` read inside the
  ## page, because the page's job is to be TRUE about the deployment it is part
  ## of and the caller is what knows. Before the bundle existed this text said
  ## "this deployment ships no script, so none of them ran" — accurate then,
  ## and it would have quietly become the page's own lie the moment one
  ## shipped.
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

        # Written by `client/searchboot/`, which is the only thing that can see
        # `?q=`. Empty in the markup on purpose: a results container pre-filled
        # with "no results" would be a claim the server is not in a position to
        # make, and would be wrong for every query that does resolve. What
        # stands in for it until the bundle answers is the directory below,
        # which is data rather than a verdict.
        tdiv(id = ResultSlotId, class = "searchresult")

        tdiv(class = "stub group"):
          tdiv(class = "measure"):
            # COPY OWNED BY THE PROSE SWEEP; the branch is not. The sentence
            # below is that sweep's, kept verbatim, and its reasoning is kept
            # with it. What this change adds is that the sentence is now
            # CONDITIONAL, because it stopped being true of every build: a
            # deployment that ships client/searchboot/ does run search, and
            # printing "Search is not running on this site" on a page whose own
            # script is at that moment resolving the query would be the page
            # contradicting itself in front of the reader.
            #
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
            # "on this site" and not "on this deployment": `deployment` is the
            # word this tree uses for itself, and the About and Settings pages
            # dropped it in the same change. One vocabulary across the site.
            if not resolvesInBrowser:
              b: text "Search is not running on this site, so nothing was "
              b: text "looked up. "
              text "This is not a result — it does not mean your identifier "
              text "is absent. "
            # The second half is unconditional, and is the sweep's wording
            # unchanged. It is the half that is true either way: the stable
            # address is what the table below is FOR, and on a build where
            # search works it is still the answer for anyone who would rather
            # navigate than type.
            text "Every block, transaction and address here has a "
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
