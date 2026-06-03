// Flat ESLint config for the console (Next 15+; `next lint` is deprecated).
// Type-aware-lite: JS + typescript-eslint recommended, scoped to source.
import js from "@eslint/js";
import tseslint from "typescript-eslint";
import globals from "globals";

export default tseslint.config(
  {
    ignores: [
      "out/**",
      ".next/**",
      "node_modules/**",
      "lib/domains.generated.ts", // generated (synced from packages/data-domains)
      "next-env.d.ts",
      "test/interop/**", // swift + json fixtures
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    languageOptions: {
      globals: { ...globals.browser, ...globals.node, ...globals.serviceworker },
    },
    rules: {
      "@typescript-eslint/no-explicit-any": "warn",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
    },
  },
);
