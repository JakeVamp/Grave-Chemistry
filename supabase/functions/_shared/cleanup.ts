// Deletes queued storage objects. The database decides what is safe to
// delete; anything under quarantine, legal hold or a child-safety hold is
// never handed out, and each object is re-confirmed right before deletion.

import type { Rpc } from "./pipeline.ts";

export interface ObjectRemover {
  remove(bucket: string, path: string): Promise<void>;
}

export interface CleanupSummary {
  enqueued: number;
  claimed: number;
  deleted: number;
  skipped: number;
  failed: number;
}

export async function runCleanupBatch(rpc: Rpc, storage: ObjectRemover, limit = 50): Promise<CleanupSummary> {
  const enqueued = await rpc("cleanup_enqueue_expired");
  if (enqueued.error) throw new Error("enqueue failed");
  const claimed = await rpc("cleanup_claim_deletions", { p_limit: limit });
  if (claimed.error) throw new Error("claim failed");

  const items = (claimed.data ?? []) as { queue_id: number; bucket_id: string; object_path: string }[];
  const summary: CleanupSummary = {
    enqueued: Number(enqueued.data ?? 0),
    claimed: items.length,
    deleted: 0,
    skipped: 0,
    failed: 0,
  };

  for (const item of items) {
    const confirmed = await rpc("cleanup_confirm_deletable", { p_queue_id: item.queue_id });
    if (confirmed.error || confirmed.data !== true) {
      summary.skipped++;
      continue;
    }
    try {
      await storage.remove(item.bucket_id, item.object_path);
      await rpc("cleanup_mark_result", { p_queue_id: item.queue_id, p_success: true });
      summary.deleted++;
    } catch {
      await rpc("cleanup_mark_result", { p_queue_id: item.queue_id, p_success: false, p_error: "storage_error" });
      summary.failed++;
    }
  }
  return summary;
}
