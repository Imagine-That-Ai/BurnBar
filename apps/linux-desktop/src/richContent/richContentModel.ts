export const RICH_CONTENT_VISIBLE_CHARACTER_LIMIT = 4_000;
export const RICH_CONTENT_MAX_SOURCE_CHARACTERS = 200_000;

const MAX_INLINE_LINE_CHARACTERS = 8_192;
const MAX_INLINE_DELIMITER_CANDIDATES = 512;
const MAX_INLINE_NESTING_DEPTH = 8;
const MAX_BLOCKS = 2_000;
const MAX_LINK_CHARACTERS = 2_048;

const KNOWN_MODEL_IDS = [
  'claude-sonnet-4.7',
  'claude-sonnet-4.6',
  'claude-sonnet-4.5',
  'claude-opus-4.7',
  'claude-opus-4.6',
  'claude-haiku-4.7',
  'gpt-5.5',
  'gpt-5',
  'gpt-4.6',
  'gpt-4o',
  'gpt-4o-mini',
  'o1-preview',
  'o1-mini',
  'minimax-m2.7',
  'minimax-m2',
  'kimi-k1.7',
  'kimi-k1.5',
  'glm-5',
  'glm-4.6',
  'deepseek-v3.5',
  'gemini-3-pro',
  'gemini-3-flash'
] as const;

export type RichInlineStyle = {
  bold?: boolean;
  italic?: boolean;
  strikethrough?: boolean;
};

export type HermesAtomWindow = 'today' | 'yesterday' | '7d' | '30d' | '90d' | 'all';
export type HermesAtomTokenScope = 'today' | 'session' | 'run' | 'lifetime' | 'unspecified';

export type HermesAtom =
  | { kind: 'cost'; amount: number; window: HermesAtomWindow }
  | { kind: 'session'; id: string }
  | { kind: 'provider'; token: string }
  | { kind: 'model'; id: string }
  | { kind: 'window'; window: HermesAtomWindow }
  | { kind: 'tool'; name: string }
  | { kind: 'project'; id: string }
  | { kind: 'tokens'; value: number; scope: HermesAtomTokenScope }
  | { kind: 'quota'; provider: string; percent: number }
  | { kind: 'runtime'; profile: string };

export type RichInlineRun =
  | { kind: 'text'; text: string; style: RichInlineStyle }
  | { kind: 'code'; text: string }
  | { kind: 'mention'; handle: string }
  | { kind: 'atom'; atom: HermesAtom; label: string }
  | { kind: 'link'; label: RichInlineRun[]; url: string }
  | { kind: 'break' };

export type RichListItem = {
  depth: number;
  runs: RichInlineRun[];
};

export type RichTable = {
  alignments: Array<'left' | 'center' | 'right' | null>;
  header: RichInlineRun[][];
  rows: RichInlineRun[][][];
};

export type RichBlock =
  | { kind: 'paragraph'; runs: RichInlineRun[] }
  | { kind: 'heading'; level: 1 | 2 | 3 | 4 | 5 | 6; runs: RichInlineRun[] }
  | { kind: 'list'; ordered: boolean; start: number; items: RichListItem[] }
  | { kind: 'quote'; blocks: RichBlock[] }
  | { kind: 'code'; language: string | null; text: string }
  | { kind: 'table'; table: RichTable }
  | { kind: 'rule' };

export type RichContentDocument = {
  blocks: RichBlock[];
  sourceCharacterCount: number;
  parserLimited: boolean;
};

type MutableTextRun = Extract<RichInlineRun, { kind: 'text' }>;

function sameStyle(a: RichInlineStyle, b: RichInlineStyle): boolean {
  return Boolean(a.bold) === Boolean(b.bold)
    && Boolean(a.italic) === Boolean(b.italic)
    && Boolean(a.strikethrough) === Boolean(b.strikethrough);
}

function mergeStyle(base: RichInlineStyle, added: RichInlineStyle): RichInlineStyle {
  return {
    bold: Boolean(base.bold || added.bold) || undefined,
    italic: Boolean(base.italic || added.italic) || undefined,
    strikethrough: Boolean(base.strikethrough || added.strikethrough) || undefined
  };
}

function appendRun(target: RichInlineRun[], run: RichInlineRun): void {
  if (run.kind === 'text' && !run.text) return;
  const previous = target[target.length - 1];
  if (run.kind === 'text' && previous?.kind === 'text' && sameStyle(previous.style, run.style)) {
    (previous as MutableTextRun).text += run.text;
    return;
  }
  target.push(run);
}

function containsControlCharacter(value: string): boolean {
  return Array.from(value).some((character) => {
    const point = character.codePointAt(0) ?? 0;
    return point <= 0x1f || (point >= 0x7f && point <= 0x9f) || point === 0xfffd;
  });
}

function uniqueQueryParams(url: URL): Map<string, string> | null {
  const params = new Map<string, string>();
  for (const [rawName, value] of url.searchParams.entries()) {
    const name = rawName.toLowerCase();
    if (params.has(name)) return null;
    params.set(name, value);
  }
  return params;
}

function boundedOpaqueValue(value: string | undefined): string | null {
  if (!value || value !== value.trim() || value.length > 4_096 || containsControlCharacter(value)) {
    return null;
  }
  return value;
}

function isWindow(value: string | undefined): value is HermesAtomWindow {
  return value === 'today'
    || value === 'yesterday'
    || value === '7d'
    || value === '30d'
    || value === '90d'
    || value === 'all';
}

function isTokenScope(value: string | undefined): value is HermesAtomTokenScope {
  return value === 'today'
    || value === 'session'
    || value === 'run'
    || value === 'lifetime'
    || value === 'unspecified';
}

export function decodeHermesAtomURL(value: string): HermesAtom | null {
  if (!value || value.length > MAX_LINK_CHARACTERS || containsControlCharacter(value)) return null;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (url.protocol.toLowerCase() !== 'burnbar:' || url.username || url.password || url.port) return null;
  const params = uniqueQueryParams(url);
  if (!params) return null;
  const host = url.hostname.toLowerCase();
  const get = (key: string) => params.get(key);
  switch (host) {
    case 'burn': {
      const rawWindow = get('window');
      const window = isWindow(rawWindow) ? rawWindow : 'today';
      const amount = Number(get('amount') ?? 0);
      return Number.isFinite(amount) ? { kind: 'cost', amount, window } : null;
    }
    case 'session': {
      const id = boundedOpaqueValue(get('id'));
      return id ? { kind: 'session', id } : null;
    }
    case 'provider': {
      const token = boundedOpaqueValue(get('token'));
      return token ? { kind: 'provider', token } : null;
    }
    case 'model': {
      const id = boundedOpaqueValue(get('id'));
      return id ? { kind: 'model', id } : null;
    }
    case 'window': {
      const window = get('value');
      return isWindow(window) ? { kind: 'window', window } : null;
    }
    case 'tool': {
      const name = boundedOpaqueValue(get('name'));
      return name ? { kind: 'tool', name } : null;
    }
    case 'project': {
      const id = boundedOpaqueValue(get('id'));
      return id ? { kind: 'project', id } : null;
    }
    case 'tokens': {
      const rawValue = get('value');
      if (!rawValue || !/^-?\d+$/u.test(rawValue)) return null;
      const numericValue = Number(rawValue);
      if (!Number.isSafeInteger(numericValue)) return null;
      const rawScope = get('scope');
      const scope = isTokenScope(rawScope) ? rawScope : 'unspecified';
      return { kind: 'tokens', value: numericValue, scope };
    }
    case 'quota': {
      const provider = boundedOpaqueValue(get('provider'));
      const rawPercent = get('percent');
      if (!provider || !rawPercent || !/^-?\d+$/u.test(rawPercent)) return null;
      const percent = Number(rawPercent);
      return Number.isSafeInteger(percent) ? { kind: 'quota', provider, percent } : null;
    }
    case 'runtime': {
      const profile = boundedOpaqueValue(get('profile'));
      return profile ? { kind: 'runtime', profile } : null;
    }
    default:
      return null;
  }
}

function isIPv4(host: string): boolean {
  const pieces = host.split('.');
  return pieces.length === 4 && pieces.every((piece) => {
    if (!/^\d{1,3}$/u.test(piece)) return false;
    const value = Number(piece);
    return value >= 0 && value <= 255;
  });
}

function isIPv6(host: string): boolean {
  return host.includes(':');
}

export function safeExternalURL(value: string): string | null {
  if (!value || value.length > MAX_LINK_CHARACTERS || containsControlCharacter(value)) return null;
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }
  if (
    url.protocol.toLowerCase() !== 'https:'
    || url.username
    || url.password
    || url.port
    || !url.hostname
  ) {
    return null;
  }
  const host = url.hostname.toLowerCase();
  if (
    host === 'localhost'
    || host.endsWith('.localhost')
    || isIPv4(host)
    || isIPv6(host)
  ) {
    return null;
  }
  return url.toString();
}

export function hermesAtomCategory(atom: HermesAtom): string {
  switch (atom.kind) {
    case 'cost': return 'Cost';
    case 'session': return 'Session';
    case 'provider': return 'Provider';
    case 'model': return 'Model';
    case 'window': return 'Window';
    case 'tool': return 'Tool';
    case 'project': return 'Project';
    case 'tokens': return 'Tokens';
    case 'quota': return 'Quota';
    case 'runtime': return 'Runtime';
  }
}

export function hermesAtomDescription(atom: HermesAtom): string {
  switch (atom.kind) {
    case 'cost': return 'Open the burn detail for this time window.';
    case 'session': return "Open this session's detail view.";
    case 'provider': return "Open this provider's dashboard.";
    case 'model': return "Open this model's detail or pick it as default.";
    case 'window': return 'Switch the dashboard to this time window.';
    case 'tool': return 'See where this tool was invoked in the run.';
    case 'project': return "Open this project's detail.";
    case 'tokens': return 'Open the token-usage detail.';
    case 'quota': return 'Open quota detail for this provider.';
    case 'runtime': return 'Open Hermes runtime details for this profile.';
  }
}

function displayWindow(window: HermesAtomWindow): string {
  switch (window) {
    case 'today': return 'today';
    case 'yesterday': return 'yesterday';
    case '7d': return '7 days';
    case '30d': return '30 days';
    case '90d': return '90 days';
    case 'all': return 'all time';
  }
}

function formatTokenCount(value: number): string {
  if (Math.abs(value) < 1_000) return String(value);
  if (Math.abs(value) < 1_000_000) return `${(value / 1_000).toFixed(1)}k`;
  if (Math.abs(value) >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)}B`;
  return `${(value / 1_000_000).toFixed(1)}M`;
}

export function hermesAtomFallbackLabel(atom: HermesAtom): string {
  switch (atom.kind) {
    case 'cost':
      return `${new Intl.NumberFormat(undefined, {
        style: 'currency',
        currency: 'USD',
        maximumFractionDigits: 2
      }).format(atom.amount)} ${displayWindow(atom.window)}`;
    case 'session': return `session ${atom.id.slice(0, 8)}`;
    case 'provider': return atom.token.charAt(0).toUpperCase() + atom.token.slice(1);
    case 'model': return atom.id;
    case 'window': return displayWindow(atom.window);
    case 'tool': return atom.name;
    case 'project': return atom.id;
    case 'tokens': {
      const scope = atom.scope === 'unspecified'
        ? ''
        : atom.scope === 'session'
          ? 'this session'
          : atom.scope === 'run'
            ? 'this run'
            : atom.scope;
      return `${formatTokenCount(atom.value)}${scope ? ` ${scope}` : ' tokens'}`;
    }
    case 'quota':
      return `${atom.percent}% ${atom.provider.charAt(0).toUpperCase()}${atom.provider.slice(1)}`;
    case 'runtime':
      return atom.profile.charAt(0).toUpperCase() + atom.profile.slice(1);
  }
}

export function hermesAtomActionLabel(atom: HermesAtom): string {
  switch (atom.kind) {
    case 'cost': return `Open ${displayWindow(atom.window)} burn`;
    case 'session': return 'Open session';
    case 'provider': return `Open ${atom.token}`;
    case 'model': return `Use ${atom.id}`;
    case 'window': return `Switch to ${displayWindow(atom.window)}`;
    case 'tool': return `Find ${atom.name} in run`;
    case 'project': return `Open project ${atom.id}`;
    case 'tokens': return 'Open token detail';
    case 'quota': return `Open ${atom.provider} quota`;
    case 'runtime': return `Open ${atom.profile} runtime`;
  }
}

function markerScanAllowed(source: string): boolean {
  if (source.length > MAX_INLINE_LINE_CHARACTERS) return false;
  let candidates = 0;
  for (const character of source) {
    if (character === '*' || character === '_' || character === '~') {
      candidates += 1;
      if (candidates > MAX_INLINE_DELIMITER_CANDIDATES) return false;
    }
  }
  return true;
}

function findClosingDelimiter(
  source: string,
  start: number,
  delimiter: string,
  length: number
): number {
  for (let index = start; index < source.length; index += 1) {
    if (source[index] !== delimiter) continue;
    let runLength = 0;
    while (source[index + runLength] === delimiter) runLength += 1;
    if (
      runLength >= length
      && index > start
      && !/\s/u.test(source[index - 1] ?? '')
    ) {
      return index;
    }
    index += Math.max(0, runLength - 1);
  }
  return -1;
}

function emphasisAt(
  source: string,
  index: number,
  previous: string | undefined
): { content: string; style: RichInlineStyle; end: number } | null {
  const delimiter = source[index];
  if (delimiter !== '*' && delimiter !== '_' && delimiter !== '~') return null;
  let length = 0;
  while (source[index + length] === delimiter) length += 1;
  let style: RichInlineStyle;
  if (delimiter === '~' && length === 2) style = { strikethrough: true };
  else if ((delimiter === '*' || delimiter === '_') && length === 1) style = { italic: true };
  else if ((delimiter === '*' || delimiter === '_') && length === 2) style = { bold: true };
  else if ((delimiter === '*' || delimiter === '_') && length === 3) style = { bold: true, italic: true };
  else return null;
  const contentStart = index + length;
  if (!source[contentStart] || /\s/u.test(source[contentStart])) return null;
  if (delimiter === '_' && previous && /[\p{L}\p{N}]/u.test(previous)) return null;
  const closing = findClosingDelimiter(source, contentStart, delimiter, length);
  if (closing < 0) return null;
  const closerEnd = closing + length;
  if (delimiter === '_' && source[closerEnd] && /[\p{L}\p{N}]/u.test(source[closerEnd])) return null;
  return {
    content: source.slice(contentStart, closing),
    style,
    end: closerEnd
  };
}

function markdownLinkAt(
  source: string,
  index: number
): { label: string; destination: string; end: number } | null {
  if (source[index] !== '[' || source[index - 1] === '\\') return null;
  let bracketDepth = 1;
  let cursor = index + 1;
  while (cursor < source.length) {
    const character = source[cursor];
    if (character === '\n') return null;
    if (character === '[') bracketDepth += 1;
    if (character === ']') {
      bracketDepth -= 1;
      if (bracketDepth === 0) break;
    }
    cursor += 1;
  }
  if (cursor >= source.length || source[cursor + 1] !== '(') return null;
  const label = source.slice(index + 1, cursor);
  const destinationStart = cursor + 2;
  let destinationEnd = destinationStart;
  while (destinationEnd < source.length && source[destinationEnd] !== ')') {
    if (source[destinationEnd] === '\n') return null;
    destinationEnd += 1;
  }
  if (destinationEnd >= source.length) return null;
  return {
    label,
    destination: source.slice(destinationStart, destinationEnd),
    end: destinationEnd + 1
  };
}

function inlineCodeAt(source: string, index: number): { text: string; end: number } | null {
  if (source[index] !== '`') return null;
  const closing = source.indexOf('`', index + 1);
  if (closing <= index + 1 || source.slice(index + 1, closing).includes('\n')) return null;
  return { text: source.slice(index + 1, closing), end: closing + 1 };
}

function mentionAt(source: string, index: number): { handle: string; end: number } | null {
  if (source[index] !== '@') return null;
  const previous = source[index - 1];
  if (previous && !/[\s([{\u2014]/u.test(previous)) return null;
  let cursor = index + 1;
  while (cursor < source.length && /[\p{L}\p{N}_.-]/u.test(source[cursor] ?? '')) cursor += 1;
  if (cursor === index + 1) return null;
  return { handle: source.slice(index, cursor), end: cursor };
}

function costAt(source: string, index: number): { atom: HermesAtom; label: string; end: number } | null {
  if (source[index] !== '$') return null;
  const match = source.slice(index).match(/^\$\d{1,3}(?:,\d{3})*(?:\.\d+)?/u);
  if (!match) return null;
  const amount = Number(match[0].slice(1).replaceAll(',', ''));
  if (!Number.isFinite(amount)) return null;
  return {
    atom: { kind: 'cost', amount, window: 'today' },
    label: match[0],
    end: index + match[0].length
  };
}

function modelAt(source: string, index: number): { atom: HermesAtom; label: string; end: number } | null {
  for (const model of KNOWN_MODEL_IDS) {
    if (!source.startsWith(model, index)) continue;
    const previous = source[index - 1];
    const next = source[index + model.length];
    if ((previous && /[\p{L}\p{N}_-]/u.test(previous)) || (next && /[\p{L}\p{N}_-]/u.test(next))) {
      continue;
    }
    return {
      atom: { kind: 'model', id: model },
      label: model,
      end: index + model.length
    };
  }
  return null;
}

export function parseRichInline(
  source: string,
  baseStyle: RichInlineStyle = {},
  depth = 0
): RichInlineRun[] {
  if (!source) return [];
  if (depth >= MAX_INLINE_NESTING_DEPTH || !markerScanAllowed(source)) {
    return [{ kind: 'text', text: source, style: baseStyle }];
  }
  const runs: RichInlineRun[] = [];
  let plain = '';
  const flush = () => {
    if (!plain) return;
    appendRun(runs, { kind: 'text', text: plain, style: baseStyle });
    plain = '';
  };
  let index = 0;
  while (index < source.length) {
    if (source[index] === '\\' && source[index + 1] && '\\`*_{}[]()#+-.!~|>'.includes(source[index + 1] ?? '')) {
      plain += source[index + 1];
      index += 2;
      continue;
    }
    const link = markdownLinkAt(source, index);
    if (link) {
      const atom = decodeHermesAtomURL(link.destination);
      const externalURL = safeExternalURL(link.destination);
      if (atom) {
        flush();
        runs.push({
          kind: 'atom',
          atom,
          label: link.label.trim() || hermesAtomFallbackLabel(atom)
        });
        index = link.end;
        continue;
      }
      if (externalURL) {
        flush();
        runs.push({
          kind: 'link',
          label: parseRichInline(link.label || externalURL, baseStyle, depth + 1),
          url: externalURL
        });
        index = link.end;
        continue;
      }
      plain += source.slice(index, link.end);
      index = link.end;
      continue;
    }
    const code = inlineCodeAt(source, index);
    if (code) {
      flush();
      runs.push({ kind: 'code', text: code.text });
      index = code.end;
      continue;
    }
    const mention = mentionAt(source, index);
    if (mention) {
      flush();
      runs.push({ kind: 'mention', handle: mention.handle });
      index = mention.end;
      continue;
    }
    const cost = costAt(source, index);
    if (cost) {
      flush();
      runs.push({ kind: 'atom', atom: cost.atom, label: cost.label });
      index = cost.end;
      continue;
    }
    const model = modelAt(source, index);
    if (model) {
      flush();
      runs.push({ kind: 'atom', atom: model.atom, label: model.label });
      index = model.end;
      continue;
    }
    const emphasis = emphasisAt(source, index, plain.at(-1));
    if (emphasis) {
      flush();
      const styled = parseRichInline(
        emphasis.content,
        mergeStyle(baseStyle, emphasis.style),
        depth + 1
      );
      for (const run of styled) appendRun(runs, run);
      index = emphasis.end;
      continue;
    }
    plain += source[index];
    index += 1;
  }
  flush();
  return runs;
}

function paragraphRuns(lines: string[]): RichInlineRun[] {
  const runs: RichInlineRun[] = [];
  lines.forEach((line, index) => {
    if (index > 0) runs.push({ kind: 'break' });
    for (const run of parseRichInline(line)) appendRun(runs, run);
  });
  return runs;
}

function splitTableRow(line: string): string[] {
  const trimmed = line.trim().replace(/^\|/u, '').replace(/\|$/u, '');
  const cells: string[] = [];
  let current = '';
  let escaped = false;
  for (const character of trimmed) {
    if (escaped) {
      current += character;
      escaped = false;
    } else if (character === '\\') {
      escaped = true;
    } else if (character === '|') {
      cells.push(current.trim());
      current = '';
    } else {
      current += character;
    }
  }
  cells.push(current.trim());
  return cells;
}

function tableAlignment(cell: string): 'left' | 'center' | 'right' | null {
  const trimmed = cell.trim();
  if (!/^:?-{3,}:?$/u.test(trimmed)) return null;
  if (trimmed.startsWith(':') && trimmed.endsWith(':')) return 'center';
  if (trimmed.endsWith(':')) return 'right';
  if (trimmed.startsWith(':')) return 'left';
  return null;
}

function isTableSeparator(line: string): boolean {
  const cells = splitTableRow(line);
  return cells.length > 0 && cells.every((cell) => /^:?-{3,}:?$/u.test(cell.trim()));
}

function isHorizontalRule(line: string): boolean {
  const trimmed = line.trim();
  return /^([-*_])(?:\s*\1){2,}$/u.test(trimmed);
}

type ListLine = {
  ordered: boolean;
  start: number;
  depth: number;
  body: string;
};

function parseListLine(line: string): ListLine | null {
  const match = line.match(/^([ \t]*)(?:(\d{1,9})[.)]|[-+*])\s+(.+)$/u);
  if (!match) return null;
  const indentation = (match[1] ?? '').replaceAll('\t', '    ').length;
  const ordered = Boolean(match[2]);
  return {
    ordered,
    start: ordered ? Number(match[2]) : 1,
    depth: Math.min(8, Math.floor(indentation / 2)),
    body: match[3] ?? ''
  };
}

function fencedCodeStart(line: string): { marker: string; language: string | null } | null {
  const match = line.match(/^\s*(`{3,}|~{3,})\s*([A-Za-z0-9_+.-]{0,64})\s*$/u);
  if (!match) return null;
  return {
    marker: match[1] ?? '```',
    language: match[2]?.trim() || null
  };
}

function startsNewBlock(lines: string[], index: number): boolean {
  const line = lines[index] ?? '';
  if (!line.trim()) return true;
  if (/^#{1,6}\s+/u.test(line)) return true;
  if (parseListLine(line)) return true;
  if (/^\s*>\s?/u.test(line)) return true;
  if (fencedCodeStart(line)) return true;
  if (isHorizontalRule(line)) return true;
  return line.includes('|') && isTableSeparator(lines[index + 1] ?? '');
}

function parseBlocks(lines: string[], startingBlockCount = 0): RichBlock[] {
  const blocks: RichBlock[] = [];
  let index = 0;
  while (index < lines.length && startingBlockCount + blocks.length < MAX_BLOCKS) {
    const line = lines[index] ?? '';
    if (!line.trim()) {
      index += 1;
      continue;
    }
    const fence = fencedCodeStart(line);
    if (fence) {
      const code: string[] = [];
      index += 1;
      while (index < lines.length) {
        const candidate = lines[index] ?? '';
        const closePattern = new RegExp(`^\\s*${fence.marker[0]}{${fence.marker.length},}\\s*$`, 'u');
        if (closePattern.test(candidate)) {
          index += 1;
          break;
        }
        code.push(candidate);
        index += 1;
      }
      blocks.push({ kind: 'code', language: fence.language, text: code.join('\n') });
      continue;
    }
    const heading = line.match(/^(#{1,6})\s+(.+)$/u);
    if (heading) {
      blocks.push({
        kind: 'heading',
        level: heading[1]?.length as 1 | 2 | 3 | 4 | 5 | 6,
        runs: parseRichInline((heading[2] ?? '').trim())
      });
      index += 1;
      continue;
    }
    if (isHorizontalRule(line)) {
      blocks.push({ kind: 'rule' });
      index += 1;
      continue;
    }
    if (line.includes('|') && isTableSeparator(lines[index + 1] ?? '')) {
      const headerCells = splitTableRow(line);
      const alignmentCells = splitTableRow(lines[index + 1] ?? '');
      const width = Math.max(headerCells.length, alignmentCells.length);
      const rows: RichInlineRun[][][] = [];
      index += 2;
      while (index < lines.length && (lines[index] ?? '').includes('|') && (lines[index] ?? '').trim()) {
        const cells = splitTableRow(lines[index] ?? '');
        rows.push(Array.from({ length: width }, (_, cellIndex) => parseRichInline(cells[cellIndex] ?? '')));
        index += 1;
      }
      blocks.push({
        kind: 'table',
        table: {
          alignments: Array.from({ length: width }, (_, cellIndex) =>
            tableAlignment(alignmentCells[cellIndex] ?? '')
          ),
          header: Array.from({ length: width }, (_, cellIndex) =>
            parseRichInline(headerCells[cellIndex] ?? '')
          ),
          rows
        }
      });
      continue;
    }
    const firstListLine = parseListLine(line);
    if (firstListLine) {
      const items: RichListItem[] = [];
      const ordered = firstListLine.ordered;
      const start = firstListLine.start;
      while (index < lines.length) {
        const item = parseListLine(lines[index] ?? '');
        if (!item || item.ordered !== ordered) break;
        items.push({ depth: item.depth, runs: parseRichInline(item.body) });
        index += 1;
      }
      blocks.push({ kind: 'list', ordered, start, items });
      continue;
    }
    if (/^\s*>\s?/u.test(line)) {
      const quotedLines: string[] = [];
      while (index < lines.length) {
        const match = (lines[index] ?? '').match(/^\s*>\s?(.*)$/u);
        if (!match) break;
        quotedLines.push(match[1] ?? '');
        index += 1;
      }
      blocks.push({
        kind: 'quote',
        blocks: parseBlocks(quotedLines, startingBlockCount + blocks.length)
      });
      continue;
    }
    const paragraph: string[] = [line];
    index += 1;
    while (index < lines.length && !startsNewBlock(lines, index)) {
      paragraph.push(lines[index] ?? '');
      index += 1;
    }
    blocks.push({ kind: 'paragraph', runs: paragraphRuns(paragraph) });
  }
  return blocks;
}

export function parseRichContent(source: string): RichContentDocument {
  const normalized = source.replace(/\r\n?/gu, '\n');
  const parserLimited = normalized.length > RICH_CONTENT_MAX_SOURCE_CHARACTERS;
  const bounded = parserLimited
    ? normalized.slice(0, RICH_CONTENT_MAX_SOURCE_CHARACTERS)
    : normalized;
  return {
    blocks: parseBlocks(bounded.split('\n')),
    sourceCharacterCount: normalized.length,
    parserLimited
  };
}

export function richContentPlainText(source: string): string {
  const document = parseRichContent(source);
  const inline = (runs: RichInlineRun[]): string => runs.map((run) => {
    switch (run.kind) {
      case 'text': return run.text;
      case 'code': return run.text;
      case 'mention': return run.handle;
      case 'atom': return run.label;
      case 'link': return inline(run.label);
      case 'break': return '\n';
    }
  }).join('');
  return document.blocks.map((block) => {
    switch (block.kind) {
      case 'paragraph': return inline(block.runs);
      case 'heading': return inline(block.runs);
      case 'list': return block.items.map((item) => `• ${inline(item.runs)}`).join('\n');
      case 'quote': return block.blocks.map((nested) => {
        if (nested.kind === 'paragraph' || nested.kind === 'heading') return inline(nested.runs);
        return '';
      }).filter(Boolean).join('\n');
      case 'code': return block.text;
      case 'table': return [
        block.table.header.map(inline).join(' | '),
        ...block.table.rows.map((row) => row.map(inline).join(' | '))
      ].join('\n');
      case 'rule': return '---';
    }
  }).join('\n');
}
