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
  initialized: boolean;
  submitting: boolean;
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
  | { type: 'initialized' };

export function createInitialPopupState(): PopupLocalState {
  return {
    agentFilter: '',
    correctionDraft: '',
    diagnosticsClearArmed: false,
    draft: '',
    initialized: false,
    submitting: false
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
  }
}
