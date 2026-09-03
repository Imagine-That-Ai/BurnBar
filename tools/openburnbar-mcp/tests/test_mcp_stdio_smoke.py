#!/usr/bin/env python3
"""End-to-end MCP smoke test: a real stdio JSON-RPC session against server.py.

Codex's bootstrap test proves the memory toolset imports; this proves the
protocol path an MCP client actually uses: initialize, tools/list, and
tools/call for the memory tools, against a temporary store.
"""

from __future__ import annotations

import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
if str(_HERE) not in sys.path:
    sys.path.insert(0, str(_HERE))
from test_memory_engine import _load_server  # noqa: E402

_SERVER = Path(__file__).resolve().parent.parent / "server.py"

# Other test modules stub `mcp` into sys.modules, so availability is decided
# the way the test runs the server: in a fresh interpreter.
_MCP_IMPORTS = (
    subprocess.run([sys.executable, "-c", "import mcp.server.fastmcp"], capture_output=True, check=False).returncode
    == 0
)
pytestmark = pytest.mark.skipif(not _MCP_IMPORTS, reason="the mcp package is not installed for this interpreter")


class _Client:
    def __init__(self, workdir: Path, extra_env: dict[str, str] | None = None) -> None:
        env = dict(os.environ)
        env.update(
            {
                "BURNBAR_MCP_TOOLSET": "memory",
                "OPENBURNBAR_MEMORY_DB_PATH": str(workdir / "memory.sqlite"),
                "BURNBAR_DB_PATH": str(workdir / "app.sqlite"),
                "OPENBURNBAR_MEMORY_EMBEDDING_PROVIDER": "none",
                "OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT": "true",
                "OPENBURNBAR_DAEMON_SOCKET_PATH": str(workdir / "missing.sock"),
            }
        )
        for name in list(env):
            if name.startswith("OPENBURNBAR_LOCAL_MCP_ENABLE_") or name == "OPENBURNBAR_LOCAL_MCP_PROFILE":
                env.pop(name)
        env.update(extra_env or {})
        sqlite3.connect(workdir / "app.sqlite").close()
        self.proc = subprocess.Popen(
            [sys.executable, str(_SERVER)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
            bufsize=1,
        )
        self.seq = 0

    def rpc(self, method: str, params: dict | None = None, *, notify: bool = False) -> dict | None:
        message: dict = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if not notify:
            self.seq += 1
            message["id"] = self.seq
        assert self.proc.stdin is not None and self.proc.stdout is not None
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()
        if notify:
            return None
        deadline = time.time() + 60
        while time.time() < deadline:
            line = self.proc.stdout.readline()
            if not line:
                raise AssertionError(
                    f"server closed stdout: {self.proc.stderr.read()[-800:] if self.proc.stderr else ''}"
                )
            try:
                payload = json.loads(line)
            except ValueError:
                continue
            if payload.get("id") == self.seq:
                return payload
        raise AssertionError("timed out waiting for the MCP response")

    def call(self, name: str, arguments: dict) -> dict:
        response = self.rpc("tools/call", {"name": name, "arguments": arguments})
        assert response is not None and "result" in response, response
        return json.loads(response["result"]["content"][0]["text"])

    def close(self) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.close()
        self.proc.wait(timeout=15)


def test_memory_toolset_over_stdio(tmp_path: Path) -> None:
    client = _Client(tmp_path)
    try:
        init = client.rpc(
            "initialize",
            {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "audit", "version": "0"}},
        )
        assert init is not None and init["result"]["serverInfo"]["name"] == "openburnbar-local"
        client.rpc("notifications/initialized", notify=True)
        listed = client.rpc("tools/list")
        assert listed is not None
        names = {tool["name"] for tool in listed["result"]["tools"]}
        assert {
            "burnbar_remember",
            "burnbar_memorize",
            "burnbar_recall",
            "burnbar_recall_pack",
            "burnbar_forget",
            "burnbar_memory_doctor",
            "burnbar_memory_ask",
        } <= names
        # The toolset filter applied at startup is exactly the server's declared memory toolset.
        assert names == set(_load_server().MEMORY_TOOLSET)
        repo = str(tmp_path)
        doctor = client.call("burnbar_memory_doctor", {"project_path": repo})
        assert (
            doctor["memoryEngine"]["status"] == "ok"
            and doctor["memoryEngine"]["writeCapability"]["memory_write"] is True
        )
        stored = client.call(
            "burnbar_remember",
            {
                "text": "Alberto prefers fewer, fatter PRs with one theme each.",
                "project_path": repo,
                "kind": "preference",
            },
        )
        assert stored["status"] == "ok" and stored["event"] == "ADD" and stored["scope"] == "personal"
        secret = client.call(
            "burnbar_remember", {"text": "Deploy uses ghp_" + "q" * 36 + " stored in 1Password.", "project_path": repo}
        )
        assert secret["sensitivity"] == "redacted" and "ghp_" not in secret["text"]
        recalled = client.call("burnbar_recall", {"query": "PR size preference", "project_path": repo, "limit": 3})
        assert recalled["results"][0]["memoryID"] == stored["memoryID"]
        assert recalled["results"][0]["body"].startswith("OPENBURNBAR_UNTRUSTED_CODE_V1")
        pack = client.call(
            "burnbar_recall_pack", {"query": "fewer fatter PRs", "project_path": repo, "token_budget": 300}
        )
        assert pack["included"] >= 1 and pack["tokensUsed"] <= pack["tokenBudget"]
        bad = client.call("burnbar_recall", {"query": "x", "project_path": repo, "filters": "{not json"})
        assert bad["code"] == "INVALID_JSON_ARGUMENT"
        forgotten = client.call("burnbar_forget", {"memory_id": stored["memoryID"], "project_path": repo})
        assert forgotten["status"] == "ok"
        assert client.call("burnbar_memory_get", {"memory_id": stored["memoryID"]})["status"] == "not_found"
        trail = client.call("burnbar_audit_trail", {"project_path": repo})
        assert trail["chain"]["ok"] is True
    finally:
        client.close()
    assert client.proc.returncode == 0


def test_memory_ask_over_stdio_is_gated_and_grounded(tmp_path: Path) -> None:
    """The Memory Pro answer tool through the real stdio path: denied without the
    capability, grounded (and wrapped) with it, against a loopback fake gateway."""
    import json as _json

    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from fakes.fake_gateway import FakeGateway, chat_reply
    from test_memory_providers import POLICY

    def answerer(path: str, body: dict) -> tuple[int, dict]:
        user = body["messages"][1]["content"]
        ids = re.findall(r"^\[([^\]\s]+)\]", user, re.M)
        return chat_reply(
            {"answer": "Fridays, from the release branch " + " ".join(f"[{i}]" for i in ids), "citations": ids}
        )

    fact = {"text": "We deploy from the release branch every Friday.", "project_path": str(tmp_path), "kind": "fact"}
    with FakeGateway(answerer) as gw:
        policy_env = {"OPENBURNBAR_MEMORY_MODEL_POLICY_JSON": _json.dumps(dict(POLICY, gatewayURL=gw.url))}
        denied_client = _Client(tmp_path, extra_env=policy_env)
        try:
            denied_client.rpc(
                "initialize",
                {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "audit", "version": "0"}},
            )
            denied_client.rpc("notifications/initialized", notify=True)
            assert denied_client.call("burnbar_remember", fact)["status"] == "ok"
            denied = denied_client.call(
                "burnbar_memory_ask", {"question": "When do we deploy?", "project_path": str(tmp_path)}
            )
            assert denied["code"] == "MCP_CAPABILITY_DISABLED" and denied["capability"] == "memory_llm_read"
        finally:
            denied_client.close()
        assert gw.requests == [], "a denied call never reaches the gateway"

        client = _Client(tmp_path, extra_env={**policy_env, "OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_LLM_READ": "true"})
        try:
            client.rpc(
                "initialize",
                {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "audit", "version": "0"}},
            )
            client.rpc("notifications/initialized", notify=True)
            answered = client.call(
                "burnbar_memory_ask", {"question": "When do we deploy?", "project_path": str(tmp_path)}
            )
        finally:
            client.close()
    assert answered["status"] == "ok" and answered["groundedness"] == "grounded", answered
    assert answered["answer"].startswith("OPENBURNBAR_UNTRUSTED_CODE_V1")
    assert answered["citations"] and all(
        c["snippet"].startswith("OPENBURNBAR_UNTRUSTED_CODE_V1") for c in answered["citations"]
    )
    assert answered["trustSignal"]["untrustedContentWrapped"] is True
    purposes = [h.get("x-openburnbar-purpose") for _, h, _ in gw.requests]
    # recall runs the policy-default rerank first; the answer purpose closes the call
    assert set(purposes) <= {"memory-rerank", "memory-answer"} and purposes[-1] == "memory-answer"
