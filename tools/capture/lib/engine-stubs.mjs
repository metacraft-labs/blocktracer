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

const REFUSING_BODY = `// capture harness (tools/capture/lib/engine-stubs.mjs) — NOT the replay engine.
// A worker that compiles its engine, says so, and then answers nothing —
// which is what the deployed engine does when it refuses a container's format:
// it logs the refusal to the WORKER's console and posts no message at all
// (client/hydrate/hydrate.nim, the deadline's comment).
self.postMessage({ type: 'wasm-loaded' });
self.onmessage = function () {};
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

  // The fault that cost the hours. The engine is present, reachable and
  // running; it is the CONTAINER it will not open.
  refusing: {
    id: "refusing",
    label: "an engine that loads, reports itself, and refuses the container",
    impersonates:
      "a published engine whose container-format reader does not accept this " +
      "trace — it logs the refusal to the worker console and posts nothing, so " +
      "the session sits in `positioning` until the deadline",
    overlay: { [WORKER_PATH]: { type: JS, body: REFUSING_BODY } },
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
