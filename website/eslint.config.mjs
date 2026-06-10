import tsParser from "@typescript-eslint/parser";
import tsPlugin from "@typescript-eslint/eslint-plugin";
import astroPlugin from "eslint-plugin-astro";
import prettier from "eslint-config-prettier";

export default [
  {
    ignores: ["dist/**", ".astro/**", "node_modules/**", "scripts/**", "src/env.d.ts"]
  },
  ...astroPlugin.configs.recommended,
  {
    files: ["src/**/*.ts"],
    languageOptions: {
      ecmaVersion: 2022,
      parser: tsParser,
      sourceType: "module"
    },
    plugins: {
      "@typescript-eslint": tsPlugin
    },
    rules: {
      ...tsPlugin.configs.recommended.rules,
      "no-console": "warn",

      // Enforce cyclomatic complexity threshold
      complexity: ["warn", { max: 20 }],

      // Enforce naming conventions
      "@typescript-eslint/naming-convention": [
        "warn",
        // camelCase for variables and functions
        {
          selector: "variable",
          format: ["camelCase", "UPPER_CASE", "PascalCase"],
          leadingUnderscore: "allowSingleOrDouble",
          trailingUnderscore: "allowSingleOrDouble"
        },
        {
          selector: "function",
          format: ["camelCase", "PascalCase"]
        },
        // PascalCase for types, interfaces, classes, enums
        {
          selector: "typeLike",
          format: ["PascalCase"]
        },
        {
          selector: "interface",
          format: ["PascalCase"],
          custom: { regex: "^I[A-Z]", match: false }
        },
        // PascalCase or UPPER_CASE for enum members
        {
          selector: "enumMember",
          format: ["PascalCase", "UPPER_CASE"]
        },
        // camelCase for class methods and properties
        {
          selector: "classMethod",
          format: ["camelCase"],
          leadingUnderscore: "allow"
        },
        {
          selector: "classProperty",
          format: ["camelCase", "UPPER_CASE"],
          leadingUnderscore: "allow"
        }
      ],

      // Disallow unused vars
      "@typescript-eslint/no-unused-vars": [
        "error",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_" }
      ]
    }
  },
  {
    // Relocations of the formerly-inline BaseLayout background scripts
    // (externalized so they ship as hashed immutable /_assets modules instead
    // of re-downloading with every no-store HTML page). They stay loose JS
    // under @ts-nocheck because semantic edits risk pixel parity with
    // production; allow that marker until a typed rewrite lands. Deliberate
    // deviations from the inline originals (lazy logo loads, idle-theme loop
    // parking, rAF-coalesced rect reads) are recorded in each file's header.
    files: [
      "src/scripts/emberSwarm.ts",
      "src/scripts/dotConstellation.ts",
      "src/scripts/easterEggFx.ts",
      "src/scripts/pretextShrinkwrap.ts"
    ],
    rules: {
      "@typescript-eslint/ban-ts-comment": "off"
    }
  },
  // Must be last: turns off all ESLint rules that conflict with Prettier formatting
  prettier
];
