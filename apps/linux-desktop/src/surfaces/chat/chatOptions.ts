import type {
  ConfigSnapshot,
  ProviderSettings
} from '../../tauriBridge.js';
import type { ChatBackendId } from './chatTypes.js';

export const CHAT_THINKING_LEVELS = ['low', 'medium', 'high', 'xhigh', 'max'] as const;
export type ChatThinkingLevel = (typeof CHAT_THINKING_LEVELS)[number];
export type ChatThinkingSelection = ChatThinkingLevel | 'default';

export type ChatModelOption = {
  id: string;
  label: string;
  baseModelID: string;
  thinkingVariants: Partial<Record<ChatThinkingLevel, string>>;
};

export type ChatModelSelection = {
  modelID: string;
  modelOptionID: string;
  thinkingLevel: ChatThinkingSelection;
};

const PROVIDER_IDS_BY_BACKEND: Record<ChatBackendId, readonly string[]> = {
  hermes: ['hermes', 'openburnbar', 'open-burn-bar'],
  codex: ['openai', 'codex'],
  claude: ['anthropic', 'claude', 'claude-code'],
  'pi-agent': ['pi', 'pi-agent', 'piagent'],
  openclaw: ['openclaw'],
  openclaude: ['openclaude'],
  omp: ['omp'],
  droid: ['droid', 'factory'],
  forge: ['forge', 'forgedev'],
  antigravity: ['antigravity'],
  'cursor-agent': ['cursor-agent', 'cursoragent'],
  junie: ['junie'],
  fx: ['fx', 'vercel-fx', 'vercelfx'],
  cli: ['cli', 'local-cli']
};

export function providerIDsForChatBackend(backend: ChatBackendId): readonly string[] {
  return PROVIDER_IDS_BY_BACKEND[backend];
}

const normalizeID = (value: string): string => value.trim().toLowerCase();

function providerForBackend(
  config: ConfigSnapshot | null,
  backend: ChatBackendId
): ProviderSettings | null {
  const candidates = new Set(PROVIDER_IDS_BY_BACKEND[backend].map(normalizeID));
  return (
    config?.providers?.find((provider) => {
      const providerID = normalizeID(provider.providerID);
      return candidates.has(providerID);
    }) ?? null
  );
}

function displayNameFor(
  provider: ProviderSettings,
  modelID: string,
  fallback: string
): string {
  const override = provider.modelDisplayOverrides.find((entry) => entry.modelID === modelID);
  if (override?.displayName.trim()) return override.displayName.trim();
  const custom = provider.customModels.find((entry) => entry.modelID === modelID);
  if (custom?.displayName.trim()) return custom.displayName.trim();
  return fallback;
}

function addOption(
  options: Map<string, ChatModelOption>,
  provider: ProviderSettings,
  id: string,
  label: string,
  baseModelID = id
): void {
  const normalizedID = id.trim();
  const normalizedBase = baseModelID.trim() || normalizedID;
  if (!normalizedID || options.has(normalizedID)) return;
  const variants = provider.modelVariants
    .filter((variant) => variant.baseModelID === normalizedBase)
    .reduce<Partial<Record<ChatThinkingLevel, string>>>((result, variant) => {
      if (variant.variantID.trim() && CHAT_THINKING_LEVELS.includes(variant.thinkingLevel)) {
        result[variant.thinkingLevel] ??= variant.variantID.trim();
      }
      return result;
    }, {});
  options.set(normalizedID, {
    id: normalizedID,
    label: label.trim() || normalizedID,
    baseModelID: normalizedBase,
    thinkingVariants: variants
  });
}

/**
 * Build the user-selectable catalog from the daemon's existing provider
 * snapshot. The gateway receives the exact option id; labels are display-only.
 */
export function chatModelOptions(
  config: ConfigSnapshot | null,
  backend: ChatBackendId,
  fallbackModel: string
): ChatModelOption[] {
  const provider = providerForBackend(config, backend);
  if (!provider || !provider.isEnabled) {
    const fallback = fallbackModel.trim();
    return fallback ? [{ id: fallback, label: fallback, baseModelID: fallback, thinkingVariants: {} }] : [];
  }

  const disabled = new Set(provider.disabledAdvertisedModelIDs.map((id) => normalizeID(id)));
  const hiddenBaseModels = new Set(
    provider.modelAliases
      .filter((alias) => alias.hidesBaseModel)
      .map((alias) => normalizeID(alias.baseModelID))
  );
  const options = new Map<string, ChatModelOption>();
  const addIfAvailable = (id: string, label: string, baseModelID = id) => {
    if (disabled.has(normalizeID(id)) || disabled.has(normalizeID(baseModelID))) return;
    addOption(options, provider, id, label, baseModelID);
  };

  for (const modelID of provider.preferredModelIDs) {
    if (!hiddenBaseModels.has(normalizeID(modelID))) {
      addIfAvailable(modelID, displayNameFor(provider, modelID, modelID));
    }
  }
  for (const custom of provider.customModels) {
    addIfAvailable(custom.modelID, custom.displayName || custom.modelID);
  }
  for (const alias of provider.modelAliases) {
    addIfAvailable(alias.aliasID, alias.displayName || alias.aliasID, alias.baseModelID);
  }
  // A configured variant can be the only declaration of a model. Include its
  // base model so its thinking-level control remains discoverable.
  for (const variant of provider.modelVariants) {
    if (!hiddenBaseModels.has(normalizeID(variant.baseModelID))) {
      addIfAvailable(
        variant.baseModelID,
        displayNameFor(provider, variant.baseModelID, variant.baseModelID)
      );
    }
  }

  if (options.size === 0) {
    const fallback = fallbackModel.trim();
    return fallback ? [{ id: fallback, label: fallback, baseModelID: fallback, thinkingVariants: {} }] : [];
  }
  return [...options.values()];
}

export function defaultChatModelSelection(
  config: ConfigSnapshot | null,
  backend: ChatBackendId,
  fallbackModel: string
): ChatModelSelection {
  const first = chatModelOptions(config, backend, fallbackModel)[0];
  if (!first) {
    return { modelID: '', modelOptionID: '', thinkingLevel: 'default' };
  }
  return { modelID: first.id, modelOptionID: first.id, thinkingLevel: 'default' };
}

export function chatModelOptionForSelection(
  options: ChatModelOption[],
  modelOptionID: string,
  modelID: string
): ChatModelOption | null {
  const selected = options.find((option) => option.id === modelOptionID);
  if (selected) return selected;
  const variantOwner = options.find((option) => Object.values(option.thinkingVariants).includes(modelID));
  return variantOwner ?? options.find((option) => option.id === modelID) ?? null;
}

export function chatThinkingLevels(
  options: ChatModelOption[],
  modelOptionID: string,
  modelID: string
): ChatThinkingLevel[] {
  const option = chatModelOptionForSelection(options, modelOptionID, modelID);
  return option ? CHAT_THINKING_LEVELS.filter((level) => option.thinkingVariants[level]) : [];
}

export function selectionForModelOption(
  options: ChatModelOption[],
  modelOptionID: string
): ChatModelSelection | null {
  const option = options.find((entry) => entry.id === modelOptionID);
  return option
    ? { modelID: option.id, modelOptionID: option.id, thinkingLevel: 'default' }
    : null;
}

export function selectionForThinkingLevel(
  options: ChatModelOption[],
  modelOptionID: string,
  modelID: string,
  thinkingLevel: ChatThinkingSelection
): ChatModelSelection | null {
  const option = chatModelOptionForSelection(options, modelOptionID, modelID);
  if (!option) return null;
  if (thinkingLevel === 'default') {
    return { modelID: option.id, modelOptionID: option.id, thinkingLevel };
  }
  const variantID = option.thinkingVariants[thinkingLevel];
  return variantID
    ? { modelID: variantID, modelOptionID: option.id, thinkingLevel }
    : null;
}

export function thinkingLabel(level: ChatThinkingSelection): string {
  return level === 'default' ? 'Default' : level[0]!.toUpperCase() + level.slice(1);
}

export function thinkingLevelForModel(
  options: ChatModelOption[],
  modelOptionID: string,
  modelID: string
): ChatThinkingSelection {
  const option = chatModelOptionForSelection(options, modelOptionID, modelID);
  if (!option) return 'default';
  const level = CHAT_THINKING_LEVELS.find((candidate) => option.thinkingVariants[candidate] === modelID);
  return level ?? 'default';
}
