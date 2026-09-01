## The source bundle, carried in the page as **data**, so hydration can render
## a line the served window does not contain.
##
## ## The problem this exists for
##
## `pages/debug.nim` opens the editor pane at the session's position
## (`openAtCurrent`), which means the served DOM holds a WINDOW of each file and
## not the file. That is right for a page with no script: a complete 400-line
## listing whose current line is at 380 puts the one line that matters below the
## fold, and there is nothing to scroll it with.
##
## It is wrong the moment the session can move. The first backward step out of
## the served window asks for a line that is not in the document, and a
## hydration that could only rearrange the DOM it was given would have to either
## render the wrong line or stop — and stopping is exactly the "renders less
## than the pre-hydration page" §7.0 forbids.
##
## ## Why data and not a fetch
##
## §7.0 already specifies the served page as "pre-rendered, crawlable,
## **data-inlined** HTML". A second network round trip for text the page has
## already rendered once would also be the slower answer to a question that is
## only asked after a step, when Debugger-Integration §7 gives the whole
## navigation 50 ms.
##
## ## What is inlined, and what is not
##
## The raw text and the executed-line set — **not** the tokens. `SourceLine`
## carries a `seq[SourceToken]` per line and serialising those would roughly
## triple the island for information the client can recompute: the lexer is
## ordinary Nim and compiles to JavaScript with everything else here, so
## `decodeSourceIsland` calls `newSourceDocument`, the SAME producer the static
## export calls. That is the property worth having — the hydrated pane's
## highlighting is not a second implementation that agrees with the served one,
## it is the served one.
##
## Positions are deliberately absent. `currentLine` is what the ENGINE says and
## what hydration overwrites on every stop; inlining it would put a stale
## position in the page for the client to have to ignore.

import std/[json, strutils]
import ./session_view
import ./source_document

const SourceIslandId* = "bt-session-source"
  ## The element id the island is served under, shared by the writer in
  ## `pages/debug.nim` and the reader in the hydration bundle. One constant, so
  ## a rename cannot leave hydration looking for an element that no longer
  ## exists — which would fail SILENTLY, as "no island, so no hydration", and
  ## look exactly like a browser that cannot run the engine.

func documentText*(d: SourceDocument): string =
  ## The file, rejoined from the lines it was split into.
  ##
  ## Lossless for everything `splitSourceLines` produces: it splits on `\n`
  ## after folding CRLF and drops one trailing empty element, so joining with
  ## `\n` returns the text a re-split yields the same lines from. It does not
  ## return the original BYTES — a CRLF file comes back LF — and that is
  ## intended, because the lines are what is rendered and a round trip that
  ## preserved the carriage returns would put them inside the rendered text.
  var parts = newSeqOfCap[string](d.lines.len)
  for ln in d.lines: parts.add ln.text
  parts.join("\n")

proc encodeSourceIsland*(p: EditorPane): string =
  ## The island's JSON.
  ##
  ## `<` is escaped to `<` on the way out. The island is served inside a
  ## `<script type="application/json">`, whose content model is raw text with
  ## exactly one terminator — a literal `</script` anywhere in a source file
  ## would end the element early and spill the rest of the trace's source into
  ## the document as markup. Escaping every `<` is the blunt form of that fix
  ## and costs nothing here: it is still valid JSON, `JSON.parse` and Nim's
  ## `parseJson` both unescape it, and source code that contains no `<` pays
  ## nothing at all.
  var docs = newJArray()
  for d in p.documents:
    var executed = newJArray()
    for ln in d.lines:
      if ln.executed: executed.add newJInt(ln.number)
    docs.add %*{
      "path": d.path,
      "language": d.language,
      "firstLine": (if d.lines.len > 0: d.lines[0].number else: 1),
      "text": documentText(d),
      "executed": executed,
    }
  let payload = %*{
    "availability": $p.availability,
    "reason": p.reason,
    # Carried, because an instruction listing without it is a grid of hex whose
    # columns nobody named. It is a derived string and could be recomputed — but
    # only by re-deriving the listing, and the listing is exactly what the island
    # exists to avoid re-deriving. Two bytes-per-page against a pane that
    # silently loses its own caption on the first step is not a trade.
    "listingCaption": p.listingCaption,
    "activeIndex": p.activeIndex,
    "documents": docs,
  }
  ($payload).replace("<", "\\u003c")

func availabilityFromWire*(s: string): SourceAvailabilityView =
  ## The enum's own spelling, back. Total by construction: an unrecognised
  ## value becomes `srcAbsent`, which is the state that shows no code and says
  ## so — the safe direction for a value the page did not understand, because
  ## the alternative is a pane that presents whatever it has as verified
  ## source.
  case s
  of "sourceLevel": srcSourceLevel
  of "unverified": srcUnverified
  else: srcAbsent

func normalisedPath*(p: string): string =
  ## One spelling of a path, for comparison only — never for display.
  ##
  ## Separators to `/`, and a leading `./` dropped. Nothing else: this is not a
  ## resolver, it does not touch `..`, and it must not, because the two sides
  ## being compared come from different machines and `..` cannot be collapsed
  ## without knowing which one's filesystem to collapse it against.
  result = newStringOfCap(p.len)
  for ch in p:
    result.add(if ch == '\\': '/' else: ch)
  if result.len >= 2 and result[0] == '.' and result[1] == '/':
    result = result[2 .. ^1]

func positionDocumentIndex*(paths: openArray[string]; positionPath: string): int =
  ## Which published document the engine's position is in, or -1 for none.
  ##
  ## ## Why this is not `==`
  ##
  ## It was, and the consequence was that a hydrated session marked NO line,
  ## ever. The two sides are the same file named by two different producers:
  ##
  ##   the engine     `/private/tmp/blocktracer-fixture-rec/noir_space_ship/src/main.nr`
  ##   the bundle     `src/main.nr`
  ##
  ## The engine reports the path the program was RECORDED at, which is absolute
  ## and belongs to the machine that ran it; the published bundle stores paths
  ## relative to the package root, because that is the only form that survives
  ## being served to someone else. `==` between them is false for every file in
  ## every session, so `decodeSourceIsland`'s `matched` was permanently false.
  ##
  ## That went unnoticed because the PREVIOUS fix in this file made the
  ## unmatched branch safe: an unmatched position clears `currentLine` rather
  ## than carrying it onto the wrong document. So the pane stopped marking the
  ## wrong line and started marking none, which is correct behaviour for a file
  ## the bundle genuinely does not carry — and indistinguishable, from inside
  ## this function, from the case where it carries it under another spelling.
  ## The safe fallback masked the broken comparison.
  ##
  ## ## The rule
  ##
  ## A document matches when its path is a trailing PATH-SEGMENT suffix of the
  ## position's path, or the reverse. `src/main.nr` matches
  ## `/…/noir_space_ship/src/main.nr`; `main.nr` does NOT match
  ## `/…/src/domain.nr`, because the boundary must fall on a `/`.
  ##
  ## Where several match, the LONGEST document path wins. This is the case that
  ## makes suffix matching safe rather than merely convenient: a bundle holding
  ## both `main.nr` and `src/main.nr` has two documents whose paths are suffixes
  ## of `/…/src/main.nr`, and the more specific one is the answer. Ties are
  ## impossible — two documents with the same normalised path are the same
  ## document — and are reported as no match rather than resolved arbitrarily,
  ## because marking a line in the wrong file is worse than marking none.
  result = -1
  if positionPath.len == 0: return
  let want = normalisedPath(positionPath)
  var bestLen = -1
  var tied = false
  for i, raw in paths:
    let have = normalisedPath(raw)
    if have.len == 0: continue
    let hit =
      have == want or
      (want.len > have.len and want.endsWith("/" & have)) or
      (have.len > want.len and have.endsWith("/" & want))
    if not hit: continue
    if have.len > bestLen:
      bestLen = have.len
      result = i
      tied = false
    elif have.len == bestLen:
      tied = true
  if tied: result = -1

proc decodeSourceIsland*(raw: string; currentPath: string; currentLine: int):
    EditorPane =
  ## The island, back into an `EditorPane` positioned wherever the ENGINE says.
  ##
  ## `currentPath` and `currentLine` come from the live session, not from the
  ## island — that is the whole point of the split. A document whose path is
  ## not `currentPath` is rebuilt with `currentLine = 0`, so exactly one line in
  ## the pane is ever marked current however many files the bundle has.
  ##
  ## A malformed island yields an empty pane rather than raising: the caller's
  ## contract is that a failed decode leaves the served DOM untouched, and a
  ## raise crossing the hydration entry point would abort the parts that had
  ## already succeeded.
  var payload: JsonNode
  try:
    payload = parseJson(raw)
  except CatchableError:
    return EditorPane()
  if payload.kind != JObject: return EditorPane()
  result.availability = availabilityFromWire(payload{"availability"}.getStr(""))
  result.reason = payload{"reason"}.getStr("")
  result.listingCaption = payload{"listingCaption"}.getStr("")
  result.activeIndex = 0
  result.currentLine = currentLine
  let docs = payload{"documents"}
  if docs == nil or docs.kind != JArray: return result

  # The position is resolved against the WHOLE document list before any document
  # is built, because the rule is "the longest matching path wins" and that
  # cannot be decided one document at a time. The previous per-document `==`
  # could, which is exactly why it was written that way and why it was wrong.
  var paths: seq[string]
  for d in docs: paths.add d{"path"}.getStr("")
  let positionIndex = positionDocumentIndex(paths, currentPath)
  let matched = positionIndex >= 0

  var index = 0
  for d in docs:
    let path = d{"path"}.getStr("")
    var executed: seq[int]
    let ex = d{"executed"}
    if ex != nil and ex.kind == JArray:
      for n in ex: executed.add n.getInt(0)
    result.documents.add newSourceDocument(
      path, d{"language"}.getStr(""), d{"text"}.getStr(""),
      executed = executed,
      currentLine = (if index == positionIndex: currentLine else: 0),
      # THE ROW NUMBERS THE ISLAND PUBLISHED, not a fresh 1..N. This field has
      # always been written and was always dropped, which was harmless while
      # every island held whole source files numbered from 1. An instruction
      # listing's rows are numbered in the session's coordinate and start at 0,
      # so renumbering them would shift every row by one and mark the wrong
      # instruction on every stop.
      firstLine = d{"firstLine"}.getInt(1))
    inc index
  if matched:
    result.activeIndex = positionIndex
  # The pane opens on the file the session is IN. Falling back to the island's
  # own `activeIndex` would be worse than the default: it records where the
  # STATIC export opened, and after a step into another file that is a document
  # the session has left.
  if currentPath.len == 0:
    result.activeIndex = payload{"activeIndex"}.getInt(0)
  elif not matched:
    # The engine named a file this bundle does not carry. Two things follow, and
    # the second is the one that was missing.
    #
    # `activeIndex` falls back to the island's, because a document the static
    # export chose is a better guess than "index 0", which after the bundle's
    # sort is whatever path sorts first — a `Nargo.toml` rather than any code.
    #
    # And `currentLine` is CLEARED. It is a coordinate in a file that is not on
    # screen; carried onto a document it does not describe it marks the wrong
    # line, and — because `openAtCurrent` windows from `currentLine - lead` —
    # against a short manifest it keeps no lines at all and the pane renders
    # empty. A pane that cannot show the position says so by not marking one,
    # which is what an unpositioned pane already means everywhere else.
    result.activeIndex = payload{"activeIndex"}.getInt(0)
    result.currentLine = 0

proc islandAvailability*(raw: string): SourceAvailabilityView =
  ## What FIDELITY the served island declares, without decoding the documents.
  ##
  ## THE ISLAND'S PRESENCE IS NOT THE ANSWER, and it was read as one. Hydration
  ## used to open its session with `sourceIsPublished = island.len > 0`, which
  ## was exact while only a source-level pane had documents to serialise. It
  ## stopped being exact the moment an instruction-level pane got rows of its
  ## own: a chain session now inlines a listing of program counters, and the
  ## presence test would have told the store `savVerified` about it — so the
  ## live pane would have joined the engine's position by FILE AND LINE against
  ## a document whose rows are step ordinals, and presented the result as source.
  ##
  ## The island carries the answer explicitly, so it is read explicitly. A
  ## payload that will not parse is `srcAbsent`, the same safe direction
  ## `availabilityFromWire` takes for a value it does not recognise: the
  ## alternative is presenting whatever arrived as verified source.
  if raw.len == 0: return srcAbsent
  var payload: JsonNode
  try:
    payload = parseJson(raw)
  except CatchableError:
    return srcAbsent
  if payload.kind != JObject: return srcAbsent
  availabilityFromWire(payload{"availability"}.getStr(""))
