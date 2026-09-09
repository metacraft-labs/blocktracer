const URL='https://aztec-testnet.drpc.org'; let id=0;
async function one(n){ const t0=Date.now();
  try{ const r=await fetch(URL,{method:'POST',headers:{'content-type':'application/json'},
    body:JSON.stringify({jsonrpc:'2.0',id:++id,method:'node_getBlock',params:[n]})});
    const txt=await r.text(); let jerr=null;
    try{const j=JSON.parse(txt); if(j.error) jerr=j.error.message;}catch{jerr='unparseable';}
    return{ms:Date.now()-t0,status:r.status,ok:r.ok&&!jerr,jerr};
  }catch(e){return{ms:Date.now()-t0,status:0,ok:false,jerr:'fetch:'+e.message};} }
// single probe first
const p = await one(50001);
console.log(`single: status=${p.status} ok=${p.ok} err=${p.jerr??''} ${p.ms}ms`);
if(!p.ok){ console.log('still limited — stopping'); process.exit(0); }
async function paced(rate,secs,start){
  const gap=1000/rate,t0=Date.now(); const inf=[]; let n=start,issued=0;
  while(Date.now()-t0<secs*1000){ inf.push(one(n++)); issued++;
    const d=t0+issued*gap-Date.now(); if(d>0) await new Promise(r=>setTimeout(r,d)); }
  const res=await Promise.all(inf); const ok=res.filter(r=>r.ok).length; const codes={};
  for(const r of res){const k=r.status===200?'200':(r.status+'/'+String(r.jerr).slice(0,28));codes[k]=(codes[k]??0)+1;}
  console.log(`rate=${String(rate).padStart(3)}/s ${secs}s issued=${issued} ok=${ok} (${(100*ok/issued).toFixed(1)}%) ${JSON.stringify(codes)}`);
  return ok/issued;
}
for(const [rate,start] of [[5,51000],[10,52000],[15,53000],[25,54000]]){
  await paced(rate,20,start);
  await new Promise(r=>setTimeout(r,10000));
}
