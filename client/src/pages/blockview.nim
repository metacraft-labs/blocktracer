## Block detail (`/{chain}/block/{hash}`) — Page-Descriptions §5.2. Header zone
## (hash, height, parent link) plus the shared transactions table filtered to
## this block.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables

proc blockPage*(chain: string, detail: BlockDetail, txs: seq[TxRow]): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          a(href = chainUrl(chain)): text chain
          span(class = "sep"): text "/"
          a(href = blocksUrl(chain)): text "blocks"
          span(class = "sep"): text "/"
          span: text truncHash(detail.hash)
        tdiv(class = "eyebrow"): text "Block"
        h1(class = "h1 tnum"): text "Block " & $detail.height
        dl(class = "dl group"):
          dt: text "Chain"
          dd: text detail.chain
          dt: text "Hash"
          dd:
            span(class = "identifier"): text detail.hash
          dt: text "Height"
          dd(class = "tnum"): text $detail.height
          dt: text "Parent"
          dd:
            a(href = blockUrl(chain, detail.parentHash), class = "identifier"):
              text detail.parentHash
          dt: text "Transactions"
          dd(class = "tnum"): text $detail.transactions.len

        h2(class = "sec-title next"): text "Transactions in this block"
        raw txTable(chain, txs)
