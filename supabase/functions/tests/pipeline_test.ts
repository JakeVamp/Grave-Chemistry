import { assert, assertEquals } from "jsr:@std/assert@1";
import { hammingDistance } from "../_shared/fingerprint.ts";
import { hasMetadataSegments } from "../_shared/image.ts";
import { type Claim, type PhotoStorage, processClaim, type Rpc, runPipelineBatch } from "../_shared/pipeline.ts";
import {
  providersFromEnv,
  UnconfiguredChildSafetyProvider,
  UnconfiguredModerationProvider,
} from "../_shared/providers.ts";
import { approve, FakeChildSafety, FakeModeration } from "./fake_providers.ts";
import { gradient, makeJpeg, rings, withExif } from "./fixtures.ts";

const PHOTO = "0b6f1c2e-3a4d-4e5f-8a6b-7c8d9e0f1a2b";
const PATH = `${PHOTO}/${"ab".repeat(16)}.jpg`;

class MemoryStorage implements PhotoStorage {
  objects = new Map<string, Uint8Array>();
  replaced: string[] = [];
  failDownload = false;
  constructor(initial?: Uint8Array) {
    if (initial) this.objects.set(`profile-photos/${PATH}`, initial);
  }
  download(bucket: string, path: string): Promise<Uint8Array> {
    if (this.failDownload) return Promise.reject(new Error("download failed"));
    const found = this.objects.get(`${bucket}/${path}`);
    return found ? Promise.resolve(found) : Promise.reject(new Error("download failed"));
  }
  replace(bucket: string, path: string, jpeg: Uint8Array): Promise<void> {
    this.objects.set(`${bucket}/${path}`, jpeg);
    this.replaced.push(path);
    return Promise.resolve();
  }
}

const claim: Claim = { photo_id: PHOTO, owner_id: "owner", bucket_id: "profile-photos", object_path: PATH, attempt: 1 };

Deno.test("clear photo: validated, normalised, fingerprinted, approved by providers", async () => {
  const storage = new MemoryStorage(withExif(makeJpeg(640, 480)));
  const result = await processClaim(claim, {
    storage,
    childSafety: new FakeChildSafety(["clear"]),
    moderation: new FakeModeration([approve]),
  });
  assertEquals(result.validation.ok, true);
  assertEquals(result.child_safety?.result, "clear");
  assertEquals(result.moderation?.result, "approve");
  const stored = storage.objects.get(`profile-photos/${PATH}`)!;
  assertEquals(result.validation.bytes, stored.length, "reported size matches the stored object");
  assert(!hasMetadataSegments(stored), "the stored object has no metadata");
  assertEquals(result.fingerprints?.sha256.length, 64);
});

Deno.test("exact duplicate: the same image gives the same fingerprint", async () => {
  const image = makeJpeg(640, 480, rings);
  const deps = () => ({ childSafety: new FakeChildSafety(["clear"]), moderation: new FakeModeration([approve]) });
  const a = await processClaim(claim, { storage: new MemoryStorage(image), ...deps() });
  const b = await processClaim(claim, { storage: new MemoryStorage(withExif(image)), ...deps() });
  assertEquals(a.fingerprints?.sha256, b.fingerprints?.sha256, "metadata differences don't hide a copy");
});

Deno.test("near duplicate: a resized copy has a close perceptual hash", async () => {
  const deps = () => ({ childSafety: new FakeChildSafety(["clear"]), moderation: new FakeModeration([approve]) });
  const a = await processClaim(claim, { storage: new MemoryStorage(makeJpeg(800, 600, gradient)), ...deps() });
  const b = await processClaim(claim, { storage: new MemoryStorage(makeJpeg(400, 300, gradient)), ...deps() });
  assert(a.fingerprints!.sha256 !== b.fingerprints!.sha256);
  assert(hammingDistance(a.fingerprints!.perceptual_hash, b.fingerprints!.perceptual_hash) <= 6);
});

Deno.test("moderation reject and manual review are passed through", async () => {
  const reject = await processClaim(claim, {
    storage: new MemoryStorage(makeJpeg(640, 480)),
    childSafety: new FakeChildSafety(["clear"]),
    moderation: new FakeModeration([{ result: "reject", categories: ["explicit_sexual"] }]),
  });
  assertEquals(reject.moderation, { result: "reject", categories: ["explicit_sexual"] });
  const manual = await processClaim(claim, {
    storage: new MemoryStorage(makeJpeg(640, 480)),
    childSafety: new FakeChildSafety(["clear"]),
    moderation: new FakeModeration([{ result: "manual_review", categories: ["text_solicitation"] }]),
  });
  assertEquals(manual.moderation?.result, "manual_review");
});

for (const serious of ["possible_match", "confirmed_known_hash_match"] as const) {
  Deno.test(`child safety ${serious}: reported, and never sent to another provider`, async () => {
    const moderation = new FakeModeration([approve]);
    const result = await processClaim(claim, {
      storage: new MemoryStorage(makeJpeg(640, 480)),
      childSafety: new FakeChildSafety([serious]),
      moderation,
    });
    assertEquals(result.child_safety?.result, serious);
    assertEquals(moderation.calls, 0);
  });
}

Deno.test("provider timeout and provider error become provider_error", async () => {
  const timeout = await processClaim(claim, {
    storage: new MemoryStorage(makeJpeg(640, 480)),
    childSafety: new FakeChildSafety(["hang"]),
    moderation: new FakeModeration(["hang"]),
    providerTimeoutMs: 20,
  });
  assertEquals(timeout.child_safety?.result, "provider_error");
  assertEquals(timeout.moderation?.result, "provider_error");

  const error = await processClaim(claim, {
    storage: new MemoryStorage(makeJpeg(640, 480)),
    childSafety: new FakeChildSafety(["throw"]),
    moderation: new FakeModeration(["throw"]),
  });
  assertEquals(error.child_safety?.result, "provider_error");
  assertEquals(error.moderation?.result, "provider_error");
});

Deno.test("malformed uploads are rejected before providers see them", async () => {
  const childSafety = new FakeChildSafety(["clear"]);
  const storage = new MemoryStorage(new Uint8Array([0xff, 0xd8, 0xff, 0x00, 0x01]));
  const result = await processClaim(claim, { storage, childSafety, moderation: new FakeModeration([approve]) });
  assertEquals(result, { validation: { ok: false, error: "malformed" } });
  assertEquals(childSafety.calls, 0);
  assertEquals(storage.replaced.length, 0);
});

Deno.test("objects outside the reserved path are refused without downloading", async () => {
  const storage = new MemoryStorage(makeJpeg(640, 480));
  storage.failDownload = true;
  for (const bad of [
    { ...claim, bucket_id: "verification-media" },
    { ...claim, object_path: `${PHOTO}/selfie.jpg` },
    { ...claim, photo_id: "11111111-1111-4111-8111-111111111111" },
  ]) {
    const result = await processClaim(bad, {
      storage,
      childSafety: new FakeChildSafety(["clear"]),
      moderation: new FakeModeration([approve]),
    });
    assertEquals(result, { validation: { ok: false, error: "wrong_path" } });
  }
});

Deno.test("without configured providers every photo needs a human", async () => {
  const result = await processClaim(claim, {
    storage: new MemoryStorage(makeJpeg(640, 480)),
    childSafety: new UnconfiguredChildSafetyProvider(),
    moderation: new UnconfiguredModerationProvider(),
  });
  assertEquals(result.child_safety?.result, "manual_review_required");
  assertEquals(result.moderation?.result, "manual_review");
});

Deno.test("an unknown provider name is a configuration error", () => {
  let threw = false;
  try {
    providersFromEnv((key) => key === "CHILD_SAFETY_PROVIDER" ? "made_up" : undefined);
  } catch {
    threw = true;
  }
  assert(threw);
});

function fakeRpc(claims: Claim[]) {
  const calls: { fn: string; params?: Record<string, unknown> }[] = [];
  const rpc: Rpc = (fn, params) => {
    calls.push({ fn, params });
    if (fn === "pipeline_claim_photos") return Promise.resolve({ data: claims, error: null });
    if (fn === "pipeline_submit_result") return Promise.resolve({ data: { outcome: "submitted" }, error: null });
    return Promise.resolve({ data: { outcome: "retry_scheduled" }, error: null });
  };
  return { rpc, calls };
}

Deno.test("retry success: a provider error is submitted, the next run succeeds", async () => {
  const storage = new MemoryStorage(makeJpeg(640, 480));
  const childSafety = new FakeChildSafety(["throw", "clear"]);
  const moderation = new FakeModeration([approve]);

  const first = fakeRpc([claim]);
  await runPipelineBatch(first.rpc, { storage, childSafety, moderation });
  const firstResult = first.calls.find((c) => c.fn === "pipeline_submit_result")!.params!.p_result as { child_safety: { result: string } };
  assertEquals(firstResult.child_safety.result, "provider_error");

  const second = fakeRpc([{ ...claim, attempt: 2 }]);
  await runPipelineBatch(second.rpc, { storage, childSafety, moderation });
  const secondCall = second.calls.find((c) => c.fn === "pipeline_submit_result")!;
  assertEquals((secondCall.params!.p_result as { child_safety: { result: string } }).child_safety.result, "clear");
  assertEquals(secondCall.params!.p_attempt, 2, "each attempt is identified so the database can ignore stale results");
});

Deno.test("worker failures are reported, not swallowed", async () => {
  const storage = new MemoryStorage();
  storage.failDownload = true;
  const { rpc, calls } = fakeRpc([claim]);
  const summary = await runPipelineBatch(rpc, {
    storage,
    childSafety: new FakeChildSafety(["clear"]),
    moderation: new FakeModeration([approve]),
  });
  assertEquals(summary.failures, 1);
  const report = calls.find((c) => c.fn === "pipeline_report_failure")!;
  assertEquals(report.params!.p_error_code, "download_failed");
  assertEquals(calls.filter((c) => c.fn === "pipeline_submit_result").length, 0);
});
