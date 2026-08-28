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
  ui:
    tdiv(class = "srcwrap"):
      if p.documents.len > 1:
        nav(class = "srctabs"):
          for d in p.documents:
            span(class = "srctab" & (if d.path == doc.path: " on" else: "")):
              text d.path
      tdiv(class = "src"):
        for ln in doc.lines:
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

proc renderCallTrace*(p: CallTracePane): string =
  if p.frames.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "The call structure comes from the execution trace.")
  ui:
    tdiv(class = "ct"):
      tdiv(class = "cthead"):
        span(class = "ctfn"): text "Frame"
        span(class = "ctcost"): text p.costLabel
      for f in p.frames:
        tdiv(class = "ctrow d" & $f.depth & (if f.current: " cur" else: "")):
          span(class = "ctfn"):
            span(class = "ctname"): text f.fn
            span(class = "ctmod"): text f.module
          span(class = "ctcost num"): text f.cost
          span(class = "ctunit"): text f.costUnit
      tdiv(class = "ctfoot"):
        text "Sorted by call order."
        span(class = "ctsort"): text "Sort by cost"

proc renderState*(p: StatePane): string =
  if p.values.len == 0:
    return paneNote(if p.note.len > 0: p.note else:
      "Variable values come from the execution trace.")
  ui:
    tdiv(class = "st"):
      for v in p.values:
        tdiv(class = "strow d" & $v.depth & (if v.changed: " chg" else: "")):
          span(class = "stname"): text v.name
          span(class = "sttype"): text v.typ
          span(class = "stval"): text v.value

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
  let filled =
    if not p.positioned: 0
    else: max(1, int(p.fraction * float(TimelineTicks)))
  ui:
    tdiv(class = "dc"):
      tdiv(class = "dcbtns"):
        for b in p.buttons:
          button(class = "dcbtn" & (if b.enabled: "" else: " off"),
                 title = b.label, `aria-label` = b.label):
            span(class = "dcglyph"): text b.glyph
      tdiv(class = "dctl"):
        for i in 1 .. TimelineTicks:
          span(class = "tick" & (if i <= filled: " on" else: ""))
      tdiv(class = "dcstatus"):
        span(class = "dcphase"): text p.statusText
        if p.totalSteps > 0:
          span(class = "dcsteps num"):
            text $p.step & " / " & $p.totalSteps

# ── the metadata pane (§7.1) ───────────────────────────────────────────────

proc renderMetadata*(m: MetadataPane): string =
  ui:
    tdiv(class = "md"):
      tdiv(class = "mdhero"):
        span(class = "badge " & m.outcomeBadge): text m.outcome
        span(class = "identifier mdhash"): text truncHash(m.hash, 10, 8)
      if m.revertReason.len > 0:
        p(class = "mdrevert"):
          text m.revertReasonLabel & ": " & m.revertReason
      dl(class = "mddl"):
        for r in m.rows:
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
      if m.executions.len > 0:
        tdiv(class = "mdexec"):
          span(class = "mdexectitle"): text "Executions"
          for e in m.executions:
            tdiv(class = "mdexecrow"):
              span(class = "sel"): text e.selector
              span(class = "badge " & e.badge): text e.availability
              if e.reason.len > 0:
                span(class = "reason"): text e.reason

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
