import { getBrowserAPI } from '../shared/browser';
import {
  isBackgroundPush,
  isPopupResponse,
  type PopupRequest,
  type PopupResponse,
  type TrustSettings
} from '../shared/messages';
import type { SafariPerformanceOutcome } from '../shared/performance';
import { buildSafariPerformanceExport, safariPerformanceExportFilename } from './diagnostics';
import { renderPopup } from './render';
import { createInitialPopupState, reducePopupState, type PopupLocalAction, type PopupLocalState } from './state';
import { buildPopupViewModel } from './viewModel';

const browserAPI = getBrowserAPI();
const ALL_WEBSITE_ORIGINS = ['http://*/*', 'https://*/*'] as const;
const popupOpenedAt = performance.now();
const root = document.getElementById('app');
if (!root) {
  throw new Error('OpenBurnBar popup root is missing.');
}
const appRoot = root;

let state: PopupLocalState = createInitialPopupState();
let refreshTimer: number | undefined;
// Safari's permission sheet is modal and asynchronous. While it is open the
// popup must stop advancing controller state, or a scheduled popup.refresh
// bumps stateVersion and the authorize call below is rejected as
// authorization_page_changed after Safari has already granted access.
let permissionSheetOpen = false;

function dispatch(action: PopupLocalAction): void {
  state = reducePopupState(state, action);
  renderPopup(appRoot, buildPopupViewModel(state));
  scheduleRefresh();
}

async function send(
  request: PopupRequest,
  options: { clearCorrectionDraft?: boolean; clearDraft?: boolean } = {}
): Promise<PopupResponse> {
  dispatch({ type: 'submitting', value: true });
  try {
    const response = await browserAPI.runtime.sendMessage(request);
    if (!isPopupResponse(response)) {
      throw new Error('OpenBurnBar returned an invalid popup response.');
    }
    if (response.snapshot) {
      dispatch({ type: 'snapshot', snapshot: response.snapshot });
    }
    if (response.ok && options.clearDraft) {
      dispatch({ type: 'draft', value: '' });
    }
    if (response.ok && options.clearCorrectionDraft) {
      dispatch({ type: 'correctionDraft', value: '' });
    }
    return response;
  } finally {
    dispatch({ type: 'submitting', value: false });
  }
}

function performanceExportJSON(snapshot: PopupResponse['snapshot'], exportedAt: Date): string {
  return JSON.stringify(
    buildSafariPerformanceExport(snapshot, browserAPI.runtime.getManifest().version, exportedAt),
    null,
    2
  );
}

async function refreshPerformanceSnapshot(): Promise<NonNullable<PopupResponse['snapshot']>> {
  const response = await browserAPI.runtime.sendMessage({
    type: 'popup.performanceSnapshot'
  } satisfies PopupRequest);
  if (!isPopupResponse(response)) {
    throw new Error('OpenBurnBar returned an invalid performance response.');
  }
  if (!response.ok || !response.snapshot?.performance) {
    throw new Error('Performance evidence is not ready.');
  }
  dispatch({ type: 'snapshot', snapshot: response.snapshot });
  return response.snapshot;
}

async function copyPerformanceDiagnostics(): Promise<void> {
  dispatch({ type: 'diagnosticsClearArmed', value: false });
  try {
    if (!navigator.clipboard?.writeText) {
      throw new Error('Safari clipboard access is unavailable.');
    }
    const snapshot = await refreshPerformanceSnapshot();
    await navigator.clipboard.writeText(performanceExportJSON(snapshot, new Date()));
    dispatch({
      type: 'diagnosticsNotice',
      notice: {
        tone: 'success',
        text: 'Privacy-safe performance JSON copied.'
      }
    });
  } catch {
    dispatch({
      type: 'diagnosticsNotice',
      notice: {
        tone: 'error',
        text: 'Could not copy in Safari. Use Download JSON instead.'
      }
    });
  }
}

async function downloadPerformanceDiagnostics(): Promise<void> {
  dispatch({ type: 'diagnosticsClearArmed', value: false });
  try {
    const snapshot = await refreshPerformanceSnapshot();
    const exportedAt = new Date();
    const url = URL.createObjectURL(
      new Blob([performanceExportJSON(snapshot, exportedAt)], {
        type: 'application/json;charset=utf-8'
      })
    );
    const anchor = document.createElement('a');
    anchor.href = url;
    anchor.download = safariPerformanceExportFilename(exportedAt);
    anchor.hidden = true;
    document.body.append(anchor);
    anchor.click();
    anchor.remove();
    window.setTimeout(() => URL.revokeObjectURL(url), 0);
    dispatch({
      type: 'diagnosticsNotice',
      notice: {
        tone: 'success',
        text: 'Privacy-safe performance JSON downloaded.'
      }
    });
  } catch {
    dispatch({
      type: 'diagnosticsNotice',
      notice: {
        tone: 'error',
        text: 'Safari could not create the JSON download.'
      }
    });
  }
}

async function clearPerformanceDiagnostics(): Promise<void> {
  if (!state.diagnosticsClearArmed) {
    dispatch({ type: 'diagnosticsClearArmed', value: true });
    dispatch({
      type: 'diagnosticsNotice',
      notice: {
        tone: 'warning',
        text: 'Click Confirm clear to erase the retained local timing window.'
      }
    });
    return;
  }
  try {
    const response = await browserAPI.runtime.sendMessage({
      type: 'popup.clearPerformance'
    } satisfies PopupRequest);
    if (!isPopupResponse(response)) {
      throw new Error('OpenBurnBar returned an invalid performance response.');
    }
    if (!response.ok || !response.snapshot?.performance) {
      throw new Error('Performance evidence could not be cleared.');
    }
    dispatch({ type: 'snapshot', snapshot: response.snapshot });
    dispatch({ type: 'diagnosticsClearArmed', value: false });
    dispatch({
      type: 'diagnosticsNotice',
      notice: {
        tone: 'success',
        text: 'Local performance samples cleared.'
      }
    });
  } catch {
    dispatch({ type: 'diagnosticsClearArmed', value: false });
    dispatch({
      type: 'diagnosticsNotice',
      notice: {
        tone: 'error',
        text: 'Safari could not clear the local performance samples.'
      }
    });
  }
}

async function recordPopupBootstrap(outcome: SafariPerformanceOutcome): Promise<void> {
  try {
    const response = await browserAPI.runtime.sendMessage({
      type: 'popup.recordPerformance',
      metric: 'popup_bootstrap',
      durationMs: Math.max(0, performance.now() - popupOpenedAt),
      outcome
    } satisfies PopupRequest);
    if (!isPopupResponse(response)) {
      return;
    }
    if (response.snapshot) {
      dispatch({ type: 'snapshot', snapshot: response.snapshot });
    }
  } catch {
    // Diagnostics must never make the popup unavailable.
  }
}

function scheduleRefresh(): void {
  if (refreshTimer !== undefined) {
    window.clearTimeout(refreshTimer);
    refreshTimer = undefined;
  }
  if (permissionSheetOpen) {
    return;
  }
  const interval = state.snapshot?.running || state.snapshot?.mode === 'watch' ? 1_250 : 5_000;
  refreshTimer = window.setTimeout(() => {
    void send({ type: 'popup.refresh' });
  }, interval);
}

function trustPatch(key: keyof TrustSettings, value: boolean): PopupRequest {
  return {
    type: 'popup.setTrust',
    patch: {
      [key]: value
    }
  };
}

async function completePermissionSetup(): Promise<void> {
  const snapshot = state.snapshot;
  const page = snapshot?.page;
  if (!snapshot || !page) {
    return;
  }
  let expectedOrigin: string;
  try {
    expectedOrigin = new URL(page.url).origin;
  } catch {
    return;
  }
  const acknowledgeCloudScreenshots = Boolean(
    buildPopupViewModel(state).selectedAgent?.cloud && !snapshot.trust.cloudScreenshotAcknowledged
  );

  // Safari requires permissions.request to begin synchronously inside the
  // user's click. Moving this call behind runtime.sendMessage loses the user
  // gesture and Safari rejects the request without presenting its sheet.
  let websiteAccessGranted = false;
  permissionSheetOpen = true;
  scheduleRefresh();
  try {
    websiteAccessGranted = await browserAPI.permissions.request({
      origins: [...ALL_WEBSITE_ORIGINS]
    });
  } catch {
    websiteAccessGranted = false;
  } finally {
    permissionSheetOpen = false;
  }

  // A refresh already in flight when the sheet opened can still have landed, so
  // authorize against the version the popup holds now. The tab and origin
  // captured before the sheet stay pinned, and the controller re-verifies both
  // against the live tab after the sheet closes.
  const expectedStateVersion = state.snapshot?.stateVersion ?? snapshot.stateVersion;

  await send({
    type: 'popup.authorizePage',
    expectedStateVersion,
    expectedTabId: page.tabId,
    expectedOrigin,
    acknowledgeCloudScreenshots,
    websiteAccessGranted
  });
}

appRoot.addEventListener('click', (event) => {
  const target = event.target instanceof Element ? event.target.closest<HTMLElement>('[data-action]') : null;
  if (!target || target instanceof HTMLButtonElement === false) {
    return;
  }
  const action = target.dataset.action;
  if (!action) {
    return;
  }
  if (action.startsWith('mode:')) {
    const mode = action.slice('mode:'.length);
    if (mode === 'ask' || mode === 'agentic' || mode === 'watch' || mode === 'handoff') {
      appRoot.dataset.modePopoverOpen = 'false';
      void send({ type: 'popup.setMode', mode });
    }
    return;
  }
  if (action === 'toggle-mode-popover') {
    appRoot.dataset.modelPickerOpen = 'false';
    appRoot.dataset.modePopoverOpen = appRoot.dataset.modePopoverOpen === 'true' ? 'false' : 'true';
    renderPopup(appRoot, buildPopupViewModel(state));
    return;
  }
  if (action === 'toggle-model-picker') {
    appRoot.dataset.modePopoverOpen = 'false';
    appRoot.dataset.modelPickerOpen = appRoot.dataset.modelPickerOpen === 'true' ? 'false' : 'true';
    renderPopup(appRoot, buildPopupViewModel(state));
    return;
  }
  if (action === 'select-agent') {
    const agentId = target.dataset.agentId;
    if (agentId) {
      appRoot.dataset.modelPickerOpen = 'false';
      void send({ type: 'popup.selectAgent', agentId });
    }
    return;
  }
  if (action === 'toggle-tools') {
    appRoot.dataset.toolsOpen = appRoot.dataset.toolsOpen === 'true' ? 'false' : 'true';
    renderPopup(appRoot, buildPopupViewModel(state));
    return;
  }
  if (action === 'toggle-popup-shape') {
    const nextShape = appRoot.dataset.popupShape === 'compact' ? 'expanded' : 'compact';
    appRoot.dataset.popupShape = nextShape;
    document.documentElement.dataset.popupShape = nextShape;
    renderPopup(appRoot, buildPopupViewModel(state));
    return;
  }
  if (action === 'complete-permission-setup') {
    void completePermissionSetup();
    return;
  }
  if (action.startsWith('approval:')) {
    const [, approvalId, decision] = action.split(':');
    if (approvalId && (decision === 'allow_once' || decision === 'allow_session' || decision === 'block')) {
      void send({ type: 'popup.approval', approvalId, decision });
    }
    return;
  }
  if (action.startsWith('learning:')) {
    const [, itemId, decision] = action.split(':');
    if (itemId && (decision === 'approve' || decision === 'reject' || decision === 'forget')) {
      void send({ type: 'popup.learningReview', itemId, decision });
    }
    return;
  }
  if (action === 'diagnostics-copy') {
    void copyPerformanceDiagnostics();
    return;
  }
  if (action === 'diagnostics-download') {
    void downloadPerformanceDiagnostics();
    return;
  }
  if (action === 'diagnostics-clear') {
    void clearPerformanceDiagnostics();
    return;
  }
  switch (action) {
    case 'abort':
      void send({ type: 'popup.abort', trigger: 'stop_button' });
      break;
    case 'refresh':
      void send({ type: 'popup.refresh' });
      break;
    case 'request-permission':
      void send({ type: 'popup.requestSitePermission' });
      break;
  }
});

appRoot.addEventListener('input', (event) => {
  const input = event.target;
  if (!(input instanceof HTMLInputElement || input instanceof HTMLTextAreaElement)) {
    return;
  }
  switch (input.dataset.input) {
    case 'agent-filter':
      dispatch({ type: 'agentFilter', value: input.value });
      break;
    case 'draft':
      dispatch({ type: 'draft', value: input.value });
      break;
    case 'mode-range': {
      const index = Number(input.value);
      const options = appRoot.querySelectorAll<HTMLButtonElement>('.mode-button[data-action^="mode:"]');
      const option = options.item(index);
      const label = option?.textContent?.trim();
      const description = option?.dataset.modeDescription;
      const value = appRoot.querySelector<HTMLElement>('.mode-popover-value');
      const descriptionNode = appRoot.querySelector<HTMLElement>('.mode-description');
      const track = appRoot.querySelector<HTMLElement>('.mode-track');
      if (option && label && description && value && descriptionNode && track) {
        value.textContent = label;
        descriptionNode.textContent = description;
        input.setAttribute('aria-valuetext', label);
        const knobFraction = options.length > 1 ? index / (options.length - 1) : 0;
        track.style.setProperty('--mode-fraction', String(knobFraction));
      }
      break;
    }
    case 'correction-draft':
      dispatch({ type: 'correctionDraft', value: input.value });
      break;
  }
});

appRoot.addEventListener('change', (event) => {
  const input = event.target;
  if (!(input instanceof HTMLInputElement)) {
    return;
  }
  if (input.dataset.input === 'mode-range') {
    const index = Number(input.value);
    const option = appRoot.querySelectorAll<HTMLButtonElement>('.mode-button[data-action^="mode:"]').item(index);
    const mode = option?.dataset.action?.slice('mode:'.length);
    if (mode === 'ask' || mode === 'agentic' || mode === 'watch' || mode === 'handoff') {
      appRoot.dataset.modePopoverOpen = 'false';
      if (mode === state.snapshot?.mode) {
        renderPopup(appRoot, buildPopupViewModel(state));
      } else {
        void send({ type: 'popup.setMode', mode });
      }
    }
    return;
  }
  switch (input.dataset.input) {
    case 'trust-site':
      void send(trustPatch('siteAllowed', input.checked));
      break;
    case 'trust-tab':
      void send(trustPatch('onlyCurrentTab', input.checked));
      break;
    case 'trust-sensitive':
      void send(trustPatch('sensitiveSiteOverride', input.checked));
      break;
    case 'trust-cloud':
      void send(trustPatch('cloudScreenshotAcknowledged', input.checked));
      break;
    case 'trust-kill':
      void send(trustPatch('globalKillSwitch', input.checked));
      break;
    case 'learning-opt-in':
      void send({ type: 'popup.setLearning', optedIn: input.checked });
      break;
  }
});

appRoot.addEventListener('toggle', (event) => {
  if (event.target instanceof HTMLDetailsElement && event.target.classList.contains('agent-drawer')) {
    renderPopup(appRoot, buildPopupViewModel(state));
  }
});

appRoot.addEventListener('submit', (event) => {
  if (!(event.target instanceof HTMLFormElement)) {
    return;
  }
  event.preventDefault();
  if (event.target.dataset.form === 'learning-correction') {
    const correction = state.correctionDraft.trim();
    const byteLength = new TextEncoder().encode(correction).byteLength;
    if (byteLength < 8 || byteLength > 4 * 1_024) {
      return;
    }
    void send({ type: 'popup.teachCorrection', correction }, { clearCorrectionDraft: true });
    return;
  }
  if (event.target.dataset.form !== 'composer') {
    return;
  }
  const prompt = state.draft.trim();
  if (!prompt) {
    return;
  }
  const mode = state.snapshot?.mode ?? 'ask';
  if (mode === 'ask') {
    void send({ type: 'popup.ask', prompt }, { clearDraft: true });
  } else if (mode === 'agentic') {
    void send({ type: 'popup.startAgentic', prompt }, { clearDraft: true });
  } else if (mode === 'handoff') {
    void send({ type: 'popup.handoff', prompt }, { clearDraft: true });
  }
});

appRoot.addEventListener('keydown', (event) => {
  if (event.key === '.' && event.ctrlKey && event.altKey && event.metaKey) {
    event.preventDefault();
    void send({ type: 'popup.abort', trigger: 'popup_shortcut' });
    return;
  }
  if (event.key === 'Enter' && event.metaKey && event.target instanceof HTMLTextAreaElement) {
    event.preventDefault();
    event.target.form?.requestSubmit();
    return;
  }
  const modelTrigger =
    event.target instanceof Element ? event.target.closest<HTMLElement>('.model-picker-trigger') : null;
  const modelOption =
    event.target instanceof Element ? event.target.closest<HTMLButtonElement>('.model-picker-option') : null;
  if (modelTrigger && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
    event.preventDefault();
    appRoot.dataset.modelPickerOpen = 'true';
    renderPopup(appRoot, buildPopupViewModel(state));
    const options = [...appRoot.querySelectorAll<HTMLButtonElement>('.model-picker-option')];
    const selected = options.findIndex((option) => option.getAttribute('aria-selected') === 'true');
    const index = event.key === 'ArrowUp' ? Math.max(0, selected - 1) : Math.min(options.length - 1, selected + 1);
    options[index]?.focus();
    return;
  }
  if (modelOption && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
    event.preventDefault();
    const options = [...appRoot.querySelectorAll<HTMLButtonElement>('.model-picker-option')];
    const index = options.indexOf(modelOption);
    const nextIndex = event.key === 'ArrowDown' ? Math.min(options.length - 1, index + 1) : Math.max(0, index - 1);
    options[nextIndex]?.focus();
    return;
  }
  if (event.key === 'Escape' && appRoot.dataset.modelPickerOpen === 'true') {
    event.preventDefault();
    appRoot.dataset.modelPickerOpen = 'false';
    renderPopup(appRoot, buildPopupViewModel(state));
    appRoot.querySelector<HTMLButtonElement>('.model-picker-trigger')?.focus();
  }
});

browserAPI.runtime.onMessage.addListener((message) => {
  if (isBackgroundPush(message)) {
    dispatch({ type: 'snapshot', snapshot: message.snapshot });
  }
  return undefined;
});

renderPopup(appRoot, buildPopupViewModel(state));
void (async () => {
  let outcome: SafariPerformanceOutcome = 'success';
  try {
    const response = await send({ type: 'popup.bootstrap' });
    if (!response.ok) {
      outcome = 'error';
    }
  } catch {
    outcome = 'error';
    dispatch({ type: 'initialized' });
  } finally {
    await recordPopupBootstrap(outcome);
  }
})();
