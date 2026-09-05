"""Session-start briefing pack builder (Packet P16 / C12).

Provides an opt-in, token-budgeted memory briefing pack for the current repo/branch,
wrapped as untrusted retrieved data.
Reuses the consent gate pattern from the resume-briefing gate.
Budget estimator: in-repo tokenizer from memory_engine.text (_estimate_tokens),
which uses context token encoder if available and falls back to chars/4.
No new dependencies.
"""

from __future__ import annotations

import os
from collections.abc import Callable

import memory_engine as me
from memory_engine.text import _estimate_tokens
import project_code_memory as pcm

OPT_IN_ENV = "OPENBURNBAR_SESSION_BRIEFING"
OPT_IN_ENV_ALT = "OPENBURNBAR_MEMORY_SESSION_BRIEFING"
SENSITIVE_READ_ENV = "OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ"


def estimate_tokens(text: str) -> int:
    """Estimate token count for a text snippet.

    Reuses the in-repo tokenizer from memory_engine.text._estimate_tokens,
    which delegates to pcm._context_token_encoder() if available and
    falls back to max(1, len(text) // 4) (chars/4).
    Calibrated in-test against standard GPT/Claude tokenization.
    """
    return _estimate_tokens(text)


def is_session_briefing_opted_in() -> bool:
    """Check if session briefing is enabled via opt-in environment settings."""
    val = os.environ.get(OPT_IN_ENV) or os.environ.get(OPT_IN_ENV_ALT) or ""
    return val.strip().lower() in {"1", "true", "yes", "on", "enabled"}


def check_briefing_consent(
    capability_denial_fn: Callable[[str, str, str | None], str | None] | None = None,
) -> bool:
    """Check sensitive_read consent, matching the resume briefing gate (server.py:4875-4879).

    Requires explicit sensitive_read capability / consent.
    """
    if capability_denial_fn is not None:
        denial = capability_denial_fn(
            "burnbar_session_briefing",
            "sensitive_read",
            "Session briefings include prior transcript context and require explicit plaintext-read consent.",
        )
        return denial is None

    env_val = os.environ.get(SENSITIVE_READ_ENV, "").strip().lower()
    return env_val in {"1", "true", "yes", "on"}


def render_headings(project_name: str, project_root: str, branch: str | None = None) -> str:
    """Render the briefing section headings."""
    lines = [
        f"# Session Briefing: {project_name}",
        f"Repository: {project_root}",
    ]
    if branch:
        lines.append(f"Branch: {branch}")
    lines.append("## Decisions")
    lines.append("## Active Facts")
    return "\n".join(lines)


def build_session_briefing(
    engine: me.MemoryEngine,
    *,
    project_path: str | None = None,
    branch: str | None = None,
    token_budget: int = 1200,
    consent: bool | None = None,
    opt_in: bool | None = None,
    wrap: bool = True,
) -> str | None:
    """Build a token-budgeted session-start briefing pack for the current repo/branch.

    - If opt_in is False (or not enabled) or consent is False: yields None (nothing).
    - If token_budget <= 0: yields headings-only.
    - If memories are over-budget: degrades to headings-only rather than truncating mid-fact.
    - The returned pack is wrapped as untrusted retrieved data.
    """
    is_opted_in = opt_in if opt_in is not None else is_session_briefing_opted_in()
    if not is_opted_in:
        return None

    has_consent = consent if consent is not None else check_briefing_consent()
    if not has_consent:
        return None

    project_id, root = me.resolve_project(engine.conn, project_path)
    project_payload_info = me.project_payload(project_id, root)
    project_name = project_payload_info.get("projectName") or project_id

    headings = render_headings(project_name=project_name, project_root=root, branch=branch)
    headings_cost = estimate_tokens(headings)

    # Budget <= 0 yields headings only
    if token_budget <= 0:
        if wrap:
            return pcm.wrap_untrusted_snippet(headings, source_tool="burnbar_session_briefing", record_id=project_id)
        return headings

    # Recall top active memories for the project
    recalled = engine.recall(
        "",
        project_path=project_path,
        limit=12,
        scope="all",
        wrap=None,
        reinforce=False,
        include_quarantined=False,
        include_superseded=False,
    )

    results = recalled.get("results", [])
    if not results:
        if wrap:
            return pcm.wrap_untrusted_snippet(headings, source_tool="burnbar_session_briefing", record_id=project_id)
        return headings

    decisions = [r for r in results if r.get("kind") == "decision"]
    facts = [r for r in results if r.get("kind") != "decision"]

    body_lines: list[str] = [
        f"# Session Briefing: {project_name}",
        f"Repository: {root}",
    ]
    if branch:
        body_lines.append(f"Branch: {branch}")

    fact_lines: list[str] = []
    if decisions:
        fact_lines.append("## Decisions")
        for d in decisions:
            fact_lines.append(f"- [decision/{d['scope']} c={d['confidence']:.2f} {d['memoryID']}] {d['body']}")

    if facts:
        fact_lines.append("## Active Facts")
        for f in facts:
            fact_lines.append(f"- [{f['kind']}/{f['scope']} c={f['confidence']:.2f} {f['memoryID']}] {f['body']}")

    full_text = "\n".join(body_lines + fact_lines)

    # Wrapper overhead reservation (~30 tokens for the envelope)
    wrapper_overhead = 30 if wrap else 0
    effective_budget = max(0, token_budget - wrapper_overhead)

    if estimate_tokens(full_text) <= effective_budget:
        final_content = full_text
    else:
        # Over budget: include whole facts only without mid-fact truncation.
        # If no whole facts fit in the budget, degrade to headings-only.
        included_facts: list[str] = []
        running_cost = headings_cost

        for line in fact_lines:
            line_cost = estimate_tokens(line + "\n")
            if running_cost + line_cost <= effective_budget:
                included_facts.append(line)
                running_cost += line_cost
            else:
                # Does not fit whole: do NOT truncate mid-fact.
                break

        # If no actual fact lines (only section headers) fit, degrade to headings only
        has_actual_facts = any(not line.startswith("##") for line in included_facts)
        if not has_actual_facts:
            final_content = headings
        else:
            final_content = "\n".join(body_lines + included_facts)

    if wrap:
        return pcm.wrap_untrusted_snippet(final_content, source_tool="burnbar_session_briefing", record_id=project_id)
    return final_content
