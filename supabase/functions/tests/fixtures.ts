// Harmless synthetic test images: colour gradients and shapes generated in
// memory. No real photos.

import jpeg from "npm:jpeg-js@0.4.4";

export type Pattern = (u: number, v: number) => [number, number, number];

export const gradient: Pattern = (u, v) => [
  255 * u,
  255 * v,
  128 + 100 * Math.sin(6 * u + 3 * v),
];

export const rings: Pattern = (u, v) => {
  const d = Math.hypot(u - 0.3, v - 0.6);
  const s = 127 + 127 * Math.cos(d * 25);
  return [s, 255 - s, 60 + 150 * v];
};

export function renderRgba(width: number, height: number, pattern: Pattern, crop = 0): Uint8Array {
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const u = crop + (x / (width - 1)) * (1 - 2 * crop);
      const v = crop + (y / (height - 1)) * (1 - 2 * crop);
      const [r, g, b] = pattern(u, v);
      const i = (y * width + x) * 4;
      data[i] = r;
      data[i + 1] = g;
      data[i + 2] = b;
      data[i + 3] = 255;
    }
  }
  return data;
}

export function makeJpeg(width: number, height: number, pattern: Pattern = gradient, quality = 90, crop = 0): Uint8Array {
  const encoded = jpeg.encode({ data: renderRgba(width, height, pattern, crop), width, height }, quality);
  return new Uint8Array(encoded.data);
}

export function recompress(bytes: Uint8Array, quality: number): Uint8Array {
  const decoded = jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true });
  return new Uint8Array(jpeg.encode({ data: decoded.data, width: decoded.width, height: decoded.height }, quality).data);
}

export function mirror(bytes: Uint8Array): Uint8Array {
  const d = jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true });
  const out = new Uint8Array(d.data.length);
  for (let y = 0; y < d.height; y++) {
    for (let x = 0; x < d.width; x++) {
      const s = (y * d.width + x) * 4;
      const t = (y * d.width + (d.width - 1 - x)) * 4;
      out.set(d.data.subarray(s, s + 4), t);
    }
  }
  return new Uint8Array(jpeg.encode({ data: out, width: d.width, height: d.height }, 90).data);
}

/**
 * Inserts an EXIF APP1 segment with an orientation, a camera make and a
 * GPS sub-directory (all fake), to prove the pipeline strips them.
 */
export function withExif(bytes: Uint8Array, orientation = 1, make = "SpyPhone"): Uint8Array {
  const makeBytes = new TextEncoder().encode(make + "\0");
  const entries = 3;
  const ifd0Size = 2 + entries * 12 + 4;
  const makeOffset = 8 + ifd0Size;
  const gpsOffset = makeOffset + makeBytes.length;
  const gpsSize = 2 + 12 + 4;
  const tiff = new Uint8Array(gpsOffset + gpsSize);
  const view = new DataView(tiff.buffer);
  tiff.set([0x49, 0x49, 0x2a, 0x00]); // little endian
  view.setUint32(4, 8, true);
  let p = 8;
  view.setUint16(p, entries, true);
  p += 2;
  const entry = (tag: number, type: number, count: number, value: number) => {
    view.setUint16(p, tag, true);
    view.setUint16(p + 2, type, true);
    view.setUint32(p + 4, count, true);
    if (type === 3 && count === 1) view.setUint16(p + 8, value, true);
    else view.setUint32(p + 8, value, true);
    p += 12;
  };
  entry(0x010f, 2, makeBytes.length, makeOffset); // Make
  entry(0x0112, 3, 1, orientation); // Orientation
  entry(0x8825, 4, 1, gpsOffset); // GPSInfo
  view.setUint32(p, 0, true);
  tiff.set(makeBytes, makeOffset);
  p = gpsOffset;
  view.setUint16(p, 1, true);
  view.setUint16(p + 2, 0x0001, true); // GPSLatitudeRef
  view.setUint16(p + 4, 2, true);
  view.setUint32(p + 6, 2, true);
  tiff.set([0x4e, 0x00], p + 10); // "N"
  view.setUint32(p + 14, 0, true);

  const header = new TextEncoder().encode("Exif\0\0");
  const payload = new Uint8Array(header.length + tiff.length);
  payload.set(header);
  payload.set(tiff, header.length);
  const segment = new Uint8Array(4 + payload.length);
  segment.set([0xff, 0xe1, ((payload.length + 2) >> 8) & 0xff, (payload.length + 2) & 0xff]);
  segment.set(payload, 4);

  const out = new Uint8Array(bytes.length + segment.length);
  out.set(bytes.subarray(0, 2));
  out.set(segment, 2);
  out.set(bytes.subarray(2), 2 + segment.length);
  return out;
}

export function contains(haystack: Uint8Array, text: string): boolean {
  const needle = new TextEncoder().encode(text);
  outer: for (let i = 0; i + needle.length <= haystack.length; i++) {
    for (let j = 0; j < needle.length; j++) if (haystack[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
}
