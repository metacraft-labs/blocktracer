const URL='https://aztec-testnet.drpc.org'; let id=0;
async function one(n){ const t0=Date.now();
  try{ const r=await fetch(URL,{method:'POST',headers:{'content-type':'application/json'},
    body:JSON.stringify({jsonrpc:'2.0',id:++id,method:'node_getBlock',params:[n]})});
    const txt=await r.text(); let jerr=null;
    try{const j=JSON.parse(txt); if(j.error) jerr=j.error.message;}catch{jerr='unparseable';}
    return{ms:Date.now()-t0,status:r.status,ok:r.ok&&!jerr,jerr};
  }catch(e){return{ms:Date.now()-t0,status:0,ok:false,jerr:'fetch:'+e.message};} }
// Paced: issue exactly `rate` req/s for `secs`, never retry. Measures the 429 floor.
async function paced(rate, secs, startBlock){
  const gap=1000/rate, t0=Date.now(); const inflight=[]; let n=startBlock, issued=0;
  while(Date.now()-t0 < secs*1000){
    inflight.push(one(n++)); issued++;
    const target=t0+issued*gap, d=target-Date.now();
    if(d>0) await new Promise(r=>setTimeout(r,d));
  }
  const res=await Promise.all(inflight);
  const ok=res.filter(r=>r.ok).length; const codes={};
  for(const r of res){const k=r.status===200?'200':(r.status+'/'+String(r.jerr).slice(0,32));codes[k]=(codes[k]??0)+1;}
  const wall=(Date.now()-t0)/1000;
  console.log(`rate=${String(rate).padStart(3)}/s ${secs}s issued=${issued} ok=${ok} (${(100*ok/issued).toFixed(1)}%) served=${(ok/wall).toFixed(1)}/s ${JSON.stringify(codes)}`);
  return ok/issued;
}
console.log('cooling 20s after the burst test…');
await new Promise(r=>setTimeout(r,20000));
for (const [rate,start] of [[20,41000],[40,43000],[60,45000],[80,48000],[100,52000]]) {
  await paced(rate, 20, start);
  await new Promise(r=>setTimeout(r,8000));
}
