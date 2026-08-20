import { extractPageContext, isSensitiveControl } from '../src/content/extract';
import { requireElement, testDOMRect } from './helpers/assertions';

function visibleRect(index = 0): DOMRect {
  const left = 20 + index * 8;
  const top = 20 + index * 12;
  return testDOMRect(left, top, 180, 32);
}

describe('page context extraction', () => {
  beforeEach(() => {
    vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function mockRect(this: Element) {
      const index = Number.parseInt(this.getAttribute('data-index') ?? '0', 10);
      return visibleRect(index);
    });
  });

  it('combines readable markdown, accessible names, refs, and viewport boxes', () => {
    document.title = 'Checkout preview';
    window.history.replaceState({}, '', '/products?token=secret');
    document.body.innerHTML = `
      <main>
        <h1>Mercury keyboard</h1>
        <p>Built from milled aluminum.</p>
        <a href="https://shop.example.test/product?token=secret" data-index="1">View details</a>
        <button aria-label="Add Mercury keyboard to cart" data-index="2">Add</button>
        <label for="query">Search</label>
        <input id="query" name="query" placeholder="Search products" value="private draft" data-index="3" />
        <img alt="Silver keyboard on a dark desk" data-index="4" />
      </main>
    `;

    const context = extractPageContext(() => new Date('2026-08-10T12:00:00Z'));
    expect(context.markdown).toContain('# Mercury keyboard');
    expect(context.markdown).toContain('Built from milled aluminum.');
    expect(context.markdown).toContain('[View details](https://shop.example.test/product)');
    expect(context.markdown).not.toContain('token=secret');
    expect(context.snapshot).toContain('[name="Add Mercury keyboard to cart"]');
    expect(context.snapshot).toContain('[box=');
    expect(context.nodes.find((node) => node.selector === '#query')?.name).toBe('Search');
    expect(context.nodes.find((node) => node.selector === '#query')?.value).toBeUndefined();
    expect(context.viewport.devicePixelRatio).toBe(2);
    expect(context.capturedAt).toBe('2026-08-10T12:00:00.000Z');
    expect(context.pageState.navigationEpoch).toBeGreaterThan(0);
  });

  it('redacts credential controls and detects sensitive pages', () => {
    window.history.replaceState({}, '', '/signin');
    document.body.innerHTML = `
      <main>
        <h1>Sign in</h1>
        <label for="password">Password</label>
        <input id="password" type="password" value="never-expose-this" data-index="1" />
        <input id="card" name="card_number" autocomplete="cc-number" value="4111111111111111" data-index="2" />
      </main>
    `;
    const password = requireElement(document.getElementById('password'), 'password input');
    const card = requireElement(document.getElementById('card'), 'card input');
    expect(isSensitiveControl(password)).toBe(true);
    expect(isSensitiveControl(card)).toBe(true);

    const context = extractPageContext();
    expect(context.sensitive).toBe(true);
    expect(context.snapshot).toContain('[sensitive=redacted]');
    expect(context.snapshot).not.toContain('never-expose-this');
    expect(context.snapshot).not.toContain('4111111111111111');
    expect(context.nodes.filter((node) => node.sensitive)).toHaveLength(2);
  });

  it('models diverse semantic controls, states, accessible names, and markdown blocks', () => {
    window.history.replaceState({}, '', '/catalog');
    document.body.innerHTML = `
      <main>
        <h2>Heading two</h2>
        <h3>Heading three</h3>
        <h4>Heading four</h4>
        <h5>Heading five</h5>
        <h6>Heading six</h6>
        <ul><li>List entry</li></ul>
        <blockquote>Quoted guidance</blockquote>
        <pre>const answer = 42;</pre>
        <table><tr><th>Plan</th><td>Pro</td></tr></table>
        <div id="label-source">Named by another node</div>
        <a href="mailto:support@example.com">Email support</a>
        <button aria-labelledby="label-source" aria-expanded="true" disabled>Fallback text</button>
        <input type="checkbox" name="updates" checked />
        <input type="radio" name="choice" />
        <input type="range" name="volume" />
        <input type="submit" value="Continue" />
        <textarea placeholder="Notes"></textarea>
        <select>
          <option role="option">Basic</option>
          <option role="option" selected>Professional</option>
        </select>
        <summary>More details</summary>
        <img tabindex="0" alt="Product preview" />
        <div role="button" title="Titled control"></div>
        <div contenteditable="true">Editable note</div>
      </main>
    `;
    document.querySelector('textarea')?.focus();

    const context = extractPageContext();
    expect(context.markdown).toContain('## Heading two');
    expect(context.markdown).toContain('###### Heading six');
    expect(context.markdown).toContain('- List entry');
    expect(context.markdown).toContain('> Quoted guidance');
    expect(context.markdown).toContain('```');
    expect(context.markdown).toContain('| Plan |');
    expect(context.markdown).not.toContain('mailto:');
    expect(context.snapshot).toContain('[role=checkbox]');
    expect(context.snapshot).toContain('[role=radio]');
    expect(context.snapshot).toContain('[role=slider]');
    expect(context.snapshot).toContain('[role=combobox]');
    expect(context.snapshot).toContain('[role=img]');
    expect(context.snapshot).toContain('[disabled=true]');
    expect(context.snapshot).toContain('[checked=true]');
    expect(context.snapshot).toContain('[expanded=true]');
    expect(context.snapshot).toContain('[focused=true]');
    expect(context.nodes.find((node) => node.role === 'combobox')?.value).toBe('Professional');
    expect(context.nodes.find((node) => node.role === 'option' && node.name === 'Professional')?.selected).toBe(true);
    expect(context.nodes.some((node) => node.name === 'Named by another node')).toBe(true);
    expect(context.nodes.some((node) => node.name === 'Titled control')).toBe(true);
  });

  it('ignores hidden content and caps oversized snapshots', () => {
    document.body.innerHTML = `
      <main>
        <p hidden>Invisible secret</p>
        ${Array.from({ length: 650 }, (_, index) => `<button data-index="${index % 40}">Button ${index}</button>`).join(
          ''
        )}
      </main>
    `;
    const context = extractPageContext();
    expect(context.markdown).not.toContain('Invisible secret');
    expect(context.nodes).toHaveLength(300);
    expect(context.truncated).toBe(true);
  });
});
