import { ContentActionExecutor } from '../src/content/act';
import { setFrameworkAwareValue } from '../src/content/reactInput';
import { snapshotRegistry } from '../src/content/snapshot';
import { requireElement, testDOMRect } from './helpers/assertions';

function mockVisible(element: Element): void {
  vi.spyOn(element, 'getBoundingClientRect').mockReturnValue(testDOMRect(10, 10, 120, 30));
}

describe('framework-aware page actions', () => {
  it('uses the native value setter, resets React tracking, and emits input/change', () => {
    const tracker = { setValue: vi.fn(), getValue: () => 'old' };
    const input = document.createElement('input');
    Reflect.set(input, '_valueTracker', tracker);
    input.value = 'old';
    const events: string[] = [];
    input.addEventListener('input', () => events.push('input'));
    input.addEventListener('change', () => events.push('change'));
    setFrameworkAwareValue(input, 'new');
    expect(input.value).toBe('new');
    expect(tracker.setValue).toHaveBeenCalledWith('old');
    expect(events).toEqual(['input', 'change']);
  });

  it('clicks, types, focuses, hovers, selects, scrolls, presses keys, extracts, and waits', async () => {
    document.body.innerHTML = `
      <button id="buy">Buy now</button>
      <input id="search" />
      <select id="size"><option value="s">Small</option><option value="l">Large</option></select>
      <div id="extract" data-sku="abc">Result text</div>
      <svg><rect id="svg-target" width="20" height="20"></rect></svg>
    `;
    for (const candidate of Array.from(document.body.children)) {
      mockVisible(candidate);
    }
    const buy = requireElement(document.getElementById('buy'), 'buy button');
    const search = requireElement(document.querySelector<HTMLInputElement>('#search'), 'search input');
    const select = requireElement(document.querySelector<HTMLSelectElement>('#size'), 'size select');
    const clicked = vi.fn();
    buy.addEventListener('click', clicked);
    const executor = new ContentActionExecutor();

    snapshotRegistry.reset();
    const buyRef = snapshotRegistry.register(buy);
    const clickResult = await executor.execute({ kind: 'click', target: { ref: buyRef } }, (path) => path);
    expect(clickResult, JSON.stringify(clickResult)).toMatchObject({ ok: true });
    expect(clicked).toHaveBeenCalled();

    snapshotRegistry.reset();
    const inputRef = snapshotRegistry.register(search);
    expect(
      (
        await executor.execute(
          { kind: 'type', target: { ref: inputRef }, text: 'Mercury', clear: true },
          (path) => path
        )
      ).ok
    ).toBe(true);
    expect(search.value).toBe('Mercury');
    expect((await executor.execute({ kind: 'focus', target: { ref: inputRef } }, (path) => path)).result).toEqual({
      focused: true
    });
    expect((await executor.execute({ kind: 'type', text: 'Focused Mercury', clear: true }, (path) => path)).ok).toBe(
      true
    );
    expect(search.value).toBe('Focused Mercury');
    expect((await executor.execute({ kind: 'hover', target: { ref: inputRef } }, (path) => path)).ok).toBe(true);
    expect(
      (
        await executor.execute(
          { kind: 'press_key', key: 'K', target: { ref: inputRef }, modifiers: ['Meta'] },
          (path) => path
        )
      ).result
    ).toEqual({ pressed: 'K' });

    snapshotRegistry.reset();
    const selectRef = snapshotRegistry.register(select);
    const selectResult = await executor.execute(
      { kind: 'select_option', target: { ref: selectRef }, values: ['l'] },
      (path) => path
    );
    expect(selectResult.ok).toBe(true);
    expect(select.value).toBe('l');

    const svgTarget = requireElement(document.getElementById('svg-target'), 'SVG target');
    mockVisible(svgTarget);
    const svgClicked = vi.fn();
    svgTarget.addEventListener('click', svgClicked);
    snapshotRegistry.reset();
    const svgRef = snapshotRegistry.register(svgTarget);
    expect((await executor.execute({ kind: 'click', target: { ref: svgRef } }, (path) => path)).ok).toBe(true);
    expect(svgClicked).toHaveBeenCalledOnce();

    expect(
      (await executor.execute({ kind: 'scroll', deltaY: 320, behavior: 'auto' }, (path) => path)).result
    ).toMatchObject({ scrollY: 320 });
    expect(
      (
        await executor.execute(
          { kind: 'extract', selector: '#extract', attributes: ['data-sku', 'value'] },
          (path) => path
        )
      ).result
    ).toEqual([{ text: 'Result text', attributes: { 'data-sku': 'abc' } }]);
    expect(
      (
        await executor.execute(
          { kind: 'wait_for', selector: '#extract', state: 'visible', timeoutMs: 100 },
          (path) => path
        )
      ).result
    ).toMatchObject({ matched: true });
  });

  it('blocks sensitive typing without explicit approval and allows it when approved', async () => {
    const password = document.createElement('input');
    password.type = 'password';
    document.body.append(password);
    mockVisible(password);
    snapshotRegistry.reset();
    const ref = snapshotRegistry.register(password);
    const executor = new ContentActionExecutor();
    const blocked = await executor.execute({ kind: 'type', target: { ref }, text: 'secret' }, (path) => path);
    expect(blocked.ok).toBe(false);
    expect(blocked.error?.code).toBe('sensitive_input_blocked');
    const allowed = await executor.execute(
      { kind: 'type', target: { ref }, text: 'secret', allowSensitive: true },
      (path) => path
    );
    expect(allowed.ok).toBe(true);
    expect(password.value).toBe('secret');
    expect(allowed.verification.target?.value).toBe('[redacted]');
  });

  it('runs approved isolated JavaScript, rejects unapproved code, invalid selectors, and aborts waits', async () => {
    const executor = new ContentActionExecutor();
    const unapproved = await executor.execute(
      { kind: 'run_javascript', source: 'return 1;', approved: false },
      (path) => path
    );
    expect(unapproved.error?.code).toBe('javascript_approval_required');

    const approved = await executor.execute(
      { kind: 'run_javascript', source: 'return { answer: 42 };', approved: true, world: 'isolated' },
      (path) => path
    );
    expect(approved.result).toEqual({ answer: 42 });

    const invalid = await executor.execute({ kind: 'extract', selector: '[' }, (path) => path);
    expect(invalid.error?.code).toBe('invalid_selector');

    const waiting = executor.execute({ kind: 'wait_for', selector: '.never', timeoutMs: 5_000 }, (path) => path);
    executor.abort();
    const aborted = await waiting;
    expect(aborted.ok).toBe(false);
    expect(aborted.error?.code).toBe('AbortError');
  });

  it('stops waiting for already-running JavaScript when the Safari command is aborted', async () => {
    const executor = new ContentActionExecutor();
    const running = executor.execute(
      {
        kind: 'run_javascript',
        source: 'return await new Promise(() => undefined);',
        approved: true,
        world: 'isolated',
        timeoutMs: 30_000
      },
      (path) => path
    );
    await Promise.resolve();
    executor.abort();
    const aborted = await running;
    expect(aborted.ok).toBe(false);
    expect(aborted.error?.code).toBe('AbortError');
  });
});
