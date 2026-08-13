import { getBrowserAPI } from '../shared/browser';
import type { BackgroundPush, PopupRequest, PopupResponse, TrustSettings } from '../shared/messages';
import { renderPopup } from './render';
import { createInitialPopupState, reducePopupState, type PopupLocalAction, type PopupLocalState } from './state';
import { buildPopupViewModel } from './viewModel';

const browserAPI = getBrowserAPI();
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
): Promise<void> {
  dispatch({ type: 'submitting', value: true });
  try {
    const response = (await browserAPI.runtime.sendMessage(request)) as PopupResponse;
    if (response.snapshot) {
      dispatch({ type: 'snapshot', snapshot: response.snapshot });
    }
    if (response.ok && options.clearDraft) {
      dispatch({ type: 'draft', value: '' });
    }
    if (response.ok && options.clearCorrectionDraft) {
      dispatch({ type: 'correctionDraft', value: '' });
    }
  } finally {
    dispatch({ type: 'submitting', value: false });
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
      void send({ type: 'popup.setMode', mode });
    }
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
  switch (action) {
    case 'abort':
      void send({ type: 'popup.abort' });
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
    void send({ type: 'popup.abort' });
    return;
  }
  if (event.key === 'Enter' && event.metaKey && event.target instanceof HTMLTextAreaElement) {
    event.preventDefault();
    event.target.form?.requestSubmit();
  }
});

browserAPI.runtime.onMessage.addListener((message) => {
  const push = message as Partial<BackgroundPush>;
  if (push.type === 'background.snapshot' && push.snapshot) {
    dispatch({ type: 'snapshot', snapshot: push.snapshot });
  }
  return undefined;
});

renderPopup(appRoot, buildPopupViewModel(state));
void send({ type: 'popup.bootstrap' });
