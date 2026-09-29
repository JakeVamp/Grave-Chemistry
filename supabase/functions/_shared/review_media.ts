// Short-lived signed URLs for the moderator photo-review tool.
//
// Order matters: the photo locations come from
// moderator_photo_review_context(), called with the CALLER's own JWT, so the
// database re-checks the moderator role and MFA (aal2), refuses anything
// under child-safety review and audits the access. Only after that succeeds
// does the service-role signer create URLs. Nothing here logs URLs or paths.

export const SIGNED_URL_SECONDS = 60;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const OBJECT_PATH = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\/[0-9a-f]{32}\.jpg$/;

export interface ContextResponse {
  data: unknown;
  error: { code?: string; message?: string } | null;
}

export interface ReviewMediaDeps {
  /** moderator_photo_review_context(photo) as the calling user. */
  fetchContext(photoId: string): PromiseLike<ContextResponse>;
  /** Service-role signer. Returns null on failure. */
  signUrl(bucketId: string, path: string, expiresIn: number): Promise<string | null>;
}

export type VerificationAvailability = "available" | "none" | "unavailable";

export type ReviewMediaResult =
  | {
    status: 200;
    body: {
      profile_photo_url: string;
      verification_photo_url: string | null;
      verification: VerificationAvailability;
      expires_in: number;
    };
  }
  | { status: 400 | 403 | 404 | 502; body: { error: string } };

interface Location {
  bucket_id: string;
  object_path: string;
}

function location(value: unknown, bucket: string): Location | null {
  if (typeof value !== "object" || value === null) return null;
  const { bucket_id, object_path } = value as Record<string, unknown>;
  if (bucket_id !== bucket || typeof object_path !== "string" || !OBJECT_PATH.test(object_path)) {
    return null;
  }
  return { bucket_id, object_path };
}

export async function issueReviewMedia(photoId: unknown, deps: ReviewMediaDeps): Promise<ReviewMediaResult> {
  if (typeof photoId !== "string" || !UUID.test(photoId)) {
    return { status: 400, body: { error: "invalid_request" } };
  }

  let context: ContextResponse;
  try {
    context = await deps.fetchContext(photoId);
  } catch {
    return { status: 502, body: { error: "unavailable" } };
  }
  if (context.error) {
    // 42501: not a moderator, no MFA, own photo or child-safety restricted.
    return context.error.code === "42501"
      ? { status: 403, body: { error: "not_authorized" } }
      : { status: 404, body: { error: "unavailable" } };
  }

  const data = (context.data ?? {}) as Record<string, unknown>;
  const profile = location(data.profile_photo, "profile-photos");
  if (!profile) return { status: 502, body: { error: "unavailable" } };
  const hasVerification = data.verification_photo !== null && data.verification_photo !== undefined;
  const verification = hasVerification ? location(data.verification_photo, "verification-media") : null;
  if (hasVerification && !verification) return { status: 502, body: { error: "unavailable" } };

  const profileUrl = await safeSign(deps, profile);
  if (!profileUrl) return { status: 502, body: { error: "media_unavailable" } };
  const verificationUrl = verification ? await safeSign(deps, verification) : null;

  return {
    status: 200,
    body: {
      profile_photo_url: profileUrl,
      verification_photo_url: verificationUrl,
      verification: !verification ? "none" : verificationUrl ? "available" : "unavailable",
      expires_in: SIGNED_URL_SECONDS,
    },
  };
}

async function safeSign(deps: ReviewMediaDeps, target: Location): Promise<string | null> {
  try {
    return await deps.signUrl(target.bucket_id, target.object_path, SIGNED_URL_SECONDS);
  } catch {
    return null;
  }
}
