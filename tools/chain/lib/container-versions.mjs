// The two version axes of a CTFS container, read off its bytes, and the sets the
// SHIPPED replay engine accepts on each, read from `tools/chain/health-checks.json`.
//
// The axes are INDEPENDENT — `client/hydrate/engine-pin.txt` carries the incident
// that taught this — so both are read for every subject, and a file with no CTFS
// magic is reported as such instead of being given a version of 0.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

const CTFS_MAGIC = Buffer.from('c0de72ace2', 'hex');

/** `{ container, metaDat, profile }` of `bytes`; a field that is not there is null. */
export function versionsOf(bytes) {
  const isCtfs = bytes.length > 5 && bytes.subarray(0, 5).equals(CTFS_MAGIC);
  const container = isCtfs ? bytes[5] : null;
  // The `meta.dat` member's own header: `CTMD` then a little-endian u16 version
  // (codetracer-trace-format-spec internal-files.md "Metadata (meta.dat)"). A
  // container whose whole file is compressed hides it; that reads as null.
  const j = isCtfs ? bytes.indexOf(Buffer.from('CTMD')) : -1;
  const metaDat = j >= 0 && j + 6 <= bytes.length ? bytes.readUInt16LE(j + 4) : null;
  // Byte 16 is the PROFILE byte, and only in a version-6 header (24 bytes).
  // In version 5 that offset is body, so reading it there would invent a field.
  const profile = container === 6 && bytes.length > 16 ? bytes[16] : null;
  return { container, metaDat, profile };
}

/** The `shipped-engine` consumer from the health-check registry under `root`. */
export function shippedEngine(root) {
  const health = JSON.parse(readFileSync(join(root, 'tools/chain/health-checks.json'), 'utf8'));
  const engine = (health.containerSchema?.consumers ?? []).find((c) => c.id === 'shipped-engine');
  if (!engine || !Array.isArray(engine.accepts) || !Array.isArray(engine.acceptsContainerVersions)) {
    throw new Error('tools/chain/health-checks.json names no shipped-engine with accepts and acceptsContainerVersions');
  }
  return engine;
}

/**
 * Why the shipped engine would refuse a container with these `versions`, or null
 * when both axes are inside its sets. A version that could not be read is a
 * refusal too: an unread axis is not a passed one.
 */
export function engineRefusal(versions, engine) {
  const why = [];
  if (!engine.acceptsContainerVersions.includes(versions.container)) {
    why.push(`container version ${versions.container ?? 'unreadable'} is not in ${JSON.stringify(engine.acceptsContainerVersions)}`);
  }
  if (!engine.accepts.includes(versions.metaDat)) {
    why.push(`meta.dat version ${versions.metaDat ?? 'unreadable'} is not in ${JSON.stringify(engine.accepts)}`);
  }
  return why.length ? why.join(' and ') : null;
}
