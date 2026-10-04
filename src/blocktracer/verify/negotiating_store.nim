## verify/negotiating_store.nim — a consumer transport that DECOMPRESSES, which is what
## a kit has instead of a browser.
##
## ## Why this exists, and why it is not in the SDK
##
## `CTFS-Compact-Profile.milestones.org` CCP-6 requires each conformance kit to "either
## negotiate or decompress explicitly". Two of the three can: they read a published tree
## and can run a codec. The third reads through the Client SDK, and the SDK **must not**
## hold a codec — `ci/test/client-sdk-boundary.sh` bans `osproc` from its import closure
## ("spawns processes — an embeddable library cannot") and bans everything under
## `src/blocktracer/publish/` with it.
##
## That is not an obstacle to route around; it is the SDK's design saying where the
## decompressor belongs. `blocktracer_client/store.nim`'s whole shape is one injected
## closure whose entire input is a path:
##
## > The honest limit: the closure is the *consumer's*, so a consumer can of course
## > capture a credential in its own `fetchProc`. That is their transport and their
## > decision.
##
## A browser's transport negotiates `Content-Encoding` and hands the SDK the raw
## container. A kit has no browser, so it supplies the equivalent here — in the
## CONSUMER's closure, outside the package, exactly where a transport concern goes. The
## SDK still contains no codec and still asks for nothing but a path.
##
## ## How it decides whether to decompress
##
## From the object's own manifest, which is the only thing that can say: brotli has no
## magic number (see `contract/container_encoding.nim`), so the bytes carry no evidence.
## For a path ending `/trace.ct` it reads the sibling `manifest.json` and inflates only
## when `container.encoding` names a scheme this build implements.
##
## An encoding token it does NOT implement is a REFUSAL and not a pass-through: handing
## the SDK bytes it cannot parse, under a manifest that said why, would convert a precise
## condition into a container-malformed error one layer up. `ObjectResponse` has no error
## channel — a missing object is `found = false` and that is deliberate — so the refusal
## is raised, which is the one thing a consumer's own closure is allowed to do that the
## SDK's read path is not.
##
## ## Three outcomes, and the middle one is why `storedBytes` exists
##
##   * decoder available        -> the SDK sees the RAW container, as a browser would
##   * no decoder on PATH       -> the at-rest bytes are passed through UNCHANGED, and the
##                                 SDK's own check reports the raw figures NOT MEASURED
##                                 while verifying the object at rest exactly
##   * `negotiate = false`      -> the at-rest bytes, deliberately, which is CCP-6's named
##                                 control: an un-negotiated read must produce a distinct
##                                 diagnosis rather than a malformed container

import std/[json, os, strutils]
import ../../blocktracer_client/store
import ../contract/container_encoding
import ../publish/encoding

proc declaredEncoding(root, path: string): string =
  ## What the manifest beside this object says it is stored under, or `""`.
  ##
  ## READ PER OBJECT rather than cached, because a kit's whole job is to read what is
  ## there: a cache would answer for a tree that has since been rewritten under it, which
  ## is the shape of defect `store.nim`'s own singleton-cache note refuses by default.
  if not path.endsWith("/trace.ct"): return ""
  let m = root / path.parentDir / "manifest.json"
  if not fileExists(m): return ""
  try:
    parseJson(readFile(m)){"container"}{"encoding"}.getStr("")
  except CatchableError:
    # A manifest that will not parse is the SDK's problem to report — it reads the same
    # file through its own decoder and says so precisely. Answering "" here leaves that
    # path intact rather than pre-empting it with a transport error.
    ""

proc negotiatingLocalTree*(dir: string, negotiate = true): ObjectStore =
  ## `store.localTree`, plus the one thing a browser's transport does that a file read
  ## does not.
  ##
  ## `negotiate = false` is the CONTROL and not a convenience: CCP-6's verification asks
  ## for the same archive read WITHOUT negotiation, and a control reachable only by
  ## editing a test is a control nobody runs.
  let root = dir
  let plain = localTree(dir)
  if not negotiate: return plain
  newObjectStore("local+negotiate:" & dir, proc(path: string): ObjectResponse =
    let r = plain.get(path)
    if not r.found: return r
    let token = declaredEncoding(root, path)
    if token.len == 0: return r
    let parsed = parseContainerEncoding(token)
    if not parsed.ok:
      raise newException(ObjectStoreDefect, "this transport cannot read " & path & ": " &
                         parsed.why)
    if parsed.enc == ceIdentity: return r
    let dec = decodeContainer(r.body, parsed.enc)
    if not dec.ok:
      # PASSED THROUGH, NOT REFUSED, and the difference is which layer reports it. The
      # bytes at rest are still checkable by length and hash against `storedBytes` /
      # `storedHash`, which is a real verdict; refusing here would replace it with a
      # transport exception and lose the half that can be measured.
      return r
    ObjectResponse(found: true, body: dec.data))
