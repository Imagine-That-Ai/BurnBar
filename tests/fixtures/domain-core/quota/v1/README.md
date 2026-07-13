# Provider quota contract v1

This directory is the language-neutral oracle for pure provider quota parsing.
Each `*-input.json` file contains recorded provider-shaped input and each paired
`*-expected.json` file contains the normalized `ProviderQuotaSnapshot` fields
that are independent of fetch time and platform I/O.

The fixtures are consumed by the existing C# parsers, the Swift characterization
suite, and `openburnbar-domain-core`. A fixture change is a contract change: it
must update all active consumer tests in the same PR and explain whether the
provider format changed or the prior behavior was incorrect.

Inputs contain no credentials or user data. Timestamps are frozen.
