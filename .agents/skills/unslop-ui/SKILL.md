---
name: unslop-ui
description: Prevents generic AI UI slop: default purple/indigo gradients, floating glow borders, nested card-in-card chrome, low contrast, and template clichés. Enforces clean, functional, platform-native design.
---

# Unslop UI: Clean & Platform-Native Interface Design (poteto / unslop)

Eliminates the generic "AI template" aesthetic: violet/indigo gradients, stacked border cards, glowing neon pill badges, low-contrast grey text, and excessive chrome that gets in the way of content.

---

## 1. The AI UI Cliché Checklist (Banned Patterns)

- ❌ **Default Violet / Indigo Gradients:** `bg-gradient-to-r from-indigo-500 via-purple-500 to-pink-500` used on every button, heading, and card border.
- ❌ **Stacked Card Chrome:** Nesting a card inside a card inside a card with 3 different border radiuses and border colors.
- ❌ **Glow / Neon Outer Halos:** Excessive `shadow-[0_0_20px_rgba(...)]` on standard interactive elements.
- ❌ **Low-Contrast Micro-Typography:** `text-xs text-gray-400` on dark backgrounds that fails WCAG AA legibility standards.
- ❌ **Generic Pill Badges:** Decorative colored pill badges everywhere with no semantic purpose.
- ❌ **Floating Hero Blobs:** Blurry circular SVG backdrop gradients placed arbitrarily behind text.

---

## 2. Principles of Unslop UI

1. **Content First, Chrome Second:**
   - Reduce visual noise. Let typography, data, and layout carry the interface.
   - Use borders OR background differences, not both stacked together.
2. **Platform Authenticity:**
   - macOS: Native translucency, standard SF Pro typography, standard control heights, platform keybindings.
   - iOS: Human Interface Guidelines, fluid gestures, proper safe area insets, native navigation bars.
   - Android: Material You dynamic color, standard elevation, proper touch targets (48dp).
   - Web: Semantic HTML, robust keyboard navigation, responsive flex/grid layouts.
3. **Intentional Color Palette:**
   - Pick a purposeful brand primary and clean semantic accents (error, warning, success, info).
   - High contrast ratios (minimum 4.5:1 for body copy).
4. **Accessible Spacing & Hierarchy:**
   - Generous whitespace, predictable hierarchy, clear focus indicators.

---

## 3. Bad vs Good UI Refactor

```html
<!-- ❌ AI SLOP UI -->
<div class="p-6 bg-slate-900 border border-purple-500/30 rounded-2xl shadow-2xl shadow-purple-500/10">
  <span class="px-2 py-1 bg-gradient-to-r from-purple-500 to-pink-500 text-xs font-semibold text-white rounded-full">PRO</span>
  <h3 class="text-xl font-bold bg-gradient-to-r from-purple-400 to-pink-400 bg-clip-text text-transparent mt-2">Active Session</h3>
  <div class="mt-4 p-4 bg-slate-800/50 border border-slate-700 rounded-xl">
    <p class="text-xs text-slate-400">Status: Running</p>
  </div>
</div>

<!-- ✅ CLEAN UNSLOP UI -->
<div class="p-5 bg-surface border border-subtle rounded-lg">
  <div class="flex items-center justify-between">
    <h3 class="text-base font-semibold text-text-primary">Active Session</h3>
    <span class="inline-flex items-center gap-1.5 text-xs font-medium text-emerald-600 dark:text-emerald-400">
      <span class="w-2 h-2 rounded-full bg-emerald-500"></span>
      Running
    </span>
  </div>
  <p class="mt-2 text-sm text-text-secondary">Started 12m ago by user@example.com</p>
</div>
```
