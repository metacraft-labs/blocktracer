## The static tree's producer for `DebugSessionView` — one of the two named in
## `session_view.nim`.
##
## ## What is derived and what is fixture, stated plainly
##
## Everything about the *transaction* is derived from published data and
## nothing else: chain, hash, block position, outcome and revert reason,
## finality, the roles and cost rows, the per-execution trace states, the
## container path and byte count, the manifest's step and frame counts, the
## recorder verdict. It comes through `reader`/`@blocktracer/client`, which is
## the same path `pages/tx.nim` reads, and it is why the metadata pane and the
## transaction page cannot diverge.
##
## Everything about the *replay* — which line the session sits on, the call
## frames, the variable values, the event stream — is **fixture data**. It has
## to be: producing it means opening the CTFS container and running the replay
## engine, the engine is WASM in a worker, and `static_export.nim` is a Nim
## compile with isonim on the path and no browser anywhere near it. This module
## is the SSR analogue of `MockBackendService`: a deterministic stand-in that
## lets everything above the seam be built and tested before the transport
## exists.
##
## The fixture is not invented from nothing. Its source files, its symbol table
## and its call structure are the real `zk_shields` Noir program the packaged
## trace records (`client/fixtures/demo-session/`), so the shapes the panes are
## designed against — a four-deep call tree, a loop that runs eight times, a
## program that prints on every iteration — are the shapes the real trace has.
##
## When `WorkerBackendService` lands, hydration produces the same
## `DebugSessionView` from a live session and this module keeps serving the
## pre-hydration frame. Nothing between here and the renderers changes.

import std/[algorithm, json, os, strutils, tables]
import ../reader
import ../viewutil
import ./deeplink_landing
import ./demo_flow
import ./flow_view
import ./instruction_listing
import ./replay_engine
import ./session_view
import ./source_document

const
  FixtureDir = currentSourcePath().parentDir.parentDir.parentDir /
               "fixtures" / "demo-session"
  MainNr = staticRead(FixtureDir / "src" / "main.nr")
  ShieldNr = staticRead(FixtureDir / "src" / "shield.nr")
  SymbolsJson = staticRead(FixtureDir / "symbols.json")
    ## Read at COMPILE time. `staticRead` is what keeps the exporter's runtime
    ## dependency set unchanged — the built binary needs no fixture directory
    ## beside it, so `nix build .#default` and a `nim c -r` from any working
    ## directory produce the same site.

  DemoLanguage = "noir"
  DemoModule = "zk_shields"

# ---------------------------------------------------------------------------
# The symbol table — real data, used for what a symbol table is for
# ---------------------------------------------------------------------------

type Symbol* = object
  name*, path*, kind*: string
  line*: int

proc demoSymbols*(): seq[Symbol] =
  ## The recorded program's symbols. The call trace below names frames through
  ## this rather than by spelling function names twice: a frame whose function
  ## is not a symbol of the recorded program is a frame that could not have
  ## happened, and `symbolLine` raising is how that shows up.
  for n in parseJson(SymbolsJson):
    result.add Symbol(name: n["name"].getStr, path: n["path"].getStr,
                      kind: n["kind"].getStr, line: n["line"].getInt)

proc symbolOf(name: string): Symbol =
  for s in demoSymbols():
    if s.name == name and s.kind == "function": return s
  raise newException(ValueError,
    "no function symbol '" & name & "' in the demo program's symbol table")

# ---------------------------------------------------------------------------
# The editor pane
# ---------------------------------------------------------------------------

proc fixtureDocuments(currentPath: string; currentLine: int;
                      executed: Table[string, seq[int]]): seq[SourceDocument] =
  for (path, text) in {"src/main.nr": MainNr, "src/shield.nr": ShieldNr}:
    result.add newSourceDocument(
      path, DemoLanguage, text,
      executed = executed.getOrDefault(path, @[]),
      currentLine = (if path == currentPath: currentLine else: 0))

proc sourceDocumentsFromBundle*(bundle: JsonNode): seq[SourceDocument] =
  ## A published source bundle's `sources` map → documents, in path order.
  ##
  ## Source-Resolution.md §5 fixes the shape: `sources` is an object keyed by
  ## the path the container interns, each value carrying `content`. Sorted by
  ## path so a bundle written by a different producer renders in the same order
  ## as one written by ours.
  if bundle.isNil or bundle.kind != JObject: return
  if not bundle.hasKey("sources"): return
  let sources = bundle["sources"]
  if sources.kind != JObject: return
  var paths: seq[string]
  for path, _ in sources: paths.add path
  paths.sort()
  for path in paths:
    let entry = sources[path]
    if entry.kind != JObject or not entry.hasKey("content"): continue
    if entry["content"].kind != JString: continue
    let language =
      if bundle.hasKey("language") and bundle["language"].kind == JString:
        bundle["language"].getStr
      else: ""
    result.add newSourceDocument(path, language, entry["content"].getStr)

# ---------------------------------------------------------------------------
# The fixture session's position, and the panes that follow from it
# ---------------------------------------------------------------------------

const
  # The fixture sits inside `calculate_damage`, called from the third
  # iteration of `iterate_asteroids`'s loop, called from `main`. Four frames
  # deep with a loop above it is the case every pane is hard at: the call trace
  # has to indent it, the state pane has to show both the loop's variables and
  # the callee's, and the event log has to interleave the loop's output with
  # the call that produced it.
  FixtureFile = "src/shield.nr"
  FixtureLine = 32           ## `damage = mass * (100 - shield_pct);`
  FixtureStep = 128          ## matches views.mjs's DEBUG_TIME_COORDINATE_MID
  FixtureTotalSteps = 1315   ## the recorded trace's step count

proc executedLines(): Table[string, seq[int]] =
  ## The lines the fixture session has visited by `FixtureStep`. Enumerated
  ## rather than computed: a pane that highlighted "every non-blank line" would
  ## look identical on a screenshot and be wrong on every real trace.
  ##
  ## Enumerated is not the same as invented, so this set is derived from the
  ## program the same way `fixtureState` derives its numbers — by following the
  ## control flow with the recorded inputs. The session sits at `src/shield.nr`
  ## line 32 in iteration 2, so the set is everything reached up to there and
  ## nothing after it:
  ##
  ##   * `main.nr` has reached only 12, 13 and the call on 15. Line 16's
  ##     conditional has not been evaluated, and its `else` on line 20 never
  ##     will be — the positive case survives with 1018 shield — so marking
  ##     either would put a gutter dot on a branch the trace does not take.
  ##
  ##   * `shield.nr` line 29 (`damage = mass * 1`) IS visited: iterations 0 and
  ##     1 both run at 100% shields, and only iteration 2 falls to the `else`
  ##     on 31/32. Both arms of that conditional are on the path.
  ##
  ##   * `calculate_shield_regeneration` (40–46) is visited for the same
  ##     reason: line 11 calls it in iterations 0 and 1, and line 44 is taken
  ##     in iteration 0, where the regeneration would overflow the initial
  ##     shield and is clamped. A call site marked executed above a body that
  ##     is not is a contradiction a reader can see on the screenshot.
  result["src/main.nr"] = @[12, 13, 15]
  result["src/shield.nr"] = @[1, 2, 4, 5, 6, 7, 9, 10, 11, 12, 14,
                              22, 26, 27, 28, 29, 31, 32, 34, 37,
                              40, 42, 43, 44, 46,
                              48, 49, 50, 53, 54, 57, 58, 60, 61, 63, 64, 65, 66]

proc withDemoFlow(pane: var EditorPane) =
  ## Attach the recorded values to whatever documents the pane holds.
  ##
  ## Separate from `fixtureEditor` and applied again in `withPublishedSources`,
  ## for the reason `markExecuted` is separate: the values belong to the TRACE
  ## and not to the copy of the file being rendered. A pane whose documents were
  ## replaced by a published bundle must come back with the same overlay — the
  ## bundle changes where the source came from and nothing else about the frame
  ## — and the join is by interned path, which is the same join a step uses to
  ## resolve to a line.
  applyFlow(pane, demoFlowInput(ShieldNr))

proc fixtureEditor(): EditorPane =
  result.availability = srcSourceLevel
  result.documents = fixtureDocuments(FixtureFile, FixtureLine, executedLines())
  result.currentLine = FixtureLine
  result.activeIndex = documentIndex(result, FixtureFile)
  withDemoFlow(result)

proc fixtureCalltrace(): CallTracePane =
  ## Four frames, three depths, plus the sibling calls the loop has already
  ## made — so the pane is judged at depth rather than as a flat list.
  proc frame(name: string; depth, step: int; cost: string;
             current = false): CallFrame =
    let s = symbolOf(name)
    # `s.line` is the symbol table's line for the FUNCTION — where it is
    # declared — so the two `calculate_damage` frames below carry the same one.
    # That is correct and it is also the limit of what a line can do here: they
    # are two occurrences of one function, and what tells them apart is `step`
    # (41 and 112). The row paints the line to place the function in its file,
    # and the selection panel leads with the step to identify the frame.
    CallFrame(depth: depth, fn: s.name, module: DemoModule & " · " & s.path,
              line: s.line,
              cost: cost, costUnit: "opcodes", step: step, current: current)
  result.costLabel = "ACIR"
  result.costUnit = "opcodes"
  result.frames = @[
    frame("main", 0, 1, "1,315"),
    frame("iterate_asteroids", 1, 6, "1,208"),
    frame("calculate_damage", 2, 41, "63"),
    frame("calculate_remaining_shield_pct", 3, 49, "11"),
    frame("status_report", 2, 74, "96"),
    frame("calculate_damage", 2, 112, "63", current = true),
    frame("calculate_remaining_shield_pct", 3, 120, "11"),
  ]
  # §6.0a's `call:` anchors, from the shared derivation. Stamped here rather
  # than spelled per frame so the path a share link emits and the path an
  # incoming link resolves against are one function's output.
  withCallAnchors(result)

proc fixtureState(): StatePane =
  ## The values are **computed from the recorded program and its recorded
  ## inputs**, not invented to look plausible.
  ##
  ## `Prover.toml` gives `initial_shield = 10000`,
  ## `shield_regen_percentage = 10` and
  ## `asteroid_masses_positive = [100, 2000, 200, …]`. Running `shield.nr` by
  ## hand: iteration 0 takes 100 damage at 100% and regenerates back to 10000;
  ## iteration 1 takes 2000 and regenerates to 9000; iteration 2 therefore
  ## enters `calculate_damage` with `remaining_shield = 9000`, `mass = 200` and
  ## `shield_pct = 90`, and line 32 assigns `damage = 200 * (100 - 90) = 2000`.
  ##
  ## That matters beyond tidiness. A state pane whose numbers do not satisfy
  ## the source beside them is unfalsifiable — nobody can tell it from a
  ## correct one — and `remaining_shield` moving at all is the property the
  ## recorder's compound-assignment fix (`906af2f42d`) restored. A pane showing
  ## it frozen at its initial value is the bug, not the design.
  result.values = @[
    StateValue(name: "initial_shield", typ: "Field", value: "10000"),
    StateValue(name: "remaining_shield", typ: "Field", value: "9000",
               changed: true),
    StateValue(name: "shield_regen_percentage", typ: "Field", value: "10"),
    StateValue(name: "masses", typ: "[Field; 8]",
               value: "[100, 2000, 200, 100, 100, 50, 50, 14]"),
    StateValue(depth: 1, name: "masses[2]", typ: "Field", value: "200"),
    StateValue(name: "mass", typ: "Field", value: "200"),
    StateValue(name: "shield_pct", typ: "Field", value: "90"),
    StateValue(name: "damage", typ: "Field", value: "2000", changed: true),
    StateValue(name: "regeneration", typ: "Field", value: "1000"),
    StateValue(name: "i", typ: "u32", value: "2"),
  ]

proc fixtureEventLog(reverted: bool): EventLogPane =
  ## Mixed kinds in one stream, which is the pane's whole job: calls, the
  ## storage writes and events a chain contributes, the program's own output,
  ## and — on a reverted transaction — the revert that ends it.
  ##
  ## The `output` rows are the program's own `println`s, at the values its
  ## recorded inputs produce (see `fixtureState`); the `call` rows are its real
  ## functions. The `storageWrite` and `event` rows are the chain's
  ## contribution — this demo transaction wraps the circuit execution — and are
  ## demo data like every other fact in this tree.
  result.rows = @[
    EventRow(kind: evCall, step: 6, label: "iterate_asteroids",
             detail: "initial_shield=10000, regen=10%"),
    EventRow(kind: evOutput, step: 22, label: "----- iteration 0 -----",
             detail: "stdout"),
    EventRow(kind: evStorageWrite, step: 31, label: "shields[0]",
             detail: "10000 → 9900"),
    EventRow(kind: evEvent, step: 58, label: "ShieldImpact",
             detail: "iteration=0, damage=100"),
    EventRow(kind: evOutput, step: 74, label: "Shield status 100% 10000",
             detail: "stdout"),
    EventRow(kind: evStorageWrite, step: 96, label: "shields[1]",
             detail: "10000 → 8000"),
    EventRow(kind: evCall, step: 112, label: "calculate_damage",
             detail: "mass=200", current: true),
    EventRow(kind: evEvent, step: 121, label: "ShieldImpact",
             detail: "iteration=2, damage=2000"),
  ]
  if reverted:
    result.rows.add EventRow(kind: evRevert, step: 1299,
      label: "assert(did_survive_positive == true)",
      detail: "constraint not satisfied — the shields did not hold")
  # `log:`, `sw:` and `revert` anchors, per §6.0a's kind table. Same reason as
  # the call trace's: one derivation, so emitting and resolving agree.
  withEventAnchors(result)

func entryStepWithin*(steps: int): int =
  ## Where a session with no `?t=` lands, INSIDE the trace it is landing in.
  ##
  ## It was `FixtureStep` — 128 — for every session, which is right for the
  ## vendored Noir recording (1315 steps) and for any real trace at least that
  ## long. A real testnet transaction is 108 steps, and the page served
  ## `step 128 of 1315` for it: a position past the end of its own recording,
  ## and a TOTAL borrowed from a program that never executed under that hash.
  ## That is the fixture asserting itself over real chain data, which this file
  ## has already had to stop doing twice (the source pane, and the language tag).
  ##
  ## The rule keeps the fixture's landing wherever the trace can hold it and
  ## lands on the trace's own last step otherwise. It does not invent a fraction:
  ## `FixtureStep / FixtureTotalSteps` is where one recording happens to have
  ## been photographed, not a ratio anything measured, and a session that landed
  ## at "9.7% of wherever you are" would be a number with no referent.
  ##
  ## ## AND IT IS THE FIXTURE'S RULE ONLY. See `chainEntryStep`.
  ##
  ## This proc is reachable from the fixture branch of `demoSession` and from
  ## nowhere else. That is the whole of the earlier fix's remaining defect: the
  ## FIRST correction here moved the DENOMINATOR off `FixtureTotalSteps` and
  ## left the NUMERATOR a constant, so eight published chain transactions went
  ## on opening at literally step 128 — whatever their length — because 128 is
  ## below every one of their step counts and the clamp above therefore never
  ## fired. A clamp that only notices a recording SHORTER than the photograph
  ## cannot notice that the photograph is of a different program.
  if steps <= 0: 0
  elif steps < FixtureStep: steps
  else: FixtureStep

func chainEntryStep*(): int =
  ## Where a session with no `?t=` lands on a REAL CHAIN RECORDING: the front
  ## of the recording, tick 0.
  ##
  ## `FixtureStep` is deliberately not in this expression and must not come
  ## back into it. 128 is the tick at which one vendored Noir demo was
  ## photographed — the file's own comment concedes it is "not a ratio anything
  ## measured" — and every pane of that fixture is consistent with it
  ## (`executedLines` is the set visited BY 128, `fixtureCalltrace` marks the
  ## frame open at 112, `fixtureState` computes iteration 2's values). None of
  ## that is true of a chain transaction: 128 is a coordinate inside a
  ## different recording, and a page opening there opens nowhere in particular.
  ##
  ## Tick 0 is not itself the answer a visitor sees, and it is not meant to be.
  ## It is the FRONT of the recording, and the two producers below move it
  ## forward to the first frame this page can actually show:
  ##
  ##   * `withSourcePositions` scans forward from here to the first step that
  ##     carries a `(path, line)` — on `0x0a807e4e…` that is tick 14,
  ##     `FeeJuice::public_dispatch` at `main.nr:203`, and `focus` then makes
  ##     the contract's own `main.nr` the open document. Landing at 128 made
  ##     that scan start PAST the positioned region (14..107), find nothing
  ##     forward, and fall into the backward scan — which is why the best page
  ##     in the product used to open on the LAST positioned step of its own
  ##     execution, inside a one-line `avm.nr` oracle shim.
  ##   * `withInstructionListing` marks row 0, which is tick 0, which is the
  ##     first instruction the recording executed.
  ##
  ## So the rule is "open at the front and let whichever pane owns the rows
  ## move to the first one it has", and both moves already existed — they were
  ## being entered from the wrong side.
  0

proc fixtureControls(positioned, live: bool; steps: int;
                     entryStep = -1): DebugControlsPane =
  ## `positioned` is "the panes carry a step"; `live` is "the engine can move
  ## it". They are different on the static route, where the first is true and
  ## the second is false, and the toolbar's enablement follows the second —
  ## an enabled button with no engine behind it is an affordance that lies on
  ## click, which is the single most likely wrong thing to ship here.
  # Four pairs, reverse then forward, in the desktop app's own toolbar order —
  # which is `DebugAction`'s declaration order, so iterating the enum IS the
  # toolbar. The name and the mark are the action's (`controlLabel`,
  # `components/icons`); this producer states only what the served page knows,
  # which is that nothing can move until the engine is live.
  #
  # It used to hold its own copy of the eight labels and glyphs, as did
  # `session_project.projectControls`, and the served toolbar and the hydrated
  # one were therefore two independent claims about one control strip.
  result.buttons = @[]
  for a in DebugAction:
    result.buttons.add ControlButton(action: a, enabled: live)
  result.positioned = positioned
  result.totalSteps = steps
  # `entryStep` IS THE CALLER'S, and the default is the fixture's rule.
  #
  # A negative `entryStep` means "you decide", which is the fixture's case and
  # the only case that wants `entryStepWithin`. Every other caller states the
  # tick it wants, so a producer cannot acquire the fixture's photograph by
  # forgetting to opt out of it — which is exactly how 128 reached eight chain
  # transactions.
  # NO CLAMP HERE, deliberately. `withInstructionListing` and
  # `withSourcePositions` clamp against the length of the stream they are about
  # to render, which is the only length that can be wrong about; the manifest's
  # `steps` is a second number and a second clamp against it would be a second
  # producer of one coordinate. See `withInstructionListing`'s own note.
  result.step =
    if not positioned: 0
    elif entryStep >= 0: entryStep
    else: entryStepWithin(steps)
  # Short, because this now renders in the identity bar beside the controls it
  # describes rather than in a pane of its own — and because the step counter
  # sits next to it (`.dcsteps`), so repeating "step 128 of 1315" here spent a
  # third of the bar restating the field to its right. What the counter cannot
  # say is WHAT is being waited for and HOW BIG it is, which is the whole of
  # what the removed engine-notice row contributed and all that is kept of it.
  result.statusText =
    if positioned and live: "Stepping"
    elif positioned:
      "Engine loading — " & approxMegabytes(ReplayEngineWasmBytes)
    else: "No position yet"

# ---------------------------------------------------------------------------
# The metadata pane — derived, never fixture
# ---------------------------------------------------------------------------

proc metadataPane*(chain: string; v: TxView; info: ChainInfo;
                   ending = eeUnstated): MetadataPane =
  ## §7.1's pane, from `viewutil.txMetadataRows` — the same seq the explorer's
  ## overview grid renders. Nothing is assembled here that the page does not
  ## also see.
  MetadataPane(
    chain: chain, hash: v.hash,
    outcome: outcomeLabel(v.outcome),
    outcomeBadge: outcomeClass(v.outcome),
    revertReason: v.outcomeReason,
    revertReasonLabel: outcomeReasonLabel(v.outcome),
    revertReasonTone: outcomeReasonTone(v.outcome),
    rows: txMetadataRows(chain, v, info, ending),
    executions: txExecutionRows(v),
    payload: txPayloadRows(v),
    payloadNote: payloadNote(v),
    native: txNativePayload(v))

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

proc demoSession*(chain: string; v: TxView; info: ChainInfo;
                  timeCoordinate = 0;
                  containerPath = ""; containerBytes = 0;
                  contentHash = "";
                  totalSteps = FixtureTotalSteps;
                  sourceLevel = true;
                  ending = eeUnstated): DebugSessionView =
  ## The pre-hydration frame for one transaction, with `trace.availability`
  ## deciding what it is — Page-Descriptions §7.0's table, applied to the
  ## explicit debug route:
  ##
  ##   ready, divergent   the session, with the divergence banner where one
  ##                      is due
  ##   onDemand           the generate action; no session, and no pretence
  ##   absent, unsupported the metadata and the reason; no debugging affordance
  ##
  ## `availability` decides this, never a preference and never a query
  ## parameter, which is what M8b's
  ## `test_availability_decides_the_landing_not_a_preference` checks.
  ##
  ## Note what the first row is NOT: a live session. `phase` stays `spFetching`
  ## because no replay engine has been loaded — see the `spFetching` branch.
  result.chain = chain
  result.txHash = v.hash
  result.blockHeight = v.height
  result.blockHash = v.blockHash
  result.outcomeLabel = outcomeLabel(v.outcome)
  result.outcomeBadge = outcomeClass(v.outcome)
  result.finality = v.finality
  result.timeCoordinate = timeCoordinate
  result.containerPath = containerPath
  result.containerBytes = containerBytes
  # Carried in every state, including the ones with no session: §6.0a's step 1
  # is "no replayable artifact → state that", and a browser has to be able to
  # tell that apart from "a different artifact", which needs the hash to be
  # absent for a real reason rather than absent because nobody passed it.
  result.traceContentHash = contentHash
  # `languages` is NOT set here. See the `else` arm of the `taReady, taDivergent`
  # branch below, which is the only state that knows a language.
  result.engineBase = ReplayEngineBase
  result.engineCrossOrigin = replayEngineIsCrossOrigin()
  result.engineBytes = ReplayEngineWasmBytes
  result.metadata = metadataPane(chain, v, info, ending)

  # The fixture session sits at step 128 of the recorded program. A tree whose
  # manifest still describes a stand-in container reports fewer steps than
  # that, and rendering "step 128 of 11" would put the position past the end of
  # its own trace. So the manifest's count is used when it can hold the
  # position and the fixture's own recorded total otherwise — which resolves
  # itself the moment the tree publishes the real container, because then the
  # manifest says 1315 and the two agree.
  # THE MANIFEST'S COUNT, WHENEVER THERE IS ONE. This used to read
  # `if totalSteps > FixtureStep`, which silently substituted the FIXTURE's 1315
  # for any real recording shorter than 128 steps — a real testnet transaction of
  # 108 steps was published as "of 1315". The guard was there because the
  # position was a constant that a short trace could not hold; the position is
  # derived from the trace now (`entryStepWithin`), so the total no longer has to
  # be inflated to accommodate it. `FixtureTotalSteps` remains the answer only
  # where there is no manifest at all, which is the fixture's own case.
  let steps = if totalSteps > 0: totalSteps else: FixtureTotalSteps

  # WHERE A SESSION WITH NO `?t=` LANDS, DECIDED ONCE, BY WHICH KIND OF
  # RECORDING THIS IS.
  #
  # `sourceLevel` is the manifest's own bit and it is already the discriminator
  # every pane below uses: true takes the vendored fixture's panes, false takes
  # the chain's. The landing step has to follow the same split, because the
  # fixture's 128 is a coordinate inside the fixture's recording and means
  # nothing anywhere else (`chainEntryStep`). `-1` is "use the fixture's rule"
  # — see `fixtureControls`.
  let entryStep = if sourceLevel: -1 else: chainEntryStep()

  case v.headline
  of taReady, taDivergent:
    # `spFetching`, not `spReady`: this is the PRE-HYDRATION frame. The panes
    # below are fully populated from published data — which is what §7.0 means
    # by "the transaction page is not a waiting room before the debugger; it is
    # the debugger's first frame" — but no engine has been fetched, so nothing
    # can step yet and the page must not imply otherwise.
    result.phase = spFetching
    result.hasFrame = true
    # The SAME derivation the controls use, so the URL coordinate the page
    # reports and the step the toolbar shows cannot come apart — they were two
    # spellings of `FixtureStep`, which agreed only because both were wrong in
    # the same way. It is read back OFF the controls now rather than recomputed
    # beside them, which is one derivation rather than two that agree.
    result.timeCoordinate = timeCoordinate
    result.integrity =
      if v.headline == taDivergent: siDivergent else: siValidated
    if v.headline == taDivergent:
      result.integrityDetail =
        "The differential oracle replayed this transaction and disagreed with " &
        "the chain's own result. The trace is real and steps normally; what it " &
        "cannot be used for is proving what the chain did."
    if not sourceLevel:
      # INSTRUCTION LEVEL. The manifest says this container carries no source
      # positions, so every pane below it must decline rather than borrow.
      #
      # This branch exists because the alternative was live for exactly one
      # build: the panes below are a FIXTURE — one recorded Noir program — and
      # before this branch a real chain transaction with a real container
      # rendered that fixture's source, its loop counts and its variable values
      # as though they were its own. A recording whose every step is a bare
      # program counter cannot show a line of Noir, an iteration count or a
      # local's value, and a page that showed them would not be slightly
      # optimistic; it would be displaying another program's execution under
      # this transaction's hash.
      #
      # The fidelity ladder's floor is a real rung, not a failure: the trace is
      # complete, it steps, and what is missing is only the text to show it
      # against. `srcUnverified` is the state that says exactly that, and §14's
      # "supply sources" affordance hangs off it.
      # WHAT THESE SENTENCES SAY, AND THE CLAIM THEY NO LONGER MAKE.
      #
      # They used to say "the chain publishes no source for this contract — an
      # Aztec contract class carries bytecode, and no debug symbols, no file map
      # and no source text". Every clause after the dash is true of the ON-CHAIN
      # class object and none of it is true as a claim about AVAILABILITY, which
      # is what a reader takes from it. `ContractClassPublic` carries
      # `artifactHash`, and upstream's own doc comment says that field is
      # "intended to be used by clients to verify that an offchain fetched
      # artifact matches a registered class" — the chain holds a COMMITMENT to
      # the artifact, which is a mechanism for obtaining source and not a
      # statement that none exists. Verified artifacts demonstrably resolve for
      # some contracts on these very chains.
      #
      # So the sentence is now about THIS RECORDING. What is true here is that
      # nothing resolved, not that nothing could — which keeps the page honest
      # in both directions: it does not promise source it has not got, and it
      # does not tell a reader the chain can never have any.
      #
      # The three pane notes below were the same claim restated three times.
      # They now say what each pane does not have and why, without deciding on
      # the chain's behalf what it will never publish.
      # ── AND IT NAMES NO CHAIN, which is the correction of 2026-10-08. ──────
      #
      # The sentence this replaces said "**Aztec** publishes a commitment to a
      # contract's compiled artifact rather than the artifact itself". That is
      # true of Aztec and this constructor serves EVERY chain: measured on the
      # first Ethereum mainnet transaction this tree ingested, the published
      # page told a visitor looking at a USDT transfer on Ethereum a fact about
      # Aztec's contract-class model. A page that names the wrong chain is not
      # over-specific, it is wrong, and it is wrong in the one pane whose whole
      # job is to explain why there is no source.
      #
      # The mechanism differs per chain and the SHAPE does not: a chain
      # publishes the bytecode that ran, source is obtained from somewhere else,
      # and something has to tie the two together — an `artifactHash`
      # commitment on Aztec, a verification registry plus the compiler the
      # contract was verified with on an EVM chain. What is true on all of them
      # is that the tying-together did not happen here, and that is now what it
      # says.
      #
      # IT STILL DOES NOT DECIDE ON THE CHAIN'S BEHALF THAT NO SOURCE EXISTS —
      # the property the previous correction landed and which is kept. "Nothing
      # resolved" is a statement about this recording; "there is none" would be
      # a claim about the chain, and on Ethereum it would additionally be false
      # for most verified contracts.
      result.editor = EditorPane(availability: srcUnverified,
        reason: "No source resolved for the code this transaction ran, so " &
                "this recording is at instruction level: every step is a " &
                "program counter into the contract's bytecode. A chain " &
                "publishes the bytecode that ran and not the source it was " &
                "built from, so source has to be obtained separately and " &
                "proved against that bytecode — which has not happened for " &
                "this contract. Stepping is complete either way.")
      # NOT "no function names". They HAVE names — the engine answers this
      # recording's call trace with `<toplevel>` and `enqueued-call-0` — and
      # for as long as this sentence said otherwise, the one pane that promised
      # data and delivered none was explaining the wrong absence. Six review
      # rounds filed it (vd9-r1 L4/L5/ADV, vd9-r2 L5/ADV): "it explains why
      # frames would be UNLABELLED, not why they are UNLISTED". They are listed
      # now, by the live session; what is genuinely missing is a source
      # position, and that is what this says.
      result.calltrace.note =
        "Frames are recorded and carry the names this recording gives them. " &
        "Nothing resolved a source position, so they carry no file or line. " &
        "They are listed once the session is live."
      result.state.note =
        "This recording carries no variable names. Naming a local needs the " &
        "debug symbols from the contract's compiled artifact, and none " &
        "resolved for this contract."
      result.eventLog.note =
        "Calls and storage writes are recorded against program counters " &
        "rather than source lines."
      result.controls = fixtureControls(positioned = true, live = false,
                                        steps = steps, entryStep = entryStep)
    else:
      # SOURCE LEVEL, and the only state in this constructor that knows what
      # language it is looking at. `languages` is set HERE, with the panes it
      # describes, rather than above the branch that decides whether they apply.
      #
      # It used to be set unconditionally beside `traceContentHash`, and the two
      # are not alike: a content hash is a fact about the CONTAINER and is
      # carried in every state on purpose (see its comment above), whereas a
      # language is a fact about the SOURCE, and three of the five §7.0 states
      # have none. The bar renders the tag on `s.languages.len > 0` alone
      # (`pages/debug.nim`), outside the `hasFrame` gate that suppresses the
      # controls and the phase rail — so the unconditional assignment put an
      # uppercase NOIR tag on the identity bar of:
      #
      #   * this branch's sibling, where the panes below it state in four
      #     separate sentences that the recording carries no debug symbols
      #     (round vd8-r1's L5 reviewer filed this P1 as forbidden fixture
      #     content — reviews/rounds/vd8-r1/debugger--testnet__wide__light__L5.json;
      #     not cited by ledger id because vd8-r2 replaced that triple's reviews
      #     and the id now names a different finding);
      #   * `onDemand`, where no trace has been recorded at all;
      #   * `absent` and `unsupported`, where no trace can ever exist.
      #
      # Only the first of those was reported. The other three are the same
      # assignment reaching further than the review that found it, which is why
      # the fix is placement and not a condition: there is no `if` here to get
      # wrong later.
      #
      # This is the second time fixture content has asserted itself over real
      # chain data. The first was the demo's Noir source rendering under a real
      # testnet transaction's hash — the defect the `if not sourceLevel` branch
      # above exists to prevent — and the tag is that same fixture claiming the
      # same authority one line higher up the page, having survived the fix
      # because it was written above the branch.
      result.languages = @[DemoLanguage]
      result.editor = fixtureEditor()
      result.calltrace = fixtureCalltrace()
      result.state = fixtureState()
      # The revert row appears only on a transaction that actually reverted.
      # `ooPartial` is not a revert — the demo's Aztec split transaction reports
      # `partial` with both halves succeeded — and rendering a failed constraint
      # against it would be the pane inventing an event the trace never carried.
      result.eventLog = fixtureEventLog(
        v.outcome in {ooReverted, ooFailedWithEffects})
      result.controls = fixtureControls(positioned = true, live = false,
                                        steps = steps, entryStep = entryStep)
    # ONE COORDINATE, READ OFF THE CONTROLS THAT OWN IT. Both arms above have
    # just built them, and an explicit `?t=` still wins — that is the visitor
    # asking for a position, which outranks any landing rule.
    if timeCoordinate <= 0:
      result.timeCoordinate = result.controls.step
  of taOnDemand:
    result.phase = spAwaitingGeneration
    result.unavailableReason = availabilityNote(taOnDemand)
    result.editor = EditorPane(availability: srcUnverified,
      reason: "Source is resolved from the trace, and no trace has been " &
              "recorded for this transaction yet.")
    result.calltrace.note =
      "The call structure comes from the execution trace."
    result.state.note = "Variable values come from the execution trace."
    result.eventLog.note =
      "Calls, storage writes and events come from the execution trace."
    result.controls = fixtureControls(positioned = false, live = false, steps = 0)
  of taAbsent, taUnsupported:
    result.phase = spUnavailable
    result.unavailableReason = availabilityNote(v.headline)
    # The published reason for THIS execution, where there is exactly one and
    # the tree carried words for it. `pages/tx.nim` renders the same value in
    # the same position on the metadata page — §7.1's rule that the transaction
    # page and the session say one thing about one transaction applies to the
    # reason it cannot be debugged as much as to its facts.
    if v.executions.len == 1:
      result.unavailableDetail = v.executions[0].reason
    result.editor = EditorPane(availability: srcAbsent,
      reason: availabilityNote(v.headline))
    result.controls = fixtureControls(positioned = false, live = false, steps = 0)

proc withPublishedSources*(session: var DebugSessionView; bundle: JsonNode) =
  ## Prefer a published source bundle over the fixture files.
  ##
  ## Source-Resolution.md §5 and Trace-Artifacts.md §4 make the manifest's
  ## recommendation the interpretation the page should use, so a tree that
  ## publishes source wins over anything vendored beside the client. A bundle
  ## that resolves to no usable documents is ignored rather than allowed to
  ## empty the pane — refusing to display is for a MISMATCHED bundle, and this
  ## is not that.
  ##
  ## The bundle supplies TEXT, and only text. The executed-line set and the
  ## position belong to the TRACE, so they are re-applied to the new documents
  ## rather than lost with the old ones — a published bundle winning must
  ## change where the source came from and nothing else about the frame. The
  ## coordinates carry over because they are the same coordinates: the bundle's
  ## layout under `src/` has to match the paths the container interns, or a
  ## step resolves to no source line at all.
  if not session.hasFrame: return
  # ONLY ONTO A PANE THAT IS ALREADY SHOWING SOURCE, and this guard was bought by a
  # regression the suite caught.
  #
  # The doc above says it exactly: "The bundle supplies TEXT, and only text. The
  # executed-line set and the position belong to the TRACE, so they are re-applied to
  # the new documents." A pane at `srcUnverified` has no such position to re-apply —
  # its rows are program counters, and its `currentLine` indexes a bytecode listing.
  # Handing it source text swapped the documents and then zeroed the coordinate,
  # which turned a positioned instruction-level frame into an unpositioned one.
  #
  # Nothing published used to reach this line without being source level, so the
  # guard was implicit in the tree rather than in the code. It stopped being implicit
  # the moment a bundle could be published for a PARTLY positioned recording
  # (CHAIN-CAPTURE.md §6.1a): that bundle's text is real and its positions are real,
  # but they arrive in `positions.json` beside the container rather than on the frame,
  # and until a pane knows how to read them the honest thing is to leave the
  # instruction listing alone.
  if session.editor.availability != srcSourceLevel: return
  let docs = sourceDocumentsFromBundle(bundle)
  if docs.len == 0: return
  # The position the session is ALREADY at, read off the session before its
  # documents are replaced. This used to be `FixtureFile` / `FixtureLine`, and
  # that was the defect: a bundle for any program the constant does not describe
  # left `activeIndex` at 0 — which after `sourceDocumentsFromBundle`'s sort is
  # whatever path sorts first, typically `Nargo.toml` — while `currentLine` kept
  # a line number belonging to a different file. `openAtCurrent` then windowed
  # the manifest to lines at or after `currentLine - lead` and kept NONE, so the
  # pane opened on an empty document.
  #
  # `activeIndex` cannot survive the replacement (it indexes the OLD seq) and
  # `currentLine` alone cannot locate a document, so the path has to be taken
  # before line 1 of the replacement. That is the whole fix: the product now
  # derives its own position instead of borrowing the fixture's.
  let posPath = activeDocument(session.editor).path
  let posLine = session.editor.currentLine
  var pane = session.editor
  pane.documents = docs
  pane.activeIndex = 0
  markExecuted(pane, executedLines())
  if posPath.len > 0 and posLine > 0 and documentIndex(pane, posPath) >= 0:
    focus(pane, posPath, posLine)
  else:
    # The bundle does not carry the file the session is in. The pane may open on
    # whatever it has, but it may NOT keep a line number that belongs to a file
    # it is not showing: that is the coordinate that empties the window.
    pane.currentLine = 0
  # ── Whose replay is this? ────────────────────────────────────────────────
  #
  # THE BUNDLE DECIDES, AND IT DECIDES MORE THAN THE TEXT.
  #
  # Everything about the replay in this module — the position, the call frames,
  # the variable values, the event stream, the values overlay — describes ONE
  # recorded program, `zk_shields`. That was harmless while one container stood
  # behind every published execution on this chain. It stopped being harmless
  # when the capability tour gave each of its programs its own recording: the
  # Code pane would show `triangular` and `collatz` while the Call Trace beside
  # it named `iterate_asteroids` and `calculate_damage`, and the Values pane
  # showed `remaining_shield`. Two programs on one screen, presented as one
  # session — a confident answer that is wrong, which is the single thing this
  # route may not produce.
  #
  # The test is the bundle's own contents and not the chain, the slug or the
  # transaction hash: the fixture describes a program whose source includes
  # `src/shield.nr`, so a bundle without that file is a bundle for a program
  # this module's replay does not describe. A tour program's bundle has none;
  # the six M5c executions all publish the fixture's own sources, so every one
  # of them keeps exactly the panes it had.
  #
  # What is served instead is not an error state. The transaction is real, the
  # recording is real and published, and the session opens — what the STATIC
  # frame cannot do is state a position inside it without a replay engine. So
  # the panes say that, and the live session fills them in.
  let describesThisProgram = documentIndex(pane, FixtureFile) >= 0
  if describesThisProgram:
    # The overlay is re-derived against the NEW documents. `newSourceDocument`
    # built them with no annotations, so a bundle that won without this line
    # would win by silently deleting the values — the same class of loss
    # `markExecuted` above exists to prevent for the gutter, and just as
    # invisible.
    withDemoFlow(pane)
  else:
    # No gutter marks either: `markExecuted` above applied the FIXTURE's
    # executed-line set, which on a different program marks lines that were
    # never reached. An unmarked gutter says nothing; a wrongly marked one says
    # something false.
    for d in pane.documents.mitems:
      for l in d.lines.mitems:
        l.executed = false
    pane.currentLine = 0
    # And the rail, which `fixtureEditor` already attached before this bundle
    # won. It is the fixture's loop, named after the fixture's function, with a
    # `line 4` link into a file this pane is no longer showing — the most
    # visible of the two-programs-on-one-screen symptoms, and the one a reader
    # would take for a fact about the program in front of them.
    pane.flow = FlowRail()
    # `positioned` is "the panes carry a step". They do not: the step this
    # module knows is the fixture's, and it is a coordinate inside a different
    # recording. `fixtureControls` already renders the unpositioned case — "No
    # position yet" — so this is a state the route has and not a new one.
    session.controls.positioned = false
    session.controls.step = 0
    session.controls.statusText = "No position yet"
    session.calltrace = CallTracePane(
      costLabel: "ACIR", costUnit: "opcodes", frames: @[],
      note: "The call structure is in the published recording. Reading it " &
            "needs the replay engine, which this page has not started.")
    session.state = StatePane(values: @[],
      note: "The recorded values are in the published recording. Reading " &
            "them needs the replay engine, which this page has not started.")
    session.eventLog = EventLogPane(rows: @[],
      note: "The recorded event stream is in the published recording. " &
            "Reading it needs the replay engine, which this page has not " &
            "started.")
  session.editor = pane

type StepPositions* = object
  ## `positions.json` (`avm-source-positions/1`) decoded — the recording's own
  ## per-step source coordinates, one entry per step, `pathId` null where the
  ## step has none.
  has*: bool
  steps*, positioned*: int
  postHoc*: bool
    ## The positions were derived AFTER the fact, by re-asking the artifact
    ## about a container that recorded none — `resolve-frozen-artifacts.mjs`,
    ## not the recording session. Carried because it changes what the frame is
    ## entitled to say; see `withSourcePositions`.
  paths*: seq[string]
  pathId*: seq[int]        ## -1 where the step carries no position
  line*, column*: seq[int]

proc decodeStepPositions*(node: JsonNode): StepPositions =
  ## Total, and refuses rather than repairs.
  ##
  ## The three parallel arrays have to agree with each other and with `steps`,
  ## because every consumer below indexes them with one number. A payload where
  ## they do not is not a payload with a gap in it — it is one whose rows mean
  ## something other than what this proc would read them as, and guessing which
  ## is exactly how a step acquires a line number belonging to a different step.
  if node.isNil or node.kind != JObject: return
  if node{"schema"}.getStr != "avm-source-positions/1": return
  let ids = node{"pathId"}
  let lines = node{"line"}
  let cols = node{"column"}
  let paths = node{"paths"}
  if ids.isNil or lines.isNil or cols.isNil or paths.isNil: return
  if ids.kind != JArray or lines.kind != JArray or cols.kind != JArray or
     paths.kind != JArray: return
  if ids.len != lines.len or ids.len != cols.len or ids.len == 0: return
  for p in paths:
    if p.kind != JString: return
    result.paths.add p.getStr
  for i in 0 ..< ids.len:
    let id = (if ids[i].kind == JInt: ids[i].getInt else: -1)
    # A position pointing outside the interned path table is dropped to
    # unpositioned rather than clamped: a step attributed to whichever file
    # happens to sit at index 0 is worse than a step that says it has no source.
    let ok = id >= 0 and id < result.paths.len and
             lines[i].kind == JInt and lines[i].getInt > 0
    result.pathId.add(if ok: id else: -1)
    result.line.add(if ok: lines[i].getInt else: 0)
    result.column.add(if ok and cols[i].kind == JInt: cols[i].getInt else: 0)
    if ok: inc result.positioned
  result.steps = result.pathId.len
  result.postHoc = node{"measuredPostHoc"}.getBool
  result.has = true

proc withSourcePositions*(session: var DebugSessionView;
                          bundle, positions: JsonNode;
                          capturedPositioned, capturedSteps: int) =
  ## Render REAL SOURCE for a recording that positions some of its steps.
  ##
  ## ## The gap this closes
  ##
  ## `withPublishedSources` refuses any pane that is not already `srcSourceLevel`,
  ## and it is right to: it re-applies a position it does not itself derive, so
  ## handing it an instruction-level pane swapped the text and zeroed the
  ## coordinate. Its header names the successor in as many words — the positions
  ## "arrive in `positions.json` beside the container rather than on the frame,
  ## and until a pane knows how to read them the honest thing is to leave the
  ## instruction listing alone." This is the pane knowing how to read them.
  ##
  ## Until it existed, a real-chain transaction whose artifact resolved
  ## published its 32-file Noir bundle AND its 108 per-step positions into the
  ## tree, and then rendered a bytecode listing over the top of both, because
  ## the only question the route could ask was `manifest.execution.sourceLevel`
  ## — one bit meaning "EVERY step is positioned". No real capture has ever set
  ## it (CHAIN-CAPTURE.md §6.2a), and on Aztec's `public_dispatch` contracts the
  ## dispatch prologue is compiled procedure code the transpiler keys no
  ## location for, so the bit is false while 86 of 108 steps sit on real Noir
  ## lines. Gating the text on it discarded all 86.
  ##
  ## ## Why this may claim source level, and what it must say
  ##
  ## `srcSourceLevel` is "a bundle resolved; the pane shows code", and both are
  ## true here: the bundle is proved against the class's `artifactHash` and the
  ## pane shows the file the step is in, at the line it is on. What is NOT true
  ## is the recording-wide claim, so the coverage travels with the pane
  ## (`positionedSteps` / `positionedOf`), `renderSource` states it, and
  ## `canHeadline` refuses a partial one. The rung, the corroboration and the
  ## `sourceLevel` bit are untouched — this reads the tree, it does not restate
  ## it, and `viewutil.sourcesLabel` keeps deriving the badge from its own two
  ## axes.
  ##
  ## ## Three refusals, matching the listing's
  ##
  ## A pane already at source level is left alone (`withPublishedSources` won,
  ## and the manifest's claim outranks this reconstruction). A pane that already
  ## has documents is left alone. A payload that decodes to nothing, or one that
  ## positions no step at all, is left alone — and the listing below then serves
  ## the page it always served.
  if not session.hasFrame: return
  if session.editor.availability != srcUnverified: return
  if session.editor.documents.len > 0: return
  let pos = decodeStepPositions(positions)
  if not pos.has or pos.positioned <= 0: return
  # ── AND A FOURTH: POST-HOC POSITIONS MUST BE CORROBORATED BY THE CAPTURE ────
  #
  # `resolve-frozen-artifacts.mjs` re-asks a container's question after the
  # fact — the artifact comes from npm, the program counters are in the `.ct`,
  # and the answer is a full per-step stream. It is the ONLY producer of that
  # stream: a live capture publishes the two COUNTS in `recording`
  # (`stepsPositioned` / `stepsUnpositioned`) and not the coordinates behind
  # them, so even a recording that positioned its own steps while it ran needs
  # this tool to say WHERE.
  #
  # That makes "post-hoc" the wrong axis to refuse on, and the right one is
  # AGREEMENT. A derived stream whose positioned count equals the number the
  # recording session itself measured is not a new claim about the recording —
  # it is the detail behind a number the recording already published, and the
  # two were produced by different code from different inputs. Where they
  # disagree, the derivation is describing something the recording did not do.
  #
  # The two cases this separates are both real and both in the tree:
  #
  #   * frozen `0x12525d6d…` — capture says `stepsPositioned: 0` (its runtime
  #     predated artifact resolution and never looked), derivation says 86.
  #     REFUSED. CHAIN-CAPTURE.md §6.2b measured that derivation as sound and
  #     still concluded the container stays rung 3; `reader.sourcesView` reads
  #     the capture and nothing else, so the badge says "Source not recorded",
  #     and a pane rendering source over it would be a page disagreeing with
  #     itself. §6.2b names the combination — `scAll` with `sourceLevel: false`
  #     — as a product decision to be taken by a person, and this keeps it one.
  #   * live `0x20ed5b91…` — capture says `stepsPositioned: 86` of 108,
  #     derivation says 86 of 108. ADMITTED. The recording measured its own
  #     positions against a proved artifact while it ran, and this is where
  #     they are.
  if pos.postHoc and
     not (capturedPositioned > 0 and capturedPositioned == pos.positioned and
          capturedSteps == pos.steps): return
  let docs = sourceDocumentsFromBundle(bundle)
  if docs.len == 0: return

  # THE COORDINATE IS THE SESSION'S, CLAMPED THE WAY THE LISTING CLAMPS IT.
  # `entryStepWithin` can land one past the end of a short recording, and this
  # is the second producer in a position to notice; correcting it here and in
  # `withInstructionListing` identically keeps the toolbar's step, the URL's
  # time coordinate and the marked row one derivation rather than three.
  var step = (if session.controls.positioned: session.controls.step else: -1)
  if step >= pos.steps: step = pos.steps - 1
  # …AND THEN MOVED TO A STEP THERE IS SOURCE FOR, which is a landing rule and
  # not a repair of the data. The 22 unpositioned steps of a FeeJuice execution
  # are its dispatch prologue and they sit at the FRONT of the stream, so a
  # session that landed on its own arithmetic mid-point would open on the one
  # region with nothing to show and report "no source position" over a bundle
  # that has source for the rest. `bestTrace` already lands the route in the
  # half that can be debugged; this is the same rule one level down. The
  # session's own step moves WITH it — a page may not report a position it is
  # not showing.
  var landed = -1
  if step >= 0 and step < pos.steps and pos.pathId[step] >= 0:
    landed = step
  else:
    for i in max(step, 0) ..< pos.steps:
      if pos.pathId[i] >= 0: landed = i; break
    if landed < 0:
      for i in countdown(min(step, pos.steps - 1), 0):
        if pos.pathId[i] >= 0: landed = i; break
  if landed < 0: return
  if landed != session.controls.step:
    session.controls.step = landed
    session.timeCoordinate = landed
  session.controls.positioned = true

  var pane = session.editor
  pane.availability = srcSourceLevel
  pane.reason = ""
  pane.listingCaption = ""
  pane.documents = docs
  pane.activeIndex = 0
  pane.positionedSteps = pos.positioned
  pane.positionedOf = pos.steps

  # THE GUTTER IS THE RECORDING'S OWN VISITED SET, built from the positions and
  # nothing else. `markExecuted` exists precisely so this comes from the trace
  # rather than from the text, and the fixture's `executedLines()` — which
  # describes a different program — must not be anywhere near it.
  var executed = initTable[string, seq[int]]()
  for i in 0 ..< pos.steps:
    if pos.pathId[i] < 0: continue
    let p = pos.paths[pos.pathId[i]]
    if not executed.hasKey(p): executed[p] = @[]
    if pos.line[i] notin executed[p]: executed[p].add pos.line[i]
  markExecuted(pane, executed)

  let path = pos.paths[pos.pathId[landed]]
  if documentIndex(pane, path) < 0:
    # The bundle does not carry the file the step is in. That is a mismatched
    # pair, not a partial one, and showing whichever file sorts first with a
    # line number from another would be the confident wrong answer. Leave the
    # pane alone and let the listing serve the page.
    return
  focus(pane, path, pos.line[landed])
  session.editor = pane

  # ── AND THE PROSE THAT WAS WRITTEN FOR THE OTHER OUTCOME ────────────────────
  #
  # `demoSession`'s instruction-level branch sets three pane notes, and two of
  # them assert the thing this proc has just disproved. The Call Trace note read
  # "Nothing resolved a source position, so they carry no file or line" on a page
  # whose Code pane is showing `avm.nr:103` — a sentence that is not merely stale
  # but visibly contradicted by the panel beside it. The Event Log's read
  # "recorded against program counters rather than source lines".
  #
  # Corrected HERE rather than at the branch that wrote them, because the branch
  # cannot know: it runs before the positions are read, and on the recordings
  # that get no positions both sentences are exactly right. This is the first
  # point at which the answer is known.
  #
  # The State note keeps its FIRST clause and loses its second. "This recording
  # carries no variable names" stays: the container's five — `contractAddress`,
  # `opcode`, `contextId`, `l2Gas`, `daGas` — are the AVM's machine columns and
  # not program locals, which is what the pane means by a name. But the reason
  # it gave, "none resolved for this contract", is exactly what has just stopped
  # being true, and it would be sitting under a badge reading "Sources
  # available". The real reason is one level in: the artifact resolved AND its
  # debug symbols carry no variable table. Measured on the FeeJuice artifact
  # this transaction proved — `debug_info.variables`, `.functions` and `.types`
  # are each `{}`, empty objects, in the published `public_dispatch`.
  session.calltrace.note =
    "Frames are recorded and carry the names this recording gives them. " &
    "They are listed once the session is live."
  session.state.note =
    "This recording carries no variable names. The contract's artifact " &
    "resolved and its debug symbols carry the source map, but their variable " &
    "table is empty — Aztec publishes these contracts compiled without " &
    "variable debug information, so there are no locals to name."
  session.eventLog.note =
    "Calls and storage writes are recorded against the step they happened on. " &
    $pos.positioned & " of this recording's " & $pos.steps & " steps carry a " &
    "source position; the rest are compiler-generated code the artifact maps " &
    "no line for."

proc withCallFrames*(session: var DebugSessionView; node: JsonNode) =
  ## Give the Call Trace pane the frames the recording opened.
  ##
  ## THE PANE THAT PROMISED ROWS AND SERVED A SENTENCE. `CHAIN-CAPTURE.md` §6.6
  ## recorded this pane's emptiness as a static-export limitation with a working
  ## live path — "they are listed once the session is live" — resting on the
  ## claim that the served page has no CTFS reader and the build is hermetic.
  ## The premise is true and the conclusion was not: `instructions.json` and
  ## `positions.json` are read out of the same containers by the same reader the
  ## build does not have, BY HAND and ahead of the build, and they reach this
  ## page. `tools/chain/derive-calltrace.mjs` now does it for the frames.
  ##
  ## So the served page lists them, which is what §6.6 said only a live session
  ## could do. Two things it said remain true and are kept: the frames carry no
  ## file and no line, because the recorder placed them on the pseudo-path; and
  ## a live session still lists MORE — `hydrate/session_project.projectCalltrace`
  ## adds `href`s and reads the engine's own `CalltraceVM`. The hydration latch
  ## in `hydrate.writePane` only replaces a served pane with one that has frames,
  ## so filling these rows cannot cost a visitor the richer live answer.
  ##
  ## ## The refusals
  ##
  ## A pane that already HAS frames is left alone — the source-level fixture
  ## fills its own, and this is the chain floor, never an overwrite of a rung
  ## above it.
  ##
  ## A payload that decodes to nothing leaves the pane exactly as it was, note
  ## and all. A snapshot captured before the derivation existed publishes no
  ## `calltrace.json`, and the paragraph it falls back to is the page this route
  ## has always served — the same absent-is-valid contract the listing signs.
  if not session.hasFrame: return
  if session.calltrace.frames.len > 0: return
  if node == nil or node.kind != JObject: return
  let arr = node{"frame"}
  if arr == nil or arr.kind != JArray or arr.len == 0: return

  var frames: seq[CallFrame]
  for f in arr:
    frames.add CallFrame(
      depth: f{"depth"}.getInt,
      fn: f{"name"}.getStr,
      # EMPTY, AND NOT THE CONTRACT ADDRESS, though the container hands one over
      # on the `Call` event and `calltrace.json` carries it.
      #
      # `module` is a SOURCE PATH by contract, not a free-text "where did this
      # run" field. `deeplink_landing.resolveAnchor` resolves a `src:` anchor by
      # `f.module.contains(file)`, and its comment says so — "matched against
      # the frame's module string, which is where the static producer puts the
      # path". `hydrate.rowsOf` reads the same value out of `data-module` for
      # the same purpose, and the live producer fills it from
      # `line.location.file`. Putting a 66-character hex address there would
      # make one field mean two things across the two producers, and would let a
      # `src:` link land on a frame because a filename happened to be a
      # substring of an address.
      #
      # The address is the transaction's own published fact and the page already
      # states it. A copy here would be a second producer of it — the same
      # reason `derive-instructions.mjs` declines to write it per step.
      # READ OFF THE DATA, not hard-coded to "". Every frame in this corpus
      # carries `path: null` — the recorder places them on its pseudo-path and
      # `derive-calltrace.mjs` refuses to write a frame placed anywhere else —
      # so this IS empty today. Writing the constant would have made this
      # producer the thing that discards a position the tool one day starts
      # emitting, silently, which is the failure the tool's own refusal exists
      # to prevent. One field, one source.
      module: f{"path"}.getStr(""),
      # The same, for the same reason. `null` decodes to 0, which is what
      # `CallFrame.line` means by "no line" and what `renderCallTrace` draws as
      # nothing rather than as `:0` — so the pane's standing sentence, "they
      # carry no file or line", stays true with rows on screen.
      line: f{"line"}.getInt(0),
      # READ, NOT MINTED — and the definition it carries is NOT the live
      # producer's. `tools/chain/lib/calltrace_frames.mjs` writes this as the
      # CALLEE'S FIRST STEP (a per-`Step` counter, read at the `Call`), while
      # `hydrate/session_project.projectCalltrace` fills the same field with
      # `int(line.rrTicks)`, which the landing evidence reads as the CALL SITE.
      # 44 of 46 frames present in both differ by exactly one, uniformly, and
      # there is no `±1` on either side — it is two definitions sharing a field
      # name, not an off-by-one. Open as #234; the question, and what settling
      # it would decide, is written out at `projectCalltrace`'s `step`.
      step: f{"step"}.getInt,
      # THE FOLD MARKS, READ AND NOT DECIDED. Which subtrees start closed is
      # `tools/chain/fold_rules.mjs`'s answer, applied where the container is
      # read; the counts behind a closed row are the derivation's walk over the
      # WHOLE recorded event stream. Both arrive here as data.
      #
      # ABSENT IS VALID, and it is what every `avm-call-frames/1` sidecar is: no
      # `foldedBy` decodes to `""`, which the renderer draws as an ordinary open
      # row. That is the correct rendering for a two-frame AVM-context recording
      # — there is no library subtree in it to close — so the twenty-seven
      # snapshots captured before this existed keep the pane they had.
      foldedBy: f{"foldedBy"}.getStr(""),
      foldWhy: f{"foldWhy"}.getStr(""),
      hiddenDescendants: f{"hiddenDescendants"}.getInt(0),
      hiddenSteps: f{"hiddenSteps"}.getInt(0),
      # NO COST COLUMN. The container carries a per-step gas reading, but both
      # frames here are open for every step of the recording — there is no
      # interval where one runs and the other does not — so any split would be
      # an arithmetic convention rendered as a measurement.
      cost: "", costUnit: "",
      # Empty on a statically exported page, per `CallFrame.href`: a query
      # string does not select a frame, and the producer decides this, not the
      # renderer. Hydration supplies them.
      href: "")

  # THE INNERMOST CONTAINING FRAME, NOT EVERY CONTAINING ONE. Both frames span
  # this recording, so a "contains the position" test marks both — and
  # `session_view.selectionPanel` takes the FIRST `current` frame it finds,
  # which would make the selection panel report `<toplevel>` as the current
  # frame on every step of every chain transaction. The deepest match is the
  # frame the reader is in.
  if session.controls.positioned:
    let pos = session.controls.step
    var innermost = -1
    for i, f in frames:
      let endStep = arr[i]{"endStep"}
      let ends = (if endStep == nil or endStep.kind == JNull: high(int)
                  else: endStep.getInt)
      if f.step <= pos and pos <= ends: innermost = i
    if innermost >= 0: frames[innermost].current = true

  session.calltrace.frames = frames
  withCallAnchors(session.calltrace)
  # THE NOTE IS CORRECTED, NOT LEFT TO GO UNREAD. `renderCallTrace` only prints
  # it when there are no frames, so a stale sentence here would be invisible
  # rather than wrong — and an invisible false statement is how this pane's
  # explanation drifted from its behaviour for six review rounds. What the note
  # claimed is now done: the frames ARE listed, statically.
  session.calltrace.note =
    "Frames are recorded and carry the names this recording gives them. " &
    "Nothing resolved a source position, so they carry no file or line."

const StorageWriteOracles* = ["storage_write", "storage_write_opcode"]
  ## The frame names that ARE a storage write rather than a call to one.
  ##
  ## Named here, as a set of two, because the AVM's write reaches the recording
  ## through one oracle whose Noir wrapper and whose opcode shim both appear as
  ## frames on some recordings. The wrappers ABOVE them —
  ## `PublicContext::storage_write`, `PublicContext::raw_storage_write`,
  ## `PublicMutable::write` — are calls that lead to a write and are rendered as
  ## calls: marking each of them would draw one write as four, which is the
  ## "count inflated by the nesting" shape. The innermost frame is the write.
  ##
  ## MATCHED ON THE WHOLE NAME, never as a substring: `raw_storage_write`
  ## contains `storage_write` and is a wrapper, so a `contains` test would mark
  ## exactly the rows this list exists to leave alone.

proc shortSourceLabel(path: string; line: int): string =
  ## `avm.nr:118` — the file's own name and the line, for a row that has room
  ## for neither the 118-character absolute build path the container interned
  ## nor nothing at all. The full path is in the Code pane's tab and in the
  ## frame's own row; this is the detail column of an event.
  if path.len == 0: return ""
  var base = path
  let slash = path.rfind('/')
  if slash >= 0: base = path[slash + 1 .. ^1]
  if line > 0: base & ":" & $line else: base

proc withEventLog*(session: var DebugSessionView; node: JsonNode;
                   reverted: bool) =
  ## Populate the Event Log from the recording's own call stream.
  ##
  ## ## THE PANE THE SPEC CALLS THE MOST VALUABLE THING IN THE PRODUCT, EMPTY
  ##
  ## `Debugger-Integration.md` §4.2: an event log "merging calls/returns,
  ## storage writes, events, reverts … Every entry is a navigation target:
  ## clicking moves the debugger to the exact step that produced it. This is the
  ## single most valuable interaction in the product." On every chain
  ## transaction this repository publishes it rendered one sentence and no rows,
  ## while `calltrace.json` sat beside the container carrying 47 frames with a
  ## step apiece — the coordinates the entries are supposed to be.
  ##
  ## So this is a RENDERER change and not a recorder one: every field below is
  ## read off an object the tree already publishes.
  ##
  ## ## WHAT IS IN THE STREAM, AND WHAT IS NOT — measured, not assumed
  ##
  ## The stream is the recording's calls, its returns and its storage writes.
  ## It is NOT the ten reproduced effects and it is NOT the six `logEvents` the
  ## capture counts, and the pane says so rather than implying it has them:
  ##
  ##   * `effects.matched: 10` / `mismatches: []` is a COUNT. The differential
  ##     oracle compared the replay's effects against the block's and published
  ##     how many agreed; no per-effect record exists anywhere in the corpus, so
  ##     there is nothing to make ten rows out of. Ten rows synthesised from a
  ##     count is the confident wrong answer this product may not ship.
  ##   * the container's `logEvents` are `elkTraceLogEvent` PROVENANCE
  ##     annotations the recorder writes — `ct.mapping-rung`,
  ##     `ct.step-producer`, `ct.chain-provenance`, `ct.merkle-root-divergence`,
  ##     `ct.private-half`, `ct.source-mapping-ceiling`, `ct.source-provenance`.
  ##     They carry no step, they are not program output, and the page already
  ##     states every one of them in the metadata pane and the Raw block. An
  ##     `event` row per annotation would put the page's own footnotes into the
  ##     execution's timeline.
  ##
  ## ## THE REFUSALS
  ##
  ## A pane that already has rows is left alone — the vendored fixture fills its
  ## own, and this is the chain floor, never an overwrite of a rung above it.
  ## A payload that decodes to nothing leaves the pane's sentence exactly as it
  ## was, which is the page this route has always served.
  if not session.hasFrame: return
  if session.eventLog.rows.len > 0: return
  if node == nil or node.kind != JObject: return
  let arr = node{"frame"}
  if arr == nil or arr.kind != JArray or arr.len == 0: return

  var rows: seq[EventRow]
  var writes = 0
  for f in arr:
    let name = f{"name"}.getStr
    if name.len == 0: continue
    let isWrite = name in StorageWriteOracles
    if isWrite: inc writes
    rows.add EventRow(
      kind: (if isWrite: evStorageWrite else: evCall),
      step: f{"step"}.getInt,
      label: name,
      # THE DETAIL IS THE FRAME'S OWN SOURCE POSITION, and where it has none it
      # is empty rather than filled with something else. `args` is deliberately
      # NOT read: the container's `Call` events carry the AVM's
      # `contractAddress` machine column and nothing else, which is a fact about
      # the execution context and not this function's arguments — see
      # `tools/chain/lib/calltrace_frames.mjs`. Printing it as an argument here
      # would put `Reader<N>::read(contractAddress)` in the timeline.
      detail: shortSourceLabel(f{"path"}.getStr(""), f{"line"}.getInt(0)))

  if rows.len == 0: return

  # THE CURRENT ROW IS THE INNERMOST FRAME CONTAINING THE POSITION, which is the
  # same rule `withCallFrames` applies and for the same reason: every AVM-context
  # recording has two frames spanning the whole stream, so "contains the
  # position" marks both and the pane would highlight `<toplevel>`.
  if session.controls.positioned:
    let pos = session.controls.step
    var innermost = -1
    for i in 0 ..< arr.len:
      if i >= rows.len: break
      let endStep = arr[i]{"endStep"}
      let ends = (if endStep == nil or endStep.kind == JNull: high(int)
                  else: endStep.getInt)
      if rows[i].step <= pos and pos <= ends: innermost = i
    if innermost >= 0: rows[innermost].current = true

  # THE REVERT, AND ONLY ON A TRANSACTION THAT REVERTED. Same rule as
  # `fixtureEventLog`'s: `ooPartial` is not a revert, and rendering a failed
  # constraint against a succeeded transaction would be the pane inventing an
  # event the trace never carried. It carries no step of its own — the recording
  # ends, it does not record a step for ending — so it takes the last frame's.
  if reverted:
    rows.add EventRow(kind: evRevert, step: rows[^1].step,
      label: "reverted",
      detail: "the transaction reverted; the recording is complete up to here")

  session.eventLog.rows = rows
  withEventAnchors(session.eventLog)
  # THE SENTENCE STAYS AND BECOMES A CAPTION, because with rows on screen it is
  # no longer "why this pane is empty" but "what these rows are and what they
  # are not". `renderEventLog` draws a non-empty note above the rows exactly as
  # `renderSource` draws `listingCaption` above a listing.
  session.eventLog.note =
    $rows.len & " recorded entries — every call this recording opened, in the " &
    "order it opened them, and " & $writes & " storage " &
    (if writes == 1: "write" else: "writes") & ". Each row's step is its " &
    "coordinate in the recording. The replay's reproduced effects are " &
    "published as a count rather than one record each, so they are in the " &
    "transaction pane and not in this timeline."

proc markCompilerAttributed*(session: var DebugSessionView;
                             positions, callFrames: JsonNode): int
                            {.discardable.} =
  ## Mark the lines whose source position is the COMPILER'S ANSWER rather than
  ## evidence that the line ran, and return how many were marked.
  ##
  ## The two shapes, why each is sound, and the measurement behind each are on
  ## `session_view.SourceLine.compilerAttributed`. What is here is the
  ## derivation; nothing in it is specific to a contract, a chain or a hash.
  ##
  ## ## THE SECOND RULE'S PREMISE, SPELLED OUT, BECAUSE ITS SOUNDNESS IS THE
  ## WHOLE VALUE OF THE MARK
  ##
  ## Two lines of ONE file, each visited by the recording in exactly ONE
  ## contiguous run of steps, both runs inside the span of ONE frame declared in
  ## that file at or above the lower of the two lines — i.e. inside one
  ## invocation of one function that lexically contains both. If the HIGHER
  ## line's run ends before the LOWER line's run begins, no forward control flow
  ## through that invocation explains it, and no loop explains it either: a loop
  ## revisits, which would give one of the two a second run and disqualify it
  ## here. So at least one of the two positions is not where the execution was.
  ##
  ## BOTH ARE MARKED AND NEITHER IS CORRECTED. The recording does not say which
  ## of the two the compiler moved, and picking one would be this producer
  ## inventing the discriminator the container lacks. Marking both understates
  ## (one of them IS right) and that is the direction to err in — a reader who
  ## checks the call tree beside it has what they need, and the call tree is
  ## published on the same page.
  ##
  ## ## WHAT THE FRAME SCOPING IS FOR, measured rather than reasoned
  ##
  ## Without it the rule fires SIX times per container and five are ordinary:
  ## `avm.nr:114` (`storage_read`) before `avm.nr:103` (`avm_return`),
  ## `type_packing.nr:103` (`unpack`) before `:98` (`pack`), `main.nr:203`
  ## (`public_dispatch`) before `:148` (`_increase_public_balance`). Calling one
  ## function in a file and then another one above it is normal. Requiring a
  ## single frame that lexically contains both runs removes all five and leaves
  ## exactly one hit on each of the two containers in this corpus — the
  ## `main.nr:223` / `main.nr:214` pair. The floor and the ceiling were both
  ## measured; the rule is not calibrated to produce one answer.
  if not session.hasFrame: return 0
  if session.editor.availability != srcSourceLevel: return 0
  if session.editor.documents.len == 0: return 0
  let pos = decodeStepPositions(positions)
  if not pos.has or pos.positioned <= 0: return 0

  # ── rule 1: `quote { … }` template bodies ─────────────────────────────────
  var suspect = initTable[string, seq[int]]()
  proc suspectAdd(path: string; line: int) =
    if not suspect.hasKey(path): suspect[path] = @[]
    if line notin suspect[path]: suspect[path].add line
  for d in session.editor.documents:
    if d.path == ListingPath: continue
    var text: seq[string]
    for l in d.lines: text.add l.text
    for r in findQuoteBodies(text, profileForDocument(d.path, d.language)):
      for line in r.firstLine .. r.lastLine: suspectAdd(d.path, line)

  # ── rule 2: a pair of positions one invocation cannot have produced ───────
  #
  # The runs, per (path, line). A run is broken by ANY other position, including
  # an unpositioned step, because the question is "was this line left and
  # returned to", and a step elsewhere is a departure however it is labelled.
  var firstRun = initTable[(string, int), (int, int)]()
  var multi: seq[(string, int)]
  var prev = ("", -1)
  for i in 0 ..< pos.steps:
    if pos.pathId[i] < 0: prev = ("", -1); continue
    let key = (pos.paths[pos.pathId[i]], pos.line[i])
    if key == prev and firstRun.hasKey(key) and firstRun[key][1] == i - 1:
      firstRun[key] = (firstRun[key][0], i)
    elif firstRun.hasKey(key):
      if key notin multi: multi.add key        # a second run: disqualified
    else:
      firstRun[key] = (i, i)
    prev = key
  for k in multi: firstRun.del k

  # The frames, as (path, declaredLine, firstStep, lastStep).
  var frames: seq[(string, int, int, int)]
  if callFrames != nil and callFrames.kind == JObject:
    let arr = callFrames{"frame"}
    if arr != nil and arr.kind == JArray:
      for f in arr:
        let p = f{"path"}.getStr("")
        let l = f{"line"}.getInt(0)
        if p.len == 0 or l <= 0: continue
        let e = f{"endStep"}
        frames.add (p, l, f{"step"}.getInt,
                    (if e == nil or e.kind == JNull: high(int) else: e.getInt))

  var keys: seq[(string, int)]
  for k in firstRun.keys: keys.add k
  keys.sort()
  for a in 0 ..< keys.len:
    for b in a + 1 ..< keys.len:
      if keys[a][0] != keys[b][0]: continue      # same file only
      let lowLine = min(keys[a][1], keys[b][1])
      let highLine = max(keys[a][1], keys[b][1])
      let lowRun = firstRun[(keys[a][0], lowLine)]
      let highRun = firstRun[(keys[a][0], highLine)]
      # The higher line's run must finish STRICTLY before the lower one's begins.
      if not (highRun[1] < lowRun[0]): continue
      var contained = false
      for f in frames:
        if f[0] != keys[a][0]: continue
        if f[1] > lowLine: continue              # declared below the pair
        if f[2] <= highRun[0] and lowRun[1] <= f[3]: contained = true; break
      if not contained: continue
      suspectAdd(keys[a][0], lowLine)
      suspectAdd(keys[a][0], highLine)

  # ── the mark ──────────────────────────────────────────────────────────────
  # …AND ON A LINE A RECORDED FRAME POINTS AT, executed or not.
  #
  # A frame's declared position is a jump target — the Call Trace row carries it
  # and a `src:` deep link resolves against it — so a frame sitting inside a
  # `quote { … }` template sends a reader to a macro body whether or not the
  # recording placed a STEP on that line. `serde/src/serialization.nr:260` is
  # exactly that on `0x0a807e4e…`: `derive_deserialize`'s frame is there, the
  # positions stream is not, and without this the one surface that would have
  # taken a visitor to the wrong place carried no mark at all.
  var pointedAt = initTable[string, seq[int]]()
  for f in frames:
    if not pointedAt.hasKey(f[0]): pointedAt[f[0]] = @[]
    if f[1] notin pointedAt[f[0]]: pointedAt[f[0]].add f[1]

  for d in session.editor.documents.mitems:
    if not suspect.hasKey(d.path): continue
    for l in d.lines.mitems:
      # Either the recording placed a step here, or a frame points here. A
      # suspect line that is neither is not a claim anybody is being invited to
      # misread — the gutter is unmarked and nothing links to it — and marking it
      # would spread a caveat over code the page says nothing about, turning the
      # count this returns into a number about the FILE rather than about the
      # recording.
      if not l.executed and
         not (pointedAt.hasKey(d.path) and l.number in pointedAt[d.path]):
        continue
      if l.number notin suspect[d.path]: continue
      l.compilerAttributed = true
      inc result

proc withMachineColumns*(session: var DebugSessionView;
                         instructions, callFrames: JsonNode) =
  ## Fill the Values pane with the VM's machine state at the session's step.
  ##
  ## ## THE PANE THAT WAS EMPTY WITH A TRUE REASON, AND HAD SOMETHING TO SAY
  ##
  ## The standing sentence is right as far as it goes: "This recording carries no
  ## variable names. The contract's artifact resolved and its debug symbols carry
  ## the source map, but their variable table is empty." Measured, and still
  ## true — Aztec publishes these contracts compiled with
  ## `debug_info.variables` empty, so there is no program local to name.
  ##
  ## What was NOT true is the implication a reader takes from an empty pane:
  ## that the recording says nothing about state at this step. It says five
  ## things, and the tree publishes four of them per step already — the
  ## program counter, the opcode, the L2 gas meter and the execution context
  ## are `instructions.json`'s four parallel columns, and which contract's
  ## context a frame ran in is `calltrace.json`'s `contractAddress`. Those are
  ## the AVM's own machine columns (`VariableName` records in the container:
  ## `contractAddress`, `opcode`, `contextId`, `l2Gas`, `daGas`), and they are
  ## exactly what a visitor stepping a bytecode recording wants to watch.
  ##
  ## ## WHY THIS IS NOT THE DEFECT IT LOOKS LIKE
  ##
  ## Publishing the AVM's machine columns as though they were program locals is
  ## the defect `tools/chain/lib/calltrace_frames.mjs` was just corrected for —
  ## 46 of the 47 frames of `0x0a807e4e…` published `contractAddress` as a
  ## function ARGUMENT, which is every frame but the synthetic `<toplevel>`.
  ## (This said "45 of 47". Measured on the pre-migration file: 45 frames share
  ## the SAME one-entry `args` list and a 46th carries a different address, so 45
  ## is the count of IDENTICAL LISTS and not the count of frames with an address.
  ## A figure that is a denominator in one sentence and a population in the next
  ## is the kind that survives review.) The
  ## difference is the label, and the label is the whole of it: these rows are
  ## headed as the VM's machine state, each one typed by what it is, and the
  ## pane's note keeps saying that no program local was recorded. A row saying
  ## `l2Gas: 641,654 (AVM machine column)` is a measurement; the same number
  ## offered as a local would be a fabrication.
  ##
  ## ## THE REFUSALS
  ##
  ## A pane that already has values is left alone — the vendored fixture computes
  ## its own from the recorded program, and this is the chain floor.
  ##
  ## An unpositioned session fills nothing: the columns are per step, and without
  ## a step there is no "at this step" to read them at. That is also why this
  ## runs after the two producers that settle the coordinate.
  ##
  ## A listing that decodes to nothing, or one whose length cannot hold the
  ## session's step, fills nothing — the same refusal `withListingBesideSource`
  ## makes, and for its reason: a column read at the wrong index is a value
  ## belonging to another step.
  if not session.hasFrame: return
  if session.state.values.len > 0: return
  if not session.controls.positioned: return
  let listing = decodeInstructionListing(instructions)
  if not listing.hasListing: return
  let step = session.controls.step
  if step < 0 or step >= listing.stepCount: return
  let s = listing.steps[step]
  # `changed` IS A RELATION BETWEEN TWO POSITIONS and is computed against the
  # PREVIOUS step, which is the position a forward step arrived from. At step 0
  # there is no previous position, so nothing is marked — an unmarked column is
  # "no claim", and marking everything changed at the front of a recording would
  # make the mark mean "this is the first frame" on every rung-3 page.
  let prev = (if step > 0: listing.steps[step - 1] else: s)
  let moved = step > 0

  # WHICH CONTRACT'S CONTEXT, from the frame the session is standing in — the
  # innermost frame containing the step, which is the same rule `withCallFrames`
  # and `withEventLog` apply. Absent where the recording attached none, and it is
  # NOT defaulted to the transaction's own contract: that would be this pane
  # asserting a context the recording did not state.
  var contractAddress = ""
  if callFrames != nil and callFrames.kind == JObject:
    let arr = callFrames{"frame"}
    if arr != nil and arr.kind == JArray:
      for f in arr:
        let ends = f{"endStep"}
        let e = (if ends == nil or ends.kind == JNull: high(int) else: ends.getInt)
        if f{"step"}.getInt <= step and step <= e:
          let a = f{"contractAddress"}.getStr("")
          if a.len > 0: contractAddress = a

  var vals: seq[StateValue]
  if contractAddress.len > 0:
    vals.add StateValue(name: "contractAddress", typ: "AVM machine column",
                        value: contractAddress)
  if s.hasProgramCounter:
    vals.add StateValue(name: "pc", typ: "bytecode offset",
                        value: pcText(s.pc, 4).strip(),
                        changed: moved and prev.pc != s.pc)
  vals.add StateValue(name: "opcode", typ: "AVM machine column",
                      value: opcodeText(listing, s.opcode) & " (" & $s.opcode & ")",
                      changed: moved and prev.opcode != s.opcode)
  vals.add StateValue(name: "contextId", typ: "AVM machine column",
                      value: $s.context,
                      changed: moved and prev.context != s.context)
  if listing.hasGas:
    vals.add StateValue(name: "l2Gas", typ: "AVM machine column",
                        value: $s.l2Gas,
                        changed: moved and prev.l2Gas != s.l2Gas)
  if vals.len == 0: return
  session.state.values = vals
  # THE NOTE KEEPS ITS CLAIM AND GAINS THE ONE IT WAS MISSING. `renderState`
  # prints the note beside the rows, so this is read where it is true: the rows
  # are the VM's, no program local was recorded, and the reason is one level in.
  # Whatever the branch above wrote about the variable table is kept verbatim —
  # it is the more specific sentence and this producer cannot re-derive it.
  let was = session.state.note
  session.state.note =
    "The rows below are the AVM's own machine columns at this step, read from " &
    "the recording. They are not program variables. " &
    (if was.len > 0: was
     else: "This recording carries no variable names, so there are no locals " &
           "to name.")

proc withInstructionListing*(session: var DebugSessionView; node: JsonNode) =
  ## Give an instruction-level pane the instructions.
  ##
  ## THE FLOOR OF THE LADDER, MADE VISIBLE. A pane at `srcUnverified` had a
  ## stated reason and nothing else — it described a recording of program
  ## counters and then rendered none of them, on every real chain transaction
  ## this site publishes. The tree carries them (`ingest.nim` publishes
  ## `instructions.json` beside the container when the capture derived one), so
  ## this is where they become rows.
  ##
  ## ## Three refusals, and each is a state this route really has
  ##
  ## A pane that is NOT `srcUnverified` is left alone. That is the coexistence
  ## rule: source resolution is becoming a per-transaction answer rather than a
  ## constant of the chain, and a transaction whose artifact resolves takes the
  ## source path untouched. This runs after `withPublishedSources` for exactly
  ## that reason — whatever won there keeps the pane.
  ##
  ## A pane that already HAS documents is left alone for the same reason, one
  ## step finer: a bundle that resolved to text is text, and replacing it with a
  ## listing would be the floor overwriting a rung above it.
  ##
  ## A payload that decodes to nothing is left alone, and the page a reader gets
  ## is the one this route has always served. A snapshot captured before the
  ## derivation existed, or one taken on a machine with no `ct-print`, publishes
  ## no listing — and "the reason, with no rows" is a correct page, so there is
  ## nothing here worth failing a build over.
  if not session.hasFrame: return
  if session.editor.availability != srcUnverified: return
  if session.editor.documents.len > 0: return
  let listing = decodeInstructionListing(node)
  if not listing.hasListing: return

  # THE POSITION IS THE SESSION'S OWN COORDINATE, read off the controls rather
  # than recomputed. `fixtureControls` derived it through `entryStepWithin`, the
  # toolbar renders it, `.srcpos` states it and a share link anchors to it; a
  # listing that marked a row from a second derivation would be a second producer
  # of the one coordinate this page has, and the two would disagree the first
  # time either changed. Row `n` is tick `n`.
  #
  # AND THE LISTING IS WHERE IT IS RESOLVED, because the listing is the only
  # place that knows how long the recording is. `entryStepWithin` lands a trace
  # shorter than the fixture's step on `steps` itself — "the trace's own last
  # step" — and under the session's own zero-based numbering that is one PAST the
  # end: a recording of 108 steps has ticks 0..107. That off-by-one predates this
  # listing and was invisible while nothing rendered a row to compare it against.
  #
  # It is corrected here rather than in the landing rule, and the session's own
  # coordinate is corrected with it — both the toolbar's step and the URL's time
  # coordinate, which `test_chain_provenance` requires to be one derivation and
  # not two. A page may not report a position outside its own recording; that is
  # an invariant this repository already asserts, and this is the first producer
  # in a position to enforce it.
  var step = (if session.controls.positioned: session.controls.step else: -1)
  if step >= listing.stepCount:
    step = listing.stepCount - 1
    session.controls.step = step
    session.timeCoordinate = step
  # An unpositioned session marks no row, which is what a coordinate outside the
  # listing means everywhere else in this pane. The listing still renders: "here
  # is the whole recording, and this page does not yet know where in it you are"
  # is a true frame, and it is strictly more than the paragraph it replaces.
  session.editor.documents = @[listingDocument(listing, step)]
  session.editor.activeIndex = 0
  session.editor.currentLine = step
  session.editor.listingCaption = listingCaption(listing)
  # A recording whose program counters this repository's opcode table could not
  # reproduce renders numbers, and SAYS SO rather than leaving a reader to
  # wonder why one page names instructions and another does not. The listing is
  # unaffected — losing the names is not losing the counters.
  if not listing.named:
    session.editor.reason.add(
      " The opcode numbers below are shown unnamed: this site's instruction " &
      "table did not reproduce this recording's own program counters, so " &
      "naming them would be a guess.")

proc withListingBesideSource*(session: var DebugSessionView; node: JsonNode) =
  ## THE LADDER STOPS BEING A CONTEST FOR THE ONE CLASS IT COULD NOT EXPRESS.
  ##
  ## ## What was wrong, and it was not a line
  ##
  ## `ssr.debugSessionFor` runs three rungs — `withPublishedSources`, then
  ## `withSourcePositions`, then `withInstructionListing` — and each refuses a
  ## pane the one above it took. That is coexistence between the RUNGS and it is
  ## a contest for the PANE: whichever won holds it for the whole session, because
  ## `SourceAvailabilityView` is one value and `documents` is one list.
  ##
  ## A recording is not one value. `aztec-testnet-frames/0x0a807e4e…` runs 459
  ## steps across two contracts at two fidelities: `0x…0003` positions 86 of its
  ## 108 steps, and `0x2fcd3dd5…` — steps 108..458 — positions none, because no
  ## distributor could prove its artifact. The middle rung won, so the pane was 32
  ## Noir documents and no listing, and at 373 of 459 ticks there was NO ROW OF
  ## ANY KIND to be stopped at. The static export escaped by an accident of
  ## `withSourcePositions`'s landing rule — it moves the served step to one there
  ## is source for, landing this recording on 107 — and hydration, which lands at
  ## tick 0, showed 224 rows of Noir with nothing marked and nothing said.
  ##
  ## `Source-Resolution.md` §7's last row asks for the other thing by name:
  ## "Partial source coverage | Source-level stepping where sources exist,
  ## instruction-level elsewhere, with the boundary visible in the source pane
  ## rather than silent." `Debugger-Integration.md` §5: "A single transaction
  ## routinely mixes both… it is the normal case, not an edge case."
  ##
  ## ## What this does
  ##
  ## The listing JOINS the source documents instead of competing with them. One
  ## pane, one document list, two kinds of document in it: the recording's files
  ## for the steps that resolve, and its program counters for the steps that do
  ## not. Row `n` of the listing is tick `n`, so there is a row for every step the
  ## recording took — including the 86 it positions, where the counter column is a
  ## dash because the container spent that field on the source line
  ## (`instruction_listing.NoProgramCounter`).
  ##
  ## `components/debugger.renderSource` decides what a document IS from the
  ## document — `path == ListingPath` — rather than from the pane's availability,
  ## which is what lets one pane render both. And the pane states the boundary
  ## above the rows in either state, which is §5's "visible transition".
  ##
  ## ## Five refusals, and each names a state the route really has
  ##
  ## A pane that is not at source level is left alone: it either has the listing
  ## already (`withInstructionListing` is the floor and runs before this) or it has
  ## no documents at all, and a listing beside nothing is just a listing.
  ##
  ## A pane whose recording is NOT partly positioned is left alone. A recording
  ## that positions every step has nothing for a listing row to say that its source
  ## line does not say better, and the counters do not exist for it — the producer
  ## refuses to derive them. `positionedOf > positionedSteps > 0` is the same
  ## definition of the class the corpus selects on and the producer measures.
  ##
  ## A pane that already carries a listing document is left alone, so this cannot
  ## run twice and produce two.
  ##
  ## A payload that decodes to nothing is left alone — a snapshot taken before the
  ## derivation existed publishes none, and "source at the steps that have it, and
  ## the reason at the rest" is the page this route already served.
  ##
  ## AND A LISTING OF A DIFFERENT LENGTH IS REFUSED OUTRIGHT. The join is the
  ## identity — row `n` is tick `n` — so a listing of a different length is not a
  ## listing of this recording, and appending it would put the mark on a row
  ## belonging to another execution. Same rule, and the same reason, as
  ## `intColumn`'s refusal to zip columns of unequal length.
  if not session.hasFrame: return
  if session.editor.availability != srcSourceLevel: return
  if session.editor.documents.len == 0: return
  if session.editor.positionedSteps <= 0: return
  if session.editor.positionedSteps >= session.editor.positionedOf: return
  if documentIndex(session.editor, ListingPath) >= 0: return
  let listing = decodeInstructionListing(node)
  if not listing.hasListing: return
  if listing.stepCount != session.editor.positionedOf: return
  # AND THE TWO PRODUCERS HAVE TO AGREE ABOUT WHICH STEPS THOSE ARE, not merely
  # about how many there are. The positions sidecar and the instruction listing
  # are derived by two different tools from the same container: one publishes a
  # `(path, line)` per step, the other a counter per step, and a step must have
  # exactly one of them. Where they disagree, one of the two is describing a
  # recording the other is not, and a pane built from both would mark a row for a
  # step the source pane also claims — the confident wrong answer.
  #
  # Read off the PANE rather than off the sidecar, because the pane is what the
  # marks are drawn from: `withSourcePositions` set the executed set and focused
  # the position from those coordinates, so this compares the listing to the thing
  # a reader will actually see.
  if listing.counterSteps != session.editor.positionedOf - session.editor.positionedSteps:
    return

  # NO ROW IS MARKED IN THE LISTING HERE, and that is not an omission.
  #
  # This runs after `withSourcePositions`, whose landing rule has already moved the
  # served step to one there IS source for — "a page may not report a position it
  # is not showing" — so the served frame's position is a source line and the
  # source document carries the mark. A listing that also marked its row would put
  # two `.srcline.cur` in one pane, which is the page reporting two positions.
  #
  # The LIVE session is the other half and it is not served from here: hydration
  # re-decodes this same island at the engine's position on every stop, and
  # `session_project.projectEditor` marks the listing row at `rrTicks` exactly when
  # the position resolves to no published document. The two halves agree because
  # they are the same rule stated once each: whichever document holds the step,
  # holds the mark.
  session.editor.documents.add listingDocument(listing, -1)
  session.editor.listingCaption = listingCaption(listing)
  # The sentence the listing half of the pane shows above its rows. `reason` is
  # empty on a source-level pane and `renderSource` only reads it inside the
  # listing's own chrome, so this is read exactly where it is true: on the steps
  # this recording publishes no source for.
  #
  # It says WHY rather than "no source is published", which is what the shared
  # default would have said and is false of this recording — 32 Noir files are on
  # the same page, four tabs away.
  #
  # AND IT NAMES NO CAUSE, because the two recordings in this class do not share
  # one. On `aztec-testnet-frames/0x0a807e4e…` the unpositioned steps are a
  # SECOND CONTRACT whose artifact no distributor could prove; on
  # `aztec-testnet/0x20ed5b91…` they are the dispatch prologue of the same
  # contract, compiler-generated code the transpiler keys no location to. A
  # sentence naming either would be false on the other, and this producer cannot
  # tell them apart — what it knows is that no published artifact maps a line for
  # them, which is the claim both support.
  session.editor.reason =
    "Source resolved for " & $(listing.stepCount - listing.counterSteps) &
    " of this recording's " & $listing.stepCount & " steps. The other " &
    $listing.counterSteps & " ran in code no published artifact maps a source " &
    "line for, so what the recording carries for them is the program counter " &
    "the VM was standing on — one row per step, below."
