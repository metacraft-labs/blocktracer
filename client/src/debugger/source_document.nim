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
                        currentLine: int = 0;
                        firstLine: int = 1): SourceDocument =
  ## One file, ready to render.
  ##
  ## `executed` is the set of line numbers the trace visited, and `currentLine`
  ## the line the session sits on. Both default to "nothing known", which is
  ## exactly the pre-hydration frame: the file renders, and nothing claims to be
  ## executing.
  ##
  ## `firstLine` is WHAT THE FIRST ROW IS CALLED, and it defaults to 1 because a
  ## file's first line is line 1. It exists because an instruction listing's rows
  ## are not lines: they are numbered in the session's own coordinate, which
  ## starts at 0 (`instruction_listing.nim`). The source island publishes it
  ## already — `encodeSourceIsland` has always written `firstLine` — and until
  ## this parameter the decoder dropped it and renumbered every row from 1, which
  ## would have moved every row of a rebuilt listing one place and put the
  ## position mark on the wrong instruction after the first step.
  var hit = initTable[int, bool]()
  for n in executed: hit[n] = true
  result.path = path
  result.language = language
  let lines = splitSourceLines(text)
  # The whole file at once, not line by line: a block comment spans lines, so
  # the lexer has to carry state between them. `highlightLines` returns one
  # token seq per line — or NOTHING at all, when no profile covers `language`.
  let tokens = highlightLines(lines, profileForDocument(path, language))
  # The token seqs are indexed by POSITION in the file and the row numbers are
  # not: `firstLine` may start them anywhere, including at 0. Indexing the
  # tokens by the row NUMBER worked only while the two were the same thing, and
  # would read `tokens[-1]` on the first row of a listing.
  for i, text in lines:
    let n = firstLine + i
    result.lines.add SourceLine(
      number: n,
      text: text,
      anchor: lineAnchor(path, n),
      executed: hit.getOrDefault(n, false),
      current: n == currentLine,
      tokens: (if i < tokens.len: tokens[i] else: @[]))

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

## ## THE SESSION PANE SHOWS THE WHOLE FILE — the lead-in window is GONE
##
## `SourceLeadIn = 6` and `openAtCurrent` used to stand here. They narrowed the
## active document to start six lines above the current line and run to the end
## of the file, and `renderSource` announced the reduction: *"Showing from line
## 71 — the session's position is below, and the lines above it are not in this
## window."* Both `pages/debug.nim` and `hydrate/hydrate.nim` applied it, so a
## visitor on `loops and iteration` — an 83-line program whose `main` is at line
## 77 — was shown thirteen lines and none of the four functions `main` calls.
##
## THE REASON IT WAS THERE, in its own words:
##
##   "The pane has no JavaScript to scroll with: a document rendered from line 1
##   puts the current line wherever the file happens to put it, and at the
##   `laptop` viewport the fixture's line 32 falls below the fold entirely — the
##   pane renders a file, the toolbar claims a step, and nothing on screen
##   connects them."
##
## That was true, and it is worth being clear that it was never about size or
## memory. It is a claim about SCROLLING, and it is a claim about A BUILD — the
## exact species of reasoning `AGENTS.md` §1b already warns about ("an
## explanation naming a mechanism is a claim about an artefact"), and it went
## wrong here in the same way it went wrong for the `Supply sources` copy:
##
##   * `just export` writes `client/dist` with zero JavaScript. That IS the tree
##     the capture harness photographs, and on it the premise held.
##   * `flake.nix packages.default` — what CI builds and deploys, and therefore
##     what a visitor loads — exports with `-d:hydrationBundle=/assets/hydrate.js`,
##     and every debugger route carries it. `hydrate.scrollToCurrentLine` has
##     moved the pane to the position on every render since hydration landed;
##     its own comment says so: "There is now, so the window can stay generous
##     and the pane can be moved instead."
##
## And the no-JavaScript build does not need the window either, because a pane
## can be opened at a row with no script at all: the current row carries
## `tabindex="-1"` and `autofocus`, and the browser scrolls a focused element
## into view before it paints. See `components/debugger.renderSource`. That is
## strictly better than dropping lines — the reader lands on the position AND
## can scroll up to the rest of the program.
##
## WHAT THE WINDOW WAS SAVING, measured rather than assumed — and it is not
## nothing, so here is the number:
##
##   * NOT ONE BYTE OF SOURCE TEXT. `pages/debug.nim` encodes
##     `#bt-session-source` from the COMPLETE documents, deliberately and before
##     the window was taken, so hydration can step outside it. On the demo
##     session that island is 5.6 KB and carries every one of `shield.nr`'s 67
##     lines. Every line the window hid was already downloaded.
##   * WHAT IT SAVED WAS ROW MARKUP, and the whole `just export` tree was
##     measured either side of this commit: the 27 debug pages go 7,000,823 ->
##     7,396,065 bytes, +395,242 in total and +5.6%. The demo session's page is
##     290,565 -> 316,386 (+25,821, +8.9%, 108 -> 133 rows); the widest chain
##     listing is 280,105 -> 308,009 (+27,904, +10.0%, 216 -> 338 rows).
##   * AND THAT IS THE WRONG PRICE TO PAY. 26 KB is 2% of the 1.33 MB hydration
##     bundle the same page fetches, and 0.1% of the 18 MB replay engine behind
##     it. What it bought was hiding 70 of an 83-line program, including all
##     four functions the visible `main` calls.
##   * the corpus a size bound would have to protect against does not exist
##     either. All 24 Noir files in `fixtures/` total 49.7 KB; the largest
##     single file is `tour/mutation/src/main.nr` at 132 lines / 5.4 KB, against
##     a ~140 KB container per transaction. The widest listing in the eight
##     published chain captures is 338 rows.
##
## A LARGER LEAD-IN WOULD HAVE BEEN THE SAME DEFECT WITH A HIGHER THRESHOLD, so
## the bound is removed rather than widened: any number picked here is a number
## some file is longer than, and the reader who hits it gets exactly the report
## that produced this comment.
##
## `windowAround` below is NOT this and stays. It serves the home page's
## embedded session, which is a fixed-height box with no scrollbar to reach the
## position with, and it keeps the banner that says what it did — an honest
## announced reduction, which is the part this pane got right.

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
  if pane.availability == srcAbsent or pane.documents.len == 0: return
  let doc = activeDocument(pane)
  if pane.currentLine <= 0: return
  var window = SourceDocument(path: doc.path, language: doc.language)
  for ln in doc.lines:
    if ln.number >= pane.currentLine - radius and
       ln.number <= pane.currentLine + radius:
      window.lines.add ln
  result.documents = @[window]
  result.activeIndex = 0
