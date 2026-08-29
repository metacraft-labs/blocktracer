## Address / account (`/{chain}/address/{address}`) — Page-Descriptions §9.
##
## "This page exists in V1 to **get you to a transaction worth tracing**, and is
## scoped accordingly." So its centre of gravity is the shared transactions
## table with Debug on every row, and everything above the table is there to
## tell you what you are looking at before you pick one.
##
## ## What §9 says is deliberately absent, and what is merely not published yet
##
## Two different things, and collapsing them would misrepresent the product:
##
##   * **Deliberately absent in V1** (FR-D8): balances, token holdings,
##     portfolio value, price, profit/loss, holder analytics. §9 states the
##     reason — "V1 is a transaction-tracing product, and this page earns its
##     place by listing executions, not assets" — and this page therefore does
##     not carry a placeholder for them either. A greyed "Balance: —" would be
##     the feature announcing itself as missing rather than as out of scope.
##   * **Not published yet**: code size, proxy relationships, and the address's
##     own logs. `Static-Site-Architecture.md` §2 has no account object and no
##     log index; `viewmodel/address_vm.nim` records the same two gaps and, for
##     the same reason, carries no signal for them. The page says so where the
##     section would be, because §9 promises "complete log coverage" and
##     silence there would read as "this address emitted none".
##
## ## §9's one claim this page can already make in full
##
## "There is no 'Requires' column, and its absence is the point. The pipeline
## builds the address index, so **every listed chain has complete history and
## complete log coverage** — no capability to negotiate, no degraded variant of
## this page, and no record cap."
##
## The no-record-cap half is structural here and not a promise: history is paged
## by block-range segment (§2.2), the page reads ONE segment, and the pager
## walks the generation's own list. The cost of the thousandth page is the cost
## of the first.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables
import ../components/pager
import ../components/degraded

proc identityBadges(label: LabelRow, code: seq[SourceBundleView]): string =
  ui:
    span(class = "badgerow"):
      # Contract or EOA is decided by whether the tree binds CODE to this
      # address (§2.3's `codeEdges`), never by the shape of the address —
      # which on several families is indistinguishable.
      if code.len > 0:
        span(class = "badge lg info"): text "Contract"
      else:
        span(class = "badge lg muted"): text "Account"
      if label.name.len > 0:
        span(class = "badge lg ok"): text label.name
        # Provenance travels with the name. A self-declared label and a curated
        # one are different claims, and a name shown without its provenance is
        # the stronger of the two by default (Search-And-Routing §6.2).
        span(class = "badge " & (if label.provenance == "curated": "ok"
                                 else: "muted")):
          text label.provenance

proc codeSummary(chain: string, address: string,
                 code: seq[SourceBundleView]): string =
  ui:
    tdiv(id = "code-summary"):
      h2(class = "sec-title next"): text "Code"
      if code.len == 0:
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            text "No code is bound to this address in the published tree, so "
            text "it is an account rather than a contract. A code binding is "
            text "published as a code edge on the transactions that ran it."
      else:
        dl(class = "dl"):
          for b in code:
            dt: text "Code hash"
            dd:
              a(href = addressCodeUrl(chain, address), class = "identifier"):
                text b.codeHash
            dt: text "Verification"
            dd:
              if b.resolved:
                span(class = "badge ok"): text b.match & " match"
                span(class = "muted"): text " via " & b.provider
              else:
                span(class = "badge muted"): text "No verified source"
            if b.resolved:
              dt: text "Compiler"
              dd(class = "mono"):
                text b.compilerName & " " & b.compilerVersion
              dt: text "Language"
              dd(class = "mono"): text b.language
            else:
              dt: text "Why"
              dd(class = "measure"): text b.reason
        p(class = "muted stack"):
          a(href = addressCodeUrl(chain, address)):
            text "Browse the verified source →"

proc addressPage*(chain: string, info: ChainInfo, v: AddressView,
                  rows: seq[TxRow], label: LabelRow,
                  code: seq[SourceBundleView],
                  degradation: ChainDegradation,
                  note: DegradationNotice): string =
  let hasOlder = v.index >= 0 and v.index + 1 < v.segmentPaths.len
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          a(href = chainUrl(chain)): text chain
          span(class = "sep"): text "/"
          span: text "address"
          span(class = "sep"): text "/"
          span: text truncHash(v.address)

        tdiv(class = "eyebrow"): text "Address"
        # The heading and its badges sit in a `titlerow`, as on the transaction
        # page, and the full value is the BLOCK beneath it. `.identifier` is
        # `display:inline-block`, so a bare `<h1 class="identifier">` followed
        # by a `<p class="identifier">` puts the truncation and the full value
        # on one line, reading as one 54-character string.
        tdiv(class = "titlerow"):
          h1(class = "h1 identifier"): text truncHash(v.address)
          raw identityBadges(label, code)
        # Rendered IN FULL, so §13's pre-hydration affordance holds: one click
        # selects the whole value, and what a selection yields is the value.
        # The truncated heading above is deliberately not offered as copyable.
        p(class = "identifier lead tight"): text v.address

        raw degraded.notice(degradation, note)

        if v.indexed:
          h2(class = "sec-title next"): text "Transactions"
          p(class = "lead"):
            text "Complete history, one block-range segment at a time. There "
            text "is no record cap and no capability to negotiate: the "
            text "pipeline builds this index, so every listed chain has all "
            text "of it."
          raw txTable(chain, rows,
            "This segment of the address's history resolved but listed no " &
            "transactions this generation still holds. The segment list " &
            "below continues backwards.")
          raw pager(Pager(
            summary: (if v.index >= 0 and v.segment.loaded:
                        "Blocks " & $v.segment.toBlock & " to " &
                        $v.segment.fromBlock & " · segment " &
                        $(v.index + 1) & " of " & $v.segmentPaths.len
                      else: ""),
            newestHref: (if v.index > 0: addressUrl(chain, v.address) else: ""),
            olderHref: (if hasOlder:
                          addressSegmentUrl(chain, v.address,
                            segmentIdOf(v.segmentPaths[v.index + 1]))
                        else: "")))

        raw codeSummary(chain, v.address, code)

        tdiv(id = "events"):
          h2(class = "sec-title next"): text "Events"
          tdiv(class = "stub"):
            tdiv(class = "measure"):
              text "Logs emitted by this address come from a log index the "
              text "published tree does not carry yet. The transactions above "
              text "carry their own raw logs, and this section fills in when "
              text "the pipeline publishes the per-address index — it is not "
              text "a statement that this address emitted none."

        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Balances and token holdings are out of scope in V1, "
            b: text "not missing. "
            text "They are the account-explorer data model, with their own "
            text "aggregates, their own reorg-recomputation surface and their "
            text "own correctness problem. This page earns its place by "
            text "listing executions."
