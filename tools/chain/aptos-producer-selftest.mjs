#!/usr/bin/env node
// aptos-producer-selftest.mjs — the Aptos producer's facts and refusals, watched going red.
//
//   node tools/chain/aptos-producer-selftest.mjs
//
// Offline and toolchain-free: no network, no recorder, no `ct-print`, no aptos CLI.
// Everything is driven from literals shaped exactly as Aptos's REST API (`/v1/blocks/
// by_height/{h}?with_transactions=true`) and `aptos move replay` write them — field names
// and nesting copied from mainnet block 1,158,421,321 read on 2026-11-03. A row WITH a
// recording needs a container, which this repository refuses to commit, so those rows are
// exercised by `just aptos-capture` from the committed transcript; this suite covers what
// can be decided without one:
//
//   §1  the facts module: the declarations a reader must be told, the cost vector as the
//       chain's product in octas with the refund signed, roles (self-paid, sponsored) and
//       the payload
//   §2  the comparison a recorded row publishes: a clean replay, and the CLI's own
//       mismatch sentence read back into the one fact that differed
//   §3  the recording id the capture hands the recorder: a function of the transaction
//   §4  the producer end to end over a container-free window: rows carry their version,
//       the protocol's own transactions are system transactions and never rows, and a
//       broken window or a foreign recording is refused rather than published around
//   §5  the REST transcript: request keys, the tip mark, and a replay that serves what it
//       holds and misses — loudly — what it does not
//   §6  the floor's reason names the node's pruning, and the verification sentence names
//       what a mismatch becomes
//   §7  the source provider's offline parts: the package registry and source map read
//       from BCS, the compiler versions read from a module, the specification syntax it
//       may change and how, and what a row says for a verified and an unverified module.
//       Compiling and comparing need the aptos CLI and run in `just aptos-capture`
//
// Every arm that asserts a refusal or a distinction has a control beside it that takes
// the other branch, so the arm measures the rule and not the fixture
// (spec/Testing/Verification-Harness-Traps.md).

import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  CHAIN_SLUG, IDENTIFIER_ENCODING, IDENTITY, INSTRUCTION_SET, ORDERING, PRESTATE_STRATEGY,
  RECORDER, VERIFICATION, costVectorForRow, effectsFromReplay, payloadForRow, reachReasonFor,
  rolesForRow,
} from './lib/aptos-producer-facts.mjs';
import { derivedRecordingId } from './lib/aptos-rest.mjs';
import { ACQUISITION_FORMAT, REPLAY_MISMATCH, main as produce } from './produce-aptos-snapshot.mjs';
import {
  decodeBody, encodeBody, isTipDependent, requestKey, startTranscriptServer,
} from './aptos-rest-transcript.mjs';
import {
  artifactFromResolution, compilationMetadata, compilerErrorLocations, decodePackageRegistry,
  decodeSourceMap, rewriteSpecStatement, inlineSpecStatements, specRegions,
} from './lib/aptos-source.mjs';
import { gzipSync } from 'node:zlib';

let asserted = 0;
let failed = 0;
const ck = (label, cond) => {
  asserted++;
  if (!cond) { failed++; console.error(`  FAIL  ${label}`); } else console.error(`  ok    ${label}`);
};
const test = (name) => console.error(`\n${name}`);

const A = `0x${'a'.repeat(64)}`;
const B = `0x${'b'.repeat(64)}`;
const h = (c) => `0x${c.repeat(64)}`;

/** A user transaction as the REST API publishes it inside a block. */
const userTx = ({ version, hash, sender = A, signature = { type: 'ed25519_signature' },
                  success = true, refund = '0', fn = '0x1::aptos_account::transfer' } = {}) => ({
  type: 'user_transaction', version: String(version), hash, success,
  vm_status: success ? 'Executed successfully' : 'Move abort',
  gas_used: '5414', gas_unit_price: '100', max_gas_amount: '20000',
  state_change_hash: h('5'), event_root_hash: h('6'),
  sender, signature,
  payload: { type: 'entry_function_payload', function: fn, type_arguments: [], arguments: [] },
  events: [{ type: '0x1::transaction_fee::FeeStatement',
             data: { storage_fee_refund_octas: refund, total_charge_gas_units: '5414' } }],
});
const sysTx = (type, version, hash) => ({ type, version: String(version), hash, success: true });

test('§1 the facts a reader must be told, stated rather than assumed');
{
  const contract = JSON.parse(readFileSync(new URL('./snapshot-contract.json', import.meta.url), 'utf8'));
  ck('the chain is Aptos mainnet under its CAIP-2 id, APT with 8 decimals, instantly final',
     CHAIN_SLUG === 'aptos-mainnet' && IDENTITY.caip2 === 'aptos:1'
     && IDENTITY.nativeCurrency.symbol === 'APT' && IDENTITY.nativeCurrency.decimals === 8
     && IDENTITY.finality.rule === 'instant' && IDENTITY.family === 'move');
  ck('the block time is the measured ~37 ms, a positive integer',
     Number.isInteger(IDENTITY.blockTimeMs) && IDENTITY.blockTimeMs === 37);
  ck('the format is the registered Aptos dialect of Move, not the bare family',
     INSTRUCTION_SET === 'aptos-move' && RECORDER.id === 'aptos-move');
  ck('the ordering is the ledger version, and the prestate strategy is in §1.4\'s closed set',
     ORDERING === 'globalVersion'
     && contract.prestateStrategies.tokens.includes(PRESTATE_STRATEGY)
     && PRESTATE_STRATEGY === 'version-addressed');
  ck('every identifier kind is hex', Object.values(IDENTIFIER_ENCODING).every((e) => e === 'hex'));

  const c = costVectorForRow(userTx({ version: 1, hash: h('1'), refund: '4400' }));
  ck('the fee is gas used × unit price, in octas, with its limit at that price',
     c[0].name === 'gas' && c[0].used === '541400' && c[0].limit === '2000000'
     && c[0].price === '100' && c[0].unit === 'octa' && c[0].token === 'APT');
  ck('the storage refund the chain\'s FeeStatement states is its own NEGATIVE entry',
     c[1].name === 'storageFeeRefund' && c[1].used === '-4400');
  const noEvent = { ...userTx({ version: 1, hash: h('1') }), events: [] };
  ck('CONTROL: no FeeStatement, or a zero refund, publishes a refund of 0 and no sign',
     costVectorForRow(noEvent)[1].used === '0'
     && costVectorForRow(userTx({ version: 1, hash: h('1'), refund: '0' }))[1].used === '0');
  ck('a fee larger than 2^53 octas is multiplied exactly, as integers',
     costVectorForRow({ gas_used: '9007199254740993', gas_unit_price: '3' })[0].used
       === '27021597764222979');

  const self = rolesForRow(userTx({ version: 1, hash: h('1') }));
  ck('a self-paid transaction names its sender, who is also the fee payer',
     JSON.stringify(self) === JSON.stringify([{ role: 'sender', address: A },
                                              { role: 'feePayer', address: A }]));
  const sponsored = rolesForRow(userTx({ version: 1, hash: h('1'),
    signature: { type: 'fee_payer_signature', fee_payer_address: B } }));
  ck('CONTROL: a fee-payer transaction names the sponsor as the fee payer, not the sender',
     JSON.stringify(sponsored) === JSON.stringify([{ role: 'sender', address: A },
       { role: 'sponsor', address: B }, { role: 'feePayer', address: B }]));

  const p = payloadForRow(userTx({ version: 1, hash: h('1'), fn: '0x75b4::scripts::swap' }));
  ck('an entry function is its selector, and its module address is the target',
     p.selector === '0x75b4::scripts::swap' && p.target === '0x75b4');
  ck('CONTROL: a script payload names its kind and no target',
     JSON.stringify(payloadForRow({ payload: { type: 'script_payload' } }))
       === JSON.stringify({ raw: '', selector: 'script_payload', target: '' }));
}

test('§2 the comparison a recorded row publishes');
{
  const tx = userTx({ version: 7881330395, hash: h('1') });
  const clean = effectsFromReplay(tx, null);
  ck('a clean replay matched all four facts the CLI compares',
     clean.reproduced === true && clean.matched === 4 && clean.mismatched === 0
     && clean.compared.join() === 'status,gasUsed,writeSetHash,eventRootHash');
  const gas = effectsFromReplay(tx, `${REPLAY_MISMATCH}: version:7881330395, gas_used:5415, `
    + 'expected:5414');
  ck('a gas mismatch is the one differing fact, with both readings',
     gas.reproduced === false && gas.mismatched === 1
     && gas.mismatches[0].field === 'gasUsed' && gas.mismatches[0].published === '5414'
     && gas.mismatches[0].replayed === '5415');
  ck('…and the facts before it matched, and the ones after it were NOT compared',
     gas.matched === 1 && gas.compared.join() === 'status,gasUsed');
  const status = effectsFromReplay(tx, `${REPLAY_MISMATCH}: version:7881330395, `
    + 'status:Keep(OutOfGas), auxiliary data:None, expected:Keep(Success)');
  ck('CONTROL: a status mismatch is the first fact, so nothing is reported matched',
     status.matched === 0 && status.mismatches[0].field === 'status'
     && status.mismatches[0].replayed === 'Keep(OutOfGas)');
}

test('§3 the recording id is a function of the transaction');
{
  const one = await derivedRecordingId(1793704220221, h('1'));
  const again = await derivedRecordingId(1793704220221, h('1'));
  ck('the same transaction derives the same id', one === again);
  ck('it is a UUIDv7 whose timestamp is the block\'s millisecond',
     /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(one)
     && one.replace(/-/g, '').slice(0, 12) === (1793704220221).toString(16).padStart(12, '0'));
  ck('CONTROL: another transaction in the same millisecond derives another id',
     one !== await derivedRecordingId(1793704220221, h('2')));
}

test('§4 the producer, end to end, over a container-free window');
{
  const dir = mkdtempSync(join(tmpdir(), 'aptos-producer-selftest-'));
  const block = (height, first, txs) => ({
    block_height: String(height), block_hash: h(String(height % 10)),
    block_timestamp: '1793704220221025', first_version: String(first),
    last_version: String(first + txs.length - 1), transactions: txs,
  });
  const b10 = block(10, 100, [sysTx('block_metadata_transaction', 100, h('a')),
    userTx({ version: 101, hash: h('b') }), userTx({ version: 102, hash: h('c') }),
    sysTx('block_epilogue_transaction', 103, h('d'))]);
  const b11 = block(11, 104, [sysTx('block_metadata_transaction', 104, h('e')),
    sysTx('block_epilogue_transaction', 105, h('f'))]);
  const acquisition = (blocks, { oldest = 5 } = {}) => ({
    format: ACQUISITION_FORMAT, endpoint: 'https://fullnode.example.invalid',
    fetchedAt: '2026-11-03T00:00:00Z', replayRuntime: 'aptos 9.9.9',
    ledger: { chainId: 1, ledgerVersion: '500', oldestLedgerVersion: '50', blockHeight: 20,
              oldestBlockHeight: oldest },
    window: { from: 10, to: 11 }, predecessor: { height: 9, hash: h('9') }, blocks,
  });
  const write = (name, obj) => { const p = join(dir, name); writeFileSync(p, JSON.stringify(obj)); return p; };
  const commit = '1'.repeat(40);
  const run = async (acq, extra = []) => {
    try {
      await produce(['--acquisition', acq, '--replay-root', join(dir, 'replay'),
                     '--recorder-commit', commit, '--out', join(dir, 'tree'), ...extra]);
      return null;
    } catch (e) { return e.message; }
  };
  const bigRec = join(dir, 'rec-101');
  mkdirSync(bigRec, { recursive: true });
  writeFileSync(join(bigRec, 'done.json'), JSON.stringify({ version: '101', hash: h('b'),
    outcome: 'too-large', refusal: 'TRACE-TOO-LARGE', recorderCommit: commit }));

  const good = write('good.json', acquisition([b10, b11]));
  const ok = await run(good, ['--rec', bigRec]);
  ck(`a whole window produces a tree — ${ok ?? 'no refusal'}`, ok === null);
  if (ok === null) {
    const snap = JSON.parse(readFileSync(join(dir, 'tree', 'snapshot.json'), 'utf8'));
    const by = Object.fromEntries(snap.transactions.map((t) => [t.txHash, t]));
    ck('the denominator is the USER transactions: two rows, the protocol\'s four are not rows',
       snap.transactions.length === 2 && snap.counts.transactions === 2
       && snap.counts.accountedFor === 2);
    ck('every row states its ledger version as a decimal string, and the tree says so',
       by[h('b')].version === '101' && by[h('c')].version === '102'
       && snap.provenance.ordering === 'globalVersion');
    ck('the protocol\'s transactions are each block\'s systemTransactions, disjoint from rows',
       JSON.stringify(snap.blocks.map((b) => b.systemTransactions))
         === JSON.stringify([[h('e'), h('f')], [h('a'), h('d')]])
       && snap.blocks[1].transactions.join() === [h('b'), h('c')].join());
    ck('a block with no user transaction is still a block, with an empty row list',
       snap.blocks[0].number === 11 && snap.blocks[0].transactions.length === 0);
    ck('blocks are newest first, each naming the block below it, the first its predecessor',
       JSON.stringify(snap.blocks.map((b) => [b.number, b.parentArchiveRoot]))
         === JSON.stringify([[11, b10.block_hash], [10, h('9')]]));
    ck('the floor is the node\'s oldest block, and its reason names that boundary',
       snap.window.replayableFrom === 5 && snap.provenance.reachReason.includes('height 5')
       && snap.provenance.reachReason.includes('versions from 50'));
    ck('a trace too large to record is refused as no-container-written',
       by[h('b')].outcome === 'refused' && by[h('b')].refusalReason === 'no-container-written'
       && by[h('b')].refusal === 'TRACE-TOO-LARGE');
    ck('CONTROL: the unattempted one is not-attempted, so the two are told apart',
       by[h('c')].outcome === 'not-attempted' && by[h('c')].refusalReason === 'not-attempted');
  }
  const gap = write('gap.json', acquisition([b10, { ...b11, block_height: '12' }]));
  ck('a window that skips a block is refused', /skips from block 10 to 12/.test(await run(gap) ?? ''));
  const torn = write('torn.json', acquisition([b10, { ...b11, first_version: '105' }]));
  ck('a window whose versions are not contiguous is refused',
     /not contiguous/.test(await run(torn) ?? ''));
  const pruned = write('pruned.json', acquisition([b10, b11], { oldest: 11 }));
  ck('a window below the node\'s retention boundary is refused',
     /retention boundary/.test(await run(pruned) ?? ''));
  const foreign = join(dir, 'rec-foreign');
  mkdirSync(foreign, { recursive: true });
  writeFileSync(join(foreign, 'done.json'), JSON.stringify({ version: '102', hash: h('c'),
    outcome: 'too-large', refusal: 'TRACE-TOO-LARGE', recorderCommit: '2'.repeat(40) }));
  ck('a recording another recorder build made is refused',
     /was recorded by 2{40}/.test(await run(good, ['--rec', foreign]) ?? ''));
  const wrongHash = join(dir, 'rec-wrong');
  mkdirSync(wrongHash, { recursive: true });
  writeFileSync(join(wrongHash, 'done.json'), JSON.stringify({ version: '102', hash: h('9'),
    outcome: 'too-large', refusal: 'TRACE-TOO-LARGE', recorderCommit: commit }));
  ck('a recording whose hash is not the chain\'s for that version is refused',
     /the chain names it/.test(await run(good, ['--rec', wrongHash]) ?? ''));
  rmSync(dir, { recursive: true, force: true });
}

test('§5 the REST transcript');
{
  const k = (o) => requestKey({ method: 'GET', path: '/v1/x', ...o }).key;
  ck('one path asked in JSON and in BCS is two requests',
     k({ accept: 'application/json' }) !== k({ accept: 'application/x-bcs' }));
  ck('two raw state reads with different keys in the body are two requests',
     requestKey({ method: 'POST', path: '/v1/experimental/state_values/raw', body: Buffer.from('a') }).key
       !== requestKey({ method: 'POST', path: '/v1/experimental/state_values/raw', body: Buffer.from('b') }).key);
  ck('CONTROL: the same request is the same key', k({ accept: 'a' }) === k({ accept: 'a' }));
  ck('ledger info asks about the tip; a block by height does not',
     isTipDependent('/v1') && isTipDependent('/v1/') && !isTipDependent('/v1/blocks/by_height/1'));
  ck('a body survives the compression it is stored under, byte for byte',
     decodeBody(encodeBody(Buffer.from([0, 1, 2, 255]))).equals(Buffer.from([0, 1, 2, 255])));

  const dir = mkdtempSync(join(tmpdir(), 'aptos-transcript-selftest-'));
  const answer = Buffer.from('{"chain_id":1}');
  let upstreamCalls = 0;
  const fakeUpstream = async () => {
    upstreamCalls++;
    return new Response(answer, { status: 200, headers: { 'content-type': 'application/json',
                                                           'x-aptos-chain-id': '1' } });
  };
  const rec = await startTranscriptServer({ mode: 'record', dir, upstream: 'http://upstream.invalid',
                                            fetchImpl: fakeUpstream, minGapMs: 0 });
  await (await fetch(`${rec.url}/v1`, { headers: { accept: 'application/json' } })).text();
  await rec.close();
  const rep = await startTranscriptServer({ mode: 'replay', dir });
  const hit = await fetch(`${rep.url}/v1`, { headers: { accept: 'application/json' } });
  const hitBody = Buffer.from(await hit.arrayBuffer());
  ck('replay serves what was recorded, status, chain header and body',
     hit.status === 200 && hit.headers.get('x-aptos-chain-id') === '1' && hitBody.equals(answer));
  const miss = await fetch(`${rep.url}/v1/blocks/by_height/7`, { headers: { accept: 'application/json' } });
  await miss.text();
  const { misses } = await rep.close();
  ck('CONTROL: a request the transcript does not hold is a counted MISS, never the network',
     miss.status === 599 && misses === 1 && upstreamCalls === 1);
  const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
  ck('the manifest lists the call and marks the tip query',
     manifest.calls === 1 && manifest.tipDependent === 1);
  rmSync(dir, { recursive: true, force: true });
}

test('§6 the sentences the chain page quotes');
{
  const r = reachReasonFor(1133277834, '7735809893');
  ck('the floor\'s reason names the node\'s pruning and both boundaries',
     r.includes('prunes') && r.includes('1133277834') && r.includes('7735809893')
     && r.includes('410'));
  ck('the verification sentence says a mismatch is published as divergent',
     VERIFICATION.includes('aptos move replay') && VERIFICATION.includes('divergent'));
}

test('§7 the source provider, offline');
{
  // BCS, written by hand: what the REST API answers for `0x1::code::PackageRegistry`.
  const uleb = (n) => { const o = []; do { let b = n & 0x7f; n >>>= 7; if (n) b |= 0x80; o.push(b); } while (n); return Buffer.from(o); };
  const str = (t) => Buffer.concat([uleb(Buffer.byteLength(t)), Buffer.from(t)]);
  const bytes = (b) => Buffer.concat([uleb(b.length), b]);
  const vec = (xs) => Buffer.concat([uleb(xs.length), ...xs]);
  const u64 = (n) => { const b = Buffer.alloc(8); b.writeBigUInt64LE(BigInt(n)); return b; };
  const u32 = (n) => { const b = Buffer.alloc(4); b.writeUInt32LE(n); return b; };
  const u16 = (n) => { const b = Buffer.alloc(2); b.writeUInt16LE(n); return b; };
  const source = gzipSync(Buffer.from('module 0x5::m { }\n'));
  const registry = Buffer.concat([vec([Buffer.concat([
    str('AptosTrading'), Buffer.from([1]), u64(9), str('1388A0EB'), bytes(gzipSync(Buffer.from('[package]'))),
    vec([Buffer.concat([str('m'), bytes(source), bytes(Buffer.alloc(0)), vec([])]),
         Buffer.concat([str('n'), bytes(Buffer.alloc(0)), bytes(Buffer.alloc(0)), vec([])])]),
    vec([Buffer.concat([Buffer.alloc(31), Buffer.from([1]), str('AptosFramework')])]),
    vec([]),
  ])])]);
  const reg = decodePackageRegistry(registry);
  const pkg = reg.packages[0];
  ck('a package registry reads back: name, upgrade, a module\'s source, an empty one, its deps',
     pkg.name === 'AptosTrading' && pkg.upgradeNumber === '9' && pkg.modules[0].source.equals(source)
     && pkg.modules[1].source.length === 0 && pkg.deps[0].account === `${'0'.repeat(63)}1`
     && pkg.deps[0].packageName === 'AptosFramework');
  let refused = null;
  try { decodePackageRegistry(Buffer.concat([registry, Buffer.from([0])])); } catch (e) { refused = e.message; }
  ck('CONTROL: a registry with a byte left over is refused, not read', /trailing/.test(refused ?? ''));

  // A source map: one function, two pcs, the second in another file (inlined code).
  const loc = (fill, a, b) => Buffer.concat([Buffer.alloc(32, fill), u32(a), u32(b)]);
  const sm = Buffer.concat([loc(1, 0, 40), Buffer.from([1]), Buffer.alloc(32), str('m'), vec([]),
    vec([Buffer.concat([u16(0), loc(1, 20, 23), vec([]), vec([Buffer.concat([str('x'), loc(1, 24, 25)])]),
      vec([]), vec([]), vec([Buffer.concat([u16(0), loc(1, 30, 35)]), Buffer.concat([u16(3), loc(2, 4, 6)])]),
      Buffer.from([0])])]), vec([])]);
  const map = decodeSourceMap(sm);
  const fn = map.functionMap[0][1];
  ck('a source map reads back: the function, its parameter, and each pc\'s file and range',
     map.moduleName[1] === 'm' && fn.parameters[0][0] === 'x' && fn.codeMap.length === 2
     && fn.codeMap[1][0] === 3 && fn.codeMap[1][1].fileHash === '02'.repeat(32)
     && fn.codeMap[0][1].start === 30);

  // A module header carries the Aptos format flag in its version word's top byte.
  const meta = Buffer.concat([str('compilation_metadata'), bytes(Buffer.concat([Buffer.from([0]), str('2.0'), str('2.4')]))]);
  const mv = Buffer.concat([Buffer.from([0xa1, 0x1c, 0xeb, 0x0b]), u32(0x0a00000a), Buffer.alloc(9), meta]);
  const cm = compilationMetadata(mv);
  ck('a module names the compiler and language versions it was built with, and bytecode v10',
     cm.compilerVersion === '2.0' && cm.languageVersion === '2.4' && cm.bytecodeVersion === 10);
  ck('CONTROL: bytes that are not a module name nothing',
     compilationMetadata(Buffer.from('not a module')).bytecodeVersion === null);

  // Specifications: what may be changed, measured on text shaped like the framework's.
  const text = Buffer.from([
    'module 0x1::m {',
    '    fun f(x: u64, v: vector<u64>): u64 {',
    '        let s = b"spec {";            // spec { in a comment',
    '        while (x > 0) { x = x - 1 } spec {',
    '            invariant spec_ok(x, v) && forall i in 0..x: v[i] > 0;',
    '        };',
    '        x',
    '    }',
    '    spec f { pragma opaque; } proof { split x == 0; }',
    '    spec native fun spec_ok(x: u64, v: vector<u64>): bool;',
    '}', ''].join('\n'));
  const regions = specRegions(text);
  ck('three spec constructs: an inline block (interior only), an item with its proof, a native spec fun',
     regions.length === 3 && regions[0].kind === 'inline' && regions[1].kind === 'item'
     && text.subarray(regions[1].start, regions[1].end).toString().endsWith('split x == 0; }')
     && text.subarray(regions[2].start, regions[2].end).toString().endsWith(': bool;'));
  const stmt = inlineSpecStatements(text, regions[0])[0];
  const rewritten = rewriteSpecStatement(text, stmt);
  const after = rewritten.subarray(stmt.start, stmt.end).toString();
  ck('a rejected inline statement is rewritten over the locals it names, at its own length',
     rewritten.length === text.length && /^invariant x==x && v==v *;$/.test(after.replace(/ +;$/, ' ;').replace(/\s+$/, ''))
     && !after.includes('i==i') && rewritten.toString().split('\n').length === text.toString().split('\n').length);
  ck('CONTROL: a statement with no room for its locals is not rewritten',
     rewriteSpecStatement(Buffer.from('invariant f(abc, defg);'), { start: 0, end: 23 }) === null);
  const out = ['warning: unused', '   ┌─ a/sources/w.move:1:1', 'error: no function named `spec_ok`',
    '   ┌─ /x/a/sources/m.move:5:23', 'error[E01]: unexpected', '   ┌─ b.move:7:2'].join('\n');
  const errs = compilerErrorLocations(out);
  ck('the compiler\'s ERRORS are located, and its warnings are not',
     errs.length === 2 && errs[0].file === '/x/a/sources/m.move' && errs[0].line === 5
     && errs[0].column === 23 && errs[1].file === 'b.move');

  // What a row says.
  const ok = artifactFromResolution({ address: h('1'), module: 'coin', codeHash: h('c'),
    outcome: 'verified', package: 'AptosFramework', upgradeNumber: '57',
    build: { compiler: 'aptos', compilerVersion: '2.0', languageVersion: '2.4',
             bytecodeVersion: 10, profile: 'framework-release', specificationsChanged: 3 } }, '99');
  ck('a verified module is resolved, by the chain itself, as an exact match',
     ok.resolved === true && ok.corroboration === 'the chain itself' && ok.contractClassId === h('c')
     && ok.reason.startsWith('Verified, exact match') && ok.reason.includes('ledger version 99'));
  const bad = artifactFromResolution({ address: h('1'), module: 'coin', codeHash: h('c'),
    outcome: 'bytecode-mismatch', reason: 'no build profile reproduces the bytes' }, '99');
  ck('CONTROL: a module whose source compiles to other bytes is not resolved, and says so',
     bad.resolved === false && bad.origin === null && bad.reason.includes('discarded')
     && bad.reason.includes('disassembly'));
  const none = artifactFromResolution({ address: h('2'), module: 'perp', codeHash: h('d'),
    outcome: 'source-not-published', reason: 'published without source' }, '99');
  ck('…and one published without source says no source was published',
     none.resolved === false && none.reason.includes('no source was published'));
}

// The count is a LITERAL because `refusal-selftest.mjs` reads it out of this line and
// cross-checks it against the Justfile header and ci.yml.
if (asserted !== 56) {
  console.error(`ASSERTION COUNT IS ${asserted}, EXPECTED 56 — a case was added, removed or skipped.`);
  failed++;
} else {
  console.error(`assertion count: ${asserted} (as declared)`);
}
if (failed) { console.error(`FAIL — ${failed} problem(s)`); process.exit(1); }
console.error('self-test: PASS');
