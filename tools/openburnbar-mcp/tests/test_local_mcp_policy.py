#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import os
import sys
import types
import unittest
from pathlib import Path


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))


def _load_server():
    if "mcp.server.fastmcp" not in sys.modules:
        mcp_mod = types.ModuleType("mcp")
        server_mod = types.ModuleType("mcp.server")
        fastmcp_mod = types.ModuleType("mcp.server.fastmcp")

        class _FastMCP:
            def __init__(self, _name: str):
                pass

            def tool(self):
                def decorator(func):
                    return func

                return decorator

            def run(self):
                raise AssertionError("test stub should not run the MCP server")

        fastmcp_mod.FastMCP = _FastMCP
        sys.modules["mcp"] = mcp_mod
        sys.modules["mcp.server"] = server_mod
        sys.modules["mcp.server.fastmcp"] = fastmcp_mod

    spec = importlib.util.spec_from_file_location("openburnbar_mcp_server_policy_test", str(_PARENT / "server.py"))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_policy_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


class LocalMcpPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self._saved_env = dict(os.environ)
        for name in list(os.environ):
            if name.startswith("OPENBURNBAR_LOCAL_MCP_"):
                os.environ.pop(name, None)
        os.environ["OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT"] = "true"
        self.server = _load_server()

    def tearDown(self) -> None:
        os.environ.clear()
        os.environ.update(self._saved_env)

    def _payload(self, raw: str) -> dict:
        return json.loads(raw)

    def test_default_profile_denies_cloud_decrypt_local_write_sensitive_read_and_spawn(self) -> None:
        cloud = self._payload(self.server.burnbar_cloud_semantic_search_conversations("vault key"))
        self.assertEqual(cloud["code"], "MCP_CAPABILITY_DISABLED")
        self.assertEqual(cloud["capability"], "cloud_decrypt")

        write = self._payload(
            self.server.burnbar_record_hermes_usage(
                provider_id="hermes",
                model_id="minimax-m2.7-highspeed",
                input_tokens=1,
                output_tokens=1,
            )
        )
        self.assertEqual(write["code"], "MCP_CAPABILITY_DISABLED")
        self.assertEqual(write["capability"], "local_write")

        read = self._payload(self.server.burnbar_get_conversation("conversation-1"))
        self.assertEqual(read["code"], "MCP_CAPABILITY_DISABLED")
        self.assertEqual(read["capability"], "sensitive_read")

        spawn = self._payload(self.server.burnbar_spawn_resume("session-1"))
        self.assertEqual(spawn["code"], "MCP_CAPABILITY_DISABLED")
        self.assertEqual(spawn["capability"], "spawn_process")

    def test_specific_env_flags_enable_only_the_requested_capability(self) -> None:
        os.environ["OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_DECRYPT"] = "true"
        cloud = self._payload(self.server.burnbar_cloud_semantic_search_conversations("vault key"))
        self.assertEqual(cloud["code"], "CLOUD_AUTH_UNCONFIGURED")

        spawn = self._payload(self.server.burnbar_spawn_resume("session-1"))
        self.assertEqual(spawn["code"], "MCP_CAPABILITY_DISABLED")
        self.assertEqual(spawn["capability"], "spawn_process")

    def test_operator_profile_enables_process_spawn_gate(self) -> None:
        os.environ["OPENBURNBAR_LOCAL_MCP_PROFILE"] = "operator"
        self.server.spawn_resume = lambda session_id, **_kwargs: {"kind": "spawned", "session_id": session_id}

        spawn = self._payload(self.server.burnbar_spawn_resume("session-1"))

        self.assertEqual(spawn["kind"], "spawned")
        self.assertEqual(spawn["session_id"], "session-1")


if __name__ == "__main__":
    unittest.main()
