## Block list (`/{chain}/blocks`) — Page-Descriptions §5.1. The full block table
## for the chain, newest first. Pagination (cursor = block number) is deferred;
## the demo generation is small enough to render in one page.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables

proc blockListPage*(chain: string, info: ChainInfo, blocks: seq[BlockRow]): string =
  ui:
    section(class = "sec"):
      tdiv(class = "inner"):
        tdiv(class = "crumbs"):
          a(href = "/"): text "Home"
          span(class = "sep"): text "/"
          a(href = chainUrl(chain)): text chain
          span(class = "sep"): text "/"
          span: text "blocks"
        tdiv(class = "eyebrow"): text "Blocks"
        h1(class = "h1"): text chain & " blocks"
        p(class = "lead"):
          text "The chain's blocks, newest first, from generation "
          span(class = "mono"): text info.generation
          text "."
        tdiv(class = "group"):
          raw blocksTable(chain, blocks)
        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Deferred: "
            text "cursor pagination (backwards-walking by block number) and "
            text "per-block gas/resource bars land with the explorer-breadth slice."
