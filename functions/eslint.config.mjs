import tsParser from "@typescript-eslint/parser";
import tsPlugin from "@typescript-eslint/eslint-plugin";
import prettier from "eslint-config-prettier";

export default [
  {
    ignores: ["lib/**", "node_modules/**"],
  },
  {
    files: ["src/**/*.ts"],
    languageOptions: {
      ecmaVersion: 2022,
      parser: tsParser,
      sourceType: "module",
    },
    plugins: {
      "@typescript-eslint": tsPlugin,
    },
    rules: {
      ...tsPlugin.configs.recommended.rules,
      "no-console": "error",

      // Enforce cyclomatic complexity threshold — warn on existing violations
      "complexity": ["warn", { max: 25 }],

      // Enforce naming conventions — warn to allow existing patterns to be
      // incrementally fixed; new code should follow these conventions
      "@typescript-eslint/naming-convention": [
        "warn",
        // camelCase for variables and functions
        {
          selector: "variable",
          format: ["camelCase", "UPPER_CASE", "PascalCase"],
          leadingUnderscore: "allowSingleOrDouble",
          trailingUnderscore: "allowSingleOrDouble",
        },
        {
          selector: "function",
          format: ["camelCase", "PascalCase"],
        },
        // PascalCase for types, interfaces, classes, enums
        {
          selector: "typeLike",
          format: ["PascalCase"],
        },
        {
          selector: "interface",
          format: ["PascalCase"],
          custom: { regex: "^I[A-Z]", match: false },
        },
        // PascalCase or UPPER_CASE for enum members
        {
          selector: "enumMember",
          format: ["PascalCase", "UPPER_CASE"],
        },
        // camelCase for class methods and properties
        {
          selector: "classMethod",
          format: ["camelCase"],
          leadingUnderscore: "allow",
        },
        {
          selector: "classProperty",
          format: ["camelCase", "UPPER_CASE"],
          leadingUnderscore: "allow",
        },
      ],

      // Disallow unused vars (use @typescript-eslint version)
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],

      // Warn on very large files — split these incrementally
      "max-lines": ["warn", { max: 600, skipComments: true, skipBlankLines: true }],
    },
  },
  {
    files: ["src/logging.ts"],
    rules: {
      "no-console": "off",
    },
  },
  // Must be last: turns off all ESLint rules that conflict with Prettier formatting
  prettier,
];
