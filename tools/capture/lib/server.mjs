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

/**
 * Serve `root` on an ephemeral loopback port.
 * Returns `{ origin, close() }`.
 */
export async function serveDist(root) {
  const server = createServer(async (req, res) => {
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
