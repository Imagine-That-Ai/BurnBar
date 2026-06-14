import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    // src/generated/** is emitted by packages/hermes-wire-protocol/codegen.mjs
    // (DO NOT EDIT) and gated by that package's drift + parity tests, not by lint.
    ignores: ["lib/**", "node_modules/**", "src/generated/**"],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.ts"],
    languageOptions: {
      globals: { ...globals.node },
    },
    rules: {
      "@typescript-eslint/no-explicit-any": "error",
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }],
      curly: ["error", "all"],
      eqeqeq: ["error", "always"],
      "no-console": ["error", { allow: ["warn", "error"] }],
      "no-var": "error",
      "prefer-const": "error",
    },
  },
  {
    files: ["src/logging.ts", "src/login.ts"],
    rules: {
      "no-console": "off",
    },
  },
);
