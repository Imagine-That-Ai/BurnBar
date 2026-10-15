import { createHash } from "node:crypto";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import icons from "../src/data/afar-icons.json";
import receipt from "../brand/afar/import-receipt.json";
import provenance from "../brand/afar/afar-logo-master.provenance.json";

const ROOT = join(__dirname, "..");
const sha256 = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");
const publicFile = (path: string) => readFileSync(join(ROOT, "public", path));

/** Width and height from a PNG IHDR, a WebP VP8/VP8L/VP8X header or an AVIF ispe box. */
function dimensions(bytes: Buffer): [number, number] {
  if (bytes.subarray(1, 4).toString() === "PNG")
    return [bytes.readUInt32BE(16), bytes.readUInt32BE(20)];
  if (bytes.subarray(8, 12).toString() === "WEBP") {
    const chunk = bytes.subarray(12, 16).toString();
    if (chunk === "VP8X") return [bytes.readUIntLE(24, 3) + 1, bytes.readUIntLE(27, 3) + 1];
    if (chunk === "VP8L") {
      const bits = bytes.readUInt32LE(21);
      return [(bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1];
    }
    return [bytes.readUInt16LE(26) & 0x3fff, bytes.readUInt16LE(28) & 0x3fff];
  }
  const ispe = bytes.indexOf("ispe");
  if (ispe > 0) return [bytes.readUInt32BE(ispe + 8), bytes.readUInt32BE(ispe + 12)];
  throw new Error("unrecognised image format");
}

describe("Afar official artwork import", () => {
  it("keeps every imported original byte-identical to the pinned source commit", () => {
    expect(receipt.source.commit).toMatch(/^[0-9a-f]{40}$/);
    for (const file of receipt.files) {
      const bytes = readFileSync(join(ROOT, "brand/afar", file.path));
      expect(bytes.length, file.path).toBe(file.bytes);
      expect(sha256(bytes), file.path).toBe(file.sha256);
    }
  });

  it("keeps the provenance chain from master SVG to reviewed raster intact", () => {
    const master = receipt.files.find((f) => f.path === "afar-logo-master.svg");
    const raster = receipt.files.find((f) => f.path === "afar-logo-1024.png");
    expect(provenance.sourceSHA256).toBe(master?.sha256);
    expect(provenance.derivatives[0]?.sourceSHA256).toBe(master?.sha256);
    expect(provenance.derivatives[0]?.sha256).toBe(raster?.sha256);
    expect(icons.source.masterSHA256).toBe(master?.sha256);
    expect(icons.source.rasterSHA256).toBe(raster?.sha256);
  });
});

describe("Afar served rasters", () => {
  const served = [...icons.formats.avif, ...icons.formats.webp, icons.fallback];

  it("serves exactly the files the manifest lists, each matching its hash, size and dimensions", () => {
    for (const file of served) {
      const bytes = publicFile(file.path);
      expect(bytes.length, file.path).toBe(file.bytes);
      expect(sha256(bytes), file.path).toBe(file.sha256);
      expect(dimensions(bytes), file.path).toEqual([file.width, file.width]);
    }
    const onDisk = readdirSync(join(ROOT, "public/afar")).sort();
    expect(onDisk).toEqual(served.map((f) => f.path.replace("/afar/", "")).sort());
  });

  it("offers matching AVIF and WebP widths that cover 1x-3x of every rendered size", () => {
    const widths = icons.formats.avif.map((f) => f.width);
    expect(icons.formats.webp.map((f) => f.width)).toEqual(widths);
    // Largest rendered size on the page is the 120 px hero tile.
    expect(Math.max(...widths)).toBeGreaterThanOrEqual(120 * 3);
    expect(Math.min(...widths)).toBeLessThanOrEqual(16 * 2);
  });

  it("never ships the 5.5 MB master and keeps every served raster small", () => {
    for (const file of served) expect(file.bytes, file.path).toBeLessThan(64 * 1024);
    expect(readdirSync(join(ROOT, "public/afar")).some((name) => name.endsWith(".svg"))).toBe(
      false
    );
  });

  it("describes the artwork in its alt text", () => {
    expect(icons.alt).toMatch(/^Afar app icon: /);
    expect(icons.alt.length).toBeGreaterThan(40);
  });
});
