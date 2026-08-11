// @vitest-environment jsdom
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { RichContent } from './RichContent.js';

afterEach(cleanup);

describe('RichContent', () => {
  it('renders semantic Markdown without injecting source HTML', () => {
    const { container } = render(
      <RichContent text={'## Summary\n\n- **safe**\n- <img src=x onerror=alert(1)>\n\n`code`'} />
    );
    expect(screen.getByRole('heading', { name: 'Summary' })).toBeTruthy();
    expect(screen.getByText('safe').tagName).toBe('STRONG');
    expect(screen.getByText('<img src=x onerror=alert(1)>')).toBeTruthy();
    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('script')).toBeNull();
    expect(screen.getByText('code').tagName).toBe('CODE');
  });

  it('requires confirmation before activating a Hermes atom', async () => {
    const onOpenAtom = vi.fn();
    render(
      <RichContent
        text={'Open [session abc](burnbar://session?id=abc).'}
        onOpenAtom={onOpenAtom}
      />
    );
    fireEvent.click(screen.getByRole('button', { name: 'Session: session abc' }));
    expect(onOpenAtom).not.toHaveBeenCalled();
    expect(screen.getByRole('dialog', { name: 'Session detail' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Open session' }));
    await waitFor(() => expect(onOpenAtom).toHaveBeenCalledWith({ kind: 'session', id: 'abc' }));
  });

  it('opens only parser-approved external HTTPS links', async () => {
    const onOpenExternal = vi.fn(async () => undefined);
    render(
      <RichContent
        text={'[Docs](https://example.com/docs) [Local](https://localhost/private)'}
        onOpenExternal={onOpenExternal}
      />
    );
    fireEvent.click(screen.getByRole('button', { name: /Docs/u }));
    await waitFor(() => expect(onOpenExternal).toHaveBeenCalledWith('https://example.com/docs'));
    expect(screen.queryByRole('button', { name: /Local/u })).toBeNull();
    expect(screen.getByText(/\[Local\]\(https:\/\/localhost\/private\)/u)).toBeTruthy();
  });

  it('surfaces link-opening failures in the same content region', async () => {
    render(
      <RichContent
        text={'[Docs](https://example.com/docs)'}
        onOpenExternal={async () => {
          throw new Error('Native opener unavailable.');
        }}
      />
    );
    fireEvent.click(screen.getByRole('button', { name: /Docs/u }));
    expect((await screen.findByRole('alert')).textContent).toContain('Native opener unavailable.');
  });

  it('limits huge messages until the user explicitly expands them', () => {
    const text = `Start ${'x'.repeat(4_100)}`;
    render(<RichContent text={text} />);
    const expand = screen.getByRole('button', { name: /Show full message/u });
    expect(expand).toBeTruthy();
    fireEvent.click(expand);
    expect(screen.queryByRole('button', { name: /Show full message/u })).toBeNull();
    expect(screen.getByText(text)).toBeTruthy();
  });

  it('keeps user-authored plain text verbatim', () => {
    render(<RichContent text={'**do not style**\n- literal'} preservePlainText />);
    expect(screen.getByText('**do not style** - literal')).toBeTruthy();
    expect(screen.queryByText('do not style', { selector: 'strong' })).toBeNull();
  });
});
