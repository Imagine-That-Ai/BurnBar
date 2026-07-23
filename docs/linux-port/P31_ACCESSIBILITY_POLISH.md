# P31 Linux Accessibility and Visual-Preference Parity

P31 is the shared-shell accessibility polish slice for the Linux desktop app.
It keeps the existing semantic landmarks and focus behavior while making the
surface respond consistently to system visual preferences across every route.

## Implemented contract

- `prefers-reduced-motion: reduce` disables shell animations and transitions and
  restores automatic scrolling. The existing `body.reduced-motion` class remains
  the runtime/evidence hook and is not removed.
- `prefers-contrast: more` strengthens control borders and focus rings and gives
  status and alert regions a visible outline without changing the frozen nav
  geometry.
- `forced-colors: active` replaces translucent glass/gradient decoration with
  system Canvas, Button, Field, and Highlight colors. Focus uses a system
  Highlight outline and selected tabs/current navigation retain a visible
  selected state.
- `prefers-reduced-transparency: reduce` is tracked at runtime by the shell and
  applies an opaque, blur-free Liquid Glass fallback across lazy-loaded routes.
  The listener follows live desktop preference changes and supports the legacy
  WebKitGTK listener API.
- Status and alert regions keep their existing `role="status"` and
  `role="alert"` semantics. Keyboard controls remain native buttons/inputs and
  continue to receive `:focus-visible` styling.

## Linux-native support boundaries

The CSS contract is portable across WebView implementations that expose the
standard media features. Desktop environment and toolkit accessibility settings
may map to these features differently, so installed-session QA must cover the
supported GNOME/Wayland, KDE/Wayland, and X11 combinations before claiming
environment-wide parity.

This slice does not claim a native AT bridge, compositor-level contrast control,
global input capture, or a Linux desktop portal integration. Screen readers,
keyboard navigation, and native display preferences remain dependent on the
WebView/desktop session and are verified at the installed-app boundary.

## Acceptance criteria

1. The global stylesheet contains reduced-motion, reduced-transparency,
   increased-contrast, and forced-colors contracts.
2. Forced-colors mode has no required dependency on blur, gradients, or custom
   palette values for control, focus, selected-state, status, or alert legibility.
3. High-contrast mode increases focus/control/status affordance visibility
   without changing the geometry-frozen navigation rail.
4. Existing status/alert roles and keyboard-control semantics remain present in
   the DOM contract test.
5. The focused Vitest, TypeScript, production bundle, and Linux diff checks pass.

## QA verification

Run from `apps/linux-desktop`:

```sh
npx vitest run src/accessibility/accessibilityContract.test.tsx --reporter=dot
npx tsc --noEmit
npm run build
```

For installed evidence, launch the packaged candidate once with each supported
desktop preference enabled and verify:

- Tab reaches the skip link, navigation, route controls, and primary actions;
- the focused control has a visible non-color-only indicator;
- daemon-offline and capability-unavailable messages remain announced as status
  or alert regions;
- reduced motion stops mesh, skeleton, shimmer, and route transitions;
- reduced transparency removes backdrop blur and makes glass surfaces opaque;
- forced colors removes dependency on the liquid-glass backdrop while preserving
  selected/current and warning/error distinctions through text and borders.

The installed checks are evidence requirements; this source slice does not mark
the parity ledger or environment receipts as certified.
