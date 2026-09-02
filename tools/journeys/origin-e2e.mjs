// origin-e2e.mjs — THE SHIPPED BUNDLE'S OWN ENGINE, ASKED FOR AN ORIGIN CHAIN.
//
// `origin-probe.mjs` drives a worker this harness constructs itself, which
// answers "can the engine classify, if someone hands it the source". It cannot
// answer "does the product hand it the source", because the harness was doing
// the handing.
//
// This one changes nothing and constructs nothing. It loads a real session
// page, lets the hydration bundle boot the engine and complete its own
// bootstrap, and then asks THAT worker — the one the product built, holding
// whatever the product wrote into its VFS — for an origin chain.
//
// The seam is `globalThis.__btReplayWorker`, which `engine_transport.nim`'s
// `startWorkerImpl` already parks the worker on. Nothing is added to the page
// for this probe's benefit; a session that never reached the engine has no
// worker there and the probe says so instead of measuring zero.
//
// Usage: node tools/journeys/origin-e2e.mjs [--dist client/dist]
//                                           [--page /demo/tx/…/debug/]
//                                           [--expect-classified N]

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
const arg = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : dflt;
};
const DIST = join(REPO, arg("--dist", "client/dist"));
const PAGE = arg("--page", "/demo/tx/0x5c678710e188fd30a879f764212f0977fb7ef8df/debug/");
const EXPECT = Number(arg("--expect-classified", "0"));

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
      const p = decodeURIComponent(new URL(req.url, "http://x").pathname);
      let f = join(root, p);
      try {
        if ((await stat(f)).isDirectory()) f = join(f, "index.html");
      } catch {
        if (!extname(f)) f = join(root, p, "index.html");
      }
      const body = await readFile(f);
      res.writeHead(200, {
        "content-type": MIME[extname(f)] ?? "application/octet-stream",
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

const CLASSIFIED = (h) =>
  h &&
  h.kind &&
  String(h.kind).toLowerCase() !== "unknown" &&
  Number(h.confidence ?? 0) > 0 &&
  !/source unavailable/i.test(String(h.classificationProvenance ?? ""));

/** Ask the bundle's own worker, in the bundle's own page. */
const ASK = async () => {
  const w = globalThis.__btReplayWorker;
  if (!w) return { ok: false, error: "the page has no __btReplayWorker — the bundle never reached the engine" };

  let seq = 100000; // far above the bundle's own counter, so no reply is stolen
  const send = (command, args_) =>
    new Promise((resolve, reject) => {
      const s = seq++;
      const onMsg = (e) => {
        let m = e.data;
        if (typeof m === "string") {
          const t = m.trim();
          if (t.startsWith("{")) {
            try {
              m = JSON.parse(t);
            } catch {
              return;
            }
          } else return;
        }
        if (m && m.type === "response" && m.request_seq === s) {
          w.removeEventListener("message", onMsg);
          resolve(m);
        }
      };
      // addEventListener, NOT `w.onmessage`: the transport already owns
      // `onmessage` and assigning it would disconnect the running session.
      w.addEventListener("message", onMsg);
      setTimeout(() => {
        w.removeEventListener("message", onMsg);
        reject(new Error(`timeout on ${command}`));
      }, 60000);
      w.postMessage({ seq: s, type: "request", command, arguments: args_ ?? {} });
    });

  // The tick, off the event stream. `ct/complete-move` carries it at
  // `body.location.rrTicks`; the top level and `cLocation` both hold zeros.
  let tick = 0;
  w.addEventListener("message", (e) => {
    let m = e.data;
    if (typeof m === "string") {
      const t = m.trim();
      if (!t.startsWith("{")) return;
      try {
        m = JSON.parse(t);
      } catch {
        return;
      }
    }
    const v = m?.body?.location?.rrTicks;
    if (typeof v === "number" && v > 0) tick = v;
  });

  try {
    // WALK PAST THE SIGNATURE. The session opens at line 1, where nothing is
    // bound yet, so a reading taken there measures the position and not the
    // product. `main`'s `let` bindings are the values an origin chain has
    // anything to say about, and they are a dozen `next`es in.
    let f = null;
    let rows = [];
    for (let i = 0; i < 14; i++) {
      const st = await send("stackTrace", { threadId: 1 });
      f = st?.body?.stackFrames?.[0];
      const locals = await send("ct/load-locals", {
        rrTicks: tick,
        countBudget: 3000,
        minCountLimit: 50,
        depthLimit: 7,
        watchExpressions: [],
        lang: 0,
      });
      const got = locals?.body?.locals ?? [];
      if (got.length > rows.length) rows = got;
      await send("next", { threadId: 1 });
    }
    const chains = [];
    for (const r of rows.slice(0, 12)) {
      const res = await send("ct/originChain", {
        variableName: r.expression,
        variablePath: [],
        frameId: f?.id ?? -1,
        stepId: -1,
        threadId: 1,
        maxHops: 32,
        lazy: false,
        sessionId: "",
        classifySource: true,
      });
      chains.push({ name: r.expression, success: res.success, body: res.body ?? null });
    }
    return {
      ok: true,
      line: f?.line ?? null,
      path: f?.source?.path ?? null,
      locals: rows.map((r) => r.expression),
      summaries: rows.map((r) => ({ name: r.expression, s: r.originSummary ?? null })),
      chains,
    };
  } catch (e) {
    return { ok: false, error: String(e.message ?? e) };
  }
};

async function main() {
  const { server, origin } = await serve(DIST);
  const browser = await chromium.launch();
  try {
    const page = await browser.newPage();
    await page.goto(origin + PAGE, { waitUntil: "domcontentloaded" });
    console.log(`page: ${PAGE}`);

    // Wait for the PRODUCT's own readiness signal, not a sleep: the session
    // writes its phase onto the root, and `ready` is the bundle saying the
    // engine answered and the panes are its own.
    await page
      .waitForFunction(
        () =>
          document.querySelector("[data-session-phase]")?.getAttribute("data-session-phase") ===
          "ready",
        { timeout: 120000 },
      )
      .catch(() => {});
    const phase = await page.evaluate(
      () => document.querySelector("[data-session-phase]")?.getAttribute("data-session-phase") ?? "?",
    );
    console.log(`session phase: ${phase}`);

    const out = await page.evaluate(ASK);

    // WHAT THE PAGE OFFERS, after the walk above has put the session on a
    // position with values. Counted with the same generous selector the
    // journey uses, plus the specific one, so a mismatch between them says
    // the control was renamed rather than removed.
    const surface = await page.evaluate(() => {
      const shown = (e) =>
        !!e &&
        typeof e.checkVisibility === "function" &&
        e.checkVisibility({ checkOpacity: true, checkVisibilityCSS: true });
      const labelled = [
        ...document.querySelectorAll("a, button, [data-action], [role=button]"),
      ].filter((e) =>
        /origin|where did this come from|provenance|trace value/i.test(
          `${e.textContent ?? ""} ${e.getAttribute("data-action") ?? ""} ${
            e.getAttribute("aria-label") ?? ""
          } ${e.getAttribute("title") ?? ""}`,
        ),
      );
      return {
        originButtons: [...document.querySelectorAll(".storigin")].length,
        originButtonsShown: [...document.querySelectorAll(".storigin")].filter(shown).length,
        labelled: labelled.length,
        titles: [...document.querySelectorAll(".storigin")].map((e) => e.getAttribute("title")),
        note: document.querySelector("#pane-state .stnote")?.textContent?.trim() ?? "",
        rows: document.querySelectorAll("#pane-state .strow").length,
      };
    });
    console.log(`\n--- the State pane as the visitor sees it ---`);
    console.log(`  rows: ${surface.rows}`);
    console.log(
      `  origin controls: ${surface.originButtons} (${surface.originButtonsShown} visible), ` +
        `matched by the journey's wide selector: ${surface.labelled}`,
    );
    for (const t of surface.titles) console.log(`      title: ${t}`);
    console.log(`  origin note: ${surface.note ? JSON.stringify(surface.note) : "(none)"}`);
    if (!out.ok) {
      console.log(`FAILED: ${out.error}`);
      process.exitCode = 1;
      return;
    }
    console.log(`position: line=${out.line} path=${out.path}`);
    console.log(`locals: ${JSON.stringify(out.locals)}`);

    console.log("\n--- originSummary on the bundle's own load-locals reply ---");
    for (const s of out.summaries) console.log(`  ${s.name}: ${JSON.stringify(s.s)}`);

    console.log("\n--- ct/originChain, asked of the bundle's engine ---");
    let hops = 0;
    let classified = 0;
    for (const c of out.chains) {
      const hs = c.body?.hops ?? [];
      hops += hs.length;
      const n = hs.filter(CLASSIFIED).length;
      classified += n;
      console.log(`  ${c.name}: success=${c.success} hops=${hs.length} classified=${n}`);
      for (const h of hs.slice(0, 2))
        console.log(
          `      kind=${h.kind} confidence=${h.confidence} provenance=${JSON.stringify(h.classificationProvenance)}`,
        );
    }

    console.log("\n=== VERDICT (the shipped bundle's engine) ===");
    console.log(`  variables asked: ${out.chains.length}`);
    console.log(`  hops returned:   ${hops}`);
    console.log(`  CLASSIFIED hops: ${classified}`);
    if (out.chains.length === 0) {
      console.log("  => VACUOUS: nothing was asked, so the count is not a measurement.");
      process.exitCode = 1;
    } else if (classified >= EXPECT && classified > 0) {
      console.log(`  => PASS: at least ${EXPECT} classified, and the product supplied the source.`);
    } else {
      console.log(
        `  => FAIL: ${classified} classified, expected at least ${EXPECT}. ` +
          `The bundle did not give its engine a line the classifier could parse.`,
      );
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
