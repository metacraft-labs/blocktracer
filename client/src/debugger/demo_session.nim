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

import std/[algorithm, json, os, tables]
import ../reader
import ../viewutil
import ./deeplink_landing
import ./demo_flow
import ./flow_view
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
    CallFrame(depth: depth, fn: s.name, module: DemoModule & " · " & s.path,
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
  if steps <= 0: 0
  elif steps < FixtureStep: steps
  else: FixtureStep

proc fixtureControls(positioned, live: bool; steps: int): DebugControlsPane =
  ## `positioned` is "the panes carry a step"; `live` is "the engine can move
  ## it". They are different on the static route, where the first is true and
  ## the second is false, and the toolbar's enablement follows the second —
  ## an enabled button with no engine behind it is an affordance that lies on
  ## click, which is the single most likely wrong thing to ship here.
  proc btn(a: DebugAction; label, glyph: string): ControlButton =
    ControlButton(action: a, label: label, glyph: glyph, enabled: live)
  # Four pairs, reverse then forward, in the desktop app's own toolbar order.
  # Every glyph is distinct: `daReverseStepOut` and `daStepOut` both used to
  # render `⤴`, so two different moves carried one mark on a toolbar whose
  # entire point is that each move has a direction.
  result.buttons = @[
    btn(daStepBackward, "Step backward", "◀"),
    btn(daStepForward, "Step forward", "▶"),
    btn(daReverseStepIn, "Reverse step in", "⇱"),
    btn(daStepIn, "Step in", "⇲"),
    btn(daReverseStepOut, "Reverse step out", "⇤"),
    btn(daStepOut, "Step out", "⇥"),
    btn(daReverseContinue, "Reverse continue", "⏮"),
    btn(daContinue, "Continue", "⏭"),
  ]
  result.positioned = positioned
  result.totalSteps = steps
  result.step = (if positioned: entryStepWithin(steps) else: 0)
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

proc metadataPane*(chain: string; v: TxView; info: ChainInfo): MetadataPane =
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
    rows: txMetadataRows(chain, v, info),
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
                  sourceLevel = true): DebugSessionView =
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
  result.metadata = metadataPane(chain, v, info)

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
    # the same way.
    result.timeCoordinate =
      if timeCoordinate > 0: timeCoordinate else: entryStepWithin(steps)
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
      result.editor = EditorPane(availability: srcUnverified,
        reason: "The chain publishes no source for this contract — an Aztec " &
                "contract class carries bytecode, and no debug symbols, no " &
                "file map and no source text. The recording is therefore at " &
                "instruction level: every step is a program counter, and " &
                "there is nothing to position it against. Stepping is " &
                "complete; only the text is missing.")
      result.calltrace.note =
        "Frames are recorded, and without a file map they carry no function " &
        "names or source positions."
      result.state.note =
        "This recording carries no variable names: naming a local needs debug " &
        "symbols, which an Aztec contract class does not publish."
      result.eventLog.note =
        "Calls and storage writes are recorded against program counters " &
        "rather than source lines."
      result.controls = fixtureControls(positioned = true, live = false,
                                        steps = steps)
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
                                        steps = steps)
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
