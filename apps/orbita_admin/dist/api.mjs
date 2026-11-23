const PROJECT = 'https://fjqghohhohgvwlmefdmo.supabase.co';
const MAX_ROWS = 50;
const MAX_BYTES = 256 * 1024;
const ACTIVE_STATES = new Set(['created', 'accepted', 'to_pickup', 'arrived', 'riding']);
const HISTORY_STATES = new Set(['completed', 'cancelled']);
const QUEUE_STATES = new Set(['waiting', 'offered', 'busy', 'updating']);
const SNAPSHOT_KEYS = ['active_orders', 'history', 'queue'];
const ID = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/iu;

export class AdminApiError extends Error {
  constructor(kind, status = 0) {
    super(kind);
    this.kind = kind;
    this.status = status;
  }

  get accessDenied() {
    return this.status === 401 || this.status === 403;
  }
}

function boundedText(value, limit) {
  return typeof value === 'string' && [...value].length <= limit;
}

function uuid(value) {
  return typeof value === 'string' && ID.test(value);
}

function timestamp(value) {
  return typeof value === 'string' && value.length <= 40 && Number.isFinite(Date.parse(value));
}

function validActive(row) {
  return row && uuid(row.id) && ACTIVE_STATES.has(row.status) && timestamp(row.created_at) &&
    timestamp(row.expires_at) && (row.driver_id === null || uuid(row.driver_id)) &&
    boundedText(row.pickup_address, 120) && boundedText(row.destination_address, 120);
}

function validHistory(row) {
  return row && uuid(row.id) && HISTORY_STATES.has(row.status) && timestamp(row.finished_at) &&
    (row.status === 'completed' ? row.cancellation_reason === null :
      ['passenger', 'search_timeout'].includes(row.cancellation_reason));
}

function validQueue(row) {
  return row && uuid(row.driver_id) && QUEUE_STATES.has(row.state) &&
    (row.display_name === null || boundedText(row.display_name, 80)) &&
    (row.order_id === null || uuid(row.order_id));
}

function validRows(rows, verify) {
  return Array.isArray(rows) && rows.length <= MAX_ROWS && rows.every(verify);
}

function checkedSnapshot(data) {
  if (!data || data.contract_version !== 1 || !timestamp(data.captured_at) ||
      !validRows(data.active_orders, validActive) || !validRows(data.history, validHistory) ||
      !validRows(data.queue, validQueue) || !data.truncated ||
      !SNAPSHOT_KEYS.every(key => typeof data.truncated[key] === 'boolean')) {
    throw new AdminApiError('invalid-response');
  }
  return data;
}

async function readJson(response) {
  const declaredLength = Number(response.headers.get('Content-Length'));
  if (!response.body || declaredLength > MAX_BYTES ||
      !/^application\/json(?:;|$)/iu.test(response.headers.get('Content-Type') ?? '')) {
    void response.body?.cancel().catch(() => {});
    throw new AdminApiError('invalid-response');
  }
  const reader = response.body.getReader();
  const decoder = new TextDecoder('utf-8', { fatal: true });
  let bytes = 0;
  let body = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_BYTES) throw new AdminApiError('invalid-response');
      body += decoder.decode(value, { stream: true });
    }
    return JSON.parse(body + decoder.decode());
  } catch {
    void reader.cancel().catch(() => {});
    throw new AdminApiError('invalid-response');
  } finally {
    reader.releaseLock();
  }
}

export function validPublishableKey(value) {
  return typeof value === 'string' && /^sb_publishable_[A-Za-z0-9_-]{16,240}$/u.test(value);
}

function jwt(value) {
  return typeof value === 'string' && value.length < 8192 &&
    /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/u.test(value);
}

export function createAdminApi(publishableKey, fetcher = globalThis.fetch) {
  if (!validPublishableKey(publishableKey)) throw new AdminApiError('invalid-config');

  async function request(path, { body, token, signal, profile }) {
    const headers = {
      apikey: publishableKey,
      'Content-Type': 'application/json',
      Accept: 'application/json',
    };
    if (token !== undefined) {
      if (!jwt(token)) throw new AdminApiError('access', 401);
      headers.Authorization = `Bearer ${token}`;
    }
    if (profile) headers['Content-Profile'] = 'orbita_admin_api';

    let response;
    const deadline = AbortSignal.timeout(8_000);
    try {
      response = await fetcher(PROJECT + path, {
        method: 'POST',
        headers,
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: 'error',
        cache: 'no-store',
        credentials: 'omit',
        signal: signal ? AbortSignal.any([signal, deadline]) : deadline,
      });
    } catch {
      throw new AdminApiError('connection');
    }
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      throw new AdminApiError('request', response.status);
    }
    return response;
  }

  return {
    async signIn(email, password, signal) {
      const data = await readJson(await request('/auth/v1/token?grant_type=password', {
        body: { email, password }, signal,
      }));
      if (!jwt(data?.access_token)) throw new AdminApiError('invalid-response');
      return data.access_token;
    },
    async snapshot(token, signal) {
      return checkedSnapshot(await readJson(await request('/rest/v1/rpc/snapshot', {
        body: {}, token, signal, profile: true,
      })));
    },
    async signOut(token) {
      const response = await request('/auth/v1/logout?scope=local', { token });
      void response.body?.cancel().catch(() => {});
    },
  };
}
