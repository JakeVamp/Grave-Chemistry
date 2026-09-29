// Edge Function: deletes queued media files that are safe to delete.
// Invoked by Supabase Cron with the x-cron-secret header.

import { createClient } from "npm:@supabase/supabase-js@2";
import { isAuthorizedCronRequest } from "../_shared/auth.ts";
import { runCleanupBatch } from "../_shared/cleanup.ts";

Deno.serve(async (req) => {
  if (!isAuthorizedCronRequest(req, Deno.env.get("PHOTO_PIPELINE_CRON_SECRET"))) {
    return new Response("forbidden", { status: 403 });
  }
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    { auth: { persistSession: false, autoRefreshToken: false } },
  );

  const summary = await runCleanupBatch(
    (fn, params) => supabase.rpc(fn, params),
    {
      async remove(bucketId, path) {
        const { error } = await supabase.storage.from(bucketId).remove([path]);
        if (error) throw new Error("remove failed");
      },
    },
  );
  return Response.json(summary);
});
