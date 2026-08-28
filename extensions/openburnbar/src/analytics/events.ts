/**
 * The canonical VS Code extension event registry — the single source of this
 * platform's event names. Tier 1 names are shared VERBATIM with every other
 * platform (see AgentLens/Services/Analytics/AnalyticsEvent.swift,
 * website/src/lib/analytics/events.ts, and docs/analytics/event-taxonomy.md).
 * Call sites reference `EVENT.*`, so an off-taxonomy name can't be invented; the
 * value is the wire name.
 *
 * Event name scheme (enforced by a unit test): `surface.object.action`,
 * lowercase dot-separated segments, `snake_case` within a segment, matching
 * `^[a-z0-9]+(\.[a-z0-9_]+)+$`. Property names are `snake_case`
 * (`^[a-z0-9]+(_[a-z0-9]+)*$`).
 */
export const EVENT = {
  // ── Tier 1 — core cross-platform spine ──────────────────────────────────────
  appSessionStarted: 'app.session.started',
  appOpened: 'app.opened',
  appSessionEnded: 'app.session.ended',
  screenViewed: 'screen.viewed',
  settingsChanged: 'settings.changed',
  errorHandled: 'error.handled',
  consentAnalyticsGranted: 'consent.analytics.granted',

  // ── Tier 2 — VS Code extension surfaces (platform: vscode) ───────────────────
  // The extension host activated (analogue of app.session.started for a process
  // that may run headless). Carries the host kind + a cold-start flag only.
  vscodeExtensionActivated: 'vscode.extension.activated',
  // A registered command fired. `command_id` is a BOUNDED ENUM of our own
  // command ids (never the args, never user text, never file paths).
  vscodeCommandInvoked: 'vscode.command.invoked',
  // A deliberate action inside the sidebar/workspace webview panel. `action` is
  // a bounded enum; never the prompt body or model output.
  vscodePanelAction: 'vscode.panel.action',
  // A daemon-backed run was acted upon (start/cancel/retry/approve/reject).
  // `action` + bounded `outcome` only; never the prompt, run id, or diff.
  vscodeRunAction: 'vscode.run.action',
  // The local daemon connection state changed (connect attempt outcome).
  vscodeDaemonConnection: 'vscode.daemon.connection'
} as const;

export type AnalyticsEventName = (typeof EVENT)[keyof typeof EVENT];

type AnalyticsCategory = 'lifecycle' | 'screen_view' | 'primary_action' | 'conversion_auth' | 'error';

const LIFECYCLE = new Set<string>([
  EVENT.appSessionStarted,
  EVENT.appOpened,
  EVENT.appSessionEnded,
  EVENT.consentAnalyticsGranted,
  EVENT.vscodeExtensionActivated,
  EVENT.vscodeDaemonConnection
]);

const SCREEN_VIEW = new Set<string>([EVENT.screenViewed]);

const ERROR = new Set<string>([EVENT.errorHandled]);

// Everything else (settings.changed, vscode.command.invoked, vscode.panel.action,
// vscode.run.action) is a deliberate user action → primary_action. There is no
// conversion_auth event on this platform: the extension has no sign-in flow, so
// identity stays anonymous (device_id only) and no user_id is ever set.

/** Amplitude category metadata for an event (a property, never embedded in the name). */
export function eventCategory(name: AnalyticsEventName): AnalyticsCategory {
  if (LIFECYCLE.has(name)) return 'lifecycle';
  if (SCREEN_VIEW.has(name)) return 'screen_view';
  if (ERROR.has(name)) return 'error';
  return 'primary_action';
}

// ── Bounded enums for property values ─────────────────────────────────────────
// These keep every property value a bounded literal — a unique command id or
// action can never become a unique fingerprint, and free text can never ride.

/** The extension's own command ids, as a bounded enum. Mirrors `contributes.commands`
 *  in package.json. The private workspace-RPC command is intentionally excluded
 *  (it is an internal channel, never a user gesture). */
export const COMMAND_ID = {
  reconnect: 'reconnect',
  refresh: 'refresh',
  repairDaemon: 'repair_daemon',
  startRun: 'start_run',
  cancelRun: 'cancel_run',
  retryRun: 'retry_run',
  approveRun: 'approve_run',
  rejectRun: 'reject_run',
  openWorkspace: 'open_workspace',
  openConversationSearch: 'open_conversation_search'
} as const;
export type CommandId = (typeof COMMAND_ID)[keyof typeof COMMAND_ID];

/** Bounded surface enum for `screen.viewed` (the panels this extension shows). */
export const SURFACE = {
  app: 'app',
  panel: 'panel',
  workspacePanel: 'workspace_panel'
} as const;
export type Surface = (typeof SURFACE)[keyof typeof SURFACE];

/** Bounded outcome enum shared by run actions and connection events. */
export const OUTCOME = {
  success: 'success',
  failure: 'failure',
  cancelled: 'cancelled'
} as const;
export type Outcome = (typeof OUTCOME)[keyof typeof OUTCOME];

/** Bounded `action` values for `vscode.run.action`. A closed union so a free
 *  string (e.g. a caught error message) is a COMPILE error at the call site. */
export type RunActionName = 'start' | 'cancel' | 'retry' | 'approve' | 'reject' | 'repair_daemon';

/** Bounded `action` values for `vscode.panel.action`. */
export type PanelActionName = 'open_app' | 'switch_section' | 'new_chat' | 'open_workspace';

/**
 * Bounded context for `screen.viewed`. The taxonomy permits `surface` plus
 * "optional surface context props" — but every such prop must be a bounded flag
 * or a pre-bucketed string, never free text. This is a CLOSED interface (no index
 * signature), so a caller cannot smuggle an arbitrary `string` onto the payload
 * the way an open `Record<string, string|boolean>` would allow. It is the
 * `screen.viewed` analogue of the closed unions on the other `track*` methods.
 *
 * Today this platform only ever attaches `is_first_view` (a flag). Any future
 * bucketed context (e.g. a `*_bucket` produced by `./buckets`) is added here as a
 * named optional field FIRST — and the field name must already exist in the
 * taxonomy — so it can never arrive as an unbounded value.
 */
export interface ScreenViewContext {
  /** First time this surface was shown in the session (the only documented
   *  optional context prop currently emitted by this platform). */
  is_first_view?: boolean;
}

/** Bounded `error_category` values for `error.handled` on this platform. A closed
 *  union so the message/stack/path of a caught error can NEVER reach the wire. */
export type ErrorCategory =
  | 'daemon_repair_failed'
  | 'run_start_failed'
  | 'run_cancel_failed'
  | 'run_retry_failed'
  | 'run_approval_failed'
  | 'daemon_unreachable';
