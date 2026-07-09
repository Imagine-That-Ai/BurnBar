# Evidence — Engine G2 parser parity (Real)

**Ledger row:** `engine-parsers-g2`  
**Status claim:** Real  
**Date recorded:** 2026-07-09  

## What this proves

Multi-provider session corpus → **byte-identical** `ParserOutputContractRecord` output on Windows vs the macOS golden for **15 providers / 26 fixtures**, on both **x64** and **ARM64** Windows CI runners.

## Artifacts

| Artifact | Location |
|----------|----------|
| Harness | `OpenBurnBarCore/Sources/OpenBurnBarG2ParserParity/G2ParserParity.swift` |
| Golden | `AgentLensTests/Fixtures/ParserContract/parser-output-golden.json` |
| CI workflow | `.github/workflows/openburnbar-engine-windows.yml` |
| Green run | [28775204323](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/28775204323) on PR **#1270** (merged `cc56024f07`) |

## Explicit non-claims

- Does **not** prove WinUI chat streaming UI parity.
- Does **not** prove live provider network acquisition.
- Does **not** depend on `OPENBURNBAR_SAMPLE_MODE`, stubs, or demo hosts.
