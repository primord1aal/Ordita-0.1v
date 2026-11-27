import { createPushWorker } from "./worker.ts";

Deno.serve(createPushWorker({
  projectUrl: Deno.env.get("SUPABASE_URL"),
  serviceKey: Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"),
  workerKey: Deno.env.get("ORBITA_PUSH_WORKER_KEY"),
  rustoreProject: Deno.env.get("ORBITA_RUSTORE_PUSH_PROJECT_ID"),
  rustoreToken: Deno.env.get("ORBITA_RUSTORE_PUSH_SERVICE_TOKEN"),
}));
