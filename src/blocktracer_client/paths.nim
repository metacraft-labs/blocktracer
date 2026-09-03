## Object-path derivation — pure functions, no I/O.
##
## "Resolves an entity to its object path (a pure function — no lookup)"
## ([Static-Site-Architecture.md](../../../codetracer-specs/BlockTracer/Static-Site-Architecture.md)
## §5, first bullet). Every path this package reads is built here, so the
## layout lives in one module on the consumer side exactly as
## `blocktracer/contract/ids.nim` holds it on the producer side.
##
## The sharding helpers are **imported from the contract**, not restated: a
## second `hexShard` would be a second place for the layout to drift, which is
## the failure Static-Site-Architecture.md §2.9 exists to prevent.

import std/strutils
import ../blocktracer/contract/shards
import ../blocktracer/contract/version

export hexShard, traceShards

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
  "d/" & chain & "/block/" & blockHash & ".json"

proc txFactsPath*(chain, txHash: string): string =
  ## The immutable facts (§2.3, §2.3b).
  "d/" & chain & "/tx/" & hexShard(txHash) & "/" & txHash & ".json"

proc txStatePath*(chain, generation, txHash: string): string =
  ## Generation-scoped canonicality + finality (§2.3b).
  "d/" & chain & "/g/" & generation & "/txstate/" & hexShard(txHash) & "/" &
    txHash & ".json"

proc traceSelectionPath*(chain, traceSelectionVersion, txHash: string): string =
  ## The versioned TraceSelection overlay (§2.3a).
  "d/" & chain & "/ts/" & traceSelectionVersion & "/" & hexShard(txHash) & "/" &
    txHash & ".json"

proc addressIndexPath*(chain, generation, address: string): string =
  "d/" & chain & "/g/" & generation & "/addr/" & hexShard(address) & "/" &
    address & ".json"

proc addressSegmentPath*(chain, address, segment: string): string =
  "d/" & chain & "/seg/" & hexShard(address) & "/" & address & "/" &
    segment & ".json"

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
