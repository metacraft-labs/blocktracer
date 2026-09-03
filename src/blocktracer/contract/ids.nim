## Content-addressed identity helpers shared by BOTH producers and the validator.
##
## The whole point of the seam is that a trace's URL is *computable* from what the
## client already knows — `executionInputId` (from the immutable transaction facts)
## plus the recorder pin (from the chain registry) — with no lookup
## (Trace-Artifacts.md §2.1, Static-Site-Architecture.md §3.2). Because the
## derivation lives in ONE module, the demo generator and the conformance validator
## necessarily agree on where every `/t/...` artifact must live.
##
## DEMO STAND-IN NOTE: the real pipeline hashes with BLAKE3. The Nim standard
## library ships SHA-1 but not BLAKE3, so this demo derivation uses SHA-1 and tags
## its opaque ids with the algorithm honestly (`sha1:...`). The *contract* treats
## these ids as opaque strings — the browser cannot recompute `executionInputId`
## either (Trace-Artifacts.md §2.1) — so swapping in BLAKE3 behind this module is a
## producer change, not a contract change.

import std/[sha1, strutils]

import ./shards
export shards   # `hexShard`, `traceShards` — see the note where they used to be

const
  ContractTagTrace = "blocktracer/trace/v1"
    ## Domain-separation tag for `traceArtifactId` (Trace-Artifacts.md §2.1).
  ArtifactSchemaVersionInt = 1
    ## `artifactSchemaVersion` input; kept in lock-step with
    ## version.ArtifactSchemaVersion by the test suite.

const b32Alphabet = "abcdefghijklmnopqrstuvwxyz234567"
  ## RFC 4648 base32, lowercased (base32 is used for `traceArtifactId`,
  ## Trace-Artifacts.md §2.1).

proc base32Lower*(data: openArray[uint8]): string =
  ## Lowercase, unpadded base32 of the given bytes.
  var acc: uint64 = 0
  var bits = 0
  for b in data:
    acc = (acc shl 8) or uint64(b)
    bits += 8
    while bits >= 5:
      bits -= 5
      result.add b32Alphabet[int((acc shr uint64(bits)) and 0x1F'u64)]
  if bits > 0:
    result.add b32Alphabet[int((acc shl uint64(5 - bits)) and 0x1F'u64)]

proc sha1Bytes(s: string): array[20, uint8] =
  array[20, uint8](secureHash(s))

proc sha1LowerHex(s: string): string =
  toLowerAscii($secureHash(s))

const idSep = "\x1f"  ## unit separator; unambiguous field join for hashing

proc demoExecutionInputId*(chain, txHash, selector: string): string =
  ## Deterministic stand-in for the execution capsule hash (Trace-Artifacts.md
  ## §2.0). Real pipeline: `BLAKE3(canonical execution capsule)`. This is a pure
  ## function of consensus-ish inputs, so it belongs in the immutable transaction
  ## facts (Static-Site-Architecture.md §2.3b) — which is exactly where the demo
  ## generator puts it, under `executions[].executionInputId`.
  "sha1:" & sha1LowerHex(chain & idSep & txHash & idSep & selector)

proc deriveTraceArtifactId*(executionInputId, recorderId, recorderBuild,
                            profileHash, traceSchema: string): string =
  ## `traceArtifactId = base32(hash(...))[0..25]` — Trace-Artifacts.md §2.1.
  ## `recorderBuild` is load-bearing: changing the recorder must change the URL so
  ## a stale artifact cannot outlive a bug fix.
  let material = [ContractTagTrace, $ArtifactSchemaVersionInt, executionInputId,
                  recorderId, recorderBuild, profileHash, traceSchema].join(idSep)
  base32Lower(sha1Bytes(material))[0 .. 25]

proc profileHash*(name: string): string =
  ## Deterministic stand-in for the recording-profile hash (Trace-Artifacts.md
  ## §2.3). Real pipeline hashes the full `RecordingProfile` struct.
  "sha1:" & sha1LowerHex("profile" & idSep & name)

proc recorderBuildHash*(recorderId, version: string): string =
  ## Deterministic stand-in for `recorderBuildHash` (Trace-Artifacts.md §2.1).
  "sha1:" & sha1LowerHex("recorder" & idSep & recorderId & idSep & version)

proc contentHashSha1*(bytes: string): string =
  ## Content hash of a container's bytes. Real pipeline: `blake3:...`.
  "sha1:" & sha1LowerHex(bytes)

# --- path sharding (Static-Site-Architecture.md §2, Trace-Artifacts.md §3) ---
#
# Moved to `./shards` and re-exported: the browser needs `hexShard` and this
# module's `std/sha1` does not compile on the JS backend. See shards.nim.
