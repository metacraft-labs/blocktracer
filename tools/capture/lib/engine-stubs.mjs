// The three ways the replay engine can fail to run, as things the CAPTURE
// SERVER does — never as files in `dist/`, and never as a branch in the
// product.
//
// ── Why this file exists ────────────────────────────────────────────────────
//
// `hydrate.markUnavailable` has three sentences and each names a different
// fault with a different fix. They are separated at their source because one
// sentence covering two of them "sent a real diagnosis down the wrong path for
// hours" (client/hydrate/hydrate.nim). Until VD.7 not one of the three had ever
// been rendered by anything: they are hydration-only, and every capture was
// taken against a build compiled with no `-d:hydrationBundle`. The separation
// was being defended by an argument about text nobody had looked at.
//
// All three are INDUCIBLE without touching the product, because all three are
// facts about what answers at `ReplayEngineBase`. This repository vendors no
// engine — `client/Justfile`'s `replay-engine` target fetches 18 MB of another
// repository's build output, deliberately uncommitted — so a served `dist/` has
// nothing at `/replay-engine/` at all, and the capture server is already the
// only thing that decides what is there. Each scenario below is one answer.
//
// ── Why a stub is not a mock of the sentence ────────────────────────────────
//
// The distinction that matters for a review: NOTHING here draws anything. The
// banner a reviewer grades is produced by `components/debugger.renderEngineFailure`
// from a string written in `hydrate.nim`, running in the real hydration bundle,
// on the page the real exporter wrote. What is substituted is the ENGINE — the
// 18 MB wasm worker whose absence, silence or refusal is the subject of the
// image. Substituting it is not staging the screenshot; it is the only way to
// take one, short of publishing a deliberately broken engine.
//
// Every scenario states, in `impersonates`, what real-world fault it stands in
// for and where that fault is documented. `views.mjs` puts the same statement
// in the view's description and `expectations.mjs` in the block a reviewer
// reads, so nobody grades one of these believing a real engine produced it.
//
// ── The worker contract these stubs implement ──────────────────────────────
//
// `engine_transport.startWorkerImpl` constructs `new Worker(url, {type:'module'})`,
// so each body below is an ES module. The only message the bootstrap cares
// about before a trace is loaded is `{"type":"wasm-loaded"}`, which
// `hydrate.onControl` answers by posting the container's URL into the worker's
// VFS — and which sets `h.engineLoaded`, the discriminator between the two
// deadline sentences.

/** `/replay-engine/worker.js`, as `replay_engine.ReplayEngineBase` names it. */
export const WORKER_PATH = "/replay-engine/worker.js";

const JS = "text/javascript; charset=utf-8";

const SILENT_BODY = `// capture harness (tools/capture/lib/engine-stubs.mjs) — NOT the replay engine.
// A worker that loads and never answers. Stands in for the 18 MB wasm engine
// during the window before it has compiled anything.
self.onmessage = function () {};
`;

// The two stubs below speak the worker's real protocol: `load-trace` is
// answered `trace-loaded`, `start` is answered with the bare string `ready`
// (as `wasm_start()` posts it), and DAP requests are answered with JSON
// STRINGS, as the engine posts them. Everything they say about the handshake
// is copied from the pinned engine rather than imagined — see each one.
const PROTOCOL_PRELUDE = `
const answer = (req, success, message) => self.postMessage(JSON.stringify({
  seq: 0, type: 'response', request_seq: req.seq, success, command: req.command,
  message: message === undefined ? null : message, body: {},
}));
let started = false;
self.onmessage = (event) => {
  const m = event.data;
  if (!started) {
    if (m && m.type === 'load-trace') {
      self.postMessage({ type: 'trace-loaded', files: m.files || [], manifestStatus: 0, rangeStatuses: [] });
    } else if (m && m.type === 'vfs-write') {
      self.postMessage({ type: 'vfs-ack', path: m.path, ok: true });
    } else if (m && m.type === 'start') {
      started = true;
      self.postMessage('ready');
    }
    return;
  }
  if (!m || m.type !== 'request') return;
  onRequest(m);
};
self.postMessage({ type: 'wasm-loaded' });
`;

// The pinned engine's refusal, VERBATIM. Measured 2026-11-26 by driving the
// pinned wasm (`d696b18d…`, client/hydrate/engine-pin.txt) over its real worker
// in the SDK's handshake order with a `meta.dat` 6 container: it answers
// `initialize` and `configurationDone`, answers `launch` with success and then
// AGAIN, same `request_seq`, with the failure below; every later request is
// refused "no trace is open". It does NOT post nothing — the stub this replaced
// said it did, and the page's sentence for it ("rejected the container's
// format", reached only by a 45 s deadline) was built on that.
const PINNED_REFUSAL =
  'handle_message_browser failed: CTFS from_bytes failed for "trace/trace.ct": ' +
  'meta.dat is malformed: meta.dat: version 6 is not readable: this reader reads ' +
  'version 7 only. Version 5 and below carry a path list after recorder_id that ' +
  'version 7 does not, and version 6 predates the event kinds 14-23, so none of ' +
  'them is read as version 7. Re-record the trace with a current recorder';

const REFUSING_BODY = `// capture harness (tools/capture/lib/engine-stubs.mjs) — NOT the replay engine.
// Replays what the PINNED engine posts for a container it cannot read.
${PROTOCOL_PRELUDE}
function onRequest(req) {
  if (req.command === 'initialize') {
    answer(req, true);
    self.postMessage(JSON.stringify({ seq: 0, type: 'event', event: 'initialized', body: {} }));
  } else if (req.command === 'configurationDone') {
    answer(req, true);
  } else if (req.command === 'launch') {
    answer(req, true);
    answer(req, false, ${JSON.stringify(PINNED_REFUSAL)});
  } else {
    answer(req, false, 'no trace is open: \`' + req.command + '\` cannot be serviced');
  }
}
`;

// An engine still opening the trace. Measured on the pinned engine with a
// 673,363-step EVM recording: the container loads in 0.6 s, the handshake's
// first two requests are answered, and `launch` is not answered in 902 s.
// Reproducing that with the real engine needs a recording no fixture should
// carry, so this stub answers exactly those two requests and then nothing.
const OPENING_BODY = `// capture harness (tools/capture/lib/engine-stubs.mjs) — NOT the replay engine.
// An engine that accepts the container and is still opening it.
${PROTOCOL_PRELUDE}
function onRequest(req) {
  if (req.command === 'initialize') {
    answer(req, true);
    self.postMessage(JSON.stringify({ seq: 0, type: 'event', event: 'initialized', body: {} }));
  } else if (req.command === 'configurationDone') {
    answer(req, true);
  }
  // \`launch\`, and anything after it: no answer — the engine is still working.
}
`;

export const ENGINE_SCENARIOS = {
  // The state every page is in for the first seconds of a real load, and the
  // one the §6.0a landing views are captured in: the link has been resolved
  // (that happens before a byte of the engine is fetched) and the engine has
  // not answered yet, so the phase rail still says what the served page said.
  //
  // Advanced past `EngineDeadlineMs` it becomes the second deadline sentence,
  // because `engineLoaded` is still false.
  silent: {
    id: "silent",
    label: "an engine that loads and never answers",
    impersonates:
      "the ordinary pre-engine window of a real load, and — past the 45 s " +
      "deadline — a misconfigured or missing `replayEngineBase` whose path " +
      "serves something that is not the engine",
    overlay: { [WORKER_PATH]: { type: JS, body: SILENT_BODY } },
  },

  // Nothing at the path at all. `new Worker` succeeds, the module 404s, and the
  // ErrorEvent carries an empty `message` — which is the case
  // `startWorkerImpl`'s `onerror` writes its own sentence for, because
  // `String(err)` would put "[object Event]" in front of a visitor.
  unreachable: {
    id: "unreachable",
    label: "nothing served at the engine's path",
    impersonates:
      "a deploy that never copied the engine to its own origin — the state " +
      "every build of this repository is in until `just replay-engine` runs",
    overlay: { [WORKER_PATH]: null },
  },

  // The engine is present, reachable and running; it is the CONTAINER it will
  // not open, and it says why. The page must report that reason when it
  // arrives — not wait out a deadline and guess.
  refusing: {
    id: "refusing",
    label: "an engine that loads, reports itself, and refuses the container",
    impersonates:
      "the pinned engine given a container its reader does not accept (a " +
      "`meta.dat` 6 recording): it answers `launch` with success and then with " +
      "the refusal, verbatim from the pinned wasm — the stub replays that transcript",
    overlay: { [WORKER_PATH]: { type: JS, body: REFUSING_BODY } },
  },

  // The engine accepted the container and has not finished opening it when
  // the page stops waiting. Not a refusal, and the page must not call it one.
  opening: {
    id: "opening",
    label: "an engine still opening the trace when the deadline passes",
    impersonates:
      "the pinned engine given a recording too large to open in the time " +
      "allowed (a 673,363-step EVM transaction): `initialize` and " +
      "`configurationDone` answered, `launch` never answered",
    overlay: { [WORKER_PATH]: { type: JS, body: OPENING_BODY } },
  },
};

export const ENGINE_SCENARIO_IDS = Object.keys(ENGINE_SCENARIOS);

export function engineScenario(id) {
  const s = ENGINE_SCENARIOS[id];
  if (!s) {
    throw new Error(
      `unknown engine scenario '${id}' (have: ${ENGINE_SCENARIO_IDS.join(", ")})`,
    );
  }
  return s;
}

/** What the manifest records, so an image's provenance includes its engine. */
export function describeScenarios() {
  return Object.fromEntries(
    Object.entries(ENGINE_SCENARIOS).map(([id, s]) => [
      id,
      { label: s.label, impersonates: s.impersonates, servedAt: WORKER_PATH },
    ]),
  );
}
