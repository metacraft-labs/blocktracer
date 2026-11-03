#!/usr/bin/env node
// Is the chain we are following still the chain we can decode?
//
//   node tools/chain/check-chain-compat.mjs --chain aztec-testnet --identity-only
//   node tools/chain/check-chain-compat.mjs --chain aztec-testnet --runtime <aztec-avm-runtime>
//
// ── WHY THIS EXISTS, AS THE THING THAT HAPPENED ────────────────────────────────────────
//
// Between 2026-09-04 and 2026-11-03 nothing was traced on any Aztec chain, and nobody
// found out from a check. The newest `capturedAt` in all three committed snapshots is
// 2026-09-04; in that window aztec-testnet restarted onto a new rollup AND moved its
// transaction serialisation, and every published `@aztec/stdlib` began refusing its
// transactions with `is greater or equal to field modulus`.
//
// Two guards existed for exactly this and neither spoke.
//
//   * `aztec-avm-runtime`'s `replay/src/node_client.ts` carries a
//     `ProtocolVersionMismatch` refusal, wired through upstream's own
//     `getVersioningResponseHandler`, whose whole purpose is the case where "every answer
//     LOOKS fine and means something else".
//   * `pins.json`'s `live_chain` declares the protocol version a node is checked against.
//
// Both are sound. NOTHING RAN THEM AGAINST A LIVE NODE, because the only thing that would
// have is a replay, and a replay is what had stopped working. A check that is not run is
// not a pass, and a guard reachable only from the broken path is not reachable.
//
// ── WHAT IT ASKS, AND WHY IDENTITY IS NOT ENOUGH ──────────────────────────────────────
//
// A matching rollup address is necessary and not sufficient. A chain can keep its
// deployment and move its serialisation underneath it, and an identity check alone would
// call that compatible — so a pass requires BOTH halves:
//
//   IDENTITY  the node's own `node_getNodeInfo` against `chain-identity.json`:
//             l1ChainId, rollupVersion, rollupAddress, nodeVersion.
//   DECODE    one real transaction of that node's, parsed by the installed decoder.
//
// The decode half is the decisive one and it is the half a human cannot eyeball. Without
// `--runtime` there is no decoder, so the run reports `decode-not-attempted` and EXITS
// NON-ZERO unless `--identity-only` says that was the intent. A tool that quietly passed
// on the half it could reach is how the two months above happened.
//
// ── IT REFUSES TO PASS OVER NOTHING ───────────────────────────────────────────────────
//
// An undeclared chain, a declaration with no chains, a node that serves no transaction to
// try: each exits non-zero with its own name rather than reporting success over an empty
// subject set. `tools/journeys/README.md` rule 3.

import { readFileSync } from 'node:fs';

export const OUTCOMES = [
  'compatible',              // identity matches and one transaction decoded
  'identity-ok',             // identity matches; --identity-only, so nothing was decoded
  'identity-moved',          // the node is not the deployment we declared
  'decoder-refused',         // identity matches, the installed decoder cannot parse it
  'decode-not-attempted',    // no decoder, or the node served no transaction to try
  'chain-not-declared',      // nothing to compare against
  'node-unreachable',        // the transport produced no answer
];

export function parseArgs(argv) {
  const o = { url: '', chain: '', expect: 'tools/chain/chain-identity.json',
              runtime: '', identityOnly: false, scan: 160, json: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--url') o.url = argv[++i];
    else if (a === '--chain') o.chain = argv[++i];
    else if (a === '--expect') o.expect = argv[++i];
    else if (a === '--runtime') o.runtime = argv[++i];
    else if (a === '--scan') o.scan = Math.max(1, Number(argv[++i]));
    else if (a === '--identity-only') o.identityOnly = true;
    else if (a === '--json') o.json = true;
    else return { error: `unknown argument: ${a}` };
  }
  if (!o.chain) return { error: '--chain <name> is required' };
  if (!o.url) o.url = o.chain.includes('testnet') ? 'https://aztec-testnet.drpc.org'
                                                  : 'https://aztec.drpc.org';
  return o;
}

/** The four fields that say WHICH chain this is. Compared as a set so a report names every
 *  one that moved rather than the first — a restart moves several at once and seeing only
 *  `rollupVersion` invites the reading that the address is still ours. */
export function compareIdentity(declared, observed) {
  const fields = ['l1ChainId', 'rollupVersion', 'rollupAddress', 'nodeVersion'];
  const moved = [];
  for (const f of fields) {
    const want = f === 'rollupAddress' ? String(declared[f] ?? '').toLowerCase() : declared[f];
    const saw = f === 'rollupAddress' ? String(observed[f] ?? '').toLowerCase() : observed[f];
    if (want === undefined || want === null) continue;
    if (String(want) !== String(saw)) moved.push({ field: f, declared: want, observed: saw });
  }
  return moved;
}

const RPC_TIMEOUT_MS = 20_000;

// EVERY CALL IS BOUNDED. A node that accepts the connection and then says nothing is
// indistinguishable from a hang, and this check's whole job is to run unattended — a
// compatibility probe that can block forever is one more silent guard.
const rpcOver = (url) => async (method, params = []) => {
  const r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
                               signal: AbortSignal.timeout(RPC_TIMEOUT_MS),
                               body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${j.error.message ?? JSON.stringify(j.error)}`);
  return j.result;
};

/** The decoder, loaded from a runtime checkout the way `lib/body-proxy.mjs` loads it — from
 *  THAT tree's `replay/node_modules`, never from this repository, which carries no copy of a
 *  protocol library whose serialisation must agree byte for byte with the driver's.
 *
 *  `CHAIN_COMPAT_DECODER` names a module exporting `decodeOne(json)` instead. It exists so the
 *  self-test can drive every outcome offline: a decoder that needs a 300 MB checkout to prove
 *  it can report a refusal is a check nobody runs. */
async function loadDecoder({ runtime }) {
  const injected = process.env.CHAIN_COMPAT_DECODER;
  if (injected) {
    const m = await import(injected.startsWith('.') || injected.startsWith('/')
      ? injected : `./${injected}`);
    return { decodeOne: m.decodeOne, from: `CHAIN_COMPAT_DECODER=${injected}` };
  }
  if (!runtime) return null;
  const { pathToFileURL } = await import('node:url');
  const { resolve } = await import('node:path');
  const at = (p) => pathToFileURL(resolve(runtime, 'replay/node_modules', p)).href;
  for (const bb of ['@aztec-foundation/bb.js/dest/node/index.js', '@aztec/bb.js/dest/node/index.js']) {
    try {
      const { BarretenbergSync } = await import(at(bb));
      await BarretenbergSync.initSingleton();
      break;
    } catch { /* the next candidate, and a decode failure below reports it */ }
  }
  for (const sl of ['@aztec-labs/stdlib/dest/tx/index.js', '@aztec/stdlib/dest/tx/index.js']) {
    try {
      const { Tx } = await import(at(sl));
      return {
        from: sl.split('/dest')[0],
        // `parseAsync`, NOT `parse`: the schema became async in the 6.x line and the sync
        // call throws `Encountered Promise during synchronous parse`, which reads like a
        // malformed transaction and is not one.
        decodeOne: async (json) => {
          const tx = Tx.schema.parseAsync ? await Tx.schema.parseAsync(json) : Tx.schema.parse(json);
          return { ok: true, publicCalls: tx.numberOfPublicCalls(), txHash: tx.getTxHash().toString() };
        },
      };
    } catch { /* ditto */ }
  }
  return null;
}

export async function run(o) {
  const say = [];
  const log = (m) => { say.push(m); if (!o.json) console.log(m); };
  const finish = (outcome, detail) => {
    const ok = outcome === 'compatible' || (outcome === 'identity-ok' && o.identityOnly);
    if (o.json) console.log(JSON.stringify({ outcome, chain: o.chain, ...detail }, null, 1));
    else log(`${ok ? '' : '::error::'}${o.chain}: ${outcome} — ${detail.why}`);
    return { outcome, code: ok ? 0 : 1 };
  };

  let declaredAll;
  try { declaredAll = JSON.parse(readFileSync(o.expect, 'utf8')); }
  catch (e) { return finish('chain-not-declared', { why: `${o.expect} is unreadable: ${e.message}` }); }
  const chains = declaredAll?.chains ?? {};
  if (Object.keys(chains).length === 0) {
    return finish('chain-not-declared', { why: `${o.expect} declares no chains, so this check would compare nothing` });
  }
  const declared = chains[o.chain];
  if (!declared) {
    return finish('chain-not-declared', {
      why: `${o.expect} carries no entry for ${o.chain} (it declares ${Object.keys(chains).join(', ')}). `
         + `A chain followed without a declaration is a chain whose compatibility nothing checks.` });
  }

  const rpc = rpcOver(o.url);
  let info;
  try { info = await rpc('node_getNodeInfo'); }
  catch (e) { return finish('node-unreachable', { why: `${o.url} produced no node_getNodeInfo: ${e.message}` }); }

  const observed = {
    l1ChainId: info?.l1ChainId,
    rollupVersion: info?.rollupVersion,
    rollupAddress: info?.l1ContractAddresses?.rollupAddress,
    nodeVersion: info?.nodeVersion,
  };
  log(`  node      ${o.url}`);
  log(`  observed  l1ChainId=${observed.l1ChainId} rollupVersion=${observed.rollupVersion} `
    + `rollup=${observed.rollupAddress} nodeVersion=${observed.nodeVersion}`);

  const moved = compareIdentity(declared, observed);
  if (moved.length) {
    return finish('identity-moved', {
      moved,
      why: `${moved.length} identity field(s) moved: `
         + moved.map((m) => `${m.field} declared ${m.declared}, observed ${m.observed}`).join('; ')
         + `. A restart moves several at once, so every one is named rather than the first.` });
  }
  log(`  identity  matches ${o.expect} (${declared.decoder?.package} ${declared.decoder?.version} `
    + `verified ${declared.decoder?.verifiedOn ?? 'never'})`);

  const decoder = await loadDecoder(o);
  if (!decoder?.decodeOne) {
    // TWO DIFFERENT ANSWERS, and the difference is whether anybody MEANT to skip the
    // decode. `--identity-only` is a caller saying "I know this is the weaker half" and it
    // is a pass; without it, the strong half silently did not run, which is precisely the
    // state that let two months go by, so it is a refusal and not a warning.
    return o.identityOnly
      ? finish('identity-ok', {
          why: `identity matches and no decode was attempted, which --identity-only declared as `
             + `the intent. This does NOT establish that the chain's transactions can be decoded.` })
      : finish('decode-not-attempted', {
          why: `no decoder was loaded${o.runtime ? ` from ${o.runtime}/replay/node_modules` : ' (no --runtime)'}. `
             + `The identity half passed and the DECISIVE half did not run, which is the state this `
             + `check exists because of. Pass --identity-only if that was the intent.` });
  }

  // One real transaction of this node's, above the finalized tip so the body is still served.
  let tip, finalized;
  try { tip = await rpc('node_getBlockNumber'); finalized = await rpc('node_getBlockNumber', ['finalized']); }
  catch (e) { return finish('node-unreachable', { why: `the node stopped answering mid-check: ${e.message}` }); }
  let subject = null;
  for (let n = tip; n > Math.max(finalized, tip - o.scan) && !subject; n -= 1) {
    const b = await rpc('node_getBlock', [n, { includeTransactions: true }]).catch(() => null);
    const h = ((b?.body?.txEffects) ?? []).map((e) => e.txHash).filter(Boolean)[0];
    if (h) subject = { block: n, hash: h };
  }
  if (!subject) {
    return finish('decode-not-attempted', {
      why: `no transaction above the finalized tip in blocks ${Math.max(finalized, tip - o.scan) + 1}..${tip}, `
         + `so the decoder was never asked. Arrivals on this chain are bursty — this is a quiet `
         + `window and not a verdict. Re-run, or widen --scan.` });
  }
  const json = await rpc('node_getTxByHash', [subject.hash]).catch(() => null);
  if (!json) {
    return finish('decode-not-attempted', {
      why: `block ${subject.block}'s ${subject.hash} finalized between enumeration and the fetch, so `
         + `its body was pruned before the decoder saw it. Nothing is known about compatibility.` });
  }

  try {
    const r = await decoder.decodeOne(json);
    // SELF-CONSISTENT, not merely non-throwing. `Tx.toBuffer` serialises `txHash` first, so a
    // decode that produces a different hash from the key requested decoded something else.
    if (r?.txHash && r.txHash.toLowerCase() !== subject.hash.toLowerCase()) {
      return finish('decoder-refused', {
        why: `${decoder.from} decoded block ${subject.block}'s ${subject.hash} into a transaction whose `
           + `own hash is ${r.txHash}. A decode that disagrees with the key it was given is a miss `
           + `wearing a success.` });
    }
    return finish('compatible', {
      decoder: decoder.from, block: subject.block, tx: subject.hash, publicCalls: r?.publicCalls ?? null,
      why: `${decoder.from} decoded block ${subject.block}'s ${subject.hash} (publicCalls=${r?.publicCalls ?? '?'}) `
         + `and the decoded hash equals the key requested` });
  } catch (e) {
    return finish('decoder-refused', {
      decoder: decoder.from, block: subject.block, tx: subject.hash,
      why: `${decoder.from} refused block ${subject.block}'s ${subject.hash}: `
         + `${String(e.message).split('\n')[0].slice(0, 200)}. The identity matched, so this is a `
         + `SERIALISATION difference under an unchanged deployment, or a decoder that is not the `
         + `one this deployment speaks.` });
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const o = parseArgs(process.argv.slice(2));
  if (o.error) { console.error(`check-chain-compat: ${o.error}`); process.exit(2); }
  try { const r = await run(o); process.exit(r.code); }
  catch (e) { console.error(`check-chain-compat: ${e.stack ?? e.message}`); process.exit(2); }
}
