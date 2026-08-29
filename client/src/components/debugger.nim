## The debug route's surface: the slim identity bar, the pane arrangement, and
## the six pane renderers.
##
## ## The arrangement is CodeTracer's, consumed rather than restated
##
## `renderLayout` walks a `LayoutNode` — the vendored copy of CodeTracer's
## `headless_app/layout_model.nim` — and turns it into markup:
##
##   `lnRow` / `lnColumn` → a flex container on that axis
##   `weight`             → a flex fraction, via a class from the weight ladder
##   `lnStack`            → tabs, one visible at a time
##   `lnPane`             → the pane renderer for that `PaneKind`
##
## Nothing here decides *what the arrangement is*. `defaultReplayLayout()`
## decides that, and a change upstream to the shape or the weights arrives here
## without an edit. That is the whole reason to consume the model: this is the
## fourth front-end to arrange these five panes, and the previous three
## disagreeing about the default was the problem.
##
## `renderLayout` is total over `LayoutNodeKind` and over `PaneKind`, so a pane
## added to CodeTracer's enum is a compile error here rather than a blank
## region — which is the failure mode `GoldenLayoutResolvedConfig` has today
## and the reason `lpUnknownPane` exists in the model at all.
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
## So the replay region is the walked tree, verbatim, and BlockTracer's own
## pane is composed beside it with the same pane chrome. `Debugger-Integration`
## §3 licenses exactly this: "BlockTracer's contribution is which panes are
## open by default … and the three augmentations in §4."

import std/strutils
import isonim/ssr/escape
import isonim/dsl/ui
import ../debugger/layout_model
import ../debugger/session_view
import ../viewutil

# ── weights → flex fractions ───────────────────────────────────────────────

const MaxWeight* = 12
  ## The weight ladder `debugger_css.nim` emits rules for. `defaultReplayLayout`
  ## uses 1, 2, 3 and 9; the ladder is wider so a change upstream has room, and
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

# ── the five replay panes ──────────────────────────────────────────────────

proc renderSource*(p: EditorPane): string =
  ## The static source renderer.
  ##
  ## Per line: a gutter number, an execution marker, and the text as ONE text
  ## node inside `<code>`. No tokenising, no highlighting, and no library —
  ## and the single text node is the seam that lets a tokeniser be dropped in
  ## later without moving anything around it.
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
            code(class = "t"): text ln.text
            if ln.annotations.len > 0:
              span(class = "ann"):
                for a in ln.annotations:
                  span(class = "annv " & $a.slot):
                    text a.label & "=" & a.value

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
  ui:
    tdiv(class = "srcwrap"):
      raw panels

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
          tdiv(class = "ctrow " & (if indented: depthClass(f.depth) else: "d0 flat") &
                       (if f.current: " cur" else: "")):
            span(class = "ctfn"):
              span(class = "ctname"): text f.fn
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
          span(class = "stval"): text v.value
          span(class = "sttype"): text v.typ

proc renderEventLog*(p: EventLogPane): string =
  if p.rows.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "Calls, storage writes and events come from the execution trace.")
  ui:
    tdiv(class = "ev"):
      for r in p.rows:
        tdiv(class = "evrow k-" & $r.kind & (if r.current: " cur" else: "")):
          span(class = "evglyph"): text eventKindGlyph(r.kind)
          span(class = "evkind"): text eventKindLabel(r.kind)
          span(class = "evstep num"): text $r.step
          span(class = "evlabel"): text r.label
          span(class = "evdetail"): text r.detail

const TimelineTicks = 48
  ## The scrubber is a fixed number of discrete ticks rather than a filled bar,
  ## because a filled bar needs a per-render width and an inline `style`
  ## attribute — which `tools/design/check-tokens.mjs` A5 rejects, correctly:
  ## an inline style is a design value no token layer can reach.

proc renderControls*(p: DebugControlsPane): string =
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
          button(class = "dcbtn" & (if b.enabled: "" else: " off"),
                 title = b.label, `aria-label` = b.label):
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
            span(class = "identifier"): text r.value
          else:
            text r.value
          if r.suffix.len > 0:
            span(class = "muted"): text " " & r.suffix

proc renderMetadata*(m: MetadataPane): string =
  ui:
    tdiv(class = "md"):
      tdiv(class = "mdhero"):
        span(class = "badge " & m.outcomeBadge): text m.outcome
        span(class = "identifier mdhash"): text truncHash(m.hash, 10, 8)
      # The hash IN FULL, below the truncation, exactly as the metadata page's
      # hero renders it (`pages/tx.nim`: a truncated `h1` over a full-hash
      # lead). §7.2 section 1 asks for "hash with copy", and after §7.0 this
      # pane is what a visitor and a crawler are served at the transaction's
      # own canonical URL — a page that states its subject's identity only in
      # two different truncations has lost the fact that identifies it. The
      # slim identity bar keeps its truncation, because §8's collapse is a
      # width constraint and this pane is not under it.
      p(class = "mdfull identifier"): text m.hash
      if m.revertReason.len > 0:
        p(class = "mdrevert " & m.revertReasonTone):
          text m.revertReasonLabel & ": " & m.revertReason
      raw metaRows(m.rows, "mddl")
      if m.executions.len > 0:
        tdiv(class = "mdexec"):
          span(class = "mdexectitle"): text "Executions"
          for e in m.executions:
            tdiv(class = "mdexecrow"):
              span(class = "sel"): text e.selector
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

proc paneClass(kind: PaneKind): string =
  case kind
  of paneEditor: "p-source"
  of paneCalltrace: "p-calltrace"
  of paneState: "p-state"
  of paneEventLog: "p-eventlog"
  of paneDebugControls: "p-controls"
  else: "p-other"

proc paneId(kind: PaneKind): string =
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
