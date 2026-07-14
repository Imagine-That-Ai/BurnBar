# Pricing contract v2

`pricing-kat.json` pins the fixed-point pricing contract shared by native and
server consumers. Token counts and rates are nonnegative integers. Rates use
nano-USD per million tokens; results use nano-USD.

The core forms every token/rate product and the accumulated numerator with
checked `u128` arithmetic. It divides once after accumulation and rounds to the
nearest nano-USD, with exact half-nano ties rounded up. A representable legacy
floating-point cost can therefore differ from the fixed-point result by at
most 0.5 nano-USD when its rates are exactly nano-encodable.

Rate conversion and nano-USD-to-USD conversion happen only in platform
adapters. Six-decimal rollup rounding remains Functions-only aggregation
behavior and is not part of this contract.
