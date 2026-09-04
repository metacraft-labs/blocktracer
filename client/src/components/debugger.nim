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
import ./icons
import ./shortcut_list
import ../debugger/flow_view
import ../debugger/layout_model
import ../debugger/replay_engine
import ../debugger/session_view
import ../debugger/keymap
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

# ── copying a value out (§13) ──────────────────────────────────────────────
#
# `Copyable` — and the whole argument for why this is a CSS affordance and not
# a button — now lives in `../debugger/session_view`, which this module already
# imports. It moved because §7.1's "one source" applies to the AFFORDANCE as
# well as to the facts: the explorer's transaction page renders the same
# `MetaRow` seq this pane does, and a class constant only the pane could reach
# is how the pane got one-click selection and the page did not.

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
  ##
  ## ## Every recorded value is emitted
  ##
  ## Nothing here decides which of a line's values the reader is allowed. There
  ## is no width budget, no priority order and no `+N` count, and the three
  ## sections of documentation that used to be here explaining those things are
  ## gone with them — see the "Why there is no width budget here" header in
  ## `debugger/flow_view.nim` for what they said, what it measured, and what
  ## CodeTracer desktop does instead.
  ##
  ## The run is a flex item on `.srcline`, which is `min-width:max-content`
  ## inside an `overflow:auto` pane. A line with more labels than fit is a line
  ## that is WIDER, and the pane scrolls to it — which is exactly what the
  ## desktop does (`ui/flow.nim:258-271` raises Monaco's
  ## `scrollBeyondLastColumn` to cover the widest flow row rather than dropping
  ## anything from it). A label cannot be separated from its line by that
  ## scroll, because the label and the line are items on the same row.
  ##
  proc chip(a: LineAnnotation): string =
    let now = (if a.iteration < 0 or a.iteration == selected: " now" else: "")
    ui:
      # `.now` is the pass the SESSION is in, and it is what the stylesheet
      # shows when no rail segment is targeted. A label outside every loop
      # (`iteration == NoIteration`) is `.now` in every pass, because there is
      # no other pass it could belong to.
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

  result = ui:
    span(class = "ann"):
      for a in annotations:
        raw chip(a)

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
      # WHERE THE HEADER IS, AS A LINK ONLY WHEN THERE IS SOMEWHERE TO GO.
      #
      # `rail.href` is complete — see `session_view.FlowRail.href` for why this
      # is not an id the renderer wraps in a `#`. It used to be, and the `#` this
      # line added was the defect: it asserted the target was on this page over a
      # pane that had since been narrowed to lines that did not include it.
      #
      # An empty href means no surface reachable from here renders that line. The
      # element then drops to a `span` — same text, same position, and no
      # underline, no pointer, no tooltip promising a destination. The line
      # number is a FACT and stays; only the affordance is conditional, because
      # an anchor that cannot arrive is the failure being fixed and `href=""`
      # (which reloads the page) would be a fresh one.
      if rail.href.len > 0:
        a(class = "frline", href = rail.href,
          title = "Go to the loop header"):
          text "line " & $rail.line
      else:
        span(class = "frline noloc"): text "line " & $rail.line
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

proc renderPositionHead(pos: DebugControlsPane): string =
  ## THE POSITION, FOR A PANE THAT HAS NO LINE TO PUT IT ON.
  ##
  ## `renderSource` below has two outputs and until now only one of them could
  ## say where the session is standing. A source-level pane says it with
  ## `.srcline.cur`; an instruction-level pane — `srcUnverified`, which is every
  ## real chain transaction this site currently publishes, because nothing
  ## resolves those contracts' compiled artifacts — returned `.srcnone`, two
  ## paragraphs of prose, and no position mark of any kind. The pane whose entire
  ## subject is "where is the execution stopped" was silent about it on the only
  ## transactions the chain actually has.
  ##
  ## That is not a styling gap. It is the debugger's single most important
  ## affordance missing on a whole class of page, and it is missing on BOTH
  ## builds: `client/dist` (what `just export` ships and the capture harness
  ## photographs) and the `flake.nix` build that serves `/assets/hydrate.js`,
  ## because hydration re-renders this pane through this same function and
  ## `projectEditor` puts a chain session on `srcUnverified` exactly as the
  ## static exporter does. One renderer, one defect, two artefacts.
  ##
  ## What it may honestly say is the STEP, and only the step. There is no line
  ## number to claim and none is claimed: `recording.stepsPositioned` is 0 for
  ## every transaction in the chain capture, so a line here would be invented.
  ## The step is the coordinate the session genuinely has — it is what
  ## `data-step` carries, what the scrubber sits at, and what a share link
  ## anchors to.
  ##
  ## IT IS A CAPTION NOW, NOT THE ONLY ANSWER. The pane has rows again — the
  ## recording's own program counters, one per recorded step
  ## (`instruction_listing.nim`) — so `.srcline.cur` marks the position visually
  ## and this states it in words. The head is kept for the reason the gutter
  ## marks carry a redundant channel: a highlight is a paint, and a reader on a
  ## printed page, a screen reader, or a pane scrolled away from the position
  ## gets the sentence instead. It is also still the ONLY answer wherever there
  ## are no rows at all, which is a state the route keeps — a transaction whose
  ## trace has not been recorded, and any recording whose instruction stream the
  ## tree does not publish.
  ##
  ## It reads `DebugControlsPane` rather than taking a step of its own, so there
  ## is ONE producer of the coordinate and two renderings of it. §7.1's "from one
  ## source" rule is about producers, not about how many places a fact may
  ## appear — and the toolbar's `128 / 208` sits in the page chrome, forty rows
  ## above the pane a reader is looking at when they ask "where am I".
  ##
  ## Nothing at all when the session is not positioned. `spAwaitingGeneration`,
  ## `srcAbsent` ("this execution ran no contract code") and a pre-positioning
  ## frame have no head to draw, and a head reading "step 0" would be the
  ## confident-but-wrong answer this product may not ship.
  if not pos.positioned or pos.step <= 0 or pos.totalSteps <= 0: return ""
  ui:
    tdiv(class = "srcpos", `aria-current` = "true"):
      # `aria-hidden` on the glyph and the sentence beside it carrying the
      # meaning, for the reason the gutter marks carry a redundant channel: a
      # screen reader announcing "black right-pointing triangle" says nothing,
      # and `aria-current` alone is not announced on a `div` by every reader.
      span(class = "p", `aria-hidden` = "true"): text "▶"
      span(class = "srcposlabel"):
        text "The session is stopped at step "
        span(class = "num"): text $pos.step
        text " of "
        span(class = "num"): text $pos.totalSteps

proc renderSource*(p: EditorPane; pos = DebugControlsPane()): string =
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
  ## A line also carries what the recording says about its CONTROL FLOW: the
  ## passes in which it sits inside a branch that was evaluated and not taken,
  ## as `nt-i*` classes plus `ntnow` for the session's own pass. Nothing is
  ## decided here — `flow_view.notTakenPasses` owns the claim and its header
  ## owns the argument for when it may be made — and nothing is stamped: the
  ## classes are re-derived from the pane on every render, so a hydrated
  ## `renderPanes` that replaces this pane's `innerHTML` gets them again rather
  ## than losing decorations it never applied.
  ##
  ## `data-line` and the element `id` carry the line's stable identity
  ## (`session_view.lineAnchor`), derived from the file path and the line
  ## number rather than from render order. That id is what an inline value
  ## overlay, a deep link and a scroll-into-view will all address. The overlay
  ## slot itself is rendered when a line carries annotations and is empty in
  ## everything this milestone ships — the point is that adding one is a
  ## producer change, not a restructuring of this function.
  # ## TWO KINDS OF ROW, ONE RENDERER
  #
  # A pane at `srcUnverified` that CARRIES DOCUMENTS is an instruction listing —
  # the program counters the recording holds, one row per step — and it goes
  # down the same path everything below draws. That is the point rather than a
  # convenience: the current-position fill, the `▶` in its own `.p` cell, the
  # `aria-current` on the row, the stable anchors and the windowing are the
  # marks this pane owes a reader, and an instruction listing that re-drew them
  # would be an imitation free to drift from the original. Going through this
  # function is what makes "the position is marked the same way" a property of
  # the code rather than a claim about it — including the `.p`/`.m` split a
  # sibling landed so the branch glyph could not displace the position glyph.
  #
  # What differs is what the pane says ABOVE the rows: source gets a tab strip
  # naming its files, a listing gets a caption naming its columns and the
  # bytecode object its counters index, and the listing keeps the stated reason
  # for having no source — beside the rows now, rather than instead of them.
  #
  # `srcUnverified` with NO documents is unchanged and is still a state this
  # route has: a transaction whose trace has not been recorded yet, and any
  # recording whose instruction stream the tree does not publish. It renders the
  # reason and the supply-sources action, exactly as before.
  #
  # AND SO IS `srcUnverified` WITH DOCUMENTS THAT ARE NOT A LISTING. The test
  # used to be `documents.len > 0`, which is not a test for "these rows are an
  # instruction listing" — it is a test for "there are rows". Handed a pane at
  # `srcUnverified` whose documents were SOURCE, this function drew a
  # `.src.instr` grid, under a FILE TAB STRIP, over syntax-highlighted program
  # text, beneath a paragraph saying no source is published for the code that
  # ran. Four channels, each contradicting the next, on the one screen whose
  # whole job is to say what fidelity a reader is getting. The
  # `tests/tdebugpanes.nim` case that asserts "nothing pretending to be code"
  # had not compiled since the day it landed, so nothing said so.
  #
  # `session_view.ListingPath` is what makes the disagreement unreachable.
  # `instruction_listing.listingDocument` is the only producer of listing rows
  # and files every one of them under that path; `session_project`'s live branch
  # decodes the island by the same name. So the pane's own documents answer what
  # they are, and the answer is the one the producers already gave — rather than
  # a count, which any pane can satisfy.
  #
  # What the other branch then means is what `srcUnverified` has always meant:
  # the recording steps, and there is no text this page is entitled to show.
  # Unverified source is not a weaker kind of source. Rendering it would be the
  # pane vouching for bytes nothing verified, which is the exact claim this
  # availability exists to withhold.
  let listing = p.availability == srcUnverified and p.documents.len > 0 and
                activeDocument(p).path == ListingPath
  if p.documents.len == 0 or
     (p.availability != srcSourceLevel and not listing):
    # The head FIRST, and outside `.srcnone`. A reader asking "where is this
    # stopped" gets the answer before the explanation of why there is no text to
    # put it on, and `.srcnone`'s prose block is byte-identical to what it was.
    # Concatenated rather than emitted from one `ui:` block with two roots, for
    # the reason `renderAnnotations` gives: two roots are wrapped in an
    # anonymous `div` that nothing asked for.
    let none = ui:
      tdiv(class = "srcnone"):
        p(class = "panenote"):
          text (if p.reason.len > 0: p.reason
                else: "No source is published for the code this transaction ran.")
        if p.availability == srcUnverified:
          p(class = "panenote"):
            text "Stepping continues at instruction level."
          # A CONTROL THAT CANNOT ACT HAS TO SAY SO AS A CONTROL. This button
          # was a bare `<button class="btn ghost sm">` with no handler, href,
          # form, `data-action` or `aria-disabled`, on a route that ships no
          # script at all — so it promised the one thing this page cannot do,
          # in the live style, directly under the sentence explaining the
          # limitation it claimed to lift. vd10-r1's adversarial reviewer on
          # `debugger--testnet/wide/light` named it the weakest element on the
          # screen and it is the only control here that hid its incapacity:
          # every one of the eight stepping buttons already carries
          # `aria-disabled="true"` with a bespoke reason, and so do Share and
          # the download.
          #
          # Same three channels the stepping controls use, and the long comment
          # on `renderControls` argues for them: `.disabled` carries the
          # disabled surface, foreground and `cursor:not-allowed`;
          # `aria-disabled` puts the same fact on the accessibility tree; the
          # `title` names the move AND what it is waiting for.
          #
          # `aria-disabled` and NOT the `disabled` attribute, for the reason
          # given there: a `disabled` button leaves the tab order and in
          # several browsers stops showing its own tooltip, so the one channel
          # that explains WHY it is inert would be unreachable exactly for the
          # readers who most need it.
          #
          # NOT DELETED, though the tx-detail precedent argued for deleting the
          # analogous one. vd9-r2's L5 withdrew a P1 about an absent
          # `supply an ABI` action on the grounds that a control which would be
          # inert even in a product that accepted ABIs is the "retry that
          # cannot succeed" §1 forbids, and that the note naming the gap is the
          # honest render. That reasoning turns on the subject having no raw
          # bytes to decode. Here the gap is real and general — this trace runs
          # at instruction level because no source is published for it — so the
          # route is a thing the product genuinely intends and does not yet
          # have. An inert control that states what it waits for says that; a
          # deleted one says the limitation has no route out at all, which
          # would be the page claiming something worse than the truth.
          # THE REASON NAMES NO MECHANISM, and the first version of it was
          # FALSE. It said "this route ships no client script, so there is
          # nowhere to upload them". That is true of the `just export` build the
          # capture harness photographs — `client/dist` contains zero `.js` —
          # and FALSE of the build a visitor reaches: `flake.nix` builds the
          # deployable site with `-d:hydrationBundle=/assets/hydrate.js` and
          # serves it on this exact route. vd10-r2's adversarial reviewer caught
          # it in the same report that confirmed the control itself was fixed.
          #
          # So a commit made to stop a control claiming something it could not
          # support shipped a sentence that misattributed its own cause on the
          # only build that matters. The lesson is narrower than "check your
          # facts": an explanation that names a BUILD-DEPENDENT mechanism is a
          # claim about an artefact, and the artefact the campaign photographs
          # is not the artefact the visitor loads. What is true on every build is
          # that the product has no route to accept sources yet, so that is all
          # this says.
          button(class = "btn ghost sm disabled",
                 `aria-disabled` = "true",
                 title = "BlockTracer cannot accept supplied sources yet. " &
                         "Stepping continues at instruction level in the " &
                         "meantime."):
            text "Supply sources"
    return renderPositionHead(pos) & none
  let doc = activeDocument(p)

  # THE SHORTEST TAIL OF EACH PATH THAT IS STILL UNIQUE, and it is a real defect
  # this fixes rather than a tidy-up.
  #
  # The strip used to label a tab with `d.path` entire. On the demo fixture that
  # is `src/shield.nr` and it reads well. On the first REAL source bundle — the
  # 32 Noir files of Aztec's FeeJuice, keyed at the absolute CI paths the
  # container interned — each label is 96 characters like
  # `/home/aztec-dev/aztec-packages/noir-projects/noir-contracts/contracts/protocol/aztec_sublib/src/oracle/avm.nr`,
  # every one wraps to two lines, and the strip took roughly six sevenths of the
  # pane. The source the whole page exists to show was four visible lines at the
  # bottom. A tab strip that crowds out the document is not a smaller version of
  # a tab strip.
  #
  # Not the basename, which would be wrong rather than merely short: a real Noir
  # bundle has `std/field/mod.nr` and `std/hash/mod.nr` in it, and two tabs both
  # labelled `mod.nr` is a control a reader cannot use. So each label grows by
  # whole path segments until nothing else in the set shares it, which gives
  # `avm.nr` where that is unambiguous and `field/mod.nr` where it is not. The
  # full path stays on `title`, and the anchor is unchanged: this renames the
  # LABEL and nothing about identity.
  func tabLabel(path: string; all: seq[string]): string =
    let segs = path.split('/')
    for take in 1 .. segs.len:
      let tail = segs[segs.len - take .. ^1].join("/")
      var shared = 0
      for other in all:
        let os = other.split('/')
        if take > os.len: continue
        if os[os.len - take .. ^1].join("/") == tail: inc shared
      if shared == 1: return tail
    path

  proc tabStrip(activePath: string): string =
    ## The strip, rendered once PER PANEL with that panel's own tab marked.
    ##
    ## Emitting it per panel is what lets the active tab be correct for N
    ## documents with no JavaScript and no per-document CSS. The alternative —
    ## one shared strip corrected by `:target ~` selectors — can only reach the
    ## first and last tab, which is why `renderStack` gets away with it for a
    ## two-pane stack and why it would silently mismark a four-file bundle.
    ##
    ## AN INSTRUCTION LISTING GETS A CAPTION INSTEAD, and not a one-tab strip.
    ## A tab strip answers "which of these files am I looking at", and a listing
    ## is one bytecode object, so the strip would be a control with one option
    ## and nothing to say. The caption answers the question a listing actually
    ## raises — what are these columns, and what are these counters offsets
    ## into — which is the difference between a grid of hex and a disassembly.
    if p.listingCaption.len > 0:
      return ui:
        p(class = "instrcap"): text p.listingCaption
    var allPaths: seq[string]
    for d in p.documents: allPaths.add d.path

    # ONE ROW, AND THE OVERFLOW IS A DROPDOWN MENU.
    #
    # The strip used to wrap. On the 32-file FeeJuice bundle it wrapped to SEVEN
    # rows at 1280 (172px of a 672px pane — a quarter of the document's height
    # spent on chrome), six at 1440 and five at 1920. That is the defect: a tab
    # strip is a way IN to the document beneath it, so a strip that displaces the
    # document has inverted its own purpose, and capping its height only bounded
    # how much it could take rather than stopping it taking it.
    #
    # THE FIRST FIX MADE THAT WORSE IN ITS OPEN STATE AND THAT IS WHY THIS ONE
    # EXISTS. The row stopped wrapping — it scrolls — and the wrapped grid became
    # a DISCLOSURE the reader unfolds. Measured on the same bundle: unfolding it
    # produced EIGHT rows and 196px at 1280, against the seven rows and 172px
    # that were reported as the defect. A control whose open state is bigger than
    # the bug is not a fix with a switch on it; the reader who opens it is back
    # in the layout they complained about, having asked for it. The report was
    # "we should have a drop down menu for the tabs that don't fit", and a menu
    # is the thing a disclosure is not: it OVERLAYS the document instead of
    # displacing it, so opening it moves nothing on the page.
    #
    # THE MENU IS THE STRIP. This is the whole design and it is what makes the
    # markup objection to a menu — recorded here, and correct about the form it
    # was aimed at — not apply to this one.
    #
    #   A second `<nav>` listing the files would cost a SECOND copy of the
    #   anchors, and the strip is rendered once per panel over 32 panels, so the
    #   duplicating form costs 1024 extra anchors on a page that already carries
    #   every line of every document. Measured on the built page, that page is
    #   4.04 MB with 1024 tab anchors in it, so the duplicating menu is a ~40%
    #   markup increase on the largest page the site serves.
    #
    #   So nothing is duplicated. There is ONE `<nav class="srctabs">` per panel
    #   holding one anchor per document, exactly as before, and the open state is
    #   that same element laid out as a vertical overlay panel — `position`,
    #   `flex-direction` and a surface, which is CSS over markup that already
    #   exists. The anchor count is UNCHANGED at 1024 and the page is unchanged
    #   in size to within the length of the label's text.
    #
    #   It also settles the second objection by construction rather than by
    #   care. `tools/journeys/lib/frame.mjs` and `lib/probe.mjs` read
    #   `.srctab.on` with `querySelector`, on the assumption that exactly one
    #   exists per visible panel — an assumption a duplicating menu breaks the
    #   moment it lists the active file too. One element cannot disagree with
    #   itself: there is one marked tab because there is one list, in the closed
    #   state and the open one, and neither reader needed changing.
    #
    # WHY A CHECKBOX AND NOT `<details>`. `:target` is already spent on choosing
    # the document, so the open state cannot be a fragment; and a `<details>`
    # that must show its contents while CLOSED depends on overriding the UA's
    # own hiding, which is exactly the kind of thing that differs between
    # engines. A checkbox with a `<label>` is the plain CSS-only toggle this
    # codebase already uses for the shortcut presets, and it is a real form
    # control, so it is focusable and operable from the keyboard for free — and
    # the menu's items are the same real links they are in the row, so the whole
    # control is reachable by Tab without a line of script.
    #
    # IT IS EMITTED ONLY WHEN THE ROW CANNOT BE ASSUMED TO HOLD THE BUNDLE.
    # Measured on the narrowest viewport the debugger is designed for: at 1280
    # the strip is 529px and the 32 tabs measure 3623px unwrapped, so a tab
    # averages ~113px and about four of them fit. Below that count the menu would
    # open onto the row the reader is already looking at — a control with nothing
    # to do — so the small demo bundles do not get one.
    const tabsOneRowFits = 4
    let allId = "srcall-" & docAnchor(activePath)
    # BUILT AS STRINGS AND `raw`-ed IN, not written as a top-level `if` inside
    # the `ui:` body — that form evaporates, which `renderPresetChooser` in
    # `shortcut_list.nim` records having shipped twice.
    var toggle, opener = ""
    if p.documents.len > tabsOneRowFits:
      toggle = ui:
        input(class = "srcallt", `type` = "checkbox", id = allId)
      opener = ui:
        label(class = "srcall", `for` = allId, role = "button"):
          # `role="button"` is load-bearing rather than decorative: journey
          # `12-a-clickable-surface-shows-the-hand` counts every element that
          # computes `cursor:pointer` and has no clickable ancestor as an
          # orphan, and requires zero of them. A bare `<label>` matches none of
          # its selectors; with the role it is a subject of that sweep instead
          # of a violation of it.
          #
          # THE CARET IS TEXT, and the two states name themselves rather than
          # relying on it: a caret alone says "there is more here" and says
          # nothing about what, and this control's whole job is to name the
          # thing the row could not show. `▾`/`▴` is the same register as the
          # position mark's `▶` and the listing's `·` — glyphs this pane already
          # spends, not an icon system this layer would have to import.
          span(class = "srcallmore"):
            text "All " & $p.documents.len & " files ▾"
          span(class = "srcallless"): text "Close ▴"
    ui:
      # `class="srctabs"` STAYS EXACTLY THAT, alone in its attribute. Four suites
      # match the literal `class="srctabs"` — `test_instruction_listing` asserts
      # it occurs zero times over a listing and more than zero over source, and
      # `test_chain_provenance` asserts its absence — so appending a modifier to
      # it would fail one of them and silently make the other two vacuous. The
      # scrolling behaviour therefore goes on `.srctabs` itself and the new
      # parts get a wrapper of their own.
      tdiv(class = "srcstrip"):
        raw toggle
        nav(class = "srctabs"):
          for d in p.documents:
            a(class = "srctab" & (if d.path == activePath: " on" else: ""),
              href = "#" & docAnchor(d.path),
              title = d.path):
              text tabLabel(d.path, allPaths)
        raw opener

  proc body(d: SourceDocument): string =
    ## One document's lines, plus the notice when the pane opens part-way in.
    let first = (if d.lines.len > 0: d.lines[0].number else: 1)
    ui:
      tdiv(class = "src" & (if listing: " instr" else: "")):
        # THE NOTICE, AND THE ONE REDUCTION LEFT TO ANNOUNCE.
        #
        # The session pane no longer takes a window: `source_document
        # .openAtCurrent` is gone and `pages/debug.nim` and `hydrate/hydrate.nim`
        # both render every line of every document. So on the debug route this
        # branch is now silent, which is the whole of the change a reader asked
        # for — "Showing from line 71" over an 83-line file whose first 70 lines
        # were dropped.
        #
        # It is NOT deleted, because there is still a caller that genuinely
        # narrows: `ssr.featuredSession` calls `windowAround(radius = 12)` for the
        # home page's embedded session, which is a fixed-height box with no
        # scrollbar to reach the position with. That reduction is real, so it is
        # announced — §13's rule that a reduction is announced rather than silent
        # — and the honest banner is the part this pane always got right. What was
        # wrong was the reduction underneath it, not the sentence about it.
        if first > 1:
          let last = d.lines[^1].number
          tdiv(class = "srcfrom"):
            # THE SENTENCE WAS REWRITTEN TWICE OVER, FOR TWO SEPARATE FAULTS.
            #
            # It read: "Showing from line 71 — the session's position is below,
            # and the lines above it are not in this window." A reader reported
            # it as copy addressed to whoever wrote the windower rather than to
            # anyone reading the page: it describes what the reduction did to
            # the document instead of telling a visitor what is in front of
            # them, and "not in this window" is the implementation's own word
            # for it.
            #
            # And by the time that was reported it was also WRONG. The clause
            # was written when the only windower was `openAtCurrent`, which
            # dropped every line ABOVE the position — so the position really was
            # below the notice. That windower is gone. The one remaining caller
            # is `ssr.featuredSession`'s `windowAround(radius = 12)`, which takes
            # `radius` lines on EITHER side, so the position is in the MIDDLE of
            # what is shown, not below it. The home page has been telling
            # visitors to look below a marker that is centred in the box.
            #
            # A range rather than a start, because a range is what a reader can
            # act on — it maps the excerpt onto the full file they can open —
            # whereas "from line 71" leaves the extent unstated. §13's rule that
            # a reduction is announced rather than silent is satisfied more
            # completely by naming both ends of it.
            #
            # Still named in the unit the rows are actually in: `line` is the one
            # word the instruction listing has spent four paragraphs explaining
            # it does not have.
            if listing:
              text "Steps " & $first & "–" & $last &
                   ", centred on where the session is stopped."
            else:
              text "Lines " & $first & "–" & $last &
                   ", centred on where the session is stopped."
        for ln in d.lines:
          tdiv(class = "srcline" &
                       (if ln.current: " cur" else: "") &
                       (if ln.executed: " hit" else: "") &
                       (if ln.breakpoint: " bp" else: "") &
                       notTakenClasses(ln.notTaken, p.flow.selected) &
                       ranClasses(ln.ran, p.flow.selected),
               id = ln.anchor, `data-line` = $ln.number,
               # THE POSITION ON THE ACCESSIBILITY TREE, which it was not on at
               # all. Every visual channel this row carries for "you are here" —
               # the fill, the rail, the position ink, the `▶` — is a paint, and
               # a reader who gets the DOM and not the pixels had no way to tell
               # the current line from any other. `aria-current` is the one
               # attribute that means exactly this.
               #
               # Valued on EVERY row rather than emitted on one, because the DSL
               # emits an attribute whose value is dynamic unconditionally, and
               # `false` is the ARIA spelling of "does not represent the current
               # item" — the same pattern `renderControls` uses for
               # `aria-disabled`. It also makes the fact countable in both
               # directions: a suite can assert one `true` AND that the rest are
               # `false`, which an absent attribute cannot distinguish from a
               # renderer that stopped emitting it.
               `aria-current` = (if ln.current: "true" else: "false")):
            # The block rail. Emitted only on a line that carries a claim, and
            # shown only in the passes where it holds, so a run of untaken lines
            # draws one continuous edge — which is what makes the region read as
            # a BLOCK the execution skipped rather than as a few unrelated dim
            # rows. It is the desktop feature's actual subject: `else { … }`, not
            # `else`.
            #
            # An absolutely positioned child rather than a border on the row,
            # because the row's border is already the current-position rail and
            # a line can be both — the demo's line 32 is where the session
            # stands AND the arm two earlier passes declined. Two edges side by
            # side state two facts; one edge fought over by two rules states
            # whichever rule was written last.
            if ln.notTaken.len > 0:
              span(class = "ntbar")
            # The affirmative rail. Same position as `.ntbar` and never at the
            # same time as it: a line cannot both run and not run in one pass,
            # and only one pass is displayed at a time, so the two block marks
            # are mutually exclusive by construction rather than by z-order.
            if ln.ran.len > 0:
              span(class = "rnbar")
            # THE POSITION GETS A COLUMN OF ITS OWN, and this is the fix for a
            # defect the stylesheet had already MEASURED and filed: "`▶` is
            # never painted anywhere in the corpus" (Q18, recorded in
            # `debugger_css.nim` beside `.srcline.cur .mt,.srcline.cur .mn`).
            #
            # The cause is structural rather than cosmetic. `.m` is ONE glyph
            # cell asked to answer two independent questions — "what does the
            # recording say about this line" (`·` steppable, `⊙` ran in this
            # pass, `⊘` did not) and "is the session standing here" (`▶`) — and
            # CSS resolves the collision by hiding one of them:
            # `.srcline.ntnow .mg{display:none}` and
            # `.srcline.rnnow .mg{display:none}`. The line the session is
            # stopped at is, structurally, also the arm that ran in the
            # displayed pass — the demo fixture's `shield.nr:32` is exactly
            # that, and it is the flagship view — so `.mg` is hidden on the one
            # row whose glyph matters most, on every page that has one. The
            # position glyph was not merely losing a contrast fight; it was not
            # drawn.
            #
            # Two cells, two questions, no contention. `.p` carries the
            # position and NOTHING else, so no branch rule can reach it and no
            # future one can: they select `.mg`, `.mn` and `.mt`, which are all
            # inside `.m`. This is the "channel the branch mark does not contend
            # for" the fix has to be, and it is a channel rather than a
            # re-tinting — `672dfc4` already spent the colour channel, giving
            # the current line's `⊙`/`⊘` the position ink to lift them off the
            # band, which fixed a contrast floor and left the current line with
            # a branch glyph WEARING position ink and no position glyph at all.
            # That rule stays; it is about legibility on the band. This is about
            # which fact is being stated.
            #
            # Emitted on EVERY row and not only the current one. A cell that
            # appeared only where the session stands would shift that row's code
            # text right by its own width relative to every other row, and a
            # listing whose current line is the one line that does not align is
            # a worse artefact than one with no marker. It is also why the width
            # cannot be widened on `.cur` alone.
            #
            # ## AND IT IS WHAT OPENS THE PANE AT THE POSITION ON A PAGE WITH NO
            # ## SCRIPT
            #
            # `source_document.openAtCurrent` used to do that by DELETING every
            # line above the position and having `.srcfrom` announce the loss —
            # "Showing from line 71 …" — because "the pane has no JavaScript to
            # scroll with". A browser will scroll a focused element into view
            # before it paints, and it needs no script to do it, so the position
            # cell takes `tabindex="-1"` and `autofocus` and the whole file
            # stays. `source_document.nim` carries the full account.
            #
            # ON THE POSITION CELL AND NOT ON THE ROW because the DSL emits a
            # named attribute unconditionally, and `autofocus` is an HTML boolean:
            # `autofocus="false"` is TRUE, so a row-level attribute would autofocus
            # every row and the browser would honour the FIRST — line 1, which is
            # the defect inverted. `.p` is already the only cell whose CONTENT is
            # conditional on `ln.current`, so the branch exists here and costs
            # nothing. It is also the correct target on its own terms: `.p` is the
            # position marker, leftmost in the row, so scrolling it into view
            # scrolls the row into view.
            #
            # `tabindex="-1"` and NOT `0`, for the reason `renderControls` gives
            # for preferring `aria-disabled` to `disabled`: the tab order belongs
            # to the controls a reader operates, and a source row is not one. `-1`
            # is focusable programmatically and by `autofocus`, and unreachable by
            # Tab, which is exactly the pair wanted.
            #
            # `aria-label` because the accessible name of this cell would otherwise
            # be the glyph `▶`, and `autofocus` means a screen reader lands on it
            # at page load. The row's own `aria-current="true"` states the fact for
            # a reader walking the DOM; this states it for the reader dropped here.
            if ln.current:
              span(class = "p", tabindex = "-1", autofocus = "autofocus",
                   `aria-label` = "the session is stopped on line " & $ln.number):
                text "▶"
            else:
              span(class = "p"): text " "
            # THE BREAKPOINT GUTTER. The line number is the target, because it
            # is the gutter a reader already points at and the conventional
            # place the gesture lives in every debugger that has one.
            #
            # The interactive attributes are emitted ONLY on a live pane
            # (`breakpointsEnabled`). On the static export this stays exactly
            # the span it has always been: a served page has no engine, so a
            # focusable `aria-pressed` control there would announce itself to a
            # screen reader as a toggle and then do nothing.
            #
            # `aria-pressed` and not `aria-checked`: this is a toggle button,
            # and it is valued on EVERY interactive line rather than emitted on
            # the marked ones, for the reason `aria-current` above is — so a
            # suite can count the `true`s AND the `false`s, which an absent
            # attribute cannot distinguish from a renderer that stopped
            # emitting it.
            #
            # Keyboard operation is NOT free here and is not assumed. This is a
            # `span`, so neither Enter nor Space fires a click on it — the
            # lesson `bindGestures` records against `role="button"` rows. The
            # role and the tabindex make it reachable and announced; the
            # `keydown` handler in `hydrate.bindBreakpointGutter` is what makes
            # it operable, and the two are a pair.
            if p.breakpointsEnabled:
              span(class = "n",
                   role = "button",
                   tabindex = "0",
                   `aria-pressed` = (if ln.breakpoint: "true" else: "false"),
                   `aria-label` =
                     (if ln.breakpoint: "Remove breakpoint on line "
                      else: "Set breakpoint on line ") & $ln.number):
                text $ln.number
            else:
              span(class = "n"): text $ln.number
            # The gutter marker, and — on a line inside a branch that was
            # evaluated and not taken — the SECOND glyph that replaces it in the
            # passes where that is true.
            #
            # Two glyphs in the markup and one on screen, for the reason the
            # iteration counter carries one span per pass: CSS can change which
            # element is shown and cannot rewrite text, so a single marker would
            # keep saying `·` ("you can stop here") on a line the displayed pass
            # never reached. The pair is emitted only for a line that carries a
            # claim, so an ordinary listing is byte-identical to before.
            #
            # It is a redundant channel and not the only one: the code text is
            # dimmed as well. Rubric A7 — the dimming alone would be a contrast
            # difference, which is the signal a reader with low vision, a bad
            # screen or a printed page loses first, and "did not run" is not a
            # decoration.
            span(class = "m"):
              # THREE STATES, THREE GLYPHS. `⊘` did not run in this pass, `⊙`
              # ran in this pass, and the ordinary marker underneath means the
              # pane is making no claim about this line — which is a real state
              # and not a default: an arm the recorder never instrumented, a
              # branch the session has not reached, a chain that went two ways.
              #
              # `⊙` and `⊘` are one glyph family — the same circle, with and
              # without the stroke through it — so the pair reads as one
              # question answered two ways rather than as two unrelated marks.
              # Neither is green or red: on this product the danger family means
              # a REVERTED execution, and a succeeded transaction with arms
              # painted in the failure colour would say the wrong thing louder
              # than the right one. Not taking a branch, and taking one, are
              # both ordinary control flow.
              #
              # `▶` IS NO LONGER ONE OF THEM. It moved to `.p` above, and with
              # it went the reason this cell ever had to choose: `·` and `▶`
              # were competing for one slot, so a steppable line the session was
              # standing on could say "you are here" or "you can stop here" and
              # not both, and a line with a branch claim said neither. Now the
              # current line states all three of its facts at once — it is
              # steppable, it ran in this pass, and the session is on it — which
              # is what was true all along.
              if ln.notTaken.len > 0 or ln.ran.len > 0:
                span(class = "mg"):
                  text (if ln.executed: "·" else: " ")
                if ln.notTaken.len > 0:
                  span(class = "mn"): text "⊘"
                if ln.ran.len > 0:
                  span(class = "mt"): text "⊙"
              else:
                text (if ln.executed: "·" else: " ")
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
            # Every value the trace recorded on this line, all on this row.
            # An empty `annotations` emits no `.ann` at all rather than an
            # empty one, so a line the flow window says nothing about costs
            # the markup nothing.
            if ln.annotations.len > 0:
              raw renderAnnotations(ln.annotations, p.flow.selected)

  # The ACTIVE document is emitted LAST so that `.srcdoc.alt:target` can reach
  # forward and hide it. CSS has only a forward sibling combinator, and the
  # active document is the one every alternate has to be able to displace.
  var panels = ""
  for d in p.documents:
    if d.path == doc.path: continue
    let alt = ui:
      tdiv(class = "srcdoc alt", id = docAnchor(d.path), `data-path` = d.path):
        raw tabStrip(d.path)
        raw body(d)
    panels.add alt
  let def = ui:
    # `data-path` carries the document's REAL path beside the anchor id.
    #
    # The id is `docAnchor(path)` — a mangled, URL-safe spelling (`src/main.nr`
    # becomes `D-src-main-nr`) chosen so it can be a fragment target. That
    # mangling is not invertible: `src/main.nr` and `src-main.nr` produce the
    # same anchor. A breakpoint has to name the file to the engine EXACTLY as
    # the trace interned it (see `live_breakpoints`'s header on the relative
    # path), so the unmangled path has to travel with the markup rather than be
    # reconstructed from the id.
    tdiv(class = "srcdoc def", id = docAnchor(doc.path), `data-path` = doc.path):
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
  if not listing: return renderFlowRail(p.flow) & wrap

  # ── the instruction listing's own chrome ──────────────────────────────────
  #
  # THE POSITION HEAD, THE REASON, THEN THE ROWS — in that order and all three,
  # which is the whole shape of the fix.
  #
  # The head stays. It is the sentence form of the position and it is now the
  # listing's caption rather than its only content: a reader who cannot see a
  # highlighted row — a screen reader, a printed page, a pane scrolled away from
  # the position — still gets "step 128 of 208" in words. Two channels for one
  # fact is what this pane already does for every other mark it draws.
  #
  # The reason stays too, and this is the part that was wrong before rather than
  # merely thin. It said the recording is at instruction level and then rendered
  # nothing at instruction level, so the words were doing the listing's job.
  # Beside the rows they do their own: they say why these are program counters
  # rather than source, and they carry the one action that could change it.
  #
  # It is deliberately ABOVE the rows and not below them. The rows scroll — there
  # are hundreds of them — and an explanation at the bottom of a scrollport is an
  # explanation nobody reaches. `.srcnone`'s own block is unchanged, so the
  # no-documents state and this one say the same thing in the same markup.
  let why = ui:
    tdiv(class = "srcnone"):
      p(class = "panenote"):
        text (if p.reason.len > 0: p.reason
              else: "No source is published for the code this transaction ran.")
      # The action, in the state it has always been in. See its long comment in
      # the no-documents branch above: it is inert, it says so on three channels,
      # and it is kept rather than deleted because supplying sources is a route
      # this product intends and does not yet have.
      button(class = "btn ghost sm disabled",
             `aria-disabled` = "true",
             title = "BlockTracer cannot accept supplied sources yet. " &
                     "The instructions below are what this recording carries."):
        text "Supply sources"
  renderPositionHead(pos) & why & wrap

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

const SelfCostViewId* = "calltrace-self-cost"
  ## The aggregate view's `:target` id. Named here because the footer link, the
  ## panel and the capture harness all address it and a third spelling is a
  ## view that can be reached but never marked.

proc renderCallTrace*(p: CallTracePane): string =
  if p.frames.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "The call structure comes from the execution trace.")

  # Declared before the row builders because the tooltip reads it: the unit is
  # the COLUMN's, carried once by the header, and a frame that does not repeat
  # it must still be describable on hover.
  let unit = (if p.costUnit.len > 0: p.costUnit
              elif p.frames.len > 0: p.frames[0].costUnit else: "")

  proc frameCells(f: CallFrame): string =
    ## The row's contents, so the two element shapes below cannot drift. A row
    ## is an `<a>` when the producer gave it a destination and a `<div>` when it
    ## did not, and everything inside is written once.
    ##
    ## **The name is painted in full and the path is not painted at all.**
    ## `.ctname` and `.ctmod` used to share the row's one flexible column with
    ## `text-overflow:ellipsis` on both, so a narrow pane cut BOTH of them and
    ## the reader got a truncated name beside a truncated path — two half
    ## identifiers where one whole one was wanted. The path is the long part
    ## and the rarely load-bearing part, so it leaves the row: it rides as
    ## `data-module` and in the row's tooltip, and the name gets the width.
    ##
    ## This generalises what the stylesheet already did at 720px, where
    ## `.ctmod` was `display:none` — the pane had ALREADY decided the path was
    ## the droppable half; it only decided it at one breakpoint.
    let name = ui:
      span(class = "ctfn"):
        span(class = "ctname " & Copyable): text f.fn
        # A coordinate is a few characters; a path is not. Dropped entirely
        # when the producer has no line, rather than rendered as `:0`.
        if f.line > 0:
          span(class = "ctline"): text ":" & $f.line
    let cost = ui:
      span(class = "ctcost num"): text f.cost
    name & cost

  proc rows(frames: seq[CallFrame]): string =
    ui:
      tdiv(class = "ctrows"):
        for f in frames:
          # `data-step` is the time coordinate the frame starts at — the same
          # coordinate `?t=` carries (Debugger-Integration §6.2), which is why
          # it needs no protocol of its own.
          #
          # `href` is what turns the row into a jump target, and it is the
          # PRODUCER's decision, not this renderer's. §3 deferred these on the
          # grounds that "until hydration lands such a link would reload the
          # page at a coordinate the static export cannot honour" — which is
          # still true of a static export, because a query string does not
          # select a file. What changed is that hydration now READS the
          # coordinate (§6.0a), so a link is honourable exactly where a script
          # is running to honour it. The served page keeps rows that are rows;
          # the hydrated page has anchors, and gets focus, Enter, middle-click
          # and the status bar from the platform rather than from a `keydown`
          # handler that would have to reimplement all four.
          #
          # `data-anchor` rides alongside as the row's §6.0a recovery anchor.
          # It is what makes the SERVED page able to resolve an incoming link
          # before a byte is fetched: §7.0 makes this page the session's first
          # frame from published data, so these rows already describe the
          # artifact the link is about, and §6.3 wants resolution "before first
          # paint" rather than after a round trip to an engine that has not
          # loaded. Inert either way — a row with no href does nothing with it.
          let cls = "ctrow " & depthClass(f.depth) &
                    (if f.current: " cur" else: "")
          #
          # `title` and `data-module` come AFTER `data-anchor` and that order
          # is load-bearing: `tools/capture/lib/entities.mjs` matches
          # `data-step="…" data-anchor="…"` as ADJACENT attributes, so anything
          # inserted between them silently stops the capture harness finding
          # rows. New attributes go on the end.
          #
          # `title` is the path's new home. A native tooltip rather than a
          # styled one because this route ships no JavaScript and must work
          # with scripting off: `title` is the only hover text a static page
          # can offer, and it is reachable by keyboard focus and to a screen
          # reader, which a CSS-only `::after` popover is not. Its content is
          # DERIVED from the frame by `session_view.frameTooltip` — no clause
          # of it is spelled here, so a row cannot describe a fact its own
          # data does not carry.
          #
          # `data-module` is the path as DATA. `hydrate.rowsOf` needs it to
          # resolve a `src:` deep link against the served rows, and it used to
          # get it by reading `.ctmod`'s `textContent` — scraping a
          # presentation element for a value. That coupling is why removing a
          # span from this row would otherwise have broken deep-link landing
          # with nothing to catch it.
          let tip = frameTooltip(f, unit)
          if f.href.len > 0:
            a(class = cls, href = f.href, `data-step` = $f.step,
              `data-anchor` = f.anchor, title = tip,
              `data-module` = f.module):
              raw frameCells(f)
          else:
            tdiv(class = cls, `data-step` = $f.step, `data-anchor` = f.anchor,
                 title = tip, `data-module` = f.module):
              raw frameCells(f)

  proc head(first, cost: string; withCalls: bool): string =
    ## The unit belongs to the COLUMN, not to every row in it. Repeating it per
    ## row spends width on a token that never varies, and the width it spends
    ## is taken from the frame column, which is the one that truncates.
    ui:
      tdiv(class = "cthead"):
        span(class = "ctfn"): text first
        if withCalls:
          span(class = "ctcalls"): text "Calls"
        span(class = "ctcost"):
          text cost
          if unit.len > 0:
            span(class = "ctunit"): text " " & unit

  # ── the aggregate view ───────────────────────────────────────────────────
  #
  # This replaced a cost-SORTED view, and the replacement is the finding rather
  # than the ranking: Chrome DevTools' `Bottom-up` is an AGGREGATION, and
  # sorting 500 frames gives 500 rows in a new order while aggregating gives
  # ~30 whose top row is the answer. `session_view.selfCostRows` does the
  # arithmetic — self cost is a frame's cost with its direct callees' taken out
  # — and this renders it.
  #
  # Still FLAT, and for the reason the sorted view was: these rows are not in
  # call order. There a flat rendering avoided drawing a tree the ordering did
  # not describe; here there is no tree to draw at all, because a function is
  # not a frame and has no depth. The reasoning survives the change that made
  # it moot, which is why it is restated rather than deleted.
  proc costRows(): string =
    ui:
      tdiv(class = "ctrows"):
        for r in selfCostRows(p):
          # Same treatment as a frame row, and for the same reason: this view
          # shares the pane's width and shared `.ctfn` column, so leaving the
          # path painted here would have left half the pane still truncating
          # two things at once. A function row has no line of its own — it is a
          # function, not an occurrence — so the tooltip is name and path.
          tdiv(class = "ctrow d0 flat" & (if r.unmetered: " partial" else: ""),
               title = (if r.module.len > 0: r.fn & "\n" & r.module else: r.fn),
               `data-module` = r.module):
            span(class = "ctfn"):
              span(class = "ctname " & Copyable): text r.fn
            span(class = "ctcalls num"): text $r.calls
            if r.unmetered:
              # A floor, marked as one. An aggregate that silently dropped an
              # unmetered frame would rank this function below one it may well
              # exceed, and the number would look exactly like a total.
              span(class = "ctcost num floor",
                   title = "At least one frame of this function reported no " &
                           "metered cost, so this total is a floor."):
                span(class = "ctfloorsign"): text "≥"
                text formatCost(r.cost)
            else:
              span(class = "ctcost num"): text formatCost(r.cost)

  # Both views are REAL alternates reached by a `:target` link, on the same
  # no-JavaScript mechanism as the pane stack's tabs — not a label styled as an
  # action. VD.5's first round recorded `.ctsort` as an affordance that lies;
  # a control that switches a view is the fix.
  ui:
    tdiv(class = "ct"):
      tdiv(class = "ctview alt", id = SelfCostViewId):
        raw head("Function", "Self " & p.costLabel, withCalls = true)
        raw costRows()
        tdiv(class = "ctfoot"):
          span: text "By function — self cost, callees excluded."
          a(class = "ctsort", href = "#pane-calltrace"): text "Call order"
      tdiv(class = "ctview def"):
        raw head("Frame", p.costLabel, withCalls = false)
        raw rows(p.frames)
        tdiv(class = "ctfoot"):
          span: text "By call order."
          a(class = "ctsort", href = "#" & SelfCostViewId): text "Self cost"

proc renderState*(p: StatePane): string =
  if p.values.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "Variable values come from the execution trace.")
  ui:
    tdiv(class = "st"):
      for v in p.values:
        # Same clamped, linear ladder as the call trace: a value nested deeper
        # than the ladder is marked, never silently drawn at the wrong depth.
        # WHAT THE LAST MOTION DID TO THIS ROW, in two mutually exclusive
        # classes and never in three. `chg` is "differs from the position you
        # came from"; `new` is "was not in scope there". A row that is neither
        # carries no marker at all, which is what makes the marked ones legible
        # — a `continue` over a long stretch may mark every row, and that reads
        # correctly as "everything here is different" precisely because the
        # unmarked state is the pane's ordinary appearance rather than a third
        # decoration.
        tdiv(class = "strow " & depthClass(v.depth) &
                     (if v.changed: " chg" elif v.appeared: " new" else: "")):
          # name → value → type, which is the desktop app's reading order
          # (`isonim_state_view.nim`). It was name → type → value here, so the
          # one pane a CodeTracer user reads fastest put its columns in an
          # order they do not know. The type stays a column of its own at the
          # end rather than trailing the name, so it is scannable down the
          # pane instead of landing at a different x on every row.
          span(class = "stname"): text v.name
          span(class = "stval " & Copyable): text v.value
          span(class = "sttype"): text v.typ
          # THE ORIGIN CONTROL, on the rows that have an origin and on no
          # others. `v.origin` is the classified terminator expression, so the
          # button's title says what the answer will be BEFORE it is asked —
          # which is the difference between an affordance and a lottery ticket.
          #
          # A row whose value the classifier could not attribute gets no
          # button. That is deliberate and it is the whole point: the engine
          # answers `success: true` for those too, carrying
          # `confidence: 0` and "source unavailable", so a control rendered on
          # every row would be a control that fails on most of them while
          # looking identical to one that works.
          if v.origin.len > 0:
            button(class = "storigin", `data-action` = "origin",
                   `data-name` = v.name,
                   title = "Trace to origin: " & v.origin):
              text "origin"
      # Said once for the pane, not once per row: it is a property of the
      # RECORDING, and repeating it beside every value would read as a
      # per-value failure rather than as the one fact it is.
      if p.originNote.len > 0:
        tdiv(class = "stnote"): text p.originNote

proc renderEventLog*(p: EventLogPane): string =
  if p.rows.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "Calls, storage writes and events come from the execution trace.")

  proc eventCells(r: EventRow): string =
    ## As in the call trace: the contents are written once and the element
    ## shape is the producer's decision. §4.2 calls clicking an event row "the
    ## single most valuable interaction in the product — 'take me to the line
    ## that wrote this value'", and an event row is the ONE surface where the
    ## storage writes are individually addressable, so it is a jump target on
    ## exactly the same terms as a call frame rather than on weaker ones.
    let glyph = ui:
      span(class = "evglyph"): text eventKindGlyph(r.kind)
    let kind = ui:
      span(class = "evkind"): text eventKindLabel(r.kind)
    let step = ui:
      span(class = "evstep num"): text $r.step
    let label = ui:
      span(class = "evlabel " & Copyable): text r.label
    let detail = ui:
      span(class = "evdetail"): text r.detail
    glyph & kind & step & label & detail

  ui:
    tdiv(class = "ev"):
      for r in p.rows:
        let cls = "evrow k-" & $r.kind & (if r.current: " cur" else: "")
        if r.href.len > 0:
          a(class = cls, href = r.href, `data-step` = $r.step,
            `data-anchor` = r.anchor):
            raw eventCells(r)
        else:
          tdiv(class = cls, `data-step` = $r.step, `data-anchor` = r.anchor):
            raw eventCells(r)

const PositionNoticeSlotId* = "dbg-position-notice"
  ## The element `renderPositionNotice`'s output goes in.
  ##
  ## A named, always-emitted slot rather than an insertion point hydration
  ## computes: `readUi` resolves every element it writes to once, at a point
  ## where failing means "do not hydrate", and a notice that could not find
  ## somewhere to go would otherwise fail silently — which is precisely the
  ## silent landing §6.0a exists to prevent, reintroduced by the mechanism
  ## meant to prevent it.

proc renderPositionNotice*(s: DebugSessionView): string =
  ## §6.0a's visible branches, as the one sentence the visitor is owed.
  ##
  ## "Every branch below (2) is *visible*. The client never silently lands
  ## somewhere other than where the link pointed." This is where that stops
  ## being a property of a data structure and becomes something on a screen.
  ##
  ## Renders NOTHING for an ordinary visit and nothing for an exact hit — the
  ## two cases where the page is showing precisely what was asked for and a
  ## banner would be noise that trains readers to ignore the one that matters.
  ## Every other outcome renders, whatever it is, because the decision about
  ## which branches speak belongs to `resolvePosition` and is made once.
  ##
  ## `role="status"` and not `role="alert"`: nothing is wrong. A recovered
  ## position is the product working as designed, and the divergence banner
  ## above it is the one that interrupts. The outcome travels as
  ## `data-landing` so the state is inspectable — by a test, by the capture
  ## harness, and by anyone reading the DOM — without parsing the sentence.
  if not s.landing.isVisible: return ""
  ui:
    tdiv(class = "dbgnotice", role = "status", `data-landing` = s.landing.outcome):
      span(class = "noticetitle"): text "Position"
      span(class = "noticetext"): text s.landing.statement

const EngineFailureSlotId* = "dbg-engine-failure"
  ## The element `renderEngineFailure`'s output goes in. Always emitted, empty
  ## on every served page, for the reason `PositionNoticeSlotId` is.

proc renderEngineFailure*(reason: string): string =
  ## The replay engine will not run, said ON THE PAGE.
  ##
  ## ## Why this exists
  ##
  ## `hydrate.markUnavailable` had three sentences to say and nowhere to say
  ## them. It wrote each one into the `title` and `aria-label` of the inert
  ## stepping buttons and into `data-engine-unavailable` on the root, and put
  ## the two words "Engine unavailable" in the controls' status. So the whole
  ## visible treatment of a failed engine was two words, and the diagnosis was
  ## a tooltip: a pointer user had to hover a disabled button to read it, a
  ## touch user could not reach it at all, and a screen-reader user got strictly
  ## more than a sighted one.
  ##
  ## The three sentences are separated at their source precisely because one
  ## sentence covering two faults — an engine that never arrived, and an engine
  ## that arrived and refused the container — sent a real diagnosis down the
  ## wrong path for hours. That separation is worth nothing while the sentence
  ## it distinguishes is only in the accessibility tree.
  ##
  ## ## Why a `.dbgbanner` and not a `.dbgnotice`
  ##
  ## The two banners above are page-level verdicts about the TRACE and stay
  ## true for as long as the page is open; `.dbgnotice` says something about the
  ## LINK, once, on arrival, and explicitly means "nothing is wrong". This is a
  ## verdict of the first kind: the engine is not going to run for this
  ## document, and the sentence stays true. `role="alert"`, like divergence and
  ## unlike truncation, because it appears after first paint and the visitor is
  ## by then looking at controls they have some reason to believe in.
  ##
  ## It is deliberately NOT a retry. §14: "a terminal state with a reason, never
  ## a retry that cannot succeed". The ladder's surviving rungs — the container
  ## download in the identity bar, and the static summary that is this whole
  ## page — are already on screen, and each of the three sentences names the one
  ## that applies.
  if reason.len == 0: return ""
  ui:
    tdiv(class = "dbgbanner bad", role = "alert"):
      span(class = "bannertitle"): text "Replay engine unavailable"
      span(class = "bannertext"): text reason

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

func controlMark(a: DebugAction): string =
  ## The action's mark. A total `case` over the enum and not a table, for the
  ## reason `toolbarActionId` is one: a control added to the toolbar has to be
  ## given a mark here or it does not compile, rather than rendering as an
  ## empty button.
  ##
  ## The marks and the survey behind them are in `components/icons`; the
  ## per-command reasoning is `Debugger-Controls.md` §"Control Actions".
  case a
  of daStepBackward: reverseStepOverMark()
  of daStepForward: stepOverMark()
  of daReverseStepIn: reverseStepInMark()
  of daStepIn: stepInMark()
  of daReverseStepOut: reverseStepOutMark()
  of daStepOut: stepOutMark()
  of daReverseContinue: reverseContinueMark()
  of daContinue: continueMark()

const ShortcutsLabel* = "Keyboard shortcuts"
  ## The gear's `title` and `aria-label`, and the dialog's heading — one
  ## string, so the control and the thing it opens cannot come to be called
  ## two different names.

proc renderShortcutsDialog*(km: Keymap; mac: bool): string =
  ## The keyboard-shortcuts dialog: which preset is in force, what it binds,
  ## and what this platform will do to each chord.
  ##
  ## ## IT IS RENDERED FROM THE TABLE, WHICH IS THE POINT OF IT
  ##
  ## Every row below comes from iterating `km.bindings` — the same sequence
  ## `keymap.actionFor` matches a key press against. There is no list of
  ## shortcuts in this file to fall out of date, and there cannot be one,
  ## because the loop has nothing to read but the bindings themselves.
  ##
  ## That is the defect this dialog exists to cure rather than to join.
  ## `Debugger-Integration.md` §10.5 records the sibling product shipping
  ## chords "restated as literals" in two documents that already contradict
  ## each other on `Shift+F5`. A settings dialog that listed shortcuts from its
  ## own hardcoded table would be a third copy — and the most authoritative
  ## looking one, because a dialog headed "Keyboard shortcuts" is precisely
  ## where a visitor goes to find out what is true.
  ##
  ## The consequence worth stating plainly: this dialog lists EXACTLY the bound
  ## set. Not the intended set, not the documented set. If a binding is dropped
  ## the row disappears, and if one is added the row appears, with no edit here.
  ##
  ## ## THE HAZARD COLUMN, which is the honest half
  ##
  ## `hazardOf` is computed per chord and per platform, so a preset cannot
  ## claim a key works that this browser will eat. A visitor who picks the
  ## desktop preset on a Mac is told, on the `F12` row, that the browser takes
  ## that key — rather than discovering it by pressing it and concluding the
  ## shortcuts are broken.
  ##
  ## `mac` is passed in rather than sniffed here because this is a pure
  ## renderer shared with a build that has no `navigator`.
  ui:
    tdiv(class = "kbdlg", id = "dbg-shortcuts", hidden = "hidden",
         role = "dialog", `aria-modal` = "true",
         `aria-labelledby` = "dbg-shortcuts-title"):
      tdiv(class = "kbdlgbox"):
        tdiv(class = "kbdlghead"):
          h2(class = "kbdlgtitle", id = "dbg-shortcuts-title"):
            text "Keyboard shortcuts"
          button(class = "kbdlgclose", `data-kb` = "close",
                 title = "Close", `aria-label` = "Close"):
            text "×"

        # THE PRESET PICKER. Radios and not a `<select>`: the options are four
        # and each needs a sentence, which an option element cannot carry.
        #
        # DELEGATED SINCE `/settings` GREW THE SAME LIST. Both this dialog and
        # the settings page show "the keyboard shortcuts", and two procs
        # drawing that would be free to draw it differently — the same defect
        # `keymap.nim`'s one-table rule exists to prevent, one level up. The
        # rows moved to `components/shortcut_list.nim` and neither surface owns
        # one now. `served = false`: this dialog only exists on the hydrated
        # page, so its chooser is live as soon as it is in the DOM.
        raw renderPresetChooser(km.id, served = false)

        # THE ACTIVE BINDINGS. `data-kb-rows` is what a check counts, so the
        # count is read off the rendered set rather than off an intention.
        # `kmNone` renders a sentence rather than an empty table — an empty
        # table reads as a dialog that failed to load, which is the one thing
        # this surface must never look like.
        raw renderBindingRows(km, mac)

        # AND THE TWO REGISTRIES THIS DIALOG USED TO OMIT.
        #
        # It was headed "Keyboard shortcuts" and listed only the stepping
        # preset, while this page also answers the scrubber's six moves and
        # `hydrate.nim`'s own `Enter`/Space/`Escape`. A reader who opened this
        # to find out what a key does was being given a third of the answer
        # under a title that claimed all of it. See `shortcut_list.nim`.
        h3(class = "kbgrouptitle"): text ScrubName
        raw renderScrubRows()
        h3(class = "kbgrouptitle"): text "Always active"
        raw renderHardRows()

        # THE FOOTNOTE IS GONE, and it is the same family as the site
        # footer's "No account, no tracking" and the removed `/settings` page:
        # the product volunteering its privacy posture at a reader who did not
        # ask. Here the mismatch is sharper than either, because the surface is
        # not even about privacy — a reader opens a shortcuts dialog to choose
        # a keybinding preset, and nobody choosing a keybinding wonders whether
        # their choice is being transmitted to a server. Raising the question in
        # order to answer it is what put the thought there.
        #
        # The claim itself remains true and remains stated where someone who
        # DOES ask will look: `/about`, under `What it costs you`.
        #
        # IT STAYS GONE ON THE NEW `/settings` TOO. That page stores the
        # preset choice and says nothing about storing it: the persistence is
        # demonstrated by the choice surviving a reload, which is the only
        # evidence a reader was ever going to accept anyway.

proc renderShortcutsButton*(): string =
  ## The gear, for the identity bar's `.dbgacts` group.
  ##
  ## ## IT IS NOT RENDERED BY THE PAGE, and that is the whole design
  ##
  ## `pages/debug.nim` does not call this. Hydration does, once, and inserts
  ## the result into `.dbgacts` beside Share and Download.
  ##
  ## A gear on the served, script-less page would open nothing. This product
  ## has a standing rule against exactly that, and states it about this exact
  ## family of control — `Page-Descriptions.md` §13, on why there is no
  ## pre-hydration copy button: "a copy *button* there would be a control that
  ## cannot succeed — which this product does not ship." The same discipline
  ## already governs the scrubber, whose `role="slider"` is stamped only by the
  ## compilation that implements the drag.
  ##
  ## So the affordance and the behaviour ship in one artefact and cannot come
  ## apart: the only build that emits this button is the build that binds its
  ## click, and the only build that binds the chords it configures.
  ##
  ## A real `<button>`, not a `role="button"` on a div — `pages/debug.nim`
  ## records why in as many words ("it shipped on this route once already").
  ui:
    button(class = "btn ghost sm icon", id = "dbg-shortcuts-open",
           `data-kb` = "open",
           title = ShortcutsLabel, `aria-label` = ShortcutsLabel,
           `aria-haspopup` = "dialog", `aria-expanded` = "false"):
      raw settingsMark()

proc renderControls*(p: DebugControlsPane; km = keymapOf(kmNone)): string =
  ## The stepping toolbar, the scrubber and the status — rendered into the
  ## identity bar (`pages/debug.nim`), not into a pane of its own.
  ##
  ## ## `km`, AND WHY ITS DEFAULT IS THE EMPTY ONE
  ##
  ## `km` is which chords are bound, and it defaults to `kmNone` so that the
  ## SERVED frame — which has no bundle, no `keydown` handler and therefore no
  ## chords — names no key in any tooltip. Hydration passes the live keymap;
  ## every other caller gets silence.
  ##
  ## This is the safe direction by construction rather than by convention: a
  ## new call site that forgets the argument under-promises. The opposite
  ## default would make forgetting it ship a tooltip naming a key that does
  ## nothing, which is the defect `keymap.controlLabel` exists to prevent.
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

  ## ## The scrubber is a control, and this is not where it says so
  ##
  ## A visitor reported the track as something they expected to be able to
  ## drag, and they were right to: it is a timeline with a distinct playhead,
  ## which is the shape of a scrubber in every tool this product is measured
  ## against. `hydrate.bindGestures` now binds that drag to `ct/goto-ticks` —
  ## the same primitive a row click and a deep link use.
  ##
  ## But NOTHING is added here. No `role`, no `tabindex`, no `cursor`. The
  ## affordance is stamped by `markScrubberSeekable`, in the one compilation
  ## that also implements the gesture, for `markRailNavigable`'s reason and one
  ## more of its own: this page is ALSO served without a bundle, and a
  ## `role="slider"` on the crawled artefact would be a control that announces
  ## a range it cannot be moved along. That is the defect family this change
  ## exists to close — after a plus-cursor on rows that were not clickable, and
  ## a `cursor: pointer` that outlived the click handler it belonged to — and
  ## reintroducing it in the fix would be an unpleasant irony. The affordance
  ## and the behaviour are emitted by the same file, so they cannot ship apart.
  ##
  ## `markedTick` is `session_view`'s, not this proc's. Hydration needs the
  ## same answer to paint the handle under a pointer that is still down, and
  ## two roundings of one quantity is two controls: the one drawn and the one
  ## dragged.
  let filled = p.markedTick
  ui:
    tdiv(class = "dc"):
      tdiv(class = "dcbtns"):
        for b in p.buttons:
          # THE CHORD COMPOSES HERE, into the one string that already feeds
          # both `title` and `aria-label` — which is where
          # `session_view.controlLabel`'s note said it would, and the reason
          # the note said so: a chord cannot be put in front of a visitor
          # without passing through a keymap that the dispatcher matches key
          # presses against. `km` is empty on the served page, so this is
          # exactly the old string there.
          let label = controlLabel(b.action, km)
          let why = (if b.enabled: label
                     else: label & " — inert until the replay engine loads")
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
            # The mark is an SVG and not a text glyph, and `raw` because
            # `components/icons` builds it through the DSL and hands back a
            # string — the same path `footer` takes for the provenance marks.
            #
            # It is `aria-hidden` inside that module, so the button's accessible
            # name stays the one `aria-label` gives it. A mark that announced
            # itself would be a control named twice.
            span(class = "dcglyph"): raw controlMark(b.action)
      tdiv(class = "dctl"):
        for i in 1 .. TimelineTicks:
          # `tickClass` is `session_view`'s, for `markedTick`'s reason: the
          # handle hydration paints under a live pointer and the handle drawn
          # when the engine answers are the same mark, and two spellings of
          # this expression would be two marks that agree until one is edited.
          span(class = tickClass(p, i, filled))
      tdiv(class = "dcstatus"):
        span(class = "dcphase"): text p.statusText
        # §10.8's "the control says so". Rendered only when there is something
        # to say, and carrying the outcome as `data-outcome` so a check can
        # read the STATE without matching the sentence — the same separation
        # `renderPositionNotice` makes with `data-landing`, and for the same
        # reason: a suite that asserted the prose would be a suite that has to
        # be edited to reword a message.
        #
        # `role="status"` and not `role="alert"`: reaching the end of the
        # breakpoints is an ordinary outcome of an ordinary gesture, not a
        # fault, and it must not interrupt what a screen-reader user is doing.
        if p.outcome.len > 0:
          span(class = "dcoutcome", role = "status",
               `data-outcome` = "no-breakpoint"):
            text p.outcome
        if p.totalSteps > 0:
          span(class = "dcsteps num"):
            # GROUPED because `dcsteps` carries no `.copyable` and `totalSteps`
            # is an integer in the view model, so the rule on `groupDigits` puts
            # it on the grouped side. That is the whole justification.
            #
            # IT IS NOT "THE SAME QUANTITY THE CALL TRACE PRINTS", which is what
            # this comment used to say, and the correction matters because the
            # false version is why the change was made at all. Two vd9-r2 lenses
            # filed the pair as "the same quantity printed two ways on one
            # screen" and I believed them. They are two DIFFERENT quantities
            # that are equal by coincidence in this one recording:
            #
            #   * `FixtureTotalSteps = 1315` in `debugger/demo_session.nim` is
            #     the recorded trace's STEP count, from `ct-print --summary`
            #     (`traceSteps = 1315` in `demo/generator.nim` says so);
            #   * the Call Trace's `main` row is 1,315 ACIR OPCODES, under an
            #     opcodes header, and `demo_session.fixtureCallTrace` builds
            #     each frame as `frame(name; depth, step: int; cost: string)` —
            #     step and cost are separate fields. `main` begins at step 1.
            #
            # So grouping this readout did not unify two spellings of one
            # number; it made two unrelated numbers character-identical about
            # 700px apart, where before they at least looked unlike. A vd10-r1
            # adversarial reviewer then read the pair as one quantity and
            # derived an arithmetic impossibility from it, which is three
            # readers misled by the same collision, one of them me, in code.
            #
            # The grouping STAYS: it is correct on its own terms and reverting
            # it would restore a difference that only ever signalled the right
            # thing by accident. What is missing is the readout's UNIT, so the
            # two counters stop reading as one — see QUEUED-DECISIONS.md Q20,
            # queued rather than taken because the identity bar is already
            # measured as over-full at 1440.
            text groupDigits(p.step) & " / " & groupDigits(p.totalSteps)

# ── the metadata pane (§7.1) ───────────────────────────────────────────────

proc metaValue(r: MetaRow): string =
  ## The inside of one row's `dd`.
  ##
  ## A proc returning a STRING rather than a block inlined at the two `dd`
  ## branches below, for the reason `layout.hydrationScriptTag` is one: the
  ## branch is over an ATTRIBUTE, and the isonim DSL emits an attribute whose
  ## value is `""` rather than omitting it, so `dd(\`data-provenance\` = r.x)`
  ## put `data-provenance=""` on every row that is not the provenance row —
  ## which would make `grep -c data-provenance` count metadata rows instead of
  ## provenance markers, and turn the one machine-findable guarantee in this
  ## register into a number that is right for the wrong reason.
  ui:
    tdiv:
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

proc metaRows(rows: seq[MetaRow]; cls: string): string =
  ## One `<dl>` of §7.2 facts. Shared by the overview rows and the decoded
  ## input so a row cannot acquire a second presentation by being in the other
  ## list.
  ui:
    dl(class = cls):
      for r in rows:
        dt: text r.label
        # `data-provenance` ONLY on the row that has one — it is the only
        # machine-findable provenance marker in this register, so it must
        # not also appear, empty, on every other fact.
        if r.dataProvenance.len > 0:
          dd(`data-provenance` = r.dataProvenance):
            raw metaValue(r)
        else:
          dd:
            raw metaValue(r)
        # THE NOTE IS ITS OWN `dd`, SPANNING BOTH COLUMNS.
        #
        # A `dt` may have several `dd`s, so this is ordinary markup rather than
        # a trick — and it is what the round that introduced the provenance row
        # asked for. Put inside the value `dd`, the paragraph inherited
        # `.mddl dd`'s `text-align:right`: nine to fifteen lines of prose set
        # flush-right, ragged-left, at a ~28-character measure, in a pane whose
        # two other paragraphs are flush-left. Three adversarial reviewers
        # across three triples independently named it the single weakest
        # element on the page, and several noted the irony directly — the one
        # element carrying the register's honesty claim was its least readable
        # text.
        #
        # Spanning both columns fixes the measure as well as the alignment. The
        # label gutter sat empty beside a paragraph squeezed into the value
        # column, so the row was tall for no reason: reviewers measured it at
        # 39% of the Transaction pane's height, a LARGER share of its new host
        # than the 17% of the viewport the band it replaced had taken.
        if r.note.len > 0:
          dd(class = "rownote"):
            p(class = "reason measure"): text r.note

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

const SelectionSlotId* = "dbg-selection"
  ## The selection section's id. Named here, beside the other two slots, for
  ## the reason `SelfCostViewId` is: the page emits it, the hydration bundle
  ## re-renders into it and a test addresses it, and a third spelling is a
  ## panel that exists and never updates.

proc renderSelection*(d: SelectionDetail): string =
  ## The current selection, as a section of the transaction pane.
  ##
  ## ## It SUPPLEMENTS the transaction's facts and displaces none of them
  ##
  ## Appended below them, not folded into them and not put above them. Three
  ## reasons, in the order they bind:
  ##
  ## 1. `pages/debug.nim` states this pane's own contract — it "is present in
  ##    every state ... because a visitor deep-linked into a stepping session
  ##    still needs to know what they are looking at". The transaction's
  ##    identity is the thing that must not be displaced by a transient
  ##    selection, so replacing part of it is ruled out before taste enters.
  ## 2. The transaction is the STABLE subject and the selection is the moving
  ##    one. A block that re-renders on every step, placed above a block that
  ##    never changes, makes the fixed facts jump on each step.
  ## 3. It costs no new layout. The pane is already a scrolling stack of
  ##    `.mdsec` blocks (`Decoded input`, `Raw (chain-native)`); this is a
  ##    third one, built from the same three elements, so it inherits the
  ##    pane's scrolling and adds no CSS. The design lint (A5/A7) exists to
  ##    stop a view inventing presentation, and reusing the section idiom is
  ##    how this one avoids doing so.
  ui:
    tdiv(class = "mdsec", id = SelectionSlotId):
      span(class = "mdexectitle"): text d.heading
      if d.kind == selNone:
        # A stated absence, in the voice the replay panes already use. An
        # empty section would be indistinguishable from a broken one.
        p(class = "panenote"): text d.note
      else:
        raw metaRows(d.facts, "mddl")

# ── walking the layout ─────────────────────────────────────────────────────

proc paneBody(kind: PaneKind; s: DebugSessionView): string =
  ## Total over `PaneKind`: a pane CodeTracer adds is a compile error here.
  case kind
  # `s.controls` and not just `s.editor`: the pane's position head reads the
  # session's step, and there is exactly one producer of it. See
  # `renderPositionHead`.
  of paneEditor: renderSource(s.editor, s.controls)
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
