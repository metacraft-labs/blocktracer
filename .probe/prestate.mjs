// How deep does the PUBLIC node's historic world state actually go?
// This is the input that decides whether a historic trace is possible at all:
// replay hydrates prestate with getPublicDataWitness / getNullifierMembership-
// Witness AT THE SETTLING BLOCK'S PARENT. If those refuse below some depth, no
// amount of body recovery makes an old transaction replayable from this node.
const URL = 'https://aztec-testnet.drpc.org';
let id = 0;
const sleep = (ms) => new Promise(r => setTimeout(r, ms));
async function rpc(method, params) {
  for (let a = 0; a < 6; a++) {
    const r = await fetch(URL, { method: 'POST', headers: {'content-type':'application/json'},
      body: JSON.stringify({ jsonrpc:'2.0', id:++id, method, params }) });
    const txt = await r.text();
    let j = null; try { j = JSON.parse(txt); } catch {}
    const msg = j?.error?.message ?? '';
    if (r.status === 429 || /too many requests/i.test(msg)) { await sleep(3000 * (a+1)); continue; }
    if (j?.error) return { err: msg, code: j.error.code };
    return { ok: true, result: j?.result };
  }
  return { err: 'throttled-out' };
}
const tip = (await rpc('node_getBlockNumber', [])).result;
const fin = (await rpc('node_getBlockNumber', ['finalized'])).result;
console.log(`tip=${tip} finalized=${fin} window(tip-finalized)=${tip - fin}`);
const info = (await rpc('node_getNodeInfo', [])).result;
console.log(`nodeVersion=${info?.nodeVersion} l1ChainId=${info?.l1ChainId} rollupVersion=${info?.rollupVersion} rollup=${info?.l1ContractAddresses?.rollupAddress}`);

// The node reports its own retention floor. One request, and it is the number
// that decides whether historic prestate is obtainable from THIS node at all.
const ws = await rpc('node_getWorldStateSyncStatus', []);
if (ws.ok) {
  console.log('worldStateSyncStatus:', JSON.stringify(ws.result));
  const oldest = ws.result?.oldestHistoricBlockNumber ?? ws.result?.oldestHistoricalBlock;
  if (oldest != null) {
    console.log(`RETENTION: oldest historic block = ${oldest}; `
      + `depth below tip = ${tip - Number(oldest)} blocks`);
  }
} else {
  console.log('worldStateSyncStatus REFUSED:', ws.err);
}

const SLOT = '0x0000000000000000000000000000000000000000000000000000000000000001';
const NULL = '0x0000000000000000000000000000000000000000000000000000000000000001';
const depths = [0, 1, 10, 49, 64, 100, 200, 400, 800, 1600, 3200, 6400, 12800, 25600, 51200];
console.log('\ndepth-below-tip  block     getPublicDataWitness            getNullifierMembershipWitness');
for (const d of depths) {
  const bn = tip - d;
  if (bn < 1) continue;
  const a = await rpc('node_getPublicDataWitness', [bn, SLOT]);
  await sleep(400);
  const b = await rpc('node_getNullifierMembershipWitness', [bn, NULL]);
  await sleep(400);
  const f = (x) => x.ok ? (x.result == null ? 'null(no witness)' : 'SERVED') : `REFUSED: ${String(x.err).slice(0,44)}`;
  console.log(`${String(d).padStart(8)}      ${String(bn).padStart(7)}   ${f(a).padEnd(32)}${f(b)}`);
}
