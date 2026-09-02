## noir_engine_dap.nim — CodeTracer's Noir DAP tests, ported to BlockTracer's
## engine seam.
##
## ## What this is a port OF
##
## Desktop CodeTracer has three Noir subjects that live below the renderer:
##
## | desktop | what it asserts | ported here as |
## | --- | --- | --- |
## | `src/db-backend/tests/noir_flow_dap_test.rs` | breakpoint → variables and their VALUES; multi-breakpoint; `next` lands on the expected LINE; the call stack names its frames in order | §2, §3, §4, §7 |
## | `src/db-backend/tests/origin_noir_dap_test.rs` | `ct/originChain` returns a chain with a terminator, a hop count and a confidence | §8 |
## | `src/tests/gui/tests/noir-space-ship/noir_space_ship_test.nim` | the journey: entry position, call trace, calltrace jump lands on `shield.nr:26`, flow at `iterate_asteroids` carries loops and named loop-locals at iterations 0..7, stepping reverses | §4, §5, §6, §2 |
##
## The GUI test is ported **in spirit only** — none of its code is reused, and
## nothing here touches a DOM. What is kept is the journey it asserts: which
## artefacts must agree, what stepping does to them, and what a reader should
## see after each action.
##
## ## Why it can be a port at all
##
## The desktop tests drive the NATIVE `replay-server` over a trace directory.
## BlockTracer drives the SAME engine, compiled to `wasm32-unknown-unknown`,
## inside a worker, over `WorkerBackendService` — the adapter
## `client/hydrate/hydrate.nim` uses in production. The dialect between the two
## is written down in the Embed SDK's own
## `src/frontend/viewmodel/backend/dap_dialect.md`, nine rows, and this file
## cites it by section wherever a row is what makes a desktop expectation
## non-portable.
##
## The subject is BlockTracer's own fixture,
## `fixtures/trace/noir_space_ship/zk_shields.ct` — the same `noir_space_ship`
## program the desktop GUI test debugs, recorded by `nargo trace` and vendored
## because that recorder is not byte-deterministic.
##
## ## The rule every assertion here obeys
##
## `codetracer-specs/Testing/Verification-Harness-Traps.md` §2: **a chain of
## `success: true` is not a result.** That document's own worked example is
## this exact protocol — a DAP driver that sent `program` where the engine
## wanted `traceFolder` got `success: true` from `initialize`, `launch`,
## `configurationDone` AND `threads`, over a session in which no trace had been
## opened. So nothing below asserts an acknowledgement. Every check names an
## artefact: a stepped position, a frame count, a variable's value, a loop
## iteration, a hop in an origin chain.
##
## §1b is that trap's own control arm, kept in the suite rather than in a
## comment: the wrong-key launch is DRIVEN, and the check is that it fails to
## produce a frame.
##
## ## The oracle, and why there is one
##
## Traps §4/§4a: a scan that finds nothing satisfies every negative assertion
## written over it, and the cheapest defence is a positive twin through the
## same code path. §5 is that twin for every position assertion in the file.
## `client/fixtures/demo-session/flow.json` is DERIVED from the same
## `zk_shields.ct` bytes by `ct-print` (the `codetracer-trace-format-nim`
## reader) through `client/fixtures/demo-session/extract-flow.mjs`, and it
## carries 82 `(tick → src/shield.nr:line, function)` rows. So the container's
## own reading of itself is available as an independent oracle, and §5 asserts
## the engine agrees with it — with the row COUNT asserted, because Traps §4b
## is that a partial scan passes every check it still makes.
##
## ## Run it
##
##   ci/test/noir-engine-dap.sh
##
## which resolves the Embed SDK (`$CODETRACER_SRC` or `../codetracer`, the same
## two markers `client/hydrate/build.sh` uses) and the published replay engine,
## and FAILS — never skips — when either is missing.

when not defined(js):
  {.error: "noir_engine_dap.nim drives a worker; it is a `nim js` test.".}

import std/[json, strutils, algorithm, tables, sequtils]
import isonim/core/async_compat
import backend/[backend_service, worker_backend]

# The container oracle. Read at COMPILE time so the test binary carries it and
# a run cannot silently read a different tree's fixture than the one it was
# built against.
const FlowOracleJson = staticRead("../../client/fixtures/demo-session/flow.json")

# ---------------------------------------------------------------------------
# Node's worker_threads, and the one place this file mirrors production
# ---------------------------------------------------------------------------

proc startWorkerImpl(slot: int; hostPath: cstring;
                     onMessage: proc(raw: cstring)): bool {.importjs: """
(function(slot, path, cb){
  const { Worker } = require('node:worker_threads');
  const w = new Worker(path);
  globalThis.__btWorkers = globalThis.__btWorkers || [];
  globalThis.__btWorkers[slot] = w;
  w.on('message', function(m){
    // The SAME normalisation `client/hydrate/engine_transport.startWorker`
    // performs, and it is not cosmetic. Traps §3: this worker posts OBJECTS
    // before the WASM handover and JSON STRINGS after it, and a handler that
    // reads only `m.type` matches nothing after the handover and reports a
    // timeout over a peer that already answered. Text either way, classified
    // once, in `WorkerBackend.deliver`.
    cb(typeof m === 'string' ? m : JSON.stringify(m));
  });
  w.on('error', function(e){
    cb(JSON.stringify({ type: 'worker-error', error: String((e && e.stack) || e) }));
  });
  return true;
})(#, #, #)
""".}
  ## `slot`, and not one global handle, because this suite runs TWO sessions —
  ## §1b's wrong-key control arm is a second worker — and a single
  ## `globalThis.__btWorker` means the second one silently becomes the target
  ## of the first one's `postMessage`s. It did: every request after §1b went to
  ## a terminated worker, nothing answered, and the run ended at the watchdog
  ## reporting a hang over an engine that was fine. Traps §1's own lesson from
  ## the other side — the rc was honestly 124, and the hang was the harness's.

proc postJsonImpl(slot: int; messageJson: cstring) {.importjs:
  "(function(i, s){ globalThis.__btWorkers[i].postMessage(JSON.parse(s)); })(#, #)".}
  ## `JSON.parse` then `postMessage`, exactly as `engine_transport.postJson`
  ## does: the worker expects a structured-clone object and `JSON.stringify`s
  ## it itself. Posting the text is accepted and ignored — no error, no
  ## response, a session that hangs in `opening` forever.

proc postTraceBytes(slot: int; vfsPath, filePath: cstring) {.importjs: """
(function(i, vp, fp){
  const fs = require('node:fs');
  globalThis.__btWorkers[i].postMessage({
    type: 'vfs-write', path: vp, data: new Uint8Array(fs.readFileSync(fp))
  });
})(#, #, #)
""".}
  ## The one message that never crosses the adapter's text boundary — it
  ## carries raw bytes, which JSON cannot represent (dialect §2).
  ##
  ## Production uses `load-trace` with a URL instead, so that the container's
  ## bytes never touch the main thread (`engine_transport.loadTraceMessage`).
  ## Under Node there is no HTTP origin to fetch from, and the byte path is the
  ## one the engine's own e2e uses; the difference is upstream of every
  ## assertion here, all of which are about what the engine does with a
  ## container it has already been given.

proc terminateWorker(slot: int) {.importjs:
  "(function(i){ if (globalThis.__btWorkers[i]) globalThis.__btWorkers[i].terminate(); })(#)".}

proc fileExists(path: cstring): bool {.importjs:
  "(function(p){ return require('node:fs').existsSync(p); })(#)".}

proc argAt(i: int): cstring {.importjs: "(process.argv[# + 2] || '')".}

proc envVar(name: cstring): cstring {.importjs: "(process.env[#] || '')".}

proc nowMs(): int {.importjs: "Date.now()".}

proc installWatchdog(ms: int) {.importjs: """
(function(ms){
  setTimeout(function(){
    console.error('');
    console.error('E2E WATCHDOG: ' + ms + 'ms elapsed and the suite has not');
    console.error('finished. A request the engine never answered is a HANG,');
    console.error('not a failure — Traps §1: assert the rc, and the rc of a');
    console.error('hang is 124. This process exits 124 so the lane above can.');
    process.exit(124);
  }, ms);
})(#)
""".}

proc afterMs(ms: int): Future[void] {.importjs:
  "new Promise(function(r){ setTimeout(r, #); })".}

proc microtask(): Future[void] {.importjs: "Promise.resolve()".}

# ---------------------------------------------------------------------------
# Reporting — a counted set, with the count asserted
# ---------------------------------------------------------------------------

var checksRun = 0
var failures: seq[string] = @[]
var notes: seq[string] = @[]

proc check(name: string; ok: bool; detail = "") =
  inc checksRun
  if ok:
    echo "  [OK]   " & name
  else:
    failures.add(name)
    echo "  [FAIL] " & name & (if detail.len > 0: "\n           " & detail else: "")

proc note(line: string) =
  notes.add(line)
  echo "         · " & line

# ---------------------------------------------------------------------------
# The worker's non-DAP bootstrap traffic
# ---------------------------------------------------------------------------

type Waiter = ref object
  matches: proc(m: JsonNode): bool
  resolve: proc(m: JsonNode)

type Engine = ref object
  slot: int
  backend: WorkerBackend
  service: BackendService
  waiters: seq[Waiter]
  control: seq[JsonNode]
  events: seq[JsonNode]

proc onControlMessage(e: Engine; m: JsonNode) =
  e.control.add(m)
  var i = 0
  while i < e.waiters.len:
    if e.waiters[i].matches(m):
      let resolve = e.waiters[i].resolve
      e.waiters.delete(i)
      resolve(m)
    else:
      inc i

proc waitControl(e: Engine; pred: proc(m: JsonNode): bool): Future[JsonNode] =
  for m in e.control:
    if pred(m):
      return newCompletedFuture[JsonNode](m)
  let eng = e
  newPromise(proc(resolve: proc(m: JsonNode)) =
    eng.waiters.add(Waiter(matches: pred, resolve: resolve)))

proc hasType(t: string): proc(m: JsonNode): bool =
  result = proc(m: JsonNode): bool = m{"type"}.getStr == t

proc isReady(): proc(m: JsonNode): bool =
  result = proc(m: JsonNode): bool =
    m{"type"}.getStr == "worker-status" and m{"status"}.getStr == "ready"

# ---------------------------------------------------------------------------
# Reading a response
# ---------------------------------------------------------------------------

proc succeeded(response: JsonNode): bool =
  (not response.isNil) and response{"success"}.getBool

type Frame = object
  line: int
  name: string
  path: string

proc topFrame(response: JsonNode): Frame =
  let frames = response{"body"}{"stackFrames"}
  if frames.isNil or frames.kind != JArray or frames.len == 0:
    return Frame(line: -1, name: "", path: "")
  Frame(line: frames[0]{"line"}.getInt(-1),
        name: frames[0]{"name"}.getStr,
        path: frames[0]{"source"}{"path"}.getStr)

proc frameNames(response: JsonNode): seq[string] =
  let frames = response{"body"}{"stackFrames"}
  if frames.isNil or frames.kind != JArray: return
  for f in frames:
    result.add f{"name"}.getStr

func baseName(path: string): string =
  ## The last two path components, which is how the container spells a source
  ## (`src/shield.nr`) and how a reader recognises one.
  let parts = path.split('/')
  if parts.len >= 2: parts[^2] & "/" & parts[^1] else: path

# ---------------------------------------------------------------------------
# The oracle: what `ct-print` reads out of the same container bytes
# ---------------------------------------------------------------------------

type OracleRow = object
  ticks: int
  line: int
  function: string
  remainingShield: string   ## "" when this step wrote no `remaining_shield`

proc oracleRows(): seq[OracleRow] =
  let doc = parseJson(FlowOracleJson)
  for s in doc{"steps"}:
    var row = OracleRow(
      ticks: s{"ticks"}.getInt(-1),
      line: s{"line"}.getInt(-1),
      function: s{"function"}.getStr)
    let after = s{"after"}
    if not after.isNil and after.kind == JObject and after.hasKey("remaining_shield"):
      row.remainingShield = after["remaining_shield"].getStr
    result.add row

const OraclePath = "src/shield.nr"
  ## `flow.json`'s own `path`. Every row above is a step in this file.

# ---------------------------------------------------------------------------
# Flow-window reading (dialect §4a: the WINDOW is the event, not the response)
# ---------------------------------------------------------------------------

type FlowStep = object
  position: int
  loop: int
  iteration: int
  exprNames: seq[string]
  valueNames: seq[string]

type FlowWindow = object
  loops: int
  registeredLines: seq[int]     ## each loop's own source line, per the engine
  iterationTicks: int           ## how many per-iteration ticks the loops carry
  steps: seq[FlowStep]
  positions: seq[int]

proc addUnique(s: var seq[string]; v: string) =
  if v.len > 0 and v notin s: s.add v

proc readFlowWindow(payload: JsonNode): FlowWindow =
  ## `viewUpdates` is an array on the engine and an object in some deployments
  ## (`backend_manager.rs` converts the event into a response); both shapes are
  ## read, because a consumer that reads one is a consumer that is empty
  ## against the other half of its own deployments.
  let vu = payload{"viewUpdates"}
  if vu.isNil: return
  var entries: seq[JsonNode] = @[]
  if vu.kind == JArray:
    entries = vu.elems
  elif vu.kind == JObject:
    for _, v in vu.pairs: entries.add v
  for entry in entries:
    if entry.isNil or entry.kind != JObject: continue
    let loops = entry{"loops"}
    if not loops.isNil and loops.kind == JArray:
      result.loops += loops.len
      for lp in loops:
        result.registeredLines.add lp{"registeredLine"}.getInt(-1)
        let ticks = lp{"rrTicksForIterations"}
        if not ticks.isNil and ticks.kind == JArray:
          result.iterationTicks += ticks.len
    let steps = entry{"steps"}
    if steps.isNil or steps.kind != JArray: continue
    for st in steps:
      var fs = FlowStep(
        position: st{"position"}.getInt(-1),
        loop: st{"loop"}.getInt(-1),
        iteration: st{"iteration"}.getInt(-1))
      let order = st{"exprOrder"}
      if not order.isNil and order.kind == JArray:
        for e in order: fs.exprNames.addUnique(e.getStr)
      for table in ["beforeValues", "afterValues"]:
        let vals = st{table}
        if not vals.isNil and vals.kind == JObject:
          for name, _ in vals.pairs: fs.valueNames.addUnique(name)
      result.steps.add fs
      if fs.position notin result.positions: result.positions.add fs.position

proc inLoopSteps(w: FlowWindow): int =
  for s in w.steps:
    if s.loop >= 0: inc result

proc iterationsAt(w: FlowWindow; position: int; requiring = ""): seq[int] =
  for s in w.steps:
    if s.position != position or s.loop < 0: continue
    if requiring.len > 0 and requiring notin s.valueNames: continue
    if s.iteration notin result: result.add s.iteration
  result.sort()

# The full `Location` shape the engine deserialises (`task.rs`'s `Location`).
# Written out once: a location missing a field the engine has no `#[serde(default)]`
# for is a parse error, and dialect §4 records that `ct/load-flow`'s `location`
# is required and is where the tick actually lives.
proc location(path: string; line: int; ticks: int; fn = ""): JsonNode =
  %*{
    "path": path, "line": line,
    "highLevelPath": path, "highLevelLine": line,
    "lowLevelPath": "", "lowLevelLine": 0,
    "rrTicks": ticks,
    "functionName": fn, "highLevelFunctionName": fn,
    "functionFirst": 0, "functionLast": 0,
    "event": 0, "expression": "", "offset": 0, "error": false,
    "callstackDepth": 0, "originatingInstructionAddress": 0,
    "key": "", "globalCallKey": "",
    "expansionParents": [], "missingPath": false,
  }

# ---------------------------------------------------------------------------
# A session
# ---------------------------------------------------------------------------

var nextSlot = 0

proc newEngine(hostPath: string): Engine =
  let e = Engine(slot: nextSlot, waiters: @[], control: @[], events: @[])
  inc nextSlot
  let slot = e.slot
  e.backend = newWorkerBackend(
    postProc = proc(messageJson: string) = postJsonImpl(slot, messageJson.cstring),
    terminateProc = proc() = terminateWorker(slot))
  e.backend.onControl(proc(m: JsonNode) = onControlMessage(e, m))
  e.backend.onEvent(proc(ev: JsonNode) = e.events.add(ev))
  e.service = e.backend.toBackendService()
  discard startWorkerImpl(slot, hostPath.cstring, proc(raw: cstring) =
    e.backend.deliver($raw))
  e

proc eventsNamed(e: Engine; name: string): seq[JsonNode] =
  for ev in e.events:
    if ev{"event"}.getStr == name: result.add ev

# The per-request hang arm.
#
# `WorkerBackend` correlates a reply to a request by `seq` and never settles a
# future that gets no reply. That is correct — a transport must not invent an
# answer — but it means a DROPPED request presents as a suite that stops, and
# "the suite stopped" cannot say which request it stopped on. Traps §3: a
# timeout is a symptom, not a diagnosis, and the expensive mistake is to raise
# it, which turns a one-line fix into an afternoon.
#
# So a deadline NAMES the command, the check written for that command goes red
# with "no response" rather than with a wrong value, and the run CONTINUES —
# because a suite that stops at its first hang reports nothing about the eight
# sections after it, which is how a single defect hides a second one. The rc is
# still 124 (Traps §1: a hang arm is one whose recorded rc is 124); the exit is
# simply taken at the end, once every verdict has been printed.
var hungCommands: seq[string] = @[]

proc deadline(ms: int): Future[JsonNode] {.importjs:
  "new Promise(function(resolve){ setTimeout(function(){ resolve(null); }, #); })".}

proc raceToJson(answer, timeout: Future[JsonNode]): Future[JsonNode] {.importjs:
  "Promise.race([#, #])".}
  ## `Future[T]` on the JS target IS a `Promise` (`std/asyncjs`), so a race is
  ## the language's own. The losing side is simply never observed — a dropped
  ## request's future stays unsettled, which is precisely the state being
  ## detected.

const HungMarker = "__bt_no_response__"

proc hung(response: JsonNode): bool =
  (not response.isNil) and response.kind == JObject and
    response{HungMarker}.getBool

proc send(e: Engine; command: string; args: JsonNode;
          timeoutMs = 20_000): Future[JsonNode] {.async.} =
  ## Every request in this suite goes through here, so no single one can turn
  ## the whole run into an unexplained silence.
  let answered = await raceToJson(e.service.send(command, args),
                                  deadline(timeoutMs))
  if answered.isNil:
    if command notin hungCommands: hungCommands.add(command)
    echo "  [HANG] " & command & " — no response in " & $timeoutMs & " ms."
    echo "         The engine answered earlier requests on this session, so this"
    echo "         is a DROPPED request rather than a dead worker: the future"
    echo "         never settles, and a pane that awaited it spins forever with"
    echo "         nothing on screen to say why."
    return %*{HungMarker: true, "success": false,
              "message": "no response to " & command}
  return answered

# The mutation switch. Each value perturbs the SUBJECT (or, where the check is
# about the harness reading its own oracle, the oracle) and is expected to
# redden exactly one named check. `ci/test/noir-engine-dap-test.sh` drives them
# and fails a mutation that is killed by a DIFFERENT check than the one written
# for it — a kill by the wrong assertion is a MISS, not a kill.
var mutation = ""

# `expect-observed` is the control arm for a suite whose DELIVERABLE is
# failures, and it is the only one that is not a defect simulation.
#
# Ten of the checks below are red against today's engine. A mutation arm cannot
# prove those are working assertions, because the ordinary proof — "break the
# subject and watch it redden" — is satisfied trivially by a check that is
# stuck red and can never say yes. So the control runs the other way: under
# `expect-observed` every expectation is taken from what the engine ACTUALLY
# reports, and each of those checks must go GREEN. A check that stays red under
# its own observed value is not measuring the engine; it is broken.
#
# `§4c` is the deliberate exception. It is red because a request is never
# answered, and no expectation can be lowered to make an absent response
# present — which is the difference between a wrong answer and no answer, and
# is why the run's rc is 124 rather than 1.

# ---------------------------------------------------------------------------

proc run() {.async.} =
  let hostPath = $argAt(0)
  let tracePath = $argAt(1)
  mutation = $envVar("BT_ENGINE_DAP_MUTATION".cstring)

  echo "=== CodeTracer's Noir DAP tests, over BlockTracer's engine seam ==="
  echo "  worker host: " & hostPath
  echo "  container:   " & tracePath
  if mutation.len > 0:
    echo "  MUTATION:    " & mutation
  echo ""

  if hostPath.len == 0 or tracePath.len == 0:
    echo "FAIL: usage: noir_engine_dap <worker_host.mjs> <trace.ct>"
    quit(1)
  if not fileExists(hostPath.cstring):
    echo "FAIL: worker host missing: " & hostPath
    quit(1)
  if not fileExists(tracePath.cstring):
    echo "FAIL: container missing: " & tracePath
    quit(1)

  installWatchdog(600_000)

  # The set every position assertion below ranges over, decided HERE and
  # counted HERE. `oracle-truncated` drops a row from it without lowering the
  # claim — Traps §4b's exact shape, where two of three trees were not
  # installed and the run reported "31 assertions, 0 failures" instead of 33.
  var oracle = oracleRows()
  if mutation == "oracle-truncated" and oracle.len > 0:
    oracle = oracle[0 ..< oracle.len - 1]
  # Traps §4: assert the set the scan produced is non-empty — and where the
  # size is knowable, assert the SIZE — BEFORE asserting anything over it.
  # 82 is what `extract-flow.mjs` derived from these bytes; a fixture that
  # regenerated to a different number must be looked at, not averaged over,
  # and a LOOP that silently ranges over 81 of them must be found here rather
  # than never.
  check("§0 the container oracle carries its 82 known rows",
        oracle.len == 82,
        "the suite is about to range over " & $oracle.len & " rows, not 82")

  # -------------------------------------------------------------------------
  # §1 The handshake OPENS something — and the wrong key does not
  # -------------------------------------------------------------------------
  let e = newEngine(hostPath)
  discard await e.waitControl(hasType("wasm-loaded"))
  postTraceBytes(e.slot, "trace/trace.ct".cstring, tracePath.cstring)
  let ack = await e.waitControl(hasType("vfs-ack"))
  check("§1.0 the container is written into the engine's VFS",
        ack{"ok"}.getBool, $ack)
  postJsonImpl(e.slot, """{"type":"start"}""")
  discard await e.waitControl(isReady())

  discard await e.send("initialize", %*{
    "clientID": "blocktracer-noir-dap-port",
    "adapterID": "codetracer",
    "supportsProgressReporting": false})

  # `traceFolder`, not `program` — §1b drives the other one.
  discard await e.send("launch", %*{"traceFolder": "trace"})
  let configStart = nowMs()
  discard await e.send("configurationDone", newJObject())
  let configMs = nowMs() - configStart

  let entry = await e.send("stackTrace", %*{"threadId": 1})
  let entryFrame = entry.topFrame
  # THE artefact assertion, and the reason §1a is not `check(launch.succeeded)`.
  check("§1a the handshake leaves a real frame at a real position",
        entry.succeeded and entryFrame.line > 0 and entryFrame.path.len > 0 and
          entryFrame.name.len > 0,
        "frame: " & entryFrame.name & " @ " & entryFrame.path & ":" & $entryFrame.line)
  note("entry frame: " & entryFrame.name & " @ " & baseName(entryFrame.path) &
       ":" & $entryFrame.line)

  # §10, measured here because the handshake is where it is paid. `configurationDone`
  # is the only place `setup_from_vfs` runs (dialect §1), and in a browser the
  # expression loader's `load_file` always takes the Err arm — there is no
  # filesystem — which is an asymmetry that has hidden a cubic path before.
  # A generous bound: this is a regression tripwire, not a benchmark.
  check("§10 configurationDone opens the container in under 5s",
        configMs < 5000, "took " & $configMs & " ms")
  note("configurationDone: " & $configMs & " ms over a 1315-step container")

  # §1b — the control arm for Traps §2, driven rather than described.
  block wrongKeyLaunch:
    let e2 = newEngine(hostPath)
    discard await e2.waitControl(hasType("wasm-loaded"))
    postTraceBytes(e2.slot, "trace/trace.ct".cstring, tracePath.cstring)
    discard await e2.waitControl(hasType("vfs-ack"))
    postJsonImpl(e2.slot, """{"type":"start"}""")
    discard await e2.waitControl(isReady())
    discard await e2.send("initialize", %*{
      "clientID": "blocktracer-wrong-key", "adapterID": "codetracer"})
    let badLaunch = await e2.send("launch", %*{"program": tracePath})
    discard await e2.send("configurationDone", newJObject())
    let badStack = await e2.send("stackTrace", %*{"threadId": 1})
    let badFrame = badStack.topFrame
    note("wrong-key launch answered success=" & $badLaunch.succeeded &
         "; stackTrace answered success=" & $badStack.succeeded)
    check("§1b a launch with `program` instead of `traceFolder` reaches NO frame",
          badFrame.line <= 0 or badFrame.path.len == 0,
          "it produced a frame: " & badFrame.name & " @ " & badFrame.path &
            ":" & $badFrame.line & " — the wrong-key session opened something")
    e2.service.disconnect()

  # -------------------------------------------------------------------------
  # §5 The engine's position agrees with the container's own reading of itself
  #
  # Ported from the GUI test's "editor loaded main.nr" and every position
  # assertion downstream of it. On desktop the trace directory holds the source
  # and the recorded path resolves; in a browser the CTFS container carries no
  # source text at all (fixture README: `source_views: []`), so the only thing
  # that can be asserted is the POSITION — and the only honest oracle for a
  # position is the container itself, read by a different reader.
  #
  # ## Which reader, and why the pairing localises the defect
  #
  # The engine opens a `.ct` down one of two paths, and it says which:
  #
  #     CTFS from_bytes: old format detected — running postprocessing
  #     CTFS from_bytes: new (split-stream) format detected — opening via the
  #                      pure-Rust reader
  #
  # Measured against the SAME published engine, back to back:
  #
  #   * the OLD-format `stylus-fund` fixture reports `src/lib.rs:49`, `:60`,
  #     `:45` — real source lines in the right file;
  #   * this NEW-format container reports `std/lib.nr:4272`, `:5869`, `:6653` —
  #     four-digit numbers in a file none of these functions is in, while
  #     `functionName` is correct at every one of the 82 rows (§5c).
  #
  # Function names come from `calls.dat`; path and line come from `steps.dat`.
  # So the disagreement is not "the engine cannot read this container" — it
  # reads the call tree perfectly — it is the new reader's STEP decoding, and
  # the container is flagged `has_column_aware_steps` while the engine logs
  # `column: None` for every step it returns.
  #
  # That format is the one `nargo trace` writes today, so it is the one
  # BlockTracer vendors and publishes.
  # -------------------------------------------------------------------------
  var agreedPath = 0
  var agreedLine = 0
  var agreedFunction = 0
  var rowsChecked = 0
  var firstDisagreement = ""
  for row in oracle:
    let seek = await e.send("ct/goto-ticks",
      %*{"threadId": 1, "ticks": row.ticks})
    if not seek.succeeded: continue
    let at = await e.send("stackTrace", %*{"threadId": 1})
    let f = at.topFrame
    inc rowsChecked
    let expectPath = (if mutation == "expect-observed": baseName(f.path) else: OraclePath)
    let expectLine = (if mutation == "expect-observed": f.line else: row.line)
    if baseName(f.path) == expectPath: inc agreedPath
    if f.line == expectLine: inc agreedLine
    if f.name == row.function: inc agreedFunction
    if firstDisagreement.len == 0 and
       (baseName(f.path) != expectPath or f.line != expectLine):
      firstDisagreement = "tick " & $row.ticks & ": container says " &
        OraclePath & ":" & $row.line & " in " & row.function &
        "; engine says " & baseName(f.path) & ":" & $f.line & " in " & f.name

  check("§5.0 every oracle row was actually seeked (the scan is not partial)",
        rowsChecked == oracle.len,
        $rowsChecked & " of " & $oracle.len & " ticks answered")
  check("§5a the engine names the same SOURCE FILE as the container",
        agreedPath == rowsChecked,
        $agreedPath & " of " & $rowsChecked & " rows agree. " & firstDisagreement &
          ". Every position the session reports is one the source pane cannot " &
          "match, so the served page and the hydrated one disagree about where " &
          "the session is.")
  check("§5b the engine names the same LINE as the container",
        agreedLine == rowsChecked,
        $agreedLine & " of " & $rowsChecked & " rows agree. " & firstDisagreement &
          ". §5c passes at the same rows, so the call tree is read correctly " &
          "and it is the step decoding that is not.")
  # The positive twin (Traps §4a): if the seek/scan were broken, THIS goes red
  # too, so §5a and §5b cannot pass or fail for a reason outside the engine.
  check("§5c the engine names the same FUNCTION as the container",
        agreedFunction == rowsChecked,
        $agreedFunction & " of " & $rowsChecked & " rows agree")

  # -------------------------------------------------------------------------
  # §2 Stepping walks the program, and reverse retraces it
  #
  # Ported from `noir_flow_dap_stepping` (desktop: break at 24, `next` → 25 →
  # 26) and the GUI suite "step forward and backward". Desktop can name the
  # lines because its recorder and its assertion were written together; here
  # the stronger and version-independent statement is asserted instead:
  # N forward steps produce N distinct advancing stops, and N reverse steps
  # visit exactly those stops again, in reverse. A reverse step that is not the
  # inverse of a forward step is the defect a user feels as "the back button
  # went somewhere else".
  # -------------------------------------------------------------------------
  const StepCount = 8
  discard await e.send("ct/goto-ticks", %*{"threadId": 1, "ticks": 9})
  var forward: seq[(int, string, int)] = @[]   # (line, function, tick)
  block:
    let at0 = await e.send("stackTrace", %*{"threadId": 1})
    forward.add (at0.topFrame.line, at0.topFrame.name, 0)
  var forwardOk = true
  for i in 1 .. StepCount:
    let stepped = await e.send("next", %*{"threadId": 1})
    if not stepped.succeeded:
      forwardOk = false
      break
    let at = await e.send("stackTrace", %*{"threadId": 1})
    forward.add (at.topFrame.line, at.topFrame.name, i)
  check("§2a " & $StepCount & " forward `next`s produce " & $StepCount & " stops",
        forwardOk and forward.len == StepCount + 1,
        "collected " & $forward.len & " stops")
  var moved = 0
  for i in 1 ..< forward.len:
    if forward[i][0] != forward[i - 1][0] or forward[i][1] != forward[i - 1][1]:
      inc moved
  check("§2b every forward step moves the position",
        forward.len > 1 and moved == forward.len - 1,
        $moved & " of " & $(forward.len - 1) & " steps changed (line, function)")

  var retraced = 0
  var reverseOk = true
  for i in countdown(forward.len - 1, 1):
    let back = await e.send("stepBack", %*{"threadId": 1})
    if not back.succeeded:
      reverseOk = false
      break
    let at = await e.send("stackTrace", %*{"threadId": 1})
    if at.topFrame.line == forward[i - 1][0] and
       at.topFrame.name == forward[i - 1][1]:
      inc retraced
  check("§2c `stepBack` retraces every forward stop exactly",
        reverseOk and retraced == StepCount,
        $retraced & " of " & $StepCount & " reverse stops matched the forward ones")

  # GUI suite "step controls recover from reverse continue".
  let revCont = await e.send("reverseContinue", %*{"threadId": 1})
  let afterRev = await e.send("stackTrace", %*{"threadId": 1})
  let fwdCont = await e.send("continue", %*{"threadId": 1})
  let afterFwd = await e.send("stackTrace", %*{"threadId": 1})
  check("§2d reverseContinue then continue leaves a positioned session",
        revCont.succeeded and fwdCont.succeeded and
          afterRev.topFrame.line > 0 and afterFwd.topFrame.line > 0,
        "reverse→" & $afterRev.topFrame.line & ", forward→" & $afterFwd.topFrame.line)

  # -------------------------------------------------------------------------
  # §3 The call stack names its frames, in order
  #
  # Ported from `noir_flow_dap_call_stack` verbatim in shape: desktop asserts
  # add_offset → calculate_sum → main. This program's equivalent nest is
  # calculate_damage → iterate_asteroids → main, and the fixture README's
  # "max call depth 3" is what makes the COUNT knowable, so it is asserted
  # rather than bounded (desktop's `expected_frame_count` is `None`; here it
  # need not be).
  # -------------------------------------------------------------------------
  # Tick 21 is `calculate_damage`'s first executable step, per the oracle.
  discard await e.send("ct/goto-ticks", %*{"threadId": 1, "ticks": 21})
  let nest = await e.send("stackTrace", %*{"threadId": 1})
  let names = nest.frameNames
  check("§3a the call stack at calculate_damage names its three frames in order",
        names.len >= 3 and names[0] == "calculate_damage" and
          names[1] == "iterate_asteroids" and names[2] == "main",
        "frames: " & $names)
  check("§3b the call stack is exactly three frames deep there",
        names.len == 3, "frames: " & $names)

  # -------------------------------------------------------------------------
  # §4 The call trace, and the jump the GUI test performs
  # -------------------------------------------------------------------------
  let calltrace = await e.send("ct/load-calltrace-section", %*{
    "location": %*{"rrTicks": 0},
    "startCallLineIndex": 0, "depth": 3, "height": 200,
    "rawIgnorePatterns": ""})
  var callNames: seq[string] = @[]
  var damageLocation: JsonNode = nil
  var damageLine = -1
  var damagePath = ""
  let callLines = calltrace{"body"}{"callLines"}
  if not callLines.isNil and callLines.kind == JArray:
    for cl in callLines:
      let call = cl{"content"}{"call"}
      if call.isNil or call.kind != JObject: continue
      let loc = call{"location"}
      let fn = loc{"functionName"}.getStr
      callNames.addUnique(fn)
      if fn == "calculate_damage" and damageLocation.isNil:
        damageLocation = loc
        damageLine = loc{"line"}.getInt(-1)
        damagePath = loc{"path"}.getStr

  # The fixture README states 6 functions; the count is knowable, so it is the
  # control (Traps §4b), not `>= 1`.
  const NoirFunctions = ["main", "iterate_asteroids", "calculate_damage",
                         "calculate_shield_regeneration",
                         "calculate_remaining_shield_pct", "status_report"]
  var present = 0
  for fn in NoirFunctions:
    if fn in callNames: inc present
  check("§4a the call trace names all six of the program's functions",
        present == NoirFunctions.len,
        $present & " of 6 present; call trace named: " & $callNames)
  let expectDamagePath =
    (if mutation == "expect-observed": baseName(damagePath) else: "src/shield.nr")
  let expectDamageLine = (if mutation == "expect-observed": damageLine else: 26)
  check("§4b the calculate_damage row points at src/shield.nr:26",
        baseName(damagePath) == expectDamagePath and damageLine == expectDamageLine,
        "row points at " & baseName(damagePath) & ":" & $damageLine &
          " (desktop asserts shield.nr:26 — the call's first executable step, " &
          "and the container's own oracle puts it at tick 21, line 26)")

  # The jump itself. GUI: "calltrace jump to calculate_damage lands on
  # shield.nr executable line 26".
  if damageLocation.isNil:
    check("§4c ct/calltrace-jump lands the session on the row's position",
          false, "no calculate_damage row to jump to")
  else:
    let jumped = await e.send("ct/calltrace-jump", damageLocation)
    let after = await e.send("stackTrace", %*{"threadId": 1})
    let jumpFrame = after.topFrame
    check("§4c ct/calltrace-jump answers and lands on the row's position",
          (not jumped.hung) and jumped.succeeded and
            jumpFrame.line == damageLine and
            baseName(jumpFrame.path) == baseName(damagePath),
          (if jumped.hung:
             "the engine never answered ct/calltrace-jump. It is dispatched " &
             "(dap_server.rs's handle_request has an arm for it), the worker " &
             "survives, and no response, error or event is ever produced — so " &
             "a consumer awaiting it waits forever."
           else:
             "jump success=" & $jumped.succeeded & ", landed at " &
             baseName(jumpFrame.path) & ":" & $jumpFrame.line))

  # -------------------------------------------------------------------------
  # §6 Flow at iterate_asteroids — the loop the GUI test is about
  #
  # Ported from the GUI suite "loop iteration via calltrace": its four tests
  # assert that after landing in `iterate_asteroids`, `ct/load-flow` produces a
  # window with loops, in-loop steps, the loop-local NAMES, and those names at
  # iterations 0 and 7.
  #
  # Two dialect rows apply and are obeyed rather than worked around:
  #   §4  `flowMode` is a NAME on the wire now ("call"), not an ordinal, and
  #       `location` is required and is where the tick lives.
  #   §4a the RESPONSE carries a placeholder window; the real one is the
  #       `ct/updated-flow` EVENT, and events QUEUE — so the drain below is
  #       load-bearing.
  # -------------------------------------------------------------------------
  discard await e.send("ct/goto-ticks", %*{"threadId": 1, "ticks": 13})
  let flowAt = await e.send("stackTrace", %*{"threadId": 1})
  let flowFrame = flowAt.topFrame

  # The drain, and a note about the arm that is NOT here.
  #
  # A `no-drain` mutation was written for this and then removed, because it is
  # a check that cannot fail: measured against this engine and this container,
  # nothing emits `ct/updated-flow` before the first `ct/load-flow`, so a run
  # that skipped the drain would read the same window as one that did not.
  # §4a's hazard is real and this line is the defence against it — but it is a
  # defence whose absence this fixture cannot demonstrate, and an arm that
  # passes for that reason is exactly the vacuous green the self-test exists to
  # refuse. Recorded rather than shipped inert.
  let drainedBefore = e.eventsNamed("ct/updated-flow").len

  let flowResp = await e.send("ct/load-flow", %*{
    "flowMode": (if mutation == "flow-mode-out-of-range": %(2) else: %"call"),
    "location": location(flowFrame.path, flowFrame.line, 13, flowFrame.name)})
  check("§6a ct/load-flow is accepted with the NAMED wire mode (dialect §4)",
        flowResp.succeeded,
        "success=false: " & flowResp{"message"}.getStr)

  var window = FlowWindow()
  var waited = 0
  while waited < 15000:
    let updates = e.eventsNamed("ct/updated-flow")
    if updates.len > drainedBefore:
      window = readFlowWindow(updates[^1]{"body"})
      break
    await afterMs(50)
    waited += 50
  check("§6b the flow WINDOW arrives as a ct/updated-flow event (dialect §4a)",
        window.steps.len > 0,
        "no window after " & $waited & " ms; ct/updated-flow events seen: " &
          $e.eventsNamed("ct/updated-flow").len)

  let goodLoops = window.loops
  let goodInLoop = window.inLoopSteps
  note("flow window: " & $window.steps.len & " steps, " & $goodLoops &
       " loops, " & $goodInLoop & " in-loop steps")
  note("flow step positions: " & $window.positions)
  note("loop registeredLine(s): " & $window.registeredLines &
       "; per-iteration ticks recorded: " & $window.iterationTicks)
  check("§6c the window carries the loop and steps inside it",
        goodLoops > 0 and goodInLoop > 0,
        "loops=" & $goodLoops & " in-loop-steps=" & $goodInLoop)

  # The loop's OWN metadata, checked before anything is asked of its steps.
  #
  # This is the artefact the iteration control is built on, and it is a
  # different thing from "there is a loop in the window": BlockTracer's static
  # demo carries `loop.registeredLine = 4` and eight `iterationTicks` (derived
  # from these same bytes into `client/fixtures/demo-session/flow.json`), and a
  # rail with no registered line and no per-iteration ticks has nothing to
  # move. Asserting it here means the failure names the loop rather than
  # arriving three checks later as "no iterations at position 4".
  let expectRegisteredLine =
    (if mutation == "expect-observed" and window.registeredLines.len > 0:
       window.registeredLines[0] else: 4)
  let expectIterationTicks =
    (if mutation == "expect-observed": window.iterationTicks else: 8)
  check("§6c2 the loop names the source line it is registered on (4)",
        expectRegisteredLine in window.registeredLines,
        "registeredLine(s): " & $window.registeredLines &
          " — the container records the loop at src/shield.nr:4")
  check("§6c3 the loop carries a tick for each of its eight passes",
        window.iterationTicks == expectIterationTicks,
        $window.iterationTicks & " per-iteration ticks; the container records " &
          "8 (flow.json's loop.iterationTicks) and the iteration control needs " &
          "one per pass to seek to")

  var allExpr: seq[string] = @[]
  var allValues: seq[string] = @[]
  for s in window.steps:
    for n in s.exprNames: allExpr.addUnique(n)
    for n in s.valueNames: allValues.addUnique(n)
  const ExpectedExpr = ["regeneration", "remaining_shield"]
  const ExpectedValues = ["initial_shield", "shield_regen_percentage", "masses",
                          "regeneration", "remaining_shield"]
  var exprPresent = 0
  for n in ExpectedExpr:
    if n in allExpr: inc exprPresent
  var valuesPresent = 0
  for n in ExpectedValues:
    if n in allValues: inc valuesPresent
  check("§6d source extraction sees both loop-local names",
        exprPresent == ExpectedExpr.len,
        $exprPresent & " of 2; exprOrder named: " & $allExpr)
  check("§6e replay resolves values for all five names the GUI test lists",
        valuesPresent == ExpectedValues.len,
        $valuesPresent & " of 5; resolved: " & $allValues)

  # The loop header is `for i in 0..8` at src/shield.nr line 4; the eight
  # passes are iterations 0..7. Desktop asserts 0 and 7 are both present, which
  # is the pair that proves the window spans the whole loop rather than the
  # pass the session is sitting in.
  # `src/shield.nr:4` is the `for` header and `:12` is `remaining_shield +=
  # regeneration`. Under `expect-observed` the positions become whichever ones
  # the engine actually emitted, and the iteration pair becomes whichever it
  # actually tagged — so a green here says the reader works and the numbers are
  # the engine's, which is exactly the distinction the ten red checks need.
  proc firstPositionCarrying(name: string): int =
    ## The position the engine ACTUALLY put this name on, for the control arm.
    ## Taking `positions[0]` instead was wrong and the self-test caught it:
    ## position 0 is the function's first line, which carries no loop-local at
    ## all, so §6g and §6h stayed red on the engine's own values — a control
    ## that failed for the same reason a stuck-red check would.
    for s in window.steps:
      if s.loop >= 0 and name in s.valueNames: return s.position
    -1
  let headerPosition = (if mutation == "expect-observed" and
                           window.positions.len > 0: window.positions[0] else: 4)
  let regenPosition = (if mutation == "expect-observed":
                         firstPositionCarrying("regeneration") else: 12)
  let shieldPosition = (if mutation == "expect-observed":
                          firstPositionCarrying("remaining_shield") else: 12)
  let headerIterations = iterationsAt(window, headerPosition)
  let regenIterations = iterationsAt(window, regenPosition, requiring = "regeneration")
  let shieldIterations = iterationsAt(window, shieldPosition, requiring = "remaining_shield")
  proc carries(iterations: seq[int]): bool =
    if mutation == "expect-observed": iterations.len > 0
    else: 0 in iterations and 7 in iterations
  note("loop-header iterations at line 4: " & $headerIterations)
  note("regeneration iterations at line 12: " & $regenIterations)
  note("remaining_shield iterations at line 12: " & $shieldIterations)
  check("§6f the loop header carries iterations 0 and 7",
        carries(headerIterations),
        "iterations at line 4: " & $headerIterations)
  check("§6g regeneration is resolved at iterations 0 and 7 on line 12",
        carries(regenIterations),
        "iterations: " & $regenIterations)
  check("§6h remaining_shield is resolved at iterations 0 and 7 on line 12",
        carries(shieldIterations),
        "iterations: " & $shieldIterations)

  # The negative twin, over the same reader: the STALE location the desktop
  # test isolates (`rrTicks = 0`, `line = NO_LINE`) must NOT produce the same
  # window. If it did, a panel that deferred its flow request would render the
  # loop widget by accident and nothing would ever notice.
  let staleBefore = e.eventsNamed("ct/updated-flow").len
  let staleResp = await e.send("ct/load-flow", %*{
    "flowMode": %"call",
    "location": location(flowFrame.path, -1, 0, "")})
  var staleWindow = FlowWindow()
  var staleWaited = 0
  while staleWaited < 5000:
    let updates = e.eventsNamed("ct/updated-flow")
    if updates.len > staleBefore:
      staleWindow = readFlowWindow(updates[^1]{"body"})
      break
    await afterMs(50)
    staleWaited += 50
  note("stale-location window: " & $staleWindow.loops & " loops, " &
       $staleWindow.inLoopSteps & " in-loop steps (response success=" &
       $staleResp.succeeded & ")")
  check("§6i the stale location does NOT reproduce the good window",
        staleWindow.loops < goodLoops or staleWindow.inLoopSteps < goodInLoop,
        "stale produced loops=" & $staleWindow.loops & " in-loop=" &
          $staleWindow.inLoopSteps & " against good loops=" & $goodLoops &
          " in-loop=" & $goodInLoop)

  # -------------------------------------------------------------------------
  # §7 Locals — the State pane's own command (dialect §3-D1)
  #
  # Ported from `noir_flow_dap_variables_and_values`, which asserts NAMES and
  # VALUES (sum_val=42, doubled=84, final_result=94). The equivalent here is
  # `remaining_shield` at a tick where the container records what it holds, so
  # the value is checked against the container rather than against a number
  # somebody typed.
  # -------------------------------------------------------------------------
  # `src/shield.nr:7` is `remaining_shield -= damage`, and the container's step
  # for it is tick 38 with an `after` value of 9900 (from 10000). The fixture
  # README calls those 29 `remaining_shield` transitions the observable
  # consequence of the recorder fix this container was taken after, so the
  # WRITE is the artefact to assert, not a static number.
  #
  # It is asserted on BOTH sides of the step, and that pairing is the point.
  # `ct/load-locals` at a tick is a PRE-step snapshot — the debugger has
  # stopped ON the line and has not run it — while the container's `after` is
  # the post-step one. Measured: engine tick 38 = 10000, tick 40 = 9900,
  # against a container that records 10000 before and 9900 after. The two
  # readers agree; they are simply reporting different sides of the same step,
  # and a check written against only one side of it cannot tell a convention
  # from a defect. So both are pinned, and a `remaining_shield` that stopped
  # updating would redden the second while a shifted convention would redden
  # the first.
  const WriteTick = 38     ## the step that performs `remaining_shield -= damage`
  const AfterTick = 40     ## the next step in the same frame
  var oracleBefore = ""
  var oracleAfter = ""
  for row in oracle:
    if row.ticks == WriteTick: oracleAfter = row.remainingShield
    if row.ticks == 17: oracleBefore = row.remainingShield  # last write before it
  check("§7.0 the oracle records the remaining_shield write at tick " & $WriteTick,
        oracleBefore.len > 0 and oracleAfter.len > 0 and oracleBefore != oracleAfter,
        "oracle before='" & oracleBefore & "' after='" & oracleAfter & "'")

  proc shieldAt(tick: int): Future[(seq[string], string)] {.async.} =
    discard await e.send("ct/goto-ticks", %*{"threadId": 1, "ticks": tick})
    let locals = await e.send("ct/load-locals", %*{
      "rrTicks": tick, "countBudget": 100, "minCountLimit": 10,
      "depthLimit": 3, "watchExpressions": [], "lang": 0})
    var names: seq[string] = @[]
    var value = ""
    proc harvest(node: JsonNode) =
      if node.isNil: return
      if node.kind == JArray:
        for item in node: harvest(item)
      elif node.kind == JObject:
        let expr = node{"expression"}.getStr
        if expr.len > 0:
          names.addUnique(expr)
          if expr == "remaining_shield":
            let v = node{"value"}
            if not v.isNil:
              value = (if v.kind == JString: v.getStr else: v{"i"}.getStr($v))
        for _, child in node.pairs: harvest(child)
    harvest(locals{"body"})
    return (names, value)

  let (localNames, beforeValue) = await shieldAt(WriteTick)
  let (_, afterValue) = await shieldAt(AfterTick)
  note("locals at tick " & $WriteTick & ": " & $localNames)
  note("remaining_shield: tick " & $WriteTick & " = '" & beforeValue &
       "', tick " & $AfterTick & " = '" & afterValue &
       "' (container: " & oracleBefore & " → " & oracleAfter & ")")
  check("§7a ct/load-locals answers with named locals, not an empty pane",
        localNames.len > 0, "names=" & $localNames)
  check("§7b remaining_shield is among them",
        "remaining_shield" in localNames, "names: " & $localNames)
  check("§7c it holds the pre-write value ON the writing step (" & oracleBefore & ")",
        beforeValue.contains(oracleBefore),
        "engine says '" & beforeValue & "', container's pre-write value is '" &
          oracleBefore & "'")
  check("§7d it holds the post-write value on the NEXT step (" & oracleAfter & ")",
        afterValue.contains(oracleAfter),
        "engine says '" & afterValue & "', container's post-write value is '" &
          oracleAfter & "' — the write the recorder fix exists to record is " &
          "not visible in the State pane")

  # -------------------------------------------------------------------------
  # §8 Value origin (dialect §3-D3; desktop `origin_noir_dap_test.rs`)
  #
  # Desktop asserts an exact chain for its own `simple_trivial_chain` fixture:
  # 3 hops, kinds [TrivialCopy, TrivialCopy, Literal], terminator Literal,
  # confidence >= 0.7. That fixture is not this program, so the numbers are not
  # portable; what IS portable — and is the thing a BlockTracer Values pane
  # would surface — is that the query answers with a CHAIN rather than with a
  # `success: true` and nothing in it.
  # -------------------------------------------------------------------------
  let originResp = await e.send("ct/originChain", %*{
    "variableName": "remaining_shield",
    "stepId": WriteTick,
    "location": location(flowFrame.path, flowFrame.line, WriteTick, flowFrame.name)})
  var hopKinds: seq[string] = @[]
  var terminator = ""
  var confidence = -1.0
  block readChain:
    let body = originResp{"body"}
    if body.isNil: break readChain
    for key in ["chain", "originChain", "hops"]:
      let node = body{key}
      if node.isNil: continue
      let hops = (if node.kind == JArray: node else: node{"hops"})
      if not hops.isNil and hops.kind == JArray:
        for hop in hops:
          hopKinds.add(hop{"kind"}.getStr(hop{"originKind"}.getStr("?")))
      if node.kind == JObject:
        terminator = node{"terminator"}{"kind"}.getStr(
          node{"terminatorKind"}.getStr(""))
        let c = node{"confidence"}
        if not c.isNil: confidence = c.getFloat(-1.0)
    if terminator.len == 0:
      terminator = body{"terminatorKind"}.getStr(body{"terminator"}{"kind"}.getStr(""))
    if confidence < 0:
      confidence = body{"confidence"}.getFloat(-1.0)
  note("originChain: " & $hopKinds.len & " hops " & $hopKinds &
       ", terminator '" & terminator & "', confidence " & $confidence)
  check("§8a ct/originChain answers at all (dialect §3-D3 no longer traps)",
        originResp.succeeded, originResp{"message"}.getStr($originResp))
  check("§8b the answer carries at least one hop",
        hopKinds.len > 0,
        "the response's chain is empty — a Values pane would show an origin " &
          "button that opens nothing. body: " & $originResp{"body"})
  check("§8c every hop names an origin kind",
        hopKinds.len > 0 and hopKinds.allIt(it.len > 0 and it != "?"),
        "hops: " & $hopKinds)

  # -------------------------------------------------------------------------
  # §9 reverse-step-in — the dialect's own extension (dialect §9)
  #
  # BlockTracer renders the eighth toolbar control. §9 records that DAP has no
  # spelling for it, that the DAP-shaped guess is refused BY NAME, and that
  # `ct/reverseStepIn` is a DISTINCT move rather than an alias of `stepBack` —
  # something no mock can tell, which is why the check has to be here.
  # -------------------------------------------------------------------------
  discard await e.send("ct/goto-ticks", %*{"threadId": 1, "ticks": 100})
  let guess = await e.send("reverseStepIn", %*{"threadId": 1})
  check("§9a the DAP-shaped guess `reverseStepIn` is refused BY NAME",
        (not guess.succeeded) and
          guess{"message"}.getStr.contains("not supported here"),
        "success=" & $guess.succeeded & " message='" &
          guess{"message"}.getStr & "'")
  let extension = await e.send(
    (if mutation == "reverse-unprefixed": "reverseStepIn" else: "ct/reverseStepIn"),
    %*{"threadId": 1})
  let afterExtension = await e.send("stackTrace", %*{"threadId": 1})
  check("§9b `ct/reverseStepIn` is dispatched and moves the session",
        extension.succeeded and afterExtension.topFrame.line > 0,
        "success=" & $extension.succeeded)

  # The sweep: a single anchor cannot distinguish a reverse-next from a
  # reverse-step-in, because they agree everywhere except at a call boundary.
  # EVERY tick the container's oracle names, not a hand-picked handful.
  #
  # A shallow sweep that finds no difference cannot distinguish "these two
  # commands are the same move" from "none of my anchors was a call boundary",
  # and the honest fix is to strengthen the fixture rather than to accept the
  # survivor. The oracle's 82 rows span all eight loop passes and every call
  # return in the window — tick 31 is `calculate_damage` immediately after
  # `calculate_remaining_shield_pct` returned, tick 38 is `iterate_asteroids`
  # immediately after `calculate_damage` returned, tick 56 the same for
  # `calculate_shield_regeneration` — so a zero here is a fact about the
  # commands, not about the anchors.
  let sweepAnchors = oracle.mapIt(it.ticks)
  var differed = 0
  var anchorsSwept = 0
  var firstDifference = ""
  for anchor in sweepAnchors:
    discard await e.send("ct/goto-ticks", %*{"threadId": 1, "ticks": anchor})
    discard await e.send("stepBack", %*{"threadId": 1})
    let backAt = await e.send("stackTrace", %*{"threadId": 1})
    discard await e.send("ct/goto-ticks", %*{"threadId": 1, "ticks": anchor})
    discard await e.send("ct/reverseStepIn", %*{"threadId": 1})
    let inAt = await e.send("stackTrace", %*{"threadId": 1})
    inc anchorsSwept
    if backAt.topFrame.line != inAt.topFrame.line or
       backAt.topFrame.name != inAt.topFrame.name:
      inc differed
      if firstDifference.len == 0:
        firstDifference = "tick " & $anchor & ": stepBack → " &
          backAt.topFrame.name & ":" & $backAt.topFrame.line &
          ", ct/reverseStepIn → " & inAt.topFrame.name & ":" & $inAt.topFrame.line
  check("§9c the sweep visited every one of its " & $sweepAnchors.len & " anchors",
        anchorsSwept == sweepAnchors.len,
        $anchorsSwept & " of " & $sweepAnchors.len)
  note("ct/reverseStepIn differs from stepBack at " & $differed & " of " &
       $anchorsSwept & " anchors" &
       (if firstDifference.len > 0: "; first: " & firstDifference else: ""))
  check("§9d ct/reverseStepIn is a DISTINCT move, not an alias of stepBack",
        (if mutation == "expect-observed": differed >= 0 else: differed > 0),
        "the two commands agreed at all " & $anchorsSwept & " anchors. The " &
          "sweep covers every call return in the container's flow window, so " &
          "'the fixture is too shallow' is ruled out: on this container the " &
          "eighth toolbar control makes the same move as the reverse-next one.")

  # -------------------------------------------------------------------------
  # §11 Teardown (dialect §3-D4)
  # -------------------------------------------------------------------------
  e.service.disconnect()
  await microtask()
  check("§11 disconnect tears the session down and strands no request",
        e.backend.pendingCount == 0 and e.backend.disconnected,
        "pending=" & $e.backend.pendingCount & " disconnected=" &
          $e.backend.disconnected)

  # -------------------------------------------------------------------------
  # The assertion-count fingerprint (Traps §4b)
  #
  # A per-check count is a fingerprint; diff it across runs and a silent skip
  # becomes visible. A check that CEASES TO EXIST does not fail — which is
  # exactly how a suite reports "31 assertions, 0 failures" instead of 33 and
  # goes green.
  # -------------------------------------------------------------------------
  # 42, not 43: §4c has two mutually exclusive call sites (the calculate_damage
  # row was found, or it was not) and exactly one of them runs.
  const ExpectedChecks = 42
  echo ""
  echo "  --- notes ---"
  for n in notes: echo "  " & n
  echo ""
  echo "noir-engine-dap: " & $checksRun & " checks, " & $failures.len & " failed"
  if failures.len > 0:
    echo ""
    echo "  failed checks:"
    for f in failures: echo "    - " & f
  if hungCommands.len > 0:
    echo ""
    echo "  commands the engine never answered (" & $hungCommands.len & "):"
    for c in hungCommands: echo "    - " & c
  if checksRun != ExpectedChecks:
    echo ""
    echo "HARNESS: this run made " & $checksRun & " checks; the suite declares " &
         $ExpectedChecks & "."
    echo "  A count that moves is a check that stopped existing, and a check that"
    echo "  stopped existing does not fail. Fix the count or find the skip."
    quit(1)
  # 124 outranks 1. A run with a hang AND ordinary failures is reported as a
  # hang, because the hang is the more expensive fact and the one whose rc a
  # reader is entitled to trust (Traps §1).
  if hungCommands.len > 0:
    quit(124)
  if failures.len > 0:
    quit(1)
  quit(0)

discard run()
