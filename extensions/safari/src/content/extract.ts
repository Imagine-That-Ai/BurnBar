import { boxAnnotation, isBoxInViewport, rectToBoundingBox, viewportInfo } from './boxes';
import { selectorForElement, snapshotRegistry, type SelectorGenerationCache } from './snapshot';
import type { ExtractedPageContext, SnapshotNode } from '../shared/protocol';
import { currentPageState } from './verification';

const MAX_MARKDOWN_CHARACTERS = 36_000;
const MAX_SNAPSHOT_NODES = 300;
const MAX_TEXT_PER_BLOCK = 1_200;

const INTERACTIVE_SELECTOR = [
  'a[href]',
  'button',
  'input',
  'textarea',
  'select',
  'summary',
  '[contenteditable="true"]',
  '[role]',
  '[tabindex]'
].join(',');

const BLOCK_TAGS = new Set([
  'ARTICLE',
  'BLOCKQUOTE',
  'DD',
  'DT',
  'FIGCAPTION',
  'H1',
  'H2',
  'H3',
  'H4',
  'H5',
  'H6',
  'LI',
  'MAIN',
  'P',
  'PRE',
  'TD',
  'TH'
]);

const SENSITIVE_AUTOCOMPLETE = new Set([
  'cc-csc',
  'cc-exp',
  'cc-exp-month',
  'cc-exp-year',
  'cc-number',
  'current-password',
  'new-password',
  'one-time-code'
]);

function normalizeText(value: string | null | undefined, limit = MAX_TEXT_PER_BLOCK): string {
  return (value ?? '').replace(/\s+/gu, ' ').trim().slice(0, limit);
}

function visibleTextContent(
  element: Element,
  visibilityCache: WeakMap<Element, boolean>,
  limit = MAX_TEXT_PER_BLOCK
): string {
  const parts: string[] = [];
  let length = 0;
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let current = walker.nextNode();
  while (current && length < limit) {
    const parent = current.parentElement;
    if (parent && isElementVisible(parent, visibilityCache)) {
      const text = normalizeText(current.textContent, limit - length);
      if (text) {
        parts.push(text);
        length += text.length + 1;
      }
    }
    current = walker.nextNode();
  }
  return normalizeText(parts.join(' '), limit);
}

function isElementVisible(element: Element, visibilityCache?: WeakMap<Element, boolean>): boolean {
  const cached = visibilityCache?.get(element);
  if (cached !== undefined) {
    return cached;
  }
  let visible = true;
  if (element.closest('[hidden], [aria-hidden="true"], script, style, template, noscript')) {
    visible = false;
  } else {
    const style = window.getComputedStyle(element);
    if (style.display === 'none' || style.visibility === 'hidden' || Number.parseFloat(style.opacity) === 0) {
      visible = false;
    } else {
      const rect = element.getBoundingClientRect();
      visible = rect.width > 0 && rect.height > 0;
    }
  }
  visibilityCache?.set(element, visible);
  return visible;
}

function implicitRole(element: Element): string {
  const explicit = element.getAttribute('role')?.trim();
  if (explicit) {
    return explicit;
  }
  switch (element.localName) {
    case 'a':
      return element.hasAttribute('href') ? 'link' : 'generic';
    case 'button':
      return 'button';
    case 'textarea':
      return 'textbox';
    case 'select':
      return element.hasAttribute('multiple') ? 'listbox' : 'combobox';
    case 'summary':
      return 'button';
    case 'img':
      return 'img';
    case 'input': {
      const type = (element.getAttribute('type') ?? 'text').toLowerCase();
      if (type === 'checkbox') {
        return 'checkbox';
      }
      if (type === 'radio') {
        return 'radio';
      }
      if (type === 'range') {
        return 'slider';
      }
      if (['button', 'reset', 'submit'].includes(type)) {
        return 'button';
      }
      return 'textbox';
    }
    default:
      return element.localName;
  }
}

function accessibleName(element: Element): string {
  const labelledBy = element.getAttribute('aria-labelledby');
  if (labelledBy) {
    const text = labelledBy
      .split(/\s+/u)
      .map((id) => document.getElementById(id)?.textContent)
      .filter(Boolean)
      .join(' ');
    if (normalizeText(text)) {
      return normalizeText(text, 320);
    }
  }
  const ariaLabel = normalizeText(element.getAttribute('aria-label'), 320);
  if (ariaLabel) {
    return ariaLabel;
  }
  if (element instanceof HTMLInputElement) {
    const label = element.labels?.[0];
    const labelText = normalizeText(label?.textContent, 320);
    if (labelText) {
      return labelText;
    }
    return normalizeText(element.placeholder || element.name || element.type, 320);
  }
  if (element instanceof HTMLTextAreaElement) {
    return normalizeText(element.labels?.[0]?.textContent || element.placeholder || element.name, 320);
  }
  if (element instanceof HTMLImageElement) {
    return normalizeText(element.alt || element.title, 320);
  }
  return normalizeText(element.textContent || element.getAttribute('title'), 320);
}

export function isSensitiveControl(element: Element): boolean {
  if (element instanceof HTMLInputElement) {
    if (element.type === 'password') {
      return true;
    }
    const autocomplete = element.autocomplete.toLowerCase();
    if (SENSITIVE_AUTOCOMPLETE.has(autocomplete)) {
      return true;
    }
    const fingerprint = `${element.name} ${element.id} ${element.placeholder}`.toLowerCase();
    return /(password|passcode|credit.?card|card.?number|cvv|cvc|security.?code|one.?time.?code|otp)/u.test(
      fingerprint
    );
  }
  return false;
}

function pageLooksSensitive(url: string): boolean {
  if (/(?:^|[./_-])(bank|billing|checkout|credential|login|oauth|payment|signin)(?:[./_?&=-]|$)/iu.test(url)) {
    return true;
  }
  return Array.from(document.querySelectorAll('input')).some((element) => isSensitiveControl(element));
}

function snapshotNode(
  element: Element,
  viewport: ReturnType<typeof viewportInfo>,
  visibilityCache: WeakMap<Element, boolean>,
  selectorCache: SelectorGenerationCache
): SnapshotNode | undefined {
  if (!isElementVisible(element, visibilityCache)) {
    return undefined;
  }
  const box = rectToBoundingBox(element.getBoundingClientRect());
  if (!isBoxInViewport(box, viewport)) {
    return undefined;
  }
  const ref = snapshotRegistry.register(element);
  const role = implicitRole(element);
  const name = accessibleName(element);
  const description = normalizeText(element.getAttribute('aria-description') || element.getAttribute('title'), 320);
  const sensitive = isSensitiveControl(element);

  const node: SnapshotNode = {
    ref,
    role,
    name,
    selector: selectorForElement(element, selectorCache),
    box,
    ...(description ? { description } : {}),
    ...(sensitive ? { sensitive: true } : {}),
    ...(element.matches(':disabled') ? { disabled: true } : {}),
    ...(element.getAttribute('aria-expanded') === 'true' ? { expanded: true } : {}),
    ...(document.activeElement === element ? { focused: true } : {})
  };

  if (element instanceof HTMLInputElement) {
    if (element.type === 'checkbox' || element.type === 'radio') {
      node.checked = element.checked;
    }
    if (!sensitive && ['button', 'reset', 'submit'].includes(element.type)) {
      node.value = normalizeText(element.value, 320);
    }
  } else if (element instanceof HTMLOptionElement) {
    node.selected = element.selected;
  } else if (element instanceof HTMLSelectElement) {
    node.value = Array.from(element.selectedOptions)
      .map((option) => normalizeText(option.textContent, 160))
      .filter(Boolean)
      .join(', ');
  }
  return node;
}

function snapshotLine(node: SnapshotNode): string {
  const fields = [
    `[ref=${node.ref}]`,
    `[role=${node.role}]`,
    `[name=${JSON.stringify(node.name)}]`,
    node.box ? boxAnnotation(node.box) : '',
    node.disabled ? '[disabled=true]' : '',
    node.checked === undefined ? '' : `[checked=${String(node.checked)}]`,
    node.expanded === undefined ? '' : `[expanded=${String(node.expanded)}]`,
    node.focused ? '[focused=true]' : '',
    node.sensitive ? '[sensitive=redacted]' : ''
  ].filter(Boolean);
  return fields.join(' ');
}

function safeLinkDestination(element: HTMLAnchorElement): string {
  try {
    const url = new URL(element.href, document.baseURI);
    if (!['http:', 'https:'].includes(url.protocol)) {
      return '';
    }
    return `${url.origin}${url.pathname}`;
  } catch {
    return '';
  }
}

function markdownForElement(element: Element, visibilityCache: WeakMap<Element, boolean>): string {
  const text = visibleTextContent(element, visibilityCache);
  if (!text) {
    return '';
  }
  switch (element.localName) {
    case 'h1':
      return `# ${text}`;
    case 'h2':
      return `## ${text}`;
    case 'h3':
      return `### ${text}`;
    case 'h4':
      return `#### ${text}`;
    case 'h5':
      return `##### ${text}`;
    case 'h6':
      return `###### ${text}`;
    case 'li':
      return `- ${text}`;
    case 'blockquote':
      return `> ${text}`;
    case 'pre':
      return `\`\`\`\n${element.textContent?.slice(0, MAX_TEXT_PER_BLOCK) ?? ''}\n\`\`\``;
    case 'td':
    case 'th':
      return `| ${text} |`;
    default:
      return text;
  }
}

function extractReadableMarkdown(visibilityCache: WeakMap<Element, boolean>): {
  markdown: string;
  truncated: boolean;
} {
  const main = document.querySelector('main, article, [role="main"]') ?? document.body ?? document.documentElement;
  const blocks: string[] = [];
  const seen = new Set<string>();
  const walker = document.createTreeWalker(main, NodeFilter.SHOW_ELEMENT);
  let current: Node | null = walker.currentNode;
  let length = 0;
  let truncated = false;

  while (current) {
    if (current instanceof Element && BLOCK_TAGS.has(current.tagName) && isElementVisible(current, visibilityCache)) {
      const markdown = markdownForElement(current, visibilityCache);
      if (markdown && !seen.has(markdown)) {
        if (length + markdown.length > MAX_MARKDOWN_CHARACTERS) {
          truncated = true;
          break;
        }
        blocks.push(markdown);
        seen.add(markdown);
        length += markdown.length + 2;
      }
    }
    current = walker.nextNode();
  }

  for (const anchor of Array.from(main.querySelectorAll<HTMLAnchorElement>('a[href]')).slice(0, 80)) {
    const name = accessibleName(anchor);
    const destination = safeLinkDestination(anchor);
    const line = name && destination ? `[${name}](${destination})` : '';
    if (line && !seen.has(line) && length + line.length <= MAX_MARKDOWN_CHARACTERS) {
      blocks.push(line);
      seen.add(line);
      length += line.length + 2;
    }
  }

  return {
    markdown: blocks.join('\n\n'),
    truncated
  };
}

export function extractPageContext(now: () => Date = () => new Date()): ExtractedPageContext {
  snapshotRegistry.reset();
  const viewport = viewportInfo();
  const visibilityCache = new WeakMap<Element, boolean>();
  const selectorCache: SelectorGenerationCache = new WeakMap();
  const candidates = Array.from(document.querySelectorAll(INTERACTIVE_SELECTOR)).slice(0, MAX_SNAPSHOT_NODES * 2);
  const nodes: SnapshotNode[] = [];
  for (const element of candidates) {
    const node = snapshotNode(element, viewport, visibilityCache, selectorCache);
    if (node) {
      nodes.push(node);
    }
    if (nodes.length === MAX_SNAPSHOT_NODES) {
      break;
    }
  }
  const readable = extractReadableMarkdown(visibilityCache);
  const url = window.location.href;
  const capturedAt = now().toISOString();
  return {
    pageState: currentPageState(() => new Date(capturedAt)),
    viewport,
    markdown: readable.markdown,
    snapshot: nodes.map((node) => snapshotLine(node)).join('\n'),
    nodes,
    truncated: readable.truncated || candidates.length > MAX_SNAPSHOT_NODES,
    sensitive: pageLooksSensitive(url),
    capturedAt
  };
}
