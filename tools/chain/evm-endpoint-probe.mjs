#!/usr/bin/env node
// evm-endpoint-probe.mjs — what an EVM instance's public endpoints serve, measured: chain id,
// tip and finalized head, a control for "method not served", state reads at a ladder of depths
// (the history floor, Recorder-EVM CXP-EVM-1), and the prestate tier on offer
// (Chain-Support-Matrix §1.4: `prestate-trace` where `debug_traceTransaction` serves
// `prestateTracer`, otherwise archive state for `replay-preceding`).
//
// Usage:
//   node tools/chain/evm-endpoint-probe.mjs --rpc <url>[,<url>…] --account <0x…> \
//        --depths <n>[,<n>…] --out <file> [--chain <label>]
//
// The depth reads carry the same two-sided control as tools/chain/measurements/
// evm-endpoint-capability.json: at each depth `eth_getProof`'s balance and nonce must equal
// `eth_getBalance` and `eth_getTransactionCount` (agreement across methods), and the readings
// must not all be one value (disagreement across depth). Choose an account whose balance
// changes over history, or the second clause cannot be met and the reading says so.
// A depth that one endpoint answers and another refuses is that endpoint's floor, not the
// instance's; the instance's floor is the shallowest depth no probed endpoint answers.

import { writeFileSync } from 'node:fs';

const flag = (name) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : undefined;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const hex = (n) => `0x${n.toString(16)}`;

async function call(rpc, method, params) {
  for (let attempt = 0; ; attempt++) {
    let body;
    try {
      const res = await fetch(rpc, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(45000),
      });
      const text = await res.text();
      try { body = JSON.parse(text); } catch { body = { error: { message: `HTTP ${res.status}: ${text.slice(0, 120)}` } }; }
    } catch (err) {
      body = { error: { message: err.message } };
    }
    const msg = String(body.error?.message ?? '');
    const limited = /rate limit|429|too many/i.test(msg);
    if (!limited || attempt >= 4) return body;
    await sleep(2000 * 2 ** attempt);
  }
}

const short = (e) => (e ? { code: e.code ?? null, message: String(e.message).slice(0, 160) } : null);

async function probe(rpc, account, depths) {
  const out = { url: rpc };
  const cid = await call(rpc, 'eth_chainId', []);
  out.chainId = cid.result ?? short(cid.error);
  const cv = await call(rpc, 'web3_clientVersion', []);
  out.clientVersion = cv.result ?? short(cv.error);
  for (const tag of ['latest', 'finalized']) {
    const b = await call(rpc, 'eth_getBlockByNumber', [tag, false]);
    out[tag === 'latest' ? 'tip' : 'finalized'] = b.result ? parseInt(b.result.number, 16) : short(b.error);
  }
  const ctl = await call(rpc, 'thisMethodDoesNotExist', []);
  out.control = { method: 'thisMethodDoesNotExist', answer: short(ctl.error) ?? 'ANSWERED (control fails)' };

  out.depths = [];
  for (const d of depths) {
    const tag = hex(d);
    const [bal, non, pf] = [await call(rpc, 'eth_getBalance', [account, tag]),
                            await call(rpc, 'eth_getTransactionCount', [account, tag]),
                            await call(rpc, 'eth_getProof', [account, [], tag])];
    const row = { block: d };
    if (bal.result !== undefined && non.result !== undefined && pf.result) {
      row.balance = bal.result;
      row.nonce = non.result;
      row.proofNodes = pf.result.accountProof.length;
      row.proofAgrees = BigInt(pf.result.balance) === BigInt(bal.result)
                     && BigInt(pf.result.nonce) === BigInt(non.result);
    } else {
      row.refused = short(bal.error ?? non.error ?? pf.error ?? { message: 'no result' });
    }
    out.depths.push(row);
  }
  const answered = out.depths.filter((r) => !r.refused);
  out.archive = {
    answered: answered.map((r) => r.block),
    refused: out.depths.filter((r) => r.refused).map((r) => r.block),
    proofAgreesAtEveryAnsweredDepth: answered.length > 0 && answered.every((r) => r.proofAgrees),
    distinctBalances: new Set(answered.map((r) => r.balance)).size,
  };

  // the prestate tier: one real transaction from the deepest answered depth's block
  const at = answered.length ? answered[answered.length - 1].block : null;
  if (at !== null) {
    const blk = await call(rpc, 'eth_getBlockByNumber', [hex(at), false]);
    const tx = blk.result?.transactions?.[0];
    if (tx) {
      const pre = await call(rpc, 'debug_traceTransaction', [tx, { tracer: 'prestateTracer' }]);
      out.prestateTracer = { tx, served: !!pre.result,
                             accounts: pre.result ? Object.keys(pre.result).length : undefined,
                             refused: short(pre.error) ?? undefined };
    }
    const tb = await call(rpc, 'trace_block', [hex(at)]);
    out.traceBlock = { block: at, served: Array.isArray(tb.result), refused: short(tb.error) ?? undefined };
  }
  return out;
}

async function main() {
  const rpcs = flag('rpc')?.split(',');
  const account = flag('account');
  const depths = flag('depths')?.split(',').map(Number);
  const out = flag('out');
  if (!rpcs || !account || !depths || !out || depths.some((d) => !Number.isInteger(d))) {
    console.error('usage: evm-endpoint-probe.mjs --rpc <url>[,…] --account <0x…> --depths <n>[,…] --out <file>');
    return 2;
  }
  const endpoints = [];
  for (const r of rpcs) endpoints.push(await probe(r, account, depths));
  const servedBy = (d) => endpoints.filter((e) => e.archive.answered.includes(d)).map((e) => e.url);
  const unanswered = depths.filter((d) => servedBy(d).length === 0);
  const doc = {
    format: 'blocktracer/evm-endpoint-probe@1',
    chain: flag('chain') ?? null,
    measuredAt: new Date().toISOString(),
    measuredBy: 'tools/chain/evm-endpoint-probe.mjs',
    account,
    endpoints,
    instance: {
      floor: unanswered.length === 0 ? 'no floor found: every probed depth answered by at least one endpoint'
                                     : `shallowest unanswered probed depth ${Math.max(...unanswered)}`,
      archiveSources: endpoints.filter((e) => e.archive.answered.length === depths.length
                                           && e.archive.proofAgreesAtEveryAnsweredDepth).map((e) => e.url),
      prestateTraceSources: endpoints.filter((e) => e.prestateTracer?.served).map((e) => e.url),
      perDepth: depths.map((d) => ({ block: d, answeredBy: servedBy(d).length })),
    },
  };
  writeFileSync(out, `${JSON.stringify(doc, null, 1)}\n`);
  console.log(`wrote ${out}: floor ${doc.instance.floor}; archive sources ${doc.instance.archiveSources.length}; `
              + `prestate-trace sources ${doc.instance.prestateTraceSources.length}`);
  for (const e of endpoints) {
    console.log(`  ${e.url}: answered ${e.archive.answered.length}/${depths.length}, `
                + `proof agrees ${e.archive.proofAgreesAtEveryAnsweredDepth}, `
                + `${e.archive.distinctBalances} distinct balances, prestateTracer ${e.prestateTracer?.served ?? 'n/a'}`);
  }
  return 0;
}

main().then((rc) => process.exit(rc), (err) => { console.error(`evm-endpoint-probe: ${err.message}`); process.exit(1); });
