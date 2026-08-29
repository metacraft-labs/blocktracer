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
  result.activeIndex = 0
  result.currentLine = currentLine
  let docs = payload{"documents"}
  if docs == nil or docs.kind != JArray: return result
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
      currentLine = (if path == currentPath: currentLine else: 0))
    if path == currentPath: result.activeIndex = index
    inc index
  # The pane opens on the file the session is IN. Falling back to the island's
  # own `activeIndex` would be worse than the default: it records where the
  # STATIC export opened, and after a step into another file that is a document
  # the session has left.
  if currentPath.len == 0:
    result.activeIndex = payload{"activeIndex"}.getInt(0)
