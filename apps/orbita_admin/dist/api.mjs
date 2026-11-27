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
    (row.order_id === null || uuid(row.order_id)) &&
    (row.queue_rank == null || (row.state === 'waiting' &&
      Number.isInteger(row.queue_rank) && row.queue_rank > 0 && row.queue_rank <= MAX_ROWS));
}

function validDriver(row) {
  return row && uuid(row.driver_id) &&
    (row.display_name === null || boundedText(row.display_name, 80)) &&
    typeof row.online === 'boolean' && typeof row.restricted === 'boolean' &&
    (row.active_order_id === null || uuid(row.active_order_id));
}

function validAudit(row) {
  return row && uuid(row.actor_id) && uuid(row.request_id) && uuid(row.target_id) &&
    timestamp(row.created_at) && row.details &&
    (row.action === 'driver_restriction' ? typeof row.details.restricted === 'boolean' :
      row.action === 'phone_order');
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

function checkedOperations(data) {
  if (!data || data.contract_version !== 1 || !timestamp(data.captured_at) ||
      !validRows(data.drivers, validDriver) || !validRows(data.audit, validAudit) ||
      typeof data.truncated?.drivers !== 'boolean' || typeof data.truncated?.audit !== 'boolean' ||
      (data.phone_orders_enabled !== undefined && typeof data.phone_orders_enabled !== 'boolean')) {
    throw new AdminApiError('invalid-response');
  }
  return data;
}

function validPoint(point) {
  return point && boundedText(point.address, 500) && point.address.trim() !== '' &&
    Number.isFinite(point.latitude) && Math.abs(point.latitude) <= 90 &&
    Number.isFinite(point.longitude) && Math.abs(point.longitude) <= 180;
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

  async function rpc(name, body, token, signal) {
    if (!jwt(token)) throw new AdminApiError('access', 401);
    return readJson(await request('/rest/v1/rpc/' + name, { body, token, signal, profile: true }));
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
      return checkedSnapshot(await rpc('snapshot', {}, token, signal));
    },
    async operations(token, signal) {
      return checkedOperations(await rpc('operations', {}, token, signal));
    },
    async setDriverRestriction(token, { requestId, driverId, restricted }, signal) {
      if (!uuid(requestId) || !uuid(driverId) || typeof restricted !== 'boolean') {
        throw new AdminApiError('invalid-input');
      }
      const result = await rpc('set_driver_restriction', {
        p_request_id: requestId, p_driver_id: driverId, p_restricted: restricted,
      }, token, signal);
      if (result?.driver_id !== driverId.toLowerCase() || result.restricted !== restricted) {
        throw new AdminApiError('invalid-response');
      }
      return result;
    },
    async createPhoneOrder(token, { requestId, passengerId, pickup, destination }, signal) {
      if (!uuid(requestId) || !uuid(passengerId) || !validPoint(pickup) || !validPoint(destination) ||
          (pickup.latitude === destination.latitude && pickup.longitude === destination.longitude)) {
        throw new AdminApiError('invalid-input');
      }
      const result = await rpc('create_phone_order', {
        p_request_id: requestId, p_passenger_id: passengerId, p_pickup: pickup, p_destination: destination,
      }, token, signal);
      if (!uuid(result?.order_id) || !timestamp(result.expires_at) ||
          (!ACTIVE_STATES.has(result.status) && !HISTORY_STATES.has(result.status))) {
        throw new AdminApiError('invalid-response');
      }
      return result;
    },
    async signOut(token) {
      const response = await request('/auth/v1/logout?scope=local', { token });
      void response.body?.cancel().catch(() => {});
    },
  };
}
