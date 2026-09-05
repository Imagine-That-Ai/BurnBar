/** Deterministic provider/model colors matching macOS DesignSystem rules. */
const PROVIDER_COLORS: Record<string, string> = {
  anthropic: '#CC785C',
  openai: '#00A67E',
  factory: '#F97316',
  google: '#4285F4',
  antigravity: '#6C63FF',
  xai: '#1A1A2E',
  deepseek: '#6366F1',
  mistral: '#FF7000',
  meta: '#0668E1',
  cohere: '#39594D',
  amazon: '#FF9900',
  alibaba: '#FF6A00',
  zai: '#8B5CF6',
  minimax: '#F59E0B',
  mimo: '#FF6900',
  ollama: '#8B8589',
  moonshot: '#6366F1',
  kimi: '#6366F1',
  cursor: '#00E5FF',
  windsurf: '#22D3EE',
  openburnbar: '#FF7578',
  opencode: '#8B5CF6',
  hermes: '#C8BFB5',
  copilot: '#8B5CF6',
  cline: '#22D3EE',
  goose: '#84CC16',
  openclaw: '#F97316',
  fx: '#A1A1AA',
  muse: '#0668E1',
};

const MODEL_PALETTE = [
  '#D4A373', '#10B981', '#EC4899', '#F97316', '#3B82F6', '#A855F7',
  '#EF4444', '#14B8A6', '#F59E0B', '#8B5CF6', '#06B6D4', '#84CC16'
];

function normalized(value: string): string {
  return value.trim().toLowerCase().replace(/[_\s-]+/g, '');
}

export function colorForProviderID(providerID: string): string {
  const key = normalized(providerID);
  if (key === 'claudecode' || key === 'claude') return PROVIDER_COLORS.anthropic;
  if (key === 'codex') return PROVIDER_COLORS.openai;
  if (key === 'geminicli' || key === 'gemini') return PROVIDER_COLORS.google;
  if (key === 'grok') return PROVIDER_COLORS.xai;
  return PROVIDER_COLORS[key] ?? '#9CA3AF';
}

export function colorForModel(modelName: string): string {
  const key = modelName.toLowerCase();
  const familyChecks: [string[], string][] = [
    [['claude', 'anthropic'], PROVIDER_COLORS.anthropic],
    [['gpt', 'openai', 'chatgpt'], PROVIDER_COLORS.openai],
    [['gemini', 'google'], PROVIDER_COLORS.google],
    [['deepseek'], PROVIDER_COLORS.deepseek],
    [['kimi', 'moonshot'], PROVIDER_COLORS.kimi],
    [['minimax', 'abab'], PROVIDER_COLORS.minimax],
    [['llama', 'meta'], PROVIDER_COLORS.meta],
    [['mistral', 'mixtral'], PROVIDER_COLORS.mistral],
    [['qwen', 'qwq'], '#615EFF'],
    [['grok', 'xai'], PROVIDER_COLORS.xai],
    [['cohere', 'command'], PROVIDER_COLORS.cohere],
    [['perplexity', 'sonar'], '#20808D'],
    [['mlx', 'apple'], '#A2AAAD'],
    [['nova', 'amazon', 'bedrock'], PROVIDER_COLORS.amazon],
    [['alibaba', 'tongyi'], PROVIDER_COLORS.alibaba],
    [['ollama'], PROVIDER_COLORS.ollama]
  ];
  const match = familyChecks.find(([families]) => families.some((family) => key.includes(family)));
  if (match) return match[1];

  let hash = 5381;
  for (const byte of new TextEncoder().encode(key)) hash = ((hash * 33) + byte) >>> 0;
  return MODEL_PALETTE[hash % MODEL_PALETTE.length]!;
}
