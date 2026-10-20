#!/usr/bin/env node
// starknet-producer-selftest.mjs — the Starknet producer's facts and refusals, watched
// going red.
//
//   node tools/chain/starknet-producer-selftest.mjs
//
// Offline and toolchain-free: no network, no recorder, no `ct-print`. Everything is
// driven from literals shaped exactly as Starknet RPC 0.10 (api.cartridge.gg, spec 0.10.2)
// and `codetracer-cairo-onchain trace-block` write them — field names and nesting copied
// from mainnet blocks 16,664,301 and 480,000 read on 2026-10-20. A TRACED row needs a
// container, which this repository refuses to commit, so traced rows are exercised by
// `just starknet-capture` over the committed transcript; this suite covers what can be
// decided without one:
//
//   §1  the facts module: the three-dimension cost vector and the fee, the roles each
//       transaction type has (and the one that has none), the payload a multicall names
//   §2  the producer end to end over container-free captures: every transaction the
//       capture saw is a row, a refused era publishes its refusals, and an input that
//       cannot be published honestly — no floor probe, a probe whose controls did not
//       hold, a foreign report format, a report missing a row — is refused, not published
//       around
//
// Every arm that asserts a refusal or a distinction has a control beside it that takes
// the other branch, so the arm measures the rule and not the fixture
// (spec/Testing/Verification-Harness-Traps.md).

import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  CHAIN_SLUG, IDENTIFIER_ENCODING, PRESTATE_STRATEGY, RECORDER,
  costVectorForRow, executionsForRow, payloadForRow, rolesForRow,
} from './lib/starknet-producer-facts.mjs';
import { BLOCK_REPORT_FORMAT, main as produce } from './produce-starknet-snapshot.mjs';

let asserted = 0;
let failed = 0;
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`);
};
const test = (name) => console.error(`\n${name}`);
const DECLARED = 26;

const SENDER = '0x48ddc53f41523d2a6b40c3dff7f69f4bbac799cd8b2e3fc50d3de1d4119441f';
const TARGET = '0x4718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d';
const SEL = '0x83afd3f4caedc6eebf44246fe54e38c95e3179a5ec9ea81740eca5b482d12e';

/** An INVOKE v3 body as `starknet_getBlockWithReceipts` returns it. */
const invokeV3 = (sender = SENDER) => ({
  type: 'INVOKE',
  version: '0x3',
  sender_address: sender,
  calldata: ['0x1', TARGET, SEL, '0x3', '0x1176a1bd8', '0xebb2001c3a8f00', '0x0'],
  resource_bounds: {
    l1_gas: { max_amount: '0x0', max_price_per_unit: '0x38d7ea4c68000' },
    l1_data_gas: { max_amount: '0x1388', max_price_per_unit: '0x9184e72a000' },
    l2_gas: { max_amount: '0x7f7f5c5bf8', max_price_per_unit: '0x174876e800' },
  },
});
const receiptOf = ({ hash, status = 'SUCCEEDED', unit = 'FRI', contract } = {}) => ({
  transaction_hash: hash,
  type: 'INVOKE',
  execution_status: status,
  finality_status: 'ACCEPTED_ON_L2',
  actual_fee: { amount: '0xebb2001c3a8f00', unit },
  execution_resources: { l1_gas: 0, l1_data_gas: 704, l2_gas: 4205440 },
  events: [],
  messages_sent: [],
  ...(contract ? { contract_address: contract } : {}),
});
const HEADER = {
  block_hash: '0x2890e47db3c92608061ecd2cfe1afac00fe63f100267e83cb15d96c2091fbe2',
  new_root: '0x261ce2fe9123c6717cc6229e286c6e2132cca568685393333aa2e70074da824',
  l1_gas_price: { price_in_fri: '0x29805df3b670', price_in_wei: '0x3f7b23c1' },
  l1_data_gas_price: { price_in_fri: '0x4e3fb27ca', price_in_wei: '0x77b0b' },
  l2_gas_price: { price_in_fri: '0x3ac133f91', price_in_wei: '0x59df2' },
};

test('§1 the facts module');
{
  ck('the chain slug, recorder and prestate strategy are the declared ones',
     CHAIN_SLUG === 'starknet-mainnet' && RECORDER.id === 'starknet-cairo'
     && PRESTATE_STRATEGY === 'replay-preceding');
  ck('every identifier kind is declared hex — the felt row of Search-And-Routing.md §2',
     IDENTIFIER_ENCODING.transaction === 'hex' && IDENTIFIER_ENCODING.address === 'hex'
     && IDENTIFIER_ENCODING.block === 'hex');

  const v = costVectorForRow({ body: invokeV3(), receipt: receiptOf({ hash: '0x1' }), header: HEADER });
  ck('a v3 transaction publishes THREE resource dimensions plus the fee',
     JSON.stringify(v.map((d) => d.name)) === '["l1Gas","l1DataGas","l2Gas","fee"]');
  const l2 = v.find((d) => d.name === 'l2Gas');
  ck('…each dimension\'s `used` is the receipt\'s, its `limit` the sender\'s bound, its price the block\'s in the fee\'s unit',
     l2.used === '4205440' && l2.limit === '0x7f7f5c5bf8' && l2.price === '0x3ac133f91'
     && l2.token === 'STRK');
  const fee = v.find((d) => d.name === 'fee');
  ck('…and the fee is the receipt\'s `actual_fee` in its own unit, verbatim',
     fee.used === '0xebb2001c3a8f00' && fee.unit === 'FRI');
  const w = costVectorForRow({ body: { type: 'INVOKE', version: '0x1', max_fee: '0x2386f26fc10000' },
                               receipt: receiptOf({ hash: '0x1', unit: 'WEI' }), header: HEADER });
  ck('CONTROL: a v1 transaction paid in WEI prices in WEI, bounds the FEE by `max_fee` and no dimension',
     w.find((d) => d.name === 'l2Gas').price === '0x59df2'
     && w.find((d) => d.name === 'l2Gas').limit === ''
     && w.find((d) => d.name === 'fee').limit === '0x2386f26fc10000'
     && w.find((d) => d.name === 'fee').token === 'ETH');

  const inv = rolesForRow({ body: invokeV3(), receipt: receiptOf({ hash: '0x1' }) });
  ck('an INVOKE is sent and paid for by its account contract — two roles, one address',
     inv.length === 2 && inv.every((r) => r.address === SENDER)
     && inv.map((r) => r.role).join(',') === 'sender,feePayer');
  const l1h = rolesForRow({ body: { type: 'L1_HANDLER', contract_address: TARGET,
                                   entry_point_selector: SEL, calldata: ['0xabc'] },
                            receipt: receiptOf({ hash: '0x2' }) });
  ck('an L1_HANDLER has NO ordinary sender, so it states no role rather than inventing one',
     l1h.length === 0);
  const dep = rolesForRow({ body: { type: 'DEPLOY_ACCOUNT' },
                            receipt: receiptOf({ hash: '0x3', contract: TARGET }) });
  ck('CONTROL: a DEPLOY_ACCOUNT\'s sender is the account it deploys, from the receipt',
     dep.length === 2 && dep[0].address === TARGET);

  const p = payloadForRow({ body: invokeV3() });
  ck('an INVOKE\'s payload is its first call\'s target and selector, as the felts they are',
     p.target === TARGET && p.selector === SEL && p.raw === '');
  const bad = payloadForRow({ body: { ...invokeV3(), calldata: ['0x1', TARGET, SEL, '0xff'] } });
  ck('CONTROL: a calldata whose first call does not decode states neither, rather than a guess',
     bad.target === '' && bad.selector === '');
  const h = payloadForRow({ body: { type: 'L1_HANDLER', contract_address: TARGET,
                                   entry_point_selector: SEL } });
  ck('an L1_HANDLER\'s payload is the entry point it calls on the contract it calls',
     h.target === TARGET && h.selector === SEL);
  ck('an untraced row\'s single execution carries its reason; a traced row\'s carries none',
     executionsForRow('why')[0].reason === 'why' && executionsForRow(null)[0].reason === undefined);
}

// ── §2 the producer, end to end, over container-free captures ─────────────────────────
const work = mkdtempSync(join(tmpdir(), 'starknet-producer-selftest-'));
const FLOOR = {
  pipelineFloor: 501514,
  executorFloor: { block: 501514, version: '0.13.0', versionBelow: '0.12.3',
                   acceptedAtFloor: true, refusedBelow: true },
  nodeState: { positiveControlHeld: true, negativeControlHeld: true },
  binds: 'executor',
  tipAtProbe: 16667292,
};
let seq = 0;
/** A capture directory as `trace-block` writes one, with no recorded transaction. */
function capture({ block = 480000, version = '0.12.3', n = 3, recordedOne = false,
                   probe = FLOOR, format = BLOCK_REPORT_FORMAT, dropReport = false,
                   outcome = 'refused' } = {}) {
  const dir = join(work, `cap-${seq++}`);
  mkdirSync(dir, { recursive: true });
  const hashes = Array.from({ length: n }, (_, i) => `0x${(block * 100 + i).toString(16)}`);
  const reports = hashes.map((h, i) => (outcome === 'refused'
    ? { txHash: h, txIndex: i, outcome: 'refused', refusalReason: 'runtime-refused',
        refusal: `the executor refused the transaction: block ${block}: the executor carries `
          + `no versioned constants for Starknet ${version}`, recorded: false,
        vm: { steps: 0 } }
    : { txHash: h, txIndex: i, outcome: 'replayed', recorded: recordedOne && i === 0,
        effects: { matched: 9, mismatched: 0, facts: [] }, vm: { steps: 100 } }));
  writeFileSync(join(dir, 'block.json'), JSON.stringify({
    format,
    recorder: { executor: 'blockifier 0.20.0-rc.1 (crates.io) + blockifier-patch' },
    endpoint: 'https://api.cartridge.gg/x/starknet/mainnet',
    blockNumber: block,
    blockHash: `0x${block.toString(16)}abc`,
    parentHash: `0x${(block - 1).toString(16)}abc`,
    starknetVersion: version,
    timestamp: 1700000000,
    chain: {
      tip: 16667292, l1Accepted: 16663863, specVersion: '0.10.2',
      endpointControl: { classified: 'absent', code: -32601 },
      header: HEADER,
      transactions: hashes.map((h) => ({ hash: h, body: invokeV3(), receipt: receiptOf({ hash: h }) })),
    },
    floorProbe: probe,
    perTransaction: dropReport ? reports.slice(1) : reports,
  }));
  return dir;
}
async function runProducer(argv) {
  try {
    await produce(argv);
    return { ok: true };
  } catch (e) {
    return { ok: false, kind: e.refusalKind, message: e.message };
  }
}

test('§2 the producer end to end, over captures with no container in them');
{
  const out = join(work, 'tree-refused');
  const r = await runProducer(['--capture', capture(), '--recorder-commit', 'abc1234',
                               '--out', out, '--captured-at', '2026-10-20T00:00:00Z']);
  ck(`a window of an era the executor does not carry PUBLISHES its refusals (${r.message ?? 'ok'})`,
     r.ok);
  const s = r.ok ? JSON.parse(readFileSync(join(out, 'snapshot.json'), 'utf8')) : {};
  ck('…every transaction the capture saw is a row, and accountedFor reconciles',
     s.counts?.transactions === 3 && s.counts?.accountedFor === 3);
  ck('…each row is `refused` / `runtime-refused`, with the executor\'s own sentence',
     (s.transactions ?? []).every((t) => t.outcome === 'refused'
       && t.refusalReason === 'runtime-refused' && /0\.12\.3/.test(t.reason)));
  ck('…the floor is the probe\'s, not a typed number, and the window is derived from it',
     s.window?.replayableFrom === 501514 && s.window?.blocks === 16667292 - 501514 + 1
     && s.provenance?.floorProbe?.binds === 'executor');
  ck('…and the provenance states the recorder, the strategy and the encoding from the facts module',
     s.provenance?.recorder?.id === RECORDER.id
     && s.provenance?.prestateStrategy === PRESTATE_STRATEGY
     && s.provenance?.identifierEncoding?.transaction === 'hex');

  const out2 = join(work, 'tree-not-attempted');
  const r2 = await runProducer(['--capture', capture({ block: 16664437, version: '0.14.4', outcome: 'replayed' }),
                                '--recorder-commit', 'abc1234', '--out', out2]);
  const s2 = r2.ok ? JSON.parse(readFileSync(join(out2, 'snapshot.json'), 'utf8')) : {};
  ck('CONTROL: rows that replayed and were not recorded are `not-attempted`, not refused',
     r2.ok && (s2.transactions ?? []).every((t) => t.outcome === 'not-attempted'
                                              && t.refusalReason === 'not-attempted'));

  const noProbe = await runProducer(['--capture', capture({ probe: null }), '--recorder-commit',
                                     'abc1234', '--out', join(work, 'x1')]);
  ck('a run with no floor probe is REFUSED as a source defect — a typed floor is not published',
     !noProbe.ok && noProbe.kind === 'source' && /floor probe/.test(noProbe.message));
  const badProbe = await runProducer(['--capture',
    capture({ probe: { ...FLOOR, nodeState: { positiveControlHeld: true, negativeControlHeld: false } } }),
    '--recorder-commit', 'abc1234', '--out', join(work, 'x2')]);
  ck('a probe whose negative control did not hold is REFUSED — the instrument did not discriminate',
     !badProbe.ok && /controls did not all hold/.test(badProbe.message));
  const foreign = await runProducer(['--capture', capture({ format: 'something-else@1' }),
                                     '--recorder-commit', 'abc1234', '--out', join(work, 'x3')]);
  ck('a block report in a format this producer does not read is REFUSED by name',
     !foreign.ok && /something-else@1/.test(foreign.message));
  const short = await runProducer(['--capture', capture({ dropReport: true }),
                                   '--recorder-commit', 'abc1234', '--out', join(work, 'x4')]);
  ck('a capture whose reports miss a transaction is REFUSED — the denominator is every transaction',
     !short.ok && /report\(s\) for 3 transaction/.test(short.message));
  const twice = await runProducer(['--capture', capture(), '--capture', capture(),
                                   '--recorder-commit', 'abc1234', '--out', join(work, 'x5')]);
  ck('one block captured twice is REFUSED as a configuration error',
     !twice.ok && twice.kind === 'config');
  const noCommit = await runProducer(['--capture', capture(), '--out', join(work, 'x6')]);
  ck('CONTROL: a missing --recorder-commit is a configuration refusal, not a source one',
     !noCommit.ok && noCommit.kind === 'config');

  const recorded = await runProducer(['--capture', capture({ block: 16664437, version: '0.14.4',
                                                             outcome: 'replayed', recordedOne: true }),
                                      '--recorder-commit', 'abc1234', '--out', join(work, 'x7'),
                                      '--ct-print', '/nonexistent/ct-print']);
  ck('a recorded row with no container beside it is REFUSED rather than published as traced',
     !recorded.ok);
}

rmSync(work, { recursive: true, force: true });
console.error('');
console.error(`assertion count: ${asserted} (${asserted === DECLARED ? 'as declared' : `DECLARED ${DECLARED}`})`);
if (failed > 0 || asserted !== DECLARED) {
  console.error(`FAIL — ${failed} assertion(s) failed`);
  process.exit(1);
}
console.error('PASS — the Starknet producer\'s facts and refusals are applied, and every refusal has been watched firing');
