/**
 * One-shot native handoff used when a desktop notification asks the user to
 * reply. The event carries no message text or credential material; it only
 * requests focus after the Chat route is mounted.
 */
export const CHAT_COMPOSER_FOCUS_EVENT = 'chat-composer-focus';

export type ChatComposerFocusDetail = {
  notificationId: string;
  paneID?: string;
};

export function isChatComposerFocusDetail(value: unknown): value is ChatComposerFocusDetail {
  if (!value || typeof value !== 'object') return false;
  const detail = value as { notificationId?: unknown; paneID?: unknown };
  return validEventID(detail.notificationId, 128)
    && (detail.paneID === undefined || validEventID(detail.paneID, 128));
}

export function chatPaneIDFromNotificationID(notificationID: string): string | null {
  const prefix = 'chat-pane-';
  if (!notificationID.startsWith(prefix)) return null;
  const paneID = notificationID.slice(prefix.length);
  return validEventID(paneID, 128) ? paneID : null;
}

function validEventID(value: unknown, maximumLength: number): value is string {
  return typeof value === 'string'
    && value.length > 0
    && value.length <= maximumLength
    && [...value].every((character) => /[A-Za-z0-9._-]/.test(character));
}
