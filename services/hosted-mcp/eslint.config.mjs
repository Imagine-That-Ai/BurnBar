import js from "@eslint/js";
import globals from "globals";
import tseslint from "typescript-eslint";

export default tseslint.config(
  {
    ignores: ["lib/**", "node_modules/**"],
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
