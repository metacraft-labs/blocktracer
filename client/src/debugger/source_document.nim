## Turning source text into the lines the editor pane renders.
##
## BlockTracer had no source rendering of any kind before this module, so the
## decisions worth stating are the ones that are cheap now and expensive later.
##
## **A line's identity does not come from its position in the render.** Every
## `SourceLine` carries an `anchor` derived from `(path, lineNumber)` — see
## `session_view.lineAnchor`. Deep links, the `?t=` position, a future
## breakpoint gutter and, above all, the inline value overlays CodeTracer's
## omniscience shows all need to address one line and keep addressing it after
## the pane re-renders with a different window of the file. An index into a
## `seq` cannot do that; a content-derived id can.
##
## **Syntax highlighting is tokenised HERE, at static-export time.** The seam
## this module reserved — one text node per line inside a `<code>` — has been
## filled exactly as described: `source_highlight.highlightLines` partitions
## each line into classified spans, the spans travel on `SourceLine.tokens`, and
## the renderer emits them. Nothing above moved. The dependency the explorer
## refused (Monaco, Shiki, tree-sitter-wasm) is still refused: the page ships no
## JavaScript, so the lexer is Nim and runs during `nim c -r static_export.nim`.
##
## **A language without a profile is rendered plain, never guessed at.**
## `newSourceDocument` takes the language as a string and asks
## `source_highlight.profileFor` for it; an unknown language yields no tokens and
## the renderer falls back to the single text node. Applying Noir's lexer to a
## Solidity file — or to the bytecode listing an instruction-level session
## shows — would produce confident nonsense, which is worse than plain text
## because it is wrong in a way that looks authoritative.
##
## **Executed-line marking is data, not a heuristic.** `newSourceDocument` takes
## the set of line numbers the trace visited. A pane that guessed — highlighting
## every non-blank line, say — would be indistinguishable from a correct one on
## a screenshot and wrong on every trace.

import std/[strutils, tables]
import ./session_view
import ./source_highlight

func splitSourceLines*(text: string): seq[string] =
  ## Split on newlines, tolerating CRLF and a trailing newline.
  ##
  ## A file ending in `\n` has N lines, not N+1: `splitLines` yields a final
  ## empty element that would render as a phantom line at the bottom of every
  ## file. Dropping it here rather than in the renderer keeps the line count
  ## right for everything downstream — including the executed-line set, which
  ## is indexed by the same numbers.
  result = text.replace("\r\n", "\n").split('\n')
  if result.len > 0 and result[^1].len == 0:
    result.setLen(result.len - 1)

proc newSourceDocument*(path, language, text: string;
                        executed: seq[int] = @[];
                        currentLine: int = 0): SourceDocument =
  ## One file, ready to render.
  ##
  ## `executed` is the set of 1-based line numbers the trace visited, and
  ## `currentLine` the line the session sits on. Both default to "nothing
  ## known", which is exactly the pre-hydration frame: the file renders, and
  ## nothing claims to be executing.
  var hit = initTable[int, bool]()
  for n in executed: hit[n] = true
  result.path = path
  result.language = language
  let lines = splitSourceLines(text)
  # The whole file at once, not line by line: a block comment spans lines, so
  # the lexer has to carry state between them. `highlightLines` returns one
  # token seq per line — or NOTHING at all, when no profile covers `language`.
  let tokens = highlightLines(lines, profileForDocument(path, language))
  var n = 0
  for text in lines:
    inc n
    result.lines.add SourceLine(
      number: n,
      text: text,
      anchor: lineAnchor(path, n),
      executed: hit.getOrDefault(n, false),
      current: n == currentLine,
      tokens: (if n <= tokens.len: tokens[n - 1] else: @[]))

proc annotate*(doc: var SourceDocument; line: int; ann: LineAnnotation) =
  ## Attach a value overlay to a line.
  ##
  ## Nothing this milestone ships calls it: the overlays are a later
  ## workstream. It exists, and is exercised by the route's test suite, because
  ## the claim being made is that the overlays can be added *without
  ## restructuring* — and the only way to make that claim checkable now is to
  ## have the attachment path work now.
  for i in 0 ..< doc.lines.len:
    if doc.lines[i].number == line:
      doc.lines[i].annotations.add ann
      return

func documentIndex*(pane: EditorPane; path: string): int =
  ## Which document in the pane has this path, or -1.
  result = -1
  for i, d in pane.documents:
    if d.path == path: return i

proc markExecuted*(pane: var EditorPane; executed: Table[string, seq[int]]) =
  ## Apply the trace's executed-line set to whatever documents the pane holds,
  ## keyed by the path the container interns.
  ##
  ## Separate from `newSourceDocument` because the set belongs to the **trace**
  ## and not to the copy of the file being rendered. The same lines executed
  ## whether the text arrived in a published source bundle or came from the
  ## files vendored beside the client — the bundle's layout under `src/` has to
  ## match the interned paths or a step resolves to no source line at all, so
  ## the two are the same coordinates by construction.
  ##
  ## Without this, a pane whose documents were replaced by a bundle would
  ## silently render a session that never ran: every gutter marker gone, and no
  ## error anywhere, which is precisely the failure a marker computed from the
  ## text rather than from the trace would also produce.
  for i in 0 ..< pane.documents.len:
    let hits = executed.getOrDefault(pane.documents[i].path, @[])
    var hit = initTable[int, bool]()
    for n in hits: hit[n] = true
    for j in 0 ..< pane.documents[i].lines.len:
      pane.documents[i].lines[j].executed =
        hit.getOrDefault(pane.documents[i].lines[j].number, false)

proc focus*(pane: var EditorPane; path: string; line: int) =
  ## Point the pane at a file and a line, marking that line current and
  ## clearing any previous current line — including one in another document,
  ## which is the case a `for` loop over the active document alone gets wrong.
  let idx = documentIndex(pane, path)
  if idx < 0: return
  pane.activeIndex = idx
  pane.currentLine = line
  for d in 0 ..< pane.documents.len:
    for i in 0 ..< pane.documents[d].lines.len:
      pane.documents[d].lines[i].current =
        d == idx and pane.documents[d].lines[i].number == line

const SourceLeadIn* = 6
  ## How many lines of context the source pane opens ABOVE the current line.
  ##
  ## Enough to see the statement in its block, few enough that the current line
  ## is on screen at the shortest viewport this route is served at. See
  ## `openAtCurrent` below for why a lead-in and not a centred window.
  ##
  ## It lives HERE, beside `openAtCurrent`, because it is read by two
  ## compilations that must agree: `pages/debug.nim` windows the served pane
  ## with it, and `hydrate/hydrate.nim` re-windows the hydrated pane with it on
  ## every stop. Those two are the same pane at the same position, and the
  ## whole claim that hydration renders the markup the export rendered rests on
  ## them windowing identically.
  ##
  ## It was briefly a private `const` restated in both files. That is a drift
  ## surface with no guard — the renderers are shared by import, so they cannot
  ## diverge, but a windowing PARAMETER copied into two modules can, and a
  ## served page and a hydrated pane that disagree by two lines would be a
  ## silent difference in exactly the thing this route promises is the same.
  ## One definition removes the possibility rather than testing for it.

proc openAtCurrent*(pane: EditorPane; lead: int = SourceLeadIn): EditorPane =
  ## The active document narrowed to start `lead` lines ABOVE the current line
  ## and run to the end of the file. Other documents are kept, untouched.
  ##
  ## This is what makes the full session *positioned* rather than merely
  ## loaded, and it is a correctness fix rather than a nicety. The pane has no
  ## JavaScript to scroll with: a document rendered from line 1 puts the
  ## current line wherever the file happens to put it, and at the `laptop`
  ## viewport the fixture's line 32 falls below the fold entirely — the pane
  ## renders a file, the toolbar claims a step, and nothing on screen connects
  ## them. Four of six reviewers in VD.5's first round independently reported
  ## the missing indicator as a presence failure, at `laptop` and not at
  ## `wide`, which is exactly the signature of a position that is rendered but
  ## off-screen.
  ##
  ## A LEAD-IN rather than a centred window: `lead` lines of context above
  ## guarantees the current line lands in row `lead + 1` at every viewport,
  ## however short the pane is, where a centred window only guarantees it for
  ## panes taller than the window. Opening on the current statement with a few
  ## lines above it is also what the desktop app does, so the continuity is
  ## with CodeTracer rather than with a file viewer.
  ##
  ## The lines above the lead-in are DROPPED, not hidden, and `renderSource`
  ## says so on the pane — Page-Descriptions §13's rule that a reduction is
  ## announced rather than silent applies to a reduction in a pane just as it
  ## does to one at a viewport.
  result = pane
  if pane.availability != srcSourceLevel or pane.documents.len == 0: return
  if pane.currentLine <= 0: return
  let idx = (if pane.activeIndex >= 0 and pane.activeIndex < pane.documents.len:
               pane.activeIndex else: 0)
  let first = max(1, pane.currentLine - lead)
  if first == 1: return
  var window = SourceDocument(path: pane.documents[idx].path,
                              language: pane.documents[idx].language)
  for ln in pane.documents[idx].lines:
    if ln.number >= first: window.lines.add ln
  result.documents[idx] = window

proc windowAround*(pane: EditorPane; radius: int): EditorPane =
  ## The active document narrowed to `radius` lines either side of the current
  ## line, other documents dropped.
  ##
  ## For the home page's embedded session, which has no scrollbar to reach the
  ## position with and must open ON it — "evidence that it is already stepping",
  ## as the review brief puts it. Line numbers and anchors are UNCHANGED by the
  ## narrowing, which is the property the anchors exist for: the same line has
  ## the same id in the embed and in the full session, so a link out of one
  ## lands in the other.
  result = pane
  if pane.availability != srcSourceLevel or pane.documents.len == 0: return
  let doc = activeDocument(pane)
  if pane.currentLine <= 0: return
  var window = SourceDocument(path: doc.path, language: doc.language)
  for ln in doc.lines:
    if ln.number >= pane.currentLine - radius and
       ln.number <= pane.currentLine + radius:
      window.lines.add ln
  result.documents = @[window]
  result.activeIndex = 0
