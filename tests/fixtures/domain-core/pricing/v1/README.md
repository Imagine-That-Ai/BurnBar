# Pricing contract v1

`pricing-kat.json` pins the duplicated pricing behavior shared by Swift and
Cloud Functions:

- per-million-token input, output, cache-create, and cache-read arithmetic;
- input-rate fallback when a model has no explicit cache-create rate; and
- the era-pinned Kimi `chatcmpl-` rewrite, model alias, cache subtraction,
  total-token calculation, and historical rates.

Numbers intentionally use the existing IEEE-754 operation order. Final
six-decimal rollup rounding is Functions-only aggregation behavior and is not a
cross-platform pricing contract.
