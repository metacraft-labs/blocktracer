#!/usr/bin/env node
// sol-fixture.mjs — PACK A LIVE SOLANA CAPTURE INTO COMMITTABLE INPUTS, AND UNPACK THEM.
//
//   node tools/chain/sol-fixture.mjs pack   --capture <dir> --from <slot> --to <slot> --out <fixture dir>
//   node tools/chain/sol-fixture.mjs unpack --fixture <fixture dir> --out <capture dir>
//
// A forward capture cannot be re-run: the account states it carried were read live and
// are not served again. What CAN be re-run is each traced transaction's replay, from the
// self-contained bundle the recorder wrote beside its trace. So the committed inputs for a
// Solana window are the window's enumeration (every transaction, with the verdict line the
// recorder gave it) plus one bundle per traced transaction, and the build re-runs every
// bundle through the recorder in a sandbox to produce the containers (tools/chain/nix/sol.nix).
//
// PACKED, CONTENT-ADDRESSED. Bundles of one program's transactions repeat the same
// programdata (hundreds of kilobytes), the same sysvars and the same feature set; stored
// whole, 74 traces of one 5-slot window were 5.8 MB. Here every account entry, the sysvar
// list and the feature list are stored once under their sha256 and the bundles reference
// them, so the fixture holds each distinct state exactly once. `unpack` restores the
// bundles byte-for-byte (`JSON.stringify` of the same object), which the build checks by
// re-deriving each bundle's digest.
//
// The `dir` member of a verdict line (an absolute path on the capturing machine) is the
// one thing dropped: it names where the capture ran, not what it captured.

import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [cmd, ...rest] = process.argv.slice(2);
const flag = (n) => { const i = rest.indexOf(`--${n}`); return i >= 0 ? rest[i + 1] : undefined; };
const sha = (s) => createHash('sha256').update(s).digest('hex');
const jsonl = (p) => readFileSync(p, 'utf8').split('\n').filter((l) => l.trim()).map((l) => JSON.parse(l));
const die = (m) => { console.error(`sol-fixture: ${m}`); process.exit(2); };

if (cmd === 'pack') {
  const cap = flag('capture'); const out = flag('out');
  const from = Number(flag('from')); const to = Number(flag('to'));
  if (!cap || !out || !Number.isFinite(from) || !Number.isFinite(to)) die('pack needs --capture --from --to --out');
  for (const d of ['', 'blocks', 'bundles', 'objects']) mkdirSync(join(out, d), { recursive: true });
  const capture = JSON.parse(readFileSync(join(cap, 'capture.json'), 'utf8'));
  const blocks = jsonl(join(cap, 'blocks.jsonl')).filter((b) => b.slot >= from && b.slot <= to);
  const sigs = new Set(blocks.flatMap((b) => (b.transactions ?? []).map((t) => t.signature)));
  const results = jsonl(join(cap, 'results.jsonl')).filter((r) => sigs.has(r.signature))
    .map((r) => { if (r.trace) { const { dir, ...t } = r.trace; return { ...r, trace: t }; } return r; });
  const store = (obj) => {
    const text = JSON.stringify(obj);
    const h = sha(text);
    const p = join(out, 'objects', `${h}.json`);
    if (!existsSync(p)) writeFileSync(p, text);
    return h;
  };
  let traced = 0;
  for (const r of results) {
    const bp = join(cap, 'traces', r.signature, 'replay.bundle.json');
    if (!r.executed || !existsSync(bp)) continue;
    const b = JSON.parse(readFileSync(bp, 'utf8'));
    // The digest is of the canonical re-serialisation, not the recorder's bytes: JSON.parse
    // turns a u64::MAX `rentEpoch` into a float, and the recorder reads that float back as
    // u64::MAX, so the replay is unchanged while the text is not.
    const canonical = JSON.stringify({ format: b.format, cluster: b.cluster, sysvars: b.sysvars,
      features: b.features, accounts: b.accounts, transactions: b.transactions });
    writeFileSync(join(out, 'bundles', `${r.signature}.json`), JSON.stringify({
      sha256: sha(canonical),
      format: b.format, cluster: b.cluster,
      sysvars: store(b.sysvars), features: store(b.features),
      accounts: b.accounts.map(store),
      transactions: b.transactions,
    }));
    traced++;
  }
  for (const b of blocks) writeFileSync(join(out, 'blocks', `${b.slot}.json`), JSON.stringify(b));
  writeFileSync(join(out, 'results.jsonl'), results.map((r) => JSON.stringify(r)).join('\n') + '\n');
  writeFileSync(join(out, 'capture.json'), JSON.stringify({
    ...capture, window: { firstSlot: from, lastSlot: to, slots: to - from + 1 },
    packedFrom: capture.window, packedBy: 'tools/chain/sol-fixture.mjs',
  }, null, 2) + '\n');
  console.error(`packed slots ${from}..${to}: ${blocks.length} slot(s), ${results.length} verdict line(s), `
    + `${traced} bundle(s), ${readdirSync(join(out, 'objects')).length} distinct object(s)`);
} else if (cmd === 'unpack') {
  const fx = flag('fixture'); const out = flag('out');
  if (!fx || !out) die('unpack needs --fixture --out');
  mkdirSync(join(out, 'bundles'), { recursive: true });
  const load = (h) => JSON.parse(readFileSync(join(fx, 'objects', `${h}.json`), 'utf8'));
  for (const f of readdirSync(join(fx, 'bundles')).sort()) {
    const p = JSON.parse(readFileSync(join(fx, 'bundles', f), 'utf8'));
    const bundle = { format: p.format, cluster: p.cluster, sysvars: load(p.sysvars),
      features: load(p.features), accounts: p.accounts.map(load), transactions: p.transactions };
    const text = JSON.stringify(bundle);
    if (sha(text) !== p.sha256) die(`${f}: the unpacked bundle does not hash to the digest packed beside it`);
    writeFileSync(join(out, 'bundles', f), text);
  }
  const blocks = readdirSync(join(fx, 'blocks')).map((f) => JSON.parse(readFileSync(join(fx, 'blocks', f), 'utf8')))
    .sort((a, b) => a.slot - b.slot);
  writeFileSync(join(out, 'blocks.jsonl'), blocks.map((b) => JSON.stringify(b)).join('\n') + '\n');
  writeFileSync(join(out, 'results.jsonl'), readFileSync(join(fx, 'results.jsonl')));
  writeFileSync(join(out, 'capture.json'), readFileSync(join(fx, 'capture.json')));
} else {
  die('usage: sol-fixture.mjs pack|unpack …');
}
