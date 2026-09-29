// Edge Function: processes pending profile photos.
// Invoked by Supabase Cron with the x-cron-secret header. Uses the service
// role to call the pipeline RPCs; users can't call those functions.
//
// Secrets: SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY (provided by Supabase),
// PHOTO_PIPELINE_CRON_SECRET, and later CHILD_SAFETY_PROVIDER /
// MODERATION_PROVIDER plus the provider's own credentials.

import { createClient } from "npm:@supabase/supabase-js@2";
import { isAuthorizedCronRequest } from "../_shared/auth.ts";
import { runPipelineBatch } from "../_shared/pipeline.ts";
import { providersFromEnv } from "../_shared/providers.ts";

Deno.serve(async (req) => {
  if (!isAuthorizedCronRequest(req, Deno.env.get("PHOTO_PIPELINE_CRON_SECRET"))) {
    return new Response("forbidden", { status: 403 });
  }

  let providers;
  try {
    providers = providersFromEnv((key) => Deno.env.get(key));
  } catch {
    // Misconfigured provider: process nothing rather than skip a check.
    return new Response("provider configuration error", { status: 500 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );
  const bucket = supabase.storage;

  const summary = await runPipelineBatch(
    (fn, params) => supabase.rpc(fn, params),
    {
      childSafety: providers.childSafety,
      moderation: providers.moderation,
      storage: {
        async download(bucketId, path) {
          const { data, error } = await bucket.from(bucketId).download(path);
          if (error || !data) throw new Error("download failed");
          return new Uint8Array(await data.arrayBuffer());
        },
        async replace(bucketId, path, jpeg) {
          const { error } = await bucket.from(bucketId).upload(path, jpeg, {
            contentType: "image/jpeg",
            upsert: true,
          });
          if (error) throw new Error("upload failed");
        },
      },
    },
    { limit: 10, workerId: "process-profile-photos" },
  );

  // Counts only: no ids, paths or provider details.
  return Response.json(summary);
});
