// Local HTTP fakes exercise safe failure paths; this is not a hosted Auth test.
import { strict as assert } from 'node:assert';
import { test } from 'node:test';
let handler:(request:Request)=>Promise<Response>;
const providerKey = 'synthetic-provider-secret';
const serviceKey = 'synthetic-service-secret';
(globalThis as any).Deno={env:{get:(name:string)=>name==='GEOAPIFY_SERVER_KEY'?providerKey:serviceKey},
  serve:(value:typeof handler)=>{handler=value;}};
await import('./index.ts');
const url='https://local.test/?path=/v1/geocode/autocomplete&text=Пушкина20';
const token=()=> 'Bearer x.'+btoa(JSON.stringify({exp:Math.ceil(Date.now()/1000)+60,nonce:Math.random()}))+'.x';
function request(path: string, parameters: Record<string, string> = {}) {
  return new Request('https://local.test/?' + new URLSearchParams({path, ...parameters}), {
    headers: {Authorization: token()},
  });
}

function allowQuota(reply: Response) {
  globalThis.fetch = async (input) => {
    const path = new URL(String(input)).pathname;
    if (path === '/auth/v1/user') return Response.json({id:'synthetic-user'});
    if (path === '/rest/v1/rpc/orbita_map_budget') return Response.json(true);
    return reply;
  };
}

test('anonymous request cannot reach Auth, quota or Geoapify',async()=>{
  globalThis.fetch=async()=>{throw Error('must not fetch');};
  assert.equal((await handler(new Request(url))).status,401);
});
test('unapproved upstream URL is rejected before external requests',async()=>{
  globalThis.fetch=async()=>{throw Error('must not fetch');};
  assert.equal((await handler(new Request('https://local.test/?path=https://evil.test',{headers:{Authorization:token()}}))).status,400);
});
test('an incomplete route spends no quota and does not call Geoapify',async()=>{
  let calls = 0;
  globalThis.fetch = async () => { calls++; throw Error('must not fetch'); };
  const reply = await handler(request('/v1/routing', {waypoints: '55,82|,82'}));
  assert.equal(reply.status, 400);
  assert.equal(calls, 0);
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
test('malformed quota response is unavailable and never reaches Geoapify', async () => {
  globalThis.fetch = async (input) => {
    const path = new URL(String(input)).pathname;
    if (path === '/auth/v1/user') return Response.json({id:'synthetic-user'});
    assert.equal(path, '/rest/v1/rpc/orbita_map_budget');
    return Response.json({allowed: true});
  };
  const reply = await handler(request('/v1/geocode/autocomplete', {text: 'Пушкина 20'}));
  assert.equal(reply.status, 503);
  assert.deepEqual(await reply.json(), {error:'maps_unavailable'});
});
test('authentication failure, outage and timeout stay distinct and a retry can recover', async () => {
  const addressed = request('/v1/geocode/autocomplete', {text: 'Пушкина 20'});
  const stages: string[] = [];
  let authStatus = 401;
  globalThis.fetch = async (input) => {
    const path = new URL(String(input)).pathname;
    stages.push(path);
    if (path === '/auth/v1/user') {
      if (authStatus === 504) throw new DOMException('private timeout', 'TimeoutError');
      return authStatus === 200 ? Response.json({id:'synthetic-user'}) : new Response(null, {status:authStatus});
    }
    if (path === '/rest/v1/rpc/orbita_map_budget') return Response.json(true);
    return Response.json({results: []});
  };
  for (const [upstream, expected] of [[401, 401], [429, 503], [503, 503], [504, 504]]) {
    authStatus = upstream;
    const reply = await handler(addressed);
    assert.equal(reply.status, expected);
    assert.deepEqual(await reply.json(), {error:'maps_unavailable'});
  }
  assert.deepEqual(stages, Array(4).fill('/auth/v1/user'));

  authStatus = 200;
  const reply = await handler(addressed);
  assert.equal(reply.status, 200);
  assert.deepEqual(await reply.json(), {results: []});
  assert.deepEqual(stages.slice(-3), ['/auth/v1/user', '/rest/v1/rpc/orbita_map_budget', '/v1/geocode/autocomplete']);
});
test('provider quota, transport failure and timeout can recover without automatic retries', async () => {
  const addressed = request('/v1/geocode/autocomplete', {text: 'Пушкина 20'});
  const stages: string[] = [];
  const failures = [
    {status: 429, reply: () => new Response('private provider error', {status: 429})},
    {status: 502, reply: () => { throw new TypeError('private transport failure'); }},
    {status: 504, reply: () => { throw new DOMException('private timeout', 'TimeoutError'); }},
    {status: 200, reply: () => Response.json({results: []})},
  ];
  for (const failure of failures) {
    globalThis.fetch = async (input) => {
      const path = new URL(String(input)).pathname;
      stages.push(path);
      if (path === '/auth/v1/user') return Response.json({id:'synthetic-user'});
      if (path === '/rest/v1/rpc/orbita_map_budget') return Response.json(true);
      return failure.reply();
    };
    const reply = await handler(addressed);
    assert.equal(reply.status, failure.status);
    const expected = failure.status === 200 ? {results: []}
      : {error: failure.status === 429 ? 'maps_limit' : 'maps_unavailable'};
    assert.deepEqual(await reply.json(), expected);
  }
  assert.deepEqual(stages, [
    '/auth/v1/user',
    ...failures.flatMap(() => ['/rest/v1/rpc/orbita_map_budget', '/v1/geocode/autocomplete']),
  ]);
});
test('accepted route is charged once and sends each credential only to its service',async()=>{
  const route = {type: 'FeatureCollection', features: []};
  const hosts: string[] = [];
  const addressed = request('/v1/routing', {waypoints: '55.0,82.430|55.01,82.44', apiKey: 'ignored'});
  globalThis.fetch = async (input, init) => {
    const to = new URL(String(input));
    hosts.push(to.host);
    assert.equal(init?.redirect, 'error');
    const headers = new Headers(init?.headers);
    if (to.pathname === '/auth/v1/user') {
      assert.equal(headers.get('authorization'), addressed.headers.get('authorization'));
      assert.equal(headers.get('apikey'), serviceKey);
      return Response.json({id:'synthetic-user'});
    }
    if (to.pathname === '/rest/v1/rpc/orbita_map_budget') {
      assert.equal(headers.get('authorization'), 'Bearer ' + serviceKey);
      assert.equal(headers.get('apikey'), serviceKey);
      assert.deepEqual(JSON.parse(String(init?.body)), {p_user:'synthetic-user',p_units:10});
      return Response.json(true);
    }
    assert.equal(to.pathname, '/v1/routing');
    assert.equal(to.searchParams.get('apiKey'), providerKey);
    assert.equal(to.searchParams.get('waypoints'), '55,82.43|55.01,82.44');
    assert.equal(headers.get('authorization'), null);
    assert.equal(headers.get('apikey'), null);
    return Response.json(route);
  };
  const reply = await handler(addressed);
  assert.equal(reply.status, 200);
  assert.deepEqual(await reply.json(), route);
  const [authHost, quotaHost, geoapifyHost] = hosts;
  assert.equal(hosts.length, 3);
  assert.equal(authHost, quotaHost);
  assert.equal(geoapifyHost, 'api.geoapify.com');
});

test('invalid address responses and echoed provider keys stay behind the gateway',async()=>{
  const escapedKey = '\\u0073' + providerKey.slice(1);
  for (const body of ['{"features":[]}', '{"results":[],"query":{"apiKey":"' + escapedKey + '"}}']) {
    allowQuota(new Response(body));
    const reply = await handler(request('/v1/geocode/reverse', {lat: '55', lon: '82'}));
    assert.equal(reply.status, 502);
    assert.deepEqual(await reply.json(), {error:'maps_unavailable'});
  }
  const data = {results: [{lat:55,lon:82,street:'Ленина'}]};
  allowQuota(Response.json(data));
  const reply = await handler(request('/v1/geocode/reverse', {lat: '55', lon: '82'}));
  assert.equal(reply.status, 200);
  assert.deepEqual(await reply.json(), data);
});

test('only the complete PNG signature and header are served as a tile',async()=>{
  const path = '/v1/tile/osm-carto/0/0/0.png';
  allowQuota(new Response(Uint8Array.of(137,80,78,71)));
  assert.equal((await handler(request(path))).status, 502);
  const image = Uint8Array.from(
    atob('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIW2Nk+M/wHwAF/gL+P3gDoAAAAABJRU5ErkJggg=='),
    char => char.charCodeAt(0),
  );
  allowQuota(new Response(image));
  const reply = await handler(request(path));
  assert.equal(reply.status, 200);
  assert.equal(reply.headers.get('content-type'), 'image/png');
  assert.deepEqual(new Uint8Array(await reply.arrayBuffer()), image);
});
