## The browser half of the replay transport: constructing the worker, getting
## the container's bytes into its VFS, and the three platform capabilities
## hydration needs beyond that.
##
## ## Why this file exists separately from `worker_backend.nim`
##
## CodeTracer's `WorkerBackendService` deliberately owns none of this. It takes
## a `postProc` and a `terminateProc` and never touches `std/jsffi`, never
## constructs a `Worker`, and never names an asset URL — which is what lets the
## same adapter be driven from a Node host in its own e2e suite and from a
## browser here. The transport is the consumer's, and this is BlockTracer's.
##
## ## Why the bytes never enter Nim
##
## `fetchIntoWorkerVfs` fetches the container and posts it to the worker
## **inside one JavaScript expression**. The `ArrayBuffer` is never converted to
## a `seq[byte]`, which is not a micro-optimisation: Debugger-Integration §7
## makes "main-thread blocking per navigation ≤ 16 ms" a hard rule and calls any
## operation that reads trace data on the main thread a defect, "however small;
## it will not be small on the transaction that matters". Marshalling a
## container into a Nim `seq` is exactly that operation, and it would be
## invisible at 144 KB and fatal at 144 MB.
##
## ## Everything here fails soft
##
## Not one of these procs raises. Page-Descriptions §7.0 requires that a
## hydration which cannot proceed leaves the served page standing, and an
## exception crossing the entry point would abandon the DOM in whatever state
## the previous step left it. So each reports its failure as a value and the
## caller decides — which is also what makes the capability ladder (§14.2) a
## set of enum values rather than a chain of `try` blocks.

when not defined(js):
  {.error: "engine_transport is the browser transport; it has no meaning " &
           "outside a `nim js` build.".}

# ---------------------------------------------------------------------------
# §14.2 — the capability ladder's detection half
# ---------------------------------------------------------------------------

type
  EngineCapability* = enum
    ## Why the replay engine can or cannot be run in THIS browser.
    ##
    ## Page-Descriptions §14.2 gives four distinct detections and insists "each
    ## has a specific cause and none should surface as a generic error". An
    ## enum, because §14's closing rule is that every degraded state is "a value
    ## of an enum on a ViewModel, not a branch in a view".
    ##
    ## Two of §14.2's four rows are deliberately NOT here. "Insufficient
    ## memory" is not detectable in advance — it is an allocation failure the
    ## worker reports, so it arrives as a `worker-error` and is handled where
    ## errors are. "Range requests broken or intercepted" cannot arise on this
    ## route at all: the container is fetched whole (§5.1's own note that a
    ## same-origin `fetch` of a 144 KB artifact needs no range machinery), so
    ## there is no `206` to be denied. Listing either here would be a check
    ## that cannot fail, which this project has already found five of.
    ecReady
      ## Everything the engine needs is present.
    ecNoWasm
      ## No `WebAssembly`, or no `compileStreaming` on it.
    ecNoWorker
      ## No `Worker` constructor — "worker behaviour unsupported", §14.2's
      ## "straight to the ladder" row.

proc hasWasm(): bool {.importjs: """
(typeof WebAssembly === 'object' &&
 typeof WebAssembly.compileStreaming === 'function' &&
 typeof WebAssembly.instantiate === 'function')
""".}

proc hasWorker(): bool {.importjs: "(typeof Worker === 'function')".}

proc detectCapability*(): EngineCapability =
  ## Feature detection, before anything is fetched.
  ##
  ## Ordered so the answer names the FIRST thing missing rather than the last
  ## thing checked, because the response the ladder gives a visitor is a
  ## sentence about their browser and "no WebAssembly" is a truer sentence than
  ## "no workers" for a browser that has neither.
  if not hasWasm(): ecNoWasm
  elif not hasWorker(): ecNoWorker
  else: ecReady

func capabilityReason*(c: EngineCapability): string =
  ## What a control says instead of "inert until the replay engine loads".
  ##
  ## The distinction that matters: the served page's inert buttons are waiting
  ## for something that is coming. These are not — so the sentence has to stop
  ## implying a wait, and must not offer a retry, because §14's own row for the
  ## permanently unreplayable is "a terminal state with a reason, never a retry
  ## that cannot succeed". Each names the ladder's surviving rungs, which are
  ## on this page already: the container download, and the desktop application.
  case c
  of ecReady: ""
  of ecNoWasm:
    "This browser cannot run WebAssembly, so the replay engine cannot start. " &
    "The trace container can still be downloaded and opened in CodeTracer."
  of ecNoWorker:
    "This browser does not support the workers the replay engine runs in. " &
    "The trace container can still be downloaded and opened in CodeTracer."

# ---------------------------------------------------------------------------
# The worker
# ---------------------------------------------------------------------------

proc startWorkerImpl(url: cstring; onMessage: proc(raw: cstring)): bool {.importjs: """
(function(u, cb){
  try {
    var w = new Worker(u, { type: 'module' });
    globalThis.__btReplayWorker = w;
    w.onmessage = function(e){
      var d = e.data;
      cb(typeof d === 'string' ? d : JSON.stringify(d));
    };
    w.onerror = function(err){
      // A module worker whose script 404s reports an ErrorEvent with an EMPTY
      // `message`, so `String(err)` is "[object Event]" — a sentence that
      // names nothing and is put in front of a visitor. The URL is the fact
      // that matters (it is almost always a missing or misconfigured
      // `replayEngineBase`), so it is what the message carries when the event
      // has nothing of its own.
      var detail = (err && (err.message || err.stack)) || '';
      cb(JSON.stringify({ type: 'worker-error',
                          error: detail ? String(detail)
                                        : 'the worker script at ' + u +
                                          ' could not be loaded' }));
    };
    return true;
  } catch (err) {
    // The §5.1 failure that matters: `new Worker` on a cross-origin URL throws
    // a bare SecurityError. It is reported through the SAME channel as every
    // other worker failure so the caller has one place to handle it, and it
    // NAMES the URL, because "which origin did this build try" is the first
    // question a misconfigured deploy raises.
    cb(JSON.stringify({ type: 'worker-error',
                        error: 'could not construct a worker from ' + u + ': ' +
                               String((err && err.message) || err) }));
    return false;
  }
})(#, #)
""".}

proc startWorker*(url: string; onMessage: proc(raw: string)): bool =
  ## Construct the replay worker and route everything it says to `onMessage`.
  ##
  ## Messages arrive as TEXT whether the worker posted a string or a structured
  ## clone, because `WorkerBackend.deliver` takes text either way and
  ## classifying the two shapes twice is how they come to disagree. The bare
  ## `"ready"` token the engine emits from `wasm_start()` is a string; every
  ## bootstrap message and every DAP frame is an object.
  ##
  ## `type: 'module'` because the published `worker.js` is an ES module — it
  ## `import`s `./pkg/db_backend.js` and resolves the wasm against
  ## `import.meta.url`, which is what makes the worker's own URL the asset base
  ## and why `ReplayEngineBase` needs to name a directory rather than a file.
  ##
  ## Returns `false` only for a synchronous construction failure; an
  ## asynchronous one arrives on `onMessage` as a `worker-error`. The caller
  ## must handle both, and treating either as fatal is correct — there is no
  ## partial success here.
  startWorkerImpl(url.cstring, proc(raw: cstring) = onMessage($raw))

proc postJsonImpl(json: cstring) {.importjs: """
(function(s){
  var w = globalThis.__btReplayWorker;
  if (!w) return;
  try { w.postMessage(JSON.parse(s)); } catch (e) { /* the backend fails it */ }
})(#)
""".}

proc postJson*(json: string) =
  ## Post one already-serialised message, as the structured-clone OBJECT the
  ## worker expects.
  ##
  ## The `JSON.parse` is the contract `WorkerBackend`'s own doc comment states:
  ## "The transport is responsible for parsing it back into an object before
  ## `postMessage` — the worker expects a structured-clone object, not a
  ## string." Posting the text would be accepted by `postMessage` and ignored
  ## by the engine, which is the worst available failure: no error, no
  ## response, and a session that hangs in `opening` forever.
  postJsonImpl(json.cstring)

proc postVfsWriteImpl(path: cstring; text: cstring) {.importjs: """
(function(p, t){
  var w = globalThis.__btReplayWorker;
  if (!w) return;
  try {
    w.postMessage({ type: 'vfs-write', path: p,
                    data: new TextEncoder().encode(t) });
  } catch (e) { /* the ack never arrives and the caller reports it */ }
})(#, #)
""".}

proc postVfsWrite*(path, text: string) =
  ## Put one file of the recording's own source into the engine's VFS.
  ##
  ## ## Why this cannot go through `postJson`
  ##
  ## `vfs-write` carries BYTES: the worker hands `msg.data` straight to
  ## `vfs_write_file`, whose wasm-bindgen signature takes a `&[u8]`, so the
  ## payload has to be a `Uint8Array` and JSON has no way to spell one.
  ## `postJson` is `JSON.parse`-then-`postMessage` by construction, so the
  ## array would arrive as an object with numeric keys and the write would
  ## either throw or store something that is not the file.
  ##
  ## ## Why it must be sent BEFORE `start`
  ##
  ## `vfs-write` is handled by the worker's PRE-START dispatcher; `wasm_start()`
  ## replaces `self.onmessage` with the DAP one, after which this message has no
  ## handler at all and is dropped in silence. Ordering is safe without waiting
  ## for the acks: `postMessage` delivery is ordered and the worker's write arm
  ## has no `await` ahead of the write itself.
  postVfsWriteImpl(path.cstring, text.cstring)

proc terminateWorkerImpl() {.importjs: """
(function(){
  var w = globalThis.__btReplayWorker;
  if (w) { try { w.terminate(); } catch (e) {} }
  globalThis.__btReplayWorker = undefined;
})()
""".}

proc terminateWorker*() =
  ## Tear the worker down. `WorkerBackend.disconnect` calls this.
  ##
  ## An ordinary Nim proc wrapping the `importjs` one, and the wrapper is not
  ## decoration: an `importjs` proc is INLINED at each call site and has no
  ## function object, so passing one as a value — which is exactly what
  ## `newWorkerBackend(terminateProc = …)` does — emits a `.bind` on
  ## `undefined`. It compiles, and it throws at run time with a message that
  ## names neither this file nor the reason. It did, and the whole engine path
  ## was dead behind it while the page looked perfectly correct, because §7.0's
  ## guarantee had held and left the served frame standing.
  terminateWorkerImpl()

# ---------------------------------------------------------------------------
# The container
# ---------------------------------------------------------------------------

proc absoluteUrlImpl(path: cstring): cstring {.importjs:
  "(new URL(#, location.href).href)".}

proc absoluteUrl*(path: string): string =
  ## A site-root path (`/d/…/trace.ct`) as an absolute URL.
  ##
  ## The container is fetched **by the worker**, and a worker resolves a
  ## relative URL against its own script — which lives under
  ## `ReplayEngineBase`, not at the site root. A same-origin path that is
  ## correct in the document would therefore be fetched from inside the engine
  ## directory and 404. Resolving here, against `location.href`, is the one
  ## place that knows which origin the page is actually on, which is also what
  ## makes this work unchanged on a preview deployment.
  $absoluteUrlImpl(path.cstring)

func loadTraceMessage*(url, vfsPath: string): string =
  ## The worker's `load-trace` message: fetch this URL, write it there.
  ##
  ## ## Why the WORKER fetches, and not this thread
  ##
  ## Debugger-Integration §7 makes "main-thread blocking per navigation ≤ 16
  ## ms" a hard rule and calls any operation that reads trace data on the main
  ## thread a defect, "however small; it will not be small on the transaction
  ## that matters". The published worker already carries a plain-`fetch`
  ## static-server path, so the container's bytes never have to touch this
  ## thread at all — not as an `ArrayBuffer`, not as a transfer, and certainly
  ## not as a Nim `seq[byte]`. The main thread posts a URL and gets back a
  ## `trace-loaded`.
  ##
  ## ## Why not range requests
  ##
  ## Debugger-Integration §2 attaches a `RangeStoreSource`, and §14.2 has a row
  ## for an intermediary that answers `200` where a `206` was asked for. Both
  ## are about a container large enough that fetching it whole is the wrong
  ## trade. This one is 144 KB, served by a static file host, and §7's budget
  ## is "bytes fetched before first step ≤ 256 KB" — the whole file is inside
  ## the budget. Range machinery here would be a mechanism with no failure it
  ## could save us from and one (§14.2's hostile intermediary) it would invent.
  ##
  ## Built as text and posted through `postJson`, so this one message goes over
  ## the same `JSON.parse`-then-`postMessage` path as every other and cannot
  ## acquire a second serialisation convention.
  ##
  ## Hand-built rather than `%*`-built so this module needs no `std/json`: it
  ## is the transport, and the only structure it has an opinion about is this.
  ## The two interpolations are a URL this code constructed and a compile-time
  ## constant, neither of which can carry a quote.
  "{\"type\":\"load-trace\",\"files\":[{\"url\":\"" & url &
    "\",\"vfsPath\":\"" & vfsPath & "\"}]}"

# ---------------------------------------------------------------------------
# The two page-level capabilities hydration adds
# ---------------------------------------------------------------------------

proc writeClipboardImpl(text: cstring; onDone: proc(ok: bool)) {.importjs: """
(function(t, cb){
  if (!navigator.clipboard || !navigator.clipboard.writeText) { cb(false); return; }
  navigator.clipboard.writeText(t).then(function(){ cb(true); },
                                        function(){ cb(false); });
})(#, #)
""".}

proc writeClipboard*(text: string; onDone: proc(ok: bool)) =
  ## §13's "one-click copy button [that] arrives with hydration".
  ##
  ## The failure path is a value, not an exception, and the caller must show
  ## it: `writeText` rejects in a non-secure context and when the document is
  ## not focused, and a copy button that silently did nothing would be the
  ## affordance-that-lies defect wearing a tick.
  writeClipboardImpl(text.cstring, onDone)

proc hasClipboard*(): bool {.importjs: """
(typeof navigator === 'object' && !!navigator.clipboard &&
 typeof navigator.clipboard.writeText === 'function')
""".}
  ## Whether a copy BUTTON may be offered at all.
  ##
  ## Checked before any is rendered, not after one is clicked. §13's staging is
  ## that the pre-hydration affordance is `user-select: all` and the button
  ## "arrives with hydration" — in a browser with no clipboard API it does not
  ## arrive, the `user-select` affordance stays, and the visitor keeps the one
  ## gesture that works. Adding a button first and discovering it cannot write
  ## is how a page comes to ship a control that cannot succeed.

proc afterMsImpl(ms: int; cb: proc()) {.importjs:
  "(function(m, f){ return setTimeout(f, m); })(#, #)".}
  ## A wrapper rather than `setTimeout(#2, #1)`: positional placeholders are
  ## not substituted the way sequential `#` is, and the emitted call referred to
  ## a Nim parameter name that does not exist in the output. It compiles, and it
  ## throws `ms_p0 is not defined` at run time — before the worker is even
  ## constructed, so the symptom is a page that never leaves `fetching`.

proc afterMs*(ms: int; cb: proc()) =
  ## Run `cb` once, `ms` from now.
  ##
  ## Exists for one caller — the watchdog that decides the engine is not
  ## coming. Nothing else here waits on a clock: every other transition is
  ## driven by a message the worker actually sent, which is the right way round.
  afterMsImpl(ms, cb)

proc onNextFrameImpl(cb: proc()) {.importjs:
  "(function(f){ return requestAnimationFrame(f); })(#)".}
  ## Wrapped for `afterMsImpl`'s reason, and read that comment before changing
  ## the spelling: a bare `requestAnimationFrame(#)` emits a call against a Nim
  ## parameter name that does not exist in the output.

proc onNextFrame*(cb: proc()) =
  ## Run `cb` before the browser's next paint.
  ##
  ## The one clock in this file that is not a watchdog, and it is deliberately
  ## the browser's own rather than a millisecond count. What it buys is that
  ## several writes arriving inside one frame produce ONE paint: the last one
  ## wins and the intermediate states are never shown, because they are gone
  ## before the compositor looks. A `setTimeout(0)` would coalesce the same
  ## callbacks and would still be a guess about when the frame is.
  onNextFrameImpl(cb)

proc replaceQueryImpl(query: cstring) {.importjs: """
(function(q){
  try { history.replaceState(history.state, '', q); } catch (e) {}
})(#)
""".}

proc locationSearchImpl(): cstring {.importjs: "(location.search || '')".}
proc locationHashImpl(): cstring {.importjs: "(location.hash || '')".}

proc linkPayload*(): string =
  ## The §6.0a payload this page was opened with — the query if it carries one,
  ## else the fragment.
  ##
  ## Both, because the payload is written in both places and a reader pastes
  ## whichever they were given. §6's URL form puts it in the fragment;
  ## Page-Descriptions §8 and Configuration.md put `t` in the query, and the
  ## query is what this page's own Share control and its `replaceState` write.
  ## The grammar is identical and the SDK's parser takes either, so the only
  ## decision here is precedence, and the query wins because it is the form
  ## this product emits — a URL carrying both is one where the fragment is the
  ## older half.
  ##
  ## A fragment that is a bare element id (`#L-src-shield-nr-32`, which every
  ## share link also carries) contains no `=` and parses to nothing, which the
  ## caller reads as "no link asked for a position". That is the correct
  ## answer: the id scrolls, it does not position.
  let q = $locationSearchImpl()
  if q.len > 1: q else: $locationHashImpl()

proc replaceQuery*(query: string) =
  ## Debugger-Integration §6.3: "`t` updates on **every** navigation via
  ## `history.replaceState`, so the back button stays a page-level control
  ## rather than a step-level undo."
  ##
  ## `replaceState` and never `pushState` — that is the whole of the rule. A
  ## thousand steps through a trace would otherwise put a thousand entries in
  ## the visitor's history and make Back mean "one step earlier in the
  ## execution", which is a meaning the toolbar already has a button for.
  replaceQueryImpl(query.cstring)
