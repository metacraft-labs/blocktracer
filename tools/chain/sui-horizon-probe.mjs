#!/usr/bin/env node
// sui-horizon-probe.mjs — how far back a Sui GraphQL endpoint serves the object versions
// a transaction consumed, measured on a fixed ladder of depths and compared against a
// committed reading.
//
//   node tools/chain/sui-horizon-probe.mjs [--node mainnet|URL] [--record]
//
// ── WHY A STANDING CHECK ──────────────────────────────────────────────────────────────
//
// Sui's prestate is version-addressed (Chain-Support-Matrix.md §1.4): a replay fetches
// exactly the object versions the transaction names. The protocol needs no archive, but
// an ENDPOINT may prune, and a horizon that moves without anyone noticing is a backfill
// that decays into scattered refusals (Recorder-Move CXP-MOVE-1). So the horizon is read,
// committed, and re-read: a rung that was served in the committed reading and is not
// served now fails the check by name.
//
// ── WHAT IS MEASURED, AND WHY THAT IS NOT CIRCULAR ────────────────────────────────────
//
// For each rung checkpoint, the first transaction (within 20 checkpoints) whose effects
// name input versions is taken, and those exact `(object, version)` pairs are asked for
// with their contents (`objectBcs`). A served version returns its bytes; an unserved one
// answers `null` — and so does a version that never existed, which is why only versions
// the chain itself named are asked for. A CONTROL asks for a version that cannot exist
// (2^53 − 1) and must answer `null`, so "served" is shown to be an answer the endpoint
// can withhold. The service's own `availableRange` is recorded beside the measurement as
// a self-report, never in place of it.
//
// Exit status: 0 the reading holds (or was recorded), 1 the horizon moved or the control
// failed, 2 no committed reading to compare against (run with --record).

import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { checkpointWithTransactions, graphql, graphqlUrlFor, inputVersionsOf, latestCheckpoint }
  from './lib/sui-graphql.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
export const READING_FORMAT = 'blocktracer/sui-endpoint-horizon@1';
const READING = join(HERE, 'measurements', 'sui-endpoint-horizon.json');

/** The ladder: near tip, the trace floor, the old prestate-trace floor, and deep history. */
export const LADDER = Object.freeze([
  { name: 'near-tip', depthBelowTip: 1000 },
  { name: 'trace-floor', checkpoint: 28_845_400 },
  { name: 'prestate-trace-floor', checkpoint: 23_900_000 },
  { name: 'june-2023', checkpoint: 5_000_000 },
  { name: 'early-2023', checkpoint: 1_000_000 },
]);

/**
 * Compare a fresh reading with the committed one. Returns the problems, each a sentence;
 * empty means the committed reading still holds. A rung served before and unserved now is
 * the horizon moving; a rung unserved before and served now is reported too (the reading
 * is stale, and a stale reading under-states reach).
 */
export function compareReadings(committed, fresh) {
  const problems = [];
  if (fresh.control?.answeredNull !== true) {
    problems.push('the control (a version that cannot exist) was not answered null, so a '
      + '"served" rung cannot be told from an endpoint that answers everything');
  }
  const before = new Map((committed?.rungs ?? []).map((r) => [r.name, r]));
  for (const r of fresh.rungs) {
    const b = before.get(r.name);
    if (b === undefined) continue;
    if (b.served && !r.served) {
      problems.push(`rung ${r.name} (checkpoint ${r.checkpoint}) was served on `
        + `${committed.measuredAt} and is not served now: the endpoint's horizon moved`);
    }
    if (!b.served && r.served) {
      problems.push(`rung ${r.name} (checkpoint ${r.checkpoint}) is served now and was not on `
        + `${committed.measuredAt}: the committed reading under-states reach; re-record it`);
    }
  }
  for (const name of before.keys()) {
    if (!fresh.rungs.some((r) => r.name === name)) problems.push(`rung ${name} was not measured`);
  }
  return problems;
}

async function measureRung(url, rung, tip) {
  const start = rung.checkpoint ?? tip - rung.depthBelowTip;
  for (let seq = start; seq < start + 20; seq++) {
    const cp = await checkpointWithTransactions(url, seq);
    if (cp === null) break;
    for (const tx of cp.transactions) {
      const inputs = inputVersionsOf(tx.effectsJson).slice(0, 3);
      if (inputs.length === 0) continue;
      const data = await graphql(url, `query($keys: [ObjectKey!]!) {
        multiGetObjects(keys: $keys) { address version objectBcs } }`,
      { keys: inputs.map((i) => ({ address: i.objectId, version: Number(i.version) })) });
      const answers = data.multiGetObjects ?? [];
      const served = inputs.length > 0 && answers.length === inputs.length
        && answers.every((o) => o !== null && typeof o.objectBcs === 'string' && o.objectBcs.length > 0);
      return { name: rung.name, checkpoint: seq, digest: tx.digest,
               inputs: inputs.map((i) => `${i.objectId}@${i.version}`), served };
    }
  }
  return { name: rung.name, checkpoint: start, digest: null, inputs: [], served: false,
           note: 'no transaction naming input versions within 20 checkpoints' };
}

export async function measure(url) {
  const tip = (await latestCheckpoint(url)).sequenceNumber;
  const rungs = [];
  for (const rung of LADDER) rungs.push(await measureRung(url, rung, tip));
  const control = await graphql(url, `{ object(address: "0x6", version: 9007199254740991) {
    version } }`);
  const range = async (type, field) => (await graphql(url, `{ serviceConfig {
    availableRange(type: "${type}", field: "${field}") { first { sequenceNumber } } } }`))
    .serviceConfig.availableRange?.first?.sequenceNumber ?? null;
  const served = rungs.filter((r) => r.served).map((r) => r.checkpoint);
  return {
    format: READING_FORMAT,
    endpoint: url,
    measuredAt: new Date().toISOString(),
    tip,
    selfReported: { objectFirst: await range('Query', 'object'),
                    transactionFirst: await range('Query', 'transaction') },
    rungs,
    deepestServed: served.length ? Math.min(...served) : null,
    control: { asked: '0x6@9007199254740991', answeredNull: control.object === null },
  };
}

async function main(argv) {
  const node = argv.includes('--node') ? argv[argv.indexOf('--node') + 1] : 'mainnet';
  const url = graphqlUrlFor(node);
  const fresh = await measure(url);
  console.log(JSON.stringify(fresh, null, 1));
  if (argv.includes('--record')) {
    if (!fresh.control.answeredNull) {
      console.error('refusing to record: the control was not answered null');
      process.exit(1);
    }
    writeFileSync(READING, `${JSON.stringify(fresh, null, 1)}\n`);
    console.error(`recorded ${READING}`);
    return;
  }
  if (!existsSync(READING)) {
    console.error(`no committed reading at ${READING}; run with --record`);
    process.exit(2);
  }
  const committed = JSON.parse(readFileSync(READING, 'utf8'));
  if (committed.endpoint !== url) {
    console.error(`the committed reading is for ${committed.endpoint}, not ${url}`);
    process.exit(2);
  }
  const problems = compareReadings(committed, fresh);
  for (const p of problems) console.error(`  FAIL  ${p}`);
  if (problems.length) process.exit(1);
  console.error(`the committed reading (${committed.measuredAt}) still holds: every rung `
    + `served then is served now; deepest served checkpoint ${fresh.deepestServed}`);
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).catch((e) => {
    console.error(`sui-horizon-probe.mjs: ${e.message}`);
    process.exit(1);
  });
}
