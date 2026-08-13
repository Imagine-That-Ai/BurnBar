import type { ActivityEvent, ApprovalPreview, LearningItem, TranscriptEntry } from '../shared/messages';
import type { BridgeAgentOption } from '../shared/protocol';
import type { PopupViewModel } from './viewModel';

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
    shield: 'M12 2 4.5 5v6c0 5 3.2 9.4 7.5 11 4.3-1.6 7.5-6 7.5-11V5L12 2Zm0 4 4.5 1.8V11c0 3.4-1.9 6.5-4.5 7.8V6Z',
    page: 'M6 2h8l4 4v16H6V2Zm8 1.8V7h3.2L14 3.8ZM8.5 11v1.5h7V11h-7Zm0 4v1.5h7V15h-7Z',
    spark: 'm12 2 1.5 6.5L20 10l-6.5 1.5L12 18l-1.5-6.5L4 10l6.5-1.5L12 2Z',
    refresh: 'M18.4 5.6A8 8 0 1 0 20 14h-2.1a6 6 0 1 1-1-6.9L14 10h7V3l-2.6 2.6Z',
    chevron: 'm8 10 4 4 4-4',
    lock: 'M7 10V7a5 5 0 0 1 10 0v3h2v12H5V10h2Zm2 0h6V7a3 3 0 0 0-6 0v3Z',
    brain:
      'M9.2 3.1A4 4 0 0 0 5 7v.2A4.5 4.5 0 0 0 4 16v.2A3.8 3.8 0 0 0 10 19v-5H8v-2h2V7.5A4.4 4.4 0 0 0 9.2 3.1ZM14.8 3.1A4 4 0 0 1 19 7v.2a4.5 4.5 0 0 1 1 8.8v.2A3.8 3.8 0 0 1 14 19v-5h2v-2h-2V7.5a4.4 4.4 0 0 1 .8-4.4Z'
  };
  path.setAttribute('d', paths[name] ?? paths.spark ?? '');
  svg.append(path);
  return svg;
}

function button(label: string, action: string, className = 'button'): HTMLButtonElement {
  const node = element('button', className, label);
  node.type = 'button';
  node.dataset.action = action;
  return node;
}

function renderHeader(viewModel: PopupViewModel): HTMLElement {
  const header = element('header', 'topbar');
  const identity = element('div', 'identity');
  const logoWrap = element('div', 'logo-wrap');
  const logo = element('img', 'logo');
  logo.src = 'icons/app-logo.svg';
  logo.alt = '';
  logoWrap.append(logo);
  const titles = element('div', 'identity-copy');
  titles.append(element('strong', 'product-name', 'OpenBurnBar'), element('span', 'surface-name', 'Safari Agent'));
  identity.append(logoWrap, titles);

  const controls = element('div', 'topbar-actions');
  const status = element('span', `connection connection--${viewModel.connectionTone}`);
  status.setAttribute('role', 'status');
  status.append(element('span', 'connection-orb'), document.createTextNode(viewModel.connectionLabel));
  const stop = button('Stop', 'abort', 'stop-button');
  stop.disabled = !viewModel.stopEnabled;
  stop.title = viewModel.stopEnabled ? 'Stop this run now (⌃⌥⌘.)' : 'No active run';
  stop.prepend(icon('stop'));
  controls.append(status, stop);
  header.append(identity, controls);
  return header;
}

function renderPageBand(viewModel: PopupViewModel): HTMLElement {
  const band = element('section', 'page-band');
  band.setAttribute('aria-label', 'Current Safari page');
  const glyph = element('span', 'page-glyph');
  glyph.append(icon('page'));
  const copy = element('div', 'page-copy');
  const title = element('strong', 'page-title', viewModel.pageLabel);
  title.title = viewModel.pageLabel;
  const detail = element('span', 'page-detail', viewModel.pageDetail);
  copy.append(title, detail);
  const chips = element('div', 'page-chips');
  if (viewModel.pageSensitive) {
    const sensitive = element('span', 'chip chip--sensitive', 'Sensitive');
    sensitive.title = 'Credential, banking, billing, or payment context detected';
    chips.append(sensitive);
  }
  const permission = element(
    'span',
    `chip chip--${viewModel.snapshot?.page?.permission === 'granted' ? 'ready' : 'muted'}`,
    viewModel.snapshot?.page?.permission === 'granted' ? 'Allowed' : 'Site access'
  );
  permission.title = viewModel.permissionLabel;
  chips.append(permission);
  band.append(glyph, copy, chips);
  return band;
}

function renderModes(viewModel: PopupViewModel): HTMLElement {
  const section = element('section', 'mode-section');
  const control = element('div', 'mode-control');
  control.setAttribute('role', 'group');
  control.setAttribute('aria-label', 'OpenBurnBar mode');
  for (const mode of viewModel.modes) {
    const option = button(mode.label, `mode:${mode.id}`, 'mode-button');
    const selected = mode.id === viewModel.selectedMode;
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

function renderAgentPicker(viewModel: PopupViewModel): HTMLElement {
  const section = element('section', 'agent-section');
  const labelRow = element('div', 'section-heading-row');
  labelRow.append(
    element('label', 'section-heading', viewModel.selectedMode === 'handoff' ? 'Installed agent' : 'Brain')
  );
  const selectionHint = viewModel.selectedAgent
    ? `${viewModel.selectedAgent.providerName} · ${viewModel.selectedAgent.cloud ? 'cloud' : 'local'}`
    : 'Discovery from OpenBurnBar';
  labelRow.append(element('span', 'section-meta', selectionHint));

  const controls = element('div', 'agent-controls');
  const search = element('input', 'agent-search');
  search.type = 'search';
  search.placeholder = 'Filter agents and models';
  search.autocomplete = 'off';
  search.dataset.input = 'agent-filter';
  search.setAttribute('aria-label', 'Filter agents and models');
  const selectWrap = element('div', 'select-wrap');
  const select = element('select', 'agent-select');
  select.dataset.input = 'agent';
  select.setAttribute('aria-label', viewModel.selectedMode === 'handoff' ? 'Installed agent' : 'Agent or model');
  if (viewModel.noAgents) {
    const empty = element('option', undefined, 'No compatible agents found');
    empty.disabled = true;
    empty.selected = true;
    select.append(empty);
  } else {
    for (const group of viewModel.agentGroups) {
      const optgroup = document.createElement('optgroup');
      optgroup.label = group.label;
      for (const agent of group.agents) {
        optgroup.append(renderAgentOption(agent, viewModel.selectedAgent?.id));
      }
      select.append(optgroup);
    }
  }
  selectWrap.append(select, icon('chevron'));
  controls.append(search, selectWrap);
  section.append(labelRow, controls);
  return section;
}

function renderAgentOption(agent: BridgeAgentOption, selectedAgentId?: string): HTMLOptionElement {
  const option = document.createElement('option');
  option.value = agent.id;
  option.textContent = `${agent.displayName}${agent.kind === 'cli' ? ' — installed' : ''}`;
  option.selected = agent.id === selectedAgentId;
  return option;
}

function renderTranscript(entries: TranscriptEntry[]): HTMLElement {
  const section = element('section', 'transcript');
  section.setAttribute('aria-label', 'Conversation');
  section.setAttribute('aria-live', 'polite');
  if (entries.length === 0) {
    const empty = element('div', 'empty-state');
    const orb = element('div', 'empty-orb');
    orb.append(icon('spark'));
    empty.append(
      orb,
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

function renderComposer(viewModel: PopupViewModel): HTMLElement | undefined {
  if (!viewModel.composerVisible) {
    return undefined;
  }
  const form = element('form', 'composer');
  form.dataset.form = 'composer';
  const textarea = element('textarea', 'composer-input');
  textarea.value = viewModel.draft;
  textarea.placeholder = viewModel.composerPlaceholder;
  textarea.rows = 3;
  textarea.maxLength = 8_000;
  textarea.dataset.input = 'draft';
  textarea.setAttribute('aria-label', viewModel.composerPlaceholder);
  const footer = element('div', 'composer-footer');
  footer.append(element('span', 'composer-hint', '⌘↵ to send'));
  const submit = element('button', 'button button--primary composer-submit', viewModel.primaryLabel);
  submit.type = 'submit';
  submit.disabled = viewModel.primaryDisabled;
  if (viewModel.primaryDisabledReason) {
    submit.title = viewModel.primaryDisabledReason;
  }
  submit.prepend(icon('spark'));
  footer.append(submit);
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
  row.append(copy, control);
  return row;
}

function renderTrust(viewModel: PopupViewModel): HTMLElement {
  const snapshot = viewModel.snapshot;
  const details = element('details', 'drawer trust-drawer');
  const summary = element('summary', 'drawer-summary');
  const title = element('span', 'drawer-title');
  title.append(icon('lock'), document.createTextNode('Trust & privacy'));
  const trustLabel = snapshot?.trust.siteAllowed ? 'This site allowed' : 'Permission needed';
  summary.append(title, element('span', 'drawer-status', trustLabel), icon('chevron'));
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
      checkboxRow(
        'Send this session’s screenshots',
        'The selected cloud model receives resized JPEGs. OpenBurnBar never stores provider keys here.',
        'trust-cloud',
        snapshot?.trust.cloudScreenshotAcknowledged ?? false
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
    actions.append(
      button('Reject', `learning:${item.id}:reject`, 'button button--quiet compact'),
      button('Approve', `learning:${item.id}:approve`, 'button button--secondary compact')
    );
  } else {
    actions.append(button('Forget', `learning:${item.id}:forget`, 'button button--quiet compact'));
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

export function renderPopup(root: HTMLElement, viewModel: PopupViewModel): void {
  root.setAttribute('aria-busy', String(!viewModel.ready));
  const learningWasOpen = root.querySelector<HTMLDetailsElement>('.learning-drawer')?.open ?? false;
  const previousFocus =
    document.activeElement instanceof HTMLElement ? document.activeElement.dataset.input : undefined;
  const previousSelection =
    document.activeElement instanceof HTMLTextAreaElement
      ? { start: document.activeElement.selectionStart, end: document.activeElement.selectionEnd }
      : undefined;
  const shell = element('main', 'shell');
  shell.append(
    renderHeader(viewModel),
    renderPageBand(viewModel),
    renderModes(viewModel),
    renderAgentPicker(viewModel)
  );

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
  const composer = renderComposer(viewModel);
  if (composer) {
    scroll.append(composer);
  }
  scroll.append(
    renderActivity(viewModel.snapshot?.activity ?? []),
    renderTrust(viewModel),
    renderLearning(viewModel, learningWasOpen)
  );
  shell.append(scroll);
  root.replaceChildren(shell);

  if (previousFocus) {
    const next = root.querySelector<HTMLElement>(`[data-input="${previousFocus}"]`);
    next?.focus({ preventScroll: true });
    if (next instanceof HTMLTextAreaElement && previousSelection) {
      next.setSelectionRange(previousSelection.start, previousSelection.end);
    }
  }
  const transcript = root.querySelector('.transcript');
  if (transcript) {
    transcript.scrollTop = transcript.scrollHeight;
  }
}
