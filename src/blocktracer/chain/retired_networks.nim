## chain/retired_networks.nim — which chains' upstream network is GONE.
##
## ## Why this is not a column in `refusal-reasons.json`
##
## That file classifies each MEMBER `permanent` or `repairable`, once, for every
## chain, and those classifications are still correct. `not-attempted` really
## does mean the run stopped rather than the chain refusing; on a chain whose
## network is still up, re-running the range still produces the trace. Sui's
## `runtime-refused` rows are the live example — a Sui build with trace hooks in
## pre-38 layers would trace them — so they are repairable and must keep saying
## so.
##
## What a member cannot carry is the OTHER half: whether the network that would
## serve the repair still exists. Durability is a property of the PAIR
## `(member, chain)`, and splitting it here is what keeps one chain's obituary
## from rewording another chain's rows.
##
## ## What a listed chain keeps
##
## Everything it published. Every row keeps its member and the sentence the
## producer wrote, because both were TRUE WHEN WRITTEN: the repair really was
## available then, and `~/m/dev/bt-historic-replay` is the proof — 206
## transactions replayed into 211 traces at blocks 1-200, 24.7k, 45k, 68k and
## 75.7k, which is where 18,087 of this corpus's traces come from. What changes
## is only the durability a PAGE infers from those rows, which is the one claim
## that went stale silently when the network went away.
##
## ## The test is not "does the endpoint answer"
##
## It answers. A restarted rollup answers perfectly well, at its own low block
## numbers, and a request for a LOW height returns a plausible header belonging
## to a different chain — which is exactly how this stayed invisible. The test
## is whether the endpoint still serves a height INSIDE THE RANGE WE CAPTURED,
## and for both Aztec chains it does not: `Unknown block`, code 26. The evidence
## string on each entry records that measurement rather than asserting the
## conclusion.

import std/[json, strutils]

const retiredNetworksJson = staticRead("../../../tools/chain/retired-networks.json")

type
  RetiredNetwork* = object
    ## One chain whose upstream no longer exists, exactly as the shared file
    ## states it.
    chain*: string
    observedOn*: string  ## when the absence was MEASURED, not when it happened
    evidence*: string    ## the measurement, so a reader can re-run it
    note*: string        ## what a visitor is told, once, at chain level

proc parseRetiredNetworks(): seq[RetiredNetwork] =
  ## Reads the shared file at compile time, in file order. A `seq` and a linear
  ## scan for the same reason `refusal_reasons.nim` gives: a `const Table`
  ## cannot be indexed at run time in Nim, and this list is three entries long.
  let doc = parseJson(retiredNetworksJson)
  if doc{"format"}.getStr != "blocktracer/retired-networks@1":
    raise newException(ValueError,
      "tools/chain/retired-networks.json declares format '" &
      doc{"format"}.getStr & "', which this build does not read")
  for n in doc{"networks"}.getElems:
    let chain = n{"chain"}.getStr
    let note = n{"note"}.getStr
    let evidence = n{"evidence"}.getStr
    # EVERY FIELD IS REQUIRED, and an entry missing one fails the BUILD rather
    # than publishing a chain-level claim with nothing behind it. This file's
    # whole purpose is to overrule a published durability, which is a strong
    # thing to do quietly; an entry with no evidence would do it with nothing
    # a reader could check.
    if chain.len == 0 or note.len == 0 or evidence.len == 0:
      raise newException(ValueError,
        "tools/chain/retired-networks.json: an entry is missing chain, note or " &
        "evidence (chain='" & chain & "'). A retirement overrules what a row " &
        "published about its own durability, so it may not be declared without " &
        "the measurement behind it.")
    result.add RetiredNetwork(chain: chain, observedOn: n{"observedOn"}.getStr,
                              evidence: evidence, note: note)

const RetiredNetworks* = parseRetiredNetworks()

func isRetiredNetwork*(chain: string): bool =
  ## Is this chain's upstream gone? The one question the wording asks.
  for n in RetiredNetworks:
    if n.chain == chain: return true
  false

func retiredNetworkNote*(chain: string): string =
  ## The chain-level sentence, or `""` when the chain is not listed.
  for n in RetiredNetworks:
    if n.chain == chain: return n.note
  ""

func retiredNetworkChains*(): seq[string] =
  ## The listed chains, for a diagnostic. Named rather than counted, because a
  ## reader who sees a durability they did not expect wants to know which list
  ## their chain is on.
  for n in RetiredNetworks: result.add n.chain

func retiredNetworkList*(): string =
  retiredNetworkChains().join(", ")
