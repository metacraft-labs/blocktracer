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
  const log = [];
  const worker = new Worker("/replay-engine/worker.js", { type: "module" });
  let seq = 1;
  const pending = new Map();
  const events = [];
  const control = [];
  const waiters = [];

  worker.onmessage = (e) => {
    const m = e.data;
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
  worker.onerror = (e) => log.push(`worker error: ${e.message ?? e}`);

  const awaitControl = (match, ms = 60000) =>
    new Promise((resolve, reject) => {
      const hit = control.find(match);
      if (hit) return resolve(hit);
      const w = { match, resolve };
      waiters.push(w);
      setTimeout(() => reject(new Error(`timeout waiting for control`)), ms);
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
  await awaitControl((m) => m && m.type === "worker-status" && m.status === "ready");
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
  const positions = [];
  for (let i = 0; i < 12; i++) {
    const st = await send("stackTrace", { threadId: 1 });
    const f = st?.body?.stackFrames?.[0];
    const locals = await send("ct/load-locals", {
      rrTicks: i,
      threadId: 1,
      frameId: f?.id ?? 0,
    });
    const rows = locals?.body?.locals ?? [];
    positions.push({
      i,
      line: f?.line ?? null,
      path: f?.source?.path ?? null,
      localCount: rows.length,
      withSummary: rows.filter((r) => r.originSummary).length,
      names: rows.map((r) => r.expression),
      summaries: rows
        .filter((r) => r.originSummary)
        .map((r) => ({ name: r.expression, s: r.originSummary })),
    });
    if (rows.length > 0) break;
    await send("next", { threadId: 1 });
  }

  const best = positions.find((p) => p.localCount > 0) ?? positions[positions.length - 1];

  // ── THE MEASUREMENT ──
  const chains = [];
  for (const name of (best?.names ?? []).slice(0, 8)) {
    const st = await send("stackTrace", { threadId: 1 });
    const f = st?.body?.stackFrames?.[0];
    const r = await send("ct/originChain", {
      variableName: name,
      variablePath: [],
      frameId: f?.id ?? -1,
      stepId: -1,
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
    page.on("console", (m) => {
      if (m.type() === "error") console.log(`  [page error] ${m.text()}`);
    });

    const pagePath =
      pageArg >= 0
        ? args[pageArg + 1]
        : "/demo/tx/0x5c678710e188fd30a879f764212f0977fb7ef8df/debug/";
    await page.goto(origin + pagePath, { waitUntil: "domcontentloaded" });

    const tracePath = await page.evaluate(
      () => document.querySelector("[data-trace]")?.getAttribute("data-trace") ?? "",
    );
    console.log(`page:  ${pagePath}`);
    console.log(`trace: ${tracePath}`);
    if (!tracePath) throw new Error("this page carries no data-trace");

    // The published source island, which is the source BlockTracer already has
    // on the page and could hand the engine.
    const island = await page.evaluate(() => {
      const el = document.querySelector("#source-island, [data-source-island]");
      if (!el) return null;
      try {
        return JSON.parse(el.textContent ?? "null");
      } catch {
        return { raw: (el.textContent ?? "").slice(0, 400) };
      }
    });
    console.log(`island: ${island ? JSON.stringify(island).slice(0, 300) : "NONE"}`);

    let sources = {};
    if (WRITE_SOURCE && island) {
      // Best effort: map whatever shape the island has into {path: text}.
      const files = island.files ?? island.sources ?? island;
      if (files && typeof files === "object") {
        for (const [k, v] of Object.entries(files)) {
          if (typeof v === "string") sources[k] = v;
          else if (v && typeof v.text === "string") sources[k] = v.text;
          else if (v && typeof v.content === "string") sources[k] = v.content;
        }
      }
    }

    const out = await page.evaluate(DRIVE, {
      tracePath,
      writeSource: WRITE_SOURCE,
      sources,
    });

    console.log("\n--- bootstrap ---");
    for (const l of out.log) console.log("  " + l);
    if (!out.ok) {
      console.log(`\nFAILED: ${out.error}`);
      process.exitCode = 1;
      return;
    }

    console.log("\n--- positions probed ---");
    for (const p of out.positions)
      console.log(
        `  tick ${p.i}: line=${p.line} path=${p.path} locals=${p.localCount} withOriginSummary=${p.withSummary} ${JSON.stringify(p.names)}`,
      );

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
    console.log(
      classified > 0
        ? "  => the engine CAN classify a hop here."
        : "  => every hop is unclassified. A control built on this would answer 'unknown'.",
    );
  } finally {
    await browser.close();
    server.close();
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
