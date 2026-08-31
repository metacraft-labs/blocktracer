## SDK-CONSUMER: the Client SDK -> Embed SDK handoff, against the real Embed SDK.
##
## M12a's deliverable "Resolution: transaction hash → traceArtifactId → manifest
## → **a TraceSource the Embed SDK accepts**". The only way to check the last
## four words is to compile against the Embed SDK and hand it one, which is what
## this file does — every `TraceSource`, `httpRangeTrace`, `validate` and
## `toLaunchArgs` below is the codetracer package's own code, reached through
## its facade.
##
## It is a SEPARATE suite from `tclientsdk.nim` on purpose. The chain half of
## the Client SDK compiles and is tested with no debugger on the path at all;
## that separation is the layering, and merging the two files would quietly
## destroy the demonstration.
##
## Build:
##   just sdk-test-embed              # resolves CODETRACER_SRC / ../codetracer
##
## or by hand:
##   nim c -r -d:nimOldCaseObjects \
##     --path:$CODETRACER_SRC/src/frontend/viewmodel \
##     --path:$CODETRACER_SRC/src/frontend --path:$CODETRACER_SRC/src \
##     --path:$ISONIM_SRC/src --path:$NIM_EVERYWHERE_SRC/src \
##     tests/tembedhandoff.nim

import std/[unittest, os, json, strutils, sha1]

import ../src/blocktracer_client_embed
import ../src/blocktracer/demo/generator

const
  Chain = "demo"
  Base = "https://blocktracer.org"
  FixtureDir = currentSourcePath().parentDir.parentDir / "fixtures" / "trace" /
               "noir_space_ship"
  # The REAL `noir_space_ship` CTFS container recorded by `nargo trace`.
  Fixture = FixtureDir / "zk_shields.ct"
  SourcesDir = FixtureDir / "sources"

proc synthHash(seed, kind: string, n: int): string =
  "0x" & toLowerAscii($secureHash(seed & "|" & kind & "|" & $n))[0 .. 39]

let dir = getTempDir() / "blocktracer-embed-handoff-test"
removeDir dir
createDir dir
discard generate(DemoConfig(outDir: dir, seed: "handoff",
                            traceFixturePath: Fixture, traceSourcesDir: SourcesDir))
let store = localTree(dir)
let opened = openChain(store, Chain)
doAssert opened.outcome == ooOpened
let session = opened.session

proc resolveFor(txHash, selector: string): ResolvedTrace =
  let tr = transaction(store, session, txHash)
  doAssert tr.outcome == roFound
  resolveTrace(store, session, tr.view, selector)

let readyTx = synthHash("handoff", "tx", 0)
let splitTx = synthHash("handoff", "tx", 1)
let onDemandTx = synthHash("handoff", "tx", 3)
let divergentTx = synthHash("handoff", "tx", 2)

suite "M12a — the Client SDK hands the Embed SDK a TraceSource":
  test "the Embed SDK is really the one being linked":
    # Its own facade constant, from its own module. If this file compiled
    # against a local stand-in instead, this would not resolve.
    check CodeTracerEmbedFacadeModule == "codetracer_embed"

  test "a ready trace becomes an http-range TraceSource the Embed SDK accepts":
    let r = resolveFor(readyTx, "")
    check r.kind == trkReady
    let handoff = toTraceSource(r, Base)
    check handoff.outcome == tsoReady
    check handoff.source.kind == tskHttpRange
    check handoff.source.url == Base & "/" & r.containerPath
    # The Embed SDK's OWN validator accepts it — not a check of ours.
    check handoff.source.isValid
    handoff.source.validate()           # raises TraceSourceDefect if not

  test "the wire form is the Embed SDK's, not a restatement of it":
    let r = resolveFor(readyTx, "")
    let handoff = toTraceSource(r, Base)
    let args = handoff.launchArgs
    check args == handoff.source.toLaunchArgs
    check args["traceSource"]["kind"].getStr == "http-range"
    check args["traceSource"]["url"].getStr == handoff.source.url

  test "what crosses the boundary carries NO chain concept":
    # This is the boundary, expressed as a value rather than a rule: the Embed
    # SDK ends up holding a URL under /t/{shard}/{shard}/{artifactId}/ and
    # nothing else. No chain slug, no transaction hash, no generation — so the
    # same type serves Noir Studio, which has none of them
    # (Client-SDK.md §2, CodeTracer-Embed-SDK.md §3.2 last row).
    let r = resolveFor(readyTx, "")
    let handoff = toTraceSource(r, Base)
    let u = handoff.source.url
    check u.contains("/t/")
    check not u.contains(readyTx)
    check not u.contains(Chain)
    check not u.contains(session.generation & "/")
    check not handoff.source.describe().contains(readyTx)

  test "an unobservable execution is not replayable, with the producer's reason":
    let r = resolveFor(splitTx, "private")
    check r.kind == trkAbsent
    let handoff = toTraceSource(r, Base)
    check handoff.outcome == tsoNotReplayable
    check handoff.reason == r.reason
    check handoff.reason.len > 0
    check handoff.launchArgs.len == 0

  test "an unpublished on-demand trace is not replayable either, and says so":
    let r = resolveFor(onDemandTx, "")
    check r.kind == trkOnDemand
    check r.traceArtifactId.len > 0        # the address exists; the bytes do not
    check toTraceSource(r, Base).outcome == tsoNotReplayable

  test "a divergent trace IS handed over, flagged rather than withheld":
    let r = resolveFor(divergentTx, "")
    check r.kind == trkDivergent
    let handoff = toTraceSource(r, Base)
    check handoff.outcome == tsoReady
    check handoff.divergent
    check handoff.source.isValid

  test "an in-memory container is handed over as `bytes`, needing no network":
    let r = resolveFor(readyTx, "")
    let raw = store.get(r.containerPath)
    check raw.found
    var bytes = newSeq[byte](raw.body.len)
    for i, c in raw.body: bytes[i] = byte(c)
    let handoff = toTraceSource(r, bytes)
    check handoff.outcome == tsoReady
    check handoff.source.kind == tskBytes
    check handoff.source.bytes.len == r.manifest.container.bytes
    check handoff.source.isValid
    check handoff.source.describe() == "bytes:" & $bytes.len & "B"

  test "an empty container is refused at the consumer's call site":
    let r = resolveFor(readyTx, "")
    check toTraceSource(r, newSeq[byte]()).outcome == tsoNotReplayable

  test "the deep-link witness comes from the container actually handed over":
    let r = resolveFor(readyTx, "")
    let handoff = toTraceSource(r, Base)
    let w = handoff.witnessFor
    check w.len == DefaultWitnessLength
    check checkWitness(w, handoff.contentHash) == wvMatches
    # INDEPENDENT ORACLE: the manifest on disk, parsed with std/json.
    let manifest = parseJson(store.get(r.manifestPath).body)
    check checkWitness(w, manifest["container"]["hash"].getStr) == wvMatches

  test "the position precedence runs against a real resolution":
    let r = resolveFor(readyTx, "")
    let handoff = toTraceSource(r, Base)
    let link = DeepLink(version: 1, coordinate: "s:42",
                        witness: handoff.witnessFor,
                        anchor: Anchor(kind: akLog, data: "1"))
    let exact = openPosition(link, handoff, false, "")
    check exact.outcome == poExact
    check exact.coordinate == "s:42"
    check not exact.visible

    # A regenerated trace: same link, a witness that no longer matches.
    var stale = link
    stale.witness = "ffffffffffff"
    let recovered = openPosition(stale, handoff, true, "s:99")
    check recovered.outcome == poRecoveredByAnchor
    check recovered.coordinate == "s:99"
    check recovered.visible

    # Nothing replayable at all: terminal, and stated.
    let absent = toTraceSource(resolveFor(splitTx, "private"), Base)
    let none = openPosition(link, absent, false, "")
    check none.outcome == poNoReplayableArtifact
    check none.visible
