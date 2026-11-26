## SDK-CONSUMER: what the page can honestly say about a replay session that is
## not live yet — from the messages that have actually crossed the worker
## boundary, and nothing else.
##
## ## Why this module exists
##
## The engine deadline in `hydrate.nim` used to choose between two sentences on
## ONE fact: whether the worker had posted `wasm-loaded`. Once it had, the page
## said the engine "would not open this trace container … it rejected the
## container's format". That inference was measured false (codetracer-pm
## `issues/2026-11-26-large-evm-recordings-cannot-be-debugged-in-the-hydrated-
## debug-page.md`): on a 673,363-step EVM recording the engine had loaded the
## container in 0.6 s and was still working on `launch` when the deadline fired.
## It had refused nothing.
##
## And the opposite case went unreported. The pinned engine answers `launch`
## TWICE when it cannot open a container — measured against the pinned wasm
## (`d696b18d…`) with a `meta.dat` 6 container, driven in the SDK's handshake
## order:
##
##     << response request_seq=3 command=launch success=true
##     << response request_seq=3 command=launch success=false
##          message="handle_message_browser failed: CTFS from_bytes failed …
##                   meta.dat: version 6 is not readable: this reader reads
##                   version 7 only. …"
##     >> threads
##     << response command=threads success=false
##          message="no trace is open: `threads` cannot be serviced — …"
##
## (`handle_message_browser`'s launch arm delegates to the shared
## `handle_message`, which answers success, and only THEN builds the handler
## from the VFS; `dap.rs` turns that failure into a second response carrying
## the same `request_seq`.) `WorkerBackend` settles the request on the first
## response, so the session goes `dspReady`; the second arrives as an unmatched
## control message, which the page discarded; and `threads`' `success: false`
## was read as success. That is how a refused container reached `phase=ready`
## with live controls and no notice.
##
## So this module RECORDS, rather than infers: which stage of the opening the
## worker has reported, which of the opening requests have been sent and which
## answered, and the first refusal of one of them, with the engine's own words.
## The verdicts below are functions of that record.
##
## ## What counts as a refusal
##
## A `success: false` response to one of the OPENING requests — `initialize`,
## `configurationDone`, `launch` (matched or not: see the transcript) — or to
## `threads`, the page's first request of an opened trace. Nothing else: once
## the panel ViewModels exist they send their own requests, and a failed
## `ct/load-locals` on a healthy trace is a pane's business, not a reason to
## declare the trace unopenable.
##
## Pure, and free of the DOM, so `tests/tdebugpanes.nim` drives it on the C
## backend over the real SDK's `WorkerBackend`.

import std/[json, options, strutils]
import codetracer_embed

const
  OpeningCommands* = ["initialize", "configurationDone", "launch"]
    ## The SDK's handshake (`DebuggerSession.launch`), in the order it sends.
  FirstRequestCommand* = "threads"
    ## The first request the page sends to an opened trace (`afterReady`).

type
  Refusal* = object
    ## The engine said no, to a request this module watches.
    command*: string     ## the request the engine refused
    message*: string     ## the engine's own reason, verbatim
    response*: JsonNode  ## the whole response, for the SDK's classifier

  SessionWatch* = object
    ## What has been observed of one session's opening.
    wasmLoaded*: bool    ## the worker posted `wasm-loaded`
    traceLoaded*: bool   ## the worker posted `trace-loaded`: the bytes are in
    workerReady*: bool   ## `wasm_start` answered `ready`; the handshake can go
    sentSeqs: seq[int]
    sentCommands: seq[string]
    answered: seq[string]  ## commands whose FIRST response has arrived
    refusal*: Option[Refusal]

  OpeningStage* = enum
    ## Where an opening that has not gone live is, as far as the messages show.
    ## Ordered: each stage is reached only through the ones above it.
    osEngineNotLoaded    ## no `wasm-loaded`: the engine never arrived
    osDownloadingTrace   ## engine loaded; the container has not finished arriving
    osStartingEngine     ## the container is in; the debugger has not said `ready`
    osHandshaking        ## `initialize` / `configurationDone` sent, not answered
    osOpeningTrace       ## `launch` sent and not answered: the engine is opening it
    osPositioning        ## opened; the first request has not been answered
    osRefused            ## the engine refused one of the watched requests

  OpeningVerdict* = object
    ## What the page says, and the SDK classification that agrees with it.
    stage*: OpeningStage
    sentence*: string
    kind*: DebuggerSessionErrorKind

proc isWatched(command: string): bool =
  command in OpeningCommands or command == FirstRequestCommand

proc commandOfSeq(w: SessionWatch; requestSeq: int): string =
  for i, s in w.sentSeqs:
    if s == requestSeq: return w.sentCommands[i]
  ""

proc wasSent*(w: SessionWatch; command: string): bool =
  command in w.sentCommands

proc wasAnswered*(w: SessionWatch; command: string): bool =
  command in w.answered

proc noteControl*(w: var SessionWatch; message: JsonNode) =
  ## The worker's own bootstrap traffic, as `WorkerBackend` hands it to
  ## `onControl`.
  if message.isNil or message.kind != JObject: return
  case message{"type"}.getStr("")
  of "wasm-loaded": w.wasmLoaded = true
  of "trace-loaded": w.traceLoaded = true
  of "worker-status":
    if message{"status"}.getStr("") == "ready": w.workerReady = true
  else: discard

proc noteOutbound*(w: var SessionWatch; messageJson: string) =
  ## A message the page is posting to the worker, as `WorkerBackend` rendered
  ## it. Only the watched requests are recorded; the seq is what lets a later
  ## response be attributed even when its `command` field is empty (the SDK's
  ## synthetic failures carry none).
  var node: JsonNode
  try: node = parseJson(messageJson)
  except CatchableError: return
  if node.isNil or node.kind != JObject: return
  if node{"type"}.getStr("") != "request": return
  let command = node{"command"}.getStr("")
  if not isWatched(command): return
  w.sentSeqs.add node{"seq"}.getInt(-1)
  w.sentCommands.add command

proc failureText(response: JsonNode): string =
  ## The engine's reason, as the engine wrote it.
  result = response{"message"}.getStr("")
  if result.len == 0:
    let body = response{"body"}
    if body != nil and body.kind == JObject and body.hasKey("error"):
      result = (if body["error"].kind == JString: body["error"].getStr()
                else: $body["error"])
  if result.len == 0: result = "no reason given"

proc noteResponse*(w: var SessionWatch; response: JsonNode): bool =
  ## A DAP response from the worker. Returns true when it is the FIRST refusal
  ## of a watched request — the moment the page has something true to say.
  if response.isNil or response.kind != JObject: return false
  if response{"type"}.getStr("") != "response": return false
  var command = w.commandOfSeq(response{"request_seq"}.getInt(-1))
  if command.len == 0:
    # Not one we recorded sending. Accept it by name only if it names a
    # watched command, so a refusal is never lost to a missing seq.
    command = response{"command"}.getStr("")
    if not isWatched(command) or not w.wasSent(command): return false
  if command notin w.answered: w.answered.add command
  if response{"success"}.getBool(true): return false
  if w.refusal.isSome: return false
  w.refusal = some(Refusal(command: command, message: failureText(response),
                           response: response))
  true

proc noteInbound*(w: var SessionWatch; raw: string): bool =
  ## One raw payload from the worker, before `WorkerBackend.deliver` sees it.
  ## Only DAP responses are of interest; bootstrap objects reach `noteControl`
  ## through `onControl`. Returns `noteResponse`'s answer.
  let trimmed = raw.strip()
  if not trimmed.startsWith("{"): return false
  # Cheap rejection before a parse: only a response can be an answer or a
  # refusal, and the rest of the opening's traffic (events) is not needed.
  if not trimmed.contains("\"response\""): return false
  var node: JsonNode
  try: node = parseJson(trimmed)
  except CatchableError: return false
  w.noteResponse(node)

func stage*(w: SessionWatch): OpeningStage =
  ## Where the opening is. A refusal outranks every other stage: it is the one
  ## thing the engine has SAID.
  if w.refusal.isSome: return osRefused
  if not w.wasmLoaded: return osEngineNotLoaded
  if not w.traceLoaded: return osDownloadingTrace
  if not w.workerReady and not w.wasSent("initialize"): return osStartingEngine
  if w.wasSent("launch") and not w.wasAnswered("launch"): return osOpeningTrace
  for c in OpeningCommands:
    if not w.wasAnswered(c): return osHandshaking
  osPositioning

const
  DownloadAndOpen* =
    "the container can still be downloaded and opened in CodeTracer."
    ## The ladder's floor, the same clause every one of these sentences ends on.
  DownloadAndOpenSentence* =
    "The container can still be downloaded and opened in CodeTracer."
    ## The same clause, starting a sentence.

func stepsPhrase(totalSteps: int): string =
  if totalSteps <= 0: "This recording"
  else: "This recording, " & insertSep($totalSteps, ',') & " steps,"

proc refusalSentence*(r: Refusal): string =
  ## The engine refused, and it gave a reason: show the reason.
  let what =
    if r.command == FirstRequestCommand:
      "The replay engine has no trace open: it refused the first request " &
        "made of it (`" & r.command & "`). The engine said: "
    else:
      "The replay engine refused to open this trace container. The engine " &
        "said (to `" & r.command & "`): "
  what & r.message.strip(chars = {' ', '.', '\n', '\r', '\t'}) & ". " &
    DownloadAndOpenSentence

proc refusalKind*(r: Refusal): DebuggerSessionErrorKind =
  ## The SDK's own classifier, over the engine's own response — the same call
  ## `DebuggerSession.launch` makes for a refusal it receives itself, so a
  ## refusal the page catches and one the session catches are classified alike.
  classifyBackendFailure(r.response)

proc deadlineVerdict*(w: SessionWatch; engineBase: string; deadlineMs: int;
                      totalSteps = 0): OpeningVerdict =
  ## What to say when the deadline passes with the session still not live.
  ##
  ## The kinds: an engine that was never reached is the transport
  ## (`classifyStartFailure(engineReached = false)`); a refusal is classified
  ## from the engine's response; everything else is work the engine had NOT
  ## finished when the page stopped waiting. Nothing failed there — no format
  ## was rejected — so it is not `UnsupportedTraceKind`, the inference this
  ## module exists to stop making (and which the SDK's
  ## `classifyStartFailure(engineReached = true)` made until codetracer
  ## corrected it to `Cancelled` in the same fix). §6.3's word for an
  ## operation the host abandoned is `Cancelled`.
  let secs = $(deadlineMs div 1000) & " s"
  result.stage = w.stage
  case result.stage
  of osEngineNotLoaded:
    result.kind = classifyStartFailure(engineReached = false)
    result.sentence = "The replay engine never loaded from " & engineBase &
      ". Nothing answered at that path, so no trace could be opened; " &
      DownloadAndOpen
  of osRefused:
    let r = w.refusal.get
    result.kind = r.refusalKind
    result.sentence = r.refusalSentence
  of osDownloadingTrace:
    result.kind = dseCancelled
    result.sentence = "The replay engine loaded, but the trace container had " &
      "not finished downloading after " & secs & ", so nothing was opened. " &
      DownloadAndOpenSentence
  of osStartingEngine:
    result.kind = dseCancelled
    result.sentence = "The replay engine loaded and received the trace " &
      "container, but its debugger had not started after " & secs & ". " &
      DownloadAndOpenSentence
  of osHandshaking:
    result.kind = dseCancelled
    result.sentence = "The replay engine loaded, but it had not answered the " &
      "debugger's opening requests after " & secs & ". " & DownloadAndOpenSentence
  of osOpeningTrace:
    result.kind = dseCancelled
    result.sentence = "The replay engine is still opening this trace: it " &
      "received the container and had not finished opening it after " & secs &
      ". Nothing was rejected. " & stepsPhrase(totalSteps) & " is too large " &
      "to open in the browser within the time allowed; " & DownloadAndOpen
  of osPositioning:
    result.kind = dseCancelled
    result.sentence = "The replay engine opened this trace but had not " &
      "answered the first request made of it after " & secs & ": it is still " &
      "working on this recording. " & stepsPhrase(totalSteps) & " is too " &
      "large to debug in the browser within the time allowed; " &
      DownloadAndOpen
