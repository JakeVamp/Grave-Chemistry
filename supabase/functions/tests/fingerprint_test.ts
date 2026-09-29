import { assert, assertEquals, assertNotEquals } from "jsr:@std/assert@1";
import { differenceHash, hammingDistance, sha256Hex } from "../_shared/fingerprint.ts";
import { validateJpeg } from "../_shared/image.ts";
import { gradient, makeJpeg, mirror, recompress, rings } from "./fixtures.ts";

// Same threshold as private.security_settings.near_duplicate_image_distance.
const NEAR_DUPLICATE_DISTANCE = 6;

function hashOf(bytes: Uint8Array): string {
  const result = validateJpeg(bytes);
  if (!result.ok) throw new Error(result.error);
  return differenceHash(result.image);
}

Deno.test("SHA-256 is stable and content-specific", async () => {
  const a = makeJpeg(400, 300, gradient);
  assertEquals(await sha256Hex(a), await sha256Hex(a.slice()));
  assertNotEquals(await sha256Hex(a), await sha256Hex(makeJpeg(400, 300, rings)));
  assertEquals((await sha256Hex(a)).length, 64);
});

Deno.test("perceptual hash is 64 bits", () => {
  const hash = hashOf(makeJpeg(400, 300));
  assertEquals(hash.length, 64);
  assert(/^[01]+$/.test(hash));
});

Deno.test("resized copies are near duplicates", () => {
  const original = hashOf(makeJpeg(800, 600, gradient));
  const resized = hashOf(makeJpeg(400, 300, gradient));
  assert(hammingDistance(original, resized) <= NEAR_DUPLICATE_DISTANCE);
});

Deno.test("recompressed copies are near duplicates", () => {
  const source = makeJpeg(600, 450, rings, 95);
  assert(hammingDistance(hashOf(source), hashOf(recompress(source, 30))) <= NEAR_DUPLICATE_DISTANCE);
});

Deno.test("lightly cropped copies are near duplicates", () => {
  const original = hashOf(makeJpeg(600, 450, gradient));
  const cropped = hashOf(makeJpeg(600, 450, gradient, 90, 0.02));
  assert(hammingDistance(original, cropped) <= NEAR_DUPLICATE_DISTANCE);
});

Deno.test("different images are not near duplicates", () => {
  assert(hammingDistance(hashOf(makeJpeg(600, 450, gradient)), hashOf(makeJpeg(600, 450, rings))) > NEAR_DUPLICATE_DISTANCE);
});

Deno.test("documented limitation: mirrored copies are not detected", () => {
  const source = makeJpeg(600, 450, rings);
  assert(hammingDistance(hashOf(source), hashOf(mirror(source))) > NEAR_DUPLICATE_DISTANCE);
});
