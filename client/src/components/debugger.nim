## The debug route's surface: the slim identity bar, the pane arrangement, and
## the six pane renderers.
##
## ## The arrangement is CodeTracer's MODEL, composed by BlockTracer
##
## `renderLayout` walks a `LayoutNode` — the type from the vendored copy of
## CodeTracer's `headless_app/layout_model.nim` — and turns it into markup:
##
##   `lnRow` / `lnColumn` → a flex container on that axis
##   `weight`             → a flex fraction, via a class from the weight ladder
##   `lnStack`            → tabs, one visible at a time
##   `lnPane`             → the pane renderer for that `PaneKind`
##
## Nothing here decides *what the arrangement is*. `session_layout
## .blockTracerReplayLayout()` decides that, over the same primitives and the
## same closed `PaneKind`. It used to be `defaultReplayLayout()` verbatim; that
## module stays byte-identical to CodeTracer's and the composition moved out of
## it, because the desktop app's default and a web session's default are two
## decisions and only one of them is ours to make. `session_layout.nim` carries
## the reasoning.
##
## `renderLayout` is total over `LayoutNodeKind` and over `PaneKind`, so a pane
## added to CodeTracer's enum is a compile error here rather than a blank
## region — which is the failure mode `GoldenLayoutResolvedConfig` has today
## and the reason `lpUnknownPane` exists in the model at all. Totality is also
## why `renderStack` survives an arrangement that places no stack: `lnStack` is
## a shape of the model, not a feature of BlockTracer's default, and a restored
## layout may still carry one.
##
## ## No layout engine, no drag, no persistence
##
## Weights become CSS flex fractions and the browser does the arithmetic. There
## is no measurement, no resize observer, no saved user layout, and no
## GoldenLayout. `stack` becomes `:target`-driven tabs, so switching a tab is a
## link — it works with no JavaScript at all, which is what lets the static
## route be the debugger's honest first frame rather than a placeholder for
## one.
##
## ## Why the metadata pane sits outside the walked tree
##
## Page-Descriptions §7.1 puts the transaction's metadata in the session "as a
## pane in the session, beside the debugger's own panes". `PaneKind` is
## CodeTracer's closed enum and has no member for it — deliberately: it
## enumerates the panes `SessionViewModel` owns, and a chain transaction is not
## one of them. Adding a value to the vendored copy would make it a fork rather
## than a copy and would fail `ci/test/layout-model-vendor.sh`.
##
## So the replay region is the walked tree and BlockTracer's own pane is
## composed beside it with the same pane chrome. `Debugger-Integration` §3
## licenses exactly this: "BlockTracer's contribution is which panes are open
## by default … and the three augmentations in §4."
##
## The debug controls make the same move in the opposite direction — a pane of
## `PaneKind` that BlockTracer renders OUTSIDE the tree, in the identity bar.
## `session_layout.ControlsArePlacedInTheBar` is where that is written down and
## `pages/debug.nim` is where it is done.

import std/strutils
import isonim/ssr/escape
import isonim/dsl/ui
import ../debugger/flow_view
import ../debugger/layout_model
import ../debugger/replay_engine
import ../debugger/session_view
# NOT `../viewutil`. These renderers are compiled TWICE — once by
# `static_export.nim` for the served HTML, and once by `nim js` for the
# hydration bundle, which is what makes the live session's markup the same
# markup by construction rather than by review. `viewutil` reaches
# `blocktracer_client` and `reader`, and therefore the filesystem, so importing
# it here would put a file reader on a browser bundle's import graph. The one
# symbol this module used from it, `truncHash`, now lives in `session_view`.

# ── weights → flex fractions ───────────────────────────────────────────────

const MaxWeight* = 12
  ## The weight ladder `debugger_css.nim` emits rules for.
  ## `blockTracerReplayLayout` uses 1, 2 and 3 and `defaultReplayLayout`
  ## uses 1, 2, 3 and 9; the ladder is wider so a change has room, and
  ## `weightClass` REFUSES a weight outside it rather than silently rendering
  ## the wrong proportions. A static export turns that refusal into a failed
  ## build, which is where a layout that cannot be rendered should surface.

proc weightClass*(w: float): string =
  ## `weight` → the class carrying its flex fraction.
  ##
  ## `0` means "equal share with the other zero-weighted siblings" (the model
  ## says so), which is a flex fraction of 1.
  let n = (if w <= 0.0: 1 else: int(w + 0.5))
  if float(n) != (if w <= 0.0: 1.0 else: w) or n > MaxWeight:
    raise newException(ValueError,
      "layout weight " & $w & " is not an integer in 1 .." & $MaxWeight &
      "; debugger_css.nim emits no flex fraction for it")
  "w" & $n

# ── pane chrome ────────────────────────────────────────────────────────────

proc paneChrome(title, id, cls, body: string; weight = 1.0): string =
  ## One pane: a header carrying its name, and a scrolling body.
  ##
  ## Every pane gets the same chrome — including the metadata pane, which is
  ## what makes §7.1's "a pane … rather than a bespoke surface" true of the
  ## markup and not only of the prose.
  ui:
    section(class = "pane " & cls & " " & weightClass(weight), id = id):
      header(class = "panehead"):
        span(class = "panetitle"): text title
      tdiv(class = "panebody"):
        raw body

proc paneNote(note: string): string =
  ## What a pane says when it has nothing to show. The review brief's
  ## anti-requirement is "Empty panes. A pane with nothing in it must say why,
  ## not sit blank", so there is no code path that renders an empty body.
  ui:
    p(class = "panenote"): text note

# ── copying a value out (§13: "every hash, address and identifier is copyable
#    with one click") ───────────────────────────────────────────────────────

const Copyable* = "copyable"
  ## The class that makes a machine value selectable **in one click**.
  ##
  ## ## Why this is a CSS affordance and not a button
  ##
  ## This page ships no JavaScript, and `navigator.clipboard.writeText` is the
  ## only way markup can put a string on the clipboard. A `<button>Copy</button>`
  ## here would therefore be a control that cannot succeed — the exact defect
  ## `panedismiss` and the inert `.ctsort` span were removed for, and one this
  ## surface has now made twice.
  ##
  ## `user-select: all` is the affordance that *does* work with scripting off:
  ## one click selects the whole value, and the platform's own copy gesture
  ## takes it from there. It is less than a copy button and it is not a lie
  ## about being one. `debugger_css.nim` gives it a hover treatment and a
  ## `cursor` so it is discoverable rather than a hidden behaviour.
  ##
  ## ## Where it is applied, and where it deliberately is not
  ##
  ## Only on values rendered **in full**: a frame name, an event label, a
  ## variable's value, an execution selector, a metadata identifier. A
  ## `user-select: all` on a value that is displayed TRUNCATED would select and
  ## copy `0xa45907…9296` — a string that is not the value and cannot be pasted
  ## anywhere useful. Truncated identifiers (`.dbgid`, `.mdhash`) therefore
  ## carry `title` and `data-copy` with the full value instead: the first makes
  ## it readable on hover today, the second is what hydration reads when it
  ## upgrades these into real one-click copy buttons.
  ##
  ## Source lines are not marked either, and that is a judgement rather than an
  ## omission: `user-select: all` on a line of code would make selecting a
  ## sub-expression impossible, and the line is already copyable — `.srcline .n`
  ## and `.srcline .m` are `user-select: none`, so a drag across the pane yields
  ## the code without the gutter, which is what a reader of code actually wants.
  ##
  ## ## The one thing a copy affordance must not do
  ##
  ## Copying must not launder a *deduced* value into a *verified* one. Where a
  ## value's provenance is in question the qualifier travels with it in the same
  ## row — the execution rows carry their availability badge and reason beside
  ## the selector, the identity bar carries `Reconstructed` beside the hash, and
  ## the source pane states `srcUnverified` before it shows anything. Nothing
  ## below marks a value copyable in a place where its qualifier is not already
  ## adjacent to it.

# ── the five replay panes ──────────────────────────────────────────────────

func tokenClass*(k: TokenKind): string =
  ## The CSS class for a lexical kind.
  ##
  ## Total over `TokenKind`, so a kind added to the lexer is a compile error
  ## here rather than an unstyled span. `debugger_css.nim` carries a rule for
  ## every class this returns, and `test_debug_route` checks that in both
  ## directions — the two files are the one place the mapping could drift, and
  ## a token whose class has no rule would render as unremarkable text while
  ## the lexer reported success.
  ##
  ## `tkPlain` is deliberately given no class: `renderSource` emits it as a bare
  ## text node, so returning one would create a class nothing uses.
  case k
  of tkPlain: ""
  of tkComment: "tk-comment"
  of tkKeyword: "tk-keyword"
  of tkType: "tk-type"
  of tkFunction: "tk-function"
  of tkString: "tk-string"
  of tkNumber: "tk-number"
  of tkPunctuation: "tk-punct"

# ── omniscience: the recorded values, beside the code ──────────────────────

proc renderAnnotations*(annotations: seq[LineAnnotation];
                        selected: int): string =
  ## One line's value labels — `Omniscience-Flow.md`'s three renderings.
  ##
  ##     [x=10]        a value the line reads
  ##     [x: 10 → 20]  a value the line WRITES
  ##     [→230]        the call's return value
  ##
  ## ## Why each part is its own span
  ##
  ## The name, the separator, the old value, the arrow and the new value are
  ## five spans, not one string. The stylesheet has to be able to recede the
  ## name and the superseded value while keeping the current one at full
  ## strength — a label rendered as one run of text can only be one weight, and
  ## `10 → 20` in one weight reads as two equally-current values rather than as
  ## a change. It is also what lets the value alone be the copy target later
  ## without the name coming with it.
  ##
  ## `title` carries `annotationText`, the ONE definition of the label as a
  ## string. Two spellings of `10 → 20` would be two chances to render it
  ## backwards, and the direction of that arrow is the whole content of the
  ## label.
  ##
  ## ## Why the pass is a class and not a filter
  ##
  ## Every pass the window carries is in the markup and the stylesheet shows
  ## one. That is what makes the iteration rail work with scripting off; see
  ## `flow_view.applyFlow`. `fv-any` is a line outside every loop and is always
  ## shown.
  ui:
    span(class = "ann"):
      for a in annotations:
        # `.now` is the pass the SESSION is in, and it is what the stylesheet
        # shows when no rail segment is targeted. A label outside every loop
        # (`iteration == NoIteration`) is `.now` in every pass, because there is
        # no other pass it could belong to.
        let now = (if a.iteration < 0 or a.iteration == selected: " now" else: "")
        span(class = "fv " & $a.slot & " m-" & $a.mode & " " &
                     iterationClass(a.iteration) & now,
             title = annotationText(a),
             # The source column the value's expression occupies, or -1 when
             # nothing in the line's text is what it names. Inert data, exactly
             # as `data-step` is: it is what the spec's parallel-column and
             # multiline modes need and neither is drawn today, and shipping it
             # costs nothing while re-deriving it later would mean re-running
             # the layout in the browser.
             `data-col` = $a.column):
          if a.label.len > 0:
            span(class = "fvn"): text a.label
            span(class = "fvsep"): text (if a.mode == vmChanged: ":" else: "=")
          if a.mode == vmChanged:
            span(class = "fvv was"): text a.beforeValue
            span(class = "fvto"): text "→"
            span(class = "fvv"): text a.afterValue
          elif a.mode == vmAfter:
            if a.label.len == 0:
              span(class = "fvto"): text "→"
            span(class = "fvv"): text a.afterValue
          else:
            span(class = "fvv"): text a.beforeValue

proc renderFlowRail*(rail: FlowRail): string =
  ## The loop-iteration control: `[Iteration: 3/8]` and a track.
  ##
  ## ## Two marks, because there are two facts
  ##
  ## `.here` is the pass the SESSION is in. It never moves, because moving the
  ## rail does not move the debugger on a page with no script. `.showing` is the
  ## pass whose values are on screen, and it is what a segment link changes.
  ## Collapsing them into one mark would make a reader who looked at pass 0
  ## believe the session had gone there — which, once hydration lands and the
  ## click really does seek, would be true half the time and false the other
  ## half. Two marks are correct in both states.
  ##
  ## ## What an unreached segment is, and why it is not hidden
  ##
  ## The window is cut at the session's position, so a pass the session has not
  ## entered carries no values AT THIS COORDINATE. Its segment renders inert and
  ## says why. Hiding it would misreport the loop's length; offering it would
  ## promise values that a still frame cannot honestly produce. It becomes live
  ## on hydration, because a live session can seek to it — `data-step` is its
  ## header tick and `hydrate.bindGestures` hands that to `ct/goto-ticks`, the
  ## same primitive a call-trace row already uses. No new protocol.
  if rail.loopIndex <= 0 or rail.iterations.len == 0: return ""
  let total = rail.iterations.len
  let shown = min(total, MaxStaticIterations)

  # The `:target` anchors, as siblings BEFORE the rail and the listing. CSS has
  # only sibling combinators, so an id nested inside the rail could not reach
  # the listing at all; the same constraint shapes `renderStack` and the source
  # tab strip, and the same answer works here.
  #
  # Concatenated rather than emitted from one `ui:` block with the rail. A block
  # with two roots is WRAPPED in an anonymous `<div>`, and that wrapper is not a
  # cosmetic difference: it puts the anchors and the listing in different
  # parents, so `#fit-3:target ~ .srcwrap` matches nothing and the whole control
  # silently does nothing. It also gave `.srcwrap` an auto-height parent to
  # resolve its `height:100%` against, which collapsed the code listing to zero
  # rows — the pane rendered its tab strip over an empty well. Both were caught
  # by looking at a capture, not by a test, which is why `test_debug_route` now
  # asserts the anchors are emitted AND that they are siblings of the listing.
  # Which passes get a counter: every one on the track, PLUS the selected one
  # when the session is past the ladder's end. Without that second half a loop
  # with more passes than the ladder would render its track, render its "showing
  # the first 16 of 21" notice, and render NO `Iteration N of M` at all — the
  # one line of the control that says where you are, missing exactly in the case
  # the clamp exists to be honest about.
  var counters: seq[int] = @[]
  for i in 0 ..< shown: counters.add i
  if rail.selected >= shown and rail.selected < total: counters.add rail.selected

  var targets = ""
  for i in 0 ..< shown:
    let anchor = ui:
      span(class = "frtarget", id = railTargetId(i)): text ""
    targets.add anchor
  let bar = ui:
    tdiv(class = "flowrail"):
      span(class = "frtitle"):
        text "Loop"
        if rail.label.len > 0:
          span(class = "frfn"): text rail.label
      a(class = "frline", href = "#" & rail.anchor,
        title = "Go to the loop header"):
        text "line " & $rail.line
      # ONE COUNTER PER PASS, and the stylesheet shows one — the same mechanism
      # as the labels, for the same reason. CSS can switch which element is
      # displayed and cannot rewrite text, so a single server-rendered counter
      # would keep saying "Iteration 3 of 8" while the rail displayed pass 1's
      # values. That is the control contradicting the thing it controls, in the
      # one place a reader looks to find out which pass they are looking at.
      for i in counters:
        span(class = "frcount num c" & $i &
                     (if i == rail.selected: " now" else: "")):
          text "Iteration " & $(i + 1) & " of " & $total
      span(class = "frtrack"):
        # Indexed rather than filtered: the `ui` DSL builds its result inside
        # the loop body, so a `continue` past a clamped segment leaves it with
        # unreachable code. Bounding the range says the same thing and says it
        # once.
        for i in 0 ..< shown:
          let it = rail.iterations[i]
          let mark = " s" & $it.index &
                     (if it.index == rail.active: " here" else: "") &
                     (if it.index == rail.selected: " showing" else: "") &
                     (if rail.navigable or it.reached: " got" else: " out")
          if rail.navigable:
            # A live session SEEKS. There is no `href`, because the target
            # mechanism switches which recorded pass is displayed and this
            # segment does something else entirely — it moves the debugger to
            # that pass's header tick. `hydrate.bindGestures` binds it, through
            # the same `data-step` a call-trace row already carries.
            span(class = "frseg" & mark, `data-step` = $it.ticks,
                 title = "Go to pass " & $(it.index + 1) & " of this loop"):
              span(class = "frnum"): text $(it.index + 1)
              span(class = "frhere")
              span(class = "frdot")
          elif it.reached:
            a(class = "frseg" & mark, href = "#" & railTargetId(it.index),
              `data-step` = $it.ticks,
              title = "Show pass " & $(it.index + 1) & " of this loop"):
              span(class = "frnum"): text $(it.index + 1)
              span(class = "frhere")
              span(class = "frdot")
          else:
            # Not a link. `Page-Descriptions` §7.0's rule about affordances
            # applies inside a control as well as to a whole page: this one
            # cannot act on a page with no engine, so it does not offer to.
            span(class = "frseg" & mark,
                 `data-step` = $it.ticks,
                 `aria-disabled` = "true",
                 title = "The session has not reached pass " &
                         $(it.index + 1) & " at this position."):
              span(class = "frnum"): text $(it.index + 1)
              span(class = "frhere")
              span(class = "frdot")
      if total > shown:
        # Clamped, and SAYING SO — `MaxIndentDepth`'s rule. A rail that silently
        # stopped at sixteen would misreport how many times the loop ran.
        span(class = "frmore"):
          text "Showing the first " & $shown & " of " & $total &
               " passes; the rest need the live session."
  targets & bar

proc renderSource*(p: EditorPane): string =
  ## The static source renderer.
  ##
  ## Per line: a gutter number, an execution marker, and the line's text inside
  ## `<code>` — as classified `<span>`s when the file's language has a lexer
  ## profile, and as the ONE text node it has always been when it does not.
  ## The seam this function reserved was used exactly as described: the spans
  ## arrive on `SourceLine.tokens`, already computed at export time by
  ## `source_highlight`, and nothing around them moved. Still no library, and
  ## still no JavaScript.
  ##
  ## The fallback is the honest half. A language with no profile, and an
  ## instruction-level session where there is no source and no lexer applies,
  ## both render plain — never mis-tokenised by whichever lexer happened to be
  ## available. A Solidity lexer over Noir would produce confident nonsense.
  ##
  ## `data-line` and the element `id` carry the line's stable identity
  ## (`session_view.lineAnchor`), derived from the file path and the line
  ## number rather than from render order. That id is what an inline value
  ## overlay, a deep link and a scroll-into-view will all address. The overlay
  ## slot itself is rendered when a line carries annotations and is empty in
  ## everything this milestone ships — the point is that adding one is a
  ## producer change, not a restructuring of this function.
  if p.availability != srcSourceLevel or p.documents.len == 0:
    return ui:
      tdiv(class = "srcnone"):
        p(class = "panenote"):
          text (if p.reason.len > 0: p.reason
                else: "No source is published for the code this transaction ran.")
        if p.availability == srcUnverified:
          p(class = "panenote"):
            text "Stepping continues at instruction level."
          button(class = "btn ghost sm"): text "Supply sources"
  let doc = activeDocument(p)

  proc tabStrip(activePath: string): string =
    ## The strip, rendered once PER PANEL with that panel's own tab marked.
    ##
    ## Emitting it per panel is what lets the active tab be correct for N
    ## documents with no JavaScript and no per-document CSS. The alternative —
    ## one shared strip corrected by `:target ~` selectors — can only reach the
    ## first and last tab, which is why `renderStack` gets away with it for a
    ## two-pane stack and why it would silently mismark a four-file bundle.
    ui:
      nav(class = "srctabs"):
        for d in p.documents:
          a(class = "srctab" & (if d.path == activePath: " on" else: ""),
            href = "#" & docAnchor(d.path)):
            text d.path

  proc body(d: SourceDocument): string =
    ## One document's lines, plus the notice when the pane opens part-way in.
    let first = (if d.lines.len > 0: d.lines[0].number else: 1)
    ui:
      tdiv(class = "src"):
        if first > 1:
          tdiv(class = "srcfrom"):
            text "Showing from line " & $first & " — the session's position is " &
                 "below, and the lines above it are not in this window."
        for ln in d.lines:
          tdiv(class = "srcline" &
                       (if ln.current: " cur" else: "") &
                       (if ln.executed: " hit" else: ""),
               id = ln.anchor, `data-line` = $ln.number):
            span(class = "n"): text $ln.number
            span(class = "m"): text (if ln.current: "▶" elif ln.executed: "·" else: " ")
            code(class = "t"):
              # No tokens means the language has no profile — render the line
              # as the ONE text node it was before highlighting existed. This
              # is the honest output for a file nothing here can lex, and for
              # an instruction-level listing where no lexer applies at all.
              if ln.tokens.len == 0:
                text ln.text
              else:
                for tok in ln.tokens:
                  # `tkPlain` carries whitespace and unremarkable identifiers.
                  # It gets no span: a wrapper that sets no colour is markup
                  # nobody reads, and it would roughly double the bytes of
                  # every source pane on the site.
                  if tok.kind == tkPlain:
                    text tok.text
                  else:
                    span(class = tokenClass(tok.kind)): text tok.text
            if ln.annotations.len > 0:
              raw renderAnnotations(ln.annotations, p.flow.selected)

  # The ACTIVE document is emitted LAST so that `.srcdoc.alt:target` can reach
  # forward and hide it. CSS has only a forward sibling combinator, and the
  # active document is the one every alternate has to be able to displace.
  var panels = ""
  for d in p.documents:
    if d.path == doc.path: continue
    let alt = ui:
      tdiv(class = "srcdoc alt", id = docAnchor(d.path)):
        raw tabStrip(d.path)
        raw body(d)
    panels.add alt
  let def = ui:
    tdiv(class = "srcdoc def", id = docAnchor(doc.path)):
      raw tabStrip(doc.path)
      raw body(doc)
  panels.add def
  # CONCATENATED, not emitted from one `ui:` block. The rail's `:target`
  # anchors, the rail and the listing must be SIBLINGS — `#fit-3:target ~
  # .srcwrap .fv` is the only shape CSS offers for "a control up here changes
  # what is shown down there", and a block with two roots wraps them in an
  # anonymous `<div>` that breaks the relationship. The wrapper also gave
  # `.srcwrap` an auto-height parent to resolve `height:100%` against, which
  # collapsed `.src` — a `flex:1 1 0` child of a flex column with no height —
  # to zero rows, so the pane rendered its tab strip over an empty well.
  let wrap = ui:
    tdiv(class = "srcwrap"):
      raw panels
  renderFlowRail(p.flow) & wrap

const MaxIndentDepth* = 8
  ## The depth the indentation ladder in `debugger_css.nim` has rules for.
  ##
  ## `depthClass` CLAMPS to it and marks the row, rather than emitting a `d9`
  ## no stylesheet answers. That distinction is the whole point: an unclamped
  ## class silently resolves to zero indentation, so a trace deeper than the
  ## ladder does not look deep — it looks FLAT, and a flattened call trace is
  ## indistinguishable from a correct one on a screenshot. Depth is the call
  ## trace's only structural signal, and losing it silently is precisely the
  ## "density collapse" VD.5's `verify_debugger_holds_under_load` exists to
  ## rule out.
  ##
  ## `weightClass` above refuses an out-of-ladder weight outright, because a
  ## layout that cannot be rendered is a build error. A frame is different: the
  ## trace is DATA and arrives at whatever depth it arrives at, so refusing
  ## would turn a deep transaction into a failed page. Clamping and SAYING SO
  ## is the honest form of the same rule.

proc depthClass*(depth: int): string =
  ## `depth` → its indentation class, clamped to the ladder and marked.
  if depth < 0: "d0"
  elif depth <= MaxIndentDepth: "d" & $depth
  else: "d" & $MaxIndentDepth & " deeper"

func costKey(f: CallFrame): int =
  ## The cost column's sort key. The producer has already FORMATTED the cost
  ## for display (`"1,315"`), so the separators come back out to compare it.
  ## A frame whose cost is not a number sorts last rather than crashing the
  ## page — a cost column can legitimately carry `—` for an unmetered frame.
  for c in f.cost:
    if c in {'0'..'9'}: result = result * 10 + (ord(c) - ord('0'))
    elif c notin {',', '_', ' '}: return -1

proc renderCallTrace*(p: CallTracePane): string =
  if p.frames.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "The call structure comes from the execution trace.")

  proc rows(frames: seq[CallFrame]; indented: bool): string =
    ui:
      tdiv(class = "ctrows"):
        for f in frames:
          # `data-step` is the time coordinate the frame starts at — the same
          # coordinate `?t=` carries (Debugger-Integration §6.2), which is why
          # it needs no protocol of its own. §3's last deferral is that "no row
          # in the navigation region is a jump target yet", and its stated
          # reason is that "until hydration lands such a link would reload the
          # page at a coordinate the static export cannot honour". So the
          # coordinate ships as DATA and the affordance does not: with
          # scripting off this row is what it has always been, and hydration is
          # what turns it into something clickable.
          tdiv(class = "ctrow " & (if indented: depthClass(f.depth) else: "d0 flat") &
                       (if f.current: " cur" else: ""),
               `data-step` = $f.step):
            span(class = "ctfn"):
              span(class = "ctname " & Copyable): text f.fn
              span(class = "ctmod"): text f.module
            span(class = "ctcost num"): text f.cost

  # Sorted by cost, descending. Rendered FLAT and not indented: the rows are no
  # longer in call order, so an indent would draw a tree that the ordering does
  # not describe — the one way a sorted call trace can lie.
  var byCost = p.frames
  for i in 1 ..< byCost.len:
    let cur = byCost[i]
    var j = i - 1
    while j >= 0 and costKey(byCost[j]) < costKey(cur):
      byCost[j + 1] = byCost[j]
      dec j
    byCost[j + 1] = cur

  let unit = (if p.costUnit.len > 0: p.costUnit
              elif p.frames.len > 0: p.frames[0].costUnit else: "")
  proc head(): string =
    ## The unit belongs to the COLUMN, not to every row in it. Repeating it per
    ## row spends width on a token that never varies, and the width it spends
    ## is taken from the frame column, which is the one that truncates.
    ui:
      tdiv(class = "cthead"):
        span(class = "ctfn"): text "Frame"
        span(class = "ctcost"):
          text p.costLabel
          if unit.len > 0:
            span(class = "ctunit"): text " " & unit

  # The cost-sorted view is a REAL alternate view reached by a `:target` link,
  # on the same no-JavaScript mechanism as the pane stack's tabs — not a label
  # styled as an action. VD.5's first round recorded `.ctsort` as an affordance
  # that lies; a sort that sorts is the fix, and it is also the milestone's own
  # "including the cost column and cost-sorted view".
  ui:
    tdiv(class = "ct"):
      tdiv(class = "ctview alt", id = "calltrace-by-cost"):
        raw head()
        raw rows(byCost, indented = false)
        tdiv(class = "ctfoot"):
          span: text "Sorted by cost."
          a(class = "ctsort", href = "#pane-calltrace"): text "Sort by call order"
      tdiv(class = "ctview def"):
        raw head()
        raw rows(p.frames, indented = true)
        tdiv(class = "ctfoot"):
          span: text "Sorted by call order."
          a(class = "ctsort", href = "#calltrace-by-cost"): text "Sort by cost"

proc renderState*(p: StatePane): string =
  if p.values.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "Variable values come from the execution trace.")
  ui:
    tdiv(class = "st"):
      for v in p.values:
        # Same clamped, linear ladder as the call trace: a value nested deeper
        # than the ladder is marked, never silently drawn at the wrong depth.
        tdiv(class = "strow " & depthClass(v.depth) &
                     (if v.changed: " chg" else: "")):
          # name → value → type, which is the desktop app's reading order
          # (`isonim_state_view.nim`). It was name → type → value here, so the
          # one pane a CodeTracer user reads fastest put its columns in an
          # order they do not know. The type stays a column of its own at the
          # end rather than trailing the name, so it is scannable down the
          # pane instead of landing at a different x on every row.
          span(class = "stname"): text v.name
          span(class = "stval " & Copyable): text v.value
          span(class = "sttype"): text v.typ

proc renderEventLog*(p: EventLogPane): string =
  if p.rows.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "Calls, storage writes and events come from the execution trace.")
  ui:
    tdiv(class = "ev"):
      for r in p.rows:
        # The same inert coordinate the call trace carries, for the same
        # reason. §4.2 calls clicking an event row "the single most valuable
        # interaction in the product — 'take me to the line that wrote this
        # value'"; `EventRow.step` is already the step identity it needs, and
        # this attribute is the only thing that was missing between the two.
        tdiv(class = "evrow k-" & $r.kind & (if r.current: " cur" else: ""),
             `data-step` = $r.step):
          span(class = "evglyph"): text eventKindGlyph(r.kind)
          span(class = "evkind"): text eventKindLabel(r.kind)
          span(class = "evstep num"): text $r.step
          span(class = "evlabel " & Copyable): text r.label
          span(class = "evdetail"): text r.detail

proc renderPhaseRail*(s: DebugSessionView): string =
  ## §8: "Loading is phased and honest — fetching, then opening, then
  ## positioning — never an indeterminate spinner."
  ##
  ## It lived in `pages/debug.nim` and moved here when hydration landed, for
  ## the reason every renderer on this route is in this file: hydration
  ## RE-RENDERS the rail as the engine advances through the three phases, and a
  ## copy of it in the bundle would be a second producer of the one thing on
  ## the page whose whole job is to be an accurate statement about the engine.
  ## `pages/debug.nim` calls this, the bundle calls this, and the phase a
  ## visitor reads mid-load is drawn by the same code that drew the served one.
  ##
  ## Nothing here is a skeleton. The panes behind this bar are already full:
  ## the loading design exists because the engine is an 18 MB wasm bundle, and
  ## the answer to that is to show the frame we already have rather than to
  ## draw grey boxes shaped like it.
  ##
  ## Renders NOTHING once the engine is live, which is how the rail disappears
  ## on hydration without hydration having to know it exists.
  if s.engineLive: return ""
  ui:
    tdiv(class = "phaserail"):
      for p in [spFetching, spOpening, spPositioning]:
        # The sentence `phaseLabel` spells is what the one-word chip is short
        # FOR, so it is the chip's title rather than something the short form
        # replaced. Fetching additionally carries the quantity, because "how
        # long is this" is the only question the word "fetching" leaves open.
        span(class = "phase" & (if p == s.phase: " on" else: ""),
             title = (if p == spFetching:
                        phaseLabel(p) & " — " & approxMegabytes(s.engineBytes)
                      else: phaseLabel(p))):
          text phaseShortLabel(p)
      # A build that loads the engine from another origin says which one. The
      # default is same-origin (`replay_engine.nim`), so this renders nothing
      # in every build that has not explicitly named a third party — which is
      # the point: there is no origin to disclose until there is.
      if s.engineCrossOrigin:
        span(class = "engineorigin"): text "Engine: " & s.engineBase

const TimelineTicks = 48
  ## The scrubber is a fixed number of discrete ticks rather than a filled bar,
  ## because a filled bar needs a per-render width and an inline `style`
  ## attribute — which `tools/design/check-tokens.mjs` A5 rejects, correctly:
  ## an inline style is a design value no token layer can reach.

proc renderControls*(p: DebugControlsPane): string =
  ## The stepping toolbar, the scrubber and the status — rendered into the
  ## identity bar (`pages/debug.nim`), not into a pane of its own.
  ##
  ## ## Why the inertness is on the buttons and not in a paragraph
  ##
  ## This used to be a full-width pane under a row of prose explaining that
  ## stepping had not started yet. The prose is gone. A control that cannot act
  ## has to say so *as a control*: `.dcbtn.off` carries the disabled surface,
  ## the disabled foreground and `cursor: not-allowed`, `aria-disabled` puts the
  ## same fact on the accessibility tree, and the `title` names the move AND
  ## what it is waiting for. Three channels, all attached to the thing that is
  ## inert, and none of them a sentence a reader has to connect to a button two
  ## panes away.
  ##
  ## `aria-disabled` rather than the `disabled` attribute, deliberately: a
  ## `disabled` button leaves the tab order and, in several browsers, stops
  ## showing its own tooltip — so the one channel that explains WHY it is inert
  ## would be unreachable exactly for the users who most need it. The button
  ## cannot act either way; this page has no script and no form behind it.

  # NEAREST tick, not the one below it. `int()` truncates, and truncation is a
  # systematic bias in one direction: the fixture sits at step 128 of 1315 =
  # 9.7%, which truncated to tick 4 of 48 and read as 8.3%. Every position the
  # scrubber can show was reported as EARLIER in the trace than it is, by up
  # to a whole tick; rounding halves the worst case and removes the bias.
  #
  # The LAST tick is reserved for `fraction == 1.0`. Rounding would otherwise
  # let step 1314 of 1315 land on it, and the final tick is not a measurement
  # — it is the claim that the trace has ended, which is a different kind of
  # statement from "roughly here" and must not be made by rounding error.
  let filled =
    if not p.positioned: 0
    else: clamp(int(p.fraction * float(TimelineTicks) + 0.5),
                1, (if p.fraction >= 1.0: TimelineTicks else: TimelineTicks - 1))
  ui:
    tdiv(class = "dc"):
      tdiv(class = "dcbtns"):
        for b in p.buttons:
          let why = (if b.enabled: b.label
                     else: b.label & " — inert until the replay engine loads")
          # `data-action` names the MOVE, in the wire spelling of
          # `DebugAction`, so hydration can bind a button to the command it
          # already claims to be. It is inert data and not an affordance — the
          # same standing `data-copy` has: no role, no `tabindex`, no handler,
          # and no change to what the button does with scripting off. What it
          # replaces is a hydration that had to identify a control by matching
          # its label text, which would make the toolbar's behaviour depend on
          # its wording.
          button(class = "dcbtn" & (if b.enabled: "" else: " off"),
                 `data-action` = $b.action,
                 title = why, `aria-label` = why,
                 `aria-disabled` = (if b.enabled: "false" else: "true")):
            span(class = "dcglyph"): text b.glyph
      tdiv(class = "dctl"):
        for i in 1 .. TimelineTicks:
          # The tick AT the position is marked separately from the ticks
          # before it. Without it the control is a progress bar, and a
          # progress bar at 10% on a page that is loading an 18 MB engine
          # reads as the engine's load progress rather than as position in
          # the trace — which is how five of six VD.5 round-1 reviewers
          # described it. The elapsed run says how far; the marker says
          # WHERE, and the scrubber's only job is the second one.
          span(class = "tick" &
                       (if p.positioned and i == filled: " at"
                        elif i <= filled: " on" else: ""))
      tdiv(class = "dcstatus"):
        span(class = "dcphase"): text p.statusText
        if p.totalSteps > 0:
          span(class = "dcsteps num"):
            text $p.step & " / " & $p.totalSteps

# ── the metadata pane (§7.1) ───────────────────────────────────────────────

proc metaRows(rows: seq[MetaRow]; cls: string): string =
  ## One `<dl>` of §7.2 facts. Shared by the overview rows and the decoded
  ## input so a row cannot acquire a second presentation by being in the other
  ## list.
  ui:
    dl(class = cls):
      for r in rows:
        dt: text r.label
        dd:
          if r.href.len > 0:
            a(href = r.href, class = "identifier"): text r.value
          elif r.badge.len > 0:
            span(class = "badge " & r.badge): text r.value
          elif r.identifier:
            # Rendered in FULL — an address, a target, a cost pair, a decoded
            # argument — so one click selects the whole of it. `Copyable` lives
            # here rather than at either call site for the same reason this
            # helper does: a row must not acquire a second presentation by
            # being in the other list.
            span(class = "identifier " & Copyable): text r.value
          else:
            text r.value
          if r.suffix.len > 0:
            span(class = "muted"): text " " & r.suffix

proc renderMetadata*(m: MetadataPane): string =
  ui:
    tdiv(class = "md"):
      tdiv(class = "mdhero"):
        span(class = "badge " & m.outcomeBadge): text m.outcome
        # Displayed TRUNCATED, so it is not `Copyable`: selecting the rendered
        # text would yield an ellipsis, which is not the hash. The full value
        # travels on `title` (readable on hover) and on `data-copy` (what
        # hydration reads when it turns this into a copy button).
        span(class = "identifier mdhash", title = m.hash,
             `data-copy` = m.hash): text truncHash(m.hash, 10, 8)
      # The hash IN FULL, below the truncation, exactly as the metadata page's
      # hero renders it (`pages/tx.nim`: a truncated `h1` over a full-hash
      # lead). §7.2 section 1 asks for "hash with copy", and after §7.0 this
      # pane is what a visitor and a crawler are served at the transaction's
      # own canonical URL — a page that states its subject's identity only in
      # two different truncations has lost the fact that identifies it. The
      # slim identity bar keeps its truncation, because §8's collapse is a
      # width constraint and this pane is not under it.
      #
      # And because it IS the full value, it is the copy target: one click
      # selects the whole hash. That is what §7.2's "with copy" can honestly
      # mean on a page with no script.
      p(class = "mdfull identifier " & Copyable): text m.hash
      if m.revertReason.len > 0:
        p(class = "mdrevert " & m.revertReasonTone):
          text m.revertReasonLabel & ": " & m.revertReason
      raw metaRows(m.rows, "mddl")
      if m.executions.len > 0:
        tdiv(class = "mdexec"):
          span(class = "mdexectitle"): text "Executions"
          for e in m.executions:
            tdiv(class = "mdexecrow"):
              # The selector is copyable and its availability badge is its
              # immediate sibling, so what is copied never arrives without the
              # qualifier that says how much it is worth.
              span(class = "sel " & Copyable): text e.selector
              span(class = "badge " & e.badge): text e.availability
              if e.reason.len > 0:
                span(class = "reason"): text e.reason
      # §7.2 sections 3 and 8, in the pane rather than only on a page.
      #
      # §7.0 makes the transaction route land in the SESSION where a trace is
      # published, so a fact that lived only on the explorer page would be a
      # fact the product stopped serving — to a visitor and to a crawler
      # alike. §7.1 says "§7.2 specifies *what* that metadata is", so the pane
      # carries §7.2, not a subset of it chosen by what fits.
      if m.payload.len > 0:
        tdiv(class = "mdsec", id = "decoded-input"):
          span(class = "mdexectitle"): text "Decoded input"
          raw metaRows(m.payload, "mddl mdpayload")
          if m.payloadNote.len > 0:
            p(class = "panenote"): text m.payloadNote
      if m.native.len > 0:
        tdiv(class = "mdsec", id = "raw"):
          span(class = "mdexectitle"): text "Raw (chain-native)"
          pre(class = "raw"): text m.native

# ── walking the layout ─────────────────────────────────────────────────────

proc paneBody(kind: PaneKind; s: DebugSessionView): string =
  ## Total over `PaneKind`: a pane CodeTracer adds is a compile error here.
  case kind
  of paneEditor: renderSource(s.editor)
  of paneCalltrace: renderCallTrace(s.calltrace)
  of paneState: renderState(s.state)
  of paneEventLog: renderEventLog(s.eventLog)
  of paneDebugControls: renderControls(s.controls)
  of paneFlow, paneTimeline, paneSearch, panePointList, paneScratchpad,
     paneShell:
    # Not placed by `defaultReplayLayout`, so unreachable today. Rendered as a
    # named, empty pane rather than left to `else: discard`, because the point
    # of the model's closed enum is that an unplaced pane is visible.
    paneNote("The " & $kind & " pane is not part of BlockTracer's session.")

proc paneClass*(kind: PaneKind): string =
  case kind
  of paneEditor: "p-source"
  of paneCalltrace: "p-calltrace"
  of paneState: "p-state"
  of paneEventLog: "p-eventlog"
  of paneDebugControls: "p-controls"
  else: "p-other"

proc paneId*(kind: PaneKind): string =
  ## The capture harness and any deep link address a pane by this id, so it is
  ## derived from the model's own enum spelling rather than hand-listed.
  "pane-" & ($kind).toLowerAscii

proc renderStack(node: LayoutNode; s: DebugSessionView): string =
  ## A tabbed region, switched by `:target`.
  ##
  ## The panels are emitted in REVERSE order and put back visually by the
  ## stylesheet, because CSS has only a forward sibling combinator: a targeted
  ## alternate has to be able to hide the default, and it can only reach
  ## siblings that come after it. The tab strip is emitted last and pulled to
  ## the top for the same reason — it needs to be reachable from a targeted
  ## panel so the active tab can be marked.
  var panels = ""
  for i in countdown(node.children.len - 1, 0):
    let child = node.children[i]
    let isDefault = i == node.activeIndex
    let panel = ui:
      section(class = "pane stackpanel " & paneClass(child.pane) &
                      (if isDefault: " def" else: " alt"),
              id = paneId(child.pane)):
        header(class = "panehead"):
          span(class = "panetitle"): text child.title
        tdiv(class = "panebody"):
          raw paneBody(child.pane, s)
    panels.add panel
  let tabs = ui:
    nav(class = "stacktabs"):
      for child in node.children:
        a(class = "stacktab t-" & paneId(child.pane),
          href = "#" & paneId(child.pane)):
          text child.title
  ui:
    tdiv(class = "ln stack " & weightClass(node.weight)):
      raw panels
      raw tabs

proc renderLayout*(node: LayoutNode; s: DebugSessionView): string =
  ## The walk. Total over `LayoutNodeKind`.
  if node.isNil: return ""
  case node.kind
  of lnPane:
    paneChrome(node.title, paneId(node.pane), paneClass(node.pane),
               paneBody(node.pane, s), node.weight)
  of lnStack:
    renderStack(node, s)
  of lnRow, lnColumn:
    var kids = ""
    for c in node.children: kids.add renderLayout(c, s)
    ui:
      tdiv(class = "ln " & (if node.kind == lnRow: "row" else: "col") & " " &
                   weightClass(node.weight)):
        raw kids
