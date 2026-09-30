## The source bundle, carried in the page as **data**, so hydration can render
## a line the served window does not contain.
##
## ## THE PROBLEM THIS WAS WRITTEN FOR NO LONGER EXISTS
##
## This section used to read: `pages/debug.nim` opens the editor pane at the
## session's position (`openAtCurrent`), so the served DOM holds a WINDOW of each
## file and not the file; the first backward step out of that window asks for a
## line the document does not contain, and a hydration that could only rearrange
## the DOM it was given would have to render the wrong line or stop.
##
## `SourceLeadIn` and `openAtCurrent` are GONE from the whole repository —
## `source_document.nim` carries the full account of why and what was measured —
## and `components/debugger.renderSource` emits every line of EVERY document,
## the active one and each alternate. There is no window for a step to fall out
## of, so the argument above is dead and is not being restated in a weaker form.
##
## ## WHAT IS STILL TRUE, AND IT IS A SMALLER CLAIM
##
## The island carries the source as DATA — raw text, the executed-line set and
## the pane's declared availability — which `decodeSourceIsland` feeds to
## `newSourceDocument`, the SAME producer the static export calls. Hydration
## therefore rebuilds documents rather than reconstructing them from rendered
## markup, and `session_project`'s live branch and `islandAvailability` both read
## it. That is a real property; it is NOT the same argument as the one above, and
## whether it alone justifies inlining the whole corpus of a session's files has
## not been re-argued since the window was removed.
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

const NoRow* = -1
  ## A `currentLine` that no row of any document can equal.
  ##
  ## Source files are numbered from 1 and an instruction listing's rows from 0,
  ## so the two kinds of document disagree about which value means "nothing here
  ## is current" — and a pane can now hold both at once. This is below both.

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
    # THE ATTRIBUTION MARKS TRAVEL WITH THE EXECUTED SET, and they have to.
    #
    # `demo_session.markCompilerAttributed` marks the lines whose position is
    # where the COMPILER keyed the code rather than somewhere the recording
    # proves the execution reached, and it derives them from the per-step
    # position stream and the call frames — `positions.json` and
    # `calltrace.json`, neither of which is in the page. So a hydrated pane
    # cannot re-derive them, exactly as it cannot re-derive `positionedSteps`
    # one field down, and for the same consequence: the `?` marks and the
    # sentence explaining them would appear on the SERVED page and vanish on the
    # first step. One renderer, two artefacts, and the caveat missing from the
    # half where a visitor actually moves — which is this module's own recorded
    # defect, twice over, and would be a third time.
    #
    # A line-number list rather than a flag per line, for `executed`'s reason:
    # it is sparse (4 lines of 288 KB of source on the recording that has any),
    # and an island that predates the field decodes to an empty list, which is
    # "nothing is claimed" and not "nothing is marked wrong".
    var attributed = newJArray()
    for ln in d.lines:
      if ln.executed: executed.add newJInt(ln.number)
      if ln.compilerAttributed: attributed.add newJInt(ln.number)
    docs.add %*{
      "path": d.path,
      "language": d.language,
      "firstLine": (if d.lines.len > 0: d.lines[0].number else: 1),
      "text": documentText(d),
      "executed": executed,
      "compilerAttributed": attributed,
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
    # THE COVERAGE, FOR THE SAME REASON THE CAPTION IS HERE AND FOR ONE MORE.
    #
    # `renderSource` draws the `.srcrung` header — §5's visible transition, "the
    # pane's header … so the user is never confused about why names disappeared"
    # — from these two counts, and a pane rebuilt without them carries `0 / 0`
    # and draws no header at all. That would put the boundary on the SERVED page
    # and lose it on the hydrated one: one renderer, two artefacts, and the
    # header missing from exactly the half where a reader can actually cross the
    # boundary by stepping. This module's own history has that defect in it
    # twice.
    #
    # They cannot be recomputed here either. They come from the recording's
    # per-step position stream (`demo_session.withSourcePositions`), which is
    # `positions.json` beside the container and is not in the page.
    "positionedSteps": p.positionedSteps,
    "positionedOf": p.positionedOf,
    # The sentence the `?` marks are explained by. Carried for the same reason
    # `listingCaption` is: it is derived, it cannot be recomputed without the two
    # sidecars, and a pane that keeps the marks and loses the explanation is
    # worse than one with neither.
    "attributionNote": p.attributionNote,
    # AND THE CAUSE OF THE STEPS WITH NO LINE, for the same reason and with the
    # same consequence if it were left out.
    #
    # It is folded from `native.replay.contractRungs` joined with
    # `native.replay.artifacts` — the transaction's MANIFEST, which is a separate
    # object the page does not carry — so a hydrated pane cannot recompute it any
    # more than it can recompute `positionedSteps`. Leaving it here would put the
    # ratio's explanation on the SERVED page and delete it on the visitor's first
    # step, which is precisely the defect this module has recorded twice and which
    # `attributionNote` was added one line up to avoid a third time.
    "coverageNote": p.coverageNote,
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
  # `0` for an island that predates the field, which is the same value a pane
  # whose text did not come from a per-step position stream carries — so an old
  # island decodes to "nobody established this" rather than to a coverage claim.
  result.positionedSteps = payload{"positionedSteps"}.getInt(0)
  result.positionedOf = payload{"positionedOf"}.getInt(0)
  result.attributionNote = payload{"attributionNote"}.getStr("")
  # `""` for an island that predates the field, which renders no caption at all —
  # the same state a pane whose transaction has one contract carries, and the
  # right direction for a value the page did not carry: no explanation is worse
  # than an explanation and better than an invented one.
  result.coverageNote = payload{"coverageNote"}.getStr("")
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
    var attributed: seq[int]
    let at = d{"compilerAttributed"}
    if at != nil and at.kind == JArray:
      for n in at: attributed.add n.getInt(0)
    result.documents.add newSourceDocument(
      path, d{"language"}.getStr(""), d{"text"}.getStr(""),
      executed = executed,
      # `NoRow` AND NOT `0` FOR THE DOCUMENTS THE POSITION IS NOT IN, and the
      # difference is a mark this shipped.
      #
      # `newSourceDocument` marks the row whose NUMBER equals `currentLine`, and
      # `0` meant "no row" only while every document was a source file numbered
      # from 1. An instruction listing's rows are numbered in the session's own
      # coordinate and start at 0, so a listing rebuilt as a NON-position
      # document had its first row marked — on every stop, in addition to the
      # source line the session was actually on. One pane, two `.srcline.cur`,
      # and the second one always claiming step 0.
      #
      # It could not arise while a pane held one kind of document: a listing was
      # the only document, so it was always the position's. It arose the moment
      # the ladder became a union and a pane held 32 Noir files AND the listing
      # (`demo_session.withListingBesideSource`). `-1` is below every row number
      # either kind of document can have, which `0` is not.
      currentLine = (if index == positionIndex: currentLine else: NoRow),
      # THE ROW NUMBERS THE ISLAND PUBLISHED, not a fresh 1..N. This field has
      # always been written and was always dropped, which was harmless while
      # every island held whole source files numbered from 1. An instruction
      # listing's rows are numbered in the session's coordinate and start at 0,
      # so renumbering them would shift every row by one and mark the wrong
      # instruction on every stop.
      firstLine = d{"firstLine"}.getInt(1))
    # …AND THE ATTRIBUTION MARKS BACK ONTO THE REBUILT ROWS.
    #
    # `newSourceDocument` takes `executed` as a parameter and has no parameter
    # for this, so it is applied here rather than threaded through a signature
    # every other caller would have to learn. Applied to the document just
    # added, by number, which is the same join the island uses for `executed`
    # and the same one a step uses to resolve to a line.
    if attributed.len > 0:
      let di = result.documents.len - 1
      for li in 0 ..< result.documents[di].lines.len:
        if result.documents[di].lines[li].number in attributed:
          result.documents[di].lines[li].compilerAttributed = true
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
    # line. (The stronger consequence this comment used to name — that
    # `openAtCurrent` windowing from `currentLine - lead` would keep no lines at
    # all against a short manifest and render the pane EMPTY — can no longer
    # happen: that proc is gone and the pane renders whole documents. What is
    # left is the wrong-line marking, which is reason enough.) A pane that cannot
    # show the position says so by not marking one, which is what an
    # unpositioned pane already means everywhere else.
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
