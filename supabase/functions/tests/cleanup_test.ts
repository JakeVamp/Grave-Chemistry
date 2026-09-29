import { assertEquals } from "jsr:@std/assert@1";
import { isAuthorizedCronRequest } from "../_shared/auth.ts";
import { runCleanupBatch } from "../_shared/cleanup.ts";
import type { Rpc } from "../_shared/pipeline.ts";

Deno.test("clean-up deletes only confirmed items and records every outcome", async () => {
  const marks: unknown[] = [];
  const confirmations: Record<number, boolean> = { 1: true, 2: false, 3: true };
  const rpc: Rpc = (fn, params) => {
    if (fn === "cleanup_enqueue_expired") return Promise.resolve({ data: 2, error: null });
    if (fn === "cleanup_claim_deletions") {
      return Promise.resolve({
        data: [
          { queue_id: 1, bucket_id: "profile-photos", object_path: "a" },
          { queue_id: 2, bucket_id: "profile-photos", object_path: "held" },
          { queue_id: 3, bucket_id: "profile-photos", object_path: "broken" },
        ],
        error: null,
      });
    }
    if (fn === "cleanup_confirm_deletable") {
      return Promise.resolve({ data: confirmations[params!.p_queue_id as number], error: null });
    }
    marks.push(params);
    return Promise.resolve({ data: "ok", error: null });
  };
  const removed: string[] = [];
  const summary = await runCleanupBatch(rpc, {
    remove(_bucket, path) {
      if (path === "broken") return Promise.reject(new Error("storage error"));
      removed.push(path);
      return Promise.resolve();
    },
  });

  assertEquals(removed, ["a"], "held objects are never removed");
  assertEquals(summary, { enqueued: 2, claimed: 3, deleted: 1, skipped: 1, failed: 1 });
  assertEquals(marks, [
    { p_queue_id: 1, p_success: true },
    { p_queue_id: 3, p_success: false, p_error: "storage_error" },
  ]);
});

Deno.test("worker functions require the cron secret", () => {
  const secret = "s".repeat(40);
  const request = (header?: string) =>
    new Request("https://example.test", { headers: header ? { "x-cron-secret": header } : {} });
  assertEquals(isAuthorizedCronRequest(request(secret), secret), true);
  assertEquals(isAuthorizedCronRequest(request("wrong"), secret), false);
  assertEquals(isAuthorizedCronRequest(request(), secret), false);
  assertEquals(isAuthorizedCronRequest(request(secret), undefined), false, "no secret configured means no access");
  assertEquals(isAuthorizedCronRequest(request("short"), "short"), false, "short secrets are refused");
});
