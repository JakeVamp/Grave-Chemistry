// Edge Function: signed URLs for side-by-side moderator photo review.
// Called by the app with the moderator's own session (JWT verification
// stays ON when deploying). The database re-checks role + MFA and audits
// the access before any URL is signed; URLs live for 60 seconds.
//
// Secrets: SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
// (all provided by Supabase). No other configuration.

import { createClient } from "npm:@supabase/supabase-js@2";
import { issueReviewMedia } from "../_shared/review_media.ts";

const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };

function reply(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers });
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "method_not_allowed" });
  const authorization = req.headers.get("Authorization") ?? "";
  if (!/^Bearer \S+$/.test(authorization)) return reply(401, { error: "not_authenticated" });

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceKey) return reply(500, { error: "configuration" });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply(400, { error: "invalid_request" });
  }

  const options = { auth: { persistSession: false, autoRefreshToken: false } };
  const asCaller = createClient(url, anonKey, { ...options, global: { headers: { Authorization: authorization } } });
  const admin = createClient(url, serviceKey, options);

  const result = await issueReviewMedia(body?.photo_id, {
    fetchContext: (photoId) => asCaller.rpc("moderator_photo_review_context", { p_photo_id: photoId }),
    async signUrl(bucketId, path, expiresIn) {
      const { data, error } = await admin.storage.from(bucketId).createSignedUrl(path, expiresIn);
      return error || !data ? null : data.signedUrl;
    },
  });
  return reply(result.status, result.body);
});
