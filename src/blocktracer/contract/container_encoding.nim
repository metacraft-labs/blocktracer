## contract/container_encoding.nim — what a published container's bytes AT REST are,
## and the ONE diagnosis for the one cost that has.
##
## ## What this is for
##
## A BlockTracer archive is a CTFS container, and `CTFS-Compact-Profile.milestones.org`
## CCP-6 settles how it is served: the stored object holds the COMPRESSED bytes and
## carries a `Content-Encoding`, the browser decompresses it before any application code
## runs, and the header the loader then reads truthfully declares raw streams. Compression
## becomes a property of the TRANSPORT, and the format reader never learns of it. No
## WebAssembly decompressor is in the BlockTracer path at all.
##
## **The compressor is brotli**, measured rather than preferred. Across five real
## blockchain traces fetched from production, brotli is outright smallest on four of five
## below ~100 KB of raw payload and loses the fifth (205 KB raw) by 0.7% to `xz`; above
## that `xz` wins and keeps winning — 12.1% on a 353 KB container. `xz` is not a candidate
## at any size, because **no browser performs it**: a pre-compressed archive is
## decompressed by the browser's own `Content-Encoding` handling, so a scheme no browser
## implements is not available however small its output. Brotli is the smallest of the
## schemes that are, by a wide margin over gzip (23,463 against 36,471 bytes, 35.7%).
## Blockchain traces sit at the low end of that range by construction — gas bounds the
## executed step count — which is the regime where the two legs of the argument agree.
##
## ## THE ONE COST, AND IT IS WHY THIS MODULE EXISTS RATHER THAN A FLAG
##
## A consumer that obtains bytes WITHOUT negotiating an encoding receives the compressed
## bytes and will fail to parse them as a container. Browsers negotiate. `curl --compressed`
## negotiates. **A file read negotiates nothing**, and the three conformance kits in this
## repository read files:
##
##   * `blocktracer-conformance` — `ingestSnapshot` over a snapshot tree, then the two below
##   * `blocktracer-validate` — `validator.validateTree` over a published tree
##   * `blocktracer-client-conformance` — `consumerConformance`, through the SDK's
##     `store.localTree`, whose fetch is `readFile`
##
## Each compares a container's length and hash against what the manifest declares. Handed
## the stored, pre-compressed bytes, every one of them would have reported
##
##     container declares 77824 bytes, served 1058
##
## which is a **format defect that does not exist** and sends a recorder team looking for a
## truncated writer. CCP-6 names that cost in advance and makes the distinct diagnosis the
## deliverable rather than a nicety. `unNegotiatedDiagnosis` below is that diagnosis,
## written ONCE for the same reason CCP-5's `compact_residency_refusal` is written once in
## the db-backend: three doors onto one condition must not drift into three descriptions
## of it.
##
## ## AND THE DIAGNOSIS CANNOT COME FROM THE BYTES — MEASURED
##
## This is the structural fact the design rests on, and it is easy to assume otherwise
## because every other compression format in reach has a signature:
##
##   | scheme | first bytes |
##   |---|---|
##   | gzip   | `1f 8b` |
##   | zstd   | `28 b5 2f fd` |
##   | xz     | `fd 37 7a 58 5a 00` |
##   | **brotli** | **nothing — there is no magic number** |
##
## Measured on a real archive: the brotli stream of the chain-health subject begins
## `81 fa 7f 09 00 8f c2 b8`, which carries no signature at all, and a different input
## begins differently. So "are these bytes a brotli stream?" is not answerable by
## inspection — only by trying to decode them.
##
## That is the whole argument for `Content-Encoding` being OBJECT METADATA and for the
## manifest carrying `container.encoding` beside it. Over HTTP the header answers the
## question. Over a file read there is no header, so the manifest is the only thing that
## can, and a kit without it is left guessing from an absent CTFS magic — which is exactly
## the "malformed container" misdiagnosis CCP-6 forbids.
##
## ## WHY THIS MODULE IS PURE, AND IT IS A BOUNDARY AND NOT A STYLE
##
## It contains the ENUM, the PARSER, the magic test and the DIAGNOSES, and no codec. The
## codec lives in `publish/encoding.nim`, which shells out to `brotli`.
##
## The split is forced, and finding that out changed the design. `blocktracer-client-conformance`
## reaches its bytes through the Client SDK, whose boundary is enforced by name
## (`ci/test/client-sdk-boundary.sh`): `osproc` is a FORBIDDEN module in that graph —
## "spawns processes — an embeddable library cannot" — and so is everything under
## `src/blocktracer/publish/` ("the publisher — writing of any kind is excluded"). So the
## consumer-side kit **cannot decompress, by construction**, and no amount of care in this
## module would let it.
##
## That is not a gap, it is the correct answer, and it is why `storedBytes` / `storedHash`
## are on the manifest at all: the object AT REST is verifiable by length and sha1 with no
## codec whatsoever, so a consumer that cannot decode still reaches a VERDICT about the
## bytes in front of it rather than a skip. The stronger claim — that the DECOMPRESSED
## bytes are the container the manifest describes — needs a decoder, and where there is
## none it is reported as NOT MEASURED with its reason. Never a pass.
##
## AND THE DECODER IS NOT ABSENT FROM THE KIT, ONLY FROM THE PACKAGE, which is the
## distinction the boundary is actually drawing. `store.nim`'s read path is one closure
## whose entire input is a path, and the closure is the CONSUMER'S — so
## `verify/negotiating_store` gives the kit the same thing a browser's transport gives a
## page, outside the SDK, and the SDK is handed the raw container either way. What the
## SDK cannot do is know WHICH representation arrived: a browser negotiates, a plain file
## read does not, and nothing in the response says which. So `conformance.nim` decides
## from the bytes against the manifest's two sets of figures rather than assuming one —
## the first version assumed the at-rest bytes and reported a browser's correct fetch as
## a length mismatch.
##
## ## THE THREE FIGURES ARE THREE FIGURES
##
## `container.bytes` / `container.hash` keep their existing meaning: **the raw container,
## as the loader sees it.** `container.storedBytes` / `storedHash` are the **object at
## rest**. Conflating "at rest", "on the wire" and "as the loader sees it" is how a 10x and
## a 21% came to be conflated in the campaign that opened this, so they are separate fields
## with separate names, and all three stored-* fields are omitted entirely under identity —
## so a tree published without pre-compression is byte-identical to one published before
## they existed.

type
  ContainerEncoding* = enum
    ## The closed set, and it is closed for CCP-1 §1c's reason: a reader that falls back,
    ## guesses, or treats an unknown encoding as `identity` is the defect the refusal rule
    ## exists to prevent. `parseContainerEncoding` refuses an unknown value BY NAME.
    ##
    ## The spelling of each is the HTTP `Content-Encoding` token and not a name of our own,
    ## because the string goes into object metadata and a second spelling of one state is
    ## the `max_shards` defect in prose.
    ceIdentity = "identity"
      ## Stored raw. The object at rest IS the container. No `Content-Encoding` is set and
      ## the manifest carries no encoding field, so a tree published this way is
      ## byte-identical to one published before CCP-6.
    ceBrotli = "br"
      ## Stored pre-compressed with brotli. The object at rest is a brotli stream, the
      ## object metadata carries `Content-Encoding: br`, and a negotiating consumer —
      ## every browser, `curl --compressed` — receives the container.

const
  CtfsMagic* = "\xc0\xde\x72\xac\xe2"
    ## The five bytes every CTFS container begins with. Used ONLY to tell "this is a
    ## container" from "this is something else"; the version byte that follows is the
    ## format reader's business and not this module's.

proc parseContainerEncoding*(s: string): tuple[enc: ContainerEncoding, ok: bool, why: string] =
  ## The closed set, with an unknown value REFUSED BY NAME rather than defaulted.
  ##
  ## The permissive-default parser is a defect this workspace has now met three times — in
  ## `container.nim`'s `readCompressionMethod`, in `deploy-gate-decide.mjs` with an unset
  ## repository variable, and in `ctfs-measure`'s `is_direct` heuristic. The EMPTY string is
  ## `identity` and that is NOT one of them: the field's PRESENCE is what records that
  ## compression happened, so its absence can only mean it did not.
  if s.len == 0: return (ceIdentity, true, "")
  for e in ContainerEncoding:
    if $e == s: return (e, true, "")
  (ceIdentity, false,
   "container encoding '" & s & "' is not one this build implements (known encodings: " &
   ($ceIdentity) & ", " & ($ceBrotli) & "). Refusing rather than reading it as '" &
   $ceIdentity & "': an unknown encoding read as identity is compressed bytes parsed as a " &
   "container, which is the one failure mode that does not announce itself")

func looksLikeContainer*(bytes: string): bool =
  ## Do these bytes BEGIN as a CTFS container? Not "are they a valid container" — that is
  ## the format reader's verdict, and this is the one piece of evidence available without
  ## one.
  bytes.len >= CtfsMagic.len and bytes[0 ..< CtfsMagic.len] == CtfsMagic

func noDecoderReason*(who: string): string =
  ## Why a particular consumer cannot decode, said in that consumer's own terms.
  ##
  ## Two callers and two different sentences, because the REMEDIES differ and a shared
  ## "install brotli" would be wrong for one of them: the Client SDK's inability is
  ## structural and permanent, and telling someone to install a decoder for it sends them
  ## in a circle — which is the mistake `chain-health-selftest.mjs` records having made when
  ## it told an operator to build a reader that was already built.
  who & " holds no decompressor and cannot acquire one: obtain the object with encoding " &
  "negotiation instead — every browser does this, and so does `curl --compressed` — which " &
  "yields the container itself and needs no decoder here"

proc unNegotiatedDiagnosis*(what: string, enc: ContainerEncoding,
                            got, storedBytes, rawBytes: int): string =
  ## THE DIAGNOSIS, WRITTEN ONCE. CCP-6: "a kit that silently accepted compressed bytes as a
  ## malformed container would report a format defect that does not exist", and the distinct
  ## diagnosis is the deliverable rather than a nicety.
  ##
  ## It says four things, and each is here because the version without it sends a reader
  ## somewhere wrong:
  ##   1. WHAT the bytes are — pre-compressed, with the scheme named;
  ##   2. that this is not a defect in the container, so nobody looks for a truncated writer;
  ##   3. the two byte figures side by side and LABELLED, so `got` is recognisable as the
  ##      at-rest figure rather than read as a short container;
  ##   4. the REMEDY, which is to negotiate or to decompress — and never "re-record".
  "the object at " & what & " is stored PRE-COMPRESSED with Content-Encoding '" & $enc &
  "' and these bytes have not been decompressed, so they are not a container and must not " &
  "be read as a malformed one. Read " & $got & " byte(s); the manifest declares " &
  $storedBytes & " byte(s) at rest and " & $rawBytes & " byte(s) of container as a loader " &
  "sees it. Nothing is wrong with the archive. Obtain it with encoding negotiation — every " &
  "browser does this, and so does `curl --compressed` — or decompress it explicitly " &
  "(`brotli -d`). Re-recording it would change nothing"

proc identityButDeclaredEncodedDiagnosis*(what: string, enc: ContainerEncoding): string =
  ## The MIRROR of the above, and it is a different defect with a different remedy: the
  ## manifest says the object is stored under an encoding and the object at rest is a plain
  ## container, so the PUBLICATION did not do what it recorded.
  ##
  ## Without an arm for it the condition is invisible — the bytes parse, every length
  ## matches, and the only thing wrong is a field. What it costs is real: a consumer that
  ## negotiates asks for the encoding, is handed identity bytes under a header claiming
  ## otherwise, and fails in its transport layer rather than here.
  "the manifest declares Content-Encoding '" & $enc & "' for the object at " & what &
  " and the bytes at rest are a plain CTFS container. The publication recorded an encoding " &
  "it did not apply, so a consumer that negotiates will receive identity bytes under a " &
  "header claiming '" & $enc & "'. This is a publication defect, not a container defect"
