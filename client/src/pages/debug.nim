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
## session fixture, and it says so on the page. It does not run a replay
## engine: that is `WorkerBackendService` over DAP-on-`postMessage`
## (Debugger-Integration §2) driving the already-published browser bundle from
## `replay_engine.ReplayEngineBase`, and until it lands `phase` stays
## `spFetching`, the stepping controls render visibly inert, and the honest
## loading line names what is missing and how big it is.
##
## Nothing here has to change when it does — the panes render a
## `DebugSessionView`, hydration produces one with `phase == spReady`, and
## every affordance on this page is already gated on that rather than on the
## presence of content.

import isonim/ssr/escape
import isonim/dsl/ui
import ../debugger/layout_model
import ../debugger/replay_engine
import ../debugger/session_view
import ../components/debugger
import ../viewutil

proc shareAnchor(s: DebugSessionView): string =
  ## The `a=` anchor of the share payload (Debugger-Integration §6.0a), as the
  ## stable id of the line the session is on.
  ##
  ## M8a: "Share **always** emits an anchor, never `t` alone." A time
  ## coordinate is a *witness*, not a stable coordinate — §6.0a is explicit
  ## that a regenerated trace can move it — and a link carrying only `t` lands
  ## silently in the wrong place. The anchor is what a witness mismatch
  ## recovers through, so a share control that cannot produce one is a control
  ## that would emit the link the spec forbids.
  for d in s.editor.documents:
    for ln in d.lines:
      if ln.current: return ln.anchor
  ""

proc identityBar(s: DebugSessionView): string =
  ## Debugger-Integration §3's slim bar: back link, identity, status, block,
  ## and the two actions a session offers — share and container download.
  ui:
    header(class = "dbgbar"):
      a(class = "dbgback", href = txUrl(s.chain, s.txHash)):
        text "← " & s.chain
      span(class = "dbgid identifier"): text truncatedHash(s.txHash)
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
      span(class = "dbgspacer")
      if s.languages.len > 0:
        span(class = "dbglang"): text joinLanguages(s)
      # Both actions are gated on there being a session to act on. A share
      # link to a coordinate in a trace that was never recorded, or a download
      # of a container that was never published, is exactly the "pretence of
      # one" §7.0 rules out — and `containerPath` is DERIVABLE for an
      # on-demand execution, so its non-emptiness proves nothing.
      if s.canShare:
        let anchor = shareAnchor(s)
        if anchor.len > 0:
          a(class = "btn ghost sm",
            href = "?t=" & $s.timeCoordinate & "#" & anchor):
            text "Share"
        else:
          button(class = "btn disabled sm",
                 title = "A share link needs a position to anchor to."):
            text "Share"
        if s.containerPath.len > 0:
          a(class = "btn ghost sm", href = "/" & s.containerPath,
            download = "trace.ct"):
            text "Download trace"

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

proc phaseRail(s: DebugSessionView): string =
  ## §8: "Loading is phased and honest — fetching, then opening, then
  ## positioning — never an indeterminate spinner."
  ##
  ## Rendered whenever the engine is not live, which on a statically exported
  ## page is always. The three phases are named as words and the current one is
  ## marked, so the visitor can see which phase they are in and what remains —
  ## which is the requirement, and is not the same thing as a spinner.
  ##
  ## Nothing here is a skeleton. The panes behind this rail are already full:
  ## the loading design exists because the engine is an 18 MB wasm bundle, and
  ## the answer to that is to show the frame we already have rather than to
  ## draw grey boxes shaped like it.
  if s.engineLive: return ""
  ui:
    tdiv(class = "phaserail"):
      for p in [spFetching, spOpening, spPositioning]:
        span(class = "phase" & (if p == s.phase: " on" else: "")):
          text phaseLabel(p)

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
            if s.phase == spAwaitingGeneration:
              tdiv(class = "norow"):
                button(class = "btn primary"): text "Generate trace"
                span(class = "panenote"):
                  text "Generating a trace costs us compute, so it needs a " &
                       "signed-in account with quota remaining."

proc engineNotice(s: DebugSessionView): string =
  ## The honest loading line, above the session and below the banner.
  ##
  ## It states three things a spinner cannot: WHAT is being waited for, HOW
  ## BIG it is, and — when the build points at another origin — WHERE it comes
  ## from. The last is not decoration: a page that fetches 18 MB from a third
  ## party should say which one, and `replay_engine.nim` makes a cross-origin
  ## base an explicit build decision rather than a default.
  if s.engineLive or not s.hasFrame: return ""
  ui:
    tdiv(class = "enginenotice"):
      span(class = "enginetext"):
        text "This is the session's first frame, rendered from published " &
             "data. Stepping starts once the replay engine loads — " &
             approxMegabytes(s.engineBytes) & ", fetched once and cached."
      raw phaseRail(s)
      if s.engineCrossOrigin:
        span(class = "engineorigin"):
          text "Engine: " & s.engineBase

proc debugPage*(s: DebugSessionView): string =
  ## The whole route.
  let replay =
    if s.hasFrame: renderLayout(defaultReplayLayout(), s)
    else: noSession(s)
  ui:
    tdiv(class = "dbg", `data-replay-engine` = s.engineBase,
         `data-session-phase` = $s.phase):
      raw identityBar(s)
      raw banner(s)
      raw engineNotice(s)
      tdiv(class = "dbgnarrow"):
        text "Narrow session: source, call trace and values only, read-only. " &
             "Stepping needs a wider viewport."
      tdiv(class = "dbgmain"):
        tdiv(class = "ln row w4 replayregion"):
          raw replay
        section(class = "pane p-metadata w1", id = "pane-metadata"):
          header(class = "panehead"):
            span(class = "panetitle"): text "Transaction"
            button(class = "panedismiss", title = "Dismiss pane",
                   `aria-label` = "Dismiss pane"):
              text "×"
          tdiv(class = "panebody"):
            raw renderMetadata(s.metadata)
