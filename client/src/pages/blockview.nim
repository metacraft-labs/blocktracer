## Block detail (`/{chain}/block/{hash}`) — Page-Descriptions §5.2. Header zone
## (hash, height, parent link) plus the shared transactions table filtered to
## this block.

import isonim/ssr/escape
import isonim/dsl/ui
import blocktracer/contract/model
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
        tdiv(class = "eyebrow"): text "Block " & $detail.height
        h1(class = "h2"): text "Block " & $detail.height
        dl(class = "dl"):
          dt: text "Chain"
          dd: text detail.chain
          dt: text "Hash"
          dd:
            code: text detail.hash
          dt: text "Height"
          dd: text $detail.height
          dt: text "Parent"
          dd:
            a(href = blockUrl(chain, detail.parentHash)):
              code: text detail.parentHash
          dt: text "Transactions"
          dd: text $detail.transactions.len

        tdiv(class = "eyebrow", style = "margin-top:var(--ct-space-2xl)"):
          text "Transactions in this block"
        raw txTable(chain, txs)
