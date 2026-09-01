## Chain overview (`/{chain}`) — Page-Descriptions §4. The browse hub: head +
## coverage, the latest blocks, the latest transactions, and the chain notes.
##
## §4's degraded row is this page's own: "the pipeline is behind → a staleness
## notice from `summary.json` naming how far behind the tip the chain is.
## Published pages keep working; only new blocks are missing." That notice is
## `components/degraded.notice(cdPipelineBehindTip, …)` — resolved by
## `ssr.renderChain` from the pinned session, and rendered by the same component
## every other §14 row goes through.
##
## `ChainOverviewDegradations` is the sensitivity set that decides what this
## surface may say, and it deliberately excludes the three debuggability rows: a
## chain overview is not "degraded" because one transaction's recorder is
## missing, and saying it is trains people to ignore the notice that matters.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables
import ../components/degraded

proc chainPage*(chain: string, info: ChainInfo,
                blocks: seq[BlockRow], txs: seq[TxRow],
                degradation: ChainDegradation,
                note: DegradationNotice,
                tour: seq[TourRow] = @[]): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          a(href = chainsUrl()): text "chains"
          span(class = "sep"): text "/"
          span: text chain
        tdiv(class = "eyebrow"): text "Chain overview"
        h1(class = "h1"): text chain
        tdiv(class = "stats"):
          tdiv(class = "stat"):
            tdiv(class = "k"): text "Head"
            tdiv(class = "v"): text $info.headHeight
          tdiv(class = "stat"):
            tdiv(class = "k"): text "Finalized"
            tdiv(class = "v"): text $info.finalizedHeight
          tdiv(class = "stat"):
            tdiv(class = "k"): text "Blocks"
            tdiv(class = "v"): text $info.blockCount
          tdiv(class = "stat"):
            tdiv(class = "k"): text "Transactions"
            tdiv(class = "v"): text $info.txCount
          tdiv(class = "stat"):
            tdiv(class = "k"): text "Coverage"
            tdiv(class = "v mono"): text info.coverageMode

        raw degraded.notice(degradation, note)

        # ── The capability tour ────────────────────────────────────────
        #
        # ABOVE the block and transaction lists, and that ordering is the
        # argument. A visitor who arrives on this chain cold is not here to read
        # a ledger of synthetic hashes — there is nothing to look up, and the
        # band above this line says so. They are here to find out what the
        # debugger can show them, and the answer is a list of programs written
        # to be read. Putting it under two tables would file the reason for the
        # page below the furniture.
        #
        # It renders only where the generation PUBLISHED one. A captured chain
        # has no tour and never will: a tour is a claim about programs someone
        # wrote to demonstrate something, and a chain of real transactions has
        # none. So this block is absent from `/aztec` and `/aztec-testnet`
        # entirely, rather than present and empty.
        if tour.len > 0:
          h2(class = "sec-title next"): text "What this debugger can show"
          p(class = "muted measure"):
            text "Each entry is one small Noir program, recorded by "
            span(class = "mono"): text "nargo trace"
            text " into its own container. Open one to step through it — the "
            text "source, the function names and the values are the program's "
            text "own. The transaction it is published under is synthetic, like "
            text "every other transaction on this chain."
          # THE PROGRAM'S ID IS THE LABEL AND ITS TITLE IS THE ACTION, in that
          # order and not the other way round.
          #
          # `.dl dt` is the label column — uppercase, muted, on a sunken
          # surface. Putting the title there rendered the tour's eight primary
          # actions as eight field names: "TYPES AND VALUES" read as a table
          # header a visitor scans past, and the one control on the page they
          # were meant to press was the one thing styled not to be pressed.
          #
          # So the label is the program's stable id — which is genuinely a key,
          # is what a test selects a fixture by, and is short enough for the
          # column — and the linked title leads the value, where `.dl dd a`
          # gives it the link treatment every other action on the site has.
          dl(class = "dl group"):
            for t in tour:
              dt(id = "tour-" & t.id): text t.id
              dd(class = "measure"):
                a(href = debugUrl(chain, t.tx)): text t.title
                tdiv: text t.summary
                tdiv(class = "muted stack"):
                  for c in t.capabilities:
                    span(class = "badge muted"): text c
                  span(class = "mono"):
                    text " " & $t.steps & " steps · " & $t.calls &
                         (if t.calls == 1: " call" else: " calls") & " · "
                  a(href = txUrl(chain, t.tx)): text "transaction\u00A0→"

        h2(class = "sec-title next"): text "Latest blocks"
        raw blocksTable(chain, info, blocks,
          "This generation indexes no blocks yet. The chain pointer resolves " &
          "and its sealed generation carries an empty block index, which is " &
          "what a chain looks like between publication and its first block.")
        p(class = "muted stack"):
          a(href = blocksUrl(chain)): text "All blocks →"

        h2(class = "sec-title next"): text "Latest transactions"
        # TWO EMPTY STATES, BECAUSE THERE ARE TWO SITUATIONS AND THEY OWE THE
        # READER DIFFERENT SENTENCES.
        #
        # The second one is the sentence that used to be unconditional: this
        # table is the newest slice, it is empty, and the visitor is pointed at
        # the full list where older blocks may have some. That is true of a
        # chain whose published record extends below the slice.
        #
        # It is FALSE of a chain that publishes no transactions at all, and the
        # curated real chains are exactly that: `/aztec` publishes 24 blocks and
        # zero transactions, and "older blocks may" sent a reader to an empty
        # list to find out otherwise. The count is a published fact — it is the
        # `Transactions` stat three lines above this — so the page reads it
        # rather than inferring from the emptiness of one slice, which cannot
        # tell the two apart.
        raw txTable(chain, txs,
          if info.txCount == 0:
            "No transaction settled in the blocks this chain publishes. The " &
            "chain's own notes above state what was watched to arrive at them."
          else:
            "The newest blocks of this chain carried no transactions. Older " &
            "blocks may; the transactions list walks backwards from here.")
        p(class = "muted stack"):
          a(href = txsUrl(chain)): text "All transactions →"

        # ── Chain notes (§4's last row) ─────────────────────────────────
        h2(class = "sec-title next"): text "Chain notes"
        dl(class = "dl group"):
          # THE PRODUCER'S OWN SENTENCES, ON THE CHAIN'S OWN PAGE.
          #
          # `provenanceMetaRows` puts these on a TRANSACTION's metadata surface,
          # and until now that was the only page in the explorer register that
          # carried them: the chain overview, the block list and the block pages
          # get `provenanceChip`, which is the label and nothing else.
          #
          # That was survivable while every captured chain had transactions on
          # it. A curated chain need not — `/aztec` publishes 24 blocks and zero
          # transactions — and on such a chain there is no transaction page to
          # reach, so the detail was reachable from nowhere at all. A visitor met
          # two dozen empty blocks with no statement of what was watched to
          # arrive at them, which is the shape of page that reads as broken while
          # being entirely correct.
          #
          # NO `data-provenance` HERE. The chip above already carries the marker
          # and `test_chain_provenance`'s "exactly one provenance marker" counts
          # them; this is the producer's prose, quoted, in the notes list where
          # the recorder pin and the coverage mode already sit.
          if info.provenanceDetail.len > 0:
            dt: text "Data"
            dd(class = "measure"):
              if info.provenanceLabel.len > 0:
                text info.provenanceLabel & " — "
              text info.provenanceDetail
          dt: text "Recorder"
          dd:
            if info.hasRecorder:
              span(class = "mono"):
                text info.recorderId & " " & info.recorderVersion
              span(class = "muted"): text " build " & truncHash(info.recorderBuild)
            else:
              span(class = "badge muted"): text "None pinned"
              span(class = "muted"):
                text " No trace address can be derived for this chain."
          dt: text "Trace schema"
          dd(class = "mono"):
            text (if info.traceSchema.len > 0: info.traceSchema else: "—")
          dt: text "Coverage"
          dd(class = "measure"):
            text "Coverage mode "
            span(class = "mono"): text info.coverageMode
            text " — what the Debug affordance does on a transaction with no "
            text "published trace yet."
          dt: text "Generation"
          dd:
            span(class = "identifier"): text info.generation
            span(class = "muted"):
              text " — every read on this page is pinned to it, so nothing here "
              text "mixes two views of the chain."
