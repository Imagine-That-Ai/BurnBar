/**
 * Whether a model can actually read an image.
 *
 * The daemon catalog does not carry a vision capability, so this is inferred.
 * It is inferred **fail-safe**: unknown means text-only. The two mistakes are
 * not symmetric — assuming a model is blind costs it a screenshot it might
 * have used, while assuming it can see makes the provider reject the entire
 * request. Ask still works without pixels, because the page's text and
 * accessibility snapshot carry most of the answer.
 */

/* Explicit markers a model puts in its own name when it can see. */
const VISION_MARKERS = ['vision', '-vl', ' vl', 'vl-', 'llava', 'pixtral', 'moondream', 'multimodal', 'omni'];

/* Families whose current generations are multimodal across the board. */
const VISION_FAMILIES = [
  'gpt-4o',
  'gpt-4.1',
  'gpt-5',
  'claude-3',
  'claude-4',
  'claude-opus',
  'claude-sonnet',
  'claude-haiku',
  'gemini',
  'grok-4',
  'grok-5',
  'llama-4',
  'gemma-3',
  'gemma3'
];

/* Families that read as multimodal by association but are text-only in the
   variants we route to, so they must never be inferred as sighted. */
const TEXT_ONLY_OVERRIDES = ['deepseek-chat', 'deepseek-v4', 'deepseek-r1', 'deepseek-coder'];

/**
 * Whether a model is answered off-device despite a local-looking host.
 *
 * Ollama serves `model:cloud` entries from `localhost:11434` but forwards them
 * to Ollama's cloud. Treating those as local would put an on-device privacy
 * badge on a request that leaves the machine.
 */
export function routesToCloud(...descriptors: Array<string | undefined>): boolean {
  return descriptors.some((value) => {
    const name = value?.toLocaleLowerCase().trim();
    return Boolean(name && (name.endsWith(':cloud') || name.includes(':cloud/') || name.includes('-cloud:')));
  });
}

export function inferModelSupportsVision(...descriptors: Array<string | undefined>): boolean {
  const haystack = descriptors
    .filter((value): value is string => Boolean(value))
    .join(' ')
    .toLocaleLowerCase();
  if (!haystack) {
    return false;
  }
  if (TEXT_ONLY_OVERRIDES.some((needle) => haystack.includes(needle))) {
    /* An explicit vision marker still wins: deepseek-vl is real. */
    return VISION_MARKERS.some((marker) => haystack.includes(marker));
  }
  return (
    VISION_MARKERS.some((marker) => haystack.includes(marker)) ||
    VISION_FAMILIES.some((family) => haystack.includes(family))
  );
}
