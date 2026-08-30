## `/{chain}/tx/{hash}/debug` — Page-Descriptions §8, Debugger-Integration §3.
##
## The full-viewport route: the explorer chrome collapses to a slim identity
## bar and the rest of the viewport goes to the session. Two things §8 is
## explicit about and this page therefore does:
##
##   * **The transaction's facts are not lost to that collapse.** The metadata
##     pane (§7.1) is present in every state, including the states where no
##     session can open, because a visitor deep-linked into a stepping session
##     still needs to know what they are looking at.
##
##   * **The divergence banner sits above the debugger and cannot be
##     dismissed.** It is markup with no dismiss control, not a control that is
##     disabled.
##
## ## This page is also what the TRANSACTION route serves (§7.0)
##
## §7.0: "Both addresses reach the same session; they differ in what the
## visitor asked for." `ssr.renderTx` renders **this procedure**, over the
## **same** `debugSessionFor` value, wherever `trace.availability` is `ready`
## or `divergent`. The served bodies are therefore byte-identical, and the two
## routes differ only in the head elements that describe the request — the
## `<title>` and the description — and in which address is submitted to a
## crawler. That is the only way "the same session" can be a property of the
## markup rather than an intention; `test_debug_route` asserts the body
## equality and ENUMERATES the permitted head differences, so a third one
## cannot appear unnoticed.
##
## What the debug address adds is what a visitor asks it for: the viewport
## without ambiguity, and `?t=` as a deep-link coordinate (§8). What the
## transaction address adds is that it is the canonical, submitted URL for the
## transaction. Neither adds a pane.
##
## ## What decides what the visitor lands in
##
## `trace.availability`, and nothing else — no query parameter, no preference,
## no capability probe. `demo_session.demoSession` resolves it into a
## `SessionPhase` and this page renders that phase. `?t=`, `?pane=` and the
## rest select a POSITION inside a session that availability has already
## decided exists; they can never conjure one.
##
## ## What this page is not doing yet, stated rather than implied
##
## It renders the session's **first frame** from published data plus the demo
## session fixture. It does not run a replay engine: that is
## `WorkerBackendService` over DAP-on-`postMessage` (Debugger-Integration §2)
## driving the already-published browser bundle from
## `replay_engine.ReplayEngineBase`, and until it lands `phase` stays
## `spFetching` and the stepping controls render visibly inert.
##
## **That fact is carried by the controls, not by a paragraph** (revised
## 2026-08-29). There used to be an `engineNotice` row above the session —
## *"This is the session's first frame, rendered from published data. Stepping
## starts once the replay engine loads — 18 MB, fetched once and cached."* —
## and it is gone. It was an artefact of hydration not existing yet: a
## page-level explanation of why the buttons two rows down do nothing, spending
## a full band of a full-viewport surface to say something the buttons are
## better placed to say themselves. What it actually contributed is kept, in
## three places that are attached to the thing they describe: the controls'
## own status (`Engine loading — 18 MB`), the phase rail beside it, and each
## inert button's `aria-disabled` and title. Its third claim — the engine's
## origin, when a build names a cross-origin one — moves to `data-replay-engine`
## on the root, which every build already carried.
##
## Nothing here has to change when hydration lands — the panes render a
## `DebugSessionView`, hydration produces one with `phase == spReady`, and
## every affordance on this page is already gated on that rather than on the
## presence of content.

import isonim/ssr/escape
import isonim/dsl/ui
import ../debugger/deeplink_landing
import ../debugger/session_layout
import ../debugger/session_view
import ../debugger/source_document
import ../debugger/source_island
import ../components/debugger
import ../components/icons
import ../viewutil

# The three names the identity bar's two actions answer to. Each is the
# `aria-label` AND the `title` of an icon-only control, so a screen-reader user
# and a pointer user are told the same thing — written once here rather than
# twice at each call site, where the two could drift into a control that is
# announced as one action and tipped as another.
const
  SharePositionLabel = "Share this position"
  ShareUnanchoredLabel = "Share — a share link needs a position to anchor to"
  DownloadTraceLabel = "Download trace"

type SharePosition = object
  ## What a Share control needs: the §6.0a anchor for the payload, and the
  ## element id for the fragment.
  anchor*: string     ## `src:src/shield.nr:32` — §6.0a's `a`
  element*: string    ## `L-src-shield-nr-32` — the id the page scrolls to

proc sharePosition(s: DebugSessionView): SharePosition =
  ## The share payload's anchor and the fragment's scroll target, from the line
  ## the session is on.
  ##
  ## M8a: "Share **always** emits an anchor, never `t` alone." A time
  ## coordinate is a *witness*, not a stable coordinate — §6.0a is explicit
  ## that a regenerated trace can move it — and a link carrying only `t` lands
  ## silently in the wrong place. The anchor is what a witness mismatch
  ## recovers through, so a share control that cannot produce one is a control
  ## that would emit the link the spec forbids.
  ##
  ## The two are different things and used to be one. §6.0a's `src` anchor is
  ## *file plus line* — a property of the transaction, which a reader's client
  ## resolves against whatever trace it opens; `SourceLine.anchor` is an HTML
  ## element id derived from the same pair, for scrolling this document. The
  ## payload carried the element id, which no client could resolve as an
  ## anchor, so every share link was a `t` with a decoration where its recovery
  ## anchor should have been. Both are emitted now, each where it means
  ## something: the anchor in `a=`, the id in the fragment, so a visitor with no
  ## script still lands on the line and a visitor with one recovers the
  ## position when the coordinate no longer transfers.
  for d in s.editor.documents:
    for ln in d.lines:
      if ln.current:
        return SharePosition(anchor: "src:" & d.path & ":" & $ln.number,
                             element: ln.anchor)

proc identityBar(s: DebugSessionView): string =
  ## Debugger-Integration §3's slim bar: back link, identity, status, block,
  ## **the stepping controls**, and the two actions a session offers — share
  ## and container download.
  ##
  ## The back link targets the CHAIN, which is what its label has always said.
  ## It used to target the transaction's own URL, on the model of §8's "a link
  ## back to the detail page" — but §7.0 makes that URL this same session, so
  ## the link had become a self-link on one route and a link to an identical
  ## page on the other. The chain overview is the surface a visitor actually
  ## leaves a session for, and it is the outbound link a `noindex,follow`
  ## crawl of this page needs.
  ##
  ## ## Why the controls are here (revised 2026-08-29)
  ##
  ## They were a full-width `paneDebugControls` pane across the top of the
  ## replay region, weight 1 — the largest interactive object on the page.
  ## Every serious recorded-execution tool makes *selection* the primary
  ## navigation gesture and *stepping* the secondary one; Tenderly, Sentio,
  ## Pernosco, WinDbg TTD, Replay.io and Chrome's performance panel all
  ## navigate by clicking a trace, an event or a timeline element, and Pernosco
  ## says outright that single-stepping is what developers reach for when they
  ## are "afraid of going too far forward". Ranking the toolbar above the call
  ## trace was a habit inherited from a desktop debugger, and the band it
  ## occupied is height the panes that answer "where do I want to be" now have.
  ##
  ## The controls are not diminished by the move: they are on screen at all
  ## times, in the one strip that never scrolls, beside the identity of the
  ## thing they step through. What changed is the ranking, not the presence —
  ## `test_debug_route.nim` asserts they render in the bar and not in the tree,
  ## so "moved" cannot quietly become "dropped".
  ##
  ## The control group takes the width its contents need; the slack goes to the
  ## spacer after it. The scrubber is deliberately NOT the elastic member —
  ## letting the one element that would happily grow absorb every spare pixel
  ## made a uniform-step readout the largest object in the bar, which is the
  ## opposite of the ranking this change is making.
  ui:
    header(class = "dbgbar"):
      a(class = "dbgback", href = chainUrl(s.chain)):
        text "← " & s.chain
      # Truncated for the bar, so the full value rides on `title` and
      # `data-copy` rather than being selectable as an ellipsis. See
      # `components/debugger.Copyable`.
      span(class = "dbgid identifier", title = s.txHash,
           `data-copy` = s.txHash): text truncatedHash(s.txHash)
      span(class = "badge " & s.outcomeBadge): text s.outcomeLabel
      span(class = "dbgblock num"): text "block " & $s.blockHeight
      # Trace-Artifacts.md §2.3a: a trace can be `ready` AND heuristically
      # reconstructed, and "presenting the second as a native execution trace
      # is the confident lie". So it is stated on the bar, beside the identity,
      # rather than left to the absence of a contradiction.
      if s.reconstructed:
        span(class = "badge warn",
             title = "Reconstructed from chain data rather than recorded by " &
                     "a native tracer."):
          text "Reconstructed"
      # The controls, and the phase they are waiting on, as one group. Gated on
      # `hasFrame` for the same reason Share and Download are: §7.0's `absent`,
      # `unsupported` and `onDemand` rows get "no debugger, and no pretence of
      # one", and a stepping toolbar over a trace that was never recorded is
      # the clearest possible pretence.
      if s.hasFrame:
        tdiv(class = "dbgctl"):
          # Both halves of the group, from the shared renderers, so hydration
          # can replace this one element's contents with the same two calls.
          raw renderControls(s.controls)
          raw renderPhaseRail(s)
      # The spacer, always, and AFTER the control group. The slack belongs
      # between the session's controls and the page's actions, not inside the
      # scrubber — see `.dbgctl` in `debugger_css.nim` for why the one element
      # here that would happily grow is the one that must not.
      span(class = "dbgspacer")
      if s.languages.len > 0:
        span(class = "dbglang"): text joinLanguages(s)
      # Both actions are gated on there being a session to act on. A share
      # link to a coordinate in a trace that was never recorded, or a download
      # of a container that was never published, is exactly the "pretence of
      # one" §7.0 rules out — and `containerPath` is DERIVABLE for an
      # on-demand execution, so its non-emptiness proves nothing.
      #
      # ## Why they are marks and not words (revised 2026-08-30)
      #
      # The bar could not hold its contents on one line and had a forced wrap
      # to prove it: `.dbgspacer` became a full-width break below 1600px, which
      # put the language tag and both actions on a row of their own at every
      # laptop viewport, and below 1366px the control group took a THIRD row.
      # Measured at 1440: 1600px of content in a 1392px box.
      #
      # "Share" and "Download trace" were 160 of those pixels, for two
      # SECONDARY actions sitting beside the controls that are the reason this
      # bar exists. A mark plus an accessible name costs 68 and says the same
      # thing to a screen reader, so this is the cheapest 92px on the line —
      # see `debugger_css.nim` for the other two cuts and the arithmetic.
      #
      # They stay a real `<a>` and a real `<button>`, which is not a detail:
      # `role="button"` on a `tdiv` is a control that neither Enter nor Space
      # activates, and it shipped on this route once already. An `<a href>` is
      # activated by Enter, a `<button>` by Enter and Space, both are in the
      # tab order, and none of that is code anybody here has to write or
      # remember. `aria-label` gives the icon-only control the name its text
      # used to give it; `title` gives a pointer user the same words.
      #
      # The identity beside them is NOT re-cut to make room. It is already
      # truncated, and it already carries `data-copy` with the full hash for
      # the hydration that turns it into a copy button — adding a copy
      # affordance here would be a second one of those on the same value.
      if s.canShare:
        let share = sharePosition(s)
        # One group, so the two actions cannot be separated from each other by
        # a wrap: a bar that breaks between Share and Download reads as two
        # unrelated strips, which is the fault the old forced break existed to
        # avoid and is now avoided by grouping rather than by breaking.
        tdiv(class = "dbgacts"):
          if share.anchor.len > 0:
            a(class = "btn ghost sm icon",
              href = positionQuery(s.traceContentHash, s.timeCoordinate,
                                   share.anchor) & "#" & share.element,
              title = SharePositionLabel, `aria-label` = SharePositionLabel):
              raw shareMark()
          else:
            button(class = "btn disabled sm icon",
                   title = ShareUnanchoredLabel,
                   `aria-label` = ShareUnanchoredLabel,
                   `aria-disabled` = "true"):
              raw shareMark()
          if s.containerPath.len > 0:
            a(class = "btn ghost sm icon", href = "/" & s.containerPath,
              download = "trace.ct",
              title = DownloadTraceLabel, `aria-label` = DownloadTraceLabel):
              raw downloadMark()

proc banner(s: DebugSessionView): string =
  ## Above the debugger, never inside it, and with no dismiss control.
  case s.integrity
  of siDivergent:
    ui:
      tdiv(class = "dbgbanner bad", role = "alert"):
        span(class = "bannertitle"): text "Divergent trace"
        span(class = "bannertext"): text s.integrityDetail
  of siTruncated:
    ui:
      tdiv(class = "dbgbanner warn", role = "status"):
        span(class = "bannertitle"): text "Truncated trace"
        span(class = "bannertext"): text s.integrityDetail
        button(class = "btn ghost sm"): text "Request a deeper profile"
  of siValidated, siUnknown:
    ""

proc noSession(s: DebugSessionView): string =
  ## §7.0's non-session rows, in the region the panes would have occupied.
  ##
  ## `onDemand` offers the generate action; `absent` and `unsupported` state
  ## the reason and offer NOTHING — "no debugger, and no pretence of one".
  ui:
    tdiv(class = "ln col w4 nosession"):
      section(class = "pane w1"):
        header(class = "panehead"):
          span(class = "panetitle"): text phaseLabel(s.phase)
        tdiv(class = "panebody"):
          tdiv(class = "nostate"):
            p(class = "panenote measure"): text s.unavailableReason
            # The pipeline's own words beneath ours, never merged into them.
            # See `session_view.DebugSessionView.unavailableDetail`.
            if s.unavailableDetail.len > 0:
              p(class = "panenote measure reason"): text s.unavailableDetail
            if s.phase == spAwaitingGeneration:
              tdiv(class = "norow"):
                button(class = "btn primary"): text "Generate trace"
                span(class = "panenote"):
                  text "Generating a trace costs us compute, so it needs a " &
                       "signed-in account with quota remaining."

proc debugPage*(s: DebugSessionView): string =
  ## The whole route.
  var s = s
  # The WHOLE bundle, before the window is taken. `openAtCurrent` below reduces
  # each document to the lines around the position, which is right for a page
  # that cannot scroll and wrong for a session that can move: the first step
  # out of that window needs a line the served DOM does not hold. So the island
  # is encoded from the complete documents, here, and the window is taken
  # after. See `source_island.nim`.
  let sourceIsland = (if s.hasFrame: encodeSourceIsland(s.editor) else: "")
  # The session is POSITIONED, which means the pane opens on the position. A
  # document rendered from line 1 leaves the current line wherever the file
  # puts it — at `laptop` the fixture's line 32 falls below the fold, so the
  # toolbar claims a step and no pane shows it. That is a presence failure
  # against this view's own "must show", and it is invisible at `wide`, which
  # is why deliverable 1 reviews both viewports rather than the widest.
  s.editor = openAtCurrent(s.editor, SourceLeadIn)
  let replay =
    if s.hasFrame: renderLayout(blockTracerReplayLayout(), s)
    else: noSession(s)
  ui:
    tdiv(class = "dbg", `data-replay-engine` = s.engineBase,
         `data-session-phase` = $s.phase,
         # The three facts hydration cannot derive from the rendered panes: the
         # container it must fetch, and the position the served frame is at.
         # Carried on the root rather than inlined into the bundle, because the
         # bundle is ONE file served to every transaction and these differ per
         # transaction — a build-time constant here would make every session
         # step through the first one's trace.
         #
         # `data-trace` is `canShare`'s predicate and not `containerPath`'s.
         #
         # That distinction is not defensive coding, it is this page's own
         # warning taken seriously: "`containerPath` is DERIVABLE for an
         # on-demand execution, so its non-emptiness proves nothing". The demo
         # tree has exactly such a transaction, and reading the raw path here
         # gave it a `data-trace` pointing at a container that 404s — while the
         # download button beside it, which reads `canShare`, correctly offered
         # nothing. Two predicates for "is there a container", disagreeing.
         #
         # So there is one. Hydration is offered a container on exactly the
         # transactions the visitor is offered one, and on the others it does
         # what §7.0's `onDemand` row says: no engine, and no pretence of one.
         `data-trace` = (if s.canShare: "/" & s.containerPath else: ""),
         `data-step` = $s.controls.step,
         `data-total-steps` = $s.controls.totalSteps,
         # §6.0's content witness needs something to be a witness OF. The
         # comparison happens in a browser, before the engine has opened
         # anything, against "the artifact currently recommended" — which is a
         # fact of the published tree that this page has already resolved and
         # the bundle has no other way to learn. Emitted for every state,
         # including the ones with no container: an empty value is `absent`,
         # which §6.0's table treats as unverifiable rather than as agreement.
         `data-content-hash` = s.traceContentHash):
      raw identityBar(s)
      raw banner(s)
      # The engine's own verdict, when hydration has one. Always emitted and
      # always empty here: a statically exported page has not tried to load an
      # engine, so it has nothing to report and `.dbgnotices:empty` hides the
      # slot. `hydrate.markUnavailable` writes into it through the SAME renderer
      # that would have drawn it from here, which is the rule every surface on
      # this route follows.
      #
      # ABOVE the position notice, because they answer different questions and
      # one outranks the other: "the engine will not run" makes "the link landed
      # on the nearest enclosing frame" a detail about a session that is not
      # going to move.
      tdiv(class = "dbgnotices", id = EngineFailureSlotId)
      # §6.0a's landing notice. Empty on every statically exported page, and
      # necessarily so: the payload is in the query, and a static route serves
      # one file per PATH — `?t=` cannot select a rendering. The resolution
      # therefore happens in the browser, and this is the slot it writes into.
      #
      # Rendered through the same producer either way, so the sentence a
      # hydrated page shows is the one this renderer would have written. That
      # is the rule every surface on this route follows and the reason the pane
      # renderers are reachable from a `nim js` build at all.
      tdiv(class = "dbgnotices", id = PositionNoticeSlotId):
        raw renderPositionNotice(s)
      tdiv(class = "dbgnarrow"):
        # Named by their pane TITLES, so the sentence and the headers a reader
        # can see agree. It said "source, call trace and values" while the
        # panes were titled Editor, Call Trace and State — two of three wrong.
        text "Narrow session: Code, Call Trace and Values only, read-only. " &
             "The event log and stepping need a wider viewport."
      tdiv(class = "dbgmain"):
        tdiv(class = "ln row w4 replayregion"):
          raw replay
        section(class = "pane p-metadata w1", id = "pane-metadata"):
          header(class = "panehead"):
            span(class = "panetitle"): text "Transaction"
            # No dismiss control.
            #
            # It had one, and nothing was behind it: the page ships no
            # JavaScript, so the `×` was the single affordance here not held to
            # the standard the stepping toolbar holds itself to two panes away,
            # where every button that cannot act renders visibly inert. It was
            # also the only pane header carrying one — the editor, call trace,
            # state and controls panes have none — so it made the pane §7.1
            # calls "a pane in the session, beside the debugger's own panes"
            # read as a sidebar that happens to be styled as a pane.
            #
            # And dismissing it is a thing this page must not offer anyway.
            # This module's own contract is that the metadata pane "is present
            # in every state, including the states where no session can open,
            # because a visitor deep-linked into a stepping session still needs
            # to know what they are looking at". A control whose success would
            # violate the page's stated invariant is not a control that is
            # merely unimplemented.
          tdiv(class = "panebody"):
            raw renderMetadata(s.metadata)
      # The source bundle, as DATA (§7.0's "data-inlined HTML").
      #
      # `type="application/json"` is not an executable script type: a browser
      # does not parse or run it, and it reaches the page as the contents of an
      # element. That distinction is the whole reason this is allowed on a
      # route whose contract is that it ships nothing that could act — it is
      # markup carrying text, in the same standing as `data-copy` and
      # `data-step`, and with scripting off it is inert bytes that render
      # nothing.
      #
      # Emitted only where there is a frame, because that is the only state
      # whose panes have a document to carry.
      if sourceIsland.len > 0:
        script(`type` = "application/json", id = SourceIslandId):
          # Pre-escaped by `encodeSourceIsland` — every `<` is `<`, so the
          # element cannot be closed early by its own contents.
          raw sourceIsland
