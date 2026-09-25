import { recordOrUndefined } from "../guards.js";

export const QUOTA_PAYLOAD_MAX_BUCKETS = 64;
export const QUOTA_PAYLOAD_MAX_LABEL_LENGTH = 160;

const QUOTA_PAYLOAD_MAX_DEPTH = 24;
const QUOTA_PAYLOAD_MAX_NODES = 2_048;
const QUOTA_PAYLOAD_MAX_CHILDREN_PER_NODE = 128;
const QUOTA_PAYLOAD_MAX_PATH_SEGMENTS = 32;
const QUOTA_PAYLOAD_MAX_PATH_SEGMENT_LENGTH = 80;

interface QuotaPayloadFrame {
  node: unknown;
  path: string[];
  depth: number;
}

type QuotaPayloadVisitResult = "stop" | void;

export function walkQuotaPayloadObjects(
  payload: unknown,
  visit: (obj: Record<string, unknown>, path: readonly string[]) => QuotaPayloadVisitResult,
): void {
  const stack: QuotaPayloadFrame[] = [{ node: payload, path: [], depth: 0 }];
  const seen = new WeakSet<object>();
  let visitedNodes = 0;

  while (stack.length > 0 && visitedNodes < QUOTA_PAYLOAD_MAX_NODES) {
    const frame = stack.pop();
    const node = frame?.node;
    if (!frame || !node || typeof node !== "object") continue;

    if (seen.has(node)) continue;
    seen.add(node);
    visitedNodes += 1;

    if (Array.isArray(node)) {
      if (frame.depth >= QUOTA_PAYLOAD_MAX_DEPTH) continue;
      pushArrayChildren(stack, node, frame.path, frame.depth);
      continue;
    }

    const obj = recordOrUndefined(node);
    if (!obj) continue;
    if (visit(obj, frame.path) === "stop") return;

    if (frame.depth >= QUOTA_PAYLOAD_MAX_DEPTH) continue;
    pushObjectChildren(stack, frame, obj);
  }
}

export function boundedQuotaLabel(
  raw: unknown,
  fallback?: string,
  maxLength = QUOTA_PAYLOAD_MAX_LABEL_LENGTH,
): string | undefined {
  if (typeof raw !== "string") return fallback;
  const value = raw.trim().replace(/\s+/g, " ");
  if (!value) return fallback;
  return truncateLabel(value, maxLength);
}

function pushArrayChildren(
  stack: QuotaPayloadFrame[],
  node: readonly unknown[],
  path: readonly string[],
  depth: number,
): void {
  const childCount = Math.min(node.length, QUOTA_PAYLOAD_MAX_CHILDREN_PER_NODE);
  for (let idx = childCount - 1; idx >= 0; idx -= 1) {
    const child = node[idx];
    if (child && typeof child === "object") {
      stack.push({
        node: child,
        path: appendPathSegment(path, `[${idx}]`),
        depth: depth + 1,
      });
    }
  }
}

function pushObjectChildren(stack: QuotaPayloadFrame[], frame: QuotaPayloadFrame, obj: Record<string, unknown>): void {
  const children: Array<{ key: string; value: unknown }> = [];
  for (const key in obj) {
    if (!Object.prototype.hasOwnProperty.call(obj, key)) continue;
    const value = obj[key];
    if (value && typeof value === "object") {
      children.push({ key, value });
      if (children.length >= QUOTA_PAYLOAD_MAX_CHILDREN_PER_NODE) break;
    }
  }

  for (let idx = children.length - 1; idx >= 0; idx -= 1) {
    const child = children[idx];
    stack.push({
      node: child.value,
      path: appendPathSegment(frame.path, child.key),
      depth: frame.depth + 1,
    });
  }
}

function appendPathSegment(path: readonly string[], segment: string): string[] {
  const next = truncateLabel(segment, QUOTA_PAYLOAD_MAX_PATH_SEGMENT_LENGTH);
  if (path.length >= QUOTA_PAYLOAD_MAX_PATH_SEGMENTS) {
    return [...path.slice(0, QUOTA_PAYLOAD_MAX_PATH_SEGMENTS - 1), next];
  }
  return [...path, next];
}

function truncateLabel(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value;
  if (maxLength <= 3) return value.slice(0, maxLength);
  return `${value.slice(0, maxLength - 3)}...`;
}
