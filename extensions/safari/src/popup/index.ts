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
const popupOpenedAt = performance.now();
const root = document.getElementById('app');
if (!root) {
  throw new Error('OpenBurnBar popup root is missing.');
}
const appRoot = root;

let state: PopupLocalState = createInitialPopupState();
let refreshTimer: number | undefined;

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
    appRoot.dataset.modePopoverOpen = appRoot.dataset.modePopoverOpen === 'true' ? 'false' : 'true';
    renderPopup(appRoot, buildPopupViewModel(state));
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
      const knob = appRoot.querySelector<HTMLElement>('.mode-knob');
      if (option && label && description && value && descriptionNode && knob) {
        value.textContent = label;
        descriptionNode.textContent = description;
        input.setAttribute('aria-valuetext', label);
        const knobFraction = options.length > 1 ? index / (options.length - 1) : 0;
        knob.style.setProperty('--mode-fraction', String(knobFraction));
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
  if (input instanceof HTMLSelectElement && input.dataset.input === 'agent') {
    void send({ type: 'popup.selectAgent', agentId: input.value });
    return;
  }
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
