# `snapshot.json` is held at `blocktracer/chain-snapshot@1`, deliberately

**Do not migrate this file, and do not edit it at all.**

`tools/chain/migrate-refusal-reasons.mjs` names this path in `HELD_OUT_AT_V1` and
refuses to promote it without `--include-held-out`. The other two held-out
subjects record the same intent in a `_comment` **inside** their JSON. This one
cannot, and the reason it cannot is the reason it exists.

## Why the note is beside the file and not in it

This snapshot is **the live follower's own output, byte for byte** — the tree
`blocktracer-follow-chain` actually wrote against Aztec mainnet on 2026-09-11,
copied in unaltered. That is its whole value. It reproduces a reader defect that
every hand-written fixture in this repository was blind to: its `provenance`
carries no `l1ChainId`, `reader.nim` read that member by unguarded bracket
access, and the real producer therefore emitted a tree the real reader raised
`KeyError` on. Eight hand-written provenance literals in
`client/tests/test_chain_provenance.nim` and every committed capture carry the
member, so nothing in the suite could see it.

A fixture that has been edited to explain itself is no longer the producer's
output, and the next person to ask "is this really what the tool writes?" would
have to take the answer on trust. So the file stays untouched and the note
stands beside it.

## Why `@1` rather than `@2`

`@1` is not merely a legacy token — it is a **shape the reader still has to be
tested against**. `Data-Contract.md` §3.1 rule 2 obliges a reader that accepts a
token to consume every member that token defines, and the only way to check that
obligation is to hold an artifact in that shape and read it. This repository has
exactly three `@1` subjects:

| path | the `@1` shape it carries |
|---|---|
| `client/fixtures/noir-frames/snapshot.json` | no untraced rows at all |
| `fixtures/chain-artifacts/aztec-testnet/snapshot.json` | untraced rows with **no** `refusalReason` |
| this one | the live producer's own output, with `counts` predating the reconciliation rule |

A glob run of the migration tool would promote all three in one command — it did,
in a review rehearsal — leaving the reader's `@1` path with no population and the
`@1` half of §5.2a's both-directions token audit vacuously true.

## Its `counts` are incomplete, and that is not a defect

`counts.accountedFor`, `counts.privateOnly` and `counts.refusals` are absent.
`Data-Contract.md` §5.2 scopes the `counts` reconciliation to `@2`; a frozen `@1`
subject is not rewritten to satisfy a rule written after it, and rewriting this
one would destroy the byte-for-byte property above for the sake of a rule it is
explicitly outside.

`tools/chain/refusal-selftest.mjs` asserts this hold-out, in both directions: the
three subjects are still `@1`, and this note still exists.
