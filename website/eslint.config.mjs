import tsParser from "@typescript-eslint/parser";
import tsPlugin from "@typescript-eslint/eslint-plugin";
import prettier from "eslint-config-prettier";

export default [
  {
    ignores: ["dist/**", ".astro/**", "node_modules/**", "scripts/**"],
  },
  {
    files: ["src/**/*.ts", "src/**/*.astro"],
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
      "no-console": "warn",

      // Enforce cyclomatic complexity threshold
      "complexity": ["warn", { max: 20 }],

      // Enforce naming conventions
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

      // Disallow unused vars
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" },
      ],
    },
  },
  // Must be last: turns off all ESLint rules that conflict with Prettier formatting
  prettier,
];
