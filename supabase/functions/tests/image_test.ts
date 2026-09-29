import { assert, assertEquals } from "jsr:@std/assert@1";
import { hasMetadataSegments, normalizeJpeg, validateJpeg } from "../_shared/image.ts";
import { contains, gradient, makeJpeg, withExif } from "./fixtures.ts";

Deno.test("accepts a normal JPEG", () => {
  const result = validateJpeg(makeJpeg(400, 300));
  assert(result.ok);
  if (result.ok) {
    assertEquals(result.image.width, 400);
    assertEquals(result.image.height, 300);
  }
});

Deno.test("rejects empty, oversized and non-JPEG files", () => {
  assertEquals(validateJpeg(new Uint8Array()), { ok: false, error: "empty" });
  assertEquals(
    validateJpeg(makeJpeg(400, 300), { maxBytes: 100, minDimension: 200, maxDimension: 4096 }),
    { ok: false, error: "too_large" },
  );
  const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 0]);
  assertEquals(validateJpeg(png), { ok: false, error: "not_jpeg" });
});

Deno.test("rejects truncated and malformed JPEGs", () => {
  const good = makeJpeg(400, 300);
  assertEquals(validateJpeg(good.subarray(0, Math.floor(good.length / 2))), { ok: false, error: "malformed" });
  const garbage = new Uint8Array(500).fill(0x41);
  garbage.set([0xff, 0xd8, 0xff]);
  assertEquals(validateJpeg(garbage), { ok: false, error: "malformed" });
});

Deno.test("rejects images that are too small or too large", () => {
  assertEquals(validateJpeg(makeJpeg(100, 100)), { ok: false, error: "too_small" });
  assertEquals(
    validateJpeg(makeJpeg(400, 400), { maxBytes: 5_000_000, minDimension: 200, maxDimension: 300 }),
    { ok: false, error: "dimensions_too_large" },
  );
});

Deno.test("normalisation removes EXIF, GPS and camera metadata", () => {
  const tagged = withExif(makeJpeg(400, 300), 1, "SpyPhone");
  assert(hasMetadataSegments(tagged));
  assert(contains(tagged, "SpyPhone"));

  const validated = validateJpeg(tagged);
  assert(validated.ok);
  if (!validated.ok) return;
  const normalized = normalizeJpeg(validated);
  assert(!hasMetadataSegments(normalized.jpeg));
  assert(!contains(normalized.jpeg, "Exif"));
  assert(!contains(normalized.jpeg, "SpyPhone"));
  assertEquals([normalized.image.width, normalized.image.height], [400, 300]);
});

Deno.test("normalisation applies EXIF orientation", () => {
  const rotated = withExif(makeJpeg(400, 300, gradient), 6);
  const validated = validateJpeg(rotated);
  assert(validated.ok);
  if (!validated.ok) return;
  assertEquals(validated.orientation, 6);
  const normalized = normalizeJpeg(validated);
  assertEquals([normalized.image.width, normalized.image.height], [300, 400]);
  const recheck = validateJpeg(normalized.jpeg);
  assert(recheck.ok && recheck.orientation === 1);
});
