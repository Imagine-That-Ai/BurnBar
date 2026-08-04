export type GltfPoint = {
  x: number;
  y: number;
  z: number;
};

export type ParsedGlb = {
  asset: Record<string, unknown>;
  nodes: string[];
  animations: string[];
  points: GltfPoint[];
};

type GltfAccessor = {
  bufferView?: number;
  byteOffset?: number;
  componentType: number;
  count: number;
  type: string;
  min?: number[];
  max?: number[];
};

type GltfBufferView = {
  buffer?: number;
  byteOffset?: number;
  byteLength: number;
  byteStride?: number;
};

type GltfPrimitive = {
  attributes?: Record<string, number>;
};

type GltfMesh = {
  primitives?: GltfPrimitive[];
};

type GltfDocument = {
  asset?: Record<string, unknown>;
  nodes?: { name?: string }[];
  animations?: { name?: string }[];
  meshes?: GltfMesh[];
  accessors?: GltfAccessor[];
  bufferViews?: GltfBufferView[];
};

const GLB_MAGIC = 0x46546c67;
const GLB_JSON = 0x4e4f534a;
const GLB_BIN = 0x004e4942;
let activePetRuntimeStop: (() => void) | null = null;

function readU32(view: DataView, offset: number): number {
  return view.getUint32(offset, true);
}

function parseJsonChunk(bytes: Uint8Array): GltfDocument {
  const text = new TextDecoder().decode(bytes).replace(/\0+$/g, '').trim();
  return JSON.parse(text) as GltfDocument;
}

function extractPositions(doc: GltfDocument, bin: Uint8Array | null): GltfPoint[] {
  if (!doc.meshes || !doc.accessors) return [];
  const primitive = doc.meshes.flatMap((mesh) => mesh.primitives ?? []).find((p) => p.attributes?.POSITION !== undefined);
  const accessorIndex = primitive?.attributes?.POSITION;
  if (accessorIndex === undefined) return [];
  const accessor = doc.accessors[accessorIndex];
  if (!accessor || accessor.componentType !== 5126 || accessor.type !== 'VEC3' || accessor.bufferView === undefined) {
    if (accessor?.min && accessor.max) return boundingShellPoints(accessor.min, accessor.max);
    return [];
  }
  if (!bin || !doc.bufferViews) return [];
  const view = doc.bufferViews[accessor.bufferView];
  if (!view) return [];

  const stride = view.byteStride ?? 12;
  const baseOffset = (view.byteOffset ?? 0) + (accessor.byteOffset ?? 0);
  const data = new DataView(bin.buffer, bin.byteOffset, bin.byteLength);
  const raw: GltfPoint[] = [];
  const step = Math.max(1, Math.floor(accessor.count / 260));
  for (let i = 0; i < accessor.count; i += step) {
    const offset = baseOffset + i * stride;
    if (offset + 12 > bin.byteLength) break;
    raw.push({
      x: data.getFloat32(offset, true),
      y: data.getFloat32(offset + 4, true),
      z: data.getFloat32(offset + 8, true)
    });
  }
  return normalizePoints(raw);
}

function boundingShellPoints(min: number[], max: number[]): GltfPoint[] {
  const cx = ((min[0] ?? -1) + (max[0] ?? 1)) / 2;
  const cy = ((min[1] ?? -1) + (max[1] ?? 1)) / 2;
  const cz = ((min[2] ?? -1) + (max[2] ?? 1)) / 2;
  const sx = Math.max(0.001, (max[0] ?? 1) - (min[0] ?? -1));
  const sy = Math.max(0.001, (max[1] ?? 1) - (min[1] ?? -1));
  const sz = Math.max(0.001, (max[2] ?? 1) - (min[2] ?? -1));
  const points: GltfPoint[] = [];
  for (let ring = 0; ring < 7; ring += 1) {
    const v = -0.5 + ring / 6;
    const radius = Math.sqrt(Math.max(0.04, 0.25 - v * v * 0.55));
    for (let i = 0; i < 36; i += 1) {
      const theta = (i / 36) * Math.PI * 2;
      points.push({
        x: cx + Math.cos(theta) * radius * sx,
        y: cy + v * sy,
        z: cz + Math.sin(theta) * radius * sz
      });
    }
  }
  return normalizePoints(points);
}

function normalizePoints(points: GltfPoint[]): GltfPoint[] {
  if (!points.length) return [];
  const xs = points.map((p) => p.x);
  const ys = points.map((p) => p.y);
  const zs = points.map((p) => p.z);
  const minX = Math.min(...xs);
  const maxX = Math.max(...xs);
  const minY = Math.min(...ys);
  const maxY = Math.max(...ys);
  const minZ = Math.min(...zs);
  const maxZ = Math.max(...zs);
  const cx = (minX + maxX) / 2;
  const cy = (minY + maxY) / 2;
  const cz = (minZ + maxZ) / 2;
  const scale = Math.max(maxX - minX, maxY - minY, maxZ - minZ, 0.001);
  return points.map((p) => ({
    x: (p.x - cx) / scale,
    y: (p.y - cy) / scale,
    z: (p.z - cz) / scale
  }));
}

export function parseGlb(buffer: ArrayBuffer): ParsedGlb {
  const view = new DataView(buffer);
  if (view.byteLength < 20 || readU32(view, 0) !== GLB_MAGIC) {
    throw new Error('Invalid GLB header');
  }
  const version = readU32(view, 4);
  if (version !== 2) throw new Error(`Unsupported GLB version ${version}`);
  const declaredLength = readU32(view, 8);
  if (declaredLength > view.byteLength) throw new Error('Truncated GLB payload');

  let offset = 12;
  let doc: GltfDocument | null = null;
  let bin: Uint8Array | null = null;
  while (offset + 8 <= declaredLength) {
    const chunkLength = readU32(view, offset);
    const chunkType = readU32(view, offset + 4);
    const start = offset + 8;
    const end = start + chunkLength;
    if (end > view.byteLength) throw new Error('Truncated GLB chunk');
    const bytes = new Uint8Array(buffer, start, chunkLength);
    if (chunkType === GLB_JSON) doc = parseJsonChunk(bytes);
    if (chunkType === GLB_BIN) bin = bytes;
    offset = end;
  }
  if (!doc) throw new Error('GLB missing JSON chunk');
  return {
    asset: doc.asset ?? {},
    nodes: (doc.nodes ?? []).map((node, index) => node.name ?? `node-${index}`),
    animations: (doc.animations ?? []).map((animation, index) => animation.name ?? `animation-${index}`),
    points: extractPositions(doc, bin)
  };
}

function fallbackPoints(): GltfPoint[] {
  return Array.from({ length: 80 }, (_, index) => {
    const theta = (index / 80) * Math.PI * 2;
    const wobble = 0.22 * Math.sin(theta * 3);
    return {
      x: Math.cos(theta) * (0.32 + wobble),
      y: Math.sin(theta) * 0.28,
      z: Math.sin(theta * 2) * 0.18
    };
  });
}

function renderPointCloud(canvas: HTMLCanvasElement, points: GltfPoint[], reducedMotion: boolean): () => void {
  const context = canvas.getContext('2d');
  if (!context) return () => undefined;
  let frame = 0;
  let raf = 0;
  const draw = (): void => {
    const rect = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const width = Math.max(1, Math.round(rect.width * dpr));
    const height = Math.max(1, Math.round(rect.height * dpr));
    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width;
      canvas.height = height;
    }
    context.clearRect(0, 0, width, height);
    const t = reducedMotion ? 0.35 : frame * 0.015;
    const cos = Math.cos(t);
    const sin = Math.sin(t);
    for (const point of points) {
      const x = point.x * cos - point.z * sin;
      const z = point.x * sin + point.z * cos;
      const y = point.y + Math.sin(t * 2 + point.x * 5) * 0.035;
      const depth = 0.78 + z * 0.42;
      const px = width * (0.5 + x * 0.88 * depth);
      const py = height * (0.5 - y * 1.25 * depth);
      const radius = Math.max(1.5, 3.4 * depth);
      context.beginPath();
      context.fillStyle = `rgba(60, 214, 192, ${Math.min(0.92, 0.34 + depth * 0.54)})`;
      context.arc(px, py, radius, 0, Math.PI * 2);
      context.fill();
    }
    frame += 1;
    if (!reducedMotion) raf = window.requestAnimationFrame(draw);
  };
  draw();
  return () => {
    if (raf) window.cancelAnimationFrame(raf);
  };
}

export async function mountPetGltfRuntime(host: HTMLElement, asset: string | ArrayBuffer): Promise<ParsedGlb> {
  activePetRuntimeStop?.();
  activePetRuntimeStop = null;
  host.replaceChildren();
  const canvas = document.createElement('canvas');
  canvas.className = 'pet-canvas';
  canvas.setAttribute('aria-hidden', 'true');
  const caption = document.createElement('p');
  caption.className = 'muted pet-runtime-caption';
  host.append(canvas, caption);

  const buffer =
    typeof asset === 'string'
      ? await (async () => {
          const response = await fetch(asset);
          if (!response.ok) throw new Error(`Unable to load pet asset: ${response.status}`);
          return response.arrayBuffer();
        })()
      : asset;
  const parsed = parseGlb(buffer);
  const points = parsed.points.length ? parsed.points : fallbackPoints();
  const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  activePetRuntimeStop = renderPointCloud(canvas, points, reducedMotion);
  caption.textContent = `GLB runtime loaded ${points.length} vertices; animations: ${
    parsed.animations.slice(0, 4).join(', ') || 'embedded idle graph'
  }.`;
  host.dataset.petRuntime = 'gltf-canvas';
  return parsed;
}

export function stopPetGltfRuntime(): void {
  activePetRuntimeStop?.();
  activePetRuntimeStop = null;
}
