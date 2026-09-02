// origin-probe.mjs — DOES THE ENGINE CLASSIFY A HOP?
//
// Not a journey. A single measurement, taken against the REAL published
// replay engine and a REAL container from this repository's own corpus, to
// answer the one question that decides whether a value-origin surface can
// exist here at all:
//
//   when BlockTracer asks `ct/originChain` for a local, does the reply carry a
//   hop that was actually CLASSIFIED — or one that says `kind: "unknown"`,
//   `confidence: 0`, `classificationProvenance: "built-in: source unavailable"`?
//
// The second is what the engine answered before the VFS-source fix landed in
// CodeTracer (`b9cd4157`), and a chain of `success: true` carrying it is the
// false pass this probe exists to exclude. So the probe reports the hop's
// fields verbatim rather than reporting that the call succeeded.
//
// Usage:  node tools/journeys/origin-probe.mjs [--dist client/dist] [--write-source]
//
// `--write-source` additionally pushes the container's own source text into
// the engine's VFS over the worker's `vfs-write` channel before asking, which
// is the arm that separates "the engine cannot classify" from "the engine was
// never given the source".

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { join, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

const HERE = dirname(fileURLToPath(import.meta.url));
const REPO = join(HERE, "..", "..");
const require = createRequire(join(REPO, "tools", "capture", "package.json"));
const { chromium } = require("playwright");

const args = process.argv.slice(2);
const distArg = args.indexOf("--dist");
const DIST = join(REPO, distArg >= 0 ? args[distArg + 1] : "client/dist");
const WRITE_SOURCE = args.includes("--write-source");
const pageArg = args.indexOf("--page");

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".wasm": "application/wasm",
  ".ct": "application/octet-stream",
  ".svg": "image/svg+xml",
  ".woff2": "font/woff2",
};

async function serve(root) {
  const server = createServer(async (req, res) => {
    try {
      let p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      let f = join(root, p);
      try {
        if ((await stat(f)).isDirectory()) f = join(f, "index.html");
      } catch {
        if (!extname(f)) f = join(root, p, "index.html");
      }
      const body = await readFile(f);
      res.writeHead(200, {
        "content-type": MIME[extname(f)] ?? "application/octet-stream",
        // The worker is a module worker on this origin; no COOP/COEP needed
        // for the plain (non-threaded) wasm build.
        "cache-control": "no-store",
      });
      res.end(body);
    } catch {
      res.writeHead(404, { "content-type": "text/plain" });
      res.end("not found");
    }
  });
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  return { server, origin: `http://127.0.0.1:${server.address().port}` };
}

/**
 * Drive the replay worker through BlockTracer's own bootstrap and handshake,
 * then ask for locals and an origin chain. Runs INSIDE the page so the worker
 * is same-origin, which §5.1 requires.
 */
const DRIVE = async ({ tracePath, writeSource, sources }) => {
  // One self-contained function: `page.evaluate` serialises THIS function and
  // nothing else, so a helper declared beside it in this module is not defined
  // inside the page. Everything the drive needs lives in here.
  const log = [];
  try {
    return await (async () => {
  const worker = new Worker("/replay-engine/worker.js", { type: "module" });
  let seq = 1;
  const pending = new Map();
  const events = [];
  const control = [];
  const waiters = [];

  worker.onmessage = (e) => {
    // THREE INBOUND SHAPES, and only one of them is an object.
    // `worker_backend.nim:222` (`deliver`) is explicit: the worker produces
    // "a DAP JSON string, a bootstrap control object, and the bare `ready`
    // token". So DAP responses and events arrive as TEXT and must be parsed
    // here; a probe that only inspected `e.data.type` sees `undefined` on
    // every response and waits out its timeout against a working engine.
    let m = e.data;
    if (typeof m === "string") {
      const t = m.trim();
      if (t.startsWith("{") || t.startsWith("[")) {
        try {
          m = JSON.parse(t);
        } catch {
          // leave as the string; it is control traffic
        }
      }
    }
    if (m && m.type === "response") {
      const r = pending.get(m.request_seq);
      if (r) {
        pending.delete(m.request_seq);
        r(m);
      }
      return;
    }
    if (m && m.type === "event") {
      events.push(m);
      return;
    }
    control.push(m);
    for (const w of waiters.slice()) {
      if (w.match(m)) {
        waiters.splice(waiters.indexOf(w), 1);
        w.resolve(m);
      }
    }
  };
  worker.onerror = (e) =>
    log.push(
      `WORKER ERROR: ${e.message ?? e} @ ${e.filename ?? "?"}:${e.lineno ?? "?"} — ` +
        `a module worker whose script or wasm 404s reports here and nowhere else`,
    );
  worker.onmessageerror = (e) => log.push(`worker message error: ${String(e)}`);

  const awaitControl = (match, ms = 60000) =>
    new Promise((resolve, reject) => {
      const hit = control.find(match);
      if (hit) return resolve(hit);
      const w = { match, resolve };
      waiters.push(w);
      setTimeout(
        () =>
          reject(
            new Error(
              `timeout waiting for a control message; saw ${JSON.stringify(
                control.map((c) => (c && c.type) || String(c)),
              )}; log=${JSON.stringify(log)}`,
            ),
          ),
        ms,
      );
    });

  const send = (command, args_) =>
    new Promise((resolve, reject) => {
      const s = seq++;
      pending.set(s, resolve);
      setTimeout(() => {
        if (pending.has(s)) {
          pending.delete(s);
          reject(new Error(`timeout on ${command}`));
        }
      }, 60000);
      worker.postMessage({ seq: s, type: "request", command, arguments: args_ ?? {} });
    });

  // ── bootstrap: exactly hydrate.nim's onControl sequence ──
  await awaitControl((m) => m && m.type === "wasm-loaded");
  log.push("wasm-loaded");

  worker.postMessage({
    type: "load-trace",
    files: [{ url: new URL(tracePath, location.href).href, vfsPath: "trace/trace.ct" }],
  });
  const loaded = await awaitControl(
    (m) => m && (m.type === "trace-loaded" || m.type === "trace-load-error"),
  );
  if (loaded.type === "trace-load-error") return { ok: false, log, error: loaded.error };
  log.push(`trace-loaded ${JSON.stringify(loaded.files)}`);

  // THE ARM. Push the recording's own source text into the engine's VFS at the
  // recorded paths, which is what `b9cd4157` made ExprLoader able to read.
  let wrote = 0;
  if (writeSource) {
    for (const [p, text] of Object.entries(sources)) {
      worker.postMessage({ type: "vfs-write", path: p, data: new TextEncoder().encode(text) });
      const ack = await awaitControl((m) => m && m.type === "vfs-ack" && m.path === p);
      if (ack.ok) wrote += 1;
      else log.push(`vfs-write REFUSED ${p}: ${ack.error}`);
    }
    log.push(`vfs-write: ${wrote}/${Object.keys(sources).length} source files accepted`);
  }

      worker.postMessage({ type: "start" });
      // The RAW worker posts the BARE STRING "ready" — not an object, and not
      // `{type: "worker-status"}`, which is the SDK's own re-spelling of it
      // (`worker_backend.nim:233` wraps a trimmed string message). A probe
      // that speaks to the worker directly has to match the string, and this
      // is worth a comment because both wrong guesses fail identically: the
      // worker is up and answering, and the wait never returns.
      await awaitControl(
        (m) =>
          m === "ready" ||
          (m && (m.type === "ready" || (m.type === "worker-status" && m.status === "ready"))),
      );
      log.push("worker ready");

  // ── DAP handshake: hydrate.nim's order ──
  const init = await send("initialize", {
    clientID: "blocktracer-origin-probe",
    adapterID: "codetracer",
    supportsProgressReporting: false,
  });
  if (!init.success) return { ok: false, log, error: `initialize: ${init.message}` };
  const launch = await send("launch", { traceFolder: "trace" });
  if (!launch.success) return { ok: false, log, error: `launch: ${launch.message}` };
  await send("configurationDone", {});
  await send("threads", {});
  log.push("handshake complete");

  // Where are we, and what is on the stack.
  const stack = await send("stackTrace", { threadId: 1 });
  const frames = stack?.body?.stackFrames ?? [];
  const top = frames[0] ?? null;
  log.push(`stackTrace: ${frames.length} frames, top=${JSON.stringify(top)}`);

  // Step forward a little: the entry frame often has nothing assigned yet, and
  // an origin chain for a value that has not been written is legitimately
  // empty — which would be an absence caused by the position, not by the
  // engine, and would read as the same "0 classified" verdict.
  // The tick is NOT on a DAP stack frame — `ct/complete-move` is where the
  // engine states it (`hydrate.nim:581-584` records that inventing a zero here
  // was a real defect). So track it off the event stream and ask AT it.
  // The tick is on the event's `location`, NOT at the body's top level:
  // `ct/complete-move`'s body is `{location: {..., rrTicks}, cLocation: {...}}`
  // and `cLocation.rrTicks` is a zero placeholder. Reading the top level finds
  // nothing, silently yields 0, and every question then gets asked at the
  // start of the recording — where the honest answer is `recordingStart` with
  // no hops, which reads exactly like "the engine cannot classify".
  const tickNow = () => {
    for (let k = events.length - 1; k >= 0; k--) {
      const b = events[k]?.body ?? {};
      const t = b.location?.rrTicks ?? b.rrTicks ?? b.ticks;
      if (typeof t === "number" && t > 0) return t;
    }
    return 0;
  };

  // STEP PAST THE PARAMETERS.
  //
  // The first position that has any locals at all has only `main`'s
  // PARAMETERS, and a parameter has no assignment whose right-hand side the
  // §6.1 classifier could parse — "unknown" is very nearly the correct answer
  // for one. Stopping there and reporting "0 classified" would blame the
  // engine for a property of the subject. So the walk continues past the
  // signature to the `let` bindings (`did_survive_positive` at main.nr:15,
  // `did_survive_negative` at :27, each assigned from a call) and asks about
  // whatever is live at the deepest position reached.
  // 14 steps: `main` is 38 lines and the walk reaches its last statement in
  // about a dozen `next`es. Past that the cursor wraps back to line 1 and the
  // positions stop being new, so a longer walk only adds duplicates.
  const positions = [];
  for (let i = 0; i < 14; i++) {
    const st = await send("stackTrace", { threadId: 1 });
    const f = st?.body?.stackFrames?.[0];
    // THE FULL `CtLoadLocalsArguments` SET. `requestLocals`
    // (`store/replay_data_store.nim:628-663`) defaults countBudget=3000,
    // minCountLimit=50, depthLimit=7, lang=0, and the engine reads them.
    // Asking with the budgets absent is asking for a budget of zero, which
    // answers `success: true` with an EMPTY locals array — a false "there are
    // no values here" indistinguishable from a position with nothing live.
    const locals = await send("ct/load-locals", {
      rrTicks: tickNow(),
      countBudget: 3000,
      minCountLimit: 50,
      depthLimit: 7,
      watchExpressions: [],
      lang: 0,
    });
    const rows = locals?.body?.locals ?? [];
    positions.push({
      i,
      tick: tickNow(),
      ok: locals?.success ?? null,
      msg: locals?.message ?? null,
      line: f?.line ?? null,
      path: f?.source?.path ?? null,
      localCount: rows.length,
      withSummary: rows.filter((r) => r.originSummary).length,
      names: rows.map((r) => r.expression),
      summaries: rows
        .filter((r) => r.originSummary)
        .map((r) => ({ name: r.expression, s: r.originSummary })),
    });
    await send("next", { threadId: 1 });
  }

  // The RICHEST position, not the first non-empty one: more names live means
  // the `let` bindings are in scope alongside the parameters.
  const best = positions.reduce(
    (a, b) => (b.localCount > (a?.localCount ?? -1) ? b : a),
    positions[0],
  );
  // Ask where the names came from at THAT position, not wherever the walk
  // happened to stop.
  await send("ct/load-locals", {
    rrTicks: best?.tick ?? 0,
    countBudget: 3000,
    minCountLimit: 50,
    depthLimit: 7,
    watchExpressions: [],
    lang: 0,
  });

  // ── THE MEASUREMENT ──
  const chains = [];
  for (const name of (best?.names ?? []).slice(0, 8)) {
    const st = await send("stackTrace", { threadId: 1 });
    const f = st?.body?.stackFrames?.[0];
    const r = await send("ct/originChain", {
      variableName: name,
      variablePath: [],
      frameId: f?.id ?? -1,
      // The step the name was READ at, so the engine resolves the origin from
      // that position rather than from wherever the walk left the cursor.
      stepId: best?.tick ?? -1,
      threadId: 1,
      maxHops: 32,
      lazy: false,
      sessionId: "",
      classifySource: true,
    });
    chains.push({ name, success: r.success, message: r.message ?? null, body: r.body ?? null });
  }

      return {
        ok: true,
        log,
        wrote,
        top,
        positions,
        best,
        chains,
        events: events.map((e) => e.event).slice(0, 40),
      };
    })();
  } catch (e) {
    // Never throw across the evaluate boundary: the bootstrap log is the whole
    // diagnosis when the worker does not come up, and a thrown error discards
    // it. A returned failure keeps what was observed up to the failure.
    return { ok: false, error: String(e && e.message ? e.message : e), log };
  }
};

const CLASSIFIED = (hop) =>
  hop &&
  hop.kind &&
  String(hop.kind).toLowerCase() !== "unknown" &&
  Number(hop.confidence ?? 0) > 0 &&
  !/source unavailable/i.test(String(hop.classificationProvenance ?? ""));

async function main() {
  const { server, origin } = await serve(DIST);
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    page.on("console", (m) => console.log(`  [page:${m.type()}] ${m.text()}`));
    page.on("pageerror", (e) => console.log(`  [pageerror] ${e.message}`));
    page.on("requestfailed", (r) =>
      console.log(`  [requestfailed] ${r.url()} — ${r.failure()?.errorText}`),
    );
    page.on("response", (r) => {
      if (r.status() >= 400) console.log(`  [http ${r.status()}] ${r.url()}`);
    });

    const pagePath =
      pageArg >= 0
        ? args[pageArg + 1]
        : "/demo/tx/0x5c678710e188fd30a879f764212f0977fb7ef8df/debug/";

    // Read the page's own data WITHOUT running its bundle: the served frame is
    // the exporter's, and the hydration bundle would otherwise open a SECOND
    // engine worker on the same page and compete with this probe's for the
    // container. `javaScriptEnabled: false` is a context option in Playwright.
    const readCtx = await browser.newContext({ javaScriptEnabled: false });
    const readPage = await readCtx.newPage();
    await readPage.goto(origin + pagePath, { waitUntil: "domcontentloaded" });
    const served = await readPage.content();
    await readCtx.close();

    const tracePath = (/data-trace="([^"]*)"/.exec(served) ?? [])[1] ?? "";
    console.log(`page:  ${pagePath}`);
    console.log(`trace: ${tracePath}`);
    if (!tracePath) throw new Error("this page carries no data-trace");

    // A BARE same-origin document. The worker must be same-origin (§5.1), but
    // it need not be the product's page — and on the product's page the
    // hydration bundle opens its own worker against the same container, so a
    // measurement taken there would be racing a second engine.
    await page.goto(origin + "/robots.txt", { waitUntil: "domcontentloaded" }).catch(async () => {
      await page.goto(origin + "/", { waitUntil: "domcontentloaded" });
    });

    // The published source island — the source BlockTracer ALREADY has on the
    // page (`source_island.nim`, element id `bt-session-source`,
    // `{documents: [{path, language, firstLine, text, executed}]}`) and could
    // hand to the engine. That it is already here is the point: no new
    // publishing step is needed to give the classifier a line to parse.
    const islandRaw = (
      /<script[^>]*id="bt-session-source"[^>]*>([\s\S]*?)<\/script>/.exec(served) ?? []
    )[1];
    let island = null;
    if (islandRaw) {
      try {
        island = JSON.parse(islandRaw);
      } catch (e) {
        island = { parseError: String(e), raw: islandRaw.slice(0, 200) };
      }
    }
    console.log(
      `island: ${
        island
          ? `availability=${island.availability} documents=${(island.documents ?? []).length} ` +
            JSON.stringify((island.documents ?? []).map((d) => ({ path: d.path, bytes: (d.text ?? "").length })))
          : "NONE"
      }`,
    );

    const sources = {};
    if (WRITE_SOURCE && island?.documents) {
      for (const d of island.documents) {
        if (typeof d.path === "string" && typeof d.text === "string") sources[d.path] = d.text;
      }
    }

    // TWO PASSES, because the write has to happen before the read and the
    // address is only knowable after it.
    //
    // The engine keys source on the path the RECORDING carries — here
    // `/private/tmp/blocktracer-fixture-rec/noir_space_ship/src/main.nr`, an
    // absolute path on the machine that recorded, which exists on no visitor's
    // computer. The island's paths are project-relative (`src/main.nr`). The
    // two have to be joined, and the joining root is only legible from a stack
    // frame — which needs a launched engine. But `vfs-write` is only accepted
    // by the worker's PRE-START dispatcher (`worker.js:280`, before
    // `wasm_start()` replaces the handler), so it cannot be issued after the
    // handshake that reveals the root.
    //
    // So: pass one launches and reports the recorded path, pass two starts a
    // fresh worker, writes the source at the derived absolute paths, and only
    // then asks. A single-pass probe would have to guess the root.
    let out = await page.evaluate(DRIVE, { tracePath, writeSource: false, sources: {} });

    if (WRITE_SOURCE) {
      const recorded = out?.positions?.[0]?.path ?? out?.top?.source?.path ?? "";
      console.log(`\nrecorded source path (pass 1): ${recorded}`);
      // BOTH SPELLINGS OF THE SAME FILE, and the relative one is the one that
      // matters.
      //
      // Position resolution and the origin classifier do NOT probe the same
      // path. `Location.missing_path` is computed from the ABSOLUTE recorded
      // path, but the classifier's probe is
      // `db.rs:3186-3192`:
      //
      //     let path_str = self.reader.path(step_record.path_id)...;   // "src/main.nr"
      //     let workdir_path = self.reader.workdir().join(&path_str);  // absolute
      //     let probe_path = if workdir_path.exists() { workdir_path }
      //                      else { PathBuf::from(&path_str) };        // RELATIVE
      //
      // `Path::exists()` is hardwired `false` on wasm32 — the very defect the
      // VFS work fixed for `missing_path` — so in a browser the classifier
      // always takes the else-branch and looks for the bare `src/main.nr`.
      // Measured: with only the absolute path in the VFS, `missing_path` goes
      // false (the editor pane resolves) while the classifier logs 105 failed
      // reads of `src/main.nr` and answers "source unavailable".
      //
      // So the recording's source is written under both spellings.
      // `--relative-only` writes ONLY the classifier's spelling. It is the arm
      // that proves which of the two paths the classification actually needed:
      // if the hops still classify with the absolute path absent, then the
      // relative one is sufficient — and the relative one is exactly what the
      // page's own source island already carries, so BlockTracer needs no new
      // knowledge of the recording machine's directory layout.
      const relativeOnly = args.includes("--relative-only");
      const placed = {};
      for (const [rel, text] of Object.entries(sources)) {
        placed[rel] = text; // what the classifier actually probes
        if (relativeOnly) continue;
        if (recorded.endsWith("/" + rel)) {
          placed[recorded.slice(0, recorded.length - rel.length) + rel] = text;
        } else {
          const root = recorded.slice(0, recorded.lastIndexOf("/src/") + 1);
          if (root) placed[root + rel] = text;
        }
      }
      console.log(`placing source at: ${JSON.stringify(Object.keys(placed))}`);
      out = await page.evaluate(DRIVE, { tracePath, writeSource: true, sources: placed });
    }

    console.log("\n--- bootstrap ---");
    for (const l of out.log) console.log("  " + l);
    if (!out.ok) {
      console.log(`\nFAILED: ${out.error}`);
      process.exitCode = 1;
      return;
    }

    console.log(`\n--- events seen: ${JSON.stringify(out.events)}`);

    console.log("\n--- positions probed ---");
    for (const p of out.positions)
      console.log(
        `  step ${p.i} @tick=${p.tick}: success=${p.ok}${p.msg ? ` msg=${p.msg}` : ""} line=${p.line} locals=${p.localCount} withOriginSummary=${p.withSummary} ${JSON.stringify(p.names)}`,
      );
    console.log(`  (engine source path: ${out.positions[0]?.path})`);

    console.log("\n--- originSummary already on the load-locals reply ---");
    for (const s of out.best?.summaries ?? []) console.log(`  ${s.name}: ${JSON.stringify(s.s)}`);
    if (!(out.best?.summaries ?? []).length) console.log("  (none)");

    console.log("\n--- ct/originChain ---");
    let hops = 0;
    let classified = 0;
    for (const c of out.chains) {
      const body = c.body ?? {};
      const hs = body.hops ?? [];
      hops += hs.length;
      const cls = hs.filter(CLASSIFIED).length;
      classified += cls;
      console.log(
        `  ${c.name}: success=${c.success} hops=${hs.length} classified=${cls} terminator=${JSON.stringify(body.terminator ?? null)}`,
      );
      for (const h of hs.slice(0, 4))
        console.log(
          `      kind=${h.kind} confidence=${h.confidence} provenance=${JSON.stringify(h.classificationProvenance)} expr=${JSON.stringify(h.expression ?? h.sourceExpr ?? null)}`,
        );
    }

    console.log("\n=== VERDICT ===");
    console.log(`  variables asked:      ${out.chains.length}`);
    console.log(`  hops returned:        ${hops}`);
    console.log(`  CLASSIFIED hops:      ${classified}`);
    console.log(
      `  source written to VFS: ${WRITE_SOURCE ? out.wrote + " file(s)" : "no (control arm)"}`,
    );
    // ASSERTED, not merely printed. Every call in this probe answers
    // `success: true` whether or not anything was classified, so a run that
    // only reported would go green on the exact failure it exists to catch.
    // The threshold is a COUNT and the count is printed beside it.
    const expectIdx = args.indexOf("--expect-classified");
    const expect = expectIdx >= 0 ? Number(args[expectIdx + 1]) : 0;
    if (classified >= expect && classified > 0) {
      console.log(`  => PASS: ${classified} classified hop(s), expected at least ${expect}.`);
    } else if (expect > 0) {
      console.log(
        `  => FAIL: ${classified} classified hop(s), expected at least ${expect}. ` +
          `Hops that answer "unknown"/"source unavailable" are the false pass this probe excludes.`,
      );
      process.exitCode = 1;
    } else {
      console.log("  => every hop is unclassified. A control built on this would answer 'unknown'.");
    }

    // NON-VACUITY: a classified count means nothing if nothing was asked.
    if (out.chains.length === 0) {
      console.log("  => VACUOUS: no variable was asked about; the count above is not a measurement.");
      process.exitCode = 1;
    }
  } finally {
    await browser.close();
    server.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
