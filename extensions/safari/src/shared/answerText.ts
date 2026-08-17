/**
 * Reasoning models stream a private scratchpad inside <think> tags. It is the
 * model talking to itself, so it is never an answer: it must not reach the
 * transcript, and a reply made only of it counts as no reply at all.
 *
 * Shared by the background controller (which decides whether a failed run has
 * anything to show) and the popup (which decides what to draw), so both agree
 * on what "the model actually said" means.
 */

const REASONING_BLOCK = /<(think|thinking|reasoning)>[\S\s]*?<\/\1>/gi;
const OPEN_REASONING_TAIL = /<(think|thinking|reasoning)>[\S\s]*$/i;

export function visibleAnswerText(text: string): string {
  return text.replace(REASONING_BLOCK, '').replace(OPEN_REASONING_TAIL, '').trim();
}

export function hasVisibleAnswer(text: string): boolean {
  return visibleAnswerText(text).length > 0;
}
