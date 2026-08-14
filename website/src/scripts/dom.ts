/**
 * Typed DOM lookups that check at runtime instead of asserting.
 *
 * The bench pages hydrate against server-rendered markup, so every lookup can
 * miss: an id can be absent, a selector can match a different tag than the
 * caller expects, and an event target can be a text node. Narrowing with
 * `instanceof` keeps the caller's static type honest and degrades to `null`
 * on a mismatch rather than handing back an object that only claims to be one.
 */

type ElementCtor<T extends Element> = abstract new () => T;

/** Look up an element by id, returning null unless it is of the expected type. */
export function byId<T extends HTMLElement>(id: string, ctor: ElementCtor<T>): T | null {
  const node = document.getElementById(id);
  return node instanceof ctor ? node : null;
}

/** Query a single element, returning null unless it is of the expected type. */
export function query<T extends Element>(
  root: ParentNode,
  selector: string,
  ctor: ElementCtor<T>
): T | null {
  const node = root.querySelector(selector);
  return node instanceof ctor ? node : null;
}

/** Walk up from an event target to the nearest matching element of a type. */
export function closestFrom<T extends Element>(
  target: EventTarget | null,
  selector: string,
  ctor: ElementCtor<T>
): T | null {
  if (!(target instanceof Element)) return null;
  const node = target.closest(selector);
  return node instanceof ctor ? node : null;
}

/** Narrow an event target to an element type, or null. */
export function targetAs<T extends Element>(
  target: EventTarget | null,
  ctor: ElementCtor<T>
): T | null {
  return target instanceof ctor ? target : null;
}

/** Keep only the nodes of the expected type. */
export function onlyElements<T extends Element>(nodes: Iterable<Node>, ctor: ElementCtor<T>): T[] {
  const kept: T[] = [];
  for (const node of nodes) if (node instanceof ctor) kept.push(node);
  return kept;
}

/** Read an array slot, throwing rather than asserting the index is populated. */
export function at<T>(items: ArrayLike<T>, index: number): T {
  const item = items[index];
  if (item === undefined) throw new Error(`expected an item at index ${index}`);
  return item;
}
