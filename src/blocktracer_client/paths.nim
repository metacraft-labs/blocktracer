## Object-path derivation — pure functions, no I/O.
##
## "Resolves an entity to its object path (a pure function — no lookup)"
## ([Static-Site-Architecture.md](../../../codetracer-specs/BlockTracer/Static-Site-Architecture.md)
## §5, first bullet). Every path this package reads is built here, so the
## layout lives in one module on the consumer side exactly as
## `blocktracer/contract/ids.nim` holds it on the producer side.
##
## The sharding helpers are **imported from the contract**, not restated: a
## second `shardKeyFor` would be a second place for the layout to drift, which is
## the failure Static-Site-Architecture.md §2.9 exists to prevent.
##
## ## Every sharded path takes the chain's identifier encoding
##
## A shard segment is derived from an identifier, and how an identifier is
## written is a property of the chain — published per kind in
## `chains[<slug>].identifierEncoding` (Configuration.md §2.1). So the five
## sharded builders below take a `ChainIdentifierEncoding` beside the chain slug,
## and each names the KIND it is placing, because a chain may write its addresses
## and its transaction hashes differently (TON does; Fuel does).
##
## THERE IS NO DEFAULT ARGUMENT, and that absence is the design. A default of hex
## would let every call site that was not updated keep deciding the encoding for
## itself, silently and correctly-looking, which is precisely the failure the
## declaration exists to remove. A caller has to say where its encoding came
## from, and the answer is always the registry: a session's (`openChain` reads it
## once and pins it, like the generation), the validator's read of the tree it is
## checking, or the producer's own declaration.
##
## `blockPath` takes none, because it is content-addressed rather than sharded —
## the whole identifier is the segment, so there is nothing to slice and no
## alphabet question to answer. The `block` kind is declared all the same, because
## a chain that numbers its blocks (`decimal`) is saying something true about them
## that a later consumer may need.
##
## ## BOTH segments of a sharded path are the identifier's KEY FORM
##
## The shard is derived from the key form and the object is NAMED by it, and the
## two have to be the same normalisation or the pair does not address anything: a
## client that folded for the shard and not for the name would compute
## `/tx/abcd/0xAbCd….json`, which is a directory that exists holding a file that
## does not. So each builder below asks `identifierKeyForm` for the name segment
## and `shardKeyFor` — which folds by the same rule — for the shard.
##
## THE CONSEQUENCE IS THE POINT OF THE CASE RULE. An EIP-55 address and its
## lowercase spelling are one account, and either spelling now resolves to the
## one object the producer wrote. What is deliberately NOT folded is the
## identifier a published object carries in its BODY — that is the DISPLAY form
## (`identifierDisplayForm`), preserved for hex so the checksum riding in its
## case survives, and folded for bech32 because a mixed-case bech32 string is not
## an address. `src/blocktracer/validator.nim` checks both halves of that against
## every tree it validates.
##
## For every chain this tree publishes the fold is a no-op — the identifiers are
## lowercase hex, measured — so no published path moves.

import std/strutils
import ../blocktracer/contract/shards
import ../blocktracer/contract/version

export shardKeyFor, traceShards, ShardWidth
export ChainIdentifierEncoding, encodingFor, declaredOrLegacy,
       hexIdentifierEncoding, chainIdentifierEncoding,
       parseChainIdentifierEncoding, identifierEncodingNode,
       isIdentifierEncoding, identifierEncodingList,
       KindTransaction, KindAddress, KindBlock, LegacyUndeclaredEncoding
export identifierKeyForm, identifierDisplayForm, identifierPayload,
       identifierCaseRule, IdentifierCaseRule

proc registryPath*(contractVersion = ContractVersion): string =
  ## `/registry/chains.v{N}.json` — version in the name (§2.9).
  "registry/chains.v" & $contractVersion & ".json"

proc currentPath*(chain: string): string =
  ## `/d/{chain}/current.json` — the ONE mutable object per chain (§3.3).
  "d/" & chain & "/current.json"

proc generationRootPath*(chain, generation: string): string =
  "d/" & chain & "/g/" & generation & "/root.json"

proc summaryPath*(chain, generation: string): string =
  "d/" & chain & "/g/" & generation & "/summary.json"

proc blockPath*(chain, blockHash: string): string =
  ## Content-addressed and generation-independent (§2).
  ##
  ## **IT DOES NOT KEY-FORM ITS IDENTIFIER, AND THAT IS A KNOWN GAP RATHER THAN A
  ## RULING.** Every other path builder here folds by the chain's declared case
  ## rule, so either spelling of a case-insensitive identifier resolves to the one
  ## object the producer wrote. This one cannot, because it takes no
  ## `ChainIdentifierEncoding` — it is not sharded, so there was never an alphabet
  ## question for it to answer, and adding the parameter is a public signature
  ## change with five call sites and its own review.
  ##
  ## The consequence is narrow and real: a client holding a block identifier in a
  ## spelling the producer did not publish computes a path that does not exist,
  ## where a transaction or an address in the same spelling resolves. Nothing in
  ## the tree is in that state — `src/blocktracer/validator.nim` requires every
  ## published block REFERENCE to be its own key form, so the identifier this is
  ## called with is already folded whenever it came out of the tree — and the gap
  ## is between what a CLIENT may arrive with and what this computes.
  ##
  ## Recorded here rather than quietly closed, for the reason the shared file
  ## records the `aleo1…` row and `base64`'s unshardability: a widening done in
  ## passing is a widening nobody reviewed.
  "d/" & chain & "/block/" & blockHash & ".json"

proc txFactsPath*(chain, txHash: string,
                  enc: ChainIdentifierEncoding): string =
  ## The immutable facts (§2.3, §2.3b).
  "d/" & chain & "/tx/" & shardKeyFor(enc, KindTransaction, txHash) & "/" &
    identifierKeyForm(enc, KindTransaction, txHash) & ".json"

proc txStatePath*(chain, generation, txHash: string,
                  enc: ChainIdentifierEncoding): string =
  ## Generation-scoped canonicality + finality (§2.3b).
  "d/" & chain & "/g/" & generation & "/txstate/" &
    shardKeyFor(enc, KindTransaction, txHash) & "/" &
    identifierKeyForm(enc, KindTransaction, txHash) & ".json"

proc traceSelectionPath*(chain, traceSelectionVersion, txHash: string,
                         enc: ChainIdentifierEncoding): string =
  ## The versioned TraceSelection overlay (§2.3a).
  "d/" & chain & "/ts/" & traceSelectionVersion & "/" &
    shardKeyFor(enc, KindTransaction, txHash) & "/" &
    identifierKeyForm(enc, KindTransaction, txHash) & ".json"

proc addressIndexPath*(chain, generation, address: string,
                       enc: ChainIdentifierEncoding): string =
  "d/" & chain & "/g/" & generation & "/addr/" &
    shardKeyFor(enc, KindAddress, address) & "/" &
    identifierKeyForm(enc, KindAddress, address) & ".json"

proc addressSegmentPath*(chain, address, segment: string,
                         enc: ChainIdentifierEncoding): string =
  "d/" & chain & "/seg/" & shardKeyFor(enc, KindAddress, address) & "/" &
    identifierKeyForm(enc, KindAddress, address) & "/" & segment & ".json"

proc traceArtifactDir*(traceArtifactId: string): string =
  ## `/t/{t0t1}/{t2t3}/{traceArtifactId}/` — Trace-Artifacts.md §3.
  ##
  ## One namespace whatever the retention class, because the client cannot
  ## derive a class and the class changes over the artifact's life
  ## (Trace-Artifacts.md §2.9). So there is deliberately no `class` parameter.
  if traceArtifactId.len < 4: return ""
  let sh = traceShards(traceArtifactId)
  "t/" & sh.a & "/" & sh.b & "/" & traceArtifactId

proc traceManifestPath*(traceArtifactId: string): string =
  let d = traceArtifactDir(traceArtifactId)
  if d.len == 0: "" else: d & "/manifest.json"

proc traceContainerPath*(traceArtifactId, containerFile: string): string =
  ## The container named by the manifest, under the artifact's own directory.
  let d = traceArtifactDir(traceArtifactId)
  if d.len == 0: ""
  elif containerFile.len == 0: d & "/trace.ct"
  else: d & "/" & containerFile

proc traceInstructionsPath*(traceArtifactId: string): string =
  ## `instructions.json` beside the container — the recording's own per-step
  ## program counters, when the capture derived them
  ## (`tools/chain/derive-instructions.mjs`).
  ##
  ## A SIBLING OF THE CONTAINER AND NOT A FIELD OF THE MANIFEST. The manifest is
  ## the artifact's identity and provenance and is read on every trace
  ## resolution; a few hundred rows of instruction stream in it would be carried
  ## by every consumer that only wanted to know whether a container exists. This
  ## is fetched by the one surface that renders it.
  ##
  ## ABSENT IS A VALID TREE. A capture taken before the derivation existed, or
  ## on a machine without the container reader, publishes none — and the pane
  ## that would have rendered it has a correct page without one. So there is no
  ## `hasInstructions` on the manifest to keep in step: the object is either
  ## there or it is not, and asking is the whole protocol.
  let d = traceArtifactDir(traceArtifactId)
  if d.len == 0: "" else: d & "/instructions.json"

proc tracePositionsPath*(traceArtifactId: string): string =
  ## `positions.json` beside the container — the recording's per-step source
  ## positions, when the capture (or a post-hoc resolution) could derive them.
  ##
  ## THE RUNG ABOVE `instructions.json`, AND A SIBLING FOR THE SAME REASON. Both
  ## are per-step streams of a few hundred rows that only the pane which renders
  ## them should pay to fetch, so neither is a field of the manifest. Asking is
  ## the whole protocol here too: absent is a valid tree, and it is exactly the
  ## tree every capture published before an artifact could be resolved.
  ##
  ## It is NOT a restatement of `manifest.execution.sourceLevel`, and the two
  ## must not be collapsed. `sourceLevel` is a claim about the RECORDING — that
  ## every executed step carries a position — while this object is the per-step
  ## measurement itself, which is how a recording that positions 86 of its 108
  ## steps can show real source at 86 of them and say so at the other 22. A
  ## reader that inferred one from the other would have to choose between
  ## suppressing real source and overclaiming a rung.
  let d = traceArtifactDir(traceArtifactId)
  if d.len == 0: "" else: d & "/positions.json"

proc traceCalltracePath*(traceArtifactId: string): string =
  ## `calltrace.json` beside the container — the frames the recording opened,
  ## when the capture derived them (`tools/chain/derive-calltrace.mjs`).
  ##
  ## A THIRD SIBLING, ON THE SAME TERMS AS THE OTHER TWO. It is not a manifest
  ## field for the reason `traceInstructionsPath` gives, and absent is a valid
  ## tree for the reason `tracePositionsPath` gives. Asking is the whole
  ## protocol here as well.
  ##
  ## It is NOT a restatement of `manifest.execution.frames`, and the difference
  ## is why this object had to exist. That field is a COUNT — one integer, taken
  ## from the capture's `recording.callsOpened` — and a count is exactly what the
  ## Call Trace pane could never render. The pane needs the frames' names, their
  ## nesting and the step each opened at, and a tree that published the count
  ## while withholding the frames is how a manifest reading `frames: 1` came to
  ## sit beside a pane rendering none.
  let d = traceArtifactDir(traceArtifactId)
  if d.len == 0: "" else: d & "/calltrace.json"

proc sourceBundlePointerPath*(chain, codeHash: string): string =
  ## `/src/{chain}/{codeHash}/current.json` — the ◆ pointer that moves when a
  ## better interpretation lands (Source-Resolution.md §5).
  "src/" & chain & "/" & codeHash & "/current.json"

proc sourceBundlePath*(chain, codeHash, bundleHash: string): string =
  ## `/src/{chain}/{codeHash}/{bundleHash}.json` — immutable bundle bytes.
  "src/" & chain & "/" & codeHash & "/" & bundleHash & ".json"

proc shortBundleHash*(sourceBundleId: string): string =
  ## `bundleHash` is the short form of `sourceBundleId` (Source-Resolution.md
  ## §5). The producer chooses the shortening; the only thing the consumer may
  ## assume is that an algorithm tag (`blake3:`, `sha1:`) is not part of a path
  ## segment, so it is stripped and nothing else is.
  let i = sourceBundleId.find(':')
  if i < 0: sourceBundleId else: sourceBundleId[i + 1 .. ^1]
