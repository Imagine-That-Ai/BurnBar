import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { writeTextExpansionConsent } from '../../textExpansionConsent.js';
import { upsertSnippet } from '../../textExpansionStore.js';
import { TextExpansionSurface } from '../TextExpansionSurface.js';

beforeEach(() => {
  localStorage.clear();
  writeTextExpansionConsent({ inAppOnly: true, declinedGlobalCapture: true });
});

afterEach(cleanup);

describe('TextExpansionSurface P14', () => {
  it('shows live preview expansion with polite announcement region', () => {
    upsertSnippet({ title: 'Sig', trigger: ';;sig', body: '-- OB', enabled: true });
    const { container } = render(<TextExpansionSurface />);
    const textarea = container.querySelector('.te-preview-input') as HTMLTextAreaElement;
    fireEvent.change(textarea, { target: { value: 'hi ;;sig' } });
    const output = container.querySelector('.te-preview-output') as HTMLElement;
    expect(output.getAttribute('aria-live')).toBe('polite');
    expect(within(output).getByText('-- OB')).toBeTruthy();
  });

  it('blocks save on exact trigger duplicate', () => {
    upsertSnippet({ title: 'Existing', trigger: ';;dup', body: 'X', enabled: true });
    const { container } = render(<TextExpansionSurface />);
    fireEvent.change(container.querySelector('input[name="trigger"]') as HTMLInputElement, {
      target: { value: ';;dup' }
    });
    expect(screen.getByText(/already uses this trigger/i)).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Add snippet' })).toHaveProperty('disabled', true);
  });

  it('shows empty list copy without placeholder li rows', () => {
    const { container } = render(<TextExpansionSurface />);
    expect(screen.getByText(/No snippets yet/)).toBeTruthy();
    expect(container.querySelectorAll('.snippet-list li')).toHaveLength(0);
  });

  it('reports import success and rejects malformed JSON', async () => {
    const { container } = render(<TextExpansionSurface />);
    const fileInput = container.querySelector('.te-import-file') as HTMLInputElement;
    const attachFile = (file: File) => {
      const list = [file] as unknown as FileList;
      Object.defineProperty(list, 'length', { value: 1 });
      Object.defineProperty(list, 'item', { value: (i: number) => (i === 0 ? file : null) });
      Object.defineProperty(fileInput, 'files', { value: list, configurable: true });
    };
    const readFile = (file: File) => {
      let resolveFn!: () => void;
      const promise = new Promise<void>((r) => { resolveFn = r; });
      attachFile(file);
      fireEvent.change(fileInput);
      queueMicrotask(resolveFn);
      return promise;
    };
    const good = new File(
      [JSON.stringify([{ title: 'Imp', trigger: ';;imp', body: 'I', enabled: true }])],
      'snippets.json',
      { type: 'application/json' }
    );
    await readFile(good);
    await waitFor(() => {
      expect(screen.getByText(/Import complete: 1 added, 0 skipped/)).toBeTruthy();
    });

    const bad = new File(['{'], 'bad.json', { type: 'application/json' });
    await readFile(bad);
    await waitFor(() => {
      expect(screen.getByText(/Invalid JSON/i)).toBeTruthy();
    });
  });

  it('renders parity ledger substitution when present', () => {
    render(<TextExpansionSurface />);
    expect(screen.getByText(/Live buffer probe/)).toBeTruthy();
  });
});