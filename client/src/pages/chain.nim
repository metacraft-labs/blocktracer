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
                note: DegradationNotice): string =
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

        h2(class = "sec-title next"): text "Latest blocks"
        raw blocksTable(chain, info, blocks,
          "This generation indexes no blocks yet. The chain pointer resolves " &
          "and its sealed generation carries an empty block index, which is " &
          "what a chain looks like between publication and its first block.")
        p(class = "muted stack"):
          a(href = blocksUrl(chain)): text "All blocks →"

        h2(class = "sec-title next"): text "Latest transactions"
        raw txTable(chain, txs,
          "The newest blocks of this chain carried no transactions. Older " &
          "blocks may; the transactions list walks backwards from here.")
        p(class = "muted stack"):
          a(href = txsUrl(chain)): text "All transactions →"

        # ── Chain notes (§4's last row) ─────────────────────────────────
        h2(class = "sec-title next"): text "Chain notes"
        dl(class = "dl group"):
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
              text " every read on this page is pinned to it, so nothing here "
              text "mixes two views of the chain."
