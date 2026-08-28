## viewmodel/contract_equality.nim
##
## `==` for the contract's discriminated unions, so they can live in signals.
##
## ## Why this file has to exist
##
## `Signal[T]` decides whether a write is a change by comparing the old value
## with the new one, and Nim's generated structural `==` refuses to walk a
## `case` object: "parallel 'fields' iterator does not work for 'case'
## objects". The contract is *full* of `case` objects, deliberately —
## Static-Site-Architecture.md §2.3's whole argument is that "every field that
## can differ across chain families is a discriminated union carrying its own
## `kind`, so an unfamiliar variant renders the native payload honestly instead
## of guessing", and M5b's model encodes that in Nim object variants.
##
## So the price of the schema being honest is that a consumer holding one in a
## reactive signal has to say what equality means. That is this file, and it is
## six short procs rather than a design.
##
## ## The alternative that was rejected
##
## A cheap comparator per signal — "two `TransactionView`s are equal if their
## hashes match" — would have been shorter and is wrong in a way that would be
## very hard to find later: re-reading the same transaction after adopting a
## new generation produces the same hash with a different `finality`, and the
## signal would not notify. Reactive staleness caused by a comparator is
## invisible at the call site. Full structural equality has no such failure
## mode, and these objects are small.
##
## ## The rule for adding to this file
##
## One `==` per contract type that is a `case` object, comparing the
## discriminant and then only the active branch. Nothing else belongs here; a
## comparison that means something other than "these are the same value" should
## be a named predicate somewhere it can be read.
##
## ## Why this module re-exports the facade
##
## An operator has to be **in scope where the generic is instantiated**, and
## `Signal[T]`'s comparison is instantiated wherever a VM writes a signal.
## Importing this module beside `blocktracer_client` works but reads as an
## unused import — and an import that looks unused is an import someone deletes,
## after which a `Signal[TransactionView]` in a *different* module silently
## falls back to the structural `==` and fails to compile with an error that
## names `system.nim` rather than anything here.
##
## Re-exporting the facade removes that trap: a module that wants the contract
## types imports this one and gets the comparisons with them, indivisibly. The
## Client SDK boundary is unaffected — this still reaches the package only
## through `blocktracer_client`, which is the one module a consumer may import.

import blocktracer_client
export blocktracer_client

func `==`*(a, b: TxId): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tikHash: a.hash == b.hash
  of tikBlockIndex: a.biBlock == b.biBlock and a.biIndex == b.biIndex
  of tikVersion: a.vVersion == b.vVersion and a.vHash == b.vHash
  of tikAccountLt:
    a.alAccount == b.alAccount and a.alLt == b.alLt and a.alHash == b.alHash

func `==`*(a, b: TxOrder): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tokBlockIndex:
    a.obBlock == b.obBlock and a.obHeight == b.obHeight and
      a.obIndex == b.obIndex
  of tokConsensusTime: a.ctTime == b.ctTime
  of tokGlobalVersion: a.gvVersion == b.gvVersion
  of tokCheckpoint: a.cpSeq == b.cpSeq
  of tokLogicalTime: a.ltAccount == b.ltAccount and a.ltLt == b.ltLt

func `==`*(a, b: BundleResult): bool =
  if a.outcome != b.outcome: return false
  if a.reference != b.reference: return false
  case a.outcome
  of boLoaded: a.bundle == b.bundle
  of boNotPublished, boMalformed, boMismatched: a.reason == b.reason

func `==`*(a, b: BlockResult): bool =
  if a.outcome != b.outcome: return false
  case a.outcome
  of roFound: a.detail == b.detail
  of roNotFound, roMalformed: a.reason == b.reason

func `==`*(a, b: TransactionResult): bool =
  if a.outcome != b.outcome: return false
  case a.outcome
  of roFound: a.view == b.view
  of roNotFound, roMalformed: a.reason == b.reason

func `==`*(a, b: OpenResult): bool =
  if a.outcome != b.outcome: return false
  case a.outcome
  of ooOpened: a.session == b.session
  of ooChainNotFound, ooUnsupportedContract, ooMalformed: a.reason == b.reason
