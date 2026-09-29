// Content fingerprints for duplicate detection. These describe pixels, not
// people: no face detection, embeddings or biometric templates.

import type { DecodedImage } from "./image.ts";

/** SHA-256 of the normalised JPEG bytes, as 64 hex characters. */
export async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new Uint8Array(bytes));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * 64-bit difference hash (dHash): shrink to 9×8 greyscale by area
 * averaging, then set a bit when a pixel is brighter than its right-hand
 * neighbour. Robust to resizing and recompression; see
 * docs/security/photo-pipeline.md for limitations.
 */
export function differenceHash(image: DecodedImage): string {
  const cols = 9;
  const rows = 8;
  const grey = new Float64Array(cols * rows);
  const { width, height, data } = image;

  for (let r = 0; r < rows; r++) {
    const y0 = Math.floor((r * height) / rows);
    const y1 = Math.max(y0 + 1, Math.floor(((r + 1) * height) / rows));
    for (let c = 0; c < cols; c++) {
      const x0 = Math.floor((c * width) / cols);
      const x1 = Math.max(x0 + 1, Math.floor(((c + 1) * width) / cols));
      let sum = 0;
      let count = 0;
      for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) {
          const i = (y * width + x) * 4;
          sum += 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2];
          count++;
        }
      }
      grey[r * cols + c] = sum / count;
    }
  }

  let bits = "";
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols - 1; c++) {
      bits += grey[r * cols + c] > grey[r * cols + c + 1] ? "1" : "0";
    }
  }
  return bits;
}

export function hammingDistance(a: string, b: string): number {
  if (a.length !== b.length) throw new Error("hash length mismatch");
  let distance = 0;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) distance++;
  return distance;
}
