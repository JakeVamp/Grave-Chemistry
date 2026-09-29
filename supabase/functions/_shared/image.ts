// JPEG validation and normalisation for profile photos.
//
// Runs in the Edge Function (Deno). Uses jpeg-js, a pure-JavaScript JPEG
// decoder/encoder, so no native image library is needed. Re-encoding
// through jpeg-js writes only image data (JFIF), so EXIF (GPS, device,
// camera), embedded thumbnails, XMP and other metadata are dropped.

import jpeg from "npm:jpeg-js@0.4.4";

export interface ImageLimits {
  maxBytes: number;
  minDimension: number;
  maxDimension: number;
}

// The bucket allows 5 MB. Clients already downscale to 1600px; the cap
// here keeps decoding within Edge Function memory limits.
export const DEFAULT_LIMITS: ImageLimits = {
  maxBytes: 5 * 1024 * 1024,
  minDimension: 200,
  maxDimension: 4096,
};

export type ValidationError =
  | "empty"
  | "too_large"
  | "not_jpeg"
  | "malformed"
  | "undecodable"
  | "too_small"
  | "dimensions_too_large";

export interface DecodedImage {
  width: number;
  height: number;
  /** RGBA, 4 bytes per pixel. */
  data: Uint8Array;
}

export type ValidationResult =
  | { ok: true; image: DecodedImage; orientation: number }
  | { ok: false; error: ValidationError };

interface JpegStructure {
  width: number;
  height: number;
  orientation: number;
}

const SOF_MARKERS = new Set([
  0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
]);

/** Walks the marker segments; returns null for anything malformed. */
export function parseJpegStructure(bytes: Uint8Array): JpegStructure | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;

  let i = 2;
  let width = 0;
  let height = 0;
  let orientation = 1;
  let sawScan = false;

  while (i < bytes.length) {
    if (bytes[i] !== 0xff) return null;
    while (i < bytes.length && bytes[i] === 0xff) i++; // fill bytes
    if (i >= bytes.length) return null;
    const marker = bytes[i];
    i++;
    if (marker === 0xd9) break; // EOI before scan
    if ((marker >= 0xd0 && marker <= 0xd7) || marker === 0x01) continue;
    if (i + 2 > bytes.length) return null;
    const length = (bytes[i] << 8) | bytes[i + 1];
    if (length < 2 || i + length > bytes.length) return null;

    if (SOF_MARKERS.has(marker)) {
      if (length < 7) return null;
      height = (bytes[i + 3] << 8) | bytes[i + 4];
      width = (bytes[i + 5] << 8) | bytes[i + 6];
    } else if (marker === 0xe1) {
      orientation = readExifOrientation(bytes, i + 2, length - 2) ?? orientation;
    } else if (marker === 0xda) {
      sawScan = true;
      break;
    }
    i += length;
  }

  if (!sawScan || width === 0 || height === 0) return null;
  // The entropy-coded data must end with an EOI marker (allow trailing
  // padding some encoders add).
  let end = bytes.length - 1;
  while (end > 0 && bytes[end] === 0x00) end--;
  if (bytes[end - 1] !== 0xff || bytes[end] !== 0xd9) return null;
  return { width, height, orientation };
}

function readExifOrientation(bytes: Uint8Array, start: number, length: number): number | null {
  // "Exif\0\0" then a TIFF header.
  const exifHeader = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
  if (length < 14 || exifHeader.some((b, k) => bytes[start + k] !== b)) return null;
  const tiff = start + 6;
  const little = bytes[tiff] === 0x49 && bytes[tiff + 1] === 0x49;
  const big = bytes[tiff] === 0x4d && bytes[tiff + 1] === 0x4d;
  if (!little && !big) return null;
  const u16 = (o: number) => little ? bytes[o] | (bytes[o + 1] << 8) : (bytes[o] << 8) | bytes[o + 1];
  const u32 = (o: number) =>
    little
      ? (bytes[o] | (bytes[o + 1] << 8) | (bytes[o + 2] << 16) | (bytes[o + 3] << 24)) >>> 0
      : ((bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3]) >>> 0;
  const limit = start + length;
  const ifd = tiff + u32(tiff + 4);
  if (ifd + 2 > limit) return null;
  const count = u16(ifd);
  for (let n = 0; n < count; n++) {
    const entry = ifd + 2 + n * 12;
    if (entry + 12 > limit) return null;
    if (u16(entry) === 0x0112) {
      const value = u16(entry + 8);
      return value >= 1 && value <= 8 ? value : null;
    }
  }
  return null;
}

/** Checks size, signature, structure, dimensions and decodability. */
export function validateJpeg(bytes: Uint8Array, limits: ImageLimits = DEFAULT_LIMITS): ValidationResult {
  if (bytes.length === 0) return { ok: false, error: "empty" };
  if (bytes.length > limits.maxBytes) return { ok: false, error: "too_large" };
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) {
    return { ok: false, error: "not_jpeg" };
  }

  const structure = parseJpegStructure(bytes);
  if (!structure) return { ok: false, error: "malformed" };

  // Check the declared size before decoding, to avoid huge allocations.
  const { width, height } = structure;
  if (Math.max(width, height) > limits.maxDimension) {
    return { ok: false, error: "dimensions_too_large" };
  }
  if (Math.min(width, height) < limits.minDimension) {
    return { ok: false, error: "too_small" };
  }

  try {
    const decoded = jpeg.decode(bytes, {
      useTArray: true,
      formatAsRGBA: true,
      maxResolutionInMP: (limits.maxDimension * limits.maxDimension) / 1_000_000,
      maxMemoryUsageInMB: 512,
    });
    if (decoded.width !== width || decoded.height !== height) {
      return { ok: false, error: "malformed" };
    }
    return {
      ok: true,
      image: { width: decoded.width, height: decoded.height, data: decoded.data },
      orientation: structure.orientation,
    };
  } catch {
    return { ok: false, error: "undecodable" };
  }
}

/** Rotates/flips pixels so the image displays upright without EXIF. */
export function applyOrientation(image: DecodedImage, orientation: number): DecodedImage {
  if (orientation <= 1 || orientation > 8) return image;
  const { width: w, height: h, data } = image;
  const swap = orientation >= 5;
  const outW = swap ? h : w;
  const outH = swap ? w : h;
  const out = new Uint8Array(outW * outH * 4);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let nx: number;
      let ny: number;
      switch (orientation) {
        case 2: nx = w - 1 - x; ny = y; break;
        case 3: nx = w - 1 - x; ny = h - 1 - y; break;
        case 4: nx = x; ny = h - 1 - y; break;
        case 5: nx = y; ny = x; break;
        case 6: nx = h - 1 - y; ny = x; break;
        case 7: nx = h - 1 - y; ny = w - 1 - x; break;
        default: nx = y; ny = w - 1 - x; break; // 8
      }
      const src = (y * w + x) * 4;
      const dst = (ny * outW + nx) * 4;
      out[dst] = data[src];
      out[dst + 1] = data[src + 1];
      out[dst + 2] = data[src + 2];
      out[dst + 3] = 255;
    }
  }
  return { width: outW, height: outH, data: out };
}

export interface NormalizedImage {
  jpeg: Uint8Array;
  image: DecodedImage;
}

/**
 * Upright, metadata-free re-encode at high quality. The only changes are
 * orientation and removal of metadata; size is kept.
 */
export function normalizeJpeg(result: { image: DecodedImage; orientation: number }, quality = 90): NormalizedImage {
  const upright = applyOrientation(result.image, result.orientation);
  const encoded = jpeg.encode(
    { data: upright.data, width: upright.width, height: upright.height },
    quality,
  );
  return { jpeg: new Uint8Array(encoded.data), image: upright };
}

/** True if any APP1 (EXIF/XMP) segment is present. */
export function hasMetadataSegments(bytes: Uint8Array): boolean {
  let i = 2;
  while (i + 4 < bytes.length && bytes[i] === 0xff) {
    const marker = bytes[i + 1];
    if (marker === 0xda) return false;
    const length = (bytes[i + 2] << 8) | bytes[i + 3];
    if (marker === 0xe1 || (marker >= 0xe2 && marker <= 0xef && marker !== 0xee)) return true;
    i += 2 + length;
  }
  return false;
}
