/**
 * Workspace panel webview script.
 *
 * Manages the sidebar panel showing agent run history, tool calls,
 * and approval UI. Communicates with the extension via RPC messages.
 */

import type { BurnBarRunProjection, BurnBarToolCallSnapshot } from '../types';

interface WorkspaceState {
  selectedRunId?: string;
  runs: BurnBarRunProjection[];
}

const state: WorkspaceState = {
  runs: [],
  selectedRunId: undefined
};

const runsList = document.getElementById('runs-list');
const runDetail = document.getElementById('run-detail');
const emptyState = document.getElementById('empty-state');

/**
 * Request initial state from the extension.
 */
export function requestInitialState(): void {
  acquireVsCodeApi().postMessage({ type: 'workspace.requestState' });
}

/**
 * Handle messages from the extension.
 */
export function handleMessage(message: { type: string; payload?: unknown }): void {
  switch (message.type) {
  case 'workspace.stateUpdated': {
    const payload = message.payload as {
        runs?: BurnBarRunProjection[];
        selectedRunId?: string;
      };
    if (payload.runs !== undefined) {
      state.runs = payload.runs;
    }
    if (payload.selectedRunId !== undefined) {
      state.selectedRunId = payload.selectedRunId;
    }
    render();
    break;
  }

  case 'workspace.runSelected': {
    const payload = message.payload as { runId: string };
    state.selectedRunId = payload.runId;
    render();
    break;
  }

  case 'workspace.toolCallUpdated': {
    const payload = message.payload as {
        runId: string;
        toolCall: BurnBarToolCallSnapshot;
      };
    updateToolCall(payload.runId, payload.toolCall);
    break;
  }

  case 'workspace.runDeleted': {
    const payload = message.payload as { runId: string };
    deleteRun(payload.runId);
    break;
  }

  default:
    console.warn('Unknown message type:', message.type);
  }
}

/**
 * Render the workspace panel based on current state.
 */
function render(): void {
  if (!runsList || !runDetail || !emptyState) {
    console.error('Required DOM elements not found');
    return;
  }

  if (state.runs.length === 0) {
    runsList.innerHTML = '';
    runDetail.innerHTML = '';
    emptyState.style.display = 'block';
    return;
  }

  emptyState.style.display = 'none';
  renderRunsList();
  renderRunDetail();
}

/**
 * Render the list of runs in the sidebar.
 */
function renderRunsList(): void {
  if (!runsList) {
    return;
  }

  runsList.innerHTML = state.runs
    .map((run) => {
      const phase = escapeHtml(String(run.phase));
      return `
      <div class="run-item ${run.id === state.selectedRunId ? 'selected' : ''}" data-run-id="${escapeHtml(run.id)}">
        <div class="run-title">${escapeHtml(run.title || 'Untitled Run')}</div>
        <div class="run-meta">
          <span class="run-phase run-phase--${phase}">${phase}</span>
          ${run.providerName ? `<span class="run-provider">${escapeHtml(run.providerName)}</span>` : ''}
        </div>
        <div class="run-date">${escapeHtml(formatDate(run.updatedAt))}</div>
      </div>
    `;
    })
    .join('');

  // Add click handlers
  runsList.querySelectorAll('.run-item').forEach((item: Element) => {
    item.addEventListener('click', () => {
      const runId = item.getAttribute('data-run-id');
      if (runId) {
        acquireVsCodeApi().postMessage({ type: 'workspace.selectRun', payload: { runId } });
      }
    });
  });
}

/**
 * Render the detail view for the selected run.
 */
function renderRunDetail(): void {
  if (!runDetail) {
    return;
  }

  const run = state.runs.find((r) => r.id === state.selectedRunId);

  if (!run) {
    runDetail.innerHTML = '<div class="run-detail-empty">Select a run to view details</div>';
    return;
  }

  const phase = escapeHtml(String(run.phase));
  runDetail.innerHTML = `
    <div class="run-detail-header">
      <h2>${escapeHtml(run.title || 'Untitled Run')}</h2>
      <span class="run-phase run-phase--${phase}">${phase}</span>
    </div>
    <div class="run-detail-meta">
      ${run.providerName ? `<div class="meta-row"><span class="meta-label">Provider:</span> ${escapeHtml(run.providerName)}</div>` : ''}
      ${run.modelId ? `<div class="meta-row"><span class="meta-label">Model:</span> ${escapeHtml(run.modelId)}</div>` : ''}
      <div class="meta-row"><span class="meta-label">Updated:</span> ${escapeHtml(formatDate(run.updatedAt))}</div>
    </div>
    ${run.note ? `<div class="run-detail-note">${escapeHtml(run.note)}</div>` : ''}
    <div class="run-detail-actions">
      <button class="btn btn-primary" data-action="view-run">View Details</button>
      <button class="btn btn-secondary" data-action="cancel-run" ${run.phase === 'completed' || run.phase === 'cancelled' ? 'disabled' : ''}>
        Cancel
      </button>
    </div>
  `;

  // Add action handlers
  runDetail.querySelectorAll('[data-action]').forEach((btn: Element) => {
    btn.addEventListener('click', () => {
      const action = btn.getAttribute('data-action');
      if (action && run) {
        acquireVsCodeApi().postMessage({ type: `workspace.${action}`, payload: { runId: run.id } });
      }
    });
  });
}

/**
 * Update a tool call in the state.
 */
function updateToolCall(runId: string, _toolCall: BurnBarToolCallSnapshot): void {
  // If this is for the selected run, re-render
  if (runId === state.selectedRunId) {
    render();
  }
}

/**
 * Remove a run from state.
 */
function deleteRun(runId: string): void {
  state.runs = state.runs.filter((r) => r.id !== runId);
  if (state.selectedRunId === runId) {
    state.selectedRunId = state.runs[0]?.id;
  }
  render();
}

/**
 * Escape HTML special characters.
 */
function escapeHtml(text: string): string {
  const map: Record<string, string> = {
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&#039;'
  };
  return text.replace(/[&<>"']/g, (m) => map[m] ?? m);
}

/**
 * Format a date string for display.
 */
function formatDate(isoString: string): string {
  try {
    const date = new Date(isoString);
    return date.toLocaleString();
  } catch {
    return isoString;
  }
}

// Register message handler
window.addEventListener('message', (event: MessageEvent) => {
  handleMessage(event.data);
});
