import type { ActivityEvent, ApprovalPreview, LearningItem, TranscriptEntry } from '../shared/messages';
import { isRecord } from '../shared/protocol';
import type { BridgeAgentOption } from '../shared/protocol';
import { SAFARI_PERFORMANCE_LABELS, formatPerformanceDuration } from './diagnostics';
import { initializeModeVisuals } from './modeVisuals';
import type { PopupViewModel } from './viewModel';

const TRANSCRIPT_FOLLOW_THRESHOLD_PX = 32;

interface TextSelectionState {
  start: number;
  end: number;
  direction: 'forward' | 'backward' | 'none';
  scrollLeft: number;
  scrollTop: number;
}

interface FocusState {
  key: string;
  selection?: TextSelectionState;
}

interface ScrollState {
  left: number;
  top: number;
}

interface TranscriptScrollState {
  followLatest: boolean;
  top: number;
}

function element<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  className?: string,
  text?: string
): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (className) {
    node.className = className;
  }
  if (text !== undefined) {
    node.textContent = text;
  }
  return node;
}

function icon(name: string): SVGSVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 24 24');
  svg.setAttribute('aria-hidden', 'true');
  svg.classList.add('icon');
  const path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
  const paths: Record<string, string> = {
    stop: 'M7 7h10v10H7z',
    globe:
      'M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Zm0 0c2.1 2.4 3.2 5.4 3.2 9S14.1 18.6 12 21c-2.1-2.4-3.2-5.4-3.2-9S9.9 5.4 12 3ZM3.4 9h17.2M3.4 15h17.2',
    shield: 'M12 2 4.5 5v6c0 5 3.2 9.4 7.5 11 4.3-1.6 7.5-6 7.5-11V5L12 2Zm0 4 4.5 1.8V11c0 3.4-1.9 6.5-4.5 7.8V6Z',
    page: 'M6 2h8l4 4v16H6V2Zm8 1.8V7h3.2L14 3.8ZM8.5 11v1.5h7V11h-7Zm0 4v1.5h7V15h-7Z',
    spark: 'm12 2 1.5 6.5L20 10l-6.5 1.5L12 18l-1.5-6.5L4 10l6.5-1.5L12 2Z',
    refresh: 'M18.4 5.6A8 8 0 1 0 20 14h-2.1a6 6 0 1 1-1-6.9L14 10h7V3l-2.6 2.6Z',
    chevron: 'm8 10 4 4 4-4',
    lock: 'M7 10V7a5 5 0 0 1 10 0v3h2v12H5V10h2Zm2 0h6V7a3 3 0 0 0-6 0v3Z',
    gauge:
      'M12 4a9 9 0 0 0-9 9c0 2.4.9 4.7 2.5 6.4l1.5-1.3A7 7 0 1 1 17 18l1.5 1.4A9 9 0 0 0 12 4Zm4.7 4.3-5.6 3.2A2.5 2.5 0 1 0 13 13.4l4.7-4.1-1-1Z',
    copy: 'M8 7V3h13v13h-4v5H3V7h5Zm2-2v2h7v7h2V5h-9Zm5 4H5v10h10V9Z',
    download: 'M11 3h2v9l3.5-3.5L18 10l-6 6-6-6 1.5-1.5L11 12V3ZM4 19h16v2H4v-2Z',
    send: 'M4 12h15M13 6l6 6-6 6',
    expand: 'M8 3H3v5h2V5h3V3Zm8 0v2h3v3h2V3h-5ZM5 16H3v5h5v-2H5v-3Zm16 0h-2v3h-3v2h5v-5Z',
    more: 'M5 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4Zm7 0a2 2 0 1 0 0 4 2 2 0 0 0 0-4Zm7 0a2 2 0 1 0 0 4 2 2 0 0 0 0-4Z',
    brain:
      'M9.2 3.1A4 4 0 0 0 5 7v.2A4.5 4.5 0 0 0 4 16v.2A3.8 3.8 0 0 0 10 19v-5H8v-2h2V7.5A4.4 4.4 0 0 0 9.2 3.1ZM14.8 3.1A4 4 0 0 1 19 7v.2a4.5 4.5 0 0 1 1 8.8v.2A3.8 3.8 0 0 1 14 19v-5h2v-2h-2V7.5a4.4 4.4 0 0 1 .8-4.4Z',
    check: 'm5 12 4 4L19 6'
  };
  path.setAttribute('d', paths[name] ?? paths.spark ?? '');
  svg.append(path);
  return svg;
}

function focusKey<T extends HTMLElement>(node: T, key: string): T {
  node.dataset.focusKey = key;
  return node;
}

function button(label: string, action: string, className = 'button'): HTMLButtonElement {
  const node = focusKey(element('button', className, label), `action:${action}`);
  node.type = 'button';
  node.dataset.action = action;
  return node;
}

function captureTextSelection(node: HTMLElement): TextSelectionState | undefined {
  if (!(node instanceof HTMLInputElement || node instanceof HTMLTextAreaElement)) {
    return undefined;
  }
  try {
    const start = node.selectionStart;
    const end = node.selectionEnd;
    if (start === null || end === null) {
      return undefined;
    }
    return {
      start,
      end,
      direction: node.selectionDirection ?? 'none',
      scrollLeft: node.scrollLeft,
      scrollTop: node.scrollTop
    };
  } catch {
    return undefined;
  }
}

function captureFocus(root: HTMLElement): FocusState | undefined {
  const active = document.activeElement;
  if (!(active instanceof HTMLElement) || !root.contains(active)) {
    return undefined;
  }
  const key = active.dataset.focusKey;
  if (!key) {
    return undefined;
  }
  const selection = captureTextSelection(active);
  return selection ? { key, selection } : { key };
}

function restoreFocus(root: HTMLElement, state: FocusState | undefined): void {
  if (!state) {
    return;
  }
  const next = [...root.querySelectorAll<HTMLElement>('[data-focus-key]')].find(
    (candidate) => candidate.dataset.focusKey === state.key
  );
  if (!next || (next instanceof HTMLButtonElement && next.disabled)) {
    return;
  }
  next.focus({ preventScroll: true });
  if (!state.selection || !(next instanceof HTMLInputElement || next instanceof HTMLTextAreaElement)) {
    return;
  }
  const start = Math.min(state.selection.start, next.value.length);
  const end = Math.min(Math.max(state.selection.end, start), next.value.length);
  try {
    next.setSelectionRange(start, end, state.selection.direction);
  } catch {
    return;
  }
  next.scrollLeft = state.selection.scrollLeft;
  next.scrollTop = state.selection.scrollTop;
}

function captureScroll(node: HTMLElement | null): ScrollState | undefined {
  return node ? { left: node.scrollLeft, top: node.scrollTop } : undefined;
}

function restoreScroll(node: HTMLElement | null, state: ScrollState | undefined): void {
  if (!node || !state) {
    return;
  }
  node.scrollLeft = state.left;
  node.scrollTop = state.top;
}

function captureTranscriptScroll(node: HTMLElement | null): TranscriptScrollState | undefined {
  if (!node) {
    return undefined;
  }
  return {
    followLatest: node.scrollHeight - node.clientHeight - node.scrollTop <= TRANSCRIPT_FOLLOW_THRESHOLD_PX,
    top: node.scrollTop
  };
}

function restoreTranscriptScroll(node: HTMLElement | null, state: TranscriptScrollState | undefined): void {
  if (!node) {
    return;
  }
  node.scrollTop = !state || state.followLatest ? node.scrollHeight : state.top;
}

function renderHeader(viewModel: PopupViewModel, toolsOpen: boolean, expanded: boolean): HTMLElement {
  const header = element('header', 'topbar');
  const identity = element('div', 'identity design-context');
  const logoWrap = element('div', 'logo-wrap');
  const logo = element('img', 'logo');
  logo.src = 'icons/app-logo.svg';
  logo.alt = '';
  logoWrap.append(logo);
  logoWrap.setAttribute('aria-label', 'OpenBurnBar Safari Agent');
  identity.append(logoWrap);

  const copy = element('div', 'identity-copy');
  copy.append(
    element('strong', 'product-name', viewModel.pageLabel),
    element('span', 'surface-name', viewModel.pageDetail || 'Safari')
  );
  identity.append(copy);

  const controls = element('div', 'topbar-actions');
  const status = element('span', `connection connection--${viewModel.connectionTone}`);
  status.setAttribute('role', 'status');
  status.title = viewModel.connectionLabel;
  status.append(element('span', 'connection-orb'), document.createTextNode(viewModel.connectionLabel));
  const resize = button(expanded ? 'Compact chat' : 'Expand chat', 'toggle-popup-shape', 'glass-icon-button');
  resize.setAttribute('aria-pressed', String(expanded));
  resize.title = expanded ? 'Use compact chat' : 'Expand chat';
  resize.replaceChildren(icon('expand'));
  const tools = button(toolsOpen ? 'Close controls' : 'Open controls', 'toggle-tools', 'glass-icon-button');
  tools.setAttribute('aria-expanded', String(toolsOpen));
  if (toolsOpen) {
    tools.setAttribute('aria-controls', 'popup-tools');
  }
  tools.title = toolsOpen ? 'Close controls' : 'Model, trust, learning, and diagnostics';
  tools.replaceChildren(icon('more'));
  const stop = button('Stop', 'abort', 'stop-button');
  stop.disabled = !viewModel.stopEnabled;
  stop.title = viewModel.stopEnabled ? 'Stop this run now (⌃⌥⌘.)' : 'No active run';
  stop.setAttribute('aria-keyshortcuts', 'Control+Alt+Meta+.');
  stop.prepend(icon('stop'));
  controls.append(status, resize, tools, stop);
  header.append(identity, controls);
  return header;
}

function renderModes(viewModel: PopupViewModel, open: boolean): HTMLElement {
  const section = element('section', 'mode-section mode-popover');
  section.id = 'mode-popover';
  section.setAttribute('role', 'group');
  section.setAttribute('aria-label', 'OpenBurnBar mode');
  section.setAttribute('aria-describedby', 'mode-description');
  section.hidden = !open;
  const heading = element('div', 'mode-popover-heading');
  heading.append(element('span', 'mode-popover-label', 'Mode'));
  const selected = viewModel.modes.find((mode) => mode.id === viewModel.selectedMode) ?? viewModel.modes[0];
  if (!selected) {
    return section;
  }
  heading.append(element('strong', 'mode-popover-value', selected.label));
  section.append(heading);
  const scale = element('div', 'mode-scale');
  scale.append(element('span', undefined, 'Faster'), element('span', undefined, 'Smarter'));
  section.append(scale);
  const range = element('input', 'mode-range');
  range.type = 'range';
  range.min = '0';
  range.max = String(Math.max(0, viewModel.modes.length - 1));
  range.step = '1';
  range.value = String(
    Math.max(
      0,
      viewModel.modes.findIndex((mode) => mode.id === viewModel.selectedMode)
    )
  );
  range.dataset.input = 'mode-range';
  focusKey(range, 'input:mode-range');
  range.setAttribute('aria-label', 'OpenBurnBar mode');
  range.setAttribute('aria-describedby', 'mode-description');
  range.setAttribute('aria-valuetext', selected.label);
  const track = element('div', 'mode-track');
  const selectedIndex = Math.max(
    0,
    viewModel.modes.findIndex((mode) => mode.id === viewModel.selectedMode)
  );
  const knobFraction = viewModel.modes.length > 1 ? selectedIndex / (viewModel.modes.length - 1) : 0;
  track.style.setProperty('--mode-fraction', String(knobFraction));
  const fire = element('canvas', 'mode-fire');
  fire.setAttribute('aria-hidden', 'true');
  const knobFallback = element('img', 'mode-knob-fallback');
  knobFallback.src = 'icons/app-logo.svg';
  knobFallback.alt = '';
  knobFallback.setAttribute('aria-hidden', 'true');
  const knob = element('canvas', 'mode-knob');
  knob.setAttribute('aria-hidden', 'true');
  track.append(fire, knobFallback, knob);
  for (let index = 0; index < viewModel.modes.length; index += 1) {
    const tick = element('span', 'mode-tick');
    tick.setAttribute('aria-hidden', 'true');
    tick.style.setProperty('--mode-index', String(index));
    tick.style.setProperty('--mode-denominator', String(Math.max(1, viewModel.modes.length - 1)));
    track.append(tick);
  }
  track.append(range);
  section.append(track);

  const control = element('div', 'mode-control mode-options');
  control.setAttribute('role', 'group');
  control.setAttribute('aria-label', 'OpenBurnBar mode options');
  control.setAttribute('aria-describedby', 'mode-description');
  for (const mode of viewModel.modes) {
    const option = button(mode.label, `mode:${mode.id}`, 'mode-button');
    const selected = mode.id === viewModel.selectedMode;
    option.dataset.modeDescription = mode.description;
    option.setAttribute('aria-pressed', String(selected));
    option.setAttribute('aria-label', mode.accessibleLabel);
    option.classList.toggle('is-selected', selected);
    control.append(option);
  }
  const description = element('p', 'mode-description', viewModel.modeDescription);
  description.id = 'mode-description';
  section.append(control, description);
  return section;
}

function renderAgentPicker(viewModel: PopupViewModel, open: boolean): HTMLElement {
  const details = element('details', 'agent-drawer');
  details.open = open;
  const summary = element('summary', 'agent-drawer-summary');
  focusKey(summary, 'drawer:agent');
  const title = element(
    'span',
    'agent-drawer-title',
    viewModel.selectedMode === 'handoff' ? 'Installed agent' : 'Brain'
  );
  const selectionHint = viewModel.selectedAgent
    ? `${viewModel.selectedAgent.providerName} · ${viewModel.selectedAgent.cloud ? 'cloud' : 'local'}`
    : viewModel.noAgents
      ? 'No compatible agents found'
      : 'Discovery from OpenBurnBar';
  summary.append(title, element('span', 'agent-drawer-status', selectionHint), icon('chevron'));
  details.append(summary);

  const section = element('section', 'agent-section');
  const labelRow = element('div', 'section-heading-row');
  labelRow.append(
    element('label', 'section-heading', viewModel.selectedMode === 'handoff' ? 'Installed agent' : 'Brain')
  );
  labelRow.append(element('span', 'section-meta', selectionHint));

  const controls = element('div', 'agent-controls');
  const search = element('input', 'agent-search');
  search.type = 'search';
  search.value = viewModel.agentFilter;
  search.placeholder = 'Filter agents and models';
  search.autocomplete = 'off';
  search.dataset.input = 'agent-filter';
  focusKey(search, 'input:agent-filter');
  search.setAttribute('aria-label', 'Filter agents and models');
  const options = element('div', 'agent-picker-options');
  options.setAttribute('role', 'listbox');
  options.setAttribute('aria-label', viewModel.selectedMode === 'handoff' ? 'Installed agents' : 'Models');
  if (viewModel.noAgents) {
    options.append(element('p', 'agent-picker-empty', 'No compatible agents found'));
  } else {
    for (const group of viewModel.agentGroups) {
      options.append(element('div', 'model-picker-group-label', group.label));
      for (const agent of group.agents) {
        options.append(renderModelOption(agent, viewModel.selectedAgent?.id, 'tools'));
      }
    }
  }
  controls.append(search, options);
  section.append(labelRow, controls);
  details.append(section);
  return details;
}

function providerLogoName(agent: BridgeAgentOption): string | undefined {
  const provider = `${agent.providerName} ${agent.id}`.toLocaleLowerCase();
  const matches: Array<[string, string]> = [
    ['factory', 'factory.png'],
    ['anthropic', 'anthropic.png'],
    ['claude', 'anthropic.png'],
    ['openai', 'openai.png'],
    ['gpt', 'openai.png'],
    ['qwen', 'qwen.svg'],
    ['google', 'google.svg'],
    ['gemini', 'google.svg'],
    ['ollama', 'ollama.png'],
    ['codex', 'codex.png'],
    ['hermes', 'hermes.png']
  ];
  return matches.find(([needle]) => provider.includes(needle))?.[1];
}

function renderProviderMark(agent: BridgeAgentOption): HTMLElement {
  const mark = element('span', 'provider-mark');
  mark.setAttribute('aria-hidden', 'true');
  const logoName = providerLogoName(agent);
  if (logoName) {
    const logo = element('img', 'provider-logo');
    logo.src = `providers/${logoName}`;
    logo.alt = '';
    mark.append(logo);
  } else {
    mark.classList.add('provider-mark--fallback');
    mark.textContent = (agent.providerName.trim()[0] ?? agent.displayName.trim()[0] ?? '•').toLocaleUpperCase();
  }
  return mark;
}

function renderModelOption(
  agent: BridgeAgentOption,
  selectedAgentId: string | undefined,
  focusNamespace: 'composer' | 'tools'
): HTMLButtonElement {
  const option = button('', 'select-agent', 'model-picker-option');
  option.dataset.agentId = agent.id;
  focusKey(option, `agent:${focusNamespace}:${agent.id}`);
  option.setAttribute('role', 'option');
  option.setAttribute('aria-selected', String(agent.id === selectedAgentId));
  option.setAttribute('aria-label', `${agent.displayName}, ${agent.providerName}, ${agent.cloud ? 'cloud' : 'local'}`);
  option.append(renderProviderMark(agent));
  const copy = element('span', 'model-picker-copy');
  copy.append(
    element('strong', undefined, agent.displayName),
    element('span', undefined, `${agent.providerName} · ${agent.cloud ? 'Cloud' : 'Local'}`)
  );
  option.append(copy);
  if (agent.id === selectedAgentId) {
    option.append(icon('check'));
  }
  return option;
}

function renderModelPicker(viewModel: PopupViewModel, open: boolean): HTMLElement {
  const picker = element('div', 'model-picker');
  const trigger = button('', 'toggle-model-picker', 'mini model-picker-trigger');
  trigger.setAttribute('aria-haspopup', 'listbox');
  trigger.setAttribute('aria-expanded', String(open));
  trigger.setAttribute('aria-controls', 'model-picker-options');
  trigger.setAttribute(
    'aria-label',
    viewModel.selectedAgent
      ? `Model: ${viewModel.selectedAgent.displayName}, ${viewModel.selectedAgent.providerName}`
      : 'Choose an agent or model'
  );
  if (viewModel.selectedAgent) {
    trigger.append(
      renderProviderMark(viewModel.selectedAgent),
      element('span', 'model-picker-trigger-label', viewModel.selectedAgent.displayName),
      icon('chevron')
    );
  } else {
    trigger.append(
      icon('brain'),
      element('span', 'model-picker-trigger-label', viewModel.noAgents ? 'No models' : 'Choose model'),
      icon('chevron')
    );
    trigger.disabled = viewModel.noAgents;
  }
  picker.append(trigger);

  const options = element('div', 'model-picker-options');
  options.id = 'model-picker-options';
  options.setAttribute('role', 'listbox');
  options.setAttribute('aria-label', viewModel.selectedMode === 'handoff' ? 'Installed agents' : 'Models');
  options.hidden = !open;
  for (const group of viewModel.agentGroups) {
    const heading = element('div', 'model-picker-group-label', group.label);
    heading.setAttribute('role', 'presentation');
    options.append(heading);
    for (const agent of group.agents) {
      options.append(renderModelOption(agent, viewModel.selectedAgent?.id, 'composer'));
    }
  }
  picker.append(options);
  return picker;
}

function renderTranscript(entries: TranscriptEntry[]): HTMLElement {
  const section = element('section', 'transcript');
  section.setAttribute('aria-label', 'Conversation');
  section.setAttribute('aria-live', 'polite');
  if (entries.length === 0) {
    const empty = element('div', 'empty empty-state');
    const mark = element('img', 'empty-mark');
    mark.src = 'icons/app-logo.svg';
    mark.alt = '';
    empty.append(
      mark,
      element('strong', undefined, 'The page is in view.'),
      element('p', undefined, 'Ask what it says, what it looks like, or what you want done.')
    );
    section.append(empty);
    return section;
  }
  for (const entry of entries) {
    const article = element('article', `message message--${entry.role}${entry.error ? ' is-error' : ''}`);
    const role =
      entry.role === 'user'
        ? 'You'
        : entry.role === 'assistant'
          ? 'OpenBurnBar'
          : entry.role === 'activity'
            ? 'Run'
            : 'System';
    article.append(element('span', 'message-role', role), element('p', 'message-text', entry.text));
    if (entry.streaming) {
      const typing = element('span', 'typing-indicator');
      typing.setAttribute('aria-label', 'Response streaming');
      typing.append(element('i'), element('i'), element('i'));
      article.append(typing);
    }
    if (entry.note) {
      const note = element('p', `message-note${entry.error ? ' message-note--error' : ''}`, entry.note);
      note.setAttribute('role', 'status');
      article.append(note);
    }
    section.append(article);
  }
  return section;
}

function renderApproval(approval: ApprovalPreview): HTMLElement {
  const card = element('article', `approval-card approval-card--${approval.risk}`);
  const eyebrow = element('div', 'approval-eyebrow');
  eyebrow.append(icon('shield'), document.createTextNode('Approval required'));
  card.append(
    eyebrow,
    element('strong', 'approval-title', approval.title),
    element('p', 'approval-summary', approval.summary)
  );
  if (approval.url) {
    const host = (() => {
      try {
        return new URL(approval.url).hostname;
      } catch {
        return approval.url;
      }
    })();
    card.append(element('span', 'approval-site', host));
  }
  const actions = element('div', 'approval-actions');
  const block = button('Block', `approval:${approval.id}:block`, 'button button--quiet');
  const once = button('Allow once', `approval:${approval.id}:allow_once`, 'button button--secondary');
  const session = button('Allow session', `approval:${approval.id}:allow_session`, 'button button--primary');
  block.setAttribute('aria-label', `Block approval: ${approval.title}`);
  once.setAttribute('aria-label', `Allow once: ${approval.title}`);
  session.setAttribute('aria-label', `Allow for this session: ${approval.title}`);
  actions.append(block, once, session);
  card.append(actions);
  return card;
}

function renderApprovals(approvals: ApprovalPreview[]): HTMLElement | undefined {
  if (approvals.length === 0) {
    return undefined;
  }
  const section = element('section', 'approvals');
  section.setAttribute('aria-label', 'Pending Safari action approvals');
  for (const approval of approvals) {
    section.append(renderApproval(approval));
  }
  return section;
}

function renderComposer(viewModel: PopupViewModel, modePopoverOpen: boolean, modelPickerOpen: boolean): HTMLElement {
  const form = element('form', 'composer');
  form.dataset.form = 'composer';
  const textarea = element('textarea', 'composer-input');
  textarea.value = viewModel.draft;
  textarea.placeholder = viewModel.composerPlaceholder;
  textarea.readOnly = viewModel.composerReadOnly;
  textarea.rows = 2;
  textarea.maxLength = 8_000;
  textarea.dataset.input = 'draft';
  focusKey(textarea, 'input:draft');
  textarea.setAttribute('aria-label', viewModel.composerPlaceholder);
  textarea.setAttribute('aria-keyshortcuts', 'Meta+Enter');
  if (viewModel.composerReadOnly) {
    textarea.setAttribute('aria-readonly', 'true');
  }
  const footer = element('div', 'composer-footer');
  const agent = renderModelPicker(viewModel, modelPickerOpen);
  const selectedMode = viewModel.modes.find((mode) => mode.id === viewModel.selectedMode);
  const modeTrigger = button('', 'toggle-mode-popover', 'button btn btn--ember-outline mode-trigger');
  modeTrigger.append(icon('brain'), element('span', 'mode-trigger-label', selectedMode?.label ?? 'Ask'));
  modeTrigger.setAttribute('aria-label', `Thinking level: ${selectedMode?.label ?? 'Ask'}`);
  modeTrigger.setAttribute('aria-haspopup', 'true');
  modeTrigger.setAttribute('aria-expanded', String(modePopoverOpen));
  modeTrigger.setAttribute('aria-controls', 'mode-popover');
  const submit = element('button', 'send composer-submit');
  submit.type = 'submit';
  focusKey(submit, 'submit:composer');
  submit.disabled = viewModel.primaryDisabled;
  submit.setAttribute('aria-keyshortcuts', 'Meta+Enter');
  if (viewModel.primaryDisabledReason) {
    submit.title = viewModel.primaryDisabledReason;
  }
  submit.setAttribute('aria-label', viewModel.primaryLabel);
  submit.prepend(icon('send'));
  footer.append(agent, modeTrigger, submit);
  form.append(textarea, footer);
  if (viewModel.primaryDisabledReason) {
    const reason = element('p', 'disabled-reason', viewModel.primaryDisabledReason);
    reason.setAttribute('role', 'status');
    form.append(reason);
  }
  return form;
}

function renderActivity(events: ActivityEvent[]): HTMLElement {
  const section = element('section', 'activity-strip');
  const heading = element('div', 'section-heading-row');
  heading.append(
    element('strong', 'section-heading', 'Live activity'),
    element('span', 'section-meta', 'Verified after every step')
  );
  section.append(heading);
  const list = element('ol', 'activity-list');
  if (events.length === 0) {
    const empty = element('li', 'activity-item activity-item--muted', 'No run activity yet.');
    list.append(empty);
  } else {
    for (const event of events.slice(-6).reverse()) {
      const item = element('li', `activity-item activity-item--${event.tone}`);
      item.append(element('span', 'activity-dot'), element('span', undefined, event.text));
      list.append(item);
    }
  }
  section.append(list);
  return section;
}

function renderPerformance(viewModel: PopupViewModel, preserveOpen: boolean): HTMLElement {
  const diagnostics = viewModel.snapshot?.performance;
  const retainedCount = diagnostics?.samples.length ?? 0;
  const details = element('details', 'drawer performance-drawer');
  details.open = preserveOpen;
  const summary = element('summary', 'drawer-summary');
  focusKey(summary, 'drawer:performance');
  const title = element('span', 'drawer-title');
  title.append(icon('gauge'), document.createTextNode('Performance evidence'));
  const statusLabel =
    diagnostics?.persistence === 'memory_only'
      ? 'Memory only'
      : retainedCount === 0
        ? 'No samples'
        : `${retainedCount.toLocaleString()} retained`;
  summary.append(title, element('span', 'drawer-status', statusLabel), icon('chevron'));
  details.append(summary);

  const body = element('div', 'drawer-body performance-body');
  body.append(
    element(
      'p',
      'performance-privacy',
      'Local timing only. Excludes page content, screenshots, URLs, prompts, provider IDs, tokens, tabs, and command IDs.'
    )
  );
  if (diagnostics?.persistence === 'memory_only') {
    const warning = element(
      'p',
      'performance-notice performance-notice--error',
      'Safari storage is unavailable. Samples remain exportable until this extension process exits.'
    );
    warning.setAttribute('role', 'status');
    body.append(warning);
  }

  if (!diagnostics || diagnostics.summaries.length === 0) {
    body.append(
      element(
        'p',
        'drawer-empty',
        'Open the popup and exercise Ask, Agentic, Stop, capture, and learning flows to collect candidate-bound samples.'
      )
    );
  } else {
    const grid = element('div', 'performance-grid');
    for (const metric of diagnostics.summaries) {
      const card = element('article', 'performance-card');
      card.setAttribute('aria-label', `${SAFARI_PERFORMANCE_LABELS[metric.metric]} latency summary`);
      const heading = element('div', 'performance-card-heading');
      heading.append(
        element('strong', undefined, SAFARI_PERFORMANCE_LABELS[metric.metric]),
        element('span', undefined, `n=${metric.retainedCount.toLocaleString()}`)
      );
      const values = element('dl', 'performance-values');
      const medianTerm = element('dt', undefined, 'Median');
      const medianValue = element('dd', undefined, formatPerformanceDuration(metric.medianMs));
      const p95Term = element('dt', undefined, 'P95');
      const p95Value = element('dd', undefined, formatPerformanceDuration(metric.p95Ms));
      values.append(medianTerm, medianValue, p95Term, p95Value);
      card.append(heading, values);
      const nonSuccessCount = metric.errorCount + metric.abortedCount;
      if (nonSuccessCount > 0) {
        card.append(
          element(
            'span',
            'performance-outcomes',
            `${metric.errorCount.toLocaleString()} errors · ${metric.abortedCount.toLocaleString()} stopped`
          )
        );
      }
      grid.append(card);
    }
    body.append(grid);
  }

  const metadata = element(
    'p',
    'performance-metadata',
    diagnostics
      ? `${diagnostics.totalRecorded.toLocaleString()} recorded · ${diagnostics.droppedCount.toLocaleString()} expired from the ${diagnostics.retentionLimit.toLocaleString()}-sample local window`
      : 'The bounded local sample window has not initialized yet.'
  );
  const actions = element('div', 'performance-actions');
  const clear = button(
    viewModel.diagnosticsClearArmed ? 'Confirm clear' : 'Clear samples',
    'diagnostics-clear',
    'button button--quiet compact'
  );
  clear.disabled = !diagnostics || retainedCount === 0;
  clear.setAttribute(
    'aria-label',
    viewModel.diagnosticsClearArmed
      ? 'Confirm clearing all retained local Safari performance samples'
      : 'Clear all retained local Safari performance samples'
  );
  const copy = button('Copy JSON', 'diagnostics-copy', 'button button--quiet compact');
  copy.prepend(icon('copy'));
  copy.disabled = !diagnostics;
  copy.setAttribute('aria-label', 'Copy privacy-safe Safari performance evidence as JSON');
  const download = button('Download JSON', 'diagnostics-download', 'button button--secondary compact');
  download.prepend(icon('download'));
  download.disabled = !diagnostics;
  download.setAttribute('aria-label', 'Download privacy-safe Safari performance evidence as JSON');
  actions.append(clear, copy, download);
  body.append(metadata, actions);

  if (viewModel.diagnosticsNotice) {
    const notice = element(
      'p',
      `performance-notice performance-notice--${viewModel.diagnosticsNotice.tone}`,
      viewModel.diagnosticsNotice.text
    );
    notice.setAttribute('role', 'status');
    body.append(notice);
  }
  details.append(body);
  return details;
}

function checkboxRow(
  label: string,
  description: string,
  inputName: string,
  checked: boolean,
  disabled = false
): HTMLElement {
  const row = element('label', `setting-row${disabled ? ' is-disabled' : ''}`);
  const copy = element('span', 'setting-copy');
  copy.append(element('strong', undefined, label), element('span', undefined, description));
  const control = element('input', 'switch');
  control.type = 'checkbox';
  control.checked = checked;
  control.disabled = disabled;
  control.dataset.input = inputName;
  focusKey(control, `input:${inputName}`);
  row.append(copy, control);
  return row;
}

function trustStatusLabel(viewModel: PopupViewModel): string {
  const snapshot = viewModel.snapshot;
  if (!snapshot?.page) {
    return 'No page';
  }
  if (snapshot.page.permission === 'unsupported') {
    return 'Unavailable';
  }
  if (snapshot.page.permission !== 'granted') {
    return 'Safari access needed';
  }
  return snapshot.trust.siteAllowed ? 'This site allowed' : 'Permission needed';
}

function renderTrust(viewModel: PopupViewModel, preserveOpen: boolean): HTMLElement {
  const snapshot = viewModel.snapshot;
  const details = element('details', 'drawer trust-drawer');
  details.open = preserveOpen;
  const summary = element('summary', 'drawer-summary');
  focusKey(summary, 'drawer:trust');
  const title = element('span', 'drawer-title');
  title.append(icon('lock'), document.createTextNode('Trust & privacy'));
  summary.append(title, element('span', 'drawer-status', trustStatusLabel(viewModel)), icon('chevron'));
  details.append(summary);
  const body = element('div', 'drawer-body');
  body.append(
    checkboxRow(
      'Allow this website',
      'Share readable page context only when you invoke OpenBurnBar.',
      'trust-site',
      snapshot?.trust.siteAllowed ?? false,
      !snapshot?.page
    ),
    checkboxRow(
      'Only this tab',
      'Never touch background tabs. Agent-opened tabs require a separate choice.',
      'trust-tab',
      snapshot?.trust.onlyCurrentTab ?? true
    )
  );
  if (viewModel.pageSensitive) {
    body.append(
      checkboxRow(
        'Sensitive-site override',
        'Still Computer Use gated. Password and payment fields remain separately protected.',
        'trust-sensitive',
        snapshot?.trust.sensitiveSiteOverride ?? false
      )
    );
  }
  if (viewModel.showCloudDisclosure) {
    body.append(
      element(
        'p',
        'privacy-note',
        snapshot?.trust.cloudScreenshotAcknowledged
          ? 'Cloud screenshot disclosure acknowledged. Resized page screenshots are sent only when you invoke the selected cloud model.'
          : 'Cloud screenshot disclosure must be acknowledged through the single Allow & continue permission flow.'
      )
    );
  }
  body.append(
    checkboxRow(
      'Global kill switch',
      'Stop and reject all new Computer Use actions across OpenBurnBar.',
      'trust-kill',
      snapshot?.trust.globalKillSwitch ?? false
    )
  );
  if (snapshot?.page?.permission !== 'granted' && snapshot?.page?.permission !== 'unsupported') {
    const permission = button(
      'Grant persistent access in Safari',
      'request-permission',
      'button button--secondary full-width'
    );
    permission.prepend(icon('shield'));
    body.append(permission);
  }
  const privacyNote = element(
    'p',
    'privacy-note',
    'Screenshots stay on this Mac unless you choose a cloud model. Page actions are scoped, audited, and panic-haltable.'
  );
  body.append(privacyNote);
  details.append(body);
  return details;
}

function renderLearningItem(item: LearningItem): HTMLElement {
  const card = element('article', 'learning-item');
  const copy = element('div', 'learning-copy');
  const eyebrow = `${item.kind === 'skill' ? 'Skill' : item.kind === 'site-rule' ? 'Site rule' : 'Memory'} · ${item.status}`;
  copy.append(element('span', 'learning-eyebrow', eyebrow), element('strong', undefined, item.title));
  if (item.summary) {
    copy.append(element('p', undefined, item.summary));
  }
  const actions = element('div', 'learning-actions');
  if (item.status === 'proposed') {
    const reject = button('Reject', `learning:${item.id}:reject`, 'button button--quiet compact');
    const approve = button('Approve', `learning:${item.id}:approve`, 'button button--secondary compact');
    reject.setAttribute('aria-label', `Reject learning item: ${item.title}`);
    approve.setAttribute('aria-label', `Approve learning item: ${item.title}`);
    actions.append(reject, approve);
  } else {
    const forget = button('Forget', `learning:${item.id}:forget`, 'button button--quiet compact');
    forget.setAttribute('aria-label', `Forget learning item: ${item.title}`);
    actions.append(forget);
  }
  card.append(copy, actions);
  return card;
}

function renderLearningCorrection(viewModel: PopupViewModel): HTMLElement {
  const form = element('form', 'learning-correction');
  form.dataset.form = 'learning-correction';
  const heading = element('div', 'learning-correction-heading');
  const label = element('label', 'learning-correction-label', 'Teach a correction');
  label.htmlFor = 'learning-correction-input';
  heading.append(label, element('span', 'learning-explicit-chip', 'Explicit only'));

  const textarea = element('textarea', 'learning-correction-input');
  textarea.id = 'learning-correction-input';
  textarea.value = viewModel.correctionDraft;
  textarea.placeholder = 'Example: Always compare annual totals before monthly prices.';
  textarea.rows = 3;
  textarea.maxLength = 4_096;
  textarea.dataset.input = 'correction-draft';
  focusKey(textarea, 'input:correction-draft');
  textarea.setAttribute('aria-describedby', 'learning-correction-note learning-correction-count');

  const note = element(
    'p',
    'learning-correction-note',
    'Only what you type is reviewed. OpenBurnBar does not infer a correction from the page, screenshot, or chat.'
  );
  note.id = 'learning-correction-note';
  const footer = element('div', 'learning-correction-footer');
  const count = element(
    'span',
    'learning-correction-count',
    `${viewModel.correctionByteCount.toLocaleString()} / 4,096 bytes`
  );
  count.id = 'learning-correction-count';
  const submit = element('button', 'button button--secondary learning-correction-submit', 'Stage for review');
  submit.type = 'submit';
  focusKey(submit, 'submit:learning-correction');
  submit.disabled = viewModel.correctionSubmitDisabled;
  if (viewModel.correctionDisabledReason) {
    submit.title = viewModel.correctionDisabledReason;
  }
  footer.append(count, submit);
  form.append(heading, textarea, note, footer);
  return form;
}

function renderLearning(viewModel: PopupViewModel, preserveOpen: boolean): HTMLElement {
  const snapshot = viewModel.snapshot;
  const details = element('details', 'drawer learning-drawer');
  details.open = preserveOpen || viewModel.correctionDraft.length > 0;
  const summary = element('summary', 'drawer-summary');
  focusKey(summary, 'drawer:learning');
  const title = element('span', 'drawer-title');
  title.append(icon('brain'), document.createTextNode('What BurnBar learned'));
  const label = !snapshot?.learning.eligible
    ? 'Pro+'
    : snapshot.learning.optedIn
      ? `${snapshot.learning.items.length} items`
      : 'Off';
  summary.append(title, element('span', 'drawer-status', label), icon('chevron'));
  details.append(summary);
  const body = element('div', 'drawer-body');
  body.append(
    checkboxRow(
      'Learn across sessions',
      snapshot?.learning.eligible
        ? 'Propose redacted memories and portable page skills. Nothing activates without review.'
        : 'Available with Pro, Pro Max, or Ultra.',
      'learning-opt-in',
      snapshot?.learning.optedIn ?? false,
      !(snapshot?.learning.eligible ?? false)
    )
  );
  if (snapshot?.learning.optedIn) {
    body.append(renderLearningCorrection(viewModel));
    if (snapshot.learning.items.length === 0) {
      body.append(
        element(
          'p',
          'drawer-empty',
          'No durable learning yet. BurnBar waits for explicit corrections or repeated workflows instead of guessing.'
        )
      );
    } else {
      for (const item of snapshot.learning.items) {
        body.append(renderLearningItem(item));
      }
    }
  }
  details.append(body);
  return details;
}

function renderError(viewModel: PopupViewModel): HTMLElement | undefined {
  const error = viewModel.snapshot?.lastError;
  if (!error) {
    return undefined;
  }
  const banner = element('div', 'error-banner');
  banner.setAttribute('role', 'alert');
  const copy = element('div');
  copy.append(element('strong', undefined, 'OpenBurnBar needs attention'), element('p', undefined, error.message));
  const refresh = button('Retry', 'refresh', 'button button--quiet compact');
  refresh.prepend(icon('refresh'));
  banner.append(copy, refresh);
  return banner;
}

function daemonCode(error: NonNullable<PopupViewModel['snapshot']>['lastError']): number | undefined {
  if (!error || !isRecord(error.details)) {
    return undefined;
  }
  const code = error.details.daemonCode;
  return typeof code === 'number' && Number.isSafeInteger(code) ? code : undefined;
}

function permissionFailureDetail(error: NonNullable<PopupViewModel['snapshot']>['lastError']): string {
  if (!error) {
    return '';
  }
  const code = daemonCode(error);
  if (error.code === 'daemon_rejected' && code === -32001) {
    return 'OpenBurnBar reconnected once, but its Safari session was replaced again. Keep the app open and try once more. Diagnostic code: -32001.';
  }
  if (error.code === 'daemon_rejected' && code === -32603) {
    return 'OpenBurnBar could not save its trusted-site rule. Restart the app and try again. Diagnostic code: -32603.';
  }
  if (error.code === 'daemon_rejected' && code !== undefined) {
    return `${error.message} Diagnostic code: ${code}.`;
  }
  return error.message;
}

function permissionChecklistRow(label: string, detail: string, complete: boolean): HTMLElement {
  const row = element('div', `permission-check${complete ? ' is-complete' : ''}`);
  const mark = element('span', 'permission-check-mark');
  mark.append(icon(complete ? 'check' : 'shield'));
  const copy = element('span', 'permission-check-copy');
  copy.append(element('strong', undefined, label), element('span', undefined, detail));
  row.append(mark, copy);
  return row;
}

function renderPermissionSheet(viewModel: PopupViewModel): HTMLElement | undefined {
  if (!viewModel.showPermissionSheet || !viewModel.snapshot?.page) {
    return undefined;
  }
  const sheet = element('section', 'permission-sheet');
  sheet.setAttribute('role', 'dialog');
  sheet.setAttribute('aria-modal', 'true');
  sheet.setAttribute('aria-labelledby', 'permission-sheet-title');
  sheet.setAttribute('aria-describedby', 'permission-sheet-description');

  const glow = element('div', 'permission-sheet-glow');
  glow.setAttribute('aria-hidden', 'true');
  const eyebrow = element('span', 'permission-sheet-eyebrow', 'Private by default');
  const title = element('h2', 'permission-sheet-title', 'Use OpenBurnBar on websites');
  title.id = 'permission-sheet-title';
  const description = element(
    'p',
    'permission-sheet-description',
    `Allow once, then OpenBurnBar will be ready when you invoke it on ${viewModel.permissionSheetHost || 'a website'}.`
  );
  description.id = 'permission-sheet-description';

  const checklist = element('div', 'permission-checklist');
  checklist.append(
    permissionChecklistRow(
      'Safari website access',
      'Safari asks once for access to websites.',
      !viewModel.permissionSheetNeedsSafari
    ),
    permissionChecklistRow(
      'OpenBurnBar trust',
      'Each site is registered securely when you invoke OpenBurnBar.',
      !viewModel.permissionSheetNeedsSiteTrust
    )
  );
  if (viewModel.showCloudDisclosure) {
    checklist.append(
      permissionChecklistRow(
        'Cloud screenshot disclosure',
        'When you invoke the selected cloud model, resized page screenshots are sent with your request. Choosing Allow & continue acknowledges this disclosure.',
        !viewModel.permissionSheetNeedsCloudDisclosure
      )
    );
  }

  const scope = element(
    'p',
    'permission-sheet-scope',
    'OpenBurnBar stays limited to your active tab. Sensitive sites and page actions still require their own approval.'
  );
  const error = viewModel.snapshot.lastError;
  if (error) {
    const notice = element('div', 'permission-sheet-error');
    notice.setAttribute('role', 'alert');
    notice.append(
      element('strong', undefined, 'Permission was not completed'),
      element('span', undefined, permissionFailureDetail(error))
    );
    sheet.append(glow, eyebrow, title, description, checklist, scope, notice);
  } else {
    sheet.append(glow, eyebrow, title, description, checklist, scope);
  }
  const primary = button(
    error ? 'Try again' : 'Allow & continue',
    'complete-permission-setup',
    'permission-sheet-primary'
  );
  primary.disabled = viewModel.snapshot.busy;
  primary.setAttribute(
    'aria-label',
    error ? 'Try website permission setup again' : 'Allow website access and continue'
  );
  sheet.append(primary);
  return sheet;
}

export function renderPopup(root: HTMLElement, viewModel: PopupViewModel): void {
  root.setAttribute('aria-busy', String(!viewModel.ready));
  const trustWasOpen = root.querySelector<HTMLDetailsElement>('.trust-drawer')?.open ?? false;
  const learningWasOpen = root.querySelector<HTMLDetailsElement>('.learning-drawer')?.open ?? false;
  const performanceWasOpen = root.querySelector<HTMLDetailsElement>('.performance-drawer')?.open ?? false;
  const previousFocus = captureFocus(root);
  const previousContentScroll = captureScroll(root.querySelector<HTMLElement>('.content-scroll'));
  const previousTranscriptScroll = captureTranscriptScroll(root.querySelector<HTMLElement>('.transcript'));
  const modePopoverWasOpen = root.dataset.modePopoverOpen === 'true';
  const modelPickerWasOpen = root.dataset.modelPickerOpen === 'true';
  const agentDrawerWasOpen = root.querySelector<HTMLDetailsElement>('.agent-drawer')?.open ?? false;
  const toolsWereOpen = root.dataset.toolsOpen === 'true';
  const popupExpanded = root.dataset.popupShape !== 'compact';
  const shell = element('main', 'shell');
  shell.dataset.popupShape = popupExpanded ? 'expanded' : 'compact';
  shell.dataset.modePopoverOpen = String(modePopoverWasOpen);
  shell.dataset.toolsOpen = String(toolsWereOpen);
  shell.append(renderHeader(viewModel, toolsWereOpen, popupExpanded), renderModes(viewModel, modePopoverWasOpen));

  const scroll = element('div', 'content-scroll');
  const error = renderError(viewModel);
  if (error) {
    scroll.append(error);
  }
  scroll.append(renderTranscript(viewModel.snapshot?.transcript ?? []));
  const approvals = renderApprovals(viewModel.snapshot?.approvals ?? []);
  if (approvals) {
    scroll.append(approvals);
  }
  shell.append(scroll);
  if (toolsWereOpen) {
    const tools = element('aside', 'popup-tools');
    tools.id = 'popup-tools';
    tools.setAttribute('aria-label', 'OpenBurnBar controls');
    tools.append(
      renderAgentPicker(viewModel, agentDrawerWasOpen),
      renderActivity(viewModel.snapshot?.activity ?? []),
      renderPerformance(viewModel, performanceWasOpen),
      renderTrust(viewModel, trustWasOpen),
      renderLearning(viewModel, learningWasOpen)
    );
    shell.append(tools);
  }
  shell.append(renderComposer(viewModel, modePopoverWasOpen, modelPickerWasOpen));
  const permissionSheet = renderPermissionSheet(viewModel);
  if (permissionSheet) {
    shell.append(permissionSheet);
  }
  root.replaceChildren(shell);
  initializeModeVisuals(root);

  restoreScroll(root.querySelector<HTMLElement>('.content-scroll'), previousContentScroll);
  restoreTranscriptScroll(root.querySelector<HTMLElement>('.transcript'), previousTranscriptScroll);
  restoreFocus(root, previousFocus);
}
