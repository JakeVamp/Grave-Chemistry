import { assertEquals } from "jsr:@std/assert@1";
import { type ContextResponse, issueReviewMedia, type ReviewMediaDeps } from "../_shared/review_media.ts";

const PHOTO = "0b6f3c4e-1d2a-4b5c-8d9e-0f1a2b3c4d5e";
const PROFILE_PATH = `${PHOTO}/${"a".repeat(32)}.jpg`;
const SELFIE_PATH = `dddddddd-0000-0000-0000-000000000001/${"b".repeat(32)}.jpg`;

function context(verification: unknown = { bucket_id: "verification-media", object_path: SELFIE_PATH }): ContextResponse {
  return {
    data: { profile_photo: { bucket_id: "profile-photos", object_path: PROFILE_PATH }, verification_photo: verification },
    error: null,
  };
}

function deps(response: ContextResponse, fail: string[] = []) {
  const signed: string[] = [];
  const contexts: string[] = [];
  const d: ReviewMediaDeps = {
    fetchContext(photoId) {
      contexts.push(photoId);
      return Promise.resolve(response);
    },
    signUrl(bucket, path, expiresIn) {
      signed.push(`${bucket}:${expiresIn}`);
      return Promise.resolve(fail.includes(bucket) ? null : `https://signed.example/${bucket}?token=x`);
    },
  };
  return { d, signed, contexts };
}

Deno.test("signed URLs are issued only after the database accepts the moderator", async () => {
  const { d, signed } = deps(context());
  const result = await issueReviewMedia(PHOTO, d);
  assertEquals(result.status, 200);
  assertEquals(signed, ["profile-photos:60", "verification-media:60"], "short-lived URLs for both photos");
  if (result.status === 200) {
    assertEquals(result.body.verification, "available");
    assertEquals(result.body.expires_in, 60);
  }
});

Deno.test("no moderator role or no MFA: nothing is signed", async () => {
  const { d, signed } = deps({ data: null, error: { code: "42501", message: "not_authorized" } });
  const result = await issueReviewMedia(PHOTO, d);
  assertEquals(result, { status: 403, body: { error: "not_authorized" } });
  assertEquals(signed, []);
});

Deno.test("child-safety restricted photos: nothing is signed", async () => {
  const { d, signed } = deps({ data: null, error: { code: "42501", message: "restricted to child-safety reviewers" } });
  assertEquals((await issueReviewMedia(PHOTO, d)).status, 403);
  assertEquals(signed, []);
});

Deno.test("an unknown or removed photo: nothing is signed", async () => {
  const { d, signed } = deps({ data: null, error: { code: "P0001", message: "photo not found" } });
  assertEquals(await issueReviewMedia(PHOTO, d), { status: 404, body: { error: "unavailable" } });
  assertEquals(signed, []);
});

Deno.test("invalid photo ids never reach the database", async () => {
  const { d, contexts, signed } = deps(context());
  for (const id of [undefined, 42, "not-a-uuid", `${PHOTO}' or 1=1`]) {
    assertEquals((await issueReviewMedia(id, d)).status, 400);
  }
  assertEquals(contexts, []);
  assertEquals(signed, []);
});

Deno.test("only the two expected buckets are ever signed (fail closed)", async () => {
  for (
    const bad of [
      { bucket_id: "child-safety-evidence", object_path: SELFIE_PATH },
      { bucket_id: "verification-media", object_path: "../../etc/passwd" },
      "verification-media",
    ]
  ) {
    const { d, signed } = deps(context(bad));
    assertEquals(await issueReviewMedia(PHOTO, d), { status: 502, body: { error: "unavailable" } });
    assertEquals(signed, []);
  }
  const { d, signed } = deps({
    data: { profile_photo: { bucket_id: "child-safety-evidence", object_path: PROFILE_PATH }, verification_photo: null },
    error: null,
  });
  assertEquals((await issueReviewMedia(PHOTO, d)).status, 502);
  assertEquals(signed, []);
});

Deno.test("if the profile photo can't be signed, no URL is returned at all", async () => {
  const { d } = deps(context(), ["profile-photos"]);
  assertEquals(await issueReviewMedia(PHOTO, d), { status: 502, body: { error: "media_unavailable" } });
});

Deno.test("a verification photo that can't be signed is reported, not skipped silently", async () => {
  const { d } = deps(context(), ["verification-media"]);
  const result = await issueReviewMedia(PHOTO, d);
  assertEquals(result.status, 200);
  if (result.status === 200) {
    assertEquals(result.body.verification_photo_url, null);
    assertEquals(result.body.verification, "unavailable");
  }
});

Deno.test("no approved verification photo on file", async () => {
  const { d, signed } = deps(context(null));
  const result = await issueReviewMedia(PHOTO, d);
  assertEquals(signed, ["profile-photos:60"]);
  if (result.status === 200) assertEquals(result.body.verification, "none");
});

Deno.test("a failing database call fails closed", async () => {
  const d: ReviewMediaDeps = {
    fetchContext: () => Promise.reject(new Error("network")),
    signUrl: () => Promise.reject(new Error("must not be called")),
  };
  assertEquals((await issueReviewMedia(PHOTO, d)).status, 502);
});
