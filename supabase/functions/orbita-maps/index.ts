import { upstream } from './proxy.ts';

// The key is server-only. This is a separately approved deployment, not an APK define.
const project = 'https://fjqghohhohgvwlmefdmo.supabase.co';
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const providerKey = Deno.env.get('GEOAPIFY_SERVER_KEY') ?? '';
const identities = new Map<string,{uid:string;expires:number}>();
const verifying = new Map<string,Promise<string>>();
function response(status:number) {
  return new Response(JSON.stringify({error:status === 429 ? 'maps_limit' : 'maps_unavailable'}),
    {status,headers:{'content-type':'application/json','cache-control':'no-store'}});
}
async function identity(token:string):Promise<string> {
  const known = identities.get(token);
  if (known && known.expires > Date.now()) return known.uid;
  const pending = verifying.get(token); if (pending) return pending;
  const task = (async () => {
    const auth = await fetch(project+'/auth/v1/user',{headers:{apikey:serviceKey,Authorization:token},signal:AbortSignal.timeout(5000)});
    if (!auth.ok) throw Error('auth');
    const user = await auth.json(); if (typeof user.id !== 'string') throw Error('auth');
    // Only expiry of an already server-verified token is used, never decoded roles.
    const segment=token.slice(7).split('.')[1].replace(/-/g,'+').replace(/_/g,'/');
    const expiry=JSON.parse(atob(segment)).exp * 1000;
    if (!Number.isFinite(expiry) || expiry <= Date.now()) throw Error('auth');
    if (identities.size >= 128) identities.clear();
    identities.set(token,{uid:user.id,expires:Math.min(expiry,Date.now()+5000)});
    return user.id;
  })();
  verifying.set(token,task);
  try { return await task; } finally { verifying.delete(token); }
}
Deno.serve(async request => {
  if (request.method !== 'GET') return response(405);
  if (!serviceKey || !providerKey) return response(503);
  const token = request.headers.get('Authorization') ?? '';
  if (!token.startsWith('Bearer ') || token.length > 8192) return response(401);
  let plan: ReturnType<typeof upstream>;
  try { plan=upstream(new URL(request.url)); } catch { return response(400); }
  let uid:string;
  try { uid=await identity(token); } catch { return response(401); }
  try {
    const quota=await fetch(project+'/rest/v1/rpc/orbita_map_budget',{
      method:'POST',headers:{apikey:serviceKey,Authorization:'Bearer '+serviceKey,'Content-Type':'application/json'},
      body:JSON.stringify({p_user:uid,p_units:plan.units}),signal:AbortSignal.timeout(5000)});
    if (!quota.ok) return response(503);
    if (await quota.json() !== true) return response(429);
    plan.url.searchParams.set('apiKey',providerKey);
    const reply=await fetch(plan.url,{redirect:'error',signal:AbortSignal.timeout(8000)});
    if (!reply.ok) return response(reply.status===429?429:reply.status===401||reply.status===403?503:502);
    const reader=reply.body?.getReader(); if (!reader) return response(502);
    let size=0; const chunks:Uint8Array[]=[];
    while(true) {
      const {done,value}=await reader.read(); if(done) break;
      size+=value.length; if(size>plan.bytes) { await reader.cancel(); return response(502); }
      chunks.push(value);
    }
    const bytes=new Uint8Array(size); let offset=0;
    for(const chunk of chunks) { bytes.set(chunk,offset); offset+=chunk.length; }
    if(plan.type==='image/png' && !(bytes[0]===137 && bytes[1]===80 && bytes[2]===78 && bytes[3]===71)) return response(502);
    if(plan.type==='application/json') { try { JSON.parse(new TextDecoder().decode(bytes)); } catch { return response(502); } }
    return new Response(bytes,{headers:{'content-type':plan.type,'cache-control':'private,max-age=60','x-content-type-options':'nosniff'}});
  } catch { return response(504); }
});
