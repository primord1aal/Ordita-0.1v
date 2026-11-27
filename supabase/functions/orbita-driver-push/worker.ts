const testProject = "https://fjqghohhohgvwlmefdmo.supabase.co";
const batchSize = 8;
const uuid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/u;

type Delivery = { event_id: string; lease_id: string; expires_at: string; token: string };
type Outcome = "provider_accepted" | "retry" | "discarded";
type Config = {
  projectUrl?: string;
  serviceKey?: string;
  workerKey?: string;
  rustoreProject?: string;
  rustoreToken?: string;
};

function secret(value: string | undefined): value is string {
  return value !== undefined && value.length >= 32 && value.length <= 4096 && /^[!-~]+$/u.test(value);
}

function sameKey(expected: string, received: string | null): boolean {
  if (received === null || received.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < expected.length; i++) {
    difference |= expected.charCodeAt(i) ^ received.charCodeAt(i);
  }
  return difference === 0;
}

function delivery(value: unknown): value is Delivery {
  if (value === null || typeof value !== "object") return false;
  const row = value as Partial<Delivery>;
  return typeof row.event_id === "string" && uuid.test(row.event_id) &&
    typeof row.lease_id === "string" && uuid.test(row.lease_id) &&
    typeof row.token === "string" && row.token.length >= 16 && row.token.length <= 2048 && /^[!-~]+$/u.test(row.token) &&
    typeof row.expires_at === "string" && row.expires_at.length <= 40 &&
    Number.isFinite(Date.parse(row.expires_at));
}

async function readJson(response: Response): Promise<unknown> {
  if (!response.body) throw new Error("missing body");
  const reader = response.body.getReader();
  const decoder = new TextDecoder("utf-8", { fatal: true });
  let bytes = 0;
  let body = "";
  try {
    while (true) {
      const chunk = await reader.read();
      if (chunk.done) return JSON.parse(body + decoder.decode());
      bytes += chunk.value.byteLength;
      if (bytes > 32 * 1024) throw new Error("excessive body");
      body += decoder.decode(chunk.value, { stream: true });
    }
  } catch (error) {
    void reader.cancel().catch(() => {});
    throw error;
  } finally {
    reader.releaseLock();
  }
}

export function createPushWorker(config: Config, http = fetch, now = Date.now) {
  const { projectUrl, serviceKey, workerKey, rustoreProject, rustoreToken } = config;
  if (projectUrl !== testProject || !secret(serviceKey) || !secret(workerKey) ||
      !secret(rustoreToken) || !rustoreProject || !/^[A-Za-z0-9_-]{1,120}$/u.test(rustoreProject)) {
    return async () => Response.json({ error: "unavailable" }, { status: 503 });
  }

  const providerUrl = `https://vkpns.rustore.ru/v1/projects/${rustoreProject}/messages:send`;
  async function rpc(name: "claim" | "finish", body: object, timeout: number): Promise<unknown> {
    const response = await http(`${projectUrl}/rest/v1/rpc/orbita_driver_push_${name}`, {
      method: "POST", redirect: "error", signal: AbortSignal.timeout(timeout),
      headers: { apikey: serviceKey!, Authorization: `Bearer ${serviceKey}`, "content-type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      void response.body?.cancel().catch(() => {});
      throw new Error("database unavailable");
    }
    return readJson(response);
  }

  async function send(item: Delivery): Promise<Outcome> {
    const expires = Date.parse(item.expires_at);
    const remaining = Math.min(expires - now(), 25_000);
    // RuStore treats zero TTL as the default of four weeks.
    if (remaining < 500) return "discarded";
    try {
      const response = await http(providerUrl, {
        method: "POST", redirect: "error", signal: AbortSignal.timeout(2500),
        headers: { Authorization: `Bearer ${rustoreToken}`, "content-type": "application/json" },
        body: JSON.stringify({ message: {
          token: item.token,
          data: { kind: "driver_offer", offer_id: item.event_id, expires_at: new Date(expires).toISOString() },
          android: { ttl: `${(remaining / 1000).toFixed(3)}s` },
        } }),
      });
      void response.body?.cancel().catch(() => {});
      if (response.status === 200) return "provider_accepted";
      if (response.status === 429 || response.status >= 500) return "retry";
      return "discarded";
    } catch {
      return "retry";
    }
  }

  return async (request: Request): Promise<Response> => {
    if (request.method !== "POST") return Response.json({ error: "method" }, { status: 405 });
    if (!sameKey(workerKey, request.headers.get("x-orbita-worker-key"))) {
      return Response.json({ error: "forbidden" }, { status: 403 });
    }
    try {
      const claims = await rpc("claim", { p_limit: batchSize }, 2000);
      if (!Array.isArray(claims) || claims.length > batchSize || !claims.every(delivery)) {
        throw new Error("invalid claim");
      }
      const counts = { provider_accepted: 0, retry: 0, discarded: 0, unconfirmed: 0 };
      await Promise.all(claims.map(async item => {
        const result = await send(item);
        try {
          const recorded = await rpc("finish", {
            p_event_id: item.event_id, p_lease_id: item.lease_id, p_result: result,
          }, 1500);
          if (recorded === true) counts[result]++;
          else counts.unconfirmed++;
        } catch {
          counts.unconfirmed++;
        }
      }));
      return Response.json(counts, { status: counts.unconfirmed === 0 ? 200 : 502 });
    } catch {
      return Response.json({ error: "unavailable" }, { status: 502 });
    }
  };
}
