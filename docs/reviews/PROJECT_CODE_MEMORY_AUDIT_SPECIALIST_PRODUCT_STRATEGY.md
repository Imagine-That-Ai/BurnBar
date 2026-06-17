# Specialist Report: Product Strategy Agent

## Scope covered
- BurnBar Project Code Memory & Agent Memory feature vs. frontier code assistants (June 2026).
- Comparison targets: Cursor, Claude Code, GitHub Copilot / Copilot Workspace, Sourcegraph Cody/Amp, Aider, Devon/DeepWiki.
- Highest-leverage upgrades preserving local-first/E2EE trust.

## Files inspected
- `docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md`
- `tools/openburnbar-mcp/project_code_memory.py`
- `tools/openburnbar-mcp/tests/test_project_code_memory.py`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ProjectCodeMemory/BurnBarProjectCodeMemoryStore.swift`
- `crates/project-code-static-parser/src/main.rs`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarIndexedSearchService.swift`
- `docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md`
- `docs/PENSIEVE.md`
- `docs/HOSTED_REMOTE_MCP.md`

## Commands run
- `wc -l` on key implementation files.
- `pytest tools/openburnbar-mcp/tests/test_project_code_memory.py -v` → 10 passed.
- `cargo test` (Rust parser) → 8 passed.

## Internet sources used
| Source | URL |
|---|---|
| Cursor — Securely indexing large codebases | https://cursor.com/blog/secure-codebase-indexing |
| Towards Data Science — How Cursor indexes codebases | https://towardsdatascience.com/how-cursor-actually-indexes-your-codebase/ |
| Zylos — Codebase Intelligence 2026 | https://zylos.ai/research/2026-04-19-codebase-intelligence-repository-understanding-ai-agents |
| Jose Nobile — Cursor IDE Complete Guide 2026 | https://josenobile.co/guides/cursor/ |
| GitHub Copilot Workspace / AIDevMe guide | https://aidevme.com/github-copilot-workspace-context-the-complete-developer-guide-to-smarter-ai-coding/ |
| StackOverflow — Copilot multi-file context | https://stackoverflow.com/questions/76509513/how-to-use-github-copilot-for-multiple-files |
| Claude Code changelog/docs | https://code.claude.com/docs/en/changelog |
| Karan Bansal — Claude Code LSP upgrade | https://karanbansal.in/blog/claude-code-lsp/ |
| Anthropic issue #40282 — LSP surface | https://github.com/anthropics/claude-code/issues/40282 |
| Sourcegraph / TechInterview guide | https://www.techinterview.org/companies/sourcegraph/ |
| Bito — Sourcegraph Cody alternatives 2026 | https://bito.ai/ai-tools/sourcegraph-alternatives/ |
| VibecodedThis — Amp Code Review 2026 | https://vibecodedthis.com/reviews/sourcegraph-cody-review-2026/ |
| Digital Applied — Aider Deep Dive 2026 | https://www.digitalapplied.com/blog/aider-deep-dive-cli-agentic-coding-tutorial-2026 |
| Hermes Agent — PageRank Repo Map | https://github.com/NousResearch/hermes-agent/issues/535 |
| ZenML / Devon knowledge graphs | https://www.zenml.io/llmops-database/building-an-autonomous-ai-software-engineer-with-advanced-codebase-understanding-and-specialized-model-training-6bnir |

## Findings by severity

### Critical — Feature feels useful but not powerful unless fixed
1. **No automatic repo-map / structural context assembly.** Evidence: `BurnBarProjectCodeMemoryStore.swift:630-909` builds flat hit lists. Why it matters: Aider’s PageRank repo-map gives 50×+ context efficiency.
2. **Chunking is text-bound, not AST-aware.** Evidence: `project_code_memory.py:563-578` (2400-char line-bound); Swift `:481` (4000-char). Frontier systems chunk at function/class boundaries.
3. **Semantic search underpowered by deterministic fake embedder.** Evidence: `project_code_memory.py:513-530`. Cannot answer natural-language questions like "where is authentication handled?"

### High — Meaningful gaps vs. frontier agents
4. **No live LSP diagnostic/code-action loop.** Evidence: `BurnBarProjectCodeMemoryStore.swift:796-818` only reads cached JSON.
5. **Incremental indexing is coarse (full reindex).** Evidence: `project_code_memory.py:1723`; Swift `:554-628`.
6. **Static parser supports only 4 languages.** Evidence: `main.rs:211-219`.
7. **No test discovery / test-aware context.** No tool surfaces or runs related tests.
8. **Call graph is lexical, not type-aware.** Evidence: `project_code_memory.py:1911-1987`; Swift `:1609-1662`.

### Medium — Competitive parity issues
9. **No natural-language codebase Q&A with citations.**
10. **No semantic diff / patch understanding.**
11. **No cross-project / multi-root workspace context.**
12. **Storage budget small for serious codebases** — default 512MB, cap 10GB.

### Low / Info
13. Watcher uses polling, not FSEvents + `.git/HEAD`.
14. Diagnostics cache has no producer.
15. Context pack lacks token budget fidelity (char÷4 heuristic).

## Evidence: Capability comparison
| Capability | BurnBar today | Frontier standard | Verdict |
|---|---|---|---|
| Local-first default | ✅ Strong | Varies | BurnBar stronger |
| Index trigger | Manual / polling watcher | Auto + Merkle incremental | Behind |
| Chunking | Fixed char | AST-aware | Behind |
| Semantic retrieval | Deterministic 96-dim hash | Learned dense + BM25 | Behind |
| Symbol extraction | 4 tree-sitter + regex | 25+ languages / LSP | Behind |
| References/call graph | Lexical token matching | SCIP/LSP precise | Behind |
| Post-edit diagnostics | Passive cache reader | Real-time LSP loop | Missing |
| Repo map | None | PageRank / structural | Missing |
| Cross-repo | None | Multi-root workspace | Missing |
| Test integration | None | Test runner feedback | Missing |
| NL codebase Q&A | Search hit list | Synthesized cited answers | Missing |

## Highest-leverage product upgrades
1. **Ship a repo-map / PageRank context tool** over existing symbol-reference graph.
2. **Adopt AST-aware chunking** at function/class boundaries.
3. **Upgrade to real local embeddings** for code (keep on-device).
4. **Expand static parser languages** and add query-driven LSP.
5. **Implement Merkle-tree incremental indexing** with `.git/HEAD` watching.
6. **Add live LSP diagnostic/code-action integration** for agent self-correction.
7. **Build test-discovery and test-running context.**
8. **Natural-language codebase Q&A with citations.**
9. **Semantic diff / patch context.**
10. **Cross-project workspace context (local-only).**

## Recommended prioritization
| Phase | Upgrade | Est. Impact | Trust Cost |
|---|---|---|---|
| P0 | Repo-map / PageRank context tool | Very High | None |
| P0 | AST-aware chunking | High | None |
| P1 | Real local embeddings | High | Low |
| P1 | Expand static parser languages | High | None |
| P1 | Merkle incremental indexing | High | None |
| P2 | Live LSP diagnostics/code actions | Very High | Low |
| P2 | Test discovery / run integration | High | None |
| P3 | NL codebase Q&A | High | Low |
| P3 | Semantic diff / patch context | Medium | None |
| P4 | Cross-project workspace context | Medium | Low |

## Open questions
1. Will BurnBar ship a default local embedder or require user download?
2. LSP trust boundary: sandbox or approve LSP binaries?
3. Hosted code sync timeline for Pensieve cloak-leakage re-evaluation?
4. Should repo map be auto-injected or explicit tool?
5. How handle symlinks/nested git repos sharing physical files?
6. Should BurnBar run tests itself or surface them for agent shell tool?
7. Does BurnBar have internal retrieval eval benchmark?

## Bottom line
BurnBar’s Project Code Memory is a solid, privacy-first *storage and retrieval substrate* with excellent trust primitives. Where it lags the frontier is in *agent-facing intelligence*: no repo-map, no AST chunking, no real embeddings, no live LSP diagnostic loop, no test integration. The highest-leverage upgrade is a graph-based repo-map context tool, because it turns existing symbol/reference tables into the structural overview agents need to navigate large codebases without burning tokens on blind search.
