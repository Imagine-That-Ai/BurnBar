import { SafariExtensionError, serializeError } from '../shared/errors';
import type {
  ActionTarget,
  ContentAction,
  ContentActionResult,
  ExtractAction,
  RunJavaScriptAction,
  WaitForAction
} from '../shared/protocol';
import { runInPageWorld } from './pageWorldBridge';
import { setFrameworkAwareValue } from './reactInput';
import { snapshotRegistry } from './snapshot';
import { currentPageState, verificationFor } from './verification';

const MAX_JAVASCRIPT_CHARACTERS = 100_000;
const MAX_EXTRACT_RESULTS = 200;

type EditableElement = HTMLInputElement | HTMLTextAreaElement;

function nextFrame(): Promise<void> {
  return new Promise((resolve) => {
    if (typeof requestAnimationFrame === 'function') {
      requestAnimationFrame(() => resolve());
    } else {
      setTimeout(resolve, 0);
    }
  });
}

async function settleFrames(): Promise<void> {
  await nextFrame();
  await nextFrame();
}

function dispatchMouseSequence(element: Element, clickCount: 1 | 2, button: number): void {
  const options: MouseEventInit = {
    bubbles: true,
    cancelable: true,
    composed: true,
    detail: clickCount,
    button,
    buttons: button === 0 ? 1 : 1 << button
  };
  element.dispatchEvent(new PointerEvent('pointerover', options));
  element.dispatchEvent(new MouseEvent('mouseover', options));
  element.dispatchEvent(new PointerEvent('pointerdown', options));
  element.dispatchEvent(new MouseEvent('mousedown', options));
  element.dispatchEvent(new PointerEvent('pointerup', { ...options, buttons: 0 }));
  element.dispatchEvent(new MouseEvent('mouseup', { ...options, buttons: 0 }));
}

function isSensitiveEditable(element: EditableElement): boolean {
  if (element instanceof HTMLInputElement && element.type === 'password') {
    return true;
  }
  const fingerprint = `${element.getAttribute('autocomplete') ?? ''} ${element.id} ${element.getAttribute('name') ?? ''}`;
  return /(?:cc-|card.?number|cvc|cvv|one-time-code|otp|passcode|password)/iu.test(fingerprint);
}

function editableElement(element: Element): EditableElement {
  if (element instanceof HTMLInputElement || element instanceof HTMLTextAreaElement) {
    if (element.disabled || element.readOnly) {
      throw new SafariExtensionError('target_not_editable', 'The target field is disabled or read-only.');
    }
    return element;
  }
  throw new SafariExtensionError('target_not_editable', 'The target is not an input or text area.');
}

function cloneSerializable(value: unknown): unknown {
  const seen = new WeakSet<object>();
  const serialized = JSON.stringify(value, (_key, candidate: unknown) => {
    if (typeof candidate === 'bigint') {
      return candidate.toString();
    }
    if (typeof candidate === 'function' || typeof candidate === 'symbol') {
      return undefined;
    }
    if (typeof candidate === 'object' && candidate !== null) {
      if (seen.has(candidate)) {
        return '[Circular]';
      }
      seen.add(candidate);
    }
    return candidate;
  });
  if (serialized === undefined) {
    return null;
  }
  return JSON.parse(serialized);
}

function isAsyncExecutor(value: unknown): value is () => Promise<unknown> {
  return typeof value === 'function';
}

async function runIsolatedJavaScript(source: string): Promise<unknown> {
  const asyncFunctionPrototype: unknown = Object.getPrototypeOf(async function () {});
  if (
    typeof asyncFunctionPrototype !== 'object' ||
    asyncFunctionPrototype === null ||
    !('constructor' in asyncFunctionPrototype) ||
    typeof asyncFunctionPrototype.constructor !== 'function'
  ) {
    throw new SafariExtensionError('javascript_unavailable', 'Safari could not create an isolated JavaScript runner.');
  }
  const candidate: unknown = Reflect.construct(asyncFunctionPrototype.constructor, [
    `"use strict";\n${source}\n//# sourceURL=openburnbar-safari-isolated-action.js`
  ]);
  if (!isAsyncExecutor(candidate)) {
    throw new SafariExtensionError('javascript_unavailable', 'Safari could not create an isolated JavaScript runner.');
  }
  const execute = candidate;
  return cloneSerializable(await execute());
}

function elementMatchesWait(element: Element | null, action: WaitForAction): boolean {
  const state = action.state ?? 'visible';
  const attached = Boolean(element?.isConnected);
  const visible =
    attached &&
    element !== null &&
    (() => {
      const style = getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
    })();
  switch (state) {
    case 'attached':
      return attached;
    case 'detached':
      return !attached;
    case 'visible':
      return visible;
    case 'hidden':
      return !visible;
  }
}

async function waitFor(action: WaitForAction, signal: AbortSignal): Promise<Record<string, unknown>> {
  if (!action.selector && !action.text) {
    throw new SafariExtensionError('wait_condition_missing', 'wait_for requires a selector or text.');
  }
  const timeoutMs = Math.min(Math.max(action.timeoutMs ?? 5_000, 50), 30_000);
  const deadline = Date.now() + timeoutMs;
  while (Date.now() <= deadline) {
    if (signal.aborted) {
      throw new DOMException('The Safari action was aborted.', 'AbortError');
    }
    let element: Element | null = null;
    if (action.selector) {
      try {
        element = document.querySelector(action.selector);
      } catch (error) {
        throw new SafariExtensionError('invalid_selector', `Selector "${action.selector}" is invalid.`, {
          details: error
        });
      }
    } else if (action.text) {
      const wanted = action.text.toLocaleLowerCase();
      element =
        Array.from(document.querySelectorAll('body *')).find((candidate) =>
          (candidate.textContent ?? '').toLocaleLowerCase().includes(wanted)
        ) ?? null;
    }
    if (elementMatchesWait(element, action)) {
      return {
        matched: true,
        ...(action.selector ? { selector: action.selector } : {}),
        ...(action.text ? { text: action.text } : {})
      };
    }
    await new Promise<void>((resolve) => setTimeout(resolve, 50));
  }
  throw new SafariExtensionError('wait_timeout', 'The page did not reach the requested state before timeout.', {
    retryable: true
  });
}

function extractElements(action: ExtractAction): Array<Record<string, unknown>> {
  let elements: Element[];
  try {
    elements = Array.from(document.querySelectorAll(action.selector));
  } catch (error) {
    throw new SafariExtensionError('invalid_selector', `Selector "${action.selector}" is invalid.`, {
      details: error
    });
  }
  const limit = Math.min(Math.max(action.limit ?? 50, 1), MAX_EXTRACT_RESULTS);
  return elements.slice(0, limit).map((element) => {
    const attributes: Record<string, string> = {};
    for (const attribute of action.attributes ?? []) {
      if (/^(?:value|srcdoc)$/iu.test(attribute)) {
        continue;
      }
      const value = element.getAttribute(attribute);
      if (value !== null) {
        attributes[attribute] = value.slice(0, 2_000);
      }
    }
    return {
      text: (element.textContent ?? '').replace(/\s+/gu, ' ').trim().slice(0, 4_000),
      attributes
    };
  });
}

export class ContentActionExecutor {
  private abortController = new AbortController();

  abort(reason = 'OpenBurnBar stopped this run.'): void {
    this.abortController.abort(reason);
    this.abortController = new AbortController();
  }

  private async resolveTarget(target: ActionTarget): Promise<Element> {
    let element = snapshotRegistry.resolve(target);
    if (!target.point) {
      element.scrollIntoView({ behavior: 'auto', block: 'center', inline: 'center' });
      await settleFrames();
      element = snapshotRegistry.resolve(target);
    }
    return element;
  }

  async execute(action: ContentAction, getURL: (path: string) => string): Promise<ContentActionResult> {
    let targetElement: Element | undefined;
    try {
      const signal = this.abortController.signal;
      if (signal.aborted) {
        throw new DOMException('The Safari action was aborted.', 'AbortError');
      }
      let result: unknown;
      switch (action.kind) {
        case 'click': {
          targetElement = await this.resolveTarget(action.target);
          const button = action.button === 'right' ? 2 : action.button === 'middle' ? 1 : 0;
          const count = action.clickCount ?? 1;
          dispatchMouseSequence(targetElement, count, button);
          if (button === 2) {
            targetElement.dispatchEvent(
              new MouseEvent('contextmenu', { bubbles: true, cancelable: true, composed: true, button })
            );
          } else {
            if (targetElement instanceof HTMLElement) {
              targetElement.click();
            } else {
              targetElement.dispatchEvent(
                new MouseEvent('click', { bubbles: true, cancelable: true, composed: true, button })
              );
            }
            if (count === 2) {
              targetElement.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, detail: 2 }));
            }
          }
          result = { clicked: true };
          break;
        }
        case 'type': {
          targetElement = action.target
            ? await this.resolveTarget(action.target)
            : document.activeElement instanceof Element
              ? document.activeElement
              : undefined;
          if (!targetElement) {
            throw new SafariExtensionError(
              'target_not_editable',
              'No editable Safari field is focused and the command did not provide a target.'
            );
          }
          const editable = editableElement(targetElement);
          if (isSensitiveEditable(editable) && action.allowSensitive !== true) {
            throw new SafariExtensionError(
              'sensitive_input_blocked',
              'Typing into credential or payment fields requires explicit sensitive-field approval.'
            );
          }
          editable.focus({ preventScroll: true });
          const nextValue = action.clear === false ? `${editable.value}${action.text}` : action.text;
          setFrameworkAwareValue(editable, nextValue);
          if (action.submit) {
            editable.form?.requestSubmit();
          }
          result = { typed: true, characterCount: action.text.length, submitted: action.submit === true };
          break;
        }
        case 'press_key': {
          targetElement = action.target
            ? await this.resolveTarget(action.target)
            : (document.activeElement ?? undefined);
          const dispatchTarget = targetElement ?? document.body;
          const modifiers = new Set(action.modifiers ?? []);
          const init: KeyboardEventInit = {
            key: action.key,
            bubbles: true,
            cancelable: true,
            composed: true,
            altKey: modifiers.has('Alt'),
            ctrlKey: modifiers.has('Control'),
            metaKey: modifiers.has('Meta'),
            shiftKey: modifiers.has('Shift')
          };
          dispatchTarget.dispatchEvent(new KeyboardEvent('keydown', init));
          dispatchTarget.dispatchEvent(new KeyboardEvent('keyup', init));
          if (action.key === 'Enter' && targetElement instanceof HTMLElement) {
            const form = targetElement.closest('form');
            if (form instanceof HTMLFormElement) {
              form.requestSubmit();
            }
          }
          result = { pressed: action.key };
          break;
        }
        case 'scroll': {
          targetElement = action.target ? await this.resolveTarget(action.target) : undefined;
          const scroller = targetElement ?? window;
          scroller.scrollBy({
            left: action.deltaX ?? 0,
            top: action.deltaY ?? 0,
            behavior: action.behavior ?? 'auto'
          });
          await settleFrames();
          result = { scrollX: window.scrollX, scrollY: window.scrollY };
          break;
        }
        case 'hover': {
          targetElement = await this.resolveTarget(action.target);
          targetElement.dispatchEvent(new PointerEvent('pointerover', { bubbles: true, composed: true }));
          targetElement.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, composed: true }));
          targetElement.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false, composed: true }));
          result = { hovered: true };
          break;
        }
        case 'focus': {
          targetElement = await this.resolveTarget(action.target);
          if (!(targetElement instanceof HTMLElement || targetElement instanceof SVGElement)) {
            throw new SafariExtensionError('target_not_focusable', 'The target cannot receive focus.');
          }
          targetElement.focus({ preventScroll: true });
          result = { focused: document.activeElement === targetElement };
          break;
        }
        case 'select_option': {
          targetElement = await this.resolveTarget(action.target);
          if (!(targetElement instanceof HTMLSelectElement)) {
            throw new SafariExtensionError('target_not_select', 'The target is not a select element.');
          }
          const wanted = new Set(action.values);
          for (const option of Array.from(targetElement.options)) {
            option.selected = wanted.has(option.value) || wanted.has(option.text);
          }
          targetElement.dispatchEvent(new Event('input', { bubbles: true, composed: true }));
          targetElement.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
          result = {
            selected: Array.from(targetElement.selectedOptions).map((option) => option.value)
          };
          break;
        }
        case 'wait_for':
          result = await waitFor(action, signal);
          break;
        case 'run_javascript':
          result = await this.runJavaScript(action, getURL, signal);
          break;
        case 'extract':
          result = extractElements(action);
          break;
      }
      await settleFrames();
      return {
        ok: true,
        result,
        pageState: currentPageState(),
        verification: verificationFor(targetElement, 'target' in action ? action.target : undefined)
      };
    } catch (error) {
      return {
        ok: false,
        error: serializeError(error, 'content_action_failed'),
        pageState: currentPageState(),
        verification: verificationFor(targetElement, 'target' in action ? action.target : undefined)
      };
    }
  }

  private async runJavaScript(
    action: RunJavaScriptAction,
    getURL: (path: string) => string,
    signal: AbortSignal
  ): Promise<unknown> {
    if (!action.approved) {
      throw new SafariExtensionError(
        'javascript_approval_required',
        'run_javascript requires an explicit Computer Use approval.'
      );
    }
    if (action.source.length === 0 || action.source.length > MAX_JAVASCRIPT_CHARACTERS) {
      throw new SafariExtensionError('javascript_source_invalid', 'JavaScript must be between 1 byte and 100 KB.');
    }
    if (signal.aborted) {
      throw new DOMException('The Safari action was aborted.', 'AbortError');
    }
    const timeoutMs = Math.min(Math.max(action.timeoutMs ?? 5_000, 50), 30_000);
    const work =
      action.world === 'page'
        ? runInPageWorld(action.source, timeoutMs, getURL, signal)
        : runIsolatedJavaScript(action.source);

    // JavaScript already running in a page or isolated world cannot be
    // force-killed. Cancellation still stops bridge waiting and prevents a
    // stale result from completing the daemon command.
    return new Promise((resolve, reject) => {
      const timeout = window.setTimeout(() => {
        cleanup();
        reject(
          new SafariExtensionError('javascript_timeout', 'JavaScript exceeded its approved execution timeout.', {
            retryable: true
          })
        );
      }, timeoutMs);
      const onAbort = (): void => {
        cleanup();
        reject(new DOMException('The Safari action was aborted.', 'AbortError'));
      };
      const cleanup = (): void => {
        window.clearTimeout(timeout);
        signal.removeEventListener('abort', onAbort);
      };
      signal.addEventListener('abort', onAbort, { once: true });
      void work.then(
        (value) => {
          cleanup();
          resolve(value);
        },
        (error: unknown) => {
          cleanup();
          reject(error);
        }
      );
    });
  }
}
