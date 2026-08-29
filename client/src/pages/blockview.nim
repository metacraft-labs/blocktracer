## Block detail (`/{chain}/block/{hash}`) — Page-Descriptions §5.2.
##
## Four zones: the header, the family extras, the shared transactions table
## filtered to this block, and previous/next navigation "disabled at genesis and
## head".
##
## ## What "disabled at genesis and head" means without script
##
## Not a greyed control. §13's rule and `pages/tx.nim`'s reasoning apply here
## too: a disabled link is a control that occupies the position of an action and
## invites the click it refuses. At the head there is no next block, and the
## honest rendering of that is the edge stated as a fact — "this is the head" —
## with no control beside it. The same at the oldest block this generation
## indexes, which is a different statement from "genesis": the generation's
## floor is what this tree holds, and claiming genesis would assert something
## about the chain that the tree does not know.
##
## ## Family extras
##
## §5.2's examples (EVM base fee and blob gas, Move checkpoint and epoch, Solana
## slot and leader) come from the adapter, and the block object in this contract
## carries chain, hash, height, parentHash and the transaction list — no
## `native` payload, unlike a transaction. So there are no family extras to
## render for any family yet, and the zone says which field would carry them
## rather than being silently absent.

import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../components/tables
import ../components/degraded

proc blockPage*(chain: string, info: ChainInfo, detail: BlockDetail,
                txs: seq[TxRow], nextHash: string, parentIndexed: bool,
                degradation: ChainDegradation,
                note: DegradationNotice): string =
  let finality = blockFinality(info, detail.height)
  let isHead = detail.height >= info.headHeight
  # `parentIndexed`, not `parentHash.len > 0`: the oldest block this generation
  # holds HAS a parent hash and does not have a parent PAGE, and a Previous
  # control pointing at a page that was never written is a control that cannot
  # succeed — the same rule that keeps a disabled Debug button off the
  # transaction page.
  let hasParent = detail.parentHash.len > 0 and parentIndexed
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
        tdiv(class = "titlerow"):
          h1(class = "h1 tnum"): text "Block " & $detail.height
          span(class = "badge lg " & finalityClass(finality)):
            text sentenceCase(finality)

        raw degraded.notice(degradation, note)

        # ── Navigation (§5.2 zone 4) ────────────────────────────────────
        tdiv(class = "pager group"):
          span(class = "pagerwhere"):
            if isHead:
              text "This is the head of the chain at generation " &
                   info.generation & "."
            elif not hasParent:
              text "Height " & $detail.height & " — the oldest block this " &
                   "generation indexes."
            else:
              text "Height " & $detail.height & " of " & $info.headHeight & "."
          tdiv(class = "pagerbtns"):
            # §5.2: "Previous / next block, disabled at genesis and head."
            #
            # DISABLED, not absent — which is the opposite of what the Debug
            # affordance does on a transaction with no trace, and the two are
            # not in tension. §7.2's rule is about a PRIMARY ACTION that would
            # refuse the click it invites; this is a navigation pair whose
            # shape has to stay the same from block to block, so that "there is
            # nothing before this one" is a state of the control rather than
            # the control's disappearance. The disabled member is not an
            # anchor at all, so there is no href to a page that was never
            # written, and it names its own reason.
            if hasParent:
              a(class = "btn ghost sm", href = blockUrl(chain, detail.parentHash)):
                text "← Previous"
            else:
              span(class = "btn ghost sm disabled",
                   title = "the oldest block this generation indexes"):
                text "← Previous"
            if nextHash.len > 0:
              a(class = "btn ghost sm", href = blockUrl(chain, nextHash)):
                text "Next →"
            else:
              span(class = "btn ghost sm disabled",
                   title = "the head of the chain at this generation"):
                text "Next →"

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
            if parentIndexed:
              a(href = blockUrl(chain, detail.parentHash), class = "identifier"):
                text detail.parentHash
            else:
              span(class = "identifier"): text detail.parentHash
              span(class = "muted"):
                text " — below this generation's floor, so there is no page "
                text "for it here. The hash is the chain's; the page is this "
                text "tree's, and this tree does not hold it."
          dt: text "Finality"
          dd:
            span(class = "badge " & finalityClass(finality)):
              text sentenceCase(finality)
          dt: text "Transactions"
          dd(class = "tnum"): text $detail.transactions.len

        h2(class = "sec-title next"): text "Transactions in this block"
        raw txTable(chain, txs,
          "This block carried no transactions. That is a fact about the " &
          "block, not a gap in the index — the block object lists its " &
          "transactions and this one lists none.")

        tdiv(class = "stub"):
          tdiv(class = "measure"):
            b: text "Family extras have no field in the block object yet. "
            text "§5.2's per-family zone — base fee and blob gas on an EVM "
            text "chain, checkpoint and epoch on Move, slot and leader on "
            text "Solana — comes from the adapter, and the published block "
            text "object carries the chain, the hash, the height, the parent "
            text "and the transaction list. A transaction already carries its "
            text "chain-native payload verbatim; a block does not, and that "
            text "is the field this zone reads when it lands."
