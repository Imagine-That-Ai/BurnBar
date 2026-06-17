/* ============================================================
   OpenBurnBar Workspace — Editor Pane Webview
   Three-section operator workspace: Command · Runs · System
   ============================================================ */

const vscode = acquireVsCodeApi();

let currentViewModel = null;
let activeSection = 'command';
let selectedMode = 'explain';

/* ----------------------------------------------------------
   Utility helpers
   ---------------------------------------------------------- */

function safe(str) {
  return str === null || str === undefined ? '' : String(str);
}

function relativeTime(isoString) {
  if (!isoString) {
    return '';
  }
  const diff = Date.now() - new Date(isoString).getTime();
  if (isNaN(diff) || diff < 0) {
    return 'now';
  }
  const secs = Math.floor(diff / 1000);
  if (secs < 10) {
    return 'now';
  }
  if (secs < 60) {
    return secs + 's';
  }
  const mins = Math.floor(secs / 60);
  if (mins < 60) {
    return mins + 'm';
  }
  const hrs = Math.floor(mins / 60);
  return hrs + 'h';
}

function phaseToColor(phase) {
  switch (phase) {
  case 'planning':
  case 'executing_tool':
  case 'waiting_on_companion':
  case 'model_streaming':
    return 'active';
  case 'awaiting_approval':
    return 'warning';
  case 'completed':
    return 'success';
  case 'failed':
  case 'cancelled':
    return 'error';
  default:
    return 'muted';
  }
}

function humanizePhase(phase) {
  if (!phase) {
    return '';
  }
  return phase.replace(/_/g, ' ');
}

function el(tag, className, textContent) {
  const e = document.createElement(tag);
  if (className) {
    e.className = className;
  }
  if (textContent !== null && textContent !== undefined) {
    e.textContent = textContent;
  }
  return e;
}

function flattenText(value) {
  if (typeof value === 'string') {
    return value;
  }
  if (value === null || value === undefined) {
    return '';
  }
  if (typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  if (typeof value === 'object') {
    return (
      flattenText(value.displayName) ||
      flattenText(value.label) ||
      flattenText(value.name) ||
      flattenText(value.id)
    );
  }
  return '';
}

function modelOptionLabel(option) {
  const display =
    flattenText(option?.displayName) ||
    flattenText(option?.model?.displayName) ||
    flattenText(option?.label) ||
    flattenText(option?.id);
  const provider =
    flattenText(option?.providerName) ||
    flattenText(option?.provider?.displayName);

  if (display && provider && !display.includes(provider)) {
    return `${display} · ${provider}`;
  }
  return display || provider || 'Select a model';
}

/* ----------------------------------------------------------
   Error banner
   ---------------------------------------------------------- */

let _errorTimer = null;

function showError(message) {
  const existing = document.querySelector('.bw-error-banner');
  if (existing) {
    existing.remove();
  }
  if (_errorTimer) {
    clearTimeout(_errorTimer);
  }

  const banner = el('div', 'bw-error-banner', message);
  document.body.appendChild(banner);

  _errorTimer = setTimeout(() => {
    if (banner.parentNode) {
      banner.remove();
    }
    _errorTimer = null;
  }, 6000);
}

/* ----------------------------------------------------------
   Section switching
   ---------------------------------------------------------- */

function switchSection(section) {
  if (section === activeSection) {
    return;
  }
  activeSection = section;

  // Update section visibility
  document.querySelectorAll('.bw-section').forEach(s => {
    s.classList.toggle('bw-section--active', s.dataset.section === section);
  });

  // Update rail buttons
  document.querySelectorAll('.bw-rail-btn[data-section]').forEach(btn => {
    btn.classList.toggle('bw-rail-btn--active', btn.dataset.section === section);
  });

  // Update rail active indicator position
  updateRailIndicator(section);

  vscode.postMessage({ type: 'switchSection', section });
}

function updateRailIndicator(section) {
  const railSections = document.querySelector('.bw-rail-sections');
  const activeBtn = document.querySelector(`.bw-rail-btn[data-section="${section}"]`);
  if (!railSections || !activeBtn) {
    return;
  }

  const railRect = railSections.getBoundingClientRect();
  const btnRect = activeBtn.getBoundingClientRect();
  const top = btnRect.top - railRect.top + (btnRect.height - 28) / 2;
  railSections.style.setProperty('--bw-indicator-top', top + 'px');
}

/* ----------------------------------------------------------
   Render: Command Section
   ---------------------------------------------------------- */

function renderCommandSection(vm) {
  const container = document.getElementById('bw-command-run');
  const timeline = document.getElementById('bw-command-timeline');
  if (!container || !timeline) {
    return;
  }

  container.innerHTML = '';
  timeline.innerHTML = '';

  // No runs / no connection
  if (!vm.isConnected || vm.noRunsYet) {
    const empty = el('div', 'bw-command-run-empty');
    const title = el('div', 'bw-command-run-empty-title',
      vm.isDaemonUnavailable ? 'Waiting for daemon' : 'Ready to work');
    const msg = el('div', 'bw-command-run-empty-msg',
      vm.isDaemonUnavailable
        ? 'Connect the OpenBurnBar daemon to start running agent tasks from this workspace.'
        : 'Use the composer below to describe a task. OpenBurnBar will plan, read, edit, and run commands in your workspace.');
    empty.appendChild(title);
    empty.appendChild(msg);
    container.appendChild(empty);
    return;
  }

  // Active run banner
  if (vm.activeRun) {
    const run = vm.activeRun;
    const banner = el('div', 'bw-active-run');
    banner.dataset.runId = safe(run.id);

    const dot = el('div', 'bw-active-run-dot bw-active-run-dot--' + safe(run.phaseColor || 'muted'));

    const info = el('div', 'bw-active-run-info');
    const title = el('div', 'bw-active-run-title', safe(run.title));
    const meta = el('div', 'bw-active-run-meta');
    meta.textContent = [
      run.providerName,
      run.modelId,
      relativeTime(run.updatedAt) ? relativeTime(run.updatedAt) + ' ago' : ''
    ].filter(Boolean).join(' · ');

    info.appendChild(title);
    info.appendChild(meta);

    const phase = el('span', 'bw-phase bw-phase--' + safe(run.phaseColor || 'muted'),
      humanizePhase(run.phase));

    banner.appendChild(dot);
    banner.appendChild(info);
    banner.appendChild(phase);
    container.appendChild(banner);
  }

  // Build timeline items from current state
  renderTimeline(vm, timeline);
}

function renderTimeline(vm, container) {
  const items = [];
  const detail = vm.selectedRunDetail;
  const run = vm.activeRun;

  if (!run && !detail) {
    const empty = el('div', 'bw-timeline-empty', 'Activity will appear here as the run progresses.');
    container.appendChild(empty);
    return;
  }

  // Note / current activity
  if (run && run.note) {
    const color = phaseToColor(run.phase);
    items.push({ label: humanizePhase(run.phase), detail: run.note, color, time: run.updatedAt });
  }

  // Loop decision
  if (detail && detail.loopDecisionText) {
    items.push({ label: 'Loop decision', detail: detail.loopDecisionText, color: 'active' });
  }

  // Response text
  if (detail && detail.responseText) {
    items.push({ label: 'Agent response', detail: detail.responseText, color: 'success', isResponse: true });
  }

  // Usage
  if (detail && detail.usageText) {
    items.push({ label: 'Usage', detail: detail.usageText, color: 'muted' });
  }

  // Recovery
  if (detail && detail.recoveryMessage) {
    items.push({ label: 'Recovery', detail: detail.recoveryMessage, color: 'error' });
  }

  if (items.length === 0) {
    const empty = el('div', 'bw-timeline-empty', 'Waiting for agent activity...');
    container.appendChild(empty);
    return;
  }

  const timelineEl = el('div', 'bw-timeline');

  for (const item of items) {
    // Response text gets special treatment
    if (item.isResponse) {
      const response = el('div', 'bw-command-response', safe(item.detail));
      timelineEl.appendChild(response);
      continue;
    }

    const row = el('div', 'bw-timeline-item bw-timeline-item--' + safe(item.color));

    const body = el('div', 'bw-timeline-item-body');
    body.appendChild(el('div', 'bw-timeline-item-label', safe(item.label)));
    if (item.detail) {
      body.appendChild(el('div', 'bw-timeline-item-detail', safe(item.detail)));
    }

    row.appendChild(body);

    if (item.time) {
      row.appendChild(el('span', 'bw-timeline-item-time', relativeTime(item.time)));
    }

    timelineEl.appendChild(row);
  }

  // Approval block in timeline
  if (vm.approvalState) {
    const approval = el('div', 'bw-timeline-approval');
    approval.appendChild(el('div', 'bw-timeline-approval-title',
      safe(vm.approvalState.title || 'Approval required')));
    approval.appendChild(el('div', 'bw-timeline-approval-msg',
      safe(vm.approvalState.message)));

    const actions = el('div', 'bw-timeline-approval-actions');
    const approveBtn = el('button', 'bw-btn bw-btn--primary bw-btn--sm', 'Approve');
    approveBtn.dataset.action = 'approveRun';
    const rejectBtn = el('button', 'bw-btn bw-btn--danger bw-btn--sm', 'Reject');
    rejectBtn.dataset.action = 'rejectRun';
    actions.appendChild(approveBtn);
    actions.appendChild(rejectBtn);
    approval.appendChild(actions);
    timelineEl.appendChild(approval);
  }

  container.appendChild(timelineEl);
}

/* ----------------------------------------------------------
   Render: Runs Section
   ---------------------------------------------------------- */

function renderRunsSection(vm) {
  const ledger = document.getElementById('bw-runs-ledger');
  if (!ledger) {
    return;
  }

  ledger.innerHTML = '';

  const allRuns = [];
  if (vm.activeRun) {
    allRuns.push(vm.activeRun);
  }
  if (vm.historyRuns) {
    allRuns.push(...vm.historyRuns);
  }

  if (allRuns.length === 0) {
    const empty = el('div', 'bw-runs-empty');
    empty.appendChild(el('div', 'bw-runs-empty-title', 'No runs yet'));
    empty.appendChild(el('div', null,
      vm.isConnected
        ? 'Start a run from the Command section to begin.'
        : 'Connect the daemon to see runs.'));
    ledger.appendChild(empty);
    return;
  }

  // Ledger header
  const header = el('div', 'bw-ledger-header');
  header.appendChild(el('span', null, ''));
  header.appendChild(el('span', null, 'Run'));
  header.appendChild(el('span', null, 'Model'));
  header.appendChild(el('span', null, 'Phase'));
  header.appendChild(el('span', null, 'Age'));
  ledger.appendChild(header);

  // Run rows
  for (const run of allRuns) {
    const row = el('div', 'bw-run-row');
    row.dataset.runId = safe(run.id);
    if (run.id === vm.selectedRunId) {
      row.classList.add('bw-run-row--selected');
    }

    // Status dot
    const dot = el('div', 'bw-run-row-dot');
    const color = safe(run.phaseColor || 'muted');
    dot.style.background = `var(--bw-${phaseVarName(color)})`;

    // Run ID
    const idCell = el('span', 'bw-run-row-id', safe(run.id).slice(0, 8));

    // Model
    const modelCell = el('span', 'bw-run-row-model',
      safe(run.providerName || run.modelId || '—'));

    // Phase
    const phaseCell = el('span', 'bw-run-row-phase', humanizePhase(run.phase));

    // Age
    const ageCell = el('span', 'bw-run-row-age', relativeTime(run.updatedAt));

    row.appendChild(dot);
    row.appendChild(idCell);
    row.appendChild(modelCell);
    row.appendChild(phaseCell);
    row.appendChild(ageCell);
    ledger.appendChild(row);
  }
}

function phaseVarName(phaseColor) {
  switch (phaseColor) {
  case 'active': return 'coral';
  case 'warning': return 'gold';
  case 'success': return 'success';
  case 'error': return 'error';
  default: return 'text-3';
  }
}

/* ----------------------------------------------------------
   Render: System Section
   ---------------------------------------------------------- */

function renderSystemSection(vm) {
  const grid = document.getElementById('bw-system-grid');
  if (!grid) {
    return;
  }

  grid.innerHTML = '';

  // Connection status card
  const conn = el('div', 'bw-system-connection');
  const orbClass = 'bw-system-connection-orb bw-system-connection-orb--' +
    safe(vm.connectionStatus || 'disconnected');
  conn.appendChild(el('div', orbClass));

  const connInfo = el('div', 'bw-system-connection-info');
  connInfo.appendChild(el('div', 'bw-system-connection-status',
    capitalize(safe(vm.connectionStatus || 'disconnected'))));
  const connDetail = [];
  if (vm.daemonVersion) {
    connDetail.push('v' + vm.daemonVersion);
  }
  if (vm.hasWorkspace) {
    connDetail.push(vm.isWorkspaceTrusted ? 'trusted' : 'restricted');
  }
  connInfo.appendChild(el('div', 'bw-system-connection-detail',
    connDetail.join(' · ') || '—'));
  conn.appendChild(connInfo);
  grid.appendChild(conn);

  // Actions
  const actions = el('div', 'bw-system-actions');
  const reconnectBtn = el('button', 'bw-btn bw-btn--secondary bw-btn--sm', 'Reconnect');
  reconnectBtn.dataset.action = 'refresh';
  const repairBtn = el('button', 'bw-btn bw-btn--secondary bw-btn--sm', 'Repair Daemon');
  repairBtn.dataset.action = 'repair';
  const openAppBtn = el('button', 'bw-btn bw-btn--secondary bw-btn--sm', 'Open App');
  openAppBtn.dataset.action = 'openApp';
  if (!vm.showOpenBurnBarApp) {
    openAppBtn.dataset.visible = 'false';
  }
  actions.appendChild(reconnectBtn);
  actions.appendChild(repairBtn);
  actions.appendChild(openAppBtn);
  grid.appendChild(actions);

  // Daemon section
  if (vm.systemInfo) {
    grid.appendChild(el('div', 'bw-system-section-label', 'Daemon'));
    addSystemRow(grid, 'Version', vm.systemInfo.daemonVersion);
    addSystemRow(grid, 'Protocol', vm.systemInfo.protocolVersion);
    addSystemRow(grid, 'Socket', vm.systemInfo.socketPath);
    addSystemRow(grid, 'Connection', vm.systemInfo.connectionStatus);
    addSystemRow(grid, 'Controller', vm.systemInfo.controllerState);
  }

  // Workspace section
  grid.appendChild(el('div', 'bw-system-section-label', 'Workspace'));
  addSystemRow(grid, 'Status', vm.workspaceDescription || '—');
  if (vm.systemInfo) {
    addSystemRow(grid, 'Host', vm.systemInfo.workspaceHost);
  }

  // Capabilities
  if (vm.capabilityChips && vm.capabilityChips.length > 0) {
    grid.appendChild(el('div', 'bw-system-section-label', 'Capabilities'));
    const caps = el('div', 'bw-system-capabilities');
    for (const chip of vm.capabilityChips) {
      const c = el('span', 'bw-cap-chip bw-cap-chip--' + safe(chip.kind || 'ready'),
        safe(chip.label));
      caps.appendChild(c);
    }
    grid.appendChild(caps);
  }

  // Provider catalog
  if (vm.selectedModelOptions && vm.selectedModelOptions.length > 0) {
    grid.appendChild(el('div', 'bw-system-section-label', 'Models'));
    const providers = el('div', 'bw-system-providers');
    for (const model of vm.selectedModelOptions) {
      const chip = el('span', 'bw-system-provider-chip');
      chip.appendChild(el('span', 'bw-system-provider-dot'));
      chip.appendChild(document.createTextNode(modelOptionLabel(model)));
      providers.appendChild(chip);
    }
    grid.appendChild(providers);
  }

  // Recovery guidance
  if (vm.recoveryMessage) {
    const recovery = el('div', 'bw-system-recovery');
    recovery.appendChild(el('div', 'bw-system-recovery-title', 'Recovery'));
    recovery.appendChild(el('div', 'bw-system-recovery-msg', safe(vm.recoveryMessage)));
    grid.appendChild(recovery);
  }

  // Last error
  if (vm.lastError) {
    const errBlock = el('div', 'bw-system-recovery');
    errBlock.appendChild(el('div', 'bw-system-recovery-title', 'Last Error'));
    errBlock.appendChild(el('div', 'bw-system-recovery-msg', safe(vm.lastError)));
    grid.appendChild(errBlock);
  }
}

function addSystemRow(parent, label, value) {
  const row = el('div', 'bw-system-row');
  row.appendChild(el('span', 'bw-system-row-label', label));
  const val = el('span', 'bw-system-row-value', safe(value));
  row.appendChild(val);
  parent.appendChild(row);
}

function capitalize(str) {
  if (!str) {
    return str;
  }
  return str.charAt(0).toUpperCase() + str.slice(1);
}

/* ----------------------------------------------------------
   Render: Inspector
   ---------------------------------------------------------- */

function renderInspector(vm) {
  const content = document.getElementById('bw-inspector-content');
  if (!content) {
    return;
  }

  content.innerHTML = '';

  const run = vm.activeRun;
  const detail = vm.selectedRunDetail;

  if (!run) {
    const empty = el('div', 'bw-insp-empty');
    empty.appendChild(el('div', null, 'No run selected'));
    empty.appendChild(el('div', 'bw-insp-empty-hint',
      'Start a run to see details here.'));
    content.appendChild(empty);
    return;
  }

  // Run identity
  const identSection = el('div', 'bw-insp-section');
  identSection.appendChild(el('div', 'bw-insp-label', 'Run'));
  addInspRow(identSection, 'ID', safe(run.id).slice(0, 12));
  addInspRow(identSection, 'Phase', humanizePhase(run.phase));
  if (run.providerName) {
    addInspRow(identSection, 'Provider', run.providerName);
  }
  if (run.modelId) {
    addInspRow(identSection, 'Model', run.modelId);
  }
  if (run.updatedAt) {
    addInspRow(identSection, 'Updated', relativeTime(run.updatedAt) + ' ago');
  }
  content.appendChild(identSection);

  // Approval state
  if (vm.approvalState) {
    const approvalSection = el('div', 'bw-insp-section');
    approvalSection.appendChild(el('div', 'bw-insp-label', 'Approval'));

    const approval = el('div', 'bw-insp-approval');
    approval.appendChild(el('div', 'bw-insp-approval-title',
      safe(vm.approvalState.title || 'Approval Required')));
    approval.appendChild(el('div', 'bw-insp-approval-msg',
      safe(vm.approvalState.message)));

    const actions = el('div', 'bw-insp-approval-actions');
    const approveBtn = el('button', 'bw-btn bw-btn--primary bw-btn--sm', 'Approve');
    approveBtn.dataset.action = 'approveRun';
    const rejectBtn = el('button', 'bw-btn bw-btn--danger bw-btn--sm', 'Reject');
    rejectBtn.dataset.action = 'rejectRun';
    actions.appendChild(approveBtn);
    actions.appendChild(rejectBtn);
    approval.appendChild(actions);
    approvalSection.appendChild(approval);
    content.appendChild(approvalSection);
  }

  // Tool chain
  if (detail && detail.summary) {
    const toolSection = el('div', 'bw-insp-section');
    toolSection.appendChild(el('div', 'bw-insp-label', 'Activity'));
    const tool = el('div', 'bw-insp-tool');
    tool.appendChild(el('div', 'bw-insp-tool-name', safe(detail.summary)));
    toolSection.appendChild(tool);
    content.appendChild(toolSection);
  }

  // Usage
  if (detail && detail.usageText) {
    const usageSection = el('div', 'bw-insp-section');
    usageSection.appendChild(el('div', 'bw-insp-label', 'Usage'));

    // Parse usage text for structured display
    const usageParts = detail.usageText.split(' \u2022 ');
    if (usageParts.length >= 2) {
      addInspRow(usageSection, 'Provider', usageParts[0]);
      // Parse token counts from the second part
      const tokenMatch = usageParts[1].match(/in (\d+) \/ out (\d+) \/ cost ([\d.]+)/);
      if (tokenMatch) {
        const usage = el('div', 'bw-insp-usage');
        addUsageItem(usage, 'Input', formatNumber(parseInt(tokenMatch[1], 10)));
        addUsageItem(usage, 'Output', formatNumber(parseInt(tokenMatch[2], 10)));
        addUsageItem(usage, 'Cost', '$' + tokenMatch[3]);
        addUsageItem(usage, 'Total', formatNumber(parseInt(tokenMatch[1], 10) + parseInt(tokenMatch[2], 10)));
        usageSection.appendChild(usage);
      } else {
        addInspRow(usageSection, 'Tokens', usageParts[1]);
      }
    } else {
      addInspRow(usageSection, 'Summary', detail.usageText);
    }
    content.appendChild(usageSection);
  }

  // Loop state
  if (detail && detail.loopDecisionText) {
    const loopSection = el('div', 'bw-insp-section');
    loopSection.appendChild(el('div', 'bw-insp-label', 'Loop'));
    const loopTool = el('div', 'bw-insp-tool');
    loopTool.appendChild(el('div', 'bw-insp-tool-name', safe(detail.loopDecisionText)));
    loopSection.appendChild(loopTool);
    content.appendChild(loopSection);
  }

  // Arbitration
  if (detail && detail.arbitrationInfo) {
    const arbSection = el('div', 'bw-insp-section');
    arbSection.appendChild(el('div', 'bw-insp-label', 'Controller'));
    addInspRow(arbSection, 'State', detail.arbitrationInfo);
    content.appendChild(arbSection);
  }

  // Recovery
  if (detail && detail.recoveryMessage) {
    const recSection = el('div', 'bw-insp-section');
    recSection.appendChild(el('div', 'bw-insp-label', 'Recovery'));
    const recMsg = el('div', 'bw-insp-tool');
    recMsg.appendChild(el('div', 'bw-insp-tool-name', safe(detail.recoveryMessage)));
    recSection.appendChild(recMsg);
    content.appendChild(recSection);
  }

  // Run actions
  if (run.source === 'daemon') {
    const actSection = el('div', 'bw-insp-section');
    actSection.appendChild(el('div', 'bw-insp-label', 'Actions'));
    const actRow = el('div', 'bw-insp-approval-actions');
    const cancelBtn = el('button', 'bw-btn bw-btn--secondary bw-btn--sm', 'Cancel');
    cancelBtn.dataset.action = 'cancelRun';
    const retryBtn = el('button', 'bw-btn bw-btn--secondary bw-btn--sm', 'Retry');
    retryBtn.dataset.action = 'retryRun';
    actRow.appendChild(cancelBtn);
    actRow.appendChild(retryBtn);
    actSection.appendChild(actRow);
    content.appendChild(actSection);
  }
}

function addInspRow(parent, key, value) {
  const row = el('div', 'bw-insp-row');
  row.appendChild(el('span', 'bw-insp-row-key', key));
  row.appendChild(el('span', 'bw-insp-row-value', safe(value)));
  parent.appendChild(row);
}

function addUsageItem(parent, label, value) {
  const item = el('div', 'bw-insp-usage-item');
  item.appendChild(el('span', 'bw-insp-usage-label', label));
  item.appendChild(el('span', 'bw-insp-usage-value', value));
  parent.appendChild(item);
}

function formatNumber(n) {
  if (n >= 1000000) {
    return (n / 1000000).toFixed(1) + 'M';
  }
  if (n >= 1000) {
    return (n / 1000).toFixed(1) + 'k';
  }
  return String(n);
}

/* ----------------------------------------------------------
   Render: Composer (shared across sections, lives in Command)
   ---------------------------------------------------------- */

function renderComposer(vm) {
  const modelSelect = document.querySelector('.bw-model-select');
  if (modelSelect && Array.isArray(vm.selectedModelOptions)) {
    const prevValue = modelSelect.value;
    modelSelect.innerHTML = '';
    for (const opt of vm.selectedModelOptions) {
      const option = document.createElement('option');
      option.value = safe(opt.id);
      option.textContent = modelOptionLabel(opt);
      modelSelect.appendChild(option);
    }
    if (prevValue && Array.from(modelSelect.options).some(option => option.value === prevValue)) {
      modelSelect.value = prevValue;
    } else if (modelSelect.options.length > 0) {
      modelSelect.selectedIndex = 0;
    }
  }

  // Composer enabled/disabled
  const composerInput = document.querySelector('.bw-composer-input');
  const startBtn = document.querySelector("[data-action='startRun']");
  const disabledMsg = document.querySelector('.bw-composer-disabled-msg');
  const composerEnabled = vm.isComposerEnabled !== false;

  if (composerInput) {
    composerInput.disabled = !composerEnabled;
  }
  if (startBtn) {
    startBtn.disabled = !composerEnabled;
  }
  if (modelSelect) {
    modelSelect.disabled = !composerEnabled;
  }
  if (disabledMsg) {
    disabledMsg.dataset.visible = composerEnabled ? 'false' : 'true';
    if (!composerEnabled && vm.composerDisabledReason) {
      disabledMsg.textContent = safe(vm.composerDisabledReason);
    }
  }
}

/* ----------------------------------------------------------
   Main render
   ---------------------------------------------------------- */

function render(vm) {
  if (!vm) {
    return;
  }

  renderCommandSection(vm);
  renderRunsSection(vm);
  renderSystemSection(vm);
  renderInspector(vm);
  renderComposer(vm);
}

/* ----------------------------------------------------------
   Start run
   ---------------------------------------------------------- */

function handleStartRun() {
  const promptEl = document.querySelector('.bw-composer-input');
  const prompt = promptEl?.value?.trim();
  if (!prompt) {
    return;
  }

  const modelSelect = document.querySelector('.bw-model-select');
  const modelID = modelSelect?.value;
  if (!modelID) {
    return;
  }

  vscode.postMessage({ type: 'startRun', prompt, modelID, mode: selectedMode });
  promptEl.value = '';
}

/* ----------------------------------------------------------
   Message handler (host → webview)
   ---------------------------------------------------------- */

function isHostMessageData(msg) {
  const hostNonce = globalThis.__OPENBURNBAR_HOST_NONCE__;
  return Boolean(
    hostNonce
    && msg
    && typeof msg === 'object'
    && msg.hostNonce === hostNonce
    && (msg.type === 'snapshot' || msg.type === 'error' || msg.type === 'restoreSection')
  );
}

function isTrustedHostMessageEvent(event) {
  const origin = typeof event.origin === 'string' ? event.origin : '';
  if (origin === window.location.origin || origin.startsWith('vscode-webview://')) {
    return true;
  }
  return window.location.protocol === 'https:' && origin.startsWith('https://');
}

window.addEventListener('message', event => {
  if (!isTrustedHostMessageEvent(event)) {
    return;
  }

  const msg = event.data;
  if (!isHostMessageData(msg)) {
    return;
  }

  if (msg.type === 'snapshot') {
    currentViewModel = msg.viewModel;
    render(currentViewModel);
  } else if (msg.type === 'error') {
    showError(safe(msg.message));
  } else if (msg.type === 'restoreSection') {
    if (msg.section) {
      switchSection(msg.section);
    }
  }
});

/* ----------------------------------------------------------
   Delegated event listeners
   ---------------------------------------------------------- */

document.addEventListener('DOMContentLoaded', () => {
  const root = document.querySelector('.bw-workspace');
  if (!root) {
    return;
  }

  // Initialize rail indicator position
  requestAnimationFrame(() => updateRailIndicator(activeSection));

  root.addEventListener('click', e => {
    // Rail section buttons
    const railBtn = e.target.closest('.bw-rail-btn[data-section]');
    if (railBtn) {
      switchSection(railBtn.dataset.section);
      return;
    }

    // Mode chips
    const modeChip = e.target.closest('.bw-mode-chip');
    if (modeChip) {
      selectedMode = modeChip.dataset.mode;
      document.querySelectorAll('.bw-mode-chip').forEach(c =>
        c.classList.toggle('bw-mode-chip--active', c.dataset.mode === selectedMode));
      return;
    }

    // Run rows (select run)
    const runRow = e.target.closest('.bw-run-row[data-run-id]');
    if (runRow && !e.target.closest('[data-action]')) {
      vscode.postMessage({ type: 'selectRun', runId: runRow.dataset.runId });
      return;
    }

    // Active run banner (select run)
    const activeBanner = e.target.closest('.bw-active-run[data-run-id]');
    if (activeBanner && !e.target.closest('[data-action]')) {
      vscode.postMessage({ type: 'selectRun', runId: activeBanner.dataset.runId });
      return;
    }

    // Action buttons
    const btn = e.target.closest('[data-action]');
    if (!btn) {
      return;
    }

    const action = btn.dataset.action;
    const runId =
      btn.closest('[data-run-id]')?.dataset?.runId ??
      currentViewModel?.selectedRunId;

    switch (action) {
    case 'refresh':
      vscode.postMessage({ type: 'refresh' });
      break;
    case 'repair':
      vscode.postMessage({ type: 'repair' });
      break;
    case 'startRun':
      handleStartRun();
      break;
    case 'cancelRun':
      vscode.postMessage({ type: 'cancelRun', runId });
      break;
    case 'retryRun':
      vscode.postMessage({ type: 'retryRun', runId });
      break;
    case 'approveRun':
      vscode.postMessage({ type: 'approveRun', runId });
      break;
    case 'rejectRun':
      vscode.postMessage({ type: 'rejectRun', runId });
      break;
    case 'openApp':
      vscode.postMessage({ type: 'openApp' });
      break;
    case 'openConversationSearch':
      vscode.postMessage({ type: 'openConversationSearch' });
      break;
    default:
      break;
    }
  });

  // Composer keyboard shortcut
  const composerInput = document.querySelector('.bw-composer-input');
  if (composerInput) {
    composerInput.addEventListener('keydown', e => {
      if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
        e.preventDefault();
        handleStartRun();
      }
    });
  }
});
