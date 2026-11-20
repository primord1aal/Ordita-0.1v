// Local HTTP fakes exercise safe failure paths; this is not a hosted Auth test.
import { strict as assert } from 'node:assert';
import { test } from 'node:test';
let handler:(request:Request)=>Promise<Response>;
(globalThis as any).Deno={env:{get:(name:string)=>name==='GEOAPIFY_SERVER_KEY'?'synthetic-provider-secret':'synthetic-service-secret'},
  serve:(value:typeof handler)=>{handler=value;}};
await import('./index.ts');
const url='https://local.test/?path=/v1/geocode/autocomplete&text=Пушкина20';
const token=()=> 'Bearer x.'+btoa(JSON.stringify({exp:Math.ceil(Date.now()/1000)+60,nonce:Math.random()}))+'.x';
test('anonymous request cannot reach Auth, quota or Geoapify',async()=>{
  globalThis.fetch=async()=>{throw Error('must not fetch');};
  assert.equal((await handler(new Request(url))).status,401);
});
test('unapproved upstream URL is rejected before external requests',async()=>{
  globalThis.fetch=async()=>{throw Error('must not fetch');};
  assert.equal((await handler(new Request('https://local.test/?path=https://evil.test',{headers:{Authorization:token()}}))).status,400);
});
test('quota rejection never fetches Geoapify',async()=>{
  let calls=0;
  globalThis.fetch=async(input)=>{
    calls++; const path=String(input);
    if(path.endsWith('/auth/v1/user')) return Response.json({id:'synthetic-user'});
    assert(path.endsWith('/rest/v1/rpc/orbita_map_budget'));
    return Response.json(false);
  };
  const reply=await handler(new Request(url,{headers:{Authorization:token()}}));
  assert.equal(reply.status,429); assert.equal(calls,2);
  assert(!(await reply.text()).includes('synthetic-provider-secret'));
});
test('unavailable budget fails closed and hides upstream details',async()=>{
  globalThis.fetch=async(input)=>String(input).endsWith('/auth/v1/user')
    ? Response.json({id:'synthetic-user'}) : new Response('private SQL failure',{status:500});
  const reply=await handler(new Request(url,{headers:{Authorization:token()}}));
  assert.equal(reply.status,503); assert(!(await reply.text()).includes('SQL'));
});
