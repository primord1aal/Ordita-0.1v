import test from "node:test";
import assert from "node:assert/strict";
import { createPushWorker } from "./worker.ts";

const config = {
  projectUrl: "https://fjqghohhohgvwlmefdmo.supabase.co",
  serviceKey: "synthetic-database-worker-key-test",
  workerKey: "synthetic-invocation-key-only-test",
  rustoreProject: "local-only-project",
  rustoreToken: "synthetic-rustore-service-key-test",
};
const now = Date.parse("2026-11-27T08:00:00Z");
const event = {
  event_id: "00000000-0000-4000-8000-000000000001",
  recipient_id: "00000000-0000-4000-8000-000000000002",
  lease_id: "00000000-0000-4000-8000-000000000003",
  expires_at: "2026-11-27T08:00:12.345678Z",
  token: "synthetic-rustore-driver-token",
};
const request = (key = config.workerKey) => new Request("https://worker.invalid", {
  method: "POST", headers: { "x-orbita-worker-key": key },
});

test("wrong project, missing secrets and wrong invocation key stay offline", async () => {
  const http = async () => { throw new Error("unexpected outbound request"); };
  for (const invalid of [{ projectUrl: "https://example.invalid" }, { rustoreToken: "" }]) {
    assert.equal((await createPushWorker({ ...config, ...invalid }, http)(request())).status, 503);
  }
  assert.equal((await createPushWorker(config, http)(request("invalid-key"))).status, 403);
});

test("authorized worker sends a fixed data-only RuStore message with short TTL", async () => {
  const calls: [string, RequestInit][] = [];
  const http: typeof fetch = async (url, init) => {
    calls.push([String(url), init!]);
    if (String(url).endsWith("_claim")) return Response.json([event]);
    if (String(url).endsWith(":send")) return Response.json({});
    return Response.json(true);
  };
  const answer = await createPushWorker(config, http, () => now)(request());
  assert.equal(answer.status, 200);
  assert.deepEqual(await answer.json(), { provider_accepted: 1, retry: 0, discarded: 0, unconfirmed: 0 });
  assert.deepEqual(calls.map(([url]) => url), [
    config.projectUrl + "/rest/v1/rpc/orbita_driver_push_claim",
    "https://vkpns.rustore.ru/v1/projects/local-only-project/messages:send",
    config.projectUrl + "/rest/v1/rpc/orbita_driver_push_finish",
  ]);
  assert.ok(calls.every(([, init]) => init.redirect === "error" && init.signal));
  assert.equal(new Headers(calls[1][1].headers).get("authorization"), "Bearer " + config.rustoreToken);
  const payload = JSON.parse(String(calls[1][1].body));
  assert.deepEqual(payload, { message: {
    token: event.token,
    data: { kind: "driver_offer", offer_id: event.event_id, expires_at: "2026-11-27T08:00:12.345Z" },
    android: { ttl: "12.345s" },
  } });
  assert.deepEqual(JSON.parse(String(calls[2][1].body)), {
    p_event_id: event.event_id, p_lease_id: event.lease_id, p_result: "provider_accepted",
  });
});

test("expired lease skips transport, temporary errors retry, and failed acknowledgement is visible", async () => {
  const calls: string[] = [];
  for (const item of [{ ...event, expires_at: "2026-11-27T08:00:00.100Z" }, event]) {
    let claimedOutcome;
    const http: typeof fetch = async (url, init) => {
      if (String(url).endsWith("_claim")) return Response.json([item]);
      if (String(url).endsWith(":send")) {
        calls.push("send");
        return new Response("private upstream body", { status: 429 });
      }
      claimedOutcome = JSON.parse(String(init?.body)).p_result;
      return Response.json(item !== event);
    };
    const response = await createPushWorker(config, http, () => now)(request());
    assert.equal(response.status, item === event ? 502 : 200);
    assert.equal(claimedOutcome, item === event ? "retry" : "discarded");
    assert.equal((await response.json()).unconfirmed, item === event ? 1 : 0);
  }
  assert.deepEqual(calls, ["send"]);
});
