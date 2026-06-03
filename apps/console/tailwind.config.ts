import type { Config } from "tailwindcss";
import tailwindcssAnimate from "tailwindcss-animate";

/**
 * Tailwind binds to the DTCG Pensieve tokens (packages/design-tokens/dist/css/pensieve.css)
 * via CSS variables — we never hardcode hex. Adding a token to the registry/codegen
 * surfaces it here automatically through var() once the CSS exposes it.
 */
const config: Config = {
  content: [
    "./app/**/*.{ts,tsx}",
    "./components/**/*.{ts,tsx}",
    "./lib/**/*.{ts,tsx}",
  ],
  theme: {
    extend: {
      colors: {
        ink: {
          void: "var(--color-ink-void)",
          base: "var(--color-ink-base)",
          elevated: "var(--color-ink-elevated)",
          furnace: "var(--color-ink-furnace)",
        },
        mercury: {
          bright: "var(--color-mercury-bright)",
          core: "var(--color-mercury-core)",
          deep: "var(--color-mercury-deep)",
          wash: "var(--color-mercury-wash)",
        },
        brass: {
          core: "var(--color-brass-core)",
          bright: "var(--color-brass-bright)",
          deep: "var(--color-brass-deep)",
          glow: "var(--color-brass-glow)",
        },
        frost: {
          veil: "var(--color-frost-veil)",
          line: "var(--color-frost-line)",
        },
        seal: {
          crimson: "var(--color-seal-crimson)",
        },
        glass: {
          bg: "var(--color-glass-bg)",
          "bg-elevated": "var(--color-glass-bg-elevated)",
          line: "var(--color-glass-line)",
          "line-bright": "var(--color-glass-line-bright)",
        },
        content: {
          bright: "var(--color-text-bright)",
          base: "var(--color-text-base)",
          mute: "var(--color-text-mute)",
          dim: "var(--color-text-dim)",
        },
        tier: {
          "server-readable": "var(--color-tier-server-readable)",
          "zero-access": "var(--color-tier-zero-access)",
          "end-to-end": "var(--color-tier-end-to-end)",
        },
      },
      fontFamily: {
        display: "var(--font-display)",
        body: "var(--font-body)",
        mono: "var(--font-mono)",
        arcane: "var(--font-arcane)",
      },
      borderRadius: {
        sm: "var(--radius-sm)",
        md: "var(--radius-md)",
        lg: "var(--radius-lg)",
        pill: "var(--radius-pill)",
      },
      spacing: {
        "token-1": "var(--space-1)",
        "token-2": "var(--space-2)",
        "token-3": "var(--space-3)",
        "token-4": "var(--space-4)",
        "token-6": "var(--space-6)",
        "token-8": "var(--space-8)",
        "token-12": "var(--space-12)",
      },
      transitionTimingFunction: {
        standard: "var(--motion-ease-standard)",
      },
      keyframes: {
        "frost-sweep": {
          "0%": { opacity: "0", backdropFilter: "blur(0px)" },
          "100%": { opacity: "1", backdropFilter: "blur(8px)" },
        },
      },
      animation: {
        "frost-sweep":
          "frost-sweep var(--motion-frost-flip-ms) var(--motion-ease-standard) forwards",
      },
    },
  },
  plugins: [tailwindcssAnimate],
};

export default config;
