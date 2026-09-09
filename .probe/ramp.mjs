// Find a rate the endpoint will sustain, starting from almost nothing and
// stopping at the first sign of a limit. Writes the chosen rate to
// .probe/chosen-rps. Deliberately conservative: it picks HALF the highest rate
// that showed a clean 30-second window, and never goes above 12/s.
import { writeFileSync } from 'node:fs';
const URL = 'https://aztec-testnet.drpc.org';
let id = 0;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function one(n) {
  try {
    const r = await fetch(URL, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method: 'node_getBlock', params: [n] }) });
    const t = await r.text();
    let j = null; try { j = JSON.parse(t); } catch {}
    const msg = j?.error?.message ?? '';
    const limited = r.status === 429 || /too many requests|rate limit/i.test(msg);
    return { ok: r.ok && !j?.error, limited };
  } catch { return { ok: false, limited: false }; }
}

// Serial pacing, the same shape the backfill uses: one request every 1000/rate ms.
async function trial(rate, secs, start) {
  const gap = 1000 / rate; const t0 = Date.now();
  let issued = 0, ok = 0, limited = 0, n = start;
  while (Date.now() - t0 < secs * 1000) {
    const r = await one(n++); issued++;
    if (r.ok) ok++; if (r.limited) limited++;
    const d = t0 + issued * gap - Date.now();
    if (d > 0) await sleep(d);
    if (limited >= 5) break;          // stop early, do not keep pushing
  }
  console.log(`  ramp rate=${rate}/s ${secs}s issued=${issued} ok=${ok} limited=${limited}`);
  return { issued, ok, limited };
}

let best = 0;
for (const rate of [1, 2, 4, 8, 12]) {
  const r = await trial(rate, 30, 55000 + rate * 700);
  if (r.limited > 0 || r.ok < r.issued * 0.98) { console.log(`  stop: ${rate}/s showed a limit`); break; }
  best = rate;
  await sleep(15000);
}
// Half of what held, floored at 1, capped at 12.
const chosen = Math.max(1, Math.min(12, Math.floor(best / 2) || 1));
console.log(`  highest clean rate ${best}/s -> backfilling at ${chosen}/s`);
writeFileSync('.probe/chosen-rps', String(chosen));
