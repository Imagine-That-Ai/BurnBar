import type { PopupSnapshot } from '../shared/messages';

export interface PopupLocalState {
  snapshot?: PopupSnapshot;
  agentFilter: string;
  correctionDraft: string;
  diagnosticsNotice?: {
    tone: 'success' | 'warning' | 'error';
    text: string;
  };
  diagnosticsClearArmed: boolean;
  draft: string;
  sendVisualState?: 'clicked';
  initialized: boolean;
  submitting: boolean;
  fullScreenPromptOpen: boolean;
  fullScreenPromptRemember: boolean;
  /** Undefined once the welcome is done; otherwise the visible step index. */
  welcomeStep?: number;
  feedbackOpen: boolean;
  feedbackDraft: string;
  feedbackIncludeDiagnostics: boolean;
  feedbackNotice?: {
    tone: 'success' | 'warning' | 'error';
    text: string;
  };
}

export type PopupLocalAction =
  | { type: 'snapshot'; snapshot: PopupSnapshot }
  | { type: 'agentFilter'; value: string }
  | { type: 'correctionDraft'; value: string }
  | {
      type: 'diagnosticsNotice';
      notice?: {
        tone: 'success' | 'warning' | 'error';
        text: string;
      };
    }
  | { type: 'diagnosticsClearArmed'; value: boolean }
  | { type: 'draft'; value: string }
  | { type: 'submitting'; value: boolean }
  | { type: 'initialized' }
  | { type: 'welcomeStep'; step?: number }
  | { type: 'fullScreenPrompt'; open: boolean }
  | { type: 'fullScreenPromptRemember'; value: boolean }
  | { type: 'feedbackOpen'; value: boolean }
  | { type: 'feedbackDraft'; value: string }
  | { type: 'feedbackIncludeDiagnostics'; value: boolean }
  | {
      type: 'feedbackNotice';
      notice?: {
        tone: 'success' | 'warning' | 'error';
        text: string;
      };
    };

export function createInitialPopupState(): PopupLocalState {
  return {
    agentFilter: '',
    correctionDraft: '',
    diagnosticsClearArmed: false,
    draft: '',
    initialized: false,
    submitting: false,
    fullScreenPromptOpen: false,
    fullScreenPromptRemember: false,
    feedbackOpen: false,
    feedbackDraft: '',
    feedbackIncludeDiagnostics: true
  };
}

export function reducePopupState(state: PopupLocalState, action: PopupLocalAction): PopupLocalState {
  switch (action.type) {
    case 'snapshot':
      return {
        ...state,
        snapshot: action.snapshot,
        initialized: true
      };
    case 'agentFilter':
      return { ...state, agentFilter: action.value };
    case 'correctionDraft':
      return { ...state, correctionDraft: action.value };
    case 'diagnosticsNotice':
      if (action.notice) {
        return { ...state, diagnosticsNotice: action.notice };
      }
      {
        const next = { ...state };
        delete next.diagnosticsNotice;
        return next;
      }
    case 'diagnosticsClearArmed':
      return { ...state, diagnosticsClearArmed: action.value };
    case 'draft':
      return { ...state, draft: action.value };
    case 'submitting':
      return { ...state, submitting: action.value };
    case 'initialized':
      return { ...state, initialized: true };
    case 'welcomeStep':
      if (action.step === undefined) {
        const next = { ...state };
        delete next.welcomeStep;
        return next;
      }
      return { ...state, welcomeStep: action.step };
    case 'fullScreenPrompt':
      return { ...state, fullScreenPromptOpen: action.open };
    case 'fullScreenPromptRemember':
      return { ...state, fullScreenPromptRemember: action.value };
    case 'feedbackOpen':
      return { ...state, feedbackOpen: action.value };
    case 'feedbackDraft':
      return { ...state, feedbackDraft: action.value };
    case 'feedbackIncludeDiagnostics':
      return { ...state, feedbackIncludeDiagnostics: action.value };
    case 'feedbackNotice':
      if (action.notice) {
        return { ...state, feedbackNotice: action.notice };
      }
      {
        const next = { ...state };
        delete next.feedbackNotice;
        return next;
      }
  }
}
