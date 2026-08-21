---
name: short-ask-concise-build
description: Prevents 'short ask, long tree' explosion of unnecessary abstractions, micro-files, wrapper boilerplate, and complex directory hierarchies for straightforward requests.
---

# Concise Architecture: Anti-Overengineering (@zarazhangrui)

Prevents the "short ask, long tree" pathology where a simple request triggers the creation of 12 files, 4 abstract factory interfaces, 3 configuration classes, and an explosion of unnecessary boilerplate.

---

## 1. The "Short Ask, Long Tree" Pathology

When asked for a straightforward utility or feature (e.g. *"Add a function to format token counts"*), AI frequently creates:
- `types/token-formatter.types.ts`
- `interfaces/ITokenFormatter.ts`
- `services/TokenFormatterService.ts`
- `factories/TokenFormatterFactory.ts`
- `constants/token-formatter.constants.ts`
- `utils/token-helpers.ts`
- `__tests__/unit/TokenFormatterService.spec.ts`

This clutters codebases, increases maintenance overhead, introduces cognitive load, and slows down builds.

---

## 2. The Rule of Proportionality

The complexity of the solution must be proportional to the complexity of the problem.

- **1 utility function = 1 function in an existing or single focused file.**
- Do not create an interface if there is only ever one implementation.
- Do not create an abstract class or factory until 3 distinct implementations exist (Rule of Three).
- Do not split a 30-line cohesive piece of logic across 5 directories.
- Keep data structures and their direct operations together unless separation provides concrete architectural value.

### Bad vs Good
```
❌ Bad:
src/
  features/
    user-greeting/
      interfaces/
        IGreetingProvider.ts
      models/
        GreetingContext.ts
      services/
        GreetingService.ts
      factories/
        GreetingFactory.ts
      index.ts

✅ Good:
src/
  utils/
    greeting.ts // 15 lines, exported pure function
```

---

## 3. Code Organization Decision Tree

1. **Can this live in an existing file?** ➔ Add it there.
2. **Does it need its own file?** ➔ Create one file with the function/class and its local types.
3. **Does it need a whole directory?** ➔ Only if it represents a major, multi-component subsystem.
