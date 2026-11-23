import test from 'node:test';
import assert from 'node:assert/strict';
import { AdminApiError, createAdminApi, validPublishableKey } from '../dist/api.mjs';

const project = 'https://fjqghohhohgvwlmefdmo.supabase.co';
const key = 'sb_publishable_fixture_0123456789abcdef';
const token = 'fixture.token.signature';

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
