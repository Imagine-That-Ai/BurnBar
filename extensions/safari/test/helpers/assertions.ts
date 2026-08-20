import { isRecord, validateNativeRequest, type NativeRequestEnvelope } from '../../src/shared/protocol';

export function requireValue<T>(value: T | null | undefined, label: string): T {
  if (value === null || value === undefined) {
    throw new Error(`Expected ${label}.`);
  }
  return value;
}

export function requireElement<T extends Element>(value: T | null, label: string): T {
  return requireValue(value, label);
}

export function requireRecord(value: unknown, label: string): Record<string, unknown> {
  if (!isRecord(value)) {
    throw new Error(`Expected ${label} to be an object.`);
  }
  return value;
}

export function requireRecordArray(value: unknown, label: string): Record<string, unknown>[] {
  if (!Array.isArray(value) || !value.every(isRecord)) {
    throw new Error(`Expected ${label} to be an array of objects.`);
  }
  return value;
}

export function requireNativeRequest(value: unknown): NativeRequestEnvelope {
  validateNativeRequest(value);
  return value;
}

export function parseJSONRecord(value: string, label: string): Record<string, unknown> {
  const parsed: unknown = JSON.parse(value);
  return requireRecord(parsed, label);
}

export function testDOMRect(left: number, top: number, width: number, height: number): DOMRect {
  const rectangle = DOMRect.fromRect();
  Object.defineProperties(rectangle, {
    x: { configurable: true, value: left },
    y: { configurable: true, value: top },
    left: { configurable: true, value: left },
    top: { configurable: true, value: top },
    width: { configurable: true, value: width },
    height: { configurable: true, value: height },
    right: { configurable: true, value: left + width },
    bottom: { configurable: true, value: top + height }
  });
  return rectangle;
}
