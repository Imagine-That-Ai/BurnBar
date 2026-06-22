// Compile the console's full styling surface into ONE self-contained stylesheet
// for /design-sync's cfg.cssEntry. Mirrors what Next.js produces at runtime:
//   1. Pensieve base tokens (packages/design-tokens → styles/pensieve.tokens.css)
//      provide --space-*, --radius-pill, --motion-ease-standard, etc.
//   2. globals.css overrides colors/fonts/radii to the "Quiet Editorial" light
//      palette and defines the @layer component classes (btn-*, glass-pane, …).
//   3. Tailwind scans ./app ./components ./lib (per tailwind.config.ts content)
//      and emits every utility class the components reference.
//   4. The brand fonts (Bricolage Grotesque / Geist / Geist Mono / Newsreader)
//      load from Google Fonts exactly as app/layout.tsx links them.
// We concatenate base+globals (dropping globals' local @import) so there is no
// relative @import for the compiler to resolve — deterministic on any machine.
//
// Usage: node .ds-build-css.mjs <out.css>   (run from apps/console)
import postcss from "postcss";
import tailwindcss from "tailwindcss";
import autoprefixer from "autoprefixer";
import { readFileSync, writeFileSync } from "node:fs";

const FONTS =
  "@import url('https://fonts.googleapis.com/css2?" +
  "family=Bricolage+Grotesque:opsz,wght@12..96,400;12..96,500;12..96,600;12..96,700;12..96,800" +
  "&family=Geist:wght@300;400;500;600" +
  "&family=Geist+Mono:wght@400;500" +
  "&family=Newsreader:ital,opsz@1,6..72&display=swap');\n";

const base = readFileSync("styles/pensieve.tokens.css", "utf8");
const globals = readFileSync("styles/globals.css", "utf8").replace(
  /@import\s+["']\.\/pensieve\.tokens\.css["'];?\s*\n?/,
  "",
);

const input = FONTS + base + "\n" + globals;
const out = process.argv[2] || ".ds-preview.css";

const result = await postcss([tailwindcss("./tailwind.config.ts"), autoprefixer()]).process(
  input,
  { from: "styles/globals.css", to: out },
);

writeFileSync(out, result.css);
console.log(`wrote ${out}: ${(result.css.length / 1024).toFixed(1)} KB`);
