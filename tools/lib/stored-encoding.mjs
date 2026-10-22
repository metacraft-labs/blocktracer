// What `Content-Encoding` must a server send for a file out of a published tree?
//
// ── WHY A SERVER HAS TO ASK AT ALL ────────────────────────────────────────
//
// `ctfs-container.md` §1f has a compact container store its members RAW, and
// §1e says that is only sound because such a container is "intended to be
// STORED AND SERVED pre-compressed". So `static_export.nim` writes every
// `/t/**/trace.ct` brotli-encoded, and the object at rest is a brotli stream
// rather than a container.
//
// A STATIC FILE SERVER CANNOT TELL. Brotli has no magic number, so there is
// nothing in the bytes to look at, and `.ct` is the extension either way. The
// manifest beside the container is the only thing that says — which is exactly
// what `contract/model.nim`'s ContainerRef declares the `encoding`,
// `storedBytes` and `storedHash` fields for.
//
// `publisher.encodingOf` already does this for the R2 upload, reading the same
// field and setting the object's `Content-Encoding`. This is the same rule for
// the local servers the captures and the journeys run against, so a container
// behaves the same way on `http://127.0.0.1:<port>` as it does on
// blocktracer.org. Without it the engine is handed brotli bytes with no header
// and reports a corrupt container — the precise failure `chain/ingest.nim`'s
// comment warned pre-compression would cause "with nothing telling them so".
//
// ── IT ANSWERS FROM THE MANIFEST, NEVER FROM THE BYTES ────────────────────
//
// A sniff is what §1f forbids a READER to do about a chunk, and the same
// argument applies here one layer up: four bytes that happen to look like a
// brotli stream are content. The manifest is the declaration.

import { readFileSync } from 'node:fs';
import { dirname, join, basename } from 'node:path';

/**
 * The `Content-Encoding` for `absPath`, or `""` when the object at rest is what
 * it claims to be.
 *
 * Only `trace.ct` is ever encoded — the exporter encodes containers and nothing
 * else — so every other path answers `""` without touching the disk.
 */
export function storedEncodingFor(absPath) {
  if (basename(absPath) !== 'trace.ct') return '';
  try {
    const m = JSON.parse(readFileSync(join(dirname(absPath), 'manifest.json'), 'utf8'));
    const enc = m?.container?.encoding;
    // `identity` and absent are the same answer, and the field's PRESENCE is
    // what records that compression happened — `parseContainerEncoding` says
    // so, and an empty string reaching a header would be a malformed response.
    return typeof enc === 'string' && enc && enc !== 'identity' ? enc : '';
  } catch {
    // NO MANIFEST IS NOT "RAW". It is a malformed tree — `publisher.encodingOf`
    // refuses to upload in exactly this case — but a local preview server is
    // not the place to fail the run, and serving the bytes unlabelled is what
    // this file exists to stop. So: no header, and the caller's own tree checks
    // (`validateTree`, `check-assets`) are where the absence is a finding.
    return '';
  }
}

/** The header object to spread into a response, empty when there is nothing to say. */
export function storedEncodingHeader(absPath) {
  const enc = storedEncodingFor(absPath);
  return enc ? { 'Content-Encoding': enc } : {};
}
