import { rectToBoundingBox } from './boxes';
import { selectorForElement } from './snapshot';
import type { ActionTarget, ActionVerification, ContentPageState } from '../shared/protocol';

const NAVIGATION_EPOCH_KEY = 'openburnbar.safari.navigationEpoch';

function navigationEpoch(): number {
  try {
    const previous = Number.parseInt(sessionStorage.getItem(NAVIGATION_EPOCH_KEY) ?? '0', 10);
    const next = Number.isSafeInteger(previous) && previous >= 0 ? previous + 1 : 1;
    sessionStorage.setItem(NAVIGATION_EPOCH_KEY, String(next));
    return next;
  } catch {
    return 1;
  }
}

const CURRENT_NAVIGATION_EPOCH = navigationEpoch();

function safeControlValue(element: Element): string | undefined {
  if (element instanceof HTMLInputElement) {
    if (element.type === 'password' || /(?:password|cc-|one-time-code)/iu.test(element.autocomplete)) {
      return '[redacted]';
    }
    if (['checkbox', 'radio'].includes(element.type)) {
      return undefined;
    }
    return element.value.slice(0, 320);
  }
  if (element instanceof HTMLTextAreaElement || element instanceof HTMLSelectElement) {
    return element.value.slice(0, 320);
  }
  return undefined;
}

export function currentPageState(now: () => Date = () => new Date()): ContentPageState {
  return {
    url: window.location.href,
    title: document.title,
    navigationEpoch: CURRENT_NAVIGATION_EPOCH,
    isTopFrame: window.top === window,
    capturedAt: now().toISOString()
  };
}

export function verificationFor(element?: Element, target?: ActionTarget): ActionVerification {
  const activeElement =
    document.activeElement instanceof Element ? selectorForElement(document.activeElement) : undefined;
  const verification: ActionVerification = {
    ...currentPageState(),
    ...(activeElement ? { activeElement } : {})
  };
  if (!element) {
    return verification;
  }
  const text = (element.textContent ?? '').replace(/\s+/gu, ' ').trim().slice(0, 320);
  const value = safeControlValue(element);
  verification.target = {
    ...(target?.ref ? { ref: target.ref } : {}),
    selector: target?.selector ?? selectorForElement(element),
    box: rectToBoundingBox(element.getBoundingClientRect()),
    ...(text ? { text } : {}),
    ...(value === undefined ? {} : { value }),
    ...(element instanceof HTMLInputElement && ['checkbox', 'radio'].includes(element.type)
      ? { checked: element.checked }
      : {})
  };
  return verification;
}
