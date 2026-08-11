import { describe, expect, it } from 'vitest';
import {
  decodeHermesAtomURL,
  parseRichContent,
  parseRichInline,
  richContentPlainText,
  safeExternalURL
} from './richContentModel.js';

describe('Linux rich-content parser', () => {
  it('matches the macOS Hermes inline emphasis contract', () => {
    expect(parseRichInline('This is **important** and *nested* with ~~old~~.')).toEqual([
      { kind: 'text', text: 'This is ', style: {} },
      { kind: 'text', text: 'important', style: { bold: true, italic: undefined, strikethrough: undefined } },
      { kind: 'text', text: ' and ', style: {} },
      { kind: 'text', text: 'nested', style: { bold: undefined, italic: true, strikethrough: undefined } },
      { kind: 'text', text: ' with ', style: {} },
      { kind: 'text', text: 'old', style: { bold: undefined, italic: undefined, strikethrough: true } },
      { kind: 'text', text: '.', style: {} }
    ]);
  });

  it('combines nested bold and italic styles without exposing markers', () => {
    expect(parseRichInline('**bold with *nested* inside**')).toEqual([
      {
        kind: 'text',
        text: 'bold with ',
        style: { bold: true, italic: undefined, strikethrough: undefined }
      },
      {
        kind: 'text',
        text: 'nested',
        style: { bold: true, italic: true, strikethrough: undefined }
      },
      {
        kind: 'text',
        text: ' inside',
        style: { bold: true, italic: undefined, strikethrough: undefined }
      }
    ]);
  });

  it('keeps snake_case and unmatched or mathematical markers literal', () => {
    expect(richContentPlainText('use snake_case_name and 2 * 3 * 4')).toBe(
      'use snake_case_name and 2 * 3 * 4'
    );
    expect(richContentPlainText('a ** b stays literal')).toBe('a ** b stays literal');
  });

  it('falls back to literal text for adversarial marker-heavy lines', () => {
    const source = '*a'.repeat(600);
    expect(parseRichInline(source)).toEqual([{ kind: 'text', text: source, style: {} }]);
  });

  it('parses mentions but does not split email addresses', () => {
    expect(parseRichInline('Ping @maya now.')).toEqual([
      { kind: 'text', text: 'Ping ', style: {} },
      { kind: 'mention', handle: '@maya' },
      { kind: 'text', text: ' now.', style: {} }
    ]);
    expect(parseRichInline('Email maya@example.com.').some((run) => run.kind === 'mention')).toBe(false);
  });

  it('keeps inline code atomic and does not parse markdown inside it', () => {
    expect(parseRichInline('Run `**git status**` now.')).toEqual([
      { kind: 'text', text: 'Run ', style: {} },
      { kind: 'code', text: '**git status**' },
      { kind: 'text', text: ' now.', style: {} }
    ]);
  });

  it('decodes all canonical Hermes atom URL families', () => {
    expect(decodeHermesAtomURL('burnbar://burn?window=7d&amount=2.34')).toEqual({
      kind: 'cost',
      amount: 2.34,
      window: '7d'
    });
    expect(decodeHermesAtomURL('burnbar://session?id=abc-123')).toEqual({ kind: 'session', id: 'abc-123' });
    expect(decodeHermesAtomURL('burnbar://provider?token=anthropic')).toEqual({ kind: 'provider', token: 'anthropic' });
    expect(decodeHermesAtomURL('burnbar://model?id=gpt-5.5')).toEqual({ kind: 'model', id: 'gpt-5.5' });
    expect(decodeHermesAtomURL('burnbar://window?value=30d')).toEqual({ kind: 'window', window: '30d' });
    expect(decodeHermesAtomURL('burnbar://tool?name=ReadFile')).toEqual({ kind: 'tool', name: 'ReadFile' });
    expect(decodeHermesAtomURL('burnbar://project?id=BurnBar')).toEqual({ kind: 'project', id: 'BurnBar' });
    expect(decodeHermesAtomURL('burnbar://tokens?value=12400&scope=session')).toEqual({
      kind: 'tokens',
      value: 12_400,
      scope: 'session'
    });
    expect(decodeHermesAtomURL('burnbar://quota?provider=anthropic&percent=78')).toEqual({
      kind: 'quota',
      provider: 'anthropic',
      percent: 78
    });
    expect(decodeHermesAtomURL('burnbar://runtime?profile=hermes')).toEqual({
      kind: 'runtime',
      profile: 'hermes'
    });
  });

  it('rejects ambiguous, foreign, credentialed, and malformed atom URLs', () => {
    expect(decodeHermesAtomURL('burnbar://session?id=abc&id=def')).toBeNull();
    expect(decodeHermesAtomURL('burnbar://session?id=abc&ID=def')).toBeNull();
    expect(decodeHermesAtomURL('burnbar://session')).toBeNull();
    expect(decodeHermesAtomURL('https://example.com/?id=abc')).toBeNull();
    expect(decodeHermesAtomURL('burnbar://user:secret@session?id=abc')).toBeNull();
  });

  it('preserves malformed atom links literally instead of parsing their internals', () => {
    const source = 'See [session $2.34](burnbar://session?id=abc&id=def) here.';
    const runs = parseRichInline(source);
    expect(runs).toEqual([{ kind: 'text', text: source, style: {} }]);
  });

  it('parses canonical atom links, cost prose, and known model IDs in order', () => {
    const runs = parseRichInline(
      'Hi @maya — open [$2.34 today](burnbar://burn?window=today&amount=2.34), then use gpt-5.5.'
    );
    expect(runs.map((run) => run.kind)).toEqual([
      'text',
      'mention',
      'text',
      'atom',
      'text',
      'atom',
      'text'
    ]);
  });

  it('allows only remote credential-free default-port HTTPS links', () => {
    expect(safeExternalURL('https://example.com/docs')).toBe('https://example.com/docs');
    expect(safeExternalURL('http://example.com/docs')).toBeNull();
    expect(safeExternalURL('https://user:secret@example.com/docs')).toBeNull();
    expect(safeExternalURL('https://example.com:8443/docs')).toBeNull();
    expect(safeExternalURL('https://localhost/docs')).toBeNull();
    expect(safeExternalURL('https://127.0.0.1/docs')).toBeNull();
    expect(safeExternalURL('file:///etc/passwd')).toBeNull();
    expect(safeExternalURL('javascript:alert(1)')).toBeNull();
  });

  it('parses semantic headings, paragraphs, lists, quotes, code, tables, and rules', () => {
    const document = parseRichContent([
      '# Heading',
      '',
      'Paragraph with **weight**.',
      '',
      '- one',
      '  - nested',
      '',
      '> quoted',
      '',
      '```ts',
      'const value = 1;',
      '```',
      '',
      '| Name | Value |',
      '| :--- | ---: |',
      '| alpha | 1 |',
      '',
      '---'
    ].join('\n'));

    expect(document.blocks.map((block) => block.kind)).toEqual([
      'heading',
      'paragraph',
      'list',
      'quote',
      'code',
      'table',
      'rule'
    ]);
    expect(document.blocks[2]).toMatchObject({
      kind: 'list',
      ordered: false,
      items: [{ depth: 0 }, { depth: 1 }]
    });
    expect(document.blocks[4]).toEqual({
      kind: 'code',
      language: 'ts',
      text: 'const value = 1;'
    });
    expect(document.blocks[5]).toMatchObject({
      kind: 'table',
      table: { alignments: ['left', 'right'] }
    });
  });

  it('normalizes CRLF and keeps hostile HTML as inert text', () => {
    const source = '<img src=x onerror=alert(1)>\r\n<script>alert(1)</script>';
    expect(richContentPlainText(source)).toBe(
      '<img src=x onerror=alert(1)>\n<script>alert(1)</script>'
    );
  });

  it('caps parser input without claiming the hidden tail was rendered', () => {
    const source = `# head\n${'x'.repeat(200_100)}`;
    const document = parseRichContent(source);
    expect(document.parserLimited).toBe(true);
    expect(document.sourceCharacterCount).toBe(source.length);
  });
});
