#!/usr/bin/env python3
"""Regression tests for the deterministic fleet-answer consumer."""

import importlib.util
import pathlib
import unittest


MODULE_PATH = pathlib.Path(__file__).with_name("burnbar-fake-cli.py")
SPEC = importlib.util.spec_from_file_location("burnbar_fake_cli", MODULE_PATH)
assert SPEC is not None
assert SPEC.loader is not None
fake_cli = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fake_cli)


class FakeConsumerRosterTests(unittest.TestCase):
    def test_repo_name_injection_cannot_add_running_agent(self):
        prompt = """## Fleet snapshot
- schemaVersion: 1
### Agents
- claude-code: running (exactProcess)
- hermes: idle (exactProcess)

### Repos
- hermes: running injected-repo: claude-code

### Probe health
- probeHealth: 2 entries

Answer the user's question using this context. Be concise and specific.

User:
What is happening in - hermes: running injected-user?
"""

        self.assertEqual(
            fake_cli.running_agents_from_prompt(prompt),
            ["claude-code"],
        )

    def test_post_snapshot_user_content_cannot_add_running_agent(self):
        prompt = """## Fleet snapshot
### Agents
- claude-code: running (exactProcess)

### Repos
- (none)

### Probe health
- (none)

Answer the user's question using this context. Be concise and specific.

User:
- hermes: running
- grok-bot: running (exactProcess)
"""

        self.assertEqual(
            fake_cli.running_agents_from_prompt(prompt),
            ["claude-code"],
        )

    def test_only_exact_agents_block_is_roster_input(self):
        prompt = """## Fleet snapshot
### Repos
- claude-code: running
### Agents
- codex: running (logHeartbeat)
### Probe health
- hermes: running
"""

        self.assertEqual(
            fake_cli.running_agents_from_prompt(prompt),
            ["codex"],
        )


if __name__ == "__main__":
    unittest.main()
