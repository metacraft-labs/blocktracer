## Block detail (`/{chain}/block/{hash}`) — Page-Descriptions §5.2.
##
## Four zones: the header, the family extras, the shared transactions table
## filtered to this block, and previous/next navigation "disabled at genesis and
## head". On a chain whose protocol runs transactions of its own under
## identifiers every block shares, the block's system transactions are listed
## after its transactions, unlinked (Data-Contract.md §5.2).
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
## carries chain, hash, height, parentHash, the transaction list and, where the
## chain has them, its system transactions — no `native` payload, unlike a
## transaction. So there are no family extras to render for any family yet, and
## the zone says which field would carry them rather than being silently absent.

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

        # ── The protocol's own transactions (Data-Contract.md §5.2) ─────
        #
        # Some chains end every block with transactions the PROTOCOL runs,
        # under identifiers that are the same in every block (Flow's system
        # transactions). They are not rows: there is no transaction page for
        # one, because a page keyed by an identifier every block shares would
        # belong to every block at once. The block object carries them as
        # `systemTransactions`, and this lists them beside the block's
        # transactions so the fact is on the page rather than dropped.
        #
        # UNLINKED, because there is nothing to link to — an anchor here would
        # be a control that cannot succeed, the rule the Previous button above
        # follows. NOT COUNTED: the "Transactions" figure above is the row
        # count, and §5.2 puts these in no count. And ABSENT when the block
        # settled none, so a chain without them renders exactly what it did.
        if detail.systemTransactions.len > 0:
          h2(class = "sec-title next"): text "System transactions in this block"
          p(class = "muted"):
            text "Transactions the protocol itself ran in this block, in the "
            text "order the chain executed them. Their identifiers are the "
            text "same in every block, so they have no page of their own and "
            text "are not counted among the block's transactions."
          ul(class = "linklist"):
            for s in detail.systemTransactions:
              li:
                span(class = "identifier"): text s

        # THE STUB NOTE IS GONE. It read: "Family extras have no field in the
        # block object yet. §5.2's per-family zone — base fee and blob gas on an
        # EVM chain, checkpoint and epoch on Move, slot and leader on Solana —
        # comes from the adapter … that is the field this zone reads when it
        # lands."
        #
        # A published spec reference and an account of which producer owes which
        # field. It named three chain families this deployment does not carry a
        # single block from, to explain the absence of a zone that has never
        # been rendered — so a reader of an Aztec block was being told about
        # blob gas and Solana leaders in order to be reassured about a gap they
        # could not see. Every clause is addressed to whoever will implement the
        # adapter. §5.2's zone appears when the block object carries the fields;
        # that plan lives with the plans.
