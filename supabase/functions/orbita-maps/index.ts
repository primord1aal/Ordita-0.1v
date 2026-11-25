import { type MapPayload, upstream } from './proxy.ts';

// The key is server-only. This is a separately approved deployment, not an APK define.
const project = 'https://fjqghohhohgvwlmefdmo.supabase.co';
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const providerKey = Deno.env.get('GEOAPIFY_SERVER_KEY') ?? '';
const identities = new Map<string,{uid:string;expires:number}>();
const verifying = new Map<string,Promise<string | null>>();
const pngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
const pngHeader = [0, 0, 0, 13, 73, 72, 68, 82]; // Length and type of the IHDR chunk.

function validPayload(kind: MapPayload, bytes: Uint8Array): boolean {
  if (kind === 'tile') {
    const headerSize = pngSignature.length + pngHeader.length + 13 + 4;
    return bytes.length >= headerSize &&
      pngSignature.every((value, index) => bytes[index] === value) &&
      pngHeader.every((value, index) => bytes[pngSignature.length + index] === value) &&
      !new TextDecoder().decode(bytes).includes(providerKey);
  }
  try {
    const text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
    const payload = JSON.parse(text);
    if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return false;
    // Check decoded JSON too, so a Unicode-escaped echo is also rejected.
    if (text.includes(providerKey) || JSON.stringify(payload).includes(providerKey)) return false;
    return kind === 'places'
      ? Array.isArray(payload.results)
      : payload.type === 'FeatureCollection' && Array.isArray(payload.features);
  } catch {
    return false;
  }
}

function response(status:number) {
  return new Response(JSON.stringify({error:status === 429 ? 'maps_limit' : 'maps_unavailable'}),
    {status,headers:{'content-type':'application/json','cache-control':'no-store'}});
}

function failedDependency(error: unknown, status: 502 | 503): Response {
  return response(error instanceof DOMException && error.name === 'TimeoutError' ? 504 : status);
}

async function identity(token:string):Promise<string | null> {
  const known = identities.get(token);
  if (known && known.expires > Date.now()) return known.uid;
  const pending = verifying.get(token); if (pending) return pending;
  const task = (async () => {
    const auth = await fetch(project+'/auth/v1/user',{
      headers:{apikey:serviceKey,Authorization:token},
      redirect:'error',
      signal:AbortSignal.timeout(5000),
    });
    if (auth.status >= 400 && auth.status < 500 && auth.status !== 429) return null;
    if (!auth.ok) throw Error('auth unavailable');
    const user = await auth.json();
    if (typeof user?.id !== 'string' || !user.id) throw Error('invalid auth response');
    // Only expiry of an already server-verified token is used, never decoded roles.
    let expiry: number;
    try {
      const segment=token.slice(7).split('.')[1].replace(/-/g,'+').replace(/_/g,'/');
      expiry=JSON.parse(atob(segment)).exp * 1000;
    } catch {
      return null;
    }
    if (!Number.isFinite(expiry) || expiry <= Date.now()) return null;
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
  let uid:string | null;
  try { uid=await identity(token); } catch (error) { return failedDependency(error, 503); }
  if (uid === null) return response(401);
  try {
    const quota=await fetch(project+'/rest/v1/rpc/orbita_map_budget',{
      method:'POST',headers:{apikey:serviceKey,Authorization:'Bearer '+serviceKey,'Content-Type':'application/json'},
      body:JSON.stringify({p_user:uid,p_units:plan.units}),redirect:'error',signal:AbortSignal.timeout(5000)});
    if (!quota.ok) return response(503);
    const allowed = await quota.json();
    if (allowed === false) return response(429);
    if (allowed !== true) return response(503);
  } catch (error) {
    return failedDependency(error, 503);
  }
  try {
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
    if(!validPayload(plan.payload, bytes)) return response(502);
    const type = plan.payload === 'tile' ? 'image/png' : 'application/json';
    return new Response(bytes,{headers:{'content-type':type,'cache-control':'private,max-age=60','x-content-type-options':'nosniff'}});
  } catch (error) { return failedDependency(error, 502); }
});
