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

proc fixtureEditor(): EditorPane =
  result.availability = srcSourceLevel
  result.documents = fixtureDocuments(FixtureFile, FixtureLine, executedLines())
  result.currentLine = FixtureLine
  result.activeIndex = documentIndex(result, FixtureFile)

proc fixtureCalltrace(): CallTracePane =
  ## Four frames, three depths, plus the sibling calls the loop has already
  ## made — so the pane is judged at depth rather than as a flat list.
  proc frame(name: string; depth, step: int; cost: string;
             current = false): CallFrame =
    let s = symbolOf(name)
    CallFrame(depth: depth, fn: s.name, module: DemoModule & " · " & s.path,
              cost: cost, costUnit: "opcodes", step: step, current: current)
  result.costLabel = "ACIR"
  result.frames = @[
    frame("main", 0, 1, "1,315"),
    frame("iterate_asteroids", 1, 6, "1,208"),
    frame("calculate_damage", 2, 41, "63"),
    frame("calculate_remaining_shield_pct", 3, 49, "11"),
    frame("status_report", 2, 74, "96"),
    frame("calculate_damage", 2, 112, "63", current = true),
    frame("calculate_remaining_shield_pct", 3, 120, "11"),
  ]

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

proc fixtureControls(positioned, live: bool; steps: int): DebugControlsPane =
  ## `positioned` is "the panes carry a step"; `live` is "the engine can move
  ## it". They are different on the static route, where the first is true and
  ## the second is false, and the toolbar's enablement follows the second —
  ## an enabled button with no engine behind it is an affordance that lies on
  ## click, which is the single most likely wrong thing to ship here.
  proc btn(a: DebugAction; label, glyph: string): ControlButton =
    ControlButton(action: a, label: label, glyph: glyph, enabled: live)
  result.buttons = @[
    btn(daReverseContinue, "Reverse continue", "⏮"),
    btn(daReverseStepOut, "Reverse step out", "⤴"),
    btn(daStepBackward, "Step backward", "◀"),
    btn(daStepForward, "Step forward", "▶"),
    btn(daStepIn, "Step in", "⤵"),
    btn(daStepOut, "Step out", "⤴"),
    btn(daContinue, "Continue", "⏭"),
  ]
  result.positioned = positioned
  result.totalSteps = steps
  result.step = (if positioned: FixtureStep else: 0)
  result.statusText =
    if positioned and live: "Stopped at step " & $FixtureStep & " of " & $steps
    elif positioned:
      "Step " & $FixtureStep & " of " & $steps & " — stepping starts when the " &
      "replay engine finishes loading (" &
      approxMegabytes(ReplayEngineWasmBytes) & ")"
    else: "No position yet"

# ---------------------------------------------------------------------------
# The metadata pane — derived, never fixture
# ---------------------------------------------------------------------------

proc metadataPane*(chain: string; v: TxView): MetadataPane =
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
    rows: txMetadataRows(chain, v),
    executions: txExecutionRows(v))

# ---------------------------------------------------------------------------
# The session
# ---------------------------------------------------------------------------

proc demoSession*(chain: string; v: TxView;
                  timeCoordinate = 0;
                  containerPath = ""; containerBytes = 0;
                  totalSteps = FixtureTotalSteps): DebugSessionView =
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
  result.languages = @[DemoLanguage]
  result.engineBase = ReplayEngineBase
  result.engineCrossOrigin = replayEngineIsCrossOrigin()
  result.engineBytes = ReplayEngineWasmBytes
  result.metadata = metadataPane(chain, v)

  # The fixture session sits at step 128 of the recorded program. A tree whose
  # manifest still describes a stand-in container reports fewer steps than
  # that, and rendering "step 128 of 11" would put the position past the end of
  # its own trace. So the manifest's count is used when it can hold the
  # position and the fixture's own recorded total otherwise — which resolves
  # itself the moment the tree publishes the real container, because then the
  # manifest says 1315 and the two agree.
  let steps = if totalSteps > FixtureStep: totalSteps else: FixtureTotalSteps

  case v.headline
  of taReady, taDivergent:
    # `spFetching`, not `spReady`: this is the PRE-HYDRATION frame. The panes
    # below are fully populated from published data — which is what §7.0 means
    # by "the transaction page is not a waiting room before the debugger; it is
    # the debugger's first frame" — but no engine has been fetched, so nothing
    # can step yet and the page must not imply otherwise.
    result.phase = spFetching
    result.hasFrame = true
    result.timeCoordinate =
      if timeCoordinate > 0: timeCoordinate else: FixtureStep
    result.integrity =
      if v.headline == taDivergent: siDivergent else: siValidated
    if v.headline == taDivergent:
      result.integrityDetail =
        "The differential oracle replayed this transaction and disagreed with " &
        "the chain's own result. The trace is real and steps normally; what it " &
        "cannot be used for is proving what the chain did."
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
  var pane = session.editor
  pane.documents = docs
  pane.activeIndex = 0
  markExecuted(pane, executedLines())
  if documentIndex(pane, FixtureFile) >= 0:
    focus(pane, FixtureFile, FixtureLine)
  session.editor = pane
