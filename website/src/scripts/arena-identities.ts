/**
 * Arena identity registry — display names and brand logos for the harnesses
 * and models in the Arena matrix.
 *
 * Blindness boundary: this module is used ONLY after a vote is recorded
 * (reveal panel, stage tab labels). Nothing here may render pre-vote.
 */

export interface IdentityInfo {
  /** Human-readable display name. */
  name: string;
  /** Logo path under /brand/providers/, or undefined for a monogram fallback. */
  logo?: string;
  /**
   * True when the logo is a dark glyph on transparency (e.g. OpenAI, Z.ai):
   * it needs a lift filter on the dark theme to stay visible.
   */
  darkGlyph?: boolean;
}

const HARNESSES: Record<string, IdentityInfo> = {
  omp: { name: "OMP", logo: "/brand/providers/omp.svg" },
  pi: { name: "Pi", logo: "/brand/providers/pi-agent.svg" },
  droid: { name: "Droid", logo: "/brand/providers/factory.png" },
  codex: { name: "Codex", logo: "/brand/providers/codex.png" },
  claude: { name: "Claude Code", logo: "/brand/providers/claude-code.png" },
  opencode: { name: "OpenCode", logo: "/brand/providers/opencode.png" },
  "prime-agent": {
    name: "Prime Agent",
    logo: "/brand/providers/prime-intellect.png"
  },
  hermes: { name: "Hermes", logo: "/brand/providers/hermes.png" }
};

const MODELS: Record<string, IdentityInfo> = {
  "deepseek-v4-flash-0731": {
    name: "DeepSeek v4 Flash",
    logo: "/brand/providers/deepseek.svg"
  },
  "gpt-5-6-luna-max": {
    name: "GPT-5.6 Luna Max",
    logo: "/brand/providers/openai.png",
    darkGlyph: true
  },
  "glm-5-2": {
    name: "GLM-5.2",
    logo: "/brand/providers/zai.png",
    darkGlyph: true
  },
  "muse-spark-1-2-contributor": {
    name: "Muse Spark 1.2",
    logo: "/brand/providers/meta.svg"
  }
};

export function harnessInfo(id: string): IdentityInfo {
  return HARNESSES[id] ?? { name: id };
}

export function modelInfo(id: string): IdentityInfo {
  return MODELS[id] ?? { name: id };
}

function logoNode(info: IdentityInfo): HTMLElement {
  if (info.logo) {
    const img = document.createElement("img");
    img.className = info.darkGlyph ? "bb-id__logo bb-id__logo--dark" : "bb-id__logo";
    img.src = info.logo;
    img.alt = "";
    img.width = 44;
    img.height = 44;
    img.loading = "lazy";
    img.decoding = "async";
    return img;
  }
  const mono = document.createElement("span");
  mono.className = "bb-id__logo bb-id__logo--mono";
  mono.textContent = info.name.charAt(0).toUpperCase();
  mono.setAttribute("aria-hidden", "true");
  return mono;
}

export interface IdentityCardInput {
  sideLabel: string;
  harness: string;
  model: string;
  task: string;
  trial: string;
  picked: boolean;
}

/**
 * Builds a post-vote identity card. All dynamic strings go through
 * textContent — nothing is interpolated into HTML.
 */
export function buildIdentityCard(input: IdentityCardInput): HTMLElement {
  const harness = harnessInfo(input.harness);
  const model = modelInfo(input.model);

  const card = document.createElement("div");
  card.className = input.picked ? "bb-id bb-id--picked" : "bb-id";

  if (input.picked) {
    const pick = document.createElement("span");
    pick.className = "bb-id__pick mono";
    pick.textContent = "✓ your pick";
    card.appendChild(pick);
  }

  const side = document.createElement("span");
  side.className = "bb-id__side mono";
  side.textContent = input.sideLabel;
  card.appendChild(side);

  const logos = document.createElement("div");
  logos.className = "bb-id__logos";
  logos.appendChild(logoNode(harness));
  logos.appendChild(logoNode(model));
  card.appendChild(logos);

  const names = document.createElement("p");
  names.className = "bb-id__names";
  names.textContent = `${harness.name} × ${model.name}`;
  card.appendChild(names);

  const sub = document.createElement("p");
  sub.className = "bb-id__sub mono";
  sub.textContent = `${input.harness} × ${input.model} · ${input.task} · ${input.trial}`;
  card.appendChild(sub);

  return card;
}
