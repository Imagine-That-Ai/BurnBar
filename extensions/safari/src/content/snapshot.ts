import { SafariExtensionError } from '../shared/errors';
import type { ActionTarget } from '../shared/protocol';

function escapeIdentifier(value: string): string {
  const cssEscape = globalThis.CSS?.escape;
  if (cssEscape) {
    return cssEscape(value);
  }
  return value.replace(/[^a-zA-Z0-9_-]/gu, (character) => `\\${character.codePointAt(0)?.toString(16)} `);
}

interface SiblingPosition {
  count: number;
  index: number;
}

export type SelectorGenerationCache = WeakMap<Element, Map<Element, SiblingPosition>>;

function siblingPositions(parent: Element): Map<Element, SiblingPosition> {
  const groups = new Map<string, Element[]>();
  for (const child of parent.children) {
    const siblings = groups.get(child.localName) ?? [];
    siblings.push(child);
    groups.set(child.localName, siblings);
  }

  const positions = new Map<Element, SiblingPosition>();
  for (const siblings of groups.values()) {
    for (const [index, sibling] of siblings.entries()) {
      positions.set(sibling, {
        count: siblings.length,
        index: index + 1
      });
    }
  }
  return positions;
}

export function selectorForElement(element: Element, cache?: SelectorGenerationCache): string {
  if (element.id) {
    return `#${escapeIdentifier(element.id)}`;
  }

  const testIdentifier = element.getAttribute('data-testid') ?? element.getAttribute('data-test');
  if (testIdentifier) {
    return `${element.localName}[data-testid="${testIdentifier.replaceAll('"', '\\"')}"]`;
  }

  const parts: string[] = [];
  let current: Element | null = element;
  while (current && current !== document.documentElement && parts.length < 6) {
    let part = current.localName;
    const parent: Element | null = current.parentElement;
    if (parent) {
      let positions = cache?.get(parent);
      if (!positions) {
        positions = siblingPositions(parent);
        cache?.set(parent, positions);
      }
      const position = positions.get(current);
      if (position && position.count > 1) {
        part += `:nth-of-type(${position.index})`;
      }
    }
    parts.unshift(part);
    current = parent;
  }
  return parts.join(' > ');
}

export class SnapshotRegistry {
  private sequence = 0;
  private readonly elements = new Map<string, Element>();

  reset(): void {
    this.sequence = 0;
    this.elements.clear();
  }

  register(element: Element): string {
    this.sequence += 1;
    const ref = `obb-${this.sequence}`;
    this.elements.set(ref, element);
    return ref;
  }

  resolve(target: ActionTarget, documentValue: Document = document): Element {
    const reference = target.ref?.trim();
    if (reference) {
      const element = this.elements.get(reference);
      if (element?.isConnected) {
        return element;
      }
      throw new SafariExtensionError('stale_snapshot_ref', `Snapshot reference "${reference}" is stale.`);
    }

    const selector = target.selector?.trim();
    if (selector) {
      try {
        const element = documentValue.querySelector(selector);
        if (element) {
          return element;
        }
      } catch (error) {
        throw new SafariExtensionError('invalid_selector', `Selector "${selector}" is invalid.`, {
          details: error
        });
      }
      throw new SafariExtensionError('target_not_found', `No element matches selector "${selector}".`);
    }

    if (target.point) {
      const element = documentValue.elementFromPoint(target.point.x, target.point.y);
      if (element) {
        return element;
      }
      throw new SafariExtensionError(
        'target_not_found',
        `No element is present at (${target.point.x}, ${target.point.y}).`
      );
    }

    throw new SafariExtensionError('missing_target', 'The action did not specify a ref, selector, or point.');
  }
}

export const snapshotRegistry = new SnapshotRegistry();
