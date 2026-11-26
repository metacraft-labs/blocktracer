// solana-history-files.mjs — HOW A WINDOW'S ADDRESS HISTORY IS STORED ON DISK.
//
// Spine need (f), Recorder-Solana. `sol-address-history.mjs` answers, for each address the
// reader pages, the chain's own history below the window. One slot's answer is 1.6 MB, and
// a wider window's is several times that, while the repository refuses a new file over
// 1024 KB (.pre-commit-config.yaml). So the answer is written as PARTS,
// `history/<from>-<to>.part-<nn>.json`, each holding some addresses under the same header,
// and read back as one document. A single `history/<from>-<to>.json` (the 2026-10-22
// window's) is read as it is.

import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const FORMAT = 'codetracer-solana/address-history@1';
/** A part stays under the 1024 KB ceiling with room to spare. */
export const PART_BYTES = 900 * 1024;

const partName = (from, to, n) => `${from}-${to}.part-${String(n).padStart(2, '0')}.json`;

/** Writes `answer` ({ rpc, from, to, addresses }) as parts; returns the file names. */
export function writeHistory(dir, answer, partBytes = PART_BYTES) {
  const { rpc, from, to, addresses } = answer;
  const header = { format: FORMAT, rpc, from, to };
  const parts = [];
  let cur = {};
  let size = 0;
  for (const address of Object.keys(addresses).sort()) {
    const entry = JSON.stringify(addresses[address]).length + address.length + 8;
    if (size > 0 && size + entry > partBytes) { parts.push(cur); cur = {}; size = 0; }
    cur[address] = addresses[address];
    size += entry;
  }
  parts.push(cur);
  return parts.map((part, i) => {
    const name = partName(from, to, i + 1);
    writeFileSync(join(dir, name), `${JSON.stringify({ ...header, part: i + 1, parts: parts.length, addresses: part })}\n`);
    return name;
  });
}

/**
 * The window's history as one document, or null when none was committed. Parts must agree
 * on their header, be numbered 1..parts with none missing, and name each address once;
 * anything else is refused rather than merged into a history the chain did not give.
 */
export function readHistory(dir, from, to) {
  const whole = join(dir, `${from}-${to}.json`);
  if (existsSync(whole)) return JSON.parse(readFileSync(whole, 'utf8'));
  if (!existsSync(dir)) return null;
  const prefix = `${from}-${to}.part-`;
  const names = readdirSync(dir).filter((f) => f.startsWith(prefix) && f.endsWith('.json')).sort();
  if (names.length === 0) return null;
  const docs = names.map((f) => ({ f, d: JSON.parse(readFileSync(join(dir, f), 'utf8')) }));
  const head = docs[0].d;
  const addresses = {};
  docs.forEach(({ f, d }, i) => {
    for (const k of ['format', 'rpc', 'from', 'to']) {
      if (d[k] !== head[k]) throw new Error(`address history ${f}: ${k} ${JSON.stringify(d[k])} differs from ${names[0]}'s ${JSON.stringify(head[k])}`);
    }
    if (d.part !== i + 1 || d.parts !== names.length) {
      throw new Error(`address history ${f}: part ${d.part} of ${d.parts}, but ${names.length} part file(s) are present`);
    }
    for (const [a, v] of Object.entries(d.addresses ?? {})) {
      if (a in addresses) throw new Error(`address history ${f}: ${a} is also in an earlier part`);
      addresses[a] = v;
    }
  });
  return { format: head.format, rpc: head.rpc, from: head.from, to: head.to, addresses };
}
