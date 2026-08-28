## Chain overview (`/{chain}`) — Page-Descriptions §4. The browse hub: head +
## coverage, the latest blocks, and the latest transactions (the shared tables).

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables

proc chainPage*(chain: string, info: ChainInfo,
                blocks: seq[BlockRow], txs: seq[TxRow]): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
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

        h2(class = "sec-title next"): text "Latest blocks"
        raw blocksTable(chain, blocks)
        p(class = "muted stack"):
          a(href = blocksUrl(chain)): text "All blocks →"

        h2(class = "sec-title next"): text "Latest transactions"
        raw txTable(chain, txs)
