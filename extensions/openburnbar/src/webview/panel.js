/* ============================================================
   OpenBurnBar Sidebar Companion — Compact launcher + status
   Lightweight view with launchers for the full workspace panel.
   ============================================================ */

const vscode = acquireVsCodeApi();

let currentViewModel = null;

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
    return secs + 's ago';
  }
  const mins = Math.floor(secs / 60);
  if (mins < 60) {
    return mins + 'm ago';
  }
  const hrs = Math.floor(mins / 60);
  return hrs + 'h ago';
}

function humanizePhase(phase) {
  if (!phase) {
    return '';
  }
  return phase.replace(/_/g, ' ');
}

/* ----------------------------------------------------------
   Error banner
   ---------------------------------------------------------- */

let _errorTimer = null;

function showError(message) {
  const existing = document.querySelector('.bb-error-banner');
  if (existing) {
    existing.remove();
  }
  if (_errorTimer) {
    clearTimeout(_errorTimer);
  }

  const banner = document.createElement('div');
  banner.className = 'bb-error-banner';
  banner.textContent = message;

  const root = document.getElementById('bb-root');
  if (root) {
    root.insertBefore(banner, root.firstChild);
  }

  _errorTimer = setTimeout(() => {
    if (banner.parentNode) {
      banner.remove();
    }
    _errorTimer = null;
  }, 6000);
}

/* ----------------------------------------------------------
   Main render — compact sidebar companion
   ---------------------------------------------------------- */

function render(vm) {
  if (!vm) {
    return;
  }

  // ── Open app button (macOS) ────────────────────────────
  const openAppBtn = document.querySelector('.bb-header-app-btn');
  if (openAppBtn) {
    openAppBtn.dataset.visible = vm.showOpenBurnBarApp ? 'true' : 'false';
  }

  // ── Search conversations launcher (macOS) ──────────────
  const searchBtn = document.querySelector("[data-action='openApp'].bb-launcher");
  if (searchBtn) {
    searchBtn.dataset.visible = vm.showOpenBurnBarApp ? 'true' : 'false';
  }

  // ── Connection orb ─────────────────────────────────────
  const orb = document.querySelector('.bb-orb');
  if (orb) {
    orb.className = 'bb-orb bb-orb--' + safe(vm.connectionStatus || 'disconnected');
  }

  // ── Status text ────────────────────────────────────────
  const statusText = document.getElementById('bb-status-text');
  if (statusText) {
    if (vm.isConnected) {
      const parts = [];
      if (vm.daemonVersion) {
        parts.push('v' + vm.daemonVersion);
      }
      if (vm.hasWorkspace) {
        parts.push(vm.isWorkspaceTrusted ? 'trusted' : 'restricted');
      }
      statusText.textContent = parts.length > 0 ? parts.join(' \u00B7 ') : 'Connected';
    } else {
      statusText.textContent = capitalize(safe(vm.connectionStatus || 'disconnected'));
    }
  }

  // ── Recovery block ─────────────────────────────────────
  const recovery = document.querySelector('.bb-recovery');
  if (recovery) {
    recovery.dataset.visible = vm.isDaemonUnavailable ? 'true' : 'false';
    if (vm.recoveryMessage) {
      const msgEl = recovery.querySelector('.bb-recovery-msg');
      if (msgEl) {
        msgEl.textContent = safe(vm.recoveryMessage);
      }
    }
  }

  // ── Active run summary ─────────────────────────────────
  const summary = document.getElementById('bb-active-summary');
  const activeRun = vm.activeRun;

  if (summary) {
    if (activeRun && vm.isConnected) {
      summary.dataset.visible = 'true';

      const dot = document.getElementById('bb-active-dot');
      if (dot) {
        dot.className = 'bb-active-dot bb-active-dot--' + safe(activeRun.phaseColor || 'muted');
      }

      const title = document.getElementById('bb-active-title');
      if (title) {
        title.textContent = safe(activeRun.title) + ' \u00B7 ' + humanizePhase(activeRun.phase);
      }

      const meta = document.getElementById('bb-active-meta');
      if (meta) {
        const parts = [];
        if (activeRun.providerName) {
          parts.push(activeRun.providerName);
        }
        if (activeRun.modelId) {
          parts.push(activeRun.modelId);
        }
        if (activeRun.updatedAt) {
          parts.push(relativeTime(activeRun.updatedAt));
        }
        meta.textContent = parts.join(' \u00B7 ');
      }
    } else {
      summary.dataset.visible = 'false';
    }
  }

  // ── Start run button state ─────────────────────────────
  const startBtn = document.querySelector("[data-action='startRun']");
  if (startBtn) {
    startBtn.disabled = !vm.isComposerEnabled;
  }

  // ── Status line ────────────────────────────────────────
  const statusLine = document.getElementById('bb-status-line');
  if (statusLine) {
    const text = safe(vm.statusLineText || '');
    statusLine.dataset.visible = text ? 'true' : 'false';
    statusLine.textContent = text;
  }
}

function capitalize(str) {
  if (!str) {
    return str;
  }
  return str.charAt(0).toUpperCase() + str.slice(1);
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
    && (msg.type === 'snapshot' || msg.type === 'error')
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
  }
});

/* ----------------------------------------------------------
   Delegated event listeners
   ---------------------------------------------------------- */

document.addEventListener('DOMContentLoaded', () => {
  const root = document.getElementById('bb-root');
  if (!root) {
    return;
  }

  root.addEventListener('click', e => {
    const btn = e.target.closest('[data-action]');
    if (!btn) {
      return;
    }

    const action = btn.dataset.action;

    switch (action) {
    case 'refresh':
      vscode.postMessage({ type: 'refresh' });
      break;
    case 'repair':
      vscode.postMessage({ type: 'repair' });
      break;
    case 'startRun':
      vscode.postMessage({ type: 'openWorkspace' });
      break;
    case 'openWorkspace':
      vscode.postMessage({ type: 'openWorkspace' });
      break;
    case 'openApp':
      vscode.postMessage({ type: 'openApp' });
      break;
    default:
      break;
    }
  });
});
