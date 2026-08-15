import js from '@eslint/js';
import tseslint from '@typescript-eslint/eslint-plugin';
import tsparser from '@typescript-eslint/parser';
import globals from 'globals';
import prettier from 'eslint-config-prettier';

export default [
  {
    ignores: ['coverage/**', 'dist/**', 'node_modules/**']
  },
  js.configs.recommended,
  {
    files: ['src/**/*.ts', 'test/**/*.ts'],
    languageOptions: {
      parser: tsparser,
      parserOptions: {
        ecmaVersion: 2022,
        sourceType: 'module'
      },
      globals: {
        ...globals.browser,
        ...globals.node,
        ...globals.webextensions,
        browser: 'readonly'
      }
    },
    plugins: {
      '@typescript-eslint': tseslint
    },
    rules: {
      ...tseslint.configs.recommended.rules,
      '@typescript-eslint/consistent-type-imports': 'error',
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-non-null-assertion': 'error',
      '@typescript-eslint/no-unused-vars': [
        'error',
        {
          argsIgnorePattern: '^_',
          varsIgnorePattern: '^_'
        }
      ],
      curly: ['error', 'all'],
      eqeqeq: ['error', 'always'],
      'no-undef': 'off',
      'no-console': ['error', { allow: ['warn', 'error'] }],
      'no-debugger': 'error',
      'no-eval': 'error',
      'no-var': 'error',
      'prefer-const': 'error'
    }
  },
  {
    // src/background runs as the MV3 service worker and src/shared is imported
    // by it. Neither may touch DOM-only globals: `window.setTimeout` in the Ask
    // stream flush once threw ReferenceError on the first delta and silently
    // truncated every streamed answer. tsconfig.background.json is the
    // compile-time twin of this rule.
    files: ['src/background/**/*.ts', 'src/shared/**/*.ts'],
    languageOptions: {
      globals: {
        ...globals.serviceworker,
        ...globals.webextensions,
        browser: 'readonly'
      }
    },
    rules: {
      'no-restricted-globals': [
        'error',
        ...[
          'window',
          'document',
          'localStorage',
          'sessionStorage',
          'history',
          'location',
          'alert',
          'confirm',
          'prompt',
          'requestAnimationFrame',
          'cancelAnimationFrame',
          'XMLHttpRequest',
          'DOMParser',
          'Image',
          'HTMLElement',
          'Node',
          'Element'
        ].map((name) => ({
          name,
          message: `${name} does not exist in the background service worker. Use worker-safe globals (setTimeout, fetch, OffscreenCanvas, createImageBitmap) or move the code to the popup/content surface.`
        }))
      ]
    }
  },
  {
    files: ['test/**/*.ts'],
    languageOptions: {
      globals: {
        ...globals.vitest
      }
    },
    rules: {
      '@typescript-eslint/no-non-null-assertion': 'off'
    }
  },
  {
    files: ['scripts/**/*.mjs'],
    languageOptions: {
      globals: {
        ...globals.node
      }
    },
    rules: {
      curly: ['error', 'all'],
      eqeqeq: ['error', 'always'],
      'no-console': ['error', { allow: ['warn', 'error'] }],
      'no-debugger': 'error',
      'no-eval': 'error',
      'no-var': 'error',
      'prefer-const': 'error'
    }
  },
  {
    files: ['src/content/pageWorldRunner.js'],
    languageOptions: {
      parser: undefined,
      globals: {
        ...globals.browser
      }
    },
    rules: {
      'no-new-func': 'off'
    }
  },
  prettier
];
