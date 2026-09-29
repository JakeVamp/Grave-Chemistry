// Profile photo processing: turns one claimed photo into the normalised
// result that public.pipeline_submit_result() decides on. The database,
// not this code, makes every approve/reject/quarantine decision.

import { differenceHash, sha256Hex } from "./fingerprint.ts";
import { DEFAULT_LIMITS, type ImageLimits, normalizeJpeg, validateJpeg } from "./image.ts";
import {
  checkModeration,
  type ChildSafetyProvider,
  type ChildSafetyResult,
  type ModerationProvider,
  scanChildSafety,
} from "./providers.ts";

export interface Claim {
  photo_id: string;
  owner_id: string;
  bucket_id: string;
  object_path: string;
  attempt: number;
}

export interface PhotoStorage {
  download(bucket: string, path: string): Promise<Uint8Array>;
  /** Overwrites the object (service role). */
  replace(bucket: string, path: string, jpeg: Uint8Array): Promise<void>;
}

export interface PipelineDeps {
  storage: PhotoStorage;
  childSafety: ChildSafetyProvider;
  moderation: ModerationProvider;
  providerTimeoutMs?: number;
  limits?: ImageLimits;
}

export interface PipelineResult {
  validation: { ok: boolean; error?: string; width?: number; height?: number; bytes?: number };
  fingerprints?: { sha256: string; perceptual_hash: string };
  child_safety?: { result: ChildSafetyResult };
  moderation?: { result: string; categories: string[] };
}

const PATH_PATTERN = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/[0-9a-f]{32}\.jpg$/;
const SERIOUS: ChildSafetyResult[] = ["possible_match", "confirmed_known_hash_match"];

export async function processClaim(claim: Claim, deps: PipelineDeps): Promise<PipelineResult> {
  const match = PATH_PATTERN.exec(claim.object_path);
  if (claim.bucket_id !== "profile-photos" || !match || match[1] !== claim.photo_id) {
    return { validation: { ok: false, error: "wrong_path" } };
  }

  const original = await deps.storage.download(claim.bucket_id, claim.object_path);
  const limits = deps.limits ?? DEFAULT_LIMITS;
  const validated = validateJpeg(original, limits);
  if (!validated.ok) return { validation: { ok: false, error: validated.error } };

  // Server-side privacy normalisation, whatever the client did.
  const normalized = normalizeJpeg(validated);
  const recheck = validateJpeg(normalized.jpeg, limits);
  if (!recheck.ok) return { validation: { ok: false, error: recheck.error } };
  await deps.storage.replace(claim.bucket_id, claim.object_path, normalized.jpeg);

  const sha256 = await sha256Hex(normalized.jpeg);
  const perceptualHash = differenceHash(normalized.image);
  const timeout = deps.providerTimeoutMs ?? 20_000;

  const childSafety = await scanChildSafety(deps.childSafety, { jpeg: normalized.jpeg, sha256 }, timeout);
  // Never send suspected child-safety material to another provider.
  const moderation = SERIOUS.includes(childSafety)
    ? { result: "manual_review", categories: [] }
    : await checkModeration(deps.moderation, normalized.jpeg, timeout);

  return {
    validation: {
      ok: true,
      width: normalized.image.width,
      height: normalized.image.height,
      bytes: normalized.jpeg.length,
    },
    fingerprints: { sha256, perceptual_hash: perceptualHash },
    child_safety: { result: childSafety },
    moderation,
  };
}

/** Minimal RPC surface (supabase-js `rpc`), so tests can supply a fake. */
export type Rpc = (fn: string, params?: Record<string, unknown>) => PromiseLike<{ data: unknown; error: unknown }>;

export interface BatchSummary {
  claimed: number;
  outcomes: Record<string, number>;
  failures: number;
}

/** Claims a batch, processes each photo and reports back. Logs no paths or bytes. */
export async function runPipelineBatch(rpc: Rpc, deps: PipelineDeps, options: { limit?: number; workerId?: string } = {}): Promise<BatchSummary> {
  const { data, error } = await rpc("pipeline_claim_photos", {
    p_limit: options.limit ?? 10,
    p_worker: options.workerId ?? "edge",
  });
  if (error) throw new Error("claim failed");
  const claims = (data ?? []) as Claim[];
  const summary: BatchSummary = { claimed: claims.length, outcomes: {}, failures: 0 };

  for (const claim of claims) {
    try {
      const result = await processClaim(claim, deps);
      const submitted = await rpc("pipeline_submit_result", {
        p_photo_id: claim.photo_id,
        p_attempt: claim.attempt,
        p_result: result,
      });
      if (submitted.error) throw new Error("submit failed");
      const outcome = (submitted.data as { outcome?: string })?.outcome ?? "unknown";
      summary.outcomes[outcome] = (summary.outcomes[outcome] ?? 0) + 1;
    } catch (err) {
      summary.failures++;
      await rpc("pipeline_report_failure", {
        p_photo_id: claim.photo_id,
        p_attempt: claim.attempt,
        p_error_code: errorCode(err),
      });
    }
  }
  return summary;
}

function errorCode(err: unknown): string {
  if (err instanceof Error) {
    if (/download/i.test(err.message)) return "download_failed";
    if (/upload|replace/i.test(err.message)) return "upload_failed";
    if (/submit/i.test(err.message)) return "submit_failed";
  }
  return "worker_error";
}
