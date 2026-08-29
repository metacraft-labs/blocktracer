## Block list (`/{chain}/blocks`) — Page-Descriptions §5.1.
##
## "Sorted descending from head, paginated by walking backwards — cursor is a
## block number, so pagination needs no server." That is now literally what this
## page is: `reader.blocksFrom` reads the generation's height map (one object
## per epoch) for the ORDER and then reads only the details of the blocks on
## this page, and the cursor in the URL is the block number the next page starts
## at. Page N costs what page 1 costs.
##
## ## Three of §5.1's seven columns have no published source
##
## §5.1 asks for height · hash · age · tx count · gas or resource usage with a
## bar · producer/proposer · finality badge. Four of those are in the tree and
## are rendered. Three are not, and are named rather than mocked:
##
##   * **Age** — `BlockDetail` carries no timestamp. Not an oversight in this
##     view: the contract type has no field for one, so there is nothing to
##     read. Nothing here fabricates one from the height.
##   * **Resource usage** — a per-block gas/mana total is an aggregate the
##     producer does not publish; the per-TRANSACTION cost vector is published
##     and is in the transactions table.
##   * **Producer / proposer** — no consensus-role field exists in the block
##     object.
##
## The finality badge IS derivable, from the finalized height the one mutable
## pointer already carries, so it renders — see `viewutil.blockFinality`.
##
## ## Row expansion is deferred, and the deferral is not a stub
##
## §5.1's "row expansion reveals the block's transaction hashes with per-row
## Debug actions" needs script for the expansion itself. The block's own page
## already shows exactly that content with the same shared table, and the height
## cell links to it — so the capability exists, one click away, rather than
## being announced as missing.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables
import ../components/pager
import ../components/degraded

proc blockListPage*(chain: string, info: ChainInfo, page: BlockPage,
                    degradation: ChainDegradation,
                    note: DegradationNotice): string =
  let atHead = page.rows.len > 0 and page.rows[0].height >= info.headHeight
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
          text "Newest first, from generation "
          span(class = "mono"): text info.generation
          text ". Paging walks backwards by block number, so a page's address "
          text "does not shift when the chain grows."

        raw degraded.notice(degradation, note)

        tdiv(class = "group"):
          raw blocksTable(chain, info, page.rows,
            "No blocks in this range. The generation indexes " &
            $info.blockCount & " block(s); the newest page is where the " &
            "walk starts.")
        raw pager(Pager(
          summary: (if page.rows.len == 0: ""
                    else: "Blocks " & $page.rows[0].height & " down to " &
                          $page.rows[^1].height),
          newestHref: (if atHead: "" else: blocksUrl(chain)),
          olderHref: (if page.hasMore: blocksFromUrl(chain, page.nextFrom)
                      else: "")))

        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Three of this table's columns have no published source. "
            text "A block's age needs a timestamp, its resource bar needs a "
            text "per-block usage aggregate, and its producer needs a "
            text "consensus-role field — none of the three is in the block "
            text "object this tree publishes. Each is a pipeline field rather "
            text "than a view, and this table reads them the moment they are "
            text "published. Nothing here is derived from the height to stand "
            text "in for one."
