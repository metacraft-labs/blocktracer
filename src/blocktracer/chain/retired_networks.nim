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
##
## ## A SLUG IS NOT A DEPLOYMENT, AND REUSING ONE EMPTIES THIS FILE OF IT
##
## `aztec` and `aztec-testnet` were listed here from 2026-10-28. They are not
## listed any more, and the reason is not that the dead rollups came back: it is
## that the two SLUGS now name the LIVE rollups the tip-follower tracks
## (`tools/chain/follow-to-tip.mjs`), by the operator's decision to publish the
## first production corpus under the plain names. The deployments this file was
## written about are gone and stay gone — what changed is that their names were
## handed to their successors.
##
## WHY THAT HAD TO BE A REMOVAL AND NOT A WORDING CHANGE. Every reader of this
## file keys on the chain slug alone — `isRetiredNetwork(chain)`, called from
## twelve render sites. A slug left listed here while the follower publishes
## fresh rows under it would word EVERY new row `akStranded`: "none can be now",
## on a transaction whose chain is up, whose range is replayable, and whose
## repair is a dispatch away. That is a worse claim than the one this file
## exists to prevent, and it would land on the whole production corpus rather
## than on a frozen one.
##
## THE SLUG-KEYED READING IS THEREFORE A KNOWN LIMIT, NOT A SETTLED DESIGN. The
## fact belongs to the pair `(chain, deployment)`: a capture carries its
## deployment in `provenance.rollupVersion` and
## `tools/chain/chain-identity.json` carries the live one (`aztec-testnet`
## 679261766 against the committed capture's 1821665230), so the two ARE
## distinguishable in data — just not at the render sites, which are handed a
## slug and nothing else. Until that is plumbed, the correct configuration is
## the one that is right about every row production serves, and the frozen
## corpora at the old deployments are discarded rather than republished. The
## gate below is what stops the two files disagreeing in the meantime.

import std/[json, strutils]

const retiredNetworksJson = staticRead("../../../tools/chain/retired-networks.json")
const chainIdentityJson = staticRead("../../../tools/chain/chain-identity.json")

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
  ## cannot be indexed at run time in Nim, and this list is one entry long
  ## (three until the `aztec` and `aztec-testnet` slugs were reused for the live
  ## rollups — see the header).
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

proc parseLiveIdentityChains(): seq[string] =
  ## The chains `tools/chain/chain-identity.json` says we last VERIFIED we can
  ## decode, and the deployment we verified against. That file calls itself the
  ## forward-looking half of this one, in its own words, so it is the one list
  ## that can contradict this one.
  let doc = parseJson(chainIdentityJson)
  if doc{"format"}.getStr != "blocktracer/chain-identity@1":
    raise newException(ValueError,
      "tools/chain/chain-identity.json declares format '" &
      doc{"format"}.getStr & "', which this build does not read")
  # `pairs` OVER THE NODE AND NOT `getFields`, which hands back an
  # `OrderedTable` this module would have to import `std/tables` to iterate —
  # and `std/json`'s own `pairs(JsonNode)` is already the right shape. The nil
  # and kind guard is not decoration: `node{"key"}` returns a **nil** JsonNode
  # for an absent key, and iterating one is a crash rather than an empty list,
  # which is how a malformed file would become a segfault at compile time
  # instead of the sentence below.
  let chains = doc{"chains"}
  if chains == nil or chains.kind != JObject:
    raise newException(ValueError,
      "tools/chain/chain-identity.json carries no `chains` object, so the " &
      "live-deployment list this build compares the retired registry against " &
      "would be silently EMPTY — and an empty list agrees with every obituary.")
  for chain, entry in chains.pairs:
    discard entry
    result.add chain

const LiveIdentityChains* = parseLiveIdentityChains()

proc registriesAgree(retired: seq[RetiredNetwork], live: seq[string]): bool =
  ## FAILS THE BUILD when one slug is in both registries, because the two make
  ## opposite claims about it and every reader of this file can only see one of
  ## them.
  ##
  ## This is the gate for the mistake that was actually made. `aztec` and
  ## `aztec-testnet` were listed as retired, then the same two slugs were handed
  ## to the live rollups the follower tracks — and nothing in the tree objected,
  ## because the obituary and the decode registry had never been compared. The
  ## symptom would not have been a crash: it would have been the whole
  ## production corpus rendering "no trace can be produced and none can be now"
  ## under a chain that was up and replayable.
  ##
  ## IT BINDS ONE OF THE TWO SLUGS AND THAT IS STATED RATHER THAN HIDDEN.
  ## `chain-identity.json` carries `aztec-testnet` and not `aztec`, because an
  ## entry there is a dated decode MEASUREMENT and no such measurement has been
  ## taken against Aztec mainnet. The follower's own table covers both, and
  ## `tools/chain/follow-to-tip-selftest.mjs` compares THAT against this file;
  ## the two gates are deliberately in different languages, over different
  ## lists, because a single list is a single thing to forget.
  for n in retired:
    if n.chain in live:
      raise newException(ValueError,
        "chain '" & n.chain & "' is in tools/chain/retired-networks.json AND in " &
        "tools/chain/chain-identity.json. Those files make opposite claims: the " &
        "first says the network that would serve a repair is gone, the second " &
        "records a deployment we verified we can decode. Every reader keys on " &
        "the slug alone, so a chain in both words every row it publishes as " &
        "permanently untraceable while the follower is still ingesting it. If a " &
        "slug has been reused for a new deployment, the retired entry must go; " &
        "if the network really is gone, the chain-identity entry must go.")
  true

const RegistriesAgree* = registriesAgree(RetiredNetworks, LiveIdentityChains)
  ## Forced at compile time by being a `const`; see `registriesAgree`.

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
