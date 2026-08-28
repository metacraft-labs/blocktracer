## Home (`/`) — Page-Descriptions §2. Not a dashboard: one sentence explaining
## the product, a search box (a stub target — see components/nav), and the chain
## strip. Deliberately no live tickers or price widgets.

import std/options
import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../viewutil
import ../debugger/layout_model
import ../debugger/session_view
import ../components/debugger

proc liveDemo(demo: DebugSessionView): string =
  ## The embedded, pre-baked debugging session (VD.3's `home--live-demo`).
  ##
  ## It is the real session surface — the same `renderLayout` walk over the
  ## same `LayoutNode`, the same pane renderers, positioned mid-trace — inside
  ## a bounded panel, not a video, not a screenshot and not a skeleton. A
  ## marketing page that shows a picture of a debugger is the failure mode the
  ## view's anti-requirements name, and reusing the route's own renderers is
  ## what makes it structurally impossible here.
  ##
  ## The panel is product register inside an explorer-register page. §2 of
  ## Design-System.md makes that crossing deliberate, so it is drawn as a
  ## bounded, elevated surface rather than left to bleed.
  ui:
    tdiv(class = "livedemo", id = "live-demo", `data-register` = "debugger"):
      tdiv(class = "dbgmain"):
        raw renderLayout(defaultReplayLayout(), demo)
      tdiv(class = "livedemofoot"):
        span:
          text "A real session, stopped mid-execution at step " &
               $demo.controls.step & " of " & $demo.controls.totalSteps & "."
        a(class = "btn primary", href = txUrl(demo.chain, demo.txHash) & "/debug"):
          text "Open the full session"

proc homePage*(infos: seq[ChainInfo];
               demo: Option[DebugSessionView] = none(DebugSessionView)): string =
  ui:
    section(class = "sec hero"):
      tdiv(class = "inner"):
        h1(class = "display"):
          text "The "
          span(class = "accent"):
            text "deepest"
          text " view into every transaction."
        p(class = "lead sub"):
          text "Step and rewind every instruction. See the full call trace "
          text "at a glance. Trace any value to its origin — across many "
          text "chains, VMs and languages."
        form(class = "search", action = "/search", `method` = "get"):
          input(name = "q", placeholder = "Paste a block, tx hash, or address")
          button(class = "btn primary", `type` = "submit"):
            text "Search"
        tdiv(class = "chainstrip"):
          for info in infos:
            a(class = "chaincard", href = chainUrl(info.slug)):
              tdiv(class = "name"): text info.slug
              tdiv(class = "meta"):
                text $info.blockCount & " blocks · " & $info.txCount & " txs · head " & $info.headHeight
        # Rendered only when the tree actually has a replayable transaction to
        # show. A placeholder panel that says "the demo will appear here" is
        # the marketing surface pretending to have the product, which is worse
        # than a page that simply does not carry one.
        # `hasFrame`, not `phase == spReady`: the embed IS the pre-hydration
        # frame — a real positioned session rendered from published data — and
        # gating on a live engine would leave the marketing page with nothing
        # to show until hydration exists.
        if demo.isSome and demo.get.hasFrame:
          raw liveDemo(demo.get)
