## BlockTracer's own arrangement of a replay session, composed from CodeTracer's
## layout primitives.
##
## ## Why this module exists rather than a call to `defaultReplayLayout()`
##
## `layout_model.nim` beside this file is a **byte-verbatim vendored copy** of
## CodeTracer's `src/frontend/headless_app/layout_model.nim`, guarded by
## `ci/test/layout-model-vendor.sh` — a hash manifest plus a probe that imports
## both modules and compares `defaultReplayLayout()`, `allPanes`, `visiblePanes`,
## the enum spellings and `validate`. Editing it to change BlockTracer's
## arrangement would fail that check, correctly: the copy's whole value is that
## it cannot drift.
##
## The alternative — changing CodeTracer's model upstream and re-vendoring —
## would move the **desktop app's** default layout and its pane naming as a side
## effect of a web decision. Debugger-Integration.md §3 does not ask for that.
## It says BlockTracer's arrangement is *inspired by* CodeTracer's default, and
## names the embedder's contribution as "which panes are open by default": the
## SDK boundary (CodeTracer-Embed-SDK.md §3.2, row 1) puts arranging panes on
## the consumer's side of the line. So the model stays byte-identical and only
## the **composition** differs — which is what these primitives are for.
##
## Concretely, this module writes down three BlockTracer decisions that
## CodeTracer's desktop default has no reason to share:
##
##   1. **The debug controls are not a pane here.** They render in the identity
##      bar (`pages/debug.nim`), so `paneDebugControls` is deliberately absent
##      from this tree. See `ControlsArePlacedInTheBar` below.
##   2. **Call Trace and Event Log are one tabbed region**, Call Trace active,
##      with Values below it — the session's navigation column.
##   3. **Titles are BlockTracer's**: `paneEditor` is labelled **Code** and
##      `paneState` is labelled **Values**. `title` is a parameter of `pane()`,
##      so both are labels and neither touches the enum or its wire spelling.
##
## ## The titles, and why they are not the enum
##
## `PaneKind`'s spellings (`"editor"`, `"state"`) are a **serialisation**
## concern shared with the Embed SDK — `saveLayout`/`restoreLayout` write them,
## and `debugger.paneId` derives `pane-editor` from them, which is the id a deep
## link and the capture harness address. Renaming a label is free; renaming the
## enum is a cross-repo change to a wire format. This module does the first and
## not the second, so `pane-editor` remains the element id of the pane titled
## "Code".
##
## **Code, not Editor.** The pane is a read-only listing, there is no editor
## behind it and there is not going to be one; and at instruction-level fidelity
## (`srcUnverified`) what it lists is not source at all. "Code" is the honest
## word for both cases, where "Editor" is wrong in the first and "Source" is
## wrong in the second.
##
## **Values, not State.** Etherscan and Blockscout both ship a transaction tab
## called `State`, and it means an aggregate state *diff* for the whole
## transaction. This pane shows variable values *at step N*. Two different
## things under one word in one product category is a collision worth one word
## to avoid, and the transaction page is where an aggregate `State` would belong
## if we ever add one.

import ./layout_model

const ControlsArePlacedInTheBar* = paneDebugControls
  ## The one pane of `ReplayCorePanes` that `blockTracerReplayLayout()` does
  ## NOT place, named here so its absence is a written decision rather than an
  ## omission a reader has to notice.
  ##
  ## Every serious recorded-execution tool makes *selection* the primary
  ## gesture and *stepping* the secondary one; the desktop default has the
  ## controls as a full-width band above everything, which ranks stepping first.
  ## They move to the identity bar — still on screen, still one glance away,
  ## no longer the largest interactive object on the page — and the band's
  ## height goes to the panes that answer "where in this execution do I want to
  ## be".
  ##
  ## This is the same move the metadata pane makes in the other direction
  ## (`components/debugger.nim`): a pane composed beside the walked tree rather
  ## than inside it. `pages/debug.nim` renders it, and
  ## `tests/test_debug_route.nim` asserts it is in the bar and not in the tree,
  ## so "moved" cannot decay into "dropped".

proc blockTracerReplayLayout*(): LayoutNode =
  ## The arrangement `/{chain}/tx/{hash}/debug` opens with.
  ##
  ## One row, four panes, no stack:
  ##
  ##   ┌────────────────────────────┬──────────────────┐
  ##   │                            │ Call Trace   (4) │
  ##   │                            │ ┌──────────┬───────────┐ │
  ##   │                            │ │CALL TRACE│ EVENT LOG │ │
  ##   │ Code                  (3)  │ └──────────┴───────────┘ │
  ##   │                            │      one region     (3)  │
  ##   │                            ├──────────────────────────┤
  ##   │                            │ Values              (2)  │
  ##   └────────────────────────────┴──────────────────────────┘
  ##                (3)                        (2)
  ##
  ## **Call Trace and Event Log are one tabbed region, Call Trace active.**
  ## They are the same execution indexed two ways — by call structure and by
  ## chronological event — and reading one to decide where to jump is the same
  ## gesture as reading the other. Tabs are how that pairing is drawn: two peers
  ## in one region, each the full height of it, one strip naming both. The
  ## alternative this replaced — stacking them as separate panes — expressed the
  ## same pairing by adjacency and paid for it in density: three list panes at
  ## one row pitch in one column read as one undifferentiated run of rows, and
  ## each of the three got a third of a column it could not use.
  ##
  ## `activeIndex = 0`, so **Call Trace is what opens**. Selection is the
  ## primary navigation gesture in this category and the call trace is the
  ## primary selection surface; the Event Log is the second way to ask the same
  ## question, which is what a second tab is for. This is also the arrangement
  ## the `:target` tab CSS is exactly correct for — `renderStack` marks the
  ## first tab as active and the first child IS the default here, where the
  ## layout this replaced had a stack whose active child was its second.
  ##
  ## **Values sits below the region, not inside it.** It is not a third way of
  ## finding a position: it answers "what is true here", which is a question you
  ## ask *after* you have arrived. Putting it in the tab strip would rank it as
  ## an alternative to navigating, and hiding it behind a tab is what this
  ## milestone spent hiding the Event Log.
  ##
  ## **Code keeps the full height of the region.** It is the pane whose content
  ## is longest and whose usefulness is most directly a function of how many
  ## rows fit, and the band the debug controls used to occupy above everything
  ## is now its height too. Nothing was put under it.
  ##
  ## The weights: the navigation region takes three fifths of its column and
  ## Values two. The region is the surface that answers "where in this execution
  ## do I want to be" and it now serves two panes rather than one, so it keeps
  ## the larger share; Values keeps a definite two fifths rather than the third
  ## of a column it had, which is what stops it from becoming a strip.
  row([
    pane(paneEditor, "Code", weight = 3.0),
    column([
      stack([
        pane(paneCalltrace, "Call Trace"),
        pane(paneEventLog, "Event Log")],
        activeIndex = 0, weight = 3.0),
      pane(paneState, "Values", weight = 2.0)],
      weight = 2.0)],
    weight = 1.0)
