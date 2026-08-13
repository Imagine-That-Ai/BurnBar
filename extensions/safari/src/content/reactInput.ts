type ValueElement = HTMLInputElement | HTMLTextAreaElement;

function nativeValueSetter(element: ValueElement): ((value: string) => void) | undefined {
  const prototype = element instanceof HTMLTextAreaElement ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
  const descriptor = Object.getOwnPropertyDescriptor(prototype, 'value');
  return descriptor?.set ? descriptor.set.bind(element) : undefined;
}

export function setFrameworkAwareValue(element: ValueElement, value: string): void {
  const previous = element.value;
  const setter = nativeValueSetter(element);
  if (setter) {
    setter(value);
  } else {
    element.value = value;
  }

  const tracker: unknown = Reflect.get(element, '_valueTracker');
  if (
    typeof tracker === 'object' &&
    tracker !== null &&
    'setValue' in tracker &&
    typeof tracker.setValue === 'function'
  ) {
    tracker.setValue(previous);
  }

  element.dispatchEvent(
    new InputEvent('input', {
      bubbles: true,
      composed: true,
      inputType: 'insertText',
      data: value
    })
  );
  element.dispatchEvent(new Event('change', { bubbles: true, composed: true }));
}
