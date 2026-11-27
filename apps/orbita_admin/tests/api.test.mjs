import test from 'node:test';
import assert from 'node:assert/strict';
import { AdminApiError, createAdminApi, validPublishableKey } from '../dist/api.mjs';

const project = 'https://fjqghohhohgvwlmefdmo.supabase.co';
const key = 'sb_publishable_fixture_0123456789abcdef';
const token = 'fixture.token.signature';
const passengerId = '00000000-0000-4000-8000-000000000001';
const driverId = '00000000-0000-4000-8000-000000000002';
const requestId = '00000000-0000-4000-8000-000000000003';
const pickup = { address: 'Чик, Учебная', latitude: 55, longitude: 82.43 };
const destination = { address: 'Прокудское, Учебная', latitude: 55.01, longitude: 82.44 };

function emptySnapshot() {
  return {
    contract_version: 1,
    captured_at: '2026-11-24T08:00:00+00:00',
    active_orders: [],
    history: [],
    queue: [],
    truncated: { active_orders: false, history: false, queue: false },
  };
}

test('password, snapshot and logout use only the fixed test project and expected API profile', async () => {
  const requests = [];
  const snapshot = emptySnapshot();
  const client = createAdminApi(key, async (url, init) => {
    requests.push([url, init]);
    if (url.includes('/token?')) return Response.json({ access_token: token, refresh_token: 'fixture ignored' });
    if (url.includes('/snapshot')) return Response.json(snapshot);
    return new Response(null, { status: 204 });
  });
  assert.equal(await client.signIn('admin@example.test', 'fixture password'), token);
  assert.deepEqual(await client.snapshot(token), snapshot);
  await client.signOut(token);
  assert.deepEqual(requests.map(([url]) => url), [
    project + '/auth/v1/token?grant_type=password',
    project + '/rest/v1/rpc/snapshot',
    project + '/auth/v1/logout?scope=local',
  ]);
  for (const [, options] of requests) {
    assert.equal(options.method, 'POST');
    assert.equal(options.headers.apikey, key);
    assert.equal(options.redirect, 'error');
    assert.equal(options.cache, 'no-store');
    assert.equal(options.credentials, 'omit');
    assert.ok(options.signal instanceof AbortSignal);
  }
  assert.equal(requests[0][1].headers.Authorization, undefined);
  assert.equal(requests[1][1].headers.Authorization, 'Bearer ' + token);
  assert.equal(requests[1][1].headers['Content-Profile'], 'orbita_admin_api');
  assert.equal(requests[2][1].headers.Authorization, 'Bearer ' + token);
});

test('service and legacy keys are rejected before any request', () => {
  for (const input of ['', 'sb_secret_fixture_0123456789abcdef', token]) {
    assert.equal(validPublishableKey(input), false);
    assert.throws(() => createAdminApi(input), { kind: 'invalid-config' });
  }
});

test('access denial remains a safe error when the server response includes private detail', async () => {
  const client = createAdminApi(key, async () => Response.json({ error: 'private detail' }, { status: 403 }));
  await assert.rejects(client.snapshot(token), error => {
    assert.ok(error instanceof AdminApiError);
    assert.equal(error.accessDenied, true);
    assert.equal(error.status, 403);
    assert.equal(error.message, 'request');
    return true;
  });
});

test('unexpected shape and oversized response never become a dashboard snapshot', async () => {
  const data = emptySnapshot();
  for (const invalid of [
    { ...data, contract_version: 2 },
    { ...data, queue: Array(51).fill({}) },
    { ...data, active_orders: [{ driver_id: null }] },
    { ...data, extra: 'x'.repeat(256 * 1024) },
  ]) {
    const client = createAdminApi(key, async () => Response.json(invalid));
    await assert.rejects(client.snapshot(token), { kind: 'invalid-response' });
  }
});

test('operations, restrictions and phone orders use typed responses and the same authenticated API', async () => {
  const operations = {
    contract_version: 1, captured_at: emptySnapshot().captured_at,
    drivers: [{ driver_id: driverId, display_name: 'Учебный водитель', online: true,
      restricted: false, active_order_id: null }],
    audit: [], truncated: { drivers: false, audit: false }, phone_orders_enabled: true,
  };
  const restriction = { driver_id: driverId, restricted: true };
  const order = { order_id: requestId, status: 'created', expires_at: '2026-11-24T08:05:00Z' };
  const routes = { operations, set_driver_restriction: restriction, create_phone_order: order };
  const requests = [];
  const client = createAdminApi(key, async (url, options) => {
    assert.ok(url.startsWith(project + '/rest/v1/rpc/'));
    assert.equal(options.headers.Authorization, 'Bearer ' + token);
    assert.equal(options.headers['Content-Profile'], 'orbita_admin_api');
    const route = url.split('/').at(-1);
    requests.push([route, JSON.parse(options.body)]);
    return Response.json(routes[route]);
  });
  assert.deepEqual(await client.operations(token), operations);
  assert.deepEqual(await client.setDriverRestriction(token, { requestId, driverId, restricted: true }), restriction);
  assert.deepEqual(await client.createPhoneOrder(token, { requestId, passengerId, pickup, destination }), order);
  assert.deepEqual(requests, [
    ['operations', {}],
    ['set_driver_restriction', { p_request_id: requestId, p_driver_id: driverId, p_restricted: true }],
    ['create_phone_order', { p_request_id: requestId, p_passenger_id: passengerId, p_pickup: pickup, p_destination: destination }],
  ]);
});

test('invalid phone inputs stay local and a rejected passenger does not expire the admin session', async () => {
  let calls = 0;
  const client = createAdminApi(key, async () => {
    calls++;
    return Response.json({ message: 'private detail' }, { status: 400 });
  });
  const intent = { requestId, passengerId, pickup, destination };
  await assert.rejects(client.createPhoneOrder(token, { ...intent, destination: pickup }), { kind: 'invalid-input' });
  assert.equal(calls, 0);
  await assert.rejects(client.createPhoneOrder(token, intent), error => {
    assert.equal(error.status, 400);
    assert.equal(error.accessDenied, false);
    assert.equal(error.message, 'request');
    return true;
  });
  assert.equal(calls, 1);
});
