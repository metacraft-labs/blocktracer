## SSR entry point — turns a data-plane `DataRoot` into rendered explorer pages,
## isonim-website style. Unlike a fixed-route marketing site, BlockTracer's routes
## are DERIVED from the data (one page per block, one per transaction), so the
## route set and every page body come from the same `/d/**` tree the browser
## reads. `staticRoutes` enumerates them; `renderRoute` dispatches one; both are
## driven by `reader`, so there is a single source of truth for "what exists".

import std/[options, strutils]
import reader
import viewutil
# THE TWO FORMS. `staticRoutes` places identifiers in ROUTES, which are KEY
# positions, while the lists it reads them from are object BODIES, which carry
# DISPLAY forms — see the note at the enumeration itself.
import blocktracer/contract/identifier_encoding
import debugger/demo_session
import debugger/source_document
import debugger/session_view
import components/layout
import components/degraded
import components/provenance
import pages/home as homePg
import pages/chains as chainsPg
import pages/chain as chainPg
import pages/blocklist as blockListPg
import pages/blockview as blockPg
import pages/txs as txsPg
import pages/tx as txPg
import pages/address as addressPg
import pages/code as codePg
import pages/search as searchPg
import pages/about as aboutPg
import pages/settings as settingsPg
import pages/notfound as notFoundPg
import pages/debug as debugPg

const SiteDomain* = "https://blocktracer.org"

# ── crawl classes (SEO-And-Crawl-Budget.md §5, §6) ─────────────────────────

type
  RouteClass* = enum
    ## The three indexability classes this product's routes fall into. §5 gives
    ## each one a robots policy and a sitemap answer; §6 assigns a class per
    ## route. Both halves are read from here, so a route cannot carry one class
    ## in its `<meta>` and be treated as another by the sitemap.
    rcCore = "index,follow"           ## I0 — home, /chains, /about, chain landing
    rcAddressable = "noindex,follow"  ## N1 — ordinary entities and their lists
    rcUtility = "noindex,nofollow"    ## N2 — search, settings and embeds

func isPaginationRoute*(route: string): bool =
  ## §6's last row: "Pagination, filter, sort and layout variants … Never
  ## submitted." The three cursor shapes this client serves, named by their
  ## path segment rather than by a count of slashes, so a fourth cursor added
  ## later has to be added here to be excluded — which is a visible edit.
  "/blocks/from/" in route or "/txs/from/" in route or "/address/" in route and
    "/seg/" in route

func routeClass*(route: string): RouteClass =
  ## The crawl class of a rendered route. A total function of the route's
  ## shape, so the class is decided in one place and both the `<meta robots>`
  ## and the sitemap read the same answer.
  let p = route.strip(chars = {'/'})
  if p.len == 0: return rcCore
  case p
  of "chains", "about": return rcCore
  of "search", "settings": return rcUtility
  else: discard
  # `/{chain}` — §6: "Chain is publicly supported", which is what being in the
  # registry means here.
  if '/' notin p: return rcCore
  rcAddressable

proc isSitemapRoute*(route: string): bool =
  ## Whether a rendered route belongs in `sitemap.xml`.
  ##
  ## A route that is RENDERED and a route that is SUBMITTED are two different
  ## questions, and this is where they part company.
  ##
  ## Three exclusions, each from a row of SEO-And-Crawl-Budget.md §6:
  ##
  ##   * **`/debug`** — the transaction's content at a second address. Its own
  ##     `<meta robots>` and canonical already say so; being absent from the
  ##     sitemap is the same statement made where a crawler reads it first, and
  ##     M8b requires this milestone to add no second indexable copy.
  ##   * **`/search` and `/settings`** — class N2, whose promotion column
  ##     reads "Never". Both are utilities a reader reaches deliberately, and
  ##     neither has content a search engine should rank: one resolves an
  ##     identifier the visitor already has, the other configures their own
  ##     browser. `routeClass` gives both `rcUtility` and the filter below
  ##     reads that, so neither is listed here by name.
  ##   * **Pagination variants** — "Never submitted". Every page of a cursor
  ##     walk is reachable by following the pager from the first page, which is
  ##     what `follow` is for.
  ##
  ## **What is deliberately NOT excluded, and why it is recorded here rather
  ## than fixed:** §5's class table also gives N1 "Sitemap: No", and this
  ## client submits N1 entity pages. That predates M9 — `test_debug_route`'s
  ## crawl-surface baseline records the transaction route's sitemap membership
  ## as it was — and narrowing it would change the crawl surface of every
  ## transaction and block in the product, which is a promotion-policy decision
  ## (§7) rather than a rendering one. It is left as it was, and named, because
  ## a rule whose comment claims more than its code does is the shape of a
  ## check that cannot fail.
  if route.endsWith("/debug"): return false
  if routeClass(route) == rcUtility: return false
  if isPaginationRoute(route): return false
  true

# ── per-route renderers ─────────────────────────────────────────────────────

proc debugSessionFor*(r: DataRoot, chain, hash: string): DebugSessionView =
  ## The session one transaction's debug route renders.
  ##
  ## Assembled here rather than inside the page so that the transaction route
  ## and the debug route can build the SAME value — §7.0's "both addresses
  ## reach the same session; they differ in what the visitor asked for" — and
  ## so the source-bundle preference is applied in one place.
  let info = chainInfo(r, chain)
  let v = txView(r, info, hash)
  let t = traceView(r, info, hash)
  result = demoSession(chain, v, info,
    containerPath = t.containerPath,
    containerBytes = t.containerBytes,
    contentHash = t.contentHash,
    totalSteps = (if t.steps > 0: t.steps else: 0),
    # The MANIFEST decides whether there are source positions, not the page and
    # not the chain's name. A container recorded at instruction level renders as
    # instruction level wherever it came from, and the client-side fixture
    # sources are offered only to a trace whose manifest claims source level.
    sourceLevel = t.sourceLevel,
    # …and, from the same manifest, WHERE THE RECORDING STOPS. This is the only
    # place both the transaction's facts and its trace manifest are in hand, so
    # it is the only place the §7.1 row producer can be given the fact. See
    # `viewutil.executionEndingRow` for why it is not the transaction's outcome.
    ending = t.ending)
  if t.languages.len > 0:
    result.languages = t.languages
  result.reconstructed = t.reconstructed
  if t.truncated:
    result.integrity = siTruncated
    result.integrityDetail =
      "The recorder stopped at " & $t.steps & " steps and " & $t.frames &
      " frames — the profile's budget. Everything before that point is " &
      "complete and steps normally."
  # Trace-Artifacts.md §4: the manifest's recommendation is "the
  # interpretation the page should use", so a published bundle wins over the
  # client's fixture sources.
  withPublishedSources(result, t.sourceBundle)
  # THE MIDDLE RUNG, between the manifest's whole-recording claim above and the
  # program counters below. A recording that positions SOME of its steps sets no
  # `sourceLevel` bit, so `withPublishedSources` declines it — and its bundle and
  # its per-step positions are both published and both were going unread. This
  # takes the pane only when the one above it did not, for the same coexistence
  # reason the listing does: whatever won keeps the pane.
  # The capture's own two counts travel with the stream, so a derived one can be
  # checked against what the recording session measured rather than trusted.
  withSourcePositions(result, t.sourceBundle, t.positions,
                      v.sources.positionedSteps, v.sources.totalSteps)
  # …and the floor, AFTER it and never over it. A pane that ended up with source
  # keeps source; one that did not gets the program counters the recording
  # carries instead of a paragraph describing them. The order is the coexistence
  # rule made mechanical — see `withInstructionListing`, which refuses any pane
  # that is not `srcUnverified` and any pane that already has documents.
  withInstructionListing(result, t.instructions)
  # ── AND THEN THE LADDER STOPS BEING A CONTEST, FOR THE ONE CLASS IT COULD
  #    NOT EXPRESS ───────────────────────────────────────────────────────────
  #
  # "Whatever won keeps the pane" is coexistence between the RUNGS and a contest
  # for the PAGE: three refusals above hand the whole session to one rung,
  # decided once, here. §7's row for the case that describes reads:
  #
  #   | Partial source coverage | Source-level stepping where sources exist,
  #     instruction-level elsewhere, with the boundary visible in the source
  #     pane rather than silent |
  #
  # and `Debugger-Integration.md` §5 says the same from the other side: "A
  # single transaction routinely mixes both. The debugger must handle this
  # without ceremony — it is the normal case, not an edge case."
  #
  # MEASURED, ON THE FIRST RECORDING THIS TREE PUBLISHES THAT SEPARATES THEM.
  # `aztec-testnet-frames/0x0a807e4e…` runs 459 steps across TWO contracts at
  # two fidelities: `0x…03` is 108 steps with 86 positioned, and `0x2fcd3dd5…`
  # is steps 108..458 with none, because no distributor could prove its
  # artifact. The middle rung won, so the pane was 32 Noir documents and no
  # listing — and at the 373 steps that carry no `(path, line)` there was no row
  # of any kind to be stopped at. Its unpositioned runs are ticks 0..13, 27..34
  # and 108..458. The STATIC export escaped by an accident of the middle rung's
  # own landing rule, which moves the served step to one there is source for
  # ("a page may not report a position it is not showing") and lands this
  # recording on 107; hydration has no counterpart, lands at tick 0, and marked
  # nothing — 224 rows of Noir, no mark, no head, no note.
  #
  # This is the union. The listing JOINS the source documents instead of
  # competing with them, so one pane holds both kinds and every tick has a row.
  # It runs LAST because it is the only rung that reads what the others decided:
  # it takes a pane the middle rung won and whose coverage is partial, and no
  # other. `withInstructionListing` above is unchanged and still refuses it, so
  # the floor cannot arrive twice.
  #
  # `session_project.projectEditor` is the hydrated half of the same rule — the
  # listing row at `rrTicks` when the engine's position resolves to no published
  # document — and `tools/journeys/lib/corpus.mjs`'s `hasSource` moved with it: a
  # page holding both kinds of document is not "no source".
  withListingBesideSource(result, t.instructions)
  # ── AND WHICH OF THE MARKED LINES ARE THE COMPILER'S ANSWER RATHER THAN
  #    EVIDENCE ────────────────────────────────────────────────────────────────
  #
  # `Source-Resolution.md` §7's last row asks for the boundary between what this
  # recording can show and what it cannot to be "visible in the source pane
  # rather than silent", and the rung boundary is not the only such boundary. A
  # position also comes from a COMPILED DEBUG MAP, and a compiler may key one
  # instruction sequence to any of the source spans that produced it: twelve
  # steps of `0x0a807e4e…` sit on `main.nr:223`, inside a branch its own call
  # tree shows was not taken, and two frames land inside `comptime quote { … }`
  # templates. An unmarked wrong line is the one defect this product may not
  # have, so the lines are marked and the pane says how many and why.
  #
  # AFTER the pane is final: it walks the pane's documents and its executed set,
  # so it must run once nothing can still replace either.
  let attributed = markCompilerAttributed(result, t.positions, t.callFrames)
  if attributed > 0:
    # APPENDED to whatever the rung boundary already said, never in place of it.
    # Both sentences are about the same pane and both are true; the listing's own
    # note explains the steps with NO source line, and this explains the ones
    # whose source line is the map's answer.
    result.editor.attributionNote =
      $attributed & " line(s) in this pane are marked with a `?`: the position " &
      "is where the compiler KEYED the compiled code, not somewhere the " &
      "recording proves the execution reached. Either the line is inside a " &
      "`comptime quote { … }` template — code emitted from there, not run there " &
      "— or it is one of a pair of positions inside a single call whose step " &
      "order this recording cannot have produced in that order, so at least one " &
      "of the two is not where the execution was and the recording does not say " &
      "which. Where a marked line disagrees with the Call Trace beside it, the " &
      "call tree is the stronger evidence: it names the frames the recording " &
      "actually opened."
  # ── …AND WHY THE STEPS IT MARKS NOWHERE HAVE NO LINE ──────────────────────
  #
  # THE SAME DEFECT AS THE ROOTS BANNER, AND IT WAS STILL STANDING FOR 81% OF
  # THIS RECORDING. The header above this says "This recording resolves source
  # for 86 of its 459 steps", which is the RATIO. The CAUSE was published too,
  # and it is specific and creditable: `native.replay.contractRungs[1]` records a
  # SECOND contract in the same transaction that ran 351 of the 373 unplaced
  # steps and positions none of them, at rung 3, because what a node serves for
  # its class is bytecode plus a commitment to the compiled artifact and not the
  # artifact — and off-chain resolution RAN for it and matched nothing. Every
  # word of that was legible only inside the collapsed "Raw (chain-native)"
  # JSON, which is exactly where the roots disagreement was before the banner.
  #
  # PROPORTIONATE, AND DELIBERATELY NOT A BANNER. The roots banner is about the
  # whole recording's standing as evidence, so it sits above every pane and
  # cannot be dismissed. This is about one pane's rows, so it is a caption in
  # that pane, in the `.srcrung`/`.srcattr` idiom already beside it. A second
  # `role="status"` competing with the first would cost the first its weight.
  #
  # AFTER `markCompilerAttributed` for the same reason that runs where it does:
  # the pane's coverage counts are what the note is about and the ladder above
  # settles them, so nothing may still replace the pane when this reads them.
  # `viewutil.unpositionedCauseNote` owns every refusal — no per-contract record,
  # no rung boundary, or no contract that positioned nothing — so a transaction
  # with one contract, and one that positions everything, get "" here rather than
  # an empty paragraph, and the rule lives with the prose it gates.
  result.editor.coverageNote = unpositionedCauseNote(
    v.contracts, result.editor.positionedSteps, result.editor.positionedOf)
  # THE CALL TRACE, AND IT IS NOT PART OF THAT CONTEST. The three calls above
  # compete for the CODE pane — a bundle beats positions beats a listing — and
  # this fills a different pane from a different object, so it runs outside the
  # ladder rather than as a fourth rung of it.
  #
  # LAST, THOUGH, AND THAT ORDER IS LOAD-BEARING: `withInstructionListing`
  # clamps `controls.step` to the recording's own last tick, and the frame this
  # marks `current` is the one containing that coordinate. Running before the
  # clamp would resolve the current frame against a step the page then corrects,
  # which is the two-producers-of-one-coordinate defect the listing's own
  # comment describes.
  withCallFrames(result, t.callFrames)
  # THE EVENT LOG, FROM THE SAME OBJECT AND AFTER IT. Not a fifth rung and not a
  # second reader of the sidecar's shape: it reads the frames' names, steps and
  # positions — which `withCallFrames` has just proved decodable — and turns the
  # ones that ARE events into events.
  #
  # AFTER `withCallFrames` because the row it marks `current` is resolved against
  # `controls.step`, and the clamp that settles that coordinate runs inside the
  # listing above. Running before it would mark a row for a step the page then
  # corrects, which is the two-producers-of-one-coordinate defect the listing's
  # own comment describes.
  #
  # The outcome is passed, not derived here: whether a transaction reverted is
  # the transaction's own published fact and `demo_session.fixtureEventLog`
  # already reads it from the same place with the same rule.
  withEventLog(result, t.callFrames,
               reverted = v.outcome in {ooReverted, ooFailedWithEffects})
  # THE VALUES PANE, AND IT RUNS LAST OF THE PANE PRODUCERS. It reads the
  # instruction stream's four parallel columns AT THE SESSION'S STEP, so it must
  # run after everything that can still move that coordinate — the listing's
  # clamp and the positions' landing rule both do. A column read at a step the
  # page then corrects is a value belonging to another step, which is the whole
  # class of defect this pane's own note exists to avoid.
  withMachineColumns(result, t.instructions, t.callFrames)
  # ── WHAT THE REPLAY WAS CHECKED AGAINST, ON THE PAGE ────────────────────────
  #
  # `Page-Descriptions.md` §8 and `Trace-Artifacts.md` §5 put the divergence
  # banner above the debugger with no dismiss control, and this repository
  # already draws it correctly for the one transaction whose effects did not
  # reproduce. What it drew NOTHING for is the case where the verdict stands and
  # is narrower than a reader will take it to be: every published Aztec
  # transaction records `rootsAnyAgree: false` with a four-entry `roots` array,
  # and the manifest beside it says `validation.status: "match"` with
  # `validation.oracle: "published-effects"`. Both are true. Only one was
  # visible, and the other was legible ONLY inside the collapsed Raw JSON —
  # outside it, the words "divergent" and "disagree" appeared three times per
  # page and every one of the three was inside a CSS comment.
  #
  # So this states the oracle and the roots in the same undismissable position,
  # following the divergence banner's precedent rather than inventing a second
  # treatment. It qualifies a verdict; it does not replace one, which is why it
  # is a separate pair of fields and not a new `SessionIntegrity` member — see
  # `session_view.DebugSessionView.scopeTitle`.
  #
  # THE NUMBERS ARE NOT RE-DERIVED HERE. `v.replay` is `reader.replayScope`'s
  # fold over the same `native` the Raw block prints, so the banner and the JSON
  # under it cannot disagree.
  if v.replay.has and v.replay.rootsTotal > 0 and
     v.replay.rootsAgreeing < v.replay.rootsTotal:
    result.scopeTitle =
      if v.replay.rootsAgreeing == 0: "State roots disagree"
      else: "Some state roots disagree"
    var d = ""
    if t.validationOracle.len > 0 and result.integrity == siValidated:
      # THE ORACLE'S OWN NAME, spelled as the narrow claim it is. Only where the
      # verdict is the validated one: on a divergent trace the banner above this
      # already says the replay disagreed, and repeating "the check passed" under
      # it would be the page arguing with itself.
      d = "This replay was checked against " &
          (if t.validationOracle == "published-effects":
             "the effects the block published, and it reproduced " &
             $v.replay.effectsMatched & " of " &
             $(v.replay.effectsMatched + v.replay.effectsMismatched) & " of them"
           else: "the '" & t.validationOracle & "' oracle") & ". "
    d.add "It was NOT checked against the block's state-tree roots, and " &
          (if v.replay.rootsAgreeing == 0: "none of the "
           else: $(v.replay.rootsTotal - v.replay.rootsAgreeing) & " of the ") &
          $v.replay.rootsTotal & " roots the capture recorded agree with the " &
          "chain's: " & v.replay.differingTrees.join(", ") & ". Replay hydrates " &
          "only the leaves this execution touched, so the trees it rebuilds are " &
          "sparse and their roots cannot equal a full block's — the surprising " &
          "outcome would be a match. What that costs is narrow and worth " &
          "stating: this recording is evidence about the execution, and not a " &
          "proof of the block's resulting state."
    result.scopeDetail = d
  # …AND THE DIVERGENCE BANNER NAMES WHAT DIVERGED. It used to say a replay
  # "disagreed with the chain's own result" and stop, on a transaction whose own
  # published record names both disagreeing fields. The records are in
  # `native.replay.effectMismatches`; where a capture predates them the count
  # still reaches the sentence, so "two differed and the tree does not say which"
  # is distinguishable from "none differed".
  if result.integrity == siDivergent and v.replay.has:
    var named: seq[string]
    for m in v.replay.mismatches: named.add m.field
    if named.len > 0:
      result.integrityDetail.add " What differed: " & named.join(", ") & "."
    elif v.replay.effectsMismatched > 0:
      result.integrityDetail.add " " & $v.replay.effectsMismatched &
        " published effect(s) differed; this capture does not record which."

proc demoSessionFor*(r: DataRoot): Option[DebugSessionView] =
  ## The home page's featured session: the first transaction in the tree whose
  ## recording `canHeadline`.
  ##
  ## Chosen by walking the published data rather than by naming a hash: the
  ## demo tree is a pure function of a seed, and a hard-coded hash would make a
  ## reseed silently produce a home page with no demo on it.
  ##
  ## THERE IS NO FALLBACK ARM, AND ITS ABSENCE IS THE FIX. This used to admit
  ## any session that was positioned, validated and not reconstructed — three
  ## clauses that between them exclude nothing a real chain publishes — and so
  ## it featured the first transaction it met, which was a rung-3 Aztec
  ## recording whose panes truthfully report three things they cannot show.
  ## `canHeadline` states what the exhibit must HAVE instead; see its comment
  ## for why that had to be a positive rule and not an exclusion.
  ##
  ## When nothing in the tree satisfies it the answer is `none`, and the home
  ## page carries no featured session at all. That is deliberate: a tree with no
  ## source-level recording in it has nothing to headline, and the alternative —
  ## relaxing the rule until something passes — is the fallback that put the
  ## floor of the fidelity ladder on the front page in the first place.
  for chain in chains(r):
    let info = chainInfo(r, chain)
    for h in blockHashes(r, info):
      for txh in readBlockDetail(r, info, h).transactions:
        var s = debugSessionFor(r, chain, txh)
        # `hasFrame`, not `phase == spReady`: the static route serves a
        # positioned frame with the replay engine still unfetched, and the
        # embed is that same frame. Gating on `spReady` would leave the home
        # page with no demo on it until hydration exists. (`canHeadline` asks
        # `hasFrame` for exactly this reason.)
        if canHeadline(s):
          # The embed has no scrollbar, so it opens ON the current line rather
          # than at line 1 of the file. Line numbers and anchors are unchanged,
          # so a link out of the embed lands on the same line of the full
          # session.
          #
          # AND THAT IS NOW SAID IN AN ARGUMENT RATHER THAN IN A COMMENT. This
          # narrowing drops the loop header — line 4, against a window of 20..44
          # — and the flow rail's "line 4" link was left pointing at `#L-…-4` on
          # a page that no longer contained it, which a reader reported as a link
          # that does nothing. `debugUrl` is this session's own full-file surface,
          # the one the button five lines down in `pages/home` already calls
          # "Open the full session", so the rail's link now goes exactly where
          # the sentence above always claimed it would.
          s.editor = windowAround(s.editor, radius = 12,
                                  fullDocumentUrl = debugUrl(s.chain, s.txHash))
          return some(s)
  none(DebugSessionView)

# ── §14, resolved once per surface ─────────────────────────────────────────
#
# Page-Descriptions §14: "Every row above is a value of an enum on a
# ViewModel, not a branch in a view." The snapshot below is built from
# published facts, `resolveChainDegradation` picks the most severe row the
# SURFACE renders, and `components/degraded` renders exactly one treatment for
# it. No page tests a condition of its own.

proc chainSnapshot(r: DataRoot, info: ChainInfo): ChainStateSnapshot =
  ## The axes every explorer surface shares, from the pinned session.
  result = initChainStateSnapshot()
  # §5 of Static-Site-Architecture: a consumer "surfaces staleness from
  # `summary.json` rather than inferring it". The published flag decides; the
  # height delta below only names HOW FAR.
  if info.stale: result.freshness = pfBehindTip
  if not info.hasRecorder: result.provenance = tpRecorderUnavailable

proc behindBy(r: DataRoot, info: ChainInfo): int =
  ## How far the sealed generation is behind the pointer's tip, in blocks.
  ##
  ## Read from the generation's height MAP (one object per epoch), never by
  ## walking block details: this number decorates a notice, and a decoration
  ## that costs one read per block would put back exactly the cap this
  ## milestone's pagination exists to remove. Zero when the generation is not
  ## behind — the notice then says so in words instead of in a number.
  let highest = highestIndexedHeight(r, info)
  if highest < 0 or info.headHeight <= highest: 0
  else: info.headHeight - highest

proc chainNotice(r: DataRoot, info: ChainInfo): DegradationNotice =
  ## `behindBy` is computed only when the published summary says the chain IS
  ## behind. §5: a consumer "surfaces staleness from `summary.json` rather than
  ## inferring it" — so the flag decides, the delta only names how far, and a
  ## page that is not showing a staleness notice pays nothing to find out it is
  ## not showing one.
  DegradationNotice(subject: info.slug,
                    behindBy: (if info.stale: behindBy(r, info) else: 0),
                    chainsChecked: chains(r))

# ── the pages ──────────────────────────────────────────────────────────────

proc renderHome*(r: DataRoot): string =
  var infos: seq[ChainInfo]
  for c in chains(r): infos.add chainInfo(r, c)
  pageLayout(
    "BlockTracer — the deepest view into every transaction",
    # The origin clause is gone, and the reason is recorded once, at the hero
    # in `pages/home.nim` — the SDK discards the `ct/load-locals` reply, so a
    # hydrated session holds no live values, and every published transaction is
    # rung 3, which carries no variable names. This string matters more than
    # the hero rather than less: it is what a search result shows to someone
    # who has not loaded the page and so cannot check it.
    "The deepest view into every transaction. Step and rewind every instruction and see the full call trace at a glance — across many chains, VMs and languages.",
    homePg.homePage(infos, demoSessionFor(r)),
    robots = $routeClass("/"),
    canonical = SiteDomain & "/")

proc renderChains*(r: DataRoot): string =
  pageLayout(
    "Supported chains — BlockTracer",
    "Every chain BlockTracer publishes: whether its data is captured from a network or synthetic, how many blocks and transactions each holds, and how close it is to the tip.",
    chainsPg.chainsPage(chainRows(r)),
    robots = $routeClass("/chains"),
    canonical = SiteDomain & "/chains")

proc renderAbout*(r: DataRoot): string =
  pageLayout(
    "About BlockTracer — what it is and what it costs you",
    # `Built on CodeTracer` EARNS ITS PLACE IN THE SNIPPET, and the words it
    # cost were `whole` and `reduced to`. The page now opens by naming what
    # BlockTracer is built on, and this is the version a reader sees BEFORE
    # deciding whether to click — someone searching for the relationship
    # between the two products is asking the question this page answers, and a
    # snippet that omits the answer sends them to a competitor's page for it.
    #
    # 155 characters. The budget is real: at ~160 a search result clips the
    # tail, and the tail is the new clause. Trimming the middle rather than
    # dropping the attribution is the whole point of the edit.
    "A block explorer where a transaction is a debugging session — its execution recorded and replayed, not just what went in and came out. Built on CodeTracer.",
    aboutPg.aboutPage(chains(r).len),
    robots = $routeClass("/about"),
    canonical = SiteDomain & "/about")

proc renderSettings*(r: DataRoot): string =
  ## The keyboard-shortcut preset, and the full list of what is bound.
  ##
  ## `scripts = settingsScriptTag()` is what separates this page from the one
  ## that was deleted at this address. That page had no controls and a header
  ## explaining that controls would need script the client did not ship; this
  ## one ships the script, so the chooser it serves is a control that acts.
  pageLayout(
    "Keyboard shortcuts — BlockTracer",
    "Choose which keys step a recorded trace, and see everything the debugger binds.",
    settingsPg.settingsPage(),
    robots = $routeClass("/settings"),
    canonical = SiteDomain & "/settings",
    scripts = settingsScriptTag())

proc renderSearch*(r: DataRoot): string =
  ## §11. The query is resolved in the browser (Search-And-Routing §1–§6), so
  ## this route renders what it genuinely holds: how an identifier resolves,
  ## which chains would be checked, and the published name corpus — browsable
  ## without a query at all.
  var named: seq[searchPg.NamedEntity]
  for chain in chains(r):
    for l in labels(r, chain):
      if l.id.len == 0 or l.name.len == 0: continue
      named.add searchPg.NamedEntity(
        chain: chain, id: l.id, name: l.name, symbol: l.symbol,
        kind: l.kind, provenance: l.provenance,
        href: addressUrl(chain, l.id))
  pageLayout(
    "Search — BlockTracer",
    "Resolve a transaction hash, block, or address. Resolution is identifier lookup, not a query.",
    searchPg.searchPage(chains(r), named,
                        resolvesInBrowser = SearchBundle.len > 0),
    robots = $routeClass("/search"),
    canonical = SiteDomain & "/search",
    scripts = searchScriptTag())

proc renderChain*(r: DataRoot, chain: string): string =
  let info = chainInfo(r, chain)
  let page = txsFrom(r, info, -1)
  let bs = blocksFrom(r, info, -1, size = 10).rows
  let d = resolveChainDegradation(chainSnapshot(r, info),
                                  ChainOverviewDegradations)
  pageLayout(
    chain & " — BlockTracer",
    "Chain overview for " & chain & ": latest blocks and transactions, each with the debugger as its primary action.",
    chainPg.chainPage(chain, info, bs, page.rows, d, chainNotice(r, info),
                      tour = tour(r, info)),
    robots = $routeClass("/" & chain),
    canonical = SiteDomain & "/" & chain,
    provenance = provenanceMarker(info))

proc renderBlockList*(r: DataRoot, chain: string, fromHeight: int): string =
  let info = chainInfo(r, chain)
  let page = blocksFrom(r, info, fromHeight)
  let d = resolveChainDegradation(chainSnapshot(r, info), BlockDegradations)
  let route = if fromHeight < 0: blocksUrl(chain)
              else: blocksFromUrl(chain, fromHeight)
  pageLayout(
    chain & " blocks — BlockTracer",
    "Blocks on " & chain & ", newest first, paginated by walking backwards.",
    blockListPg.blockListPage(chain, info, page, d, chainNotice(r, info)),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderTxList*(r: DataRoot, chain: string, fromHeight: int): string =
  let info = chainInfo(r, chain)
  let page = txsFrom(r, info, fromHeight)
  let d = resolveChainDegradation(chainSnapshot(r, info), BlockDegradations)
  let route = if fromHeight < 0: txsUrl(chain)
              else: txsFromUrl(chain, fromHeight)
  pageLayout(
    chain & " transactions — BlockTracer",
    "Transactions on " & chain & ", newest first, with Debug as the first column of every row.",
    txsPg.txsPage(chain, info, page, d, chainNotice(r, info)),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderBlock*(r: DataRoot, chain, hash: string): string =
  let info = chainInfo(r, chain)
  let detail = readBlockDetail(r, info, hash)
  var txs: seq[TxRow]
  for h in detail.transactions:
    txs.add txRow(r, info, h)
  # §2.1: a reorg is a change to the height map, not to the block. So the
  # question this page asks is whether the generation's map still points at
  # this hash for this height — and the block object is correct either way.
  let canonicalHere = canonicalBlockAt(r, info, detail.height)
  var snapshot = chainSnapshot(r, info)
  if canonicalHere.len > 0 and canonicalHere != detail.hash:
    snapshot.canonicality = ccReorganisedAway
  let d = resolveChainDegradation(snapshot, BlockDegradations)
  var note = chainNotice(r, info)
  note.subject = detail.hash
  if snapshot.canonicality != ccCanonical:
    note.detail = "At height " & $detail.height & " this generation's height " &
      "map points at " & canonicalHere & "."
    note.actionHref = blockUrl(chain, canonicalHere)
    note.actionLabel = "The canonical block at this height"
  pageLayout(
    "Block " & $detail.height & " — " & chain & " — BlockTracer",
    "Block " & $detail.height & " on " & chain & " with " & $detail.transactions.len & " transactions.",
    blockPg.blockPage(chain, info, detail, txs,
                      nextBlockHash(r, info, detail.height),
                      hasBlock(r, info, detail.parentHash), d, note),
    robots = $routeClass("/" & chain & "/block/" & hash),
    canonical = SiteDomain & "/" & chain & "/block/" & hash,
    provenance = provenanceMarker(info))

proc addressCode(r: DataRoot, info: ChainInfo, address: string,
                 rows: seq[TxRow]): seq[SourceBundleView] =
  for h in codeHashesAt(r, info, address, rows):
    result.add sourceBundleAt(r, info.slug, h)

proc renderAddress*(r: DataRoot, chain, address, segmentId: string): string =
  ## §9. One block-range segment of an address's history, with Debug on every
  ## row — and the code bound to the address, where any is.
  let info = chainInfo(r, chain)
  let v = addressView(r, info, address, segmentId)
  let rows = addressRows(r, info, v)
  var snapshot = chainSnapshot(r, info)
  if not v.indexed: snapshot.presence = opNotOnThisChain
  let d = resolveChainDegradation(snapshot, AddressDegradations)
  var note = chainNotice(r, info)
  note.subject = address
  note.detail = v.reason
  let route = if segmentId.len > 0: addressSegmentUrl(chain, address, segmentId)
              else: addressUrl(chain, address)
  pageLayout(
    "Address " & truncHash(address) & " — " & chain & " — BlockTracer",
    "Complete transaction history for " & address & " on " & chain & ", with the debugger as the primary action on every row.",
    addressPg.addressPage(chain, info, v, rows,
                          labelFor(labels(r, chain), address),
                          addressCode(r, info, address, rows), d, note),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderAddressCode*(r: DataRoot, chain, address: string): string =
  ## §10. The verified-source browser for the code at an address.
  let info = chainInfo(r, chain)
  let v = addressView(r, info, address)
  let rows = addressRows(r, info, v)
  var snapshot = chainSnapshot(r, info)
  if not v.indexed: snapshot.presence = opNotOnThisChain
  let d = resolveChainDegradation(snapshot, AddressDegradations)
  var note = chainNotice(r, info)
  note.subject = address
  note.detail = v.reason
  let code = addressCode(r, info, address, rows)
  var deployments: seq[string]
  if code.len > 0:
    deployments = deploymentsOf(r, info, code[0].codeHash)
  let route = addressCodeUrl(chain, address)
  pageLayout(
    "Source for " & truncHash(address) & " — " & chain & " — BlockTracer",
    "Verified source, compiler settings and deployments for the code at " & address & " on " & chain & ".",
    codePg.codePage(chain, address, code, deployments, d, note),
    robots = $routeClass(route),
    canonical = SiteDomain & route,
    provenance = provenanceMarker(info))

proc renderTx*(r: DataRoot, chain, hash: string): string =
  ## `/{chain}/tx/{hash}` — Page-Descriptions §7.0, whose whole point is that
  ## **what this route serves depends on the trace, not on a click**:
  ##
  ##   `ready`, `divergent`   the debugging interface, with the transaction's
  ##                          facts as the metadata pane inside it (§7.1)
  ##   `onDemand`             the metadata, and the generate action
  ##   `absent`, `unsupported` the metadata, with the reason stated
  ##
  ## The first row renders `debugPg.debugPage` over the SAME `debugSessionFor`
  ## value the `/debug` route renders, in the same `debugLayout`. That is what
  ## §7.0's "both addresses reach the same session" means as markup: the served
  ## BODIES are byte-identical, and the two routes differ only in the two head
  ## elements that describe the request — the `<title>` and the description —
  ## and in which address `sitemapRoutes` submits. `robots`, `canonical` and
  ## the inlined stylesheet are the same bytes on both, which is the part that
  ## matters: the crawl surface does not depend on which address was asked
  ## for. Arriving at a transaction is arriving in its execution, and
  ## there is no Debug button here because there is nothing left for one to do.
  ##
  ## What this costs, itemised, because §7.0 claims it costs nothing:
  ##
  ##   * **The crawl surface.** `robots` and `canonical` are the same values on
  ##     both branches and are unchanged from before this milestone; §7.2's
  ##     facts — the overview grid, the decoded input and the chain-native
  ##     payload — are in the metadata pane on the session branch, from
  ##     `viewutil`'s producers, so no fact left the transaction's own URL.
  ##   * **First paint.** Still static HTML; the replay engine is not on the
  ##     critical path and the page says so (`engineNotice`).
  ##   * **The fallback.** There is nothing to fall back to. The client ships
  ##     no JavaScript, so the frame served here is what every visitor sees,
  ##     and "no state renders less than the pre-hydration page" holds because
  ##     the pre-hydration page is all there is.
  let info = chainInfo(r, chain)
  let v = txView(r, info, hash)
  let short = hash[0 ..< min(10, hash.len)]
  let description = "Transaction on " & chain & " at block " & $v.height & "."
  let canonical = SiteDomain & "/" & chain & "/tx/" & hash
  let robots = $routeClass("/" & chain & "/tx/" & hash)
  let s = debugSessionFor(r, chain, hash)
  if s.hasFrame:
    debugLayout(
      "Transaction " & short & "… — " & chain & " — BlockTracer",
      description,
      debugPg.debugPage(s),
      robots = robots,
      canonical = canonical,
      # NO PROVENANCE BAND IN THIS SHELL. `debugLayout` has a metadata pane
      # that §7.1 puts on the page in every state, and `viewutil.txMetadataRows`
      # opens it with the provenance row — so the marker is on this page beside
      # the transaction's other facts rather than in a strip above them. See
      # `provenance.provenanceMarker` for the whole argument; the short form is
      # that a band costs ~190px of a 1080px viewport here and the pane costs a
      # row.
      provenance = "")
  else:
    pageLayout(
      "Transaction " & short & "… — " & chain & " — BlockTracer",
      description,
      txPg.txPage(chain, v, info),
      robots = robots,
      canonical = canonical,
      # NO band and no chip: this page has a METADATA SURFACE, and
      # `viewutil.txMetadataRows` opens it with the provenance row. The rule is
      # one marker per page — the row wherever a page has facts to put it among,
      # the band or the chip only where there is nowhere else for it to go. A
      # chip above a grid whose first row says the same thing is the redundancy
      # the band rule objected to, wearing a smaller element.
      provenance = "")

proc renderDebug*(r: DataRoot, chain, hash: string): string =
  let s = debugSessionFor(r, chain, hash)
  let info = chainInfo(r, chain)
  debugLayout(
    "Debug " & truncHash(hash) & " — " & chain & " — BlockTracer",
    "Step through transaction " & hash & " on " & chain & ".",
    debugPg.debugPage(s),
    robots = $routeClass("/" & chain & "/tx/" & hash & "/debug"),
    # The canonical address of this content is the TRANSACTION's URL. §7.0
    # makes that page the same session's first frame, and M8b requires the
    # transaction route's crawl surface to be unchanged — which a second
    # indexable copy of the same content would not leave it.
    canonical = SiteDomain & "/" & chain & "/tx/" & hash,
    # See `renderTx` above: this shell's provenance is the metadata pane's row.
    provenance = "")

proc renderNotFound*(r: DataRoot): string =
  ## §14's "Object not found" row, at a real 404 (SEO §6 class G0).
  ##
  ## `chains(r)` is what was ACTUALLY reachable, not the registry's declared
  ## list, for the same reason `SearchVM.chainsChecked` is: naming a chain that
  ## could not be read would claim a search that did not happen.
  ##
  ## Takes no path, so the body is a pure function of the tree and
  ## `static_export` can write these exact bytes to `404.html` — see
  ## `pages/notfound.nim`.
  pageLayout(
    "Not found — BlockTracer",
    "Nothing is published at this address.",
    notFoundPg.notFoundPage(chains(r)),
    robots = "noindex,nofollow")

# ── route enumeration + dispatch ────────────────────────────────────────────

proc staticRoutes*(r: DataRoot): seq[string] =
  ## Every clean-URL route the explorer renders from the data tree.
  ##
  ## Enumerated from the data rather than declared, which is what makes the
  ## route set and the page bodies the same source of truth: a block that is
  ## published gets a page, a page of a cursor walk exists exactly while the
  ## walk has one, and an address the generation indexes gets a page for every
  ## segment its own list carries. Nothing here is a literal path except the
  ## five site-level pages, which have no entity behind them.
  result.add "/"
  result.add "/chains"
  result.add "/about"
  result.add "/search"
  result.add "/settings"
  for chain in chains(r):
    let info = chainInfo(r, chain)
    result.add "/" & chain
    # Block list, walked to exhaustion by its own cursor — so a page exists
    # exactly when the pager offers a link to it, and never otherwise.
    result.add blocksUrl(chain)
    var page = blocksFrom(r, info, -1)
    while page.hasMore:
      result.add blocksFromUrl(chain, page.nextFrom)
      page = blocksFrom(r, info, page.nextFrom)
    result.add txsUrl(chain)
    var tp = txsFrom(r, info, -1)
    while tp.hasMore:
      result.add txsFromUrl(chain, tp.nextFrom)
      tp = txsFrom(r, info, tp.nextFrom)
    # ── EVERY IDENTIFIER THAT BECOMES A ROUTE IS KEY-FORMED HERE ─────────────
    #
    # `blockHashes` and `bd.transactions` read identifiers out of published
    # OBJECT BODIES, and a body carries the DISPLAY form — that is the whole
    # point of the two forms being separate, and `identifier-encodings.json`
    # states it outright: "DISPLAY FORM: the identifier a published object
    # carries in its body… KEY FORM: every path segment and every index key…
    # and the route `/{chain}/{kind}/{id}/`".
    #
    # So these two lists are the one place in the tree where a display form was
    # being spelled straight into a key position. A no-op for every chain
    # published today, because `hex`'s two forms coincide for a field element —
    # but the first chain whose forms differ gets its ENTIRE static export at
    # spellings the producer never wrote: the page is rendered at
    # `/eth/tx/0xAbC…`, the object sits at `d/eth/tx/…/0xabc….json`, and the
    # §5 hash index is built from THIS LIST, so the index would key the display
    # form too and a correctly-spelled query would miss an entity that is right
    # there. Fixing it here fixes all three at once, because all three read this
    # enumeration.
    let enc = info.session.identifierEncoding
    for h in blockHashes(r, info):
      result.add "/" & chain & "/block/" & identifierKeyForm(enc, KindBlock, h)
      let bd = readBlockDetail(r, info, h)
      for txh in bd.transactions:
        let txh = identifierKeyForm(enc, KindTransaction, txh)
        result.add "/" & chain & "/tx/" & txh
        # Page-Descriptions §8: the explicit full-viewport route and the deep
        # link target. Enumerated for EVERY transaction, not only the ones with
        # a replayable trace, because §7.0's `absent`/`unsupported` rows are
        # states this route renders — "the metadata, with the reason stated" —
        # and a 404 there would be a different, worse answer.
        result.add "/" & chain & "/tx/" & txh & "/debug"
    for rawAddress in addressesInGeneration(r, info):
      # Key-formed for the reason above, and stated separately because the
      # address list has a second source: it is read from the generation root's
      # `addr` paths, whose file NAMES are already key forms, so today this is a
      # no-op twice over. `identifierKeyForm` is idempotent — it folds case and
      # touches nothing else — so applying it to a value that is already a key
      # form is safe, which is what lets every route site say the rule out loud
      # instead of tracking which of its inputs happens to be normalised.
      let address = identifierKeyForm(enc, KindAddress, rawAddress)
      result.add addressUrl(chain, address)
      result.add addressCodeUrl(chain, address)
      let listed = addressSegmentPaths(r, info, address)
      # Every segment but the first: the first IS the address page, and a
      # second URL serving identical bytes is the duplicate a canonical link
      # exists to prevent.
      for i in 1 ..< listed.paths.len:
        result.add addressSegmentUrl(chain, address, segmentIdOf(listed.paths[i]))

proc sitemapRoutes*(r: DataRoot): seq[string] =
  ## The subset of `staticRoutes` that is submitted to search engines.
  for route in staticRoutes(r):
    if isSitemapRoute(route): result.add route

proc renderRoute*(r: DataRoot, path: string): tuple[status: int, body: string, contentType: string] =
  ## Dispatch one clean-URL path to its renderer.
  ##
  ## ── A NON-KEY SPELLING NOW RESOLVES, AND THE PAGE STILL NAMES ITSELF AS THE
  ##    CANONICAL ONE. RECORDED HERE, NOT CLOSED ──────────────────────────────
  ##
  ## Every entity branch below resolves its object through a builder that
  ## KEY-FORMS the identifier, so `/{chain}/tx/0xABC…`, `/{chain}/block/0xABC…`
  ## and `/{chain}/address/0xABC…` all return 200 against a tree that published
  ## the folded spelling. That is the point of the case rule and it is tested at
  ## this level (`client/tests/test_debug_route.nim`, all three kinds, with a
  ## one-digit-different control that still 404s).
  ##
  ## What no renderer then does is key-form the URL it writes into
  ## `<link rel="canonical">`. Each echoes the spelling it was CALLED with, at
  ## FIVE sites — `renderBlock`, `renderAddress`, `renderAddressCode`,
  ## `renderTx` and `renderDebug` — so N spellings of one page each answer 200
  ## and each declares ITSELF canonical. That is precisely the duplicate a
  ## canonical link exists to prevent, which `staticRoutes` above says in so
  ## many words about segment URLs.
  ##
  ## NOT INHERITED, AND NOT WHOLLY NEW EITHER. Before per-encoding case handling
  ## every kind was equally case-sensitive, a non-key spelling 404ed, and there
  ## was no duplicate to declare. The transaction and address kinds acquired
  ## this when they began folding; `blockPath` taking the declaration widened it
  ## to the third. The surface is wider by one kind; the defect is the same one.
  ##
  ## WHY IT IS RECORDED AND NOT PATCHED HERE. The two candidate answers are
  ## different decisions and neither is a rename. Emitting the KEY form in the
  ## canonical link keeps every spelling a 200 and points them all at one URL;
  ## REDIRECTING a non-key spelling is the stricter answer and is a router and
  ## hosting-layer change, not an SSR one. SEO-And-Crawl-Budget.md §6 classes
  ## these routes but does not choose between the two, and a canonical tag is
  ## published content — so it wants the decision made rather than taken in
  ## passing, which is the same argument that kept `blockPath` unwidened until
  ## it had its own review.
  ##
  ## NOTHING THIS REPOSITORY PUBLISHES IS IN THE DUPLICATED STATE. `staticRoutes`
  ## and `sitemapRoutes` enumerate from the tree, so every route exported or
  ## submitted carries an identifier the producer wrote. A hand-typed or
  ## externally-linked URL is what reaches the state above.
  let p = path.strip(chars = {'/'})
  if p.len == 0:
    return (200, renderHome(r), "text/html")
  let parts = p.split('/')
  # Every route below the site level is chain-scoped, and `chainInfo` RAISES on
  # a chain the registry does not publish (`DataPlaneError`, so that a page
  # silently omitting a chain fails the build rather than half-rendering). That
  # is right for the exporter and wrong for a dispatcher: an unknown slug in a
  # URL is a visitor's typo, and §14's answer to it is "not on this chain",
  # not an exception. So the slug is checked ONCE here, against the registry,
  # before any branch reaches a reader.
  if parts.len >= 2 and parts[0] notin chains(r):
    return (404, renderNotFound(r), "text/html")
  case parts.len
  of 1:
    case parts[0]
    of "chains": return (200, renderChains(r), "text/html")
    of "about": return (200, renderAbout(r), "text/html")
    of "search": return (200, renderSearch(r), "text/html")
    of "settings": return (200, renderSettings(r), "text/html")
    else:
      if parts[0] in chains(r):
        return (200, renderChain(r, parts[0]), "text/html")
  of 2:
    if parts[1] == "blocks":
      return (200, renderBlockList(r, parts[0], -1), "text/html")
    if parts[1] == "txs":
      return (200, renderTxList(r, parts[0], -1), "text/html")
  of 3:
    case parts[1]
    of "block":
      if hasBlock(r, chainInfo(r, parts[0]), parts[2]):
        return (200, renderBlock(r, parts[0], parts[2]), "text/html")
    of "tx":
      if hasTx(r, chainInfo(r, parts[0]), parts[2]):
        return (200, renderTx(r, parts[0], parts[2]), "text/html")
    of "address":
      let info = chainInfo(r, parts[0])
      if addressSegmentPaths(r, info, parts[2]).found:
        return (200, renderAddress(r, parts[0], parts[2], ""), "text/html")
    else: discard
  of 4:
    if parts[1] == "tx" and parts[3] == "debug" and
       hasTx(r, chainInfo(r, parts[0]), parts[2]):
      return (200, renderDebug(r, parts[0], parts[2]), "text/html")
    if parts[1] == "address" and parts[3] == "code":
      let info = chainInfo(r, parts[0])
      if addressSegmentPaths(r, info, parts[2]).found:
        return (200, renderAddressCode(r, parts[0], parts[2]), "text/html")
    if parts[1] == "blocks" and parts[2] == "from":
      try:
        return (200, renderBlockList(r, parts[0], parseInt(parts[3])), "text/html")
      except ValueError: discard
    if parts[1] == "txs" and parts[2] == "from":
      try:
        return (200, renderTxList(r, parts[0], parseInt(parts[3])), "text/html")
      except ValueError: discard
  of 5:
    if parts[1] == "address" and parts[3] == "seg":
      let info = chainInfo(r, parts[0])
      let v = addressView(r, info, parts[2], parts[4])
      if v.indexed:
        return (200, renderAddress(r, parts[0], parts[2], parts[4]), "text/html")
  else: discard
  (404, renderNotFound(r), "text/html")
