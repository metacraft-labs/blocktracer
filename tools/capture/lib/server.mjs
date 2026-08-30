// A minimal static server for the exported `dist/`, with clean URLs.
//
// Captures are taken over HTTP rather than file:// on purpose: the published
// site serves clean URLs (`/aztec/blocks` → `.../blocks/index.html`), and a
// file:// capture would exercise a different URL resolution, a different
// origin model and a different font-loading path from the one that ships.

import { createServer } from "node:http";
import { readFile, stat } from "node:fs/promises";
import { join, extname, normalize } from "node:path";

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".webp": "image/webp",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml; charset=utf-8",
  ".ct": "application/octet-stream",
};

async function resolveFile(root, urlPath) {
  // Strip the query, decode, and refuse anything that escapes the root.
  const clean = normalize(decodeURIComponent(urlPath.split("?")[0]));
  if (clean.includes("..")) return null;
  const base = join(root, clean);
  const candidates = clean.endsWith("/")
    ? [join(base, "index.html")]
    : [base, join(base, "index.html")];
  for (const candidate of candidates) {
    try {
      const s = await stat(candidate);
      if (s.isFile()) return candidate;
    } catch {
      /* next candidate */
    }
  }
  return null;
}

function cleanPath(urlPath) {
  return normalize(decodeURIComponent(urlPath.split("?")[0]));
}

/**
 * Serve `root` on an ephemeral loopback port.
 * Returns `{ origin, close() }`.
 *
 * `overlay` maps a clean pathname to what this server answers there INSTEAD of
 * the file tree — `{ type, body }` for a body, or `null` for a 404. It exists
 * for exactly one caller: the engine-failure views, which need
 * `/replay-engine/worker.js` to be missing, silent or refusing, one scenario
 * per image (tools/capture/lib/engine-stubs.mjs).
 *
 * The overlay lives HERE and never in `dist/`, which is the property that
 * matters: the harness's stand-in engine is not a file in the exported site,
 * so no fixture is reachable as if it were a product route, and the pages the
 * browser is served are byte-for-byte the pages the exporter wrote. What the
 * scenario changes is what the page's ENVIRONMENT does, which is the fault
 * being photographed.
 */
export async function serveDist(root, { overlay = null } = {}) {
  const server = createServer(async (req, res) => {
    if (overlay) {
      const p = cleanPath(req.url ?? "/");
      if (Object.prototype.hasOwnProperty.call(overlay, p)) {
        const entry = overlay[p];
        const headers = { "Cache-Control": "no-store, max-age=0" };
        if (entry === null) {
          res.writeHead(404, { ...headers, "Content-Type": MIME[".txt"] });
          res.end("not found (capture-harness engine scenario)\n");
          return;
        }
        res.writeHead(200, { ...headers, "Content-Type": entry.type ?? MIME[".js"] });
        res.end(entry.body);
        return;
      }
    }
    const file = await resolveFile(root, req.url ?? "/");
    // Every response is no-store: a capture must never be served a body the
    // previous capture warmed, or the second run of the canary would be
    // measuring the HTTP cache rather than the renderer.
    const headers = { "Cache-Control": "no-store, max-age=0" };
    if (!file) {
      const notFound = await resolveFile(root, "/404.html");
      if (notFound) {
        res.writeHead(404, { ...headers, "Content-Type": MIME[".html"] });
        res.end(await readFile(notFound));
        return;
      }
      res.writeHead(404, { ...headers, "Content-Type": MIME[".html"] });
      res.end("<!doctype html><title>404</title><h1>404</h1>");
      return;
    }
    const type = MIME[extname(file)] ?? "application/octet-stream";
    res.writeHead(200, { ...headers, "Content-Type": type });
    res.end(await readFile(file));
  });

  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  return {
    origin: `http://127.0.0.1:${port}`,
    close: () => new Promise((resolve) => server.close(resolve)),
  };
}
