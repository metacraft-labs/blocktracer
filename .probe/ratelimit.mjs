// Measure the drpc endpoint's real behaviour at increasing concurrency.
const URL = 'https://aztec-testnet.drpc.org';
let id = 0;
async function one(n) {
  const t0 = Date.now();
  try {
    const r = await fetch(URL, { method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method: 'node_getBlock', params: [n] }) });
    const txt = await r.text();
    let jerr = null;
    try { const j = JSON.parse(txt); if (j.error) jerr = j.error.message; } catch { jerr = 'unparseable'; }
    return { ms: Date.now() - t0, status: r.status, ok: r.ok && !jerr, jerr,
             ra: r.headers.get('retry-after'), rl: r.headers.get('x-ratelimit-remaining') };
  } catch (e) { return { ms: Date.now() - t0, status: 0, ok: false, jerr: 'fetch:' + e.message }; }
}
const base = 20000;
for (const conc of [1, 2, 4, 8, 16, 32]) {
  const N = conc * 12;
  const t0 = Date.now();
  const results = [];
  let next = 0;
  await Promise.all(Array.from({ length: conc }, async () => {
    while (true) { const i = next++; if (i >= N) return;
      results.push(await one(base + conc * 1000 + i)); }
  }));
  const wall = (Date.now() - t0) / 1000;
  const okc = results.filter(r => r.ok).length;
  const codes = {}; for (const r of results) codes[r.status + (r.jerr ? '/' + r.jerr.slice(0,30) : '')] = (codes[r.status + (r.jerr ? '/' + r.jerr.slice(0,30) : '')] ?? 0) + 1;
  const lat = results.map(r => r.ms).sort((a, b) => a - b);
  const pct = (p) => lat[Math.min(lat.length - 1, Math.floor(lat.length * p))];
  console.log(`conc=${String(conc).padStart(2)} n=${N} wall=${wall.toFixed(2)}s  rate=${(N/wall).toFixed(1)} req/s  ok=${okc}/${N}  p50=${pct(.5)}ms p95=${pct(.95)}ms  ${JSON.stringify(codes)}`);
  const hdr = results.find(r => r.ra || r.rl);
  if (hdr) console.log(`   headers: retry-after=${hdr.ra} ratelimit-remaining=${hdr.rl}`);
  await new Promise(r => setTimeout(r, 2000));
}
