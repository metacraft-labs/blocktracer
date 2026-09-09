const URL = 'https://aztec-testnet.drpc.org';
let id = 0;
async function one(n) {
  const t0 = Date.now();
  try {
    const r = await fetch(URL, { method: 'POST', headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method: 'node_getBlock', params: [n] }) });
    const txt = await r.text(); let jerr = null;
    try { const j = JSON.parse(txt); if (j.error) jerr = j.error.message; } catch { jerr = 'unparseable'; }
    return { ms: Date.now()-t0, status: r.status, ok: r.ok && !jerr, jerr };
  } catch (e) { return { ms: Date.now()-t0, status: 0, ok: false, jerr: 'fetch:'+e.message }; }
}
// find the knee
for (const conc of [64, 96]) {
  const N = conc*8, t0 = Date.now(); const res=[]; let next=0;
  await Promise.all(Array.from({length: conc}, async () => {
    while (true) { const i = next++; if (i>=N) return; res.push(await one(30000+conc*1000+i)); } }));
  const wall=(Date.now()-t0)/1000, ok=res.filter(r=>r.ok).length;
  const codes={}; for(const r of res){const k=r.status+(r.jerr?'/'+r.jerr.slice(0,40):'');codes[k]=(codes[k]??0)+1;}
  console.log(`knee conc=${conc} n=${N} wall=${wall.toFixed(2)}s rate=${(N/wall).toFixed(1)}/s ok=${ok}/${N} ${JSON.stringify(codes)}`);
  await new Promise(r=>setTimeout(r,2000));
}
// sustained 45s at conc=24
console.log('--- sustained conc=24 for 45s ---');
{
  const conc=24, deadline=Date.now()+45000; let n=40000, done=0, ok=0; const codes={}; const buckets=[];
  let bstart=Date.now(), bcount=0;
  await Promise.all(Array.from({length: conc}, async () => {
    while (Date.now() < deadline) {
      const r = await one(n++); done++; if (r.ok) ok++;
      const k=r.status+(r.jerr?'/'+r.jerr.slice(0,40):''); codes[k]=(codes[k]??0)+1;
      bcount++;
      if (Date.now()-bstart >= 5000) { buckets.push(bcount/((Date.now()-bstart)/1000)); bcount=0; bstart=Date.now(); }
    } }));
  console.log(`sustained: ${done} req, ok=${ok}, ${JSON.stringify(codes)}`);
  console.log(`per-5s throughput req/s: ${buckets.map(b=>b.toFixed(0)).join(' ')}`);
}
