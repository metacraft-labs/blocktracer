## Home (`/`) — Page-Descriptions §2. Not a dashboard: one sentence explaining
## the product, a search box (a stub target — see components/nav), and the chain
## strip. Deliberately no live tickers or price widgets.

import std/options
import isonim/ssr/escape
import isonim/dsl/ui
import ../reader
import ../components/provenance
import ../viewutil
import ../debugger/session_layout
import ../debugger/session_view
import ../components/debugger

func stripOrder*(infos: seq[ChainInfo]): seq[ChainInfo] =
  ## The order the home strip offers chains in: captured chains first, then
  ## everything else, stable within each group.
  ##
  ## WHY THIS IS WRITTEN DOWN AT ALL. Until now the strip's order was whatever
  ## `chains()` returned, which is the registry's key order — lexicographic. The
  ## synthetic demo chain led the strip because `aztec` sorts before
  ## `aztec-mainnet`, so the first thing a first-time visitor was offered was
  ## three blocks of data that exists on no network, ahead of two chains with
  ## four hundred. Nothing decided that; the alphabet did.
  ##
  ## What a visitor sees first is a product decision, and a product decision
  ## that is a byproduct of a sort key changes silently the moment a chain is
  ## renamed — which is the exact failure `provenanceBanner` refuses when it
  ## declines to key off the slug. So the ordering is stated here, keyed off the
  ## same published provenance the badges are, and a chain the generation says
  ## nothing about sorts with the synthetic ones rather than ahead of them.
  ##
  ## The demo chain is NOT hidden and does not lose its badge. It stops leading,
  ## which it only ever did by accident.
  ##
  ## The rule itself moved to `components/provenance.captureFirst` when `/chains`
  ## turned out to need the same one — see there for why it is a shared proc and
  ## not a second loop that agrees with this one today.
  captureFirst(infos, proc(i: ChainInfo): string {.noSideEffect.} = i.provenanceKind)

proc liveDemo(demo: DebugSessionView;
              provenanceKind, provenanceLabel: string): string =
  ## The embedded, pre-baked debugging session (VD.3's `home--live-demo`).
  ##
  ## It is the real session surface — the same `renderLayout` walk over the
  ## same `LayoutNode`, the same pane renderers, positioned mid-trace — inside
  ## a bounded panel, not a video, not a screenshot and not a skeleton. A
  ## marketing page that shows a picture of a debugger is the failure mode the
  ## view's anti-requirements name, and reusing the route's own renderers is
  ## what makes it structurally impossible here.
  ##
  ## It walks `blockTracerReplayLayout()` — the debug route's own arrangement,
  ## not a second one — so the embed cannot come to show a layout the product
  ## does not have. That is also why the stepping controls are absent from it:
  ## they are in the route's identity bar, and the embed has no identity bar
  ## because the page around it is the identity. An embed that grew a toolbar
  ## of its own would be offering to step inside a marketing panel, which is
  ## the "picture of a debugger" failure in the other direction.
  ##
  ## The panel is product register inside an explorer-register page. §2 of
  ## Design-System.md makes that crossing deliberate, so it is drawn as a
  ## bounded, elevated surface rather than left to bleed.
  ##
  ## IT CARRIES THE SUBJECT'S PROVENANCE BADGE, from the same published block
  ## the chain strip's badges and the chain banner read. The embed's own
  ## sentence says "a real session", which has always meant a real session
  ## rather than a picture of one — the anti-requirement above. That reading is
  ## unambiguous only while the tree holds one kind of chain. It no longer does:
  ## the site publishes two captured chains and one synthetic fixture, and a
  ## reader who meets "real" beside a transaction hash has every reason to take
  ## it as a claim about the DATA. So the claim about the data is made
  ## explicitly, in the badge, next to it — and it is read from the tree rather
  ## than assumed from the slug, for the reason `stripOrder` gives: a marker
  ## keyed off a name is one rename away from mislabelling its own data.
  ui:
    tdiv(class = "livedemo", id = "live-demo", `data-register` = "debugger",
         `data-provenance` = provenanceKind):
      tdiv(class = "dbgmain"):
        raw renderLayout(blockTracerReplayLayout(), demo)
      tdiv(class = "livedemofoot"):
        span:
          if provenanceLabel.len > 0:
            span(class = "badge " & provenanceTone(provenanceKind)):
              text provenanceLabel
          # The home page's third spelling of the trace length. Grouped for the
          # reason `groupDigits` gives: prose is read, never copied.
          #
          # "A REAL SESSION" WAS DROPPED, and not on register grounds — the rest
          # of this line is concrete and stays. It was dropped because of what
          # it sits NEXT TO: the badge emitted three lines above reads "Synthetic
          # demo data", so the caption rendered as "Synthetic demo data · A real
          # session". Both halves are true and they are about different things —
          # the DATA is generated, the recorded EXECUTION is genuine — but two
          # adjacent adjectives in direct contradiction make a reader stop and
          # work out which one to believe, on the one element of the home page
          # whose whole job is to be obviously alive. The evidence that it is a
          # real session is the session: it steps, it has 1,315 of them, and the
          # button below opens it.
          text "Stopped mid-execution at step " &
               groupDigits(demo.controls.step) & " of " &
               groupDigits(demo.controls.totalSteps) & "."
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
        # THE ORIGIN CLAUSE WAS REMOVED BECAUSE IT WAS FALSE.
        #
        # This line used to end "Trace any value to its origin — across many
        # chains, VMs and languages." No surface in this product does that, and
        # the gap is not the one-assignment gap it was reported to be. The
        # measurement, against the pinned Embed SDK
        # (`ci/embed-sdk-pin.env`, 8d1c84a8):
        #
        #   `ReplayDataStore.requestLocals` (replay_data_store.nim:628 at the
        #   pin) SENDS `ct/load-locals` and DISCARDS the reply — its `onSuccess`
        #   sets `loadingState` and `loadedForRRTicks` and nothing else. Its
        #   own comment says so: "The actual JSON→Variable parsing will be
        #   added when the locals panel is converted". The only writer of
        #   `store.locals.locals` is `updateLocals` (:788 at the pin).
        #
        # THAT MEASUREMENT NO LONGER SUPPORTS THE CONCLUSION IT ONCE DID. This
        # comment used to add "and nothing under `client/hydrate/` calls it",
        # and concluded `StateVM.currentVariables` is EMPTY for the life of
        # every hydrated session. Two callers exist —
        # `client/hydrate/live_locals.nim:445` and
        # `client/hydrate/session_project.nim:590` — both feeding
        # `store.updateLocals`, which is the bridge the SDK documents for a host
        # that parses the reply itself. So the client fills locals around the
        # SDK's gap, and "there is no live value to ask the origin OF" is not a
        # reason that holds. (The line numbers above were wrong too: :664-680
        # and :795, against :628 and :788 at the pin.)
        #
        # The second reason is fidelity, and it survives the first being fixed:
        # every real transaction this explorer publishes is declared rung 3,
        # and rung 3 is where `demo_session.nim` prints "This recording carries
        # no variable names: naming a local needs debug symbols, which an Aztec
        # contract class does not publish." The origin classifier works by
        # splitting the right-hand side of a source assignment; with no source
        # and no names there is nothing for it to split.
        #
        # Restore the clause when BOTH hold, not either: the SDK parses the
        # locals reply (upstream, behind the pin), and the recording in front
        # of the visitor is source-level. Until then this sentence claims what
        # it can show. See `tools/journeys/journeys/07-*.journey.mjs`.
        p(class = "lead sub"):
          text "Step and rewind every instruction. See the full call trace "
          text "at a glance — across many chains, VMs and languages."
        form(class = "search", action = "/search", `method` = "get"):
          input(name = "q", placeholder = "Paste a block, tx hash, or address")
          button(class = "btn primary", `type` = "submit"):
            text "Search"
        tdiv(class = "chainstrip"):
          # THE STRIP HAS TO SAY WHICH OF THESE IS REAL. Once the tree carries
          # both a synthetic chain and captured ones, three cards that differ
          # only by slug ask a reader to know from the name — and a marker keyed
          # off a name is one rename away from mislabelling its own data. So the
          # badge comes from the same published `provenance` block the chain's
          # own banner renders, and a chain whose generation published none gets
          # no badge rather than a guessed one.
          for info in stripOrder(infos):
            a(class = "chaincard", href = chainUrl(info.slug),
              `data-provenance` = info.provenanceKind):
              tdiv(class = "name"): text info.slug
              if info.provenanceLabel.len > 0:
                tdiv(class = "row"):
                  span(class = "badge " & provenanceTone(info.provenanceKind)):
                    text info.provenanceLabel
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
        # `ssr.demoSessionFor` has already decided this is a session worth
        # featuring — `canHeadline`, a positive rule with no fallback arm — so
        # `isSome` is the whole test here. `hasFrame` used to be re-checked at
        # this line, which put half of a selection rule in the page and half in
        # the producer; `canHeadline` asks it, and a page that re-asked one
        # clause of a rule it does not own would go stale against the rest of it.
        if demo.isSome:
          let subject = demo.get.chain
          var kind, label: string
          for info in infos:
            if info.slug == subject:
              kind = info.provenanceKind
              label = info.provenanceLabel
          raw liveDemo(demo.get, kind, label)
