/**
 * One-shot native handoff used when a desktop notification asks the user to
 * reply. The event carries no message text or credential material; it only
 * requests focus after the Chat route is mounted.
 */
export const CHAT_COMPOSER_FOCUS_EVENT = 'chat-composer-focus';

export type ChatComposerFocusDetail = {
  notificationId: string;
};

export function isChatComposerFocusDetail(value: unknown): value is ChatComposerFocusDetail {
  if (!value || typeof value !== 'object') return false;
  const notificationId = (value as { notificationId?: unknown }).notificationId;
  return typeof notificationId === 'string'
    && notificationId.length > 0
    && notificationId.length <= 96
    && [...notificationId].every((character) => /[A-Za-z0-9._-]/.test(character));
}
