/* ============================================================
   BurnBar VS Code Webview Panel — panel.js
   Plain ES2020. Runs inside a VS Code webview sandbox.
   ============================================================ */

const vscode = acquireVsCodeApi();

let currentViewModel = null;
let selectedMode = "explain";

/* ----------------------------------------------------------
   Utility helpers
   ---------------------------------------------------------- */

/**
 * Set the text content of the first element matching selector.
 * @param {string} selector
 * @param {string} value
 */
function setText(selector, value) {
  const el = document.querySelector(selector);
  if (el) el.textContent = value;
}

/**
 * Show or hide the first element matching selector via data-visible.
 * @param {string} selector
 * @param {boolean} visible
 */
function setVisible(selector, visible) {
  const el = document.querySelector(selector);
  if (el) el.dataset.visible = visible ? "true" : "false";
}

/**
 * Returns a human-friendly relative time string.
 * @param {string} isoString  ISO-8601 timestamp
 * @returns {string}
 */
function relativeTime(isoString) {
  if (!isoString) return "";
  const diff = Date.now() - new Date(isoString).getTime();
  if (isNaN(diff) || diff < 0) return "just now";
  const secs = Math.floor(diff / 1000);
  if (secs < 10) return "just now";
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.floor(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.floor(mins / 60);
  return `${hrs}h ago`;
}

/**
 * Escape text for safe insertion as textContent (no innerHTML risk).
 * Kept as a no-op alias — always use textContent, never innerHTML for
 * user-supplied strings.
 * @param {string} str
 * @returns {string}
 */
function safe(str) {
  return str == null ? "" : String(str);
}

/* ----------------------------------------------------------
   Error banner
   ---------------------------------------------------------- */

let _errorTimer = null;

/**
 * Display a temporary error banner at the top of the panel.
 * @param {string} message
 */
function showError(message) {
  // Remove any existing banner
  const existing = document.querySelector(".bb-error-banner");
  if (existing) existing.remove();
  if (_errorTimer) clearTimeout(_errorTimer);

  const banner = document.createElement("div");
  banner.className = "bb-error-banner";
  banner.textContent = message;

  const root = document.getElementById("bb-root");
  if (root) root.insertBefore(banner, root.firstChild);

  _errorTimer = setTimeout(() => {
    if (banner.parentNode) banner.remove();
    _errorTimer = null;
  }, 6000);
}

/* ----------------------------------------------------------
   Run card builder
   ---------------------------------------------------------- */

/**
 * Build and return a run card DOM element.
 * @param {object} run
 * @param {boolean} isActive
 * @returns {HTMLElement}
 */
function renderRunCard(run, isActive) {
  const card = document.createElement("div");
  card.className = "bb-run-card" + (isActive ? " bb-run-card--active" : " bb-run-card--compact");
  card.dataset.runId = safe(run.id);

  // ── Header row ──────────────────────────────────────────
  const header = document.createElement("div");
  header.className = "bb-run-card-header";

  const title = document.createElement("span");
  title.className = "bb-run-title";
  title.textContent = "Run " + safe(run.id).slice(0, 8);

  const phaseChip = document.createElement("span");
  const phaseColor = safe(run.phaseColor || "muted");
  phaseChip.className = `bb-phase-chip bb-phase-chip--${phaseColor}`;
  phaseChip.textContent = safe(run.phase || run.status || "unknown");

  header.appendChild(title);
  header.appendChild(phaseChip);
  card.appendChild(header);

  // ── Meta row (active cards only) ────────────────────────
  if (isActive) {
    const meta = document.createElement("div");
    meta.className = "bb-run-card-meta";

    const provider = document.createElement("span");
    provider.className = "bb-run-provider";
    provider.textContent = safe(run.provider || "");

    const timeEl = document.createElement("span");
    timeEl.className = "bb-run-time";
    timeEl.textContent = relativeTime(run.startedAt);

    meta.appendChild(provider);
    if (run.provider) meta.appendChild(provider);
    meta.appendChild(timeEl);
    card.appendChild(meta);
  }

  // ── Note ────────────────────────────────────────────────
  if (run.note) {
    const note = document.createElement("p");
    note.className = "bb-run-note";
    note.textContent = safe(run.note);
    card.appendChild(note);
  }

  // ── Compact card stops here ─────────────────────────────
  if (!isActive) return card;

  // ── Approval block ──────────────────────────────────────
  const approval = document.createElement("div");
  approval.className = "bb-approval";
  approval.dataset.visible = "false";

  const approvalTitle = document.createElement("p");
  approvalTitle.className = "bb-approval-title";

  const approvalMsg = document.createElement("p");
  approvalMsg.className = "bb-approval-msg";

  const approvalActions = document.createElement("div");
  approvalActions.className = "bb-approval-actions";

  const approveBtn = document.createElement("button");
  approveBtn.className = "bb-btn bb-btn--primary";
  approveBtn.dataset.action = "approveRun";
  approveBtn.textContent = "Approve";

  const rejectBtn = document.createElement("button");
  rejectBtn.className = "bb-btn bb-btn--danger";
  rejectBtn.dataset.action = "rejectRun";
  rejectBtn.textContent = "Reject";

  approvalActions.appendChild(approveBtn);
  approvalActions.appendChild(rejectBtn);
  approval.appendChild(approvalTitle);
  approval.appendChild(approvalMsg);
  approval.appendChild(approvalActions);
  card.appendChild(approval);

  // Populate approval state if present
  if (run.approvalState) {
    approval.dataset.visible = "true";
    approvalTitle.textContent = safe(run.approvalState.title || "Approval required");
    approvalMsg.textContent = safe(run.approvalState.message || "");
  }

  // ── Detail sections ─────────────────────────────────────
  const detailSections = document.createElement("div");
  detailSections.className = "bb-detail-sections";

  const sectionDefs = [
    { label: "Summary",  key: "summary" },
    { label: "Response", key: "response" },
    { label: "Loop",     key: "loop" },
    { label: "Usage",    key: "usage" },
    { label: "Recovery", key: "recovery" },
    { label: "System",   key: "system" },
  ];

  for (const def of sectionDefs) {
    const details = document.createElement("details");
    details.className = "bb-detail-section";

    const summary = document.createElement("summary");
    summary.textContent = def.label;

    const content = document.createElement("div");
    content.className = "bb-detail-content";

    const data = run[def.key];
    if (data) {
      if (typeof data === "string") {
        content.textContent = data;
      } else if (typeof data === "object") {
        // Render as key-value list
        for (const [k, v] of Object.entries(data)) {
          const row = document.createElement("div");
          row.className = "bb-system-kv";

          const keyEl = document.createElement("span");
          keyEl.className = "bb-system-kv-key";
          keyEl.textContent = k;

          const valEl = document.createElement("span");
          valEl.className = "bb-system-kv-value";
          valEl.textContent = safe(v);

          row.appendChild(keyEl);
          row.appendChild(valEl);
          content.appendChild(row);
        }
      }
    } else {
      content.textContent = "No details yet.";
    }

    details.appendChild(summary);
    details.appendChild(content);
    detailSections.appendChild(details);
  }

  card.appendChild(detailSections);

  // ── Run actions ─────────────────────────────────────────
  const runActions = document.createElement("div");
  runActions.className = "bb-run-actions";

  const cancelBtn = document.createElement("button");
  cancelBtn.className = "bb-btn bb-btn--secondary bb-btn--sm";
  cancelBtn.dataset.action = "cancelRun";
  cancelBtn.textContent = "Cancel";

  const retryBtn = document.createElement("button");
  retryBtn.className = "bb-btn bb-btn--secondary bb-btn--sm";
  retryBtn.dataset.action = "retryRun";
  retryBtn.textContent = "Retry";

  runActions.appendChild(cancelBtn);
  runActions.appendChild(retryBtn);
  card.appendChild(runActions);

  return card;
}

/* ----------------------------------------------------------
   Main render function
   ---------------------------------------------------------- */

/**
 * Re-render the entire panel from the given view model.
 * @param {object} vm
 */
function render(vm) {
  if (!vm) return;

  // ── Open app (macOS) ────────────────────────────────────
  const openAppBtn = document.querySelector(".bb-header-app-btn");
  if (openAppBtn) {
    openAppBtn.dataset.visible = vm.showOpenBurnBarApp ? "true" : "false";
  }

  // ── Connection orb ──────────────────────────────────────
  const orb = document.querySelector(".bb-orb");
  if (orb) {
    orb.className = "bb-orb bb-orb--" + safe(vm.connectionStatus || "disconnected");
  }

  // ── Recovery block ──────────────────────────────────────
  const recovery = document.querySelector(".bb-recovery");
  if (recovery) {
    recovery.dataset.visible = vm.isDaemonUnavailable ? "true" : "false";
    if (vm.recoveryMessage) {
      const msgEl = recovery.querySelector(".bb-recovery-msg");
      if (msgEl) msgEl.textContent = safe(vm.recoveryMessage);
    }
  }

  // ── Model select ────────────────────────────────────────
  const modelSelect = document.querySelector(".bb-model-select");
  if (modelSelect && Array.isArray(vm.selectedModelOptions)) {
    const prevValue = modelSelect.value;
    modelSelect.innerHTML = "";
    for (const opt of vm.selectedModelOptions) {
      const option = document.createElement("option");
      option.value = safe(opt.id ?? opt.value ?? opt);
      option.textContent = safe(opt.label ?? opt.name ?? opt);
      modelSelect.appendChild(option);
    }
    // Restore selection if still available
    if (prevValue) modelSelect.value = prevValue;
  }

  // ── Composer enabled/disabled ───────────────────────────
  const composerInput = document.querySelector(".bb-composer-input");
  const startBtn = document.querySelector(".bb-start-run");
  const disabledMsg = document.querySelector(".bb-composer-disabled-msg");

  const composerEnabled = vm.isComposerEnabled !== false;
  if (composerInput) composerInput.disabled = !composerEnabled;
  if (startBtn)      startBtn.disabled = !composerEnabled;
  if (modelSelect)   modelSelect.disabled = !composerEnabled;
  if (disabledMsg) {
    disabledMsg.dataset.visible = composerEnabled ? "false" : "true";
    if (!composerEnabled && vm.composerDisabledMessage) {
      disabledMsg.textContent = safe(vm.composerDisabledMessage);
    }
  }

  // ── Active run ──────────────────────────────────────────
  const runsSection = document.querySelector(".bb-runs");
  if (runsSection) {
    // Clear existing active card(s) — keep .bb-history-runs
    Array.from(runsSection.children).forEach(child => {
      if (!child.classList.contains("bb-history-runs")) child.remove();
    });

    if (vm.activeRun) {
      const activeRunDetail = vm.selectedRunId && vm.activeRun.id === vm.selectedRunId
        ? vm.selectedRunDetail
        : undefined;
      const activeCard = renderRunCard(
        {
          ...vm.activeRun,
          approvalState: vm.selectedRunId && vm.activeRun.id === vm.selectedRunId ? vm.approvalState : undefined,
          summary: activeRunDetail?.summary,
          response: activeRunDetail?.responseText,
          loop: activeRunDetail?.loopDecisionText,
          usage: activeRunDetail?.usageText,
          recovery: activeRunDetail?.recoveryMessage,
          system: {
            controller: activeRunDetail?.arbitrationInfo ?? safe(vm.systemInfo?.controllerState),
            daemon: safe(vm.systemInfo?.daemonVersion),
            protocol: safe(vm.systemInfo?.protocolVersion),
            socket: safe(vm.systemInfo?.socketPath),
            workspace: safe(vm.systemInfo?.workspaceHost)
          }
        },
        true
      );
      // Mark selected if applicable
      if (vm.selectedRunId && vm.activeRun.id === vm.selectedRunId) {
        activeCard.classList.add("bb-run-card--selected");
      }
      // Insert before history runs
      const historyContainer = runsSection.querySelector(".bb-history-runs");
      runsSection.insertBefore(activeCard, historyContainer);
    }
  }

  // ── History runs ────────────────────────────────────────
  const historyContainer = document.querySelector(".bb-history-runs");
  if (historyContainer) {
    historyContainer.innerHTML = "";
    if (Array.isArray(vm.historyRuns)) {
      for (const run of vm.historyRuns) {
        const card = renderRunCard(run, false);
        if (vm.selectedRunId && run.id === vm.selectedRunId) {
          card.classList.add("bb-run-card--selected");
        }
        historyContainer.appendChild(card);
      }
    }
  }

  // ── Capability chips ────────────────────────────────────
  const capsSection = document.querySelector(".bb-capabilities");
  if (capsSection && Array.isArray(vm.capabilities)) {
    capsSection.innerHTML = "";
    for (const cap of vm.capabilities) {
      const chip = document.createElement("span");
      const variant = safe(cap.variant || "ready");
      chip.className = `bb-cap-chip bb-cap-chip--${variant}`;
      chip.textContent = safe(cap.label);
      capsSection.appendChild(chip);
    }
  }

  // ── System drawer ────────────────────────────────────────
  const systemContent = document.querySelector(".bb-system-content");
  if (systemContent && vm.systemInfo && typeof vm.systemInfo === "object") {
    systemContent.innerHTML = "";
    for (const [k, v] of Object.entries(vm.systemInfo)) {
      const row = document.createElement("div");
      row.className = "bb-system-kv";

      const keyEl = document.createElement("span");
      keyEl.className = "bb-system-kv-key";
      keyEl.textContent = k;

      const valEl = document.createElement("span");
      valEl.className = "bb-system-kv-value";
      valEl.textContent = safe(v);

      row.appendChild(keyEl);
      row.appendChild(valEl);
      systemContent.appendChild(row);
    }
  }

  // ── Header chips (model name, workspace) ────────────────
  const chipEls = document.querySelectorAll(".bb-header-chips .bb-chip");
  if (chipEls.length >= 2) {
    // First non-orb chip: workspace
    if (vm.workspaceLabel) {
      chipEls[0].textContent = safe(vm.workspaceLabel);
      // Trust variant
      const trust = vm.workspaceTrust === "trusted" ? "trusted" : "untrusted";
      chipEls[0].className = `bb-chip bb-chip--${trust}`;
    }
    // Second chip: model name
    if (vm.activeModelLabel) {
      chipEls[1].textContent = safe(vm.activeModelLabel);
    }
  }
}

/* ----------------------------------------------------------
   handleStartRun
   ---------------------------------------------------------- */

function handleStartRun() {
  const promptEl = document.querySelector(".bb-composer-input");
  const prompt = promptEl?.value?.trim();
  if (!prompt) return;

  const modelSelect = document.querySelector(".bb-model-select");
  const modelID = modelSelect?.value;
  if (!modelID) return;

  vscode.postMessage({ type: "startRun", prompt, modelID, mode: selectedMode });
  promptEl.value = "";
}

/* ----------------------------------------------------------
   Message handler (host → webview)
   ---------------------------------------------------------- */

window.addEventListener("message", event => {
  const msg = event.data;
  if (!msg || !msg.type) return;

  if (msg.type === "snapshot") {
    currentViewModel = msg.viewModel;
    render(currentViewModel);
  } else if (msg.type === "error") {
    showError(safe(msg.message));
  }
  // Additional: theme change hint — VS Code handles CSS variable
  // updates automatically, but we could add body class updates here.
});

/* ----------------------------------------------------------
   Delegated event listeners (set up after DOMContentLoaded)
   ---------------------------------------------------------- */

document.addEventListener("DOMContentLoaded", () => {
  const root = document.getElementById("bb-root");
  if (!root) return;

  root.addEventListener("click", e => {
    // ── Mode chip toggle ───────────────────────────────────
    const modeChip = e.target.closest(".bb-mode-chip");
    if (modeChip) {
      selectedMode = modeChip.dataset.mode;
      document.querySelectorAll(".bb-mode-chip").forEach(c => {
        c.classList.remove("bb-mode-chip--active");
      });
      modeChip.classList.add("bb-mode-chip--active");
      return;
    }

    // ── Action buttons ─────────────────────────────────────
    const btn = e.target.closest("[data-action]");
    if (!btn) {
      // Check if clicking a compact run card to select it
      const card = e.target.closest(".bb-run-card[data-run-id]");
      if (card && currentViewModel) {
        vscode.postMessage({ type: "selectRun", runId: card.dataset.runId });
      }
      return;
    }

    const action = btn.dataset.action;
    const runId =
      btn.closest("[data-run-id]")?.dataset?.runId ??
      currentViewModel?.selectedRunId;

    switch (action) {
      case "refresh":
        vscode.postMessage({ type: "refresh" });
        break;
      case "repair":
        vscode.postMessage({ type: "repair" });
        break;
      case "startRun":
        handleStartRun();
        break;
      case "cancelRun":
        vscode.postMessage({ type: "cancelRun", runId });
        break;
      case "retryRun":
        vscode.postMessage({ type: "retryRun", runId });
        break;
      case "approveRun":
        vscode.postMessage({ type: "approveRun", runId });
        break;
      case "rejectRun":
        vscode.postMessage({ type: "rejectRun", runId });
        break;
      case "openApp":
        vscode.postMessage({ type: "openApp" });
        break;
      default:
        break;
    }
  });

  // Keyboard: allow Enter in composer textarea with Ctrl/Cmd to submit
  const composerInput = document.querySelector(".bb-composer-input");
  if (composerInput) {
    composerInput.addEventListener("keydown", e => {
      if ((e.ctrlKey || e.metaKey) && e.key === "Enter") {
        e.preventDefault();
        handleStartRun();
      }
    });
  }
});
