## Object-path derivation — pure functions, no I/O.
##
## "Resolves an entity to its object path (a pure function — no lookup)"
## ([Static-Site-Architecture.md](../../../codetracer-specs/BlockTracer/Static-Site-Architecture.md)
## §5, first bullet). Every path this package reads is reached through this
## module, so a consumer has one import to make and one place to look.
##
## Nothing here is restated from the contract: a second `shardKeyFor` — or a
## second `/d/{chain}/tx/{shard}/{id}.json` — would be a second place for the
## layout to drift, which is the failure Static-Site-Architecture.md §2.9 exists
## to prevent. What this module HOLDS is the consumer-only layout; what it
## RE-EXPORTS is everything the producer shares with it.
##
## ## THE IDENTIFIER-KEYED BUILDERS ARE NOT HERE. THEY ARE IN THE CONTRACT
##
## `blockPath`, `txFactsPath`, `txStatePath`, `traceSelectionPath`,
## `addressIndexPath` and `addressSegmentPath` live in
## `blocktracer/contract/shards.nim` and are RE-EXPORTED here, so every consumer
## of this module sees them unchanged. They moved because the PRODUCERS could not
## reach them here: `src/blocktracer/chain/ingest.nim` and
## `src/blocktracer/demo/generator.nim` are producers, and this package is what
## READS what a producer wrote — so they built their sharded paths by hand, at
## fourteen sites, and when `shardKeyFor` started folding per the declared case
## rule twelve of those acquired a folded shard beside a raw name. That module's
## header carries the measurement and the reason the move is the fix rather than
## fourteen edited call sites.
##
## What stays here is what no producer needs and what is not keyed by a chain's
## identifier: the registry and `current.json` pointers, the generation objects,
## the trace-artifact namespace (`traceShards`, which is deliberately NOT
## encoding-parameterised) and the source-bundle layout.
##
## ## Every identifier-keyed path takes the chain's identifier encoding
##
## A shard segment is derived from an identifier, and how an identifier is
## written is a property of the chain — published per kind in
## `chains[<slug>].identifierEncoding` (Configuration.md §2.1). So all six
## builders take a `ChainIdentifierEncoding` beside the chain slug, and each names
## the KIND it is placing, because a chain may write its addresses and its
## transaction hashes differently (TON does; Fuel does).
##
## THERE IS NO DEFAULT ARGUMENT, and that absence is the design. A default of hex
## would let every call site that was not updated keep deciding the encoding for
## itself, silently and correctly-looking, which is precisely the failure the
## declaration exists to remove. A caller has to say where its encoding came
## from, and the answer is always the registry: a session's (`openChain` reads it
## once and pins it, like the generation), the validator's read of the tree it is
## checking, or the producer's own declaration.
##
## `blockPath` HAS NO SHARD SEGMENT AND STILL TAKES THE ENCODING. It is
## content-addressed, so there is nothing to slice and no alphabet question — but
## the CASE question is a different question from the alphabet question, and while
## this one alone did not fold, `/tx/0xABC…` and `/address/0xABC…` resolved on
## input that `/block/0xABC…` 404ed on.
##
## ## BOTH segments of a sharded path are the identifier's KEY FORM
##
## The shard is derived from the key form and the object is NAMED by it, and the
## two have to be the same normalisation or the pair does not address anything: a
## client that folded for the shard and not for the name would compute
## `/tx/abcd/0xAbCd….json`, which is a directory that exists holding a file that
## does not. So each builder asks `identifierKeyForm` for the name segment and
## `shardKeyFor` — which folds by the same rule — for the shard.
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
export blockPath, txFactsPath, txStatePath, traceSelectionPath,
       addressIndexPath, addressSegmentPath
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
